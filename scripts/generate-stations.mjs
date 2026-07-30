#!/usr/bin/env node
/**
 * Build step 3: generate data/stations.json.
 *
 * The spec is blunt about this: "Verify every CRS code programmatically. Do not
 * hand-type them. A transposed three-letter code is the single likeliest bug in
 * this build." So nothing here contains a CRS code. Codes come from the API.
 *
 * How it works:
 *
 *   1. Six probe corridors are named in prose ("London Fenchurch Street" ->
 *      "Shoeburyness"). Those names are resolved to codes against /data/stops.
 *   2. For each corridor, several real services spread across the day are
 *      fetched, and their calling points *between the two endpoints* are
 *      unioned. Sampling several catches stations the fast services skip.
 *      Bounding to the segment is what keeps Norwich and Ipswich out: the
 *      Greater Anglia trains through Shenfield carry on far past our scope.
 *   3. Coordinates come from NaPTAN, joined on TIPLOC, which is the API's
 *      `longCode`. Where NaPTAN has only an OS grid reference -- as it does for
 *      the Elizabeth line central core -- it is converted to WGS84, and the
 *      converter is checked against the thousands of rows that carry both.
 *   4. Route markers ("via Tilbury") are resolved by name against the harvested
 *      set, so a marker naming a station we never found is a hard failure.
 *
 * Run:  node scripts/generate-stations.mjs
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const BASE = 'https://data.rtt.io';
const API_VERSION = process.env.RTT_API_VERSION || '2026-04-09';

const NAPTAN_RAIL_CSV =
  'https://naptan.api.dft.gov.uk/v1/access-nodes?dataFormat=csv&atcoAreaCodes=910';

/**
 * The corridors the app covers, exactly as scoped: the whole of c2c, the whole
 * of the Elizabeth line, and Liverpool Street <-> Shenfield for Greater Anglia.
 *
 * Named in prose on purpose. Resolving these to codes is step one of the run.
 */
/**
 * Each probe pins one route.
 *
 * `via` is the crucial part. Querying Fenchurch Street -> Shoeburyness and sampling
 * whatever comes back catches only the Basildon main line, because the Tilbury loop
 * services to Shoeburyness are the minority -- a first run harvested 64 stations and
 * silently missed the entire loop east of Grays. Filtering on a waypoint forces the
 * route, so coverage no longer depends on which services a sample happens to land on.
 *
 * `bound` decides how much of each sampled service's calling pattern to keep:
 *   - `end`  : everything from the boarding station onwards. Safe where the whole
 *              route is in scope, which is all of c2c and all of the Elizabeth line.
 *   - `to`   : stop at the named station. Needed for Greater Anglia, whose trains
 *              run far past Shenfield to Colchester, Ipswich and Norwich.
 */
const PROBES = [
  // c2c, all three routes out of Fenchurch Street.
  {
    from: 'London Fenchurch Street',
    via: 'Tilbury Town',
    to: 'Shoeburyness',
    bound: 'end',
    note: 'c2c Tilbury loop',
  },
  {
    from: 'London Fenchurch Street',
    via: 'Basildon',
    to: 'Shoeburyness',
    bound: 'end',
    note: 'c2c Basildon main line',
  },
  {
    from: 'London Fenchurch Street',
    via: 'Ockendon',
    to: 'Grays',
    bound: 'end',
    note: 'c2c Ockendon branch',
  },
  // The Rainham and Purfleet stoppers mostly terminate at Grays and never go near
  // Tilbury, so the loop probe above structurally cannot reach them -- a first run
  // missed Dagenham Dock, Rainham and Purfleet entirely because of it.
  {
    from: 'London Fenchurch Street',
    via: 'Rainham (London)',
    to: 'Grays',
    bound: 'end',
    note: 'c2c Rainham/Purfleet stoppers',
  },
  // Stanford-le-Hope sits between East Tilbury and Pitsea; the fast loop services
  // sampled above skipped it.
  {
    from: 'London Fenchurch Street',
    via: 'Stanford-le-Hope',
    to: 'Shoeburyness',
    bound: 'end',
    note: 'c2c loop, all-stations east of Tilbury',
  },

  // Elizabeth line, all four branches. Named exactly as the API names them:
  // "Heathrow Airport Terminal 5", not "Heathrow Terminal 5". Terminals 2 & 3 are
  // "Heathrow Central", picked up en route rather than probed for.
  { from: 'Reading', to: 'Abbey Wood', bound: 'end', note: 'Elizabeth line west + core + SE' },
  {
    from: 'London Paddington',
    to: 'Heathrow Airport Terminal 5',
    bound: 'end',
    note: 'Elizabeth line Heathrow T5',
  },
  {
    from: 'London Paddington',
    to: 'Heathrow Airport Terminal 4',
    bound: 'end',
    note: 'Elizabeth line Heathrow T4',
  },
  { from: 'Shenfield', to: 'London Paddington', bound: 'end', note: 'Elizabeth line Shenfield branch' },

  // Greater Anglia, bounded so Colchester and Norwich stay out.
  {
    from: 'London Liverpool Street',
    to: 'Shenfield',
    bound: 'to',
    note: 'Greater Anglia GEML corridor',
  },
];

/**
 * Only these operators are harvested: Greater Anglia, c2c and the Elizabeth line.
 *
 * Without this, the Paddington probes sample Heathrow Express (HX), which shares the
 * track but is not part of this app, and Farringdon would pull in Thameslink.
 */
const OPERATORS_IN_SCOPE = new Set(['LE', 'CC', 'XR']);

/**
 * Ordered most-distinctive first: a Tilbury loop service also passes Rainham,
 * so Tilbury must win. Resolved against the harvested stations, never typed.
 */
const ROUTE_MARKERS = [
  { station: 'Tilbury Town', label: 'via Tilbury' },
  { station: 'Ockendon', label: 'via Ockendon' },
  // "Rainham" alone is ambiguous: there is also Rainham (Kent), on Southeastern.
  { station: 'Rainham (London)', label: 'via Rainham' },
  { station: 'Basildon', label: 'via Basildon' },
];

/**
 * Services sampled per route, spread across the service day.
 *
 * Four is enough now that `via` pins each route: the samples differ only in stopping
 * pattern, and off-peak services call everywhere, so their union covers the route.
 * It also keeps a full run to roughly 45 requests against a limit of 100 an hour,
 * leaving room to retry.
 */
const SAMPLES_PER_PROBE = 4;

// -------------------------------------------------------------- env + service day

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
    /* rely on the real environment */
  }
}

const isoDate = (ms) => new Date(ms).toISOString().slice(0, 10);
const addDays = (date, n) => {
  const [y, m, d] = date.split('-').map(Number);
  return isoDate(Date.UTC(y, m - 1, d) + n * 86_400_000);
};

function londonHourAndDate(now) {
  const f = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    hourCycle: 'h23',
  });
  const p = {};
  for (const part of f.formatToParts(now)) if (part.type !== 'literal') p[part.type] = part.value;
  return p;
}

/**
 * A weekday is sampled deliberately: Sunday timetables miss stations entirely,
 * and a station absent from the list cannot be searched for.
 */
function nextWeekday(from) {
  let date = from;
  for (let i = 0; i < 8; i++) {
    const day = new Date(`${date}T12:00:00Z`).getUTCDay();
    if (day !== 0 && day !== 6) return date;
    date = addDays(date, 1);
  }
  return date;
}

// ----------------------------------------------------------------- rate limiting

/**
 * The free personal tier allows 10 requests a minute and 100 an hour. Both are
 * tracked, with a little headroom, so a long run paces itself rather than tripping a
 * 429 halfway through and losing the work.
 *
 * Note these are a third of the limits quoted in the project spec; the portal is the
 * authority. At 8 a minute a full generation run takes roughly seven minutes.
 */
const MAX_PER_MINUTE = 8;
const MAX_PER_HOUR = 90;

const requestTimes = [];

/**
 * The allowance is shared with anything else using the token -- a spike run, a dev
 * server -- so starting from a clean slate is an assumption, not a fact. The first
 * response's remaining-hour header is used to seed the pacing with whatever has
 * already been spent, which turns an abrupt 429 into orderly waiting.
 */
let hourBudgetSynced = false;

function syncHourBudget(res) {
  if (hourBudgetSynced) return;
  const remaining = Number(res.headers.get('X-RateLimit-Remaining-Hour'));
  const limit = Number(res.headers.get('X-RateLimit-Limit-Hour'));
  if (!Number.isFinite(remaining) || !Number.isFinite(limit)) return;

  hourBudgetSynced = true;
  const alreadySpent = Math.max(limit - remaining - 1, 0);
  if (alreadySpent === 0) return;

  console.log(
    `  (${alreadySpent} of ${limit} hourly requests already spent before this run; pacing for it)`
  );
  // Counted as if spent now, which is conservative: they will actually age out
  // sooner than this assumes.
  for (let i = 0; i < alreadySpent; i++) requestTimes.push(Date.now());
}

async function throttle() {
  for (;;) {
    const now = Date.now();
    while (requestTimes.length && now - requestTimes[0] > 3_600_000) requestTimes.shift();

    const inLastMinute = requestTimes.filter((t) => now - t <= 60_000).length;
    const inLastHour = requestTimes.length;

    if (inLastMinute < MAX_PER_MINUTE && inLastHour < MAX_PER_HOUR) {
      requestTimes.push(now);
      return;
    }

    const waitMs =
      inLastMinute >= MAX_PER_MINUTE
        ? 60_000 - (now - requestTimes.filter((t) => now - t <= 60_000)[0]) + 250
        : 3_600_000 - (now - requestTimes[0]) + 250;

    const reason = inLastMinute >= MAX_PER_MINUTE ? 'per-minute' : 'hourly';
    // Newline, not a carriage return: overwriting the line ate the per-probe
    // coverage summaries, which are the most useful output the script produces.
    console.log(`  (${reason} rate limit: pausing ${Math.ceil(waitMs / 1000)}s)`);
    await new Promise((resolve) => setTimeout(resolve, waitMs));
  }
}

// -------------------------------------------------------------------- transport

let bearer = null;

/**
 * When the cached access token stops being usable.
 *
 * An access token exchanged from a refresh token lives about an hour, and a full run
 * can easily take longer than that once it starts waiting out the hourly rate limit.
 * Caching the token for the life of the process therefore fails with a 401 partway
 * through -- which is exactly what happened on the first long run.
 */
let bearerExpiresAtMillis = 0;

async function getBearer() {
  if (process.env.RTT_ACCESS_TOKEN) return process.env.RTT_ACCESS_TOKEN.trim();
  if (bearer && Date.now() < bearerExpiresAtMillis) return bearer;
  if (!process.env.RTT_REFRESH_TOKEN) {
    throw new Error('No credentials. Set RTT_ACCESS_TOKEN or RTT_REFRESH_TOKEN in .env.local');
  }
  const res = await fetch(`${BASE}/api/get_access_token`, {
    headers: {
      Authorization: `Bearer ${process.env.RTT_REFRESH_TOKEN.trim()}`,
      Version: API_VERSION,
      Accept: 'application/json',
    },
  });
  if (!res.ok) throw new Error(`Token exchange failed: HTTP ${res.status}`);

  const body = await res.json();
  const validUntil = Date.parse(body.validUntil);
  // 60s of slack so a request cannot go out with a token that expires in flight.
  bearerExpiresAtMillis = Number.isNaN(validUntil) ? Date.now() + 300_000 : validUntil - 60_000;
  bearer = body.token;
  return bearer;
}

/**
 * On-disk response cache, gitignored.
 *
 * The free tier allows 100 requests an hour and a full run is around 55, so without
 * this, iterating on the probe list means waiting out the rolling window between
 * attempts. Responses are keyed by full URL, and the sampled service date is part of
 * that URL, so a cached entry can never be mistaken for a different day.
 *
 * Delete `.rtt-cache/` to force a clean run.
 */
const CACHE_DIR = join(ROOT, '.rtt-cache');

const cachePathFor = (url) =>
  join(CACHE_DIR, `${url.toString().replace(/^https:\/\//, '').replace(/[^A-Za-z0-9._-]/g, '_')}.json`);

function readCache(url) {
  try {
    return JSON.parse(readFileSync(cachePathFor(url), 'utf8'));
  } catch {
    return undefined;
  }
}

function writeCache(url, body) {
  try {
    mkdirSync(CACHE_DIR, { recursive: true });
    writeFileSync(cachePathFor(url), JSON.stringify(body));
  } catch {
    /* caching is an optimisation; a failure to write must not fail the run */
  }
}

let cacheHits = 0;
let apiCalls = 0;

async function rtt(path, params = {}) {
  const url = new URL(path, BASE);
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== null) url.searchParams.set(k, String(v));
  }

  const cached = readCache(url);
  if (cached !== undefined) {
    cacheHits++;
    return cached.body;
  }

  for (let attempt = 0; attempt < 4; attempt++) {
    await throttle();
    const res = await fetch(url, {
      headers: {
        Authorization: `Bearer ${await getBearer()}`,
        Version: API_VERSION,
        Accept: 'application/json',
      },
    });

    apiCalls++;
    syncHourBudget(res);

    if (res.status === 204) {
      writeCache(url, { body: null });
      return null;
    }
    if (res.status === 429) {
      const wait = (Number(res.headers.get('Retry-After')) || 30) + 1;
      console.log(`\n  429; waiting ${wait}s`);
      await new Promise((r) => setTimeout(r, wait * 1000));
      continue;
    }
    if (res.status === 401) {
      // The access token has expired or been rotated. Drop it and let the next
      // attempt exchange a fresh one.
      console.log('\n  401; refreshing access token');
      bearer = null;
      bearerExpiresAtMillis = 0;
      continue;
    }
    if (!res.ok) throw new Error(`GET ${url.pathname} -> HTTP ${res.status}`);

    const body = await res.json();
    writeCache(url, { body });
    return body;
  }
  throw new Error(`GET ${url.pathname} -> gave up after repeated rate limiting`);
}

// ------------------------------------------------- OSGB36 grid ref -> WGS84

/**
 * Inverse transverse Mercator on the Airy 1830 ellipsoid, then a Helmert
 * transform onto WGS84. Accurate to a few metres, which is ample for deciding
 * which platform you are standing on.
 */
function gridToOsgb36LatLon(easting, northing) {
  const a = 6377563.396;
  const b = 6356256.909;
  const f0 = 0.9996012717;
  const lat0 = (49 * Math.PI) / 180;
  const lon0 = (-2 * Math.PI) / 180;
  const n0 = -100_000;
  const e0 = 400_000;

  const e2 = 1 - (b * b) / (a * a);
  const n = (a - b) / (a + b);
  const n2 = n * n;
  const n3 = n2 * n;

  let lat = lat0;
  let m = 0;
  do {
    lat = (northing - n0 - m) / (a * f0) + lat;
    const ma = (1 + n + 1.25 * n2 + 1.25 * n3) * (lat - lat0);
    const mb = (3 * n + 3 * n2 + 2.625 * n3) * Math.sin(lat - lat0) * Math.cos(lat + lat0);
    const mc = (1.875 * n2 + 1.875 * n3) * Math.sin(2 * (lat - lat0)) * Math.cos(2 * (lat + lat0));
    const md = (35 / 24) * n3 * Math.sin(3 * (lat - lat0)) * Math.cos(3 * (lat + lat0));
    m = b * f0 * (ma - mb + mc - md);
  } while (Math.abs(northing - n0 - m) >= 0.00001);

  const sinLat = Math.sin(lat);
  const cosLat = Math.cos(lat);
  const nu = (a * f0) / Math.sqrt(1 - e2 * sinLat * sinLat);
  const rho = (a * f0 * (1 - e2)) / Math.pow(1 - e2 * sinLat * sinLat, 1.5);
  const eta2 = nu / rho - 1;

  const tanLat = Math.tan(lat);
  const t2 = tanLat * tanLat;
  const t4 = t2 * t2;
  const t6 = t4 * t2;
  const sec = 1 / cosLat;
  const nu3 = nu ** 3;
  const nu5 = nu ** 5;
  const nu7 = nu ** 7;

  const vii = tanLat / (2 * rho * nu);
  const viii = (tanLat / (24 * rho * nu3)) * (5 + 3 * t2 + eta2 - 9 * t2 * eta2);
  const ix = (tanLat / (720 * rho * nu5)) * (61 + 90 * t2 + 45 * t4);
  const x = sec / nu;
  const xi = (sec / (6 * nu3)) * (nu / rho + 2 * t2);
  const xii = (sec / (120 * nu5)) * (5 + 28 * t2 + 24 * t4);
  const xiia = (sec / (5040 * nu7)) * (61 + 662 * t2 + 1320 * t4 + 720 * t6);

  const d = easting - e0;
  return {
    lat: lat - vii * d ** 2 + viii * d ** 4 - ix * d ** 6,
    lon: lon0 + x * d - xi * d ** 3 + xii * d ** 5 - xiia * d ** 7,
  };
}

/** Helmert, OSGB36 -> WGS84 (the inverse of the published WGS84 -> OSGB36 set). */
function osgb36ToWgs84(latRad, lonRad) {
  const a1 = 6377563.396;
  const b1 = 6356256.909;
  const e1 = 1 - (b1 * b1) / (a1 * a1);
  const sinLat = Math.sin(latRad);
  const cosLat = Math.cos(latRad);
  const nu1 = a1 / Math.sqrt(1 - e1 * sinLat * sinLat);

  const x1 = nu1 * cosLat * Math.cos(lonRad);
  const y1 = nu1 * cosLat * Math.sin(lonRad);
  const z1 = (1 - e1) * nu1 * sinLat;

  const tx = 446.448;
  const ty = -125.157;
  const tz = 542.06;
  const s = -20.4894e-6;
  const arcsec = Math.PI / 180 / 3600;
  const rx = 0.1502 * arcsec;
  const ry = 0.247 * arcsec;
  const rz = 0.8421 * arcsec;

  const x2 = tx + x1 * (1 + s) - y1 * rz + z1 * ry;
  const y2 = ty + x1 * rz + y1 * (1 + s) - z1 * rx;
  const z2 = tz - x1 * ry + y1 * rx + z1 * (1 + s);

  const a2 = 6378137.0;
  const b2 = 6356752.3142;
  const e22 = 1 - (b2 * b2) / (a2 * a2);
  const p = Math.hypot(x2, y2);

  let lat = Math.atan2(z2, p * (1 - e22));
  for (let i = 0; i < 12; i++) {
    const nu2 = a2 / Math.sqrt(1 - e22 * Math.sin(lat) ** 2);
    const next = Math.atan2(z2 + e22 * nu2 * Math.sin(lat), p);
    if (Math.abs(next - lat) < 1e-13) {
      lat = next;
      break;
    }
    lat = next;
  }

  return { lat: (lat * 180) / Math.PI, lon: (Math.atan2(y2, x2) * 180) / Math.PI };
}

function gridToWgs84(easting, northing) {
  const osgb = gridToOsgb36LatLon(Number(easting), Number(northing));
  return osgb36ToWgs84(osgb.lat, osgb.lon);
}

// ------------------------------------------------------------------ NaPTAN load

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

const haversineMetres = (a, b) => {
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.sqrt(h));
};

async function loadNaptan() {
  console.log('  fetching NaPTAN rail access nodes...');
  const res = await fetch(NAPTAN_RAIL_CSV);
  if (!res.ok) throw new Error(`NaPTAN download failed: HTTP ${res.status}`);
  const text = await res.text();

  const lines = text.split(/\r?\n/).filter(Boolean);
  const header = parseCsvLine(lines[0]);
  const col = (name) => {
    const index = header.indexOf(name);
    if (index === -1) throw new Error(`NaPTAN column "${name}" missing; format changed`);
    return index;
  };
  const iAtco = col('ATCOCode');
  const iName = col('CommonName');
  const iEast = col('Easting');
  const iNorth = col('Northing');
  const iLon = col('Longitude');
  const iLat = col('Latitude');
  const iStatus = col('Status');

  /** TIPLOC -> { name, lat, lon, source } */
  const byTiploc = new Map();
  const checks = [];

  for (let i = 1; i < lines.length; i++) {
    const row = parseCsvLine(lines[i]);
    const atco = row[iAtco];
    if (!atco?.startsWith('9100')) continue;
    if (row[iStatus] && row[iStatus] !== 'active') continue;

    const tiploc = atco.slice(4).trim().toUpperCase();
    if (!tiploc) continue;

    const lat = Number(row[iLat]);
    const lon = Number(row[iLon]);
    const east = Number(row[iEast]);
    const north = Number(row[iNorth]);

    const hasLatLon = Number.isFinite(lat) && Number.isFinite(lon) && lat !== 0 && lon !== 0 && row[iLat] !== '';
    const hasGrid = Number.isFinite(east) && Number.isFinite(north) && east > 0 && north > 0;

    if (hasLatLon && hasGrid) {
      // Free self-test for the converter, on real data.
      checks.push({ expected: { lat, lon }, got: gridToWgs84(east, north) });
    }

    let coords = null;
    let source = null;
    if (hasLatLon) {
      coords = { lat, lon };
      source = 'naptan';
    } else if (hasGrid) {
      // The Elizabeth line central core stations land here.
      coords = gridToWgs84(east, north);
      source = 'naptan-grid';
    }
    if (!coords) continue;

    byTiploc.set(tiploc, {
      name: row[iName]?.replace(/\s+Rail Station$/i, '').trim(),
      lat: Number(coords.lat.toFixed(6)),
      lon: Number(coords.lon.toFixed(6)),
      source,
    });
  }


  // Validate the grid conversion before trusting it for anything.
  const errors = checks.map((c) => haversineMetres(c.expected, c.got)).sort((a, b) => a - b);
  const median = errors[Math.floor(errors.length / 2)];
  const p99 = errors[Math.floor(errors.length * 0.99)];
  console.log(
    `  ${byTiploc.size} TIPLOCs with coordinates ` +
      `(grid converter checked on ${checks.length} rows: median ${median.toFixed(1)}m, p99 ${p99.toFixed(1)}m)`
  );
  if (median > 15) {
    throw new Error(
      `OSGB->WGS84 conversion is wrong (median error ${median.toFixed(1)}m). Refusing to emit coordinates.`
    );
  }

  return byTiploc;
}

// -------------------------------------------------------------------- resolving

function makeResolver(stops) {
  const norm = (s) => s.toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();

  return function resolve(name) {
    const target = norm(name);

    const exact = stops.filter((s) => norm(s.description ?? '') === target);
    if (exact.length === 1) return exact[0];
    if (exact.length > 1) {
      // Same name, several codes: prefer the one that looks like a CRS.
      const crsish = exact.filter((s) => /^[A-Z]{3}$/.test(s.shortCode ?? ''));
      if (crsish.length === 1) return crsish[0];
    }

    const partial = stops.filter((s) => norm(s.description ?? '').includes(target));
    if (partial.length === 1) return partial[0];

    throw new Error(
      `Cannot resolve "${name}" to a single stop. ` +
        `Candidates: ${(exact.length ? exact : partial)
          .slice(0, 12)
          .map((s) => `${s.description} [${s.shortCode}]`)
          .join(', ') || '(none)'}`
    );
  };
}

// ------------------------------------------------------------------------- main

const ADVERTISED = new Set(['ADVERTISED_OPEN', 'ADVERTISED_SET_DOWN', 'ADVERTISED_PICK_UP']);
const STOPS_HERE = new Set(['CALL', 'STARTS', 'TERMINATES']);

/**
 * A service query returns public calling points only, and its locations carry no
 * `displayAs` -- a location line-up does, but this endpoint does not. So `displayAs`
 * is a veto when present rather than a requirement; the call type does the work.
 * Requiring it would harvest nothing at all.
 */
function isPassengerCall(temporal = {}) {
  if (temporal.displayAs && !STOPS_HERE.has(temporal.displayAs)) return false;
  const callType = temporal.scheduledCallType ?? temporal.realtimeCallType;
  return ADVERTISED.has(callType);
}

/** The namespaced endpoint wants the identity without its `gb-nr:` prefix. */
const stripNamespace = (uniqueIdentity) => uniqueIdentity.replace(/^gb-nr:/, '');

async function main() {
  loadEnvLocal();

  console.log('=== Station data generation ==================================\n');

  const info = await rtt('/api/info');
  console.log(`  API version served: ${info.api_version} (asked for ${API_VERSION})`);

  const naptan = await loadNaptan();

  console.log('\n--- resolving probe endpoints --------------------------------\n');
  const stops = (await rtt('/data/stops'))?.stops ?? [];
  if (!stops.length) throw new Error('/data/stops returned nothing; check entitlements');
  console.log(`  ${stops.length} stops available\n`);
  const resolve = makeResolver(stops);

  const probes = PROBES.map((probe) => {
    const from = resolve(probe.from);
    const to = resolve(probe.to);
    const via = probe.via ? resolve(probe.via) : null;
    console.log(
      `  ${probe.from} [${from.shortCode}] -> ` +
        (via ? `via ${probe.via} [${via.shortCode}] -> ` : '') +
        `${probe.to} [${to.shortCode}]   ${probe.note}`
    );
    return {
      ...probe,
      fromCode: from.shortCode,
      toCode: to.shortCode,
      viaCode: via?.shortCode ?? null,
    };
  });

  // CRS <-> TIPLOC, so coordinates can be attached.
  const locations = (await rtt('/data/locations_ungrouped'))?.locations ?? [];
  const tiplocsByCrs = new Map();
  for (const loc of locations) {
    if (!loc.shortCode || !loc.longCode) continue;
    const list = tiplocsByCrs.get(loc.shortCode) ?? [];
    list.push(loc.longCode.trim().toUpperCase());
    tiplocsByCrs.set(loc.shortCode, list);
  }
  console.log(`  ${locations.length} ungrouped locations, ${tiplocsByCrs.size} distinct short codes`);

  console.log('\n--- harvesting calling patterns ------------------------------\n');
  const date = nextWeekday(addDays(isoDate(Date.now()), 1));
  console.log(`  sampling service date ${date} (a weekday: Sunday patterns omit stations)\n`);

  const window = { timeFrom: `${date}T03:00:00`, timeTo: `${addDays(date, 1)}T02:59:00` };

  /** CRS -> { crs, names:Set, operators:Set } */
  const harvested = new Map();

  /**
   * Destination names of trains that demonstrably run through a corridor.
   *
   * Every probe line-up is filtered to a waypoint inside the app's scope, so every
   * service in one calls somewhere in scope by construction -- which makes their
   * destinations exactly the set of "bound somewhere reachable along a corridor".
   * For the Greater Anglia probe that is Colchester, Ipswich, Norwich, Clacton,
   * Southend Victoria and friends: destinations outside the station list, but reached
   * by trains that call at Shenfield.
   *
   * This is what lets the route handler reject a Stansted or Cambridge service
   * without spending a request on its calling pattern, which matters a great deal
   * when the whole minute's allowance is ten requests. Free to collect: the line-ups
   * are already being fetched.
   */
  const corridorDestinations = new Set();

  /**
   * Ordered in-scope calling points of every sampled service.
   *
   * Used after coordinates are attached to work out, for each station, whether the
   * corridor actually continues east and/or west of it. Shenfield is the case that
   * needs this: Colchester is a legitimate corridor destination, but from Shenfield
   * itself the corridor is behind you, so eastbound there is genuinely nothing in
   * scope -- and the right answer is an empty one, not a list of Norwich trains.
   */
  const sampledOrders = [];

  const record = (loc, tocCode) => {
    const crs = (loc.location?.shortCodes ?? []).find((c) => /^[A-Z]{3}$/.test(c));
    if (!crs) return;
    const entry = harvested.get(crs) ?? { crs, names: new Set(), operators: new Set(), tiplocs: new Set() };
    if (loc.location?.description) entry.names.add(loc.location.description);
    for (const long of loc.location?.longCodes ?? []) entry.tiplocs.add(long.trim().toUpperCase());
    if (tocCode) entry.operators.add(tocCode);
    harvested.set(crs, entry);
  };

  for (const probe of probes) {
    // Filter on the waypoint where there is one: that is what pins the route.
    const lineUp = await rtt('/gb-nr/location', {
      code: probe.fromCode,
      filterTo: probe.viaCode ?? probe.toCode,
      ...window,
    });

    const candidates = (lineUp?.services ?? []).filter(
      (s) =>
        s.scheduleMetadata?.uniqueIdentity &&
        s.scheduleMetadata?.inPassengerService !== false &&
        OPERATORS_IN_SCOPE.has(s.scheduleMetadata?.operator?.code)
    );

    if (!candidates.length) {
      console.log(`  ${probe.fromCode} -> ${probe.toCode}: NO SERVICES -- cannot harvest this corridor`);
      continue;
    }

    for (const candidate of candidates) {
      for (const pair of candidate.destination ?? []) {
        if (pair.location?.description) corridorDestinations.add(pair.location.description);
      }
    }

    // Spread the sample across the whole day: peak fast services and off-peak
    // all-stations services call at different sets of stations.
    const step = Math.max(1, Math.floor(candidates.length / SAMPLES_PER_PROBE));
    const sample = [];
    for (let i = 0; i < candidates.length && sample.length < SAMPLES_PER_PROBE; i += step) {
      sample.push(candidates[i]);
    }
    const lastCandidate = candidates[candidates.length - 1];
    if (!sample.includes(lastCandidate)) sample.push(lastCandidate);

    let added = 0;
    for (const candidate of sample) {
      const detail = await rtt('/gb-nr/service', {
        uniqueIdentity: stripNamespace(candidate.scheduleMetadata.uniqueIdentity),
      });
      const locs = detail?.service?.locations ?? [];
      const toc = detail?.service?.scheduleMetadata?.operator?.code;
      if (!OPERATORS_IN_SCOPE.has(toc)) continue;

      const indexOf = (code) =>
        locs.findIndex(
          (l) =>
            l.location?.shortCodes?.includes(code) || l.location?.longCodes?.includes(code)
        );
      const start = indexOf(probe.fromCode);
      if (start === -1) continue;

      // `end` keeps everything onward, which is safe where the whole route is in
      // scope. `to` stops at the named station, which is what keeps Ipswich and
      // Norwich out of a Liverpool Street -> Shenfield harvest.
      let end;
      if (probe.bound === 'end') {
        end = locs.length - 1;
      } else {
        end = indexOf(probe.toCode);
        if (end === -1) continue;
      }

      const [lo, hi] = start <= end ? [start, end] : [end, start];
      const order = [];
      for (let i = lo; i <= hi; i++) {
        const loc = locs[i];
        if (!isPassengerCall(loc.temporalData)) continue;
        const before = harvested.size;
        record(loc, toc);
        if (harvested.size > before) added++;

        const crs = (loc.location?.shortCodes ?? []).find((c) => /^[A-Z]{3}$/.test(c));
        if (crs) order.push(crs);
      }
      // Reversed if this service runs the probe backwards, so the array is always in
      // order of travel.
      if (order.length > 1) sampledOrders.push(start <= end ? order : [...order].reverse());
    }

    console.log(
      `  ${probe.fromCode} -> ${probe.toCode}: ${candidates.length} services, ` +
        `sampled ${sample.length}, +${added} new stations (running total ${harvested.size})`
    );
  }

  console.log('\n--- attaching coordinates -----------------------------------\n');

  const stations = [];
  const missing = [];

  for (const entry of harvested.values()) {
    const tiplocCandidates = [...entry.tiplocs, ...(tiplocsByCrs.get(entry.crs) ?? [])];
    let coords = null;
    let tiploc = tiplocCandidates[0] ?? '';

    for (const candidate of tiplocCandidates) {
      const hit = naptan.get(candidate);
      if (hit) {
        coords = hit;
        tiploc = candidate;
        break;
      }
    }

    // Shortest name is the cleanest: "Farringdon" over "Farringdon (Elizabeth line)".
    const name = [...entry.names].sort((a, b) => a.length - b.length)[0] ?? coords?.name ?? entry.crs;

    if (!coords) {
      missing.push({ crs: entry.crs, name, tried: tiplocCandidates });
      continue;
    }

    stations.push({
      crs: entry.crs,
      name,
      tiploc,
      lat: coords.lat,
      lon: coords.lon,
      operators: [...entry.operators].sort(),
      coordSource: coords.source,
    });
  }

  stations.sort((a, b) => a.name.localeCompare(b.name));

  // ---- does the corridor continue past each station? ------------------------
  //
  // Derived from the sampled calling patterns rather than assumed: for every station,
  // whether any in-scope station further east (or west) is reachable onward from it.
  // Where the answer is no, that direction has no in-scope services at all and the
  // route handler can answer "nothing that way" without calling the API.
  const lonOf = new Map(stations.map((s) => [s.crs, s.lon]));
  const onward = new Map(stations.map((s) => [s.crs, new Set()]));

  // Each sampled pattern is evidence for both directions, because track runs both
  // ways: if Pitsea is reachable east of Grays, then Grays is reachable west of
  // Pitsea. Reading only the direction the sample happened to travel made every
  // station look like a one-way dead end, since every probe runs outbound from London.
  for (const order of sampledOrders) {
    for (let i = 0; i < order.length; i++) {
      for (let j = i + 1; j < order.length; j++) {
        const here = lonOf.get(order[i]);
        const there = lonOf.get(order[j]);
        if (here === undefined || there === undefined || here === there) continue;

        const forward = there > here ? 'east' : 'west';
        const backward = forward === 'east' ? 'west' : 'east';
        onward.get(order[i])?.add(forward);
        onward.get(order[j])?.add(backward);
      }
    }
  }

  for (const station of stations) {
    station.onward = [...(onward.get(station.crs) ?? [])].sort();
  }

  const deadEnds = stations.filter((s) => s.onward.length < 2);
  console.log(
    `  ${deadEnds.length} station(s) where the corridor does not continue both ways:` +
      `\n    ${deadEnds.map((s) => `${s.crs}(${s.onward.join('+') || 'none'})`).join(' ')}`
  );

  if (missing.length) {
    console.log(`  ${missing.length} station(s) with no coordinates:`);
    for (const m of missing) {
      console.log(`    ${m.crs} ${m.name} (tried TIPLOCs: ${m.tried.join(', ') || 'none'})`);
    }
    throw new Error(
      'Every station needs coordinates for the nearest-station button. Refusing to emit a partial list.'
    );
  }

  const fromGrid = stations.filter((s) => s.coordSource === 'naptan-grid');
  console.log(`  ${stations.length} stations, all with coordinates`);
  console.log(`  ${fromGrid.length} converted from OS grid: ${fromGrid.map((s) => s.crs).join(', ')}`);

  // ---- validation ----------------------------------------------------------

  console.log('\n--- validating ----------------------------------------------\n');
  const problems = [];

  for (const station of stations) {
    if (!/^[A-Z]{3}$/.test(station.crs)) problems.push(`${station.crs}: not a 3-letter CRS code`);
    if (!station.name) problems.push(`${station.crs}: no name`);
    // Everything in scope sits inside a generous box around London and the Thames
    // estuary, out to Reading. A transposed code would land outside it.
    if (station.lat < 51.0 || station.lat > 52.1) problems.push(`${station.crs}: latitude ${station.lat} outside expected area`);
    if (station.lon < -1.3 || station.lon > 1.1) problems.push(`${station.crs}: longitude ${station.lon} outside expected area`);
    if (!station.operators.length) problems.push(`${station.crs}: no operator observed`);
  }

  const seen = new Set();
  for (const station of stations) {
    if (seen.has(station.crs)) problems.push(`${station.crs}: duplicated`);
    seen.add(station.crs);
  }

  const operatorCounts = {};
  for (const station of stations) {
    for (const toc of station.operators) operatorCounts[toc] = (operatorCounts[toc] ?? 0) + 1;
  }
  console.log(`  operators observed: ${Object.entries(operatorCounts).map(([k, v]) => `${k}=${v}`).join(', ')}`);

  for (const expected of ['CC', 'XR', 'LE']) {
    if (!operatorCounts[expected]) problems.push(`no stations found for operator ${expected}`);
  }

  const outOfScope = Object.keys(operatorCounts).filter((toc) => !OPERATORS_IN_SCOPE.has(toc));
  if (outOfScope.length) problems.push(`out-of-scope operators harvested: ${outOfScope.join(', ')}`);

  // Printed so the coverage can actually be eyeballed. A missing branch shows up
  // here far more clearly than in a total.
  console.log('\n  stations by operator:');
  for (const toc of [...Object.keys(operatorCounts)].sort()) {
    const names = stations.filter((s) => s.operators.includes(toc)).map((s) => s.crs);
    console.log(`    ${toc} (${names.length}): ${names.join(' ')}`);
  }

  // ---- route markers -------------------------------------------------------

  const byName = new Map();
  for (const station of stations) {
    const key = station.name.toLowerCase();
    byName.set(key, station);
  }

  const routeMarkers = [];
  for (const marker of ROUTE_MARKERS) {
    const exact = byName.get(marker.station.toLowerCase());
    const matches = exact
      ? [exact]
      : stations.filter((s) => s.name.toLowerCase().includes(marker.station.toLowerCase()));
    if (matches.length !== 1) {
      problems.push(
        `route marker "${marker.station}" resolved to ${matches.length} stations` +
          (matches.length ? ` (${matches.map((s) => `${s.name} [${s.crs}]`).join(', ')})` : '')
      );
      continue;
    }
    routeMarkers.push({ crs: matches[0].crs, label: marker.label, station: matches[0].name });
    console.log(`  marker ${marker.label.padEnd(16)} -> ${matches[0].name} [${matches[0].crs}]`);
  }

  if (problems.length) {
    console.log('\n  PROBLEMS:');
    for (const problem of problems) console.log(`    - ${problem}`);
    throw new Error(`${problems.length} validation problem(s); not writing stations.json`);
  }

  console.log('  all checks passed');

  // ---- emit ----------------------------------------------------------------

  const payload = {
    generatedAt: new Date().toISOString(),
    apiVersion: info.api_version ?? API_VERSION,
    sampledServiceDate: date,
    routeMarkers,
    stations: stations.map(({ coordSource, ...rest }) => rest),
  };

  mkdirSync(join(ROOT, 'data'), { recursive: true });
  const out = join(ROOT, 'data', 'stations.json');
  writeFileSync(out, `${JSON.stringify(payload, null, 2)}\n`);

  console.log(`\n  wrote ${out}`);
  console.log(`  ${stations.length} stations, ${routeMarkers.length} route markers`);
  console.log(`  ${apiCalls} API calls, ${cacheHits} served from .rtt-cache/`);
  console.log(
    `  ${corridorDestinations.size} corridor destinations, incl. ` +
      `${[...corridorDestinations].filter((n) => !byName.has(n.toLowerCase())).slice(0, 6).join(', ')}`
  );

  // ---- longitude table for telling east from west --------------------------
  //
  // Every GB rail station, not just the ones in scope: the Greater Anglia trains
  // through Shenfield carry on to Norwich, Ipswich, Colchester and Clacton, all
  // legitimate eastbound destinations that are deliberately absent from the
  // station list above. Longitude only, rounded to ~100m, and read server-side
  // only.
  const byTiplocLon = {};
  for (const [tiploc, entry] of naptan) byTiplocLon[tiploc] = Number(entry.lon.toFixed(3));

  const byCrsLon = {};
  for (const loc of locations) {
    if (!loc.shortCode || !loc.longCode) continue;
    const lon = byTiplocLon[loc.longCode.trim().toUpperCase()];
    if (typeof lon === 'number' && !(loc.shortCode in byCrsLon)) byCrsLon[loc.shortCode] = lon;
  }

  // Stations in scope take their own already-validated longitude, which overrides
  // anything derived above. Some interchanges -- West Ham is one -- carry a TIPLOC in
  // the reference data that has no rail-area NaPTAN entry, so deriving alone leaves a
  // hole exactly where it matters most.
  for (const station of stations) byCrsLon[station.crs] = station.lon;

  // A missing entry would silently classify every train at that station as heading
  // one way, which is worse than a visible failure.
  for (const station of stations) {
    if (typeof byCrsLon[station.crs] !== 'number') {
      throw new Error(`No longitude for ${station.crs} in the east/west table`);
    }
  }

  // Kept out of stations.json deliberately: that file is imported by the station
  // picker and so ships to the browser, and none of this is any use there.
  const geoOut = join(ROOT, 'data', 'geo.json');
  writeFileSync(
    geoOut,
    `${JSON.stringify(
      {
        generatedAt: payload.generatedAt,
        corridorDestinations: [...corridorDestinations].sort(),
        byTiploc: byTiplocLon,
        byCrs: byCrsLon,
      },
      null,
      0
    )}\n`
  );
  console.log(
    `  wrote ${geoOut}` +
      ` (${Object.keys(byTiplocLon).length} TIPLOCs, ${Object.keys(byCrsLon).length} CRS)\n`
  );
}

main().catch((error) => {
  console.error(`\nFAILED: ${error.message}`);
  process.exitCode = 1;
});
