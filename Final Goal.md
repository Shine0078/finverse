You are taking over the FINVERSE project as a **senior principal software engineer, security engineer, DevSecOps engineer, mobile engineer, SRE, fintech architect, and adversarial reviewer**.

Your job is **not** to simply read documentation and assume it is correct.

Your job is to inspect the **actual repository, actual Git state, actual deployment configuration, actual CI/CD, actual live endpoints, actual mobile implementation, actual security controls, and actual tests**, then continue improving FINVERSE until every repository-local task that can reasonably be completed is finished.

---

# PROJECT

**Repository path**

`C:\Users\samue\OneDrive\Desktop\starter`

**Current working branch**

`codex/passkey-webauthn-p0`

At the latest verified review:

* Current branch HEAD: `d7fb6ba`
* `main` is **58 commits behind**
* Working branch CI is green
* Working tree was clean
* Branch had approximately:

  * 82 files changed vs `main`
  * 3,614 insertions
  * 302 deletions
* No obvious textual merge conflict was found against `main`

Do **not** assume these numbers are still current. Re-check them before acting.

---

# PRIMARY MISSION

Continue from the actual repository state and move FINVERSE through:

**P0 → P1 → P2**

in strict risk and dependency order.

Your objective is:

> Turn FINVERSE into the strongest technically achievable production candidate while preserving security, data isolation, release integrity, mobile reliability, financial correctness, user privacy, and deployment reproducibility.

Do not waste time rebuilding systems that are already correctly implemented and tested.

Focus effort where adversarial evidence shows the real remaining risk exists.

---

# OPERATING RULE

Use this loop continuously:

**INSPECT → VERIFY → ATTACK ASSUMPTIONS → REPRODUCE → FIX → TEST → REVIEW → COMMIT → CONTINUE**

Do not stop because one task passes.

When one verified task is finished, immediately move to the next highest-priority task.

Do not ask for permission to continue normal engineering work.

Do not claim something is complete because:

* documentation says so,
* a file exists,
* a unit test exists,
* `/` returns HTTP 200,
* the application compiles,
* a deployment workflow exists,
* a GitHub Action is green,
* or a UI screen renders.

Verify the actual system behavior.

---

# IMPORTANT ADVERSARIAL FINDINGS ALREADY VERIFIED

Treat these as starting evidence, but independently re-check them before changing production-critical code.

---

# 1. BRANCH / RELEASE STATE

The working branch:

`codex/passkey-webauthn-p0`

was verified as **58 commits ahead of `main`**.

The current feature branch CI was green.

The most recent observed `main` CI was not healthy enough to justify releasing `main` as-is.

GitHub branch protection for `main` was checked and GitHub reported:

`Branch not protected`

There was also no repository-level `CODEOWNERS` file detected.

This means the release pipeline may be cryptographically and mechanically strict while the branch feeding it remains insufficiently governed.

Do **not** weaken the release gate to publish feature branches directly.

Preserve the intended secure release chain:

**feature branch → PR → required CI → protected main → green main CI → release**

---

# 2. WEBAUTHN / PASSKEY BACKEND

Do **not** rebuild the entire server-side WebAuthn implementation unless you find a concrete security defect.

The current implementation has already been significantly hardened.

Verified functionality includes:

* PostgreSQL-backed WebAuthn credential storage
* PostgreSQL-backed challenge/ceremony storage
* hashed ceremony IDs
* purpose binding
* atomic challenge consumption
* five-minute challenge expiry
* ES256 verification
* required user presence
* required user verification
* RP ID validation
* origin allowlisting
* credential ID binding
* registration AT flag enforcement
* sign-counter handling
* credential enumeration protection
* restricted credential-owner routing
* FORCE RLS
* throttled passkey registration/removal/login
* passkey failure lockout
* password lockout separated from passkey lockout
* security event recording
* passkey add/remove notifications
* password step-up
* MFA step-up when enabled
* normal FINVERSE session issuance after successful passkey authentication
* mobile client persistence of successful passkey sessions

Successful passkey authentication eventually uses the normal FINVERSE session path.

That is the correct architecture.

Do not create a parallel token/session model for passkeys.

---

# 3. REMAINING PASSKEY GAP

The real passkey gap is **native platform ceremony support**.

Current mobile platform abstraction effectively behaves like:

* Web → uses browser WebAuthn / `navigator.credentials`
* Native iOS/Android → reports unsupported

Native code intentionally refuses to pretend there is a valid hardware ceremony.

This is good failure behavior, but it is not production-complete.

You must complete native passkey support.

---

# 4. CURRENT PUBLIC DEPLOYMENT SPLIT

This is one of the most important findings.

FINVERSE currently has conflicting deployment paths.

## Broken public path

The GitHub Pages PWA:

`https://shine0078.github.io/finverse/app/`

was verified to load its UI.

However its compiled `main.dart.js` contains:

`finverse.onrender.com`

The repository GitHub variable:

`API_BASE_URL`

also pointed to:

`https://finverse.onrender.com`

At review time:

`https://finverse.onrender.com`

returned **HTTP 503**.

Historically that same Render hostname had also served an unrelated placeholder Express application rather than FINVERSE.

Therefore the public GitHub Pages UI can render while authentication, account creation, and bank operations fail.

More importantly:

**future Android release artifacts built by the release workflow will also target the broken backend if `API_BASE_URL` is not corrected.**

Treat this as a **P0 release-integrity defect**.

---

# 5. WORKING CLOUD RUN DEPLOYMENT

A second deployment was verified:

Google Cloud Run + Neon PostgreSQL.

The Cloud Run application endpoint served `/app/`.

The readiness endpoint:

`/api/readiness`

returned HTTP 200 and reported:

* service: `finverse-api`
* store: `postgres`
* database: `reachable`

The Cloud Run Flutter bundle did not embed the dead Render hostname.

This same-origin deployment architecture is significantly safer because:

**Web PWA + FINVERSE API share the same origin.**

This reduces:

* CORS mistakes
* stale API hostname problems
* split deployment failures
* release-variable mismatch
* cross-origin authentication issues

Unless new evidence shows otherwise, prefer Cloud Run + Neon as the current controlled technical-beta deployment.

---

# 6. LIVE LEGAL CONFIGURATION IS NOT READY FOR REAL USERS

The Cloud Run endpoint:

`/api/legal`

was live.

The registration gate was enabled.

However the legal document URLs were still placeholder `example.com` values.

This must be treated as a **real-user P0 gate**.

Do not allow real customer financial data to be collected while production registration points to temporary placeholder Terms or Privacy documents.

Code may be correct, but production policy configuration is not.

---

# 7. LIVE PASSKEY DEPLOYMENT STATUS

Cloud Run:

`/api/webauthn/status`

returned approximately:

`{"available":false}`

Therefore the server code supports WebAuthn but the live beta environment has not actually activated valid relying-party configuration.

You must distinguish:

**implemented in repository**

from:

**enabled and validated in deployed environment**

They are not the same thing.

---

# 8. MONITORING FALSE POSITIVE

The repository includes a scheduled workflow:

`Production uptime`

Recent workflow runs were green.

However GitHub repository variables did not include a configured:

`PRODUCTION_HEALTH_URL`

The workflow's current behavior is to mark itself healthy and exit successfully if the health URL is absent.

Therefore:

> Green uptime workflow runs currently do not prove production uptime.

They prove only that the monitoring job itself executed.

This is dangerous because it creates false operational confidence.

Fix this.

---

# 9. CURRENT TEST / SECURITY EVIDENCE

The adversarial review re-ran the complete PostgreSQL-backed API suite on the active branch.

Latest verified result:

**62 test files**

**1,014 tests passed**

**0 failed**

The previous handover count was lower, so do not quote stale counts.

Re-run the tests yourself and record the current exact number.

Production npm audit:

`npm audit --omit=dev --audit-level=high`

returned:

**0 vulnerabilities**

Flutter analysis:

`flutter analyze`

returned:

**No issues found**

Flutter test suite was also rerun.

The first execution failed because the Remote Desktop Commander environment lacked `%PROGRAMFILES(X86)%`.

Once supplied, the test suite completed:

**112 tests passed**

So that environment-variable problem was not a FINVERSE code regression.

Use the current environment and re-run verification.

---

# 10. DATABASE / RLS SECURITY

Production has strong runtime-role safeguards.

The code already checks that production:

* uses PostgreSQL
* has `DATABASE_APP_URL`
* does not use the same DB role as schema owner
* does not run migrations automatically on boot
* rejects superuser runtime roles
* rejects `BYPASSRLS`
* rejects runtime roles owning public tables

These are important and must be preserved.

Do not simplify production database configuration by reconnecting the application as the schema owner.

Production runtime must never operate with owner/superuser privileges.

---

# 11. CI/CD SECURITY ALREADY PRESENT

Do not duplicate work unnecessarily.

The repository already contains important release controls, including:

* SHA-pinned GitHub Actions
* production `npm audit`
* PostgreSQL service-container testing
* migrations
* migration idempotence verification
* backup/restore drill
* authenticated PostgreSQL load smoke
* API build
* deployable container build
* Flutter analyze
* Flutter tests
* Android release compile
* PWA release compile
* unsigned iOS compile
* release artifacts
* Android signing secret requirements
* release SHA verification
* main/master-only release gating
* SBOM
* build provenance
* Dependabot for:

  * npm
  * Docker
  * GitHub Actions
  * Flutter/pub

Do not throw these away.

Strengthen them where needed.

---

# 12. DASHBOARD / PRODUCT FEATURES ALREADY EXIST

Do not waste P0 engineering time rebuilding dashboards from scratch.

FINVERSE already includes substantial financial UX:

* category spending donut chart
* income vs spending trends
* budget progress
* projected budget overrun warnings
* financial health score
* net position
* net-worth history
* income metrics
* expense metrics
* net cash flow
* savings rate
* period-over-period comparison
* evidence-based insights
* subscription detection
* recurring-charge analysis
* transaction timelines
* 7/30/90-day cash-flow forecasting
* purchase simulation
* financial calendar
* low-balance forecasting
* monthly PDF reporting
* week analytics
* month analytics
* 3-month analytics
* 6-month analytics
* annual analytics
* lifetime analytics
* custom date range analytics
* budget and goal workflows
* shared expenses
* receipt parsing/OCR
* deterministic financial assistant
* correction-driven categorization learning

Evaluate UX quality and correctness.

Do not pretend these features are absent.

---

# P0 — BEFORE REAL USERS

Everything in P0 is a launch blocker.

Work through these in dependency order.

---

## P0.1 — Establish one canonical deployment

The project must stop presenting multiple contradictory "production" paths.

Choose and enforce one canonical technical-beta deployment.

Current preferred architecture:

**Google Cloud Run + Neon PostgreSQL + same-origin Flutter PWA**

Canonical form:

`https://<canonical-host>/app/`

and the API at the same origin.

Do not simultaneously tell users that:

* GitHub Pages is production,
* Render is production,
* Cloud Run is production,
* and temporary Cloudflare tunnels are production.

There must be exactly one current source of truth.

### Actions

* verify Cloud Run service identity
* verify current deployed SHA/version if possible
* verify database connectivity
* verify `/api/readiness`
* verify `/app/`
* verify `/api/legal`
* verify `/api/categories`
* verify authentication routes
* verify CORS configuration
* verify production environment settings
* verify no sandbox-only or preview-only configuration leaks into real production
* verify migrations match current branch
* verify deployed Flutter bundle matches deployed API
* retire or clearly mark stale deployment paths

### Exit criteria

Only one public technical-beta URL is described as canonical.

Every client release targets the intended backend.

---

## P0.2 — Fix GitHub `API_BASE_URL`

Inspect GitHub repository variables.

If it still points at the dead Render backend, replace it with the intended canonical API origin.

Then verify:

* release workflow consumes the correct variable
* Android release builds receive the correct API origin
* no stale Render hostname exists in active production build configuration
* old release binaries are clearly marked stale if necessary

Do not merely change documentation.

Change the actual release input.

---

## P0.3 — Fix uptime monitoring

Configure:

`PRODUCTION_HEALTH_URL`

to the canonical production readiness/health endpoint.

Then improve the workflow so a production monitoring workflow cannot report healthy simply because monitoring was never configured.

Possible design:

* workflow should explicitly report `NOT CONFIGURED`
* production environment release should fail if health monitoring is required but missing
* issue/alert should be generated for missing monitoring configuration
* green should mean an actual successful health probe

Use an endpoint that validates real service/database readiness.

For Cloud Run, `/api/readiness` is acceptable if that is the platform-supported route.

### Exit criteria

A green production uptime job means:

> FINVERSE was actually probed and healthy.

---

## P0.4 — Add deployment identity verification

One major previous failure occurred because `/` returned HTTP 200 while the wrong application was running.

Never repeat that.

Add deterministic deployment identity.

Examples:

`GET /api/version`

or readiness response containing:

* application name
* release SHA
* build timestamp
* environment
* database mode
* schema version

Do not expose secrets.

Then deployment verification must assert the expected SHA.

A generic HTTP 200 is insufficient.

---

## P0.5 — Add automated post-deployment smoke tests

After deployment verify:

* application identity
* API readiness
* DB readiness
* legal endpoint
* categories
* web shell
* Flutter bootstrap
* expected base href
* same-origin configuration
* login endpoint reaches correct service
* WebAuthn status
* asset association endpoints
* authenticated staging-account flow where safely possible

Never log financial data.

---

## P0.6 — Protect `main`

Configure repository branch protection / ruleset.

Require:

* PR before merge
* required CI
* branch up-to-date before merge
* no force pushes
* no deletion
* protected production environment
* required release checks
* required DB checks

Add `CODEOWNERS`.

At minimum consider ownership for:

`.github/`

`apps/api/src/modules/auth/`

`apps/api/src/modules/webauthn/`

`apps/api/migrations/`

`apps/api/src/infra/postgres/`

`infra/`

release scripts

security configuration

If this is a single-owner repository, CODEOWNERS still documents security-sensitive paths even if organizational review cannot yet be enforced.

---

## P0.7 — Merge current security branch into `main`

Do not manually copy selected commits.

Perform a real merge/PR of:

`codex/passkey-webauthn-p0`

into:

`main`

Before merge:

* refresh remotes
* ensure working tree clean
* run full test suite
* run Flutter tests
* run Flutter analyze
* run npm audit
* run migrations
* verify merge conflict state
* review 58-commit diff for accidental files/secrets
* verify `.env`, credentials, keystores, cloud secret files are not tracked

After merge:

* run CI on the resulting `main` SHA
* verify every required job is green
* verify `main` now contains the hardened WebAuthn/RLS/release logic
* only release that exact CI-proven SHA

Do not release a different SHA than the one CI tested.

---

## P0.8 — Native Android passkeys

Implement Android passkey ceremony using the proper Android Credential Manager / public-key credential APIs.

Do not bypass server WebAuthn verification.

Reuse the existing API ceremony.

Implement:

* registration
* authentication
* base64url conversion
* challenge parsing
* RP configuration
* cancellation handling
* no-credential state
* invalid credential state
* lockout UX
* multiple credentials
* settings integration
* passkey login integration
* passkey management integration

Validate:

* `assetlinks.json`
* package name
* release certificate fingerprint
* Digital Asset Links
* actual release signing identity

Test on physical Android hardware.

Do not call Android native passkeys complete based only on unit tests.

---

## P0.9 — Native iOS passkeys

Implement iOS passkeys using:

`AuthenticationServices`

and the appropriate platform public-key credential APIs.

Integrate with the existing Dart `PasskeyCeremony` abstraction.

Support:

* registration
* authentication
* cancellation
* Face ID / Touch ID / device passcode
* missing credential handling
* associated domain
* AASA `webcredentials`
* correct RP ID
* production team signing identity

Test on physical iPhone.

Do not claim success based only on an unsigned macOS CI compile.

---

## P0.10 — Activate WebAuthn on canonical deployment

Current live environment reported:

`available:false`

Configure actual deployment values:

`WEBAUTHN_ENABLED=true`

`WEBAUTHN_RP_ID=<real domain>`

`WEBAUTHN_ORIGIN=<allowed origins>`

`WEBAUTHN_RP_NAME=FINVERSE`

Include native Android origin / asset association requirements as appropriate.

Verify:

* browser registration
* browser authentication
* Android authentication
* iOS authentication
* multiple passkeys
* credential removal
* MFA-enabled user
* failed assertion lockout
* password fallback
* account recovery

---

## P0.11 — Replace placeholder legal configuration

Current Cloud Run legal endpoint exposed temporary example URLs.

Replace:

* Terms version
* Terms URL
* Privacy version
* Privacy URL

with immutable, reviewed documents.

If counsel review has not happened yet:

keep this as a blocker to **real users**.

Technical testers may use a clearly designated non-production environment with explicit test-only language, but do not market it as a real launch.

---

## P0.12 — Production DB privilege validation

Before any real-user environment:

verify using live database queries that the runtime user:

* is not superuser
* has no BYPASSRLS
* owns no public tables
* cannot bypass RLS
* cannot perform migration-owner operations

Add deployment smoke or startup validation where reasonable.

Preserve the existing fail-closed behavior.

---

# P1 — BEFORE CALLING IT PRODUCTION-READY

---

## P1.1 — Reconcile documentation into one source of truth

Current documentation has contradictory deployment information.

Examples include:

* README referring to Render
* historical handovers
* Cloud Run deployment notes
* `Not Complete list .md`
* multiple hosting guides
* stale test counts
* historical branch state

Create one canonical current-state document.

Recommended:

`STATUS.md`

or:

`HANDOVER-CURRENT.md`

It should contain only:

* current branch
* current deployed SHA
* canonical deployment
* current test results
* open P0/P1/P2 items
* owner/external blockers
* exact next action

Move historical investigation into archive sections/documents.

Do not let stale deployment text continue creating operational errors.

---

## P1.2 — Add stronger static/security analysis

Existing npm auditing is good but not sufficient.

Add where appropriate:

* CodeQL
* dependency review
* secret scanning
* Trivy or equivalent container scanning
* SAST
* IaC/config scanning
* Flutter dependency review
* Docker base image vulnerability checks

Do not introduce noisy scanners with no triage process.

Define severity thresholds.

High/critical findings should fail release unless formally reviewed and documented.

---

## P1.3 — Protect the software supply chain

Existing SHA-pinned Actions, SBOM, provenance, and lockfiles are strong.

Continue hardening:

* immutable dependencies where practical
* container digest pinning
* signed release artifacts
* protected signing keys
* environment-scoped production secrets
* no reusable long-lived secrets in workflows
* artifact attestation verification
* reproducible build notes
* dependency update review process

---

## P1.4 — Physical device acceptance matrix

Run real hardware testing.

At minimum:

### Android

* supported low-end device
* modern Android device
* release build
* passkeys
* biometrics
* offline mode
* reconnect
* background sync
* receipt OCR
* push
* Plaid
* account deletion
* export
* MFA

### iPhone

* physical iPhone
* current iOS
* Safari PWA
* Chrome iOS
* native build
* passkeys
* Face ID
* Plaid
* push
* background refresh
* receipt OCR
* app lock
* session restore
* account deletion

Document actual observed results.

---

## P1.5 — Production Plaid

Complete:

* production approval
* production credentials
* representative Canadian institutions
* representative US institutions where supported
* OAuth institutions
* update mode
* login-required recovery
* webhook verification
* revoked Items
* deleted accounts
* pending→posted handling
* institution downtime
* provider rate limits
* bank-sync monitoring

Do not use synthetic Plaid Sandbox performance as evidence of real-world categorization quality.

---

## P1.6 — SMTP / email

Configure a production mail provider.

Validate:

* SPF
* DKIM
* DMARC
* password reset
* email verification
* passkey security notification
* account deletion notifications
* bounce behavior
* retry behavior
* deliverability
* privacy-safe email content

---

## P1.7 — Push notifications

Finish:

* Firebase production credentials
* APNs configuration
* client token registration
* stale token handling
* permission-denial UX
* foreground/background behavior
* privacy-safe lock-screen messages
* retries
* alert deduplication

Physical-device proof required.

---

## P1.8 — Crash/error monitoring

FINVERSE currently cannot honestly claim a crash-free rate without telemetry.

Add a privacy-conscious production error/crash provider.

Requirements:

* no transaction descriptions
* no account numbers
* no tokens
* no bank credentials
* no financial values unless deliberately redacted
* user IDs should be pseudonymous where possible
* consent implications reviewed
* sampling and retention documented

---

## P1.9 — Offline synchronization improvements

Current offline implementation is already stronger than a naive queue.

Verified behavior includes:

* encrypted cache
* account-scoped cache
* mutation serialization
* retry queue
* 408/429 retained for retry
* permanent rejections surfaced
* rejected list cleared appropriately
* background sync hooks

Improve:

* field-level conflict semantics
* conflict center UI
* retry timestamps/history
* failure reason visibility
* dedupe
* broader mutation support
* server-version awareness
* observability
* stale-data indication

Do not silently overwrite conflicting user changes.

---

## P1.10 — Product dashboard evolution

Do not rebuild existing visualizations.

Improve them selectively.

Potential additions:

### Spending calendar heatmap

Show actual daily spending intensity.

### Cash-flow Sankey

Visualize:

income → obligations → categories → savings.

### Category drill-down

Tap:

category → merchants → transactions → comparison → budget impact.

### Forecast uncertainty

Current model intentionally avoids false precision.

Add:

* baseline
* conservative range
* risk band
* low-balance probability only if statistically defensible

Do not invent confidence numbers.

### Custom dashboard cards

Allow users to select the most useful metrics.

---

## P1.11 — Categorization quality

The current correction learner is conservative and user-specific.

Keep that property.

Add real evaluation before claiming ML accuracy.

Measure:

* top-1 accuracy
* coverage
* abstention rate
* correction rate
* merchant coverage
* confidence calibration

Use held-out real transactions only with appropriate consent/privacy.

Synthetic self-generated data is not acceptable evidence.

---

## P1.12 — Full localization/accessibility QA

Repository already contains English/French localization and semantic testing.

Do not claim full accessibility until physical audit.

Perform:

* VoiceOver
* TalkBack
* 200%+ text scaling
* high contrast
* color-blind review
* one-handed usability
* screen-reader order
* actionable semantics
* focus order
* error messaging
* charts with equivalent spoken summaries

---

# P2 — BEFORE SELLING FINVERSE

P2 includes external assurance and commercial launch controls.

Engineering should prepare everything possible, but do not fake external approvals.

---

## P2.1 — Independent penetration test

Commission a real third-party penetration test.

Scope:

* web
* Android
* iOS
* API
* auth
* passkeys
* MFA
* RLS
* IDOR
* session handling
* bank linking
* exports
* file/report handling
* webhook endpoints
* billing
* cloud configuration
* secrets/IAM

Track every finding.

Do not declare complete until high/critical findings are closed.

---

## P2.2 — Privacy / legal review

Obtain professional review of:

* Terms
* Privacy Notice
* data inventory
* data retention
* account deletion
* backups
* consent
* PIPEDA
* GDPR where applicable
* CCPA where applicable
* financial recommendation language
* subscription practices
* support procedures
* incident communications

Engineering documentation is not legal approval.

---

## P2.3 — Disaster recovery

Perform a real disaster-recovery exercise against the actual production architecture.

Test:

* database restore
* lost service deployment
* lost container version
* corrupt migration
* compromised credentials
* provider outage
* key rotation
* rollback
* user deletion vs backup retention

Record:

* RPO
* RTO
* exact procedure
* gaps
* remediation

---

## P2.4 — Observability validation

Production observability must cover:

* API readiness
* error rate
* latency
* DB availability
* DB saturation
* background jobs
* webhook jobs
* login abuse
* passkey failure abuse
* push failures
* email failures
* Plaid errors
* backup failures
* queue growth
* deployment health

Alerts must reach a real human responder.

A workflow that merely opens an issue with nobody monitoring notifications is not an operational response system.

---

## P2.5 — Load / failure testing

Go beyond the existing CI smoke test.

Run:

* sustained staging soak
* burst authentication traffic
* dashboard read load
* transaction history load
* concurrent sync
* provider latency
* DB failure
* partial network failure
* 429 behavior
* slow email
* slow Plaid
* webhook bursts
* Cloud Run cold starts
* Neon scale-to-zero recovery

Measure actual capacity.

Do not guess maximum users.

---

## P2.6 — App store review readiness

Complete:

### Apple

* developer account
* signing
* TestFlight
* privacy manifest
* App Privacy answers
* screenshots
* support URL
* legal URLs
* passkeys
* associated domains
* StoreKit
* review notes

### Google

* developer verification
* Play Console
* signing
* Data Safety form
* financial features declarations
* Play Billing
* screenshots
* store listing
* privacy policy

---

## P2.7 — Provider approvals

Complete:

* Plaid production
* Stripe live
* Firebase/APNs
* Apple
* Google
* email provider
* monitoring providers

Record owner/provider dependencies explicitly.

---

## P2.8 — Incident response exercise

Current repository has an incident runbook.

Now test it.

Run a tabletop scenario such as:

* DB credentials compromised
* Plaid token encryption key suspected leaked
* login service outage
* cross-user access suspected
* deleted-user backup restoration issue

Document:

* detection
* containment
* evidence
* recovery
* user communication
* provider notification
* postmortem

---

## P2.9 — Production secret/KMS lifecycle

Replace ad-hoc environment-secret management with a formal lifecycle.

Include:

* JWT signing secret
* MFA key
* Plaid token encryption key
* DB credentials
* Stripe webhook secret
* Firebase service account
* SMTP credentials
* signing keys

Define:

* storage
* access
* rotation
* revocation
* recovery
* backup
* audit
* emergency replacement

Do not rotate encrypted-data keys without a safe migration strategy.

---

# ADDITIONAL SECURITY CHECKS

Continuously adversarially inspect for:

* IDOR
* broken authorization
* missing `user_id` scope
* mass assignment
* insecure direct SQL
* secrets in logs
* secrets in Git
* unsafe exports
* spreadsheet injection
* SSRF
* open redirects
* weak CORS
* unbounded inputs
* missing rate limits
* webhook replay
* refresh-token replay
* MFA bypass
* passkey bypass
* account enumeration
* session fixation
* unsafe password-reset tokens
* unsafe file handling
* stale-account data
* cross-user offline cache
* race conditions
* integer/currency mistakes
* timezone mistakes
* mixed-currency addition
* sync idempotency defects
* duplicate transactions
* pending/posting mismatch
* deletion failures
* backup-retention conflicts
* release artifact mismatch
* stale deployment URLs
* dependency compromises

---

# FINANCIAL CORRECTNESS RULES

Financial software must not lie.

Preserve:

* integer minor-unit arithmetic
* explicit currency
* no silent FX conversion
* no adding unlike currencies
* deterministic date handling
* transaction idempotency
* pending→posted reconciliation
* explicit uncertainty
* conservative forecasts
* evidence-backed insights

Never improve UX by making financial values more confident than the underlying evidence.

---

# SECURITY / PRIVACY RULES

Never:

* commit credentials
* print secrets
* expose bank tokens
* expose refresh tokens
* expose MFA secrets
* expose password hashes
* expose raw credentials
* expose sensitive financial payloads in monitoring
* bypass RLS
* use DB owner for serving user requests
* silently downgrade production security
* enable real registration with placeholder legal documents
* claim penetration testing when only automated scanning was run
* claim production-ready when provider approvals are missing

---

# DOCUMENTATION RULE

Documentation must describe reality.

When code/deployment changes:

update the canonical documentation immediately.

Remove contradictory status claims.

Label historical notes as historical.

Never allow a stale document to override verified repository/deployment evidence.

---

# COMMIT DISCIPLINE

Create professional, reviewable commits.

Each commit should:

* represent one coherent change
* have a clear conventional message
* include tests where appropriate
* avoid unrelated formatting churn
* never include secrets
* leave the repository buildable where practical

Examples:

`fix(release): point artifacts at canonical Cloud Run API`

`ci(ops): fail closed when production health URL is missing`

`feat(android): implement Credential Manager passkey ceremony`

`feat(ios): implement AuthenticationServices passkeys`

`security(github): add protected release ownership rules`

`docs(status): reconcile canonical production deployment`

Do not manufacture meaningless commits merely to inflate commit count.

---

# VERIFICATION AFTER EVERY IMPORTANT CHANGE

Use the relevant subset of:

```text
git status
git diff --check
npm audit --omit=dev --audit-level=high
npm test
npm run test:db
npm run typecheck --workspace @finverse/api
npm run build --workspace @finverse/api
flutter analyze
flutter test
flutter build web --release --no-web-resources-cdn --base-href=/app/
flutter build apk --release --dart-define=API_BASE_URL=<canonical HTTPS API>
```

Also test deployed endpoints when deployment configuration changes.

Do not blindly execute production-changing commands without understanding their effect.

---

# CANONICAL PRIORITY ORDER

Execute in this order unless new evidence reveals a more severe security defect:

1. Verify repository/Git/current deployments again.
2. Fix canonical deployment mismatch.
3. Correct GitHub `API_BASE_URL`.
4. Activate real production health monitoring.
5. Add deployment identity/version verification.
6. Protect `main`.
7. Review and merge the 58-commit security branch.
8. Require green CI on resulting `main`.
9. Replace placeholder legal configuration.
10. Implement Android native passkeys.
11. Implement iOS native passkeys.
12. Configure real WebAuthn RP/domain.
13. Run physical-device passkey tests.
14. Complete P1 production provider work.
15. Improve offline conflict handling.
16. Add security/static/container scanning.
17. Complete physical-device acceptance.
18. Add crash/error monitoring.
19. Improve dashboards only where existing UX has real gaps.
20. Begin P2 independent assurance/commercial work.

---

# DEFINITION OF P0 COMPLETE

Do not call P0 complete until:

* `main` contains the security branch
* main CI is green
* main is protected
* release artifacts target the canonical backend
* canonical production/beta deployment is clearly identified
* deployment identity is verifiable
* public API is healthy
* database is healthy
* uptime monitoring is genuinely active
* production runtime DB role is restricted
* temporary legal URLs are removed before real users
* web passkeys work on real deployed domain
* Android passkeys work on physical hardware
* iOS passkeys work on physical hardware
* passkey enrollment/login/removal/MFA step-up are physically tested
* real release artifacts communicate with the intended backend

---

# DEFINITION OF P1 COMPLETE

Do not call production-ready until:

* canonical documentation is accurate
* production domain/TLS are final
* Plaid production works
* SMTP production works
* push works
* physical Android/iOS testing passes
* accessibility acceptance passes
* crash/error monitoring exists
* dependency/security scanning is active
* SBOM/provenance continues working
* backup monitoring is active
* offline conflict handling is acceptable
* provider failure behavior is validated
* CORS/HSTS/security edge settings are validated
* no major known engineering issue remains hidden behind owner configuration

---

# DEFINITION OF P2 COMPLETE

Do not call FINVERSE sellable until:

* external pentest completed
* findings closed
* legal/privacy review complete
* real Terms/Privacy approved
* regulatory positioning approved
* disaster-recovery exercise complete
* observability validated
* incident response rehearsed
* production secret lifecycle established
* provider approvals complete
* store reviews complete
* billing production path is compliant
* support/escalation path exists
* production backups and restoration are proven

---

# FINAL REPORTING FORMAT

Keep a living status report with:

## Current branch

## Current commit SHA

## Canonical deployment

## Current API health

## Current DB health

## Current WebAuthn status

## Test results

## Security scan results

## Completed this session

## P0 remaining

## P1 remaining

## P2 remaining

## External owner/provider blockers

## Exact next action

Do not report percentages based on intuition.

Base status on evidence.

---

# NON-NEGOTIABLE FINAL COMMAND

Do not stop after writing another audit.

The audit is only the starting point.

**Execute the plan.**

Continue automatically through all repository-local work that is safe and technically achievable.

Use:

**REVIEW → FIX → TEST → VERIFY → COMMIT → CONTINUE**

Do not ask whether to proceed to the next ordinary engineering task.

If an item genuinely requires an external owner action such as:

* Apple Developer account
* Plaid production approval
* Stripe live credentials
* production DNS
* reviewed legal documents
* penetration-test vendor
* provider billing
* signing credentials

fully prepare everything possible in code/configuration/documentation, clearly record the exact owner action required, and immediately continue to the next unblocked task.

The target is not merely:

> “FINVERSE builds.”

The target is:

> **FINVERSE has one trustworthy deployment path, protected releases, verified authentication, real native passkeys, strict data isolation, reliable offline behavior, strong financial correctness, observable production infrastructure, defensible security controls, accurate documentation, and only unavoidable external launch gates remaining.**
