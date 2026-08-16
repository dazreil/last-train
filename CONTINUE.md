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

**Work on `main`.** `main-ms16uk` was merged into it on 16 August 2026 — a clean
fast-forward, thirteen commits — and is kept only as a fallback. Nothing new should land
on it. **Every push to `main` deploys to production**, which the iOS app talks to, so a
server change reaches the phone without rebuilding anything.

**The iOS work of 12–16 August is built, verified and merged.** Driven on an iPhone 17 Pro
simulator against the deployment, and on device by Daryl:

1. The date walk is `back | here | next` — `TODAY | SUN ›`, then `TODAY · SUN | MON ›`,
   through five days to `THU | TODAY ›`. Days are named, not dated; the right slot names
   where the next tap lands, so the wrap needs no return arrow and no branch.
2. Fast Train's pager mirrors it exactly: `NOW | TWO ›` … `THREE | NOW ›`.
3. The masthead names both modes — `LAST TRAIN` white beside `fast train` faint — and
   white means active everywhere in that bar.
4. Fast Train asks where you are going when you tap a direction, and remembers a
   destination per station *and* direction.

`swift test` passes 112, `npm test` 114.

**The next task is `IOS.md` §9 step 7: the paid RTT token, attribution, and
submission** — plus the two *Exposure* decisions in `STATUS.md`, which are cheap now and
awkward once the app is public.

Two traps worth keeping in view, both in `STATUS.md`: Xcode's Run button builds Debug and
Debug points at `localhost:3000`, so run `npm run dev` or switch the scheme to Release.
And testing costs upstream requests — a cold board is two line-ups and a cold Fast Train
lookup is up to nine. That was tight against the free tier's 10/minute; the Team plan is
now live, so the binding number is the weekly one, `25000 ÷ 7`.

**The Team tier is live**, bought 15 August 2026. No new token was issued — the plan
attaches to the account, so `RTT_REFRESH_TOKEN` is unchanged and the limits rose upstream.
Confirmed from the response headers rather than the invoice.

Two of the budgets it unblocked are done: `PATTERN_BUDGET` in `app/api/v2/fast` is 15,
which is what the app can display, and `RATE_LIMIT_PER_MINUTE` in `lib/rtt.ts` reads 40.
**Still sized against the free tier:** `DETAIL_BUDGET` in `app/api/trains/route.ts` (the
old web route) and `PATTERN_BUDGET` in `app/api/v2/destinations`. Neither is urgent; both
are cheap now. The separate dev key — Team allows five — has not been taken, so testing
still shares production's quota.

**In flight, not in the repo:** Rail Data Marketplace access came through on 15 August for
the Darwin spike in `IOS.md` §2. The product to find is the **timetable feed, not LDBWS** —
§2 explains why the departure-board API structurally cannot answer this app's question.
One finding from the openraildata list worth carrying in: the Push Port is Kafka now, and
the timetable files alone cannot give cancellations or live platforms, which this app
already shows. So "Darwin makes it £0" is true of the last-train question and not of what
the app does today.

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
