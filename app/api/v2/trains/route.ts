/**
 * GET /api/v2/trains?from=INV&direction=north&date=2026-08-04
 *   -> { mode, services: [...], directions: { north, east, south, west }, ... }
 *
 * The national board. IOS.md §9 step 4.
 *
 * **This lands beside `/api/trains`, which is untouched.** That route serves the
 * deployed web app, which is finished and in daily use; this one serves the native
 * app and covers all 2,619 stations. They share the line-up cache, so looking at
 * Upminster on the web and then in the app costs one upstream request, not two.
 *
 * ## What this route does not do, and why that is the point
 *
 * Everything the corridor machinery existed for is gone. Nationally there is no
 * scope to be inside or outside of: a Cambridge train from Liverpool Street is not
 * out of scope, it is simply a northbound train. So there is no operator filter, no
 * `servesScopeAhead`, no `corridorDestinations`, no `onward` topology check, and no
 * per-service verification budget — none of which have any meaning once every
 * operator and every station is in scope.
 *
 * `via` goes too, per §5. It existed for one real ambiguity — c2c via Basildon
 * against the slower Tilbury loop — and it is what cost up to four extra requests a
 * lookup. Nationally, with the destination on every row, it earns much less than it
 * costs.
 *
 * What that leaves is the cheapest possible lookup: **one station line-up per service
 * day, and no service queries at all.** A normal board spends two, because the first
 * train back belongs to the next service day; a pre-service board spends one. Both
 * are free on a warm cache.
 */

import {
  RttError,
  locationLineUp,
  rateLimitSnapshot,
  API_VERSION,
  type LocationLineUpResponse,
} from '@/lib/rtt';
import { sortedDepartures, destinationNames, destinationCodes, type Departure } from '@/lib/journeys';
import { boardHasExpired, boardMode, selectBoard } from '@/lib/board';
import { classify, isCompass, tally, type Compass } from '@/lib/compass';
import { coordinateFor, findStationByCrs } from '@/lib/nationalStations';
import {
  currentServiceDate,
  isValidIsoDate,
  serviceDayWindow,
  addDays,
  formatLondonTime,
  toInstantMillis,
  type IsoDate,
} from '@/lib/serviceDay';
import {
  lineUpKey,
  getCached,
  setCached,
  getCachedLineUp,
  setCachedLineUp,
  ttlSecondsFor,
} from '@/lib/cache';
import type { Diagnostics, NationalBoard, NationalService } from '@/lib/nationalContract';

export const runtime = 'nodejs';

/** Namespaced so it cannot collide with `/api/trains` in the same answer store. */
const answerKey = (crs: string, direction: string, date: IsoDate) =>
  `v2:${crs}:${direction}:${date}`;

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

/**
 * Which plan the loaded token is on, read from the rate-limit headers.
 *
 * IOS.md §3 is explicit that there must be no `FREE`/`PAID` mode flag: the API states
 * its own limits on every response, so switching plans is one environment variable
 * and there is nothing to forget to flip on release day. Free and Hobbyist are
 * indistinguishable here because Hobbyist does not raise the limits — which is
 * exactly why it cannot ship the app.
 */
function inferTier(minute: string | undefined): Diagnostics['tier'] {
  const limit = Number(minute?.split('/')[1]);
  if (limit >= 40) return 'team';
  if (limit > 0) return 'free-or-hobbyist';
  return 'unknown';
}

const describeDestination = (departure: Departure): string => {
  const names = destinationNames(departure.service);
  // Portion working: a service can carry two destinations and divide en route, and
  // boarding the wrong half is a real failure. Both are kept.
  return names.length ? names.join(' & ') : 'Unknown';
};

const platformOf = (departure: Departure): string | null =>
  departure.service.locationMetadata?.platform?.actual ??
  departure.service.locationMetadata?.platform?.planned ??
  null;

export async function GET(request: Request) {
  const params = new URL(request.url).searchParams;

  const fromCrs = (params.get('from') ?? '').trim().toUpperCase();
  const from = findStationByCrs(fromCrs);
  if (!from) return badRequest(`Unknown station code "${fromCrs}".`);

  const directionParam = (params.get('direction') ?? '').trim().toLowerCase();
  if (!isCompass(directionParam)) {
    return badRequest('Direction must be north, east, south or west.');
  }
  const direction: Compass = directionParam;

  const today = currentServiceDate();
  const date = (params.get('date') ?? today).trim();
  if (!isValidIsoDate(date)) return badRequest('Date must be YYYY-MM-DD.');
  if (date < addDays(today, -7) || date > addDays(today, 90)) {
    return badRequest('Date is outside the range the timetable covers.');
  }

  const refresh = params.get('refresh') === '1';
  const diagnosticsOn = process.env.DEBUG_DIAGNOSTICS === '1';
  const key = answerKey(from.crs, direction, date);
  const ttl = ttlSecondsFor(date);

  if (!refresh) {
    const hit = getCached<NationalBoard>(key);
    // A stored answer outlives its arrangement exactly once a day, when the first
    // train goes and a pre-service board becomes an ordinary one.
    if (hit && !boardHasExpired(hit.value)) {
      return json(hit.value, {
        headers: {
          'cache-control': `private, max-age=${Math.max(ttl - hit.ageSeconds, 0)}`,
          'x-cache': 'HIT',
        },
      });
    }
  }

  try {
    const origin = { lat: from.lat, lon: from.lon };
    let requestsSpent = 0;

    /**
     * One service day: the whole line-up, then every boardable departure classified
     * by the bearing to where it is going.
     *
     * Unfiltered on purpose. There is no destination to filter to, and filtering to a
     * line's far terminus would drop the services that terminate short — often
     * including the last one out.
     */
    const loadDay = async (forDate: IsoDate) => {
      const rawKey = lineUpKey(from.crs, forDate);
      let lineUp: LocationLineUpResponse | null = null;
      let fromCache = false;

      if (!refresh) {
        const cached = getCachedLineUp<LocationLineUpResponse | null>(rawKey);
        if (cached) {
          lineUp = cached.value;
          fromCache = true;
        }
      }

      if (!fromCache) {
        lineUp = await locationLineUp({ code: from.crs, ...serviceDayWindow(forDate) });
        requestsSpent += 1;
        setCachedLineUp(rawKey, lineUp, ttlSecondsFor(forDate));
      }

      const boardable = sortedDepartures(lineUp);

      // Bucketed once, and read twice: the counts for all four directions and the
      // services for the one asked for both come out of this single pass.
      const classified = boardable.map((departure) => ({
        departure,
        destination: coordinateFor(
          destinationNames(departure.service),
          destinationCodes(departure.service)
        ),
      }));

      return {
        lineUp,
        fromCache,
        boardable,
        classified,
        candidates: classified
          .filter((entry) => classify(origin, entry.destination) === direction)
          .map((entry) => entry.departure),
      };
    };

    const day = await loadDay(date);

    const mode = boardMode({
      isLiveServiceDay: date === today,
      firstDeparture: day.candidates[0]?.depInstant ?? null,
    });

    // In pre-service mode the first trains are the day's own; in normal mode they are
    // the next day's, which is a second line-up.
    const firstDate = mode === 'pre-service' ? date : addDays(date, 1);

    const selected = await selectBoard(mode, async (which, fromEnd, wanted) => {
      const candidates =
        which === 'current' ? day.candidates : (await loadDay(firstDate)).candidates;
      const picked = fromEnd ? candidates.slice(-wanted) : candidates.slice(0, wanted);
      return picked;
    });

    const services: NationalService[] = selected.map(({ item, role }) => ({
      dep: formatLondonTime(item.depInstant),
      // Emitted as a true UTC instant, not the API's timezone-less original, so
      // nothing downstream can reintroduce the ambiguity serviceDay just resolved.
      depInstant: new Date(toInstantMillis(item.depInstant)).toISOString(),
      toc: item.service.scheduleMetadata?.operator?.code ?? '??',
      tocName: item.service.scheduleMetadata?.operator?.name ?? 'Unknown operator',
      destination: describeDestination(item),
      platform: platformOf(item),
      isReplacementBus:
        item.service.scheduleMetadata?.modeType === 'REPLACEMENT_BUS' ||
        item.service.scheduleMetadata?.modeType === 'SCHEDULED_BUS' ||
        item.service.scheduleMetadata?.modeType === 'BUS',
      headcode: item.service.scheduleMetadata?.trainReportingIdentity ?? null,
      serviceId: item.id,
      role,
    }));

    // Availability, free with the query that was being made anyway.
    const counts = tally(origin, day.classified.map((entry) => entry.destination));

    const body: NationalBoard = {
      from: { crs: from.crs, name: from.name, locality: from.locality },
      direction,
      date,
      mode,
      firstDate,
      services,
      directions: counts.counts,
      available: counts.available,
      unclassified: counts.unclassified,
      totalServices: day.candidates.length,
      towards: summariseDestinations(services.map((service) => service.destination)),
      systemStatus: day.lineUp?.systemStatus,
      apiVersion: API_VERSION,
    };

    if (diagnosticsOn) {
      const limits = rateLimitSnapshot();
      const window = serviceDayWindow(date);
      body.diagnostics = {
        rateLimit: limits,
        tier: inferTier(limits.minute),
        requestsSpent,
        cache: requestsSpent === 0 ? 'PARTIAL' : 'MISS',
        window,
        counts: {
          inLineUp: day.lineUp?.services?.length ?? 0,
          boardable: day.boardable.length,
          inDirection: day.candidates.length,
          unclassified: counts.unclassified,
        },
      };
    }

    // An empty list is a real answer -- nothing runs that way today -- and is cached
    // like any other. At a terminus, three of the four directions are empty and always
    // will be.
    setCached(key, body, ttl);

    return json(body, {
      headers: {
        'cache-control': `private, max-age=${ttl}`,
        'x-cache': requestsSpent === 0 ? 'PARTIAL' : 'MISS',
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
    console.error('[api/v2/trains] unexpected failure', error);
    return json({ error: 'Something went wrong looking that up.' }, { status: 500 });
  }
}
