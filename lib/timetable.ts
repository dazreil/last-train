import 'server-only';

import { sharedRedis } from './cache.ts';
import { findStationByCrs } from './nationalStations.ts';
import {
  ageSecondsOf,
  boardKey,
  META_KEY,
  toNormalizedService,
  unpackBoard,
  type TimetableMeta,
} from './timetablePacking.ts';
import type { NormalizedService } from './darwin.ts';

/**
 * Reading the ingested Darwin timetable.
 *
 * `DARWIN-INGEST.md` §3 stage 3. This module **reads**. It never fetches from
 * S3, never parses XML and never writes: the daily job writes, the app reads,
 * and keeping that one-way is what stops a request path acquiring credentials
 * that can rewrite every board the app serves.
 *
 * It returns `NormalizedService[]` — the same type `lib/darwin.ts` produces from
 * a live board — so a route can be handed a timetable board without learning a
 * second vocabulary. That is the whole point of the shape chosen in stage 2.
 *
 * **What it does not do is pretend.** A board that is missing, or a store that
 * was never configured, comes back said out loud rather than as an empty array.
 * The fault this ingest exists to remove was a silent one: a refused request
 * left Fast Train short with no message. Returning `[]` for "I do not know"
 * would rebuild that fault behind a new door.
 */

/**
 * When a snapshot stops being trustworthy.
 *
 * Darwin publishes once a day, at about 02:05. Thirty hours therefore means at
 * least one publish was missed, or the delivery stopped — which is the likeliest
 * way this ingest dies, because a new version of the data product silently
 * unlinks the destination and nothing errors. Age is the signal that catches it;
 * a job exiting zero having found nothing new looks exactly like a healthy one.
 */
export const STALE_AFTER_SECONDS = 30 * 60 * 60;

export type TimetableResult =
  /** A board, with how old the snapshot behind it is. */
  | { status: 'ok'; services: NormalizedService[]; meta: TimetableMeta; ageSeconds: number }
  /** The snapshot is readable but older than `STALE_AFTER_SECONDS`. */
  | { status: 'stale'; services: NormalizedService[]; meta: TimetableMeta; ageSeconds: number }
  /** No shared store is configured. Local development, or a deployment without one. */
  | { status: 'unconfigured' }
  /** The store answered, but holds no board for that station and day. */
  | { status: 'missing'; meta: TimetableMeta | null }
  /** The store failed. Distinct from empty, because the caller must not cache it. */
  | { status: 'error'; message: string };

/** True once per build, so a broken store is logged once rather than per request. */
let warned = false;
function note(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  if (!warned) {
    warned = true;
    console.warn(`Timetable store unavailable. ${message}`);
  }
  return message;
}

async function readMeta(): Promise<TimetableMeta | null> {
  const redis = sharedRedis();
  if (!redis) return null;
  return (await redis.get<TimetableMeta>(META_KEY)) ?? null;
}

/** A stop's name as the app knows it, falling back to the code for one it does not. */
const nameOf = (crs: string): string => findStationByCrs(crs)?.name ?? crs;

/**
 * Every departure from `crs` on `serviceDate`, in departure order.
 *
 * One read. The board already carries each train's onward calls, which is the
 * trade stage 2 measured and took: three times the bytes to avoid a request per
 * train.
 */
export async function timetableBoard(
  crs: string,
  serviceDate: string,
  now: Date = new Date()
): Promise<TimetableResult> {
  const redis = sharedRedis();
  if (!redis) return { status: 'unconfigured' };

  try {
    const [packed, meta] = await Promise.all([
      redis.get<string>(boardKey(crs, serviceDate)),
      readMeta(),
    ]);

    if (!packed || !meta) return { status: 'missing', meta };

    const services = unpackBoard(packed).map((departure) =>
      toNormalizedService(departure, crs.toUpperCase(), serviceDate, meta.operators ?? {}, nameOf)
    );
    const ageSeconds = ageSecondsOf(meta, now);
    const status = ageSeconds > STALE_AFTER_SECONDS ? 'stale' : 'ok';
    return { status, services, meta, ageSeconds };
  } catch (error) {
    return { status: 'error', message: note(error) };
  }
}

/**
 * What the store holds, without reading a board.
 *
 * For the health check stage 7 leans on. It reports the snapshot's age rather
 * than whether the last job succeeded, for the reason given on
 * `STALE_AFTER_SECONDS`.
 */
export async function timetableStatus(now: Date = new Date()): Promise<
  | { configured: false }
  | { configured: true; meta: null }
  | { configured: true; meta: TimetableMeta; ageSeconds: number; stale: boolean }
> {
  if (!sharedRedis()) return { configured: false };
  try {
    const meta = await readMeta();
    if (!meta) return { configured: true, meta: null };
    const ageSeconds = ageSecondsOf(meta, now);
    return { configured: true, meta, ageSeconds, stale: ageSeconds > STALE_AFTER_SECONDS };
  } catch (error) {
    note(error);
    return { configured: true, meta: null };
  }
}
