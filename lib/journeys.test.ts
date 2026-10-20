import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  describeDestination,
  destinationCodes,
  isBusMode,
  platformOf,
  sortedDepartures,
} from './journeys.ts';
import type { CallType, DisplayAs, LocationLineUpObject, LocationLineUpResponse } from './rtt.ts';
import { formatLondonTime } from './serviceDay.ts';

/**
 * Departure times here use the shape the API actually sends: a London wall-clock
 * time with no timezone at all. `Z`-suffixed instants would be unambiguous, and so
 * would pass under any server timezone -- which is precisely how an hour-late bug
 * reached production unnoticed. `npm test` runs under `TZ=UTC` to keep it honest.
 */

// ------------------------------------------------------------------- fixtures

interface StubOptions {
  id: string;
  depart?: string;
  displayAs?: DisplayAs;
  callType?: CallType;
  toc?: string;
  tocName?: string;
  destination?: string;
  inPassengerService?: boolean;
  cancelled?: boolean;
  platform?: string;
  mode?: 'TRAIN' | 'REPLACEMENT_BUS';
}

function stub(options: StubOptions): LocationLineUpObject {
  const {
    id,
    depart,
    displayAs = 'CALL',
    callType = 'ADVERTISED_OPEN',
    toc = 'CC',
    tocName = 'c2c',
    destination = 'Shoeburyness',
    inPassengerService = true,
    cancelled = false,
    platform,
    mode = 'TRAIN',
  } = options;

  return {
    temporalData: {
      displayAs,
      scheduledCallType: callType,
      ...(depart ? { departure: { scheduleAdvertised: depart, isCancelled: cancelled } } : {}),
    },
    ...(platform ? { locationMetadata: { platform: { planned: platform } } } : {}),
    scheduleMetadata: {
      uniqueIdentity: id,
      identity: id,
      operator: { code: toc, name: tocName },
      inPassengerService,
      modeType: mode,
    },
    destination: [{ location: { description: destination } }],
  };
}

const lineUp = (services: LocationLineUpObject[]): LocationLineUpResponse => ({ services });

// ------------------------------------------------------------------ departures

test('a boardable departure is returned with its London time', () => {
  const departures = sortedDepartures(
    lineUp([stub({ id: 'a', depart: '2026-07-29T23:52:00' })])
  );

  assert.equal(departures.length, 1);

  assert.equal(formatLondonTime(departures[0].depInstant), '23:52'); // BST
  assert.equal(describeDestination(departures[0].service), 'Shoeburyness');
  assert.equal(departures[0].service.scheduleMetadata?.operator?.code, 'CC');
});

test('a departure after midnight keeps its own time and belongs to this service day', () => {
  // 00:22 on the 30th is the last train of the 29th's service day. It is shown as
  // 00:22 and nothing else: the app works in service days throughout, so a next-day
  // marker would be reintroducing calendar days where they do not apply.
  const departures = sortedDepartures(
    lineUp([stub({ id: 'late', depart: '2026-07-30T00:22:00' })])
  );

  assert.equal(formatLondonTime(departures[0].depInstant), '00:22');
});

test('trains that only pass through are excluded', () => {
  const departures = sortedDepartures(
    lineUp([
      stub({ id: 'pass', depart: '2026-07-29T23:00:00', displayAs: 'PASS', callType: null }),
      stub({ id: 'stop', depart: '2026-07-29T23:30:00' }),
    ])
  );

  assert.deepEqual(
    departures.map((d) => d.id),
    ['stop']
  );
});

test('a null displayAs counts as a pass, not a stop', () => {
  const departures = sortedDepartures(
    lineUp([stub({ id: 'a', depart: '2026-07-29T23:00:00', displayAs: null, callType: null })])
  );
  assert.equal(departures.length, 0);
});

test('operational-only stops are excluded', () => {
  // A crew-change stop is a stop the public cannot board.
  const departures = sortedDepartures(
    lineUp([stub({ id: 'crew', depart: '2026-07-29T23:00:00', callType: 'OPERATIONAL_ONLY' })])
  );
  assert.equal(departures.length, 0);
});

test('a pick-up call can be boarded but a set-down call cannot', () => {
  assert.equal(
    sortedDepartures(
      lineUp([stub({ id: 'a', depart: '2026-07-29T23:00:00', callType: 'ADVERTISED_PICK_UP' })])
    ).length,
    1
  );
  assert.equal(
    sortedDepartures(
      lineUp([stub({ id: 'b', depart: '2026-07-29T23:00:00', callType: 'ADVERTISED_SET_DOWN' })])
    ).length,
    0
  );
});

test('empty stock and freight are excluded', () => {
  const departures = sortedDepartures(
    lineUp([
      stub({ id: 'ecs', depart: '2026-07-29T23:00:00', inPassengerService: false }),
      stub({ id: 'pax', depart: '2026-07-29T23:10:00' }),
    ])
  );
  assert.deepEqual(
    departures.map((d) => d.id),
    ['pax']
  );
});

test('cancelled departures are excluded', () => {
  const departures = sortedDepartures(
    lineUp([stub({ id: 'a', depart: '2026-07-29T23:00:00', cancelled: true })])
  );
  assert.equal(departures.length, 0);
});

test('departures come back in time order regardless of API order', () => {
  // The 00:22 is last, not first: it is after midnight but still tonight's train.
  const departures = sortedDepartures(
    lineUp([
      stub({ id: 'postMidnight', depart: '2026-07-30T00:22:00' }), // 00:22
      stub({ id: 'firstOfDay', depart: '2026-07-29T05:30:00' }), // 05:30
      stub({ id: 'evening', depart: '2026-07-29T23:52:00' }), // 23:52
    ])
  );

  assert.deepEqual(
    departures.map((d) => d.id),
    ['firstOfDay', 'evening', 'postMidnight']
  );
});

test('operators are merged in one list, never filtered apart', () => {
  // Liverpool Street eastbound is served by both Greater Anglia and the Elizabeth
  // line, and the last train is often the Greater Anglia one.
  const departures = sortedDepartures(
    lineUp([
      stub({ id: 'xr', depart: '2026-07-29T23:00:00', toc: 'XR', tocName: 'Elizabeth line' }),
      stub({ id: 'le', depart: '2026-07-29T23:30:00', toc: 'LE', tocName: 'Greater Anglia' }),
    ])
  );

  assert.deepEqual(
    departures.map((d) => d.service.scheduleMetadata?.operator?.code),
    ['XR', 'LE']
  );
});

test('a replacement bus is flagged rather than passed off as a train', () => {
  const departures = sortedDepartures(
    lineUp([stub({ id: 'bus', depart: '2026-07-29T10:00:00', mode: 'REPLACEMENT_BUS' })])
  );
  assert.equal(isBusMode(departures[0].service.scheduleMetadata?.modeType), true);
});

test('splitting trains show both destinations', () => {
  const service = stub({ id: 'split', depart: '2026-07-29T10:00:00' });
  service.destination = [
    { location: { description: 'Shoeburyness' } },
    { location: { description: 'Grays' } },
  ];

  const departures = sortedDepartures(lineUp([service]));
  assert.equal(describeDestination(departures[0].service), 'Shoeburyness & Grays');
});

test('destination codes are read for both portions of a splitting train', () => {
  const service: LocationLineUpObject = {
    destination: [
      { location: { shortCodes: ['SRY'] } },
      { location: { shortCodes: ['GRY'] } },
    ],
  };
  assert.deepEqual(destinationCodes(service), ['SRY', 'GRY']);
  assert.deepEqual(destinationCodes({}), []);
});

test('the platform is the live one when RTT has it, else the planned one', () => {
  assert.equal(platformOf(stub({ id: 'p', platform: '2' })), '2');
  const moved = stub({ id: 'm', platform: '2' });
  moved.locationMetadata = { platform: { planned: '2', actual: '3' } };
  assert.equal(platformOf(moved), '3');
  assert.equal(platformOf(stub({ id: 'n' })), null);
});
