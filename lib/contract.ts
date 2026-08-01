/**
 * The wire contract between the route handler and the page.
 *
 * Kept in its own module, with no import from `lib/rtt.ts` or `lib/direction.ts`,
 * so that nothing in the client bundle can reach the file that holds the token or
 * the full-GB longitude table -- even by way of a type import.
 */

import type { BoardMode, ServiceRole } from './board.ts';
import type { DepartureService } from './journeys.ts';

export interface SystemStatusView {
  realtimeNetworkRail?: 'OK' | 'REALTIME_DATA_LIMITED' | 'REALTIME_DATA_NONE';
  rttCore?: 'OK' | 'REALTIME_DATA_LIMITED' | 'SCHEDULE_ONLY' | 'REALTIME_DEGRADED';
}

/** Roles are owned by `lib/board.ts`, which decides what goes in which block. */
export type { ServiceRole };

export type DirectionValue = 'east' | 'west';

export interface TrainsResponse {
  from: { crs: string; name: string };
  direction: DirectionValue;
  /** The service date on the board, `YYYY-MM-DD`. */
  date: string;
  /**
   * Which arrangement this answer is built for. `normal` is the last trains of
   * `date` followed by the first train of the next service day; `pre-service` is
   * the first trains of `date`, which has not started running yet, followed by its
   * own last train. See `lib/board.ts`.
   */
  mode: BoardMode;
  /**
   * The service day the `first`-role entries belong to. The day after `date` in
   * normal mode, and `date` itself in pre-service mode. Stated rather than derived,
   * so the heading can name the morning it means without the client re-deriving a
   * service day.
   */
  firstDate: string;
  /**
   * The chosen services, in departure order, which is also the order they are shown
   * in. The final `last`-role entry is the last train of `date`, and the only thing
   * in the app that is red.
   */
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
