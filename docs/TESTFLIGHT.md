# Getting a build to testers with TestFlight (for Milai)

Plain words, step by step. You need: an active Apple Developer account, Xcode
signed in with it (see `docs/TRY-IT.md`, step 1), and the app building on your Mac.

Two halves: **A** is done once (create the app record), **B** is repeated for
every build you send out.

---

## A. Create the app in App Store Connect (once)

### A1. The App ID and its services

1. Go to <https://developer.apple.com/account> → **Certificates, Identifiers &
   Profiles** → **Identifiers**.
2. If `com.milaiwalker.auditioner` (or whatever bundle identifier you ended up
   with in Xcode) is **not** in the list, click **+** → **App IDs** → **App** →
   Description `Auditioner`, Bundle ID **Explicit** = the identifier from Xcode
   → **Continue** → **Register**. (Xcode usually registers it for you the first
   time you run on a real device, so it is often already there.)
3. Click the identifier → under **Capabilities** scroll to **App Services** (a
   separate tab on newer pages) → tick **MusicKit** → **Save**. This is what lets
   the app play Apple Music recordings for subscribers. Without it, Apple Music
   playback silently fails; everything else still works.

### A2. The app record

1. Go to <https://appstoreconnect.apple.com> → **My Apps** → **+** → **New App**.
2. Fill in:
   - **Platforms**: iOS.
   - **Name**: `Auditioner`. If it says the name is taken, use a variant for
     now (`Auditioner – orchestra excerpts`); the public name can be changed
     before release.
   - **Primary language**: English (U.S.).
   - **Bundle ID**: pick the identifier from A1.
   - **SKU**: any short word you'll recognise, e.g. `auditioner-ios`.
   - **User access**: Full Access.
3. **Create**. You land on the app's page. Then do A4 and A5 once, while you
   are there.

### A3. Export compliance — already answered

The project sets `ITSAppUsesNonExemptEncryption = NO` in its build settings, so
App Store Connect will **not** ask the "Does your app use encryption?" question
on every upload. (The app only uses the standard HTTPS built into iOS, which is
exempt.)

### A4. Where the app is offered (countries)

Your decision (PLAN.md rows A6 and A6b): the app is **not offered in mainland
China, Russia, Belarus, Hong Kong or Macau**. The app itself has no
country-specific behaviour — this list in App Store Connect is the only place
the rule lives.

1. On the app's page, left-hand menu → **Pricing and Availability**.
2. **Price**: Free (the app is free during TestFlight, PLAN.md row B5).
3. Under **Availability** click **Edit** (the first time it may say **Set Up
   Availability**). Every country and region is ticked.
4. Untick **China mainland**, **Russia**, **Belarus**, **Hong Kong** and
   **Macau** (Apple's list may spell it "Macao"). Leave everything else ticked.
5. **Done** → **Save**.

TestFlight does not look at this list — an invitation works anywhere — so when
you add testers in B3, **don't invite people who live in those five places**,
and don't post the public link where they would pick it up.

### A5. Privacy policy and support addresses

Both pages are live on Tutti's site (PLAN.md row U1c):

- Privacy policy: **https://tutti-orchestra.com/auditioner/privacy**
- Support: **https://tutti-orchestra.com/auditioner/support**

Paste them in three places (copy the addresses exactly, with `https://`):

1. **TestFlight** tab → left-hand list → **Test Information** → **Privacy Policy
   URL**: the privacy address. On the same page, **Feedback Email** stays your
   own email address — only testers see it, inside the TestFlight app. **Save**.
2. **App Store** tab → left-hand list → **App Privacy** → next to **Privacy
   Policy URL** click **Edit** → paste the privacy address → **Save**. This is
   the one shown on the App Store page later.
3. **App Store** tab → the version at the top of the left-hand list (**1.0
   Prepare for Submission**) → scroll down to the **Support URL** field (it sits
   near **Keywords**) → paste the support address → **Save** (top right).
   **Marketing URL** can stay empty. The App Store needs this before review, not
   TestFlight, but it takes a minute while you are here.

The same two addresses are the **Privacy policy** and **Help and support** rows
under **Settings → About** in the app.

## B. Send a build (every time)

### B1. Archive in Xcode

1. Open `ios/Auditioner.xcodeproj`, pull the latest version of the branch first.
2. In the device menu next to ▶ choose **Any iOS Device (arm64)** (it is near
   the top of the list, above the simulators). You cannot archive while a
   simulator is selected.
3. Optional but useful: click the blue **Auditioner** project icon → target
   **Auditioner** → **General** → under **Identity** raise **Build** by one
   (1 → 2 → 3…). Each upload needs a new build number; Xcode can also do this
   for you if you leave it, but changing it yourself avoids a confusing error.
4. Menu **Product → Archive**. Wait a few minutes. The **Organizer** window
   opens with the new archive selected.

### B2. Upload

1. In the Organizer click **Distribute App**.
2. Choose **App Store Connect** (newer Xcode may word it "TestFlight & App
   Store") → **Distribute**.
3. If Xcode asks more questions instead (Upload or Export, symbols, build
   number, signing), keep the defaults — **Upload**, ticks as they are,
   **Automatically manage signing** — and click **Next** until the button says
   **Upload**.
4. Wait for "Upload Successful". Close the window.
5. Apple now processes the build; you get an email ("…has completed
   processing") in 5–30 minutes.

### B3. Add testers in App Store Connect

Open <https://appstoreconnect.apple.com> → **My Apps** → **Auditioner** →
**TestFlight** tab. The build appears under **iOS builds** once processed.

There are two kinds of groups:

**Internal Testing** — fastest, no review.

- Up to **100 people**, but each must first be added as a *user* of your
  App Store Connect account: **Users and Access** (top-left menu) → **+** →
  name, email, role **App Manager** or **Developer** (either is fine for
  testing) → **Invite**. They accept the email invitation.
- Back in TestFlight → **Internal Testing** → **+** → group name
  (`Colleagues`) → tick **Enable automatic distribution** so every new build
  goes out by itself → add the testers → **Create**.
- Testers install the **TestFlight** app from the App Store and open the
  invitation; the build is available within minutes of processing.

**External Testing** — for anyone, by email or public link.

- Up to **10,000 testers**; they do **not** need an App Store Connect account.
- The **first build** of the app (and any build with big changes) goes through
  **Beta App Review** (usually a day or two; it checks the app runs and
  doesn't break the rules). Later builds in the same version usually go out
  without waiting.
- What App Store Connect asks for before you can submit:
  - **What to Test** — a few lines, e.g. "Open the cello excerpt pages, try the
    demo in Practice, add a PDF to My parts. Scanning needs the server, which
    isn't live yet."
  - **Test Information** (under the TestFlight tab): a **feedback email** (your
    own — only testers see it, in the TestFlight app) and the **privacy policy
    URL**, which is **required** for external testing:
    `https://tutti-orchestra.com/auditioner/privacy` (A5 above).
  - **Beta App Description**, contact name, phone — fill in once.
- TestFlight → **External Testing** → **+** → group name (`Testers`) → add
  testers by email, or turn on **Public Link** and share the link → add the
  build → **Submit for Review**. Invite only people outside mainland China,
  Russia, Belarus, Hong Kong and Macau (A4).

### B4. What testers see

- The TestFlight app shows "Auditioner" with the **What to Test** notes.
- Builds expire after **90 days**; upload a new one before that.
- Crashes and the "Send Beta Feedback" screenshots testers submit from
  TestFlight arrive under the **TestFlight → Feedback** section of the app in
  App Store Connect. Forward anything you can't read to me.

## Things that go wrong, in plain words

- **"No accounts with App Store Connect access"** in Organizer → Xcode →
  Settings → Accounts → sign in again with the Apple ID that owns the developer
  account.
- **"The bundle identifier … is not available"** → change it in Xcode
  (Signing & Capabilities) and create the app record with the new one.
- **"Build already exists"** → raise the Build number (B1 step 3) and archive
  again.
- **The build never appears in TestFlight** → check the email from Apple; a
  "missing compliance" or "invalid binary" email says exactly what to fix.
  Send it to me.
- **Testers can't see the build** → internal testers must accept the Users and
  Access invitation first; external testers need the Beta App Review to have
  passed.
