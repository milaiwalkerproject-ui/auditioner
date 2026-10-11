# Auditioner — Privacy policy

*Version 0.2 · 11 October 2026 · applies to the Auditioner app for iPhone and iPad
(test version 0.1.0).*

Auditioner helps orchestral musicians prepare for auditions. We designed it to
collect as little as possible. You do not need an account, and the app has no
ads, no tracking and no analytics.

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

Auditioner is intended for people aged 13 and over.

## Your choices

- You can use the app without reading notes from scans; then nothing leaves
  your device except when you play a video or music.
- You can delete everything on the device by deleting the app.
- Questions or requests about your data — including asking us to delete feedback
  you sent — go through **Send feedback** in Settings or **Report an error** on an
  excerpt page. Mention the date you sent the message so we can find it; we don't
  know who sent what otherwise. There is no public contact email.

## Changes

If this policy changes, we will update this page and its date, and describe the
change in the app's release notes.
