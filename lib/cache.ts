/**
 * Caching, in two layers.
 *
 * Two reasons, per the spec: it protects the rate limit, and it makes repeat
 * lookups feel instant. Querying the same thing twice in an evening must not hit
 * the API twice.
 *
 *   - Answers, keyed `from:direction:date`. Small, so plenty are kept.
 *   - Raw line-ups, keyed `from:date`. One whole service day at Fenchurch Street is
 *     hundreds of services, so only a handful are kept -- but it means tapping East
 *     and then West costs a single API call, not two.
 *
 * A given service day's timetable barely changes once published, so hours is the
 * right order of magnitude. Today gets a shorter life than tomorrow, because
 * short-term amendments do land during the day.
 */

import { currentServiceDate, type IsoDate } from './serviceDay.ts';

const HOUR = 3600;

interface Entry<T> {
  value: T;
  storedAtMillis: number;
  expiresAtMillis: number;
}

export interface CacheHit<T> {
  value: T;
  ageSeconds: number;
}

/** A bounded, least-recently-used, time-to-live store. */
function createStore(maxEntries: number) {
  const store = new Map<string, Entry<unknown>>();

  return {
    get<T>(key: string): CacheHit<T> | null {
      const entry = store.get(key) as Entry<T> | undefined;
      if (!entry) return null;

      if (Date.now() >= entry.expiresAtMillis) {
        store.delete(key);
        return null;
      }

      // Refresh recency for the eviction order below.
      store.delete(key);
      store.set(key, entry);

      return {
        value: entry.value,
        ageSeconds: Math.round((Date.now() - entry.storedAtMillis) / 1000),
      };
    },

    set<T>(key: string, value: T, ttlSeconds: number): void {
      if (store.size >= maxEntries) {
        // Map preserves insertion order, so the first key is the least recently used.
        const oldest = store.keys().next();
        if (!oldest.done) store.delete(oldest.value);
      }
      store.set(key, {
        value,
        storedAtMillis: Date.now(),
        expiresAtMillis: Date.now() + ttlSeconds * 1000,
      });
    },

    delete(key: string): void {
      store.delete(key);
    },
  };
}

const answers = createStore(200);
const lineUps = createStore(8);

/**
 * Calling patterns, keyed by the service's own unique identity.
 *
 * A given service's calling pattern on a given day does not change, so this is the
 * safest thing in the app to cache and the most valuable: on the free tier only ten
 * requests a minute are allowed, and establishing whether a Colchester train calls
 * at Shenfield costs one each. Caching them means the second and subsequent lookups
 * at a station are nearly free.
 */
const patterns = createStore(400);

/**
 * `advanced` is part of the key because the same service day answers differently
 * depending on whether the reader has stepped on to it because the previous one is
 * spent, or is browsing ahead to it. Same data, different arrangement.
 */
export const cacheKey = (
  from: string,
  direction: string,
  date: IsoDate,
  advanced = false
): string => `${from}:${direction}:${date}${advanced ? ':advanced' : ''}`;

export const lineUpKey = (from: string, date: IsoDate): string => `${from}:${date}`;

/**
 * Seconds a result for this service date stays fresh.
 *
 * Future days are settled timetable. Today can still be amended, so it is
 * re-checked more often. Past days never change at all.
 */
export function ttlSecondsFor(date: IsoDate, now: Date = new Date()): number {
  const today = currentServiceDate(now);
  if (date < today) return 12 * HOUR;
  if (date === today) return 1 * HOUR;
  return 6 * HOUR;
}

export const getCached = <T>(key: string): CacheHit<T> | null => answers.get<T>(key);
export const setCached = <T>(key: string, value: T, ttlSeconds: number): void =>
  answers.set(key, value, ttlSeconds);
export const invalidate = (key: string): void => answers.delete(key);

export const getCachedLineUp = <T>(key: string): CacheHit<T> | null => lineUps.get<T>(key);
export const setCachedLineUp = <T>(key: string, value: T, ttlSeconds: number): void =>
  lineUps.set(key, value, ttlSeconds);
export const invalidateLineUp = (key: string): void => lineUps.delete(key);

/**
 * Two things are cached per service, and they are **not** the same shape.
 *
 * `/api/trains` stores the raw RTT `locations` array, which it reads to work out route
 * labels. `/api/v2/service` stores a rendered `ServiceCalls` body, which it returns
 * verbatim. Both are keyed by `scheduleMetadata.uniqueIdentity` — the same
 * `gb-nr:Y65292:2026-08-09` string — so a single shared namespace let whichever route
 * wrote first hand its shape to the other.
 *
 * Nothing caught it: the accessor was generic over an unconstrained `T`, so the cast
 * was unchecked and the wrong object came back typed as the right one. Observed as the
 * app reporting "the server sent something this version cannot read" after the web app
 * had been used against the same process — a failure that looked transient, because it
 * depended on which route ran first.
 *
 * Namespacing the keys is the fix. Keeping one store keeps one eviction pool, and the
 * two accessors below are typed so a caller cannot ask for the wrong shape by accident.
 */
const LOCATIONS = 'locations:';
const CALLS = 'calls:';

/** Raw RTT calling-pattern locations, for `/api/trains`'s route labelling. */
export const getCachedLocations = <T>(serviceId: string): CacheHit<T> | null =>
  patterns.get<T>(LOCATIONS + serviceId);
export const setCachedLocations = <T>(serviceId: string, value: T, ttlSeconds: number): void =>
  patterns.set(LOCATIONS + serviceId, value, ttlSeconds);

/** The rendered calling-points body `/api/v2/service` returns. */
export const getCachedCalls = <T>(serviceId: string): CacheHit<T> | null =>
  patterns.get<T>(CALLS + serviceId);
export const setCachedCalls = <T>(serviceId: string, value: T, ttlSeconds: number): void =>
  patterns.set(CALLS + serviceId, value, ttlSeconds);
