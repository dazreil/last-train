/**
 * Darwin timetable ingest, stage 2: the query shape.
 *
 * `DARWIN-INGEST.md` §3 stage 2. Stage 1 produced journeys; the app never asks
 * for a journey. It asks two questions and only two:
 *
 *   - Fast Train: every direct train from A to B on a date, with an arrival.
 *   - Last Train: every departure from a station, for a whole service day.
 *
 * Both are one **per-station day board**: for each CRS and service date, the
 * departures from that station, each carrying its own onward calls. Deliberately
 * the shape `GetDepBoardWithDetails` already returns, so `lib/timetable.ts` can
 * hand the routes something they cannot tell apart from Darwin's own answer.
 *
 * The cost of that shape is duplication: a train's onward calls are repeated at
 * every station it calls at, so a journey of k calls contributes k(k−1)/2 rows
 * rather than k. Measured on a weekday file that is 4.33 million rows. This
 * module exists to find out what those rows actually weigh, in bytes, before
 * anything is written to a store.
 */

import { packBoard } from '../../lib/timetablePacking.ts';

/** Calendar days between two ISO dates. Pure date arithmetic, so DST cannot reach it. */
function daysBetween(from, to) {
  const ms = Date.UTC(...to.split('-').map(Number).map((n, i) => (i === 1 ? n - 1 : n)))
    - Date.UTC(...from.split('-').map(Number).map((n, i) => (i === 1 ? n - 1 : n)));
  return Math.round(ms / 86_400_000);
}

/**
 * Minutes from midnight opening the service date.
 *
 * Times past midnight keep counting up — 00:33 on the day after a 2026-09-09
 * board is 1473, not 33 — so a board sorts and compares as plain numbers with no
 * date handling at the point of use. Wall-clock arithmetic throughout, which is
 * why an hour lost or gained to daylight saving cannot shift a printed time.
 */
export function minutesFrom(serviceDate, naiveInstant) {
  if (!naiveInstant) return null;
  const [date, time] = naiveInstant.split('T');
  return daysBetween(serviceDate, date) * 1440 + Number(time.slice(0, 2)) * 60 + Number(time.slice(3, 5));
}

/**
 * Pivot journeys into boards.
 *
 * `onJourney`-shaped input, one board per `crs|serviceDate`. The final call of a
 * journey is an arrival and never becomes a departure, which is the difference
 * between a board and a list of calls.
 */
export function buildBoards() {
  const boards = new Map();

  function add(journey) {
    for (let i = 0; i < journey.calls.length - 1; i += 1) {
      const call = journey.calls[i];
      if (!call.ptd) continue;
      // A set-down-only stop is not a departure. The train leaves, but nobody
      // may get on it here, so it must not appear on this station's board.
      if (!call.canBoard) continue;

      const key = `${call.crs}|${journey.serviceDate}`;
      let board = boards.get(key);
      if (!board) {
        board = { crs: call.crs, serviceDate: journey.serviceDate, departures: [] };
        boards.set(key, board);
      }

      board.departures.push({
        rid: journey.rid,
        toc: journey.toc,
        origin: journey.calls[0].crs,
        dep: minutesFrom(journey.serviceDate, call.departureInstant),
        platform: call.platform,
        isBus: journey.isBus,
        isConditional: journey.isConditional,
        destination: journey.destinationName,
        // Every later call is kept, including ones a passenger may not get off
        // at, because the detail sheet still lists them as calling points. The
        // flag is what stops Fast Train treating one as a reachable arrival.
        onward: journey.calls.slice(i + 1).map((c) => ({
          crs: c.crs,
          arr: minutesFrom(journey.serviceDate, c.arrivalInstant ?? c.departureInstant),
          canAlight: c.canAlight !== false,
        })),
      });
    }
  }

  function finish() {
    for (const board of boards.values()) board.departures.sort((a, b) => a.dep - b.dep);
    return boards;
  }

  return { add, finish };
}

/* ------------------------------------------------------------- encodings */

/** What stage 1 writes: every field named in full. The baseline, not a candidate. */
export const encodeVerbose = (board) => JSON.stringify(board);

/**
 * The same board with short keys and nothing the app does not read.
 *
 * Honest JSON, just not chatty. Kept as the middle option because it stays
 * inspectable: a board can be read in a terminal without a decoder.
 */
export function encodeCompactJson(board) {
  return JSON.stringify(
    board.departures.map((d) => {
      const row = [d.dep, d.rid, d.toc, d.destination, d.onward.map((o) => [o.crs, o.arr])];
      const flags = (d.isBus ? 1 : 0) | (d.isConditional ? 2 : 0);
      if (d.platform || flags) row.push(d.platform ?? '', flags);
      return row;
    })
  );
}

/**
 * The packed encoding lives in `lib/timetablePacking.ts`, not here.
 *
 * The ingest writes it and the app reads it, so a second copy of the format is
 * a second chance for the two to disagree — and a disagreement would not fail,
 * it would serve a board with the wrong times on it. Re-exported so this module
 * stays the one place stage 2 is assembled, while `npm test` owns the format.
 */
export { packBoard, unpackBoard } from '../../lib/timetablePacking.ts';

/**
 * The fallback shape §3 names: one record per journey, plus a light index.
 *
 * No duplication, so it stores the 598k calls once instead of 4.33M times. The
 * cost moves from bytes to round trips — answering Fast Train means reading the
 * index and then fetching each candidate journey — which is why it is the
 * fallback and not the plan.
 */
export function encodeJourneyShape(journeys) {
  const records = journeys.map((j) =>
    [
      j.rid,
      j.toc,
      (j.isBus ? 1 : 0) | (j.isConditional ? 2 : 0),
      j.calls.map((c) => `${c.crs}${String(minutesFrom(j.serviceDate, c.arrivalInstant ?? c.departureInstant)).padStart(4, '0')}${String(minutesFrom(j.serviceDate, c.departureInstant ?? c.arrivalInstant)).padStart(4, '0')}`).join(''),
    ].join('\t')
  );

  const index = new Map();
  for (const j of journeys) {
    for (let i = 0; i < j.calls.length - 1; i += 1) {
      const c = j.calls[i];
      if (!c.ptd) continue;
      const key = `${c.crs}|${j.serviceDate}`;
      if (!index.has(key)) index.set(key, []);
      index.get(key).push(`${String(minutesFrom(j.serviceDate, c.departureInstant)).padStart(4, '0')}${j.rid}`);
    }
  }

  return { records, index };
}
