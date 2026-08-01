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
  directions with actual services are offered. No north or south at Upminster
- Shows the first train of the service day and the last three, with the final one
  distinguished
- Data source: Realtime Trains next-generation API. Darwin/LDBWS cannot serve this
  product — its 2-hour window and 10-row cap structurally cannot answer "what is the
  last train tonight" when asked in the afternoon
- **The token must never reach the device.** The app talks to our API only
- Terminology in use: CRS, TIPLOC, TOC, service day, calling pattern, headcode

Explicitly undecided, and not to be invented:

- **Whether a free App Store app counts as commercial to Realtime Trains.** Must be
  confirmed in writing with them before native work starts; it can invalidate the
  plan
- **Paid tier rate limits**, which determine how hard the on-device cache must work
- Whether the `via` route label survives nationally (it exists for one real
  ambiguity: c2c via Basildon versus the slower Tilbury loop)

The current credential is personal and non-commercial. It cannot ship, and a paid
plan is a precondition of submission.

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
- 55 passing tests covering the service-day boundary, timezone resolution, direction
  classification and departure filtering
- `PROJECT.md` (original brief) and `IOS.md` (approved national/native spec)
- FasterRoute publishes an Apache-2.0 JSON of every UK station (~2,600), suitable as
  the national base list — not yet integrated

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
