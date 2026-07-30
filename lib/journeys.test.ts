import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  deriveVia,
  destinationCodes,
  servesScopeAhead,
  sortedDepartures,
  toDepartureService,
  type RouteMarker,
} from './journeys.ts';
import type {
  CallType,
  DisplayAs,
  LocationLineUpObject,
  LocationLineUpResponse,
  ServiceLocation,
} from './rtt.ts';

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

const buildOptions = {
  fromCrs: 'GRY',
  markers: [] as RouteMarker[],
};

// ------------------------------------------------------------------ departures

test('a boardable departure is returned with its London time', () => {
  const departures = sortedDepartures(
    lineUp([stub({ id: 'a', depart: '2026-07-29T23:52:00' })])
  );

  assert.equal(departures.length, 1);

  const service = toDepartureService(departures[0], buildOptions);
  assert.equal(service.dep, '23:52'); // BST
  assert.equal(service.destination, 'Shoeburyness');
  assert.equal(service.toc, 'CC');
});

test('a departure after midnight keeps its own time and belongs to this service day', () => {
  // 00:22 on the 30th is the last train of the 29th's service day. It is shown as
  // 00:22 and nothing else: the app works in service days throughout, so a next-day
  // marker would be reintroducing calendar days where they do not apply.
  const departures = sortedDepartures(
    lineUp([stub({ id: 'late', depart: '2026-07-30T00:22:00' })])
  );

  const service = toDepartureService(departures[0], buildOptions);
  assert.equal(service.dep, '00:22');
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
    departures.map((d) => toDepartureService(d, buildOptions).toc),
    ['XR', 'LE']
  );
});

test('a replacement bus is flagged rather than passed off as a train', () => {
  const departures = sortedDepartures(
    lineUp([stub({ id: 'bus', depart: '2026-07-29T10:00:00', mode: 'REPLACEMENT_BUS' })])
  );
  assert.equal(toDepartureService(departures[0], buildOptions).isReplacementBus, true);
});

test('splitting trains show both destinations', () => {
  const service = stub({ id: 'split', depart: '2026-07-29T10:00:00' });
  service.destination = [
    { location: { description: 'Shoeburyness' } },
    { location: { description: 'Grays' } },
  ];

  const departures = sortedDepartures(lineUp([service]));
  assert.equal(
    toDepartureService(departures[0], buildOptions).destination,
    'Shoeburyness & Grays'
  );
});

// ----------------------------------------------------------------------- route

const MARKERS: RouteMarker[] = [
  { crs: 'TIL', label: 'via Tilbury' },
  { crs: 'OCK', label: 'via Ockendon' },
  { crs: 'RNM', label: 'via Rainham' },
  { crs: 'BSO', label: 'via Basildon' },
];

const callingAt = (...codes: string[]): ServiceLocation[] =>
  codes.map((crs) => ({ location: { shortCodes: [crs] } }));

test('with no destination the route runs to the end of the service', () => {
  // Standing at Fenchurch Street, "east" mixes both routes, and only the via label
  // distinguishes them.
  const viaTilbury = callingAt('FST', 'BKG', 'RNM', 'GRY', 'TIL', 'PSE', 'SOC', 'SRY');
  assert.equal(deriveVia(viaTilbury, 'FST', null, MARKERS), 'via Tilbury');

  const viaBasildon = callingAt('FST', 'BKG', 'UPM', 'LAI', 'BSO', 'PSE', 'SOC', 'SRY');
  assert.equal(deriveVia(viaBasildon, 'FST', null, MARKERS), 'via Basildon');

  const viaOckendon = callingAt('FST', 'BKG', 'UPM', 'OCK', 'CFH', 'GRY');
  assert.equal(deriveVia(viaOckendon, 'FST', null, MARKERS), 'via Ockendon');
});

test('boarding partway along, only the stretch ahead of you counts', () => {
  // This service passes Rainham before Grays, but from Grays it is Tilbury onward.
  const eastbound = callingAt('FST', 'BKG', 'RNM', 'GRY', 'TIL', 'PSE', 'SOC');
  assert.equal(deriveVia(eastbound, 'GRY', null, MARKERS), 'via Tilbury');

  // The same train, but boarding at Tilbury: nothing distinctive remains ahead.
  assert.equal(deriveVia(eastbound, 'TIL', null, MARKERS), null);
});

test('westbound from Grays, the two routes back to town are named', () => {
  const viaOckendon = callingAt('GRY', 'CFH', 'OCK', 'UPM', 'BKG', 'FST');
  assert.equal(deriveVia(viaOckendon, 'GRY', null, MARKERS), 'via Ockendon');

  const viaRainham = callingAt('GRY', 'PFL', 'RNM', 'DDK', 'BKG', 'FST');
  assert.equal(deriveVia(viaRainham, 'GRY', null, MARKERS), 'via Rainham');
});

test('the most distinctive marker wins', () => {
  // A Tilbury loop service also passes Rainham; "via Tilbury" is the useful label.
  const locations = callingAt('FST', 'RNM', 'PFL', 'GRY', 'TIL', 'SLH', 'PSE');
  assert.equal(deriveVia(locations, 'FST', null, MARKERS), 'via Tilbury');
});

test('an unambiguous route gets no label', () => {
  const locations = callingAt('LST', 'STF', 'IFD', 'RMF', 'BWD', 'SNF');
  assert.equal(deriveVia(locations, 'LST', null, MARKERS), null);
});

test('a fixed destination still bounds the route, ignoring markers beyond it', () => {
  // The pair form is still used by the tests and remains correct: this train
  // reaches Tilbury, but not before Grays, where you got off.
  const locations = callingAt('FST', 'BKG', 'DDK', 'RNM', 'GRY', 'TIL', 'PSE');
  assert.equal(deriveVia(locations, 'FST', 'GRY', MARKERS), 'via Rainham');
});

// -------------------------------------------------------------------- corridor

/**
 * The stations the app knows about, for the Liverpool Street corridor. Chelmsford,
 * Colchester, Norwich and Cambridge are deliberately absent -- that is the point.
 */
const IN_SCOPE = new Set(['LST', 'STF', 'IFD', 'RMF', 'BWD', 'SNF', 'ZLW', 'CUS', 'ABW']);
const isInScope = (crs: string) => IN_SCOPE.has(crs);

/**
 * A calling pattern as `/gb-nr/service` really returns one, verified against the
 * live API: no `displayAs` on any location, and stations the train runs through
 * without stopping are absent from the list entirely rather than marked as passes.
 */
const stopsAt = (...codes: string[]): ServiceLocation[] =>
  codes.map((crs, index) => ({
    location: { shortCodes: [crs] },
    temporalData: {
      scheduledCallType:
        index === 0
          ? ('ADVERTISED_PICK_UP' as const)
          : index === codes.length - 1
            ? ('ADVERTISED_SET_DOWN' as const)
            : ('ADVERTISED_OPEN' as const),
      ...(index > 0 ? { arrival: { scheduleAdvertised: '2026-07-31T09:00:00' } } : {}),
      ...(index < codes.length - 1
        ? { departure: { scheduleAdvertised: '2026-07-31T09:01:00' } }
        : {}),
    },
  }));

test('a long-distance train that calls at Shenfield is in the corridor', () => {
  // The headline case. Greater Anglia no longer serves Ilford or Romford, so its
  // Shenfield trains are the Norwich and Colchester expresses passing through -- and
  // the spec is explicit that the last train to Shenfield is often one of them.
  const norwich = stopsAt('LST', 'SNF', 'CHM', 'COL', 'NRW');
  assert.equal(servesScopeAhead(norwich, 'LST', isInScope), true);
});

test('a train that runs through Shenfield without stopping is not', () => {
  // Running down the same line is not the same as being useful: you cannot get off.
  // The API expresses this by omitting Shenfield from the pattern altogether.
  const fastToChelmsford = stopsAt('LST', 'CHM', 'COL');
  assert.equal(servesScopeAhead(fastToChelmsford, 'LST', isInScope), false);
});

test('a location carrying no displayAs is still recognised as a call', () => {
  // The regression this guards against: gating on displayAs, which a service query
  // never sends, silently rejected every calling point and made every train look
  // off-corridor.
  const pattern: ServiceLocation[] = [
    { location: { shortCodes: ['LST'] }, temporalData: { scheduledCallType: 'ADVERTISED_PICK_UP' } },
    { location: { shortCodes: ['SNF'] }, temporalData: { scheduledCallType: 'ADVERTISED_OPEN' } },
  ];
  assert.equal(pattern[1].temporalData?.displayAs, undefined);
  assert.equal(servesScopeAhead(pattern, 'LST', isInScope), true);
});

test('a cancelled call ahead does not count as reachable', () => {
  const pattern: ServiceLocation[] = [
    { location: { shortCodes: ['LST'] }, temporalData: { scheduledCallType: 'ADVERTISED_PICK_UP' } },
    {
      location: { shortCodes: ['SNF'] },
      temporalData: {
        scheduledCallType: 'ADVERTISED_OPEN',
        arrival: { scheduleAdvertised: '2026-07-31T09:30:00', isCancelled: true },
      },
    },
  ];
  assert.equal(servesScopeAhead(pattern, 'LST', isInScope), false);
});

test('trains leaving the corridor entirely are excluded', () => {
  // Cambridge and Stansted services leave Liverpool Street via Tottenham Hale and
  // touch nothing in scope.
  assert.equal(servesScopeAhead(stopsAt('LST', 'TOM', 'BSS', 'CBG'), 'LST', isInScope), false);
  assert.equal(servesScopeAhead(stopsAt('LST', 'CHH', 'EDR', 'ENF'), 'LST', isInScope), false);
});

test('Elizabeth line services on both eastbound branches are in the corridor', () => {
  assert.equal(servesScopeAhead(stopsAt('LST', 'STF', 'IFD', 'SNF'), 'LST', isInScope), true);
  assert.equal(servesScopeAhead(stopsAt('LST', 'ZLW', 'CUS', 'ABW'), 'LST', isInScope), true);
});

test('only stations ahead of where you board count', () => {
  const pattern = stopsAt('LST', 'STF', 'IFD', 'SNF', 'CHM', 'COL');

  // From Shenfield, everything in scope is behind you: the corridor ends here, so
  // eastbound there is genuinely nothing, which is correct behaviour per §6.
  assert.equal(servesScopeAhead(pattern, 'SNF', isInScope), false);

  // From Ilford, Shenfield is still ahead.
  assert.equal(servesScopeAhead(pattern, 'IFD', isInScope), true);
});

test('corridor checking copes with missing or unusable data', () => {
  assert.equal(servesScopeAhead(undefined, 'LST', isInScope), false);
  assert.equal(servesScopeAhead([], 'LST', isInScope), false);
  // Boarding station absent from the pattern.
  assert.equal(servesScopeAhead(stopsAt('AAA', 'BBB'), 'LST', isInScope), false);
  // Boarding at the final stop.
  assert.equal(servesScopeAhead(stopsAt('LST', 'SNF'), 'SNF', isInScope), false);
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

test('route derivation copes with missing or unusable data', () => {
  assert.equal(deriveVia(undefined, 'FST', null, MARKERS), null);
  assert.equal(deriveVia([], 'FST', null, MARKERS), null);
  // Boarding point absent from the calling pattern.
  assert.equal(deriveVia(callingAt('AAA', 'BBB'), 'FST', null, MARKERS), null);
  // Boarding at the last stop: nothing ahead.
  assert.equal(deriveVia(callingAt('FST', 'BKG', 'SOC'), 'SOC', null, MARKERS), null);
  // Adjacent stations, nothing in between.
  assert.equal(deriveVia(callingAt('FST', 'SOC'), 'FST', 'SOC', MARKERS), null);
});
