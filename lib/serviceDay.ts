/**
 * The rail service day, and London time.
 *
 * Two rules from the spec live here, and both are the kind that produce a wrong
 * answer rather than a crash:
 *
 *   1. The last train from London is usually after midnight, i.e. on the next
 *      calendar date. Query "today" naively and you drop the single most
 *      important result in the app.
 *   2. Always query a specific date. Sundays and engineering weekends are
 *      completely different timetables.
 *
 * The service day therefore runs 03:00 -> 02:59 the following morning. A train
 * leaving Fenchurch Street at 00:32 on Saturday morning belongs to Friday's
 * service day, which is what a person standing on the platform means by "the
 * last train tonight".
 *
 * 03:00 is a safe cut for these three operators: last arrivals are around
 * 01:30, first departures around 04:30. Nothing runs through the boundary.
 */

export const LONDON_TZ = 'Europe/London';
export const SERVICE_DAY_START_HOUR = 3;

/** An ISO calendar date, `YYYY-MM-DD`. Not a service day on its own. */
export type IsoDate = string;

const partsFormatter = new Intl.DateTimeFormat('en-GB', {
  timeZone: LONDON_TZ,
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  // h23 rather than hour12:false: some ICU builds render midnight as "24" with
  // the latter, which would put every post-midnight train on the wrong day.
  hourCycle: 'h23',
});

interface LondonParts {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
}

function londonParts(instant: Date): LondonParts {
  const out: Record<string, string> = {};
  for (const part of partsFormatter.formatToParts(instant)) {
    if (part.type !== 'literal') out[part.type] = part.value;
  }
  return {
    year: Number(out.year),
    month: Number(out.month),
    day: Number(out.day),
    hour: Number(out.hour),
    minute: Number(out.minute),
  };
}

const toIsoDate = (utcMillis: number): IsoDate =>
  new Date(utcMillis).toISOString().slice(0, 10);

/** Calendar arithmetic on a bare date, done in UTC so no DST can perturb it. */
export function addDays(date: IsoDate, days: number): IsoDate {
  const [y, m, d] = date.split('-').map(Number);
  return toIsoDate(Date.UTC(y, m - 1, d) + days * 86_400_000);
}

export function isValidIsoDate(value: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(value) && !Number.isNaN(Date.parse(`${value}T00:00:00Z`));
}

/**
 * The service day currently in progress in London.
 *
 * At 00:20 on Saturday this returns Friday, because the trains still running are
 * Friday's. This is the difference between the app being useful at 23:40 and
 * being actively misleading at 00:10.
 */
export function currentServiceDate(now: Date = new Date()): IsoDate {
  const p = londonParts(now);
  const midnight = Date.UTC(p.year, p.month - 1, p.day);
  return toIsoDate(p.hour < SERVICE_DAY_START_HOUR ? midnight - 86_400_000 : midnight);
}

export interface ServiceDayWindow {
  timeFrom: string;
  timeTo: string;
}

/**
 * The query window covering one whole service day.
 *
 * Deliberately offset-less. The API reads a datetime with no offset as local to
 * the station being queried, so this is correct through both BST and GMT without
 * us converting anything -- and correct across the spring-forward night, when
 * 01:00-02:00 does not exist in London.
 *
 * 03:00 -> 02:59 is 23h59m, exactly the documented maximum window.
 */
export function serviceDayWindow(date: IsoDate): ServiceDayWindow {
  const pad = (n: number) => String(n).padStart(2, '0');
  return {
    timeFrom: `${date}T${pad(SERVICE_DAY_START_HOUR)}:00:00`,
    timeTo: `${addDays(date, 1)}T${pad(SERVICE_DAY_START_HOUR - 1)}:59:00`,
  };
}

const timeFormatter = new Intl.DateTimeFormat('en-GB', {
  timeZone: LONDON_TZ,
  hour: '2-digit',
  minute: '2-digit',
  hourCycle: 'h23',
});

/** `23:52`, in London local time, from an RFC3339 instant. */
export function formatLondonTime(instant: string): string {
  return timeFormatter.format(new Date(instant));
}

/** The London calendar date an instant falls on -- used to flag arrivals after midnight. */
export function londonDateOf(instant: string): IsoDate {
  const p = londonParts(new Date(instant));
  return `${p.year}-${String(p.month).padStart(2, '0')}-${String(p.day).padStart(2, '0')}`;
}

/**
 * Minutes between two RFC3339 instants.
 *
 * Both are absolute, so this is right across midnight and across a DST change
 * without special-casing either.
 */
export function minutesBetween(fromInstant: string, toInstant: string): number {
  return Math.round((Date.parse(toInstant) - Date.parse(fromInstant)) / 60_000);
}

const weekdayFormatter = new Intl.DateTimeFormat('en-GB', {
  timeZone: 'UTC',
  weekday: 'short',
  day: 'numeric',
  month: 'short',
});

/** `Thu 30 Jul`, for showing which service day is on screen. */
export function formatServiceDate(date: IsoDate): string {
  return weekdayFormatter.format(new Date(`${date}T12:00:00Z`));
}
