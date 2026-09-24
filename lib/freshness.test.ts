import assert from 'node:assert/strict';
import test from 'node:test';

import {
  FAST_FALLBACK_NOW_TTL,
  PHONE_CALLS_MAX_AGE,
  PHONE_NOW_MAX_AGE,
  boardMaxAge,
  callsMaxAge,
  fastFallbackTtl,
} from './freshness.ts';

test('a board read now, with no live times yet, is kept on the phone two minutes at most', () => {
  // The audit's case: the last train is more than two hours out, so no overlay — and
  // within the hour it would come into the live window. The phone must ask again.
  assert.equal(boardMaxAge(false, true, 3600), PHONE_NOW_MAX_AGE);
});

test('a board carrying live times is kept a minute', () => {
  assert.equal(boardMaxAge(true, true, 3600), 60);
});

test('a board for another day keeps what the stored answer has left', () => {
  assert.equal(boardMaxAge(false, false, 5000), 5000);
});

test('never longer than the stored answer has left, and never negative', () => {
  assert.equal(boardMaxAge(false, true, 30), 30);
  assert.equal(boardMaxAge(true, true, 10), 10);
  assert.equal(boardMaxAge(false, false, -5), 0);
});

test("today's Fast Train fallback is cached ten minutes, not the day", () => {
  assert.equal(fastFallbackTtl(true, 3600), FAST_FALLBACK_NOW_TTL);
  assert.equal(fastFallbackTtl(true, 300), 300);
  assert.equal(fastFallbackTtl(false, 6 * 3600), 6 * 3600);
});

test('a stop list is kept five minutes at most, and no longer than it has left', () => {
  assert.equal(callsMaxAge(6 * 3600), PHONE_CALLS_MAX_AGE);
  assert.equal(callsMaxAge(90), 90);
  assert.equal(callsMaxAge(-1), 0);
});
