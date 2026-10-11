# Trying Auditioner on your Mac, iPad or iPhone (for Milai)

Plain words, step by step. Nothing here needs you to write code. Budget about
45 minutes the first time (most of it is Xcode downloading); after that, pulling
a new version and pressing Run takes a couple of minutes.

Your setup: MacBook Air M5, macOS Tahoe 26.6.2, Xcode 27. The branch to try is
`claude/funny-noether-si8co1`.

---

## 1. Install Xcode (once)

1. Open the **App Store** on the Mac, search for **Xcode**, click **Get** / **Install**.
   It is big (well over 10 GB) — start it and have a coffee.
2. Open Xcode once from Launchpad. It asks to install "additional components" —
   say **Install** and enter your Mac password. If it offers **iOS platform
   support** (the iPhone/iPad simulators), tick it and let it download.
3. Xcode → **Settings…** (⌘,) → **Accounts** → **+** → **Apple ID** → sign in with
   the Apple ID of your Apple Developer account. Your team should appear in the
   list. Close Settings.

## 2. Get the code onto your Mac

Pick **one** of the two ways. Both end with a folder called `auditioner` on your Mac.

### Option A — GitHub Desktop (buttons, no typing)

1. Download GitHub Desktop from <https://desktop.github.com>, open it, sign in
   with your GitHub account (the one that owns the `auditioner` repository).
2. **File → Clone Repository…** → **GitHub.com** tab → pick
   `milaiwalkerproject-ui/auditioner` → choose where to put it (Documents is
   fine) → **Clone**.
3. At the top of the window there is a **Current Branch** button. Click it,
   type `funny-noether` in the filter box and pick
   **claude/funny-noether-si8co1**.
4. Click **Fetch origin** (top right). If it turns into **Pull origin**, click it
   again. You now have the latest version of this branch.

   Every time I tell you "there's a new version": open GitHub Desktop, make sure
   the branch button still says `claude/funny-noether-si8co1`, click
   **Fetch origin** then **Pull origin**.

   If GitHub Desktop shows a change to `Localizable.xcstrings` or
   `InfoPlist.xcstrings` that you didn't make, Xcode updated it while building —
   right-click it → **Discard changes**, then pull.

### Option B — Terminal (typing, exact commands)

Open **Terminal** (Launchpad → Other → Terminal, or press ⌘-space and type
"Terminal"). Type each line and press Return.

First time only:

```
cd ~/Documents
git clone https://github.com/milaiwalkerproject-ui/auditioner.git
cd auditioner
git checkout claude/funny-noether-si8co1
```

The repository is public, so no sign-in is needed to download it. (If it is
made private later, Git will ask for your GitHub username and a *personal
access token*: GitHub → your photo → Settings → Developer settings → Personal
access tokens → Generate new token, tick `repo`.)

Every later time ("there's a new version"):

```
cd ~/Documents/auditioner
git checkout claude/funny-noether-si8co1
git pull
```

## 3. Open the project in Xcode

1. In Finder, open the `auditioner` folder → `ios` → double-click
   **Auditioner.xcodeproj**. Xcode opens. (Or in Xcode: File → Open… and pick
   that file.)
2. If Xcode asks any "trust" question about the project, choose **Trust** — the
   project has no outside packages or scripts.
3. Wait for the top of the window to stop saying "Indexing".

## 4. Tell Xcode it is your app (once)

1. In the left-hand list, click the very top item, the blue **Auditioner** icon.
2. In the middle, under **TARGETS**, click **Auditioner**.
3. Click the **Signing & Capabilities** tab.
4. Tick **Automatically manage signing**.
5. **Team**: choose your name / your Apple Developer team.
6. If Xcode shows a red message saying the bundle identifier
   `com.milaiwalker.auditioner` is already taken or can't be registered, change
   **Bundle Identifier** to something unique, for example
   `com.milaiwalker.auditioner2`. (Tell me if you change it — TestFlight needs
   to match.)
7. Wait a few seconds; the red messages should go away.

## 5. Choose where to run it

Next to the ▶ (Run) button at the top there is a device menu (it says something
like "Auditioner › iPhone 16" ). Click it and choose one:

- **My Mac (Designed for iPad)** — fastest way to see it. Runs the iPad app in a
  window on your Mac. Camera scanning isn't available there; Files and Photos
  import are.
- An **iPad or iPhone simulator** (e.g. "iPad Pro 13-inch" or "iPhone 16") —
  looks like the real thing. No camera either. If the list is empty, Xcode →
  Settings → Components → download an iOS simulator.
- **Your real iPad or iPhone** — needed for the camera, Apple Pencil and the
  AirTurn pedal:
  1. Plug the device into the Mac with a cable. Unlock it. Tap **Trust** on the
     device if asked.
  2. On the device: **Settings → Privacy & Security → Developer Mode** → turn it
     on → the device restarts → confirm. (If you don't see Developer Mode, plug the
     device in, open Xcode's device menu once, then look again.)
  3. Back in Xcode's device menu, your device appears at the top. Pick it.
  4. The first time, the device says "Untrusted Developer" when the app
     launches: on the device go to **Settings → General → VPN & Device
     Management** → tap your developer name → **Trust**. Launch the app again.

## 6. Run

Press the ▶ button (or ⌘R). The first build takes a few minutes; later builds
are quick. The app starts with a three-page welcome: pick **Cello**, your chair,
your region, **Start**.

If the build stops with red errors, don't try to fix them — take a screenshot
of the error list and send it to me.

## 7. What you can try right now

**Works offline (no server needed):**

- **Excerpts** tab — the catalogue for your instrument, search, filters, and an
  excerpt page for each (tempo, techniques, history, recordings, how often it's
  asked). Only published entries show; see "Reviewer mode" below to see drafts.
- **YouTube clips** on excerpt pages (needs internet, but no server of ours).
- **Practice → Try the demo** — a short scale: tempo slider, loop a few bars,
  count-in, tuning A = 440/442, "Save audio".
- **My parts** — add a PDF from Files (iCloud Drive, Google Drive, Dropbox…), a
  photo, or scan with the camera. Open a part, draw on it with the **Apple
  Pencil**, turn pages with an **AirTurn** pedal (arrow keys / page up-down).
  Sharing a PDF to Auditioner from another app also lands it here.
- **Scan my part** from an excerpt page, or **Make reference audio** on a part
  in My parts (long-press): camera → mark the excerpt → the app recognises the
  excerpt from the text on the page. If the catalogue already has checked
  notation for that excerpt, it plays straight away.

**Practice tools (new — all offline):**

- **Practice → Metronome** — tempo dial, tap tempo, beats per bar, subdivisions,
  accent. Opened from an excerpt page ("Metronome for this excerpt") it remembers
  your settings for that excerpt.
- **Practice → Drone** — any note, with or without the fifth, cello sound or a
  pure tone, at your A = 440/442 tuning.
- **Record & compare** — in the practice player, tap **Record**: a bar of
  count-in (if Count-in is switched on), then the reference plays while the app records you (use headphones), then
  **Compare** lets you hear You / Reference / Both, also slowed down.
- **Practice → Mock audition** — pick excerpts, random order, "behind the
  screen" hides the titles, preparation time between excerpts, one continuous
  recording; afterwards rate each excerpt and listen back.
- **Practice → My recordings** — every take and mock audition, with ratings and
  notes; share or delete.
- **Fix notes** — when the server read your scan, the practice player shows
  **Fix notes**: your scan above, the notes below; tap a note to change pitch,
  accidental, length, rest, tie, insert or delete; bars that don't add up are
  marked red; save keeps a corrected copy.
- **Report an error / Send feedback** — on excerpt pages and in Settings. Your
  message waits on the device until the server (with feedback turned on, see
  `docs/SETUP.md`) can receive it.

**Needs the server (see `docs/SETUP.md`):**

- Reading the notes from a scan when the catalogue has no checked notation for
  that excerpt (or when the excerpt isn't in the catalogue). Without a server
  address in **Settings → Server** you get a friendly "the server isn't set up
  yet" screen instead, with a button to the excerpt page and to the demo.
- The first time you read notes the app asks for your consent: the marked part
  of the page goes to our server, is used only to read the notes, and is deleted
  within 24 hours. Nothing is ever sent to an AI service.
- **Sign in with Apple** (optional, **Settings → Account**) — needs the server
  *and* the Apple sign-in key (`docs/SETUP.md`, step 8: Apple Developer
  capability, the `.p8` key, two secrets, one Supabase migration). Until then
  the black Apple button is greyed out with no server address, and with a server
  address but no key it answers "Accounts aren't set up on the server yet."
  Once set up: tap the button, confirm with Face ID / your Apple ID password —
  the app asks Apple for **no name and no email**, so Apple shows no sharing
  choice. The section then shows "Signed in with Apple", "Scans a day · 60",
  **Sign out** and **Delete account**. Delete account asks "Delete your
  account?", then says "Your account is deleted." and, on your iPhone, Settings →
  [your name] → Sign-In & Security → Sign in with Apple no longer lists
  Auditioner. Everything else in the app works exactly the same signed out.
- **Popular with other players** (off by default) — needs the server with
  Supabase turned on (`docs/SETUP.md`, step 7; the same deploy sets up trends and
  there is one more migration, `20261012010000_trends.sql`). **Settings →
  Popular with other players → Share what I practise**; the app asks "Are you 18
  or older?" first. Then play a reference, record a take or finish a mock
  audition: the excerpts are remembered for this week and sent when the app comes
  to the front (at most twice a day). The Excerpts tab gets a "Popular with cello
  players" section under "Most asked for your chair", and excerpt pages a small
  "Very popular" / "Popular" line. With fewer than 20 players sharing you see
  "Not enough players share yet to show this." — expected during TestFlight.
  Turning the switch off deletes what you shared.

**Links from Tutti and the app's language (no server needed):**

- **Open the app from a link.** Auditioner now answers `auditioner://` links
  (`docs/TUTTI.md` has the full format). On your iPad with the app installed,
  open **Safari**, paste this made-up example into the address bar and press Go,
  then tap **Open** when Safari asks:

  ```
  auditioner://audition/new?orchestra=Example%20Philharmonic&position=Section%20cello&instrument=cello&deadline=2027-01-15&auditionDate=2027-03-02&url=https%3A%2F%2Fexample.org%2Fauditions%2Fcello
  ```

  The app switches to **Auditions** and opens the **New audition** form with
  "Example Philharmonic", "Section cello", both dates and the link already
  filled in. Nothing is saved until you tap **Add**; **Cancel** throws it away.
  (The orchestra, dates and address are invented for the example.) An excerpt
  link looks like `auditioner://excerpt/<excerpt id>` and opens that excerpt
  page; an id the catalogue doesn't have shows "That excerpt isn't in the
  catalogue on this device yet." The same links also work pasted into Notes and
  tapped. In the Mac simulator, Terminal:
  `xcrun simctl openurl booted "auditioner://audition/new?orchestra=Example%20Philharmonic"`.
- **Language.** iOS lets you pick a language per app: on the device, **Settings
  (the iOS one) → scroll down to Auditioner → Language**. Inside the app,
  **Settings → Language → App language** jumps to that page. The app speaks
  English, Spanish, Chinese (simplified and traditional), Italian, Russian,
  Japanese, Korean, German, French and Portuguese (Brazil); with no choice made it
  follows the device's language. The translations are machine-made and checked
  by a second pass, not yet by a native speaker, so the app shows a "Beta
  translation" tag in Settings while it runs in another language. Spot a strange
  phrase? Send feedback from that screen. In the Mac/iPad simulator you can also
  pick a language in Xcode: **Product → Scheme → Edit Scheme… → Run → Options →
  App Language**.
- **Translated excerpt notes — not before 12 November, on purpose.** The
  history, technique, pitfalls and practice-tips notes have machine
  translations ready in the app (Spanish, Italian, Chinese and more are
  bundled), but a date lock keeps them hidden until **12 November 2026** (the
  date in the plan, row I2, from which AI text may be shown; the lock opens at one
  moment worldwide, when it is 12 November everywhere — 13:00 in Berlin, 04:00 in
  Los Angeles). There is no
  switch to see them earlier, not even in reviewer mode, so until then every
  note appears in English whatever language the app runs in. From that day
  on, with the app in one of those languages (on the device: **Settings → scroll
  down to Auditioner → Language**, then reopen the excerpt page), each approved
  note shows the translation with a small "Machine-translated" tag, the line
  "Machine-translated from English — may contain errors", and a "Show
  original" link under it; "Show translation" brings the translation back. The
  "AI-generated — may contain errors" line stays on every AI note, translated or
  not. Draft notes (reviewer mode) are never translated. Work titles, composer
  names and score markings stay as they are.
- **Privacy page.** **Settings → About → Privacy** has new blocks for signing in
  with Apple and for "Popular with other players"; the full text is
  `docs/PRIVACY.md` (version 0.3). It is a promise to users — please read both
  once.
- **Find an orchestra near you.** **Settings → About** now shows this row; it
  opens Tutti's site (https://tutti-orchestra.com) inside the app.

**Your answers of 11 October, applied (Auditions tab):**

- **Archive instead of delete.** On an audition's page, **⋯ → Archive audition**
  puts it away at once (no "are you sure?" — it's undoable) and goes back to
  the Auditions tab. Its reminders are switched off while it's archived. Under
  **My auditions** a row **Archived (1)** appears (hidden when nothing is
  archived). Open it: each archived audition has **Restore** (back into My
  auditions with its list, readiness and reminders if they were on) and
  **Delete for good** (asks "Delete this audition for good?" — only this
  really deletes). If you archive an audition you made from the feed and later
  tap **Prepare for this audition** on the same vacancy, the app restores the
  archived one instead of making a second copy.
- **All regions.** Under **Open auditions** the first row is a picker **Show:
  Your region (North America)** / **All regions**. The choice is remembered,
  the section's subtitle says which is shown, and the feed reloads. Needs the
  server, like the feed itself.
- **Brass counts every chair.** For horn, trumpet, trombone, bass trombone and
  tuba, **Include all chairs** ("Most asked for your chair" and each excerpt
  page) starts switched **on**, because the brass lists don't say which chair
  they were for. The switch is now remembered per instrument: turning it off
  for horn doesn't change cello.

## 8. Reviewer mode (to see draft excerpts)

You reviewed and published all 19 cello excerpts and the brass import, so
testers already see them. New excerpts will arrive as drafts. To see drafts
before they are published: **Settings → About → tap the Version row seven
times** → a new **Catalogue review** section appears → turn on **Reviewer mode
(show drafts)**. Draft entries show a "Draft" tag, and unreviewed notes show a
"Draft — not reviewed" banner. Turn it off again to see what a tester sees.

## 9. How to report problems

Send me, in one message:

1. What you did (which tab, which buttons, in order).
2. What you expected and what happened instead.
3. A screenshot (on iPad/iPhone: press the top button and volume-up together;
   on the Mac: ⇧⌘4 and drag).
4. If the app crashed or Xcode showed red text: a screenshot of Xcode's error
   list (the ⚠︎/⊗ icon in the left-hand column).
5. Which device (Mac, simulator, iPad/iPhone model) and the app version
   (Settings → About → Version).

Don't worry about the wording — "the loop button did nothing on the demo, iPad,
version 0.1.0 (1)" is perfect.
