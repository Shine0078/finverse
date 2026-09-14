import { createHash, randomUUID } from 'node:crypto';
import { BadRequestException, ConflictException, HttpException, HttpStatus, Inject, Injectable, Logger, NotFoundException, Optional } from '@nestjs/common';

import { getCategory, isKnownCategory } from '../../domain/categories';
import { categorizeDescriptor, ruleFromCorrection } from '../../domain/categorization/categorize';
import { normalizeDescriptor } from '../../domain/categorization/normalize';
import { addDays } from '../../domain/dates';
import { analyzeStatement, categorizeStatementDescriptor, formatFor } from '../../domain/statement-import/analyze';
import { summarizeStatementRows } from '../../domain/statement-import/summary';
import { detectInternalTransfers, internalTransferIds, isUserCategorised } from '../../domain/transactions/internal-transfers';
import { UserCorrectionClassifier } from '../../domain/categorization/user-correction-classifier';
import type { StatementImport, StatementImportEvent, StatementImportJob, StatementRowDraft, StatementRowRecord } from '../../domain/statement-import/types';
import type { Transaction } from '../../domain/types';
import { loadConfig } from '../../config';
import {
  ACCOUNT_STORE, CLOCK, RULE_STORE, STATEMENT_FILE_CIPHER, STATEMENT_IMPORT_STORE, TRANSACTION_STORE,
  type AccountStore, type ClockPort, type ImportBatch, type RuleStore, type StatementFileCipher,
  type StatementImportStore, type TransactionStore,
} from '../../ports';
import { FinanceEventBus } from '../../infra/events/finance-event-bus';

const MAX_BYTES = 10 * 1024 * 1024;
const MAX_FILENAME = 260;

export interface CreateStatementInput {
  accountId?: unknown;
  filename?: unknown;
  mimeType?: unknown;
  contentBase64?: unknown;
}

export interface EditStatementRowInput {
  postedAt?: unknown;
  description?: unknown;
  merchant?: unknown;
  amount?: unknown;
  currency?: unknown;
  categorySlug?: unknown;
  isRecurring?: unknown;
  decision?: unknown;
}

@Injectable()
export class StatementImportService {
  private readonly logger = new Logger(StatementImportService.name);

  constructor(
    @Inject(STATEMENT_IMPORT_STORE) private readonly imports: StatementImportStore,
    @Inject(STATEMENT_FILE_CIPHER) private readonly cipher: StatementFileCipher,
    @Inject(ACCOUNT_STORE) private readonly accounts: AccountStore,
    @Inject(TRANSACTION_STORE) private readonly transactions: TransactionStore,
    @Inject(RULE_STORE) private readonly rules: RuleStore,
    @Inject(CLOCK) private readonly clock: ClockPort,
    @Optional() private readonly events?: FinanceEventBus,
  ) {}

  async create(userId: string, input: CreateStatementInput): Promise<{ statement: StatementImport; rows: StatementRowRecord[]; warnings: string[]; queued: boolean }> {
    const accountId = stringField(input.accountId, 'accountId', 1, 120);
    const filename = stringField(input.filename, 'filename', 1, MAX_FILENAME);
    const mimeType = typeof input.mimeType === 'string' ? input.mimeType.trim().toLowerCase() : 'application/octet-stream';
    const encoded = stringField(input.contentBase64, 'contentBase64', 1, Math.ceil(MAX_BYTES * 4 / 3) + 32);
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(encoded) || encoded.length % 4 === 1) throw new BadRequestException('contentBase64 must be valid base64.');
    const bytes = Buffer.from(encoded, 'base64');
    if (bytes.length === 0 || bytes.length > MAX_BYTES) throw new BadRequestException('Statement files must be between 1 byte and 10 MB.');
    const account = await this.accounts.get(userId, accountId);
    if (!account) throw new NotFoundException('No such account.');

    // Production uses a durable queue so OCR and workbook parsing cannot hold
    // an HTTP request open or lose an upload when the process restarts. Local
    // development and contract tests keep the synchronous response unless
    // explicitly opted into the worker with STATEMENT_IMPORT_ASYNC=true.
    if (loadConfig().statementImportAsync) {
      let format;
      try {
        format = formatFor(filename, mimeType);
      } catch (error) {
        throw new BadRequestException(error instanceof Error ? error.message : 'Unsupported statement format.');
      }
      const statement: StatementImport = {
        id: randomUUID(), accountId, filename, mimeType, format,
        statementHash: createHash('sha256').update(bytes).digest('hex'),
        status: 'queued', rowsTotal: 0, rowsIncluded: 0, rowsExcluded: 0,
        rowsNeedsReview: 0, createdAt: this.clock.now().toISOString(),
        processedAt: null, approvedAt: null, sourceDeletedAt: null, error: null,
      };
      try {
        await this.imports.enqueue(userId, statement, this.cipher.encrypt(encoded));
      } catch (error) {
        if (error instanceof Error && error.message === 'STATEMENT_DUPLICATE') throw new ConflictException('This statement has already been imported for this account.');
        if (error instanceof Error && error.message === 'STATEMENT_QUOTA_EXCEEDED') throw new HttpException('Statement import storage or queue capacity is temporarily full. Delete old sources or wait for existing imports to finish.', HttpStatus.TOO_MANY_REQUESTS);
        throw error;
      }
      return { statement, rows: [], warnings: [], queued: true };
    }

    const existing = await this.transactions.list(userId, { accountId });
    const rules = await this.rules.list(userId);
    let extraction;
    try {
      extraction = await analyzeStatement({ filename, mimeType, bytes, currency: account.currency, existing, rules });
    } catch (error) {
      throw new BadRequestException(error instanceof Error ? error.message : 'Could not process this statement.');
    }
    const id = randomUUID();
    const rows = this.decorateRows(id, extraction.rows, existing);
    const now = this.clock.now().toISOString();
    const statement: StatementImport = {
      id, accountId, filename, mimeType, format: extraction.format, statementHash: extraction.statementHash,
      status: 'ready', rowsTotal: rows.length, rowsIncluded: rows.filter((row) => row.decision === 'include').length,
      rowsExcluded: rows.filter((row) => row.decision === 'exclude').length,
      rowsNeedsReview: rows.filter((row) => row.decision === 'needs_review').length,
      createdAt: now, processedAt: now, approvedAt: null, sourceDeletedAt: null, error: null,
      documentDetails: extraction.documentDetails,
    };
    try {
      await this.imports.create(userId, statement, this.cipher.encrypt(encoded), rows);
    } catch (error) {
      if (error instanceof Error && error.message === 'STATEMENT_DUPLICATE') throw new ConflictException('This statement has already been imported for this account.');
      if (error instanceof Error && error.message === 'STATEMENT_QUOTA_EXCEEDED') throw new HttpException('Statement import storage capacity is temporarily full. Delete old sources before uploading another statement.', HttpStatus.TOO_MANY_REQUESTS);
      throw error;
    }
    return { statement, rows, warnings: extraction.warnings, queued: false };
  }

  /** Runs one claimed durable job. Safe to call concurrently across instances. */
  async processQueued(job: StatementImportJob): Promise<void> {
    const source = await this.imports.source(job.userId, job.id);
    if (!source) {
      await this.imports.failProcessing(
        job.userId,
        job.id,
        'The encrypted statement source is unavailable.',
        this.clock.now().toISOString(),
        this.event(job.id, null, 'failed', { reason: 'source_unavailable' }),
      );
      return;
    }

    try {
      const encoded = this.cipher.decrypt(source.encryptedSource);
      const bytes = Buffer.from(encoded, 'base64');
      if (bytes.length === 0 || bytes.length > MAX_BYTES) throw new Error('Statement source integrity check failed.');
      const hash = createHash('sha256').update(bytes).digest('hex');
      if (hash !== source.statement.statementHash) throw new Error('Statement source integrity check failed.');
      const account = await this.accounts.get(job.userId, source.statement.accountId);
      if (!account) throw new Error('The statement account no longer exists.');
      const existing = await this.transactions.list(job.userId, { accountId: source.statement.accountId });
      const rules = await this.rules.list(job.userId);
      const extraction = await analyzeStatement({
        filename: source.statement.filename,
        mimeType: source.statement.mimeType,
        bytes,
        currency: account.currency,
        existing,
        rules,
      });
      const rows = this.decorateRows(job.id, extraction.rows, existing);
      const processedAt = this.clock.now().toISOString();
      await this.imports.completeProcessing(
        job.userId,
        job.id,
        rows,
        processedAt,
        this.event(job.id, null, 'processed', {
          rows: rows.length,
          warnings: extraction.warnings.slice(0, 8),
        }),
        extraction.documentDetails,
      );
    } catch (error) {
      const message = safeProcessingError(error);
      await this.imports.failProcessing(
        job.userId,
        job.id,
        message,
        this.clock.now().toISOString(),
        this.event(job.id, null, 'failed', { reason: message }),
      );
    }
  }

  list(userId: string): Promise<StatementImport[]> { return this.imports.list(userId); }

  async get(userId: string, id: string): Promise<{ statement: StatementImport; rows: StatementRowRecord[] }> {
    const statement = await this.imports.get(userId, id);
    if (!statement) throw new NotFoundException('Statement import not found.');
    return { statement, rows: await this.imports.rows(userId, id) };
  }

  async editRow(userId: string, importId: string, rowId: string, input: EditStatementRowInput): Promise<StatementRowRecord> {
    const current = await this.findRow(userId, importId, rowId);
    const patch: Partial<StatementRowRecord> = {};
    if (input.postedAt !== undefined) {
      if (typeof input.postedAt !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(input.postedAt) || Number.isNaN(Date.parse(`${input.postedAt}T00:00:00Z`))) throw new BadRequestException('postedAt must be YYYY-MM-DD.');
      patch.postedAt = input.postedAt;
    }
    if (input.description !== undefined) {
      if (typeof input.description !== 'string' || input.description.trim().length === 0 || input.description.length > 500) throw new BadRequestException('description must be 1 through 500 characters.');
      patch.description = input.description.trim();
      patch.merchant = current.merchant;
    }
    if (input.merchant !== undefined) {
      if (input.merchant !== null && (typeof input.merchant !== 'string' || input.merchant.length > 160)) throw new BadRequestException('merchant is too long.');
      patch.merchant = typeof input.merchant === 'string' ? input.merchant.trim() : null;
    }
    if (input.amount !== undefined) {
      if (!Number.isSafeInteger(input.amount) || (input.amount as number) === 0) throw new BadRequestException('amount must be a non-zero minor-unit integer.');
      patch.amount = input.amount as number;
      patch.direction = (input.amount as number) < 0 ? 'debit' : 'credit';
    }
    if (input.currency !== undefined) {
      if (typeof input.currency !== 'string' || !/^[A-Za-z]{3}$/.test(input.currency)) throw new BadRequestException('currency must be a 3-letter ISO code.');
      patch.currency = input.currency.toUpperCase();
    }
    if (input.categorySlug !== undefined) {
      if (typeof input.categorySlug !== 'string' || !isKnownCategory(input.categorySlug)) throw new BadRequestException('Unknown category.');
      patch.categorySlug = input.categorySlug;
      patch.categorySource = 'user_manual';
      patch.categoryConfidence = 1;
    }
    if (input.isRecurring !== undefined) {
      if (typeof input.isRecurring !== 'boolean') throw new BadRequestException('isRecurring must be boolean.');
      patch.isRecurring = input.isRecurring;
    }
    if (input.decision !== undefined) {
      if (input.decision !== 'include' && input.decision !== 'exclude' && input.decision !== 'needs_review') throw new BadRequestException('decision must be include, exclude, or needs_review.');
      patch.decision = input.decision;
    }
    const next = { ...current, ...patch };
    patch.fingerprint = fingerprint(next);
    const event = this.event(importId, rowId, 'row_edited', { fields: Object.keys(patch) });
    const updated = await this.imports.updateRow(userId, importId, rowId, patch, event);
    if (!updated) throw new NotFoundException('Statement row is not editable.');
    return updated;
  }

  async decideRows(userId: string, importId: string, input: { rowIds?: unknown; decision?: unknown }): Promise<StatementRowRecord[]> {
    if (!Array.isArray(input.rowIds) || input.rowIds.length < 1 || input.rowIds.length > 10_000 || input.rowIds.some((value) => typeof value !== 'string')) {
      throw new BadRequestException('Provide one or more row ids.');
    }
    const rowIds = [...new Set(input.rowIds as string[])];
    if (rowIds.length !== input.rowIds.length) throw new BadRequestException('rowIds must not contain duplicates.');
    if (input.decision !== 'include' && input.decision !== 'exclude' && input.decision !== 'needs_review') {
      throw new BadRequestException('decision must be include, exclude, or needs_review.');
    }
    const existing = await this.imports.rows(userId, importId);
    if (existing.length === 0 || existing.some((row) => row.importId !== importId) || rowIds.some((id) => !existing.some((row) => row.id === id))) {
      throw new NotFoundException('One or more statement rows were not found.');
    }
    const updated = await this.imports.updateRowsDecision(
      userId,
      importId,
      rowIds,
      input.decision as StatementRowRecord['decision'],
      this.event(importId, null, 'row_edited', { fields: ['decision'], rows: rowIds.length, decision: input.decision }),
    );
    if (!updated) throw new ConflictException('This statement is no longer awaiting row review.');
    return updated;
  }

  async splitRow(userId: string, importId: string, rowId: string, input: { parts?: unknown }): Promise<StatementRowRecord[]> {
    const current = await this.findRow(userId, importId, rowId);
    if (!Array.isArray(input.parts) || input.parts.length < 2 || input.parts.length > 10 || current.amount === null) throw new BadRequestException('Provide between 2 and 10 parts for a valid transaction.');
    const parts = input.parts.map((part, index) => {
      if (!part || typeof part !== 'object') throw new BadRequestException('Each split part must be an object.');
      const value = part as { amount?: unknown; categorySlug?: unknown; description?: unknown };
      if (!Number.isSafeInteger(value.amount) || value.amount === 0) throw new BadRequestException('Split amounts must be non-zero minor-unit integers.');
      const category = typeof value.categorySlug === 'string' && isKnownCategory(value.categorySlug) ? value.categorySlug : current.categorySlug;
      const description = typeof value.description === 'string' && value.description.trim() ? value.description.trim().slice(0, 500) : `${current.description} (${index + 1})`;
      const row: StatementRowRecord = { ...current, id: `${current.id}_part_${index + 1}`, description, amount: value.amount as number, merchant: current.merchant, categorySlug: category, categorySource: 'user_manual', categoryConfidence: 1, direction: (value.amount as number) < 0 ? 'debit' : 'credit', decision: 'include', flags: ['split_child'], editedAt: this.clock.now().toISOString(), fingerprint: '' };
      row.fingerprint = fingerprint(row);
      return row;
    });
    if (parts.reduce((sum, part) => sum + (part.amount ?? 0), 0) !== current.amount) throw new BadRequestException('Split parts must add up exactly to the original amount.');
    const updated = await this.imports.splitRow(userId, importId, rowId, parts, this.event(importId, rowId, 'row_split', { parts: parts.length }));
    if (!updated) throw new NotFoundException('Statement row is not editable.');
    return updated;
  }

  async mergeRows(userId: string, importId: string, input: { rowIds?: unknown }): Promise<StatementRowRecord> {
    if (!Array.isArray(input.rowIds) || input.rowIds.length < 2 || input.rowIds.length > 10 || input.rowIds.some((value) => typeof value !== 'string')) throw new BadRequestException('Provide between 2 and 10 row ids.');
    const rows = await this.imports.rows(userId, importId);
    const wanted = rows.filter((row) => (input.rowIds as string[]).includes(row.id));
    if (wanted.length !== input.rowIds.length || wanted.some((row) => row.amount === null)) throw new BadRequestException('All merge rows must exist and have amounts.');
    const first = wanted[0]!;
    const merged: StatementRowRecord = { ...first, id: `${first.id}_merged_${randomUUID()}`, description: wanted.map((row) => row.description).join(' + ').slice(0, 500), amount: wanted.reduce((sum, row) => sum + (row.amount ?? 0), 0), categorySource: 'user_manual', categoryConfidence: 1, flags: ['merged_row'], decision: 'include', editedAt: this.clock.now().toISOString(), fingerprint: '' };
    merged.fingerprint = fingerprint(merged);
    const result = await this.imports.mergeRows(userId, importId, input.rowIds as string[], merged, this.event(importId, null, 'rows_merged', { rows: input.rowIds }));
    if (!result) throw new NotFoundException('Statement rows are not editable.');
    return result;
  }

  async approve(userId: string, importId: string): Promise<StatementImport> {
    const found = await this.get(userId, importId);
    if (found.statement.status !== 'ready') throw new ConflictException('This statement is no longer awaiting approval.');
    const existing = await this.transactions.list(userId, { accountId: found.statement.accountId });
    const rules = await this.rules.list(userId);
    const model = UserCorrectionClassifier.fromTransactions(existing);
    const existingProviderIds = new Set(existing.map((transaction) => transaction.providerTxnId));

    const autoCategorized = new Set<string>();
    const resolved = found.rows.map((row) => {
      if (row.categorySlug !== 'unknown' && row.categoryConfidence >= 0.7) return row;
      const category = categorizeStatementDescriptor(row.description, {
        rules,
        model,
        amount: row.amount,
      });
      if (category.categorySlug === 'unknown') return row;
      autoCategorized.add(row.id);
      return {
        ...row,
        categorySlug: category.categorySlug,
        categorySource: category.source,
        categoryConfidence: category.confidence,
        merchant: category.merchant ?? row.merchant,
        flags: row.flags.filter((flag) => flag !== 'uncategorized' && flag !== 'low_confidence'),
      };
    });

    const valid = resolved.filter(
      (row) => row.decision !== 'exclude' && row.amount !== null && row.amount !== 0 && row.postedAt,
    );
    const duplicateIds = new Set(
      valid
        .filter(
          (row) =>
            existingProviderIds.has(`manual_${row.fingerprint}`) ||
            existing.some((transaction) => sameTransactionIdentity(transaction, row)),
        )
        .map((row) => row.id),
    );
    const included = valid.filter((row) => !duplicateIds.has(row.id));
    const includedIds = new Set(included.map((row) => row.id));
    const includeDecisions = found.rows
      .filter((row) => includedIds.has(row.id) && row.decision !== 'include')
      .map((row) => row.id);
    const excludeDecisions = found.rows
      .filter((row) => row.decision !== 'exclude' && !includedIds.has(row.id))
      .map((row) => row.id);

    if (includeDecisions.length > 0) {
      await this.imports.updateRowsDecision(
        userId,
        importId,
        includeDecisions,
        'include',
        this.event(importId, null, 'row_edited', {
          fields: ['decision'],
          rows: includeDecisions.length,
          decision: 'include',
          automatic: true,
        }),
      );
    }
    if (excludeDecisions.length > 0) {
      await this.imports.updateRowsDecision(
        userId,
        importId,
        excludeDecisions,
        'exclude',
        this.event(importId, null, 'row_edited', {
          fields: ['decision'],
          rows: excludeDecisions.length,
          decision: 'exclude',
          automatic: true,
        }),
      );
    }
    for (const row of resolved.filter((candidate) => autoCategorized.has(candidate.id))) {
      await this.imports.updateRow(
        userId,
        importId,
        row.id,
        {
          merchant: row.merchant,
          categorySlug: row.categorySlug,
          categorySource: row.categorySource,
          categoryConfidence: row.categoryConfidence,
          flags: row.flags,
        },
        this.event(importId, row.id, 'row_edited', {
          fields: ['merchant', 'categorySlug', 'categorySource', 'categoryConfidence', 'flags'],
          automatic: true,
        }),
      );
    }
    const batchId = randomUUID();
    const transactions: Transaction[] = included.map((row) => ({
      id: `stmt_${importId}_${row.id}`, accountId: found.statement.accountId, providerTxnId: `manual_${row.fingerprint}`,
      postedAt: row.postedAt!, amount: row.amount!, currency: row.currency, rawDescriptor: row.description,
      normalizedDescriptor: normalizeDescriptor(row.description), merchant: row.merchant ?? undefined,
      categorySlug: row.categorySlug, categorySource: row.categorySource, categoryConfidence: row.categoryConfidence,
      isRecurring: row.isRecurring, pending: false, importBatchId: batchId,
    }));
    const batch: ImportBatch = { id: batchId, accountId: found.statement.accountId, statementImportId: importId, filename: found.statement.filename, status: 'committed', rowsTotal: found.rows.length, rowsImported: transactions.length, rowsDuplicate: new Set([...duplicateIds, ...found.rows.filter((row) => row.flags.includes('possible_duplicate')).map((row) => row.id)]).size, rowsInvalid: found.rows.filter((row) => row.amount === null || row.amount === 0 || !row.postedAt).length, createdAt: this.clock.now().toISOString(), revertedAt: null };
    let result: StatementImport | null;
    try {
      result = await this.imports.finalize(userId, importId, batch, transactions, this.event(importId, null, 'approved', {
        rows: transactions.length,
        autoCategorized: autoCategorized.size,
        skipped: found.rows.length - transactions.length,
      }));
    } catch (error) {
      if (error instanceof Error && error.message === 'STATEMENT_DUPLICATE') {
        throw new ConflictException('One or more included rows already exist in this account. Exclude them to prevent a duplicate ledger entry.');
      }
      throw error;
    }
    if (!result) throw new ConflictException('This statement is no longer awaiting approval.');
    this.events?.publish({
      type: 'TransactionImported',
      userId,
      at: this.clock.now().toISOString(),
      inserted: transactions.length,
      transactionIds: transactions.map((transaction) => transaction.id),
    });
    try {
      await this.reconcileInternalTransfers(userId, included);
    } catch (error) {
      // Approval is already durable. A transient categorisation failure must
      // not turn a successful financial write into a misleading 500; the next
      // bank sync or manual approval can safely retry this derived update.
      this.logger.warn(`Internal transfer reconciliation deferred: ${safeProcessingError(error)}`);
    }
    for (const row of included.filter((candidate) => candidate.categorySource === 'user_manual')) {
      try { await this.rules.create(userId, ruleFromCorrection(row.description, row.categorySlug, randomUUID())); } catch { /* a duplicate correction does not invalidate an approved import */ }
    }
    return result;
  }

  async deleteSource(userId: string, id: string): Promise<void> {
    const ok = await this.imports.deleteSource(userId, id, this.clock.now().toISOString(), this.event(id, null, 'source_deleted', {}));
    if (!ok) throw new NotFoundException('Source already deleted or statement not found.');
  }

  async delete(userId: string, id: string): Promise<void> {
    const ok = await this.imports.delete(userId, id, this.clock.now().toISOString(), this.event(id, null, 'deleted', {}));
    if (!ok) throw new NotFoundException('Statement import not found.');
  }

  audit(userId: string, id: string): Promise<StatementImportEvent[]> { return this.imports.audit(userId, id); }

  async summary(userId: string, id: string) {
    const found = await this.get(userId, id);
    return summarizeStatementRows(
      found.rows,
      found.statement.documentDetails?.currency ?? 'USD',
    );
  }

  private async findRow(userId: string, importId: string, rowId: string): Promise<StatementRowRecord> {
    const row = (await this.imports.rows(userId, importId)).find((candidate) => candidate.id === rowId);
    if (!row) throw new NotFoundException('Statement row not found.');
    return row;
  }

  private decorateRows(importId: string, rows: readonly StatementRowDraft[], existing: readonly Transaction[]): StatementRowRecord[] {
    const counts = new Map<string, number>();
    for (const row of rows) counts.set(normalizeDescriptor(row.description), (counts.get(normalizeDescriptor(row.description)) ?? 0) + 1);
    return rows.map((row) => {
      const flags = [...row.flags];
      const key = normalizeDescriptor(row.description);
      const recurring = (counts.get(key) ?? 0) > 1 || existing.filter((txn) => normalizeDescriptor(txn.rawDescriptor) === key && txn.amount === row.amount).length > 0;
      if (recurring && !flags.includes('recurring_payment')) flags.push('recurring_payment');
      if (getCategory(row.categorySlug)?.kind === 'transfer' && !flags.includes('internal_transfer')) flags.push('internal_transfer');
      if ((row.categorySlug === 'refunds' || /\brefund\b|\breversal\b/i.test(row.description)) && !flags.includes('refund')) flags.push('refund');
      if (row.amount !== null && Math.abs(row.amount) > 500_000 && !flags.includes('unusual_spending')) flags.push('unusual_spending');
      // Recurring, refund, transfer, and unusual-spend markers are useful
      // analysis signals, not extraction failures. Only evidence that makes a
      // row unsafe to approve should hold the import at the review boundary.
      const blocksApproval = flags.some((flag) =>
        ['extraction_error', 'uncategorized', 'low_confidence', 'ambiguous_date', 'possible_duplicate'].includes(flag),
      );
      return { ...row, id: `${importId}_row_${row.sourceLine}_${randomUUID().slice(0, 8)}`, importId, isRecurring: recurring || row.isRecurring, flags: flags.slice(0, 8), decision: blocksApproval ? 'needs_review' : row.decision, editedAt: null };
    });
  }

  /**
   * Manual statements can arrive in either order. Re-check the small date
   * window around the approved rows so a matching debit and credit across two
   * user-owned accounts are classified as a transfer immediately, without
   * waiting for a future bank sync. User corrections always win.
   */
  private async reconcileInternalTransfers(userId: string, importedRows: readonly StatementRowRecord[]): Promise<void> {
    const dates = importedRows
      .map((row) => row.postedAt)
      .filter((date): date is string => date !== null)
      .sort();
    if (dates.length === 0) return;

    const recent = await this.transactions.list(userId, {
      range: { start: addDays(dates[0]!, -3), end: addDays(dates[dates.length - 1]!, 3) },
    });
    const pairs = detectInternalTransfers(recent);
    if (pairs.length === 0) return;

    const byId = new Map(recent.map((transaction) => [transaction.id, transaction]));
    const categorized: string[] = [];
    for (const id of internalTransferIds(pairs)) {
      const transaction = byId.get(id);
      if (!transaction || isUserCategorised(transaction) || transaction.categorySlug === 'transfer') continue;
      const updated = await this.transactions.update(userId, id, {
        categorySlug: 'transfer',
        categorySource: 'transfer_pairing',
        categoryConfidence: 0.95,
      });
      if (updated) categorized.push(id);
    }
    if (categorized.length > 0) {
      this.events?.publish({
        type: 'TransactionCategorized',
        userId,
        at: this.clock.now().toISOString(),
        transactionIds: categorized,
        updated: categorized.length,
      });
    }
  }

  private event(importId: string, rowId: string | null, kind: StatementImportEvent['kind'], detail: Record<string, unknown>): StatementImportEvent {
    return { id: randomUUID(), importId, rowId, kind, detail, createdAt: this.clock.now().toISOString() };
  }
}

function stringField(value: unknown, field: string, min: number, max: number): string {
  if (typeof value !== 'string' || value.trim().length < min || value.trim().length > max) throw new BadRequestException(`${field} must be between ${min} and ${max} characters.`);
  return value.trim();
}

function fingerprint(row: Pick<StatementRowRecord, 'sourceLine' | 'postedAt' | 'amount' | 'description' | 'currency'>): string {
  return createHash('sha256').update(`${row.sourceLine}|${row.postedAt ?? ''}|${row.amount ?? ''}|${normalizeDescriptor(row.description)}|${row.currency}`).digest('hex');
}

function sameTransactionIdentity(transaction: Transaction, row: StatementRowRecord): boolean {
  return transaction.postedAt === row.postedAt
    && transaction.amount === row.amount
    && transaction.currency === row.currency
    && transaction.normalizedDescriptor === normalizeDescriptor(row.description);
}

function safeProcessingError(error: unknown): string {
  const message = error instanceof Error ? error.message : 'Statement processing failed.';
  return message.replace(/[\r\n]+/g, ' ').slice(0, 500) || 'Statement processing failed.';
}
