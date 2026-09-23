# The Vertical Slice

One path through the system, end to end, with no real bank:

```
mock aggregator -> categorize -> store -> budgets -> insights -> health score
```

It exists to prove the architecture holds up before any of it is expensive to
change, and to give a new engineer something running in under a minute.

## Run it

```bash
npm install
npm run demo
```

`npm run demo` executes the whole pipeline in-process and prints each stage.
No server, no Docker, no network.

For the HTTP API and dev dashboard:

```bash
npm run dev --workspace @finverse/api
```

Then open <http://localhost:3000/>. Press **Sync**.

## What each stage does

### 1. Import

`MockAggregator` emits ~180 transactions across four months and three accounts
(checking, savings, credit card). It stands in for Plaid/Flinks/TrueLayer and
implements the same `AggregatorPort` they will.

Two things about it are deliberate:

- **The descriptors are ugly.** `SQ *BLUE BOTTLE 0093 SAN FRAN CA`,
  `AMZN Mktp US*2K4L91`, `TST* SWEETGREEN 1042`. Clean fixture data would make
  the categorizer look far better than it is.
- **It re-sends the entire ledger on every call**, ignoring the cursor. That is
  the pathological case for sync, and the code has to survive it.

### 2. Categorize

Three tiers, first match wins: user rules → merchant lexicon → a conservative
per-user learner trained only from explicit manual corrections, falling back to
`unknown`. The learner accepts only exact or highly similar non-conflicting
merchant evidence; the rest lands in a review queue rather than being guessed at.
Around **92%** of the generated ledger gets a category without relying on the
learner.

### 3. Store

`InMemoryTransactionStore` and `PostgresTransactionStore` are keyed on
`(accountId, providerTxnId)`, enforced by a matching Postgres unique index.
Re-running sync reports
`inserted: 0, updated: 182` and the row count does not move.

### 4. Correct

Recategorizing a transaction with `createRule: true` writes a tier-1 rule and
**backfills every past transaction from the same merchant**. In the demo, one
correction clears five rows from the review queue at once.

This is the mechanism behind "we never make the same mistake twice." Without the
backfill the user still sees the wrong category on all their history, which
reads as the correction not having worked.

### 5. Budgets

Progress, thresholds at 50/75/90/100%, and a pace projection that warns before
the limit is hit rather than after.

### 6. Insights

Month-to-date compared against **the same elapsed window last month**, not
against the whole of last month. Every insight carries the ids of the
transactions that produced it.

### 7. Subscriptions

Detected from the data, never declared by the user. Requires three or more
charges at a consistent interval *and* consistent amounts, with a single step
change treated as a price rise rather than as inconsistency.

### 8. Health score

0–1000 across six weighted components, each reported separately with a concrete
action attached.

## Verified behaviour

Run against the mock ledger on 2026-08-07:

| Check | Result |
|---|---|
| Transactions imported | 182 from 3 accounts |
| Categorization coverage | 92.3% (95% after one user rule) |
| Re-sync idempotency | `inserted: 0, updated: 182`, row count unchanged |
| Correction backfill | one fix cleared 5 review-queue rows |
| Subscriptions detected | 8, including a 16% Netflix price rise |
| False positives | 0 — no habit misreported as a subscription |
| 30-day cash-flow outlook | $9,965.12 liquid cash projected to $17,772.35 from known recurring income and bills |
| Credit-card plan | 28.5% utilization, with a payment window three days before the due date |
| Full test suite | 184 passing against real PostgreSQL |

## What this slice is not

- **Not connected to a real bank.** Gated on commercial agreements, not code.
- **Not the product UI.** The page at `localhost:3000` is a developer dashboard.
  The product is the Flutter app in `apps/mobile`.
- **Historical note.** This slice predates the production auth system. Accounts
  are now protected by bearer-token sessions, TOTP MFA and passkey support; the
  retired `x-user-id` development header no longer exists anywhere in the
  request path. The test suite has grown well past the 184 tests recorded here.

## Bugs this slice caught

Worth recording, because they are the kind that ship silently:

1. **Uncategorized outflows were excluded from expenses.** A $2,180 rent payment
   the lexicon didn't recognize vanished from spending totals, inflating the
   savings rate to 94% and the health score to 975. Fixed by making `unknown`
   an expense category.
2. **Branch numbers survived normalization.** `blue bottle 0093 san` meant a
   user rule matched one store rather than the merchant, quietly defeating the
   tier-1 guarantee.
3. **A 7-day month-to-date was compared against a full 31-day month**, reporting
   every category as "down 100%".
4. **Frequent habits were reported as weekly subscriptions.** Thirty wandering
   lunch charges will always contain three near their own median.
5. **The mock aggregator emitted duplicate provider ids** — 182 transactions,
   175 unique — so seven silently overwrote each other. Caught by the
   idempotency test, not by reading the code.
