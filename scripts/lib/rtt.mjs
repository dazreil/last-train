/**
 * A small read-only client for RTT reference data.
 *
 * Shared by the national probe and the national generator. Deliberately not used by
 * `generate-stations.mjs`, whose own client carries retry and hour-budget pacing
 * tuned for a fifty-request run; this one is for scripts that make a handful of
 * requests and lean on the cache for the rest.
 *
 * Everything is cached to `.rtt-cache/` under the same key scheme the generator
 * uses, so reference data fetched by one script is free for the others. On the free
 * tier that matters: ten requests a minute is not a budget to spend twice on the
 * same list of stations.
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const CACHE = join(ROOT, '.rtt-cache');

export const BASE = 'https://data.rtt.io';
export const API_VERSION = process.env.RTT_API_VERSION || '2026-04-09';

export function loadEnvLocal() {
  try {
    for (const raw of readFileSync(join(ROOT, '.env.local'), 'utf8').split('\n')) {
      const line = raw.trim();
      if (!line || line.startsWith('#')) continue;
      const eq = line.indexOf('=');
      if (eq === -1) continue;
      const key = line.slice(0, eq).trim();
      let val = line.slice(eq + 1).trim();
      if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1);
      }
      if (!(key in process.env)) process.env[key] = val;
    }
  } catch {
    /* no .env.local; rely on the real environment */
  }
}

const cachePath = (key) => join(CACHE, `${key.replace(/[^a-z0-9.-]/gi, '_')}.json`);

export function readCache(key) {
  try {
    return JSON.parse(readFileSync(cachePath(key), 'utf8')).body;
  } catch {
    return undefined;
  }
}

export function writeCache(key, body) {
  try {
    mkdirSync(CACHE, { recursive: true });
    writeFileSync(cachePath(key), JSON.stringify({ body }));
  } catch {
    /* the cache is an optimisation, never a requirement */
  }
}

// -------------------------------------------------------------------- requests

let bearer = null;
const requestTimes = [];
let spent = 0;

export const requestsSpent = () => spent;

/** Free tier is 10 a minute. Eight leaves room for anything else on the token. */
async function throttle(log) {
  for (;;) {
    const now = Date.now();
    while (requestTimes.length && now - requestTimes[0] > 60_000) requestTimes.shift();
    if (requestTimes.length < 8) {
      requestTimes.push(now);
      return;
    }
    const waitMs = 60_000 - (now - requestTimes[0]) + 250;
    log(`  (minute allowance reached; waiting ${Math.ceil(waitMs / 1000)}s)`);
    await new Promise((r) => setTimeout(r, waitMs));
  }
}

async function getBearer(log) {
  if (bearer) return bearer;
  if (process.env.RTT_ACCESS_TOKEN) return (bearer = process.env.RTT_ACCESS_TOKEN);
  if (!process.env.RTT_REFRESH_TOKEN) {
    throw new Error('No credentials. Put RTT_REFRESH_TOKEN=... in .env.local');
  }

  await throttle(log);
  spent++;
  const res = await fetch(`${BASE}/api/get_access_token`, {
    headers: {
      Authorization: `Bearer ${process.env.RTT_REFRESH_TOKEN}`,
      Version: API_VERSION,
      Accept: 'application/json',
    },
  });
  if (!res.ok) throw new Error(`Token exchange failed: HTTP ${res.status}`);
  return (bearer = (await res.json()).token);
}

let lastLimits = '';
export const rateLimits = () => lastLimits;

export async function rtt(path, params = {}, { cache = false, log = console.log } = {}) {
  const url = new URL(path, BASE);
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== null) url.searchParams.set(k, String(v));
  }

  const key = `${url.host}${url.pathname}${url.search}`;
  if (cache) {
    const hit = readCache(key);
    if (hit !== undefined) {
      log(`  cached  ${url.pathname}${url.search.slice(0, 80)}`);
      return hit;
    }
  }

  await throttle(log);
  spent++;
  const res = await fetch(url, {
    headers: {
      Authorization: `Bearer ${await getBearer(log)}`,
      Version: API_VERSION,
      Accept: 'application/json',
    },
  });

  lastLimits =
    ['Minute', 'Hour', 'Day', 'Week']
      .map((d) => {
        const r = res.headers.get(`X-RateLimit-Remaining-${d}`);
        const l = res.headers.get(`X-RateLimit-Limit-${d}`);
        return r ? `${d.toLowerCase()} ${r}/${l}` : null;
      })
      .filter(Boolean)
      .join(', ') || lastLimits;

  log(`  GET     ${url.pathname}${url.search.slice(0, 80)} -> ${res.status}`);

  if (res.status === 429) {
    throw new Error(`Rate limited; retry after ${res.headers.get('Retry-After')}s`);
  }
  const body = res.status === 204 ? null : await res.json();
  if (!res.ok && res.status !== 204) {
    throw new Error(`HTTP ${res.status}: ${JSON.stringify(body).slice(0, 300)}`);
  }
  if (cache) writeCache(key, body);
  return body;
}

// ------------------------------------------------------------- service day

export const SERVICE_DAY_START_HOUR = 3;

const londonParts = (d) => {
  const f = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  });
  const p = {};
  for (const part of f.formatToParts(d)) if (part.type !== 'literal') p[part.type] = part.value;
  return p;
};

const isoDate = (ms) => new Date(ms).toISOString().slice(0, 10);

export const addDays = (date, n) => {
  const [y, m, d] = date.split('-').map(Number);
  return isoDate(Date.UTC(y, m - 1, d) + n * 86_400_000);
};

export function currentServiceDate(now = new Date()) {
  const p = londonParts(now);
  const midnight = Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day));
  return isoDate(Number(p.hour) < SERVICE_DAY_START_HOUR ? midnight - 86_400_000 : midnight);
}

/** 03:00 -> 02:59, deliberately offset-less: the API reads it as local to the station. */
export function serviceDayWindow(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return {
    timeFrom: `${date}T${pad(SERVICE_DAY_START_HOUR)}:00:00`,
    timeTo: `${addDays(date, 1)}T${pad(SERVICE_DAY_START_HOUR - 1)}:59:00`,
  };
}
