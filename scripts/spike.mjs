#!/usr/bin/env node
/**
 * Build step 1: the spike. Throwaway, no UI, no framework.
 *
 * Prints every service from London Liverpool Street to Shenfield for tomorrow's
 * service day, and confirms three things the rest of the build depends on:
 *
 *   1. The next-generation API answers a station-pair query at all.
 *   2. Elizabeth line (XR) services appear in the data alongside Greater Anglia (LE).
 *   3. The Elizabeth line central core stations (Farringdon et al) appear too,
 *      under their real codes — looked up, never inferred.
 *
 * Run:  node scripts/spike.mjs
 * Needs RTT_ACCESS_TOKEN or RTT_REFRESH_TOKEN in the environment or .env.local.
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const BASE = 'https://data.rtt.io';

// Reference-data endpoints (/data/stops) need 2026-04-09 or later.
const API_VERSION = process.env.RTT_API_VERSION || '2026-04-09';

// ---------------------------------------------------------------- env loading

function loadEnvLocal() {
  try {
    for (const raw of readFileSync(join(ROOT, '.env.local'), 'utf8').split('\n')) {
      const line = raw.trim();
      if (!line || line.startsWith('#')) continue;
      const eq = line.indexOf('=');
      if (eq === -1) continue;
      const key = line.slice(0, eq).trim();
      let val = line.slice(eq + 1).trim();
      if (
        (val.startsWith('"') && val.endsWith('"')) ||
        (val.startsWith("'") && val.endsWith("'"))
      ) {
        val = val.slice(1, -1);
      }
      if (!(key in process.env)) process.env[key] = val;
    }
  } catch {
    /* no .env.local; rely on the real environment */
  }
}

// ------------------------------------------------------------- service day

// The rail service day runs 03:00 -> 02:59 the next morning. A train leaving
// London at 00:30 belongs to the *previous* calendar day's service. Getting this
// wrong silently drops the last train, which is the whole point of the app.
const SERVICE_DAY_START_HOUR = 3;

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
  for (const part of f.formatToParts(d)) {
    if (part.type !== 'literal') p[part.type] = part.value;
  }
  return p;
};

const isoDate = (ms) => new Date(ms).toISOString().slice(0, 10);
const addDays = (date, n) => {
  const [y, m, d] = date.split('-').map(Number);
  return isoDate(Date.UTC(y, m - 1, d) + n * 86_400_000);
};

function currentServiceDate(now = new Date()) {
  const p = londonParts(now);
  const midnight = Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day));
  return isoDate(Number(p.hour) < SERVICE_DAY_START_HOUR ? midnight - 86_400_000 : midnight);
}

// Naked local times: the API reads an offset-less datetime as local to the
// queried location, so this is correct through both BST and GMT with no
// conversion of our own. Window is 23h59m -- exactly the documented maximum.
function serviceDayWindow(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return {
    timeFrom: `${date}T${pad(SERVICE_DAY_START_HOUR)}:00:00`,
    timeTo: `${addDays(date, 1)}T${pad(SERVICE_DAY_START_HOUR - 1)}:59:00`,
  };
}

// ------------------------------------------------------------------- transport

let bearer = null;

async function getBearer() {
  if (bearer) return bearer;

  if (process.env.RTT_ACCESS_TOKEN) {
    bearer = process.env.RTT_ACCESS_TOKEN;
    return bearer;
  }
  if (!process.env.RTT_REFRESH_TOKEN) {
    throw new Error(
      'No credentials. Put RTT_ACCESS_TOKEN=... (or RTT_REFRESH_TOKEN=...) in .env.local'
    );
  }

  const res = await fetch(`${BASE}/api/get_access_token`, {
    headers: {
      Authorization: `Bearer ${process.env.RTT_REFRESH_TOKEN}`,
      Version: API_VERSION,
      Accept: 'application/json',
    },
  });
  if (!res.ok) throw new Error(`Token exchange failed: HTTP ${res.status}`);
  const body = await res.json();
  console.log(`  token valid until ${body.validUntil}`);
  bearer = body.token;
  return bearer;
}

async function rtt(path, params = {}) {
  const url = new URL(path, BASE);
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== null) url.searchParams.set(k, String(v));
  }

  const res = await fetch(url, {
    headers: {
      Authorization: `Bearer ${await getBearer()}`,
      Version: API_VERSION,
      Accept: 'application/json',
    },
  });

  const remaining = ['Minute', 'Hour', 'Day', 'Week']
    .map((d) => {
      const r = res.headers.get(`X-RateLimit-Remaining-${d}`);
      const l = res.headers.get(`X-RateLimit-Limit-${d}`);
      return r ? `${d.toLowerCase()} ${r}/${l}` : null;
    })
    .filter(Boolean)
    .join(', ');

  console.log(`  GET ${url.pathname}${url.search}`);
  console.log(`   -> HTTP ${res.status}${remaining ? `  [remaining: ${remaining}]` : ''}`);

  if (res.status === 204) return null; // valid query, no services
  if (res.status === 429) {
    throw new Error(`Rate limited; retry after ${res.headers.get('Retry-After')}s`);
  }
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`);
  return res.json();
}

// -------------------------------------------------------------------- helpers

// The API sends departure times with no timezone -- "2026-07-30T23:12:00" -- and
// those are London wall-clock times. new Date() would resolve them using whatever
// timezone this process happens to be in, so read the wall clock directly and only
// convert when an offset is actually present.
const hhmm = (value) => {
  if (!value) return ' -- ';
  if (!/(?:Z|[+-]\d{2}:?\d{2})$/i.test(value.trim())) return value.slice(11, 16);
  const p = londonParts(new Date(value));
  return `${p.hour}:${p.minute}`;
};

const ADVERTISED_PICKUP = new Set(['ADVERTISED_OPEN', 'ADVERTISED_PICK_UP']);
const ADVERTISED_SETDOWN = new Set(['ADVERTISED_OPEN', 'ADVERTISED_SET_DOWN']);

const describe = (pairs) =>
  (pairs ?? []).map((p) => p?.location?.description).filter(Boolean).join(' & ') || '?';

// ------------------------------------------------------------------------ main

async function main() {
  loadEnvLocal();

  console.log('=== 0. Entitlements =========================================\n');
  const info = await rtt('/api/info');
  console.log(`  api_version served : ${info.api_version}`);
  console.log(`  entitlements       : ${(info.credentials?.entitlements ?? []).join(', ') || '(none)'}`);
  console.log(`  namespaces         : ${(info.credentials?.namespacesAvailable ?? ['(unrestricted)']).join(', ')}`);
  console.log(
    `  history limit      : ${info.credentials?.historyRestriction ? `${info.credentials.historyRestrictToDays} days` : 'none'}`
  );
  if (info.api_version !== API_VERSION) {
    console.log(
      `\n  NOTE: asked for Version ${API_VERSION}, served ${info.api_version}.` +
        `\n        Pin RTT_API_VERSION to the served value once happy.`
    );
  }

  console.log('\n=== 1. Resolve station codes (never hand-typed) ==============\n');
  const stops = (await rtt('/data/stops')).stops ?? [];
  console.log(`  ${stops.length} stops available to this token\n`);

  const find = (needle) => {
    const hits = stops.filter(
      (s) => s.description?.toLowerCase() === needle.toLowerCase()
    );
    if (!hits.length) {
      const loose = stops.filter((s) => s.description?.toLowerCase().includes(needle.toLowerCase()));
      throw new Error(
        `No exact stop named "${needle}". Near misses: ` +
          loose.slice(0, 8).map((s) => `${s.description} (${s.shortCode})`).join(', ')
      );
    }
    return hits[0];
  };

  const from = find('London Liverpool Street');
  const to = find('Shenfield');
  console.log(`  from : ${from.description} -> ${from.shortCode}`);
  console.log(`  to   : ${to.description} -> ${to.shortCode}`);

  console.log('\n  Elizabeth line central core (spec flags these as unusual):');
  for (const name of [
    'Farringdon',
    'Whitechapel',
    'Bond Street',
    'Tottenham Court Road',
    'Liverpool Street (Elizabeth line)',
    'Paddington',
    'Canary Wharf',
    'Abbey Wood',
  ]) {
    const hits = stops.filter((s) => s.description?.toLowerCase().includes(name.toLowerCase()));
    console.log(
      `    ${name.padEnd(34)} ${
        hits.map((s) => `${s.shortCode} "${s.description}"`).join(' | ') || '*** NOT FOUND ***'
      }`
    );
  }

  console.log('\n=== 2. A full service day, Liverpool St -> Shenfield =========\n');
  const date = addDays(currentServiceDate(), 1); // tomorrow
  const win = serviceDayWindow(date);
  console.log(`  service date : ${date}`);
  console.log(`  window       : ${win.timeFrom} .. ${win.timeTo}  (local to station)\n`);

  const dep = await rtt('/gb-nr/location', {
    code: from.shortCode,
    filterTo: to.shortCode,
    timeFrom: win.timeFrom,
    timeTo: win.timeTo,
  });

  if (!dep) {
    console.log('\n  204 -- no services. On a Sunday or engineering weekend that is a real answer.');
    return;
  }

  console.log(`  systemStatus : ${JSON.stringify(dep.systemStatus)}`);

  // Mirror query: the origin line-up knows when a train leaves, but not when it
  // reaches our destination. Ask the destination for arrivals of trains that
  // previously called at the origin, then join on uniqueIdentity. Two calls.
  const arr = await rtt('/gb-nr/location', {
    code: to.shortCode,
    filterFrom: from.shortCode,
    timeFrom: win.timeFrom,
    timeTo: win.timeTo,
  });

  const arrivals = new Map();
  for (const s of arr?.services ?? []) {
    const id = s.scheduleMetadata?.uniqueIdentity;
    if (id) arrivals.set(id, s);
  }

  console.log(
    `\n  ${dep.services.length} departures matched, ${arrivals.size} arrivals matched\n`
  );

  const byToc = new Map();
  let printed = 0;

  for (const s of dep.services) {
    const meta = s.scheduleMetadata ?? {};
    const td = s.temporalData ?? {};
    const toc = meta.operator?.code ?? '??';

    const displayAs = td.displayAs;
    const callType = td.scheduledCallType ?? td.realtimeCallType;
    const departs = td.departure?.scheduleAdvertised;

    const usable =
      departs &&
      (displayAs === 'CALL' || displayAs === 'STARTS') &&
      ADVERTISED_PICKUP.has(callType) &&
      meta.inPassengerService !== false &&
      td.departure?.isCancelled !== true;

    const a = arrivals.get(meta.uniqueIdentity);
    const atd = a?.temporalData ?? {};
    const arrives = atd.arrival?.scheduleAdvertised;
    const arrUsable =
      arrives &&
      (atd.displayAs === 'CALL' || atd.displayAs === 'TERMINATES') &&
      ADVERTISED_SETDOWN.has(atd.scheduledCallType ?? atd.realtimeCallType) &&
      atd.arrival?.isCancelled !== true;

    const mins =
      departs && arrives
        ? Math.round((new Date(arrives) - new Date(departs)) / 60000)
        : null;

    if (usable) {
      byToc.set(toc, (byToc.get(toc) ?? 0) + 1);
      printed++;
      console.log(
        `  ${hhmm(departs)} -> ${hhmm(arrives)}  ` +
          `${String(mins ?? '?').padStart(3)}m  ` +
          `${toc}  ${(meta.operator?.name ?? '').padEnd(22).slice(0, 22)} ` +
          `${(meta.trainReportingIdentity ?? meta.identity ?? '').padEnd(7)} ` +
          `dest ${describe(s.destination)}` +
          (arrUsable ? '' : '   <-- arrival not matched')
      );
    } else {
      console.log(
        `  [skip ${hhmm(departs)} ${toc} displayAs=${displayAs} callType=${callType} ` +
          `pax=${meta.inPassengerService} mode=${meta.modeType}]`
      );
    }
  }

  console.log(`\n=== 3. Verdict ==============================================\n`);
  console.log(`  usable passenger departures : ${printed}`);
  console.log(`  by operator                 : ${[...byToc].map(([k, v]) => `${k}=${v}`).join(', ')}`);

  const hasXR = byToc.has('XR');
  const hasLE = byToc.has('LE');
  console.log(`\n  Elizabeth line (XR) present  : ${hasXR ? 'YES' : 'NO  <-- investigate'}`);
  console.log(`  Greater Anglia (LE) present  : ${hasLE ? 'YES' : 'NO  <-- investigate'}`);

  if (hasXR && hasLE) {
    console.log(
      '\n  Both operators in one station-pair query, merged in time order.\n' +
        '  This is the behaviour the app depends on. Spike passes.'
    );
  } else {
    console.log('\n  Spike has NOT passed. Do not build on this yet.');
    process.exitCode = 1;
  }

  // The calling pattern, which the route label and the corridor check both need.
  // Two things bite here, and both were found the hard way:
  //   - the namespaced endpoint rejects the namespaced identity a line-up returns;
  //   - its locations carry no displayAs, and omit passes entirely, so gating on
  //     displayAs silently matches nothing.
  console.log('\n=== 4. One service in detail =================================\n');

  const sample = dep.services.find(
    (s) => s.scheduleMetadata?.operator?.code === 'LE' && s.scheduleMetadata?.uniqueIdentity
  );

  if (!sample) {
    console.log('  no Greater Anglia service to inspect');
  } else {
    const namespaced = sample.scheduleMetadata.uniqueIdentity;
    const stripped = namespaced.replace(/^gb-nr:/, '');
    console.log(`  line-up gives uniqueIdentity : ${namespaced}`);
    console.log(`  sending to /gb-nr/service    : ${stripped}\n`);

    const detail = await rtt('/gb-nr/service', { uniqueIdentity: stripped });
    const locations = detail?.service?.locations ?? [];
    const advertised = new Set([
      'ADVERTISED_OPEN',
      'ADVERTISED_SET_DOWN',
      'ADVERTISED_PICK_UP',
    ]);
    const calls = locations.filter((l) =>
      advertised.has(l.temporalData?.scheduledCallType ?? l.temporalData?.realtimeCallType)
    );

    console.log(`  ${locations.length} locations, ${calls.length} advertised calls`);
    console.log(`  displayAs populated here? ${locations.some((l) => l.temporalData?.displayAs) ? 'yes' : 'NO -- do not gate on it'}`);
    console.log(
      `  calls at: ${calls.map((l) => l.location?.shortCodes?.[0]).filter(Boolean).join(' ')}`
    );

    const reachesShenfield = calls.some((l) => l.location?.shortCodes?.includes(to.shortCode));
    console.log(`  calls at ${to.shortCode}: ${reachesShenfield ? 'YES' : 'NO  <-- investigate'}`);
    if (!reachesShenfield) process.exitCode = 1;
  }

  // The spec's other worry: a central-core Elizabeth line station should return
  // services under its own code.
  console.log('\n=== 5. Central core sanity: Farringdon line-up ===============\n');
  const far = stops.find((s) => s.description === 'Farringdon');
  if (!far) {
    console.log('  Farringdon not in stop list -- investigate.');
  } else {
    const core = await rtt('/gb-nr/location', {
      code: far.shortCode,
      timeFrom: `${date}T08:00:00`,
      timeTo: `${date}T08:30:00`,
    });
    const tocs = new Set((core?.services ?? []).map((s) => s.scheduleMetadata?.operator?.code));
    console.log(`  Farringdon (${far.shortCode}) 08:00-08:30: ${core?.services?.length ?? 0} services`);
    console.log(`  operators seen: ${[...tocs].join(', ') || '(none)'}`);
    console.log(`  XR at Farringdon: ${tocs.has('XR') ? 'YES' : 'NO  <-- investigate'}`);
  }
}

main().catch((err) => {
  console.error(`\nFAILED: ${err.message}`);
  process.exitCode = 1;
});
