/**
 * Which way is this train going?
 *
 * With no destination station chosen, direction has to be derived rather than
 * queried. The tempting shortcut -- pair each station with its line's far
 * terminus, so Grays "east" means Grays -> Shoeburyness -- is wrong for exactly
 * the reason the spec warns about: plenty of eastbound services terminate short,
 * at Pitsea or Southend Central, and the *last* one often does. Filtering to
 * trains that reach the terminus would drop them.
 *
 * So every boardable service at the station is classified by comparing the
 * longitude of where it is going with the longitude of where you are standing.
 * All three networks in scope run broadly east-west -- Reading and Heathrow in the
 * west, Shoeburyness and Shenfield in the east -- and longitude increases
 * monotonically along every route in scope, including both the Tilbury loop and
 * the Basildon main line.
 *
 * Pure and parameterised by a longitude lookup, so it can be tested without the
 * full-GB table. `lib/geo.ts` supplies the real one, server-side only.
 */

import type { GeographicLocation, LocationLineUpObject, LocationPair } from './rtt.ts';

export type Direction = 'east' | 'west';

export const isDirection = (value: string): value is Direction =>
  value === 'east' || value === 'west';

export const oppositeOf = (direction: Direction): Direction =>
  direction === 'east' ? 'west' : 'east';

/** Resolves a location to a longitude, or null if it is not known. */
export type LongitudeLookup = (location: GeographicLocation | undefined) => number | null;

/**
 * Roughly 140 metres. Below this the two places are effectively the same spot and
 * the comparison means nothing, so no direction is claimed.
 */
const MIN_DELTA_DEGREES = 0.002;

/** First resolvable longitude among a service's origins or destinations. */
function firstLongitude(pairs: LocationPair[] | undefined, lookup: LongitudeLookup): number | null {
  for (const pair of pairs ?? []) {
    const lon = lookup(pair.location);
    if (lon !== null) return lon;
  }
  return null;
}

/**
 * Classify a service at a station, or return null if it genuinely cannot be told.
 *
 * Destination first. Origin is the fallback for the rare service whose destination
 * is not in the table: a train that came from the east is heading west. A service
 * that both starts here and has an unknown destination cannot be placed, and the
 * caller decides what to do about it.
 */
export function classifyDirection(
  service: LocationLineUpObject,
  stationLongitude: number,
  lookup: LongitudeLookup
): Direction | null {
  const destination = firstLongitude(service.destination, lookup);
  if (destination !== null && Math.abs(destination - stationLongitude) >= MIN_DELTA_DEGREES) {
    return destination > stationLongitude ? 'east' : 'west';
  }

  const origin = firstLongitude(service.origin, lookup);
  if (origin !== null && Math.abs(origin - stationLongitude) >= MIN_DELTA_DEGREES) {
    // Came from the east, so it is going west.
    return origin > stationLongitude ? 'west' : 'east';
  }

  return null;
}

/**
 * The operators in scope, per §1: Greater Anglia, c2c and the Elizabeth line.
 *
 * This is a scope filter, not the operator filtering the spec forbids. That rule is
 * about never modelling a journey per-operator -- eastbound from Liverpool Street
 * must return Greater Anglia and Elizabeth line services merged in one time-ordered
 * list, and it still does. This only keeps out operators the app was never about,
 * such as London Overground at Barking.
 */
export const OPERATORS_IN_SCOPE = new Set(['LE', 'CC', 'XR']);

export const isOperatorInScope = (toc: string | undefined): boolean =>
  Boolean(toc && OPERATORS_IN_SCOPE.has(toc));
