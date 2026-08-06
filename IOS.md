# Last Train — UK-wide iOS app

A spec for taking the existing app national and native: every UK station, compass
directions, SwiftUI, App Store.

Written against the working web app, which stays as-is until this ships.

---

## 1. Scope, and what it deliberately excludes

**The app answers one question: what is the last train home, and if you miss it,
what is the first one back?**

It is a departure board with first-and-last framing. It is **not** a journey
planner, and will not become one. There are many good journey planners; there is
no good answer to "I am standing here at 23:40, what have I got left". That gap is
the entire product.

Concretely, out of scope for good:

- Journeys requiring a change. Not "later" — not at all.
- Fares, tickets, seat reservations, platforms-as-a-service, live disruption feeds
- Destination search. You pick where you *are*, not where you are going.

This is a narrowing from the previous draft, and it is the right call. It removes
the largest risk in the project: at national scale most station *pairs* need a
change, so an A→B direct-only app would have answered "no direct service" to most
questions. Asking "what leaves here, going that way" never has that failure mode.

| | Now | Then |
|---|---|---|
| Coverage | 67 stations, 3 operators | ~2,600 stations, all operators |
| Query | station + east/west | station + compass direction |
| Client | Next.js PWA | SwiftUI, App Store |
| Licence | personal, non-commercial | paid — see §3 |

---

## 2. The data source decision

**Stay on Realtime Trains and pay for it.** Everything else is worse for this
specific app, and I checked.

| Source | Whole service day? | Licence for a distributed app |
|---|---|---|
| **RTT next-gen** (current) | ✅ 23h59m window in one query | ✅ paid tier, £4–29/mo |
| Darwin **LDBWS** | ❌ **2h window, 10 rows** | ✅ free |
| Darwin **timetable files** | ✅ (after building an ingest) | ✅ free |
| National Rail **OJP** | ✅ | ❌ signed licence, not self-serve |

### Why not Darwin/LDBWS, despite being free and official

It is the obvious choice right up until you read the parameter limits. LDBWS is a
**departure board**, not a timetable: `timeOffset` ±120 minutes, `timeWindow` 120
minutes, `numRows` **10**. It tells you what leaves in the next two hours.

Ask it at 14:00 what the last train tonight is and it structurally cannot answer.
That is the entire product, so LDBWS is out. This is the single most important
finding in this document.

### Why RTT

One query returns a **whole service day** at a station. That is the only thing
this app needs, and RTT is the only source that provides it without either a
two-hour ceiling or building a timetable database.

Note that the narrowed scope in §1 means we no longer need `filterTo` either. We
need exactly one endpoint: the station line-up. Which makes the request budget
almost trivially small — see §5.

### The fallback, if RTT ever says no

Darwin timetable files: free, whole-day, but bulk XML that must be ingested into
our own timetable database, reimplementing schedule assembly (associations,
splits, STP overlays) that RTT already does. A rail-data project with a train app
attached. Only worth it if §3 fails.

---

## 3. Licensing, and the debug/production split

**The current token cannot ship.** It is personal, non-commercial, and the terms
are explicit that a token found in a distributed application gets revoked.

The plan you've chosen — free tier while building, paid before publishing — is
right, and the code should make the switch a non-event.

### How the switch works: it doesn't

**Do not build a `FREE` / `PAID` mode flag.** RTT returns the actual limits on
every response:

```
X-RateLimit-Limit-Minute / -Hour / -Day / -Week
X-RateLimit-Remaining-Minute / -Hour / -Day / -Week
```

Read those and adapt. Then switching plans is swapping one environment variable,
and there is no mode flag to forget to flip on release day. A hardcoded tier is a
bug waiting for the worst possible moment.

### What debug mode actually is

A **diagnostics surface**, not a different code path:

- Current remaining quota on all four dimensions, live from the last response
- Requests spent on the last lookup, and whether it was a cache hit
- The resolved service date and query window, so a wrong answer is traceable
- Which token is loaded — free or paid — **never the token itself**

Gated behind an env var on the server (`DEBUG_DIAGNOSTICS=1`) and a hidden gesture
in the app, e.g. long-press the masthead. Ships disabled.

### Three things true before submission

1. **A paid plan. Confirmed in writing with RTT, 1 August 2026: a free App Store app
   still needs a commercial one**, because of the number of calls it makes. Being
   free to the user is not the test; call volume is.

   **Team, £29/month: 40/minute, 1200/hour, 12000/day, 25000/week**, 5 API keys,
   31 days history, tip-jar and ad friendly, "permission to incorporate in your
   existing products but may only publish derivative data".

   Size against `week ÷ 7`, never the daily headline. Which cap binds differs between
   the tiers: on free, 7 × 1000/day fits inside 10000/week, so 1000/day is a rate you
   can hold; on Team, 7 × 12000 is 84000 against a 25000 ceiling, so 12000/day is a
   burst worth **two days** before the week is gone. Sustainable is **3571/day against
   free's 1000 — about 3.6×, not the 12× the daily figures imply**.

   **Hobbyist at £4 is not an option**, and not on price. It offers 2 keys, detailed
   mode, allocations, monetisation permission and "for use by individuals only", and
   **carries the free tier's rate limits — confirmed with RTT**. They required a
   commercial plan *because of call volume*; a tier that does not raise volume cannot
   answer that. £29/month, £348 a year, is the real price of shipping.

   Take the 5 keys. A separate development key means testing never competes with
   production for quota, which on the free tier it does.
2. **The token still never reaches the device**, paid or not. The app talks to our
   API, never to `data.rtt.io`. See §5.
3. **Visible attribution** — RTT require clear credit with a link in any
   public-facing app. Permanent, not buried in an About sheet.

---

## 4. Compass directions, context-aware

East/west was right for three linear corridors. Nationally it needs all four, and
it needs to know which ones are real.

### Classification: bearing, not longitude

**Built — `ios/Sources/LastTrainCore/Direction.swift`.** The web app compares
destination longitude against the station's, which works on three corridors running
broadly east–west and fails the moment the network does anything else. The native
code takes the **bearing** from station to destination, bucketed into four 90°
sectors centred on the cardinal points:

| Sector | Direction |
|---|---|
| 315°–45° | North |
| 45°–135° | East |
| 135°–225° | South |
| 225°–315° | West |

Boundaries belong to the clockwise sector — exactly 45° is east, exactly 315° is
north. Which side they fall on matters far less than that it is stated and tested.

`Direction.tally` returns the counts for all four directions **and** the number it
could not classify, so a service with no coordinate for its destination is visibly
absent rather than quietly folded into a bucket.

This behaves sensibly on real journeys — now measured rather than asserted, see §9
step 2. Inverness is the proof: Wick reads north, Aberdeen east, Edinburgh south and
Kyle of Lochalsh west, all four out of one line-up. Across the probe stations the
narrowest margin to a sector edge was 10.9°, so nothing sat on a boundary waiting to
flip.

**The minimum-distance guard must stay tiny — about 140 metres, as `lib/direction.ts`
already has it.** It exists so two places at the same spot cannot produce a bearing
out of rounding noise. It is *not* a guard against short journeys, and the difference
is not academic: a first pass at the probe used 5km, on the reasonable-sounding logic
that a train terminating a couple of stops away gives a meaningless direction. It
silently deleted all 32 London Overground departures on the Romford branch at
Upminster, because Romford is 4.99km away. **Any threshold big enough to catch
"terminates one stop away" is big enough to delete a branch line**, and it does it
quietly, in the safe-looking direction.

Destination bearing, not next-calling-point bearing — it matches how a passenger
thinks about which way a train is going.

### Availability comes free with the query

A station must not be offered a direction nothing runs in — at a terminus like
Penzance, three of the four are empty and always will be.

**Correction, 4 August 2026.** This section used to say "at Upminster, north and south
have no services and must not be offered." That was wrong, and it is worth
understanding why, because it is the case the compass was built for.

Upminster has **16 southbound departures on a weekday**, down the Ockendon branch to
Grays. The 07:02 calls at Ockendon, then Chafford Hundred, then Grays — every one of
them south and slightly east. The claim survived because the web app only ever offered
east and west, so those trains were being folded into one of the two and nobody
noticed a whole branch line had no direction of its own.

The lesson is not about Upminster. It is that **a hand-written list of which directions
a station has will be wrong**, and wrong in the direction of hiding services. That is
why availability is counted from the line-up on every query rather than stored.

Do not precompute this. **The unfiltered line-up already contains every service at
the station**, so classifying them into four buckets yields the available
directions as a by-product of the query you were making anyway. The response
returns counts for all four directions and services for the selected one.

The client caches availability per station effectively forever — track topology
does not change week to week — so a station visited before shows the right
controls instantly.

This replaces the `onward` field currently generated by sampling calling patterns,
which does not scale to 2,600 stations.

**A direction now merges unrelated branches, and that is intended.** Measured at
Upminster: "west" holds c2c to Fenchurch Street at 257° *and* the London Overground
shuttle to Romford at 291°. Two different railways, one button. It is the honest
answer to "what leaves here going that way", and separating them would mean
reintroducing exactly the corridor machinery §5 deletes. The destination is on every
row, so the difference is visible where it matters — but note that "last train west"
at such a station is the last of a merged set, and may well be a train the passenger
had no interest in. Watch for it at multi-branch stations before assuming it reads
well.

### The control: chevron quadrants

**Decided 4 August 2026, after prototyping six arrangements against the fold.** Both
halves of the previous proposal turned out to be wrong, so it is worth recording what
replaced them and why.

A 2×2 grid. Each block is clipped into a chevron pointing the way its trains go, and
carries the direction word above `towards <destination>` — the same line the sliding
block already shows. **The shape says which way, so the position does not have to.**
That is what makes four directions fit in two rows.

```
   ┌──────────────┐┌──────────────┐
   │  ▲  NORTH    ││  ▶  EAST     │
   │  towards Wick││ towards Aberdeen │
   └──────────────┘└──────────────┘
   ┌──────────────┐┌──────────────┐
   │  ▼  SOUTH    ││  ◀  WEST     │
   │towards Edinburgh││ towards Kyle of Lochalsh │
   └──────────────┘└──────────────┘
```

- **Order is north, east, south, west** in reading order — compass order. A 2×2 cannot
  be geographically faithful, so it matches the order directions are listed in
  everywhere else rather than inventing a second one.
- **A direction with no services goes black**, to `--ink`, so it reads as a hole in the
  control rather than a disabled button. The word stays: "nothing runs north" is a real
  answer and has to be legible as one.
- **No service count.** The number was never the question. `east` only means something
  once you know where east goes, which is what the `towards` line is for.
- **Not red.** Obvious, and worth writing down anyway, because a four-block control is
  exactly the sort of thing that invites a colour. Red means the last train and nothing
  else; spend it here and the red block downstairs stops meaning anything.

### Why not the compass, and why not the slider

Measured at 375×667, the smallest phone still supported, with all four directions:

| Arrangement | Control height | Last train |
|---|---|---|
| Sliding block | 90px | clears the fold |
| Compass cross | 169px | **41px below the fold** |
| Four across | 73px | clears the fold |
| **Chevron quadrants** | **118px** | **clears the fold** |

**The compass is out.** Its middle row is mostly a dead hub, and the third row costs
enough to push the red block under the fold on an SE. Dropping empty arms helps only at
the stations that have an empty arm, and makes the control change height between
stations — which moves it under the thumb of someone who opens this app for the same
journey every night.

**"Keep the slider where a station has two directions" does not survive contact with
the network.** It assumes two directions means an *axis*, and usually it does not:
**Penzance runs north and east; Denton east and south.** Perpendicular pairs. A control
whose entire idea is left-versus-right cannot express either of them. Of the stations
probed, only Berney Arms is a genuine axis.

Four across is cheaper still — and cheaper than today's slider — but it throws away the
one idea worth keeping. North sitting left of east means nothing.

### What the prototype also settled

- **`towards` fits.** At Inverness, the worst case here, every block is 58px and the
  control is 118px. `towards Kyle of Lochalsh` wraps to two lines and the row grows to
  hold it, exactly as the **Real Length Rule** in `DESIGN.md` requires. Names are never
  ellipsised.
- **`via` must not be borrowed for this.** It already names a station a train passes
  *through* — the whole reason the label exists. `via Grays` would read as a train
  carrying on past Grays when it terminates there. If `towards` ever needs trimming, the
  bare name is the safe cut: the block already says NORTH.
- **200% Dynamic Type does not decide anything.** Every arrangement loses the fold at
  200%, including the one shipping today, by 379px. That budget is already gone and
  cannot be used to choose between controls.

Prototype: `direction-control.html`, six arrangements, real availability and departures
from `/api/v2/trains`, every number measured from the rendered page.

---

## 5. Architecture

```
SwiftUI app  ──►  our API (Vercel)  ──►  Realtime Trains
   bundled            holds the token         paid plan
   stations           caches aggressively
```

The app is a client of our own API, not of RTT. Forced by §3, with consequences
worth stating: the app needs our server up, so the Vercel deployment is
infrastructure rather than convenience, and cached answers make it feel
offline-ish without making it offline.

### The narrowed scope makes this very cheap

One lookup is **one API request** — a single station line-up for the service day,
which is then split four ways and cached. Compare with the current app's up-to-
eight, and note what §1 deleted:

- No operator scope filter. Nationally every operator is in scope by definition.
- No corridor membership check, no `corridorDestinations`, no `servesScopeAhead`.
  Those existed to keep Cambridge trains out of a three-operator app; now a
  Cambridge train from Liverpool Street is simply a northbound train.
- No `filterTo` pair queries.

**Recommend dropping the `via` route label for v1.** It existed for one real
ambiguity — c2c via Basildon versus the slower Tilbury loop — and it is what costs
the extra four requests per lookup. Nationally, with the destination shown on every
row, it earns much less. Dropping it takes a lookup to a single request, which
makes the free tier's 10/minute comfortable for development.

### Caching matters more, not less

67 stations produced few distinct cache keys; 2,600 produce a long tail where most
queries miss. Cache server-side by `station:date` as now — note the key loses its
direction component, since one query serves all four — and cache on the device too,
which is what makes the widget viable.

---

## 6. Station data

**Done, 1 August 2026 — `npm run national:data` writes `data/national.json`, 2,619
stations.** `stations.json` and `geo.json` are untouched; the web app stays as-is.

### FasterRoute is not needed after all

The earlier plan was FasterRoute's Apache-2.0 JSON as the base list, cross-checked
against `/data/stops`. Measured, it earns nothing: **RTT's own `/data/stops` is the
list, and NaPTAN alone places 2,619 of its 2,622 stops.**

`/data/stops` is the right base rather than a cross-check, because it is *by
definition* what the token can query — a station in FasterRoute but not here is a
station the app cannot answer for. It carries no coordinates, only namespace,
description, `shortCode` and `uniqueIdentity`, so position comes from NaPTAN via
`/data/locations_ungrouped`, which supplies the TIPLOC to join on.

That join needs three passes, and the first alone silently misses the busiest
stations in Britain. `scripts/lib/naptan.mjs` has the detail; in short, NaPTAN splits
large stations into platform groups under suffixed codes, so `WATRLOO` is `WATRLMN`
and `CLPHMJN` is five separate rows — Waterloo, Victoria, London Bridge, Clapham
Junction and Vauxhall all need the name fallback. Six more, the Elizabeth line core,
carry `0,0` for latitude and longitude but a real OS grid reference.

Matching by name is only safe because it was checked: across every station where both
the code and the name route resolve, they never disagreed by more than 500m. The
generator asserts that on every run.

**Three stops have no position, and that is the whole gap:**

| CRS | | |
|---|---|---|
| `XPB` | Bristol International Airport | a rail-air interchange, not a rail station |
| `XMT` | East Midlands Airport | a rail-air interchange, not a rail station |
| `WNO` | Winslow | reopened on East West Rail, not yet published by NaPTAN |

Two of those are not stations. Taking on a third-party dependency for the third is
not a trade worth making, so the generator names them and refuses to emit if a
*fourth* ever appears.

**The existing rule stands: no CRS code is ever typed by hand.** The generator
validates before writing — every coordinate inside Great Britain, every CRS unique,
no two stations within 25m of each other, the name and code joins in agreement, and
the gap list exactly as expected.

### What breaks at 2,600 stations

- ~~**Nearest-station** is a linear haversine scan.~~ **Done — `lib/nearest.ts`.**
  Bucketed by rounded lat/lon at 0.1°, with ring-by-ring expansion outward. The part
  that matters is the stopping rule: searching the 3×3 block around the query and
  stopping is wrong whenever the nearest station is just over a cell boundary, so
  each ring is followed by a proof that nothing unsearched could be closer. The bound
  uses the smallest kilometres-per-degree in play, because a degree of longitude is
  71km at Penzance and 57km at Wick.

  **80× faster than the scan where a phone actually is**, 7µs against 560µs. Over a
  box that includes open sea it is only 3–4×, because empty rings grow as the square
  of their radius; once more cells have been probed than there are stations it gives
  up and scans, which bounds the worst case. Tested by agreeing exactly with a full
  scan from several thousand positions across Britain, beside every station, and at
  both latitude extremes.
- **Search must disambiguate.** Two Newports, several Ashfords, Whitchurch in
  three counties. Show county or operator on collision, and rank by size — nobody
  typing "birmingham" wants Birmingham International first.

  `national.json` carries NaPTAN's `locality` and `town` for this, populated for 732
  and 84 stations respectively — enough to separate collisions, not enough to rank
  by size. **Ranking still has no data source.** Passenger-entry counts are published
  by ORR annually; that is the obvious candidate and is not yet in the repo.
- **Cities are not stations.** London has ~18 terminals; Glasgow, Manchester,
  Birmingham, Leeds and Edinburgh have several each. Typing "Manchester" offers
  Piccadilly *and* Victoria rather than guessing.

---

## 7. The native app

### What justifies going native

Not the App Store listing. **The widget.** Last train home on the lock screen,
updating through the evening, is precisely this app's use case and is impossible in
a PWA on iOS. If one native feature ships, it is that one.

Then App Intents ("Siri, when's my last train home?"), and Core Location without a
permission prompt every session.

A wrapped web view would also risk rejection under the minimum-functionality
guideline. Native sidesteps it.

### Port, don't redesign

The design is settled:

- Full-bleed blocks, zero radius, zero gaps
- **Red means last train and nothing else.** `#E4002B`, not flag red — chosen by
  measurement against the blue beneath it. Keep the visible `LAST TRAIN` label;
  colour is never the only signal.
- Mono tabular times as the largest thing on screen
- Operator as a white outline, never a filled brand colour

Use Dynamic Type rather than fixed sizes — the native equivalent of the 200% font
test the web app already passes.

### Reimplement carefully

The **service day** logic: the 03:00 boundary, "tonight" versus "today" after
midnight, and London wall-clock times arriving with no timezone marker at all.
Port the tests first, then the code.

Set the timezone explicitly on every Swift formatter. The web app's hour-late
production bug came from trusting a default; a rewrite is exactly where that
returns.

---

## 8. Domain rules that get harder nationally

The existing rules still apply. These are new:

**Sleepers cross the service day mid-journey.** The Caledonian Sleeper leaves
Euston around 21:00 and reaches Inverness after 08:00. Nothing in the current
three-operator world does that, so the 03:00 boundary now falls *inside* journeys.
It belongs to its origin's service day; the display has to make the arrival day
obvious without reintroducing calendar-day thinking.

**Splits and joins matter more.** A train can carry two destinations and divide en
route, and boarding the wrong half is a real failure. The API returns both — keep
surfacing both, and consider whether joining with "&" is clear enough at scale.

**Replacement buses become routine**, especially at weekends. Already badged.

**Rural is the best case, not the edge case.** A station with four trains a day is
where "last train home" matters most and where a wrong answer costs most. Test
against Berney Arms or Denton, not only high-frequency commuter routes where being
wrong is cheap.

Measured, §9 step 2: **Berney Arms had three boardable departures all day and exactly
one of them westbound.** Denton had two, one in each direction. So at a rural station
a direction's "last three trains" is routinely **one** train — and that train is
simultaneously the first and the last of its service day. That is not a hypothetical
edge case to handle later; it is the ordinary shape of a rural board, and the
first/last de-duplication in `lib/board.ts` is load-bearing there rather than
defensive. Denton's entire service day spans 34 minutes, so from mid-morning onward
its board is nothing but trains that have gone — which makes the spent-day handling
matter far more nationally than it ever did in Essex.

---

## 9. Build order

1. ~~**Email RTT.**~~ **Answered, 1 August 2026.** A free App Store app needs a
   commercial plan; call volume is the test, not price to the user. Everything below
   is unblocked. What remains is which tier, which follows from volume.
2. ~~**Prove the line-up query nationally.**~~ **Done, 1 August 2026 —
   `scripts/national.mjs`, `npm run national`. It passes.** Penzance, Inverness,
   Upminster, Berney Arms and Denton, a whole service day each, 5 requests.

   - **The window works everywhere.** Spans of 16h08 at Penzance, 18h19 at Inverness,
     20h02 at Upminster. Not one departure fell outside 03:00–02:59, and nothing was
     truncated or paginated. The one query really does return a whole service day
     anywhere on the network.
   - **Departure times are timezone-less nationally.** 319 boardable departures across
     five stations; every one of them naive. The parsing rule in `lib/serviceDay.ts`
     is not a south-east quirk.
   - **Four-way bucketing is sound.** Inverness returns all four directions from one
     line-up, with Wick north, Aberdeen east, Edinburgh south and Kyle of Lochalsh
     west. Upminster returns east and west only, which is what `PRODUCT.md` claims
     for it — so bearing classification does not invent a direction where the
     longitude comparison found none.
   - **Two things it changed:** the minimum-distance guard (§4) and what "rural"
     really means (§8).
3. ~~**Station data.**~~ **Done, 1 August 2026.** `npm run national:data` →
   `data/national.json`, 2,619 stations, generated and validated, 0 API requests on a
   warm cache. FasterRoute turned out to be unnecessary — `/data/stops` plus NaPTAN
   covers all but three stops, two of which are not rail stations. Nearest-station is
   `lib/nearest.ts`, a bucketed grid, 80× the scan where it matters and proved against
   the scan everywhere. See §6.
4. ~~**API route.**~~ **Done, 4 August 2026 — `GET /api/v2/trains`.** It lands
   *beside* `/api/trains`, which is untouched and still serves the deployed web app.

   Compass direction via `lib/compass.ts`, the TypeScript twin of `Direction.swift`;
   all four buckets from one line-up; corridor machinery and `via` both gone; the
   diagnostics surface behind `DEBUG_DIAGNOSTICS=1`.

   The two routes **share the line-up cache**, so looking at a station on the web and
   then in the app costs one upstream request rather than two. Measured at Upminster:
   the v2 lookup came back `x-cache: PARTIAL`, spending nothing.

   Verified at Inverness: `{"north":8,"east":17,"south":14,"west":4}` from a single
   query, nothing unclassified. And at Upminster, 139 westbound against the old
   route's 107 — the difference is the London Overground services the operator scope
   filter used to exclude, one of which is now in the last three.
5. **SwiftUI app.** Service-day logic and its tests first, then pickers, then the
   result stack, then the design system.

   **In progress. `ios/` is a Swift package; `LastTrainCore` imports Foundation and
   nothing else, so all of this is proved before anything needs a view.**

   - ~~Service-day logic and its tests~~ — `ServiceDay.swift`, 17 tests ported from
     the JavaScript suite test for test.
   - ~~Direction~~ — `Direction.swift`, 15 tests. The one piece here that is new code
     rather than a port.
   - ~~Board~~ — `Board.swift`, 13 tests. The two arrangements, and the guarantee that
     a pre-service board never fetches a second service day.
   - ~~Nearest~~ — `Nearest.swift`, 15 tests. The bucketed grid, reusing the haversine
     already in `Direction` rather than adding a second one.

   - ~~Bundled stations~~ — `Stations.swift`, loading `Resources/national.json` through
     `Bundle.module`. `npm run national:data` writes that copy and the API's from the
     same run, so neither is hand-maintained.

   **`LastTrainCore` is complete: 81 tests, no SwiftUI, no UIKit.** The views are done
   too, including the nearest-station button — `Nearest.swift` had been built and tested
   in this step and then left unwired for a while, which is the kind of gap a test suite
   cannot catch.
6. ~~**Widget.**~~ **Done, 5 August 2026.** The reason for doing any of this, and it
   works. Lock screen and home screen, configured on the widget itself, and the whole
   evening computed from one request. See §12.
7. **Paid token, attribution, submit.**

---

## 10. Open questions

- ~~Does a free App Store app count as commercial to RTT?~~ **Answered 1 August
  2026: yes, a commercial plan is required, on call volume rather than on price to
  the user.**
- ~~Team at £29/month, or is £4 hobbyist enough?~~ **Team. Hobbyist does not raise
  the rate limits, so it cannot answer a volume requirement — see §3.** What is left
  is whether £348/year is worth it for this app, which is a decision rather than a
  question.
- ~~**What upstream volume actually scales with.**~~ **Settled 5 August 2026, and it
  is better than this expected.** The worry was that widget refreshes would drive
  volume. They cannot: the widget fetches **once** and computes the rest of the night
  from what it already holds — see §12. What costs a request is a service day running
  out, roughly once a night per configured widget, onto a cache keyed by station and
  date that the web app shares. Still worth measuring over a real week, but the lever
  is the server-side TTL and nothing on the device.
- ~~Two-direction vs four-direction control~~ **Answered 4 August 2026: chevron
  quadrants.** The compass did not earn its space, and keeping the slider for
  two-direction stations does not work because two directions are usually
  perpendicular rather than opposite. See §4.
- **Is the server dependency acceptable?** The app cannot work without our Vercel
  deployment. If not, the answer is the Darwin ingest, which is a much larger
  project but removes reliance on someone else's uptime.
- **Do we keep `via` anywhere?** Dropping it is recommended, but the c2c Tilbury
  case was real and you use that line daily.

---

## 11. Parked for a future update — Fast Train

**Not part of this build.** Recorded so it is neither lost nor quietly reinvented as
something smaller. Nothing in §9 changes.

### The gesture

Tapping **"Last Train"** in the header switches the app into **Fast Train** mode —
the same interaction as tapping the date opposite it, which already swaps today for
tomorrow. Two taps at opposite ends of the same bar, each toggling one axis.

The name is the description: the mode ranks by how fast you get there, and it is one
word swapped in the title the tap lands on — *Last* Train becomes *Fast* Train.

### Fast Train

Same app, one addition: you enter a **from** and a **to**. It lists **four trains,
ordered by arrival time at the destination**, fastest first.

Ordering by arrival rather than departure is the entire feature. UPM→SOC: a train
leaving in a few minutes goes via Tilbury and arrives later than one leaving fifteen
minutes afterwards via Basildon. A departure board cannot show you that; this can.

In this mode the date tap changes meaning too. Instead of today/tomorrow it pages
forward — the next four trains after the four on screen.

### Last Fast Train

The third mode, unadvertised: last-train behaviour with a selectable destination,
listing the **last four trains ordered by arrival**. Usually that is the same order
as the plain last-train board; where it is not, it is the case that matters most, and
it hands over complete control.

### What has to be settled before any of this is built

1. **It asks where you are going.** `PRODUCT.md` positioning is "it never asks where
   you are going", and §1 above puts destination search out of scope for good. This
   survives that only if Fast Train is a *separate mode* behind a deliberate tap, and
   the default surface — the one that must answer in two seconds — never gains a
   destination field. That is a change to the positioning and should be written down
   as one, not slipped in.
2. **Arrival times are not in the line-up.** The single query returns departures. To
   rank by arrival at a chosen station, each service's calling pattern is needed —
   roughly a request per train shown. That runs directly against §5's one-request
   lookup and against the Team tier's ceiling in §3. **Size it before designing it**;
   it may be what decides whether the mode is affordable.
3. **Still direct-only.** Ranking direct services by arrival is not journey planning,
   as long as nothing ever proposes a change. But it reintroduces the failure mode §1
   removed: nationally, most station pairs have no direct service, so "nothing runs
   between these two" must be believable on its own (Principle 2).
4. **It resurrects `via`.** The open question about dropping `via` is now entangled
   with this — the Tilbury/Basildon ambiguity is this feature's motivating example.
   If Fast Train ever ships, either `via` comes back or the arrival time does its job
   better. Do not delete the reasoning behind it, only the code.

---

## 12. The widget

**Built 5 August 2026.** `ios/App/Widget`, an app extension embedded in the app, plus
`Glance.swift` in `LastTrainCore` with 12 tests. Four families: `accessoryRectangular`
and `accessoryInline` on the lock screen, `systemSmall` and `systemMedium` on the home
screen.

### The last train, not the next one

The whole design turns on which departure the widget leads with, and the answer is
**the last train**, held still for the entire evening. A next-train widget is a
different product; this one exists because the interesting departure is the one after
which you are walking. At 19:00, at 22:00 and at 23:52 the widget reads 00:42, even
though a train left in between. **That stillness is the feature** — a number that does
not move is a number you can trust at a glance from a pub table.

It changes exactly twice a night. Once the last train has gone the answer becomes the
first one back; and inside the pre-service window, when nothing has run yet and the
day's last train is twenty hours out, it leads with the first train instead. Both
follow the arrangement the server already chose, so no rule is restated here.

### One request buys the whole night

A `normal` board carries the last trains *and* the first one back together — which is
exactly the pair the widget switches between. So `Glance.changePoints` turns one
response into a timeline entry per remaining departure, WidgetKit is handed a schedule
rather than a reason to wake up, and the reload waits until the board has genuinely run
out. That is what settles the volume question in §10: refresh cadence is not a cost.

### It follows the app until you tell it not to

Leave a field blank and the widget tracks whatever the app is showing, live, through an
App Group. Choose a station or a direction in Edit Widget and that choice wins from then
on — which is what a lock screen widget needs, because it is set once and trusted for
months, and a Tuesday spent checking a friend's line should not silently replace your
own last train home.

**`defaultResult` is a trap, and using it was a bug.** It looks like the way to start a
widget on the station you were last looking at. AppIntents does not treat it as a
fallback: it fills the parameter in and stores the answer, so the widget freezes
whichever station happened to be current when WidgetKit first indexed the extension.
Observed on device — a widget stuck on Upminster while the app had been on Manchester
Piccadilly for some time, which is neither following the app nor a choice anyone made.
Leaving it unimplemented keeps the parameter nil and `resolved` re-reads the App Group
on every render. `suggestedEntities` still puts that station at the top of the picker,
which was the part actually wanted.

### Two things fell out of the design already being right

- **The lock screen strips colour.** Accessory families render vibrant, so
  `#E4002B` does not survive there at all. It did not need to: `DESIGN.md` never let
  red be the only signal, and the literal `LAST TRAIN` label was already carrying it.
- **No `accessoryCircular`.** A circle fits a time and nothing else, and a bare `00:42`
  with no station, no direction and no word for what it is reads as the *next* train as
  often as the last one. A widget that can be misread on a platform at midnight is
  worse than no widget.

### Verified

The simulator's widget gallery will not accept synthetic taps, so the widget was proved
by rendering all four families against a live `/api/v2/trains` response and walking the
real timeline: Upminster east held 00:42 through the departure of 23:51, turned blue at
`first train back 05:00` once it had gone, and ended at an empty board. The deep link
(`lasttrain://board?from=…&direction=…`) was driven separately and lands on the right
station and direction.

---

## Reference

- [Realtime Trains API portal](https://api-portal.rtt.io) — plans and tokens
- [RTT API specification](https://realtimetrains.github.io/api-specification/)
- [LDBWS documentation](https://realtime.nationalrail.co.uk/OpenLDBWS/) — note the
  2-hour and 10-row limits
- [Rail Data Marketplace](https://raildata.org.uk) — Darwin
- [NaPTAN](https://naptan.api.dft.gov.uk/) — DfT access nodes, Open Government
  Licence. Where every coordinate in this project comes from
- [FasterRoute](https://www.fasteroute.com/) — Apache-2.0 UK station JSON. Evaluated
  and **not used**; see §6
