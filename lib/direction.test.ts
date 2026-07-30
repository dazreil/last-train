import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  classifyDirection,
  isDirection,
  isOperatorInScope,
  oppositeOf,
  type LongitudeLookup,
} from './direction.ts';
import type { LocationLineUpObject } from './rtt.ts';

/**
 * Real longitudes, so the tests exercise the actual geography rather than made-up
 * numbers. Kept here only as test data -- nothing in the app reads them.
 */
const LON: Record<string, number> = {
  RDG: -0.972, // Reading
  HXX: -0.454, // Heathrow
  PAD: -0.176, // London Paddington
  ZFD: -0.105, // Farringdon
  FST: -0.079, // London Fenchurch Street
  LST: -0.081, // London Liverpool Street
  BKG: 0.081, // Barking
  ABW: 0.121, // Abbey Wood
  UPM: 0.251, // Upminster
  OCK: 0.293, // Ockendon
  GRY: 0.322, // Grays
  SNF: 0.33, // Shenfield
  TIL: 0.353, // Tilbury Town
  BSO: 0.462, // Basildon
  PSE: 0.52, // Pitsea
  SOC: 0.712, // Southend Central
  SRY: 0.795, // Shoeburyness
  NRW: 1.306, // Norwich -- out of scope, but a real eastbound destination
  CLT: 1.156, // Clacton -- likewise
};

const lookup: LongitudeLookup = (location) => {
  for (const crs of location?.shortCodes ?? []) {
    if (crs in LON) return LON[crs];
  }
  return null;
};

/** A line-up entry with an origin and destination, which is all classification reads. */
function service(originCrs: string | null, destinationCrs: string | null): LocationLineUpObject {
  return {
    ...(originCrs ? { origin: [{ location: { shortCodes: [originCrs] } }] } : {}),
    ...(destinationCrs ? { destination: [{ location: { shortCodes: [destinationCrs] } }] } : {}),
  };
}

// ---------------------------------------------------------------------- basics

test('at Grays, Shoeburyness is east and Fenchurch Street is west', () => {
  // The example from the brief.
  assert.equal(classifyDirection(service('FST', 'SRY'), LON.GRY, lookup), 'east');
  assert.equal(classifyDirection(service('SRY', 'FST'), LON.GRY, lookup), 'west');
});

test('a service terminating short is still classified by which way it went', () => {
  // This is the whole reason direction is derived rather than filtered for: the last
  // eastbound train out of Grays may well stop at Pitsea, never reaching Shoeburyness.
  assert.equal(classifyDirection(service('FST', 'PSE'), LON.GRY, lookup), 'east');
  assert.equal(classifyDirection(service('FST', 'TIL'), LON.GRY, lookup), 'east');

  // And westbound ones that terminate at Barking rather than running into town.
  assert.equal(classifyDirection(service('SRY', 'BKG'), LON.GRY, lookup), 'west');
});

test('both c2c routes out of Fenchurch Street are eastbound', () => {
  // Via Basildon and via the Tilbury loop reach the same places by different lines,
  // and longitude rises along both.
  assert.equal(classifyDirection(service('FST', 'SRY'), LON.FST, lookup), 'east');
  assert.equal(classifyDirection(service('FST', 'GRY'), LON.FST, lookup), 'east');
  assert.equal(classifyDirection(service('FST', 'BSO'), LON.FST, lookup), 'east');
});

test('the Ockendon branch is classified consistently from both ends', () => {
  // Grays is east of Ockendon, which is east of Upminster.
  assert.equal(classifyDirection(service('FST', 'GRY'), LON.OCK, lookup), 'east');
  assert.equal(classifyDirection(service('GRY', 'FST'), LON.OCK, lookup), 'west');
});

test('Elizabeth line branches sort east and west correctly', () => {
  // At Farringdon, in the central core.
  assert.equal(classifyDirection(service('RDG', 'ABW'), LON.ZFD, lookup), 'east');
  assert.equal(classifyDirection(service('RDG', 'SNF'), LON.ZFD, lookup), 'east');
  assert.equal(classifyDirection(service('SNF', 'RDG'), LON.ZFD, lookup), 'west');
  assert.equal(classifyDirection(service('ABW', 'HXX'), LON.ZFD, lookup), 'west');

  // Heathrow is west of Paddington, even though the branch runs south-west.
  assert.equal(classifyDirection(service('PAD', 'HXX'), LON.PAD, lookup), 'west');
});

test('Greater Anglia destinations beyond the app’s own station list still classify', () => {
  // Norwich and Clacton are deliberately absent from stations.json, which is why the
  // longitude table covers all of GB rather than just the corridors in scope.
  assert.equal(classifyDirection(service('LST', 'NRW'), LON.LST, lookup), 'east');
  assert.equal(classifyDirection(service('LST', 'CLT'), LON.SNF, lookup), 'east');
  assert.equal(classifyDirection(service('NRW', 'LST'), LON.SNF, lookup), 'west');
});

// -------------------------------------------------------------------- fallback

test('an unknown destination falls back to the origin, inverted', () => {
  // Came from the west, so it is heading east.
  assert.equal(classifyDirection(service('FST', 'ZZZ'), LON.GRY, lookup), 'east');
  // Came from the east, so it is heading west.
  assert.equal(classifyDirection(service('SRY', 'ZZZ'), LON.GRY, lookup), 'west');
});

test('a service that cannot be placed is not guessed at', () => {
  // Neither end resolves: returning a direction here would put the train under one
  // button arbitrarily, or under both.
  assert.equal(classifyDirection(service('ZZZ', 'YYY'), LON.GRY, lookup), null);
  assert.equal(classifyDirection(service(null, null), LON.GRY, lookup), null);

  // Starts and finishes where we are standing, so there is no direction to read.
  assert.equal(classifyDirection(service('GRY', 'GRY'), LON.GRY, lookup), null);
});

test('a destination too close to call yields no direction', () => {
  // Guards against reading a heading out of sub-100m noise. In practice
  // destinations are termini, tens of kilometres away, so this never fires on real
  // data -- the nearest real case is the Heathrow T4 shuttle at ~0.007 degrees,
  // comfortably clear of the threshold.
  const nextDoor: LongitudeLookup = () => LON.GRY + 0.0005;
  assert.equal(classifyDirection(service(null, 'anything'), LON.GRY, nextDoor), null);

  // Just past the threshold, a direction is reported.
  const justFarEnough: LongitudeLookup = () => LON.GRY + 0.003;
  assert.equal(classifyDirection(service(null, 'anything'), LON.GRY, justFarEnough), 'east');
});

// ----------------------------------------------------------------------- scope

test('only the three operators in scope are kept', () => {
  assert.ok(isOperatorInScope('CC')); // c2c
  assert.ok(isOperatorInScope('LE')); // Greater Anglia
  assert.ok(isOperatorInScope('XR')); // Elizabeth line

  // London Overground also calls at Barking; it was never part of this app.
  assert.ok(!isOperatorInScope('LO'));
  assert.ok(!isOperatorInScope('SE'));
  assert.ok(!isOperatorInScope(undefined));
  assert.ok(!isOperatorInScope(''));
});

test('direction parsing rejects anything else', () => {
  assert.ok(isDirection('east'));
  assert.ok(isDirection('west'));
  assert.ok(!isDirection('north'));
  assert.ok(!isDirection('East'));
  assert.ok(!isDirection(''));
});

test('the opposite direction is the return journey', () => {
  assert.equal(oppositeOf('east'), 'west');
  assert.equal(oppositeOf('west'), 'east');
});
