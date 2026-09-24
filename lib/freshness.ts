/**
 * How long an answer may be kept, where "kept" is somewhere the server cannot reach.
 *
 * **The phone's own cache.** A board sent with `max-age=3600` is served from the phone's
 * URL cache for the hour, and the server is never asked. The Redis answer cache is fine to
 * hold for the hour, because every read of it goes through the live overlay; the phone's
 * copy is not, because it skips the overlay. A train that comes within Darwin's two-hour
 * live window in that hour, or runs late, or is cancelled, would not show. So a board read
 * *now* — today's, or tomorrow's stepped on to after the last train — is kept on the
 * phone for two minutes at most. A board for another day has no live times to miss and
 * keeps its full time. (`SERVER-AUDIT.md` finding 3.)
 *
 * Pure, so the rule is tested without a route.
 */

/** The longest a board read now may sit on the phone. */
export const PHONE_NOW_MAX_AGE = 120;

/** The longest a stop list read on the live day may sit on the phone. */
export const PHONE_CALLS_MAX_AGE = 300;

/**
 * Today's Fast Train RTT fallback, in the shared cache.
 *
 * Its window starts at the minute it was asked, so a whole-day TTL replays a window that
 * has moved on: the trains in it leave, and the next ones never arrive. Ten minutes keeps
 * the upstream spend down without serving a window long out of date.
 */
export const FAST_FALLBACK_NOW_TTL = 10 * 60;

/**
 * `max-age` for a board.
 *
 * @param live         the live overlay was applied to this response
 * @param readNow      the board is today's, or the next day stepped on to
 * @param remaining    seconds the stored answer has left
 */
export function boardMaxAge(live: boolean, readNow: boolean, remaining: number): number {
  const left = Math.max(Math.floor(remaining), 0);
  if (live) return Math.min(60, left);
  if (readNow) return Math.min(PHONE_NOW_MAX_AGE, left);
  return left;
}

/** The shared-cache TTL for a Fast Train RTT fallback answer. */
export function fastFallbackTtl(isToday: boolean, dayTtl: number): number {
  return isToday ? Math.min(FAST_FALLBACK_NOW_TTL, dayTtl) : dayTtl;
}

/**
 * `max-age` for a stop list: what the stored entry has left, and on the live day no more
 * than five minutes, so a platform change or a late running is not held for hours.
 */
export function callsMaxAge(remaining: number): number {
  return Math.min(PHONE_CALLS_MAX_AGE, Math.max(Math.floor(remaining), 0));
}
