/**
 * Turning a station line-up into a list of boardable departures.
 *
 * The app answers "first and last train out of here, going that way", so a single
 * unfiltered line-up at one station is the query. Direction is derived per service
 * rather than filtered for -- see lib/direction.ts for why pairing each station
 * with its line's terminus would drop the very services that matter.
 *
 * Still direct services only: these are trains you can board here, going where
 * they are going. Nothing here plans an interchange.
 */

import { formatLondonTime, londonDateOf, type IsoDate } from './serviceDay.ts';
import type {
  CallType,
  DisplayAs,
  LocationLineUpObject,
  LocationLineUpResponse,
  LocationPair,
  LocationTemporalData,
  ServiceLocation,
} from './rtt.ts';

/** One boardable departure, in the shape the client renders. */
export interface DepartureService {
  /** `23:52`, London local. */
  dep: string;
  /** RFC3339 instant, kept so the client never has to re-derive the time. */
  depInstant: string;
  /** TOC code, e.g. `LE`, `CC`, `XR`. */
  toc: string;
  tocName: string;
  /** `via Tilbury` where the route is worth stating, else null. */
  via: string | null;
  /** Where the train itself is going, which may be short of the far terminus. */
  destination: string;
  /** True when the departure is after midnight, i.e. late in this service day. */
  departsAfterMidnight: boolean;
  platform: string | null;
  /** Rail replacement road transport. Badged, never silently shown as a train. */
  isReplacementBus: boolean;
  headcode: string | null;
  serviceId: string;
}

const PICKS_UP = new Set<string>(['ADVERTISED_OPEN', 'ADVERTISED_PICK_UP']);
const SETS_DOWN = new Set<string>(['ADVERTISED_OPEN', 'ADVERTISED_SET_DOWN']);
const CAN_BOARD = new Set<string>(['CALL', 'STARTS']);
const CAN_ALIGHT = new Set<string>(['CALL', 'TERMINATES']);

/**
 * Whether passengers may join or leave here.
 *
 * The timetable is the primary gate, because the question being asked is a
 * timetable question. A realtime call type is allowed to *add* a stop -- a
 * service altered to start or terminate at this station -- but a missing
 * realtime call type never removes one, which matters because a query for a
 * future date has no realtime data at all.
 *
 * OPERATIONAL_ONLY stops (crew changes and the like) fail both gates, as they
 * should: you cannot board them.
 */
function callTypeAllows(temporal: LocationTemporalData, allowed: Set<string>): boolean {
  const scheduled: CallType | undefined = temporal.scheduledCallType;
  if (scheduled && allowed.has(scheduled)) return true;
  const realtime: CallType | undefined = temporal.realtimeCallType;
  return Boolean(realtime && allowed.has(realtime));
}

/** Per the spec, a null `displayAs` means PASS -- so it must not count as a stop. */
function displayAllows(displayAs: DisplayAs | undefined, allowed: Set<string>): boolean {
  return Boolean(displayAs && allowed.has(displayAs));
}

function describePair(pairs: LocationPair[] | undefined): string {
  const names = (pairs ?? [])
    .map((pair) => pair.location?.description)
    .filter((name): name is string => Boolean(name));
  // Portion working: a service can have two destinations, e.g. splitting trains.
  return names.length ? names.join(' & ') : 'Unknown';
}

const platformOf = (service: LocationLineUpObject): string | null =>
  service.locationMetadata?.platform?.actual ??
  service.locationMetadata?.platform?.planned ??
  null;

export interface Departure {
  id: string;
  service: LocationLineUpObject;
  depInstant: string;
}

/** Departures a passenger can actually board here. */
function boardableDepartures(lineUp: LocationLineUpResponse | null): Departure[] {
  const out: Departure[] = [];

  for (const service of lineUp?.services ?? []) {
    const meta = service.scheduleMetadata;
    const temporal = service.temporalData;
    const id = meta?.uniqueIdentity;
    if (!id || !temporal) continue;

    // Empty stock, light engines and freight are not answers to this question.
    if (meta?.inPassengerService === false) continue;

    const depInstant = temporal.departure?.scheduleAdvertised;
    if (!depInstant) continue; // no public departure time => not advertised here

    if (!displayAllows(temporal.displayAs, CAN_BOARD)) continue;
    if (!callTypeAllows(temporal, PICKS_UP)) continue;
    if (temporal.departure?.isCancelled === true) continue;

    out.push({ id, service, depInstant });
  }

  return out;
}

/**
 * Every departure a passenger can board here, in time order.
 *
 * Sorted by us rather than trusted from the API, so the first and last of the
 * service day are unambiguous. Note that "last" is the 00:22 that leaves after
 * midnight, not the 23:52 -- the sort is on absolute instants and the query window
 * is the service day, so post-midnight departures land at the end where they
 * belong.
 */
export function sortedDepartures(lineUp: LocationLineUpResponse | null): Departure[] {
  const departures = boardableDepartures(lineUp);
  departures.sort((a, b) => Date.parse(a.depInstant) - Date.parse(b.depInstant));
  return departures;
}

// ----------------------------------------------------------------- corridor

/**
 * The CRS codes a service is bound for. Two of them, for a splitting train.
 *
 * Frequently empty: a line-up's origin and destination pairs carry a description but
 * no codes, verified against the live API. Use `destinationNames` alongside this.
 */
export function destinationCodes(service: LocationLineUpObject): string[] {
  const codes: string[] = [];
  for (const pair of service.destination ?? []) {
    for (const crs of pair.location?.shortCodes ?? []) codes.push(crs);
  }
  return codes;
}

/** The display names a service is bound for, which the API does reliably populate. */
export function destinationNames(service: LocationLineUpObject): string[] {
  const names: string[] = [];
  for (const pair of service.destination ?? []) {
    const name = pair.location?.description;
    if (name) names.push(name);
  }
  return names;
}

/**
 * Does this train actually go anywhere useful from here?
 *
 * The app covers three corridors, and a station line-up contains trains that leave
 * them entirely. At Liverpool Street, Greater Anglia runs to Cambridge, Stansted
 * and Enfield Town via Tottenham Hale, touching nothing in scope — those are not
 * answers to "first and last train east".
 *
 * The test is whether the service *calls* at an in-scope station ahead of where you
 * board. That is deliberately stricter than looking at the destination:
 *
 *   - It keeps the Colchester, Ipswich and Norwich trains that call at Shenfield.
 *     The spec is explicit that the last train to Shenfield is often one of these,
 *     so excluding them by destination would break the headline case.
 *   - It drops a fast service that runs through Shenfield without stopping, which
 *     is just as useless to you as a Cambridge train despite using the same line.
 *
 * A service query returns public calling points only: stations a train runs through
 * without stopping are absent from the pattern entirely, and no location carries a
 * `displayAs` -- unlike a location line-up, which does populate it. So `displayAs`
 * is treated as a veto when present rather than as a requirement, and the scheduled
 * call type does the real work. Both shapes were checked against the live API.
 *
 * At Shenfield itself, eastbound, nothing passes this test — the corridor ends
 * there. An empty answer is the correct one, per §6.
 */
export function servesScopeAhead(
  pattern: ServiceLocation[] | undefined,
  fromCrs: string,
  isInScope: (crs: string) => boolean
): boolean {
  if (!pattern?.length) return false;

  const boardingIndex = pattern.findIndex((stop) =>
    stop.location?.shortCodes?.includes(fromCrs)
  );
  if (boardingIndex === -1) return false;

  // Forward through the pattern is forward along the journey.
  for (let i = boardingIndex + 1; i < pattern.length; i++) {
    const stop = pattern[i];
    const temporal = stop.temporalData;
    if (!temporal) continue;

    // Must be somewhere you could actually get off. `displayAs` is a veto when
    // present rather than a requirement: a service query omits it entirely.
    if (temporal.displayAs && !CAN_ALIGHT.has(temporal.displayAs)) continue;
    if (!callTypeAllows(temporal, SETS_DOWN)) continue;
    if (temporal.arrival?.isCancelled === true) continue;

    for (const crs of stop.location?.shortCodes ?? []) {
      if (isInScope(crs)) return true;
    }
  }

  return false;
}

// ------------------------------------------------------------- route labelling

export interface RouteMarker {
  /** CRS code, resolved from the API at station-data generation time. */
  crs: string;
  label: string;
}

/**
 * Which way round did it go?
 *
 * More important now than when a destination was chosen, not less. From Fenchurch
 * Street, "east" mixes the Basildon main line with the Tilbury loop, and the loop
 * can be 20+ minutes slower -- so `23:52 towards Shoeburyness, via Tilbury` tells
 * you something a bare departure time cannot. Passing Pitsea says nothing about
 * whether the train goes anywhere near Grays.
 *
 * `toCrs` may be null, meaning "as far as this train goes", which is the case when
 * only a direction has been chosen. Markers are ordered most-distinctive first,
 * since a Tilbury loop service also passes through Rainham.
 */
export function deriveVia(
  locations: ServiceLocation[] | undefined,
  fromCrs: string,
  toCrs: string | null,
  markers: RouteMarker[]
): string | null {
  if (!locations?.length) return null;

  const crsAt = (index: number): string[] => locations[index]?.location?.shortCodes ?? [];
  const indexOf = (crs: string) =>
    locations.findIndex((loc) => loc.location?.shortCodes?.includes(crs));

  const start = indexOf(fromCrs);
  if (start === -1) return null;

  // With no destination, the stretch travelled runs to the end of the service.
  const end = toCrs === null ? locations.length : indexOf(toCrs);
  if (end === -1 || end <= start) return null;

  // Only the stretch actually travelled counts. A train that passes Basildon
  // after you have already got off says nothing about your journey.
  const traversed = new Set<string>();
  for (let i = start + 1; i < end; i++) {
    for (const crs of crsAt(i)) traversed.add(crs);
  }

  for (const marker of markers) {
    if (traversed.has(marker.crs)) return marker.label;
  }
  return null;
}

// ------------------------------------------------------------------- assembling

export interface BuildOptions {
  fromCrs: string;
  /** The service day being shown, which is what "after midnight" is relative to. */
  serviceDate: IsoDate;
  markers: RouteMarker[];
  /** Calling patterns for enriched services, keyed by uniqueIdentity. */
  callingPatterns?: Map<string, ServiceLocation[]>;
}

export function toDepartureService(
  departure: Departure,
  options: BuildOptions
): DepartureService {
  const meta = departure.service.scheduleMetadata ?? {};
  const pattern = options.callingPatterns?.get(departure.id);
  const mode = meta.modeType;

  return {
    dep: formatLondonTime(departure.depInstant),
    depInstant: departure.depInstant,
    toc: meta.operator?.code ?? '??',
    tocName: meta.operator?.name ?? 'Unknown operator',
    via: pattern ? deriveVia(pattern, options.fromCrs, null, options.markers) : null,
    destination: describePair(departure.service.destination),
    // Relative to the service day on screen, not to the train's own origin date:
    // a service *starting* at 00:22 has an origin date of the next calendar day,
    // which would read as "not after midnight" if compared the other way.
    departsAfterMidnight: londonDateOf(departure.depInstant) !== options.serviceDate,
    platform: platformOf(departure.service),
    isReplacementBus: mode === 'REPLACEMENT_BUS' || mode === 'SCHEDULED_BUS' || mode === 'BUS',
    headcode: meta.trainReportingIdentity ?? null,
    serviceId: departure.id,
  };
}
