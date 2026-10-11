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
# Extra flags only used when feedback storage is being turned on this run. (The
# ${ARR[@]+"${ARR[@]}"} form below is how an empty array is expanded safely under
# `set -u` in the bash 3.2 that ships with macOS.)
FEEDBACK_FLAGS=()
if [ "$FEEDBACK_ON" = 1 ]; then
  ENV_VARS="$ENV_VARS,SUPABASE_URL=$SUPABASE_URL"
  FEEDBACK_FLAGS=(--update-secrets "SUPABASE_SERVICE_ROLE_KEY=$FEEDBACK_SECRET:latest")
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
  ${FEEDBACK_FLAGS[@]+"${FEEDBACK_FLAGS[@]}"} \
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
else
  say "Feedback storage: not changed this run (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY weren't set)."
  echo "If you never turned it on, it is OFF: the app keeps players' messages on their device until the server"
  echo "accepts them. To turn it on, follow docs/SETUP.md → 'Turn on feedback (Supabase)' and run this script again."
fi

printf '\nPaste this into the app: Settings → Server\n\n    %s\n\n' "$URL"
