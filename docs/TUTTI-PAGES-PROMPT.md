# Prompt for the Tutti project: Auditioner privacy and support pages

## Update for the privacy page (2026-10-11)

Milai: the two pages are live at https://tutti-orchestra.com/auditioner/privacy
and https://tutti-orchestra.com/auditioner/support. One sentence of the policy
has been made more precise since you pasted it. Copy **everything between the
two lines below** into your Tutti session — it changes that one sentence and
nothing else. (If the privacy page was never built, skip this and use the full
prompt further down; its policy text already has the new wording.)

---

On the page https://tutti-orchestra.com/auditioner/privacy ("Auditioner —
Privacy policy"), in the section "If you sign in with Apple (optional)", replace
this one sentence:

> While you are signed in, the app's requests to our server carry the session, so the server can count your scans against your account instead of your device.

with exactly this sentence:

> While you are signed in, only the app's scan uploads — and its requests about the account itself (checking it, signing out, deleting it) — carry the session, so the server can count your scans against your account instead of your device.

Change nothing else on the page: the version stays 0.3, the date stays
11 October 2026, and the sentence that follows ("It uses the session for nothing
else: …") stays as it is. Tell me when it is done.

---

## The full prompt (both pages)

Milai: copy **everything between the two lines below** (from "I need two simple
pages" down to the end of the policy) and paste it into a Claude session that
works on the Tutti website. When the pages are live, send me their two addresses
— they go into App Store Connect (Privacy Policy URL and Support URL) and into
the app's Settings.

If the privacy policy changes later, I'll update this file and tell you; then
paste the new policy text into the same page.

---

I need two simple pages on the Tutti website (https://tutti-orchestra.com) for
**Auditioner**, my companion iPhone/iPad app that helps orchestral musicians
prepare for auditions. Apple requires a public privacy policy page and a public
support page before testers outside my team can use the app through TestFlight,
and before the App Store release. Auditioner has no website of its own, so these
pages live on Tutti's site.

## Pages and addresses

1. **https://tutti-orchestra.com/auditioner/privacy** — "Auditioner — Privacy
   policy". The text is at the end of this message.
2. **https://tutti-orchestra.com/auditioner/support** — "Auditioner — Help and
   support".

If the site's structure makes those exact paths awkward, choose the closest
clean paths, and tell me the final addresses.

## Rules for both pages

- Public: no login, no paywall, and readable by Apple's reviewers.
- Readable on a phone, in light and dark mode, and in the site's normal style.
  Each page clearly says it is about **Auditioner** (a separate app from Tutti)
  and links to the other page.
- **No analytics, no tracking pixels, no third-party scripts and no
  advertising** on these two pages, because the policy promises "no tracking". If
  the whole site loads analytics on every page, turn it off for these two pages,
  or tell me, so the policy can say so honestly.
- **No email address may appear on either page.** I don't publish a contact
  email.
- Do not edit the policy's meaning. Turn the Markdown into the site's HTML, keep
  every heading, list and link, and change words only where step 3 below says so.
  If something in it can't be true on this website, stop and tell me rather
  than rewording it.

## Support page content

Write it in plain words for musicians (sentence case, short):

- One line on what Auditioner is.
- **Getting help in the app** (the main way): in Auditioner, go to **Settings →
  Send feedback**, or tap **Report an error** on an excerpt page. Messages are
  read by a person.
- **Contact form** (for people who can't use the app, for example if it won't
  open): fields **Message** (required, at most 2000 characters), **Email**
  (optional, only if they want a reply; say so next to the field), and the
  **device and app version** (optional). The form must deliver messages to me
  privately using Tutti's existing infrastructure. My email address must not
  appear in the page, the page source or the network requests. Add basic spam
  protection with no third-party tracking (a honeypot field plus a rate limit is
  fine). After sending, show "Thanks — we read every message." Keep messages no
  longer than 12 months.
- **Common questions**, short answers only:
  - "Do I need an account?" No. Signing in with Apple is optional and only raises
    the daily scan limit.
  - "How do I delete my account?" In the app: Settings → Account → Delete
    account. It is deleted from our server straight away and Apple is
    disconnected.
  - "Is my music uploaded?" Only the part of a page you mark when you choose to
    read the notes. It is deleted straight after reading, and is never sent to an
    AI service. Everything else stays on your device.
  - "Which devices?" iPhone and iPad with iOS 17 or later.
- A link to the privacy policy page.

## Privacy page: three changes to make to the text below

1. In "Your choices", replace the final sentence "There is no public contact
   email." with "You can also use the contact form on our support page
   (https://tutti-orchestra.com/auditioner/support). There is no public contact
   email." (use the real support address).
2. In "Feedback you send", directly after the paragraph that begins "There is no
   public contact email.", add a short paragraph that describes the website
   contact form **exactly as you built it**: what it collects (message, optional
   email, optional device/app version), where the messages are stored (which
   service and in which country), who reads them (people, never an AI service),
   and that they are deleted within 12 months. Don't guess: if you can't tell
   where Tutti's infrastructure stores the messages, ask me.
3. Add one line under the title: "This page is about the Auditioner app. Tutti
   has its own privacy policy." Link it to Tutti's own privacy page if there is
   one.

Do not add an `apple-app-site-association` file or any app-link set-up yet. That
comes later, if we decide to make https links open the app.

When you're done, give me the two final addresses and a one-line summary of
where contact-form messages go.

## The Auditioner privacy policy (paste this onto the privacy page)

# Auditioner — Privacy policy

*Version 0.3 · 11 October 2026 · applies to the Auditioner app for iPhone and iPad
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

While you are signed in, only the app's scan uploads — and its requests about
the account itself (checking it, signing out, deleting it) — carry the session,
so the server can count your scans against your account instead of your device.
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

---
