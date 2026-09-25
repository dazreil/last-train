import assert from 'node:assert/strict';
import test from 'node:test';

import {
  CALLER_WINDOWS,
  REFRESH_WINDOWS,
  UPSTREAM_WINDOWS,
  createLocalBudget,
  callerAddress,
  count,
  judge,
  secondsUntilReset,
  windowKey,
  type Counter,
  type Window,
} from './limits.ts';

/** An in-memory stand-in for Redis, with the same pipeline shape. */
function fakeCounter() {
  const values = new Map<string, number>();
  const counter: Counter = {
    pipeline() {
      const ops: (() => unknown)[] = [];
      return {
        incr(key: string) {
          ops.push(() => {
            const next = (values.get(key) ?? 0) + 1;
            values.set(key, next);
            return next;
          });
        },
        expire() {
          ops.push(() => 1);
        },
        async exec() {
          return ops.map((op) => op());
        },
      };
    },
  };
  return { counter, values };
}

const MINUTE: Window = { name: 'm', seconds: 60, max: 3 };
const HOUR: Window = { name: 'h', seconds: 3600, max: 5 };

test('requests up to the limit pass, and the one past it is refused', async () => {
  const { counter } = fakeCounter();
  const at = 1_000_020_000;
  for (let i = 0; i < 3; i += 1) {
    assert.deepEqual(await count(counter, 'ip:a', [MINUTE], at), { allowed: true });
  }
  const refused = await count(counter, 'ip:a', [MINUTE], at);
  assert.equal(refused.allowed, false);
});

test('a new window starts the count again', async () => {
  const { counter } = fakeCounter();
  const at = 1_000_020_000;
  for (let i = 0; i < 4; i += 1) await count(counter, 'ip:a', [MINUTE], at);
  assert.deepEqual(await count(counter, 'ip:a', [MINUTE], at + 60_000), { allowed: true });
});

test('one caller does not spend another caller’s allowance', async () => {
  const { counter } = fakeCounter();
  const at = 1_000_020_000;
  for (let i = 0; i < 4; i += 1) await count(counter, 'ip:a', [MINUTE], at);
  assert.deepEqual(await count(counter, 'ip:b', [MINUTE], at), { allowed: true });
});

/** Waiting out the minute is no use when the hour is also spent. */
test('the wait quoted is the longest of the full windows', () => {
  const at = 3600 * 1000 * 100 + 30_000; // 30 seconds into both a minute and an hour
  const verdict = judge([MINUTE, HOUR], [4, 6], at);
  assert.deepEqual(verdict, { allowed: false, retryAfterSeconds: 3570 });
});

test('the minute alone full quotes the rest of the minute', () => {
  const at = 3600 * 1000 * 100 + 45_000;
  assert.deepEqual(judge([MINUTE, HOUR], [4, 4], at), { allowed: false, retryAfterSeconds: 15 });
});

test('the wait is never zero', () => {
  assert.equal(secondsUntilReset(MINUTE, 60_000 * 7), 60);
  assert.equal(secondsUntilReset(MINUTE, 60_000 * 7 + 59_999), 1);
});

test('keys name their window, so a key is never reused across windows', () => {
  assert.notEqual(windowKey('x', MINUTE, 0), windowKey('x', MINUTE, 60_000));
  assert.equal(windowKey('x', MINUTE, 0), windowKey('x', MINUTE, 59_999));
});

/** A guard that takes the board down whenever its counter is unavailable is an outage. */
test('no counter configured allows everything', async () => {
  assert.deepEqual(await count(null, 'ip:a', [MINUTE]), { allowed: true });
});

test('a counter that fails allows the request', async () => {
  const broken: Counter = {
    pipeline: () => ({
      incr() {},
      expire() {},
      exec: async () => {
        throw new Error('connection refused');
      },
    }),
  };
  assert.deepEqual(await count(broken, 'ip:a', [MINUTE]), { allowed: true, unmeasured: true });
});

test('a counter that hangs allows the request, promptly', async () => {
  const hung: Counter = {
    pipeline: () => ({ incr() {}, expire() {}, exec: () => new Promise(() => {}) }),
  };
  const started = Date.now();
  assert.deepEqual(await count(hung, 'ip:a', [MINUTE]), { allowed: true, unmeasured: true });
  assert.ok(Date.now() - started < 1_000);
});

test('the caller is read from Vercel’s headers, and loopback is not counted', () => {
  assert.equal(callerAddress(new Headers({ 'x-real-ip': '203.0.113.9' })), '203.0.113.9');
  assert.equal(
    callerAddress(new Headers({ 'x-forwarded-for': '198.51.100.4, 10.0.0.1' })),
    '198.51.100.4'
  );
  assert.equal(callerAddress(new Headers({ 'x-real-ip': '127.0.0.1' })), null);
  assert.equal(callerAddress(new Headers()), null);
});

/**
 * The upstream ceiling exists to protect the week. If someone raises the daily figure
 * past a seventh of 25,000, the week can be spent by Friday again.
 */
test('the upstream daily ceiling fits inside the weekly RTT quota', () => {
  const day = UPSTREAM_WINDOWS.find((w) => w.seconds === 86400);
  assert.ok(day);
  assert.ok(day.max * 7 <= 25000, `${day.max} a day is ${day.max * 7} a week`);
});

test('the per-caller limit leaves room for a person using the app', () => {
  const minute = CALLER_WINDOWS.find((w) => w.seconds === 60);
  assert.ok(minute && minute.max >= 30);
});

test('the shared minute stays under RTT\'s 40 a minute', () => {
  const minute = UPSTREAM_WINDOWS.find((w) => w.seconds === 60);
  assert.ok(minute && minute.max < 40);
});

test('a person refreshing by hand is never held back by the refresh limit', () => {
  const minute = REFRESH_WINDOWS.find((w) => w.seconds === 60);
  assert.ok(minute && minute.max >= 4);
});

test('with Redis down, one process spends only its small local budget, then waits', () => {
  let t = 1_790_000_000_000;
  const budget = createLocalBudget({ max: 3, seconds: 3600, now: () => t });
  assert.equal(budget.take().allowed, true);
  assert.equal(budget.take().allowed, true);
  assert.equal(budget.take().allowed, true);
  const refused = budget.take();
  assert.equal(refused.allowed, false);
  assert.ok(!refused.allowed && refused.retryAfterSeconds > 0);
  // The next hour starts afresh.
  t += 3600 * 1000;
  assert.equal(budget.take().allowed, true);
});
