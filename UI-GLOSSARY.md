# Last Train — UI Glossary

Plain names for each piece of the iOS UI, and the code name that matches it.
Read top of the screen to bottom. **What you see → `the name`.**

## Top bar
| What you see | Name |
| --- | --- |
| The "LAST TRAIN / FAST TRAIN" title you tap to switch; hold it to refresh | `masthead` |
| The whole "WCF → UPM" area under the title | `stationHeader` |
| The "WCF → UPM" line itself | `journeyBar` |
| Each station code (WCF, UPM); hold for recent journeys | `codeButton` |
| The arrow that finds your nearest station; hold for Most used / Recent | `locateButton` |
| The ⇄ that turns the journey round; hold for Continue from / Trains into | `swapButton` |
| The **×** clear button; hold for Clear / Go home | `clearButton` |
| The house that replaces × on the blank board; tap for the home station, hold to set or clear it | `homeButton` |
| The "WEST / EAST / SOUTH" row | `directionPicker` |
| "Choose a direction or a destination", after a station is picked (Last Train) | `directionPrompt` → `StepHint` |

## The stepper (row like "TODAY MON ›" or "1ST 2ND ›")
| What you see | Name |
| --- | --- |
| The whole row | `dayControl` |
| The button to the next day (Last) or next page (Fast) | `stepButton` |
| The "back to today" / "back to now" button | `todayButton` (Last) / `nowButton` (Fast) |

## One train line
| What you see | Name |
| --- | --- |
| A Last Train line | `ServiceRow` |
| A Fast Train line | `FastRow` |
| The big glowing clock number | `CathodeNumber` |
| The "Follow / Following" button | `FollowPill` |
| The ⓘ that opens train details | `infoMark` |

## Section titles
LAST TRAIN, EARLIER TRAINS, FASTEST TRAIN, LATER TRAINS, FIRST BACK → `sectionHeading`

## Whole boards
| What you see | Name |
| --- | --- |
| The Last Train board | `cathodeBoard` |
| — its normal look | `normalBoard` |
| — its "first trains then last train" look (pre‑service / after midnight) | `preServiceBoard` |
| The Fast Train board | `FastBoardView` |

## Pop‑up sheets
| What you see | Name |
| --- | --- |
| The "From" station search | `StationPicker` |
| The destination list ("West of UPM") | `LinePicker` |
| The train detail / calling points | `ServiceSheet` |

## Messages
| What you see | Name |
| --- | --- |
| "Choose a direction or a destination" / "Choose a destination" (Fast) | `emptyPrompt` → `StepHint` |
| "Tap Where? or the arrow to pick a station", on the blank board | `stepHint` → `StepHint` |
| "Nothing westbound" and other notices | `notice` |
| The recent journeys on the blank board | `recentJourneysList` |
| "Couldn't refresh" banner over the dimmed old board | `staleNotice` |
| "Try again" pill | `retryButton` |
| Grey loading blocks | `loadingBoard` |
| The gear, top right | opens `SettingsView` |
| Settings: home station, credits, about | `SettingsView` (home is `HomeJourney`) |

## The look (background / texture)
| What you see | Name |
| --- | --- |
| The dark glowing background | `CathodeBackdrop` |
| The faint scan lines | `CathodeScanlines` |
| The thin glowing line under a title | `CathodeRule` |
