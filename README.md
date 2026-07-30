# Last Train

Answers one question: **what is the first and last train out of here, going that
way?**

Pick where you are, tap **East** or **West**. At Grays, west is Fenchurch Street
and east is Shoeburyness.

Built for a phone, on a platform, in a hurry. Three operators, direct services
only: c2c, the Elizabeth line, and Liverpool Street ↔ Shenfield.

---

## Getting it running

You need an RTT next-generation API credential. Sign up at
<https://api-portal.rtt.io> (requires an RTT unified login). The free tier is for
personal, non-commercial use.

```bash
cp .env.example .env.local
```

Put your token in `.env.local` — `RTT_ACCESS_TOKEN` if you were issued a
long-life access token, `RTT_REFRESH_TOKEN` if you hold a refresh token. The file
is gitignored, and must stay that way: **a token found in a distributable app
gets revoked.**

Then, in order:

```bash
npm run spike
```

Prints every service from Liverpool Street to Shenfield tomorrow and checks that
Elizabeth line services — including the central core stations — actually appear.
Nothing downstream is worth debugging until this passes.

```bash
npm run stations
```

Generates `data/stations.json` and `data/geo.json`. Paces itself at 8 requests a
minute and 90 an hour, reading the actual remaining allowance from the response
headers, so a run takes several minutes. Responses are cached in `.rtt-cache/`
(gitignored), which makes re-runs nearly free — delete it to force a clean run.
Refuses to write anything if validation fails.

```bash
npm run dev
```

Then add it to your home screen. That is the point — one tap at 23:40.

Other scripts: `npm test` (domain logic), `npm run typecheck`, `npm run build`.

---

## How it works

```
app/page.tsx              single page, mobile-first, client-side
app/api/trains/route.ts   server-side proxy; the only thing holding the token
lib/rtt.ts                API client, marked server-only
lib/serviceDay.ts         the 03:00 service-day boundary and London time
lib/journeys.ts           departure filtering and route labelling
lib/direction.ts          east/west classification (pure, testable)
lib/geo.ts                the longitude table, server-only
lib/stations.ts           bundled station list, search, nearest-station
lib/cache.ts              cache by from:direction:date
data/stations.json        generated; never hand-edited. Client-safe.
data/geo.json             generated; longitudes + corridor destinations. Server-only.
.rtt-cache/               generator response cache, gitignored
scripts/spike.mjs         build step 1
scripts/generate-stations.mjs   build step 3
public/sw.js              service worker
```

### The API contract

```
GET /api/trains?from=GRY&direction=east&date=2026-07-28
→ { from, direction, date, towards: [...], totalServices,
    services: [ { dep, destination, via, toc, tocName, platform,
                  departsAfterMidnight, role, … } ] }
```

### Direction is derived, not queried

The obvious shortcut — pair each station with its line's far terminus, so Grays
"east" means `GRY → SRY` — is wrong, for the same reason the spec warns against
modelling "lines". Plenty of eastbound services terminate short, at Pitsea or
Southend Central, and **the last one often does**. Filtering to trains that reach
Shoeburyness would drop exactly the service you needed.

So the route asks for the station's whole line-up unfiltered, then classifies each
boardable service by comparing the longitude of where it is going against the
longitude of where you are standing. All three networks run broadly east–west, and
longitude rises monotonically along every route in scope — including both the
Tilbury loop and the Basildon main line.

That comparison needs a longitude for destinations that are deliberately *not* in
the app's own station list: the Greater Anglia trains through Shenfield carry on to
Norwich, Ipswich, Colchester and Clacton. Hence `data/geo.json`, which covers every
GB rail station and is read server-side only. A service whose direction genuinely
cannot be established is left out rather than guessed at, since a guess would put
it under an arbitrary button.

One line-up plus a service query for each of the four displayed services. Both
directions are built and cached from that single line-up, so tapping East then West
is one API call, not two — the return journey should be instant.

### Only trains that go somewhere in scope

A station line-up contains trains that leave the app's corridors entirely. At
Liverpool Street, Greater Anglia runs to Cambridge, Stansted and Enfield Town via
Tottenham Hale, touching nothing covered here.

The test is whether a service **calls at an in-scope station ahead of where you
board** — deliberately stricter than looking at its destination:

- It keeps the Colchester, Ipswich and Norwich trains that call at Shenfield. The
  spec is explicit that the last train to Shenfield is often one of these, so
  excluding them by destination would break the headline case.
- It drops a fast service that runs *through* Shenfield without stopping, which is
  as useless to you as a Cambridge train despite using the same track.

Reading a calling pattern costs a request, and at ten a minute that is a budget the
app does not have, so two things are precomputed at generation time instead:

- **`corridorDestinations`** — destination names of trains that demonstrably run
  along a corridor. Every probe line-up is filtered to a waypoint in scope, so every
  service in one calls in scope by construction; their destinations are therefore
  evidence, not assumption. Colchester, Ipswich, Clacton, Southend Victoria, Braintree
  and Witham are in; Stansted, Cambridge and Ely are not.
- **`onward`** — per station, whether the corridor continues east and/or west,
  derived from the sampled calling patterns. Shenfield is `["west"]`, so eastbound
  from there the answer is "nothing", returned without touching the API. That also
  keeps the shortcut above honest: Colchester is a corridor destination, but from
  Shenfield the corridor is behind you.

A calling pattern is only fetched for a service in neither category, walking outward
from each end and stopping once the answer is found. Anything left unverified is
**kept, not dropped** — losing the last train of the night to a failed side request
would be far worse than showing one train too many, and the destination is always on
screen.

### Never filtered by operator

Except by scope. Only c2c, Greater Anglia and the Elizabeth line are kept, which is
§1 of the spec, not the per-operator journey modelling §6 forbids — it exists to
keep London Overground out of a line-up at Barking. Within scope every operator is
merged in time order, which is exactly what is wanted:

- **Liverpool Street, eastbound** is served by both Greater Anglia and the
  Elizabeth line. Greater Anglia no longer calls at Ilford, Romford or Brentwood,
  so its Shenfield services are the long-distance trains to Colchester, Ipswich,
  Norwich, Southend Victoria and Clacton passing through — and they typically run
  later than the Elizabeth line, so the last train is often a Greater Anglia one.
- **Grays** is where the Ockendon branch and the Tilbury loop converge. One
  unfiltered line-up catches both, and the `via` label distinguishes them.

### Where the CRS codes come from

Not from a keyboard. `scripts/generate-stations.mjs` names seven corridors in
prose, resolves them against `/data/stops`, then samples real services across a
weekday and unions their calling points — bounded to the segment between each
corridor's endpoints, which is what keeps Ipswich and Norwich out of a Liverpool
Street → Shenfield harvest.

Coordinates come from NaPTAN, joined on TIPLOC (the API's `longCode`). Where
NaPTAN carries only an OS grid reference — as it does for the Elizabeth line
central core, whose stations use `Z`-prefixed CRS codes — it is converted to
WGS84, and the converter is checked against the thousands of NaPTAN rows that
carry both representations before its output is trusted.

The generator refuses to emit a partial list. No coordinates, a non-three-letter
code, a station outside the expected geographic box, an operator missing
entirely, or a route marker that does not resolve — any of these fail the run.

---

## Domain rules worth knowing before changing anything

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

## Deploying

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

## Things the live API does that the spec does not mention

All four were found by running against it, and each would have failed silently or
confusingly:

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

Coverage is **67 stations**, not the 150–200 the spec estimates: c2c is 26 and the
Elizabeth line 41, and the Liverpool Street ↔ Shenfield corridor adds nothing the
Elizabeth line does not already cover.

## Data source

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
- `npm run stations` paces itself at 8/minute and 90/hour and takes about seven
  minutes. It is roughly 50 requests, so a failed run can be retried once inside the
  hour without waiting.

The token's entitlements, namespaces and history restriction are printed by
`npm run spike`, and every response's remaining allowance is logged as it goes.

Non-commercial, single user. If colleagues start relying on this operationally,
RTT's terms need revisiting — that is a conversation with RTT, not a code change.
