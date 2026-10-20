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

import { toInstantMillis } from './serviceDay.ts';
import type {
  CallType,
  DisplayAs,
  LocationLineUpObject,
  LocationLineUpResponse,
  LocationTemporalData,
  ScheduleMetadata,
} from './rtt.ts';

const PICKS_UP = new Set<string>(['ADVERTISED_OPEN', 'ADVERTISED_PICK_UP']);
const CAN_BOARD = new Set<string>(['CALL', 'STARTS']);

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
  // Resolved to absolute instants rather than string-parsed: the API sends times
  // with no timezone, so Date.parse would order them by the server's local clock.
  departures.sort((a, b) => toInstantMillis(a.depInstant) - toInstantMillis(b.depInstant));
  return departures;
}

// ------------------------------------------------------------- describing

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
 * Where a train is going, as one line. Portion working: a service can carry two
 * destinations and divide en route, and boarding the wrong half is a real failure, so
 * both are kept.
 */
export function describeDestination(service: LocationLineUpObject): string {
  const names = destinationNames(service);
  return names.length ? names.join(' & ') : 'Unknown';
}

/** The platform it leaves from here: the live one when RTT has it, else the planned one. */
export function platformOf(service: LocationLineUpObject): string | null {
  return (
    service.locationMetadata?.platform?.actual ??
    service.locationMetadata?.platform?.planned ??
    null
  );
}

/** Whether a service runs by road: a replacement, scheduled or plain bus. */
export function isBusMode(modeType: ScheduleMetadata['modeType']): boolean {
  return modeType === 'REPLACEMENT_BUS' || modeType === 'SCHEDULED_BUS' || modeType === 'BUS';
}
