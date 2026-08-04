import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  bearingDegrees,
  classify,
  compassOf,
  distanceMetres,
  MIN_SEPARATION_METRES,
  tally,
} from './compass.ts';

/**
 * The mirror of `ios/Tests/LastTrainCoreTests/DirectionTests.swift`, on the same
 * coordinates and asserting the same answers.
 *
 * Two implementations of this rule now exist — one in the API, one on the device —
 * and they have to agree, or the counts on screen will not match the list beneath
 * them. Keeping the suites parallel is what makes a drift between them show up as a
 * failing test rather than as a train appearing under the wrong button.
 *
 * Fixtures are copied from `data/national.json`, which is generated. Each is
 * commented with its CRS so a wrong one is visible rather than plausible.
 */
const STATION = {
  inverness: { lat: 57.47987, lon: -4.223361 },          // INV
  wick: { lat: 58.441568, lon: -3.096859 },              // WCK
  aberdeen: { lat: 57.143704, lon: -2.098685 },          // ABD
  edinburgh: { lat: 55.952393, lon: -3.188228 },         // EDB
  kyleOfLochalsh: { lat: 57.279772, lon: -5.713813 },    // KYL

  upminster: { lat: 51.559018, lon: 0.25088 },           // UPM
  fenchurchStreet: { lat: 51.511646, lon: -0.078897 },   // FST
  shoeburyness: { lat: 51.530973, lon: 0.795345 },       // SRY
  romford: { lat: 51.574829, lon: 0.183237 },            // RMF
  barking: { lat: 51.539495, lon: 0.080903 },            // BKG

  // The Ockendon branch, which runs south out of Upminster to Grays.
  ockendon: { lat: 51.521992, lon: 0.290469 },           // OCK
  chaffordHundred: { lat: 51.485557, lon: 0.287447 },    // CFH
  grays: { lat: 51.476248, lon: 0.321832 },              // GRY

  penzance: { lat: 50.121674, lon: -5.532565 },          // PNZ
  stIves: { lat: 50.209045, lon: -5.477912 },            // SIV

  denton: { lat: 53.456866, lon: -2.13166 },             // DTN
  stalybridge: { lat: 53.484579, lon: -2.062742 },       // SYB
  stockport: { lat: 53.405538, lon: -2.163013 },         // SPT

  berneyArms: { lat: 52.589787, lon: 1.630376 },         // BYA
  norwich: { lat: 52.627154, lon: 1.30682 },             // NRW
  greatYarmouth: { lat: 52.61216, lon: 1.720886 },       // GYM
};

// ------------------------------------------- the case the compass exists for

test('Inverness sends trains in all four directions, and each reads right', () => {
  const from = STATION.inverness;
  assert.equal(classify(from, STATION.wick), 'north');
  assert.equal(classify(from, STATION.aberdeen), 'east');
  assert.equal(classify(from, STATION.edinburgh), 'south');
  assert.equal(classify(from, STATION.kyleOfLochalsh), 'west');
});

test('a station offers only the directions that have services', () => {
  // Upminster, using only the c2c main line and the Overground shuttle: west to
  // Fenchurch Street and Barking, east to Shoeburyness, north-west to Romford.
  const result = tally(STATION.upminster, [
    STATION.fenchurchStreet,
    STATION.barking,
    STATION.shoeburyness,
    STATION.romford,
  ]);

  assert.deepEqual(result.available, ['east', 'west']);
  assert.equal(result.counts.east, 1);
  assert.equal(result.counts.west, 3);
  assert.equal(result.counts.north, 0);
  assert.equal(result.counts.south, 0);
  assert.equal(result.unclassified, 0);
  assert.equal(result.total, 4);
});

test('the Ockendon branch is southbound, and used to be invisible', () => {
  // Both PRODUCT.md and IOS.md asserted that Upminster has no southbound service. It
  // has 16 on a weekday, down the Ockendon branch to Grays -- the 07:02 calls at
  // Ockendon, then Chafford Hundred, then Grays, each of them south and slightly east.
  // The claim survived only because the web app offered east and west and nothing
  // else, so a whole branch line was being folded into one of the two.
  assert.equal(classify(STATION.upminster, STATION.ockendon), 'south');
  assert.equal(classify(STATION.upminster, STATION.chaffordHundred), 'south');
  assert.equal(classify(STATION.upminster, STATION.grays), 'south');

  // With the branch included, Upminster has three directions, not two.
  const result = tally(STATION.upminster, [
    STATION.fenchurchStreet,
    STATION.shoeburyness,
    STATION.romford,
    STATION.grays,
  ]);
  assert.deepEqual(result.available, ['east', 'south', 'west']);
});

// ----------------------------------------------- the guard that ate a branch line

test('a branch line five kilometres away is still a direction', () => {
  // The regression that matters most in this file. Romford is 4.99km from Upminster.
  // A guard set anywhere in the kilometres silently removes every London Overground
  // departure on that branch -- 32 of them on the day the national probe ran.
  const metres = distanceMetres(STATION.upminster, STATION.romford);
  assert.ok(metres > 4_900 && metres < 5_100, `expected about 4.99km, got ${metres}`);

  assert.equal(classify(STATION.upminster, STATION.romford), 'west');
});

test('the guard is 140 metres, not kilometres', () => {
  assert.equal(MIN_SEPARATION_METRES, 140);

  // Roughly 100m north of Upminster: the same place, no meaningful bearing.
  const almostHere = { lat: STATION.upminster.lat + 0.0009, lon: STATION.upminster.lon };
  assert.ok(distanceMetres(STATION.upminster, almostHere) < 140);
  assert.equal(classify(STATION.upminster, almostHere), null);

  // Roughly 300m north: far enough to mean something.
  const clearlyNorth = { lat: STATION.upminster.lat + 0.0027, lon: STATION.upminster.lon };
  assert.ok(distanceMetres(STATION.upminster, clearlyNorth) > 140);
  assert.equal(classify(STATION.upminster, clearlyNorth), 'north');
});

test('a service terminating where you are standing has no direction', () => {
  assert.equal(classify(STATION.upminster, STATION.upminster), null);
});

test('a destination with no coordinates is unclassified, never guessed', () => {
  assert.equal(classify(STATION.upminster, null), null);
  assert.equal(classify(STATION.upminster, undefined), null);

  const result = tally(STATION.upminster, [STATION.shoeburyness, null, STATION.fenchurchStreet]);
  assert.equal(result.unclassified, 1);
  assert.equal(result.total, 2);
  assert.deepEqual(result.available, ['east', 'west']);
});

// ---------------------------------------------- the rest of the network probed

test('the far south-west reads north and east, never west into the Atlantic', () => {
  assert.equal(classify(STATION.penzance, STATION.stIves), 'north');
  assert.equal(classify(STATION.penzance, STATION.edinburgh), 'north');
  assert.deepEqual(tally(STATION.penzance, [STATION.stIves, STATION.edinburgh]).available, [
    'north',
  ]);
});

test('a two-train rural station still classifies both of them', () => {
  // Denton has two departures all day, one each way, 5.5km and 6.1km out. Under a
  // kilometres-scale guard this station would have no directions at all.
  assert.equal(classify(STATION.denton, STATION.stalybridge), 'east');
  assert.equal(classify(STATION.denton, STATION.stockport), 'south');

  assert.equal(classify(STATION.berneyArms, STATION.greatYarmouth), 'east');
  assert.equal(classify(STATION.berneyArms, STATION.norwich), 'west');
});

// ------------------------------------------------------------------- geometry

test('bearings match the ones the national probe measured', () => {
  const cases: [{ lat: number; lon: number }, { lat: number; lon: number }, number, string][] = [
    [STATION.upminster, STATION.romford, 290.6, 'Upminster to Romford'],
    [STATION.upminster, STATION.fenchurchStreet, 257.1, 'Upminster to Fenchurch Street'],
    [STATION.upminster, STATION.shoeburyness, 94.5, 'Upminster to Shoeburyness'],
    [STATION.penzance, STATION.stIves, 21.8, 'Penzance to St Ives'],
    [STATION.inverness, STATION.wick, 31.4, 'Inverness to Wick'],
    [STATION.inverness, STATION.kyleOfLochalsh, 256.6, 'Inverness to Kyle of Lochalsh'],
    [STATION.denton, STATION.stalybridge, 55.9, 'Denton to Stalybridge'],
    [STATION.denton, STATION.stockport, 200.0, 'Denton to Stockport'],
  ];

  for (const [from, to, expected, label] of cases) {
    const actual = bearingDegrees(from, to);
    assert.ok(Math.abs(actual - expected) < 0.1, `${label}: expected ${expected}, got ${actual}`);
  }
});

test('sector boundaries belong to the clockwise sector', () => {
  assert.equal(compassOf(0), 'north');
  assert.equal(compassOf(44.9), 'north');
  assert.equal(compassOf(45), 'east');
  assert.equal(compassOf(134.9), 'east');
  assert.equal(compassOf(135), 'south');
  assert.equal(compassOf(224.9), 'south');
  assert.equal(compassOf(225), 'west');
  assert.equal(compassOf(314.9), 'west');
  assert.equal(compassOf(315), 'north');
  assert.equal(compassOf(359.9), 'north');
});

test('bearings out of range are normalised rather than misfiled', () => {
  assert.equal(compassOf(360), 'north');
  assert.equal(compassOf(450), 'east');
  assert.equal(compassOf(-90), 'west');
});

test('the reverse bearing is the opposite direction', () => {
  // Not exactly 180 degrees apart on a sphere, but the sectors must oppose.
  assert.equal(classify(STATION.upminster, STATION.shoeburyness), 'east');
  assert.equal(classify(STATION.shoeburyness, STATION.upminster), 'west');
  assert.equal(classify(STATION.inverness, STATION.edinburgh), 'south');
  assert.equal(classify(STATION.edinburgh, STATION.inverness), 'north');
});

test('an empty line-up offers no directions rather than all of them', () => {
  const result = tally(STATION.upminster, []);
  assert.deepEqual(result.available, []);
  assert.equal(result.total, 0);
  assert.equal(result.unclassified, 0);
});
