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

- **Supabase** (accounts, catalogue updates, audition feed) — M4/M5.
- **Anthropic API key** (AI-written excerpt notes, generated offline) — later, and
  the key lives only in the server's secrets, never in the app or on GitHub.
- **YouTube Data API key** (finding recordings) — later milestone.
- **App Attest** (replaces the per-phone scan limit) — M5.
