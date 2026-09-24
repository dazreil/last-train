/**
 * Which services a board lists: the filtered line-up's, or the ones classified by bearing.
 *
 * **Chosen by whether a filter was asked for, never by whether it returned anything.**
 * RTT answers a valid query with no services as HTTP 204, which `lib/rtt.ts` turns into
 * `null`. Choosing by the value read that `null` as "no filter" and listed the unfiltered
 * direction instead — every train leaving that way, for a destination none of them reach.
 * An empty filtered answer is the answer: nothing goes there. (`SERVER-AUDIT.md` finding 9.)
 *
 * Pure, so the rule is tested without a route.
 */
export function chooseCandidates<T>(
  filterRequested: boolean,
  filtered: () => T[],
  byBearing: () => T[]
): T[] {
  return filterRequested ? filtered() : byBearing();
}
