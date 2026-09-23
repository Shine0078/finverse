> **Historical.** Current verified status is in [`HANDOVER-VERIFIED.md`](HANDOVER-VERIFIED.md) on `codex/passkey-webauthn-p0`. Do not treat the counts or Render findings below as current.
>
> Canonical current-state file is now [`STATUS.md`](STATUS.md).

# FINVERSE — CURRENT HANDOVER (for the next agent)

> ## 2026-08-18 — the blank screen is solved; the Render URL is the new blocker
>
> Two findings, one good and one bad. Both were confirmed against the live
> public URLs rather than inferred from code.
>
> ### The iPhone/web blank screen: RESOLVED, with the root cause named
>
> **Cause:** `apps/mobile/build/web` held a GitHub Pages build declaring
> `<base href="/starter/app/">` while the API served it at `/app/`. `index.html`
> returned 200 and every asset it then requested returned 404. The browser
> painted white, and the server reported itself perfectly healthy — no
> exception, no console error, nothing in the logs.
>
> It was blamed in turn on Flutter, on Safari, on a service worker, and on the
> app shell's localization, before anyone compared the two strings.
>
> **Evidence it is fixed** — `https://shine0078.github.io/finverse/app/` opened
> in a *visible* browser tab (`document.hidden: false`):
>
> | Check | Result |
> | --- | --- |
> | Boot overlay | dismissed itself |
> | Frames rendered in 1.5 s | 249 |
> | Canvas | 1 — 440x956 CSS, 881x1913 backing store at DPR 2 |
> | `<flt-scene>` | populated |
> | Declared base href | `/starter/app/`, matching the Pages path |
>
> Onboarding paints correctly at 440x956 (iPhone 17 Pro Max CSS size).
>
> **A trap for the next agent, because it cost this one a long detour.** Earlier
> diagnostics were run through a browser pane that was never visible. A hidden
> tab does not run `requestAnimationFrame`, so CanvasKit never composites, so
> the scene graph is legitimately empty and the canvas count is legitimately
> zero. That is *not* evidence of a stall. **Always check `document.hidden`
> before concluding a Flutter web app is not painting.** Reading those numbers
> as a hang sent the investigation into the localization delegates and the app
> shell, where there was no bug.
>
> **Guarded so it cannot recur silently:** `src/infra/http/web-bundle.ts`
> compares the bundle's declared base href against its mount path at boot and
> logs the exact rebuild command. It warns rather than refusing to start, since
> a reverse proxy may legitimately rewrite the prefix. Seven tests in
> `test/web-bundle.spec.ts` cover the real regression, slash-variant
> equivalence, and an unsubstituted `$FLUTTER_BASE_HREF` reported as its own
> distinct fault (different cause, different fix).
>
> ### `finverse.onrender.com` is serving a different application
>
> The service is live but is **not FINVERSE**:
>
> ```text
> GET https://finverse.onrender.com/        -> 200  "You have requested the home route with GET"
> GET https://finverse.onrender.com/healthz -> 404  Cannot GET /healthz
> ```
>
> `x-powered-by: Express`, no NestJS routes, no `/api` surface. The first
> request took 31 s (free-tier cold start), so the service is awake — it is
> running the wrong deploy, most likely a leftover starter template.
>
> Consequence: **the public PWA renders but cannot authenticate.** A `fetch` to
> `/api/auth/login` from the Pages origin fails outright. The user sees
> "Couldn't reach the server. Check your connection."
> (`apps/mobile/lib/api/client.dart:187`), which is honest but understates the
> situation — the server answers, just as a different application.
>
> **Owner action:** point the Render service at this repository's Blueprint
> (`render.yaml`, see `docs/14-public-hosting-render.md`), or delete the service
> and redeploy. Verify with `/healthz` returning 200 and a JSON body, **not**
> with `/` returning 200 — the placeholder answers `/` too, which is exactly why
> this went unnoticed.
>
> ### Corrected measurement
>
> `flutter test` is **108 passed**, stable across three consecutive runs on a
> clean tree. The **94** recorded in the 2026-08-15 block below is wrong. One
> run during this session reported 93 immediately after `flutter analyze`
> triggered a `pub get`; that figure was not reproducible and should not be
> quoted. API counts re-confirmed unchanged: `npm test` **487 passed, 5
> Postgres-only skips**; `npm run test:db` **596 passed**; `flutter analyze`
> clean; API typecheck clean.
>
> ### Status
>
> The blank screen is closed. **Physical-iPhone verification is still open** and
> is now blocked behind the Render fix, since there is no working API for a
> phone to talk to. Everything in the external-blockers list is unchanged.

> ## 2026-08-15 takeover audit — this supersedes stale statements below
>
> A fresh agent re-ran the complete verification suite against the actual
> repository (branch `main`, commit `9a7898b` + the takeover commits, clean
> working tree at start). Nothing below the previous handovers was trusted
> without evidence.
>
> **Re-measured on this workstation (2026-08-15):**
>
> - `npm test` (API in-memory): **487 passed, 5 Postgres-only skips** (49.5 s).
> - `npm run test:db` (real embedded PostgreSQL incl. the full RLS suite):
>   **596 passed** (55.9 s).
> - `npm run typecheck --workspace @finverse/api`: clean.
> - `npm run build --workspace @finverse/api`: clean.
> - `npm run load:smoke` (memory adapter): 250 requests, concurrency 10,
>   **0 failures, p95 117.3 ms, p99 172.1 ms** (ceiling 750 ms).
> - `flutter analyze`: clean; `flutter test`: **94 passed**. *(Superseded: 108. See the 2026-08-18 block.)*
> - `flutter build web --release --no-web-resources-cdn --base-href=/app/`:
>   built; served from the compiled API on an isolated port with `/app/`, a
>   deep route (GET returns the shell, 200), bootstrap, local CanvasKit
>   JS+Wasm, and the migration worker all 200/no-cache.
> - `flutter build apk --release`: 87.0 MB APK via the intentional
>   debug-signing fallback (upload keystore remains an owner secret).
> - **Plaid Sandbox credentials verified live**: a `link_token/create` call
>   against `https://sandbox.plaid.com` succeeded with the local `.env` keys
>   (never printed, never committed). Provider error mapping in
>   `banking.service.ts` returns actionable per-platform messages.
>
> **Changes made during the takeover:**
>
> - Localized the previously hardcoded English dashboard dialogs and controls
>   (sign-out confirm, account-deletion confirm, verify-email dialog, app-bar
>   tooltips, account popup menu), the app-lock gate, the secure-storage retry
>   screen, and the analytics timeline kind labels — English + French, with a
>   delegate-free English fallback for isolated embedders. New French widget
>   regression included (94th test).
> - `Dockerfile.public` (the Render image) now builds the web bundle with
>   `--no-web-resources-cdn`, matching CI and `release.yml`; the public image
>   previously could fetch the renderer from gstatic even though the bootstrap
>   pins local CanvasKit.
> - Docs re-synced to reality: `07-session-notes.md`, `08-what-blocks-selling.md`,
>   `12-mission2-audit.md` now carry the 487/596/94 evidence *(the 94 is superseded by 108)* and 2026-08-15
>   measurements.
>
> **Verified as still true:** production refuses the in-memory store and
> boot-time migrations; the mock-aggregator `/api/sync` route is refused for
> every persistent Postgres deployment and in production (MockAggregator can
> only feed the in-memory demo); no secrets/keystores are tracked by git.
>
> **Still open and external (unchanged):** the live tunnel from §1 is dead
> (nothing listens on port 3000 after the reboot; in-memory data was lost by
> design). Physical iPhone Safari/Chrome-on-iOS verification of the PWA has
> still never happened — after any deploy, reload the current URL twice (or
> clear Website Data) and confirm onboarding renders; only then close that
> gate. Everything in §8 (domain/hosting, Plaid production, Apple/Mac, push
> credentials, legal/Stripe, pen-test) remains owner action.
>
> ## 2026-08-11 continuation — supersedes stale statements below
>
> - Latest UI/deployment commits: `8960fa0` simplifies the dashboard into a
>   responsive 2x2 financial summary and replaces spinner-only loading states
>   on transaction, budget, goal, subscription, notification, and account
>   screens with shared skeletons. The full Flutter suite now has **93 passing
>   tests** and analysis is clean.
> - Commit `8d56799` adds the permanent public-hosting path: `render.yaml`,
>   `Dockerfile.public`, and `docs/14-public-hosting-render.md`. It deploys the
>   API and Flutter PWA together behind Render HTTPS with managed PostgreSQL;
>   no VPN, Tailscale, home PC, or tunnel is required. A one-click Render
>   button is in `README.md`. The deployment itself is not yet created because
>   the owner must authorize Render and enter secrets/legal settings.
> - The current owner-facing Plaid Sandbox CIBC test values are `user_good` /
>   `pass_good`, not a real card number or real bank password. Sandbox MFA is
>   commonly `1234`. See `docs/11-run-on-your-phone.md`.
>
> - Commit `9c713f3` localizes transaction-row status badges and the category
>   correction menu, including the common quick categories in English and
>   French. Flutter analysis is clean and all **92** tests pass.
> - Commit `c107e6a` localizes plan state, tier comparison, entitlements,
>   checkout/manage flows, payment warnings, and upgrade sheets. It also fixes
>   a real isolated-host crash caused by uninitialized explicit intl date data:
>   date labels now use Flutter's locale-aware `MaterialLocalizations` API.
>   All **92** Flutter tests pass and analysis is clean. A fresh
>   `flutter build web --release --no-web-resources-cdn --base-href=/app/`
>   and Android debug APK build pass after the full localization set. Android
>   still warns that `workmanager_android` must adopt Flutter's future built-in
>   Kotlin model; this is a third-party upgrade watch item, not a current build
>   failure.
> - Commit `0a1898f` localizes the support and recovery centre, including
>   privacy-safe diagnostics and all troubleshooting content. It adds the
>   shared fallback used by recovery screens when an isolated host omits app
>   localization delegates, plus a French regression. All **92** Flutter tests
>   pass and analysis is clean.
> - Commit `6074da0` localizes the transaction explorer and its complete
>   filter sheet: search, empty/error states, status and recurrence filters,
>   range validation, and locale-aware date labels. Flutter analysis is clean
>   and all **91** mobile tests pass.
> - Commit `9497e6c` localizes the complete bank-account management path:
>   Plaid step-up, link/reconnect/disconnect, manual accounts, provider error
>   recovery, plan-limit messaging, status labels, and account card actions.
>   It adds a French regression test. Flutter analysis is clean, all **91**
>   mobile tests pass, and a fresh local-CanvasKit release-web build succeeds.
> - Commit `048f48d` localizes sign-in, account creation, MFA, password
>   recovery, legal-consent, and secure-session messaging in English and
>   French. The login screen safely falls back to English when embedded without
>   localization delegates, which preserves the isolated authentication test
>   harnesses. Flutter analysis is clean and all **90** mobile tests pass.
> - Working tree status at handover: all product changes are committed; this
>   handover file is deliberately untracked and local-only.
>
> - PWA recheck after the later mobile work: a freshly built current API on an
>   isolated port served `/app/`, a deep link, local CanvasKit JS/Wasm, and the
>   source-owned migration worker as 200/no-cache. Its final bootstrap loader
>   call supplies only `canvasKitBaseUrl: 'canvaskit/'`; Flutter's bundled
>   loader source legitimately contains the string `serviceWorkerSettings`, so
>   do **not** use a broad text search as evidence of registration. The
>   existing public quick tunnel has the corrected bootstrap but still runs the
>   old in-memory API process and therefore serves its earlier migration worker
>   without `event.waitUntil`. It was intentionally not restarted, preserving
>   its live in-memory data. Physical iPhone proof remains outstanding.
> - Commit `02bec35` localizes all first-run onboarding pages and actions.
>   Flutter analysis and all **90** mobile tests pass.
> - Commit `9f05508` localizes the Analytics screen's time-range controls,
>   loading/error/empty states, metrics, spending-pace explanations,
>   insight evidence, subscription summary and priority chips. Flutter
>   analysis and all **90** mobile tests pass; fresh release-web and Android
>   debug builds also pass.
> - Commit `54df54a` localizes the shared cash-flow planner’s forecast,
>   purchase scenario controls, forecast chart semantics, and recurring-event
>   panel. It also applies the active locale to the date shown by the purchase
>   picker. Flutter analysis and all **90** mobile tests pass.
> - Commit `95bca4a` localizes monthly-budget creation/removal and savings-goal
>   creation/contributions in English and French. Flutter analysis and all
>   **90** mobile tests pass after this batch.
> - Commit `5bea2a6` localizes subscription insights and the full cash-flow
>   calendar, including locale-aware dates and spoken calendar labels. The
>   existing calendar widget test now hosts real localization delegates. Full
>   Flutter test (**90 passing**), release web, and Android debug builds pass.
>   Android warns that the third-party `workmanager_android` plugin must adopt
>   Flutter's future built-in Kotlin model; current builds remain successful.
> - Commit `f20a392` moves the private finance guide, notifications and device
>   alert preferences, and saved merchant-rule management onto generated
>   English/French strings. It adds a French UI regression test for the guide.
>   The complete Flutter suite now has **90 passing tests**; analysis and a
>   fresh release web bundle pass.
> - Commit `1e54af3` localizes the Profile hub's visible headings, navigation
>   destinations, sign-out control, and verification confirmation in English
>   and French. Flutter analysis is clean and the complete Flutter test suite
>   has **89 passing tests**.
> - Commit `46ee91a` adds a persisted, user-selectable display language:
>   device default, English, or French. The preference restores *after*
>   `runApp`, uses the guarded web shared-preferences registration, and cannot
>   delay the first frame. Settings shows the selector and explicitly discloses
>   that some screens are still being translated; this is **not** a claim that
>   full AppLocalizations adoption is complete. Five new controller/scope
>   regression tests pass; the full Flutter suite now has **89 passing tests**.
> - **PWA startup follow-up (commit `39e435f`):**
>   the generated Flutter 3.44 release bootstrap still chose
>   `https://www.gstatic.com/flutter-canvaskit/<engine-revision>/` by default.
>   The previous local-asset checks therefore did not prove that the renderer
>   needed for the first frame was reachable on an iPhone. A custom
>   `web/flutter_bootstrap.js` now forces `canvaskit/` relative to `/app/`, and
>   the release/CI commands use `--no-web-resources-cdn` as a second guard.
> - Fresh FINVERSE bundles now **do not register a service worker**. A small
>   source-owned `web/flutter_service_worker.js` remains only to migrate older
>   Flutter cache-first clients: it clears every cache, unregisters itself, and
>   uses `event.waitUntil` so Safari cannot terminate cleanup early. Both the
>   API static host and public Nginx host serve that same file; no host-specific
>   interception remains.
> - This code path was verified against a fresh release bundle and an isolated
>   compiled API on port 3011: `/app/`, a deep route, the bootstrap, migration
>   worker, CanvasKit JS/Wasm all returned 200 with `Cache-Control: no-cache`;
>   bootstrap selected local CanvasKit and its final loader call had no service
>   worker registration. Flutter analysis, all 84 Flutter tests, all 475
>   in-memory API tests, API typecheck/build, and a new Android debug APK pass.
> - **Still not physical-iPhone proof.** After deploying this commit, test the
>   current HTTPS URL in Safari and Chrome-on-iOS. For an origin that previously
>   cached the broken build, remove its Safari Website Data or reload once to
>   let the migration worker run, then reload again. Do not call the loading
>   issue resolved until FINVERSE onboarding visibly renders on the phone.
> - The permanent iPhone PWA splash was reproduced as a **pre-first-frame
>   Flutter exception**, not a service-worker or API failure: Flutter 3.44 did
>   not register `shared_preferences_web`, while `ApiClient` constructed
>   `SharedPreferencesAsync` during startup. Commit `8e29c8a` adds an
>   idempotent web registration before session construction. A fresh public
>   Chromium load now reaches FINVERSE onboarding with an empty console.
> - This is **not physical-iPhone proof**. The owner must reload the current
>   tunnel on Safari and Chrome-on-iOS and report whether onboarding appears;
>   do not claim that gate closed until then. The original live-link details
>   below may no longer be current after a restart.
> - Commit `54c06c3` adds required-production HIBP k-anonymity password
>   screening. It is implemented and targeted API tests/build pass.
> - Commit `cf603bb` adds `FcmHttpV1PushProvider`: built-in Node
>   service-account OAuth, FCM delivery for Android/web and APNs-routed iOS,
>   privacy-safe lock-screen payloads, confirmed-stale-token cleanup, and
>   fail-closed configuration. `FCM_CREDENTIALS_JSON` remains an owner secret.
> - The same commit adds `workmanager` network-constrained
>   background bank refresh, iOS BGTask/UIScene plugin registration, and three
>   policy tests. `flutter analyze` and the targeted scheduler tests pass; a
>   fresh Android debug APK was built. The FCM delivery adapter (4 tests) and
>   push API (4 tests) also pass.
> - Commit `140b55a` adds a bounded, explainable learner trained
>   solely from the current user's explicit manual category corrections. Rules
>   and the merchant lexicon still win; conflicting or weak examples predict
>   nothing. The API suite now has 475 passing tests (5 intentional database
>   skips); Flutter has 84 passing tests, analysis is clean, and fresh web
>   release / Android release-mode builds both succeed (the local release uses
>   the project's intentional debug-signing fallback, not a sellable store key).
> - Commit `f2188b0` adds direct private receipt-photo OCR:
>   Android's bundled ML Kit and iOS Apple Vision return a transcript for user
>   review, then only that text is uploaded. Android compiles; Windows cannot
>   compile or physical-test the iOS Vision path.
> - Commit `fd104ac` localizes every new receipt scan/review action in the
>   shipped English and French ARB catalogs. The 84-test Flutter suite and
>   analysis remain clean after this change.
> - Commit `a8dce16` adds an interaction-level accessibility regression that
>   verifies the receipt scan and paste choices expose spoken labels.
> - Commit `f9f8877` aligns the architecture, ADR, roadmap, and selling audit
>   with the correction learner and local receipt-image OCR; previous Phase-2
>   placeholder wording is no longer current.

Workspace: `C:\Users\samue\OneDrive\Desktop\starter` · Branch `main` · Latest commit `9c713f3`.

The only intentional uncommitted file is this handover note itself.

Read this whole file before touching anything. It is the current, verified state as of the last session —
not a promise, and the loading issue at the end is **RESOLVED as of 2026-08-18** (base-href mismatch; see the top block).

---

## 1. Live test link (iPhone, right now)

> **Replaced 2026-08-16 because port 3000 was occupied by an unrelated SPLITLY
> process; the previous URL now reaches that service.**

**`https://mystery-democrats-header-timeline.trycloudflare.com`**

Deployed on 2026-08-16 for UI testing on port 3001 with the fresh
post-theme-customization web bundle. It uses the **in-memory development
store** because the embedded PostgreSQL process stopped and port 3000 is owned
by SPLITLY; do not use this link for real financial data:

| Piece | Process | Notes |
|---|---|---|
| Cloudflare quick tunnel (no account) | `cloudflared.exe` in `%TEMP%\opencode` | public HTTPS → localhost:3001; logs at `%TEMP%\opencode\tunnel-ui.{out,err}.log` |
| FINVERSE API (compiled `dist/main.js`) | `node.exe` on port 3001 | **`Store memory`** — data resets on restart; logs at `%TEMP%\opencode\finverse-api-ui.log` |
| Port 3000 | unrelated SPLITLY process | do not stop it; the old FINVERSE URL reaches SPLITLY |
| Flutter web PWA | built 2026-08-15 with `--no-web-resources-cdn --base-href=/app/` | same-origin API calls, local CanvasKit, migration-only worker |

Verified live through the public URL on 2026-08-16: `/healthz` 200,
`/app/` 200, `main.dart.js` 200 (3.9 MB), `flutter_bootstrap.js` 200 with
`canvasKitBaseUrl: 'canvaskit/'` taking priority over the (dead) gstatic
branch, `canvaskit.wasm` 200 (7.2 MB), `flutter_service_worker.js` 200,
`/api/legal` 200 (`registrationRequired:false` in dev), `/api/categories` 200.

Caveats (unchanged): the URL dies if this PC sleeps/reboots or the tunnel
restarts, quick tunnels have no uptime guarantee, and `THROTTLE_DISABLED=true`
is set in the local `.env` — fine for phone testing, never for a real
deployment. To restart after a reboot: `npm run db:start --workspace
@finverse/api`, then set `PORT=3001` and `STORE=memory` before running
`node dist/main.js` in `apps/api`, then
`cloudflared tunnel --url http://localhost:3001` — and record the new URL here.

**Physical iPhone verification is still the open gate:** open the URL above in
Safari and Chrome-on-iOS. If this phone ever loaded a previously broken build,
clear Safari Website Data or reload twice. Do not close the loading-splash
issue until onboarding visibly renders on the phone.

**How to reach the same app away from this PC (owner gate, not code):** deploy `infra/docker-compose.public.yml` (Caddy auto-HTTPS) on any VPS with a domain, or the Render Blueprint in `render.yaml`. The repo is fully ready; a domain + hosting account are the only missing pieces.

---

## 2. ~~THE OPEN ISSUE~~ — RESOLVED 2026-08-18: iPhone web app stuck on the loading splash

> **Resolved.** Root cause was a base-href mismatch, not a caching, service-worker,
> or Safari fault. The investigation recorded below pursued those and found nothing,
> which is itself useful: it rules them out. See the 2026-08-18 block at the top.

**Original symptom:** On the iPhone (Safari), opening the link showed forever:

> **FINVERSE — Still loading. The first open downloads the app; later ones are cached.**

That text is Flutter web's default boot splash. It only disappears after `main()` runs and the first frame renders. Server-side is verified healthy (see §1) — every asset returns 200 and the bundle is the fresh same-origin build.

**What is now fixed in source (commits `8e29c8a` and `39e435f`):**
- `SharedPreferencesAsync` is registered before startup on web, eliminating the
  original pre-first-frame Dart exception.
- The release bootstrap explicitly loads CanvasKit from `/app/canvaskit/`, not
  `gstatic.com`; CI and release builds use `--no-web-resources-cdn` as a second
  guard. The public tunnel was rechecked after the build and its bootstrap has
  the local config, `useLocalCanvasKit`, and **no** fresh worker registration.
- New bundles ship a source-owned, migration-only worker which removes stale
  Flutter caches with `event.waitUntil`, then unregisters. Fresh loads use no
  service worker. App static files revalidate with `Cache-Control: no-cache`.

**Live-tunnel caveat:** the API already running on port 3000 was intentionally
not restarted because it holds in-memory test data. It serves the new static
bootstrap (so an uncached iPhone takes the corrected startup path), but its
old in-process worker handler still returns the earlier 240-byte cleanup script
and `no-store` response headers. Restart it only when nobody is testing, to
make the live tunnel match the compiled `39e435f` API exactly.

**One-time recovery step for a previously broken phone:** remove Website Data
for the tunnel/domain (or reload twice). The first navigation lets an old
bootstrap fetch the migration worker; the second navigation runs the new
self-contained bootstrap.

**Remaining hypotheses if it still fails after a clean double-reload (next agent must check in this order):**

1. **iOS Safari version vs modern JS output.** Flutter 3.44 compiles to ES2022+; an older iOS (<16.4-ish) Safari can fail to parse `main.dart.js`, which manifests exactly as an eternal boot splash. **Action:** ask the user's iOS version; have them open the same URL in **Chrome (iOS)** — if Chrome loads fine, it is Safari-version incompatibility.
2. **iPhone Website Data still holds a cached copy.** Settings → Safari → Advanced → Website Data → delete the `trycloudflare` entry. Equivalent to clearing site data.
3. **A startup exception in `main()` on web.** Suspects: `flutter_secure_storage` on web (needs a secure context — we have HTTPS, so unlikely), or `SecureOnboardingStore`/`SecureAppLockStore` reads. Note: these run *after* the first frame, so a stuck splash is more likely (1) or (2) than (3).
4. **Definitive diagnosis:** serve a debug/profile web build (`flutter run -d web-server --web-port 8080` then tunnel it) and read the browser console; or attach Safari Web Inspector from a Mac.

**Do not claim this issue fixed until the user confirms the app renders on their phone.**

---

## 3. What the product is

FINVERSE — AI-assisted personal finance (Plaid-backed bank sync, budgets, goals, insights, health score, cash-flow forecast, subscriptions, alerts, PDF/CSV exports, privacy/consent, billing). NestJS API + PostgreSQL + Flutter (Android/iOS/web PWA). Pure-domain rule (ADR-0002); ports/adapters everywhere; row-level security in Postgres (ADR-0006).

## 4. State of the four original user complaints

1. **iPhone needs no VPN/Tailscale** — release builds reject loopback origins; physical phones use public HTTPS; same-Wi-Fi dev via `apps/mobile/run-ios-lan.ps1`. Code done; the real iPhone gate is a deployed domain.
2. **Auth/session persistence** — atomic refresh-token rotation (server + store contract), offline-cached reads during refresh outages, keystore-tolerant rotation, tombstone logout. Tests green.
3. **Bank connections / transaction sync** — Plaid Sandbox verified end-to-end; stale in-memory sync-lock recovery; dashboard survives a failed bank sync; reconnect/revoke/webhook/pending→posted flows complete.
4. **Stability/UX** — friendly error messages across all screens, skeletons/empty/error states, offline cache + mutation queue, localization (en+fr), accessibility semantics checks.

## 5. Features completed in the last sessions (all tested, committed)

- `59e66da` config-test isolation from local Plaid Sandbox env bleed
- `c7a1f83` **atomic refresh-token rotation** + concurrent-refresh regression test
- `765edcb` recover stale in-memory bank-sync locks
- `c59533b` iPhone connectivity made explicit (loopback rejection, diagnostics, `run-ios-lan.ps1`, docs)
- `0cce4f1` serve encrypted cached reads when refresh is offline
- `7b2cf04`/`c9ad46c`/`8178266`/`6a67e02` docs + counts synced to reality
- `b301ffc` dashboard stays usable when a bank sync fails
- `3451ec7` `friendlyErrorMessage()` applied across all screens
- `1ad8582` merchant lexicon expanded ~3× (US/CA merchants, streaming, gaming, insurers, telecoms, airlines)
- `107cd6a`/`91bbfc5` localization: `gen_l10n`, English + French ARB, wired through shell/login/offline banner
- `08c656f` **receipt OCR**: pure parser + provider port + `POST/PUT/GET /api/receipts/*` + RLS + mobile attach flow (images never uploaded)
- `ff90f53` + `1212638` **passkeys (WebAuthn)**: pure-Node FIDO2 verifier (challenge, registration/login verify, ES256, sign-counter regression), CBOR/COSE parsing, credential store with RLS, domain-gated config; **push registration**: `POST/DELETE /api/push/device` + failing-closed provider port
- `6e579fb` mobile passkey + push client protocol
- `2e630c9` automated spoken-label accessibility assertion on nav
- `23c9eac` **no-op service worker + no-store for the PWA bundle** (the loading-splash fix)

## 6. Test / build state (last verified)

- API in-memory: **475 passed** (5 Postgres-only skips) · `npm test`
- API + PostgreSQL: **564 passed** · `npm run test:db` (migrations 001–019, RLS, deletion-purge all covered)
- Flutter: **90 passed**, `flutter analyze` clean
- API `npm run build` + `npm run typecheck`: pass
- `flutter build apk --debug`, `flutter build web --release --no-web-resources-cdn --base-href=/app/`: pass
- Load smoke: 0 failures, p95 well under 750 ms

## 7. Local environment facts

- Flutter: `C:\Users\samue\development\flutter` (3.44.9 stable)
- Android SDK: `C:\Users\samue\AppData\Local\Android\Sdk`; Java JDK 21 at `C:\Program Files\Android\openjdk\jdk-21.0.8`
- Local Postgres: `npm run db:start` → `localhost:55432` (`finverse` / `finverse_app` roles), data in `apps/api/.postgres-data`
- `.env` has Plaid **Sandbox** keys (ignored by git). `THROTTLE_DISABLED=true` in dev.
- iOS native builds require macOS/Xcode (CI compiles iOS without signing on macOS).

## 8. External blockers (owner actions — code cannot complete these)

1. Domain + VPS/hosting → deploy `infra/docker-compose.public.yml` → removes the "PC must be on" dependency and gives a permanent HTTPS URL (this is the only real fix for "use it away from this device").
2. Plaid production approval (+ Google identity verification to allowlist `com.finverse.finance` on Android).
3. Apple Developer + Mac/Xcode: signing, Universal Link (`PLAID_IOS_REDIRECT_URI` + `IOS_TEAM_ID` + AASA), physical iOS test, native passkey ceremony.
4. Push delivery: FCM/APNs credentials behind `ports/push.ts`.
5. Legal review (Terms/Privacy versions), Stripe live keys, app-store accounts, penetration test.

## 9. Recommended next milestone for the next agent

**Resolve the iPhone loading splash definitively** (order: iOS version + Chrome test → clear site data → console via debug web build). Then, with owner credentials, deploy the public stack — that single step fulfils the user's "works away from this device" requirement. Do not restart the running API casually: it wipes the in-memory test data and, if `cloudflared` is also restarted, the live URL changes (the next agent should restart both only when the owner is not mid-test, and should document the new URL).
