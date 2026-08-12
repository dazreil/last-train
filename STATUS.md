# Status — handoff

Written 5 August 2026. Working tree clean, `main` in sync with origin.

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

The **native iOS app is built** and runs on the simulator against the deployment:
2,619 stations bundled, the chevron direction control, both board arrangements, and
**the widget** — lock screen and home screen, leading with the last train and holding
it still through the evening. `IOS.md` §9 steps 1–6 are done. What is left is step 7:
the paid RTT token, attribution, and submission.

| | |
|---|---|
| Repo | `github.com/dazreil/last-train` (private) |
| Live | `https://last-train-dazreils-projects.vercel.app` |
| Stack | Next.js 16 (App Router), React 19, TypeScript, plain CSS |
| Data | Realtime Trains next-gen API, `data.rtt.io`, **free tier** |
| Tests | 85, all passing, run under `TZ=UTC` |

**`last-train.vercel.app` is not this app.** That subdomain belongs to an unrelated
Singapore MRT tracker. Use the full alias above.

---

## Commands

```bash
npm run dev          # dev server
npm run dev:lan      # dev server reachable from a phone on the same Wi-Fi
npm test             # 85 tests, TZ=UTC (that is deliberate, see Traps)
npm run typecheck
npm run build
npm run spike        # throwaway API probe; needs .env.local
npm run national     # IOS.md §9 step 2 probe; 5 requests, then cached
npm run national:data # regenerate data/national.json; 0 requests on a warm cache
npm run stations     # regenerate data/stations.json + data/geo.json
```

The native app is a separate toolchain.

```bash
cd ios && TZ=UTC swift test   # 68 tests, ~7s
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

### A rate-limited Fast Train lookup reports itself as being offline

Found 12 August 2026, while verifying the pager. Five date steps in a minute spend the
free tier's 10/minute; the Fast Train lookup that followed queued behind the limiter,
overran `BoardClient`'s **20-second** timeout, and the app said *"Could not reach the
server. Are you online?"* — which sends you looking at the network, the base URL and the
deployment, none of which were wrong. The same lookup answered in 1.2s once the window
had rolled.

It is the `devServerDown` lesson again in a second place: a transport-level failure is
reported as one, and the *cause* was the quota. **Warm the pair with `curl` before
driving the app**, and the app's request is an `x-cache` HIT that cannot time out.

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
2. ~~Station data~~ — **done, `npm run national:data`.** `data/national.json`, 2,619
   stations, generated and validated, 0 API requests on a warm cache. FasterRoute was
   not needed: `/data/stops` is the base list and NaPTAN places all but three stops,
   two of which are rail-air interchanges rather than stations. Nearest-station is
   `lib/nearest.ts` — see Traps for the part that is easy to get wrong
3. ~~API route~~ — **done, `GET /api/v2/trains`**, landing beside `/api/trains` so the
   deployed web app is untouched. Compass directions, all four buckets from one
   line-up, no corridor machinery, no `via`, diagnostics behind `DEBUG_DIAGNOSTICS=1`.
   The two routes share the line-up cache, so a station looked at on the web is free
   in the app
4. ~~SwiftUI app~~ — **done.** `ios/` is an XcodeGen project: `LastTrainCore` (the
   domain, Foundation only, 81 tests) plus an app target and a widget extension. The
   board, the chevron direction control, the station picker and the two arrangements
   all run against the deployed API
5. ~~The widget. It is the actual reason for going native~~ — **done, 5 August 2026.**
   Lock screen and home screen; it leads with the *last* train and holds it still all
   evening, and the whole night is computed from one request. Written up in `IOS.md`
   §12. The nearest-station button landed at the same time — `Nearest.swift` had been
   sitting built and tested but unwired since step 4
6. Paid token, attribution, submit — and the two decisions in *Exposure* below, which
   are cheap now and awkward once the app is public

### Parked, not scheduled

**Fast Train** — tapping the "Last Train" title flips the app into a from/to mode
showing four trains ordered by *arrival*, plus a hidden "Last Fast Train" variant.
Captured in full in `IOS.md` §11. It is not in the build order and does not change
it. Two things to know before anyone starts it: arrival ordering needs each service's
calling pattern, which is about a request per train and breaks the one-request
lookup; and it makes the `via` question below moot, since the Tilbury/Basildon case
is exactly what it exists to solve.

### Open questions carried forward

- **Is £348/year worth it for this?** The tier question is answered; whether the app
  is worth its running cost is a separate one, and it is now a real decision rather
  than a rounding error. Tip-jar and ads are permitted on both paid tiers if it ever
  needs to pay for itself.
- **What the volume actually scales with.** Not users, and **not widget refreshes**
  — that is now settled rather than hoped for. The widget fetches once and derives
  every later entry from the board it already holds, so it asks again only when a
  service day runs out, roughly once a night. Upstream cost is
  *distinct station-days × cache miss rate*, which makes the TTL in `lib/cache.ts`
  the lever. At a 1-hour live-day TTL a station watched all evening costs a request an
  hour, so Team's 3571/day sustainable covers a few hundred stations in daily use.
  Confirm that arithmetic against a real week before committing to a tier.
- ~~Does the compass control earn its vertical space?~~ **Answered — it does not.
  The control is chevron quadrants; see `IOS.md` §4.** Two findings worth carrying: a
  2×2 of chevron-clipped blocks holds four directions in two rows and clears the fold
  on the smallest supported phone, where the compass cross does not. And "keep the
  slider where a station has two directions" fails, because two directions are usually
  *perpendicular* rather than opposite — Penzance runs north and east, Denton east and
  south, and a left-versus-right control cannot express either.
- Keep `via` nationally? Recommended to drop — it exists for one real ambiguity (c2c
  via Basildon versus the slower Tilbury loop) and it is what costs the extra
  requests per lookup. That is now a question about the monthly bill, not only
  latency.
- The app depends on our Vercel deployment being up. If that is unacceptable, the
  alternative is ingesting Darwin timetable files — a much larger project.

---

## Exposure — decide before submission

Neither of these is a leak of the RTT token, which has never left the server. Both are
about **quota and staleness**, and both are consequences of choices that were right at
the time.

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

### The API is unauthenticated, and sized for one person

`/api/v2/trains` has no key, no origin check and no rate limit. Upstream cost is
*distinct station-days that miss the cache*, so hammering one station is free and
walking the country is not — and `data/national.json` ships inside the app, so the list
of every station to walk is public by construction.

Against the sustainable ceilings in the table above:

| | Free | Team |
|---|---|---|
| Sustainable per day | 1000 | 3571 |
| One pass over all 2,619 stations | **2.6× a day's budget** | **73% of a day's budget** |

One enumeration of the station list costs most of a day on the paid tier. At Team's
40/min a script reaches that in about an hour, and the app is throttled for everyone
until the window rolls.

Nothing has been done about this. The cheap options, in increasing order of nuisance:
a per-IP rate limit at the edge; a shared secret the app carries, which stops casual use
without pretending to be security; or requiring an App Attest token, which is the only
one that actually holds and is a real piece of work. **This wants a decision before the
app is public, not after** — the bill arrives either way, but a limit added afterwards
is a limit added during an incident.

---

## Known and deliberately unfixed

- The From field clips a long station name at phone width. Ordinary input behaviour,
  not the truncation the design forbids; the alternatives are worse.
- `totalServices` is hidden at Liverpool Street, where the count is a lower bound
  rather than exact.
- Vercel **Deployment Protection** was enabled and had to be turned off for the
  phone to reach the app. If a future deploy starts returning a Vercel login page,
  that setting has come back on. Turning it off exposed every preview deployment as
  well — see *Exposure* above, which is a decision rather than a fixed thing.
