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

**Needs the server (see `docs/SETUP.md`):**

- Reading the notes from a scan when the catalogue has no checked notation for
  that excerpt (or when the excerpt isn't in the catalogue). Without a server
  address in **Settings → Server** you get a friendly "the server isn't set up
  yet" screen instead, with a button to the excerpt page and to the demo.
- The first time you read notes the app asks for your consent: the marked part
  of the page goes to our server, is used only to read the notes, and is deleted
  within 24 hours. Nothing is ever sent to an AI service.

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
