import assert from 'node:assert/strict';
import test from 'node:test';

import { placeTrain, type Waypoints } from './directionRule.ts';

// Barking: west has a waypoint (West Ham), east has none.
const barking: Waypoints = [
  ['north', undefined],
  ['east', undefined],
  ['south', undefined],
  ['west', 'WEH'],
];

// Upminster: two waypoints, which is the case they exist for.
const upminster: Waypoints = [
  ['north', undefined],
  ['east', 'LAI'],
  ['south', 'OCK'],
  ['west', undefined],
];

test('a train that calls at the waypoint belongs to that direction', () => {
  const calls = new Set(['WEH', 'FST']);
  assert.equal(placeTrain((c) => calls.has(c), barking, 'west'), 'west');
});

test('BUG-001: a diverted train that misses the waypoint goes by its bearing, not nowhere', () => {
  // 27 Sep 2026: Barking to Liverpool Street via Stratford, no West Ham.
  const calls = new Set(['SRA', 'LST']);
  assert.equal(placeTrain((c) => calls.has(c), barking, 'west'), 'west');
});

test('the Overground from Barking to Gospel Oak is on the west board, not hidden', () => {
  const calls = new Set(['WMW', 'GPO']);
  assert.equal(placeTrain((c) => calls.has(c), barking, 'west'), 'west');
});

test('a waypoint still separates two branches with the same bearing', () => {
  // Both run to Shoeburyness, so both bear east from Upminster.
  const viaOckendon = new Set(['OCK', 'GRY', 'SRY']);
  const viaLaindon = new Set(['WHR', 'LAI', 'SRY']);
  assert.equal(placeTrain((c) => viaOckendon.has(c), upminster, 'east'), 'south');
  assert.equal(placeTrain((c) => viaLaindon.has(c), upminster, 'east'), 'east');
});

test('a train is placed in one direction only', () => {
  // Calls at both waypoints, which no real train does: the first in compass order wins.
  const both = new Set(['LAI', 'OCK']);
  assert.equal(placeTrain((c) => both.has(c), upminster, 'west'), 'east');
});

test('no bearing and no waypoint: nowhere, as before', () => {
  assert.equal(placeTrain(() => false, barking, null), null);
});
