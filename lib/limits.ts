/**
 * Two limits that keep the API from being used up by someone other than the app.
 *
 * **Why they exist.** `/api/*` has no key and no login, and the list of every station to
 * walk ships inside the app. One pass over all 2,619 stations costs 73% of a sustainable
 * day on the RTT Team tier, and a script at 40/minute does it in about an hour — after
 * which the board is throttled for everyone. See STATUS.md, *Exposure*.
 *
 * - **Per caller**, in `middleware.ts`: a fixed number of requests a minute and an hour
 *   from one IP address. Cheap to get round with many addresses, which is why it is not
 *   the only line.
 * - **Upstream spend**, in `lib/rtt.ts`: a ceiling on RTT requests an hour and a day,
 *   across every caller. However the calls arrive, the week's quota cannot be spent. Past
 *   it, cached boards still answer and only cold lookups are refused.
 *
 * Both count in the shared Redis, because each Vercel instance is its own process and a
 * count held in memory would be divided by however many happen to be warm.
 *
 * **Both fail open.** With no Redis configured, or Redis slow or down, nothing is limited.
 * A limit that takes the board down whenever its counter is unavailable has turned a
 * guard into an outage, and the in-process token bucket in `lib/rtt.ts` still paces
 * whatever gets through.
 *
 * The counting is here, apart from Redis and from the clock, so it can be tested.
 */

/** One fixed window: how many requests fit in how many seconds. */
export interface Window {
  /** Short name, part of the Redis key. */
  name: string;
  seconds: number;
  max: number;
}

/**
 * Per IP address. Generous on purpose: a person flicking between directions and
 * destinations makes a handful of requests a minute, and a phone network can put many
 * people behind one address.
 */
export const CALLER_WINDOWS: readonly Window[] = [
  { name: 'm', seconds: 60, max: 60 },
  { name: 'h', seconds: 3600, max: 600 },
];

/**
 * Upstream RTT requests, across every caller.
 *
 * Sized against the Team tier's **weekly** 25,000, which is the cap that binds. 3,000 a
 * day is 21,000 a week, leaving 4,000 for the generators and for testing, which share the
 * key. The hour stops a burst spending the day before anyone notices. Measured use in
 * August was 122 requests in a week, so neither is near anything real.
 */
export const UPSTREAM_WINDOWS: readonly Window[] = [
  /*
   The minute, shared by every instance (`SERVER-AUDIT.md` finding 5). The token bucket in
   `lib/rtt.ts` paces one process; several warm instances each held their own 40 and could
   together ask RTT for more than its 40 a minute. 36 leaves room for the generators and
   for testing. A fixed window can pass two full minutes' worth either side of its edge;
   RTT's own 429 and the one retry in `lib/rtt.ts` cover that rare case.
  */
  { name: 'm', seconds: 60, max: 36 },
  { name: 'h', seconds: 3600, max: 400 },
  { name: 'd', seconds: 86400, max: 3000 },
];

/**
 * `refresh=1` per caller. A refresh skips the stored answer and rebuilds it, so a script
 * calling with it on every request could turn the cache off for itself. Past these, the
 * request is still answered — from the cache, as if the refresh had not been asked for.
 * A person pulling down to refresh does it a few times a minute at most.
 */
export const REFRESH_WINDOWS: readonly Window[] = [
  { name: 'm', seconds: 60, max: 6 },
  { name: 'h', seconds: 3600, max: 60 },
];

/** The key a request is counted under, for one window at one moment. */
export function windowKey(prefix: string, window: Window, nowMillis: number): string {
  const index = Math.floor(nowMillis / 1000 / window.seconds);
  return `${prefix}:${window.name}:${index}`;
}

/** Seconds until the window holding `nowMillis` rolls over. At least one. */
export function secondsUntilReset(window: Window, nowMillis: number): number {
  const elapsed = (nowMillis / 1000) % window.seconds;
  return Math.max(1, Math.ceil(window.seconds - elapsed));
}

/**
 * `unmeasured` when the count could not be made — Redis slow or down. The request is still
 * allowed; a caller that must not run blind, like RTT spend, checks the flag and falls back
 * to a budget of its own (see `createLocalBudget`).
 */
export type Verdict =
  | { allowed: true; unmeasured?: true }
  | { allowed: false; retryAfterSeconds: number };

/**
 * Given each window's count *including this request*, may it go?
 *
 * When several windows are full, the wait quoted is the longest, because waiting out the
 * minute is no use if the hour is also spent.
 */
export function judge(windows: readonly Window[], counts: readonly number[], nowMillis: number): Verdict {
  let wait = 0;
  windows.forEach((window, i) => {
    if (counts[i] > window.max) wait = Math.max(wait, secondsUntilReset(window, nowMillis));
  });
  return wait === 0 ? { allowed: true } : { allowed: false, retryAfterSeconds: wait };
}

/** The part of a Redis client this needs. `@upstash/redis` fits it. */
export interface Counter {
  pipeline(): {
    incr(key: string): unknown;
    expire(key: string, seconds: number): unknown;
    exec(): Promise<unknown[]>;
  };
}

/** Past this, the count is skipped and the request allowed. A limit must not add latency. */
const COUNT_TIMEOUT_MS = 400;

/**
 * Count one request against every window and judge it.
 *
 * One round trip: an `INCR` and an `EXPIRE` per window, pipelined. The expiry is set
 * every time rather than only on the first count, which is harmless because the key
 * names its own window and is never reused.
 *
 * Refused requests are counted too. That only ever errs towards refusing, and a caller
 * still hammering after a refusal has earned it.
 */
export async function count(
  counter: Counter | null,
  prefix: string,
  windows: readonly Window[],
  nowMillis: number = Date.now()
): Promise<Verdict> {
  if (!counter) return { allowed: true };

  const pipe = counter.pipeline();
  for (const window of windows) {
    const key = windowKey(prefix, window, nowMillis);
    pipe.incr(key);
    // A little past the window, so a key cannot vanish while its window is still open.
    pipe.expire(key, window.seconds + 60);
  }

  let results: unknown[];
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    results = await Promise.race([
      pipe.exec(),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error('timed out')), COUNT_TIMEOUT_MS);
      }),
    ]);
  } catch {
    return { allowed: true, unmeasured: true };
  } finally {
    clearTimeout(timer);
  }

  // INCR results sit at the even positions, EXPIRE results at the odd.
  const counts = windows.map((_, i) => Number(results[i * 2]));
  if (counts.some((n) => !Number.isFinite(n))) return { allowed: true, unmeasured: true };
  return judge(windows, counts, nowMillis);
}

/**
 * The caller's address, as Vercel reports it. Null when there is none to count — local
 * development, where limiting yourself is only a nuisance.
 */
export function callerAddress(headers: Headers): string | null {
  const real = headers.get('x-real-ip')?.trim();
  const forwarded = headers.get('x-forwarded-for')?.split(',')[0]?.trim();
  const address = real || forwarded;
  if (!address) return null;
  if (address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1') return null;
  return address;
}

/**
 * A small budget one process keeps for itself, for when the shared count cannot be made.
 *
 * **Why not simply refuse.** With Redis down there is no cache either, so refusing every
 * RTT request would turn a short Redis blip into a blank board for everyone. **Why not
 * simply allow**, as before (`SERVER-AUDIT.md` finding 5): with no shared count, nothing
 * stops many instances spending the week's quota between them. So each process may spend
 * a little on its own — enough to keep a board working through a blip, too little for a
 * long outage to cost anything that matters.
 *
 * A fixed window, with the clock passed in so it can be tested.
 */
export function createLocalBudget(options: { max: number; seconds: number; now?: () => number }) {
  const now = options.now ?? Date.now;
  let windowIndex = -1;
  let used = 0;
  return {
    take(): Verdict {
      const t = now();
      const index = Math.floor(t / 1000 / options.seconds);
      if (index !== windowIndex) {
        windowIndex = index;
        used = 0;
      }
      if (used >= options.max) {
        return { allowed: false, retryAfterSeconds: secondsUntilReset({ name: 'local', ...options }, t) };
      }
      used += 1;
      return { allowed: true };
    },
  };
}

/**
 * Whether this caller's `refresh=1` is honoured. Past `REFRESH_WINDOWS` it is not, and the
 * request is answered from the cache instead — never refused, because a refresh that
 * fails is worse than one that is a minute old. A caller with no address (local
 * development) is never limited.
 */
export async function refreshAllowed(counter: Counter | null, headers: Headers): Promise<boolean> {
  const address = callerAddress(headers);
  if (!address) return true;
  return (await count(counter, `refresh:${address}`, REFRESH_WINDOWS)).allowed;
}
