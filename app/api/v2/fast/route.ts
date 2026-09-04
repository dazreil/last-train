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
import { DarwinError, departureBoard, normalize, toFastService, toServiceCalls } from '@/lib/darwin';
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
import {
  getCached,
  getCachedLocations,
  setCached,
  setCachedCalls,
  setCachedLocations,
  ttlSecondsFor,
} from '@/lib/cache';
import type { FastBoard, FastService } from '@/lib/nationalContract';
import type { LocationLineUpObject, ServiceLocation } from '@/lib/rtt';

export const runtime = 'nodejs';

/**
 * How many candidates get a calling pattern.
 *
 * Each one is a request, so this is the cost of the mode and it used to be the free
 * tier's 10/minute that set it. Eight covered the Upminster two-hour window in §14 and
 * kept a cold lookup to nine requests.
 *
 * **Fifteen now, because that is what the app can show.** The client pages three at a
 * time up to five pages and discards the rest, so anything above `perPage × maximumPages`
 * is paid for and thrown away. Eight was also the wrong shape: it does not divide by
 * three, so a full result was 3 + 3 + 2 and the last page arrived short — one train on it
 * whenever a candidate failed to price.
 *
 * The Team tier is what affords it: 40/minute against a worst case of sixteen requests for
 * a cold lookup, and `25000 ÷ 7` sustainable a day against a cost that is only paid when a
 * pair is looked at for the first time that day. Calling patterns are cached by service id
 * rather than by pair, so a second destination from the same station reuses most of them.
 *
 * Candidates past this are still counted and reported as `truncated` rather than silently
 * dropped.
 */
const PATTERN_BUDGET = 15;

/**
 * How long a board thinned by rate limiting may be cached.
 *
 * A pattern fetch that throws drops its train, so when the upstream is rate limited the
 * board comes back short — sometimes a single train out of seventy-odd. That is not the
 * real board, and the day TTL would replay it for the hour. A minute lets it be served
 * without hammering the upstream, and the next request recomputes against a pattern cache
 * that each attempt leaves warmer, so a thin board fills itself in over a few opens.
 */
const RATE_LIMITED_TTL = 60;

/**
 * How long a Darwin board is held.
 *
 * The board carries live times, so it is cached briefly — long enough to absorb a burst
 * of opens, short enough that a delay shows within a couple of minutes. The 100k/month
 * budget makes a frequent refetch affordable in a way the RTT minute never did.
 */
const DARWIN_TTL = 90;

/**
 * How long the calling points behind a Darwin service are kept.
 *
 * A timetabled pattern does not change through its service day, so the detail sheet can
 * read the day's copy safely. The board id is day-scoped, so a stale entry cannot outlive
 * the train it describes.
 */
const DARWIN_CALLS_TTL = 60 * 60 * 6;

/**
 * Which platform it leaves from.
 *
 * Free here: the filtered line-up already carries it for the origin, so this costs no
 * request on a route where every arrival costs one. A local copy for the same reason
 * `/api/v2/trains` keeps one — the shared helper in `lib/journeys` is private to the
 * module that answers the old web route.
 */
const platformOf = (service: LocationLineUpObject): string | null =>
  service.locationMetadata?.platform?.actual ??
  service.locationMetadata?.platform?.planned ??
  null;

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

  /*
   Darwin first, and for the live day only.

   `GetDepBoardWithDetails` brings the calling points with the board, so the whole screen
   is one request instead of one per train — the fan-out that let a single user exhaust
   the RTT minute. It looks about two hours ahead, which is what "the next trains from
   here" means, so it answers the live day directly.

   It cannot answer a future date, and near the end of the night the next direct train can
   be tomorrow morning, past its two-hour horizon — an empty board. Both of those fall
   through to the RTT path below, which reads to the end of the service day and rolls on
   to tomorrow's first trains. RTT stays the fallback; Darwin carries the common case.
  */
  if (date === today) {
    try {
      const board = await departureBoard(from.crs, {
        filterCrs: to.crs,
        filterType: 'to',
        numRows: 25,
      });
      const normalized = normalize(board);
      const services: FastService[] = [];
      for (const service of normalized) {
        const priced = toFastService(service, to.crs);
        if (!priced) continue;
        services.push(priced);
        // The tap that opens this train reads its stops from here; the board already
        // fetched them, so the detail sheet costs no request of its own.
        setCachedCalls(service.serviceId, toServiceCalls(service), DARWIN_CALLS_TTL);
      }

      if (services.length > 0) {
        const body: FastBoard = {
          from: { crs: from.crs, name: from.name, locality: from.locality },
          to: { crs: to.crs, name: to.name, locality: to.locality },
          date,
          services,
          candidates: normalized.length,
          // The board returns every calling train in the window, so nothing was left
          // unpriced for want of a budget.
          truncated: false,
        };
        setCached(key, body, DARWIN_TTL);
        return NextResponse.json(body, { headers: { 'x-cache': 'MISS', 'x-source': 'darwin' } });
      }
      // Empty window: the next direct train is beyond two hours. RTT answers it.
    } catch (error) {
      // Darwin down or misconfigured: the screen still works, on RTT.
      if (!(error instanceof DarwinError)) throw error;
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
  // Pattern fetches that threw rather than answering. Above zero means the upstream was
  // rate limiting, so trains dropped out and this board is thinner than the real one.
  let fetchFailures = 0;

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
        // rest still answer. But count it: a throw is the upstream refusing, not the
        // train being unpriceable, and enough of them mean the board is short.
        fetchFailures += 1;
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
      platform: platformOf(candidate),
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

  /*
   Cache the full board for the day, a rate-limited one for only a minute.

   `pricedNothing` is the limit case — every fetch threw — and is never cached, so a
   refresh is not the only way back from it. Short of that limit, a board with any thrown
   fetch is still short of the trains rate limiting swallowed; caching it for the hour is
   what pinned a single train to the top for an hour. A minute serves it without a
   recompute per request, and lets the next open fill it in.
  */
  let outcome: 'MISS' | 'PARTIAL' | 'SKIP';
  if (pricedNothing) {
    outcome = 'SKIP';
  } else if (fetchFailures > 0) {
    setCached(key, body, RATE_LIMITED_TTL);
    outcome = 'PARTIAL';
  } else {
    setCached(key, body, ttl);
    outcome = 'MISS';
  }

  return NextResponse.json(body, { headers: { 'x-cache': outcome } });
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
