/**
 * Live times laid over the Last Train board.
 *
 * The board comes from the timetable, cached for up to an hour, so on its own it cannot
 * say a train is late. Darwin's plain departure board can, for the next two hours — the
 * window that matters at 23:40. This matches the two and copies the live word across:
 * an expected time, "Delayed", or "Cancelled".
 *
 * Pure, so the matching can be tested. The route fetches the live board and calls this
 * on every response, cached or not, so a delay shows within a minute however old the
 * board underneath is.
 */

import type { NationalService } from './nationalContract.ts';
import type { LiveDeparture } from './darwin.ts';

/** How far ahead the live board reaches, less a margin. */
export const LIVE_HORIZON_MS = 125 * 60 * 1000;
/** A train just gone is still worth matching: it may be running a few minutes late. */
const LIVE_PAST_MS = 30 * 60 * 1000;

const minutesOf = (hhmm: string): number | null => {
  const match = /^(\d{2}):(\d{2})$/.exec(hhmm.trim());
  return match ? Number(match[1]) * 60 + Number(match[2]) : null;
};

const sameName = (a: string, b: string): boolean => {
  const x = a.toLowerCase();
  const y = b.toLowerCase();
  return x.includes(y) || y.includes(x);
};

/** Whether any departure on the board is inside the live window. */
export function needsLive(services: NationalService[], nowMs: number): boolean {
  return services.some((service) => {
    const delta = Date.parse(service.depInstant) - nowMs;
    return delta >= -LIVE_PAST_MS && delta <= LIVE_HORIZON_MS;
  });
}

/**
 * The board with live fields filled in where a train can be matched.
 *
 * Matched on the scheduled minute, then on the destination when two trains share a
 * minute. A departure that cannot be matched with confidence is left exactly as the
 * timetable had it: saying nothing is better than attaching another train's delay.
 */
export function applyLive(
  services: NationalService[],
  live: LiveDeparture[],
  nowMs: number
): NationalService[] {
  return services.map((service) => {
    const delta = Date.parse(service.depInstant) - nowMs;
    if (delta < -LIVE_PAST_MS || delta > LIVE_HORIZON_MS) return service;

    let matches = live.filter((row) => row.std === service.dep);
    if (matches.length > 1) {
      matches = matches.filter((row) => sameName(row.destinationName, service.destination));
    }
    if (matches.length !== 1) return service;
    const row = matches[0];
    // Matched, so whatever follows is the live board's word — including "on time".
    const checked = { ...service, isLive: true };

    if (row.isCancelled) return { ...checked, isCancelled: true };
    const etd = row.etd?.trim() ?? '';
    if (etd === 'Delayed') return { ...checked, isDelayed: true };

    const expected = minutesOf(etd);
    const scheduled = minutesOf(service.dep);
    if (expected === null || scheduled === null || expected === scheduled) return checked;

    // The shortest way round the clock: 00:05 against 23:55 is ten late, not a day early.
    const shift = ((expected - scheduled + 1440 + 720) % 1440) - 720;
    const instant = new Date(Date.parse(service.depInstant) + shift * 60_000).toISOString();
    return { ...checked, expectedDep: etd, expectedDepInstant: instant };
  });
}
