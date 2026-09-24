import { NextResponse } from 'next/server';

import { STALE_AFTER_SECONDS, timetableBoard, timetableStatus } from '@/lib/timetable';
import { coverageProblems } from '@/lib/timetablePacking';
import { addDays, currentServiceDate } from '@/lib/serviceDay';

/**
 * GET /api/timetable-health -> what the ingested timetable holds, and how old it is.
 *
 * `DARWIN-INGEST.md` §3 stage 7. A sibling of `/api/cache-health` rather than part of it,
 * because the two answer different questions: that one asks whether the cache works, and a
 * cache that is empty is merely cold. This asks whether the **store** is current, and a
 * store that is empty is broken.
 *
 * **It checks what the app needs, not whether the last job succeeded:** the snapshot's age,
 * that today and tomorrow are whole, and that a real board reads back.
 *
 * **Age, not job success.** The likeliest way this ingest
 * dies is silent: a new version of the data product unlinks the delivery destination and
 * the files simply stop arriving. A job that exits zero having found nothing new looks
 * exactly like a healthy one. Age does not.
 *
 * Reveals no credentials — only what is in the store and when Darwin made it — so it is
 * safe to leave in place as an operational check.
 */

export const runtime = 'nodejs';

/**
 * The board read back as proof the store serves boards, not only a description of them.
 * Clapham Junction: the busiest station there is, so it has a board on every day covered.
 */
const PROBE_CRS = 'CLJ';

/**
 * A reply, with **503 when unhealthy** (`SERVER-AUDIT.md` finding 8). A 200 for every answer
 * made a monitor read the body to find out whether anything was wrong; the status now says
 * so on its own, and the body still says why.
 */
function reply(body: Record<string, unknown> & { healthy: boolean }) {
  return NextResponse.json(body, {
    status: body.healthy ? 200 : 503,
    headers: { 'cache-control': 'no-store' },
  });
}

export async function GET() {
  const status = await timetableStatus();

  if (!status.configured) {
    return reply({ configured: false, healthy: false, reason: 'No shared store is configured.' });
  }

  if (!status.meta) {
    return reply({
      configured: true,
      healthy: false,
      reason: status.error
        ? 'The store could not be read just now.'
        : 'The store is reachable but holds no timetable. Has the ingest ever run?',
    });
  }

  const { meta, ageSeconds, stale } = status;

  // Today must be whole. Tomorrow too — once today's file is in: Darwin makes each day's
  // file at about 02:05 and it reaches the store some hours later, and until then
  // yesterday's file is the newest there is and cannot yet cover tomorrow. Asking it to
  // would report unhealthy every morning; the age check catches a file that never comes.
  const today = currentServiceDate();
  const needed = meta.generatedAt.slice(0, 10) >= today ? [today, addDays(today, 1)] : [today];
  const problems = coverageProblems(meta, needed);

  // Read one real board. A description of boards is not proof they can be read.
  const probe = await timetableBoard(PROBE_CRS, today);
  if (probe.status !== 'ok' && probe.status !== 'stale') {
    problems.push(`The ${PROBE_CRS} board for ${today} could not be read (${probe.status}).`);
  } else if (probe.services.length === 0) {
    problems.push(`The ${PROBE_CRS} board for ${today} is empty.`);
  }
  if (stale) problems.push(`The snapshot is ${Math.round(ageSeconds / 3600)} hours old.`);

  return reply({
    configured: true,
    healthy: problems.length === 0,
    problems,
    // Darwin's own id for the file, so a snapshot stuck on one publish is identifiable
    // at a glance rather than by arithmetic on the age.
    timetableId: meta.timetableId,
    generatedAt: meta.generatedAt,
    publishedAt: meta.publishedAt,
    ageHours: Number((ageSeconds / 3600).toFixed(1)),
    staleAfterHours: STALE_AFTER_SECONDS / 3600,
    stale,
    serviceDates: meta.serviceDates,
    boardCount: meta.boardCount,
    departureCount: meta.departureCount,
    departuresByDate: meta.departuresByDate ?? null,
    keyed: meta.keyed ?? null,
    operatorCount: Object.keys(meta.operators ?? {}).length,
  });
}
