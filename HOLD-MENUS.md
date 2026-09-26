# Hold menus

**Status:** built, 24 September 2026. Both decisions in §6 taken as option A.

Every button in the journey bar keeps its tap exactly as it is. Holding the button
opens a short menu of related actions. The menus let a commuter jump between the
stations they use without typing, and without adding anything to the board.

---

## 1. The rules every menu keeps

1. **The first item is the tap.** Holding a button always offers its tap action
   first. The menu then teaches what the tap does, and nothing is hidden behind the
   hold that the tap cannot reach.
2. **A hold opens a menu. It never acts by itself.** A hold that did something
   silently would be undiscoverable and easy to trigger by accident on a platform.
3. **Labels name real stations.** "Continue from MKC", not "Slide left". The reader
   is in a hurry and must not have to work out a direction.
4. **No red.** Red means the last train and nothing else (`DESIGN.md`). This
   includes the iOS "destructive" style, which turns a button or dialog action red.
   Use plain buttons and plain words instead.
5. **Nothing costs Realtime Trains quota.** Every menu reads what the phone already
   holds, or makes a request the app already makes. None of them adds an upstream
   request.

### How it is built

SwiftUI's `Menu(content:label:primaryAction:)` does exactly this: a tap runs
`primaryAction`, and a hold opens `content`. It is available from iOS 15, and the
app targets iOS 17. Each of the four buttons in the journey bar becomes one of these,
keeping its 44 × 44 point tap target and its current icon.

Accessibility: the menu is read out by VoiceOver automatically. Each button also
gets the hint "Hold for more options".

---

## 2. The four menus

### ✕ clear (`clearButton`)

| | Item | Does |
|---|---|---|
| 1 | Clear | The tap. Clears the journey to the blank board. |
| 2 | Go home | Straight to the home journey, without passing the blank board. Shown only when a home is set. |

**"Reset to default" is not here.** It moves to Settings (§3). A full reset held
under the button you press to clear, on a platform, one-handed, is one slip from
wiping everything, even with a warning.

### ⇄ reverse (`swapButton`)

Shown only when both ends are set, as now. Example journey: `EUS → MKC`.

| | Item | Does |
|---|---|---|
| 1 | Reverse | The tap. `MKC → EUS`. |
| 2 | Continue from MKC | The end becomes the start and the end is left blank: `MKC → —`. "I have arrived; what can I get from here?" The board asks which way, as it does for any new station. |
| 3 | Trains into EUS | The start becomes the end and the start is left blank: `— → EUS`. Then the start picker opens, listing the stations with a direct train **to** Euston. "What gets me to here?" — for example, meeting someone off a train. |

Item 3 needs no new server work. When the destination is set and the start is
edited, `LinePicker` already lists the stations that reach the destination from the
other side. That is exactly this list.

### ➤ location (`locateButton`)

| | Item | Does |
|---|---|---|
| 1 | Nearest station | The tap. Finds where you are and opens the nearby list. |
| 2 | Most used | Up to four stations, most used first. Tap one to start from it. |
| 3 | Recent | Up to four stations, most recent first, leaving out any already under Most used. |

Items 2 and 3 appear only once there is something to show. Each station row reads
as its name and code, for example `Upminster · UPM`.

### ⌂ house (`homeButton`)

The house always shows on the blank board (§6). With a home set, a tap goes home and
a hold opens the menu. With none, there is nowhere to go, so a tap opens the menu.

| | Item | Does |
|---|---|---|
| 1 | Go home | The tap. |
| 2 | Set home from nearest | Finds where you are, then you pick from the nearby list. |
| 3 | Set home from search | Opens the station search. |
| 4 | Set home from recent | A submenu of your recent stations. |
| 5 | Clear home | Removes the home. The house then stops showing. |

**A home is a station** (`HomeStation`). It was a station and a direction until the
fix below; picking one now sets it at once.

Items 1 and 5 show only when a home is set.

---

## 3. Reset, in Settings

A new row at the bottom of Settings: **Reset app…**

It opens a confirmation dialog that lists what goes, in plain words, with a plain
(not red) **Reset** button and **Cancel**:

- the home journey
- every remembered destination
- the followed train, and any Live Activity
- the station usage record (§4)
- the Last Train / Fast Train mode
- the current journey, which goes back to the blank board

It does **not** touch the lock screen widget's own configuration. That is set on
the widget itself, and resetting the app should not reach into it.

---

## 4. The usage record — build this first

"Most used" and "Recent" both need the app to remember which stations you use. It is
one small record kept on the phone, never sent anywhere.

- **Shape:** station code → how many times it was used, and when it was last used.
- **What counts as a use:** choosing a **start** station yourself — from search,
  from the nearby list, from a hold menu, by reverse or continue, or by going home.
  Not the launch restoring where you left off, which is not a choice.
- **Size:** capped at 50 stations. When full, drop the least recently used. A few
  kilobytes at most.
- **Where it lives:** app-only `UserDefaults`, like `HomeJourney`. The widget does not
  need it.
- **The ranking is pure logic**, so it goes in `LastTrainCore` with tests: most used
  (count, then recency to break ties), recent (recency, leaving out the most-used
  ones), and the cap.

Destinations do not count (§6): "Most used" means "where I usually stand", which is
what the location button is about.

---

## 5. Build order

Each phase ends somewhere it can be left, and each is tested on the simulator and
then on the phone before the next starts.

| Phase | What | Needs |
|---|---|---|
| 1 | The usage record and its tests | — |
| 2 | ✕ and ⇄ hold menus | — |
| 3 | ➤ location hold menu | Phase 1 |
| 4 | ⌂ house hold menu | Phase 1 |
| 5 | Reset in Settings | Phase 1 |

Phase 2 is independent of the record and could go first, if the menus are wanted
before the record exists.

**Each phase is done when:**

- the tap on every button behaves exactly as before
- the hold opens the menu, with the tap's action first
- the board still fits the screen without scrolling
- `swift test` passes, including new tests for anything added to `LastTrainCore`
- `UI-GLOSSARY.md` names anything new

---

## 6. Decisions, taken 24 September 2026

1. **The house with no home set: A.** It always shows on the blank board. With no
   home, a tap opens its menu, since there is nowhere to go yet.
2. **What counts as a use: start stations only.**

---

## 7. As built

All five phases, tested on the simulator: each tap unchanged, each hold opening its menu
with the tap first, "Trains into UPM" giving `FST → UPM` eastbound with the right trains,
a home set from search saved only once its direction was chosen, and Reset clearing the
home, the usage record, every remembered destination and the pin.

Differences from the plan above:

- **"Trains into" leaves the board alone until you pick.** The plan blanked the start
  first. Opening the list over the current board instead means Cancel changes nothing.
- **Its list is the stations reachable *from* the target**, the same list the start
  picker already uses. Direct routes are almost always two-way, and the direction for
  the new journey is still looked up from the picked station, as Reverse does. The list's
  own wording ("Most journeys from here", minutes from the target) is the destinations
  sheet's and reads slightly off in this use. Worth a caption of its own if it confuses.
- **Menu station names drop "London"**, as the board does.

### Fixes after the first build, 24 September 2026

- **Home is a station, not a journey.** Going home used to restore the destination
  remembered under the home's direction, so from `BSO → UPM` "Go home" opened
  `UPM → BSO` — Reverse under another name. Home now sets the start only and the board
  asks which way.
- **Both station codes share one size.** Each used to shrink on its own, so the longer
  code came out smaller and kept its size when the two swapped. The pair now steps down
  a text size together (`ViewThatFits`) until it fits.
- **The board trims its rows to fit.** It measures how far the page overflows and takes
  up to 8 points off the top and bottom of each row to cover it (`RowSqueeze`). Past that
  it scrolls. Fixed trims had each fitted the simulator and not the owner's phone.

### Recent journeys, added 24 September 2026

A journey is a start and a destination; `UPM → BSO` and `BSO → UPM` are two. Kept on
the phone (`JourneyStore`, ranked by `LastTrainCore.RecentJourneys`, tested), twenty
kept and five shown.

- **On the blank board**, under "Tap Where? or the arrow to pick a station": the five most recent, one tap
  each to reopen the board with both ends and the direction.
- **Hold either station code**: the same list, leaving out the journey on screen. The
  codes were the one part of the bar without a hold.
- **A journey you followed a train on ranks higher.** It counts as if used a day later
  than it was, so it rises above anything used in the last day, then settles back.
- Recorded when a destination is picked, on Reverse and Trains into, and when a recent
  journey is reopened. Cleared by Reset.
