#!/usr/bin/env node
/**
 * IOS.md §9 step 3: generate data/national.json — every station in Great Britain.
 *
 * The web app's `data/stations.json` covers 67 stations on three corridors, harvested
 * by sampling real services along known routes. That approach does not scale and does
 * not need to: nationally there are no corridors, so the station list is simply
 * *every stop the token can query*, which the API will hand over in one request.
 *
 * `stations.json` and `geo.json` are left alone. The web app is finished and in daily
 * use, and IOS.md is explicit that it stays as-is until the native app ships.
 *
 * The same rule as everywhere else in this project: **no CRS code is typed by hand**,
 * and the generator refuses to emit a list it cannot validate.
 *
 * Run:  npm run national:data
 *
 * Costs nothing on a warm cache. Both endpoints it needs are reference data already
 * fetched by the other scripts, and coordinates come from NaPTAN, which is the DfT's.
 */

import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { loadEnvLocal, rtt, requestsSpent, rateLimits } from './lib/rtt.mjs';
import { loadNaptan, haversineMetres, canonicalName } from './lib/naptan.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

/**
 * Two destinations, one source of truth.
 *
 * The API reads `data/national.json` from disk. The native app cannot — it ships as a
 * bundle and has no repo to reach into — so the same bytes are written into the Swift
 * package's resources, where `Bundle.module` can find them.
 *
 * Written by the generator rather than copied by hand, because a second copy of
 * generated data that somebody has to remember to sync is a copy that will be stale.
 * Re-run `npm run national:data` and both are current.
 */
const OUTPUTS = [
  join(ROOT, 'data', 'national.json'),
  join(ROOT, 'ios', 'Sources', 'LastTrainCore', 'Resources', 'national.json'),
];

/**
 * Stops with no coordinates, and why.
 *
 * Recorded rather than quietly dropped, and asserted rather than tolerated: if this
 * list stops matching reality the generator says so, because a station silently
 * losing its position is exactly the kind of failure that shows up later as a
 * direction that cannot be classified.
 *
 * Two of the three are not rail stations at all -- they are the rail-air interchanges
 * RTT lists alongside real stops. The third is a genuine gap: Winslow reopened on
 * East West Rail and NaPTAN has not published it yet.
 */
const KNOWN_GAPS = {
  XPB: 'Bristol International Airport — a rail-air interchange, not a rail station',
  XMT: 'East Midlands Airport — a rail-air interchange, not a rail station',
  WNO: 'Winslow — reopened on East West Rail, not yet published by NaPTAN',
};

/** Below this, two "different" stations are the same place and one of them is wrong. */
const DUPLICATE_METRES = 25;

/** Great Britain, generously bounded. Anything outside is a bad coordinate. */
const GB_BOUNDS = { minLat: 49.5, maxLat: 61.0, minLon: -8.8, maxLon: 2.1 };

async function main() {
  loadEnvLocal();

  console.log('=== Reference data ==========================================\n');

  const stops = (await rtt('/data/stops', {}, { cache: true }))?.stops ?? [];
  const locations = (await rtt('/data/locations_ungrouped', {}, { cache: true }))?.locations ?? [];
  const naptan = await loadNaptan();

  console.log(`\n  ${stops.length} stops queryable, ${locations.length} locations known`);

  // CRS -> every TIPLOC the API associates with it. A handful of stations have more
  // than one; any of them resolves to the same place, so the first hit wins.
  const tiplocsByCrs = new Map();
  for (const loc of locations) {
    const crs = String(loc.shortCode ?? '').trim().toUpperCase();
    const tiploc = String(loc.longCode ?? '').trim().toUpperCase();
    if (!crs || !tiploc) continue;
    if (!tiplocsByCrs.has(crs)) tiplocsByCrs.set(crs, []);
    tiplocsByCrs.get(crs).push(tiploc);
  }

  console.log('\n=== Joining coordinates =====================================\n');

  const stations = [];
  const missing = [];
  const via = { tiploc: 0, name: 0, 'tiploc-inactive': 0, 'name-inactive': 0 };
  const bySource = { naptan: 0, 'naptan-grid': 0 };
  const disagreements = [];

  for (const stop of stops) {
    const crs = String(stop.shortCode ?? '').trim().toUpperCase();
    const name = String(stop.description ?? '').trim();
    if (!crs || !name) continue;

    const tiplocs = tiplocsByCrs.get(crs) ?? [];
    const place = naptan.resolve(tiplocs, name);

    if (!place) {
      missing.push({ crs, name });
      continue;
    }

    via[place.via] = (via[place.via] ?? 0) + 1;
    bySource[place.source] = (bySource[place.source] ?? 0) + 1;

    // Cross-check the name fallback against the code route wherever both resolve.
    // This is the check that makes matching by name safe rather than hopeful.
    if (place.via === 'tiploc') {
      const byName = naptan.byName.get(canonicalName(name));
      if (byName && haversineMetres(place, byName) > 500) {
        disagreements.push(
          `${name} (${crs}): TIPLOC and name disagree by ${Math.round(haversineMetres(place, byName))}m`
        );
      }
    }

    stations.push({
      crs,
      name,
      lat: place.lat,
      lon: place.lon,
      // For search disambiguation: two Newports, several Ashfords, Whitchurch in
      // three counties. NaPTAN's locality is what tells them apart on screen.
      locality: place.locality && place.locality !== name ? place.locality : null,
      town: place.town && place.town !== name ? place.town : null,
      coordSource: place.source,
      matchedBy: place.via,
    });
  }

  stations.sort((a, b) => a.crs.localeCompare(b.crs));

  console.log(`  ${stations.length} of ${stops.length} stops placed`);
  console.log(
    `  matched by: ${Object.entries(via).filter(([, n]) => n).map(([k, n]) => `${k} ${n}`).join(', ')}`
  );
  console.log(
    `  positions from: ${Object.entries(bySource).filter(([, n]) => n).map(([k, n]) => `${k} ${n}`).join(', ')}`
  );

  console.log('\n=== Validating ==============================================\n');

  const problems = [];

  // 1. Coordinates have to be in Great Britain.
  const outOfBounds = stations.filter(
    (s) =>
      s.lat < GB_BOUNDS.minLat ||
      s.lat > GB_BOUNDS.maxLat ||
      s.lon < GB_BOUNDS.minLon ||
      s.lon > GB_BOUNDS.maxLon
  );
  if (outOfBounds.length) {
    problems.push(
      `${outOfBounds.length} station(s) outside Great Britain: ` +
        outOfBounds.slice(0, 6).map((s) => `${s.name} (${s.crs}) ${s.lat},${s.lon}`).join('; ')
    );
  } else {
    console.log('  ok    every coordinate is inside Great Britain');
  }

  // 2. CRS codes are unique. A duplicate means the list cannot be keyed on them.
  const seen = new Set();
  const dupeCrs = stations.filter((s) => (seen.has(s.crs) ? true : (seen.add(s.crs), false)));
  if (dupeCrs.length) problems.push(`duplicate CRS codes: ${dupeCrs.map((s) => s.crs).join(', ')}`);
  else console.log('  ok    every CRS code is unique');

  // 3. Two stations at the same spot means a bad join, not two stations.
  const byCell = new Map();
  const cellOf = (s) => `${s.lat.toFixed(2)}:${s.lon.toFixed(2)}`;
  for (const s of stations) {
    for (const dLat of [-0.01, 0, 0.01]) {
      for (const dLon of [-0.01, 0, 0.01]) {
        const key = `${(s.lat + dLat).toFixed(2)}:${(s.lon + dLon).toFixed(2)}`;
        if (!byCell.has(key)) byCell.set(key, []);
        if (key === cellOf(s)) byCell.get(key).push(s);
      }
    }
  }
  const collisions = [];
  for (const bucket of byCell.values()) {
    for (let i = 0; i < bucket.length; i++) {
      for (let j = i + 1; j < bucket.length; j++) {
        const d = haversineMetres(bucket[i], bucket[j]);
        if (d < DUPLICATE_METRES) {
          collisions.push(`${bucket[i].name} (${bucket[i].crs}) and ${bucket[j].name} (${bucket[j].crs}) are ${Math.round(d)}m apart`);
        }
      }
    }
  }
  if (collisions.length) {
    console.log(`  note  ${collisions.length} pair(s) within ${DUPLICATE_METRES}m:`);
    for (const c of collisions.slice(0, 8)) console.log(`          ${c}`);
  } else {
    console.log(`  ok    no two stations share a position within ${DUPLICATE_METRES}m`);
  }

  // 4. The name fallback must not contradict the code route.
  if (disagreements.length) {
    problems.push(`name and TIPLOC joins disagree: ${disagreements.slice(0, 5).join('; ')}`);
  } else {
    console.log('  ok    name and TIPLOC joins agree wherever both resolve');
  }

  // 5. The gaps have to be exactly the ones we know about. A new one is a signal
  //    that something upstream changed, not something to shrug at.
  const missingCrs = missing.map((m) => m.crs).sort();
  const expected = Object.keys(KNOWN_GAPS).sort();
  const unexpected = missingCrs.filter((c) => !(c in KNOWN_GAPS));
  const healed = expected.filter((c) => !missingCrs.includes(c));

  if (unexpected.length) {
    problems.push(
      `${unexpected.length} station(s) newly without coordinates: ` +
        missing.filter((m) => unexpected.includes(m.crs)).map((m) => `${m.name} (${m.crs})`).join(', ')
    );
  }
  if (healed.length) {
    console.log(`  note  NaPTAN now covers ${healed.join(', ')} — remove from KNOWN_GAPS`);
  }
  if (!unexpected.length) {
    console.log(`  ok    the only gaps are the ${missing.length} already known:`);
    for (const m of missing) console.log(`          ${m.crs}  ${KNOWN_GAPS[m.crs] ?? m.name}`);
  }

  if (problems.length) {
    console.log('\n  Refusing to emit an invalid list:\n');
    for (const p of problems) console.log(`  FAIL  ${p}`);
    process.exitCode = 1;
    return;
  }

  const body = {
    generatedAt: new Date().toISOString(),
    stationCount: stations.length,
    /** Stops the API can query but that have no published position. See KNOWN_GAPS. */
    unplaced: missing.map((m) => ({ ...m, reason: KNOWN_GAPS[m.crs] ?? 'unknown' })),
    stations,
  };

  const serialised = JSON.stringify(body);
  for (const out of OUTPUTS) {
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, serialised);
    console.log(`\n  wrote ${out}`);
  }
  console.log(`  ${stations.length} stations, ${missing.length} unplaced`);
  console.log(
    `  ${requestsSpent()} API requests spent${rateLimits() ? `  [remaining: ${rateLimits()}]` : ''}`
  );
}

main().catch((err) => {
  console.error(`\nFAILED: ${err.message}`);
  process.exitCode = 1;
});
