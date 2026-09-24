#!/usr/bin/env node
/**
 * Darwin timetable ingest, stage 3: publish boards to the shared store.
 *
 * `DARWIN-INGEST.md` §3 stage 3. The write half. `lib/timetable.ts` is the read
 * half and the two share `lib/timetablePacking.ts`, so the format has one
 * definition and `npm test` owns it.
 *
 * Four things this gets right on purpose:
 *
 *   1. **A snapshot is switched on in one write.** Its boards go under its own
 *      id, beside the snapshot the app is reading, and are counted back. Only
 *      then does meta move to name them. A run that dies half way leaves the old
 *      snapshot whole and in use; a reader never sees two snapshots mixed
 *      (`SERVER-AUDIT.md` finding 2). The old snapshot is then set to expire in
 *      two hours, long enough for a request already reading it to finish.
 *   2. **Every board expires.** A board is rewritten by each day's run, so a
 *      time to live costs nothing while the job is healthy — and empties the
 *      store within three days if the job stops. A store that empties says so;
 *      one that keeps serving four-day-old boards does not.
 *   3. **Re-running is safe.** Same file in, same keys out, same values. A retry
 *      after a network failure is just the same work again.
 *   4. **Each day has an index** of the stations with a board, so the app can tell
 *      a station with no trains from a board that has gone missing.
 *
 * Run:  node scripts/darwin-publish.mjs --file ~/Downloads
 *       node scripts/darwin-publish.mjs --bucket            (what the daily job runs)
 *       node scripts/darwin-publish.mjs --bucket --dry-run
 */

import { statSync } from 'node:fs';

import { Redis } from '@upstash/redis';

import { loadEnvLocal } from './lib/rtt.mjs';
import { parseDarwinKey } from './lib/darwin-scan.mjs';
import { choosePair, fetchFromBucket, localPaths } from './lib/darwin-source.mjs';
import { parseReference, parseTimetable } from './lib/darwin-parse.mjs';
import { buildBoards } from './lib/darwin-board.mjs';
import { boardKey, indexKey, META_KEY, packBoard, packIndex } from '../lib/timetablePacking.ts';

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

/**
 * How long the snapshot being replaced lives on once the new one is switched on.
 *
 * A request that read the old meta a moment ago still reads the old boards; two hours is
 * far longer than any request, and short enough that two snapshots are held side by side
 * for only a little of each day.
 */
const RETIRE_SECONDS = 2 * 60 * 60;

/** Keys per `EXISTS` when counting the new snapshot back. */
const EXISTS_CHUNK = 500;

/** Roughly how many bytes to put in one pipelined round trip. */
const BATCH_BYTES = 400_000;

const args = process.argv.slice(2);
const has = (f) => args.includes(f);
const allValuesOf = (f) =>
  args.reduce((out, a, i) => (a === f && args[i + 1] ? [...out, args[i + 1]] : out), []);

const FILES = allValuesOf('--file');
const FROM_BUCKET = has('--bucket');
const DRY_RUN = has('--dry-run');

const withCommas = (n) => n.toLocaleString('en-GB');
const mib = (b) => `${(b / 1024 / 1024).toFixed(1)} MiB`;

function fail(lines) {
  console.error(`\n  ${[].concat(lines).join('\n  ')}\n`);
  process.exit(1);
}

if (!FILES.length && !FROM_BUCKET) {
  fail([
    'Nothing to publish. Choose a source.',
    '',
    '  --file <path>   files or a folder on this machine.',
    '  --bucket        the delivery bucket. What the daily job uses; needs',
    '                  DARWIN_S3_BUCKET and credentials.',
  ]);
}

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

let timetablePath;
let referencePath;
let cleanup = () => {};

if (FROM_BUCKET) {
  let fetched;
  try {
    fetched = await fetchFromBucket();
  } catch (error) {
    fail([error.message, '', 'To publish from files on this machine instead, use --file.']);
  }
  timetablePath = fetched.timetable;
  referencePath = fetched.reference;
  cleanup = fetched.cleanup;
  console.log(`\n  bucket   ${fetched.objects} objects, newest publish ${fetched.stamp}`);
  for (const d of fetched.downloaded) console.log(`    ${mib(d.bytes).padStart(9)}  ${d.key}`);
} else {
  const paths = localPaths(FILES);
  const pair = await choosePair(paths);
  timetablePath = pair.timetable;
  referencePath = pair.reference;
  if (!timetablePath) fail('No timetable file found. That is the large one, named _vN.');
  if (!referencePath) {
    fail([
      'No reference file found. That is the small one, named _ref_vN.',
      '',
      'The timetable speaks TIPLOC and this app is keyed by CRS. Without the',
      'reference file there is no mapping between them.',
    ]);
  }
}

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
  keyed: 'snapshot',
  departuresByDate: Object.fromEntries(
    serviceDates.map((date) => [
      date,
      [...boards.values()].filter((b) => b.serviceDate === date).reduce((n, b) => n + b.departures.length, 0),
    ])
  ),
};

const payloads = [...boards.values()].map((board) => ({
  key: boardKey(board.crs, board.serviceDate, meta.timetableId),
  value: packBoard(board.departures),
}));

// One index per day: the stations with a board. Written with the boards, before meta.
const indexes = serviceDates.map((date) => ({
  key: indexKey(meta.timetableId, date),
  value: packIndex([...boards.values()].filter((b) => b.serviceDate === date).map((b) => b.crs)),
}));
const totalBytes = payloads.reduce((n, p) => n + Buffer.byteLength(p.value), 0);
const largest = payloads.reduce((a, b) => (Buffer.byteLength(b.value) > Buffer.byteLength(a.value) ? b : a));

console.log(`\n  ${withCommas(boards.size)} boards, ${withCommas(departures)} departures, ${mib(totalBytes)}`);
console.log(`  service days ${serviceDates.join(', ')}`);
console.log(`  generated ${generatedAt}, timetable id ${meta.timetableId}`);
console.log(`  largest value ${(Buffer.byteLength(largest.value) / 1024).toFixed(0)} KiB at ${largest.key}`);
console.log(`  built in ${((Date.now() - started) / 1000).toFixed(1)}s`);

if (DRY_RUN || !url || !token) {
  cleanup();
  console.log(
    `\n  --dry-run: nothing written. Would set ${withCommas(payloads.length + indexes.length + 1)} keys, ttl ${TTL_SECONDS / 3600}h.\n`
  );
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
  process.stdout.write(`\r  written ${withCommas(written)} / ${withCommas(payloads.length + indexes.length)} keys`);
  batch = redis.pipeline();
  batchBytes = 0;
  batchCount = 0;
}

// The snapshot the app reads now, so it can be retired once the new one is on.
const previous = await redis.get(META_KEY);

console.log();
for (const { key, value } of [...payloads, ...indexes]) {
  batch.set(key, value, { ex: TTL_SECONDS });
  batchBytes += Buffer.byteLength(value);
  batchCount += 1;
  if (batchBytes >= BATCH_BYTES) await flush();
}
await flush();

// Counted back before anything names it. A pipeline that failed part way has thrown by
// now, but one that dropped writes silently has not, and this is what catches that.
const writtenKeys = [...payloads, ...indexes].map((p) => p.key);
let present = 0;
for (let i = 0; i < writtenKeys.length; i += EXISTS_CHUNK) {
  present += await redis.exists(...writtenKeys.slice(i, i + EXISTS_CHUNK));
}
if (present !== writtenKeys.length) {
  cleanup();
  fail([
    `Only ${withCommas(present)} of ${withCommas(writtenKeys.length)} keys are in the store.`,
    '',
    'Meta has not been changed, so the app is still reading the previous snapshot,',
    'whole. Re-run the job; the publish is idempotent.',
  ]);
}

// Last, and only now. Everything above is in place and counted, so this one write is the
// moment the snapshot becomes the one the app reads.
await redis.set(META_KEY, meta, { ex: TTL_SECONDS });

// Retire the snapshot that was in use. Not deleted: a request that read the old meta a
// moment ago is still reading its boards. A snapshot from before snapshot keys shares no
// names with this one and expires on its own TTL.
let retired = 0;
if (previous?.keyed === 'snapshot' && previous.timetableId !== meta.timetableId) {
  let retire = redis.pipeline();
  let queued = 0;
  const send = async () => {
    if (queued) await retire.exec();
    retire = redis.pipeline();
    queued = 0;
  };
  for (const date of previous.serviceDates ?? []) {
    const listed = (await redis.get(indexKey(previous.timetableId, date))) ?? '';
    for (const crs of String(listed).split(',').filter(Boolean)) {
      retire.expire(boardKey(crs, date, previous.timetableId), RETIRE_SECONDS);
      retired += 1;
      if (++queued >= 1000) await send();
    }
    retire.expire(indexKey(previous.timetableId, date), RETIRE_SECONDS);
    queued += 1;
  }
  await send();
}

// For the workflow's check that the store now names exactly this snapshot.
if (process.env.GITHUB_OUTPUT) {
  const { appendFileSync } = await import('node:fs');
  appendFileSync(process.env.GITHUB_OUTPUT, `timetable_id=${meta.timetableId}\n`);
}

cleanup();
console.log(`\n\n  published ${meta.timetableId}. ${withCommas(written)} keys + meta, ttl ${TTL_SECONDS / 3600}h.`);
if (retired) console.log(`  retired ${previous.timetableId}: ${withCommas(retired)} boards expire in ${RETIRE_SECONDS / 3600}h.`);
console.log();
