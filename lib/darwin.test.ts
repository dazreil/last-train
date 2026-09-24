import assert from 'node:assert/strict';
import test from 'node:test';

import { normalize, toFastService } from './darwin.ts';

/** A live board generated at 21:40 London (20:40 UTC) on 24 September 2026. */
function board(services: unknown[], generatedAt = '2026-09-24T21:40:00.0000000+01:00') {
  return { locationName: 'East Tilbury', crs: 'ETL', generatedAt, trainServices: services } as never;
}

function service(std: string, etd: string, upmSt: string, upmEt: string) {
  return {
    serviceID: `s${std}`,
    std,
    etd,
    operator: 'c2c',
    operatorCode: 'CC',
    destination: [{ locationName: 'Fenchurch Street', crs: 'FST' }],
    subsequentCallingPoints: [{ callingPoint: [{ locationName: 'Upminster', crs: 'UPM', st: upmSt, et: upmEt }] }],
  };
}

/** The bug found on 24 September 2026: dated tomorrow, sorted last, unfollowable, stuck. */
test('a late train still listed after its timetabled minute stays today', () => {
  const [late] = normalize(board([service('21:37', '21:41', '22:00', '22:04')]));
  assert.equal(late.stops[0].timeInstant, '2026-09-24T21:37:00');
  assert.equal(late.stops[0].expectedInstant, '2026-09-24T21:41:00');
  const fast = toFastService(late, 'UPM');
  assert.equal(fast?.arrivalInstant, '2026-09-24T22:00:00');
  assert.equal(fast?.expectedArrivalInstant, '2026-09-24T22:04:00');
});

test('a train after midnight on a late-evening board is still tomorrow', () => {
  const [after] = normalize(
    board([service('00:05', 'On time', '00:30', 'On time')], '2026-09-24T23:50:00.0000000+01:00')
  );
  assert.equal(after.stops[0].timeInstant, '2026-09-25T00:05:00');
  assert.equal(after.stops[1].timeInstant, '2026-09-25T00:30:00');
});

test('a journey that crosses midnight rolls its later stops, not its first', () => {
  const [crossing] = normalize(
    board([service('23:55', 'On time', '00:20', 'On time')], '2026-09-24T23:50:00.0000000+01:00')
  );
  assert.equal(crossing.stops[0].timeInstant, '2026-09-24T23:55:00');
  assert.equal(crossing.stops[1].timeInstant, '2026-09-25T00:20:00');
});

test('a late train across midnight gets tomorrow for its estimate', () => {
  const [late] = normalize(board([service('23:55', '00:05', '00:20', '00:30')], '2026-09-24T23:58:00.0000000+01:00'));
  assert.equal(late.stops[0].timeInstant, '2026-09-24T23:55:00');
  assert.equal(late.stops[0].expectedInstant, '2026-09-25T00:05:00');
  assert.equal(late.stops[1].expectedInstant, '2026-09-25T00:30:00');
});
