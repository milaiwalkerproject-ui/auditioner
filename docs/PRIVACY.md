# Auditioner — Privacy policy

*Version 0.3 · 12 October 2026 · applies to the Auditioner app for iPhone and iPad
(test version 0.1.0). Changed in this version: the sections "If you sign in with
Apple" and "Popular with other players".*

Auditioner helps orchestral musicians prepare for auditions. We designed it to
collect as little as possible. You do not need an account (signing in with Apple
is optional, see below), and the app has no ads, no tracking and no analytics.

## What stays on your device

These never leave your iPhone or iPad unless you share them yourself:

- the parts you import or scan into **My parts** (PDFs and images) and your
  Apple Pencil markings on them;
- the reference audio and notation the app makes for you;
- your own practice recordings (record & compare takes and mock auditions) — the
  microphone is used only while you record, and the files are never uploaded;
- the pictures of the parts you scanned, kept so you can correct the notes next to
  the original;
- the start/end marks you set on recordings;
- your settings (instrument, position, region, tuning).

Deleting the app deletes all of this.

## What is sent to our server, and only when you ask

When you choose **read the notes** from a scan, the app sends our server:

- the part of the page you marked (one image),
- your instrument and its transposition,
- the text the app recognised on the page (titles, tempo words), to help
  identify the excerpt,
- a random number created on install, used only to apply the daily scan limit,
- the app's version number.

Our server runs on Google Cloud in the United States. It uses the image only to
read the notes, sends the result back to your device, and **deletes the image
straight away** (at the latest within 24 hours). Images are not stored, not used
to train anything, and **never sent to any AI service**. The random install
number is held in memory only to count scans per day and is not linked to you.

Like every web service, our hosting provider keeps standard technical request
logs (such as IP address and time of request) for up to 30 days for security
and troubleshooting. We do not use them to identify you.

The first time you read notes, the app asks for your permission and explains
this. You can use everything else in the app without ever sending a scan.

## If you sign in with Apple (optional)

You can use the whole app without an account. Signing in with Apple only raises
your daily scan limit (the server allows more scans per signed-in account than
per device). **Skip** is always available, and you can sign in or out at any
time in **Settings → Account**.

When you sign in, the app asks Apple for **no name and no email**, and we never
store either. Our server checks the sign-in with Apple and then stores exactly
this:

- a one-way scrambled code (an HMAC hash) of the identifier Apple gives us for
  you — not the identifier itself, so it cannot be turned back into your Apple
  ID;
- an encrypted key from Apple (a "refresh token") whose only use is to tell
  Apple to disconnect the app from your Apple ID when you delete the account;
- the date the account was created and when it was last used;
- a scrambled code (a hash) of the sign-in session on your device, so the server
  can recognise it, with the dates it was created and last used. A session not
  used for a year stops working by itself.

On your device the app keeps the session key and Apple's identifier for the app
in that device's keychain; they do not move to another device, even from a
backup.

While you are signed in, the app's requests to our server carry the session, so
the server can count your scans against your account instead of your device.
It uses the session for nothing else: feedback and "Popular with other players"
are stored without it. Nothing else in the app changes: your parts, recordings,
notes and auditions stay on your device, and the server never sees them.

**Delete account** (Settings → Account) asks Apple to disconnect the app from
your Apple ID and then deletes the account and its sessions from our server
straight away — there is no waiting period and nothing is kept. If Apple cannot
be reached, nothing is deleted and the app says so; try again a few minutes
later. Deleting the account does not remove anything from your device.
**Sign out** removes the session from your device at once and, when the server
can be reached, from the server too; otherwise that session ends by itself after
a year unused.

Account records are kept by our database provider, **Supabase** (hosted in the
United States), in tables only our server can read.

## Feedback you send

There is no public contact email. You reach us through **Send feedback**
(Settings) or **Report an error** (on excerpt pages). When you tap Send, the app
stores:

- your message (up to 2000 characters — please don't put personal details in it),
- where in the app you sent it from (for example "excerpt notes — common
  pitfalls"),
- the excerpt it is about, if any,
- the app's version number,
- a scrambled install code — a one-way hash of the random install number — so we
  can tell that two messages came from the same install. It is **not** your name,
  email, Apple ID or device identifier, and we cannot turn it back into any of
  those.

Messages are kept by our database provider, **Supabase** (hosted in the United
States), in a table only our server can read. We keep each message until we have
handled it and delete it **within 12 months** at the latest. Feedback is read by
people; it is **never sent to any AI service**.

If the server is not reachable the message waits on your device and is sent
later. Deleting the app deletes unsent messages.

## Popular with other players (optional, off unless you turn it on)

In **Settings → Popular with other players** you can choose to **share what you
practise**. It is **off until you turn it on**, and the app first asks whether
you are 18 or older; the feature is for players 18 and older only. Until you
turn it on, the app keeps no record of what you practised for this purpose.

While it is on, the app sends our server — when you open it, at most twice a
day — exactly this, for each instrument you practised:

- your instrument (for example "cello"),
- the week (for example "2026-W41"),
- the ids of the **catalogue excerpts** you practised that week (up to 50) — the
  excerpts whose reference you played, recorded against, or put in a mock
  audition. Nothing you typed, no recordings, notes, scans or parts, and no
  times or counts.

Each send replaces the one before it for that week, so the server holds **one
row per instrument and week** for you. It stores the row against a one-way
scrambled code (an HMAC hash) of the random install number — never the number
itself, and the code cannot be turned back into it — in a table only our
server can read, at our database provider **Supabase** (United States). Rows
older than **26 weeks are deleted**. From these rows the server works out which
excerpts are **popular** with players of your instrument over the last eight
weeks, and shows that only when **at least 20 players** share, as two tiers
("Very popular", "Popular") — never as numbers or percentages, and never mixed
into "what orchestras ask". Only players who share see these lists.

**Turning sharing off deletes everything you shared** from our server (the app
asks the server straight away and tries again later if it couldn't be reached)
and forgets this week's list on your device.

## Videos and music from other services

- **YouTube.** Excerpt pages can play videos in YouTube's own embedded player.
  When you play one, YouTube (Google) may collect information under its own
  terms. Auditioner uses YouTube API Services; by using the YouTube features you
  agree to the [YouTube Terms of Service](https://www.youtube.com/t/terms).
  See the [Google Privacy Policy](https://policies.google.com/privacy).
- **Apple Music.** If you choose to play a recording through Apple Music, the app
  asks for permission and Apple handles playback under
  [Apple's privacy policy](https://www.apple.com/legal/privacy/).
- **IMSLP and other links.** "Get the part on IMSLP" and similar links open
  those websites, which have their own privacy policies.

## Children

Auditioner is intended for people aged 13 and over. Sharing what you practise,
and the "Popular with other players" lists, are for players 18 and older only.

## Your choices

- You can use the app without reading notes from scans; then nothing leaves
  your device except when you play a video or music.
- You can delete everything on the device by deleting the app.
- You never have to sign in. If you did, you can delete the account at any time
  in the app (Settings → Account → Delete account); that removes it from our
  server straight away and disconnects Apple.
- You can stop sharing what you practise at any time (Settings → Popular with
  other players); that deletes what you shared from our server.
- Questions or requests about your data — including asking us to delete feedback
  you sent — go through **Send feedback** in Settings or **Report an error** on an
  excerpt page. Mention the date you sent the message so we can find it; we don't
  know who sent what otherwise. There is no public contact email.

## Changes

If this policy changes, we will update this page and its date, and describe the
change in the app's release notes.
