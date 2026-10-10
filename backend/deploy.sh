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

set -euo pipefail

REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-auditioner-api}"
AR_REPO="${AR_REPO:-auditioner}"
DAILY_SCAN_LIMIT="${DAILY_SCAN_LIMIT:-30}"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nStopped: %s\n' "$*" >&2; exit 1; }

# 0. Work from the repo root, wherever the script was started from.
cd "$(dirname "$0")/.."
[ -f backend/Dockerfile ] && [ -f backend/cloudbuild.yaml ] \
  || die "Run this from the Auditioner repo folder (backend/Dockerfile not found)."
[ -d content/catalog ] || die "content/catalog is missing — the image needs the catalogue."

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

# 3. A place to keep the server image.
if ! gcloud artifacts repositories describe "$AR_REPO" --location "$REGION" --project "$PROJECT" >/dev/null 2>&1; then
  say "Creating the image store '$AR_REPO' in $REGION"
  gcloud artifacts repositories create "$AR_REPO" \
    --repository-format docker --location "$REGION" --project "$PROJECT" \
    --description "Auditioner server images"
else
  say "Image store '$AR_REPO' already exists"
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
  --update-env-vars "DAILY_SCAN_LIMIT=$DAILY_SCAN_LIMIT" \
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

printf '\nPaste this into the app: Settings → Server\n\n    %s\n\n' "$URL"
