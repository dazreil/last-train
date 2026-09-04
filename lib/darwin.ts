import 'server-only';

import { addDays, formatLondonTime, type IsoDate } from './serviceDay.ts';
import type { FastService, ServiceCall, ServiceCalls } from './nationalContract.ts';

/**
 * Darwin Live Departure Boards (LDBWS REST), on the Rail Data Marketplace.
 *
 * The one call that ends the fan-out. `/api/v2/fast` and `/api/v2/destinations` used to
 * spend one upstream request per train to learn where it stopped — a screen cost a dozen
 * or more, and a single user could exhaust the RTT minute. `GetDepBoardWithDetails`
 * returns the departures **with every calling point already attached**, so a whole screen
 * is one request.
 *
 * This module fetches and normalises. It never ranks and never caches: the ranking rule
 * lives in `FastBoard` on the client, and caching is the routes' decision. Last Train is
 * deliberately not here — it needs the whole service day, which a board that sees two
 * hours ahead cannot give, so it stays on `lib/rtt.ts`.
 *
 * Times on the wire are `"HH:MM"` London wall-clock. They are resolved to the same
 * timezone-less London ISO the rest of the contract uses, rolling to the next day
 * wherever the clock steps back — the only way a 00:05 train on a 23:50 board lands on
 * the right date.
 */

const API_KEY = () => process.env.DARWIN_LDBWS_KEY?.trim();
const BASE_URL = () => process.env.DARWIN_LDBWS_BASE_URL?.trim();

/** Only the fields the two routes actually read. The feed sends a great deal more. */
interface DarwinCallingPoint {
  locationName?: string;
  crs?: string;
  /** Scheduled time, `"HH:MM"`. */
  st?: string;
  isCancelled?: boolean;
}

interface DarwinCallingPointList {
  callingPoint?: DarwinCallingPoint[];
}

interface DarwinLocation {
  locationName?: string;
  crs?: string;
}

interface DarwinService {
  serviceID?: string;
  /** Scheduled departure from the board station, `"HH:MM"`. */
  std?: string;
  platform?: string;
  operator?: string;
  operatorCode?: string;
  origin?: DarwinLocation[];
  destination?: DarwinLocation[];
  isCancelled?: boolean;
  /** `train`, `bus`, `ferry`. Only trains reach a Fast Train board. */
  serviceType?: string;
  subsequentCallingPoints?: DarwinCallingPointList[];
}

interface DarwinBoard {
  locationName?: string;
  crs?: string;
  /** RFC3339 with an offset — the anchor the wall-clock times are resolved against. */
  generatedAt?: string;
  trainServices?: DarwinService[];
}

/**
 * One stop, in the shared form both routes read.
 *
 * `stops[0]` is the board station itself — the boarding point, with its departure — and
 * the rest are the calling points after it, in order. Fast Train reads the departure from
 * the first and the arrival from the stop that matches the destination; the destinations
 * walk measures every later stop from the first; the detail sheet shows them all.
 */
export interface NormalizedStop {
  crs: string | null;
  name: string;
  time: string | null;
  timeInstant: string | null;
  isCancelled: boolean;
}

export interface NormalizedService {
  serviceId: string;
  operatorCode: string;
  operatorName: string;
  originName: string;
  destinationName: string;
  platform: string | null;
  isCancelled: boolean;
  stops: NormalizedStop[];
}

export class DarwinError extends Error {
  constructor(
    message: string,
    readonly status: number
  ) {
    super(message);
    this.name = 'DarwinError';
  }
}

interface BoardQuery {
  /** A CRS to filter to — only trains that call there come back. */
  filterCrs?: string;
  filterType?: 'to' | 'from';
  numRows?: number;
}

/**
 * Departures from `crs`, with details, from now.
 *
 * The board looks about two hours ahead, which is all Fast Train and the destinations
 * list need — the next trains from where you are standing. It is not enough for the last
 * train of the day, which is why Last Train is not built on this.
 */
export async function departureBoard(crs: string, query: BoardQuery = {}): Promise<DarwinBoard> {
  const key = API_KEY();
  const base = BASE_URL();
  if (!key || !base) {
    throw new DarwinError(
      'Darwin credentials are not configured on the server. Set DARWIN_LDBWS_KEY and DARWIN_LDBWS_BASE_URL.',
      500
    );
  }

  const params = new URLSearchParams();
  if (query.numRows) params.set('numRows', String(query.numRows));
  if (query.filterCrs) {
    params.set('filterCrs', query.filterCrs);
    params.set('filterType', query.filterType ?? 'to');
  }
  const url = `${base}/GetDepBoardWithDetails/${encodeURIComponent(crs)}?${params.toString()}`;

  let res: Response;
  try {
    res = await fetch(url, {
      headers: { 'x-apikey': key, Accept: 'application/json' },
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    // A timeout or a dropped connection. The routes fall back to RTT rather than fail.
    throw new DarwinError('Could not reach the live departure board.', 502);
  }

  if (!res.ok) {
    throw new DarwinError(`Live departure board returned ${res.status}.`, res.status);
  }

  return (await res.json()) as DarwinBoard;
}

/** `"HH:MM"` to minutes since midnight, or null when it is a status word like `On time`. */
function minutesOfDay(hhmm: string | undefined): number | null {
  if (!hhmm) return null;
  const match = /^(\d{2}):(\d{2})$/.exec(hhmm.trim());
  if (!match) return null;
  return Number(match[1]) * 60 + Number(match[2]);
}

/**
 * London date and minute the board was generated at, the anchor for its wall-clock times.
 *
 * Every train on a departure board leaves at or after this moment, so a scheduled time
 * earlier in the day than this has wrapped past midnight and belongs to tomorrow. Falls
 * back to the process clock if the feed omits the stamp, which it does not in practice.
 */
function anchorOf(generatedAt: string | undefined): { date: IsoDate; minute: number } {
  const iso = generatedAt ?? new Date().toISOString();
  const date = new Date(iso);
  // The feed stamps an offset, so these read London's wall clock at generation.
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).formatToParts(date);
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? '00';
  const day = `${get('year')}-${get('month')}-${get('day')}`;
  const hour = get('hour') === '24' ? '00' : get('hour');
  return { date: day, minute: Number(hour) * 60 + Number(get('minute')) };
}

/**
 * Turn a board into the shared shape, resolving every wall-clock time to a London ISO.
 *
 * The times on one train only ever move forward, so a step back is midnight: each time
 * that reads earlier than the one before it takes the next day. The same rule spans the
 * gap from the board's own clock to the first departure, so a train just past midnight on
 * a board generated just before it is dated tomorrow without a special case.
 */
export function normalize(board: DarwinBoard): NormalizedService[] {
  const anchor = anchorOf(board.generatedAt);
  const services: NormalizedService[] = [];

  for (const service of board.trainServices ?? []) {
    if (!service.serviceID) continue;
    // Buses and ferries are not Fast Train's answer, and a cancelled train is not a
    // journey. Both drop out here rather than in each route.
    if (service.serviceType && service.serviceType !== 'train') continue;
    if (service.isCancelled) continue;

    const board0 = service.subsequentCallingPoints?.[0]?.callingPoint ?? [];
    // Boarding point first, then everything the train calls at after it.
    const raw: { name: string; crs: string | null; hhmm: string | undefined; cancelled: boolean }[] = [
      {
        name: board.locationName ?? board.crs ?? 'Here',
        crs: board.crs ?? null,
        hhmm: service.std,
        cancelled: Boolean(service.isCancelled),
      },
      ...board0.map((cp) => ({
        name: cp.locationName ?? 'Unknown',
        crs: cp.crs ?? null,
        hhmm: cp.st,
        cancelled: Boolean(cp.isCancelled),
      })),
    ];

    let dayOffset = 0;
    let previous = anchor.minute;
    const stops: NormalizedStop[] = raw.map((stop) => {
      const minute = minutesOfDay(stop.hhmm);
      let instant: string | null = null;
      let clock: string | null = null;
      if (minute !== null) {
        if (minute < previous) dayOffset += 1;
        previous = minute;
        const naive = `${addDays(anchor.date, dayOffset)}T${stop.hhmm}:00`;
        instant = naive;
        clock = formatLondonTime(naive);
      }
      return {
        crs: stop.crs,
        name: stop.name,
        time: clock,
        timeInstant: instant,
        isCancelled: stop.cancelled,
      };
    });

    services.push({
      serviceId: service.serviceID,
      operatorCode: service.operatorCode ?? '??',
      operatorName: service.operator ?? 'Unknown operator',
      originName: service.origin?.[0]?.locationName ?? board.locationName ?? '',
      destinationName: service.destination?.map((d) => d.locationName).filter(Boolean).join(' & ') || '',
      platform: service.platform ?? null,
      isCancelled: Boolean(service.isCancelled),
      stops,
    });
  }

  return services;
}

/**
 * One priced journey to `toCrs`, or null when the train cannot be priced.
 *
 * Null for the same reasons the RTT path refuses one: the destination is not on the
 * pattern after the boarding point, or a time will not read. The board is filtered to
 * trains that call at the destination, so the miss is rare — but the arrival is the
 * proof, and this is where the proof is.
 */
export function toFastService(service: NormalizedService, toCrs: string): FastService | null {
  const boarding = service.stops[0];
  if (!boarding?.timeInstant) return null;

  const alighting = service.stops.slice(1).find((stop) => stop.crs === toCrs);
  if (!alighting?.timeInstant || !alighting.time || alighting.isCancelled) return null;
  // A journey that ends before it starts is a parsing failure in disguise.
  if (alighting.timeInstant <= boarding.timeInstant) return null;

  return {
    serviceId: service.serviceId,
    // The board carries no reporting number; the app treats it as optional.
    headcode: null,
    toc: service.operatorCode,
    tocName: service.operatorName,
    destination: service.destinationName,
    departure: boarding.time ?? formatLondonTime(boarding.timeInstant),
    departureInstant: boarding.timeInstant,
    arrival: alighting.time,
    arrivalInstant: alighting.timeInstant,
    platform: service.platform,
  };
}

/** The whole route, for the sheet behind a tap — cached so the tap costs no request. */
export function toServiceCalls(service: NormalizedService): ServiceCalls {
  const calls: ServiceCall[] = service.stops.map((stop) => ({
    crs: stop.crs,
    name: stop.name,
    time: stop.time,
    timeInstant: stop.timeInstant,
    isCancelled: stop.isCancelled,
  }));

  return {
    serviceId: service.serviceId,
    headcode: null,
    toc: service.operatorCode,
    tocName: service.operatorName,
    origin: service.originName,
    destination: service.destinationName,
    calls,
  };
}
