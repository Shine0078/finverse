# Public hosting: Google Cloud Run + Neon

This is the lowest-operations public deployment path for FINVERSE. Cloud Run
hosts the API and Flutter PWA in the existing `Dockerfile.public`; Neon hosts
the persistent PostgreSQL database. There is no VM, Ubuntu installation, or
SSH server to maintain.

**Credential safety:** if a Neon URL has ever been pasted into chat, source
control, or a terminal transcript, reset that role's password in Neon before
continuing. Treat the old URL as revoked and never reuse it.

## One-time Google Cloud setup

In Cloud Shell, select the project and enable the APIs:

```bash
gcloud config set project gen-lang-client-0585745083
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com
```

The project must have an attached billing account. Google Cloud's free quota
is usage-based, not a hard spending cap, so create a budget alert before
launching. Neon Free currently includes 0.5 GB storage and 100 compute-hours
per project each month; it scales compute to zero when idle.

## Neon connection details

Open **Connect** in the Neon dashboard and select **Direct connection**. Use
the owner URL as `DATABASE_URL`. Create a second URL with username
`finverse_app` and a new strong password for `DATABASE_APP_URL`; the migration
job creates that least-privileged role and applies the RLS policies.

Do not paste either URL into chat or commit them. Keep them in the private
Cloud Shell env file copied from `infra/cloudrun.env.example`.

## Build and deploy

Clone the repository in Cloud Shell, copy the example env file, and fill in the
Neon URLs, generated keys, reviewed legal-document URLs, and the temporary
Cloud Run origin:

```bash
git clone https://github.com/Shine0078/finverse.git
cd finverse
cp infra/cloudrun.env.example ~/finverse-cloudrun.env.yaml
nano ~/finverse-cloudrun.env.yaml
bash infra/scripts/deploy-cloud-run.sh ~/finverse-cloudrun.env.yaml
```

To avoid ever typing credentials into terminal history, use the interactive
helper instead. It prompts for the rotated owner URL and SMTP app password
without echoing either, creates the restricted `finverse_app` URL and
encryption keys, and writes the file with mode `600`:

```bash
bash infra/scripts/create-cloudrun-env.sh ~/finverse-cloudrun.env.yaml
bash infra/scripts/deploy-cloud-run.sh ~/finverse-cloudrun.env.yaml
```

The helper no longer writes legal URLs. For the technical beta, set all four
`LEGAL_*` values to the same-origin documents at
`/api/legal/terms/technical-beta-v1` and
`/api/legal/privacy/technical-beta-v1`. Placeholder `example.com` hosts are
refused at boot. Replace those documents with counsel-reviewed Terms and
Privacy before a commercial launch. The helper defaults to Gmail SMTP
(`smtp.gmail.com:587`), but accepts any SMTP provider at the prompts.

The script builds `Dockerfile.public` with Cloud Build, executes the Postgres
migrations as a one-shot Cloud Run Job, deploys the service with unauthenticated
HTTPS, and prints the permanent `run.app` URL. Replace
`CORS_ORIGINS` in the private env file with that URL and rerun the script once.
Cloud Run supplies the `PORT` variable automatically; do not add `PORT` to the
private env file.

If a previous build completed but a later deployment step failed, you can
reuse that image by setting `FINVERSE_IMAGE` to the image printed by Cloud
Build. This avoids rebuilding unchanged source.

Visit `https://SERVICE-URL/app/` for the PWA and
`https://SERVICE-URL/api/readiness` for the Cloud Run health check. The
platform-neutral `/healthz` route remains available on ordinary hosts. Keep
`MIGRATE_ON_BOOT=false`; migrations are a release
step so two Cloud Run instances cannot race on startup.

## Before accepting real customers

Replace the temporary legal URLs with counsel-approved HTTPS documents, set a
custom domain (and then update `CORS_ORIGINS`), add Cloud Run/Neon backup and
alerting, and only then add production Plaid and Stripe credentials. Sandbox
Plaid credentials are intentionally rejected by the production configuration.
