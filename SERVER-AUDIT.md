# Server audit — 24 September 2026

Recommendation: retain RTT during hardening, then make Darwin the primary source for dates with proven complete coverage. RTT is still required by the deployed product. Removing the token now breaks Last Train, future browsing and fallback/detail paths.

This is an audit, not a migration or deployment. Existing iOS edits were left untouched.

## Verified now

- Production `/api/timetable-health`: healthy, snapshot `20260924020538`, generated 02:05:38 London time, published 08:29:59 UTC; 6,119 boards and 546,520 departures. Listed service dates: 22–25 September. Presence of a date does not prove the complete service day is covered.
- Production `/api/cache-health`: configured and reachable, reported Redis round trip 20 ms.
- Scheduled GitHub ingests on 23 and 24 September succeeded. Today's run: https://github.com/dazreil/last-train/actions/runs/35975534190
- Both scheduled runs started around 08:30 UTC despite a 03:20 cron. Delivery and scheduling need separate monitoring.
- 190 Node tests pass; TypeScript and production build pass.
- `npm audit --omit=dev`: four affected dependency packages, one critical and three high. These are advisory classifications, not proof of exploitability on this deployment.
- Small production smoke sample: Upminster destinations returned 24 entries from the timetable in 161 ms; Paddington–Reading later window returned a timetable response in 184 ms. These are single observations, not load-test percentiles.
- No server source, dependency or deployment changes were made during the audit.

## What RTT does today

| Feature | Current source | Removal implications |
|---|---|---|
| Last Train `/api/v2/trains` | RTT whole-day line-ups, Darwin near-term overlay | Needs a Darwin whole-day implementation and complete coverage checks |
| Last Train destination filtering | Additional filtered RTT line-up per date | Darwin onward calls can supply this locally |
| Last Train journey durations | RTT details for up to four displayed trains | Darwin already carries onward arrival times |
| Fast Train now | Darwin; RTT on empty live results, failures and future dates | Use stored timetable for covered windows; explicitly distinguish schedule from live data |
| Fast Train later | Darwin timetable | Already independent of RTT |
| Destination picker | Darwin timetable, with directional Darwin/RTT fallbacks | Mostly independent; fallback and missing/stale semantics need work |
| Service detail | Cached Darwin calls or RTT service lookup | Needs reliable origin-aware or canonical Darwin detail storage |
| Legacy web board and generators | RTT | Retire or migrate explicitly before removing credentials |

A cold normal Last Train request with a destination can require four line-ups plus four detail requests, excluding authentication: up to eight RTT requests. The route's introductory claim of one or two requests is obsolete. Caching reduces this, but public `refresh=1` bypasses answer and line-up caches.

The iOS board permits five days ahead (`BoardModel.maximumDaysAhead`); the currently published Darwin dates do not cover that. A Darwin-only migration needs either a longer-range timetable source or a deliberate reduction in planning scope. Even tomorrow must be checked for full 03:00–02:59 coverage, including the next day's first-train requirement.

## Prioritised findings

1. **Release gate: update vulnerable dependencies.** `package.json` pins Next 16.2.12. The registry audit recommends 16.3.6 and reports Next, Sharp, PostCSS and nanoid advisories. Windows-specific exposure does not establish exposure on Vercel; image and dependency paths need separate assessment. Upgrade in a scoped change, regenerate the lockfile, rerun audit/tests/build and verify a preview. Do not infer deployment safety from a green build.

2. **High: timetable publication is not atomic.** `lib/timetablePacking.ts:88` keys boards by station/date, without snapshot ID. `scripts/darwin-publish.mjs:224` overwrites those keys before changing metadata. Requests during a publish can read new boards with old metadata; a partial failed publish leaves a mixed store. A station/day absent from the new snapshot can retain an old board for its remaining 72-hour TTL. Write immutable snapshot-prefixed boards, validate them, then switch one metadata pointer. Readers must resolve metadata first and use that exact snapshot ID. Explicitly represent empty covered boards and distinguish missing/corrupt data.

3. **High: live freshness can be defeated by HTTP and application caching.** `app/api/v2/trains/route.ts:313` and `:631` allow up to an hour of phone caching when no live overlay is applied. A train can enter the live horizon during that interval, or Darwin can recover after a failure, without the phone contacting the server. The cache-hit path also bypasses `confirmedAgainstDarwin`, which only runs during answer construction. Fast Train's successful RTT fallback is cached by station pair/date for an hour even though its two-hour window moves with time (`app/api/v2/fast/route.ts:543`). Bound live-day response TTLs and rolling-window caches to short freshness intervals; revalidate near-term candidates independently of the long-lived schedule cache.

4. **High: Darwin calling-point cache is scoped too broadly.** Fast Train stores `toServiceCalls(service)` by service ID alone, but normalized Darwin services contain calls from the queried boarding station onward. Opening the same train at another station can overwrite the first station's detail. The detail route also advertises 12-hour public caching regardless of the entry's age or its six-hour Darwin TTL. Store a canonical complete service, or carry origin in the detail/cache key, and use remaining TTL with separate live/scheduled freshness.

5. **High before scaling: quota protection is incomplete.** RTT minute pacing is process-local; many Vercel instances can exceed the shared provider allowance. Redis-backed hour/day protection fails open, as do caller limits. Public refresh can repeatedly spend upstream quota. Introduce shared minute admission, coalesce identical in-flight requests, and constrain refresh so it refreshes live state without forcing expensive schedule reloads. Preserve cached responses during outages; refuse new paid upstream work when a reliable global budget cannot be established. Validate the account's actual limits rather than relying on old comments.

6. **Medium: stale/missing timetable can look authoritative.** The destination path accepts `stale` boards and does not expose that state. Its cached snapshot list can also be reused without testing current freshness. A missing station board becomes an empty list merely because metadata lists the date. That cannot distinguish a real no-service station from partial publication or data loss. Require coverage/empty-board evidence and return a clear unavailable/stale state.

7. **Medium: avoid unnecessary latency and request amplification.** The live Fast Train path awaits one Redis write per displayed service in a loop (`app/api/v2/fast/route.ts:440`): batch/pipeline these writes. RTT token exchange lacks a timeout and a shared in-flight promise (`lib/rtt.ts:185`), so concurrent cold requests can duplicate exchanges and stall outside the later fetch's timeout. Add bounded deadlines, coalescing and recovery tests. Profile before attempting smaller CPU optimisations.

8. **Medium: health checks are weaker than production readiness.** Timetable health tests metadata age, not current/next service-day completeness or actual readable boards, and reports HTTP 200 even when unhealthy. Redis read failure is described as an empty reachable store. Cache health uses the same ping key for all callers, allowing concurrent checks to interfere. Use unique probe keys, explicit unavailable states, readiness status codes and independent stale-feed monitoring. The ingest's health check should verify the exact newly published snapshot, not just any healthy metadata.

9. **Regression case needed: empty filtered RTT responses.** `app/api/v2/trains/route.ts:429` selects filtered results by truthiness. The RTT client maps HTTP 204 to null, so a valid empty filtered response would incorrectly fall back to the unfiltered direction. Select by whether filtering was requested. A production Upminster–Penzance probe returned an empty board correctly; this did not reproduce the 204 branch, so this finding is code-path analysis, not an observed production incident.

## Recommended implementation sequence

1. Fix dependencies, incorrect cache scopes/freshness and the filtered-empty branch. Add route-level regression tests; the existing suite largely exercises library/domain behaviour.
2. Make ingest publication atomic, validate coverage and add reliable operational health signals. Test interrupted publication, stale delivery, missing boards and rollback to the prior snapshot.
3. Make Darwin primary for Last Train only where a complete required window is proven. Preserve RTT for uncovered dates and controlled fallback. Compare both sources on representative routes, engineering weekends, overnight services, DST and split/join services before switching.
4. Remove routine RTT calls for covered Fast Train/destination windows. Measure provider calls, cache hit rates, fallback frequency, 429s and cold/warm latency; load-test representative concurrency against mocks/staging, not the live quota.
5. Decide whether five-day planning and the legacy web app remain. Only retire RTT when every remaining dependency has a tested replacement.

## External references and limits

- RTT current API specification: https://realtimetrains.github.io/api-specification/
- RTT current product plans: https://www.realtimetrains.co.uk/about/developer/ — continued commercial use should be checked against the actual account entitlement; the audit did not inspect billing or account quotas.
- National Rail identifies Darwin as its official running-information engine and documents the live and timetable feeds: https://www.nationalrail.co.uk/developers/darwin-data-feeds/

This review inspected local source and sampled production endpoints and CI. It did not verify deployment/source commit equality, sustained load, Vercel execution-region configuration, provider billing, all national route coverage or alert delivery. Successful checks establish a useful baseline, not complete production readiness.
