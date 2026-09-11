/**
 * Where the two Darwin files come from.
 *
 * Three scripts need exactly the same answer to "give me one timetable and one
 * reference file", and each had grown its own copy of the logic. This is that
 * answer, once.
 *
 * Two sources, and they suit different moments:
 *
 *   - `--file`  paths or a folder on this machine. What a person uses. No
 *               credentials, no cloud account.
 *   - `--bucket` an S3 bucket. What the daily job uses. The same code serves a
 *               bucket Rail Data Marketplace delivers into and a bucket Darwin
 *               serves directly, because the difference between them is whose
 *               credentials are in the environment, not how a file is fetched.
 */

import { createWriteStream, mkdirSync, readdirSync, statSync, rmSync } from 'node:fs';
import { pipeline } from 'node:stream/promises';
import { tmpdir, homedir } from 'node:os';
import { join, resolve } from 'node:path';

import { parseDarwinKey, pickBest, scanFile } from './darwin-scan.mjs';

export const expandPath = (p) =>
  resolve(p.startsWith('~') ? join(homedir(), p.slice(1)) : p);

/**
 * Pick one timetable and one reference out of however many paths were given.
 *
 * Darwin publishes the same content at several schema versions side by side, so
 * a folder can hold five files describing one publish. Names are tried first;
 * anything that will not parse falls back to its root element, because a file
 * downloaded by hand can be called anything at all.
 */
export async function choosePair(paths) {
  const parsed = paths.map((path) => ({ path, meta: parseDarwinKey(path) })).filter((x) => x.meta);
  const pick = (kind) => {
    const best = pickBest(parsed.map((x) => x.meta), kind);
    return best ? parsed.find((x) => x.meta.name === best.name).path : null;
  };

  let timetable = pick('timetable');
  let reference = pick('reference');

  for (const path of paths) {
    if (timetable && reference) break;
    const { rootTag } = await scanFile(path, {});
    if (rootTag === 'PportTimetable') timetable ??= path;
    if (rootTag === 'PportTimetableRef') reference ??= path;
  }

  return { timetable, reference };
}

/** Paths named on the command line, expanding any folder among them one level. */
export function localPaths(files) {
  const out = [];
  for (const raw of files) {
    const path = expandPath(raw);
    const stat = statSync(path);
    if (stat.isDirectory()) {
      out.push(...readdirSync(path).filter((n) => /\.(xml|gz)$/i.test(n)).map((n) => join(path, n)));
    } else {
      out.push(path);
    }
  }
  return out;
}

export function bucketConfig() {
  return {
    bucket: process.env.DARWIN_S3_BUCKET?.trim() || null,
    prefix: process.env.DARWIN_S3_PREFIX?.trim() ?? '',
    region: process.env.DARWIN_S3_REGION?.trim() || 'eu-west-2',
    accessKeyId: process.env.DARWIN_S3_ACCESS_KEY?.trim() || null,
    secretAccessKey: process.env.DARWIN_S3_SECRET_KEY?.trim() || null,
  };
}

/** Everything under the prefix, oldest first. */
export async function listBucket(client, ListObjectsV2Command, { bucket, prefix }) {
  const objects = [];
  let token;
  do {
    const page = await client.send(
      new ListObjectsV2Command({ Bucket: bucket, Prefix: prefix || undefined, ContinuationToken: token })
    );
    for (const o of page.Contents ?? []) objects.push(o);
    token = page.IsTruncated ? page.NextContinuationToken : undefined;
  } while (token);
  return objects;
}

/**
 * The newest publish's timetable and reference, downloaded.
 *
 * Downloads land in the system temp directory. In CI that is the runner's disk
 * and disappears with it; on this machine it keeps a fifty-megabyte file out of
 * a repo that lives in iCloud Drive, where writing one is how the file provider
 * wedges and the next build hangs.
 */
export async function fetchFromBucket({ outDir } = {}) {
  const config = bucketConfig();
  if (!config.bucket) throw new Error('DARWIN_S3_BUCKET is not set.');
  if (!config.accessKeyId || !config.secretAccessKey) {
    throw new Error('DARWIN_S3_ACCESS_KEY and DARWIN_S3_SECRET_KEY are not set.');
  }

  const { S3Client, ListObjectsV2Command, GetObjectCommand } = await import('@aws-sdk/client-s3');
  const client = new S3Client({
    region: config.region,
    credentials: { accessKeyId: config.accessKeyId, secretAccessKey: config.secretAccessKey },
  });

  const objects = await listBucket(client, ListObjectsV2Command, config);
  if (!objects.length) {
    throw new Error(
      `Nothing under s3://${config.bucket}/${config.prefix}. If a transfer was only just ` +
        'set up, the marketplace writes on the next publish rather than backfilling — and a ' +
        'new version of the data product has to be linked to the destination again.'
    );
  }

  const parsed = objects.map((o) => parseDarwinKey(o.Key)).filter(Boolean);
  const wanted = [pickBest(parsed, 'timetable'), pickBest(parsed, 'reference')];
  if (!wanted[0] || !wanted[1]) {
    throw new Error('The bucket holds no complete publish: one timetable and one reference are needed.');
  }

  /*
   Both halves must come from the same publish.

   The reference file barely moves -- four days apart it differed by three
   sidings and one station gaining a name -- so a mismatch does not fail, it
   quietly resolves TIPLOCs against the wrong day's table and drops any station
   that opened in between. Refusing is the only way that gets noticed.
  */
  if (wanted[0].stamp !== wanted[1].stamp) {
    throw new Error(
      `The newest timetable (${wanted[0].stamp}) and reference (${wanted[1].stamp}) are from ` +
        'different publishes. Refusing rather than resolving stations against the wrong day.'
    );
  }

  const dir = outDir ?? join(tmpdir(), 'darwin-timetable');
  mkdirSync(dir, { recursive: true });

  const downloaded = [];
  for (const meta of wanted) {
    const path = join(dir, meta.name);
    const body = (await client.send(new GetObjectCommand({ Bucket: config.bucket, Key: meta.key }))).Body;
    await pipeline(body, createWriteStream(path));
    downloaded.push({ path, key: meta.key, bytes: statSync(path).size });
  }

  return {
    timetable: downloaded[0].path,
    reference: downloaded[1].path,
    stamp: wanted[0].stamp,
    objects: objects.length,
    downloaded,
    cleanup: () => {
      for (const d of downloaded) rmSync(d.path, { force: true });
    },
  };
}
