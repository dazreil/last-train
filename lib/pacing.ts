/**
 * A token bucket, kept apart from the client that uses it so it can be tested.
 *
 * `lib/rtt.ts` is `server-only` and every call in it goes to the network, so the pacing
 * arithmetic was untestable while it lived there — which is a poor place for it, since the
 * whole job of this code is to be right about a number nobody watches until it is wrong.
 * The clock is injected for the same reason: the behaviour worth proving is what happens
 * *over a minute*, and no test should take one.
 *
 * Nothing here sleeps or throws. It answers one question — may I send now, and if not, how
 * long until I may — and leaves the caller to decide whether that wait is worth having.
 */
export interface TokenBucket {
  /** Granted, or the wait in milliseconds until one token would be free. */
  take(): { granted: true } | { granted: false; waitMs: number };
}

export function createTokenBucket(options: {
  perMinute: number;
  now?: () => number;
}): TokenBucket {
  const { perMinute } = options;
  const now = options.now ?? Date.now;

  let tokens = perMinute;
  let lastRefill = now();

  const refill = () => {
    const at = now();
    // Continuous rather than in steps, so a lookup arriving a few seconds after the last
    // one gets the tokens that accrued in between instead of waiting for a window to roll.
    const gained = ((at - lastRefill) / 60_000) * perMinute;
    if (gained <= 0) return;
    tokens = Math.min(perMinute, tokens + gained);
    lastRefill = at;
  };

  return {
    take() {
      refill();
      if (tokens < 1) {
        return { granted: false, waitMs: Math.ceil(((1 - tokens) / perMinute) * 60_000) };
      }
      tokens -= 1;
      return { granted: true };
    },
  };
}
