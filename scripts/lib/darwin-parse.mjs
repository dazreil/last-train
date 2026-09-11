/**
 * Darwin timetable ingest, stage 1: the real parser.
 *
 * `DARWIN-INGEST.md` §3 stage 1. Stage 0's probe counted bytes; this reads
 * structure. It takes the two delivered files and produces normalised journeys:
 * passenger services only, public calls only, every time resolved to a London
 * wall-clock instant and every call keyed by CRS.
 *
 * It writes nothing and knows nothing about storage. Stage 2 pivots what comes
 * out of here into per-station boards; stage 3 decides where those live.
 *
 * **Dates come from `lib/serviceDay.ts`, not from here.** The rail service day
 * runs 03:00–02:59 and the feed's times carry no timezone marker. That
 * combination has already caused one production bug, and the rule lives in one
 * module on purpose.
 */

import { createReadStream } from 'node:fs';
import { createGunzip } from 'node:zlib';
import { pipeline } from 'node:stream/promises';
import { Writable } from 'node:stream';

import { SaxesParser } from 'saxes';

import { addDays, currentServiceDate, toInstantMillis } from '../../lib/serviceDay.ts';

/**
 * Which services are a passenger's business, read from the CIF train status the
 * feed carries through.
 *
 * Measured on a real file: 56,935 journeys, of which 12,612 are flagged
 * `isPassengerSvc="false"` — empty stock moves, mostly — and 501 are ships.
 *
 * Buses are **kept and badged**, not dropped. The app already has
 * `isReplacementBus` and shows them, and a rail replacement bus is very often
 * the true answer to "what is the last way home". Dropping them here would
 * quietly make the app wrong on exactly the nights it matters.
 */
const STATUS_BUS = new Set(['B', '5']);
const STATUS_SHIP = new Set(['S', '4']);
const STATUS_FREIGHT = new Set(['F', '2', 'T', '3']);

/**
 * Whether a passenger may board, and whether they may get off.
 *
 * Not the same question, and the file answers them separately. `act` is a run of
 * two-character CIF activity codes, and four of them concern passengers:
 *
 *   `T ` take up and set down    `R ` stops on request
 *   `U ` take up only            `D ` set down only
 *
 * A **take-up-only** stop is one you can board but not leave. The Caledonian
 * Sleeper is full of them: heading south it picks up all the way down Scotland
 * and lets nobody off. Offering one as a Fast Train arrival sends someone to a
 * station the train will not put them down at. 1,052 calls in a weekday file are
 * like this, against one that cannot be boarded.
 *
 * A stop carrying both `U ` and `D ` is a normal stop by another route, and a
 * stop with a public time but no passenger code at all is treated as normal —
 * refusing it would be inventing a restriction the file never stated.
 */
function passengerUse(act) {
  const codes = new Set((act ?? '').match(/.{1,2}/g)?.map((c) => c.trim()) ?? []);
  const stated = codes.has('T') || codes.has('R') || codes.has('U') || codes.has('D');
  if (!stated) return { canBoard: true, canAlight: true };
  const both = codes.has('T') || codes.has('R') || (codes.has('U') && codes.has('D'));
  return {
    canBoard: both || codes.has('U'),
    canAlight: both || codes.has('D'),
  };
}

/** Stops a passenger can use. The operational variants carry no public time at all. */
const PUBLIC_STOPS = new Set(['OR', 'IP', 'DT']);

/** Feed a gzipped file through a SAX parser, one chunk at a time. */
async function streamXml(path, { onOpenTag, onCloseTag, onText }) {
  const parser = new SaxesParser({ fragment: false });
  let failure = null;
  parser.on('error', (e) => {
    failure ??= e;
  });
  if (onOpenTag) parser.on('opentag', onOpenTag);
  if (onCloseTag) parser.on('closetag', onCloseTag);
  if (onText) parser.on('text', onText);

  const sink = new Writable({
    write(chunk, _enc, done) {
      parser.write(chunk.toString('utf8'));
      done(failure);
    },
  });

  await pipeline(createReadStream(path), createGunzip(), sink);
  parser.close();
  if (failure) throw failure;
}

/**
 * The TIPLOC → CRS table, from the reference file.
 *
 * Nothing downstream works without this: the timetable speaks TIPLOC and every
 * station in this app is keyed by CRS. The mapping is many-to-one — several
 * TIPLOCs share a CRS — which is fine in this direction and is the reason the
 * reverse is never built here.
 *
 * A location with no `crs` is a junction, siding or depot. It is kept in the
 * table with a null CRS so a call can be recognised and dropped deliberately,
 * rather than looking like a lookup failure.
 */
export async function parseReference(path) {
  const locations = new Map();
  const operators = new Map();

  await streamXml(path, {
    onOpenTag(node) {
      if (node.name === 'LocationRef') {
        const { tpl, crs, locname, toc } = node.attributes;
        if (tpl) locations.set(tpl, { crs: crs ?? null, name: locname ?? tpl, toc: toc ?? null });
      } else if (node.name === 'TocRef') {
        const { toc, tocname } = node.attributes;
        if (toc) operators.set(toc, tocname ?? toc);
      }
    },
  });

  return { locations, operators };
}

/** `"07:39"` -> 459. Null for anything else. */
function minutesOfDay(hhmm) {
  if (!hhmm) return null;
  const m = /^(\d{2}):(\d{2})$/.exec(hhmm);
  if (!m) return null;
  return Number(m[1]) * 60 + Number(m[2]);
}

/**
 * Resolve a journey's wall-clock times to dated London instants.
 *
 * The times on one train only ever move forward, so a time that reads earlier
 * than the one before it has crossed midnight. This is the same rule
 * `lib/darwin.ts` applies to a live board, and it is the only way a 00:05 call
 * on a train that left at 23:50 lands on the right date.
 *
 * The sequence walked is arrival-then-departure at each call, so a train that
 * arrives at 23:59 and leaves at 00:01 rolls in the middle of one stop.
 */
function resolveTimes(calls, ssd) {
  let dayOffset = 0;
  let previous = null;

  const stamp = (hhmm) => {
    const minute = minutesOfDay(hhmm);
    if (minute === null) return null;
    if (previous !== null && minute < previous) dayOffset += 1;
    previous = minute;
    return `${addDays(ssd, dayOffset)}T${hhmm}:00`;
  };

  for (const call of calls) {
    call.arrivalInstant = stamp(call.pta);
    call.departureInstant = stamp(call.ptd);
  }
}

/**
 * Which service day a call belongs to.
 *
 * Not the same question as which calendar day, and not the same as the
 * journey's `ssd`. A train leaving at 01:00 on 6 September carries
 * `ssd="2026-09-06"`, but 01:00 falls before the 03:00 boundary, so a passenger
 * standing on the platform is still in the 5 September service day — which is
 * the day the app's board is asking about.
 */
function serviceDateOf(naiveLondonIso) {
  return currentServiceDate(new Date(toInstantMillis(naiveLondonIso)));
}

/**
 * Every passenger journey in the timetable file, normalised.
 *
 * `onJourney` is called once per surviving journey. Streaming rather than
 * collecting keeps a 63 MiB file from becoming a far larger object graph, and
 * lets the caller decide what to keep.
 *
 * Returns the tally of what was dropped and why. A silent filter is how an
 * ingest quietly loses a third of the network, so every exclusion is counted.
 */
export async function parseTimetable(path, { locations, onJourney }) {
  const stats = {
    journeysSeen: 0,
    kept: 0,
    droppedNotPassenger: 0,
    droppedShip: 0,
    droppedFreight: 0,
    droppedCancelled: 0,
    droppedTooFewCalls: 0,
    buses: 0,
    charters: 0,
    qtrains: 0,
    callsSeen: 0,
    callsKept: 0,
    callsNoPublicTime: 0,
    callsNoCrs: 0,
    callsCancelled: 0,
    callsAfterTerminus: 0,
    callsNoBoarding: 0,
    callsNoAlighting: 0,
    shortTerminations: 0,
    falseDestinations: 0,
    associations: 0,
    unknownTiplocs: new Set(),
    timetableId: null,
  };

  let journey = null;

  await streamXml(path, {
    onOpenTag(node) {
      const { name, attributes: a } = node;

      if (name === 'PportTimetable') {
        stats.timetableId = a.timetableID ?? a.timetableId ?? null;
        return;
      }
      if (name === 'Association') {
        stats.associations += 1;
        return;
      }
      if (name === 'Journey') {
        stats.journeysSeen += 1;
        journey = { attrs: a, calls: [], terminated: false };
        return;
      }
      if (!journey || !PUBLIC_STOPS.has(name)) return;

      stats.callsSeen += 1;
      const { tpl, pta, ptd, plat, act, can, fd } = a;
      if (!pta && !ptd) {
        stats.callsNoPublicTime += 1;
        return;
      }

      /**
       * A train that terminates early carries **two** destinations.
       *
       * Found against a live board: a c2c service planned through to
       * Shoeburyness now terminates at Laindon for engineering work, so the
       * file holds `<DT tpl="LAINDON" act="TF" planAct="T ">` in the middle of
       * the journey, then the original stops to Shoeburyness, every one of them
       * `can="true"`, and a second `<DT>` at the end.
       *
       * Taking the last call as the destination reads that as a train to
       * Shoeburyness calling at Southend. It does not go there. On a last-train
       * board that is the worst answer the app could give: it strands someone at
       * Laindon at one in the morning.
       *
       * So the journey ends at its first `DT` that is not cancelled, and
       * cancelled calls are dropped outright. Either rule alone would fix this
       * example; both are kept because they catch different shapes — a skipped
       * stop mid-route is a cancelled call on a train that still runs to the
       * end, and needs the first rule but not the second.
       */
      if (journey.terminated) {
        stats.callsAfterTerminus += 1;
        return;
      }
      if (can === 'true') {
        stats.callsCancelled += 1;
        return;
      }

      const location = locations.get(tpl);
      if (!location) stats.unknownTiplocs.add(tpl);
      if (!location?.crs) {
        stats.callsNoCrs += 1;
        if (name === 'DT') journey.terminated = true;
        return;
      }
      if (fd) stats.falseDestinations += 1;
      if (name === 'DT') journey.terminated = true;

      const use = passengerUse(act);
      if (!use.canBoard) stats.callsNoBoarding += 1;
      if (!use.canAlight) stats.callsNoAlighting += 1;

      journey.calls.push({
        canBoard: use.canBoard,
        canAlight: use.canAlight,
        crs: location.crs,
        tiploc: tpl,
        name: location.name,
        pta: pta ?? null,
        ptd: ptd ?? null,
        platform: plat ?? null,
        activity: act?.trim() || null,
        // Present only when the activity here was changed. On a terminus it is
        // the mark of a train cut short of where it was planned to run.
        plannedActivity: a.planAct?.trim() || null,
        isCancelled: can === 'true',
        falseDestination: fd ?? null,
        kind: name,
      });
    },

    onCloseTag(node) {
      if (node.name !== 'Journey' || !journey) return;
      const { attrs, calls } = journey;
      journey = null;

      const status = attrs.status ?? 'P';
      if (attrs.isPassengerSvc === 'false') return void (stats.droppedNotPassenger += 1);
      if (STATUS_SHIP.has(status)) return void (stats.droppedShip += 1);
      if (STATUS_FREIGHT.has(status)) return void (stats.droppedFreight += 1);
      if (attrs.can === 'true') return void (stats.droppedCancelled += 1);

      // Two calls is the minimum that can answer "when does it leave and when
      // does it get there". One is a train the app could show but never use.
      if (calls.length < 2) return void (stats.droppedTooFewCalls += 1);

      // A train whose advertised terminus is not where it was planned to end.
      if (calls.at(-1).plannedActivity) stats.shortTerminations += 1;

      resolveTimes(calls, attrs.ssd);
      stats.callsKept += calls.length;
      stats.kept += 1;

      const isBus = STATUS_BUS.has(status);
      if (isBus) stats.buses += 1;
      if (attrs.isCharter === 'true') stats.charters += 1;
      if (attrs.qtrain === 'true') stats.qtrains += 1;

      onJourney({
        rid: attrs.rid,
        uid: attrs.uid,
        trainId: attrs.trainId ?? null,
        ssd: attrs.ssd,
        toc: attrs.toc ?? null,
        trainCat: attrs.trainCat ?? null,
        isBus,
        // A train that only runs when required. Shown, but the app should never
        // call one the last train home without saying so.
        isConditional: attrs.qtrain === 'true',
        isCharter: attrs.isCharter === 'true',
        originName: calls[0].name,
        destinationName: calls.at(-1).name,
        // The service day the train departs in, which is what a board asks for.
        serviceDate: serviceDateOf(calls[0].departureInstant ?? calls[0].arrivalInstant),
        calls,
      });
    },
  });

  return stats;
}

export const _internals = { minutesOfDay, resolveTimes, serviceDateOf, passengerUse, STATUS_BUS, STATUS_SHIP };
