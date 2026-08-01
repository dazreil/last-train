# Status — handoff

Written 1 August 2026 at commit `2a770ee`. Working tree clean, `main` in sync with
origin.

---

## Where things stand

The web app is **finished, deployed and in daily use**. It answers one question —
the last train home, and the first one back — for 67 stations across c2c, the
Elizabeth line, and the Liverpool Street ↔ Shenfield corridor.

The board takes one of two arrangements, chosen by the clock in `lib/board.ts`.
Normally it is the last three trains of the service day, then the first train of the
**next** one below them — today's own first train is never shown in the evening,
because it went at dawn. Between a day's last train and the next day's first that
inverts: the first three lead, with the day's last train kept below. In both, the red
block is the genuine last train of the day on the board.

The next piece of work is a **UK-wide native iOS app**, specced in `IOS.md`. The
licensing question that used to block it is answered — see Next.

| | |
|---|---|
| Repo | `github.com/dazreil/last-train` (private) |
| Live | `https://last-train-dazreils-projects.vercel.app` |
| Stack | Next.js 16 (App Router), React 19, TypeScript, plain CSS |
| Data | Realtime Trains next-gen API, `data.rtt.io`, **free tier** |
| Tests | 70, all passing, run under `TZ=UTC` |

**`last-train.vercel.app` is not this app.** That subdomain belongs to an unrelated
Singapore MRT tracker. Use the full alias above.

---

## Commands

```bash
npm run dev          # dev server
npm run dev:lan      # dev server reachable from a phone on the same Wi-Fi
npm test             # 70 tests, TZ=UTC (that is deliberate, see Traps)
npm run typecheck
npm run build
npm run spike        # throwaway API probe; needs .env.local
npm run national     # IOS.md §9 step 2 probe; 5 requests, then cached
npm run stations     # regenerate data/stations.json + data/geo.json
```

Node was installed via Homebrew for this project (`/opt/homebrew/bin/node`, v26).
It is not on the default PATH in every shell — prefix with
`export PATH="/opt/homebrew/bin:$PATH"` if `node` is not found.

Credentials live in `.env.local` (gitignored, never committed). The token is a
**refresh** token in `RTT_REFRESH_TOKEN`; the code exchanges it for short-lived
access tokens automatically.

---

## Traps

Every one of these cost real time to find. A fresh session will otherwise
rediscover them the hard way.

### The API sends times with no timezone at all

`"2026-07-30T23:12:00"` — no `Z`, no offset. It is **London wall-clock time**. The
query echo *does* carry `+01:00`, which makes it easy to assume the rest do.

`new Date()` resolves such a string using the process timezone, so this was correct
on a London laptop and an hour late on Vercel, with every departure wrongly flagged
as after midnight. `lib/serviceDay.ts` now resolves naive strings as London
explicitly. **`npm test` runs under `TZ=UTC` so a regression fails locally too**, and
the fixtures deliberately use the timezone-less shape — `Z`-suffixed fixtures pass
under any timezone and hide this entire class of bug.

### Four more API surprises

- **`/gb-nr/service` rejects the identity a line-up gives you.** It wants
  `P67203:2026-07-31`, not `gb-nr:P67203:2026-07-31`. Flat 400.
- **Service-query locations carry no `displayAs`**, and stations a train passes
  without stopping are absent from the pattern entirely. Gating on `displayAs` there
  matches *nothing* — which fails silently, in the safe-looking direction.
- **Origin/destination pairs have no `shortCodes`**, only a description. Match by
  name, not code.
- **The Elizabeth line core is not uniformly `Z`-prefixed.** `ZFD` and `ZLW`, but
  also `BDS`, `TCR`, `CWX`. Inferring the pattern gives three wrong codes.

### Rate limits are a third of what the original brief said

Free tier is **10/minute, 100/hour, 1000/day, 10000/week**. The brief said
30/750/9000. Every budget in the app is sized against 10/minute. Do not run
`npm run stations` while testing the live app — they share the quota.

### Team tier, £29/month — the real numbers

Confirmed 1 August 2026: **40/minute, 1200/hour, 12000/day, 25000/week**, up to
**5 API keys**, 31 days history, tip-jar and ad friendly. Licence adds "permission to
incorporate in your existing products but may only publish derivative data".

**Which cap binds changes between the tiers, and that is the whole trap.** On free,
7 × 1000/day fits inside 10000/week, so the daily cap binds and 1000/day is a rate you
can actually hold. On Team, 7 × 12000 is 84000 against a 25000 weekly ceiling, so the
**weekly** cap binds — 12000/day is a burst you can spend on **two days** before the
week is gone, not a rate.

| | Free | Team | Increase |
|---|---|---|---|
| Per minute | 10 | 40 | 4× |
| Per day, headline | 1000 | 12000 | 12× |
| Per week | 10000 | 25000 | 2.5× |
| **Sustainable per day** | **1000** (day-bound) | **3571** (week-bound) | **3.6×** |

**£29/month buys about 3.6× the sustainable volume, not 12×.** Size against
`week ÷ 7`, never the daily headline, or the app works on Monday and is throttled by
Wednesday.

The 5 keys are worth taking: a separate development key retires the shared-quota trap
above, so testing the live app and running the generator stop competing with
production.

### Hobbyist at £4 does not raise the rate limits, so it cannot ship the app

Its listing offers 2 API keys, detailed mode, passenger allocations, tip-jar and ad
permission, and "for use by individuals only". **It says nothing about rate limits**,
where Team's listing states them outright — so it carries the free tier's.

That is decisive, and not on price. RTT's reason for requiring a commercial plan was
**call volume**. A tier that does not raise the volume cannot answer a volume
objection, whatever it costs. **Team is the tier**, and £29/month is the real number.

Confirmed with RTT, 1 August 2026. It was first inferred from the absence of a limits
line, and the inference was right.

The generator caches responses in `.rtt-cache/` (gitignored), so re-runs cost
nothing; the last several runs used **0 API calls**. Delete it to force a clean run.

**A cold lookup now spends two station line-ups, not one** — the first train back
belongs to the next service day, so it is a second query. Repeats cost nothing:
flipping direction at Upminster returns `x-cache: PARTIAL` with no API calls, because
both days are already cached, and a pre-service board never fetches the second day at
all. `DETAIL_BUDGET` in the route caps service queries per lookup so the worst case
stays at eight requests, which is where it was before.

### Domain rules that produce wrong answers rather than crashes

- **The service day runs 03:00 → 02:59.** A train leaving at 00:22 belongs to the
  previous calendar day. After midnight, "tonight" means yesterday's date.
- **No CRS code is ever typed by hand.** `scripts/generate-stations.mjs` resolves
  everything from the API and refuses to emit an invalid list.
- **Direction is derived, never queried.** Pairing a station with its line's terminus
  would drop eastbound services that terminate short — which is frequently the last
  one out.
- **The minimum-distance guard on direction is ~140 metres, and must stay that small.**
  It stops two places at the same spot producing a bearing out of rounding noise. It
  is not a guard against short journeys. Sizing it at 5km — which sounds right, since
  a train terminating one stop away gives a meaningless bearing — silently deleted
  every London Overground departure on the Romford branch at Upminster, 32 real
  trains, because Romford is 4.99km away. Any threshold big enough to catch
  "terminates one stop away" is big enough to delete a branch line, and it does it
  quietly.
- **The board's arrangement is decided against a real first departure**, read from
  the timetable, never a guessed hour. It differs between a Monday, a Sunday and a
  rural branch. Within a service day the mode only ever goes `pre-service → normal`,
  which is why a cached answer is checked against the boundary on read rather than
  keyed on the mode — keying on it would force a cache miss, and a miss costs an API
  call at exactly the wrong moment.
- **Between roughly 00:30 and 03:00 the page advances to the next service day.** The
  current day is still technically today's but has nothing left in it. This is a
  deliberate choice, confirmed: you lose "you just missed the 00:22" in exchange for a
  board with trains on it. Tapping back to Today is respected, not undone.

### Build environment

- `lib/*.ts` use explicit `.ts` extensions on relative imports so Node's native type
  stripping can run the tests. `allowImportingTsExtensions` is set for this.
- `server-only` is a declared dependency. It makes an accidental client import of the
  token module **fail the build** — verified, not assumed.

---

## Documents, and what each owns

| File | Owns |
|---|---|
| `PRODUCT.md` | Product truth: users, purpose, positioning, constraints. Platform recorded as **ios**. |
| `DESIGN.md` | The visual system, with machine-readable tokens in frontmatter. North star "The Departure Board". |
| `.impeccable/design.json` | Sidecar: tonal ramps, contrast measurements, motion, 8 renderable component snippets. |
| `IOS.md` | The approved spec for the national iOS app. |
| `README.md` | Setup, architecture, API contract, deployment. |

The original brief (`PROJECT.md`) and the UI design brief were supplied as
attachments and are **not in the repo** — they are in `~/Downloads/`.

Two rules from `DESIGN.md` are load-bearing and easy to break by accident:

- **Red means "this is the last train" and nothing else.** There is deliberately no
  `--danger` token. Errors, buses and alerts are all non-red.
- **Contrast is computed, never eyeballed.** The palette already changed once because
  the Union Flag red measured 2.51:1 against the blue beneath it.

---

## Next

### The blocker is cleared

RTT replied on 1 August 2026: **a free App Store app still needs a commercial plan**,
because of the number of calls it makes. Being free to the user is not the test; call
volume is.

So the plan holds — `IOS.md` already assumed a paid tier — but the app now carries a
monthly cost from its first day on the store, and that is a product decision rather
than a line item.

**The tier is Team, £29/month.** Hobbyist at £4 does not raise the rate limits (see
Traps), so it cannot answer an objection that was about volume. £348/year is the real
price of shipping this, and `IOS.md` §5's single-request lookup is now an argument
about money as well as latency.

Nothing changes about how to build: stay on the free tier throughout, exactly as
`IOS.md` §3 planned, and buy the plan at submission. The cost starts when the app
ships, not now. The current token still cannot ship either way — a token found in a
distributed app gets revoked.

### Per `IOS.md` §9

1. ~~Prove the line-up query nationally~~ — **done, `npm run national`, it passes.**
   The 23h59m window returns a whole service day at Penzance, Inverness, Upminster,
   Berney Arms and Denton alike; all 319 departures were timezone-less; Inverness
   returns all four compass directions correctly and Upminster still returns only two.
   Two things it changed are in `IOS.md` §4 and §8 — see Traps below for the one that
   nearly cost a branch line.
2. Station data: FasterRoute's Apache-2.0 UK station JSON, cross-checked against
   `/data/stops`, plus a spatial index for nearest-station
3. API route: compass directions, all four buckets from one query, drop the corridor
   machinery
4. SwiftUI app — port the service-day tests *first*, then the code
5. The widget. It is the actual reason for going native
6. Paid token, attribution, submit

### Open questions carried forward

- **Is £348/year worth it for this?** The tier question is answered; whether the app
  is worth its running cost is a separate one, and it is now a real decision rather
  than a rounding error. Tip-jar and ads are permitted on both paid tiers if it ever
  needs to pay for itself.
- **What the volume actually scales with.** Not users, and not widget refreshes:
  the app is a client of our API, which caches line-ups by `station:date`, so a
  refresh that hits a warm cache costs RTT nothing. Upstream cost is
  *distinct station-days × cache miss rate*, which makes the TTL in `lib/cache.ts`
  the lever — not the widget's refresh cadence. At a 1-hour live-day TTL a station
  watched all evening costs a request an hour, so Team's 3571/day sustainable covers
  a few hundred stations in daily use. Confirm that arithmetic against a real week
  before committing to a tier.
- Does the compass control earn its vertical space at 3–4 directions, or does the
  two-direction sliding block cover enough? Prototype before committing.
- Keep `via` nationally? Recommended to drop — it exists for one real ambiguity (c2c
  via Basildon versus the slower Tilbury loop) and it is what costs the extra
  requests per lookup. That is now a question about the monthly bill, not only
  latency.
- The app depends on our Vercel deployment being up. If that is unacceptable, the
  alternative is ingesting Darwin timetable files — a much larger project.

---

## Known and deliberately unfixed

- The From field clips a long station name at phone width. Ordinary input behaviour,
  not the truncation the design forbids; the alternatives are worse.
- `totalServices` is hidden at Liverpool Street, where the count is a lower bound
  rather than exact.
- Vercel **Deployment Protection** was enabled and had to be turned off for the
  phone to reach the app. If a future deploy starts returning a Vercel login page,
  that setting has come back on.
