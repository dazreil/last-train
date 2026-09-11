# Darwin timetable ingest

**Status:** spec. Nothing here is built. Agreed direction, 10 September 2026.

A daily job downloads Darwin's timetable file, turns it into per-station day
boards, and stores them. The app then reads a whole service day from our own
store instead of buying it a train at a time from Realtime Trains.

---

## 1. Why

Two faults, both recorded in `STATUS.md` and both caused by the same thing —
the app has no timetable of its own.

**Fast Train stops at two hours.** Darwin LDBWS is a departure board with a hard
120-minute ceiling. `timeOffset` cannot pass +120; the API returns HTTP 400. A
second call cannot reach four hours.

**The RTT tail that fills 2–4h is not robust.** `/api/v2/fast?later=1` reads that
window from RTT, and every later train needs its own calling-pattern call to get
an arrival — about nine requests for one window. RTT allows 40 a minute, so a
burst gets refused, `loadLater` swallows the error, and the board silently stays
at two hours.

A timetable ingest removes both. It also removes RTT from the app's biggest
consumer, and gives the app the assembled timetable a planner would need anyway.

### What this does not replace

The file is the **schedule**. LDBWS is **what is actually happening**. Delays,
live platforms and same-day cancellations stay on LDBWS for the near window. The
ingest never becomes the source of a live time.

---

## 2. What Darwin actually gives us

`IOS.md` §2 rejects this work because it would mean "reimplementing schedule
assembly (associations, splits, STP overlays)". **That is true of Network Rail
CIF. It is not true of Darwin's timetable file.** `IOS.md` is wrong on this point
and should be corrected when this lands.

Verified 10 September 2026 against the Open Rail Data wiki and the National Rail
developer pages:

- **Pre-assembled.** Schedule changes, new schedules, false destinations,
  cancellations and associations are already merged in. There is no overlay logic
  to write.
- **At least 48 hours** of coverage. Measured: a file generated at 02:05 on
  6 September carried four service dates, 5 to 8 September — yesterday, today and
  two days ahead. The app needs four hours. Last Train needs one service day.
  Both fit with room to spare.
- **One gzipped XML file** per publish.
- **Free, and not rate limited.** It is a file download, not a per-request API.
- Same Rail Data Marketplace account the app already holds.

### How you actually get the file

**Rail Data Marketplace pushes; it does not serve.** This is the part worth
getting right before any infrastructure is bought. A file product is delivered to
a **destination you own** — your own S3 bucket, Google Cloud Storage bucket,
Azure blob container, or an SFTP server you run. There is no marketplace bucket
to pull from and no marketplace credential to hold.

There are therefore two ways to get the file, and they suit different stages.

| | By hand | By transfer |
|---|---|---|
| Where | Product page → **Data files** tab → download | Product page → **Data files** → **File transfers** → add a destination |
| Needs | Nothing | A bucket or SFTP server of your own |
| Good for | Stages 0–3. Measuring, parsing, sizing. | Stage 7. The daily job. |

Stage 0 needs one copy of each file, once. Take it by hand. An AWS account is a
stage 7 decision and should be made with stage 0's numbers in hand, not before.

### Four traps, written down before they cost a day

1. **RDM needs write access to your bucket.** The transfer is a push, so the
   IAM policy grants `s3:PutObject` as well as `s3:ListBucket` and `s3:GetObject`,
   and a bucket policy names RDM's own IAM user as principal. Both policies are
   printed on the marketplace's "Access file data and automate transfers" guide.
   Copy them; do not improvise them.
2. **A new product version silently stops transfers.** When the publisher
   releases an updated version of the data product, the destination has to be
   linked to the new version by hand. Nothing fails loudly. This is the single
   most likely way this ingest dies six months from now, which is why stage 7
   watches snapshot age rather than job exit codes.
3. **Ten files arrive, describing two.** `…_v8.xml.gz` is the timetable;
   `…_ref_v4.xml.gz` is the reference data — locations, operators, reasons. We
   need one of each, and both matter: the reference file is where TIPLOC maps to
   CRS.

   The count is ten because Darwin publishes **the same content at several schema
   versions side by side** — timetable at v7 and v8, reference at v2, v3 and v4 —
   and two days are retained. The versions are additive, so take the highest.
   Sorting by delivery time cannot choose between them: every file of one publish
   carries the same generation stamp and lands together.

   Two naming traps follow. A reference file's name also ends `_v3.xml.gz`, so any
   test for the timetable must exclude `_ref_` explicitly or it matches both. And
   downloading by hand flattens the key, so `PPTimetable/20260906020530_v8.xml.gz`
   reaches the disk as `PPTimetable_20260906020530_v8.xml.gz`. Safest of all is to
   read the kind from the root element: `PportTimetable` against
   `PportTimetableRef`.
4. **The timetable speaks TIPLOC, not CRS.** Every station in this app is keyed
   by CRS. Nothing works until the reference file is parsed first. The mapping is
   many-to-one: several TIPLOCs can share a CRS, so dedupe.

### Shape of a journey

Each `Journey` carries a scheduled start date and a run identifier, then its
stops in order: origin, intermediate, passing, destination. Each stop carries a
TIPLOC and its times.

- `ptd` / `pta` are **public** times. These are what a passenger sees.
- `wtd` / `wta` / `wtp` are **working** times. These include passing points.
- **A stop with no public time is not a public call.** Drop it. This is the trap
  that would otherwise put a passing point on a departure board.

---

## 3. What we build, in order

Seven stages. Each one ends somewhere it can be left. Nothing after stage 4 is
needed to fix the fault that started this.

### Stage 0 — Prove the download and measure it

A throwaway script in `scripts/`. Take one timetable file and one reference
file, and count what is in them.

Record and write down:

- Compressed and uncompressed size.
- Journey count, and public-calling-point count.
- The exact window the file covers, and how that lines up with the 03:00–02:59
  service day.
- How often a new file appears. By hand, that is the timestamps on the Data files
  tab; once a transfer runs, it is the spread of modification times in the bucket.

**This stage sizes every stage after it.** Do not guess these numbers — the
storage decision in stage 3 depends on the real ones.

Gate: if the download or the credentials do not work, stop here. Everything else
is wasted.

**Built, 10 September 2026.** `scripts/darwin-probe.mjs`, with two ways in that
match the two ways of getting the file.

```
npm run darwin:probe -- --file ~/Downloads      # files taken by hand
npm run darwin:probe -- --bucket                # once a transfer is running
```

`--file` takes any number of paths, or a folder holding them, and needs no
credentials and no cloud account. It sniffs the gzip magic bytes rather than
trusting the extension, and decides each file's kind from its root element rather
than its name, so a hand-download called anything still measures correctly.
`--bucket` adds the delivery listing and reports publish cadence from the spread
of modification times. `--list-only` stops before downloading; `--keep` leaves the
files on disk.

The counting lives in `scripts/lib/darwin-scan.mjs`, apart from the probe so it
can be checked. It is verified across thirteen chunk sizes from one byte to the
whole file, because a chunk-boundary bug there would quietly inflate every number
the storage decision rests on, and inflate it in a direction that looks plausible.

Downloads never land in the repo. The repo is inside iCloud Drive, and a large
file written there is how the file provider wedges and the next build hangs.

### Stage 0 is done. The measurements

From `PPTimetable/20260906020530_v8.xml.gz` and its reference file, taken by hand
on 10 September 2026. The whole scan takes under a second.

| | |
|---|---|
| Timetable, delivered | 8.1 MiB gzipped |
| Timetable, uncompressed | 62.8 MiB (×7.7) |
| Reference, uncompressed | 1.8 MiB |
| Journeys | 56,935 |
| Public calls | 480,768 |
| Public calls per journey, mean | 8.4 |
| Passing points dropped | 346,965 — 42% of all stops |
| TIPLOCs in the reference file | 12,088 |
| …of those, carrying a CRS | 3,695 |
| Operators | 43 |
| Associations | 9,372 |
| Cancellation flags | 3,345 |
| Service dates covered | 2026-09-05 … 2026-09-08 |
| Publish cadence | daily, generated about 02:05 |

**What the numbers change.**

*The file is smaller than the design feared.* 62.8 MiB uncompressed, scanned in
under a second. The "a serverless function cannot hold this" argument in §4 is
weaker than it was written — see the note there.

*The passing-point filter earns its place.* It removes 42% of all stops before
anything else runs. Nothing downstream should ever see them.

*Stage 2's storage estimate is about 1.8 million rows*, and that is a floor.
A journey of k calls stores k(k−1)/2 rows in the per-station shape, k(k−1)/2 is
convex, and a scan cannot measure the spread of k. Stage 1 can, and must, before
the shape is committed to.

*Associations are not a rounding error.* 9,372 of them against 56,935 journeys.
§6 still accepts ignoring them for v1, because that matches what the app shows
today, but the gap is bigger than "a few splits".

*3,695 CRS-bearing locations against the app's own 2,619 stations.* The reference
file is a superset, so the join is safe. Anything the app does not know is simply
not looked up.

**Two bugs stage 0 caught, both of the quiet kind.**

The counter over-counted 284 intermediate stops out of 392,050, by counting a
greedy match twice when a chunk boundary fell inside an element. It now counts by
absolute start offset and never counts one start twice. Every pattern is checked
against a whole-file ground truth at seven chunk sizes, from one byte to 63 MiB.

The sizing figure conflated public *times* with public *calls*. An intermediate
stop carries both an arrival and a departure, so adding the attribute counts
roughly doubled it — and stage 2 squares that number. 15.6 calls per journey was
really 8.4.

Neither would have failed loudly. Both would have sized the store wrong.

### Stage 1 — Parse to a snapshot

Offline only. File in, file out, on disk. No app code touched.

- Parse `_ref_v3` into a TIPLOC → CRS table.
- Stream `_v8` — do not hold it in memory as one tree.
- Keep passenger trains. Drop buses, ships and freight, or badge them the way
  `isReplacementBus` already does.
- Keep only stops that have a public time **and** a CRS.
- Drop journeys left with fewer than two public calls.
- Carry the cancellation flag through. The file has it, and it is free.

Output: one normalised snapshot per service day.

Gate: spot-check ten journeys against what LDBWS says for the same trains.

**Built, 10 September 2026.** `scripts/darwin-parse.mjs`, run with
`npm run darwin:parse -- --file ~/Downloads`; the parsing itself is in
`scripts/lib/darwin-parse.mjs` so it can be tested. It uses a real streaming SAX
parser, writes one NDJSON file per service day, and touches nothing the app
reads. `--dry-run` reports without writing.

**Dates come from `lib/serviceDay.ts`.** The script imports the app's own module
rather than restating the rule. That is not tidiness: see the boundary finding
below.

### Stage 1 results

| | |
|---|---|
| Journeys in the file | 56,935 |
| Kept | 43,598 — 77% |
| …of those, buses | 6,960, badged not dropped |
| …conditional (Q) | 719 |
| Dropped, not a passenger service | 12,612 |
| Dropped, ship | 501 |
| Dropped, cancelled outright | 34 |
| Dropped, under two calls | 190 |
| Public calls kept | 478,887 |
| Calls dropped for having no CRS | 357 — junctions, sidings, depots |
| Parse time | 2.5 s |
| Snapshot written | 122.6 MiB as NDJSON, 4.9 MiB gzipped per day |

**Calls per journey: mean 11.0, median 10, p90 20, p99 30, max 39.** Stage 0's
8.4 was taken over every journey in the file including the non-passenger ones,
which carry almost no public calls and dragged the mean down.

**The per-station board costs 3,372,333 rows.** Stage 0 estimated 1,789,456. It
was **1.88× too low**, for the two reasons above: the wrong mean, and squaring a
mean to price a convex cost. The warning stage 0 wrote — "treat that as a floor"
— was right, and the gap is larger than it reads.

### Two findings that change decisions

**1. Bucketing by `ssd` would put 438 late trains on the wrong day.** This is the
important one. A journey's `ssd` is the calendar date it starts, so a train
leaving King's Cross at 01:07 carries `ssd="2026-09-06"`. Under the 03:00–02:59
service day that train belongs to **5 September**, which is the board a passenger
standing on the platform at one in the morning is asking about. 438 of 43,598
journeys differ this way. They are, without exception, the small-hours services
— which is to say they are the last trains home, and the last train home is the
entire product. Every call is therefore bucketed by its resolved London instant,
never by `ssd`.

**2. Non-passenger journeys cost almost nothing to drop.** 12,612 of them, but
they carry operational stops (`OPOR`, `OPIP`, `OPDT`) rather than public ones, so
removing them costs about 1,500 public calls out of 480,768. The filter is nearly
free and it is worth keeping strict.

### Gate

Passed on the parser, not yet on the data.

- Ten journeys — the longest, the shortest, buses, midnight-crossers — pulled
  from the raw XML with no parser involved and compared field by field. All
  match.
- 1,144 journeys cross midnight. Across all 43,598, **zero times run backwards**.
- Every journey's service day re-derived independently and checked. All correct.
- The feed carries 2,734 CRS the app could show against the app's own 2,619:
  136 in the feed the app does not know, 21 in the app absent from this file.
  Both counts are small and in the safe direction.

**The reference file barely moves, but must still be fetched.** Four days apart
(6 to 10 September) it gained three sidings with no CRS and changed one real
entry: Balgray went from a bare code to a name and an operator. So a stale
reference file mostly works, which is exactly what makes it dangerous — a station
that opened in between is simply absent, with no error. Fetch it with every
timetable; at 212 KiB it costs nothing.

That mismatch is easy to create by accident and was found by doing it: a
downloads folder holding several days lets the newest timetable and the newest
reference be days apart, and the pair looks entirely reasonable.
`scripts/darwin-parse.mjs` now compares the two generation stamps and says so. It
warns rather than refuses, because an old reference file is usually still usable.

### The LDBWS cross-check, run 10 September 2026 at 23:45

Run against a same-day file, at the hour the app is actually for. Twelve
stations, 113 live services with a scheduled departure.

| | |
|---|---|
| Exact match, time and destination | 112 |
| Cancelled live, correctly absent | 6 |
| Not in the snapshot | 1 |

The one miss is the 00:48 Paddington to Reading. The file marks it cancelled;
the live board has it running on time. It was reinstated after the 02:05
snapshot, which is the file behaving exactly as §2 says it does. It is an
argument for the seam rule in stage 4, not against the ingest.

**The check found a real bug, and it was the dangerous kind.**

A train cut short carries **two** destinations. A c2c service planned through to
Shoeburyness now terminates at Laindon for engineering work, so the file holds a
`<DT>` for Laindon in the middle of the journey, then the original stops onward
to Shoeburyness — every one of them `can="true"` — and a second `<DT>` at the
end. Taking the last call as the destination reads that as a train to
Shoeburyness calling at Southend. **It does not go there.** On a last-train board
that is the worst answer the app can give: it strands someone at Laindon at one
in the morning.

The parser now ends a journey at its first uncancelled `DT` and drops cancelled
calls outright. On a weekday file that is 79 journeys terminating early, 3,141
cancelled calls and 299 stops beyond a terminus. Every one of them would have
been shown as reachable.

Nothing in the counting caught this. Stage 0 counted `<DT>` elements and found
44,354 against 44,364 origins — near enough to equal to look right, and a
mid-journey `<DT>` is invisible in a total. It took a comparison against a live
board to see it.

### A sixth bug, found on the deployment itself

Minutes after the first deploy, Upminster to Southend answered `later=1` with
the **live** board and no `source` field, while Clapham Junction — which had
nothing cached — correctly returned 69 scheduled trains.

`answerKey` names the nought-to-two-hour answer, and the general cache was read
**before** the later branch, so a `later=1` request could be handed the very
trains the caller already has. It had always been that way; it only became
consequential once the later window started working.

And it is not merely wrong. The client appends by service id, finds every train
already on screen, appends nothing, and concludes the window is exhausted — with
no notice, because nothing failed. **The silent failure again, wearing a
different costume.** Fixed by not consulting the live board's cache for a later
request at all.

### Weekday numbers, after the fix

The measurements above are from a Sunday-into-Monday file. A weekday file is the
worse case and is what the store must be sized for.

| | Sun 6 Sept | Thu 10 Sept |
|---|---|---|
| Journeys in the file | 56,935 | 69,014 |
| Kept | 43,598 | 51,759 |
| Public calls kept | 478,887 | 597,738 |
| Calls per journey, mean | 11.0 | 11.5 |
| Journeys terminating early | — | 79 |
| **Per-station board rows** | 3,372,333 | **4,334,535** |

**4.33 million rows is the number stage 2 has to answer for.** Stage 0 said
1,789,456. It was 2.42× too low.

### Stage 2 — Build the query shape

The app asks two questions. Build for exactly those and no more.

- Fast Train: every direct train from A to B on a date, with an arrival.
- Last Train: every departure from a station in a direction, for a whole service
  day.

Both are answered by a **per-station day board**: for each CRS and service date, the
departures from that station, each carrying its own onward public calls. This is
deliberately the same shape `GetDepBoardWithDetails` returns, so the routes cannot
tell where a board came from.

Onward calls are duplicated across the stations a train passes through. That is
the trade — storage for a one-read lookup. Stage 0's numbers say whether it is
affordable. If it is not, fall back to two keys: one journey record per train,
plus a light per-station index of run identifiers.

Gate: measure the total stored size before writing any of it to a live store.

**Built, 10 September 2026.** `scripts/darwin-board.mjs`, run with
`npm run darwin:board -- --file ~/Downloads`; the pivot and the encodings are in
`scripts/lib/darwin-board.mjs`. It writes nothing and talks to no store. It
builds every board in memory, proves the encoding round-trips, and weighs it.

### The answer: rows were the wrong unit

4.33 million rows sounded like a problem. It is not, because a packed row is
seven bytes.

| Encoding, one full service day | Size |
|---|---|
| Verbose JSON, as stage 1 writes it | 120.9 MiB |
| Compact JSON, short keys | 39.0 MiB |
| **Packed text** | **27.4 MiB** |
| Packed and gzipped | 8.2 MiB |

Two service days live is **54.9 MiB across about 2,728 keys**, against a 256 MiB
free tier. It fits more than four times over.

**The number that could have vetoed the shape is the largest single value.**
A shared store caps how much one request may carry, and Clapham Junction is the
board that finds it: 1,950 departures, **212 KiB packed**. The Upstash limit is
1 MiB. It clears it with room, so the one-read design survives.

**Do not gzip yet.** It would save 19 MiB a day, and the headroom does not need
it. Compression costs readability — a board you cannot read in a terminal is a
board you cannot debug — and it stays a one-line change for the day the numbers
get tight.

**The fallback shape is rejected, on round trips rather than bytes.** One record
per journey plus a light index is 8.5 MiB a day against 27.4, but answering Fast
Train then means reading an index and fetching each candidate journey
separately. The per-station board answers the same question in one read. Three
times the bytes for one round trip is the right trade at this size.

One thing to keep in view for stage 3: a Fast Train lookup at Clapham Junction
reads 212 KiB to show fifteen trains. Sharding a board by hour would cut that,
at the cost of Last Train needing several reads for a whole day. Not worth
building until it hurts.

### Stage 2 found the same bug again, in a new place

Stage 1 found that a train cut short carries two destinations. Stage 2 found
that **a stop is not automatically one a passenger may use**.

The activity code on each call says which of two separate things is allowed:

- **Take up only** (`U `). You may board, you may not get off. The 23:33 King's
  Cross to Leeds is take-up-only at Stevenage.
- **Set down only** (`D `). You may get off, you may not board. The same train
  is set-down-only at Peterborough, Grantham, Newark and Doncaster.

A weekday file holds 1,622 calls you cannot board and 1,059 you cannot leave.
Untreated, the board would have offered a departure from Peterborough on a train
that will not pick anyone up there, and offered Stevenage as a Fast Train arrival
on a train that will not put anyone down.

The pivot now refuses to make a departure out of a stop nobody may board, and
carries a flag on every onward call for whether a passenger may get off. The flag
is kept rather than the call dropped, because a detail sheet still lists it as a
calling point — it is Fast Train that must not treat it as reachable.

Checked across the whole corpus: 544,367 departures offered, **zero** from a stop
that cannot be boarded, 1,736 onward calls flagged.

### The shape stage 3 will store

One key per station per service day. The value is one line per departure:

```
<minute>	<rid>	<toc>	<platform>	<flags>	<destination>	<onward calls>
```

`minute` counts from midnight opening the service date and keeps counting past
it, so 02:30 the next morning is 1590 and a board sorts as plain numbers with no
date handling where it is read. Each onward call is a fixed eight characters:
three of CRS, four of minute, one flag that is `.` normally and `u` where a
passenger may not get off.

The encoding is proved to round-trip exactly across all 6,012 boards on every
run, because a packed format that cannot be read back would not fail until
stage 3.

### Stage 3 — Store and serve

New module, `lib/timetable.ts`. It **returns `NormalizedService`** — the type
`lib/darwin.ts` already exports. That is the whole point. The routes get a board;
they do not learn a new vocabulary.

It reads. It never fetches from S3 and never parses XML. The job writes; the app
reads.

Every stored board carries the **generation time of the file it came from**.

**Built, 11 September 2026.** Three files, and the split between them is the
point.

| | |
|---|---|
| `lib/timetablePacking.ts` | The format, and the shaping into `NormalizedService`. Pure. |
| `lib/timetable.ts` | The read half. `server-only`, talks to Redis. |
| `scripts/darwin-publish.mjs` | The write half. `npm run darwin:publish`. |

**The format has one definition.** The ingest writes it and the app reads it, so
a second copy is a second chance for the two to disagree — and a disagreement
would not fail, it would serve a board with the wrong times on it.
`scripts/lib/darwin-board.mjs` imports the app's module rather than restating
it, which also puts the format under `npm test`.

### What the writer gets right on purpose

- **Meta is written last.** It names the snapshot the app reads. Written first, a
  run that dies halfway advertises a complete snapshot over a half-written one.
- **Every board expires after 72 hours.** Each day's run rewrites them, so a time
  to live costs nothing while the job is healthy, and empties the store within
  three days if it stops. A store that empties says so; one still serving
  four-day-old boards does not.
- **A mismatched pair is refused, not warned about.** The measurement scripts warn
  when the timetable and reference come from different publishes. This one writes
  what the app serves, so it stops.
- **Age is measured from Darwin's generation time**, never from when the ingest
  ran. A job cycling happily against a feed that stopped delivering four days ago
  would otherwise report itself fresh for ever.

### What the reader refuses to do

`timetableBoard` never returns an empty array to mean "I do not know". It returns
one of `ok`, `stale`, `unconfigured`, `missing` or `error`. The fault this whole
ingest exists to remove was a silent one — a refused request left Fast Train
short with no message — and returning `[]` for an unconfigured store would
rebuild that fault behind a new door. Stale means older than thirty hours, which
is at least one missed publish.

### Stage 3 found three bugs in code that already shipped

**1. `toFastService` refused journeys of zero minutes.** The test was
`alighting <= boarding`, commented as catching a journey that ends *before* it
starts. Equal is not before. The 05:13 Stonebridge Park leaves Harlesden at 05:21
and reaches Willesden Junction at 05:21, and the app was hiding it — a real
journey, and the fastest way between those two stations. Now `<`.

**2. `toFastService` did not know about alighting.** Stage 2 established that a
take-up-only stop must never be offered as somewhere you can get to. The flag was
carried all the way to `NormalizedStop` and then ignored by the one function that
decides reachability. Only an explicit `false` refuses, so the live Darwin path —
which never states it — is unchanged.

**3. `DarwinError` could not be imported by a test.** It used a TypeScript
constructor parameter property, which Node's type stripping cannot compile, so
`lib/darwin.ts` was unreachable from `npm test` entirely. Declared and assigned
instead; behaviour identical.

### `npm test` now reaches the server-only modules

It runs with `--conditions=react-server`, which is what that condition is for:
`server-only` resolves to an empty module instead of throwing. Before this,
importing any module guarded by it failed, which is why `lib/darwin.ts` had no
tests despite holding the ranking and pricing rules. 119 tests became 149.

### Gate

Everything but the Redis hop, on the real 11 September file, through the app's
own modules:

| | |
|---|---|
| Boards packed and read back | 6,012 |
| Services shaped | 544,367 |
| Destinations priced | 4,329,002 |
| Destinations refused | 1,736 |

Every refusal was a stop a passenger cannot get off at. No time ran backwards.
`npm test` 149, typecheck clean, `npm run build` clean.

**Not yet done: the live publish.** It needs `KV_REST_API_URL` and
`KV_REST_API_TOKEN` locally, which the deployment has and this machine does not
(`vercel env pull .env.local`). `npm run darwin:publish -- --file ~/Downloads
--dry-run` reports exactly what it would write: 6,013 keys, 57.1 MiB, largest
value 219 KiB.

### Stage 4 — Cut Fast Train's later window over

This is the fix.

- `/api/v2/fast?later=1` reads `lib/timetable.ts`. Nine RTT calls become zero.
- Delete the RTT tail and `LATER_BUDGET`.
- **The window stops being silent.** If the snapshot is missing or stale, the
  response says so and the client shows it. A refused burst leaving you on three
  pages with no message is the fault we are removing, so a stale store must not
  reproduce it in a new costume.
- Rule at the seam: **0–2h is LDBWS, past 2h is the timetable.** A timetable train
  is never presented as a live one.

Gate: `?later=1` returns a full 2–4h window on a busy route with no upstream RTT
request, and returns a named error when the store is empty.

**Built, 11 September 2026.** The RTT tail is gone. `LATER_BUDGET` is gone with
it, because there is nothing left to budget: the stored board already carries
each train's calling points, so a window costs **one read and no upstream
request** where it used to cost about nine.

### The window cannot fail quietly any more

Two fields carry it, one on the board and one on each train.

`notice` is a sentence to show as it is. **An empty `services` with a notice means
"could not find out"; an empty `services` without one means "there are none".**
Those are different answers and the app no longer shows them the same way. The
server writes the sentence because the server is the only thing that knows which
of four ways it failed — a store nobody configured, a publish that never ran, a
store refusing connections, and a snapshot gone stale all need different things
done about them, and the person reading is often the person who can do them.

`source` says `live` or `timetable`, and `isScheduled` marks each train past the
two-hour horizon. They matter because the two sources are appended into one list
on screen: without a marker a schedule would sit beside a live departure looking
equally sure of its platform and its punctuality.

**The client no longer swallows it.** `loadLater` used to catch and discard, which
is how a refused burst left the board on three pages with nothing said. It now
sets `laterNotice` from the board, and marks the window exhausted **only when the
window actually answered** — claiming "that is all of them" on an answer never
received is the precise failure being removed. `FastBoardView` shows the notice
where the loading row was.

A stale board is still served, because scheduled times a day old beat no answer,
but it is not cached, so the next publish is picked up at once. None of the four
failure states is cached either: each is a condition that can be fixed in a
minute, and an hour of a cached apology would outlive the fix.

### Gate, run 11 September 2026

**Published for real**: 6,012 boards and the meta key into the shared store,
544,367 departures, 72-hour expiry. The snapshot read back at 23.4 hours old,
inside the thirty-hour staleness line.

A 2–4 hour window, taken from a representative evening so the window sits inside
the service day:

| Route | Direct trains | Time | Store reads | Upstream requests |
|---|---|---|---|---|
| Clapham Junction → Waterloo | 61 | 327 ms | 1 | 0 |
| Paddington → Reading | 17 | 133 ms | 1 | 0 |
| Upminster → Southend Central | 11 | 49 ms | 1 | 0 |
| Fenchurch Street → Shoeburyness | 10 | 42 ms | 1 | 0 |
| King's Cross → York | 3 | 47 ms | 1 | 0 |
| Manchester → Leeds | 2 | 124 ms | 1 | 0 |

**Sixty-one trains on the busiest route, for one read and no upstream request.**
The old path would have needed about nine RTT calls to return a handful, and
would have been refused for the burst.

The failure path, checked before publishing, against a store with no snapshot in
it:

```
{"source":"timetable","services":[],"candidates":0,"truncated":false,
 "notice":"No timetable has been published for today yet."}
x-cache: SKIP   x-window: later   cache-control: no-store
```

And the live route after publishing, at 02:25 with the service day ending at
02:59: empty services, `notice: null`, in 0.35 s. That is the right answer, and
the absence of a notice is what says so — there genuinely are no trains in a
window that falls outside the service day, as opposed to not being able to find
out.

`npm test` 149, typecheck clean, `npm run build` clean, `swift build` clean.

**One thing stage 7 must plan for:** publishing 6,012 keys took about forty
minutes from this machine, throttled by the store rather than by the work — the
parse itself is eight seconds. A runner on better network will do better, but
the job should be assumed slow and must never be left half-written, which is why
meta is written last.

### Stage 5 — Let four hours fit on screen

The client holds fifteen trains, three a page over five pages. A busy route
spends ten of those in the first two hours, so the board covers about two and a
half hours even when the fetch works. Raise the cap. The trains cost nothing now.

This is an iOS change in `FastModel` and `FastBoardView`, not a server one.

**Built, 11 September 2026.** `maximumPages` is seven, so the board holds
twenty-one trains.

**Twenty-one is counted, not chosen.** Across 2,212 real station pairs with
direct service, taken from the published snapshot:

| From | Median | p75 | p90 | p95 | Max |
|---|---|---|---|---|---|
| 08:00, four hours | 5 | 8 | 16 | 19 | 91 |
| 13:00 | 5 | 8 | 16 | 18 | 92 |
| 18:00 | 4 | 8 | 16 | 17 | 84 |
| 22:00 | 2 | 4 | 7 | 9 | 49 |

A cap of fifteen cuts 13% of daytime pairs short. Twenty-one cuts 3%, and
twenty-four cuts the same 3% — the curve flattens at twenty-one, so that is the
number.

The old cap did more damage than the arithmetic suggests. `canLoadLater` refuses
to fetch the later window **at all** when the cap is already full, so on a busy
route the board never reached past two hours, whatever the window would have
returned. Since the ranking is by arrival and a 2–4h train can never beat a 0–2h
one, later trains only ever append — which is exactly why raising the cap is the
fix rather than a workaround.

`PATTERN_BUDGET` on the server stays at fifteen deliberately. It prices the RTT
fallback, where each train is a separate upstream request, and that path is only
reached when Darwin is down. The timetable path has no per-train cost at all.

**Scheduled trains now say so.** A row past the live horizon reads
`22 min · c2c · plat 1 · scheduled`, and VoiceOver says it too — a caveat only
sighted users get is not a caveat. The platform is kept, because a planned
platform is usually right and worth having; the word is what stops it being read
as a promise. This is the seam rule from stage 4 finally reaching the screen.

### Gate

The app was built against the stage 4 server and run on an iPhone 17 simulator.
Fast Train answers from it: Grays to Barking, the 04:46 to Fenchurch Street,
22 minutes.

Six tests were added for the wire contract, and they are the durable part: that a
notice survives, that `isScheduled` defaults to **live** when absent, that a board
from an older deployment still decodes, and — the one that matters — that an
empty board **with** a notice and an empty board **without** one are two different
answers.

`swift test` 123, of which the only failure is a pinned-glance test that was
already failing on `main` before any of this work and is unrelated to it.

**Not seen on screen: the `scheduled` suffix and the seventh page.** Both need a
route with trains in the 2–4 hour window, and the run was at 02:28, when the
service day ends at 02:59 and no such window exists. The code paths are covered by
tests; the look of them wants a daytime run.

### Stage 6 — Last Train off RTT

Optional, and clearly later. Last Train needs a whole service day, which is why
it never moved to LDBWS. The timetable gives it one.

Whole-day board from the store, live overlay from LDBWS inside the near window.
Red still means last train, and it still comes from the timetable rather than a
guess.

### Stage 7 — Automate and watch it

Two halves, and they fail differently.

**Delivery.** Set up a file transfer on the product page so RDM pushes each new
file into a destination we own. Until this exists, stages 1–6 run on a file
fetched by hand, which is fine for building and useless for running.

**The job.** A daily cron that reads the newest delivered file, parses it, and
writes the boards. Twice daily if stage 0 shows the file is republished through
the day. It must be re-runnable and idempotent: a retry writes the same boards.

**The watch, which matters more than usual here.** Extend `/api/cache-health`, or
add a sibling, reporting **snapshot age** and which service dates are covered.
Age is the right signal because the likeliest failure is silent: a new product
version unlinks the destination and the files simply stop arriving. A job that
exits zero having found nothing new looks identical to a healthy one. Age does
not.

**Built, 11 September 2026.** Two of the three halves.

`GET /api/timetable-health` reports the snapshot's id, when Darwin generated it,
its age in hours, whether that is past the thirty-hour line, which service days
it covers, and how many boards and departures it holds. A sibling of
`/api/cache-health` rather than part of it: that one asks whether the cache
works, and an empty cache is merely cold; this asks whether the store is
current, and an empty store is broken. It reveals no credentials.

`.github/workflows/darwin-ingest.yml` runs at 03:20 UTC daily, and can be run by
hand for a failed night — the publish is idempotent, so the same file in means
the same keys out. Four things it does deliberately:

- **`npm test` before publishing.** A parser that has stopped agreeing with
  itself must not write boards.
- **A concurrency group.** Two publishes at once would interleave their writes
  and race on the meta key that names which snapshot the app is reading.
- **A sixty-minute timeout**, set for the bad day. The parse is eight seconds;
  the writes were forty minutes from a home connection.
- **It reads the snapshot back from the deployment afterwards, and fails if it
  is not healthy.** The job exiting zero proves nothing — a run that found
  nothing new would exit zero too. The store's own age is the proof.

`scripts/darwin-publish.mjs` grew a `--bucket` mode so the job can run
unattended, and the source resolution that three scripts had each grown a copy
of now lives once in `scripts/lib/darwin-source.mjs`.

**Still to do: delivery.** Nothing is scheduled to put a file where the job can
read it. Until that exists the workflow will run and fail, correctly, saying the
bucket is empty.

---

## 4. Where it runs — the one decision

Two questions, and only the second is open.

**Where the file lands is decided for us.** RDM pushes to a destination we own,
so this needs an S3 or GCS bucket, an Azure container, or an SFTP server. S3 is
the closest fit: the job can read it with an IAM user, and the marketplace guide
prints the exact bucket policy. Storage is one file a few times a day, which is
pennies. **Defer creating it until stage 7** — stages 0 to 6 run on a hand
download, and the account is easier to justify once the numbers are known.

**Where the parse runs is the real choice.**

**Option A — GitHub Actions cron reads the bucket and writes Upstash Redis.**
Recommended. The repo is already on GitHub. Actions gives hours of runtime and
real memory, which a 48-hour national XML file wants. Redis is already wired into
`lib/cache.ts` and the app already reads it. Vercel never sees the parse, and the
AWS credentials live in one place that is not the serving app.

**Option B — Vercel Cron calls a route that parses and writes.** One platform,
fewer moving parts, credentials in one place. But it puts the parse inside a
serverless function, and a failure there is a failure of the thing serving the
app.

**Still A, but for a different reason than first written.** The original case
against B was size, and stage 0 undercut it: 62.8 MiB uncompressed, scanned in
under a second, is not obviously beyond a serverless function. What survives is
blast radius and credentials. The job holds keys that can read a private bucket
and rewrite every board the app serves; that does not belong in the request path
of the app itself. The parse is a build step, not a request.

---

## 5. Rules this must keep

These are settled elsewhere in the repo. The ingest does not get to reopen them.

- **The service day is 03:00–02:59**, and times arrive with no timezone marker.
  They are London wall-clock. Reuse `lib/serviceDay.ts`. Do not write new date
  handling. This combination already caused one production bug.
- **No CRS is ever typed by hand.** The mapping comes out of the reference file,
  the way the station list comes out of the API.
- **Red means last train and nothing else.**
- **The app is a departure board, not a journey planner.**
- `npm test` runs under `TZ=UTC` on purpose. New tests run there too.

---

## 6. Known gaps, accepted

- **Associations.** Splits and joins are in the file, but v1 treats every journey
  as its own train. A portion that divides is not followed. This matches what the
  app shows today, so it is not a regression. Revisit only if a real route breaks.
- **Cancellations after the snapshot.** The file carries cancellations as of its
  generation time. Something cancelled afterwards still shows in the 2–4h window.
  Acceptable: past two hours the app is answering a schedule question. LDBWS
  covers the near window, where it matters.
- **Non-passenger services.** Filtered out. If a badge is wanted later, the flag
  is already carried.

---

## 7. Done means

1. Fast Train shows a full four hours on a busy route.
2. It costs zero RTT requests to do it.
3. An empty or stale store produces a visible message, never a short board.
4. A timetable train is never shown as a live one.
5. The snapshot age is readable from a health endpoint.
6. `IOS.md` §2 is corrected.
