/**
 * Which way is that train going?
 *
 * The twin of `ios/Sources/LastTrainCore/Direction.swift`. **The two must agree.**
 * Same 140-metre guard, same sector boundaries, same rule about what happens when a
 * destination has no coordinates — because the app and the API it talks to have to
 * bucket a service the same way or the counts on screen will not match the list
 * beneath them.
 *
 * This replaces `lib/direction.ts`, which compares destination *longitude* against
 * the station's. That works on three corridors running broadly east–west and fails
 * the moment the network does anything else. `lib/direction.ts` stays where it is
 * until the web app is retired; see `app/api/v2/trains/route.ts`.
 *
 * The direction is taken to the **destination**, not to the next calling point: it
 * matches how a passenger thinks about which way a train is going. The 23:52 out of
 * Inverness is "the Wick train", not "the train to Dingwall".
 */

import { distanceKm, type GeoPoint } from './nearest.ts';

export type Compass = 'north' | 'east' | 'south' | 'west';

/** Canonical order, used wherever directions are listed. */
export const COMPASS_POINTS: readonly Compass[] = ['north', 'east', 'south', 'west'];

/**
 * Below this, two places are the same place and a bearing between them is noise.
 *
 * **This number has to stay small, and 140 metres is the size of the thing it guards
 * against: rounding, not short journeys.** A first pass at the national probe used
 * 5km on the reasonable-sounding logic that a train terminating a couple of stops
 * away gives a meaningless direction. It silently deleted every London Overground
 * departure on the Romford branch at Upminster — 32 real, boardable trains — because
 * Romford is 4.99km away.
 *
 * Any threshold big enough to catch "terminates one stop away" is big enough to
 * delete a branch line, and it does it quietly, in the safe-looking direction.
 */
export const MIN_SEPARATION_METRES = 140;

const toRadians = (degrees: number): number => (degrees * Math.PI) / 180;

/** One haversine in this project. `lib/nearest.ts` owns it; this is the metre form. */
export const distanceMetres = (a: GeoPoint, b: GeoPoint): number => distanceKm(a, b) * 1000;

/**
 * Initial great-circle bearing, degrees clockwise from true north, in `[0, 360)`.
 *
 * Initial rather than average: over the length of Great Britain the two differ by a
 * few degrees, and only the initial one answers "which way does it set off".
 */
export function bearingDegrees(from: GeoPoint, to: GeoPoint): number {
  const lat1 = toRadians(from.lat);
  const lat2 = toRadians(to.lat);
  const deltaLon = toRadians(to.lon - from.lon);

  const y = Math.sin(deltaLon) * Math.cos(lat2);
  const x = Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(deltaLon);

  return ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360;
}

/**
 * Four 90° sectors centred on the cardinal points.
 *
 * | Sector | Direction |
 * |---|---|
 * | 315°–45° | North |
 * | 45°–135° | East |
 * | 135°–225° | South |
 * | 225°–315° | West |
 *
 * Boundaries belong to the clockwise sector: exactly 45° is east, exactly 315° is
 * north. Which side they fall on matters less than that it is stated and tested — the
 * narrowest margin measured across the national probe was 10.9°.
 */
export function compassOf(bearing: number): Compass {
  const normalised = ((bearing % 360) + 360) % 360;
  if (normalised >= 45 && normalised < 135) return 'east';
  if (normalised >= 135 && normalised < 225) return 'south';
  if (normalised >= 225 && normalised < 315) return 'west';
  return 'north';
}

/**
 * Which way a service goes, or `null` if the question has no answer.
 *
 * `null` means one of two things, and both are honest: the destination is closer than
 * `MIN_SEPARATION_METRES`, so there is no meaningful bearing; or the caller had no
 * coordinate for the destination at all. A service whose direction cannot be
 * established is left out rather than guessed at — guessing would put it under two
 * buttons at once.
 */
export function classify(from: GeoPoint, to: GeoPoint | null | undefined): Compass | null {
  if (!to) return null;
  if (distanceMetres(from, to) < MIN_SEPARATION_METRES) return null;
  return compassOf(bearingDegrees(from, to));
}

export interface CompassTally {
  counts: Record<Compass, number>;
  /** Services whose direction could not be established. Never silently folded in. */
  unclassified: number;
  /** Directions with at least one service, in compass order. */
  available: Compass[];
  total: number;
}

/**
 * How many services run each way from a station, and therefore which directions to
 * offer at all.
 *
 * At Upminster north and south have no services and must not be offered. This falls
 * out of the query that was being made anyway — the unfiltered line-up already
 * contains every service at the station — so availability costs nothing.
 */
export function tally(
  from: GeoPoint,
  destinations: Iterable<GeoPoint | null | undefined>
): CompassTally {
  const counts: Record<Compass, number> = { north: 0, east: 0, south: 0, west: 0 };
  let unclassified = 0;

  for (const destination of destinations) {
    const direction = classify(from, destination);
    if (direction) counts[direction] += 1;
    else unclassified += 1;
  }

  return {
    counts,
    unclassified,
    available: COMPASS_POINTS.filter((point) => counts[point] > 0),
    total: COMPASS_POINTS.reduce((sum, point) => sum + counts[point], 0),
  };
}

export const isCompass = (value: string): value is Compass =>
  (COMPASS_POINTS as readonly string[]).includes(value);
