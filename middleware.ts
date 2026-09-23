import { NextResponse, type NextRequest } from 'next/server';

import { sharedRedis } from './lib/cache.ts';
import { CALLER_WINDOWS, callerAddress, count } from './lib/limits.ts';
import { CANONICAL_HOST, isLiveHost } from './lib/liveHost.ts';

/**
 * Only the live deployment answers as the API.
 *
 * See `lib/liveHost.ts` for why: every Vercel deployment keeps a permanent URL, those
 * URLs keep serving their own build, and the Hobby plan has no way to protect them
 * without also protecting the one the app talks to.
 *
 * **Scoped to `/api`, deliberately.** A stale *page* on an old URL is a curiosity; a
 * stale *board* is an answer someone might act on, and it spends the same RTT quota as
 * the real one while doing it. Leaving the pages reachable also keeps preview
 * deployments useful for looking at the web app, which is what they are for.
 *
 * `410 Gone` rather than `404`: the endpoint existed here and deliberately no longer
 * answers, which is exactly what the status is for. The body is the same `{ error }`
 * shape every other failure uses, so `BoardClient` surfaces it as a sentence rather
 * than as a status code.
 */
export async function middleware(request: NextRequest) {
  if (isLiveHost(request.headers.get('host'))) return limitCaller(request);

  return NextResponse.json(
    {
      error:
        `This is an old deployment and no longer answers. The live board is at ` +
        `https://${CANONICAL_HOST}.`,
    },
    {
      status: 410,
      // Nothing about this is worth remembering: the answer depends only on which URL
      // was asked, and a cached copy would outlive a change to the rule.
      headers: { 'cache-control': 'no-store' },
    }
  );
}

/**
 * A fixed number of requests a minute and an hour from one address. See `lib/limits.ts`
 * for the numbers and for why this is one of two lines rather than the only one.
 *
 * Checked here rather than in each route so no route can be added without it. Fails open:
 * with Redis absent or unwell, everything passes.
 */
async function limitCaller(request: NextRequest) {
  const address = callerAddress(request.headers);
  if (!address) return NextResponse.next();

  const verdict = await count(sharedRedis(), `caller:${address}`, CALLER_WINDOWS);
  if (verdict.allowed) return NextResponse.next();

  return NextResponse.json(
    {
      error: 'Too many requests from this connection. Wait a minute and try again.',
      retryAfterSeconds: verdict.retryAfterSeconds,
    },
    {
      status: 429,
      headers: { 'cache-control': 'no-store', 'retry-after': String(verdict.retryAfterSeconds) },
    }
  );
}

export const config = {
  matcher: '/api/:path*',
};
