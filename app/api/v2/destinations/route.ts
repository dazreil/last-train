/**
 * GET /api/v2/destinations?from=UPM&direction=east
 * GET /api/v2/destinations?from=UPM
 *   -> { destinations: [{ crs, name, minutes, direction }], truncated }
 *
 * Every station you can reach directly from here — that way, or with no direction, every
 * way at once, each station tagged with the way you head to reach it.
 *
 * **The timetable answers first, for the whole service day.** One read of the stored board,
 * no upstream request, and the unfiltered list and every filtered one come from the same
 * computation, so "all" and "west" can never disagree. The live Darwin and RTT paths below
 * remain for a direction the timetable cannot answer — a day it does not cover. The
 * unfiltered list has no live fallback: building it live would cost a board per direction,
 * and the app can always fall back to asking which way.
 *
 * Fast Train offers a list rather than a search box. The list has to be built from real
 * calling patterns, because a station's *final* destinations are only three or four names
 * and the place you are going is usually somewhere in between.
 *
 * Sorted by journey time, shortest first, which on a railway is also the order you pass
 * through them. It is the sort a passenger expects and it needs no notion of route order.
 *
 * The journey times are the point, not a decoration: §14's rule is that a destination
 * belongs to the direction that reaches it **fastest**, and this is where that number
 * comes from.
 */

import { NextResponse } from 'next/server';

import { locationLineUp, serviceDetail } from '@/lib/rtt';
import { DarwinError, departureBoard, normalize } from '@/lib/darwin';
import {
  currentServiceDate,
  formatLondonTime,
  isValidIsoDate,
  londonDateOf,
  minutesBetween,
  serviceDayWindow,
  toInstantMillis,
  type IsoDate,
} from '@/lib/serviceDay';
import { classify, COMPASS_POINTS, isCompass, type Compass } from '@/lib/compass';
import { directDestinations, popularAmong } from '@/lib/directDestinations';
import { busiestFrom, popularitySource } from '@/lib/popularity';
import { timetableBoard } from '@/lib/timetable';
import type { NormalizedService } from '@/lib/darwin';
import { coordinateFor, findStationByCrs } from '@/lib/nationalStations';
import { waypointFor } from '@/lib/adjacency';
import { getCached, getCachedLocations, setCached, setCachedLocations, ttlSecondsFor } from '@/lib/cache';
import type { Destination, DestinationList } from '@/lib/nationalContract';
import type { ServiceLocation } from '@/lib/rtt';

export const runtime = 'nodejs';

/**
 * How many services get their pattern read.
 *
 * A direction usually runs three or four distinct stopping patterns, so this covers the
 * routes rather than merely the first few trains — and every pattern missed is a place
 * that never appears in the picker, which is a destination you cannot choose rather than
 * a list that is merely shorter.
 *
 * **Fifteen, deliberately the same number as `/api/v2/fast`.** They share the pattern
 * cache, keyed by service id, so choosing a destination straight after opening this list
 * is largely paid for already — and that property only holds while the two agree. Eight
 * was the free tier's ceiling for both; raise or lower them together.
 */
const PATTERN_BUDGET = 15;

/** How far the RTT fallback reaches — the same two hours Darwin sees, so it stays cheap. */
const FALLBACK_WINDOW_MINUTES = 120;

const maxIso = (a: string, b: string): string => (a >= b ? a : b);
const minIso = (a: string, b: string): string => (a <= b ? a : b);

/** Now, as a naive London ISO string — the same shape the API's own times use. */
function londonNow(now: Date = new Date()): string {
  const iso = now.toISOString();
  return `${londonDateOf(iso)}T${formatLondonTime(iso)}:00`;
}

/** A naive London ISO shifted by whole minutes, staying on the same clock. */
function addMinutesLondon(naive: string, minutes: number): string {
  const iso = new Date(toInstantMillis(naive) + minutes * 60_000).toISOString();
  return `${londonDateOf(iso)}T${formatLondonTime(iso)}:00`;
}

const key = (crs: string, direction: string, date: IsoDate) => `dest:${crs}:${direction}:${date}`;

export async function GET(request: Request) {
  const params = new URL(request.url).searchParams;
  const fromCrs = (params.get('from') ?? '').trim().toUpperCase();
  const requested = (params.get('direction') ?? '').trim().toLowerCase();
  // No direction means every direction. The app sends none until you have chosen one.
  const everyWay = requested === '' || requested === 'all';

  const from = findStationByCrs(fromCrs);
  if (!from) return NextResponse.json({ error: 'Unknown station.' }, { status: 400 });
  if (!everyWay && !isCompass(requested)) {
    return NextResponse.json({ error: 'direction must be a compass point.' }, { status: 400 });
  }

  const today = currentServiceDate();
  const date = params.get('date') ?? today;
  if (!isValidIsoDate(date)) {
    return NextResponse.json({ error: 'date must be YYYY-MM-DD.' }, { status: 400 });
  }

  const fromTimetable = await timetableList(from, date);
  if (fromTimetable) {
    const destinations = everyWay
      ? fromTimetable
      : fromTimetable.filter((destination) => destination.direction === requested);
    const body: DestinationList = {
      from: { crs: from.crs, name: from.name },
      direction: everyWay ? null : requested,
      date,
      destinations,
      // Nothing to budget: the board carries every train's calling points.
      truncated: false,
      // The whole day, every direction, in one pass — so the fastest-direction rule saw
      // everything it could have compared against.
      comparedWith: everyWay ? [...COMPASS_POINTS] : COMPASS_POINTS.filter((p) => p !== requested),
      source: 'timetable',
      ...popularity(from.crs, destinations, everyWay ? null : (requested as Compass)),
    };
    return NextResponse.json(body, { headers: { 'x-source': 'timetable' } });
  }

  if (everyWay) {
    return NextResponse.json(
      {
        error: 'Pick the direction you are heading to see where trains go from here.',
        needsDirection: true,
      },
      { status: 503 }
    );
  }
  const direction: Compass = requested as Compass;

  const cacheKey = key(from.crs, direction, date);
  if (params.get('refresh') !== '1') {
    const hit = await getCached<DestinationList>(cacheKey);
    if (hit) return NextResponse.json(hit.value, { headers: { 'x-cache': 'HIT' } });
  }

  /*
   Darwin first, live day only — one request, calling points attached.

   The reachable set is read straight from the board's own calling points, so the list is
   built without a pattern fetch per train. The waypoint filters the board to this
   direction exactly as it filtered the RTT line-up; without one, the bearing rule sorts
   the board by each train's terminus, as before. A future date or an empty board falls
   through to the RTT path below.
  */
  if (date === today) {
    try {
      const waypoint = waypointFor(from.crs, direction);
      const board = await departureBoard(
        from.crs,
        waypoint ? { filterCrs: waypoint, filterType: 'to', numRows: 40 } : { numRows: 40 }
      );
      let reachable = normalize(board);

      if (!waypoint) {
        const origin = coordinateFor([from.name], [from.crs]);
        if (!origin) {
          return NextResponse.json(
            { error: 'That station has no position to work from.' },
            { status: 422 }
          );
        }
        reachable = reachable.filter((service) => {
          const terminus = service.stops[service.stops.length - 1];
          const to = coordinateFor([service.destinationName], terminus?.crs ? [terminus.crs] : []);
          return classify(origin, to) === direction;
        });
      }

      const best = new Map<string, number>();
      for (const service of reachable) {
        const boarding = service.stops[0];
        if (!boarding?.timeInstant) continue;
        for (const stop of service.stops.slice(1)) {
          if (!stop.crs || !stop.timeInstant) continue;
          const minutes = minutesBetween(boarding.timeInstant, stop.timeInstant);
          if (!Number.isFinite(minutes) || minutes <= 0) continue;
          const seen = best.get(stop.crs);
          if (seen === undefined || minutes < seen) best.set(stop.crs, minutes);
        }
      }

      if (best.size > 0) {
        const body = await assembleList(from, direction, date, best, false);
        await setCached(cacheKey, body, ttlSecondsFor(date));
        return NextResponse.json(body, { headers: { 'x-cache': 'MISS', 'x-source': 'darwin' } });
      }
    } catch (error) {
      if (!(error instanceof DarwinError)) throw error;
    }
  }

  const window = serviceDayWindow(date);
  const waypoint = waypointFor(from.crs, direction);

  // The RTT fallback matches Darwin's two-hour reach so it prices a handful of trains, not
  // the whole day — the fan-out that could exhaust the rate limit when the picker is opened
  // at a quiet station. On a future date the whole window stays, but that path is rare.
  const timeFrom = date === today ? maxIso(window.timeFrom, londonNow()) : window.timeFrom;
  const timeTo =
    date === today
      ? minIso(window.timeTo, addMinutesLondon(timeFrom, FALLBACK_WINDOW_MINUTES))
      : window.timeTo;

  let lineUp;
  try {
    // The waypoint picks out this direction exactly, the same way the board does. Without
    // one the whole day comes back and the bearing rule sorts it, which is the older and
    // less reliable answer -- see §13.
    lineUp = await locationLineUp({
      code: from.crs,
      ...(waypoint ? { filterTo: waypoint } : {}),
      timeFrom,
      timeTo,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Could not look that up.';
    return NextResponse.json({ error: message }, { status: 502 });
  }

  // The station is in the table by construction, so this is a type narrowing rather
  // than a real branch -- but a station with no coordinate cannot be classified, and
  // saying so beats classifying it wrongly.
  const origin = coordinateFor([from.name], [from.crs]);
  if (!origin && !waypoint) {
    return NextResponse.json({ error: 'That station has no position to work from.' }, { status: 422 });
  }

  let services = (lineUp?.services ?? []).filter(
    (service) => service.temporalData?.displayAs !== 'PASS'
  );

  if (!waypoint) {
    services = services.filter((service) => {
      const to = coordinateFor(
        (service.destination ?? []).map((d) => d.location?.description ?? ''),
        (service.destination ?? []).flatMap((d) => d.location?.shortCodes ?? [])
      );
      return classify(origin!, to) === direction;
    });
  }

  const ttl = ttlSecondsFor(date);
  const priced = services.slice(0, PATTERN_BUDGET);

  /** crs -> the shortest journey seen. A station served by two patterns keeps the best. */
  const best = new Map<string, number>();

  for (const service of priced) {
    const id = service.scheduleMetadata?.uniqueIdentity;
    if (!id) continue;

    let locations: ServiceLocation[] | null = null;
    const cached = await getCachedLocations<ServiceLocation[] | null>(id);

    if (cached) {
      locations = cached.value;
    } else {
      try {
        const detail = await serviceDetail(id);
        locations = detail?.service?.locations ?? null;
        if (locations) await setCachedLocations(id, locations, ttl);
      } catch {
        continue;
      }
    }

    if (!locations) continue;
    collect(from.crs, locations, best);
  }

  /*
   A destination belongs to the direction that reaches it fastest -- §14.

   At Upminster the loop runs south and rejoins the main line at Pitsea. Left alone this
   list offers Pitsea at 34 minutes and Southend at 50, when east does them in 15 and 31.
   Dropping every station another direction beats ends the south list at Stanford-le-Hope
   on its own, which is where the loop stops winning. No junction is named anywhere.

   Compared against cached sibling lists only. Fetching the other three would cost four
   line-ups and thirty-odd patterns for one screen, and the exact answer belongs in the
   walk, which already holds every stop sequence it needs. Until then the check is as good
   as what has been looked at, and `comparedWith` says how good that is.
  */
  const comparedWith: string[] = [];
  const beaten = new Map<string, number>();

  for (const point of COMPASS_POINTS) {
    if (point === direction) continue;
    const sibling = await getCached<DestinationList>(key(from.crs, point, date));
    if (!sibling) continue;

    comparedWith.push(point);
    for (const other of sibling.value.destinations) {
      const seen = beaten.get(other.crs);
      if (seen === undefined || other.minutes < seen) beaten.set(other.crs, other.minutes);
    }
  }

  const destinations: Destination[] = [...best.entries()]
    .filter(([crs, minutes]) => {
      const rival = beaten.get(crs);
      // Ties stay. Two directions reaching a place in the same time is a real choice,
      // and dropping one of them would hide it.
      return rival === undefined || minutes <= rival;
    })
    .map(([crs, minutes]) => ({ crs, name: findStationByCrs(crs)?.name ?? crs, minutes }))
    .sort((a, b) => a.minutes - b.minutes || a.name.localeCompare(b.name));

  const body: DestinationList = {
    from: { crs: from.crs, name: from.name },
    direction,
    date,
    destinations,
    truncated: services.length > priced.length,
    comparedWith,
    ...popularity(from.crs, destinations, direction),
  };

  await setCached(cacheKey, body, ttl);

  return NextResponse.json(body, { headers: { 'x-cache': 'MISS' } });
}

/**
 * The reachable set, filtered against the other directions and sorted, as the wire shape.
 *
 * §14's rule lives here: a destination another direction reaches faster drops out, and the
 * comparison is against whatever sibling lists are cached — `comparedWith` says which. The
 * Darwin and RTT paths both end here, so the rule is written once.
 */
async function assembleList(
  from: { crs: string; name: string },
  direction: string,
  date: IsoDate,
  best: Map<string, number>,
  truncated: boolean
): Promise<DestinationList> {
  const comparedWith: string[] = [];
  const beaten = new Map<string, number>();

  for (const point of COMPASS_POINTS) {
    if (point === direction) continue;
    const sibling = await getCached<DestinationList>(key(from.crs, point, date));
    if (!sibling) continue;

    comparedWith.push(point);
    for (const other of sibling.value.destinations) {
      const seen = beaten.get(other.crs);
      if (seen === undefined || other.minutes < seen) beaten.set(other.crs, other.minutes);
    }
  }

  const destinations: Destination[] = [...best.entries()]
    .filter(([crs, minutes]) => {
      const rival = beaten.get(crs);
      return rival === undefined || minutes <= rival;
    })
    .map(([crs, minutes]) => ({ crs, name: findStationByCrs(crs)?.name ?? crs, minutes }))
    .sort((a, b) => a.minutes - b.minutes || a.name.localeCompare(b.name));

  return {
    from: { crs: from.crs, name: from.name },
    direction,
    date,
    destinations,
    truncated,
    comparedWith,
    ...popularity(from.crs, destinations, direction as Compass),
  };
}

/**
 * The busiest few destinations, for the top of the picker, with their source.
 *
 * Every path that returns a list ends here, so the shortcut is the same whichever path
 * answered. A live list carries no per-station direction, so it takes the one asked for.
 */
function popularity(
  fromCrs: string,
  destinations: readonly Destination[],
  direction: Compass | null
): Pick<DestinationList, 'popular' | 'popularSource'> {
  const popular = popularAmong(
    destinations.map((d) => ({ ...d, direction: d.direction ?? direction })),
    busiestFrom(fromCrs)
  );
  return popular.length ? { popular, popularSource: popularitySource } : { popular: [] };
}

/**
 * Every stop after this one, with how long it takes to reach.
 *
 * Only what comes *after* the origin in the pattern. A train calls at the same pair of
 * stations going each way, and the order is the only thing that separates them — the same
 * reason `/api/v2/fast` searches from the boarding point on.
 */
function collect(origin: string, locations: ServiceLocation[], best: Map<string, number>): void {
  const boarding = locations.findIndex((stop) => stop.location?.shortCodes?.[0] === origin);
  if (boarding === -1) return;

  const departure = locations[boarding].temporalData?.departure?.scheduleAdvertised;
  if (!departure) return;

  for (const stop of locations.slice(boarding + 1)) {
    const crs = stop.location?.shortCodes?.[0];
    if (!crs) continue;

    const arrival =
      stop.temporalData?.arrival?.scheduleAdvertised ??
      stop.temporalData?.departure?.scheduleAdvertised;
    if (!arrival) continue;

    const minutes = minutesBetween(departure, arrival);
    if (!Number.isFinite(minutes) || minutes <= 0) continue;

    const seen = best.get(crs);
    if (seen === undefined || minutes < seen) best.set(crs, minutes);
  }
}

/**
 * The whole day's direct destinations from the stored timetable, or null when it cannot say.
 *
 * Null sends the caller to the live path. An empty array is a real answer — the timetable
 * covers this day and nothing leaves this station — and is returned as one, rather than
 * falling through to a live lookup that would reach the same conclusion more slowly.
 */
async function timetableList(
  from: { crs: string; name: string },
  date: IsoDate
): Promise<(Destination & { direction: Compass; trains: number })[] | null> {
  const stored = await timetableBoard(from.crs, date);

  if (stored.status === 'missing') {
    return stored.meta?.serviceDates.includes(date) ? [] : null;
  }
  if (stored.status !== 'ok' && stored.status !== 'stale') return null;

  const origin = coordinateFor([from.name], [from.crs]);
  const waypoints = COMPASS_POINTS.map((point) => [point, waypointFor(from.crs, point)] as const);

  /**
   * The board's own rule, restated for a timetable train.
   *
   * Where a direction has a waypoint, that direction's board is the trains that call at it —
   * so a train that does is that way, and nothing else is. Where it has none, the board sorts
   * by the bearing to where the train ends. One subtlety makes the two agree: a train whose
   * bearing points at a direction that *does* have a waypoint, but which misses it, is on no
   * board at all. It is left out here too, because a destination offered under a direction
   * whose board does not carry the train is exactly the bug this list exists to prevent.
   */
  const directionOf = (service: NormalizedService): Compass | null => {
    const onward = new Set(service.stops.slice(1).map((stop) => stop.crs));
    for (const [point, waypoint] of waypoints) {
      if (waypoint && onward.has(waypoint)) return point;
    }
    if (!origin) return null;
    const terminus = service.stops[service.stops.length - 1];
    const to = coordinateFor([service.destinationName], terminus?.crs ? [terminus.crs] : []);
    const bearing = classify(origin, to);
    if (!bearing || waypointFor(from.crs, bearing)) return null;
    return bearing;
  };

  return directDestinations(
    from.crs,
    stored.services,
    directionOf,
    (crs) => findStationByCrs(crs)?.name ?? crs
  );
}
