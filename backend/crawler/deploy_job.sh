#!/usr/bin/env bash
#
# Puts the audition-feed crawler on Google Cloud as a nightly job:
#   Cloud Run Job "auditioner-crawler"  +  Cloud Scheduler "auditioner-crawler-nightly"
#
# Run it from the repo folder in Terminal:     ./backend/crawler/deploy_job.sh
# (docs/SETUP.md covers the one-time Google Cloud sign-in; docs/FEED.md explains
# what the job does and how to review what it finds.)
#
# Safe to run again whenever the crawler code, the catalogue or the registry
# changes: every step either creates something once or updates what is already
# there. Stops at the first problem and says what to do. Secrets are typed in
# hidden and go straight to Secret Manager — they are never printed or stored here.
#
# Works with the macOS default bash (3.2): no associative arrays, no ${var,,}.

set -euo pipefail

REGION="${REGION:-us-central1}"
JOB="${JOB:-auditioner-crawler}"
AR_REPO="${AR_REPO:-auditioner}"
SCHEDULE="${SCHEDULE:-17 3 * * *}"      # 03:17 UTC every night (odd minute: less queueing)
TIME_ZONE="${TIME_ZONE:-Etc/UTC}"
ANTHROPIC_SECRET="${ANTHROPIC_SECRET:-anthropic-api-key}"
SUPABASE_SECRET="${SUPABASE_SECRET:-supabase-service-role-key}"
TASK_TIMEOUT="${TASK_TIMEOUT:-4h}"      # 250 orchestras × polite 10 s gaps fits comfortably
CRAWLER_CONCURRENCY="${CRAWLER_CONCURRENCY:-3}"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nStopped: %s\n' "$*" >&2; exit 1; }

# 0. Work from the repo root, wherever the script was started from.
cd "$(dirname "$0")/../.."
[ -f backend/crawler/Dockerfile.crawler ] && [ -f backend/crawler/cloudbuild.yaml ] \
  || die "Run this from the Auditioner repo folder (backend/crawler/Dockerfile.crawler not found)."
[ -d content/catalog ] || die "content/catalog is missing — the image needs the catalogue."
[ -f content/registry/orchestras.json ] \
  || die "content/registry/orchestras.json is missing — the crawler needs the list of orchestras."

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
say "Making sure Cloud Run, Cloud Build, Artifact Registry, Secret Manager and Cloud Scheduler are switched on"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  secretmanager.googleapis.com cloudscheduler.googleapis.com --project "$PROJECT"

# 3. A place to keep the image (shared with the API server).
if ! gcloud artifacts repositories describe "$AR_REPO" --location "$REGION" --project "$PROJECT" >/dev/null 2>&1; then
  say "Creating the image store '$AR_REPO' in $REGION"
  gcloud artifacts repositories create "$AR_REPO" \
    --repository-format docker --location "$REGION" --project "$PROJECT" \
    --description "Auditioner server images"
else
  say "Image store '$AR_REPO' already exists"
fi

# 4. Secrets. Created once, typed in hidden; later runs only check they exist.
#    To rotate a key later:  printf '%s' 'NEW-KEY' | gcloud secrets versions add anthropic-api-key --data-file=-
ensure_secret() {
  name="$1"; label="$2"
  if gcloud secrets describe "$name" --project "$PROJECT" >/dev/null 2>&1; then
    say "Secret '$name' already exists (not changed)"
    return 0
  fi
  say "Creating secret '$name'"
  printf 'Paste the %s and press Return (nothing is shown while you type): ' "$label"
  value=""
  IFS= read -rs value
  printf '\n'
  [ -n "$value" ] || die "Nothing was entered for $name."
  printf '%s' "$value" | gcloud secrets create "$name" --data-file=- --replication-policy automatic --project "$PROJECT"
  value=""
}
ensure_secret "$ANTHROPIC_SECRET" "Anthropic API key (console.anthropic.com → API keys)"
ensure_secret "$SUPABASE_SECRET" "Supabase service_role key (Supabase → Project settings → API)"

# 5. The Supabase project address (not a secret, but needed).
SUPABASE_URL="${SUPABASE_URL:-}"
if [ -z "$SUPABASE_URL" ]; then
  # Re-use the address an earlier deploy stored on the job, if there is one.
  EXISTING_URL="$(gcloud run jobs describe "$JOB" --region "$REGION" --project "$PROJECT" --format yaml 2>/dev/null \
    | grep -A1 'name: SUPABASE_URL' | grep 'value:' | awk '{print $2}' | head -n 1 || true)"
  if [ -n "$EXISTING_URL" ]; then
    SUPABASE_URL="$EXISTING_URL"
    say "Using the Supabase address already on the job: $SUPABASE_URL"
  else
    printf 'Supabase project URL (looks like https://abcdefgh.supabase.co): '
    IFS= read -r SUPABASE_URL
  fi
fi
case "$SUPABASE_URL" in
  https://*) ;;
  *) die "The Supabase URL should start with https:// (got '$SUPABASE_URL')." ;;
esac

# 6. The job's own service account, with just the rights it needs.
JOB_SA="auditioner-crawler@$PROJECT.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$JOB_SA" --project "$PROJECT" >/dev/null 2>&1; then
  say "Creating the job's service account"
  gcloud iam service-accounts create auditioner-crawler --display-name "Auditioner crawler job" --project "$PROJECT"
fi
for secret in "$ANTHROPIC_SECRET" "$SUPABASE_SECRET"; do
  gcloud secrets add-iam-policy-binding "$secret" --project "$PROJECT" \
    --member "serviceAccount:$JOB_SA" --role roles/secretmanager.secretAccessor --quiet >/dev/null
done

# 7. Build the image on Google's machines (a couple of minutes).
SHORT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
TAG="$(date +%Y%m%d-%H%M%S)-$SHORT_SHA"
IMAGE="$REGION-docker.pkg.dev/$PROJECT/$AR_REPO/$JOB:$TAG"
say "Building $IMAGE with Cloud Build"
gcloud builds submit . \
  --config backend/crawler/cloudbuild.yaml \
  --substitutions "_IMAGE=$IMAGE" \
  --ignore-file backend/crawler/.gcloudignore \
  --project "$PROJECT"

# 8. Create or update the job. Secrets are mounted as environment variables from
#    Secret Manager at run time; nothing is written into the image.
say "Deploying Cloud Run Job '$JOB'"
gcloud run jobs deploy "$JOB" \
  --image "$IMAGE" \
  --region "$REGION" \
  --project "$PROJECT" \
  --service-account "$JOB_SA" \
  --memory 1Gi \
  --cpu 1 \
  --task-timeout "$TASK_TIMEOUT" \
  --max-retries 0 \
  --tasks 1 \
  --set-env-vars "SUPABASE_URL=$SUPABASE_URL,CRAWLER_CONCURRENCY=$CRAWLER_CONCURRENCY" \
  --set-secrets "ANTHROPIC_API_KEY=$ANTHROPIC_SECRET:latest,SUPABASE_SERVICE_ROLE_KEY=$SUPABASE_SECRET:latest" \
  --quiet

# 9. A service account for the scheduler, allowed only to start this job.
SCHED_SA="auditioner-scheduler@$PROJECT.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$SCHED_SA" --project "$PROJECT" >/dev/null 2>&1; then
  say "Creating the scheduler's service account"
  gcloud iam service-accounts create auditioner-scheduler --display-name "Auditioner nightly scheduler" --project "$PROJECT"
fi
gcloud run jobs add-iam-policy-binding "$JOB" --region "$REGION" --project "$PROJECT" \
  --member "serviceAccount:$SCHED_SA" --role roles/run.invoker --quiet >/dev/null

# 10. The nightly schedule (create the first time, update afterwards).
RUN_URI="https://$REGION-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/$PROJECT/jobs/$JOB:run"
SCHEDULER_JOB="$JOB-nightly"
if gcloud scheduler jobs describe "$SCHEDULER_JOB" --location "$REGION" --project "$PROJECT" >/dev/null 2>&1; then
  say "Updating the nightly schedule ($SCHEDULE $TIME_ZONE)"
  gcloud scheduler jobs update http "$SCHEDULER_JOB" \
    --location "$REGION" --project "$PROJECT" \
    --schedule "$SCHEDULE" --time-zone "$TIME_ZONE" \
    --uri "$RUN_URI" --http-method POST \
    --oauth-service-account-email "$SCHED_SA" \
    --attempt-deadline 30m --quiet
else
  say "Creating the nightly schedule ($SCHEDULE $TIME_ZONE)"
  gcloud scheduler jobs create http "$SCHEDULER_JOB" \
    --location "$REGION" --project "$PROJECT" \
    --schedule "$SCHEDULE" --time-zone "$TIME_ZONE" \
    --uri "$RUN_URI" --http-method POST \
    --oauth-service-account-email "$SCHED_SA" \
    --attempt-deadline 30m --quiet
fi

printf '\nDone. The crawler runs every night at %s (%s).\n' "$SCHEDULE" "$TIME_ZONE"
printf 'To run it right now:        gcloud run jobs execute %s --region %s\n' "$JOB" "$REGION"
printf 'To watch the log:           gcloud run jobs executions list --job %s --region %s\n' "$JOB" "$REGION"
printf 'New lists wait for you in Supabase → Table editor → vacancies (review_status = in_review). See docs/FEED.md.\n\n'
