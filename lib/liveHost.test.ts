import assert from 'node:assert/strict';
import { test } from 'node:test';

import { CANONICAL_HOST, isLiveHost } from './liveHost.ts';

/**
 * The rule that decides whether a deployment is allowed to answer as the API.
 *
 * The failure that matters is a false *negative*: locking out the alias the app is built
 * against would take the whole app down, and it would look exactly like the server being
 * off. Most of these guard that direction.
 */

test('the alias the app is built against answers', () => {
  assert.equal(isLiveHost(CANONICAL_HOST), true);
  assert.equal(isLiveHost(`${CANONICAL_HOST}:443`), true);
  // Host headers are case-insensitive and arrive however the client wrote them.
  assert.equal(isLiveHost(CANONICAL_HOST.toUpperCase()), true);
});

test('a dev server answers, on whatever port it landed on', () => {
  for (const host of ['localhost:3000', 'localhost', '127.0.0.1:3000', '[::1]:3000']) {
    assert.equal(isLiveHost(host), true, host);
  }
});

/**
 * The three URLs measured on 7 August 2026, all still serving a board that said the last
 * train south from Upminster was 18:34 when it was 00:33.
 */
test('a per-deployment URL does not answer', () => {
  for (const host of [
    'last-train-33hui4foq-dazreils-projects.vercel.app',
    'last-train-ldbsfus86-dazreils-projects.vercel.app',
    'last-train-dp4i1unu6-dazreils-projects.vercel.app',
  ]) {
    assert.equal(isLiveHost(host), false, host);
  }
});

/**
 * A prefix match would have accepted every one of the hashed URLs, since they all begin
 * `last-train-`. A suffix match would accept anything under `vercel.app`, which is
 * anyone's deployment. The comparison is the whole hostname or nothing.
 */
test('near misses are not near enough', () => {
  for (const host of [
    'last-train-dazreils-projects.vercel.app.evil.example',
    'evil.example',
    'last-train-dazreils-projects.vercel.app.',
    'notlast-train-dazreils-projects.vercel.app',
    'localhost.evil.example',
  ]) {
    assert.equal(isLiveHost(host), false, host);
  }
});

test('a missing host is refused rather than waved through', () => {
  assert.equal(isLiveHost(null), false);
  assert.equal(isLiveHost(''), false);
  assert.equal(isLiveHost('   '), false);
});

/**
 * An environment that has not been told its own name should serve, not refuse.
 *
 * Someone running this from a fork, or on a host that is not Vercel, has no canonical
 * name to compare against — and taking their API down over a missing constant would be a
 * worse failure than the stale deployments this exists to prevent.
 */
test('no canonical host configured means the check is off', () => {
  assert.equal(isLiveHost('anything.example', ''), true);
  assert.equal(isLiveHost(null, ''), true);
});

test('a fork only has one value to change', () => {
  assert.equal(isLiveHost('board.example.com', 'board.example.com'), true);
  assert.equal(isLiveHost(CANONICAL_HOST, 'board.example.com'), false);
});
