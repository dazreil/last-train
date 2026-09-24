/**
 * GET /api/cache-health -> { configured, reachable, roundTripMs }
 *
 * A read of whether the shared cache (Vercel KV / Upstash) is wired up and answering. Does a
 * real write-then-read round trip through Redis. Reveals no credentials — only whether it
 * works — so it is safe to leave in place as an operational check.
 */

import { NextResponse } from 'next/server';

import { sharedCacheHealth } from '@/lib/cache';

export const runtime = 'nodejs';

export async function GET() {
  const health = await sharedCacheHealth();
  // 503 when it is not working, so the status alone answers a monitor.
  return NextResponse.json(health, {
    status: health.configured && health.reachable ? 200 : 503,
    headers: { 'cache-control': 'no-store' },
  });
}
