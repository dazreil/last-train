import { test } from 'node:test';
import assert from 'node:assert/strict';

import { boardHasExpired, boardMode, isServiceDaySpent, selectBoard } from './board.ts';
import type { BoardDay, BoardMode } from './board.ts';

/**
 * Departure times here are the shape the API actually sends: London wall-clock with
 * no timezone at all. `now` is written as a true instant, with the London time it
 * corresponds to in a comment, because those two differing by an hour through BST is
 * the whole reason this file runs under `TZ=UTC`.
 */

const at = (instant: string) => new Date(instant);

// ------------------------------------------------------------------ board shape

test('a service day that has not started yet leads with its first trains', () => {
  assert.equal(
    boardMode({
      isLiveServiceDay: true,
      firstDeparture: '2026-08-02T06:04:00',
      now: at('2026-08-02T02:00:00Z'), // 03:00 London, the service day just rolled over
    }),
    'pre-service'
  );
});

test('once the day is running the board is the normal way round', () => {
  assert.equal(
    boardMode({
      isLiveServiceDay: true,
      firstDeparture: '2026-08-02T06:04:00',
      now: at('2026-08-02T21:00:00Z'), // 22:00 London, the case the app is really for
    }),
    'normal'
  );
});

test('the boundary is the first departure itself, resolved as London', () => {
  // 06:04 London in August is 05:04Z. Read the API string as UTC instead -- which is
  // what any timezone-less parse does on a server -- and this same clock reads as an
  // hour before the first train rather than half an hour after it, flipping the
  // board into the wrong shape for the whole of the early morning.
  const firstDeparture = '2026-08-02T06:04:00';

  assert.equal(
    boardMode({ isLiveServiceDay: true, firstDeparture, now: at('2026-08-02T05:30:00Z') }),
    'normal' // 06:30 London: it has gone
  );
  assert.equal(
    boardMode({ isLiveServiceDay: true, firstDeparture, now: at('2026-08-02T04:30:00Z') }),
    'pre-service' // 05:30 London: it has not
  );
  assert.equal(
    boardMode({ isLiveServiceDay: true, firstDeparture, now: at('2026-08-02T05:04:00Z') }),
    'normal' // exactly 06:04 London: it is leaving, not waiting
  );
});

test('the same rule holds under GMT', () => {
  assert.equal(
    boardMode({
      isLiveServiceDay: true,
      firstDeparture: '2026-12-13T07:12:00',
      now: at('2026-12-13T03:00:00Z'), // 03:00 London, no offset in winter
    }),
    'pre-service'
  );
  assert.equal(
    boardMode({
      isLiveServiceDay: true,
      firstDeparture: '2026-12-13T07:12:00',
      now: at('2026-12-13T09:00:00Z'),
    }),
    'normal'
  );
});

test('a day other than the live one is never pre-service', () => {
  // Tomorrow's board is a timetable, not a countdown. Nothing on it has "not started
  // yet" with respect to a clock it does not contain, so it always reads last-first.
  assert.equal(
    boardMode({
      isLiveServiceDay: false,
      firstDeparture: '2026-08-03T06:04:00',
      now: at('2026-08-02T02:00:00Z'),
    }),
    'normal'
  );
});

test('a day with nothing running is never pre-service', () => {
  assert.equal(
    boardMode({
      isLiveServiceDay: true,
      firstDeparture: null,
      now: at('2026-08-02T02:00:00Z'),
    }),
    'normal'
  );
});

// ------------------------------------------------------------------ spent days

test('a service day is spent once its last train has gone', () => {
  // Saturday's last train leaves at 00:22 on Sunday morning and is still Saturday's.
  const lastDeparture = '2026-08-02T00:22:00'; // 23:22Z

  assert.equal(isServiceDaySpent(lastDeparture, at('2026-08-01T23:40:00Z')), true); // 00:40
  assert.equal(isServiceDaySpent(lastDeparture, at('2026-08-01T23:00:00Z')), false); // 00:00
});

test('a day with nothing running is not spent', () => {
  // Nothing ran, so nothing has been missed. An empty board is its own answer and
  // must not push the app on to the next day looking for one.
  assert.equal(isServiceDaySpent(null, at('2026-08-01T23:40:00Z')), false);
});

// ----------------------------------------------------------------- selection

interface Stub {
  id: string;
}

const train = (id: string): Stub => ({ id });

/**
 * Stands in for the route's lazy walk along a day's departures.
 *
 * Records what it was asked for, which is how the tests below check that a
 * pre-service board never reaches for the next service day -- that is a rate-limit
 * guarantee, not a detail, because each day costs a station line-up.
 */
function taker(days: { current: Stub[]; next?: Stub[] }) {
  const asked: string[] = [];

  const take = async (day: BoardDay, fromEnd: boolean, wanted: number): Promise<Stub[]> => {
    asked.push(day);
    const all = (day === 'current' ? days.current : days.next) ?? [];
    return fromEnd ? all.slice(-wanted) : all.slice(0, wanted);
  };

  return { take, asked };
}

const shape = (board: { item: Stub; role: string }[]) =>
  board.map(({ item, role }) => `${role}:${item.id}`);

const build = (mode: BoardMode, days: { current: Stub[]; next?: Stub[] }) => {
  const { take, asked } = taker(days);
  return selectBoard(mode, take).then((board) => ({ shape: shape(board), asked }));
};

test('a normal board is the last three, then the first train of the next day', async () => {
  const { shape: rows, asked } = await build('normal', {
    current: ['a', 'b', 'c', 'd', 'e'].map(train),
    next: ['n1', 'n2', 'n3'].map(train),
  });

  // Departure order, and the first train back is the next morning's, not this
  // morning's -- which is the whole point of the block moving to the bottom.
  assert.deepEqual(rows, ['last:c', 'last:d', 'last:e', 'first:n1']);
  assert.deepEqual(asked, ['current', 'next']);
});

test('an empty day never reaches for the next one', async () => {
  // The rate limit is ten requests a minute and each day costs a line-up. Nothing
  // runs this way, so there is nothing to miss and nothing to look up.
  const { shape: rows, asked } = await build('normal', { current: [], next: [train('n1')] });

  assert.deepEqual(rows, []);
  assert.deepEqual(asked, ['current']);
});

test('a pre-service board is the first three, then that same day last train', async () => {
  const { shape: rows, asked } = await build('pre-service', {
    current: ['a', 'b', 'c', 'd', 'e'].map(train),
    next: ['n1'].map(train),
  });

  assert.deepEqual(rows, ['first:a', 'first:b', 'first:c', 'last:e']);
  // Answered entirely out of the day already in hand: no second line-up.
  assert.deepEqual(asked, ['current', 'current']);
});

test('a train that is both first and last is only shown as the last one', async () => {
  // Three trains all day: the third is both the last of the first three and the last
  // of the day. Red goes on the genuine last train, and nothing is listed twice.
  const { shape: rows } = await build('pre-service', { current: ['a', 'b', 'c'].map(train) });
  assert.deepEqual(rows, ['first:a', 'first:b', 'last:c']);

  const { shape: two } = await build('pre-service', { current: ['a', 'b'].map(train) });
  assert.deepEqual(two, ['first:a', 'last:b']);

  const { shape: one } = await build('pre-service', { current: [train('a')] });
  assert.deepEqual(one, ['last:a']);
});

// ------------------------------------------------------------- cached answers

test('a pre-service answer expires when the first train it leads with departs', () => {
  const board = {
    mode: 'pre-service' as const,
    services: [
      { role: 'first', depInstant: '2026-08-02T05:04:00Z' }, // 06:04 London
      { role: 'first', depInstant: '2026-08-02T05:34:00Z' },
      { role: 'last', depInstant: '2026-08-02T22:47:00Z' },
    ],
  };

  assert.equal(boardHasExpired(board, at('2026-08-02T04:00:00Z')), false);
  assert.equal(boardHasExpired(board, at('2026-08-02T05:30:00Z')), true);
});

test('a normal answer does not expire this way', () => {
  // Within one service day the shape only ever goes pre-service -> normal, so a
  // normal answer stays the right shape until its TTL runs out.
  const board = {
    mode: 'normal' as const,
    services: [
      { role: 'last', depInstant: '2026-08-02T22:47:00Z' },
      { role: 'first', depInstant: '2026-08-03T05:04:00Z' },
    ],
  };

  assert.equal(boardHasExpired(board, at('2026-08-03T12:00:00Z')), false);
});

test('a pre-service answer with no first train left is not treated as expired', () => {
  // One train all day: it is the last train, so it is shown as one, and there is no
  // first-train entry whose departure could decide anything.
  const board = {
    mode: 'pre-service' as const,
    services: [{ role: 'last', depInstant: '2026-08-02T22:47:00Z' }],
  };

  assert.equal(boardHasExpired(board, at('2026-08-02T04:00:00Z')), false);
});
