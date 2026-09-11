#!/usr/bin/env node
/**
 * Darwin timetable ingest, stage 2: measure the query shape.
 *
 * `DARWIN-INGEST.md` §3 stage 2, whose gate is explicit: **measure the total
 * stored size before writing any of it to a live store.** This does that and
 * nothing else. It writes no boards and talks to no store.
 *
 * Three encodings of the same per-station board are weighed against each other
 * and against the fallback shape, gzipped and not, per service day and at the
 * largest single station. The last of those is the one that can veto the design:
 * a shared store has a per-value ceiling, and Clapham Junction is the board that
 * finds it.
 *
 * Run:  node scripts/darwin-board.mjs --file ~/Downloads
 */

import { gzipSync } from 'node:zlib';
import { readdirSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';

import { parseDarwinKey, pickBest, scanFile } from './lib/darwin-scan.mjs';
import { parseReference, parseTimetable } from './lib/darwin-parse.mjs';
import {
  buildBoards,
  encodeCompactJson,
  encodeJourneyShape,
  encodeVerbose,
  packBoard,
  unpackBoard,
} from './lib/darwin-board.mjs';

const args = process.argv.slice(2);
const allValuesOf = (f) =>
  args.reduce((out, a, i) => (a === f && args[i + 1] ? [...out, args[i + 1]] : out), []);
const FILES = allValuesOf('--file');

const expand = (p) => resolve(p.startsWith('~') ? join(homedir(), p.slice(1)) : p);
const withCommas = (n) => n.toLocaleString('en-GB');
const mib = (b) => `${(b / 1024 / 1024).toFixed(1)} MiB`;
const kib = (b) => `${(b / 1024).toFixed(0)} KiB`;

if (!FILES.length) {
  console.error('\n  --file <path>   the timetable and reference files, or a folder holding them.\n');
  process.exit(1);
}

const paths = [];
for (const raw of FILES) {
  const p = expand(raw);
  const st = statSync(p);
  if (st.isDirectory()) paths.push(...readdirSync(p).filter((n) => /\.(xml|gz)$/i.test(n)).map((n) => join(p, n)));
  else paths.push(p);
}
const metas = paths.map((p) => ({ path: p, meta: parseDarwinKey(p) })).filter((x) => x.meta);
const pick = (kind) => {
  const best = pickBest(metas.map((m) => m.meta), kind);
  return best ? metas.find((m) => m.meta.name === best.name).path : null;
};
let timetablePath = pick('timetable');
let referencePath = pick('reference');
for (const p of paths) {
  if (timetablePath && referencePath) break;
  const { rootTag } = await scanFile(p, {});
  if (rootTag === 'PportTimetable') timetablePath ??= p;
  if (rootTag === 'PportTimetableRef') referencePath ??= p;
}
if (!timetablePath || !referencePath) {
  console.error('\n  Need one timetable (_vN) and one reference (_ref_vN).\n');
  process.exit(1);
}

/* -------------------------------------------------------------- build it */

console.log(`\n  ${timetablePath.split('/').pop()}`);
const { locations } = await parseReference(referencePath);
const builder = buildBoards();
const journeysByDay = new Map();

const started = Date.now();
await parseTimetable(timetablePath, {
  locations,
  onJourney(journey) {
    builder.add(journey);
    if (!journeysByDay.has(journey.serviceDate)) journeysByDay.set(journey.serviceDate, []);
    journeysByDay.get(journey.serviceDate).push(journey);
  },
});
const boards = builder.finish();
console.log(`  ${withCommas(boards.size)} boards built in ${((Date.now() - started) / 1000).toFixed(1)}s\n`);

/* ------------------------------------------------------- prove it decodes */

/**
 * A packed board that cannot be read back is worthless, and the failure would
 * not show until stage 3. Check the whole corpus, not a sample: the encoding is
 * fixed-width, so the only way it breaks is a field that is not the width it was
 * assumed to be, and that will be one board out of eight thousand.
 */
let checked = 0;
for (const board of boards.values()) {
  const back = unpackBoard(packBoard(board.departures));
  if (back.length !== board.departures.length) throw new Error(`departure count lost at ${board.crs}`);
  for (let i = 0; i < back.length; i += 1) {
    const a = board.departures[i], b = back[i];
    if (a.dep !== b.dep || a.rid !== b.rid || a.destination !== b.destination) {
      throw new Error(`round trip changed a departure at ${board.crs} ${a.rid}`);
    }
    if (a.onward.length !== b.onward.length) throw new Error(`onward calls lost at ${board.crs} ${a.rid}`);
    for (let k = 0; k < a.onward.length; k += 1) {
      if (a.onward[k].crs !== b.onward[k].crs || a.onward[k].arr !== b.onward[k].arr
          || a.onward[k].canAlight !== b.onward[k].canAlight) {
        throw new Error(`onward call changed at ${board.crs} ${a.rid}`);
      }
    }
  }
  checked += 1;
}
console.log(`  packed encoding round-trips exactly, all ${withCommas(checked)} boards\n`);

/* ---------------------------------------------------------------- weigh it */

const byDay = new Map();
let rows = 0;
for (const board of boards.values()) {
  const day = board.serviceDate;
  if (!byDay.has(day)) byDay.set(day, { boards: 0, departures: 0, rows: 0, verbose: 0, compact: 0, packed: 0, packedGz: 0, largest: null });
  const d = byDay.get(day);
  const packed = packBoard(board.departures);
  const packedGz = gzipSync(packed).length;
  const onward = board.departures.reduce((n, x) => n + x.onward.length, 0);
  d.boards += 1;
  d.departures += board.departures.length;
  d.rows += onward;
  rows += onward;
  d.verbose += Buffer.byteLength(encodeVerbose(board));
  d.compact += Buffer.byteLength(encodeCompactJson(board));
  d.packed += Buffer.byteLength(packed);
  d.packedGz += packedGz;
  if (!d.largest || Buffer.byteLength(packed) > d.largest.bytes) {
    d.largest = { crs: board.crs, departures: board.departures.length, rows: onward, bytes: Buffer.byteLength(packed), gz: packedGz };
  }
}

console.log(`  PER-STATION BOARD, by service day   (${withCommas(rows)} rows in total)\n`);
for (const [day, d] of [...byDay.entries()].sort()) {
  console.log(`  ${day}   ${withCommas(d.boards)} stations, ${withCommas(d.departures)} departures, ${withCommas(d.rows)} rows`);
  console.log(`      verbose JSON   ${mib(d.verbose).padStart(9)}`);
  console.log(`      compact JSON   ${mib(d.compact).padStart(9)}`);
  console.log(`      packed         ${mib(d.packed).padStart(9)}`);
  console.log(`      packed + gzip  ${mib(d.packedGz).padStart(9)}`);
  console.log(`      largest board  ${d.largest.crs}, ${withCommas(d.largest.departures)} departures, ${kib(d.largest.bytes)} packed, ${kib(d.largest.gz)} gzipped`);
  console.log();
}

/* ------------------------------------------------- the fallback, for contrast */

console.log('  FALLBACK SHAPE: one record per journey, plus a per-station index\n');
for (const [day, journeys] of [...journeysByDay.entries()].sort()) {
  const { records, index } = encodeJourneyShape(journeys);
  const recordBytes = records.reduce((n, r) => n + Buffer.byteLength(r), 0);
  const indexBytes = [...index.values()].reduce((n, list) => n + Buffer.byteLength(list.join('')), 0);
  const total = recordBytes + indexBytes;
  console.log(`  ${day}   ${withCommas(journeys.length)} journeys`);
  console.log(`      journey records ${mib(recordBytes).padStart(9)}   ${withCommas(records.length)} keys`);
  console.log(`      station index   ${mib(indexBytes).padStart(9)}   ${withCommas(index.size)} keys`);
  console.log(`      total           ${mib(total).padStart(9)}   gzipped ${mib(gzipSync(records.join('\n') + [...index.values()].map(l=>l.join('')).join('\n')).length)}`);
  console.log();
}

/* ------------------------------------------------------------- the verdict */

const days = [...byDay.entries()].sort();
const full = days.filter(([, d]) => d.departures > 100_000);
const perDayPacked = full.length ? full.reduce((n, [, d]) => n + d.packed, 0) / full.length : 0;
const perDayGz = full.length ? full.reduce((n, [, d]) => n + d.packedGz, 0) / full.length : 0;
const biggest = days.reduce((b, [, d]) => (!b || d.largest.bytes > b.bytes ? d.largest : b), null);

console.log('  WHAT THIS MEANS FOR STAGE 3\n');
console.log(`    A full service day, packed          ${mib(perDayPacked)}`);
console.log(`    A full service day, packed + gzip   ${mib(perDayGz)}`);
console.log(`    Holding two days at once            ${mib(perDayPacked * 2)}  (${mib(perDayGz * 2)} gzipped)`);
console.log(`    Keys per day                        ~${withCommas(Math.round(days.reduce((n,[,d])=>Math.max(n,d.boards),0)))}`);
console.log(`    Largest single value                ${kib(biggest.bytes)}  (${kib(biggest.gz)} gzipped)  at ${biggest.crs}`);
console.log();
console.log('    Upstash free tier is 256 MiB of storage and a 1 MiB limit per');
console.log('    request. Both numbers above are what to check against it.');
console.log();
