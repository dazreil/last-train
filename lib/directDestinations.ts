/**
 * Every station reachable directly from here, in every direction, for a whole day.
 *
 * The picker used to be asked one direction at a time, from the next two hours of live
 * trains. That made "no direction chosen yet" impossible to answer — the app fell back to
 * west — and it meant a list of "all" built from four separate two-hour windows could
 * disagree with a list of "west" built from one of them. This answers every direction at
 * once from one day's timetable board, so the filtered list is only ever a subset of the
 * whole one.
 *
 * Pure. The rule that says which way a train goes is passed in rather than imported,
 * because it depends on the station table and the adjacency table, both server-only —
 * and the thing worth testing here is what happens *after* a train has a direction.
 */

import { COMPASS_POINTS, type Compass } from './compass.ts';
import { minutesBetween } from './serviceDay.ts';
import type { NormalizedService } from './darwin.ts';

export interface TaggedDestination {
  crs: string;
  name: string;
  /** The fastest direct journey that way, in minutes. Zero is real: two stops a minute apart. */
  minutes: number;
  /** The way you head to get there. */
  direction: Compass;
  /** How many direct trains that way reach it in the day. */
  trains: number;
}

/**
 * The reachable set, each station filed under the direction that gets there fastest.
 *
 * `directionOf` must be the **same rule the board uses** to file a train under a direction.
 * If it were not, picking "Barking, west" could open a west board with no train to
 * Barking on it — which is the bug a list like this exists to prevent.
 *
 * Three things are left out on purpose:
 *
 *   - Stops a passenger may not get off at. A take-up-only stop is on the route but is not
 *     a destination.
 *   - The station you are at. A loop train reaches it again at the end, and nobody rides all
 *     the way round to get off where they got on.
 *   - Trains whose direction cannot be established. Guessing would file one under two
 *     buttons at once.
 *
 * A station two directions reach in exactly the same time is listed under both. That is a
 * real choice, and hiding one side of it would be the list deciding for you. It also means
 * no tiebreak is ever needed: every row carries its direction, so the row you tap is the
 * way you are going.
 */
export function directDestinations(
  from: string,
  services: readonly NormalizedService[],
  directionOf: (service: NormalizedService) => Compass | null,
  nameOf: (crs: string) => string
): TaggedDestination[] {
  /** crs -> direction -> { fastest, trains } */
  const seen = new Map<string, Map<Compass, { minutes: number; trains: number }>>();

  for (const service of services) {
    const direction = directionOf(service);
    if (!direction) continue;

    const boarding = service.stops[0];
    if (!boarding?.timeInstant) continue;

    // A train counts once per destination, however many times it passes through it.
    const counted = new Set<string>();

    for (const stop of service.stops.slice(1)) {
      if (!stop.crs || !stop.timeInstant) continue;
      if (stop.crs === from) continue;
      if (stop.canAlight === false) continue;

      const minutes = minutesBetween(boarding.timeInstant, stop.timeInstant);
      if (!Number.isFinite(minutes) || minutes < 0) continue;

      let byDirection = seen.get(stop.crs);
      if (!byDirection) seen.set(stop.crs, (byDirection = new Map()));
      const entry = byDirection.get(direction) ?? { minutes, trains: 0 };
      entry.minutes = Math.min(entry.minutes, minutes);
      if (!counted.has(stop.crs)) {
        entry.trains += 1;
        counted.add(stop.crs);
      }
      byDirection.set(direction, entry);
    }
  }

  const out: TaggedDestination[] = [];
  for (const [crs, byDirection] of seen) {
    const fastest = Math.min(...[...byDirection.values()].map((e) => e.minutes));
    for (const [direction, entry] of byDirection) {
      // §14: a destination belongs to the direction that reaches it fastest. Ties stay.
      if (entry.minutes !== fastest) continue;
      out.push({ crs, name: nameOf(crs), minutes: entry.minutes, direction, trains: entry.trains });
    }
  }

  const order = (d: Compass) => COMPASS_POINTS.indexOf(d);
  return out.sort(
    (a, b) => order(a.direction) - order(b.direction) || a.minutes - b.minutes || a.name.localeCompare(b.name)
  );
}

/**
 * The few destinations to put at the top: the busiest that a direct train actually reaches.
 *
 * `busiest` is every station's ranking from the ORR matrix, direct or not; this keeps only
 * the ones in `destinations`, in that order. From Upminster that is West Ham, Fenchurch
 * Street and Barking — where the route order below them puts Fenchurch Street last.
 *
 * Nothing is offered for a short list. Below `minimumList` stations the whole list fits on
 * one screen, and a "popular" section would only repeat rows already in view.
 *
 * A station listed under two directions appears here once, under the direction with more
 * trains: a shortcut is for the usual way, and the full list below still shows both.
 */
export function popularAmong(
  destinations: readonly { crs: string; direction?: Compass | null; trains?: number }[],
  busiest: readonly string[],
  { count = 3, minimumList = 8 }: { count?: number; minimumList?: number } = {}
): { crs: string; direction: Compass | null }[] {
  const distinct = new Set(destinations.map((d) => d.crs));
  if (distinct.size < minimumList) return [];

  const order = (d: Compass | null | undefined) => (d ? COMPASS_POINTS.indexOf(d) : 99);
  const out: { crs: string; direction: Compass | null }[] = [];
  for (const crs of busiest) {
    const here = destinations.filter((d) => d.crs === crs);
    if (!here.length) continue;
    const best = [...here].sort(
      (a, b) => (b.trains ?? 0) - (a.trains ?? 0) || order(a.direction) - order(b.direction)
    )[0];
    out.push({ crs, direction: best.direction ?? null });
    if (out.length === count) break;
  }
  return out;
}
