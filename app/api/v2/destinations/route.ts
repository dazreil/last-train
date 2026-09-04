/**
 * GET /api/v2/destinations?from=UPM&direction=east
 *   -> { destinations: [{ crs, name, minutes }], truncated }
 *
 * Every station you can reach directly from here, that way.
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
  isValidIsoDate,
  minutesBetween,
  serviceDayWindow,
  type IsoDate,
} from '@/lib/serviceDay';
import { classify, COMPASS_POINTS, isCompass } from '@/lib/compass';
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

const key = (crs: string, direction: string, date: IsoDate) => `dest:${crs}:${direction}:${date}`;

export async function GET(request: Request) {
  const params = new URL(request.url).searchParams;
  const fromCrs = (params.get('from') ?? '').trim().toUpperCase();
  const direction = (params.get('direction') ?? '').trim().toLowerCase();

  const from = findStationByCrs(fromCrs);
  if (!from) return NextResponse.json({ error: 'Unknown station.' }, { status: 400 });
  if (!isCompass(direction)) {
    return NextResponse.json({ error: 'direction must be a compass point.' }, { status: 400 });
  }

  const today = currentServiceDate();
  const date = params.get('date') ?? today;
  if (!isValidIsoDate(date)) {
    return NextResponse.json({ error: 'date must be YYYY-MM-DD.' }, { status: 400 });
  }

  const cacheKey = key(from.crs, direction, date);
  if (params.get('refresh') !== '1') {
    const hit = getCached<DestinationList>(cacheKey);
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
        const body = assembleList(from, direction, date, best, false);
        setCached(cacheKey, body, ttlSecondsFor(date));
        return NextResponse.json(body, { headers: { 'x-cache': 'MISS', 'x-source': 'darwin' } });
      }
    } catch (error) {
      if (!(error instanceof DarwinError)) throw error;
    }
  }

  const window = serviceDayWindow(date);
  const waypoint = waypointFor(from.crs, direction);

  let lineUp;
  try {
    // The waypoint picks out this direction exactly, the same way the board does. Without
    // one the whole day comes back and the bearing rule sorts it, which is the older and
    // less reliable answer -- see §13.
    lineUp = await locationLineUp({
      code: from.crs,
      ...(waypoint ? { filterTo: waypoint } : {}),
      ...window,
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
    const cached = getCachedLocations<ServiceLocation[] | null>(id);

    if (cached) {
      locations = cached.value;
    } else {
      try {
        const detail = await serviceDetail(id);
        locations = detail?.service?.locations ?? null;
        if (locations) setCachedLocations(id, locations, ttl);
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
    const sibling = getCached<DestinationList>(key(from.crs, point, date));
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
  };

  setCached(cacheKey, body, ttl);

  return NextResponse.json(body, { headers: { 'x-cache': 'MISS' } });
}

/**
 * The reachable set, filtered against the other directions and sorted, as the wire shape.
 *
 * §14's rule lives here: a destination another direction reaches faster drops out, and the
 * comparison is against whatever sibling lists are cached — `comparedWith` says which. The
 * Darwin and RTT paths both end here, so the rule is written once.
 */
function assembleList(
  from: { crs: string; name: string },
  direction: string,
  date: IsoDate,
  best: Map<string, number>,
  truncated: boolean
): DestinationList {
  const comparedWith: string[] = [];
  const beaten = new Map<string, number>();

  for (const point of COMPASS_POINTS) {
    if (point === direction) continue;
    const sibling = getCached<DestinationList>(key(from.crs, point, date));
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

  return { from: { crs: from.crs, name: from.name }, direction, date, destinations, truncated, comparedWith };
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
