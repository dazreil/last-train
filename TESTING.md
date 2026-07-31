# Test coverage: where it is good, and where it is missing

An assessment of what `npm test` actually covers, what it cannot currently reach,
and what is worth writing next. Written against commit `b98484e`.

---

## Where it stands

`npm test` runs 55 tests across three files under `TZ=UTC`, and they all pass.
They use only `node:test` and `node:assert` — no dependencies, no runner, no
config. That is a genuinely good position to be in and worth protecting: the
suite runs on a clean checkout with no `npm install`.

Coverage of the modules those tests import is high:

```
file            | line % | branch % | funcs % | uncovered
----------------|--------|----------|---------|----------
direction.ts    | 100.00 |   100.00 |  100.00 |
serviceDay.ts   | 100.00 |    95.83 |  100.00 |
journeys.ts     |  97.69 |    74.39 |   94.44 | 153-159
```

The quality is high too, not just the percentage. The fixtures use the
timezone-less datetime shape the API really sends rather than `Z`-suffixed
instants, which is what makes the DST and service-day tests meaningful; the
corridor fixtures reproduce a `/gb-nr/service` response accurately, including the
absent `displayAs` that made every train look off-corridor. These tests were
written by someone who had been bitten.

The problem is what sits outside those three files.

| | Lines | Tests |
|---|---|---|
| `serviceDay.ts`, `direction.ts`, `journeys.ts` | 578 | 55 |
| `rtt.ts`, `stations.ts`, `cache.ts`, `geo.ts`, `route.ts` | 1,066 | 0 |
| `page.tsx` and components | 852 | 0 |
| `scripts/*.mjs` | 1,528 | 0 |

So roughly 15% of the executable code is under test, and the untested 85%
includes the route handler — which is where most of the app's decisions are made.

---

## The blocker to deal with first

Four of the five untested library modules are not untested by choice. The test
runner physically cannot load them:

```
lib/stations.ts   ERR_IMPORT_ATTRIBUTE_MISSING   import ... from '../data/stations.json'
lib/geo.ts        ERR_IMPORT_ATTRIBUTE_MISSING + ERR_MODULE_NOT_FOUND ('server-only')
lib/rtt.ts        ERR_MODULE_NOT_FOUND ('server-only')
route.ts          ERR_MODULE_NOT_FOUND ('@/lib')
```

Next.js resolves all three of these — bare JSON imports, the `server-only`
sentinel, and the `@/*` path alias — and plain Node resolves none of them. Any
plan that starts with "write tests for the route handler" hits this on the first
line, so it has to be dealt with first.

The cheapest fix that keeps the zero-dependency property:

1. Add `with { type: 'json' }` to the two JSON imports. Standard in Node 22 and
   TypeScript 5.3+; verify `npm run build` still passes, since this is the one
   change that touches the shipped bundle.
2. Register a small `--import` loader hook in the `test` script that maps `@/*`
   to the repo root and resolves `server-only` to an empty module. About 20 lines,
   no packages.

The alternative is Vitest, which handles all four out of the box and would also
unlock component tests — but it costs the dependency-free checkout, and `npm test`
running on a bare clone is worth something.

---

## Priority 1 — the route handler

`app/api/trains/route.ts` is 350 lines with no tests. It holds every decision
that produces a *wrong answer* rather than a crash, which is precisely the class
of bug the README says is covered by tests. It isn't.

Once it can be imported, `GET` takes a `Request` and returns a `Response`, so it
is testable end-to-end with a stubbed `fetch` and no server. Worth asserting:

- **The last train is never dropped.** When `VERIFY_BUDGET` is exhausted, or a
  side request fails, `isInCorridor` returns `true` and the service is kept. This
  is the app's most important safety property and it is stated only in a comment.
- **No service is listed twice.** On a quiet day the earliest qualifying service
  is also among the last three, and the dedup on `earliest.id` is what stops it
  appearing under both headings.
- **The topology shortcut.** Eastbound from Shenfield returns `[]` with
  `x-cache: TOPOLOGY` and zero API calls. Six stations in the bundled list have a
  single `onward` direction, so this path fires in real use.
- **`totalIsExact`.** False where the line-up carries out-of-scope services
  (Liverpool Street), true everywhere else. The UI hides the count when it is
  false, so getting this backwards states a confident wrong number.
- **Request budget.** A lookup issues at most one line-up plus `VERIFY_BUDGET`
  checks; a second lookup at the same station in the other direction issues zero
  further line-up calls. Counting stub calls tests the rate-limit design directly.
- **Error mapping.** `RttError(429)` → 429 plus a `retry-after` header;
  `RttError(400)` → 502; anything unrecognised → 500 with a generic message.
- **Parameter validation.** Unknown CRS, bad direction, malformed date, and the
  −7/+90 day range bounds.
- **An unclassifiable service appears under neither direction** — the deliberate
  choice not to guess.

---

## Priority 2 — the cheap ones that already have bugs in them

These need no harness changes beyond the JSON import attribute, and writing them
turns up defects immediately.

### `lib/cache.ts` (121 lines, 0 tests)

Two real defects, both found by exercising the store directly:

**Overwriting an existing key evicts a bystander.** `set` checks
`store.size >= maxEntries` before writing, without checking whether the key is
already present. Filling the 8-slot line-up store and then re-setting a key that
is already in it drops an unrelated station's line-up, even though the store
never exceeded its capacity. `refresh=1` takes exactly this path. On an 8-slot
cache protecting a 10-request-per-minute budget, that costs real API calls.

**An overwrite does not refresh recency.** `Map.set` on an existing key keeps its
original insertion position, so `get` refreshes LRU order but `set` does not. An
entry written repeatedly and never read is still evicted first.

Neither is catastrophic — it is a cache, and the failure mode is extra API calls
rather than wrong answers — but both are invisible without tests. Worth covering:
eviction order, recency refresh on `get`, TTL expiry and deletion, and the
`ttlSecondsFor` boundaries (12h past / 1h today / 6h future) evaluated across the
03:00 service-day edge, where "today" is still yesterday's date.

### `lib/stations.ts` (174 lines, 0 tests)

**The "London" ranking rule is unreachable.** `searchStations` scores
`haystack.replace(/^london /, '').startsWith(needle)` as 2, but that branch sits
after `haystack.includes(needle)` scoring 3 — and stripping a leading prefix
cannot produce a substring the original did not already contain, so the earlier
branch always wins. The rule was written specifically to stop London termini
being buried, and it does nothing: `"fenchurch st"` scores London Fenchurch
Street at 3, below any station with a word starting `"fenchurch st"`. A handful
of ranking assertions would have caught it.

**`findStationByName` is load-bearing and unverified.** It is how the route
decides a service is in scope without spending an API request. If the API's
spelling drifts from `stations.json` — `Rainham (London)`, `Southend-on-Sea` —
services get silently mis-scoped in the safe-looking direction. Test the
canonicalisation against the awkward names actually in the data.

**`nearestStations` has no distance ceiling.** From Manchester it returns
Reading, 241 km away, as the nearest station; from Edinburgh, Maidenhead at
519 km. That may be fine for an app covering three corridors, but it is a
decision that should be written down as a test — especially with the UK-wide
rewrite in `IOS.md` coming, where "nearest station" becomes the primary input.

### Data-file invariants

`data/stations.json` and `data/geo.json` are generated but committed as build
inputs. The generator refuses to emit a partial list; nothing re-checks the
committed files. A fast, dependency-free test asserting the invariants would
catch a hand-edit or a bad regeneration. Today's files satisfy all of these:

- All 4 route markers resolve to stations in the bundled list.
- All 67 stations appear in `geo.byCrs` and `geo.byTiploc`, with longitudes
  agreeing with `stations.json` to within 0.01°.
- No duplicate CRS codes, no duplicate canonical names.
- Every station carries an `onward`, and no station lists an out-of-scope
  operator.
- Every CRS is three letters and every station sits inside the expected box.

---

## Priority 3 — `lib/rtt.ts` (351 lines, 0 tests)

Testable by stubbing `globalThis.fetch`. The behaviours worth pinning are the
four the README documents as live-API surprises, none of which are covered:

- **`serviceDetail` strips the `gb-nr:` prefix.** A one-line regex, and passing
  the identity through verbatim is a flat 400. Assert the URL the stub receives.
- **204 → `null`.** "Valid query, no services" is a real answer. The entire
  "an empty result can be trusted" design rests on this not being an error.
- **401/403 clears the cached access token before throwing 502**, so a rotated
  credential recovers on the next request instead of failing until redeploy.
- **The error message never echoes the response body**, which can quote the
  token. That is a security property asserted only by a comment.

Also: 429 carrying `retryAfterSeconds`, the timeout path returning 504, and the
refresh-token exchange with its 60-second expiry slack and `NaN` fallback.

---

## Priority 4 — the UI, without adding a DOM runner

`page.tsx` and the components are 852 untested lines. Most of that is markup that
does not repay unit testing, but three pieces are pure logic that decides what
the user sees, and all three would be better off extracted to `lib/` and tested
there than left inline:

- **`shortenPlace`** (`ServiceCard.tsx`) — splits on ` & ` and strips a leading
  `London `. Handles splitting trains; four assertions.
- **The first/last partition and `lastTrainId`** (`page.tsx`) — decides which
  card gets the red "Last train" flag. Pure function of the services array.
- **The `afterMidnight` label.** `page.tsx` re-derives the 03:00 boundary inline
  with its own `Intl.DateTimeFormat` instead of calling `serviceDay.ts`. The rule
  is thoroughly tested in one place and reimplemented untested in another — the
  duplication is the finding, not the coverage gap. It should call
  `currentServiceDate` and lose the second implementation.

---

## Priority 5 — branch coverage in the modules that are tested

`journeys.ts` sits at 74% branch coverage, and lines 153–159 — `destinationNames`
— are entirely uncovered despite being one of the two functions the route's
corridor decision depends on. Its sibling `destinationCodes` has a test; this one
does not. Also unasserted in `toDepartureService`:

- `depInstant`, the UTC-normalised emission that is the actual fix for the
  hour-late bug. Only `dep` is asserted, so the normalisation is verified
  indirectly.
- The `'??'` and `'Unknown operator'` fallbacks.
- `platform` preferring `actual` over `planned`.
- `via` when a calling pattern *is* supplied — every current test passes empty
  markers, so `deriveVia` is tested directly but never through the assembly path.

---

## Priority 6 — nothing runs any of this automatically

There is no `.github/workflows`. `npm test` covers `lib/*.test.ts`;
`npm run typecheck` and `npm run build` are never run anywhere but a laptop. That
matters more than usual here, because `tsc --noEmit` is what enforces the
`server-only` boundary — the guard that stops the RTT token reaching a client
bundle. A three-job workflow (test, typecheck, build) is a small change that
protects the one property with a real-world cost attached to getting it wrong.

---

## Suggested order

1. Unblock the harness — JSON import attributes and a loader hook. Nothing else
   is possible before this.
2. `cache.ts`, `stations.ts` and the data invariants. Cheap, fast, and they have
   defects in them today.
3. The route handler, with a stubbed `fetch`. The largest single risk.
4. `rtt.ts`, same stub.
5. Extract and test the three pure UI helpers; drop the duplicated service-day
   rule in `page.tsx`.
6. CI running test, typecheck and build.

One forward-looking note: `IOS.md` takes the app UK-wide and replaces east/west
with compass directions. `direction.ts` is the module that changes most under
that, and it is the best-tested thing in the repo — the tests use real
longitudes, so they will keep their meaning when the comparison becomes a
bearing. That is the right shape to have the rest of the codebase in before the
rewrite starts, not after.
