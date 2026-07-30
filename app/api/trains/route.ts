/**
 * GET /api/trains?from=GRY&direction=east&date=2026-07-28
 *   -> { services: [ { dep, destination, via, toc, tocName, … } ], towards: [...] }
 *
 * This route exists so the RTT token stays on the server. It is the only thing in
 * the app that can reach the API.
 *
 * Per uncached lookup: one unfiltered location line-up, plus a service query for
 * each service that needs one -- to establish the route it takes, and to confirm it
 * calls somewhere in scope. The line-up is cached separately from the answer, so
 * tapping East and then West costs one API call between them, not two.
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
import { classifyDirection, isDirection, isOperatorInScope, type Direction } from '@/lib/direction';
import { isCorridorDestination, longitudeOf } from '@/lib/geo';
import { currentServiceDate, isValidIsoDate, serviceDayWindow, addDays } from '@/lib/serviceDay';
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
 * Ceiling on corridor checks per lookup.
 *
 * The free tier allows ten requests a minute and a lookup already spends one on the
 * line-up. Checks are only needed for services bound outside the app's station list,
 * which in practice means Liverpool Street and nowhere else; their patterns are then
 * reused for route labelling. Four keeps the worst case around eight requests, so a
 * single lookup cannot exhaust the minute on its own.
 */
const VERIFY_BUDGET = 4;

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
    if (hit) {
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
    // Unfiltered: every service at this station across the whole service day. There
    // is no destination to filter to, and filtering to a line's far terminus would
    // drop the services that terminate short -- often including the last one.
    const rawKey = lineUpKey(from.crs, date);
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
      lineUp = await locationLineUp({ code: from.crs, ...serviceDayWindow(date) });
      setCachedLineUp(rawKey, lineUp, ttl);
    }

    const candidates = sortedDepartures(lineUp).filter((departure) => {
      if (!isOperatorInScope(departure.service.scheduleMetadata?.operator?.code)) return false;
      // A service whose direction genuinely cannot be established is left out rather
      // than guessed at. It would otherwise appear under both buttons.
      return classifyDirection(departure.service, from.lon, longitudeOf) === direction;
    });

    // ---- corridor membership -------------------------------------------------
    //
    // A service bound for a station the app knows about is in scope by definition,
    // and that covers almost everything: all of c2c, all of the Elizabeth line.
    // Anything else needs its calling pattern read, because the destination alone
    // cannot tell a Colchester train that calls at Shenfield from one that runs
    // past it, nor either from a Cambridge train that never comes near.
    //
    // Destinations are matched by name as well as by code: a line-up's destination
    // pair carries a description but usually no codes, so matching on codes alone
    // made every single service look like it needed checking.
    const patterns = new Map<string, ServiceLocation[] | null>();

    const boundForKnownStation = (departure: Departure) =>
      destinationCodes(departure.service).some(isKnownStation) ||
      destinationNames(departure.service).some(
        (name) => isKnownStationName(name) || isCorridorDestination(name)
      );

    /**
     * Fetch a calling pattern, memoised for the request and cached across requests.
     *
     * A service's calling pattern on a given day never changes, so this is the safest
     * thing in the app to cache and the most valuable: at ten requests a minute, the
     * four route labels are most of a lookup's budget. Caching them makes the second
     * and subsequent lookups at a station nearly free -- which is what stops the
     * `via` labels quietly going missing at Fenchurch Street, where they matter most.
     */
    const fetchPattern = async (id: string) => {
      if (patterns.has(id)) return;

      const cached = getCachedPattern<ServiceLocation[] | null>(id);
      if (cached) {
        patterns.set(id, cached.value);
        return;
      }

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

    let checksSpent = 0;

    /**
     * Whether to show this service, reading its calling pattern only if it has to.
     *
     * Unverifiable services are kept, not dropped. Losing the last train of the night
     * to a failed side request, or to an exhausted budget, would be a far worse
     * outcome than showing one train too many -- and the destination is always on
     * screen, so an off-corridor train is visible for what it is.
     */
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
    const takeFrom = async (fromEnd: boolean, wanted: number): Promise<Departure[]> => {
      const picked: Departure[] = [];
      const order = fromEnd ? [...candidates].reverse() : candidates;

      for (const departure of order) {
        if (picked.length >= wanted) break;
        if (await isInCorridor(departure)) picked.push(departure);
      }

      return fromEnd ? picked.reverse() : picked;
    };

    // ---- pick the first, and the last three ---------------------------------
    const lastThree = await takeFrom(true, 3);
    const [earliest] = await takeFrom(false, 1);

    // If the earliest qualifying service is already among the last three, it belongs
    // only there -- on a quiet day nothing should be listed twice.
    const alreadyShown = earliest && lastThree.some((d) => d.id === earliest.id);

    const selected = [
      ...(earliest && !alreadyShown
        ? [{ departure: earliest, role: 'first' as const }]
        : []),
      ...lastThree.map((departure) => ({ departure, role: 'last' as const })),
    ];

    // The route label needs the calling pattern too. Most of these are already in
    // hand from the corridor check; fetch whatever is missing, in parallel.
    await Promise.all(
      selected
        .filter(({ departure }) => !patterns.has(departure.id))
        .map(({ departure }) => fetchPattern(departure.id))
    );

    const callingPatterns = new Map<string, ServiceLocation[]>();
    for (const [id, pattern] of patterns) {
      if (pattern) callingPatterns.set(id, pattern);
    }

    const services = selected.map(({ departure, role }) => ({
      ...toDepartureService(departure, {
        fromCrs: from.crs,
        markers: routeMarkers,
        callingPatterns,
      }),
      role,
    }));

    // How many departures run this way. Exact only when every candidate was bound
    // somewhere in scope and so needed no checking -- true everywhere except
    // Liverpool Street, where the line-up also holds West Anglia services that were
    // never counted. Rather than show a confident wrong number there, the UI omits
    // it; see `totalIsExact`.
    const definite = candidates.filter(boundForKnownStation);
    const totalIsExact = definite.length === candidates.length;

    const body: TrainsResponse = {
      from: { crs: from.crs, name: from.name },
      direction,
      date,
      services,
      totalServices: totalIsExact ? candidates.length : definite.length,
      totalIsExact,
      // Taken from the services actually shown, which are the only ones fully
      // verified. It exists to answer "what does east mean from here".
      towards: summariseDestinations(services.map((service) => service.destination)),
      systemStatus: lineUp?.systemStatus,
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
        'x-cache': fromCache ? 'PARTIAL' : 'MISS',
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
