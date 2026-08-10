/**
 * GET /api/v2/service?id=gb-nr:F20585:2026-08-07
 *   -> { headcode, origin, destination, calls: [{ crs, name, time, isCancelled }] }
 *
 * Where one train actually goes, for the sheet behind a tap on a service block.
 *
 * **One request per tap, not per train shown.** That distinction is what makes this
 * affordable where `IOS.md` §11's arrival-ordered Fast Train mode was not: that needed a
 * calling pattern for every departure on the board before it could rank them, which is
 * roughly a request per row and breaks the budget in §3. This spends one, only when
 * somebody asks, and caches it by service id — the pattern for a given service on a
 * given day does not change.
 *
 * The response carries **calling points only**. RTT omits passes from this endpoint
 * entirely and the locations carry no `displayAs`, so there is nothing to filter: every
 * entry is somewhere a passenger can get off. Filtering on `displayAs` here would match
 * nothing and silently return an empty route — see STATUS.md.
 */

import { NextResponse } from 'next/server';

import { serviceDetail } from '@/lib/rtt';
import { formatLondonTime } from '@/lib/serviceDay';
import { getCachedCalls, setCachedCalls } from '@/lib/cache';
import type { ServiceCall, ServiceCalls } from '@/lib/nationalContract';

export const runtime = 'nodejs';

/**
 * A day, near enough.
 *
 * A timetabled calling pattern is fixed for the service day it belongs to, and the id
 * carries that date — so a stale entry cannot outlive the thing it describes.
 */
const TTL_SECONDS = 60 * 60 * 12;

const describe = (list: { location?: { description?: string } }[] | undefined): string =>
  (list ?? [])
    .map((entry) => entry.location?.description)
    .filter((name): name is string => Boolean(name))
    .join(' & ');

export async function GET(request: Request) {
  const id = (new URL(request.url).searchParams.get('id') ?? '').trim();

  // Shape check only. `serviceDetail` strips the namespace itself, and RTT is the
  // authority on whether the identity exists.
  if (!id || !id.includes(':')) {
    return NextResponse.json({ error: 'A service id is required.' }, { status: 400 });
  }

  const cached = getCachedCalls<ServiceCalls>(id);
  if (cached) {
    return NextResponse.json(cached.value, {
      headers: { 'x-cache': 'HIT', 'cache-control': `public, max-age=${TTL_SECONDS}` },
    });
  }

  let detail;
  try {
    detail = await serviceDetail(id);
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Could not look up that train.';
    return NextResponse.json({ error: message }, { status: 502 });
  }

  const service = detail?.service;
  if (!service) {
    return NextResponse.json({ error: 'No such train.' }, { status: 404 });
  }

  const calls: ServiceCall[] = (service.locations ?? []).map((stop) => {
    // The departure everywhere except the far end, which only has an arrival.
    const departure = stop.temporalData?.departure;
    const arrival = stop.temporalData?.arrival;
    const when = departure?.scheduleAdvertised ?? arrival?.scheduleAdvertised ?? null;

    return {
      crs: stop.location?.shortCodes?.[0] ?? null,
      name: stop.location?.description ?? 'Unknown',
      time: when ? (formatLondonTime(when) ?? null) : null,
      // The raw London string, kept so a client can order these. See ServiceCall.
      timeInstant: when ?? null,
      isCancelled: Boolean(departure?.isCancelled ?? arrival?.isCancelled),
    };
  });

  const body: ServiceCalls = {
    serviceId: id,
    headcode: service.scheduleMetadata?.trainReportingIdentity ?? null,
    toc: service.scheduleMetadata?.operator?.code ?? '??',
    tocName: service.scheduleMetadata?.operator?.name ?? 'Unknown operator',
    origin: describe(service.origin),
    destination: describe(service.destination),
    calls,
  };

  setCachedCalls(id, body, TTL_SECONDS);

  return NextResponse.json(body, {
    headers: { 'x-cache': 'MISS', 'cache-control': `public, max-age=${TTL_SECONDS}` },
  });
}
