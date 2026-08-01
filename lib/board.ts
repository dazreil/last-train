/**
 * Which shape the board takes, decided by the clock.
 *
 * The app answers "what is the last train home, and if I miss it, what is the
 * first one back". Those are two different questions at two different times of
 * night, and showing them in a fixed arrangement gets one of them wrong:
 *
 *   - At 22:00 the last trains are the answer, and the first train that is any use
 *     is tomorrow morning's. Today's first train left before breakfast; printing it
 *     under "first train" is filling space with a departure that has already gone.
 *   - Between the last train of a service day and the first of the next, there is
 *     no last train left to catch. What you need is the next few departures, with
 *     the day's last one still visible because that is the thing this app is for.
 *
 * So there are two arrangements, and one rule chooses between them: has the first
 * train of the service day on the board departed yet?
 *
 *   normal        last three of the day, then the first train of the next day
 *   pre-service   first three of the day, then that same day's last train
 *
 * Both are in departure order top to bottom, and in both the red block is the last
 * train of the service day on the board. Red never means anything else.
 *
 * The rule reads times through `toInstantMillis`, so it is correct for the API's
 * timezone-less London wall-clock strings as well as for the true UTC instants the
 * client holds. Comparing either against a raw `Date.parse` would reintroduce the
 * production bug that `serviceDay.ts` exists to prevent.
 */

import { toInstantMillis } from './serviceDay.ts';

/** The two arrangements. See the module comment for which is which. */
export type BoardMode = 'normal' | 'pre-service';

/** Which part of the answer a service is: a first train, or a last one. */
export type ServiceRole = 'first' | 'last';

/** Which service day a block is drawn from, relative to the one on the board. */
export type BoardDay = 'current' | 'next';

/** The minimum a service has to look like for the rules below to read it. */
interface TimedService {
  role: string;
  depInstant: string;
}

export interface BoardModeOptions {
  /**
   * Whether the day on the board is the one currently in progress. A past or
   * future service day is never pre-service: nothing on it has "not started yet"
   * relative to a clock it does not contain.
   */
  isLiveServiceDay: boolean;
  /** The day's first boardable departure, or null if it has none. */
  firstDeparture: string | null;
  now?: Date;
}

/**
 * Pre-service when the service day on the board has not started running.
 *
 * That window opens at 03:00, when the service day rolls over, and closes at the
 * day's first departure -- which is a real time read from the timetable, not a
 * guessed hour. It differs by station and by day: a Sunday first train is well
 * after a Monday one, and a rural branch later than either.
 *
 * Within one service day this can only ever go pre-service -> normal, never back,
 * because the first departure does not move and the clock only advances. That
 * one-way property is what makes a cached answer safe to keep -- see
 * `boardHasExpired`.
 */
export function boardMode(options: BoardModeOptions): BoardMode {
  const { isLiveServiceDay, firstDeparture, now = new Date() } = options;
  if (!isLiveServiceDay || !firstDeparture) return 'normal';
  return now.getTime() < toInstantMillis(firstDeparture) ? 'pre-service' : 'normal';
}

/**
 * True once every train of the service day on the board has gone.
 *
 * Only reachable between the last departure and 03:00 -- at 00:40 on Sunday
 * morning, Saturday's service day is still the current one but has nothing left in
 * it. A board of departures that have all been and gone answers nothing, so the
 * useful day is the next one, and the caller moves to it.
 */
export function isServiceDaySpent(lastDeparture: string | null, now: Date = new Date()): boolean {
  if (!lastDeparture) return false;
  return now.getTime() > toInstantMillis(lastDeparture);
}

export interface BoardSelection<T> {
  item: T;
  role: ServiceRole;
}

/**
 * Which departures the board is made of.
 *
 * Kept apart from the fetching so the arrangement can be tested without an API: the
 * caller passes a `take`, which yields the first or last few qualifying departures of
 * a service day, and this decides what to ask it for. The result comes back in
 * departure order, which is also the order it is shown in.
 *
 * The one thing to preserve if this is ever edited: **pre-service must never ask for
 * the next day.** Each day costs a station line-up, and the free tier allows ten
 * requests a minute. A pre-service board is answered entirely out of the day it is
 * already holding, and there is a test that says so.
 */
export async function selectBoard<T extends { id: string }>(
  mode: BoardMode,
  take: (day: BoardDay, fromEnd: boolean, wanted: number) => Promise<T[]>
): Promise<BoardSelection<T>[]> {
  if (mode === 'pre-service') {
    const lastTrain = await take('current', true, 1);
    const firstThree = (await take('current', false, 3)).filter(
      // On a quiet enough day the last train is also one of the first three. It
      // belongs to the last-train block, which is where the red goes -- listing it
      // twice would be the same train contradicting itself.
      (item) => !lastTrain.some((entry) => entry.id === item.id)
    );

    return [
      ...firstThree.map((item) => ({ item, role: 'first' as const })),
      ...lastTrain.map((item) => ({ item, role: 'last' as const })),
    ];
  }

  const lastThree = await take('current', true, 3);

  // Skipped when nothing runs this way today. An empty board is answered by saying
  // so, not by offering tomorrow morning instead -- and it saves a line-up at every
  // station where the direction is a dead end.
  const firstBack = lastThree.length ? await take('next', false, 1) : [];

  return [
    ...lastThree.map((item) => ({ item, role: 'last' as const })),
    ...firstBack.map((item) => ({ item, role: 'first' as const })),
  ];
}

/**
 * Whether a stored answer has outlived the arrangement it was built for.
 *
 * Answers are cached by station, direction and date, deliberately without the mode
 * in the key: the mode is only known after the line-up has been read, and keying on
 * it would mean a cache miss forcing a fresh API call at exactly the moment the
 * line-up cache has aged out.
 *
 * Instead the boundary is checked on read. A pre-service answer holds the day's
 * first departures, so it carries the very time that decides its own validity;
 * once that train has gone the answer is the wrong shape and is rebuilt. A normal
 * answer cannot go stale this way, because the transition only runs one direction
 * within a service day.
 */
export function boardHasExpired(
  board: { mode: BoardMode; services: readonly TimedService[] },
  now: Date = new Date()
): boolean {
  if (board.mode !== 'pre-service') return false;
  const firstOut = board.services.find((service) => service.role === 'first');
  return firstOut ? toInstantMillis(firstOut.depInstant) <= now.getTime() : false;
}
