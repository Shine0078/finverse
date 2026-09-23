# Manual Statement Import

Manual Statement Import is a review-first path for bringing a statement into
the FINVERSE ledger when a bank connection is unavailable. It accepts CSV,
XLSX, text PDFs, and PNG/JPEG/WEBP/TIFF/BMP images up to 10 MiB.

## Security contract

- The upload is authenticated and account-scoped. The account is resolved
  through the caller's user scope before parsing or persistence.
- The API validates the file signature as well as the extension/MIME type,
  bounds rows at 10,000, bounds XLSX decompression at 10 MiB, and never
  evaluates spreadsheet formulas.
- The original payload is encrypted with AES-256-GCM before it is stored.
  Production must set `STATEMENT_IMPORT_ENCRYPTION_KEY` to canonical base64 for
  a 32-byte key. The key belongs in the deployment secret manager, never in the
  repository or a client build.
- Staged descriptions, merchant names, and raw source lines are encrypted with
  the same authenticated envelope before PostgreSQL persistence (migration
  `043`). The row keeps only a placeholder plus dates, amounts, categories, and
  decision state needed for scoped review and duplicate checks. Tampered staged
  text fails closed instead of being returned to the client.
- `statement_imports`, `statement_import_rows`, and
  `statement_import_events` use forced PostgreSQL RLS and user-scoped foreign
  keys. The runtime connection must be the restricted application role.
- Parsing and categorization are local and deterministic: user rules and the
  existing merchant lexicon are applied first. Unknown or low-confidence rows
  remain `needs_review`; no remote model call or training export is made.
- A statement identity is SHA-256 of the original bytes. It cannot be imported
  twice for the same user/account while the previous import is retained.
  Transaction fingerprints and the ledger's unique provider key provide a
  second idempotency boundary.
- The original encrypted source can be deleted after approval with
  `DELETE /api/imports/statements/:id/source`. Approved transaction rows and
  the audit history remain. Deleting the account cascades staged statement
  material through the existing account-deletion path.

## Review workflow

1. `POST /api/imports/statements` with `accountId`, `filename`, `mimeType`, and
   a base64 payload. Development may return staged rows immediately. Production
   returns `202` with a queued import; the mobile client polls the import until
   the worker has produced rows.
2. Review every row. Each row includes the source line, normalized date,
   signed minor-unit amount, currency, debit/credit direction, merchant,
   category, confidence, and flags such as `possible_duplicate`,
   `recurring_payment`, `refund`, `internal_transfer`, `unusual_spending`, or
   `extraction_error`.
3. Use `PATCH .../:rowId` to edit fields or set `decision` to `include` or
   `exclude`. A category correction is recorded as a user rule after approval
   and applies only to that user's future descriptors.
4. Use the split and merge endpoints when a source row represents multiple
   purchases or a combined posting. Splits must sum exactly to the original
   amount; parent rows are retained as excluded audit records.
5. `POST /api/imports/statements/:id/approve` atomically creates the normal
   import batch and ledger transactions. Rows still marked `needs_review` are
   resolved as part of approval — valid rows move to `include`, invalid or
   duplicate rows to `exclude` — before the batch is finalized.
6. `GET .../:id/summary` reports the included income, expenses, savings,
   category totals, date range, recurring count, duplicate count, and unusual
   count. Approved rows consequently appear in the existing transactions,
   budgets, analytics, subscriptions, and monthly report surfaces.
7. `GET .../:id/audit` returns the append-only import event history for the
   user's own import.

The mobile Transactions and Settings screens expose the same flow. The server
remains authoritative, so a client cannot bypass review, isolation, or the
approval transaction by sending a handcrafted request.

## Durable processing and operational limits

Image OCR and PDF text extraction are bounded, local processing steps. A PDF
with no extractable text produces no guessed transactions and must be reviewed
or converted by the user before approval. In production, migration `037` turns
the encrypted `statement_imports` row into a durable `queued`/`processing` job:
the restricted runtime role claims work through
`finverse_claim_statement_imports(integer)`, processes only inside the owning
user's RLS scope, and recovers a stale lease after five minutes. The worker is
bounded to 25 claims per pass and runs on every API instance; PostgreSQL
`SKIP LOCKED` prevents duplicate processing across instances. A parser failure
is recorded as `failed` without exposing source contents in logs.

Production configuration defaults `STATEMENT_IMPORT_ASYNC=true` and refuses an
explicit `false`. Local development can opt in with the same variable when a
durable queue is desired. The 10 MiB source and 10,000-row limits remain in
force until load testing demonstrates a larger safe envelope.
