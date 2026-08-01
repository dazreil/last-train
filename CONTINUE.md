# Continuation prompt

Paste this into a new session to resume. It is deliberately short — it points at
the detail rather than repeating it.

---

I'm continuing work on Last Train, a personal web app that answers one question:
what is the last train home, and if I miss it, what's the first one back.

**Read `STATUS.md` first** — it has the current state, the API traps that already
cost us time, and what's blocked on what. Then `PRODUCT.md` (product truth,
platform is iOS), `DESIGN.md` (visual system), and `IOS.md` (the approved spec for
the national iOS app) as the work requires.

Please don't re-derive these, they're settled and written down:

- The rail service day runs 03:00–02:59, and API departure times arrive with **no
  timezone marker** — they're London wall-clock. That combination already caused a
  production bug. `npm test` runs under `TZ=UTC` on purpose.
- Red means "this is the last train" and nothing else. There is no `--danger` token
  by design.
- No CRS code is ever typed by hand; the generator resolves them from the API.
- The app is a departure board, not a journey planner. It never asks where you're
  going. That refusal is the product.

Working tree should be clean on `main`. Node is at `/opt/homebrew/bin/node` and may
not be on PATH.

**The next task is:** _[state it here — see the Next section of STATUS.md]_

---

## If the next task is the iOS app

The blocker comes first: email `hello@realtimetrains.com` and confirm in writing
whether a free App Store app counts as commercial use, and what the paid tier's rate
limits are. Nothing in `IOS.md` should start before that answer — the current token
explicitly cannot ship.

## If the next task is more work on the web app

It's live at `https://last-train-dazreils-projects.vercel.app` and deploys
automatically from `main`. `npm run dev` to work locally, `npm run dev:lan` to reach
it from a phone on the same network.
