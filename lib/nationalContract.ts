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
