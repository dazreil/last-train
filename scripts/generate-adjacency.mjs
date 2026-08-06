#!/usr/bin/env node
/**
 * Which way does a train actually leave?
 *
 * The line-up does not say. It gives an origin, a destination and a time, and the app
 * has been inferring direction from the bearing to the destination — which is right for
 * a straight line and wrong for any route that turns. The case that exposed it: from
 * Upminster the 00:33 and the 00:57 are both "Shoeburyness", but the first runs down the
 * Ockendon branch through Grays and Tilbury while the second takes the main line through
 * Basildon. Same origin, same destination, opposite first legs. Nothing in the line-up
 * distinguishes them, so nothing computed from the line-up ever could.
 *
 * The route is only visible in a service's calling pattern, and fetching one per
 * departure would cost a request per train shown — the budget IOS.md §3 and §5 are built
 * on. So the patterns are walked **here**, once, offline, and what comes out is a small
 * fact per station that the runtime can use for free:
 *
 *   for each compass sector, a waypoint that every service leaving that way calls at,
 *   and no service leaving any other way calls at.
 *
 * At Upminster southbound that waypoint is Grays. `filterTo=GRY` on the line-up then
 * returns exactly the southbound services — one request, no inference, and it picks up
 * the 00:33 that destination-bearing threw into the eastbound pile.
 *
 * The idea is not new here: `generate-stations.mjs` already filtered its probes on "the
 * waypoint where there is one: that is what pins the route". This computes them rather
 * than hand-listing them, which is the rule this project has held throughout —
 * identifiers are resolved, never typed.
 *
 * ## Running it
 *
 *   node scripts/generate-adjacency.mjs --stations UPM,OCK,GRY   # a few, for checking
 *   node scripts/generate-adjacency.mjs --all --budget 900       # a day's worth
 *
 * **Resumable, because it has to be.** Covering Great Britain is thousands of requests
 * against a tier that allows 1,000 a day, so every response goes through `.rtt-cache/`
 * and progress is kept in `data/.adjacency-state.json`. Re-running continues where the
 * last run stopped and costs nothing for the ground already covered.
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadEnvLocal, rtt, addDays, requestsSpent, rateLimits } from './lib/rtt.mjs';
import { bearingDegrees, compassOf, COMPASS_POINTS } from '../lib/compass.ts';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const STATE_PATH = resolve(ROOT, 'data/.adjacency-state.json');
const OUT_PATH = resolve(ROOT, 'data/adjacency.json');
const NATIONAL_PATH = resolve(ROOT, 'data/national.json');

/**
 * How many distinct route-shapes to sample at each station.
 *
 * Services are grouped by origin, destination and headcode prefix before sampling, so
 * this is a cap on genuinely different workings rather than on trains. Twelve covers
 * every platform at a large junction; the cost of raising it is paid in requests.
 */
const MAX_GROUPS_PER_STATION = 16;

/**
 * How many sampled routes a sector needs before its waypoint is trusted.
 *
 * The failure that matters is a waypoint too *narrow* — one that a fast service skips,
 * so `filterTo` silently drops it and the board under-reports. That happens when the
 * sample saw only the stopping pattern. Seen once, a sector gets no waypoint and the
 * runtime keeps its old behaviour, which is wrong in a known way rather than wrong in a
 * way nobody notices.
 *
 * Thin samples mostly cure themselves as the walk spreads: a pattern fetched anywhere
 * along a route covers every station on it, so neighbours enrich each other.
 */
const MIN_SAMPLES_FOR_WAYPOINT = 3;

// ------------------------------------------------------------------ arguments

const args = process.argv.slice(2);
/** Accepts `--name=value`, `--name value`, and bare `--name`. */
const flag = (name) => {
  const index = args.findIndex((a) => a === `--${name}` || a.startsWith(`--${name}=`));
  if (index === -1) return undefined;
  const hit = args[index];
  if (hit.includes('=')) return hit.slice(hit.indexOf('=') + 1);
  const next = args[index + 1];
  return next && !next.startsWith('--') ? next : true;
};

const BUDGET = Number(flag('budget') ?? 900);
const ONLY = flag('stations');
const ALL = flag('all') === true;

/**
 * A reference weekday, because the question is about track rather than about today.
 *
 * Tuesday deliberately: no Sunday engineering pattern, no Friday-only extras, and far
 * enough ahead that the timetable is settled. Seasonal and Sunday-only branches are a
 * known gap — they will simply have no waypoint and fall back to the old behaviour.
 */
const referenceDate = (() => {
  const explicit = flag('date');
  if (typeof explicit === 'string') return explicit;
  const now = new Date();
  const iso = now.toISOString().slice(0, 10);
  // 2 = Tuesday.
  let d = iso;
  for (let i = 0; i < 8; i++) {
    const day = new Date(`${d}T12:00:00Z`).getUTCDay();
    if (day === 2 && d > iso) return d;
    d = addDays(d, 1);
  }
  return addDays(iso, 7);
})();

// ----------------------------------------------------------------- state, i/o

const readJson = (path, fallback) =>
  existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : fallback;

const state = readJson(STATE_PATH, { date: referenceDate, patterns: {}, sampled: {} });
if (state.date !== referenceDate) {
  // A different reference day is a different timetable; mixing them would produce
  // waypoints that were never true on any single day.
  console.log(`Reference date changed (${state.date} -> ${referenceDate}); starting over.`);
  state.date = referenceDate;
  state.patterns = {};
  state.sampled = {};
}

const nationalRaw = readJson(NATIONAL_PATH, null);
if (!nationalRaw) throw new Error('data/national.json missing; run `npm run national:data` first');
const stations = Array.isArray(nationalRaw) ? nationalRaw : nationalRaw.stations;
const byCrs = new Map(stations.map((s) => [s.crs, s]));

// -------------------------------------------------------------------- helpers

const stripNamespace = (identity) => String(identity).replace(/^[a-z-]+:/, '');

const departureOf = (service) => service?.temporalData?.departure?.scheduleAdvertised ?? '';

const describe = (list) => (list ?? []).map((d) => d.location?.description).join(' & ');

/** Calling points only. A place the train runs through is not somewhere you get off. */
const callingPattern = (detail) =>
  (detail?.service?.locations ?? [])
    .filter((l) => l.temporalData?.displayAs !== 'PASS')
    .map((l) => (l.location?.shortCodes ?? [])[0])
    .filter((crs) => crs && byCrs.has(crs));

// ------------------------------------------------------------------ collecting

/** crs -> sector -> how many sampled routes leave that way. Rebuilt each run. */
const coverageIndex = (() => {
  const index = new Map();
  for (const stops of Object.values(state.patterns)) {
    for (let i = 0; i < stops.length - 1; i++) {
      const a = byCrs.get(stops[i]);
      const b = byCrs.get(stops[i + 1]);
      if (!a || !b) continue;
      const sector = compassOf(bearingDegrees(a, b));
      if (!sector) continue;
      if (!index.has(stops[i])) index.set(stops[i], new Map());
      const sectors = index.get(stops[i]);
      sectors.set(sector, (sectors.get(sector) ?? 0) + 1);
    }
  }
  return index;
})();

let spentAtStart = requestsSpent();
const overBudget = () => requestsSpent() - spentAtStart >= BUDGET;

/**
 * Coverage already gathered for a station, without asking for anything.
 *
 * A calling pattern fetched anywhere covers every station along it, so most stations are
 * described by their neighbours' work before the walk ever reaches them. Sampling them
 * again buys nothing and the quota is the scarce thing here — 12 stations sampled put
 * 149 in the table, so skipping the ones already answered is most of the saving
 * available.
 */
function sectorsAlreadyCovered(crs) {
  let good = 0;
  const sectors = coverageIndex.get(crs);
  if (!sectors) return 0;
  for (const count of sectors.values()) if (count >= MIN_SAMPLES_FOR_WAYPOINT) good++;
  return good;
}

async function sampleStation(crs) {
  if (state.sampled[crs]) return;

  // Two well-sampled sectors is a through station fully described. A junction has more
  // and will still have a thin one, so it stays in the queue.
  if (sectorsAlreadyCovered(crs) >= 2) {
    state.sampled[crs] = 'covered-by-neighbours';
    return;
  }

  const window = {
    timeFrom: `${referenceDate}T03:00:00`,
    timeTo: `${addDays(referenceDate, 1)}T02:59:00`,
  };

  const lineUp = await rtt('/gb-nr/location', { code: crs, ...window }, { cache: true, log: () => {} });
  const services = (lineUp?.services ?? []).filter(
    (s) =>
      s.scheduleMetadata?.uniqueIdentity &&
      s.scheduleMetadata?.inPassengerService !== false &&
      departureOf(s)
  );

  // Group before sampling: a hundred trains to Shoeburyness are a handful of workings,
  // and fetching all of them would buy nothing the first of each does not already say.
  const groups = new Map();
  for (const service of services) {
    const key = [
      describe(service.origin),
      describe(service.destination),
      (service.scheduleMetadata?.trainReportingIdentity ?? '').slice(0, 2),
    ].join('|');
    if (!groups.has(key)) groups.set(key, service);
  }

  // Spread across the day rather than taking the first few. Peak fast services and
  // off-peak all-stations services call at different sets of stations, and a sample of
  // consecutive early-morning workings sees only one of those shapes.
  const candidates = [...groups.values()];
  const step = Math.max(1, Math.floor(candidates.length / MAX_GROUPS_PER_STATION));
  const chosen = [];
  for (let i = 0; i < candidates.length && chosen.length < MAX_GROUPS_PER_STATION; i += step) {
    chosen.push(candidates[i]);
  }

  for (const service of chosen) {
    const id = stripNamespace(service.scheduleMetadata.uniqueIdentity);
    if (state.patterns[id]) continue;
    if (overBudget()) return; // stop cleanly; the station stays unsampled and is retried
    const detail = await rtt('/gb-nr/service', { uniqueIdentity: id }, { cache: true, log: () => {} });
    state.patterns[id] = callingPattern(detail);
  }

  state.sampled[crs] = true;
}

// ------------------------------------------------------------------- deriving

/**
 * Turn the collected patterns into one waypoint per station per compass sector.
 *
 * A waypoint has to do two jobs at once: be called at by *every* service leaving that
 * way, so none is missed, and by *no* service leaving another way, so none is stolen.
 * Where no station satisfies both there is no waypoint, and the runtime keeps its old
 * behaviour for that sector rather than guessing.
 */
function derive() {
  /** crs -> sector -> { patterns: [stops after the station], firstCalls:Set } */
  const perStation = new Map();

  for (const stops of Object.values(state.patterns)) {
    for (let i = 0; i < stops.length - 1; i++) {
      const here = stops[i];
      const next = stops[i + 1];
      const a = byCrs.get(here);
      const b = byCrs.get(next);
      if (!a || !b) continue;

      const sector = compassOf(bearingDegrees(a, b));
      if (!sector) continue;

      if (!perStation.has(here)) perStation.set(here, new Map());
      const sectors = perStation.get(here);
      if (!sectors.has(sector)) sectors.set(sector, { onward: [], firstCalls: new Set() });

      const bucket = sectors.get(sector);
      bucket.firstCalls.add(next);
      bucket.onward.push(stops.slice(i + 1));
    }
  }

  const out = {};

  for (const [crs, sectors] of perStation) {
    const entry = {};

    for (const point of COMPASS_POINTS) {
      const bucket = sectors.get(point);
      if (!bucket) continue;

      // Called at by every service going this way.
      let common = null;
      for (const onward of bucket.onward) {
        const seen = new Set(onward);
        common = common === null ? seen : new Set([...common].filter((c) => seen.has(c)));
      }

      // Called at by anything going another way, at any point in its journey.
      const elsewhere = new Set();
      for (const [other, otherBucket] of sectors) {
        if (other === point) continue;
        for (const onward of otherBucket.onward) for (const c of onward) elsewhere.add(c);
      }

      const candidates = [...(common ?? [])].filter((c) => !elsewhere.has(c) && byCrs.has(c));

      // Nearest wins. A waypoint one stop away is likelier to survive a timetable
      // change than one at the far end of the line, and short-workings that turn back
      // early are the common way a distant waypoint stops being universal.
      candidates.sort(
        (x, y) =>
          haversineKm(byCrs.get(crs), byCrs.get(x)) - haversineKm(byCrs.get(crs), byCrs.get(y))
      );

      // Where this way goes, for the direction control's `towards` line.
      //
      // Baked rather than read from the line-up, because a filtered query only
      // describes the direction it was asked about and the control names a destination
      // on all four blocks. Sampled from a reference Tuesday, so these are labels
      // rather than facts about today -- which is all the block ever claimed.
      const endpoints = new Map();
      for (const onward of bucket.onward) {
        const last = onward[onward.length - 1];
        if (last) endpoints.set(last, (endpoints.get(last) ?? 0) + 1);
      }

      entry[point] = {
        waypoint: bucket.onward.length >= MIN_SAMPLES_FOR_WAYPOINT ? (candidates[0] ?? null) : null,
        firstCalls: [...bucket.firstCalls].sort(),
        destinations: [...endpoints.entries()]
          .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
          .slice(0, 3)
          .map(([crs]) => crs),
        samples: bucket.onward.length,
      };
    }

    if (Object.keys(entry).length) out[crs] = entry;
  }

  return out;
}

function haversineKm(a, b) {
  const R = 6371;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

// ----------------------------------------------------------------------- main

async function main() {
  loadEnvLocal();

  const queue = ONLY
    ? String(ONLY)
        .split(',')
        .map((c) => c.trim().toUpperCase())
    : ALL
      ? stations.map((s) => s.crs)
      : [];

  if (!queue.length) {
    console.log('Nothing to do. Pass --stations CRS,CRS or --all.');
    return;
  }

  const outstanding = queue.filter((crs) => !state.sampled[crs]);
  console.log(`Reference date ${referenceDate}`);
  console.log(`${outstanding.length} of ${queue.length} stations still to sample.`);
  console.log(`Budget ${BUDGET} live requests.\n`);

  let done = 0;
  try {
    for (const crs of outstanding) {
      if (overBudget()) {
        console.log(`\nBudget reached after ${done} stations. Run again to continue.`);
        break;
      }
      if (!byCrs.has(crs)) continue;
      try {
        await sampleStation(crs);
      } catch (error) {
        // The free tier caps by hour as well as by day, and the hour is what bites
        // first. Hitting it is expected on a walk this size, not a failure.
        if (/Rate limited/.test(String(error?.message))) {
          console.log(`\n${error.message.replace('Rate limited; retry', 'Rate limited. Retry')}`);
          break;
        }
        throw error;
      }
      done++;
      if (done % 10 === 0) {
        console.log(`  ${done}/${outstanding.length}  (${requestsSpent() - spentAtStart} requests)`);
      }
    }
  } finally {
    // Always save. A run stopped by a rate limit or a keystroke must not throw away
    // the requests it already paid for.
    writeFileSync(STATE_PATH, JSON.stringify(state, null, 1));
    const table = derive();
    writeFileSync(
      OUT_PATH,
      JSON.stringify(
        {
          generatedAt: new Date().toISOString(),
          referenceDate,
          note: 'Generated by scripts/generate-adjacency.mjs. Never hand-edited.',
          stations: table,
        },
        null,
        1
      )
    );

    const withWaypoint = Object.values(table).filter((s) =>
      Object.values(s).some((sector) => sector.waypoint)
    ).length;
    console.log(`\nSampled stations:      ${Object.keys(state.sampled).length}`);
    console.log(`Patterns collected:    ${Object.keys(state.patterns).length}`);
    console.log(`Stations in the table: ${Object.keys(table).length} (${withWaypoint} with a waypoint)`);
    console.log(`Live requests spent:   ${requestsSpent() - spentAtStart}`);
    if (rateLimits()) console.log(`Rate limits:           ${rateLimits()}`);
    console.log(`\nWrote ${OUT_PATH}`);
  }
}

await main();
