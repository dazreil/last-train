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

Node is at `/opt/homebrew/bin/node` and may not be on PATH.

**Work is on the branch `main-ms16uk`, not `main`.** Three commits ahead of it, all
pushed. `git fetch origin main-ms16uk && git checkout main-ms16uk`.

**The next task is: build the two iOS changes in Xcode and verify them.** They were
written in a cloud session on Linux, which has no Swift toolchain, so *nothing in them
has been compiled*. Four files changed, all in the app target — `BoardModel.swift`,
`BoardView.swift`, `FastModel.swift`, `FastBoardView.swift`. No new files, so the
XcodeGen project does not need regenerating. `swift test` covers `LastTrainCore` only
and touches none of it.

What to verify, from the two commits:

1. Tap the date once — it steps a day and `TODAY` appears **without the date shifting
   sideways**. The shift was the bug: it moved the date out from under your finger, so
   the second tap landed on `TODAY` and came back.
2. Change direction while on a future day — the day **holds** now.
3. Step to the fifth day — the chevron becomes a return arrow, and the next tap rounds
   to today. Five days, was seven.
4. Fast Train on a busy pair (Upminster → Southend Central) — `1 OF 3` is now in the
   **masthead** where the date sits, not in a footer below the fold. Last page rounds
   back to the first.

Two traps, both already written down in `STATUS.md`: Xcode's Run button builds Debug
and Debug points at `localhost:3000`, so run `npm run dev` or switch the scheme to
Release. And this testing is expensive on the free tier — a cold board is two line-ups
and a cold Fast Train lookup is up to nine requests, against 10/minute.

**In flight, not in the repo:** the RTT **Team** tier is being bought (see
`PRODUCT.md` § Paying for it), and Rail Data Marketplace registration is pending for
the Darwin spike in `IOS.md` §2. When the Team token lands: set `RTT_ACCESS_TOKEN` in
Vercel and `.env.local`, take a separate dev key, and revisit the three budgets sized
against the free tier's 10/minute — `DETAIL_BUDGET` in `app/api/trains/route.ts` and
`PATTERN_BUDGET` in both `app/api/v2/fast` and `app/api/v2/destinations`. Also
`RATE_LIMIT_PER_MINUTE` in `lib/rtt.ts`, which is exported, never used, and will be
wrong.

---

## If the next task is the iOS app

The licensing blocker is cleared. RTT confirmed on 1 August 2026 that a free App
Store app still needs a **commercial plan**, on call volume rather than on price to
the user, so `IOS.md` §9 can start at step 2. **The tier is Team, £29/month**;
hobbyist at £4 raises no rate limits and so cannot answer a volume requirement. Build
on the free tier and buy the plan at submission — the current token explicitly cannot
ship.

## If the next task is more work on the web app

It's live at `https://last-train-dazreils-projects.vercel.app` and deploys
automatically from `main`. `npm run dev` to work locally, `npm run dev:lan` to reach
it from a phone on the same network.
