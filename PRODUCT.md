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
  product — its 2-hour window and 10-row cap structurally cannot answer "what is the
  last train tonight" when asked in the afternoon
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
