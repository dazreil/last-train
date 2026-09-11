import { NextResponse } from 'next/server';

import { STALE_AFTER_SECONDS, timetableStatus } from '@/lib/timetable';

/**
 * GET /api/timetable-health -> what the ingested timetable holds, and how old it is.
 *
 * `DARWIN-INGEST.md` §3 stage 7. A sibling of `/api/cache-health` rather than part of it,
 * because the two answer different questions: that one asks whether the cache works, and a
 * cache that is empty is merely cold. This asks whether the **store** is current, and a
 * store that is empty is broken.
 *
 * **It reports age, not whether the last job succeeded.** The likeliest way this ingest
 * dies is silent: a new version of the data product unlinks the delivery destination and
 * the files simply stop arriving. A job that exits zero having found nothing new looks
 * exactly like a healthy one. Age does not.
 *
 * Reveals no credentials — only what is in the store and when Darwin made it — so it is
 * safe to leave in place as an operational check.
 */

export const runtime = 'nodejs';

export async function GET() {
  const status = await timetableStatus();

  if (!status.configured) {
    return NextResponse.json(
      { configured: false, healthy: false, reason: 'No shared store is configured.' },
      { headers: { 'cache-control': 'no-store' } }
    );
  }

  if (!status.meta) {
    return NextResponse.json(
      {
        configured: true,
        healthy: false,
        reason: 'The store is reachable but holds no timetable. Has the ingest ever run?',
      },
      { headers: { 'cache-control': 'no-store' } }
    );
  }

  const { meta, ageSeconds, stale } = status;
  return NextResponse.json(
    {
      configured: true,
      healthy: !stale,
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
      operatorCount: Object.keys(meta.operators ?? {}).length,
    },
    { headers: { 'cache-control': 'no-store' } }
  );
}
