#!/usr/bin/env node
/**
 * Darwin timetable ingest, stage 1: parse to a snapshot.
 *
 * `DARWIN-INGEST.md` §3 stage 1. Reads the two delivered files, normalises every
 * passenger journey, and writes one NDJSON file per service day. Nothing the app
 * reads is touched, and nothing is stored anywhere the app can see it: this is
 * file in, file out.
 *
 * It also answers the question stage 0 could not. Stage 0 measured a mean of 8.4
 * public calls per journey and projected the per-station board at about 1.8
 * million rows, while warning that a mean understates a convex cost. This counts
 * the rows exactly, from the real distribution.
 *
 * Output lands in the system temp directory unless `--out` says otherwise. The
 * repo is inside iCloud Drive, and writing tens of megabytes there is how the
 * file provider wedges and the next build hangs.
 *
 * Run:  node scripts/darwin-parse.mjs --file ~/Downloads
 *       node scripts/darwin-parse.mjs --file ~/Downloads --out /tmp/snapshot
 *       node scripts/darwin-parse.mjs --file ~/Downloads --dry-run
 */

import { createWriteStream, mkdirSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { parseDarwinKey, pickBest, scanFile } from './lib/darwin-scan.mjs';
import { parseReference, parseTimetable } from './lib/darwin-parse.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

const args = process.argv.slice(2);
const has = (f) => args.includes(f);
const allValuesOf = (f) =>
  args.reduce((out, a, i) => (a === f && args[i + 1] ? [...out, args[i + 1]] : out), []);

const FILES = allValuesOf('--file');
const OUT = allValuesOf('--out')[0] || join(tmpdir(), 'darwin-snapshot');
const DRY_RUN = has('--dry-run');

const expand = (p) => resolve(p.startsWith('~') ? join(homedir(), p.slice(1)) : p);
const withCommas = (n) => n.toLocaleString('en-GB');
const mib = (b) => `${(b / 1024 / 1024).toFixed(1)} MiB`;
const pct = (n, of) => (of ? `${((n / of) * 100).toFixed(1)}%` : '—');

function fail(lines) {
  console.error(`\n  ${[].concat(lines).join('\n  ')}\n`);
  process.exit(1);
}

if (!FILES.length) {
  fail([
    'Nothing to parse.',
    '',
    '  --file <path>   one or more files, or a folder holding them.',
    '                  Needs one timetable (_vN) and one reference (_ref_vN).',
    '',
    'Run scripts/darwin-probe.mjs first if you have not measured them yet.',
  ]);
}

/* ------------------------------------------------------------ find the pair */

const paths = [];
for (const raw of FILES) {
  const path = expand(raw);
  let stat;
  try {
    stat = statSync(path);
  } catch {
    fail(`No such file: ${path}`);
  }
  if (stat.isDirectory()) {
    paths.push(...readdirSync(path).filter((n) => /\.(xml|gz)$/i.test(n)).map((n) => join(path, n)));
  } else {
    paths.push(path);
  }
}

const metas = paths.map((p) => ({ path: p, meta: parseDarwinKey(p) })).filter((p) => p.meta);
const bestTimetable = pickBest(metas.map((p) => p.meta), 'timetable');
const bestReference = pickBest(metas.map((p) => p.meta), 'reference');

/**
 * Fall back to reading the root element when the names do not parse.
 *
 * A file taken by hand can be called anything, and being unable to parse a
 * filename is a poor reason to refuse a perfectly good file.
 */
async function byRootElement() {
  const found = { timetable: null, reference: null };
  for (const path of paths) {
    const { rootTag } = await scanFile(path, {});
    if (rootTag === 'PportTimetable') found.timetable ??= path;
    else if (rootTag === 'PportTimetableRef') found.reference ??= path;
  }
  return found;
}

let timetablePath = metas.find((p) => p.meta.name === bestTimetable?.name)?.path ?? null;
let referencePath = metas.find((p) => p.meta.name === bestReference?.name)?.path ?? null;
if (!timetablePath || !referencePath) {
  const found = await byRootElement();
  timetablePath ??= found.timetable;
  referencePath ??= found.reference;
}

if (!timetablePath) fail('No timetable file found. That is the large one, named _vN.');
if (!referencePath) {
  fail([
    'No reference file found. That is the small one, named _ref_vN.',
    '',
    'The timetable speaks TIPLOC and this app is keyed by CRS. Without the',
    'reference file there is no mapping between them, so nothing can be built.',
  ]);
}

console.log(`\n  timetable  ${timetablePath.split('/').pop()}  ${mib(statSync(timetablePath).size)}`);
console.log(`  reference  ${referencePath.split('/').pop()}  ${mib(statSync(referencePath).size)}`);

/**
 * The two files must come from the same publish.
 *
 * Easy to get wrong with a downloads folder, which is how it was found: keeping
 * several days of files means the newest timetable and the newest reference can
 * be days apart, and the pair still looks perfectly reasonable. The reference
 * file barely moves -- four days apart it differed by three sidings and one
 * station gaining a name -- so a mismatch does not fail. It quietly resolves
 * TIPLOCs against the wrong day's table, and a station that opened in between is
 * simply absent.
 *
 * A warning, not an error: an old reference file is usually still usable, and
 * refusing to run would be worse than saying so.
 */
const timetableStamp = parseDarwinKey(timetablePath)?.stamp ?? null;
const referenceStamp = parseDarwinKey(referencePath)?.stamp ?? null;
if (timetableStamp && referenceStamp && timetableStamp !== referenceStamp) {
  const readable = (t) => `${t.slice(0, 4)}-${t.slice(4, 6)}-${t.slice(6, 8)} ${t.slice(8, 10)}:${t.slice(10, 12)}`;
  console.log(`\n  WARNING: these are different publishes.`);
  console.log(`    timetable generated ${readable(timetableStamp)}`);
  console.log(`    reference generated ${readable(referenceStamp)}`);
  console.log(`    TIPLOCs will resolve against the wrong day's table. Usually harmless,`);
  console.log(`    but a station that opened between the two will be missing.`);
}

/* ------------------------------------------------------------------- parse */

const startedAt = Date.now();

console.log('\n  reading the reference file');
const { locations, operators } = await parseReference(referencePath);
const withCrs = [...locations.values()].filter((l) => l.crs).length;
console.log(`    ${withCommas(locations.size)} locations, ${withCommas(withCrs)} with a CRS, ${operators.size} operators`);

if (!DRY_RUN) mkdirSync(OUT, { recursive: true });

/** One NDJSON file per service day, opened as days are met. */
const writers = new Map();
const perDay = new Map();
function record(journey) {
  perDay.set(journey.serviceDate, (perDay.get(journey.serviceDate) ?? 0) + 1);
  if (DRY_RUN) return;
  let w = writers.get(journey.serviceDate);
  if (!w) {
    w = createWriteStream(join(OUT, `${journey.serviceDate}.ndjson`));
    writers.set(journey.serviceDate, w);
  }
  w.write(`${JSON.stringify(journey)}\n`);
}

/**
 * The measurement stage 0 could not make.
 *
 * A per-station board repeats each train's onward calls, so a journey of k
 * public calls contributes k(k−1)/2 rows. Summing that over the real
 * distribution is the honest number; the mean of k, squared, is not, because
 * the function is convex and long journeys dominate.
 */
const callHistogram = new Map();
let boardRows = 0;
const crsSeen = new Set();

console.log('  reading the timetable');
const stats = await parseTimetable(timetablePath, {
  locations,
  onJourney(journey) {
    const k = journey.calls.length;
    callHistogram.set(k, (callHistogram.get(k) ?? 0) + 1);
    boardRows += (k * (k - 1)) / 2;
    for (const call of journey.calls) crsSeen.add(call.crs);
    record(journey);
  },
});

for (const w of writers.values()) w.end();
const seconds = ((Date.now() - startedAt) / 1000).toFixed(1);

/* ------------------------------------------------------------------ report */

const seen = stats.journeysSeen;
console.log(`\n  JOURNEYS  (${withCommas(seen)} in the file, parsed in ${seconds}s)`);
console.log(`    kept                    ${withCommas(stats.kept).padStart(8)}   ${pct(stats.kept, seen)}`);
console.log(`      of those, buses       ${withCommas(stats.buses).padStart(8)}   kept and badged, never dropped`);
console.log(`      conditional (Q)       ${withCommas(stats.qtrains).padStart(8)}   runs only when required`);
console.log(`      charters              ${withCommas(stats.charters).padStart(8)}`);
console.log(`      terminating early     ${withCommas(stats.shortTerminations).padStart(8)}   cut short of the planned terminus`);
console.log(`    dropped, not passenger  ${withCommas(stats.droppedNotPassenger).padStart(8)}   ${pct(stats.droppedNotPassenger, seen)}`);
console.log(`    dropped, ship           ${withCommas(stats.droppedShip).padStart(8)}`);
console.log(`    dropped, freight        ${withCommas(stats.droppedFreight).padStart(8)}`);
console.log(`    dropped, cancelled      ${withCommas(stats.droppedCancelled).padStart(8)}   whole journey cancelled`);
console.log(`    dropped, under 2 calls  ${withCommas(stats.droppedTooFewCalls).padStart(8)}`);

// These do not sum to the total, and should not be read as though they do. A
// non-passenger journey is almost all operational stops, so it contributes stop
// elements to `callsSeen` and almost none to `callsKept` -- the difference is
// mostly calls belonging to journeys that were dropped whole.
console.log(`\n  CALLS  (${withCommas(stats.callsSeen)} public stop elements, across every journey)`);
console.log(`    kept                    ${withCommas(stats.callsKept).padStart(8)}   ${pct(stats.callsKept, stats.callsSeen)}`);
console.log(`    dropped, no public time ${withCommas(stats.callsNoPublicTime).padStart(8)}`);
console.log(`    dropped, no CRS         ${withCommas(stats.callsNoCrs).padStart(8)}   ${pct(stats.callsNoCrs, stats.callsSeen)}  junctions, sidings, depots`);
console.log(`    dropped, cancelled stop ${withCommas(stats.callsCancelled).padStart(8)}   the train runs but does not call`);
console.log(`    dropped, past terminus  ${withCommas(stats.callsAfterTerminus).padStart(8)}   stops beyond an early termination`);
console.log(`    false destinations      ${withCommas(stats.falseDestinations).padStart(8)}`);
console.log(`    cannot board here       ${withCommas(stats.callsNoBoarding).padStart(8)}   set down only, never a departure`);
console.log(`    cannot alight here      ${withCommas(stats.callsNoAlighting).padStart(8)}   take up only, never an arrival`);
if (stats.unknownTiplocs.size) {
  console.log(`    TIPLOC not in reference ${withCommas(stats.unknownTiplocs.size).padStart(8)}   e.g. ${[...stats.unknownTiplocs].slice(0, 5).join(', ')}`);
}
console.log(`    associations ignored    ${withCommas(stats.associations).padStart(8)}   v1 gap, see §6`);

console.log('\n  SERVICE DAYS');
for (const [day, n] of [...perDay.entries()].sort()) {
  console.log(`    ${day}   ${withCommas(n).padStart(7)} journeys`);
}

/* -------------------------------------------------- the spread, and the cost */

const lengths = [...callHistogram.entries()].sort((a, b) => a[0] - b[0]);
const total = stats.kept;
const quantile = (q) => {
  let running = 0;
  for (const [k, n] of lengths) {
    running += n;
    if (running >= total * q) return k;
  }
  return lengths.at(-1)?.[0] ?? 0;
};
const mean = stats.callsKept / (total || 1);

console.log('\n  CALLS PER JOURNEY');
console.log(`    mean ${mean.toFixed(1)}   median ${quantile(0.5)}   p90 ${quantile(0.9)}   p99 ${quantile(0.99)}   max ${lengths.at(-1)?.[0] ?? 0}`);
const widest = Math.max(...lengths.map(([, n]) => n));
for (const [k, n] of lengths) {
  if (n < total / 500) continue;
  console.log(`    ${String(k).padStart(3)}  ${'#'.repeat(Math.max(1, Math.round((n / widest) * 42)))} ${withCommas(n)}`);
}

const naive = Math.round(total * ((mean * (mean - 1)) / 2));
/**
 * What stage 0 wrote down, so the correction is visible rather than quietly
 * replaced. Its mean of 8.4 was taken over every journey in the file, including
 * the 12,612 non-passenger ones that carry almost no public calls at all, which
 * dragged it down; and squaring a mean understates a convex cost besides.
 */
const STAGE_0_ESTIMATE = 1_789_456;
console.log('\n  PER-STATION BOARD COST');
console.log(`    rows, counted exactly   ${withCommas(boardRows)}`);
console.log(`    rows, from this mean    ${withCommas(naive)}`);
console.log(`    rows, stage 0 estimated ${withCommas(STAGE_0_ESTIMATE)}   ${(boardRows / STAGE_0_ESTIMATE).toFixed(2)}x too low`);
console.log(`    distinct CRS on a board ${withCommas(crsSeen.size)}`);

const known = new Set(JSON.parse(readFileSync(join(ROOT, 'data/national.json'), 'utf8')).stations.map((s) => s.crs));
const unknown = [...crsSeen].filter((c) => !known.has(c));
const missing = [...known].filter((c) => !crsSeen.has(c));
console.log(`    the app knows           ${withCommas(known.size)} stations`);
console.log(`    in the feed, not the app ${withCommas(unknown.length).padStart(7)}   ${unknown.slice(0, 8).join(', ')}${unknown.length > 8 ? ' …' : ''}`);
console.log(`    in the app, not the feed ${withCommas(missing.length).padStart(7)}   ${missing.slice(0, 8).join(', ')}${missing.length > 8 ? ' …' : ''}`);

if (DRY_RUN) {
  console.log('\n  --dry-run: nothing written.\n');
} else {
  const written = readdirSync(OUT).filter((n) => n.endsWith('.ndjson'));
  const bytes = written.reduce((sum, n) => sum + statSync(join(OUT, n)).size, 0);
  console.log(`\n  WROTE  ${written.length} files, ${mib(bytes)}, to ${OUT}\n`);
}
