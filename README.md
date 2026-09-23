# FINVERSE

An AI-powered personal finance platform. Privacy-first, offline-capable,
automated.

[`MISSION1.md`](MISSION1.md) and [`MISSION2.md`](MISSION2.md) are the product briefs. [`docs/`](docs/) turns them into
a plan. This README tells you how to run what exists.

**Status: launch engineering in progress.** Current verified state is [`STATUS.md`](STATUS.md). Historical investigation lives in [`HANDOVER-VERIFIED.md`](HANDOVER-VERIFIED.md) and older handover files. The API and Android app include
TOTP multi-factor authentication, device app lock, real
Plaid Sandbox Link, encrypted token storage, incremental sync, budgets, goals,
evidence-based bill, subscription, duplicate-charge, and unusual-spending alerts,
insights, and account lifecycle controls. Production Plaid access,
hosting, legal review, store approval, and billing remain external launch gates
([selling audit](docs/08-what-blocks-selling.md)).

## Deployment status

The canonical production path is Google Cloud Run + Neon, but the advertised
Cloud Run URL is currently an older deployment and is not the verified
candidate:

- **Stale public URL** — <https://finverse-d6vqs5iu7q-uc.a.run.app/app/>
- **Candidate preview** — <http://localhost:3001/app/> when the local preview
  server is running.
- **Candidate identity** — `http://localhost:3001/api/version` reports the
  locally verified schema and build state.
- **Required before launch** — deploy the exact CI-green candidate SHA, then
  verify `/api/readiness`, `/api/version`, and `/app/` from the same Cloud Run
  origin before directing users to it.

GitHub Pages and `finverse.onrender.com` are **not** the current API. Render still
serves an unrelated Express placeholder (`/healthz` is 404). Release Android
builds are configured for the canonical Cloud Run origin, which must be
redeployed from the verified candidate before production use.
See [`docs/17-public-hosting-google-cloud-run.md`](docs/17-public-hosting-google-cloud-run.md).

## Quick start

```bash
npm install
```

## Preview hosting

`render.yaml` remains a **preview-only** blueprint (`finverse-preview`). It is not
the canonical technical-beta. Use Cloud Run + Neon for the public API and PWA.
Historical Render notes live in [`docs/14-public-hosting-render.md`](docs/14-public-hosting-render.md).

Run the whole pipeline in-process and watch it work — no server, no database:

```bash
npm run demo
```

Or start the API with its in-memory developer dashboard at <http://localhost:3000/>:
(`STORE=postgres` deliberately disables the fabricated dashboard):

```bash
npm run dev
```

Run the tests:

```bash
npm test
```

On Windows, configure Plaid Sandbox without writing credentials into the repo:

```powershell
npm run plaid:configure --workspace @finverse/api
```

Open the one-time loopback URL it prints, paste the Client ID and Sandbox secret,
then restart open terminals. The helper stores user-level development variables
and preserves an existing bank-token encryption key. Production must use the
hosting provider's secret manager instead.

## Layout

```
apps/
  api/          NestJS API — the vertical slice
    src/domain/   pure financial logic, no framework, no I/O
    src/ports/    interfaces the domain needs satisfied
    src/infra/    in-memory, Postgres, mock, email, and Plaid adapters
    src/modules/  controllers and services — thin wiring
    public/       in-memory development dashboard (never served by persistent stores)
    test/         domain, HTTP, persistence, isolation, and Plaid tests
  mobile/       Flutter Android client with native Plaid Link
packages/
  contracts/    shared API types
infra/          docker-compose: PostgreSQL plus backup/restore tooling
docs/           architecture, data model, privacy, roadmap, ADRs
```

## The one rule

**Domain logic is pure. Infrastructure is an adapter.**

Categorization, budget arithmetic, insight derivation, and the health score are
plain functions over plain data — no framework imports, no database, no clock
access. Everything else sits behind a port interface.

That is why the tests run in under two seconds without a database, and why the
slice runs today with no Docker. See [ADR-0002](docs/adr/0002-pure-domain-layer.md).

## API

Base path `/api`. **Every route requires a bearer token** except those marked
public — the guard is registered globally, so a new controller is protected the
moment it is written.

```bash
curl -X POST localhost:3000/api/auth/register \
  -H 'content-type: application/json' \
  -d '{"email":"you@example.com","password":"correct horse battery staple"}'
```

When reviewed legal documents are configured, first read `GET /api/legal` and
send both acceptance booleans plus the exact returned `termsVersion` and
`privacyVersion`. Production refuses to boot until versioned HTTPS Terms and
Privacy Notice URLs are configured; the mobile client handles this handshake.

Then send `Authorization: Bearer <accessToken>` on everything else. Access tokens
last 15 minutes; exchange the refresh token at `/api/auth/refresh` for a new pair.

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/auth/register` | **Public.** Create an account, returns a session |
| `GET` | `/legal` | **Public.** Current Terms/Privacy versions and URLs required at registration |
| `POST` | `/auth/login` | **Public.** Exchange credentials for a session |
| `POST` | `/auth/refresh` | **Public.** Rotate the refresh token |
| `POST` | `/auth/logout` | End this session |
| `POST` | `/auth/logout-all` | End every session on every device |
| `GET` | `/auth/me` | The signed-in user |
| `GET` | `/auth/sessions` | Active sessions, with the current one marked |
| `DELETE` | `/auth/sessions/:id` | Revoke one session |
| `POST` | `/privacy/export` | Password-confirmed portable JSON export of user-owned data and security activity |
| `GET` | `/privacy` | Optional consent state/history, security activity, and retention summary |
| `PATCH` | `/privacy/consents/:kind` | Append a grant/withdrawal event for analytics or product updates |
| `POST` | `/sync` | Pull from the aggregator, categorize, persist |
| `GET` | `/bank-links` | List connected institutions and sync health |
| `POST` | `/bank-links/link-token` | Password-confirmed Plaid Link token (new or update mode) |
| `POST` | `/bank-links/exchange` | Exchange a temporary public token and begin sync |
| `POST` | `/bank-links/:id/sync` | Incrementally reconcile one institution |
| `DELETE` | `/bank-links/:id` | Revoke Plaid access and remove the stored token |
| `GET` | `/accounts` | Balances and credit utilization |
| `POST`/`PATCH`/`DELETE` | `/accounts/manual[/:id]` | User-owned cash, offline assets, investments, and debts; provider rows are never editable here |
| `GET` | `/transactions` | `?search=&category=&account=&kind=&pending=&recurring=&minAmount=&maxAmount=&from=&to=&before=&limit=` |
| `GET` | `/transactions/export.csv` | Download the user-owned ledger as a CSV; spreadsheet-formula-safe text fields |
| `GET` | `/transactions/needs-review` | What we refused to guess at |
| `POST` | `/imports/statements` | Upload and stage a CSV, XLSX, PDF, or supported image statement for review |
| `GET`/`PATCH`/`POST`/`DELETE` | `/imports/statements/:id...` | Review rows, split/merge, approve, inspect audit, and remove the original source |
| `PATCH` | `/transactions/:id/category` | Correct a category, optionally create a rule |
| `GET`/`DELETE` | `/categorization-rules[/:id]` | Review or remove durable merchant categorization rules |
| `GET`/`POST` | `/budgets` | List / create |
| `GET` | `/budgets/progress` | Spend, thresholds, projections, alerts |
| `GET` | `/insights` | `?currency=USD`; month-to-date vs. the same window last month without mixing currencies |
| `GET` | `/analytics` | `?period=week|month|3m|6m|year|lifetime|custom&from=&to=&currency=`; spending, income, savings, velocity, refund matches, and timeline |
| `GET` | `/reports/monthly.pdf?asOf=YYYY-MM-DD&currency=CAD` | Private multi-page PDF with currency-specific cash-flow charts, budgets, subscriptions, forecast, and actions |
| `GET` | `/subscriptions?currency=CAD` | Currency-specific detected recurring charges and price rises |
| `GET` | `/health-score` | 0–1000 with per-component actions |
| `GET` | `/cash-flow-forecast?days=7|30|90&currency=CAD` | Currency-specific conservative liquid-cash outlook from repeatable income and bills |
| `GET` | `/purchase-scenario?days=7|30|90&amount=<minor>&date=YYYY-MM-DD&currency=CAD` | One-off purchase impact against the same currency-specific outlook |
| `GET` | `/credit-cards` | Utilization, pay-down target, and an early payment window |
| `PATCH` | `/notifications/:id/read` | Mark one alert read |
| `PATCH` | `/notifications/read-all` | Mark all alerts read |
| `POST` | `/receipts/scan` | Recognise pasted receipt text without storing it |
| `PUT` | `/receipts/:transactionId` | Attach a parsed receipt to one of your transactions |
| `GET` | `/receipts/:transactionId` | The stored receipt for a transaction |
| `POST`/`DELETE` | `/push/device` | Register / unregister this device for remote push |
| `GET` | `/webauthn/status` | **Public.** Whether passkeys are configured |
| `POST` | `/webauthn/register/options` · `/verify` | Passkey registration ceremony |
| `POST` | `/webauthn/login/options` · `/verify` | Passkey login ceremony |
| `GET`/`DELETE` | `/webauthn/credentials[/:id]` | Manage the user's passkeys |
| `GET` | `/billing/subscription` | Current plan, entitlements, and renewal state |
| `POST` | `/billing/checkout-session` | Start hosted checkout for a plan. Returns a URL; no card data reaches this API |
| `POST` | `/billing/portal-session` | Link to the provider's page for cancellation, card changes, and invoices |
| `POST` | `/billing-webhooks/stripe` | **Public.** Signature-verified over the raw body |
| `GET` | `/billing/plans` | **Public.** The tier catalogue |
| `GET` | `/categories` | **Public.** The seeded category tree |
| `GET` | `/healthz` | **Public.** Liveness and database readiness |

## Billing

Off unless `STRIPE_SECRET_KEY` is set, and it says so rather than half-working:
`/billing/subscription` reports everyone as free with `purchaseAvailable: false`,
and checkout returns 503.

Card details never reach this API — checkout and card management are the
provider's hosted pages, which is what keeps PCI DSS out of scope. Entitlement is
derived by a pure function that fails closed on a missing record, an unknown
status, or a lapsed period, so a missed webhook downgrades rather than gives the
product away.

**Free tells you where your money went; Pro tells you what happens next.** The
free tier keeps transactions, categorisation, budgets, goals, insights, the
health score, subscription detection and export; Pro adds the cash-flow
forecast, the purchase simulator, the monthly PDF report, and more than one
connected institution. Monthly or annual, with a 14-day trial.
See [09-pricing.md](docs/09-pricing.md) for the price points and the argument
behind them.

Gates are **inert on any deployment with no payment provider configured** —
nobody is refused a feature for not paying where paying is impossible, which is
the state of every developer checkout and CI run. Configuring Stripe is what
switches pricing on; there is no second flag.

The mobile client has a plan screen and a paywall sheet, and turns the API's
`plan_upgrade_required` 403 into a typed exception so any gated route explains
itself instead of showing a raw error. Purchasing from inside the app is behind
`BILLING_PURCHASE_MODE`, which **defaults to `informational`** — no checkout
button — because Apple and Google require their own billing for digital
subscriptions:

```bash
flutter build apk --dart-define=BILLING_PURCHASE_MODE=linkOut
```

See [ADR-0007](docs/adr/0007-billing-and-entitlements.md) for the full reasoning.

## Persistence

Two adapters implement the same store ports. Which one runs is decided in one
place — `src/modules/core.module.ts` — and nothing in the domain, the services,
or the controllers knows the difference.

| `STORE` | Behaviour |
|---|---|
| `postgres` | Persists. Requires `DATABASE_URL`. |
| `memory` | Fast, zero-dependency, **lost on restart**. |

The default is `postgres` when `DATABASE_URL` is set and `memory` otherwise, so
the repo works on a machine with no database but persists as soon as one exists.

```bash
npm run infra:up                        # PostgreSQL via docker compose
npm run dev
```

Two connection strings, deliberately. `DATABASE_URL` is the schema owner and is
used for migrations only; `DATABASE_APP_URL` is the restricted role that serves
requests, and it is the one row-level security applies to — a superuser bypasses
every policy without saying so. The role is created by the migration step from
the credentials in that URL, so it does not have to exist beforehand. Leaving it
unset still runs, and logs on every boot that isolation is resting on
application code alone. See [ADR-0006](docs/adr/0006-row-level-security.md).

Migrations live in `apps/api/migrations` as numbered `.sql` files, applied once
each inside a transaction. They run automatically on boot in development; set
`MIGRATE_ON_BOOT=false` in production and run them as a deploy step, so two
instances starting together cannot race.

```bash
npm run migrate --workspace @finverse/api
```

`GET /healthz` reports `status: "degraded"` when the database is unreachable
rather than claiming success because the process is alive.

### Testing against Postgres

The store contract suite runs against both adapters — the same assertions, twice —
so a divergence between them fails a test rather than surfacing as a wrong number
in production.

One command, no Docker required. It unpacks the official PostgreSQL binaries,
runs the suite against them, and throws the data directory away afterwards:

```bash
npm run test:db
```

Run the guarded authenticated load smoke against the in-memory development path:

```bash
npm run load:smoke
```

CI runs the same benchmark against PostgreSQL. A database target requires the
explicit `LOAD_TEST_DATABASE=true` safety flag, and remote targets require a
second confirmation so this command is not accidentally aimed at production.

`npm test` on its own skips the Postgres half and runs the in-memory adapter
only — that is what a contributor without a database gets, and it must keep
passing on its own.

The suite creates the restricted `finverse_app` role itself and connects the
stores through it, so both halves of row-level security — the policies and the
role they apply to — are exercised on every run rather than only in production.

To leave a database running for `npm run dev`:

```bash
npm run db:start
```

It prints both connection strings to paste into `.env`.

If you prefer containers, `npm run infra:up` brings up the same thing via
docker compose. Docker is never required: it does not start reliably on every
machine, and a database test that silently skips is one nobody notices has
stopped running.

## Notes on what is and isn't verified

- **The API and its domain logic run and are tested.** Current counts live in `HANDOVER-VERIFIED.md`. An earlier in-memory suite and a later full PostgreSQL run both passed, including
  the store contract — which runs as the restricted role, so it executes with the
  row-level security policies in force — and a suite that issues deliberately
  unfiltered SQL to prove the database withholds other users' rows on its own.
  The slice is also exercised end to end over HTTP.
- **The Flutter app is verified by static analysis, automated tests, and real
  Android release APK and web builds.** Android and iOS platform projects can be generated
  locally. See the
  [cheap launch path](docs/06-cheap-launch-path.md).
- **Ask FINVERSE is available without an external AI provider.** The protected
  `/api/assistant` route answers common spending, savings, merchant, and
  subscription questions from explainable aggregates; a zero-retention LLM is
  optional and never required for core functionality.
- **Users can share a professional monthly PDF from Settings.** The report is
  generated on demand and includes summary metrics, vector charts, category and
  budget performance, recurring costs, a 30-day forecast, and prioritized actions.
- **CI is ready in `.github/workflows/ci.yml`.** It starts automatically after a
  commit is pushed to GitHub and requires no secrets for its default checks.

## Where to read next

1. [docs/01-architecture.md](docs/01-architecture.md) — the shape of the system
2. [docs/05-vertical-slice.md](docs/05-vertical-slice.md) — what runs today
3. [docs/adr/](docs/adr/) — the decisions, including where the mission's
   zero-knowledge goal collides with its AI goals
4. [docs/06-cheap-launch-path.md](docs/06-cheap-launch-path.md) — the cheapest
   safe route to a personal Android beta

## License

MIT — see [LICENSE](LICENSE).
