/**
 * The wire contract between the route handler and the page.
 *
 * Kept in its own module, with no import from `lib/rtt.ts` or `lib/direction.ts`,
 * so that nothing in the client bundle can reach the file that holds the token or
 * the full-GB longitude table -- even by way of a type import.
 */

import type { DepartureService } from './journeys.ts';

export interface SystemStatusView {
  realtimeNetworkRail?: 'OK' | 'REALTIME_DATA_LIMITED' | 'REALTIME_DATA_NONE';
  rttCore?: 'OK' | 'REALTIME_DATA_LIMITED' | 'SCHEDULE_ONLY' | 'REALTIME_DEGRADED';
}

/** Which part of the answer a service is: the first train, or one of the last three. */
export type ServiceRole = 'first' | 'last';

export type DirectionValue = 'east' | 'west';

export interface TrainsResponse {
  from: { crs: string; name: string };
  direction: DirectionValue;
  /** The service date queried, `YYYY-MM-DD`. */
  date: string;
  /** First train, then the last three, in departure order. */
  services: (DepartureService & { role: ServiceRole })[];
  /** Departures in this direction across the whole service day, before selection. */
  totalServices: number;
  /**
   * False when the count is a lower bound rather than the real figure, which happens
   * where the line-up holds services outside the app's corridors that were never
   * individually checked. The UI hides the count in that case rather than stating a
   * confident wrong number.
   */
  totalIsExact: boolean;
  /**
   * Where the trains in this direction actually go, most frequent first. Shown as
   * a hint under the direction buttons, because "east" is only meaningful if you
   * know it means Shoeburyness rather than Norwich.
   */
  towards: string[];
  systemStatus?: SystemStatusView;
  apiVersion: string;
}

export interface TrainsError {
  error: string;
  retryAfterSeconds?: number;
}
