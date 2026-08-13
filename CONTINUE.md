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

**Work is on the branch `main-ms16uk`, not `main`.** Four commits ahead of it, all
pushed. `git fetch origin main-ms16uk && git checkout main-ms16uk`.

**The two iOS changes are built and verified — 12 August 2026.** They had been written
on Linux with no Swift toolchain and never compiled; they compile clean, and all four
behaviours were driven on an iPhone 17 Pro simulator against the deployment (Release, so
no dev server was needed):

1. The date steps a day, `TODAY` appears, and the date **holds its position** — the
   control is right-anchored, so the second tap lands where the first did.
2. Changing direction on a future day **keeps** the day.
3. The fifth day shows a return arrow in place of the chevron, and the next tap rounds
   to today.
4. Fast Train's pager is in the **masthead**, above the fold; the last page rounds back
   to the first, and `NOW` appears without shoving the counter sideways.

`swift test` still passes, 108 tests. Nothing is uncommitted — the four commits on this
branch are the same ones that were already pushed.

**The next task is `IOS.md` §9 step 7: the paid RTT token, attribution, and
submission** — plus the two *Exposure* decisions in `STATUS.md`, which are cheap now and
awkward once the app is public.

Two traps worth keeping in view, both in `STATUS.md`: Xcode's Run button builds Debug and
Debug points at `localhost:3000`, so run `npm run dev` or switch the scheme to Release.
And testing costs upstream requests — a cold board is two line-ups and a cold Fast Train
lookup is up to nine. That was tight against the free tier's 10/minute; the Team plan is
now live, so the binding number is the weekly one, `25000 ÷ 7`.

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
