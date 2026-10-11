# Setting up the Auditioner server (for Milai)

This is the one-time setup so "Scan my part" works on your phone. The app itself
works without a server (catalogue, excerpt pages, recordings, the reader); only
scanning needs it, because the note-reading program is too big to run on a phone.

Plain words, step by step, on your MacBook Air. Budget about an hour the first time.
Nothing here needs you to write code. If anything on screen doesn't match these
words, stop and ask — Google moves its buttons around now and then.

What you will end up with: a small web address like
`https://auditioner-api-xxxxx-uc.a.run.app` that you paste into the app under
**Settings → Server**.

---

## 1. A Google Cloud account and a project

1. Go to <https://console.cloud.google.com> and sign in with a Google account
   (the same one you use for YouTube is fine, or a fresh one just for Auditioner).
2. Accept the terms when asked.
3. At the top of the page there is a project picker (it says something like
   "Select a project" or "My First Project"). Click it → **New project**.
   - Name: `Auditioner`
   - Leave the organisation / location as it is.
   - Click **Create**, then pick the new project in the picker so it is selected.
4. Write down the **Project ID** (shown on the dashboard — it looks like
   `auditioner-123456`, not just `Auditioner`). You need it in step 4.

## 2. Turn on billing and set a safety budget

The server is free to sit idle but Google needs a card on file to run anything.

1. Left menu (☰) → **Billing** → **Link a billing account** → create one and add a
   card. (New accounts usually come with a trial credit; whether that still applies
   is up to Google — check what the page says.)
2. Still under Billing → **Budgets & alerts** → **Create budget**:
   - Name: `Auditioner safety net`
   - Scope: this project. Amount: **$20 per month** (any number you are comfortable
     with).
   - Alerts at 50 %, 90 %, 100 % — email to you.
   - Save.

   A budget does **not** stop the service by itself; it emails you so you can look.
   With the settings in this repo the server scales to zero when nobody is scanning,
   so an idle month should cost close to nothing. We cannot promise exact numbers
   (Google's prices change and depend on usage), but for the first testers a month
   of use is expected to land in the "cents to a few dollars" range, and the budget
   alert tells you if it ever doesn't.

## 3. Install the Google Cloud command-line tool (gcloud)

Pick one:

- **Official installer** — <https://cloud.google.com/sdk/docs/install> → macOS →
  download the Apple Silicon (arm64) package, unzip it into your home folder, then
  in Terminal run `./google-cloud-sdk/install.sh` and answer yes to the questions.
  Close and reopen Terminal afterwards.
- **Homebrew** (if you already use it) — in Terminal: `brew install --cask google-cloud-sdk`

Check it worked: open Terminal and type `gcloud --version`. You should see a few
lines with version numbers, not "command not found".

## 4. Sign the tool in and point it at your project

In Terminal, one line at a time:

```
gcloud auth login
```

A browser window opens; choose the Google account from step 1 and allow access.

```
gcloud config set project YOUR-PROJECT-ID
```

Replace `YOUR-PROJECT-ID` with the Project ID you wrote down (for example
`gcloud config set project auditioner-123456`).

## 5. Put the server up

1. Open Terminal and go into the Auditioner folder (the one you cloned from GitHub).
   The easiest way: type `cd ` (with a space), drag the folder from Finder into the
   Terminal window, press Return.
2. Run:

   ```
   ./backend/deploy.sh
   ```

   If it says "permission denied", run `chmod +x backend/deploy.sh` once and try
   again.

3. The script explains what it is doing as it goes. The first run takes **10–20
   minutes** (it builds the server on Google's machines and downloads the
   note-reading models). It may ask once whether it can create a storage bucket or
   turn on a service — answer `y`.
4. At the end it prints:

   ```
   Paste this into the app: Settings → Server

       https://auditioner-api-xxxxx-uc.a.run.app
   ```

   Copy that address.

Running the script again later (after a server update or a catalogue change) is
fine — it only changes what needs changing.

## 6. Tell the app

On the iPhone/iPad, open Auditioner → **Settings → Server** → paste the address →
**Test connection**. You should see a tick. Then scan a page.

The first scan after a quiet period takes longer (up to a minute) while Google
wakes the server up; the next ones are quicker.

## 7. Turn on feedback (Supabase)

There is no public contact email for Auditioner. Players reach you through the
**Send feedback** row in Settings and the **Report an error** buttons on excerpt
pages. Those messages are saved on the player's device and sent to the server,
which stores them in a database table you can read. Until this step is done the
server answers "Feedback isn't set up yet" and the app keeps the messages on the
phone, so nothing is lost — but you won't see them. Budget about 20 minutes.

You already use Supabase for Tutti. Auditioner gets its **own, separate project** so
the two apps' data and keys never mix.

1. **Create the project.** Go to <https://supabase.com/dashboard> (same account as
   Tutti is fine) → **New project**:
   - Name: `auditioner`
   - Database password: let it generate one and store it in your password manager
     (you won't need it day to day).
   - Region: pick a United States region (the server is in the US too).
   - Plan: **Free** is fine to start. Note: a free project is **paused after about a
     week without use**; the dashboard shows a "Restore" button when that happens,
     and until you click it feedback can't be stored (the app keeps messages on the
     phone and sends them later). Upgrade when real testers arrive.
   - Click **Create new project** and wait a minute or two.
2. **Create the table.** Left bar → **SQL Editor** → **New query**. Open the file
   `supabase/migrations/20261011000000_feedback.sql` from the Auditioner folder
   (double-click opens TextEdit; or read it on GitHub), copy all of it, paste it
   into the editor, click **Run**. "Success. No rows returned" is right.
   `supabase/README.md` explains the folder; any later file in it is applied the
   same way, oldest first.
3. **Copy two values.** Left bar → **Project Settings** (the cog) → **API**:
   - **Project URL**, e.g. `https://abcdefgh.supabase.co`
   - **service_role** key (under "Project API keys"; click *Reveal*).

   The service_role key is a **secret**: it can read and change everything in the
   project. Never paste it into the app, GitHub, a chat, an email or a screenshot.
   The script below puts it straight into Google Secret Manager and never prints it.
4. **Tell the server.** In Terminal, in the Auditioner folder, one line at a time
   (replace the values; keep the quotes):

   ```
   export SUPABASE_URL="https://abcdefgh.supabase.co"
   export SUPABASE_SERVICE_ROLE_KEY="paste-the-service_role-key-here"
   ./backend/deploy.sh
   ```

   The script stores the key in Secret Manager (as `auditioner-supabase-service-key`),
   lets the server read it, and redeploys. At the end it says **"Feedback storage is
   ON"**. Close that Terminal window afterwards so the key isn't left in its history
   (or run `history -c`).

   Later runs of `./backend/deploy.sh` *without* those two lines leave feedback
   exactly as it is. Run them again only to change the key or the project.

   The same run also sets up **community trends** ("Popular with cellists"): it
   makes a random secret salt once, stores it as `auditioner-trends-salt` and never
   shows or changes it. If feedback was already on before trends existed, apply
   `supabase/migrations/20261012010000_trends.sql` (step 2) and run the three lines
   above once more.
5. **Try it.** In the app: Settings → **Send feedback** → write "test" → Send. The
   app says "Thanks". Then in Supabase: left bar → **Table Editor** → `feedback` —
   your row is there within a few seconds.

**Reading reports.** Table Editor → `feedback`. Each row has `created_at`, `context`
(where in the app: `excerpt-note:pitfalls`, `excerpt-fact`, `settings`, …),
`excerpt_id`, `message`, `app_version` and `device_hash` (a scrambled install code;
it only tells you that two rows came from the same install — not who). When you have
dealt with a row, double-click its `status` cell and set it to `handled` (or
`ignored`). Delete handled rows every so often: the privacy policy promises they are
gone within 12 months.

**Limits.** Each phone can send 20 messages a day (`DAILY_FEEDBACK_LIMIT` in
`backend/deploy.sh`). Messages are at most 2000 characters.

## 8. Sign in with Apple (once)

Accounts are optional for players: everything in the app works without one, and
there is always a Skip button. Signing in gives a player 60 scans a day instead of
30, and they can delete the account from the app at any time. Until this step is
done nobody can sign in; nothing else changes. Budget about 20 minutes. Step 7
(Supabase) must be done first.

The server never sees a player's name or email: it keeps a scrambled version of
Apple's id for them and, locked with a secret, the token it needs to tell Apple
"this player deleted their account".

**On developer.apple.com**

1. **Note your Team ID.** Go to <https://developer.apple.com/account> → scroll to
   **Membership details** → **Team ID**: 10 capital letters and digits, e.g.
   `ABCDE12345`. Write it down (it isn't secret).
2. **Switch Sign in with Apple on for the app.** **Certificates, Identifiers &
   Profiles** → **Identifiers** → click `com.milaiwalker.auditioner` (if it isn't
   there yet, create it first — `docs/TESTFLIGHT.md`, step A1) → under
   **Capabilities** tick **Sign in with Apple** (leave "Enable as a primary App ID"
   as it is) → **Save** → **Confirm**.
3. **Create the key.** Left bar → **Keys** → the blue **+**:
   - **Key Name**: `Auditioner Sign in with Apple`
   - tick **Sign in with Apple** → **Configure** → **Primary App ID**: pick
     `com.milaiwalker.auditioner` → **Save**
   - **Continue** → **Register**.
4. **Download the key — you can do this only once.** Click **Download**. A file
   called `AuthKey_XXXXXXXXXX.p8` lands in your Downloads folder. The ten characters
   after `AuthKey_` are the **Key ID** (also shown on the page); write it down. The
   file itself is a **secret**: never put it in the app, GitHub, a chat, an email or
   a screenshot. Keep one copy somewhere safe (your password manager can hold it as
   an attachment).

**Into Google Secret Manager** (Terminal, in the Auditioner folder, one line at a
time)

5. **Store the key.** Replace `XXXXXXXXXX` with your Key ID:

   ```
   gcloud services enable secretmanager.googleapis.com
   gcloud secrets create auditioner-apple-signin-key --replication-policy automatic --data-file="$HOME/Downloads/AuthKey_XXXXXXXXXX.p8"
   ```

   "Created version [1] of the secret" is the right answer.
6. **Make the account secret.** This makes a long random secret and puts it straight
   into Secret Manager — you never see it and never need to:

   ```
   openssl rand -base64 48 | tr -d '\n' | gcloud secrets create auditioner-account-secret --replication-policy automatic --data-file=-
   ```

   Run it **only once**. If it ever says the secret "already exists", that is fine —
   leave it alone. **Never replace this secret**: a new one would cut every player
   off from their account.

**In Supabase**

7. **Create the tables.** Supabase → **SQL Editor** → **New query** → paste all of
   `supabase/migrations/20261012000000_accounts.sql` → **Run** ("Success. No rows
   returned").

**Tell the server**

8. Replace the two ids with yours (keep the quotes):

   ```
   export APPLE_TEAM_ID="ABCDE12345"
   export APPLE_KEY_ID="XXXXXXXXXX"
   ./backend/deploy.sh
   ```

   The script checks that both secrets are there, lets the server read them and
   redeploys. At the end it says **"Sign in with Apple is ON"**. Later runs without
   the two `export` lines leave it exactly as it is.
9. **Tidy up.** Move `AuthKey_….p8` out of Downloads into your safe place (or
   delete it once your password manager has a copy).
10. **Try it.** In the app, sign in with Apple, then look in Supabase → **Table
    Editor** → `accounts`: one row, all scrambled letters, no name or email. Delete
    the account in the app: the row disappears, and on your iPhone **Settings →
    [your name] → Sign-In & Security → Sign in with Apple** no longer lists
    Auditioner.

**If you lose the key or think someone saw it:** on developer.apple.com → **Keys**
→ click it → **Revoke**. Make a new one (steps 3–4), then store it with
`gcloud secrets versions add auditioner-apple-signin-key --data-file="$HOME/Downloads/AuthKey_NEWKEYID.p8"`
(not `create`), and run step 8 again with the new Key ID. Players stay signed in.

**Limits.** Signed-in players get 60 scans a day (`SIGNED_IN_DAILY_SCAN_LIMIT` in
`backend/deploy.sh`); a signed-in session that isn't used for a year ends by itself.

## Looking at what the server is doing

- **Logs**: <https://console.cloud.google.com/run> → click `auditioner-api` →
  **Logs** tab. Each scan shows one line like `omr ok instrument=cello measures=12
  warnings=1 seconds=38.2`. Scans themselves are never written to the logs and the
  pictures are deleted from the server the moment they have been read.
- **Cost so far**: left menu → **Billing** → **Reports**.
- **Is it up?** Open `https://…run.app/healthz` in a browser; it should say
  `{"status":"ok","engine":"homr","version":"…"}`.

## Pausing or removing the server

- **Pause** (keeps everything, costs next to nothing while idle): nothing to do — it
  already sleeps between scans. The only thing kept around is the server image in
  **Artifact Registry**; every deploy adds a version, and old ones can be deleted
  there whenever you like.
- **Delete the service** (the app's scan button stops working until you deploy
  again): in Terminal

  ```
  gcloud run services delete auditioner-api --region us-central1
  ```

  Running `./backend/deploy.sh` again brings it back.
- **Delete everything** (no more charges of any kind): Google Cloud console → **IAM
  & Admin → Settings → Shut down** the project. This is final after 30 days.

## If something goes wrong

- "**You're not signed in**" → run `gcloud auth login` again.
- "**No Google Cloud project chosen**" → `gcloud config set project YOUR-PROJECT-ID`.
- "**Billing account … not found / not enabled**" → step 2 isn't finished.
- The build fails with a **permission** message mentioning Artifact Registry,
  Cloud Build or a service account → in the console go to **IAM & Admin → IAM**,
  find the row ending in `compute@developer.gserviceaccount.com`, click the pencil
  and add the roles **Cloud Build Service Account**, **Artifact Registry Writer**
  and **Logs Writer**; then run the script again.
- Scans fail with "**Busy — try again in a minute**" → several people are scanning at
  once and the queue is full; it really does clear in a minute.
- "**Reading this page took too long**" → the page had more than the server could
  read in the time the app waits (about two minutes). A straighter, closer photo of
  fewer staves works better.
- "**Daily scan limit reached**" → each phone gets 30 scans a day for now (set in
  `backend/deploy.sh`, `DAILY_SCAN_LIMIT`).
- **Every scan fails right away** after a server update → look at the Logs tab (see
  above) for a line starting `homr exited with status 2`: the note-reading program
  was given an option it doesn't know. Ask for help; nothing on the phone is wrong.
- Anything else: copy the last 20 lines from Terminal into a message and ask.

## Not needed yet

These come in later milestones; don't set them up now:

- **Supabase beyond feedback and accounts** (catalogue updates, audition feed) — M4/M5.
  The `auditioner` project from step 7 is the one they will use; nothing more to
  create yet.
- **Anthropic API key** (AI-written excerpt notes, generated offline) — later, and
  the key lives only in the server's secrets, never in the app or on GitHub.
- **YouTube Data API key** (finding recordings) — later milestone.
- **App Attest** (replaces the per-phone scan limit) — M5.
