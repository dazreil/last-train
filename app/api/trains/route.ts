/**
 * GET /api/trains?from=GRY&direction=east&date=2026-07-28
 *   -> { mode, services: [ { dep, destination, via, role, … } ], towards: [...] }
 *
 * This route exists so the RTT token stays on the server. It is the only thing in
 * the app that can reach the API.
 *
 * The answer comes in one of two arrangements, chosen by the clock in `lib/board.ts`:
 *
 *   normal        the last three trains of the service day on the board, then the
 *                 first train of the *next* one -- the "if I miss it" answer. Today's
 *                 own first train is not shown at 22:00, because it went at dawn.
 *   pre-service   the day on the board has not started running yet, so its first
 *                 three are the answer, with its last train kept below them.
 *
 * Per uncached lookup: one unfiltered location line-up per service day involved --
 * two in normal mode, one in pre-service -- plus a service query for each service
 * that needs one, to establish the route it takes and to confirm it calls somewhere
 * in scope. Line-ups are cached separately from answers, so tapping East and then
 * West costs one API call between them, not two, and the next day's line-up is
 * fetched once an evening rather than once a lookup.
 */

import {
  RttError,
  locationLineUp,
  serviceDetail,
  rateLimitSnapshot,
  API_VERSION,
  type LocationLineUpResponse,
  type ServiceLocation,
} from '@/lib/rtt';
import {
  sortedDepartures,
  destinationCodes,
  destinationNames,
  servesScopeAhead,
  toDepartureService,
  type Departure,
} from '@/lib/journeys';
import { boardHasExpired, boardMode, selectBoard } from '@/lib/board';
import { classifyDirection, isDirection, isOperatorInScope, type Direction } from '@/lib/direction';
import { isCorridorDestination, longitudeOf } from '@/lib/geo';
import {
  currentServiceDate,
  isValidIsoDate,
  serviceDayWindow,
  addDays,
  type IsoDate,
} from '@/lib/serviceDay';
import {
  cacheKey,
  lineUpKey,
  getCached,
  setCached,
  getCachedLineUp,
  setCachedLineUp,
  getCachedPattern,
  setCachedPattern,
  ttlSecondsFor,
} from '@/lib/cache';
import { findStation, isKnownStation, isKnownStationName, routeMarkers } from '@/lib/stations';
import type { TrainsResponse } from '@/lib/contract';

export const runtime = 'nodejs';

/**
 * Ceiling on speculative corridor checks per lookup.
 *
 * Checks are only needed for services bound outside the app's station list, which in
 * practice means Liverpool Street and nowhere else; their patterns are then reused
 * for route labelling. Four leaves room in the budget below for the services that
 * actually get shown, which matter more than the ones being sifted.
 */
const VERIFY_BUDGET = 4;

/**
 * Ceiling on service queries per lookup, whatever they are for.
 *
 * The free tier allows ten requests a minute, and a lookup now spends up to two of
 * them on line-ups. Six leaves the worst case at eight, which is where it was before
 * the next service day was brought in -- so a single lookup still cannot exhaust the
 * minute on its own. Cache hits are free and do not count against it.
 */
const DETAIL_BUDGET = 6;

const json = (body: unknown, init?: ResponseInit) =>
  new Response(JSON.stringify(body), {
    ...init,
    headers: { 'content-type': 'application/json; charset=utf-8', ...init?.headers },
  });

const badRequest = (message: string) => json({ error: message }, { status: 400 });

/** The places the shown trains actually go, most frequent first, de-duplicated. */
function summariseDestinations(names: string[]): string[] {
  const counts = new Map<string, number>();
  for (const name of names) {
    if (name && name !== 'Unknown') counts.set(name, (counts.get(name) ?? 0) + 1);
  }
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, 3)
    .map(([name]) => name);
}

export async function GET(request: Request) {
  const params = new URL(request.url).searchParams;

  const fromCrs = (params.get('from') ?? '').trim().toUpperCase();
  const from = findStation(fromCrs);
  if (!from) return badRequest(`Unknown station code "${fromCrs}".`);

  const directionParam = (params.get('direction') ?? '').trim().toLowerCase();
  if (!isDirection(directionParam)) return badRequest('Direction must be east or west.');
  const direction: Direction = directionParam;

  const today = currentServiceDate();
  const date = (params.get('date') ?? today).trim();
  if (!isValidIsoDate(date)) return badRequest('Date must be YYYY-MM-DD.');
  if (date < addDays(today, -7) || date > addDays(today, 90)) {
    return badRequest('Date is outside the range the timetable covers.');
  }

  const refresh = params.get('refresh') === '1';
  const key = cacheKey(from.crs, direction, date);
  const ttl = ttlSecondsFor(date);

  if (!refresh) {
    const hit = getCached<TrainsResponse>(key);
    // A stored answer outlives its arrangement exactly once a day, when the first
    // train goes and a pre-service board becomes an ordinary one. Checked here rather
    // than keyed on, so the mode never forces a cache miss that costs an API call.
    if (hit && !boardHasExpired(hit.value)) {
      return json(hit.value, {
        headers: {
          'cache-control': `private, max-age=${Math.max(ttl - hit.ageSeconds, 0)}`,
          'x-cache': 'HIT',
        },
      });
    }
  }

  /**
   * Where the corridor does not continue, answer without asking.
   *
   * Eastbound from Shenfield or Shoeburyness there is nothing in scope: the app's
   * coverage ends there, and §6 is explicit that returning nothing for the Essex
   * branches beyond it is correct behaviour rather than a bug. Establishing that from
   * the bundled topology costs no API call, and it also keeps the corridor shortcut
   * below honest -- Colchester is a corridor destination, but from Shenfield the
   * corridor is behind you.
   */
  const onward = from.onward;
  if (onward && !onward.includes(direction)) {
    const body: TrainsResponse = {
      from: { crs: from.crs, name: from.name },
      direction,
      date,
      mode: 'normal',
      firstDate: addDays(date, 1),
      services: [],
      totalServices: 0,
      totalIsExact: true,
      towards: [],
      apiVersion: API_VERSION,
    };
    setCached(key, body, ttl);
    return json(body, {
      headers: { 'cache-control': `private, max-age=${ttl}`, 'x-cache': 'TOPOLOGY' },
    });
  }

  try {
    // ---- calling patterns ----------------------------------------------------
    //
    // Request-scoped, and shared across both service days: a budget that reset per
    // day would let one lookup spend twice what it used to.
    const patterns = new Map<string, ServiceLocation[] | null>();
    let checksSpent = 0;
    let detailsSpent = 0;
    let lineUpsFetched = 0;

    /**
     * Fetch a calling pattern, memoised for the request and cached across requests.
     *
     * A service's calling pattern on a given day never changes, so this is the safest
     * thing in the app to cache and the most valuable: at ten requests a minute, route
     * labels are most of a lookup's budget. Caching them makes the second and
     * subsequent lookups at a station nearly free -- which is what stops the `via`
     * labels quietly going missing at Fenchurch Street, where they matter most.
     */
    const fetchPattern = async (id: string) => {
      if (patterns.has(id)) return;

      const cached = getCachedPattern<ServiceLocation[] | null>(id);
      if (cached) {
        patterns.set(id, cached.value);
        return;
      }

      if (detailsSpent >= DETAIL_BUDGET) return;
      detailsSpent++;

      try {
        const detail = await serviceDetail(id);
        const locations = detail?.service?.locations ?? null;
        patterns.set(id, locations);
        if (locations) setCachedPattern(id, locations, ttl);
      } catch {
        // Not cached: a transient failure should not persist as a missing route.
        patterns.set(id, null);
      }
    };

    /**
     * Whether to show this service, reading its calling pattern only if it has to.
     *
     * Unverifiable services are kept, not dropped. Losing the last train of the night
     * to a failed side request, or to an exhausted budget, would be a far worse
     * outcome than showing one train too many -- and the destination is always on
     * screen, so an off-corridor train is visible for what it is.
     */
    const boundForKnownStation = (departure: Departure) =>
      destinationCodes(departure.service).some(isKnownStation) ||
      destinationNames(departure.service).some(
        (name) => isKnownStationName(name) || isCorridorDestination(name)
      );

    const isInCorridor = async (departure: Departure): Promise<boolean> => {
      if (boundForKnownStation(departure)) return true;

      if (!patterns.has(departure.id)) {
        if (checksSpent >= VERIFY_BUDGET) return true;
        checksSpent++;
        await fetchPattern(departure.id);
      }

      const pattern = patterns.get(departure.id);
      if (!pattern) return true;
      return servesScopeAhead(pattern, from.crs, isKnownStation);
    };

    /**
     * Walk outward from one end, taking the first `wanted` services that qualify.
     *
     * Lazy on purpose. Checking a fixed window from each end wasted the budget on
     * services that were never going to be shown, and left the ones that were shown
     * unverified. Walking until the answer is found spends the minimum, which matters
     * when the whole minute's allowance is ten requests.
     */
    const takeFrom = async (
      candidates: Departure[],
      fromEnd: boolean,
      wanted: number
    ): Promise<Departure[]> => {
      const picked: Departure[] = [];
      const order = fromEnd ? [...candidates].reverse() : candidates;

      for (const departure of order) {
        if (picked.length >= wanted) break;
        if (await isInCorridor(departure)) picked.push(departure);
      }

      return fromEnd ? picked.reverse() : picked;
    };

    // ---- one service day at a time -------------------------------------------

    interface Day {
      lineUp: LocationLineUpResponse | null;
      /** Departures this way, in time order, before corridor verification. */
      candidates: Departure[];
      fromCache: boolean;
    }

    /**
     * Unfiltered: every service at this station across the whole service day. There
     * is no destination to filter to, and filtering to a line's far terminus would
     * drop the services that terminate short -- often including the last one.
     */
    const loadDay = async (forDate: IsoDate): Promise<Day> => {
      const rawKey = lineUpKey(from.crs, forDate);
      let lineUp: LocationLineUpResponse | null = null;
      let fromCache = false;

      if (!refresh) {
        const cachedLineUp = getCachedLineUp<LocationLineUpResponse | null>(rawKey);
        if (cachedLineUp) {
          lineUp = cachedLineUp.value;
          fromCache = true;
        }
      }

      if (!fromCache) {
        lineUp = await locationLineUp({ code: from.crs, ...serviceDayWindow(forDate) });
        lineUpsFetched++;
        setCachedLineUp(rawKey, lineUp, ttlSecondsFor(forDate));
      }

      const candidates = sortedDepartures(lineUp).filter((departure) => {
        if (!isOperatorInScope(departure.service.scheduleMetadata?.operator?.code)) return false;
        // A service whose direction genuinely cannot be established is left out rather
        // than guessed at. It would otherwise appear under both buttons.
        return classifyDirection(departure.service, from.lon, longitudeOf) === direction;
      });

      return { lineUp, candidates, fromCache };
    };

    const day = await loadDay(date);

    const mode = boardMode({
      isLiveServiceDay: date === today,
      // The earliest candidate, taken before corridor verification. Verification can
      // only ever move this later, and only at Liverpool Street; a few minutes' slack
      // at a boundary crossed once a day is not worth a request against an allowance
      // of ten a minute.
      firstDeparture: day.candidates[0]?.depInstant ?? null,
    });

    // ---- pick the board ------------------------------------------------------
    //
    // Both arrangements come out in departure order, which is also the order they are
    // shown in, and in both the final `last` entry is the genuine last train of the
    // service day on the board -- the one thing in the app that is red.
    //
    // In pre-service mode the first trains are the day's own, so they are the day on
    // the board; in normal mode they are the next day's, which is a second line-up.
    const firstDate = mode === 'pre-service' ? date : addDays(date, 1);

    const selected = await selectBoard(mode, async (which, fromEnd, wanted) => {
      const candidates =
        which === 'current' ? day.candidates : (await loadDay(firstDate)).candidates;
      return takeFrom(candidates, fromEnd, wanted);
    });

    // The route label needs the calling pattern too. Most of these are already in
    // hand from the corridor check; fetch whatever is missing, in parallel.
    await Promise.all(
      selected
        .filter(({ item }) => !patterns.has(item.id))
        .map(({ item }) => fetchPattern(item.id))
    );

    const callingPatterns = new Map<string, ServiceLocation[]>();
    for (const [id, pattern] of patterns) {
      if (pattern) callingPatterns.set(id, pattern);
    }

    const services = selected.map(({ item, role }) => ({
      ...toDepartureService(item, {
        fromCrs: from.crs,
        markers: routeMarkers,
        callingPatterns,
      }),
      role,
    }));

    // How many departures run this way on the day on the board. Exact only when every
    // candidate was bound somewhere in scope and so needed no checking -- true
    // everywhere except Liverpool Street, where the line-up also holds West Anglia
    // services that were never counted. Rather than show a confident wrong number
    // there, the UI omits it; see `totalIsExact`.
    const definite = day.candidates.filter(boundForKnownStation);
    const totalIsExact = definite.length === day.candidates.length;

    const body: TrainsResponse = {
      from: { crs: from.crs, name: from.name },
      direction,
      date,
      mode,
      firstDate,
      services,
      totalServices: totalIsExact ? day.candidates.length : definite.length,
      totalIsExact,
      // Taken from the services actually shown, which are the only ones fully
      // verified. It exists to answer "what does east mean from here".
      towards: summariseDestinations(services.map((service) => service.destination)),
      systemStatus: day.lineUp?.systemStatus,
      apiVersion: API_VERSION,
    };

    // An empty list is a real answer -- nothing runs that way, or nothing in scope
    // does -- and is cached like any other. At Shenfield going east, the corridor
    // simply ends; on a Sunday with the line closed for engineering, that is the
    // truth, not a failure.
    setCached(key, body, ttl);

    return json(body, {
      headers: {
        'cache-control': `private, max-age=${ttl}`,
        'x-cache': lineUpsFetched === 0 ? 'PARTIAL' : 'MISS',
        'x-ratelimit-remaining': JSON.stringify(rateLimitSnapshot()),
      },
    });
  } catch (error) {
    if (error instanceof RttError) {
      return json(
        { error: error.message, retryAfterSeconds: error.retryAfterSeconds },
        {
          status: error.status === 400 ? 502 : error.status,
          headers: error.retryAfterSeconds
            ? { 'retry-after': String(error.retryAfterSeconds) }
            : undefined,
        }
      );
    }
    console.error('[api/trains] unexpected failure', error);
    return json({ error: 'Something went wrong looking that up.' }, { status: 500 });
  }
}
