/**
 * The wire contract for the national board, `GET /api/v2/trains`.
 *
 * Kept apart from `lib/contract.ts`, which the deployed web app depends on. The web
 * app is finished and in daily use; IOS.md is explicit that it stays as-is until the
 * native app ships, so nothing here may change anything it reads.
 *
 * No import from `lib/rtt.ts` or `lib/nationalStations.ts`, so that nothing on a
 * client can reach the token or the 2,619-station table even by way of a type import.
 */

import type { BoardMode, ServiceRole } from './board.ts';
import type { Compass } from './compass.ts';

export interface NationalService {
  /** `23:52`, London local. */
  dep: string;
  /** RFC3339 instant, so the client never re-derives the time. */
  depInstant: string;
  /** TOC code, e.g. `SR`, `GW`, `LE`. */
  toc: string;
  tocName: string;
  /** Where the train is going. Two names, joined, when it divides en route. */
  destination: string;
  platform: string | null;
  /** Road transport. Badged, never silently shown as a train. */
  isReplacementBus: boolean;
  headcode: string | null;
  serviceId: string;
  role: ServiceRole;
}

export interface SystemStatusView {
  realtimeNetworkRail?: 'OK' | 'REALTIME_DATA_LIMITED' | 'REALTIME_DATA_NONE';
  rttCore?: 'OK' | 'REALTIME_DATA_LIMITED' | 'SCHEDULE_ONLY' | 'REALTIME_DEGRADED';
}

/**
 * A diagnostics surface, not a different code path.
 *
 * IOS.md §3: ships disabled, gated behind `DEBUG_DIAGNOSTICS=1` on the server and a
 * hidden gesture in the app. **Never contains the token**, only which tier it appears
 * to be — and that is read from the rate-limit headers rather than from a mode flag,
 * so switching plans is one environment variable and there is nothing to forget to
 * flip on release day.
 */
export interface Diagnostics {
  /** Remaining/limit on all four dimensions, straight from the last response. */
  rateLimit: { minute?: string; hour?: string; day?: string; week?: string };
  /** Inferred from the per-minute limit. Never the token itself. */
  tier: 'free-or-hobbyist' | 'team' | 'unknown';
  /** Upstream requests this lookup actually spent. */
  requestsSpent: number;
  cache: 'HIT' | 'PARTIAL' | 'MISS';
  /** The window sent upstream, so a wrong answer is traceable. */
  window: { timeFrom: string; timeTo: string };
  /** How many services the line-up held, and how many survived each stage. */
  counts: { inLineUp: number; boardable: number; inDirection: number; unclassified: number };
}

export interface NationalBoard {
  from: { crs: string; name: string; locality: string | null };
  direction: Compass;
  /** The service date on the board, `YYYY-MM-DD`. */
  date: string;
  mode: BoardMode;
  /** The service day the `first`-role entries belong to. */
  firstDate: string;
  /** In departure order, which is also the order they are shown in. */
  services: NationalService[];
  /**
   * Every direction's count, from the one query. The client caches this per station
   * effectively forever — track topology does not change week to week — so a station
   * visited before shows the right controls instantly.
   */
  directions: Record<Compass, number>;
  /** Directions with at least one service, in compass order. */
  available: Compass[];
  /** Departures whose direction could not be established. Never folded into a bucket. */
  unclassified: number;
  /** Departures in this direction across the whole service day, before selection. */
  totalServices: number;
  /** Where the trains in this direction actually go, most frequent first. */
  towards: string[];
  /**
   * The same, for every direction — because the control names a destination on each
   * block it offers, not only the selected one. Free: it comes out of the same pass
   * that produced `directions`.
   */
  towardsByDirection: Record<Compass, string[]>;
  systemStatus?: SystemStatusView;
  apiVersion: string;
  diagnostics?: Diagnostics;
}

export interface NationalError {
  error: string;
  retryAfterSeconds?: number;
}

/**
 * One stop on a train's route, for the calling-points sheet.
 *
 * A *call*, not a location: the service response omits passes entirely, so everything
 * here is somewhere you can actually get off. See `lib/rtt.ts`'s note on `serviceDetail`.
 */
export interface ServiceCall {
  /** Null for the handful of stops with no CRS, which are still worth naming. */
  crs: string | null;
  name: string;
  /** London wall-clock. The departure where there is one, the arrival at the far end. */
  time: string | null;
  /**
   * The same moment, in the API's timezone-less London form, for ordering.
   *
   * `time` cannot be ordered: 00:15 sorts before 23:50 as a string and the two belong to
   * one night. Fast Train ranks by arrival, so it needs this.
   */
  timeInstant: string | null;
  isCancelled: boolean;
}

/** Where a train goes, end to end. */
export interface ServiceCalls {
  serviceId: string;
  /** `2D88`. Stable day to day, unlike `serviceId`, which carries its date. */
  headcode: string | null;
  toc: string;
  tocName: string;
  origin: string;
  destination: string;
  calls: ServiceCall[];
}

/**
 * One way of getting from A to B, with the arrival that decides its place.
 *
 * The server works out the arrival, because that costs a calling pattern per train. The
 * *ranking* is left to the client, so the rule lives in one place — `FastBoard` in
 * `LastTrainCore` — rather than in two that must be kept in step. `lib/compass.ts` and
 * `Direction.swift` are already a pair like that, and one is enough.
 */
export interface FastService {
  serviceId: string;
  /** Stable day to day, unlike `serviceId`. What a pattern cache keys on. */
  headcode: string | null;
  toc: string;
  tocName: string;
  /** Where the train finishes, which is often past where you get off. */
  destination: string;
  /** London clock at the origin, for reading. */
  departure: string;
  /** The same, orderable. */
  departureInstant: string;
  /** London clock at the chosen destination. */
  arrival: string;
  arrivalInstant: string;
  /** The platform it leaves the origin from, when the line-up knows one. */
  platform: string | null;
}

/** Every direct train from A to B in the window, with arrivals worked out. */
export interface FastBoard {
  from: { crs: string; name: string; locality: string | null };
  to: { crs: string; name: string; locality: string | null };
  /** `YYYY-MM-DD`, the service day the window belongs to. */
  date: string;
  /** In departure order. The client ranks by arrival. */
  services: FastService[];
  /** How many trains call at the destination in the window, before any budget. */
  candidates: number;
  /**
   * True when the pattern budget stopped us pricing every candidate.
   *
   * The answer is still correct for what it shows, but it is not provably the fastest
   * four — and a board that might be wrong has to say so.
   */
  truncated: boolean;
}

/** One place you can get to directly, and how long it takes. */
export interface Destination {
  crs: string;
  name: string;
  /** The shortest direct journey found, in minutes. Also the list's sort key. */
  minutes: number;
}

/**
 * Where one direction goes.
 *
 * Built from calling patterns, so every entry is reachable by a direct train. That is
 * what lets Fast Train offer a list instead of a search box, and it is why
 * `PRODUCT.md` §1's "no direct service" dead end cannot happen in the mode.
 */
export interface DestinationList {
  from: { crs: string; name: string };
  direction: string;
  date: string;
  /** Nearest first, by journey time. That is also route order along the line. */
  destinations: Destination[];
  /** True when the pattern budget stopped us reading every route this way. */
  truncated: boolean;
  /**
   * Which other directions this list was checked against.
   *
   * §14's rule is that a destination belongs to the direction that reaches it fastest, so
   * the check needs the other directions' times. Those are read from cache only — never
   * fetched, because four directions would cost four line-ups and thirty-odd patterns.
   *
   * An empty array means nothing was compared, so the list may name places another
   * direction reaches sooner. The client should say so rather than imply the list is
   * settled.
   */
  comparedWith: string[];
}
