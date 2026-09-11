/**
 * Counting a gzipped Darwin XML file without parsing it.
 *
 * Stage 0 of `DARWIN-INGEST.md` needs sizes and counts, not a document. Building
 * a tree from a national 48-hour timetable to answer "how many journeys" would
 * cost more memory than the measurement is worth, and would need the parser
 * choice that stage 1 exists to make.
 *
 * So this scans the decompressed byte stream. That is honest for a probe and
 * wrong for an ingest: a scan cannot tell a stop's kind from its position, and
 * stage 1 replaces it with a real streaming parser.
 *
 * Split out from the probe so the boundary arithmetic can be tested, which is
 * the only part with a way to be quietly wrong.
 */

import { createReadStream, openSync, readSync, closeSync } from 'node:fs';
import { createGunzip } from 'node:zlib';
import { pipeline } from 'node:stream/promises';
import { Writable } from 'node:stream';

/**
 * How much of the previous chunk is carried into the next.
 *
 * Longer than any tag or attribute being matched, so no pattern can span more
 * than one boundary.
 */
export const TAIL = 512;

/**
 * Take a delivered file apart: `PPTimetable/20260910020536_ref_v4.xml.gz`.
 *
 * Three fields matter and they are easy to confuse.
 *
 *   - `stamp` is when Darwin generated the file, and it is the *only* reliable
 *     ordering. Delivery timestamps are all equal, because every file of one
 *     publish arrives together.
 *   - `kind` separates the timetable from the reference data. `_ref_` is the
 *     marker, and note that a reference file's name ends `_v4.xml.gz` too, so
 *     any test for the timetable must exclude `_ref_` explicitly or it matches
 *     both.
 *   - `version` is the **schema** version, not a revision. Darwin publishes the
 *     same publish at several schema versions side by side -- v7 and v8 of the
 *     timetable, v2, v3 and v4 of the reference -- so picking "the newest file"
 *     by timestamp alone chooses between them at random.
 */
export function parseDarwinKey(key) {
  const name = key.split('/').pop() ?? '';
  // The stamp may carry a prefix. Downloading by hand flattens the S3 key, so
  // `PPTimetable/20260906020530_v8.xml.gz` reaches the disk as
  // `PPTimetable_20260906020530_v8.xml.gz` and an anchored match would reject
  // exactly the files a person is most likely to have.
  const m = name.match(/(?:^|[_/])(\d{14})_(?:(ref)_)?v(\d+)\.xml(?:\.gz)?$/i);
  if (!m) return null;
  return {
    name,
    key,
    stamp: m[1],
    kind: m[2] ? 'reference' : 'timetable',
    version: Number(m[3]),
  };
}

export const isTimetable = (key) => parseDarwinKey(key)?.kind === 'timetable';
export const isReference = (key) => parseDarwinKey(key)?.kind === 'reference';

/**
 * The newest publish, at its highest schema version, for one kind.
 *
 * Latest stamp first, then highest version within it. Highest version is right
 * because the versions are additive -- v8 carries everything v7 does -- so the
 * lower ones are only there for consumers that have not moved.
 */
export function pickBest(parsed, kind) {
  const of = parsed.filter((p) => p && p.kind === kind);
  if (!of.length) return null;
  return of.sort((a, b) => (a.stamp === b.stamp ? a.version - b.version : a.stamp < b.stamp ? -1 : 1)).at(-1);
}

/**
 * Count `patterns` across a gzipped file, and collect the service dates.
 *
 * A chunk boundary can fall inside a tag, so each chunk is scanned with the tail
 * of the previous one in front of it. That overlap means the same tag is offered
 * to the patterns twice, and the counting has to decide which offer is real.
 *
 * **It counts by where a match starts, in absolute stream offsets, and never
 * counts one start twice.** The obvious alternative -- count a match that
 * reaches into the new bytes -- is wrong for any pattern whose end can move. A
 * greedy pattern like `<IP\b[^>]*\bpt[ad]="` matched `ptd="` on a truncated
 * element in one chunk and then matched the same element's later `pta="` in the
 * next, ending further along, and so was counted twice. That over-counted 284
 * stops out of 392,050 in a real file: small enough to look plausible, and the
 * number stage 2 squares.
 *
 * `latin1` is deliberate: it maps bytes to code units one for one, so a
 * multi-byte character cannot be split across a boundary into something that
 * looks like a match. Every pattern here is ASCII.
 */
export function scanText(patterns) {
  const counts = Object.fromEntries(Object.keys(patterns).map((k) => [k, 0]));
  const dates = new Set();
  let bytes = 0;
  let carry = '';
  let rootTag = null;
  let lastDateStart = -1;

  const compiled = Object.entries(patterns).map(([name, re]) => ({
    name,
    rx: new RegExp(re.source, 'g'),
    lastStart: -1,
  }));

  const push = (chunk) => {
    // Where text[0] sits in the whole stream, so match offsets are absolute.
    const base = bytes - carry.length;
    bytes += chunk.length;
    const text = carry + chunk.toString('latin1');

    if (!rootTag) {
      const m = text.match(/<([A-Za-z_][\w.:-]*)[\s/>]/);
      if (m) rootTag = m[1];
    }

    for (const entry of compiled) {
      const { rx } = entry;
      rx.lastIndex = 0;
      let m;
      while ((m = rx.exec(text)) !== null) {
        const start = base + m.index;
        if (start > entry.lastStart) {
          counts[entry.name] += 1;
          entry.lastStart = start;
        }
        if (m[0].length === 0) rx.lastIndex += 1;
      }
    }

    const ssd = /\bssd="(\d{4}-\d{2}-\d{2})"/g;
    let d;
    while ((d = ssd.exec(text)) !== null) {
      const start = base + d.index;
      if (start > lastDateStart) {
        dates.add(d[1]);
        lastDateStart = start;
      }
    }

    carry = text.slice(-TAIL);
  };

  return {
    push,
    result: () => ({ bytes, counts, rootTag, dates: [...dates].sort() }),
  };
}

/**
 * Is this file gzipped?
 *
 * Read the two magic bytes rather than trusting the extension. A file pulled by
 * hand off the Data files tab may arrive already decompressed, or keep a `.gz`
 * name it no longer earns, and either way guessing wrong turns a good file into
 * an unhelpful zlib error.
 */
export function isGzipped(path) {
  const fd = openSync(path, 'r');
  try {
    const head = Buffer.alloc(2);
    return readSync(fd, head, 0, 2, 0) === 2 && head[0] === 0x1f && head[1] === 0x8b;
  } finally {
    closeSync(fd);
  }
}

/** `scanText`, driven from a file on disk, gzipped or not. */
export async function scanFile(path, patterns) {
  const scanner = scanText(patterns);
  const sink = new Writable({
    write(chunk, _enc, done) {
      scanner.push(chunk);
      done();
    },
  });
  const stages = [createReadStream(path)];
  if (isGzipped(path)) stages.push(createGunzip());
  stages.push(sink);
  await pipeline(...stages);
  return scanner.result();
}

/**
 * Which of the two files this is, from its root element rather than its name.
 *
 * The naming rules above hold for the S3 delivery, but a file downloaded by hand
 * can be called anything, so the kind is read from the document itself.
 */
export function kindOfRoot(rootTag) {
  if (!rootTag) return 'unknown';
  if (/^PportTimetableRef$/i.test(rootTag)) return 'reference';
  if (/^PportTimetable$/i.test(rootTag)) return 'timetable';
  return 'unknown';
}

/**
 * Everything worth counting in either file.
 *
 * One union, run over both, so a file's kind can be decided from its root
 * element after the scan rather than assumed from its name beforehand. The extra
 * patterns cost one pass over bytes already in memory.
 *
 * Public times are the point of the count. `ptd`/`pta` are what a passenger
 * sees; `wtd`/`wta`/`wtp` are working times and include passing points. A stop
 * carrying only working times is not a public call, and counting it would size
 * the store for rows the app must never show.
 */
export const PATTERNS = {
  // Timetable
  journeys: /<Journey\b/,
  origins: /<OR\b/,
  operatingOrigins: /<OPOR\b/,
  intermediates: /<IP\b/,
  passingPoints: /<PP\b/,
  destinations: /<DT\b/,
  publicDepartures: /\bptd="/,
  publicArrivals: /\bpta="/,
  // A stop carrying at least one public time, counted per element rather than
  // per attribute. An intermediate stop has both `pta` and `ptd`, so adding the
  // two attribute counts gives public *times*, roughly double the public
  // *calls* -- and stage 2's storage estimate squares that number, so the
  // difference is not small. Stops are single self-closing tags, so `[^>]*`
  // stays inside one element.
  publicOriginStops: /<OR\b[^>]*\bpt[ad]="/,
  publicIntermediateStops: /<IP\b[^>]*\bpt[ad]="/,
  publicDestinationStops: /<DT\b[^>]*\bpt[ad]="/,
  publicPassingStops: /<PP\b[^>]*\bpt[ad]="/,
  workingTimes: /\bwt[dap]="/,
  platforms: /\bplat="/,
  cancelled: /\bcan="true"/,
  cancelReasons: /<cancelReason\b/,
  associations: /<Association\b/,
  // Reference
  locations: /<LocationRef\b/,
  withCrs: /\bcrs="/,
  operators: /<TocRef\b/,
};
