import assert from 'node:assert/strict';
import test from 'node:test';

import { chooseCandidates } from './filteredLineUp.ts';

test('a filter that found nothing lists nothing, not the whole direction', () => {
  // The 204 case: the filtered line-up came back empty.
  assert.deepEqual(chooseCandidates(true, () => [], () => ['all', 'westbound']), []);
});

test('a filter that found trains lists them', () => {
  assert.deepEqual(chooseCandidates(true, () => ['2S12'], () => ['all']), ['2S12']);
});

test('no filter asked for lists the direction by bearing', () => {
  assert.deepEqual(chooseCandidates(false, () => [], () => ['all']), ['all']);
});
