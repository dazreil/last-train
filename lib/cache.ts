/**
 * Caching, in two layers that sit under one interface.
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
 *
 * **The two layers.** L1 is an in-process map: instant, but private to one serverless
 * instance, so on Vercel it only helps a warm copy. L2 is a shared Redis (Vercel KV /
 * Upstash) that every instance reads, so the *first* person to look up a board pays the
 * one upstream call and everyone after that — on any instance, until it expires — is
 * served from the shared copy. L2 is optional: with no Redis configured the cache is L1
 * only, exactly as it was before, which is what local development and any un-provisioned
 * deployment fall back to.
 */

import { Redis } from '@upstash/redis';

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

/** What a shared entry carries: the value, when it was stored, and when it expires. */
interface Envelope<T> {
  v: T;
  s: number;
  e: number;
}

/**
 * The shared client, or null when none is configured.
 *
 * Built once, lazily, from whichever of the two conventional variable pairs is present:
 * `KV_REST_API_*` (Vercel KV) or `UPSTASH_REDIS_REST_*` (the Upstash marketplace add-on).
 * Absent both, the cache is L1 only and every helper below simply skips the shared layer.
 */
let sharedClient: Redis | null | undefined;

function shared(): Redis | null {
  if (sharedClient !== undefined) return sharedClient;

  const url =
    process.env.KV_REST_API_URL?.trim() || process.env.UPSTASH_REDIS_REST_URL?.trim();
  const token =
    process.env.KV_REST_API_TOKEN?.trim() || process.env.UPSTASH_REDIS_REST_TOKEN?.trim();

  sharedClient = url && token ? new Redis({ url, token }) : null;
  return sharedClient;
}

/**
 * The shared client, for modules that are not caches.
 *
 * `lib/timetable.ts` reads a store rather than a cache — a board that is missing
 * cannot be recomputed from anywhere — but it should not open a second
 * connection to say so. One client, configured in one place.
 */
export const sharedRedis = (): Redis | null => shared();

/** True once, for one build, so a broken Redis is logged rather than logged per request. */
let sharedWarned = false;
function noteSharedFailure(operation: string, error: unknown): void {
  if (sharedWarned) return;
  sharedWarned = true;
  const message = error instanceof Error ? error.message : String(error);
  console.warn(`Shared cache ${operation} failed; serving from memory only. ${message}`);
}

/**
 * A bounded, least-recently-used, time-to-live store over both layers.
 *
 * `namespace` prefixes the shared keys, because L1's separate maps become one shared
 * keyspace in Redis and `from:date` (a line-up) must not collide with another store's key
 * of the same shape.
 */
function createStore(maxEntries: number, namespace: string) {
  const store = new Map<string, Entry<unknown>>();
  const shareKey = (key: string) => `${namespace}${key}`;

  function readLocal<T>(key: string): CacheHit<T> | null {
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
  }

  function writeLocal<T>(key: string, value: T, storedAtMillis: number, expiresAtMillis: number): void {
    if (store.size >= maxEntries) {
      // Map preserves insertion order, so the first key is the least recently used.
      const oldest = store.keys().next();
      if (!oldest.done) store.delete(oldest.value);
    }
    store.set(key, { value, storedAtMillis, expiresAtMillis });
  }

  return {
    async get<T>(key: string): Promise<CacheHit<T> | null> {
      const local = readLocal<T>(key);
      if (local) return local;

      const redis = shared();
      if (!redis) return null;

      try {
        const envelope = await redis.get<Envelope<T>>(shareKey(key));
        if (!envelope || Date.now() >= envelope.e) return null;

        // Seen on this instance now, so keep a warm local copy for the rest of its life.
        writeLocal(key, envelope.v, envelope.s, envelope.e);
        return {
          value: envelope.v,
          ageSeconds: Math.round((Date.now() - envelope.s) / 1000),
        };
      } catch (error) {
        noteSharedFailure('read', error);
        return null;
      }
    },

    async set<T>(key: string, value: T, ttlSeconds: number): Promise<void> {
      const now = Date.now();
      writeLocal(key, value, now, now + ttlSeconds * 1000);

      const redis = shared();
      if (!redis) return;

      try {
        const envelope: Envelope<T> = { v: value, s: now, e: now + ttlSeconds * 1000 };
        // Awaited, not fire-and-forget: a serverless instance can freeze the moment it
        // has responded, dropping an unresolved write.
        await redis.set(shareKey(key), envelope, { ex: ttlSeconds });
      } catch (error) {
        noteSharedFailure('write', error);
      }
    },

    async delete(key: string): Promise<void> {
      store.delete(key);
      const redis = shared();
      if (!redis) return;
      try {
        await redis.del(shareKey(key));
      } catch (error) {
        noteSharedFailure('delete', error);
      }
    },
  };
}

const answers = createStore(200, 'a:');
const lineUps = createStore(8, 'l:');

/**
 * Calling patterns, keyed by the service's own unique identity.
 *
 * A given service's calling pattern on a given day does not change, so this is the
 * safest thing in the app to cache and the most valuable: on the free tier only ten
 * requests a minute are allowed, and establishing whether a Colchester train calls
 * at Shenfield costs one each. Caching them means the second and subsequent lookups
 * at a station are nearly free.
 */
const patterns = createStore(400, 'p:');

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

export const getCached = <T>(key: string): Promise<CacheHit<T> | null> => answers.get<T>(key);
export const setCached = <T>(key: string, value: T, ttlSeconds: number): Promise<void> =>
  answers.set(key, value, ttlSeconds);
export const invalidate = (key: string): Promise<void> => answers.delete(key);

export const getCachedLineUp = <T>(key: string): Promise<CacheHit<T> | null> => lineUps.get<T>(key);
export const setCachedLineUp = <T>(key: string, value: T, ttlSeconds: number): Promise<void> =>
  lineUps.set(key, value, ttlSeconds);
export const invalidateLineUp = (key: string): Promise<void> => lineUps.delete(key);

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
export const getCachedLocations = <T>(serviceId: string): Promise<CacheHit<T> | null> =>
  patterns.get<T>(LOCATIONS + serviceId);
export const setCachedLocations = <T>(serviceId: string, value: T, ttlSeconds: number): Promise<void> =>
  patterns.set(LOCATIONS + serviceId, value, ttlSeconds);

/** The rendered calling-points body `/api/v2/service` returns. */
export const getCachedCalls = <T>(serviceId: string): Promise<CacheHit<T> | null> =>
  patterns.get<T>(CALLS + serviceId);
export const setCachedCalls = <T>(serviceId: string, value: T, ttlSeconds: number): Promise<void> =>
  patterns.set(CALLS + serviceId, value, ttlSeconds);

/**
 * Whether the shared layer is configured and actually reachable, for a health check.
 *
 * `configured` says the credentials are present; `reachable` says a write-then-read round
 * trip through Redis actually came back with what went in. Never returns the error text —
 * that can quote the connection URL — only whether it worked and how long it took.
 */
export async function sharedCacheHealth(): Promise<{
  configured: boolean;
  reachable: boolean;
  roundTripMs: number | null;
}> {
  const redis = shared();
  if (!redis) return { configured: false, reachable: false, roundTripMs: null };

  const started = Date.now();
  try {
    await redis.set('health:ping', { t: started }, { ex: 30 });
    const seen = await redis.get<{ t: number }>('health:ping');
    return { configured: true, reachable: seen?.t === started, roundTripMs: Date.now() - started };
  } catch (error) {
    noteSharedFailure('health', error);
    return { configured: true, reachable: false, roundTripMs: null };
  }
}
