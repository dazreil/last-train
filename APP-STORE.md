# App Store listing — draft, 25 September 2026

Copy each field into App Store Connect → LTFT. The character counts are checked against
Apple's limits. Every claim below is true of the app today; if a feature changes, change
the text here too. The privacy answers must match `/privacy`.

---

## App information

| Field | Value | Limit |
|---|---|---|
| Name | `LTFT: Last Train & Fast Train` | 29 / 30 |
| Subtitle | `Last train home. Fastest now.` | 29 / 30 |
| Primary category | Travel | |
| Secondary category | Navigation | |
| Content rights | No third-party content that needs rights. Train times are used under the Realtime Trains and National Rail data licences. | |
| Age rating | Answer **None** to every question → **4+** | |
| Copyright | `2026 Daryl Smith` | |

The name under the icon on the phone stays **Last Train**. The store name can differ.

## URLs

| Field | Value |
|---|---|
| Privacy Policy URL | https://last-train-dazreils-projects.vercel.app/privacy |
| Support URL | https://last-train-dazreils-projects.vercel.app/support |
| Marketing URL (optional) | https://last-train-dazreils-projects.vercel.app/ |

---

## Promotional text (154 / 170)

Can be changed at any time without a new build.

```
Know your last train home before you need it. Follow the train you're catching and the countdown sits on your lock screen. Live delays from National Rail.
```

## Keywords (97 / 100)

No spaces after the commas. Words in the name are searched already, so they are not
repeated here.

```
timetable,departures,rail,railway,uk,live,delays,platform,commute,station,night,countdown,journey
```

## Description

```
Two questions, one app.

LAST TRAIN
What is the last train home tonight, and if I miss it, what is the first one back?

Pick your station and the way you are going. The board shows the last trains of the night, with the very last one in red, and the first train back in the morning. It knows the railway day runs past midnight, so at 00:30 it still shows tonight's last train, not tomorrow's. Look up to five days ahead to plan a night out.

FAST TRAIN
Which train gets me there first?

Choose where you are going. Fast Train lists the next direct trains, ranked by when they arrive, not when they leave. A slower train that leaves first is not the one to catch, and Fast Train shows you that. Delays from National Rail move the ranking as they happen.

FOLLOW YOUR TRAIN
In Fast Train, tap Follow and the countdown goes to your lock screen and the Dynamic Island, with the platform and whether it is on time. If the train runs late, the countdown moves with it. In Last Train, Follow puts that train on your home and lock screen widgets, counting down.

SHARE WHEN YOU'LL BE HOME
Send a friend which train you are getting and when it arrives, from the train's details.

ALSO
• Home and lock screen widgets
• Your recent journeys, one tap away
• Find the stations near you
• Every station in Great Britain, direct trains only

NO ACCOUNT, NO ADS, NO TRACKING
What you save stays on your phone. Your location is only used when you tap the arrow, and it never leaves your phone.

Train times from Realtime Trains and National Rail Enquiries. Popular destinations from the Office of Rail and Road. LTFT is not made by, or linked to, National Rail or any train company.
```

## What's New in This Version (first release)

```
The first release. Your last train home, and the fastest one there.
```

---

## App Privacy

**Data Not Collected.**

Why this is the right answer: the app has no account, analytics or ads, and does not
track. Settings stay on the phone. Location is used on the phone only. The server
receives the station codes being looked up, plus the IP address as every web request
does. It counts requests per address to stop misuse, and the counts are deleted within
about an hour, so nothing is kept or linked to a person.

## App Review notes

```
No sign-in is needed.

The app shows trains in Great Britain. If you are outside the UK, tap "Where?" and search for "Liverpool Street", then pick a direction. For Fast Train, tap FAST TRAIN at the top, pick "Liverpool Street" and then "Stratford" as the destination.

Location is asked for only when you tap the arrow button, to find nearby stations. Live Activities start when you tap Follow on a train in Fast Train.

Train data: Realtime Trains (licensed, Team plan) and National Rail Darwin. The data credits are in Settings (the gear icon).
```

## Export compliance

Already answered in the build (`ITSAppUsesNonExemptEncryption = NO`). Upload nothing
under App Encryption Documentation.

---

## Screenshots

Apple needs one set at **6.9 inch (1320 × 2868)**; it scales them for smaller phones.
The iPhone 17 Pro Max simulator makes them at that size. Suggested five, in this order,
each with a short caption above the phone:

1. **Last Train board, evening, red last train** — "Your last train home, in red."
2. **Fast Train board** — "The train that gets you there first."
3. **Lock screen with a followed train** — "The countdown on your lock screen."
4. **Home screen with the medium widget** — "Tonight's last train, at a glance."
5. **Train details with Share ETA** — "Tell them when you'll be home."

Take them in the evening, so the Last Train board has real last trains to show.

---

## Reply to App Review — Guideline 2.1, Information Needed (26 September 2026)

Paste this as the reply in App Store Connect, **and** into App Review Information → Notes,
as Apple asks. Attach the screen recording to the reply.

```
Thank you. Here is the information requested.

1. SCREEN RECORDING
Attached, recorded on an iPhone 17 running iOS 27.0, starting from launch. It shows: choosing a station, the Last Train board (the last train of the night in red, and the first train back), Fast Train (choosing a destination and the trains ranked by arrival time), following a train so its countdown appears on the Lock Screen and Dynamic Island, a train's calling points, sharing an arrival time through the share sheet, the home screen widget, and the data credits in Settings.
The app has no account registration, login, user-generated content, or paid content or features.

2. PURPOSE AND AUDIENCE
LTFT answers two questions for rail passengers in Great Britain: "What is the last train home tonight, and if I miss it, what is the first one back?" and "Which train gets me there first?". It is for anyone travelling by train in the evening, especially people on a night out or a late shift who need to know when they must leave. Journey planners answer these questions poorly: they plan a trip from a chosen time rather than showing the last direct train of the night, and they list trains by departure time, when a later fast train often arrives before an earlier slow one.

3. HOW TO USE IT
No login or setup is needed.
- Last Train: tap "Where?", search for "Liverpool Street", then tap a direction (for example EAST). The board shows the last trains of the night, the last one in red, and the first train back.
- Fast Train: tap FAST TRAIN at the top, then "Choose a destination" and pick "Stratford". The next direct trains are listed, ranked by arrival time.
- Follow: tap Follow on a Fast Train result. The countdown appears on the Lock Screen and in the Dynamic Island.
- Train details: tap the (i) on any train to see where it calls. The share button at the top left sends which train you are on and when it arrives.
- Nearby: tap the arrow to find stations near you. Location is used only when this is tapped. Outside Great Britain it will say there is no station near you.
- Credits: the gear icon opens Settings, with the data sources.

4. EXTERNAL SERVICES
- Realtime Trains (realtimetrains.co.uk): train times, under a paid commercial API licence (Team plan).
- National Rail Enquiries, Darwin: live departures and the daily timetable, under the National Rail Data Portal licence.
- Office of Rail and Road: station usage figures for the "Popular" destinations, under the Open Government Licence v3.0.
- Our own server on Vercel, with an Upstash Redis cache, which holds the API credentials and passes the train data to the app. No personal data is stored.
No authentication, payment or AI services are used. There are no ads or analytics.

5. REGIONAL DIFFERENCES
The app is available in the United Kingdom only, because its content is trains in Great Britain and it is not useful elsewhere. Within the UK it works the same everywhere. For review from outside the UK, every feature works by searching for a station by name; only the "nearest station" button has nothing to find.

6. REGULATED INDUSTRY OR PROTECTED MATERIAL
Not a regulated industry. The train data is used under the licences listed in point 4, and credited in the app's Settings. The app is not made by, or linked to, National Rail or any train operator, and uses none of their logos or branding.
```

### Recording the video (on your phone)

1. Settings → Control Center: make sure **Screen Recording** is in it.
2. Close LTFT fully (swipe it away in the app switcher).
3. Open Control Center, tap Screen Recording, wait for the 3-second count.
4. Follow the order in point 1 above. About 1½–2 minutes is enough.
5. Stop the recording. It is saved to Photos. Trim the Control Center part at the start
   if you like, but the recording must still start with launching the app.
6. Record **after** the build under review is the one with Share ETA and the bug fixes (build 3), so the
   video matches the app Apple tests.
