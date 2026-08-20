import assert from 'node:assert/strict';
import test from 'node:test';

import { createTokenBucket } from './pacing.ts';

/** A clock the test drives, so a minute costs nothing. */
function fakeClock(start = 1_000_000) {
  let at = start;
  return { now: () => at, advance: (ms: number) => { at += ms; } };
}

test('a burst up to the allowance is granted outright', () => {
  const clock = fakeClock();
  const bucket = createTokenBucket({ perMinute: 40, now: clock.now });

  for (let i = 0; i < 40; i += 1) {
    assert.deepEqual(bucket.take(), { granted: true }, `request ${i + 1} should pass`);
  }
});

test('the request past the allowance is refused, not silently allowed', () => {
  const clock = fakeClock();
  const bucket = createTokenBucket({ perMinute: 40, now: clock.now });
  for (let i = 0; i < 40; i += 1) bucket.take();

  const verdict = bucket.take();
  assert.equal(verdict.granted, false);
});

/**
 * The point of a bucket rather than a window: allowance accrues continuously, so a second
 * lookup a few seconds later is not made to wait for a boundary that means nothing.
 */
test('waiting the quoted time is enough, and not a boundary longer', () => {
  const clock = fakeClock();
  const bucket = createTokenBucket({ perMinute: 40, now: clock.now });
  for (let i = 0; i < 40; i += 1) bucket.take();

  const refused = bucket.take();
  assert.equal(refused.granted, false);
  if (refused.granted) return;

  // One short of the quoted wait is still a refusal...
  clock.advance(refused.waitMs - 1);
  assert.equal(bucket.take().granted, false);

  // ...and the quoted wait itself is enough.
  clock.advance(1);
  assert.equal(bucket.take().granted, true);
});

test('a full minute restores the whole allowance and no more', () => {
  const clock = fakeClock();
  const bucket = createTokenBucket({ perMinute: 40, now: clock.now });
  for (let i = 0; i < 40; i += 1) bucket.take();

  // Ten times longer than it takes to refill, to prove the ceiling holds.
  clock.advance(10 * 60_000);

  for (let i = 0; i < 40; i += 1) {
    assert.equal(bucket.take().granted, true, `request ${i + 1} after refill should pass`);
  }
  assert.equal(bucket.take().granted, false, 'the allowance must not exceed one minute of it');
});

/**
 * The measured case this was built for: one cold Fast Train interaction is about seventeen
 * requests in five seconds, and two of them inside a minute is what went over.
 */
test('two cold interactions inside a minute are paced rather than refused outright', () => {
  const clock = fakeClock();
  const bucket = createTokenBucket({ perMinute: 40, now: clock.now });

  for (let i = 0; i < 17; i += 1) {
    assert.equal(bucket.take().granted, true, 'the first interaction passes untouched');
  }
  clock.advance(5_000);
  for (let i = 0; i < 17; i += 1) {
    assert.equal(bucket.take().granted, true, 'the second still fits inside the allowance');
  }

  // The third is where it genuinely runs out, and the wait quoted is short.
  clock.advance(5_000);
  let refusals = 0;
  for (let i = 0; i < 17; i += 1) {
    const verdict = bucket.take();
    if (!verdict.granted) {
      refusals += 1;
      assert.ok(verdict.waitMs < 60_000, 'a wait longer than a minute would be a bug');
    }
  }
  assert.ok(refusals > 0, 'a third interaction in ten seconds must not all pass');
});
