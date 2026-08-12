# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Stack

SwiftUI, native. The app is a client of our own API (Next.js on Vercel), never of
the upstream rail API directly — the data licence requires the token stay
server-side. The existing Next.js web app is a prototype that proved the domain
logic, the design language and the API shape; it is not a surface anyone designs
for going forward.

## Users

The author and commuters like him: people who know their own line cold. Small and
self-selecting — this is not built to teach anyone the network.

The situation is specific and it outranks everything else. One hand, outdoors,
after dark, often hurrying, often around 23:40. Sometimes standing on a platform;
sometimes in a pub deciding whether to leave. Signal is frequently poor.

The job: **know the time of the last train home — and if it's already gone, the
first one back.**

## Product Purpose

Answers one question and refuses the rest.

Success is the answer being on screen within about two seconds of opening, and
being trustworthy enough to act on without checking somewhere else. Anything that
delays that, or introduces doubt about it, has made the product worse regardless
of what it added.

## Positioning

**It never asks where you are going.** You pick where you *are* and which way you
are heading; it shows what leaves.

That is the mechanism a journey planner cannot copy without ceasing to be one. No
origin/destination pair means no interchange logic, no fare engine, and — most
importantly — no "no direct service" dead ends, which is what an A-to-B direct-only
app degenerates into at national scale.

Journey planners answer "how do I get from A to B". Nothing answers "I am here, it
is 23:40, what have I got left". That gap is the whole product.

### Direct services only

**Decided 11 August 2026.** Every time the app shows is a direct service from the station
you are standing at. It never joins two services together, and it never suggests a change.

This is why a replacement bus from *your* station appears, badged as one, while a bus from
somewhere down the line does not. The first is a departure. The second is a connection,
and a connection is journey planning.

Say it plainly on the board: **the last direct train**. Not the last way home. The
difference matters on a night when the line is closed and buses run from further along —
the app is not hiding that service, it is declining to plan a journey around it.

### The Fast Train exception

**Approved 10 August 2026.** Fast Train asks where you are going. It is a separate mode,
and you reach it by a deliberate tap on the title.

The rule above still holds for the default surface. The board you see when you open the
app has no destination field, and it will not get one. That surface must answer in two
seconds, and a second field would cost more than it returns.

This is a change to the positioning, written down as one rather than slipped in. `IOS.md`
§11 required that.

**The dead end does not go away.** Most station pairs in Great Britain have no direct
train. Fast Train is direct-only, so it will often have nothing to show. "Nothing runs
between these two" must be believable on its own, in the same way an empty board is.
Principle 2 applies to the new mode without change.

## Operating Context

- Opened repeatedly for the same station and direction; the common case is a repeat
  of the last query, not a new one
- The lock-screen widget is intended to be the primary surface for the evening use
  case — glanceable without opening anything
- UK National Rail network, all operators
- **The rail service day runs 03:00 to 02:59.** A train leaving at 00:22 belongs to
  the previous calendar day's service. After midnight, "tonight" still means
  yesterday's date. This is a fact about railways, not a display preference, and
  the product reasons in service days throughout
- Departure times arrive from the API with **no timezone marker at all**; they are
  London wall-clock times. Resolving them against a runtime's local clock is a
  known production defect, already hit once

## Capabilities and Constraints

**Direct departures only.** Never journeys requiring a change — not deferred, not
planned, out of scope permanently.

- Query is station + compass direction (north/east/south/west), context-aware: only
  directions with actual services are offered. Most stations have two; Inverness has
  four. Availability is read from the timetable, never assumed — see the Upminster
  correction below
- Shows the last three trains of the service day, the final one distinguished, and
  below them the first train of the **next** service day — the "if I miss it" answer.
  Today's own first train is never shown in the evening; it went at dawn
- Between a day's last train and the next day's first, that arrangement inverts: the
  first three trains lead, with the day's last train kept below them. Nothing is left
  to catch, so the useful answer is what is coming, not what has gone
- **Availability is counted, never assumed.** This document previously stated that
  Upminster has no northbound or southbound service. It has 16 southbound departures
  on a weekday, down the Ockendon branch to Grays — invisible for as long as the app
  offered only east and west, because they were being folded into one of the two. A
  hand-written list of a station's directions will be wrong, and wrong in the
  direction of hiding trains
- Data source: Realtime Trains next-generation API. Darwin/LDBWS cannot serve this
  product — its **120-minute window** structurally cannot answer "what is the last train
  tonight" when asked in the afternoon. The binding limit is the window, not the row
  count: `numRows` reaches 149 on a plain board and is capped at 10 only with calling
  points, and no row count reveals a 23:47 departure at 14:00. Darwin's *timetable
  files* are a different matter and remain the fallback — see `IOS.md` §2
- **The token must never reach the device.** The app talks to our API only
- Terminology in use: CRS, TIPLOC, TOC, service day, calling pattern, headcode

**Settled in writing with Realtime Trains, 1 August 2026: a free App Store app still
needs a commercial plan.** Being free to the user is not the test — the number of
calls the app makes is. The current credential is personal and non-commercial, cannot
ship, and a paid plan is a precondition of submission. The app therefore carries a
monthly cost from its first day on the store, and that cost is a product constraint
rather than an implementation detail.

**The tier is Team, £29/month** — 40/minute, 1200/hour, 12000/day, **25000/week**,
5 keys, and a licence permitting incorporation into existing products while allowing
only derivative data to be published. Hobbyist at £4 raises no rate limits, so it
cannot satisfy a requirement that was about volume. Size against `week ÷ 7`:
3571/day sustained against the free tier's 1000, about 3.6× rather than the 12× the
daily headline implies. **That ceiling is a product constraint**: it caps how many
distinct stations can be in daily use, and the lever on it is cache lifetime, not
anything the interface does.

Explicitly undecided, and not to be invented:

- Whether the `via` route label survives nationally (it exists for one real
  ambiguity: c2c via Basildon versus the slower Tilbury loop)

## Paying for it

**Reviewed 12 August 2026. Decision: monetise nothing yet, and attack the cost instead
of chasing revenue.** The options were priced first so that the deferral is a choice
rather than a gap.

The figure to clear is **£348/year** for RTT Team, plus **~£79/year** for the Apple
Developer Program in any option needing in-app purchase — the current account is a free
personal team. Call it **~£427/year** in that case.

### Affiliate ticket sales — rejected for this app

The programmes are real: Trainline pays roughly **3% on new customers and 1% on
existing** through Partnerize, Omio quotes **2–8%** varying by market, and the
split-ticketing sellers (TrainPal, TrainSplit) pay better per booking because their
margin is a service fee rather than the fare.

**The intent is wrong, and that is structural.** Someone checking the last train home
already holds a ticket — a season, a Travelcard, or contactless, which is how c2c and
the Elizabeth line are paid for. The last-train question is *post-purchase by
definition*. At 1–3% of a £10 fare a conversion is worth 10–30p, and conversions will be
close to none.

It also costs positioning. A Buy Ticket button is the thin end of becoming a booking app,
competing with Trainline using none of its inventory, and this document's first line is
that the app never asks where you are going.

### Banner advertising — rejected

Permitted by the licence: Team is explicitly tip-jar and ad friendly. Rejected on
arithmetic and on design.

A UK iOS banner in a small utility returns roughly **£0.50–£2 eCPM**, lower once most
users decline the tracking prompt. At £1 that is ~29,000 impressions a month to clear
£29 — about **3,000 monthly active users** at one banner per open and ten opens a month.
Against that: an ad SDK, an ATT prompt, a privacy manifest, and store privacy
disclosures, on a surface whose whole design language is that one red block means one
thing, and where required RTT attribution is already competing for the space.

### A one-off unlock for Fast Train — held in reserve

The only option that fits the product, and for a better reason than willingness to pay:
**Fast Train is the mode that costs money.** Up to nine requests for a cold lookup
against one or two for a board. Gating it bills the users who drive the API spend, which
is coherent pricing rather than an arbitrary wall.

Mechanically small: one non-consumable StoreKit 2 product, an entitlement check, and a
Restore Purchases affordance that review requires. No server involvement — the gate is
client-side, and the worst case is an unlock nobody paid for, which costs a few requests.
At **£2.99** Apple takes 15% under the Small Business Program, netting ~£2.54, so
break-even against £427 is about **170 purchases a year**.

**Two honest objections, recorded so they are not rediscovered:**

1. **The cost recurs and a one-off payment does not.** 170 buyers covers year one; year
   two needs 170 new ones from a finite niche. One-off pricing front-loads revenue and
   then decays while the bill keeps arriving. It cannot be the whole plan.
2. **`IOS.md` §14 measured Fast Train's value as real but narrow** — it wins on lines
   with several endings, and wins nothing on c2c's last train. Charging for a mode that
   does nothing on the line the author uses daily is a hard sell. If it ships, price it
   at £1.99 and treat it as a tip jar with a feature attached.

### What is actually being done instead

1. **Ship on RTT Team and monetise nothing.** A thing with no users cannot be priced.
2. **A tip jar at submission** — permitted, one line in an About sheet, no ATT prompt and
   no design compromise.
3. **Run the Darwin spike** once Rail Data Marketplace access is approved. Darwin permits
   commercial use, paid apps included, free below five million requests per four-week
   railway period — a ceiling this app will never approach. If the timetable files can
   reproduce a Fenchurch Street evening, the running cost goes to roughly **£0** and this
   whole section becomes moot. See `IOS.md` §2.
4. **Keep the unlock in reserve**, for if Darwin does not work out and the app finds an
   audience.

**170 in-app purchases a year is a marketing problem; a timetable ingest is an
engineering problem.** The second one stays solved.

### Noted 12 August 2026: the journey planner is a separate app

Everything learned here — service days, the timezone-less API times, direction as a
property of the route, the station data, the arrival-ranking work in Fast Train — is
reusable in a full journey planner, and **that** is the product where ticket affiliate
revenue has matching intent, because the user is planning a journey they have not bought
yet.

**It must be a separate app, not a mode of this one.** Interchange logic, fare display
and A-to-B search are precisely what the Positioning section above refuses, and the
refusal is the reason this app can answer in two seconds. A planner also inherits the
"no direct service" dead end that Principle 2 exists to keep out of this product.

Sequenced deliberately: **this app shipped and its bugs worked out first.** The planner is
a bigger build with real competitors, and it would need a data source that supports it —
which is another argument for doing the Darwin work, since a planner needs an assembled
timetable of its own regardless.

## Brand Commitments

- Name: **Last Train**
- Visual language derived from the Great British Railways identity — flat colour
  blocks, square corners, monospaced tabular times. Held in DESIGN.md
- **Red means "this is the last train", and nothing else.** Never errors, alerts,
  operators, or emphasis. The moment it means two things it means nothing
- Visible attribution to Realtime Trains, required by their terms for any
  public-facing app. Permanent, not buried in an About sheet
- The British Rail double arrow is a protected mark. The app uses an original
  directional mark instead
- Voice: plain and factual. No transit jargon the interface does not need. An empty
  result is a real answer and is never dressed as an error

## Evidence on Hand

- Working web prototype: `github.com/dazreil/last-train`, deployed on Vercel
- Real API credentials, free tier, in `.env.local` — never committed
- `data/stations.json` (67 stations) and `data/geo.json`, generated from the API and
  NaPTAN. **No CRS code in this project was ever typed by hand**, and the generator
  refuses to emit an invalid list
- `data/national.json` (2,619 stations, the whole network) generated from RTT's
  `/data/stops` joined to NaPTAN. Three stops have no position: two rail-air
  interchanges that are not stations, and Winslow, too new for NaPTAN
- 85 passing tests covering the service-day boundary, timezone resolution, direction
  classification, departure filtering, board arrangement and nearest-station
- `PROJECT.md` (original brief) and `IOS.md` (approved national/native spec)

No user research, no testimonials, no analytics, no other users yet. Nothing may be
claimed about anyone else's behaviour.

## Product Principles

1. **One question, answered.** Anything that is not "last train home, first train
   back" is scope creep however reasonable it sounds. The refusals are the product.
2. **A blank result must be believable.** "Nothing runs that way" is an answer, and
   it is only useful if it can be trusted without a second opinion.
3. **Speed is the feature.** Two seconds to an answer beats any amount of additional
   information.
4. **Never silently drop the most important result.** The last train is why this
   exists; when uncertain, include and label rather than exclude.
5. **Assume competence.** The audience knows their line. Density and speed beat
   explanation.

## Accessibility & Inclusion

- WCAG AA on every text/background pair, established by measurement rather than by
  eye — the palette has already been changed once because a chosen red failed
- **Colour is never the only signal.** The red block carries a visible LAST TRAIN
  label as well
- Text scales to 200% (Dynamic Type on iOS) without clipping; the layout grows
  downward, never overflows sideways
- The governing scene is one hand, outdoors, after dark, in a hurry. Where legibility
  and expression conflict, legibility wins
