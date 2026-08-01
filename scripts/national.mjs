#!/usr/bin/env node
/**
 * IOS.md §9 step 2: prove the line-up query nationally.
 *
 * The app's whole domain model was built and tested against three operators in the
 * south-east. Two assumptions in IOS.md have to survive going national, and both fail
 * quietly rather than loudly if they are wrong:
 *
 *   1. **The 23h59m window returns a whole service day anywhere.** If the API
 *      truncates, or paginates, or behaves differently at a Scottish station or a
 *      request stop, then "the last train tonight" is wrong outside the south-east
 *      and looks perfectly plausible while being wrong.
 *
 *   2. **Bearing to the destination, bucketed into four 90° sectors, produces
 *      directions a passenger would recognise.** §4 replaces the current longitude
 *      comparison with this. It is asserted in the spec and has never been run.
 *
 * Throwaway, per the build order. It is not wired into the app and nothing imports
 * it.
 *
 * Run:  npm run national            (today's service day)
 *       npm run national -- --date=2026-08-05
 *       npm run national -- Penzance "Fort William"
 *
 * Needs RTT_ACCESS_TOKEN or RTT_REFRESH_TOKEN in .env.local.
 *
 * Costs one API request per station. Reference data and NaPTAN are cached in
 * `.rtt-cache/`, so a second run costs the same again and no more -- and coordinates
 * cost nothing at all, because NaPTAN is the DfT's and not RTT's.
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const CACHE = join(ROOT, '.rtt-cache');
const BASE = 'https://data.rtt.io';
const API_VERSION = process.env.RTT_API_VERSION || '2026-04-09';

const NAPTAN_RAIL_CSV =
  'https://naptan.api.dft.gov.uk/v1/access-nodes?dataFormat=csv&atcoAreaCodes=910';

/**
 * The stations to probe, by name.
 *
 * §9 names Penzance, Inverness, Upminster and "somewhere rural". Each is here for a
 * reason rather than for spread:
 *
 *   Penzance     the far south-west terminus. Everything leaves in one direction,
 *                which is the degenerate case for a four-way compass control.
 *   Inverness    a genuine junction far outside the tested area, with routes leaving
 *                on several bearings -- the case the compass exists for.
 *   Upminster    known-good. PRODUCT.md states it has no northbound or southbound
 *                service, so if bucketing invents one here, it is wrong.
 *   Berney Arms  a request stop on the Norwich-Yarmouth line with a handful of trains.
 *                §8: "rural is the best case, not the edge case" -- it is where a
 *                wrong last train costs most.
 *   Denton       one of the least-used stations on the network. The extreme: a board
 *                that is nearly or entirely empty, which must be a believable answer
 *                rather than a failure.
 *
 * **Names, never codes.** No CRS is hand-typed anywhere in this project; they are
 * resolved from the API, and a name that does not resolve is a hard failure.
 */
const DEFAULT_STATIONS = ['Penzance', 'Inverness', 'Upminster', 'Berney Arms', 'Denton'];

/**
 * Below this, the two places are effectively the same spot and a bearing between them
 * means nothing. Matches `MIN_DELTA_DEGREES` in `lib/direction.ts`, which §4 says to
 * keep.
 *
 * It has to stay this small. A first pass at this probe used 5km on the reasoning
 * that a train terminating a couple of stops away gives a meaningless bearing, and it
 * silently removed **every** London Overground service on the Romford branch at
 * Upminster -- 32 real, boardable trains, dropped because Romford is 4.99km away. A
 * guard against two places being the same place is 140 metres; anything larger is a
 * guard against short journeys, which is a different and much worse idea.
 */
const MIN_BEARING_METRES = 150;

// ---------------------------------------------------------------- env loading

function loadEnvLocal() {
  try {
    for (const raw of readFileSync(join(ROOT, '.env.local'), 'utf8').split('\n')) {
      const line = raw.trim();
      if (!line || line.startsWith('#')) continue;
      const eq = line.indexOf('=');
      if (eq === -1) continue;
      const key = line.slice(0, eq).trim();
      let val = line.slice(eq + 1).trim();
      if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1);
      }
      if (!(key in process.env)) process.env[key] = val;
    }
  } catch {
    /* no .env.local; rely on the real environment */
  }
}

// ------------------------------------------------------------- service day

const SERVICE_DAY_START_HOUR = 3;

const londonParts = (d) => {
  const f = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  });
  const p = {};
  for (const part of f.formatToParts(d)) if (part.type !== 'literal') p[part.type] = part.value;
  return p;
};

const isoDate = (ms) => new Date(ms).toISOString().slice(0, 10);
const addDays = (date, n) => {
  const [y, m, d] = date.split('-').map(Number);
  return isoDate(Date.UTC(y, m - 1, d) + n * 86_400_000);
};

function currentServiceDate(now = new Date()) {
  const p = londonParts(now);
  const midnight = Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day));
  return isoDate(Number(p.hour) < SERVICE_DAY_START_HOUR ? midnight - 86_400_000 : midnight);
}

/** 03:00 -> 02:59, deliberately offset-less: the API reads it as local to the station. */
function serviceDayWindow(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return {
    timeFrom: `${date}T${pad(SERVICE_DAY_START_HOUR)}:00:00`,
    timeTo: `${addDays(date, 1)}T${pad(SERVICE_DAY_START_HOUR - 1)}:59:00`,
  };
}

const hasTimeZone = (v) => /(?:Z|[+-]\d{2}:?\d{2})$/i.test(String(v).trim());

/**
 * Minutes since 03:00 on the service date, for ordering and for span arithmetic.
 *
 * Departure strings arrive with no timezone at all, which is the defect this project
 * has already shipped once. Reading the wall clock out of the string directly is
 * correct precisely because it refuses to involve any timezone -- and the probe
 * asserts separately that the strings really are naive.
 */
function minutesIntoServiceDay(value, date) {
  if (!value) return null;
  const day = value.slice(0, 10);
  const hh = Number(value.slice(11, 13));
  const mm = Number(value.slice(14, 16));
  if (!Number.isFinite(hh) || !Number.isFinite(mm)) return null;
  const dayOffset = day === date ? 0 : day === addDays(date, 1) ? 1440 : null;
  if (dayOffset === null) return null;
  return dayOffset + hh * 60 + mm - SERVICE_DAY_START_HOUR * 60;
}

const hhmm = (v) => (v ? v.slice(11, 16) : ' -- ');

// -------------------------------------------------------------------- caching

const cacheFile = (key) => join(CACHE, `${key.replace(/[^a-z0-9.-]/gi, '_')}.json`);

function readCache(key) {
  try {
    return JSON.parse(readFileSync(cacheFile(key), 'utf8')).body;
  } catch {
    return undefined;
  }
}

function writeCache(key, body) {
  try {
    mkdirSync(CACHE, { recursive: true });
    writeFileSync(cacheFile(key), JSON.stringify({ body }));
  } catch {
    /* cache is an optimisation, never a requirement */
  }
}

// ------------------------------------------------------------------- transport

let bearer = null;
let spent = 0;
const requestTimes = [];

/** Free tier is 10/minute. Eight leaves headroom for anything else on the token. */
async function throttle() {
  for (;;) {
    const now = Date.now();
    while (requestTimes.length && now - requestTimes[0] > 60_000) requestTimes.shift();
    if (requestTimes.length < 8) {
      requestTimes.push(now);
      return;
    }
    const waitMs = 60_000 - (now - requestTimes[0]) + 250;
    console.log(`  (minute allowance reached; waiting ${Math.ceil(waitMs / 1000)}s)`);
    await new Promise((r) => setTimeout(r, waitMs));
  }
}

async function getBearer() {
  if (bearer) return bearer;
  if (process.env.RTT_ACCESS_TOKEN) return (bearer = process.env.RTT_ACCESS_TOKEN);
  if (!process.env.RTT_REFRESH_TOKEN) {
    throw new Error('No credentials. Put RTT_REFRESH_TOKEN=... in .env.local');
  }

  await throttle();
  spent++;
  const res = await fetch(`${BASE}/api/get_access_token`, {
    headers: {
      Authorization: `Bearer ${process.env.RTT_REFRESH_TOKEN}`,
      Version: API_VERSION,
      Accept: 'application/json',
    },
  });
  if (!res.ok) throw new Error(`Token exchange failed: HTTP ${res.status}`);
  return (bearer = (await res.json()).token);
}

let lastLimits = '';

async function rtt(path, params = {}, { cache = false } = {}) {
  const url = new URL(path, BASE);
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== null) url.searchParams.set(k, String(v));
  }

  const key = `${url.host}${url.pathname}${url.search}`;
  if (cache) {
    const hit = readCache(key);
    if (hit !== undefined) {
      console.log(`  cached  ${url.pathname}${url.search.slice(0, 80)}`);
      return hit;
    }
  }

  await throttle();
  spent++;
  const res = await fetch(url, {
    headers: {
      Authorization: `Bearer ${await getBearer()}`,
      Version: API_VERSION,
      Accept: 'application/json',
    },
  });

  lastLimits =
    ['Minute', 'Hour', 'Day', 'Week']
      .map((d) => {
        const r = res.headers.get(`X-RateLimit-Remaining-${d}`);
        const l = res.headers.get(`X-RateLimit-Limit-${d}`);
        return r ? `${d.toLowerCase()} ${r}/${l}` : null;
      })
      .filter(Boolean)
      .join(', ') || lastLimits;

  console.log(`  GET     ${url.pathname}${url.search.slice(0, 80)} -> ${res.status}`);

  if (res.status === 429) {
    throw new Error(`Rate limited; retry after ${res.headers.get('Retry-After')}s`);
  }
  const body = res.status === 204 ? null : await res.json();
  if (!res.ok && res.status !== 204) {
    throw new Error(`HTTP ${res.status}: ${JSON.stringify(body).slice(0, 300)}`);
  }
  if (cache) writeCache(key, body);
  return body;
}

// ------------------------------------------------------------------ geography

const toRad = (d) => (d * Math.PI) / 180;

function haversineMetres(a, b) {
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.sqrt(h));
}

/** Initial great-circle bearing, degrees clockwise from true north. */
function bearingDegrees(a, b) {
  const p1 = toRad(a.lat);
  const p2 = toRad(b.lat);
  const dl = toRad(b.lon - a.lon);
  const y = Math.sin(dl) * Math.cos(p2);
  const x = Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dl);
  return ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360;
}

/** IOS.md §4: four 90° sectors centred on the cardinal points. */
const compassOf = (deg) =>
  deg >= 315 || deg < 45 ? 'north' : deg < 135 ? 'east' : deg < 225 ? 'south' : 'west';

function parseCsvLine(line) {
  const out = [];
  let field = '';
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quoted) {
      if (ch === '"') {
        if (line[i + 1] === '"') {
          field += '"';
          i++;
        } else quoted = false;
      } else field += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ',') {
      out.push(field);
      field = '';
    } else field += ch;
  }
  out.push(field);
  return out;
}

/**
 * TIPLOC -> { lat, lon }, from NaPTAN.
 *
 * The DfT's, not RTT's, so it costs nothing against the rail API's allowance. TIPLOC
 * is the ATCO code with its `9100` prefix removed, which is the same join
 * `generate-stations.mjs` already makes to produce `data/geo.json` -- that file holds
 * longitude only, and a bearing needs both.
 */
async function loadNaptanCoords() {
  const cached = readCache('naptan-rail-coords');
  if (cached) {
    console.log(`  cached  NaPTAN (${Object.keys(cached).length} tiplocs)`);
    return new Map(Object.entries(cached));
  }

  console.log('  fetching NaPTAN rail access nodes (DfT, free)...');
  const res = await fetch(NAPTAN_RAIL_CSV);
  if (!res.ok) throw new Error(`NaPTAN download failed: HTTP ${res.status}`);
  const lines = (await res.text()).split(/\r?\n/).filter(Boolean);

  const header = parseCsvLine(lines[0]);
  const col = (name) => {
    const i = header.indexOf(name);
    if (i === -1) throw new Error(`NaPTAN column "${name}" missing; format changed`);
    return i;
  };
  const iAtco = col('ATCOCode');
  const iLat = col('Latitude');
  const iLon = col('Longitude');
  const iStatus = col('Status');

  const byTiploc = {};
  for (let i = 1; i < lines.length; i++) {
    const row = parseCsvLine(lines[i]);
    const atco = row[iAtco];
    if (!atco?.startsWith('9100')) continue;
    if (row[iStatus] && row[iStatus] !== 'active') continue;

    const lat = Number(row[iLat]);
    const lon = Number(row[iLon]);
    if (!Number.isFinite(lat) || !Number.isFinite(lon) || (lat === 0 && lon === 0)) continue;

    const tiploc = atco.slice(4).trim().toUpperCase();
    if (tiploc) byTiploc[tiploc] = { lat, lon };
  }

  writeCache('naptan-rail-coords', byTiploc);
  console.log(`  ${Object.keys(byTiploc).length} tiplocs with coordinates`);
  return new Map(Object.entries(byTiploc));
}

// ------------------------------------------------------------------------ main

const canonical = (s) => String(s).toLowerCase().replace(/[^a-z0-9]/g, '');

async function main() {
  loadEnvLocal();

  const args = process.argv.slice(2);
  const dateArg = args.find((a) => a.startsWith('--date='))?.slice(7);
  const names = args.filter((a) => !a.startsWith('--'));
  const stationNames = names.length ? names : DEFAULT_STATIONS;

  const date = dateArg || currentServiceDate();
  const win = serviceDayWindow(date);

  console.log('=== Reference data (cached; no quota on a re-run) ============\n');

  const stops = (await rtt('/data/stops', {}, { cache: true }))?.stops ?? [];
  const locations = (await rtt('/data/locations_ungrouped', {}, { cache: true }))?.locations ?? [];
  const naptan = await loadNaptanCoords();

  console.log(`\n  ${stops.length} stops queryable, ${locations.length} locations known`);

  // name/CRS -> coordinates, joined through TIPLOC. Destination pairs in a line-up
  // carry a description and usually no codes, so the name index does the real work.
  const coordsByName = new Map();
  const coordsByCrs = new Map();
  for (const loc of locations) {
    const point = naptan.get(String(loc.longCode ?? '').trim().toUpperCase());
    if (!point) continue;
    if (loc.description) coordsByName.set(canonical(loc.description), point);
    if (loc.shortCode) coordsByCrs.set(loc.shortCode.trim().toUpperCase(), point);
  }
  console.log(`  ${coordsByName.size} names and ${coordsByCrs.size} CRS codes have coordinates`);

  // --- resolve the probe stations, by name, never by hand-typed code ---------
  const resolve = (needle) => {
    const exact = stops.filter((s) => canonical(s.description) === canonical(needle));
    if (exact.length === 1) return exact[0];
    if (exact.length > 1) {
      throw new Error(
        `"${needle}" is ambiguous: ${exact.map((s) => `${s.description} (${s.shortCode})`).join(', ')}`
      );
    }
    const loose = stops.filter((s) => canonical(s.description).includes(canonical(needle)));
    throw new Error(
      `No stop named "${needle}". Near misses: ` +
        (loose.slice(0, 8).map((s) => `${s.description} (${s.shortCode})`).join(', ') || 'none')
    );
  };

  console.log('\n=== Probe stations ==========================================\n');
  const targets = stationNames.map((name) => {
    const stop = resolve(name);
    const point = coordsByCrs.get(stop.shortCode);
    console.log(
      `  ${stop.description.padEnd(16)} ${stop.shortCode}  ` +
        (point ? `${point.lat.toFixed(4)}, ${point.lon.toFixed(4)}` : '*** no coordinates ***')
    );
    return { stop, point };
  });

  console.log(`\n  service date : ${date}`);
  console.log(`  window       : ${win.timeFrom} .. ${win.timeTo}  (23h59m, local to station)`);

  const findings = [];

  for (const { stop, point } of targets) {
    console.log(`\n=== ${stop.description} (${stop.shortCode}) ${'='.repeat(Math.max(0, 44 - stop.description.length))}\n`);

    const lineUp = await rtt(
      '/gb-nr/location',
      { code: stop.shortCode, timeFrom: win.timeFrom, timeTo: win.timeTo },
      { cache: true }
    );

    const services = lineUp?.services ?? [];
    const finding = {
      name: stop.description,
      crs: stop.shortCode,
      services: services.length,
      boardable: 0,
      firstDep: null,
      lastDep: null,
      spanMinutes: null,
      outsideWindow: 0,
      naiveTimes: 0,
      zonedTimes: 0,
      buckets: { north: 0, east: 0, south: 0, west: 0 },
      examples: { north: new Set(), east: new Set(), south: new Set(), west: new Set() },
      tooClose: 0,
      ungeocoded: new Set(),
      queryEchoZoned: null,
    };

    // The query echo carries an offset even though service times do not. Worth
    // re-confirming nationally: it is what makes the naive times look zoned.
    const echo = lineUp?.query ?? lineUp?.request ?? null;
    if (echo) {
      const echoTime = echo.timeFrom ?? echo.from ?? null;
      if (echoTime) finding.queryEchoZoned = hasTimeZone(echoTime);
    }

    if (!services.length) {
      console.log('  204 / no services. For a request stop on the right day that is a real answer.');
      findings.push(finding);
      continue;
    }

    const rows = [];

    for (const s of services) {
      const meta = s.scheduleMetadata ?? {};
      const td = s.temporalData ?? {};
      const dep = td.departure?.scheduleAdvertised;
      if (!dep) continue;
      if (meta.inPassengerService === false) continue;
      if (td.departure?.isCancelled === true) continue;
      if (td.displayAs !== 'CALL' && td.displayAs !== 'STARTS') continue;

      finding.boardable++;
      if (hasTimeZone(dep)) finding.zonedTimes++;
      else finding.naiveTimes++;

      const mins = minutesIntoServiceDay(dep, date);
      if (mins === null || mins < 0 || mins > 23 * 60 + 59) finding.outsideWindow++;

      const destNames = (s.destination ?? [])
        .map((p) => p?.location?.description)
        .filter(Boolean);
      const destCodes = (s.destination ?? []).flatMap((p) => p?.location?.shortCodes ?? []);

      // Name first: destination pairs carry a description and usually no codes.
      let destPoint = null;
      for (const n of destNames) {
        destPoint = coordsByName.get(canonical(n));
        if (destPoint) break;
      }
      if (!destPoint) {
        for (const c of destCodes) {
          destPoint = coordsByCrs.get(c.trim().toUpperCase());
          if (destPoint) break;
        }
      }

      let dir = null;
      let deg = null;
      if (!point || !destPoint) {
        if (destNames.length) finding.ungeocoded.add(destNames.join(' & '));
      } else if (haversineMetres(point, destPoint) < MIN_BEARING_METRES) {
        finding.tooClose++;
      } else {
        deg = bearingDegrees(point, destPoint);
        dir = compassOf(deg);
        finding.buckets[dir]++;
        finding.examples[dir].add(destNames.join(' & ') || '?');
      }

      rows.push({ mins, dep, dir, deg, toc: meta.operator?.code ?? '??', dest: destNames.join(' & ') || '?' });
    }

    rows.sort((a, b) => (a.mins ?? 0) - (b.mins ?? 0));
    if (rows.length) {
      finding.firstDep = rows[0].dep;
      finding.lastDep = rows[rows.length - 1].dep;
      finding.spanMinutes = (rows[rows.length - 1].mins ?? 0) - (rows[0].mins ?? 0);
    }

    console.log(`  ${services.length} services, ${finding.boardable} boardable`);
    console.log(
      `  first ${hhmm(finding.firstDep)}, last ${hhmm(finding.lastDep)}` +
        (finding.spanMinutes !== null
          ? `  (span ${Math.floor(finding.spanMinutes / 60)}h${String(finding.spanMinutes % 60).padStart(2, '0')})`
          : '')
    );
    console.log(
      `  departure times: ${finding.naiveTimes} without a timezone, ${finding.zonedTimes} with one`
    );

    const available = Object.entries(finding.buckets).filter(([, n]) => n > 0);
    console.log(`\n  directions with services: ${available.map(([d]) => d).join(', ') || '(none)'}`);
    for (const [dir, n] of available) {
      const eg = [...finding.examples[dir]].slice(0, 3).join(', ');
      console.log(`    ${dir.padEnd(6)} ${String(n).padStart(3)}  ${eg}`);
    }
    if (finding.tooClose) {
      console.log(`    (${finding.tooClose} terminating within ${MIN_BEARING_METRES / 1000}km, no bearing taken)`);
    }
    if (finding.ungeocoded.size) {
      console.log(`    (${finding.ungeocoded.size} destinations without coordinates: ${[...finding.ungeocoded].slice(0, 4).join(', ')})`);
    }

    // The last three of the day and the first, which is what the app would show.
    console.log('\n  what the app would show:');
    for (const r of rows.slice(-3)) {
      console.log(`    last   ${hhmm(r.dep)}  ${(r.dir ?? '?').padEnd(6)} ${r.toc}  ${r.dest}`);
    }
    if (rows.length) {
      const f = rows[0];
      console.log(`    first  ${hhmm(f.dep)}  ${(f.dir ?? '?').padEnd(6)} ${f.toc}  ${f.dest}`);
    }

    findings.push(finding);
  }

  // ------------------------------------------------------------------ verdict
  console.log('\n=== Verdict =================================================\n');

  let pass = true;
  const fail = (msg) => {
    pass = false;
    console.log(`  FAIL  ${msg}`);
  };
  const ok = (msg) => console.log(`  ok    ${msg}`);

  const withServices = findings.filter((f) => f.boardable > 0);

  if (!withServices.length) {
    fail('no station returned any boardable service; nothing was proved');
  } else {
    const outside = withServices.filter((f) => f.outsideWindow > 0);
    if (outside.length) {
      fail(`departures outside the 03:00-02:59 window at ${outside.map((f) => f.crs).join(', ')}`);
    } else {
      ok('every departure fell inside the 23h59m service-day window');
    }

    const zoned = withServices.filter((f) => f.zonedTimes > 0);
    if (zoned.length) {
      fail(`departure times carried a timezone at ${zoned.map((f) => f.crs).join(', ')} -- the parsing assumption differs nationally`);
    } else {
      ok('departure times are timezone-less everywhere, as in the south-east');
    }

    const wide = withServices.filter((f) => f.spanMinutes > 15 * 60);
    ok(`${wide.length} of ${withServices.length} stations returned a span over 15h (a whole day, not a window)`);

    const upm = findings.find((f) => f.name === 'Upminster');
    if (upm && upm.boardable) {
      const ns = upm.buckets.north + upm.buckets.south;
      if (ns > 0) {
        fail(`Upminster bucketed ${ns} services north/south; PRODUCT.md says it has none`);
      } else {
        ok('Upminster offers east and west only, as the known-good case requires');
      }
    }

    const uncovered = withServices.filter((f) => f.ungeocoded.size > 0);
    if (uncovered.length) {
      console.log(
        `  note  ${uncovered.length} station(s) had destinations without coordinates; ` +
          'those services cannot be bucketed and would be dropped or shown undirected'
      );
    }
  }

  console.log(`\n  API requests spent: ${spent}${lastLimits ? `  [remaining: ${lastLimits}]` : ''}`);
  console.log(`\n  ${pass ? 'Step 2 passes.' : 'Step 2 has NOT passed. Do not build §4 on this yet.'}`);
  if (!pass) process.exitCode = 1;
}

main().catch((err) => {
  console.error(`\nFAILED: ${err.message}`);
  process.exitCode = 1;
});
