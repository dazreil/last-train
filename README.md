# Last Train

Answers one question: **what is the last train home, and if I miss it, what is the
first one back?**

An iOS app for the whole of Great Britain — 2,619 stations, every operator, direct
services only. Pick where you are and which way you are heading; the board shows the last
three trains of the service day, the last one in red, and the first train back.

This repo holds two things:

- **`ios/`** — the SwiftUI app, its widget and Live Activity, and `LastTrainCore`, the
  domain logic as a Swift package. This is the product.
- **Everything else** — a Next.js project on Vercel that is the app's API. It holds the
  data credentials, which must never reach a phone, and caches every answer in shared
  Redis. It also serves the site at `/`: home, privacy and support; see *The site*.

Current state and next steps: `STATUS.md`. Product rules: `PRODUCT.md`. Visual system:
`DESIGN.md`. The iOS spec and how it was decided: `IOS.md`. The timetable store:
`DARWIN-INGEST.md`.

---

## Running it

```bash
cp .env.example .env.local     # then fill it in, see below
npm install
npm run dev                    # the API on localhost:3000
npm test                       # under TZ=UTC, deliberately
```

The iOS app is an XcodeGen project. `project.yml` is the source; the `.xcodeproj` is
generated and gitignored.

```bash
cd ios && xcodegen generate && open LastTrain.xcodeproj
cd ios && TZ=UTC swift test
```

A Debug build talks to `localhost:3000`, so run `npm run dev` first; a Release build
talks to the deployment. Putting it on a real iPhone has four traps, written up in
`STATUS.md`.

### Environment

In `.env.local` locally, and in Vercel's project settings for the deployment. Never in
the repo, never in the app.

| Variable | For |
|---|---|
| `RTT_REFRESH_TOKEN` (or `RTT_ACCESS_TOKEN`) | Realtime Trains, Team tier. Last Train's whole-day board. |
| `DARWIN_LDBWS_KEY` | Darwin live departures, Fast Train's first two hours. |
| `KV_REST_API_URL`, `KV_REST_API_TOKEN` | Shared Redis: the cache, the rate-limit counters and the timetable store. |
| `DEBUG_DIAGNOSTICS=1` | Optional. Adds quota and cache detail to responses. |

`lib/rtt.ts` is `server-only`, so importing it from client code fails the build rather
than shipping the token.

---

## The API

The app talks to these and nothing else.

| Route | Answers |
|---|---|
| `GET /api/v2/trains?from=UPM&direction=east&date=…` | The Last Train board, with which of the four directions have trains. |
| `GET /api/v2/fast?from=UPM&to=SOC&date=…` | Fast Train: every direct train A to B with its arrival. `&later=1` for the 2–4 hour window. |
| `GET /api/v2/destinations?from=UPM[&direction=east]` | Every station reachable directly, for the picker. |
| `GET /api/v2/service?id=…` | One train's calling points, for the sheet behind a tap. |
| `GET /api/timetable-health` | Age and coverage of the Darwin timetable store. |
| `GET /api/cache-health` | Whether shared Redis answers. |

Every error is `{ error }` with a sentence, and the app shows that sentence as it is.

**Where the data comes from:**

| | Source |
|---|---|
| Last Train, whole service day | Realtime Trains line-up |
| Fast Train, 0–2 hours | Darwin LDBWS, live |
| Fast Train, 2–4 hours; destination lists | Darwin timetable store, published nightly by `.github/workflows/darwin-ingest.yml` |
| Popular destinations | `data/popularity.json`, from the ORR origin–destination matrix |
| Stations | `data/national.json`, generated from RTT and NaPTAN; never hand-edited |

**Protection.** `middleware.ts` refuses `/api` on any old deployment URL, and limits each
caller to 60 requests a minute and 600 an hour. `lib/rtt.ts` caps total RTT spend at 400
an hour and 3,000 a day, so the weekly quota cannot be drained. Both limits fail open if
Redis is down. Numbers and reasons are in `lib/limits.ts` and `STATUS.md` *Exposure*.

### Generated data

```bash
npm run national:data        # data/national.json, and the copy bundled in the app
npm run national:adjacency   # data/adjacency.json, direction waypoints (IOS.md §13)
node scripts/generate-popularity.mjs --file <ODM csv>   # data/popularity.json, each December
npm run darwin:publish -- --file ~/Downloads            # the timetable store, by hand
```

---

## The site

`/`, `/privacy` and `/support`: what the app is, the privacy policy and the support page,
which the App Store asks for by address. Static pages in `app/`, sharing `app/site.tsx`.
The contact address is `CONTACT_EMAIL` there. The privacy page makes claims about the code;
change the code in a way that touches one, and change the page with it.

The 67-station web prototype that used to live at `/`, with its own `/api/trains`, was
removed on 25 September 2026. It proved the domain rules, the design and the API shape
before the iOS app existed. `public/sw.js` is now a worker that unregisters itself, so a
phone that saved the old board to its home screen stops showing a cached copy; delete it
after a few months. The prototype is in git history before that date.

---

## Notes that still hold

### Domain rules worth knowing before changing anything

These are the things that produce **wrong answers** rather than obvious crashes.
There are tests for all of them in `lib/*.test.ts`.

**The service day runs 03:00 → 02:59.** The last train from London is usually
after midnight, on the next calendar date. At 00:20 on Saturday, "tonight" still
means Friday's service. Query naively for "today" and you drop the single most
important result in the app. `currentServiceDate()` handles the boundary; the UI
says "Tonight" rather than "Today" when the London clock is past midnight.

**Always query the specific date.** Never a generic weekday timetable. Sundays
and engineering weekends are wildly different, and getting this wrong is the one
failure mode that makes the app actively harmful rather than merely broken.

**Direct services only.** These are trains you can board here, going where they
are going. Nothing plans an interchange, so a journey needing a change never
appears.

**An empty result is a valid answer.** Shown plainly and calmly, never as an
error. The app is only useful if a blank result can be trusted to mean something
real. Empty results on a Sunday morning out of Liverpool Street are usually a real
engineering closure.

**The route is part of the answer.** More so than when a destination was chosen,
not less. From Fenchurch Street, "east" mixes the Basildon main line with the
Tilbury loop, which can be 20+ minutes slower — and only one of them goes anywhere
near Grays. Hence `23:52 Shoeburyness · via Tilbury`. The `via` label is derived
from the stretch ahead of you, so a marker the train passes before you board, or
after you would get off, is ignored.

**Southend is two railways.** Southend Victoria is Greater Anglia from Liverpool
Street; Southend Central and East are c2c from Fenchurch Street. Same town,
different London terminus, no relationship. They are never merged by place name —
nothing in this codebase groups stations by place at all.

---

### Deploying

Vercel, free tier. Import the repo, then:

1. Add `RTT_ACCESS_TOKEN` (or `RTT_REFRESH_TOKEN`) and `RTT_API_VERSION` as
   environment variables in the project settings, for all environments.
2. Set the function region to London (`lhr1`) in project settings — the API is
   UK-hosted, and it shaves a round trip off every uncached lookup.
3. Commit `data/stations.json` and `data/geo.json`. They are generated, but they
   are also build inputs.

The token belongs only in Vercel's environment variables. Never in the repo,
never in a client bundle. `lib/rtt.ts` is marked `server-only` so an accidental
client import fails the build rather than shipping the token.

---

### Things the live API does that the spec does not mention

All four were found by running against it, and each would have failed silently or
confusingly:

**Departure and arrival times carry no timezone at all.** Not `Z`, not an offset —
literally `"2026-07-30T23:12:00"`, and it means London wall-clock time. (The query
echo *does* come back with `+01:00`, which makes it easy to assume the rest do too.)

`new Date("2026-07-30T23:12:00")` resolves a string like that using whatever timezone
the process is in. On a laptop in London that is correct by luck; on a server running
UTC — which is what Vercel does — every departure reads an hour late and gets wrongly
flagged as after midnight. `lib/serviceDay.ts` therefore interprets naive strings as
London explicitly and never relies on the runtime clock, and `npm test` runs under
`TZ=UTC` so the mistake cannot come back unnoticed.

Test fixtures matter here: `Z`-suffixed instants are unambiguous and pass under any
server timezone, so fixtures written that way hide this class of bug entirely. The
tests use the timezone-less shape the API really sends.

**`/gb-nr/service` rejects the identity a line-up hands you.** Line-ups return
`gb-nr:P67203:2026-07-31`; the namespaced endpoint wants `P67203:2026-07-31`. Passing
it through verbatim is a flat `400`. Only `/rtt/service` takes the namespaced form.

**Service-query locations carry no `displayAs`, and omit passes entirely.** A location
line-up populates `displayAs`; `/gb-nr/service` does not, and stations a train runs
through without stopping are simply absent from the pattern. Gating on `displayAs`
therefore matches *nothing* — which fails in the safe-looking direction, quietly
making every train appear off-corridor. The scheduled call type does the work
instead, and `displayAs` is treated as a veto only when present.

**Origin and destination pairs have no `shortCodes`.** Only a `description`. So
"is this train bound somewhere in scope?" has to be answered by name, not by code.

**The Elizabeth line central section is not uniformly `Z`-prefixed.** Farringdon is
`ZFD` and Whitechapel `ZLW`, but Bond Street is `BDS`, Tottenham Court Road `TCR` and
Canary Wharf `CWX`. Inferring the pattern would have produced three wrong codes; the
spec's instruction to look them up was right.

### Data source

[Realtime Trains](https://www.realtimetrains.co.uk) next-generation API, built
against the [published
specification](https://realtimetrains.github.io/api-specification/) (v2.0),
`https://data.rtt.io`. Not `api.rtt.io`, which is deprecated and shuts down on
30 September 2026.

Rate limits on the free personal tier are **10/minute, 100/hour, 1,000/day,
10,000/week** — a third of the figures quoted in the original project spec, so check
the portal rather than trusting the spec here. Every budget in the app is sized
against the per-minute limit, which is much the tightest:

- A lookup costs one line-up plus at most seven service queries, and everything is
  cached for hours. Away from Liverpool Street it is one line-up plus four.
- The line-up is cached separately from the answer, so East then West is one call.

The token's entitlements, namespaces and history restriction are printed by
`npm run spike`, and every response's remaining allowance is logged as it goes.

Non-commercial, single user. If colleagues start relying on this operationally,
RTT's terms need revisiting — that is a conversation with RTT, not a code change.
