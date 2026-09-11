#!/usr/bin/env node
/**
 * Darwin timetable ingest, stage 3: publish boards to the shared store.
 *
 * `DARWIN-INGEST.md` §3 stage 3. The write half. `lib/timetable.ts` is the read
 * half and the two share `lib/timetablePacking.ts`, so the format has one
 * definition and `npm test` owns it.
 *
 * Three things this gets right on purpose:
 *
 *   1. **Meta is written last.** It names the snapshot the app is reading. Write
 *      it first and a run that dies halfway advertises a complete snapshot over
 *      a half-written one, which is worse than no snapshot at all.
 *   2. **Every board expires.** A board is rewritten by each day's run, so a
 *      time to live costs nothing while the job is healthy — and empties the
 *      store within three days if the job stops. A store that empties says so;
 *      one that keeps serving four-day-old boards does not.
 *   3. **Re-running is safe.** Same file in, same keys out, same values. A retry
 *      after a network failure is just the same work again.
 *
 * Run:  node scripts/darwin-publish.mjs --file ~/Downloads
 *       node scripts/darwin-publish.mjs --file ~/Downloads --dry-run
 */

import { readdirSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';

import { Redis } from '@upstash/redis';

import { loadEnvLocal } from './lib/rtt.mjs';
import { parseDarwinKey, pickBest, scanFile } from './lib/darwin-scan.mjs';
import { parseReference, parseTimetable } from './lib/darwin-parse.mjs';
import { buildBoards } from './lib/darwin-board.mjs';
import { boardKey, META_KEY, packBoard } from '../lib/timetablePacking.ts';

loadEnvLocal();

/**
 * How long a board lives.
 *
 * Three days: longer than the gap between publishes, shorter than the point at
 * which a board becomes a lie. It is the backstop under the staleness check in
 * `lib/timetable.ts`, not a replacement for it — that reports an old snapshot
 * within thirty hours, while this eventually removes it.
 */
const TTL_SECONDS = 72 * 60 * 60;

/** Roughly how many bytes to put in one pipelined round trip. */
const BATCH_BYTES = 400_000;

const args = process.argv.slice(2);
const has = (f) => args.includes(f);
const allValuesOf = (f) =>
  args.reduce((out, a, i) => (a === f && args[i + 1] ? [...out, args[i + 1]] : out), []);

const FILES = allValuesOf('--file');
const DRY_RUN = has('--dry-run');

const expand = (p) => resolve(p.startsWith('~') ? join(homedir(), p.slice(1)) : p);
const withCommas = (n) => n.toLocaleString('en-GB');
const mib = (b) => `${(b / 1024 / 1024).toFixed(1)} MiB`;

function fail(lines) {
  console.error(`\n  ${[].concat(lines).join('\n  ')}\n`);
  process.exit(1);
}

if (!FILES.length) fail('--file <path>   the timetable and reference files, or a folder holding them.');

/* ------------------------------------------------------------ credentials */

const url = process.env.KV_REST_API_URL?.trim() || process.env.UPSTASH_REDIS_REST_URL?.trim();
const token = process.env.KV_REST_API_TOKEN?.trim() || process.env.UPSTASH_REDIS_REST_TOKEN?.trim();

if (!url || !token) {
  if (!DRY_RUN) {
    fail([
      'No shared store configured.',
      '',
      'Set KV_REST_API_URL and KV_REST_API_TOKEN in .env.local. The deployment',
      'already has them, so the quickest way to get them locally is:',
      '',
      '  vercel env pull .env.local',
      '',
      'Or use --dry-run to see exactly what would be written without writing it.',
    ]);
  }
  console.log('\n  no store configured; --dry-run reports what would be written');
}

/* ------------------------------------------------------------- find files */

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
if (!timetablePath || !referencePath) fail('Need one timetable (_vN) and one reference (_ref_vN).');

const timetableStamp = parseDarwinKey(timetablePath)?.stamp ?? null;
const referenceStamp = parseDarwinKey(referencePath)?.stamp ?? null;
if (timetableStamp && referenceStamp && timetableStamp !== referenceStamp) {
  fail([
    'The timetable and reference files are from different publishes.',
    `  timetable ${timetableStamp}`,
    `  reference ${referenceStamp}`,
    '',
    'A warning would do for a measurement run. This one writes what the app',
    'serves, so it refuses: TIPLOCs would resolve against the wrong day and a',
    'station that opened in between would simply be missing.',
  ]);
}

/* ------------------------------------------------------------------ build */

console.log(`\n  timetable  ${timetablePath.split('/').pop()}`);
console.log(`  reference  ${referencePath.split('/').pop()}`);

const { locations, operators } = await parseReference(referencePath);
const builder = buildBoards();
let stats;
const started = Date.now();
stats = await parseTimetable(timetablePath, { locations, onJourney: (j) => builder.add(j) });
const boards = builder.finish();

const serviceDates = [...new Set([...boards.values()].map((b) => b.serviceDate))].sort();
let departures = 0;
for (const b of boards.values()) departures += b.departures.length;

/**
 * Darwin's stamp, `20260910020536`, as the London instant it is.
 *
 * Stored so `lib/timetable.ts` can age the snapshot against when Darwin made
 * the file rather than when this ran — a job cycling happily against a feed
 * that stopped delivering would otherwise look fresh for ever.
 */
const generatedAt = timetableStamp
  ? `${timetableStamp.slice(0, 4)}-${timetableStamp.slice(4, 6)}-${timetableStamp.slice(6, 8)}T${timetableStamp.slice(8, 10)}:${timetableStamp.slice(10, 12)}:${timetableStamp.slice(12, 14)}`
  : new Date().toISOString().slice(0, 19);

const meta = {
  timetableId: stats.timetableId ?? timetableStamp ?? 'unknown',
  generatedAt,
  publishedAt: new Date().toISOString(),
  serviceDates,
  boardCount: boards.size,
  departureCount: departures,
  operators: Object.fromEntries(operators),
};

const payloads = [...boards.values()].map((board) => ({
  key: boardKey(board.crs, board.serviceDate),
  value: packBoard(board.departures),
}));
const totalBytes = payloads.reduce((n, p) => n + Buffer.byteLength(p.value), 0);
const largest = payloads.reduce((a, b) => (Buffer.byteLength(b.value) > Buffer.byteLength(a.value) ? b : a));

console.log(`\n  ${withCommas(boards.size)} boards, ${withCommas(departures)} departures, ${mib(totalBytes)}`);
console.log(`  service days ${serviceDates.join(', ')}`);
console.log(`  generated ${generatedAt}, timetable id ${meta.timetableId}`);
console.log(`  largest value ${(Buffer.byteLength(largest.value) / 1024).toFixed(0)} KiB at ${largest.key}`);
console.log(`  built in ${((Date.now() - started) / 1000).toFixed(1)}s`);

if (DRY_RUN || !url || !token) {
  console.log(`\n  --dry-run: nothing written. Would set ${withCommas(payloads.length + 1)} keys, ttl ${TTL_SECONDS / 3600}h.\n`);
  process.exit(0);
}

/* ---------------------------------------------------------------- publish */

const redis = new Redis({ url, token });

let written = 0;
let batch = redis.pipeline();
let batchBytes = 0;
let batchCount = 0;

async function flush() {
  if (!batchCount) return;
  await batch.exec();
  written += batchCount;
  process.stdout.write(`\r  written ${withCommas(written)} / ${withCommas(payloads.length)} boards`);
  batch = redis.pipeline();
  batchBytes = 0;
  batchCount = 0;
}

console.log();
for (const { key, value } of payloads) {
  batch.set(key, value, { ex: TTL_SECONDS });
  batchBytes += Buffer.byteLength(value);
  batchCount += 1;
  if (batchBytes >= BATCH_BYTES) await flush();
}
await flush();

// Last, and only now. Everything above is in place, so this is the moment the
// snapshot becomes the one the app reads.
await redis.set(META_KEY, meta, { ex: TTL_SECONDS });

console.log(`\n\n  published. ${withCommas(written)} boards + meta, ttl ${TTL_SECONDS / 3600}h.\n`);
