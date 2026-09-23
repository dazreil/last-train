# Status — handoff

Updated 24 September 2026. First written 5 August 2026; the Traps below are from
across that whole period and are still true unless marked otherwise.

---

## Where things stand

**The product is the iOS app.** The Next.js project is now its API: it holds the RTT
token, reads the Darwin timetable store, and serves `/api/v2/*`. The old web page at
`/` and `/api/trains` still work but nobody designs for them.

What the app does, all built and run on device:

- **Last Train** — station and compass direction, the last three trains of the service
  day and the first one back. Before a day's first train the board inverts: first three
  lead, the day's last train below. `lib/board.ts` chooses. Red is the genuine last
  train and nothing else.
- **Fast Train** — tap the masthead. Choose a destination from a list of direct
  stations; trains ranked by arrival, seven pages of three, reaching four hours ahead.
- **The widget** — lock screen and home screen, leading with the last train and holding
  it still all evening. **Live Activity** — follow a train and it counts down on the
  lock screen and the Dynamic Island.
- **The destination picker** — with no direction chosen, every direct station grouped by
  direction, and tapping one sets the direction. A *Popular* section at the top from the
  ORR origin–destination matrix, credited on screen.

Where each answer comes from:

| | Source |
|---|---|
| Last Train, whole service day | Realtime Trains line-up, cached in shared Redis |
| Fast Train, 0–2 hours | Darwin LDBWS, live |
| Fast Train, 2–4 hours, and the destination lists | Darwin timetable store, published nightly — see `DARWIN-INGEST.md` |
| Popular destinations | `data/popularity.json`, from the ORR matrix, refreshed each December |

**Next:** `IOS.md` §9 step 7 — submission. The RTT Team plan is paid for, the credit
line is in the app (*"Powered by Realtime Trains and National Rail Enquiries"*), and
the open-API question is closed by rate limits (see *Exposure*). What remains is
confirming the information flow end to end, then App Store submission.

| | |
|---|---|
| Repo | `github.com/dazreil/last-train` (private) |
| Live API | `https://last-train-dazreils-projects.vercel.app` |
| Stack | Next.js 16 on Vercel, TypeScript; SwiftUI app in `ios/` |
| Data | RTT next-gen API (**Team tier**, paid), Darwin LDBWS, Darwin timetable files |
| Tests | `npm test` 178, `swift test` 130, all passing, both under `TZ=UTC` |

**`last-train.vercel.app` is not this app.** That subdomain belongs to an unrelated
Singapore MRT tracker. Use the full alias above.

---

## Commands

```bash
npm run dev          # dev server
npm run dev:lan      # dev server reachable from a phone on the same Wi-Fi
npm test             # 178 tests, TZ=UTC (that is deliberate, see Traps)
npm run typecheck
npm run build
npm run spike        # throwaway API probe; needs .env.local
npm run national     # IOS.md §9 step 2 probe; 5 requests, then cached
npm run national:data # regenerate data/national.json; 0 requests on a warm cache
npm run stations     # regenerate data/stations.json + data/geo.json
```

The native app is a separate toolchain.

```bash
cd ios && TZ=UTC swift test   # 130 tests
cd ios && TZ=UTC LASTTRAIN_EXHAUSTIVE=1 swift test   # full nearest coverage, ~55s
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
30/750/9000. **History now** — the Team tier replaced it on 15 August 2026 — but some
older comments still size things against 10/minute. Do not run `npm run stations`
while testing the live app — they share the quota, and still do until a separate
development key is taken.

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

### Xcode is installed; the iOS platform has landed

As of 4 August 2026: **Xcode 26.3**, `xcode-select -p` already pointing at
`/Applications/Xcode.app/Contents/Developer`, iOS SDK 26.2 present, `swift test`
working with both `swift-testing` and XCTest.

The **iOS platform** — the simulator runtime, downloaded separately from Xcode ▸
Settings ▸ Components — was missing at the time of writing and is now in: iOS 26.3
(23D8133), confirmed 12 August 2026, with `xcodebuild -destination` accepting simulator
destinations and a full app build succeeding. If a fresh machine ever fails an iOS build
with an empty `xcrun simctl list runtimes`, this is the cause and the error names the
missing platform explicitly.

`swift build --triple arm64-apple-ios17.0-simulator` compiles `LastTrainCore` but
warns `using sysroot for 'MacOSX' but targeting 'iPhone'`, so it is a smoke test
rather than proof. The real check is `xcodebuild -scheme LastTrain -destination
'generic/platform=iOS Simulator'` once the platform is in.

**Historical note, in case a comment still refers to it:** before Xcode arrived,
neither `XCTest` nor `swift-testing` was available — both ship with Xcode, not with
the Command Line Tools — so the tests were briefly an executable with a hand-rolled
assertion harness. That is gone; they are a normal `.testTarget` now.

### The Swift port has the same timezone hazard, and the same tests

`ios/Sources/LastTrainCore/ServiceDay.swift` sets `timeZone` and `locale` explicitly
on **every** formatter, per `IOS.md` §7. The 17 tests in
`ios/Tests/LastTrainCoreTests` are the JavaScript suite ported test for test, and they
are worth their weight: swapping the one London timezone for `TimeZone.current` fails
four of them, including the scenario that reproduces the original production bug. They
pass under UTC, London, New York, Sydney and Kolkata.

They import `LastTrainCore` rather than `@testable import` it, so the public surface
is proved sufficient. `swift-testing` runs them in parallel, which also exercises the
shared formatter statics concurrently.

One Swift-specific difference from the JavaScript: bad input returns `nil` rather than
`NaN`, so a malformed departure cannot be rendered as a plausible-looking time.

`ISO8601DateFormatter` cannot be a shared static under Swift 6 strict concurrency —
it is not `Sendable`. `DateFormatter` is fine. The port uses `DateFormatter` with an
`XXXXX` offset pattern throughout, which accepts `Z` and `+01:00` alike.

### Upminster does have a southbound service, whatever the docs used to say

Both `PRODUCT.md` and `IOS.md` asserted that Upminster has no northbound or southbound
service, and it was used as a known-good oracle in tests. **It is wrong.** Upminster
has 16 southbound departures on a weekday, down the Ockendon branch to Grays — the
07:02 calls at Ockendon, then Chafford Hundred, then Grays, each of them south and
slightly east of Upminster.

The claim survived because the web app only ever offered east and west, so a whole
branch line was being folded into one of the two and nobody noticed it had no
direction of its own. Both documents are corrected.

The lesson generalises: **a hand-written list of which directions a station has will be
wrong, and wrong in the direction of hiding trains.** Availability is counted from the
line-up on every query, never stored.

### The station list has two copies, and the generator writes both

`npm run national:data` emits byte-identical files to `data/national.json`, which the
API reads from disk, and `ios/Sources/LastTrainCore/Resources/national.json`, which the
app loads through `Bundle.module`. An app ships as a bundle and cannot reach into the
repo, so it needs its own copy; writing it from the generator is what stops the second
copy going stale.

**Never edit either by hand.** Regenerate, and both are current.

Deleting the bundled copy is a *build* failure rather than a silent empty list —
SwiftPM refuses to build a target whose declared resource is missing. If it is ever
present but unreadable, `Stations.validate()` throws and `StationsTests` fails, which
is the check the app should also make at launch.

### Swift test runtime is dominated by cross-module calls, not by the work

Worth knowing before optimising anything in `ios/`: in a `-Onone` test build, a call
into another module is a real call, and the nearest-station agreement tests make
millions of them. Moving the reference scan's haversine into the test file took the
suite from 22 seconds to 7 — after two earlier guesses (reference-scan allocation,
then a computed property) each made it *slower*. Measure per-test before changing
anything; the numbers also swing with machine load, so compare like with like.

That local haversine is a better oracle anyway: a reference that calls the same
function as the code under test cannot catch an error inside that function.

### Two implementations of the compass, which must not drift

`lib/compass.ts` and `ios/Sources/LastTrainCore/Direction.swift` are twins — same
140-metre guard, same sector boundaries, same rule for a destination with no
coordinates. If they disagree, the counts on screen stop matching the list beneath
them. Their test suites are deliberately parallel, on the same fixtures, so a drift
shows up as a failing test rather than as a train under the wrong button.

`lib/direction.ts` is the *old* longitude comparison and still serves `/api/trains`.
It is not the same rule and is not meant to be; it goes when the web app does.

### The nearest-station grid is easy to make subtly wrong

`lib/nearest.ts` buckets 2,619 stations by rounded lat/lon. Two things about it are
not optional:

- **Searching the 3×3 block around the query and stopping is wrong.** It fails
  whenever the nearest station sits just over a cell boundary, and it looks perfectly
  fine in casual use. Every ring is followed by a proof that nothing unsearched can be
  closer, and the tests assert the grid agrees *exactly* with a full linear scan.
  Measured, by deleting the proof in the Swift port: the naive version returns a
  station **46km further away** than the real nearest, and all three agreement tests
  catch it.
- **A cell is not a fixed number of kilometres.** A degree of longitude is 71km at
  Penzance and 57km at Wick. The bound uses the smallest kilometres-per-degree in
  play, which can only cause more searching, never a wrong answer.

Worth knowing: it is 80× faster than the scan near a station, but only 3–4× over a
box that includes open sea, because empty rings grow as the square of their radius.
It falls back to a scan once it has probed more cells than there are stations.

### NaPTAN alone misses Waterloo, Victoria and London Bridge

Joining the API's TIPLOC straight to NaPTAN's `9100`-prefixed ATCO code covers 2,612
of 2,622 stops and silently loses some of the busiest stations in Britain, because
NaPTAN splits large stations into platform groups under suffixed codes — `WATRLOO` is
`WATRLMN`, `CLPHMJN` is five separate rows. A canonical-name fallback closes it, and
is safe only because the generator checks the two routes never disagree by more than
500m. Six more stations, the Elizabeth line core, carry `0,0` coordinates and a real
OS grid reference instead. All of this lives in `scripts/lib/naptan.mjs`.

### Domain rules that produce wrong answers rather than crashes

- **The service day runs 03:00 → 02:59.** A train leaving at 00:22 belongs to the
  previous calendar day. After midnight, "tonight" means yesterday's date.
- **No CRS code is ever typed by hand.** `scripts/generate-stations.mjs` resolves
  everything from the API and refuses to emit an invalid list.
- **Direction is derived, never queried.** Pairing a station with its line's terminus
  would drop eastbound services that terminate short — which is frequently the last
  one out.
- **The minimum-distance guard on direction is 140 metres, and must stay that small.**
  Now enforced by a test in both languages —
  `ios/Tests/LastTrainCoreTests/DirectionTests.swift` fails three tests if it is moved
  to 5km, and one of the failures is the tally silently reclassifying a real service
  as `unclassified`, which is the production symptom exactly.
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

### Xcode's Run button builds Debug, and Debug points at localhost

`project.yml` sets `BOARD_API_BASE_URL` per configuration: Debug to
`http://localhost:3000`, Release to the deployment. Xcode runs Debug by default, so
pressing Run without `npm run dev` gives an app that cannot reach anything — and it used
to say "Could not reach the server. Are you online?", which sends you looking at the
wrong thing entirely.

`BoardClientError.devServerDown` now names it: *"No dev server at localhost:3000. Run
`npm run dev`, or switch the scheme to Release to use the deployment."* Only a loopback
address can produce it, so a shipped build can never show it.

Either fix works — start the dev server, or Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Build
Configuration ▸ Release.

### A cancelled request reported itself as being offline

Fixed 13 August 2026. Fast Train said *"Could not reach the server. Are you online?"* on
the first entry after every launch, and worked on the second.

**Nothing was wrong with the network, and the server had already answered.** Two faults
compounded, and the first one hid the second:

- `BoardClient` caught every thrown transport error and mapped it to `.unreachable`.
  `URLSession` reports **cancellation** as an ordinary thrown error, so a request the app
  itself called off was reported as one the network had refused.
- `BoardView`'s `.task(id: fastKey)` was keyed on `fast.destination`, and the lookup it
  started **set** that destination through `adopt`. The key changed underneath the task,
  SwiftUI cancelled it, and the cancellation came back as "are you online?".

So the mode cancelled its own first lookup, every time, and blamed the network. It cost a
wasted upstream request as well as the wrong diagnosis.

`BoardClient.transportFailure` now re-throws cancellation as `CancellationError`, which
`FastModel` treats as "nothing happened" — the guard `BoardModel` already had.
`FastModel.load` no longer adopts; `FastBoardView` does, so the key settles before the
request goes. `TransportFailureTests` pins all four cases, including that a genuine
failure still says unreachable and still names the dev server on loopback.

**This was first misdiagnosed as a rate limit** — the free tier's 10/minute had just been
spent, which fitted the timing and was wrong. The tell that should have settled it sooner:
a `curl` of the same pair came back *warm in 1.2 seconds*, which means the app's request
had reached the server and populated the cache. A request that times out upstream does not
leave a warm answer behind.

### One remembered destination was not enough, and it failed silently

Found the same day. `SharedSelection` held a single destination plus the scope it belonged
to, copied from the pin design — where one-at-a-time is deliberate, because a headcode
means nothing at another station.

A destination is not like that. Choosing where to go *east* from a station overwrote where
you went *west* from it, and the read returned nothing on a scope mismatch, so the field
fell back to "Choose a destination" as though it had never been set. It now stores a map
of scope to destination, one short string per pair actually used, and carries the old
single slot over on first write.

### An empty Fast Train board late at night is usually the right answer

`Upminster → Southend Central` returns `candidates: 0` after about 23:40, and it is
correct: the last eastbound trains terminate at **Laindon**, short of Southend. Anything
picked as a test pair needs enough trains left in the evening to fill a second page —
near end of service most pairs do not, and `Stratford → Liverpool Street` (Elizabeth line
plus Greater Anglia, every few minutes past midnight) is the reliable one.

### There is always a nearest station, and that is the problem

Run from Xcode, whose default simulated location is San Francisco, the nearest-station
button confidently filled the field with **Thurso**. Nothing was broken: Thurso really
is the closest British station to California, 7,907km away. The index was right and the
answer was absurd, which is a shape of bug no correctness test catches.

`Stations.plausibleRadiusMetres` (100km) bounds it, mirrored by `PLAUSIBLE_RADIUS_KM` in
`lib/stations.ts`. **It is not a test of which country you are in, and must not be
turned into one.** Measured: Cape Wrath is 70.7km from a railhead and Kinlochbervie
63.3km, while Belfast is 67.7km from Stranraer and Douglas 68.2km from Nethertown —
remote Great Britain is *further from a station* than Northern Ireland or the Isle of
Man. No threshold separates them. A test in `NearestTests.swift` asserts that inequality
directly, so anyone "tightening" the bound to exclude Belfast finds out it would take
the north-west Highlands with it.

### Core Location has two traps, and both fail silently

Both found by pressing the button rather than by reading the code.

**A `CLLocationUpdate.liveUpdates` sequence started before the permission dialog is
answered simply ends.** No location, no error, no resumption when the answer arrives.
A single pass over it therefore left the first press after granting doing *nothing* —
no station, no message, a button that looked ignored — and the second press worked.
`LocationFinder.firstFix` restarts the stream until a fix arrives for this reason.

**`CLLocationManager.authorizationStatus` can report the previous answer while a prompt
is on screen.** Reproducible right after `simctl privacy reset location`: the prompt is
visible and the manager still says `authorizedWhenInUse`. So it cannot be trusted to
tell you the dialog is up, and any timeout that assumes it can will fire underneath an
unanswered prompt — "could not get your location in time", on the very first press.
The fix budget is 30s rather than the web app's 8s for exactly this reason; the
`authorizationDenied` flag that would settle it properly is iOS 18 and the deployment
target is 17.

### Getting it onto a real iPhone: four blockers, none of them self-explaining

Done 9 August 2026, on a **free personal team** (`6G9H3H7HTP`). Each failure below
reported something other than its cause, so this is the order they surface in.

1. **`security find-identity` shows 0 identities, and that is normal.** Signing in to
   Xcode does not create a development certificate — the first device build does. Do not
   go hunting for a missing certificate.
2. **Developer Mode is off on the phone.** Symptom: `devicectl` lists the device as
   `connected (no DDI)` and every build says *"Unable to find a device matching the
   provided destination specifier"*, which sounds like the wrong id. It is not.
   Settings ▸ Privacy & Security ▸ Developer Mode, on, restart, confirm.
3. **`devicectl`'s identifier is not `xcodebuild`'s.** `devicectl list devices` prints a
   CoreDevice UUID; `-destination id=` wants the hardware UDID. Get the right one from
   `xcodebuild -showdestinations`, never by copying the one you can already see.
4. **A free team cannot provision an App Group.** This is the real wall, and it is the
   last to appear because a profile has to exist before it can mismatch: *"Provisioning
   profile … doesn't match the entitlements file's value for the
   com.apple.security.application-groups entitlement"*. Overriding
   `CODE_SIGN_ENTITLEMENTS` to `App/Resources/PersonalTeam.entitlements`, which is empty,
   signs both targets without it and leaves `project.yml` — what a paid build uses —
   untouched.

Then trust the certificate **on the phone**: Settings ▸ General ▸ VPN & Device Management
▸ Developer App ▸ Trust. Until that is done the app installs and refuses to launch, with
`FBSOpenApplicationErrorDomain error 3`.

```bash
cd ios
xcodebuild -project LastTrain.xcodeproj -scheme LastTrain -configuration Release \
  -destination "id=$(xcodebuild -project LastTrain.xcodeproj -scheme LastTrain \
    -showdestinations 2>/dev/null | grep 'platform:iOS, arch' | \
    sed -E 's/.*id:([^,]+).*/\1/')" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=6G9H3H7HTP CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_ENTITLEMENTS='App/Resources/PersonalTeam.entitlements' build

xcrun devicectl device install app --device <hardware-udid> \
  ~/Library/Developer/Xcode/DerivedData/LastTrain-*/Build/Products/Release-iphoneos/LastTrain.app
```

**Release, so the phone talks to the deployment** rather than a dev server it cannot
reach. **A free team signs for 7 days**; after that the app stops launching until it is
rebuilt and reinstalled.

The widget works on device without the App Group, as expected: it cannot read which
station the app was last on, so it starts blank instead of following the app, and
behaves normally once a station is picked in Edit Widget.

#### The same thing from Xcode, without the terminal

Five one-time changes, and then the Run button does it. Each one replaces a flag in the
command above, so the reasons are the same ones written up under the four blockers.

1. Open `ios/LastTrain.xcodeproj`. Plug the phone in, unlock it, and pick it in the
   destination dropdown at the top of the window.
2. **Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Info ▸ Build Configuration → `Release`.**
   `project.yml` deliberately sets Run to Debug for the simulator, and Debug points at
   `localhost:3000`, which a phone cannot reach.
3. Select the **LastTrain** project in the navigator, then the **LastTrain** target ▸
   *Signing & Capabilities* ▸ Team → the personal team. Repeat on the
   **LastTrainWidget** target. Both get signed, so both need it.
4. On those same two targets, *Build Settings* ▸ search `Code Signing Entitlements` →
   set it to `App/Resources/PersonalTeam.entitlements`. **This is the step that matters**
   — it is the App Group wall in blocker 4, and without it the build fails on a
   provisioning-profile mismatch that names an entitlement rather than the free team.
5. Press ⌘R. First run only: trust the certificate on the phone, as above.

**These settings do not survive `xcodegen generate`.** The `.xcodeproj` is generated and
gitignored — `project.yml` is the source of truth — so regenerating resets all five and
the symptom is a build that suddenly cannot sign, or an app that says it cannot reach the
server. Regeneration is only needed when files are added or removed, so in practice this
is set once and forgotten. The terminal recipe above needs none of it, which is why it is
the one written down first.

### The first Xcode open after `xcodegen generate` looks like a hang

Measured 20 August 2026, after the Live Activity added two files. Xcode opened, the window
came up, and it stopped responding for **over three minutes** — long enough to look wedged
and be force-quit, which only starts the wait again.

It is not wedged. Regenerating recreates the `.xcodeproj`, which throws away Xcode's cached
Swift package resolution, and `project.yml` points the `LastTrainCore` package at `.` — the
package root *is* `ios/`. So resolution walks the same directory that CLI `swift test`
fills with build artifacts: **`ios/.build` was 307MB** at the time. `xcodebuild -project
LastTrain.xcodeproj -list` shows exactly where it sits, printing `Resolve Package Graph` and
then nothing.

**It is a one-off.** The same command took three seconds the second time, and Xcode opens
normally afterwards. The cheap way to pay it without watching a frozen window is to run
`xcodebuild -list` in a terminal first and let it finish, then open Xcode.

If it ever does not settle, `rm -rf ios/.build` is safe — it is gitignored, and the next
`swift test` rebuilds it at the cost of one slow run.

### The simulator's widget gallery will not take synthetic taps

Adding a widget needs long-press → Edit → Add Widget, and the tap on **Edit** is
delivered as a tap on the background every time, which just exits jiggle mode. Three
variations failed the same way. Do not spend time on it.

What works instead: render the widget's families directly inside the app for one
build. `BoardProvider.entries(for:)` returns the real timeline, so every entry can be
drawn at its real size against a live response, including the ones hours away that
cannot be reached by waiting. `WidgetPreviewContext(family:)` does **not** set
`widgetFamily` at runtime — the environment value is read-only and everything renders
as `systemMedium` — so the harness has to build each family's view directly.

### Build environment

- `lib/*.ts` use explicit `.ts` extensions on relative imports so Node's native type
  stripping can run the tests. `allowImportingTsExtensions` is set for this.
- `server-only` is a declared dependency. It makes an accidental client import of the
  token module **fail the build** — verified, not assumed.

---

## Documents, and what each owns

| File | Owns |
|---|---|
| `STATUS.md` | This file. Where things stand, the traps, and what is next. Read first. |
| `CONTINUE.md` | A short prompt to paste into a new session. Points here. |
| `PRODUCT.md` | Product truth: users, purpose, positioning, constraints. Platform recorded as **ios**. |
| `DESIGN.md` | The visual system, with machine-readable tokens in frontmatter. North star "The Departure Board". |
| `.impeccable/design.json` | Sidecar: tonal ramps, contrast measurements, motion, 8 renderable component snippets. |
| `IOS.md` | The approved spec for the national iOS app, and the record of how each part was decided. |
| `DARWIN-INGEST.md` | The Darwin timetable ingest: what the file holds, how it is parsed, stored and delivered. |
| `UI-GLOSSARY.md` | Plain names for each piece of the iOS screen, and the code name that matches it. |
| `README.md` | How to run it, how the API is laid out, and deployment. |

The original brief (`PROJECT.md`) and the UI design brief were supplied as
attachments and are **not in the repo** — they are in `~/Downloads/`.

Two rules from `DESIGN.md` are load-bearing and easy to break by accident:

- **Red means "this is the last train" and nothing else.** There is deliberately no
  `--danger` token. Errors, buses and alerts are all non-red.
- **Contrast is computed, never eyeballed.** The palette already changed once because
  the Union Flag red measured 2.51:1 against the blue beneath it.

---

## Next

### Before submission

1. **Confirm an unattended night of the Darwin ingest.** The job has only been proved
   by hand. Check `/api/timetable-health` the morning after it runs on its own.
2. **Confirm the information flow end to end** — every screen answers from the source
   in the table at the top, and a failure in any one of them says so in words.
3. **Submit.** `IOS.md` §9 step 7. The RTT Team plan is paid; the credit line is in
   the app; the API is rate limited.

### Worth doing, not blocking

- **Take a separate RTT development key.** Team allows five. Until then, testing and the
  generators spend production's quota, and now also production's spend ceiling.
- **Resize the free-tier budgets.** `DETAIL_BUDGET` in `app/api/trains/route.ts` is the
  old web route and can wait for that route to go. `PATTERN_BUDGET` in
  `app/api/v2/destinations` prices only the RTT fallback now, since the lists come from
  the timetable store.
- **Move Last Train off RTT** — `DARWIN-INGEST.md` stage 6. Last Train's whole-day board
  is now the app's main RTT cost. Moving it to the timetable store, with LDBWS inside the
  near window, cuts the running cost towards £0 and shrinks the quota anyone can drain.
- **Last Fast Train**, the unadvertised third mode in `IOS.md` §11. Not built.

### Open questions carried forward

- **Is £348/year worth it for this?** Tip-jar and ads are permitted on the Team tier if
  it ever needs to pay for itself. `PRODUCT.md` *Paying for it* has the priced options.
  The Darwin work above is the other way to answer it.
- **What the volume actually scales with.** Not users, and **not widget refreshes** —
  the widget fetches once and derives the rest of the night from what it holds. Upstream
  cost is *distinct station-days × cache miss rate*, which makes the TTL in
  `lib/cache.ts` the lever. Measured in August: 122 requests in a week against 25,000.
- The app depends on our Vercel deployment being up. That is accepted.

### Settled, kept for the reasoning

- **The compass control** is not a compass. Chevron quadrants first, then one row of
  four tabs (21 August 2026). See `IOS.md` §4 for why the cross and the slider failed.
- **`via` is gone.** Direction comes from a walked waypoint (`IOS.md` §13), and Fast
  Train answers the Tilbury/Basildon case by arrival time.
- **Darwin timetable files are not "a much larger project".** They arrive pre-assembled.
  See `DARWIN-INGEST.md` §2.

---

## Exposure

None of these is a leak of the RTT token, which has never left the server. They are
about **quota and staleness**, and each is a consequence of a choice that was right at
the time.

### The rule that requires the proxy, in RTT's own words

Read from the RTT API terms on 13 August 2026. The architecture already assumed this;
this is the citation it was missing.

> You must not embed or distribute your API token in any downstream user-facing
> application, including but not limited to client-side code, mobile apps, or browser
> extensions, unless specifically authorised by us. If we identify that a token is
> exposed in a downstream application, it will be revoked immediately. End-user
> applications are expected to proxy requests through a server-side application such that
> the token is not publicly accessible.

**We comply, and it was checked rather than assumed** (13 August 2026):

- The only occurrences of "token" in the whole Swift codebase are the comment in
  `BoardClient.swift` explaining this rule. No key, no bearer, nothing in the widget.
- The app can reach exactly one host — `BOARD_API_BASE_URL`, loopback in Debug and the
  deployment in Release. Nothing in `ios/` names `data.rtt.io` at all.
- `lib/rtt.ts` opens with `import 'server-only'`, so a client import **fails the build**.
  `.env*` is gitignored, no env file is tracked, and no credential-shaped string exists
  in any tracked file.

Two things the clause does **not** settle, and conflating them would be a mistake:

- **It does not replace the commercial-plan requirement.** RTT's answer of 1 August was
  about call volume. Proxying correctly and needing a Team plan are independent, and both
  are true.
- **It sharpens the open-proxy question below rather than answering it.** The token
  cannot be stolen, but its *quota* can be spent by anyone, and the terms show RTT
  reasoning about who is answerable for the calls a token makes. Answered below, with
  rate limits.

### Old deployment URLs served old answers — closed 7 August 2026

Deployment Protection had to be turned off for the phone to reach the API, and that
switch is not scoped. Vercel mints a permanent URL for **every** deployment, and each one
keeps serving its own build. Measured: three of them — one preview and **two
production** — all answering HTTP 200 with the last train south from Upminster at
**18:34**, when the right answer that evening was 00:33.

Note the two production ones. Every push to `main` mints a hashed URL and only the newest
is aliased, so this was never a preview-only problem, and protecting previews alone would
have fixed the smaller half of it.

**The Vercel-side fix does not exist on Hobby.** The Deployment Protection page offers a
single `Require Log In` toggle covering every deployment including the alias the app is
built against — that toggle is what broke the phone originally. Password Protection is
Pro plus Advanced Deployment Protection at $150/month. There is no scope selector to set.

So the line is drawn in our own code: `middleware.ts` refuses `/api/*` on any host that
is not `lib/liveHost.ts`'s `CANONICAL_HOST` or loopback, answering `410 Gone` with the
live URL in the usual `{ error }` shape. Pages are left alone — a stale page is a
curiosity, a stale board is an answer someone acts on — which also keeps previews useful
for looking at the web app.

**It cannot retire deployments that already exist.** They carry their own copy of the old
code and will answer until they are deleted. Doing that once clears the backlog; the
middleware stops it building up again.

Not through the dashboard — that is one triple-dot menu per deployment, and there were
**35**. The CLI does the lot:

```bash
npx vercel login
npx vercel remove last-train --safe    # lists what it will remove, asks once
npx vercel remove last-train --safe --yes
```

`--safe` skips deployments with an active alias, so the live production one survives and
the rest go. Flags read from `vercel remove --help` on CLI 58.8.0 rather than recalled —
this is the third Vercel control in this project whose behaviour did not match its
description, so check the help output before trusting any of it, including this.

### The API was unauthenticated — closed 24 September 2026, by rate limits

`/api/*` has no key and no login, and `data/national.json` ships inside the app, so the
list of every station to walk is public by construction. Upstream cost is *distinct
station-days that miss the cache*: hammering one station is free, walking the country
is not.

| | Free | Team |
|---|---|---|
| Sustainable per day | 1000 | 3571 |
| One pass over all 2,619 stations | **2.6× a day's budget** | **73% of a day's budget** |

**Decided: two rate limits now, App Attest only if abuse is ever seen.** Both count in
the shared Redis, so every Vercel instance sees the same numbers. The rules and the
numbers are in `lib/limits.ts`, with tests.

- **Per caller**, in `middleware.ts`: 60 requests a minute and 600 an hour from one IP
  address. Past it, `429` with a sentence the app shows as it is. Generous on purpose —
  a phone network can put many people behind one address.
- **Upstream spend**, in `lib/rtt.ts`: at most 400 RTT requests an hour and 3,000 a day,
  across every caller. 3,000 × 7 is 21,000, which leaves 4,000 of the week's 25,000 for
  generators and testing. Past it, cold lookups get `503` and a sentence; any board
  already in the cache still answers. So someone with many addresses can slow new
  lookups down, but cannot spend the week.

**Both fail open.** With Redis absent, slow (over 400 ms) or down, nothing is limited. A
guard that takes the board down whenever its counter is unavailable is an outage. The
in-process token bucket still paces what gets through.

Checked against the real Redis store: calls one and two passed a limit of two, call
three was refused with the right wait.

**What it does not do:** prove a request comes from the app. That is App Attest, which
needs the paid Apple Developer Program and several days' work. Not needed unless the
spend ceiling is actually hit by someone who is not us.

---

## Known and deliberately unfixed

- The From field clips a long station name at phone width. Ordinary input behaviour,
  not the truncation the design forbids; the alternatives are worse.
- `totalServices` is hidden at Liverpool Street, where the count is a lower bound
  rather than exact.
- Vercel **Deployment Protection** was enabled and had to be turned off for the
  phone to reach the app. If a future deploy starts returning a Vercel login page,
  that setting has come back on. Turning it off exposed every preview deployment as
  well — see *Exposure* above; `middleware.ts` now refuses `/api` on any old URL.
