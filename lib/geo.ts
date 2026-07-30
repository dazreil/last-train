/**
 * Server-side reference data: longitudes, and which destinations lie along a corridor.
 *
 * The longitude table covers every GB rail station, not just the ones in scope,
 * because the Greater Anglia trains through Shenfield carry on to Norwich, Ipswich,
 * Colchester and Clacton -- all legitimate eastbound destinations that are
 * deliberately absent from the app's own station list.
 *
 * Server-side only, and in its own file rather than in `stations.json`, because that
 * file is imported by the station picker and therefore ships to the browser. A few
 * thousand longitudes are a pointless download on a platform with one bar of signal.
 */

import 'server-only';
import geoData from '../data/geo.json';
import type { LongitudeLookup } from './direction.ts';

interface GeoTable {
  /** Destination names reached by trains that call somewhere in scope. */
  corridorDestinations?: string[];
  /** TIPLOC -> longitude, rounded to ~100m. */
  byTiploc: Record<string, number>;
  /** CRS -> longitude. */
  byCrs: Record<string, number>;
}

const geo = geoData as GeoTable;

/** Longitude of a location, by whichever code is present. */
export const longitudeOf: LongitudeLookup = (location) => {
  if (!location) return null;

  for (const tiploc of location.longCodes ?? []) {
    const lon = geo.byTiploc[tiploc.trim().toUpperCase()];
    if (typeof lon === 'number') return lon;
  }
  for (const crs of location.shortCodes ?? []) {
    const lon = geo.byCrs[crs.trim().toUpperCase()];
    if (typeof lon === 'number') return lon;
  }
  return null;
};

/** True once `npm run stations` has generated the table. */
export const isGeoTableReady = (): boolean => Object.keys(geo.byCrs).length > 0;

const canonicalName = (value: string): string => value.toLowerCase().replace(/[^a-z0-9]/g, '');

const corridorDestinations = new Set(
  (geo.corridorDestinations ?? []).map(canonicalName)
);

/**
 * Is a train bound here demonstrably running along one of the app's corridors?
 *
 * Collected at generation time from line-ups already filtered to a waypoint in scope,
 * so membership is evidence rather than assumption. It covers the Greater Anglia
 * destinations that sit outside the station list but are reached by trains calling at
 * Shenfield -- Colchester, Ipswich, Clacton, Southend Victoria, Braintree, Witham --
 * while excluding Stansted, Cambridge and the rest of West Anglia.
 *
 * The point is to answer "is this in scope?" without spending an API request. At ten
 * requests a minute, reading calling patterns at runtime is a budget the app does not
 * have, and without this the exclusion quietly stopped happening under load.
 *
 * Only meaningful in a direction where the corridor actually continues; see the
 * `onward` check in the route handler.
 */
export const isCorridorDestination = (name: string): boolean =>
  corridorDestinations.has(canonicalName(name));
