import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  addDays,
  currentServiceDate,
  formatLondonTime,
  formatServiceDate,
  isValidIsoDate,
  londonDateOf,
  minutesBetween,
  serviceDayWindow,
  toInstantMillis,
} from './serviceDay.ts';

/**
 * The API sends departure times with no timezone at all -- `"2026-07-30T23:12:00"`,
 * verified against the live service -- and those are London wall-clock times.
 *
 * These tests deliberately use that shape. An earlier version used `Z`-suffixed
 * instants, which are unambiguous and therefore passed everywhere, hiding a bug that
 * only appeared once the code ran on a server in UTC: every departure an hour late,
 * each wrongly flagged as after midnight. `npm test` now runs under `TZ=UTC` so a
 * regression fails on a London laptop too.
 */

// In 2026, BST runs from 29 March to 25 October.

test('the service day does not roll over at midnight', () => {
  // 23:00 BST on the 29th -- squarely inside the 29th's service day.
  assert.equal(currentServiceDate(new Date('2026-07-29T22:00:00Z')), '2026-07-29');

  // 00:30 BST on the 30th. The calendar says the 30th; the trains still running
  // are the 29th's. This is the case that decides whether the app is useful or
  // actively misleading at ten past midnight.
  assert.equal(currentServiceDate(new Date('2026-07-29T23:30:00Z')), '2026-07-29');

  // 02:59 BST -- still the previous service day.
  assert.equal(currentServiceDate(new Date('2026-07-30T01:59:00Z')), '2026-07-29');

  // 03:00 BST -- the new service day has begun.
  assert.equal(currentServiceDate(new Date('2026-07-30T02:00:00Z')), '2026-07-30');
});

test('the service day boundary respects GMT as well as BST', () => {
  // 00:30 GMT in January: same rule, no offset applied.
  assert.equal(currentServiceDate(new Date('2026-01-15T00:30:00Z')), '2026-01-14');
  assert.equal(currentServiceDate(new Date('2026-01-15T03:30:00Z')), '2026-01-15');

  // 23:30 UTC in January is 23:30 London, so still the same day -- whereas the
  // identical UTC instant in July is 00:30 the next morning. A UTC-only
  // implementation gets exactly one of these two wrong.
  assert.equal(currentServiceDate(new Date('2026-01-15T23:30:00Z')), '2026-01-15');
  assert.equal(currentServiceDate(new Date('2026-07-15T23:30:00Z')), '2026-07-15');
});

test('the service day boundary rolls the month and year over', () => {
  assert.equal(currentServiceDate(new Date('2027-01-01T01:00:00Z')), '2026-12-31');
  assert.equal(currentServiceDate(new Date('2026-08-01T01:30:00Z')), '2026-07-31');
});

test('the query window covers 03:00 to 02:59 the next morning', () => {
  const window = serviceDayWindow('2026-07-29');
  assert.equal(window.timeFrom, '2026-07-29T03:00:00');
  assert.equal(window.timeTo, '2026-07-30T02:59:00');
});

test('the query window never exceeds the documented 23h59m maximum', () => {
  // Offset-less, so the API reads it as local to the station. Checking the span
  // in London terms is what matters: on the spring-forward night the local day is
  // only 23 hours long, and on the autumn night it is 25 -- the latter is the one
  // that could breach the limit.
  for (const date of ['2026-03-29', '2026-10-25', '2026-07-29', '2026-01-15']) {
    const window = serviceDayWindow(date);
    const from = new Date(`${window.timeFrom}Z`);
    const to = new Date(`${window.timeTo}Z`);
    const minutes = (to.getTime() - from.getTime()) / 60_000;
    assert.equal(minutes, 23 * 60 + 59, `window for ${date} must be exactly 23h59m`);
  }
});

test('a timezone-less time from the API is read as London, not as the server clock', () => {
  // This is the exact shape the API returns, and the exact bug: on a server running
  // UTC these read an hour late unless London is applied explicitly.
  assert.equal(formatLondonTime('2026-07-30T23:12:00'), '23:12');
  assert.equal(formatLondonTime('2026-07-30T00:22:00'), '00:22');
  assert.equal(londonDateOf('2026-07-30T23:12:00'), '2026-07-30');

  // Winter, when London is UTC, so the naive reading happens to agree.
  assert.equal(formatLondonTime('2026-01-15T23:12:00'), '23:12');
  assert.equal(londonDateOf('2026-01-15T23:12:00'), '2026-01-15');
});

test('a time that does carry an offset is still honoured', () => {
  // The spec permits both forms; the query echo comes back with an offset.
  assert.equal(formatLondonTime('2026-07-29T22:52:00Z'), '23:52');
  assert.equal(formatLondonTime('2026-07-29T23:52:00+01:00'), '23:52');
  assert.equal(formatLondonTime('2026-01-15T23:52:00Z'), '23:52');
});

test('times are formatted in London local time', () => {
  // The spec's own example: 23:52 -> 00:48.
  assert.equal(formatLondonTime('2026-07-29T22:52:00Z'), '23:52');
  assert.equal(formatLondonTime('2026-07-29T23:48:00Z'), '00:48');

  // Midnight must render as 00:00, never 24:00.
  assert.equal(formatLondonTime('2026-07-29T23:00:00Z'), '00:00');

  // Winter: no offset.
  assert.equal(formatLondonTime('2026-01-15T23:52:00Z'), '23:52');
});

test('London wall-clock times resolve to the right absolute instant', () => {
  // 23:12 BST is 22:12 UTC.
  assert.equal(
    new Date(toInstantMillis('2026-07-30T23:12:00')).toISOString(),
    '2026-07-30T22:12:00.000Z'
  );
  // 23:12 GMT is 23:12 UTC.
  assert.equal(
    new Date(toInstantMillis('2026-01-15T23:12:00')).toISOString(),
    '2026-01-15T23:12:00.000Z'
  );
  // Either side of the autumn change, when 01:30 happens twice. The first pass can
  // land on the wrong side of the transition, which is why there is a second.
  assert.equal(
    new Date(toInstantMillis('2026-10-25T00:30:00')).toISOString(),
    '2026-10-24T23:30:00.000Z'
  );
  assert.equal(
    new Date(toInstantMillis('2026-10-25T03:30:00')).toISOString(),
    '2026-10-25T03:30:00.000Z'
  );
});

test('the last trains of the night keep their real times', () => {
  // The reported bug, as a whole scenario: real c2c departures from Grays, as the
  // API sends them. Every one of these read an hour late in production.
  const serviceDate = '2026-07-30';
  const departures = ['2026-07-30T23:17:00', '2026-07-30T23:47:00', '2026-07-31T00:18:00'];
  const shown = departures.map((d) => ({
    at: formatLondonTime(d),
    afterMidnight: londonDateOf(d) !== serviceDate,
  }));

  assert.deepEqual(shown, [
    { at: '23:17', afterMidnight: false },
    { at: '23:47', afterMidnight: false },
    { at: '00:18', afterMidnight: true },
  ]);
});

test('an arrival after midnight is recognised as the next calendar day', () => {
  const departure = '2026-07-29T22:52:00Z'; // 23:52 BST on the 29th
  const arrival = '2026-07-29T23:48:00Z'; // 00:48 BST on the 30th

  assert.equal(londonDateOf(departure), '2026-07-29');
  assert.equal(londonDateOf(arrival), '2026-07-30');
  assert.notEqual(londonDateOf(departure), londonDateOf(arrival));
});

test('durations are correct across midnight and across a clock change', () => {
  // 23:52 -> 00:48 is 56 minutes, as the spec's example says.
  assert.equal(minutesBetween('2026-07-29T22:52:00Z', '2026-07-29T23:48:00Z'), 56);

  // Spring forward: London clocks jump 01:00 -> 02:00, so a train that appears
  // to depart 00:50 and arrive 02:10 really took 20 minutes. Comparing absolute
  // instants gets this right without special-casing.
  assert.equal(minutesBetween('2026-03-29T00:50:00Z', '2026-03-29T01:10:00Z'), 20);

  // Autumn back: 01:00-02:00 happens twice.
  assert.equal(minutesBetween('2026-10-25T00:50:00Z', '2026-10-25T01:30:00Z'), 40);
});

test('date arithmetic survives month, year and DST boundaries', () => {
  assert.equal(addDays('2026-12-31', 1), '2027-01-01');
  assert.equal(addDays('2026-01-01', -1), '2025-12-31');
  assert.equal(addDays('2026-02-28', 1), '2026-03-01'); // 2026 is not a leap year
  assert.equal(addDays('2028-02-28', 1), '2028-02-29'); // 2028 is
  assert.equal(addDays('2026-03-28', 1), '2026-03-29'); // clocks go forward
  assert.equal(addDays('2026-10-24', 1), '2026-10-25'); // clocks go back
  assert.equal(addDays('2026-07-29', 0), '2026-07-29');
});

test('dates are validated', () => {
  assert.ok(isValidIsoDate('2026-07-29'));
  assert.ok(!isValidIsoDate('29-07-2026'));
  assert.ok(!isValidIsoDate('2026-7-9'));
  assert.ok(!isValidIsoDate('2026-13-01'));
  assert.ok(!isValidIsoDate(''));
  assert.ok(!isValidIsoDate('tomorrow'));
});

test('service dates are rendered without drifting a day', () => {
  // Formatted from a midday UTC instant precisely so no offset can shift it.
  assert.equal(formatServiceDate('2026-07-29'), 'Wed 29 Jul');
  assert.equal(formatServiceDate('2026-01-01'), 'Thu 1 Jan');
});
