# Continuation prompt

Paste this into a new session to resume. It is deliberately short — it points at
the detail rather than repeating it.

---

I'm continuing work on Last Train, an iOS app that answers one question: what is the
last train home, and if I miss it, what's the first one back.

**Read `STATUS.md` first** — the current state, where each answer's data comes from, the
traps that already cost us time, and what is next. Then, as the work requires:
`PRODUCT.md` (product truth), `DESIGN.md` (visual system), `IOS.md` (the iOS spec and
how each part was decided), `DARWIN-INGEST.md` (the timetable store), `UI-GLOSSARY.md`
(what each piece of the screen is called in code).

Please don't re-derive these, they're settled and written down:

- The rail service day runs 03:00–02:59, and API departure times arrive with **no
  timezone marker** — they're London wall-clock. That combination already caused a
  production bug. `npm test` and `swift test` run under `TZ=UTC` on purpose.
- Red means "this is the last train" and nothing else. There is no `--danger` token
  by design.
- No CRS code is ever typed by hand; the generators resolve them.
- The Last Train board never asks where you're going. Fast Train does, as a separate
  mode behind a tap on the title — an approved exception, written up in `PRODUCT.md`.
- Direct services only. Nothing ever suggests a change of train.

Node is at `/opt/homebrew/bin/node` and may not be on PATH. The repo lives at
`~/Last Train`; the old copy in `~/Documents` is a stale backup.

**Work on `main`. Every push to `main` deploys the API to production**, which the iOS
app talks to, so a server change reaches the phone without rebuilding anything.

**Where it stands, 24 September 2026:** the app is built and runs on device — Last
Train, Fast Train to four hours, the widget, the Live Activity, and the destination
picker with a Popular section. RTT Team is paid for. The credit line is in the app. The
API is rate limited (`lib/limits.ts`). The Darwin timetable ingest is live and has been
run by hand; an unattended nightly run is still to be confirmed.

**The next task is App Store submission** — `IOS.md` §9 step 7, after confirming the
information flow end to end. The list is under *Next* in `STATUS.md`.

Two traps worth keeping in view, both in `STATUS.md`: Xcode's Run button builds Debug and
Debug points at `localhost:3000`, so run `npm run dev` or switch the scheme to Release.
And testing still shares production's RTT quota until a separate development key is
taken — which now also means it spends production's rate-limit ceiling.
