/**
 * GET /api/v2/fast?from=UPM&to=SOC&date=2026-08-10
 *   -> { from, to, date, services: [...], candidates, truncated }
 *
 * Every direct train from A to B, with the arrival worked out for each.
 *
 * **This route does not rank.** It does the expensive half — one filtered line-up, then a
 * calling pattern per candidate — and hands back the pairs in departure order. `FastBoard`
 * in `LastTrainCore` puts them in arrival order. Keeping the rule in one place matters
 * more than saving the client a sort: `lib/compass.ts` and `Direction.swift` are already
 * a pair that must agree, and one such pair is enough.
 *
 * IOS.md §14 has the measurement this is built on. `filterTo` returns the candidate set
 * for one request and carries no arrival time at all, so the arrival costs a pattern per
 * train. That is the whole cost of the mode.
 */

import { NextResponse } from 'next/server';

import { locationLineUp, serviceDetail } from '@/lib/rtt';
import {
  currentServiceDate,
  formatLondonTime,
  isValidIsoDate,
  londonDateOf,
  serviceDayWindow,
  toInstantMillis,
  type IsoDate,
} from '@/lib/serviceDay';
import { findStationByCrs } from '@/lib/nationalStations';
import { getCached, getCachedLocations, setCached, setCachedLocations, ttlSecondsFor } from '@/lib/cache';
import type { FastBoard, FastService } from '@/lib/nationalContract';
import type { ServiceLocation } from '@/lib/rtt';

export const runtime = 'nodejs';

/**
 * How many candidates get a calling pattern.
 *
 * Each one is a request. Eight is what the Upminster measurement in §14 needed to cover
 * a two-hour window, and it leaves the worst case at nine requests for a cold lookup —
 * the same order as a board. Candidates past this are counted and reported as
 * `truncated` rather than silently dropped.
 */
const PATTERN_BUDGET = 8;

const answerKey = (from: string, to: string, date: IsoDate) => `fast:${from}:${to}:${date}`;

/** Now, as a naive London ISO string — the same shape the API's own times use. */
function londonNow(now: Date = new Date()): string {
  const iso = now.toISOString();
  return `${londonDateOf(iso)}T${formatLondonTime(iso)}:00`;
}

const maxIso = (a: string, b: string): string => (a >= b ? a : b);

const describe = (list: { location?: { description?: string } }[] | undefined): string =>
  (list ?? [])
    .map((entry) => entry.location?.description)
    .filter((name): name is string => Boolean(name))
    .join(' & ');

export async function GET(request: Request) {
  const params = new URL(request.url).searchParams;
  const fromCrs = (params.get('from') ?? '').trim().toUpperCase();
  const toCrs = (params.get('to') ?? '').trim().toUpperCase();

  const from = findStationByCrs(fromCrs);
  const to = findStationByCrs(toCrs);

  if (!from || !to) {
    return NextResponse.json({ error: 'Both from and to must be stations.' }, { status: 400 });
  }
  if (from.crs === to.crs) {
    // Not an error worth a stack trace, but not an answerable question either.
    return NextResponse.json({ error: 'Those are the same station.' }, { status: 400 });
  }

  const today = currentServiceDate();
  const date = params.get('date') ?? today;
  if (!isValidIsoDate(date)) {
    return NextResponse.json({ error: 'date must be YYYY-MM-DD.' }, { status: 400 });
  }

  const key = answerKey(from.crs, to.crs, date);
  if (params.get('refresh') !== '1') {
    const cached = getCached<FastBoard>(key);
    if (cached) {
      return NextResponse.json(cached.value, { headers: { 'x-cache': 'HIT' } });
    }
  }

  const window = serviceDayWindow(date);
  if (!window) {
    return NextResponse.json({ error: 'That date has no service day.' }, { status: 400 });
  }

  /*
   On the live day the window starts now, not at 03:00.

   Only eight candidates get priced, and Upminster to Southend has 106 in a day — so a
   window that begins at the start of the service day spends the whole budget on the
   dawn trains and answers a question nobody asked. Fast Train shows the next four from
   where you are standing, which means the window has to start there too.

   Both strings are naive London ISO in the same shape, so comparing them as text is the
   comparison, not an approximation of it.
  */
  const timeFrom =
    date === today ? maxIso(window.timeFrom, londonNow()) : window.timeFrom;

  let lineUp;
  try {
    // One request, and it does the hardest part: only trains that call at the
    // destination come back. Nothing here has to work out which way a train goes.
    lineUp = await locationLineUp({
      code: from.crs,
      filterTo: to.crs,
      timeFrom,
      timeTo: window.timeTo,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Could not look that up.';
    return NextResponse.json({ error: message }, { status: 502 });
  }

  const boardable = (lineUp?.services ?? []).filter(
    (service) => service.temporalData?.displayAs !== 'PASS'
  );

  const candidates = boardable.length;
  const priced = boardable.slice(0, PATTERN_BUDGET);
  const ttl = ttlSecondsFor(date);

  const services: FastService[] = [];

  for (const candidate of priced) {
    const id = candidate.scheduleMetadata?.uniqueIdentity;
    if (!id) continue;

    let locations: ServiceLocation[] | null = null;
    const cachedPattern = getCachedLocations<ServiceLocation[] | null>(id);

    if (cachedPattern) {
      locations = cachedPattern.value;
    } else {
      try {
        const detail = await serviceDetail(id);
        locations = detail?.service?.locations ?? null;
        if (locations) setCachedLocations(id, locations, ttl);
      } catch {
        // One train that cannot be priced is not a failed lookup. It drops out and the
        // rest still answer.
        continue;
      }
    }

    if (!locations) continue;

    const service = priceOne(from.crs, to.crs, locations);
    if (!service) continue;

    services.push({
      serviceId: id,
      headcode: candidate.scheduleMetadata?.trainReportingIdentity ?? null,
      toc: candidate.scheduleMetadata?.operator?.code ?? '??',
      tocName: candidate.scheduleMetadata?.operator?.name ?? 'Unknown operator',
      destination: describe(candidate.destination),
      ...service,
    });
  }

  const body: FastBoard = {
    from: { crs: from.crs, name: from.name, locality: from.locality },
    to: { crs: to.crs, name: to.name, locality: to.locality },
    date,
    services,
    candidates,
    truncated: candidates > priced.length,
  };

  /*
   Never cache "found trains, priced none".

   Every arrival costs a calling pattern, and a pattern fetch that throws drops its train
   silently so the rest can still answer. When the upstream is rate limited *every* fetch
   throws, so the board comes back with candidates and no services -- a failure wearing
   the shape of an answer. Cached for the hour, it then replays as "nothing direct left"
   at midday, and `refresh=1` is the only way out.

   Observed on the deployment: Upminster to West Horndon, 25 candidates, none priced,
   while a refresh returned the 13:26 immediately.

   An empty board with no candidates is a real answer and is cached as one.
  */
  const pricedNothing = services.length === 0 && candidates > 0;
  if (!pricedNothing) setCached(key, body, ttl);

  return NextResponse.json(body, {
    headers: { 'x-cache': pricedNothing ? 'SKIP' : 'MISS' },
  });
}

/**
 * The departure and the arrival, from one calling pattern.
 *
 * Returns null for the three cases `FastBoard.service` refuses, and for the same
 * reasons — the two must agree, so the reasons are written in both places. The
 * destination is searched for **from the boarding point on**: the same pair of stations
 * appears in a train going each way, and only the order separates them.
 */
function priceOne(
  origin: string,
  destination: string,
  locations: ServiceLocation[]
): Pick<FastService, 'departure' | 'departureInstant' | 'arrival' | 'arrivalInstant'> | null {
  const boarding = locations.findIndex((stop) => stop.location?.shortCodes?.[0] === origin);
  if (boarding === -1) return null;

  const offset = locations
    .slice(boarding)
    .findIndex((stop) => stop.location?.shortCodes?.[0] === destination);
  if (offset === -1) return null;

  const alighting = boarding + offset;

  const departureInstant = locations[boarding].temporalData?.departure?.scheduleAdvertised;
  const arrivalInstant =
    locations[alighting].temporalData?.arrival?.scheduleAdvertised ??
    locations[alighting].temporalData?.departure?.scheduleAdvertised;

  if (!departureInstant || !arrivalInstant) return null;

  // A journey that ends before it starts is a parsing failure in disguise.
  if (toInstantMillis(arrivalInstant) <= toInstantMillis(departureInstant)) return null;

  const departure = formatLondonTime(departureInstant);
  const arrival = formatLondonTime(arrivalInstant);
  if (!departure || !arrival) return null;

  return { departure, departureInstant, arrival, arrivalInstant };
}
