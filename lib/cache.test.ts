import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  getCachedCalls,
  getCachedLocations,
  setCachedCalls,
  setCachedLocations,
} from './cache.ts';

/**
 * The two per-service caches must not be able to see each other.
 *
 * `/api/trains` stores raw RTT `locations`; `/api/v2/service` stores a rendered
 * `ServiceCalls`. Both key on the same `gb-nr:…` identity, and the accessor used to be
 * generic over an unconstrained `T` — so whichever route wrote first handed its shape to
 * the other, typed as the shape it expected. Nothing checked the cast.
 *
 * It surfaced as the app reporting "the server sent something this version cannot read",
 * intermittently, depending on which route had run in that process first. Both orders
 * are exercised here because only one was ever observed, and the reverse corrupts route
 * labelling silently rather than loudly.
 */

const locations = [{ location: { description: 'Upminster' } }];
const calls = { serviceId: 'x', headcode: '2W33', calls: [] };

test('locations written first are not served as calls', () => {
  const id = 'gb-nr:Y65292:2026-08-09';
  setCachedLocations(id, locations, 60);

  assert.equal(getCachedCalls(id), null, 'a calls lookup must not see the locations entry');
  assert.deepEqual(getCachedLocations<typeof locations>(id)?.value, locations);
});

test('calls written first are not served as locations', () => {
  const id = 'gb-nr:AAAAA:2026-08-09';
  setCachedCalls(id, calls, 60);

  assert.equal(getCachedLocations(id), null, 'a locations lookup must not see the calls entry');
  assert.deepEqual(getCachedCalls<typeof calls>(id)?.value, calls);
});

/** Both routes may legitimately have cached the same train. Neither should evict the other. */
test('both shapes coexist for one service', () => {
  const id = 'gb-nr:BBBBB:2026-08-09';
  setCachedLocations(id, locations, 60);
  setCachedCalls(id, calls, 60);

  assert.deepEqual(getCachedLocations<typeof locations>(id)?.value, locations);
  assert.deepEqual(getCachedCalls<typeof calls>(id)?.value, calls);
});
