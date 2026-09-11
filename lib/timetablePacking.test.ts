import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  boardKey,
  clockOf,
  instantOf,
  packBoard,
  unpackBoard,
  type PackedDeparture,
} from './timetablePacking.ts';

/**
 * The ingest writes this format and the app reads it. A silent disagreement
 * between the two would not fail: it would serve a board with the wrong times
 * on it. So the round trip is tested on the shapes that actually occur, not on
 * a tidy example.
 */

const departure = (over: Partial<PackedDeparture> = {}): PackedDeparture => ({
  dep: 1413,
  rid: '202609107044221',
  toc: 'CC',
  origin: 'FST',
  platform: '1',
  isBus: false,
  isConditional: false,
  destination: 'Laindon',
  onward: [
    { crs: 'LMS', arr: 1417, canAlight: true },
    { crs: 'UPM', arr: 1436, canAlight: true },
  ],
  ...over,
});

test('a board round-trips unchanged', () => {
  const board = [departure(), departure({ dep: 1440, rid: 'r2', destination: 'Grays' })];
  assert.deepEqual(unpackBoard(packBoard(board)), board);
});

test('an empty board packs and unpacks to nothing', () => {
  assert.equal(packBoard([]), '');
  assert.deepEqual(unpackBoard(''), []);
  assert.deepEqual(unpackBoard(null), []);
  assert.deepEqual(unpackBoard(undefined), []);
});

test('a departure with no onward calls survives', () => {
  const board = [departure({ onward: [] })];
  assert.deepEqual(unpackBoard(packBoard(board)), board);
});

test('a missing platform stays null rather than becoming an empty string', () => {
  const board = [departure({ platform: null })];
  assert.equal(unpackBoard(packBoard(board))[0].platform, null);
});

test('both flags survive independently', () => {
  for (const isBus of [true, false]) {
    for (const isConditional of [true, false]) {
      const [back] = unpackBoard(packBoard([departure({ isBus, isConditional })]));
      assert.equal(back.isBus, isBus, `isBus ${isBus}/${isConditional}`);
      assert.equal(back.isConditional, isConditional, `isConditional ${isBus}/${isConditional}`);
    }
  }
});

test('a stop a passenger may not get off at keeps its flag', () => {
  // The 23:33 King's Cross to Leeds: take-up-only at Stevenage.
  const board = [
    departure({
      destination: 'Leeds',
      onward: [
        { crs: 'SVG', arr: 1434, canAlight: false },
        { crs: 'PBO', arr: 1462, canAlight: true },
      ],
    }),
  ];
  const [back] = unpackBoard(packBoard(board));
  assert.equal(back.onward[0].canAlight, false);
  assert.equal(back.onward[1].canAlight, true);
});

test('times past midnight keep counting up', () => {
  const board = [departure({ dep: 1413, onward: [{ crs: 'LDS', arr: 1590, canAlight: true }] })];
  const [back] = unpackBoard(packBoard(board));
  assert.equal(back.onward[0].arr, 1590);
});

test('a minute needing all four digits is not truncated', () => {
  const board = [departure({ dep: 2879, onward: [{ crs: 'ABC', arr: 2879, canAlight: true }] })];
  const [back] = unpackBoard(packBoard(board));
  assert.equal(back.dep, 2879);
  assert.equal(back.onward[0].arr, 2879);
});

test('a minute of zero packs as four digits, not one', () => {
  const packed = packBoard([departure({ dep: 0, onward: [{ crs: 'ABC', arr: 0, canAlight: true }] })]);
  assert.match(packed, /ABC0000\./);
  assert.equal(unpackBoard(packed)[0].onward[0].arr, 0);
});

test('a destination containing spaces and punctuation survives', () => {
  const board = [departure({ destination: "London King's Cross & Hitchin (via Welwyn)" })];
  assert.deepEqual(unpackBoard(packBoard(board)), board);
});

test('a long onward list survives, so width assumptions hold at scale', () => {
  const onward = Array.from({ length: 39 }, (_, i) => ({
    crs: `A${String(i).padStart(2, '0')}`,
    arr: 300 + i * 7,
    canAlight: i % 5 !== 0,
  }));
  assert.deepEqual(unpackBoard(packBoard([departure({ onward })]))[0].onward, onward);
});

test('instantOf resolves a minute to the right London date', () => {
  assert.equal(instantOf('2026-09-10', 0), '2026-09-10T00:00:00');
  assert.equal(instantOf('2026-09-10', 1413), '2026-09-10T23:33:00');
  // Past midnight: still the 2026-09-10 board, but the 11th on the clock.
  assert.equal(instantOf('2026-09-10', 1590), '2026-09-11T02:30:00');
  assert.equal(instantOf('2026-09-10', 1440), '2026-09-11T00:00:00');
});

test('instantOf rolls a month and a year', () => {
  assert.equal(instantOf('2026-09-30', 1500), '2026-10-01T01:00:00');
  assert.equal(instantOf('2026-12-31', 1500), '2027-01-01T01:00:00');
});

test('instantOf is unmoved by the clocks changing', () => {
  // Britain puts the clocks back on 25 October 2026. Wall-clock arithmetic
  // means a board time is the time on the platform clock either way; doing this
  // in UTC milliseconds would slide an hour.
  assert.equal(instantOf('2026-10-24', 1590), '2026-10-25T02:30:00');
  assert.equal(instantOf('2026-03-28', 1500), '2026-03-29T01:00:00');
});

test('clockOf drops the day but keeps the time', () => {
  assert.equal(clockOf(1413), '23:33');
  assert.equal(clockOf(1590), '02:30');
  assert.equal(clockOf(0), '00:00');
  assert.equal(clockOf(1440), '00:00');
});

test('the origin survives, since the sheet names it', () => {
  const [back] = unpackBoard(packBoard([departure({ origin: 'SHB' })]));
  assert.equal(back.origin, 'SHB');
});

test('boardKey is stable and case-insensitive on the station', () => {
  assert.equal(boardKey('upm', '2026-09-10'), 'tt:board:UPM:2026-09-10');
  assert.equal(boardKey('UPM', '2026-09-10'), 'tt:board:UPM:2026-09-10');
});
