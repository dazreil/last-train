/**
 * Which direction a train from a station belongs to. One rule, for the board and for the
 * destination list, so the two can never disagree.
 *
 * 1. A train that calls at a direction's **waypoint** belongs to that direction. The
 *    waypoint is what tells two branches apart where the bearing cannot: from Upminster,
 *    trains to Shoeburyness go south via Ockendon or east via Laindon.
 * 2. A train that calls at **no** waypoint goes by the bearing to where it is going.
 * 3. It is **never dropped**.
 *
 * Rule 3 is the fix for BUG-001 (27 September 2026). The waypoint used to be required as
 * well as sufficient: a train whose bearing pointed at a direction with a waypoint, but
 * which missed it, was on no board at all. On a diversion day that emptied Barking's west
 * board — every c2c train ran via Stratford to Liverpool Street and none called at West
 * Ham — and on every day it hid the Overground from Barking to Gospel Oak.
 *
 * Pure, so the rule is tested without a network.
 */
import type { Compass } from './compass.ts';

export type Waypoints = readonly (readonly [Compass, string | undefined])[];

export function placeTrain(
  callsAt: (crs: string) => boolean,
  waypoints: Waypoints,
  bearing: Compass | null
): Compass | null {
  for (const [point, waypoint] of waypoints) {
    if (waypoint && callsAt(waypoint)) return point;
  }
  return bearing;
}
