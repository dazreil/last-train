import assert from 'node:assert/strict';
import { test } from 'node:test';

import { directDestinations, popularAmong } from './directDestinations.ts';
import type { Compass } from './compass.ts';
import type { NormalizedService, NormalizedStop } from './darwin.ts';

/**
 * The picker's list, from trains that have already been given a direction.
 *
 * What is tested is the part after classification: which stops count, which direction a
 * station is filed under, and what is left out. The classification itself is the board's
 * own rule, injected, so these tests cannot drift from it.
 */

const stop = (crs: string, time: string, extra: Partial<NormalizedStop> = {}): NormalizedStop => ({
  crs,
  name: crs,
  time,
  timeInstant: `2026-09-23T${time}:00`,
  isCancelled: false,
  ...extra,
});

const train = (id: string, stops: NormalizedStop[]): NormalizedService => ({
  serviceId: id,
  operatorCode: 'CC',
  operatorName: 'c2c',
  originName: 'x',
  destinationName: stops.at(-1)!.name,
  platform: null,
  isCancelled: false,
  stops,
});

const nameOf = (crs: string) => `Station ${crs}`;
/** Direction by train id, standing in for the board's waypoint-then-bearing rule. */
const by = (map: Record<string, Compass | null>) => (s: NormalizedService) => map[s.serviceId] ?? null;

test('every stop after the boarding one is a destination, filed under its train', () => {
  const list = directDestinations(
    'UPM',
    [train('w1', [stop('UPM', '10:00'), stop('BKG', '10:08'), stop('FST', '10:25')])],
    by({ w1: 'west' }),
    nameOf
  );
  assert.deepEqual(
    list.map((d) => [d.crs, d.direction, d.minutes]),
    [['BKG', 'west', 8], ['FST', 'west', 25]]
  );
});

test('a station belongs to the direction that reaches it fastest', () => {
  // Upminster: the loop reaches Pitsea south in 34 minutes, the main line east in 15.
  const list = directDestinations(
    'UPM',
    [
      train('s1', [stop('UPM', '10:00'), stop('OCK', '10:06'), stop('PSE', '10:34')]),
      train('e1', [stop('UPM', '10:00'), stop('LAI', '10:07'), stop('PSE', '10:15')]),
    ],
    by({ s1: 'south', e1: 'east' }),
    nameOf
  );
  const pitsea = list.filter((d) => d.crs === 'PSE');
  assert.equal(pitsea.length, 1);
  assert.equal(pitsea[0].direction, 'east');
  assert.equal(pitsea[0].minutes, 15);
});

test('a tie is listed under both directions, not decided for you', () => {
  const list = directDestinations(
    'AAA',
    [
      train('n1', [stop('AAA', '10:00'), stop('TIE', '10:20')]),
      train('s1', [stop('AAA', '11:00'), stop('TIE', '11:20')]),
    ],
    by({ n1: 'north', s1: 'south' }),
    nameOf
  );
  assert.deepEqual(list.filter((d) => d.crs === 'TIE').map((d) => d.direction), ['north', 'south']);
});

test('the fastest train that day sets the time, not the first one', () => {
  const list = directDestinations(
    'UPM',
    [
      train('slow', [stop('UPM', '07:00'), stop('X', '07:40')]),
      train('fast', [stop('UPM', '19:00'), stop('X', '19:22')]),
    ],
    by({ slow: 'west', fast: 'west' }),
    nameOf
  );
  assert.equal(list[0].minutes, 22);
  assert.equal(list[0].trains, 2);
});

test('a stop you cannot get off at is not a destination', () => {
  // The 23:33 King's Cross to Leeds is take-up-only at Stevenage.
  const list = directDestinations(
    'KGX',
    [
      train('gr', [
        stop('KGX', '23:33'),
        stop('SVG', '23:54', { canAlight: false }),
        // Past midnight, so the next day on the clock.
        stop('PBO', '00:22', { timeInstant: '2026-09-24T00:22:00' }),
      ]),
    ],
    by({ gr: 'north' }),
    nameOf
  );
  assert.deepEqual(list.map((d) => d.crs), ['PBO']);
});

test('the station you are at is never offered, even when a loop comes back to it', () => {
  const list = directDestinations(
    'WAT',
    [train('loop', [stop('WAT', '10:00'), stop('CLJ', '10:07'), stop('KNG', '10:40'), stop('WAT', '11:20')])],
    by({ loop: 'west' }),
    nameOf
  );
  assert.ok(!list.some((d) => d.crs === 'WAT'));
});

test('a train that passes a station twice counts once towards it', () => {
  const list = directDestinations(
    'WAT',
    [train('loop', [stop('WAT', '10:00'), stop('CLJ', '10:07'), stop('KNG', '10:40'), stop('CLJ', '11:10')])],
    by({ loop: 'west' }),
    nameOf
  );
  const clj = list.find((d) => d.crs === 'CLJ')!;
  assert.equal(clj.trains, 1);
  assert.equal(clj.minutes, 7, 'the first pass, going out, is the journey');
});

test('a train with no direction is left out rather than guessed', () => {
  const list = directDestinations(
    'UPM',
    [train('odd', [stop('UPM', '10:00'), stop('ZZZ', '10:10')])],
    by({ odd: null }),
    nameOf
  );
  assert.deepEqual(list, []);
});

test('a zero-minute hop is a real destination', () => {
  const list = directDestinations(
    'HDN',
    [train('ow', [stop('HDN', '05:21'), stop('WIJ', '05:21')])],
    by({ ow: 'east' }),
    nameOf
  );
  assert.equal(list[0].crs, 'WIJ');
  assert.equal(list[0].minutes, 0);
});

test('the list comes back grouped: compass order, then journey time', () => {
  const list = directDestinations(
    'UPM',
    [
      train('w', [stop('UPM', '10:00'), stop('W2', '10:20'), stop('W1', '10:30')]),
      train('e', [stop('UPM', '10:00'), stop('E1', '10:05')]),
      train('n', [stop('UPM', '10:00'), stop('N1', '10:40')]),
    ],
    by({ w: 'west', e: 'east', n: 'north' }),
    nameOf
  );
  assert.deepEqual(list.map((d) => d.crs), ['N1', 'E1', 'W2', 'W1']);
});


const many = (crsList: string[], direction: Compass = 'west') =>
  crsList.map((crs, i) => ({ crs, direction, trains: 10, minutes: i + 1 }));

test('the busiest direct destinations come first, in the matrix order', () => {
  // Upminster's real ranking, which includes places it cannot reach directly.
  const list = many(['EMP', 'BKG', 'RMF', 'WEH', 'LHS', 'FST', 'OCK', 'WHR']);
  const busiest = ['WEH', 'FST', 'LST', 'BKG', 'LHS'];
  assert.deepEqual(popularAmong(list, busiest).map((p) => p.crs), ['WEH', 'FST', 'BKG']);
});

test('a station no direct train reaches is never offered, however busy', () => {
  const list = many(['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']);
  assert.deepEqual(popularAmong(list, ['LST', 'KGX', 'C']).map((p) => p.crs), ['C']);
});

test('a direction list gets its own busiest stations, however short', () => {
  // "West of UPM": six stations, and Fenchurch Street last in route order.
  const west = many(['EMP', 'BKG', 'RMF', 'WEH', 'LHS', 'FST']);
  assert.deepEqual(popularAmong(west, ['WEH', 'FST', 'OCK', 'BKG']).map((p) => p.crs), ['WEH', 'FST', 'BKG']);
});

test('a list no longer than the section gets none, since it would print the list twice', () => {
  assert.deepEqual(popularAmong(many(['A', 'B', 'C']), ['A', 'B', 'C']), []);
  assert.equal(popularAmong(many(['A', 'B', 'C', 'D']), ['A', 'B', 'C']).length, 3);
});

test('a station listed two ways is offered once, the way more trains go', () => {
  const list = [
    ...many(['A', 'B', 'C', 'D', 'E', 'F', 'G']),
    { crs: 'TIE', direction: 'north' as Compass, trains: 3, minutes: 5 },
    { crs: 'TIE', direction: 'south' as Compass, trains: 40, minutes: 5 },
  ];
  assert.deepEqual(popularAmong(list, ['TIE']), [{ crs: 'TIE', direction: 'south' }]);
});

test('a station with no matrix data gets no popular section rather than a wrong one', () => {
  assert.deepEqual(popularAmong(many(['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']), []), []);
});
