import assert from 'node:assert/strict';
import { test } from 'node:test';

import { toFastService, toServiceCalls } from './darwin.ts';
import {
  ageSecondsOf,
  packBoard,
  toNormalizedService,
  unpackBoard,
  type PackedDeparture,
} from './timetablePacking.ts';

/**
 * The station names the app would resolve, supplied here rather than loaded.
 * `lib/nationalStations.ts` is server-only and imports a JSON file Node cannot,
 * which is why the shaping takes a resolver instead of reaching for it.
 */
const NAMES: Record<string, string> = {
  KGX: 'London Kings Cross',
  SVG: 'Stevenage',
  PBO: 'Peterborough',
  LDS: 'Leeds',
};
const nameOf = (crs: string) => NAMES[crs] ?? crs;

/**
 * The join between the store and the routes.
 *
 * A board goes in packed and has to come out as something `toFastService` can
 * price, indistinguishable from a live Darwin board. These tests walk the real
 * path — pack, unpack, normalise, price — because each step alone can be right
 * while the seam between two of them is wrong.
 */

const OPERATORS = { CC: 'c2c', GR: 'LNER' };

/** The 23:33 King's Cross to Leeds: take-up-only at Stevenage, set-down after. */
const sleeper: PackedDeparture = {
  dep: 1413,
  rid: '202609096702022',
  toc: 'GR',
  origin: 'KGX',
  platform: '5',
  isBus: false,
  isConditional: false,
  destination: 'Leeds',
  onward: [
    { crs: 'SVG', arr: 1434, canAlight: false },
    { crs: 'PBO', arr: 1462, canAlight: true },
    { crs: 'LDS', arr: 1590, canAlight: true },
  ],
};

const normalise = (departure: PackedDeparture, crs = 'KGX', date = '2026-09-09') =>
  toNormalizedService(unpackBoard(packBoard([departure]))[0], crs, date, OPERATORS, nameOf);

test('a packed board becomes a service the routes can read', () => {
  const service = normalise(sleeper);
  assert.equal(service.serviceId, '202609096702022');
  assert.equal(service.operatorCode, 'GR');
  assert.equal(service.operatorName, 'LNER');
  assert.equal(service.destinationName, 'Leeds');
  assert.equal(service.platform, '5');
  assert.equal(service.stops.length, 4);
});

test('the boarding station is the first stop, carrying the departure', () => {
  const [boarding] = normalise(sleeper).stops;
  assert.equal(boarding.crs, 'KGX');
  assert.equal(boarding.time, '23:33');
  assert.equal(boarding.timeInstant, '2026-09-09T23:33:00');
});

test('a call past midnight lands on the next date, not the board date', () => {
  const leeds = normalise(sleeper).stops.at(-1);
  assert.equal(leeds?.time, '02:30');
  assert.equal(leeds?.timeInstant, '2026-09-10T02:30:00');
});

test('a journey can be priced end to end', () => {
  const priced = toFastService(normalise(sleeper), 'LDS');
  assert.ok(priced, 'expected a priced journey to Leeds');
  assert.equal(priced.departure, '23:33');
  assert.equal(priced.arrival, '02:30');
  assert.equal(priced.departureInstant, '2026-09-09T23:33:00');
  assert.equal(priced.arrivalInstant, '2026-09-10T02:30:00');
  assert.equal(priced.tocName, 'LNER');
});

test('a stop the train will not put you down at is refused as a destination', () => {
  // This is the whole reason the flag is carried. Stevenage is on the route and
  // has a time, so every other check passes; only `canAlight` refuses it.
  assert.equal(toFastService(normalise(sleeper), 'SVG'), null);
  assert.ok(toFastService(normalise(sleeper), 'PBO'), 'Peterborough is set down, so it prices');
});

test('a live Darwin board is unaffected, since it never states alighting', () => {
  const service = normalise(sleeper);
  // Undefined means "not stated", which must behave as it always did.
  service.stops[1].canAlight = undefined;
  assert.ok(toFastService(service, 'SVG'), 'an unstated stop still prices');
});

test('a hop of zero minutes is a real journey, not a parsing failure', () => {
  // The 05:13 Stonebridge Park leaves Harlesden at 05:21 and reaches Willesden
  // Junction at 05:21. Refusing equal times hid it, and it is the fastest way
  // between the two.
  const hop = normalise(
    {
      ...sleeper,
      dep: 321,
      origin: 'SBP',
      destination: 'Queens Park (London)',
      onward: [{ crs: 'WIJ', arr: 321, canAlight: true }],
    },
    'HDN'
  );
  const fast = toFastService(hop, 'WIJ');
  assert.ok(fast, 'a zero-minute hop must still price');
  assert.equal(fast.departure, '05:21');
  assert.equal(fast.arrival, '05:21');
});

test('a journey that truly ends before it starts is still refused', () => {
  const broken = normalise({ ...sleeper, dep: 600, onward: [{ crs: 'LDS', arr: 599, canAlight: true }] });
  assert.equal(toFastService(broken, 'LDS'), null);
});

test('the detail sheet gets the origin, which is behind the boarding point', () => {
  const calls = toServiceCalls(normalise(sleeper));
  assert.equal(calls.origin, 'London Kings Cross');
  assert.equal(calls.destination, 'Leeds');
  assert.equal(calls.calls.length, 4);
});

test('a station the app does not know falls back to its code', () => {
  const service = normalise({ ...sleeper, onward: [{ crs: 'ZZZ', arr: 1500, canAlight: true }] });
  assert.equal(service.stops[1].name, 'ZZZ');
});

test('an unknown operator falls back to its code rather than going blank', () => {
  assert.equal(normalise({ ...sleeper, toc: 'QQ' }).operatorName, 'QQ');
});

test('age is measured from when Darwin made the file, not when we wrote it', () => {
  const meta = {
    timetableId: '20260910020536',
    generatedAt: '2026-09-10T02:05:36',
    // A job cycling happily against a feed that stopped would look fresh if this
    // were the number used. It is not.
    publishedAt: '2026-09-14T09:00:00.000Z',
    serviceDates: ['2026-09-10'],
    boardCount: 1,
    departureCount: 1,
    operators: {},
  };
  const fourHoursLater = new Date('2026-09-10T06:05:36Z');
  assert.equal(ageSecondsOf(meta, fourHoursLater), 4 * 3600);
});

test('an unreadable generation time reads as infinitely old, never as fresh', () => {
  const meta = {
    timetableId: 'x',
    generatedAt: 'not a date',
    publishedAt: '2026-09-10T02:10:00.000Z',
    serviceDates: [],
    boardCount: 0,
    departureCount: 0,
    operators: {},
  };
  assert.equal(ageSecondsOf(meta, new Date()), Number.POSITIVE_INFINITY);
});
