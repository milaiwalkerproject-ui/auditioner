#!/usr/bin/env bash
#
# Puts the Auditioner server on Google Cloud Run.
#
# Run it from the repo folder in Terminal:     ./backend/deploy.sh
# (docs/SETUP.md walks through the one-time account setup first.)
#
# Safe to run again whenever the server code or the catalogue changes: every step
# either creates something once or updates what is already there. Stops at the
# first problem and says what to do.
#
# Feedback storage (Supabase) is optional. When BOTH of these are exported before
# running the script, the key goes into Google Secret Manager (never printed, never
# written to disk by this script) and the server is deployed with it:
#     export SUPABASE_URL=https://xxxx.supabase.co
#     export SUPABASE_SERVICE_ROLE_KEY=...        # secret — see docs/SETUP.md
# Without them the deploy is exactly as before and feedback storage stays as it was.
#
# Community trends (/v1/trends) need one more secret, TRENDS_SALT. On a run with the
# Supabase values above, the script makes sure it exists in Secret Manager: the first
# time it creates a random one (or stores yours if you exported TRENDS_SALT); after
# that it is NEVER replaced, because a new salt would stop players from deleting
# what they shared.
#
# Sign in with Apple accounts (/v1/account…) turn on when BOTH of these are exported:
#     export APPLE_TEAM_ID=ABCDE12345       # developer.apple.com → Membership details
#     export APPLE_KEY_ID=FGHIJ67890        # the Sign in with Apple key's Key ID
# The two secrets they need — the .p8 key file and ACCOUNT_SECRET — must already be in
# Secret Manager (docs/SETUP.md, "Sign in with Apple (once)", has the exact commands).
# This script only checks they exist and lets the server read them; it never reads,
# prints or changes them.

set -euo pipefail

REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-auditioner-api}"
AR_REPO="${AR_REPO:-auditioner}"
DAILY_SCAN_LIMIT="${DAILY_SCAN_LIMIT:-30}"
DAILY_FEEDBACK_LIMIT="${DAILY_FEEDBACK_LIMIT:-20}"
# Name of the secret in Secret Manager that holds the Supabase service-role key.
FEEDBACK_SECRET="${FEEDBACK_SECRET:-auditioner-supabase-service-key}"
SUPABASE_URL="${SUPABASE_URL:-}"
SUPABASE_SERVICE_ROLE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
# Name of the secret that holds TRENDS_SALT (community trends), and an optional value.
TRENDS_SECRET="${TRENDS_SECRET:-auditioner-trends-salt}"
TRENDS_SALT="${TRENDS_SALT:-}"
# Sign in with Apple: the two plain ids, and the names of the two secrets in Secret Manager.
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_KEY_ID="${APPLE_KEY_ID:-}"
APPLE_KEY_SECRET="${APPLE_KEY_SECRET:-auditioner-apple-signin-key}"
ACCOUNT_SECRET_NAME="${ACCOUNT_SECRET_NAME:-auditioner-account-secret}"
SIGNED_IN_DAILY_SCAN_LIMIT="${SIGNED_IN_DAILY_SCAN_LIMIT:-60}"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nStopped: %s\n' "$*" >&2; exit 1; }

# 0. Work from the repo root, wherever the script was started from.
cd "$(dirname "$0")/.."
[ -f backend/Dockerfile ] && [ -f backend/cloudbuild.yaml ] \
  || die "Run this from the Auditioner repo folder (backend/Dockerfile not found)."
[ -d content/catalog ] || die "content/catalog is missing — the image needs the catalogue."

# 0b. Feedback storage on or off for this run? Both values or neither.
FEEDBACK_ON=0
if [ -n "$SUPABASE_URL" ] && [ -n "$SUPABASE_SERVICE_ROLE_KEY" ]; then
  FEEDBACK_ON=1
  case "$SUPABASE_URL" in
    https://*) ;;
    *) die "SUPABASE_URL should start with https:// (Supabase → Project Settings → API → Project URL)." ;;
  esac
  # Trailing slash off, so the server builds https://xxxx.supabase.co/rest/v1/feedback.
  SUPABASE_URL="${SUPABASE_URL%/}"
elif [ -n "$SUPABASE_URL" ] || [ -n "$SUPABASE_SERVICE_ROLE_KEY" ]; then
  die "Set both SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (export them in this Terminal), or neither."
fi

# 0c. Sign in with Apple on or off for this run? Both ids or neither. Apple's Team ID
#     and Key ID are each 10 capital letters and digits.
ACCOUNTS_ON=0
if [ -n "$APPLE_TEAM_ID" ] && [ -n "$APPLE_KEY_ID" ]; then
  ACCOUNTS_ON=1
  [[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
    || die "APPLE_TEAM_ID should be 10 capital letters and digits (developer.apple.com → Account → Membership details → Team ID)."
  [[ "$APPLE_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] \
    || die "APPLE_KEY_ID should be 10 capital letters and digits (the Key ID shown next to your Sign in with Apple key)."
elif [ -n "$APPLE_TEAM_ID" ] || [ -n "$APPLE_KEY_ID" ]; then
  die "Set both APPLE_TEAM_ID and APPLE_KEY_ID (export them in this Terminal), or neither."
fi
[[ "$SIGNED_IN_DAILY_SCAN_LIMIT" =~ ^[0-9]+$ ]] || die "SIGNED_IN_DAILY_SCAN_LIMIT should be a whole number."

# 1. Tools and sign-in.
command -v gcloud >/dev/null 2>&1 \
  || die "The Google Cloud CLI (gcloud) isn't installed. See docs/SETUP.md, step 3."
ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
[ -n "$ACCOUNT" ] || die "You're not signed in to Google Cloud. Run:  gcloud auth login"
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [ -z "$PROJECT" ] || [ "$PROJECT" = "(unset)" ]; then
  die "No Google Cloud project chosen yet. Run:  gcloud config set project YOUR-PROJECT-ID"
fi
say "Signed in as $ACCOUNT, project $PROJECT, region $REGION"

# 2. Turn on the services we use (does nothing if they are already on).
say "Making sure Cloud Run, Cloud Build and Artifact Registry are switched on"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  --project "$PROJECT"
if [ "$FEEDBACK_ON" = 1 ]; then
  say "Making sure Secret Manager is switched on (it keeps the Supabase key)"
  gcloud services enable secretmanager.googleapis.com --project "$PROJECT"
fi

# 3. A place to keep the server image.
if ! gcloud artifacts repositories describe "$AR_REPO" --location "$REGION" --project "$PROJECT" >/dev/null 2>&1; then
  say "Creating the image store '$AR_REPO' in $REGION"
  gcloud artifacts repositories create "$AR_REPO" \
    --repository-format docker --location "$REGION" --project "$PROJECT" \
    --description "Auditioner server images"
else
  say "Image store '$AR_REPO' already exists"
fi

# 3b. Feedback storage: put the Supabase key in Secret Manager and let the server read it.
#     The key only ever travels through a pipe into gcloud; it is never echoed.
if [ "$FEEDBACK_ON" = 1 ]; then
  say "Storing the Supabase key in Secret Manager as '$FEEDBACK_SECRET' (the key itself is never shown)"
  if gcloud secrets describe "$FEEDBACK_SECRET" --project "$PROJECT" >/dev/null 2>&1; then
    CURRENT_KEY="$(gcloud secrets versions access latest --secret "$FEEDBACK_SECRET" --project "$PROJECT" 2>/dev/null || true)"
    if [ "$CURRENT_KEY" = "$SUPABASE_SERVICE_ROLE_KEY" ]; then
      echo "The stored key is already up to date."
    else
      printf '%s' "$SUPABASE_SERVICE_ROLE_KEY" \
        | gcloud secrets versions add "$FEEDBACK_SECRET" --data-file=- --project "$PROJECT" >/dev/null
      echo "Added a new version of the key."
    fi
    unset CURRENT_KEY
  else
    printf '%s' "$SUPABASE_SERVICE_ROLE_KEY" \
      | gcloud secrets create "$FEEDBACK_SECRET" --data-file=- --replication-policy automatic --project "$PROJECT" >/dev/null
    echo "Created the secret."
  fi

  # The account the Cloud Run service runs as (the one it already uses, or the project
  # default compute account on a first deploy) must be allowed to read the secret.
  RUNTIME_SA="$(gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT" \
    --format 'value(spec.template.spec.serviceAccountName)' 2>/dev/null || true)"
  if [ -z "$RUNTIME_SA" ]; then
    PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format 'value(projectNumber)')"
    [ -n "$PROJECT_NUMBER" ] || die "Couldn't read the project number to find the server's service account."
    RUNTIME_SA="$PROJECT_NUMBER-compute@developer.gserviceaccount.com"
  fi
  say "Allowing $RUNTIME_SA to read the secret"
  gcloud secrets add-iam-policy-binding "$FEEDBACK_SECRET" \
    --member "serviceAccount:$RUNTIME_SA" \
    --role roles/secretmanager.secretAccessor \
    --project "$PROJECT" >/dev/null
fi

# 3c. Community trends: the salt for hashing device ids (TRENDS_SALT). Created once —
#     random unless you exported your own — and never replaced afterwards: a new salt
#     would orphan every stored row, so "turn sharing off" could no longer delete them.
#     The salt only ever travels through a pipe into gcloud; it is never echoed.
if [ "$FEEDBACK_ON" = 1 ]; then
  say "Making sure the community-trends salt is in Secret Manager as '$TRENDS_SECRET' (never shown)"
  if gcloud secrets describe "$TRENDS_SECRET" --project "$PROJECT" >/dev/null 2>&1; then
    if [ -n "$TRENDS_SALT" ]; then
      STORED_SALT="$(gcloud secrets versions access latest --secret "$TRENDS_SECRET" --project "$PROJECT" 2>/dev/null || true)"
      if [ "$STORED_SALT" != "$TRENDS_SALT" ]; then
        unset STORED_SALT
        die "A different TRENDS_SALT is already stored. Changing it would stop players from deleting what they shared. Run  unset TRENDS_SALT  and run this script again (the stored salt is kept)."
      fi
      unset STORED_SALT
    fi
    echo "The stored salt is kept (it must never change)."
  else
    if [ -z "$TRENDS_SALT" ]; then
      TRENDS_SALT="$(od -A n -t x1 -N 32 /dev/urandom | tr -d ' \n')"
    fi
    [ "${#TRENDS_SALT}" -ge 32 ] || die "TRENDS_SALT is too short — use at least 32 characters, or unset it to get a random one."
    printf '%s' "$TRENDS_SALT" \
      | gcloud secrets create "$TRENDS_SECRET" --data-file=- --replication-policy automatic --project "$PROJECT" >/dev/null
    echo "Created the secret."
  fi
  unset TRENDS_SALT
  gcloud secrets add-iam-policy-binding "$TRENDS_SECRET" \
    --member "serviceAccount:$RUNTIME_SA" \
    --role roles/secretmanager.secretAccessor \
    --project "$PROJECT" >/dev/null
fi

# 3d. Sign in with Apple: the .p8 key and ACCOUNT_SECRET must already be in Secret
#     Manager (docs/SETUP.md, "Sign in with Apple (once)"). Only their existence is
#     checked; their contents are never read here. Then the server may read them.
if [ "$ACCOUNTS_ON" = 1 ]; then
  say "Checking the Sign in with Apple secrets in Secret Manager (never shown)"
  gcloud services enable secretmanager.googleapis.com --project "$PROJECT"
  for NAME in "$APPLE_KEY_SECRET" "$ACCOUNT_SECRET_NAME"; do
    gcloud secrets describe "$NAME" --project "$PROJECT" >/dev/null 2>&1 \
      || die "The secret '$NAME' isn't in Secret Manager yet. Follow docs/SETUP.md → 'Sign in with Apple (once)', then run this script again."
  done
  if [ -z "${RUNTIME_SA:-}" ]; then
    RUNTIME_SA="$(gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT" \
      --format 'value(spec.template.spec.serviceAccountName)' 2>/dev/null || true)"
  fi
  if [ -z "$RUNTIME_SA" ]; then
    PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format 'value(projectNumber)')"
    [ -n "$PROJECT_NUMBER" ] || die "Couldn't read the project number to find the server's service account."
    RUNTIME_SA="$PROJECT_NUMBER-compute@developer.gserviceaccount.com"
  fi
  say "Allowing $RUNTIME_SA to read the Sign in with Apple secrets"
  for NAME in "$APPLE_KEY_SECRET" "$ACCOUNT_SECRET_NAME"; do
    gcloud secrets add-iam-policy-binding "$NAME" \
      --member "serviceAccount:$RUNTIME_SA" \
      --role roles/secretmanager.secretAccessor \
      --project "$PROJECT" >/dev/null
  done
fi

# 4. Build the image on Google's machines (this is the slow step: 5–15 minutes the
#    first time, because it downloads the note-reading models).
SHORT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
TAG="$(date +%Y%m%d-%H%M%S)-$SHORT_SHA"
IMAGE="$REGION-docker.pkg.dev/$PROJECT/$AR_REPO/$SERVICE:$TAG"
say "Building $IMAGE with Cloud Build"
gcloud builds submit . \
  --config backend/cloudbuild.yaml \
  --substitutions "_IMAGE=$IMAGE" \
  --ignore-file backend/.gcloudignore \
  --project "$PROJECT"

# 5. Put it live (creates the service the first time, updates it afterwards).
#    --update-env-vars (not --set-env-vars) so anything set by hand in the console,
#    e.g. INCLUDE_DRAFTS=1 for an internal TestFlight, survives a re-run.
#    --concurrency 4: one instance keeps answering /healthz and /v1/identify while a
#    scan runs; extra scans wait in the server's own short queue (503 "Busy" when it
#    is full) instead of hitting Cloud Run's 429, which the app would show as
#    "Daily scan limit reached".
ENV_VARS="DAILY_SCAN_LIMIT=$DAILY_SCAN_LIMIT,DAILY_FEEDBACK_LIMIT=$DAILY_FEEDBACK_LIMIT"
# Secrets the server reads as environment variables, all in ONE --update-secrets flag
# ("VAR=secret-name:latest,VAR2=…", the documented form) so nothing depends on how
# gcloud treats a repeated flag. Only the secrets being turned on this run are named;
# --update-secrets (not --set-secrets) keeps the ones already on the service.
SECRETS=""
if [ "$FEEDBACK_ON" = 1 ]; then
  ENV_VARS="$ENV_VARS,SUPABASE_URL=$SUPABASE_URL"
  # The Supabase key (step 3b) and the community-trends salt (step 3c).
  SECRETS="SUPABASE_SERVICE_ROLE_KEY=$FEEDBACK_SECRET:latest,TRENDS_SALT=$TRENDS_SECRET:latest"
fi
# Sign in with Apple (step 3d): the scan limit for signed-in players always; the two
# ids and the two secrets only on a run that turns accounts on.
ENV_VARS="$ENV_VARS,SIGNED_IN_DAILY_SCAN_LIMIT=$SIGNED_IN_DAILY_SCAN_LIMIT"
if [ "$ACCOUNTS_ON" = 1 ]; then
  ENV_VARS="$ENV_VARS,APPLE_TEAM_ID=$APPLE_TEAM_ID,APPLE_KEY_ID=$APPLE_KEY_ID"
  SECRETS="${SECRETS:+$SECRETS,}APPLE_PRIVATE_KEY=$APPLE_KEY_SECRET:latest,ACCOUNT_SECRET=$ACCOUNT_SECRET_NAME:latest"
fi
# (The ${ARR[@]+"${ARR[@]}"} form below is how an empty array is expanded safely
# under `set -u` in the bash 3.2 that ships with macOS.)
SECRET_FLAGS=()
if [ -n "$SECRETS" ]; then
  SECRET_FLAGS=(--update-secrets "$SECRETS")
fi

say "Deploying to Cloud Run service '$SERVICE'"
gcloud run deploy "$SERVICE" \
  --image "$IMAGE" \
  --region "$REGION" \
  --project "$PROJECT" \
  --platform managed \
  --allow-unauthenticated \
  --memory 4Gi \
  --cpu 2 \
  --cpu-boost \
  --concurrency 4 \
  --timeout 300 \
  --min-instances 0 \
  --max-instances 3 \
  --port 8080 \
  --update-env-vars "$ENV_VARS" \
  ${SECRET_FLAGS[@]+"${SECRET_FLAGS[@]}"} \
  --quiet

# 6. Check it answers and print the address for the app.
URL="$(gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT" --format 'value(status.url)')"
[ -n "$URL" ] || die "Deployed, but couldn't read the service address. Look in the Cloud Run console."
say "Checking $URL/healthz"
if curl -fsS --max-time 90 "$URL/healthz" >/dev/null 2>&1; then
  echo "The server answered."
else
  echo "The server didn't answer yet — give it a minute, then open $URL/healthz in a browser."
fi

if [ "$FEEDBACK_ON" = 1 ]; then
  say "Feedback storage is ON: 'Send feedback' and 'Report an error' in the app now land in your Supabase table 'feedback'."
  echo "Community trends are ON too, once the trends migration (supabase/migrations/20261012010000_trends.sql) is applied."
else
  say "Feedback storage: not changed this run (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY weren't set)."
  echo "If you never turned it on, it is OFF: the app keeps players' messages on their device until the server"
  echo "accepts them. To turn it on, follow docs/SETUP.md → 'Turn on feedback (Supabase)' and run this script again."
fi

if [ "$ACCOUNTS_ON" = 1 ]; then
  say "Sign in with Apple is ON (team $APPLE_TEAM_ID, key $APPLE_KEY_ID), once the accounts migration"
  echo "(supabase/migrations/20261012000000_accounts.sql) is applied and feedback storage (Supabase) is on."
else
  say "Sign in with Apple: not changed this run (APPLE_TEAM_ID / APPLE_KEY_ID weren't set)."
  echo "If you never turned it on, it is OFF: nobody can sign in yet, and everything else in the app works"
  echo "without an account. See docs/SETUP.md → 'Sign in with Apple (once)'."
fi

printf '\nPaste this into the app: Settings → Server\n\n    %s\n\n' "$URL"
