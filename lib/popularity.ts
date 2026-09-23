/**
 * Where people actually go from each station, from the ORR Origin-Destination Matrix.
 *
 * The picker orders destinations by journey time, which is route order, and leaves the
 * place most people are going wherever the route puts it. This is the correction: each
 * station's busiest destinations, busiest first, so the picker can put the likely answer
 * at the top. Generated yearly by `scripts/generate-popularity.mjs`.
 *
 * Server-only, like the adjacency table. The app receives answers, not tables.
 */
import 'server-only';
import popularityData from '../data/popularity.json';

interface PopularityFile {
  financialYear: string;
  source: string;
  attribution: string;
  /** CRS -> busiest destinations, busiest first, space-separated. */
  stations: Record<string, string>;
}

const data = popularityData as PopularityFile;

/** Named in the picker, both as the reason for the order and as the licence's attribution. */
export const popularitySource = data.source;
export const popularityAttribution = data.attribution;

/** The busiest destinations from `crs`, busiest first. Empty when the matrix has none. */
export function busiestFrom(crs: string): string[] {
  return data.stations[crs.toUpperCase()]?.split(' ') ?? [];
}
