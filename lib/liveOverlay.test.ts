import assert from 'node:assert/strict';
import test from 'node:test';

import { applyLive, needsLive } from './liveOverlay.ts';
import type { NationalService } from './nationalContract.ts';
import type { LiveDeparture } from './darwin.ts';

/** 23:00 London on 24 September 2026 is 22:00 UTC. */
const NOW = Date.parse('2026-09-24T22:00:00.000Z');

function service(dep: string, depInstant: string, destination = 'Southend Central'): NationalService {
  return {
    dep,
    depInstant,
    toc: 'CC',
    tocName: 'c2c',
    destination,
    platform: '2',
    isReplacementBus: false,
    headcode: '2S99',
    serviceId: `x:${dep}`,
    role: 'last',
    journeyMinutes: null,
  };
}

function row(std: string, etd: string | null, destinationName = 'Southend Central', isCancelled = false): LiveDeparture {
  return { std, etd, destinationCrs: null, destinationName, isCancelled };
}

test('a late train gets its expected time, as a UTC instant', () => {
  const [out] = applyLive([service('23:19', '2026-09-24T22:19:00.000Z')], [row('23:19', '23:24')], NOW);
  assert.equal(out.expectedDep, '23:24');
  assert.equal(out.expectedDepInstant, '2026-09-24T22:24:00.000Z');
});

test('on time changes nothing', () => {
  const [out] = applyLive([service('23:19', '2026-09-24T22:19:00.000Z')], [row('23:19', 'On time')], NOW);
  assert.equal(out.expectedDep, undefined);
  assert.equal(out.isDelayed, undefined);
});

test('delayed with no estimate says so', () => {
  const [out] = applyLive([service('23:19', '2026-09-24T22:19:00.000Z')], [row('23:19', 'Delayed')], NOW);
  assert.equal(out.isDelayed, true);
  assert.equal(out.expectedDep, undefined);
});

test('a cancelled train is kept and marked, not dropped', () => {
  const out = applyLive([service('23:19', '2026-09-24T22:19:00.000Z')], [row('23:19', 'Cancelled', 'Southend Central', true)], NOW);
  assert.equal(out.length, 1);
  assert.equal(out[0].isCancelled, true);
});

/** The last train home is often just past midnight. */
test('a delay across midnight lands on the next day', () => {
  const [out] = applyLive([service('23:55', '2026-09-24T22:55:00.000Z')], [row('23:55', '00:05')], NOW);
  assert.equal(out.expectedDep, '00:05');
  assert.equal(out.expectedDepInstant, '2026-09-24T23:05:00.000Z');
});

test('two trains in one minute are told apart by destination', () => {
  const services = [service('23:19', '2026-09-24T22:19:00.000Z', 'Shoeburyness')];
  const live = [row('23:19', '23:30', 'Southend Central'), row('23:19', '23:22', 'Shoeburyness')];
  assert.equal(applyLive(services, live, NOW)[0].expectedDep, '23:22');
});

/** Saying nothing beats attaching another train's delay. */
test('an ambiguous match is left alone', () => {
  const services = [service('23:19', '2026-09-24T22:19:00.000Z', 'Pitsea')];
  const live = [row('23:19', '23:30', 'Southend Central'), row('23:19', '23:22', 'Shoeburyness')];
  assert.equal(applyLive(services, live, NOW)[0].expectedDep, undefined);
});

test('trains beyond the live window are untouched, and do not ask for it', () => {
  const far = service('05:31', '2026-09-25T04:31:00.000Z');
  assert.equal(needsLive([far], NOW), false);
  assert.equal(applyLive([far], [row('05:31', '05:40')], NOW)[0].expectedDep, undefined);
  assert.equal(needsLive([service('23:19', '2026-09-24T22:19:00.000Z')], NOW), true);
});
