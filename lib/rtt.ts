/**
 * Realtime Trains next-generation API client. Server-side only.
 *
 * The token must never reach the browser: RTT's terms require end-user apps to
 * proxy through a server-side component, and a token found in a client bundle
 * gets revoked. This module is the only thing that touches it, it is imported
 * exclusively by the route handler, and the guard at the bottom of the file
 * makes a client import fail loudly rather than quietly leaking.
 *
 * Built against https://realtimetrains.github.io/api-specification/ (spec
 * version 2.0). Not against api.rtt.io, which is deprecated and shuts down on
 * 30 September 2026.
 */

import 'server-only';

const BASE_URL = 'https://data.rtt.io';

/**
 * Rate limits on the **Team** tier, live since 15 August 2026: 40/minute, 1200/hour,
 * 12000/day, 25000/week. The free personal tier was 10/100/1000/10000, and every budget
 * in this app was sized against its 10/minute.
 *
 * **The per-minute figure is no longer the one that binds.** On free, 7 × 1000/day fitted
 * inside 10000/week, so the daily cap was a rate you could hold. On Team, 7 × 12000 is
 * 84000 against a 25000 weekly ceiling, so the *week* binds: `25000 ÷ 7` = 3571 a day
 * sustainable, not the 12000 headline. Size against that. See STATUS.md.
 *
 * Nothing reads this constant — the budgets it informs are written where they are spent.
 * It is kept as the one place the numbers are recorded in code, and it was wrong until now.
 */
export const RATE_LIMIT_PER_MINUTE = 40;

/**
 * Pinned so a spec change cannot silently alter response shapes underneath us.
 * 2026-04-09 is the first version serving /data/stops and
 * /data/locations_ungrouped, which the station data is generated from.
 * Bump deliberately, after re-running the spike.
 */
export const API_VERSION = process.env.RTT_API_VERSION || '2026-04-09';

export class RttError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly retryAfterSeconds?: number
  ) {
    super(message);
    this.name = 'RttError';
  }
}

// ------------------------------------------------------------------ credentials

interface CachedToken {
  value: string;
  expiresAtMillis: number;
}

let cachedAccessToken: CachedToken | null = null;

/**
 * A long-life access token is used as-is. A refresh token is exchanged for a
 * short-life access token and cached until just before it expires.
 */
async function getBearerToken(): Promise<string> {
  const longLife = process.env.RTT_ACCESS_TOKEN?.trim();
  if (longLife) return longLife;

  const refresh = process.env.RTT_REFRESH_TOKEN?.trim();
  if (!refresh) {
    throw new RttError(
      'RTT credentials are not configured on the server. Set RTT_ACCESS_TOKEN or RTT_REFRESH_TOKEN.',
      500
    );
  }

  if (cachedAccessToken && Date.now() < cachedAccessToken.expiresAtMillis) {
    return cachedAccessToken.value;
  }

  const res = await fetch(`${BASE_URL}/api/get_access_token`, {
    headers: {
      Authorization: `Bearer ${refresh}`,
      Version: API_VERSION,
      Accept: 'application/json',
    },
    cache: 'no-store',
  });

  if (!res.ok) {
    // Deliberately does not echo the response body, which can quote the token.
    throw new RttError(`Could not exchange refresh token (HTTP ${res.status}).`, 502);
  }

  const body = (await res.json()) as { token: string; validUntil: string };
  const expiry = Date.parse(body.validUntil);
  cachedAccessToken = {
    value: body.token,
    // 60s of slack so a request cannot be issued with a token that expires mid-flight.
    expiresAtMillis: Number.isNaN(expiry) ? Date.now() + 300_000 : expiry - 60_000,
  };
  return cachedAccessToken.value;
}

// -------------------------------------------------------------------- requests

export interface RateLimitSnapshot {
  minute?: string;
  hour?: string;
  day?: string;
  week?: string;
}

function readRateLimits(headers: Headers): RateLimitSnapshot {
  const snapshot: RateLimitSnapshot = {};
  for (const dimension of ['Minute', 'Hour', 'Day', 'Week'] as const) {
    const remaining = headers.get(`X-RateLimit-Remaining-${dimension}`);
    const limit = headers.get(`X-RateLimit-Limit-${dimension}`);
    if (remaining !== null) {
      snapshot[dimension.toLowerCase() as keyof RateLimitSnapshot] = `${remaining}/${limit ?? '?'}`;
    }
  }
  return snapshot;
}

let lastRateLimits: RateLimitSnapshot = {};

/** Most recent rate-limit headers seen, for diagnostics. */
export const rateLimitSnapshot = (): RateLimitSnapshot => ({ ...lastRateLimits });

type QueryValue = string | number | boolean | undefined | null;

/**
 * A single GET against the API.
 *
 * Returns `null` on 204, which the API uses for "valid query, no services
 * found". That is a real answer, not an error -- treating it as one would break
 * the rule that a blank result can be trusted.
 */
async function request<T>(path: string, params: Record<string, QueryValue> = {}): Promise<T | null> {
  const url = new URL(path, BASE_URL);
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null) url.searchParams.set(key, String(value));
  }

  let res: Response;
  try {
    res = await fetch(url, {
      headers: {
        Authorization: `Bearer ${await getBearerToken()}`,
        Version: API_VERSION,
        Accept: 'application/json',
      },
      // Our own cache layer decides freshness; see lib/cache.ts.
      cache: 'no-store',
      signal: AbortSignal.timeout(12_000),
    });
  } catch (cause) {
    if (cause instanceof RttError) throw cause;
    const timedOut = cause instanceof Error && cause.name === 'TimeoutError';
    throw new RttError(
      timedOut ? 'Realtime Trains did not respond in time.' : 'Could not reach Realtime Trains.',
      504
    );
  }

  lastRateLimits = readRateLimits(res.headers);

  if (res.status === 204) return null;

  if (res.status === 429) {
    const retryAfter = Number(res.headers.get('Retry-After'));
    throw new RttError(
      'Realtime Trains rate limit reached.',
      429,
      Number.isFinite(retryAfter) ? retryAfter : undefined
    );
  }

  if (res.status === 401 || res.status === 403) {
    cachedAccessToken = null;
    throw new RttError('Realtime Trains rejected our credentials.', 502);
  }

  if (!res.ok) {
    throw new RttError(`Realtime Trains returned HTTP ${res.status}.`, res.status === 400 ? 400 : 502);
  }

  return (await res.json()) as T;
}

// --------------------------------------------------------------------- schemas
// Only the fields this app actually reads. Names follow the spec exactly.

export type CallType =
  | 'OPERATIONAL_ONLY'
  | 'ADVERTISED_OPEN'
  | 'ADVERTISED_SET_DOWN'
  | 'ADVERTISED_PICK_UP'
  | null;

export type DisplayAs =
  | 'CALL'
  | 'CANCELLED'
  | 'DIVERTED'
  | 'STARTS'
  | 'TERMINATES'
  | 'PASS'
  | null;

export interface IndividualTemporalData {
  scheduleInternal?: string;
  scheduleAdvertised?: string;
  realtimeForecast?: string;
  realtimeActual?: string;
  isCancelled?: boolean;
}

export interface LocationTemporalData {
  arrival?: IndividualTemporalData;
  departure?: IndividualTemporalData;
  pass?: IndividualTemporalData;
  scheduledCallType?: CallType;
  realtimeCallType?: CallType;
  displayAs?: DisplayAs;
}

export interface GeographicLocation {
  namespace?: string;
  description?: string;
  shortCodes?: string[];
  longCodes?: string[];
}

export interface LocationPair {
  location?: GeographicLocation;
  temporalData?: IndividualTemporalData;
}

export interface ScheduleMetadata {
  uniqueIdentity?: string;
  identity?: string;
  departureDate?: string;
  operator?: { code?: string; name?: string };
  modeType?: 'TRAIN' | 'SHIP' | 'BUS' | 'SCHEDULED_BUS' | 'REPLACEMENT_BUS';
  inPassengerService?: boolean;
  trainReportingIdentity?: string;
}

export interface LocationLineUpObject {
  temporalData?: LocationTemporalData;
  locationMetadata?: { platform?: { planned?: string; actual?: string } };
  scheduleMetadata?: ScheduleMetadata;
  origin?: LocationPair[];
  destination?: LocationPair[];
}

export interface SystemStatus {
  realtimeNetworkRail?: 'OK' | 'REALTIME_DATA_LIMITED' | 'REALTIME_DATA_NONE';
  rttCore?: 'OK' | 'REALTIME_DEGRADED' | 'SCHEDULE_ONLY';
}

export interface LocationLineUpResponse {
  systemStatus?: SystemStatus;
  query?: { location?: GeographicLocation; timeFrom?: string; timeTo?: string };
  services?: LocationLineUpObject[];
}

export interface ServiceLocation {
  location?: GeographicLocation;
  temporalData?: LocationTemporalData;
}

export interface ServiceResponse {
  systemStatus?: SystemStatus;
  service?: {
    scheduleMetadata?: ScheduleMetadata;
    locations?: ServiceLocation[];
    origin?: LocationPair[];
    destination?: LocationPair[];
  };
}

export interface StopsResponse {
  stops?: { namespace?: string; description?: string; shortCode?: string; uniqueIdentity?: string }[];
}

export interface LocationsResponse {
  locations?: {
    namespace?: string;
    description?: string;
    shortCode?: string;
    longCode?: string;
    uniqueIdentity?: string;
  }[];
}

export interface ApiInfoResponse {
  api_version?: string;
  credentials?: {
    entitlements?: string[];
    historyRestriction?: boolean;
    historyRestrictToDays?: number | null;
    namespaceRestriction?: boolean;
    namespacesAvailable?: string[] | null;
  };
}

// ------------------------------------------------------------------- endpoints

export interface LineUpQuery {
  /** CRS (short) or TIPLOC (long) code of the station being queried. */
  code: string;
  /** Restrict to trains that subsequently call at this code. */
  filterTo?: string;
  /** Restrict to trains that previously called at this code. */
  filterFrom?: string;
  timeFrom: string;
  timeTo: string;
}

/**
 * Services at one station over a time window, optionally filtered by another
 * station the train calls at.
 *
 * Note there is no operator parameter, and that is on purpose: querying by
 * station pair returns every operator merged in time order, which is exactly
 * what is wanted. Liverpool Street -> Shenfield needs both Greater Anglia and
 * the Elizabeth line in one list, and the last train is often the Greater
 * Anglia one.
 */
export const locationLineUp = (query: LineUpQuery) =>
  request<LocationLineUpResponse>('/gb-nr/location', { ...query });

/**
 * One service's calling pattern, used to derive the route it takes.
 *
 * The namespaced endpoint wants the identity *without* its namespace, while a
 * line-up hands back `gb-nr:P67203:2026-07-31`. Passing that through verbatim
 * returns 400 -- only `/rtt/service` takes the namespaced form. Confirmed against
 * the live API, since the two endpoints' examples differ by exactly this.
 *
 * Note the response contains public calling points only: passes are omitted, and
 * locations carry no `displayAs`. See `servesScopeAhead` in lib/journeys.ts.
 */
export const serviceDetail = (uniqueIdentity: string) =>
  request<ServiceResponse>('/gb-nr/service', {
    uniqueIdentity: uniqueIdentity.replace(/^gb-nr:/, ''),
  });

export const apiInfo = () => request<ApiInfoResponse>('/api/info');

/** Passenger stops. The source of truth for CRS codes; requires version >= 2026-04-09. */
export const dataStops = () => request<StopsResponse>('/data/stops');

/** Ungrouped locations, giving the CRS <-> TIPLOC pairing used to attach coordinates. */
export const dataLocations = () => request<LocationsResponse>('/data/locations_ungrouped');
