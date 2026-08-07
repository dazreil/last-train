import assert from 'node:assert/strict';
import { test } from 'node:test';

import { CANONICAL_HOST, isLiveHost } from './liveHost.ts';

/**
 * The rule that keeps stale deployments from answering as the API.
 *
 * The failure that matters is a **false accept**: a hashed deployment URL that this lets
 * through goes on serving its own build forever, and an old build answers 18:34 where
 * the live one answers 00:33. A false reject is loud and gets fixed in minutes.
 */

test('the alias the app is built against answers', () => {
  assert.equal(isLiveHost(CANONICAL_HOST), true);
  assert.equal(isLiveHost(`${CANONICAL_HOST}:443`), true);
  assert.equal(isLiveHost(CANONICAL_HOST.toUpperCase()), true);
});

/** The three that were measured serving 18:34 on 7 August 2026. */
test('the hashed per-deployment URLs do not', () => {
  for (const host of [
    'last-train-33hui4foq-dazreils-projects.vercel.app',
    'last-train-ldbsfus86-dazreils-projects.vercel.app',
    'last-train-dp4i1unu6-dazreils-projects.vercel.app',
  ]) {
    assert.equal(isLiveHost(host), false, `${host} should be refused`);
  }
});

test('local development keeps working, on any port', () => {
  for (const host of ['localhost:3000', 'localhost', '127.0.0.1:3000', '[::1]:3000']) {
    assert.equal(isLiveHost(host), true, `${host} should be allowed`);
  }
});

/**
 * A prefix match would accept every one of these, which is why the comparison is on the
 * whole hostname. `vercel.app` is a shared domain — anyone can deploy to it.
 */
test('lookalike hosts are refused', () => {
  for (const host of [
    'last-train-dazreils-projects.vercel.app.evil.test',
    'evil-last-train-dazreils-projects.vercel.app',
    'last-train-dazreils-projects.vercel.app.',
    'localhost.evil.test',
    'notlocalhost',
  ]) {
    assert.equal(isLiveHost(host), false, `${host} should be refused`);
  }
});

test('a missing Host header is refused, not waved through', () => {
  assert.equal(isLiveHost(null), false);
  assert.equal(isLiveHost(undefined), false);
  assert.equal(isLiveHost(''), false);
});

/**
 * An environment that has not been told its own name should not refuse everything.
 *
 * Deploying somewhere else and having every request fail closed would be a worse
 * outcome than the staleness this prevents — and far harder to diagnose, since the
 * cause would be a value that is absent rather than wrong.
 */
test('no canonical host configured disables the check', () => {
  assert.equal(isLiveHost('anything.example', ''), true);
  assert.equal(isLiveHost(null, ''), true);
});
