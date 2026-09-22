#!/usr/bin/env bash
set -euo pipefail

# Deploy FINVERSE to Cloud Run using a checked-out repository and a local
# env-vars YAML file. Secrets stay in the operator's Cloud Shell; this script
# never writes them to git or prints their values.
#
# Usage:
#   ./infra/scripts/deploy-cloud-run.sh ./infra/cloudrun.env.yaml
#
# The env file must contain the production variables documented in
# docs/17-public-hosting-google-cloud-run.md. Set DATABASE_URL and
# DATABASE_APP_URL to the Neon direct connection URLs. Keep the file private.

ENV_FILE="${1:-infra/cloudrun.env.yaml}"
PROJECT_ID="${GOOGLE_CLOUD_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${CLOUD_RUN_REGION:-us-central1}"
REPOSITORY="${ARTIFACT_REPOSITORY:-finverse}"
SERVICE="${CLOUD_RUN_SERVICE:-finverse}"
IMAGE_REPOSITORY="${FINVERSE_IMAGE_REPOSITORY:-${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${SERVICE}}"

case "${IMAGE_REPOSITORY}" in
  *:*|*@*)
    echo "FINVERSE_IMAGE_REPOSITORY must be an untagged Artifact Registry repository path." >&2
    exit 1
    ;;
esac

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  echo "No Google Cloud project is selected. Run: gcloud config set project PROJECT_ID" >&2
  exit 1
fi
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Environment file not found: ${ENV_FILE}" >&2
  echo "Copy infra/cloudrun.env.example to a private YAML file and fill it in." >&2
  exit 1
fi

# Deploy only committed application files. Untracked workstation files and
# unrelated projects never enter the upload, even if ignore rules regress.
git diff --quiet HEAD -- || { echo "Commit reviewed changes before deploying." >&2; exit 1; }
SHA="$(git rev-parse HEAD)"
IMAGE_TAG="${IMAGE_REPOSITORY}:${SHA}"
umask 077
WORK_DIR="$(mktemp -d /tmp/finverse-release.XXXXXX)"
cleanup_release() {
  case "${WORK_DIR:-}" in /tmp/finverse-release.*) rm -rf -- "${WORK_DIR}" ;; esac
}
trap cleanup_release EXIT
RUNTIME_ENV_FILE="${WORK_DIR}/runtime.json"
MIGRATION_ENV_FILE="${WORK_DIR}/migration.json"
node infra/scripts/cloudrun-env.mjs "${ENV_FILE}" "${SHA}" "${RUNTIME_ENV_FILE}" "${MIGRATION_ENV_FILE}"
mkdir "${WORK_DIR}/source"
git archive --format=tar HEAD -- package.json package-lock.json packages/contracts apps/api apps/mobile Dockerfile.public cloudbuild.yaml .dockerignore .gcloudignore |
  tar -xf - -C "${WORK_DIR}/source"

gcloud artifacts repositories describe "${REPOSITORY}" \
  --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1 || \
  gcloud artifacts repositories create "${REPOSITORY}" \
    --repository-format=docker --location="${REGION}" \
    --description="FINVERSE container images" --project="${PROJECT_ID}"

# Always build the checked-out commit. A mutable tag must never let old bytes
# inherit the current runtime GIT_SHA and pass the identity readback.
gcloud builds submit "${WORK_DIR}/source" \
  --project="${PROJECT_ID}" \
  --config="${WORK_DIR}/source/cloudbuild.yaml" \
  --substitutions="_IMAGE=${IMAGE_TAG},_GIT_SHA=${SHA}"

DIGEST="$(gcloud artifacts docker images describe "${IMAGE_TAG}" \
  --project="${PROJECT_ID}" --format='value(image_summary.digest)')"
if [[ ! "${DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "Could not resolve an immutable digest for ${IMAGE_TAG}." >&2
  exit 1
fi
IMAGE="${IMAGE_REPOSITORY}@${DIGEST}"
echo "Deploying immutable image ${IMAGE}."

# Migrations run once as a Cloud Run Job with the schema-owner URL. The
# application service receives only runtime settings and never runs migrations on
# boot. The job is idempotent and provisions the restricted RLS role.
gcloud run jobs deploy "${SERVICE}-migrate" \
  --image="${IMAGE}" --region="${REGION}" --project="${PROJECT_ID}" \
  --command=node --args=dist/infra/postgres/migrate.js \
  --env-vars-file="${MIGRATION_ENV_FILE}" --max-retries=1
gcloud run jobs execute "${SERVICE}-migrate" \
  --region="${REGION}" --project="${PROJECT_ID}" --wait

# Keep existing traffic until the candidate passes readiness and identity checks.
PREVIOUS_TRAFFIC="$(gcloud run services describe "${SERVICE}" --region="${REGION}" --project="${PROJECT_ID}" --format=json 2>/dev/null |
  node -e 'let input="";process.stdin.on("data",d=>input+=d);process.stdin.on("end",()=>{if(!input)return;const t=JSON.parse(input).status?.traffic??[];process.stdout.write(t.filter(x=>x.percent>0&&x.revisionName).map(x=>x.revisionName+"="+x.percent).join(","));});')" || PREVIOUS_TRAFFIC=""
RELEASE_TAG="review-${SHA:0:8}"
gcloud run deploy "${SERVICE}" \
  --image="${IMAGE}" --region="${REGION}" --project="${PROJECT_ID}" \
  --allow-unauthenticated --port=3000 --memory=1Gi --max-instances=1 \
  --no-traffic --tag="${RELEASE_TAG}" \
  --min-instances=1 --no-cpu-throttling \
  --env-vars-file="${RUNTIME_ENV_FILE}"

URL="$(gcloud run services describe "${SERVICE}" --region="${REGION}" \
  --project="${PROJECT_ID}" --format='value(status.url)')"
CANONICAL_URL="${URL}"
REVISION="$(gcloud run services describe "${SERVICE}" --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.latestReadyRevisionName)')"
URL="$(gcloud run services describe "${SERVICE}" --region="${REGION}" --project="${PROJECT_ID}" --format=json |
  node -e 'let input="";process.stdin.on("data",d=>input+=d);process.stdin.on("end",()=>{const tag=process.argv[1];const entry=JSON.parse(input).status.traffic.find(x=>x.tag===tag);if(!entry?.url)process.exit(1);process.stdout.write(entry.url);});' "${RELEASE_TAG}")"
echo
echo "Checking candidate deployment: ${URL}/app/"
echo "Health check:        ${URL}/api/readiness"
echo "Identity:            ${URL}/api/version"
READINESS="$(curl --fail --silent --show-error --max-time 20 "${URL}/api/readiness")"
echo "${READINESS}" | grep -F '"service":"finverse-api"' >/dev/null
VERSION="$(curl --fail --silent --show-error --max-time 20 "${URL}/api/version")"
echo "${VERSION}" | grep -F '"service":"finverse-api"' >/dev/null
echo "${VERSION}" | grep -F "\"sha\":\"${SHA}\"" >/dev/null || echo "${VERSION}" | grep -F "\"sha\":\"${SHA:0:7}\"" >/dev/null
LEGAL="$(curl --fail --silent --show-error --max-time 20 "${URL}/api/legal")"
echo "${LEGAL}" | grep -F 'example.com' >/dev/null && {
  echo "Legal URLs still point at example.com. Replace LEGAL_* before collecting real-user data." >&2
  exit 1
}
curl --fail --silent --show-error --max-time 20 "${URL}/api/categories" >/dev/null
curl --fail --silent --show-error --max-time 20 "${URL}/api/webauthn/status" >/dev/null
APP="$(curl --fail --silent --show-error --max-time 20 "${URL}/app/")"
echo "${APP}" | grep -F '<base href="/app/">' >/dev/null
echo
# Promotion is reversible; database migrations are never automatically reversed.
gcloud run services update-traffic "${SERVICE}" --region="${REGION}" --project="${PROJECT_ID}" --to-revisions="${REVISION}=100"
if ! curl --fail --silent --show-error --max-time 30 "${CANONICAL_URL}/api/version" |
  node -e 'let input="";process.stdin.on("data",d=>input+=d);process.stdin.on("end",()=>{try{const v=JSON.parse(input);if(v.service!=="finverse-api"||![process.argv[1],process.argv[1].slice(0,7)].includes(v.sha))process.exit(1);}catch{process.exit(1);}});' "${SHA}"; then
  if [[ -n "${PREVIOUS_TRAFFIC}" ]]; then
    gcloud run services update-traffic "${SERVICE}" --region="${REGION}" --project="${PROJECT_ID}" --to-revisions="${PREVIOUS_TRAFFIC}"
  fi
  echo "Production identity check failed; prior traffic was restored when available." >&2
  exit 1
fi
echo "Public deployment checks passed: ${CANONICAL_URL}/app/"
echo "Rollback traffic target: ${PREVIOUS_TRAFFIC:-none (first deployment)}"
echo "Next verify sign-in, session persistence, and a statement import in the deployed app."
