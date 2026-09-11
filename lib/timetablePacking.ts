/**
 * How a timetable board is written down, and read back.
 *
 * `DARWIN-INGEST.md` §3 stage 2 chose the shape; this is the shape itself. It
 * lives here, in the app's own code, for one reason: **the ingest script and the
 * app must agree byte for byte, and two implementations of one format is how
 * they stop agreeing.** `scripts/lib/darwin-board.mjs` imports this file rather
 * than restating it, so `npm test` covers the same code the ingest runs.
 *
 * Pure. No Redis, no `server-only`, nothing that cannot run in a script.
 *
 * A board is one station's departures on one service day, one line each:
 *
 *     <minute>\t<rid>\t<toc>\t<origin>\t<platform>\t<flags>\t<destination>\t<onward>
 *
 * `minute` counts from the midnight that opens the service date and keeps
 * counting past it, so 02:30 the following morning is 1590. That is what lets a
 * board sort and compare as plain numbers with no date handling where it is
 * read, which matters because the service day runs 03:00–02:59 and every time
 * the feed gives is timezone-less London wall clock.
 *
 * `onward` is fixed-width, eight characters per call: three of CRS, four digits
 * of minute, one flag. There are no separators because there is nothing to
 * separate — every field is a known width. The saving is real (27 MiB a service
 * day against 39 for compact JSON) but the reason it is safe is that width, so
 * do not add a variable-length field to it.
 */

import type { NormalizedService, NormalizedStop } from './darwin.ts';

/** `.` where a passenger may get off, `u` where the train will not put them down. */
const ALIGHT_OK = '.';
const ALIGHT_NO = 'u';

const ONWARD_WIDTH = 8;
const CRS_WIDTH = 3;
const MINUTE_WIDTH = 4;

export interface PackedCall {
  crs: string;
  /** Minutes from the midnight opening the service date. May exceed 1440. */
  arr: number;
  /**
   * Whether a passenger may leave the train here.
   *
   * False at a take-up-only stop. The call is still listed, because a detail
   * sheet shows it as a calling point; it is a destination search that must
   * refuse it.
   */
  canAlight: boolean;
}

export interface PackedDeparture {
  /** Minutes from the midnight opening the service date. May exceed 1440. */
  dep: number;
  /** Darwin's run identifier. Unique per service per day. */
  rid: string;
  toc: string;
  /**
   * CRS of where the train started, which is usually behind the boarding point.
   *
   * Carried because the detail sheet names it, and a board cannot work it out:
   * the calls before you boarded are not on your board. Three characters per
   * departure, about 1.6 MiB on a 27 MiB service day.
   */
  origin: string;
  platform: string | null;
  isBus: boolean;
  /** A service that runs only when required. Never call one the last train without saying so. */
  isConditional: boolean;
  destination: string;
  onward: PackedCall[];
}

const FLAG_BUS = 1;
const FLAG_CONDITIONAL = 2;

/**
 * Where a board lives.
 *
 * Defined here so the writer and the reader cannot drift. `tt:` keeps the
 * timetable out of `lib/cache.ts`'s keyspace: the cache holds answers that may
 * be thrown away, and this is the store.
 */
export const boardKey = (crs: string, serviceDate: string): string =>
  `tt:board:${crs.toUpperCase()}:${serviceDate}`;

/** Where the snapshot's own description lives. One key, rewritten by each publish. */
export const META_KEY = 'tt:meta';

/** What the app needs to know about the snapshot it is reading. */
export interface TimetableMeta {
  /** Darwin's own id for the file, e.g. `20260910020536`. */
  timetableId: string;
  /** When Darwin generated it, as a London instant with no zone marker. */
  generatedAt: string;
  /** When the ingest wrote it, RFC3339 with a zone. */
  publishedAt: string;
  /** Service days this snapshot covers, ascending. */
  serviceDates: string[];
  boardCount: number;
  departureCount: number;
  /** TOC code to operator name, so a board need not repeat it on every line. */
  operators: Record<string, string>;
}

/** One departure line. Tabs and newlines are the only reserved characters. */
function packDeparture(d: PackedDeparture): string {
  const onward = d.onward
    .map(
      (o) =>
        `${o.crs}${String(o.arr).padStart(MINUTE_WIDTH, '0')}${o.canAlight ? ALIGHT_OK : ALIGHT_NO}`
    )
    .join('');
  const flags = (d.isBus ? FLAG_BUS : 0) | (d.isConditional ? FLAG_CONDITIONAL : 0);
  return [d.dep, d.rid, d.toc, d.origin, d.platform ?? '', flags, d.destination, onward].join('\t');
}

export function packBoard(departures: PackedDeparture[]): string {
  return departures.map(packDeparture).join('\n');
}

export function unpackBoard(text: string | null | undefined): PackedDeparture[] {
  if (!text) return [];
  const out: PackedDeparture[] = [];

  for (const line of text.split('\n')) {
    if (!line) continue;
    const [dep, rid, toc, origin, platform, flags, destination, onward = ''] = line.split('\t');
    const calls: PackedCall[] = [];
    for (let i = 0; i + ONWARD_WIDTH <= onward.length; i += ONWARD_WIDTH) {
      calls.push({
        crs: onward.slice(i, i + CRS_WIDTH),
        arr: Number(onward.slice(i + CRS_WIDTH, i + CRS_WIDTH + MINUTE_WIDTH)),
        canAlight: onward[i + ONWARD_WIDTH - 1] !== ALIGHT_NO,
      });
    }
    const flagBits = Number(flags);
    out.push({
      dep: Number(dep),
      rid,
      toc,
      origin,
      platform: platform || null,
      isBus: Boolean(flagBits & FLAG_BUS),
      isConditional: Boolean(flagBits & FLAG_CONDITIONAL),
      destination,
      onward: calls,
    });
  }

  return out;
}

/** `1590` on a 2026-09-10 board -> `2026-09-11T02:30:00`. Naive London, as the contract uses. */
export function instantOf(serviceDate: string, minutes: number): string {
  const dayOffset = Math.floor(minutes / 1440);
  const within = minutes - dayOffset * 1440;
  const [y, m, d] = serviceDate.split('-').map(Number);
  const shifted = new Date(Date.UTC(y, m - 1, d + dayOffset));
  const date = shifted.toISOString().slice(0, 10);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${date}T${pad(Math.floor(within / 60))}:${pad(within % 60)}:00`;
}

/**
 * How old a snapshot is, from Darwin's own generation time.
 *
 * Deliberately not when the ingest wrote it. A job cycling happily every hour
 * against a feed that stopped delivering four days ago would report itself
 * fresh for ever, and that is precisely the failure being watched for. An
 * unreadable stamp reads as infinitely old, never as fresh.
 */
export function ageSecondsOf(meta: TimetableMeta, now: Date): number {
  const generated = Date.parse(`${meta.generatedAt}Z`);
  if (Number.isNaN(generated)) return Number.POSITIVE_INFINITY;
  return Math.max(0, Math.round((now.getTime() - generated) / 1000));
}

/**
 * One packed departure as the shape `lib/darwin.ts` produces from a live board.
 *
 * `stops[0]` is the boarding station carrying its departure, then every later
 * call in order — the layout `toFastService` reads.
 *
 * `nameOf` is passed in rather than imported. The station table is a
 * `server-only` module that loads a JSON file Node cannot import directly, so
 * reaching for it here would put this whole file out of reach of `npm test` —
 * and this is the file that most needs testing.
 */
export function toNormalizedService(
  departure: PackedDeparture,
  boardCrs: string,
  serviceDate: string,
  operators: Record<string, string>,
  nameOf: (crs: string) => string
): NormalizedService {
  const stops: NormalizedStop[] = [
    {
      crs: boardCrs,
      name: nameOf(boardCrs),
      time: clockOf(departure.dep),
      timeInstant: instantOf(serviceDate, departure.dep),
      isCancelled: false,
      canAlight: true,
    },
    ...departure.onward.map((call) => ({
      crs: call.crs,
      name: nameOf(call.crs),
      time: clockOf(call.arr),
      timeInstant: instantOf(serviceDate, call.arr),
      // Cancelled calls are dropped by the ingest, so anything here is running.
      isCancelled: false,
      canAlight: call.canAlight,
    })),
  ];

  return {
    serviceId: departure.rid,
    operatorCode: departure.toc,
    operatorName: operators[departure.toc] ?? departure.toc,
    originName: nameOf(departure.origin),
    destinationName: departure.destination,
    platform: departure.platform,
    isCancelled: false,
    stops,
  };
}

/** `1590` -> `02:30`. The clock a passenger reads, without the date. */
export function clockOf(minutes: number): string {
  const within = minutes % 1440;
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${pad(Math.floor(within / 60))}:${pad(within % 60)}`;
}
