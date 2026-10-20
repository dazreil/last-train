# London Underground — roadmap, parked 26 September 2026

Add the Tube to Last Train, inside the same app. Decided: **no region lock.** Tube
stations are searchable from anywhere, marked as Underground, and ranked nearer first.
Parked for later, because it needs a lot of testing. Nothing here is built.

Why inside the app: a journey home often mixes Tube and rail, and the question is the
same — the last train, and the fastest one. Why no region lock: the people who most need
the last Tube are visitors to London, and a lock would hide it from them.

---

## The data

**TfL Unified API**, free. Register at api-portal.tfl.gov.uk for an app key; the free tier
allows 500 requests a minute. The key stays on the server, like the RTT token.

| Need | Endpoint |
|---|---|
| Every Tube station | `/StopPoint/Mode/tube` (about 272 stations; ids like `940GZZLUOXC`) |
| Live arrivals at a station | `/StopPoint/{id}/Arrivals` or `/Line/{line}/Arrivals/{id}` |
| First and last trains | `/Line/{line}/Timetable/{fromId}` |
| Line status (closures, delays) | `/Line/Mode/tube/Status` |
| Night Tube | Shown in the timetable for Friday and Saturday nights |

**Licence rules:** show "Powered by TfL Open Data" with the other credits. Do not use the
TfL roundel, and do not look official. Line names are fine.

The Elizabeth line, the Overground and the DLR's rail links already come through National
Rail and work today. This adds the **Underground** only. The DLR and trams can follow the
same way later.

---

## Decisions already made

1. **No region lock.** See above.
2. **Two entries where a station is both rail and Tube**, for example "Paddington" and
   "Paddington (Underground)". The boards stay clean, and the Tube gets the board it needs.
3. **The Tube board is by line, not by compass.** People think "Central line, eastbound",
   not "east". TfL's own platform names already say "Eastbound — Platform 1".

## Decisions still open

- **Codes.** Tube stations have no CRS code. TfL's short codes (`OXC`) can clash with rail
  CRS codes, so the app needs a prefix or its own scheme, for example `LU:OXC`.
- **Fast Train on the Tube.** Ranking by arrival needs journey times between stations.
  The timetable has them, but this can wait for a second step.
- **Line colours.** Useful for telling lines apart. Check TfL's brand rules first; if in
  doubt, use line names only.

---

## Steps

### 1. Station list
- A generator script that fetches the Tube stations and writes them next to
  `data/national.json`, each marked as Underground, with its lines.
- It refuses to write if a station is missing a position or a line, like the rail
  generator.
- Name clashes are listed by the script, so each one can be checked by hand.

### 2. Server
- `GET /api/v2/tube?station=…&line=…&direction=…`: the last trains of the night from the
  timetable, the first trains back, and live arrivals within the next half hour or so.
- Cached in Redis like the rail boards. The TfL key is used only on the server.
- Line status on the same answer, so a closed line says so in words rather than showing
  an empty board.

### 3. Search
- A small "Underground" tag on Tube stations.
- Nearer first: rank by the rough area the phone was last in (from the last nearest-station
  lookup or the home station), never by an exact position.
- The nearest-station arrow and "Popular" stay local, as they are now.

### 4. App
- The Tube board: pick a line, then a direction, then see the last trains and live
  arrivals. Red is still the last train only.
- Night Tube: on Friday and Saturday, lines that run all night say so, rather than showing
  a "last train".
- Follow, the widget and the Live Activity reuse the rail versions.

### 5. Credits, privacy and the listing
- "Powered by TfL Open Data" in Settings and on the website.
- The privacy page does not change: no new data is collected.
- Add the Tube to the App Store description and keywords.

---

## Testing — the reason this is parked

- **Name clashes:** every clash from step 1, searched from inside London and from outside.
- **Interchange stations:** Paddington, Liverpool Street, Stratford, Victoria, King's Cross
  and others show both entries, clearly different.
- **The service day:** the Tube's last trains are around 00:30, earlier than much of rail.
  Check that the board rolls to the first train back at the right moment.
- **Night Tube:** Friday and Saturday nights on the Night Tube lines, and the same lines on
  a weekday.
- **Closures:** a weekend engineering closure, and a line suspended during the day.
- **Branches:** the Northern line (two branches through central London) and the District
  line (several ends), where "eastbound" alone is not enough.
- **Live arrivals:** trains that TfL lists and then drops, and the "at platform" state.
- **Rate limits:** a busy evening, within TfL's 500 a minute across all users.
