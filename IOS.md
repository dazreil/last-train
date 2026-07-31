# Last Train — UK-wide iOS app

A spec for taking the existing app national and native: every UK station, a
from→to search, SwiftUI, App Store.

Written against the working web app, which stays as-is until this ships.

---

## 1. What changes

| | Now | Then |
|---|---|---|
| Coverage | 67 stations, 3 operators | ~2,600 stations, all operators |
| Query | station + direction | station → station |
| Journeys | direct only | direct only, changes later (§4) |
| Client | Next.js PWA | SwiftUI, App Store |
| Licence | personal, non-commercial | **paid — this is the blocker, see §3** |

**What does not change:** the question. First and last train, legible at 23:40,
in under two seconds. Everything below serves that or gets cut.

The west/east toggle retires. It was the right answer for three linear corridors
where "which way am I going" was the only real question; at national scale the
destination is the question, and there is no coherent "east" from Crewe.

---

## 2. The data source decision

This is the part worth reading. The short version: **stay on Realtime Trains and
pay for it.** Everything else is worse for this specific app, and I checked.

| Source | First/last of day? | Direct A→B? | Changes? | Licence for a distributed app |
|---|---|---|---|---|
| **RTT next-gen** (current) | ✅ 23h59m window | ✅ `filterTo` | ❌ | ✅ paid tier, £4–29/mo |
| Darwin **LDBWS** | ❌ **2h window, 10 rows** | ✅ `filterCrs` | ❌ | ✅ free, open tier |
| Darwin **timetable files** | ✅ whole day | ✅ (after ingest) | ❌ | ✅ free |
| National Rail **OJP** | ✅ | ✅ | ✅ | ❌ signed licence, paid, not self-serve |
| **TransportAPI** | ✅ | ✅ | ✅ | ✅ commercial, paid |

### Why not Darwin/LDBWS, despite being free and official

LDBWS is a **departure board**, not a timetable. Its parameters cap at
`timeOffset` ±120 minutes, `timeWindow` 120 minutes, `numRows` 10. It can tell you
what leaves in the next two hours. It structurally **cannot** answer "what is the
first train tomorrow" or "what is the last train tonight" when you ask at 14:00.

That is the entire product. So LDBWS is out as the primary source, and this is
the single most important finding in this document — it is the obvious choice
until you read the parameter limits.

### Why not the Darwin timetable files

They do contain the full day, and they are free. But they are bulk XML dropped to
a bucket, so using them means running an ingest pipeline and a timetable database,
and reimplementing schedule assembly (associations, splits, overlays, STP
cancellations) that RTT already does. That is a rail-data project with a train app
attached, rather than a train app.

Worth revisiting only if the RTT bill ever stops making sense, or if per-query
rate limits become the constraint.

### Why RTT stays

It already does the two hard things: a **23h59m window** in one query, and
**station-pair filtering** in the same query. That combination is why the current
app can answer first-and-last at all. It is also the only source in the table that
gives it to us without either a 2-hour ceiling or a data pipeline.

The blocker was never technical. It was the licence, and RTT sells one.

---

## 3. Licensing — the actual blocker

**The current token cannot ship.** It is issued for personal, non-commercial use,
and the terms are explicit that a token found in a downstream user application
gets revoked. Putting the current build on the App Store would breach it.

Three things must be true before submission:

1. **A paid RTT plan.** Self-service from £4/month (hobbyist) and £29/month
   (business). Which tier depends on whether a free App Store app counts as
   commercial — **ask RTT directly at hello@realtimetrains.com**, do not assume.
   Get the answer in writing before building anything.

2. **The token still never reaches the device.** A paid plan does not change this.
   The rule is that end-user applications proxy through a server-side component,
   so the SwiftUI app talks to *our* API, never to `data.rtt.io`. See §5.

3. **Visible attribution.** RTT requires clearly visible credit with a link to
   realtimetrains.co.uk in any public-facing application. The web app has this in
   the footer; the iOS app needs it somewhere permanent, not buried in an About
   sheet.

> If RTT decline to license App Store distribution at any price, the fallback is
> the Darwin timetable ingest (§2). Establish this **first**. It is the one
> question that can invalidate the whole plan, and it costs an email.

---

## 4. Direct only, with a door left open

Ship direct-only. Architect so a journey planner can slot in behind the same UI.

### The problem this creates, stated plainly

For c2c and the Elizabeth line, "direct only" was near-complete — a blank result
genuinely meant "nothing runs". Nationally that inverts. **Most UK station pairs
need a change.** Manchester → Brighton, Cardiff → Norwich, and the large majority
of anything not on one line.

So "no direct service" goes from a rare, trustworthy answer to the *common* one.
An app that says "no direct trains" to most questions is not obviously useful, and
this is the biggest product risk in this document — bigger than any technical item.

### Mitigations, in order of value

1. **Say which it is.** "No direct trains — this journey needs a change" reads as
   an answer. A blank result reads as a broken app. The distinction is free: if
   the pair returns nothing, that *is* the finding.
2. **Lead with what direct-only is genuinely good at.** Commuter corridors and
   rural branches. The last train from a village station with four services a day
   is where this app is most valuable, and it is always direct.
3. **Suggest the interchange without planning it.** For a pair with no direct
   service, both stations usually share one obvious hub. Offering "try via
   Birmingham New Street" is cheap and honest, and is not journey planning.
4. **Keep the seam clean.** One function answers "services from A to B on date D".
   A licensed planner replaces its body without the UI knowing.

### The door

If changes are ever wanted: TransportAPI is the pragmatic route (REST, JSON,
commercial, no signed paperwork). National Rail OJP is the official one but is
SOAP, needs a countersigned licence, and is not self-serve.

---

## 5. Architecture

```
SwiftUI app  ──►  our API (Vercel)  ──►  Realtime Trains
   bundled            holds the token         paid plan
   stations           caches aggressively
```

The app is a client of our own API, not of RTT. This is forced by §3 and has
consequences worth being honest about:

- **The app needs the internet and needs our server up.** It is not offline-first.
  Cached answers make it feel offline-ish; they do not make it offline.
- **The Vercel deployment becomes infrastructure**, not a convenience. If it is
  down, the App Store app is down.
- **The existing `/api/trains` route is reusable almost as-is.** It already holds
  the token, caches by key, and returns a clean contract. It needs the `direction`
  parameter swapped back for `to`, which is largely reverting a known-good commit.

### Caching gets more important, not less

67 stations produced few distinct cache keys. 2,600 stations produce a long tail
where almost every query is a miss. Rate limits then bind much harder.

- Cache on the **server** by `from:to:date`, as now, but expect a far lower hit
  rate.
- Cache on the **device** too, so a repeated journey costs nothing at all. The
  device cache is what makes the widget (§7) viable.
- Check the paid tier's actual limits before assuming headroom. The free tier is
  10/minute, and one lookup currently costs up to eight requests.

---

## 6. Station data

**FasterRoute publishes an Apache-2.0 JSON of every National Rail station** — CRS,
TIPLOC, operator, name, latitude, longitude — assembled from Darwin reference data,
NaPTAN and manual research. That is the base list, and the licence permits use.

Cross-check it against RTT's `/data/stops`, which is authoritative for *what our
token can actually query*. A station in one and not the other is a bug to
investigate, not to paper over.

**The existing rule stands: no CRS code is ever typed by hand.** The generator
already resolves names to codes against the API and refuses to emit an invalid
list; extend it rather than replacing it.

### What breaks at 2,600 stations

- **Nearest-station** is currently a linear scan with a haversine per station.
  Fine for 67, wasteful for 2,600 on every location update. Use a spatial grid or
  k-d tree, or bucket by rounded lat/lon.
- **Search** must disambiguate. There are two Newports, several Ashfords,
  Whitchurch in three counties. Show the county or operator on collision, and rank
  by size — nobody typing "birmingham" wants Birmingham International first.
- **Cities are not stations.** London has ~18 terminals; Glasgow, Manchester,
  Birmingham, Leeds and Edinburgh all have multiple. Typing "Manchester" must
  offer Piccadilly *and* Victoria, not guess. The "London Terminals" grouping
  concept exists in rail data and is worth supporting explicitly.

---

## 7. The native app

### What justifies going native at all

Not the App Store listing. **The widget.** A home-screen or lock-screen widget
showing the last train home, updating through the evening, is precisely this
app's use case and is impossible in a PWA on iOS. If only one native feature ships,
it is this one.

After that: App Intents ("Siri, when's my last train home?"), Live Activities for
a journey in progress, and Core Location without a permission prompt every session.

A wrapped web view would also risk rejection under the minimum-functionality
guideline. Native sidesteps that.

### What to port, not redesign

The design is settled and should transfer intact:

- Full-bleed blocks, zero radius, zero gaps
- **Red means last train, and nothing else.** `#E4002B`, not flag red — it was
  chosen by measurement against the blue it sits beneath, and the reasoning is in
  the CSS. Carry the visible `LAST TRAIN` label too; colour is never the only signal.
- Mono tabular times as the largest thing on screen
- Operator as a white outline, never a filled brand colour

Use Dynamic Type properly rather than fixed sizes — it is the native equivalent of
the 200% font test the web app already passes.

### What must be reimplemented carefully

The **service day** logic. It is the part most likely to be got wrong in a rewrite
and the part where being wrong is invisible: 03:00 boundary, "tonight" versus
"today" after midnight, and London wall-clock times that arrive from the API with
no timezone marker at all. Port the tests first, then the code.

Swift's `Calendar`/`TimeZone` handle this well *if* you set the timezone
explicitly on every formatter. The web app's bug — an hour late in production —
came from trusting a default. Do not trust a default.

---

## 8. Domain rules that get harder nationally

The existing rules all still apply. These are new:

**Sleepers cross the service day mid-journey.** The Caledonian Sleeper leaves
Euston around 21:00 and arrives in Inverness after 08:00. Nothing in the current
three-operator world does that. The 03:00 boundary now falls *inside* journeys, not
just between them. Decide deliberately which service day such a train belongs to —
the answer is its origin's, but the display needs to make the arrival day obvious.

**Very long journeys need duration back.** Dropped it because Grays→Fenchurch
Street is always about 40 minutes. Penzance→Aberdeen is not, and "how long is
this" becomes a real question again.

**Splits and joins are common.** Portion working exists on the current network but
matters far more nationally. A train can carry two destinations and divide en
route; boarding the wrong half is a genuine failure. The API returns both
destinations — surface it clearly rather than joining with "&".

**Replacement buses are frequent.** Already badged; at national scale this will be
a routine occurrence rather than an oddity, especially at weekends.

**Rural is the best case, not the edge case.** A station with four trains a day is
where "first and last" is most valuable and where a wrong answer is most costly.
Test against one — Berney Arms, Denton, Teesside Airport — not just against
high-frequency commuter routes where being wrong is cheap.

---

## 9. Build order

1. **Email RTT.** Confirm in writing that a paid plan permits an App Store app.
   Nothing else starts until this is answered (§3).
2. **Prove the pair query nationally.** A throwaway script: first and last direct
   train, Penzance→Plymouth, Inverness→Perth, somewhere rural. Confirm the
   23h59m window and `filterTo` behave the same outside the south-east.
3. **Station data.** FasterRoute JSON crossed against `/data/stops`, validated the
   way the current generator validates. Spatial index for nearest.
4. **API route.** Revert `direction` to `to`; keep the caching, the service-day
   window, and the token handling.
5. **SwiftUI app.** Service-day logic and its tests first. Then pickers, then the
   result stack, then the design system.
6. **Widget.** The reason for doing any of this.
7. **App Store.** Attribution visible, privacy manifest, location usage string.

---

## 10. Open questions

- **Does a free App Store app count as commercial to RTT?** Blocks everything.
- **What are the paid tier's rate limits?** Determines whether the current
  eight-requests-per-lookup design survives 2,600 stations.
- **Is the server dependency acceptable?** The app cannot work without our Vercel
  deployment. If that is unacceptable, the answer is the Darwin ingest (§2), which
  is a much larger project but removes the dependency on someone else's uptime.
- **Do we support station groups (London Terminals)?** Affects the picker and the
  query model, and is easier to decide now than to retrofit.
- **How aggressively do we suggest interchanges** for pairs with no direct service
  before it becomes journey planning we are not licensed to do?

---

## Reference

- [Realtime Trains API portal](https://api-portal.rtt.io) — plans and tokens
- [RTT API specification](https://realtimetrains.github.io/api-specification/)
- [Rail Data Marketplace](https://raildata.org.uk) — Darwin, LDBWS
- [LDBWS documentation](https://realtime.nationalrail.co.uk/OpenLDBWS/) — note the
  2-hour and 10-row limits
- [National Rail developers](https://www.nationalrail.co.uk/developers/) — OJP
  licensing
- [FasterRoute](https://www.fasteroute.com/) — Apache-2.0 UK station JSON
- [TransportAPI](https://www.transportapi.com/) — commercial journey planning
