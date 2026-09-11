#!/usr/bin/env node
/**
 * Darwin timetable ingest, stage 0: prove the file and measure it.
 *
 * `DARWIN-INGEST.md` §3 stage 0. This exists to answer the questions the storage
 * design rests on, with real numbers rather than guesses:
 *
 *   - How big is the file, compressed and not?
 *   - How many journeys, and how many *public* calling points?
 *   - What window does it cover, against the 03:00-02:59 service day?
 *   - How often is a new one published?
 *
 * It is a probe, not the ingest. It counts by scanning the byte stream; it does
 * not build a document tree and it produces nothing the app reads. Stage 1 is
 * where a real streaming parser arrives.
 *
 * **Two ways in, because Rail Data Marketplace pushes rather than serves.** RDM
 * file products are delivered to a destination you own -- your own S3 or GCS
 * bucket, Azure blob, or an SFTP server -- so there is no marketplace bucket to
 * pull from. Until a destination is set up, the Data files tab on the product
 * page gives the same file by hand, which is all stage 0 needs.
 *
 *   --file    scan files already on disk. No credentials, no cloud account.
 *   --bucket  scan the delivery bucket, once RDM is pushing into one of ours.
 *
 * Downloads land in the system temp directory, never in the repo. The repo is
 * inside iCloud Drive, and a large file written there is how the file provider
 * wedges and the next build hangs.
 *
 * Run:  node scripts/darwin-probe.mjs --file ~/Downloads
 *       node scripts/darwin-probe.mjs --file a.xml.gz --file b.xml.gz
 *       node scripts/darwin-probe.mjs --bucket
 *       node scripts/darwin-probe.mjs --bucket --list-only
 *       node scripts/darwin-probe.mjs --file ~/Downloads --all
 */

import { createWriteStream, mkdirSync, statSync, rmSync, readdirSync } from 'node:fs';
import { pipeline } from 'node:stream/promises';
import { tmpdir, homedir } from 'node:os';
import { join, resolve } from 'node:path';

import { loadEnvLocal } from './lib/rtt.mjs';
import { PATTERNS, kindOfRoot, parseDarwinKey, pickBest, scanFile } from './lib/darwin-scan.mjs';

loadEnvLocal();

const args = process.argv.slice(2);
const has = (flag) => args.includes(flag);
const allValuesOf = (flag) =>
  args.reduce((out, a, i) => (a === flag && args[i + 1] ? [...out, args[i + 1]] : out), []);
const valueOf = (flag) => allValuesOf(flag)[0] ?? null;

const FILES = allValuesOf('--file');
const BUCKET_MODE = has('--bucket');
const LIST_ONLY = has('--list-only');
const KEEP = has('--keep');
const ALL = has('--all');
const OUT = valueOf('--out') || join(tmpdir(), 'darwin-timetable');

/**
 * The bucket RDM delivers into, which is ours, not Darwin's.
 *
 * No default. Under the marketplace's transfer model the bucket is one we
 * created and named, so a guessed default could only ever be wrong -- and wrong
 * in a way that reads like a permissions problem.
 */
const BUCKET = process.env.DARWIN_S3_BUCKET?.trim();
const PREFIX = process.env.DARWIN_S3_PREFIX?.trim() ?? '';
const REGION = process.env.DARWIN_S3_REGION?.trim() || 'eu-west-2';
const ACCESS_KEY = process.env.DARWIN_S3_ACCESS_KEY?.trim();
const SECRET_KEY = process.env.DARWIN_S3_SECRET_KEY?.trim();

const mib = (bytes) => `${(bytes / 1024 / 1024).toFixed(1)} MiB`;
const withCommas = (n) => n.toLocaleString('en-GB');
const expand = (p) => resolve(p.startsWith('~') ? join(homedir(), p.slice(1)) : p);

function fail(lines) {
  console.error(`\n  ${[].concat(lines).join('\n  ')}\n`);
  process.exit(1);
}

const USAGE = [
  'Nothing to measure. Choose a source.',
  '',
  '  --file <path>    one or more files, or a folder holding them.',
  '                   Get them from the product page on raildata.org.uk:',
  '                   My subscriptions -> the Darwin timetable product ->',
  '                   Data files tab -> download. This needs no cloud account',
  '                   and is all stage 0 requires.',
  '',
  '  --bucket         read the bucket RDM delivers into. Needs DARWIN_S3_BUCKET',
  '                   and credentials in .env.local. See .env.example.',
];

if (!FILES.length && !BUCKET_MODE) fail(USAGE);

/* ---------------------------------------------------------------- sources */

/** Files named on the command line, expanding any folder among them one level. */
function localPaths() {
  const out = [];
  for (const raw of FILES) {
    const path = expand(raw);
    let stat;
    try {
      stat = statSync(path);
    } catch {
      fail(`No such file: ${path}`);
    }
    if (stat.isDirectory()) {
      const found = readdirSync(path)
        .filter((n) => /\.(xml|gz)$/i.test(n))
        .map((n) => join(path, n));
      if (!found.length) fail(`No .xml or .xml.gz files in ${path}`);
      out.push(...found);
    } else {
      out.push(path);
    }
  }
  return ALL ? out : narrowToBestPair(out);
}

/**
 * One timetable and one reference, out of however many were downloaded.
 *
 * Darwin publishes each day at several schema versions at once, so a folder can
 * hold five files describing one publish. Scanning all of them measures the same
 * data repeatedly and leaves the sizing figures resting on whichever happened to
 * be scanned last.
 *
 * A file whose name does not parse is kept rather than dropped: it was probably
 * renamed on the way out of a browser, and its kind is read from its root
 * element later anyway.
 */
function narrowToBestPair(paths) {
  const parsed = paths.map((path) => ({ path, meta: parseDarwinKey(path) }));
  const named = parsed.filter((p) => p.meta);
  if (named.length < 2) return paths;

  const metas = named.map((p) => p.meta);
  const best = [pickBest(metas, 'timetable'), pickBest(metas, 'reference')].filter(Boolean);
  const bestNames = new Set(best.map((m) => m.name));

  const kept = parsed.filter((p) => !p.meta || bestNames.has(p.meta.name));
  const skipped = named.filter((p) => !bestNames.has(p.meta.name));
  if (skipped.length) {
    console.log(`\n  ${skipped.length} older or lower-schema file${skipped.length === 1 ? '' : 's'} skipped:`);
    for (const p of skipped) console.log(`    ${p.meta.name}`);
    console.log('    --all to measure every one of them.');
  }
  return kept.map((p) => p.path);
}

/**
 * The delivery bucket.
 *
 * The spread of LastModified across the objects *is* the publish cadence,
 * measured rather than assumed, without watching a folder for a day.
 */
async function bucketPaths() {
  if (!BUCKET) {
    fail([
      'DARWIN_S3_BUCKET is not set.',
      '',
      'Under the marketplace transfer model this is a bucket you own and RDM',
      'writes into, not one of Darwin\'s. Set it up on the product page:',
      'Data files tab -> File transfers -> Add a new destination. See',
      'DARWIN-INGEST.md §3 stage 7.',
      '',
      'To measure the file today without any of that, use --file instead.',
    ]);
  }
  if (!ACCESS_KEY || !SECRET_KEY) {
    fail([
      'No credentials for the delivery bucket.',
      '',
      'Set DARWIN_S3_ACCESS_KEY and DARWIN_S3_SECRET_KEY in .env.local. These',
      'are the keys of an IAM user that can read your own bucket. See',
      '.env.example.',
      '',
      'To measure the file today without any of that, use --file instead.',
    ]);
  }

  let S3Client, ListObjectsV2Command, GetObjectCommand;
  try {
    ({ S3Client, ListObjectsV2Command, GetObjectCommand } = await import('@aws-sdk/client-s3'));
  } catch {
    fail('Missing @aws-sdk/client-s3. Run: npm install');
  }

  const s3 = new S3Client({
    region: REGION,
    credentials: { accessKeyId: ACCESS_KEY, secretAccessKey: SECRET_KEY },
  });

  console.log(`\n  bucket   s3://${BUCKET}/${PREFIX}`);
  console.log(`  region   ${REGION}`);

  const objects = [];
  try {
    let token;
    do {
      const page = await s3.send(
        new ListObjectsV2Command({
          Bucket: BUCKET,
          Prefix: PREFIX || undefined,
          ContinuationToken: token,
        })
      );
      for (const o of page.Contents ?? []) objects.push(o);
      token = page.IsTruncated ? page.NextContinuationToken : undefined;
    } while (token);
  } catch (error) {
    fail([
      `Listing failed: ${error.name} -- ${error.message}`,
      '',
      error.name === 'PermanentRedirect'
        ? 'The bucket is in another region. Set DARWIN_S3_REGION.'
        : 'Check DARWIN_S3_BUCKET, and that the IAM user may s3:ListBucket on it.',
    ]);
  }

  if (!objects.length) {
    fail([
      `Nothing under s3://${BUCKET}/${PREFIX}`,
      '',
      'If the transfer was only just set up, RDM writes on the next publish',
      'rather than backfilling. A new *version* of the product also has to be',
      'linked to the destination again, which is the quiet way transfers stop.',
    ]);
  }

  const sized = new Map(objects.map((o) => [o.Key, o.Size]));
  const parsed = objects.map((o) => parseDarwinKey(o.Key)).filter(Boolean);
  const stamps = [...new Set(parsed.map((p) => p.stamp))].sort();
  const other = objects.length - parsed.length;

  console.log(`\n  objects  ${objects.length}`);
  console.log(`    publishes            ${stamps.length}`);
  console.log(`    timetable (_vN)      ${parsed.filter((p) => p.kind === 'timetable').length}`);
  console.log(`    reference (_ref_vN)  ${parsed.filter((p) => p.kind === 'reference').length}`);
  if (other) console.log(`    unrecognised         ${other}`);

  /**
   * Cadence is measured between *publishes*, not between files.
   *
   * Every file of one publish carries the same generation stamp and is delivered
   * together, so counting gaps per file would report a run of zeroes and then
   * one real interval.
   */
  const times = stamps.map((t) =>
    Date.parse(`${t.slice(0, 4)}-${t.slice(4, 6)}-${t.slice(6, 8)}T${t.slice(8, 10)}:${t.slice(10, 12)}:${t.slice(12, 14)}Z`)
  );
  const gaps = times.slice(1).map((t, i) => (t - times[i]) / 3_600_000).sort((a, b) => a - b);
  if (gaps.length) {
    console.log(`\n  publish cadence, from ${gaps.length} gap${gaps.length === 1 ? '' : 's'} between publishes`);
    console.log(`    shortest  ${gaps[0].toFixed(1)} h`);
    console.log(`    median    ${gaps[Math.floor(gaps.length / 2)].toFixed(1)} h`);
    console.log(`    longest   ${gaps[gaps.length - 1].toFixed(1)} h`);
  }

  const wanted = [pickBest(parsed, 'timetable'), pickBest(parsed, 'reference')].filter(Boolean);
  console.log('\n  newest publish, highest schema version');
  for (const m of wanted) {
    console.log(`    ${m.key}`);
    console.log(`      ${mib(sized.get(m.key) ?? 0)}  schema v${m.version}`);
  }

  if (LIST_ONLY) {
    console.log('\n  --list-only: stopping before download.\n');
    process.exit(0);
  }

  mkdirSync(OUT, { recursive: true });
  console.log(`\n  downloading to ${OUT}`);
  const paths = [];
  for (const m of wanted) {
    const path = join(OUT, m.name);
    const body = (await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: m.key }))).Body;
    await pipeline(body, createWriteStream(path));
    paths.push(path);
    console.log(`    ${mib(statSync(path).size)}  ${path.split('/').pop()}`);
  }
  return paths;
}

/* ---------------------------------------------------------------- report */

function reportTimetable(name, compressed, r) {
  const c = r.counts;
  const publicCalls = c.publicDepartures + c.publicArrivals;
  const allStops = c.origins + c.intermediates + c.passingPoints + c.destinations;
  const publicStops =
    c.publicOriginStops + c.publicIntermediateStops + c.publicDestinationStops + c.publicPassingStops;

  console.log(`\n  TIMETABLE  ${name}`);
  console.log(`    root element        ${r.rootTag}`);
  console.log(`    on disk             ${mib(compressed)}`);
  console.log(`    uncompressed        ${mib(r.bytes)}   (x${(r.bytes / compressed).toFixed(1)})`);
  console.log(`    journeys            ${withCommas(c.journeys)}`);
  console.log(`    stops, all kinds    ${withCommas(allStops)}`);
  console.log(`      origin            ${withCommas(c.origins)}`);
  console.log(`      intermediate      ${withCommas(c.intermediates)}`);
  console.log(`      passing           ${withCommas(c.passingPoints)}   <- dropped: no public time`);
  console.log(`      destination       ${withCommas(c.destinations)}`);
  console.log(`    public times        ${withCommas(publicCalls)}   (ptd ${withCommas(c.publicDepartures)} / pta ${withCommas(c.publicArrivals)})`);
  console.log(`    PUBLIC CALLS        ${withCommas(publicStops)}   <- stops the app can show`);
  console.log(`      origin            ${withCommas(c.publicOriginStops)}`);
  console.log(`      intermediate      ${withCommas(c.publicIntermediateStops)}`);
  console.log(`      destination       ${withCommas(c.publicDestinationStops)}`);
  if (c.publicPassingStops) {
    console.log(`      passing           ${withCommas(c.publicPassingStops)}   <- a PP with a public time; check this`);
  }
  console.log(`    dropped as private  ${withCommas(allStops - publicStops)}   (${((1 - publicStops / allStops) * 100).toFixed(0)}% of all stops)`);
  console.log(`    with a platform     ${withCommas(c.platforms)}`);
  console.log(`    cancelled flags     ${withCommas(c.cancelled)}   (cancelReason ${withCommas(c.cancelReasons)})`);
  console.log(`    associations        ${withCommas(c.associations)}`);
  console.log(
    `    service dates       ${
      r.dates.length
        ? `${r.dates[0]} .. ${r.dates.at(-1)}  (${r.dates.length})`
        : 'none found -- check the ssd attribute name'
    }`
  );
  return { journeys: c.journeys, publicStops };
}

function reportReference(name, compressed, r) {
  const c = r.counts;
  console.log(`\n  REFERENCE  ${name}`);
  console.log(`    root element        ${r.rootTag}`);
  console.log(`    on disk             ${mib(compressed)}`);
  console.log(`    uncompressed        ${mib(r.bytes)}`);
  console.log(`    locations           ${withCommas(c.locations)}`);
  console.log(`    with a CRS          ${withCommas(c.withCrs)}   <- the only ones this app can key`);
  console.log(`    operators           ${withCommas(c.operators)}`);
}

/* ---------------------------------------------------------------- main */

const paths = BUCKET_MODE ? await bucketPaths() : localPaths();

console.log(`\n  scanning ${paths.length} file${paths.length === 1 ? '' : 's'}`);

let sizing = null;
let sawReference = false;

for (const path of paths) {
  const name = path.split('/').pop();
  const compressed = statSync(path).size;
  let r;
  try {
    r = await scanFile(path, PATTERNS);
  } catch (error) {
    console.log(`\n  SKIPPED  ${name}\n    unreadable: ${error.message}`);
    continue;
  }

  const kind = kindOfRoot(r.rootTag);
  if (kind === 'timetable') sizing = reportTimetable(name, compressed, r);
  else if (kind === 'reference') {
    reportReference(name, compressed, r);
    sawReference = true;
  } else {
    console.log(`\n  UNRECOGNISED  ${name}`);
    console.log(`    root element        ${r.rootTag ?? 'none found'}`);
    console.log(`    Expected PportTimetable or PportTimetableRef.`);
  }
}

if (sizing?.journeys > 0) {
  const perJourney = sizing.publicStops / sizing.journeys;
  console.log('\n  SIZING STAGE 2');
  console.log(`    public calls per journey, mean   ${perJourney.toFixed(1)}`);
  console.log('    A per-station board repeats each train\'s onward calls, so a journey');
  console.log('    of k calls stores k(k-1)/2 rows. At the mean that is about');
  console.log(`    ${withCommas(Math.round(sizing.journeys * ((perJourney * (perJourney - 1)) / 2)))} rows.`);
  console.log('');
  console.log('    Treat that as a floor. The square is convex, so a spread of journey');
  console.log('    lengths costs more than the mean suggests, and only stage 1 -- which');
  console.log('    has a real parser -- can measure the spread. Compare against the');
  console.log('    Upstash budget before committing to this shape.');
}

if (sizing && !sawReference) {
  console.log('\n  No reference file was scanned. TIPLOC cannot be mapped to CRS');
  console.log('  without it, so stage 1 needs it too. It is the _ref_vN file.');
}

if (BUCKET_MODE && !KEEP) {
  for (const p of paths) rmSync(p, { force: true });
  console.log(`\n  removed the downloads. --keep to leave them in ${OUT}`);
}
console.log();
