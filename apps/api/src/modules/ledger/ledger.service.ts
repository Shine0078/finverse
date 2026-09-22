import { BadRequestException, ConflictException, Inject, Injectable, NotFoundException } from '@nestjs/common';
import { createHash, randomUUID } from 'node:crypto';

import { categorizeDescriptor, coverageRate, ruleFromCorrection } from '../../domain/categorization/categorize';
import { UserCorrectionClassifier } from '../../domain/categorization/user-correction-classifier';
import { normalizeDescriptor } from '../../domain/categorization/normalize';
import { getCategory, isKnownCategory } from '../../domain/categories';
import { detectSubscriptions } from '../../domain/insights/subscriptions';
import { interpretTransactionSearch } from '../../domain/transactions/natural-search';
import { normalizeTransactionTags } from '../../domain/transactions/tags';
import { addDays, assertIsoDate } from '../../domain/dates';
import { FinanceEventBus } from '../../infra/events/finance-event-bus';
import type { Account, CategorizationRule, RawTransaction, Transaction } from '../../domain/types';
import {
  ACCOUNT_STORE,
  AGGREGATOR,
  CLOCK,
  RULE_STORE,
  TRANSACTION_STORE,
  type AccountStore,
  type AggregatorPort,
  type ClockPort,
  type RuleStore,
  type TransactionQuery,
  type TransactionStore,
} from '../../ports';

export interface SyncResult {
  accounts: number;
  fetched: number;
  inserted: number;
  updated: number;
  /** Share of transactions we could assign a category to, 0–1. */
  coverage: number;
  needsReview: number;
  recurringDetected: number;
}

@Injectable()
export class LedgerService {
  constructor(
    @Inject(AGGREGATOR) private readonly aggregator: AggregatorPort,
    @Inject(ACCOUNT_STORE) private readonly accounts: AccountStore,
    @Inject(TRANSACTION_STORE) private readonly transactions: TransactionStore,
    @Inject(RULE_STORE) private readonly rules: RuleStore,
    @Inject(CLOCK) private readonly clock: ClockPort,
    private readonly events: FinanceEventBus,
  ) {}

  /**
   * Pull from the aggregator, categorize, persist.
   *
   * Safe to run repeatedly: transaction identity is derived from
   * `(accountId, providerTxnId)`, so a provider resending its whole history
   * updates rows rather than duplicating them.
   */
  async sync(userId: string, linkId = 'link_demo'): Promise<SyncResult> {
    const remoteAccounts = await this.aggregator.listAccounts(linkId);
    await this.accounts.upsertMany(userId, remoteAccounts);
    await this.accounts.recordNetWorthSnapshot(userId, this.clock.today());

    const { transactions: raw } = await this.aggregator.fetchTransactions(linkId);
    const [rules, historicalTransactions] = await Promise.all([
      this.rules.list(userId),
      this.transactions.list(userId),
    ]);
    const model = UserCorrectionClassifier.fromTransactions(historicalTransactions);

    const results = raw.map((rawTxn) => ({
      rawTxn,
      categorization: categorizeDescriptor(rawTxn.descriptor, { rules, model }),
    }));

    const mapped: Transaction[] = results.map(({ rawTxn, categorization }) =>
      this.toTransaction(rawTxn, categorization),
    );

    const { inserted, updated } = await this.transactions.upsertMany(userId, mapped);

    // Recurrence is a property of the series, not of a single row, so it can
    // only be determined after the whole ledger is stored.
    const stored = await this.transactions.list(userId);
    const subscriptions = detectSubscriptions(stored);
    const recurringDescriptors = new Set(subscriptions.map((s) => s.normalizedDescriptor));

    for (const txn of stored) {
      if (txn.recurringOverride !== undefined) continue;
      const shouldBeRecurring = recurringDescriptors.has(txn.normalizedDescriptor);
      if (txn.isRecurring !== shouldBeRecurring) {
        await this.transactions.update(userId, txn.id, { isRecurring: shouldBeRecurring });
      }
    }

    const result = {
      accounts: remoteAccounts.length,
      fetched: raw.length,
      inserted,
      updated,
      coverage: coverageRate(results.map((r) => r.categorization)),
      needsReview: results.filter((r) => r.categorization.source === 'unknown').length,
      recurringDetected: subscriptions.length,
    };
    this.events.publish({
      type: 'BankSyncCompleted',
      userId,
      at: this.clock.now().toISOString(),
      fetched: result.fetched,
      inserted: result.inserted,
      updated: result.updated,
    });
    if (result.inserted > 0) {
      this.events.publish({
        type: 'TransactionImported',
        userId,
        at: this.clock.now().toISOString(),
        inserted: result.inserted,
      });
    }
    if (result.updated > 0) {
      this.events.publish({
        type: 'TransactionUpdated',
        userId,
        at: this.clock.now().toISOString(),
        updated: result.updated,
      });
    }
    return result;
  }

  private toTransaction(
    raw: RawTransaction,
    categorization: ReturnType<typeof categorizeDescriptor>,
  ): Transaction {
    return {
      // Deterministic id: re-syncing the same provider transaction must map to
      // the same row even if the store is rebuilt from scratch.
      id: `txn_${raw.accountId}_${raw.providerTxnId}`,
      accountId: raw.accountId,
      providerTxnId: raw.providerTxnId,
      postedAt: raw.postedAt,
      amount: raw.amount,
      currency: raw.currency,
      rawDescriptor: raw.descriptor,
      normalizedDescriptor: normalizeDescriptor(raw.descriptor),
      merchant: categorization.merchant,
      categorySlug: categorization.categorySlug,
      categorySource: categorization.source,
      categoryConfidence: categorization.confidence,
      isRecurring: false,
      pending: raw.pending,
    };
  }

  async createManualTransaction(userId: string, body: Record<string, unknown>): Promise<Transaction> {
    if (!body || typeof body !== 'object') throw new BadRequestException('Enter transaction details.');
    const { requestId, accountId, postedAt, amount, categorySlug } = body;
    const description = typeof body.description === 'string' ? body.description.trim() : '';
    if (typeof requestId !== 'string' || !/^[a-zA-Z0-9_-]{20,100}$/.test(requestId)) {
      throw new BadRequestException('A valid requestId is required for safe retries.');
    }
    if (typeof accountId !== 'string') throw new BadRequestException('Choose an account.');
    const account = await this.accounts.get(userId, accountId);
    if (!account || account.source !== 'manual') throw new NotFoundException('Choose one of your manual accounts.');
    if (!description || description.length > 200) throw new BadRequestException('Description must contain 1 to 200 characters.');
    try { assertIsoDate(postedAt as string); } catch { throw new BadRequestException('Choose a real calendar date.'); }
    if ((postedAt as string) > addDays(this.clock.today(), 1)) throw new BadRequestException('Use a schedule for a future payment.');
    if (!Number.isSafeInteger(amount) || amount === 0 || Math.abs(amount as number) > 10_000_000_000_000) {
      throw new BadRequestException('Enter a non-zero amount in exact minor units.');
    }
    const category = typeof categorySlug === 'string' ? getCategory(categorySlug) : undefined;
    if (!category || !['income', 'expense'].includes(category.kind)
      || ((amount as number) > 0) !== (category.kind === 'income')) {
      throw new BadRequestException('Choose an income or expense category matching the amount.');
    }
    const id = 'manual_' + createHash('sha256').update(userId + ':' + requestId).digest('hex');
    const transaction: Transaction = {
      id, accountId, providerTxnId: id, postedAt: postedAt as string, amount: amount as number,
      currency: account.currency, rawDescriptor: description,
      normalizedDescriptor: normalizeDescriptor(description), merchant: description,
      categorySlug: category.slug, categorySource: 'user_manual', categoryConfidence: 1,
      isRecurring: false, pending: false,
    };
    const { transaction: stored, inserted } = await this.transactions.insertIfAbsent(userId, transaction);
    for (const key of ['accountId', 'postedAt', 'amount', 'rawDescriptor', 'categorySlug'] as const) {
      if (stored[key] !== transaction[key]) throw new ConflictException('This request was already saved with different details. Refresh transactions before trying again.');
    }
    if (inserted) this.events.publish({ type: 'TransactionImported', userId, at: this.clock.now().toISOString(), inserted: 1 });
    return stored;
  }

  listAccounts(userId: string): Promise<Account[]> {
    return this.accounts.list(userId);
  }

  async createManualAccount(
    userId: string,
    details: Omit<Account, 'id' | 'mask' | 'source'>,
  ): Promise<Account> {
    const account: Account = {
      ...details,
      id: `manual_${randomUUID()}`,
      mask: 'manual',
      source: 'manual',
    };
    await this.accounts.upsertMany(userId, [account]);
    await this.accounts.recordNetWorthSnapshot(userId, this.clock.today());
    this.events.publish({
      type: 'AccountConnected',
      userId,
      at: this.clock.now().toISOString(),
    });
    return account;
  }

  async updateManualAccount(
    userId: string,
    accountId: string,
    details: Omit<Account, 'id' | 'mask' | 'source'>,
  ): Promise<Account> {
    const existing = await this.accounts.get(userId, accountId);
    if (!existing || existing.source !== 'manual') {
      throw new NotFoundException('No editable manual account was found.');
    }
    const account: Account = {
      ...details,
      id: existing.id,
      mask: existing.mask,
      source: 'manual',
    };
    await this.accounts.upsertMany(userId, [account]);
    await this.accounts.recordNetWorthSnapshot(userId, this.clock.today());
    this.events.publish({
      type: 'AccountUpdated',
      userId,
      at: this.clock.now().toISOString(),
    });
    return account;
  }

  async removeManualAccount(userId: string, accountId: string): Promise<void> {
    const existing = await this.accounts.get(userId, accountId);
    if (!existing || existing.source !== 'manual') {
      throw new NotFoundException('No editable manual account was found.');
    }
    await this.accounts.remove(userId, accountId);
    await this.accounts.recordNetWorthSnapshot(userId, this.clock.today());
    this.events.publish({
      type: 'AccountDisconnected',
      userId,
      at: this.clock.now().toISOString(),
    });
  }

  listTransactions(userId: string, query: TransactionQuery): Promise<Transaction[]> {
    return this.transactions.list(userId, query);
  }

  async updateTransactionTags(
    userId: string,
    transactionId: string,
    rawTags: unknown,
  ): Promise<Transaction> {
    let tags: string[];
    try {
      tags = normalizeTransactionTags(rawTags);
    } catch (error) {
      throw new BadRequestException(error instanceof Error ? error.message : 'Invalid tags');
    }
    const updated = await this.transactions.update(userId, transactionId, { tags });
    if (!updated) throw new NotFoundException(`No transaction ${transactionId}`);
    this.events.publish({
      type: 'TransactionUpdated',
      userId,
      at: this.clock.now().toISOString(),
      updated: 1,
    });
    return updated;
  }

  listNetWorthHistory(userId: string, limit = 365) {
    return this.accounts.listNetWorthHistory(userId, limit);
  }

  interpretTransactionSearch(input: string) {
    return interpretTransactionSearch(input, this.clock.today());
  }

  listCategorizationRules(userId: string): Promise<CategorizationRule[]> {
    return this.rules.list(userId);
  }

  async removeCategorizationRule(userId: string, ruleId: string): Promise<void> {
    if (!(await this.rules.remove(userId, ruleId))) {
      throw new NotFoundException('Categorization rule not found.');
    }
  }

  /** Transactions the categorizer could not place. The review queue. */
  async listNeedsReview(userId: string): Promise<Transaction[]> {
    const all = await this.transactions.list(userId);
    return all.filter((t) => t.categorySource === 'unknown');
  }

  /** Persist user-owned presentation and analytics choices without touching
   * provider evidence. Empty strings clear optional text fields. */
  async updatePreferences(
    userId: string,
    transactionId: string,
    patch: {
      merchantOverride?: unknown;
      note?: unknown;
      excludedFromAnalytics?: unknown;
      isRecurring?: unknown;
      duplicateReported?: unknown;
    },
  ): Promise<Transaction> {
    const existing = await this.transactions.get(userId, transactionId);
    if (!existing) throw new NotFoundException(`No transaction ${transactionId}`);

    const next: Partial<Transaction> = {};
    for (const [key, value] of Object.entries(patch)) {
      if (key === 'merchantOverride' || key === 'note') {
        if (value !== undefined && value !== null && typeof value !== 'string') {
          throw new BadRequestException(`${key} must be text`);
        }
        const text = typeof value === 'string' ? value.trim() : '';
        const limit = key === 'merchantOverride' ? 120 : 2000;
        if (text.length > limit) {
          throw new BadRequestException(`${key} must be at most ${limit} characters`);
        }
        next[key] = text || undefined;
      } else if (key === 'excludedFromAnalytics') {
        if (typeof value !== 'boolean') {
          throw new BadRequestException('excludedFromAnalytics must be a boolean');
        }
        next.excludedFromAnalytics = value;
      } else if (key === 'isRecurring') {
        if (typeof value !== 'boolean') {
          throw new BadRequestException('isRecurring must be a boolean');
        }
        next.isRecurring = value;
        next.recurringOverride = value;
      } else if (key === 'duplicateReported') {
        if (typeof value !== 'boolean') {
          throw new BadRequestException('duplicateReported must be a boolean');
        }
        next.duplicateReported = value;
      }
    }

    const updated = await this.transactions.update(userId, transactionId, next);
    if (!updated) throw new NotFoundException(`No transaction ${transactionId}`);
    this.events.publish({
      type: 'TransactionUpdated',
      userId,
      at: this.clock.now().toISOString(),
      updated: 1,
    });
    return updated;
  }

  /**
   * A user correction.
   *
   * With `createRule`, this also writes a tier-1 rule and reapplies it across
   * the whole ledger. That is the mechanism behind "we never make the same
   * mistake twice" (ADR-0004) — without the backfill the user still sees the
   * old category on every past transaction from that merchant.
   */
  async recategorize(
    userId: string,
    transactionId: string,
    categorySlug: string,
    createRule: boolean,
  ): Promise<{ transaction: Transaction; alsoUpdated: number }> {
    if (!isKnownCategory(categorySlug)) {
      throw new NotFoundException(`Unknown category "${categorySlug}"`);
    }

    const existing = await this.transactions.get(userId, transactionId);
    if (!existing) throw new NotFoundException(`No transaction ${transactionId}`);

    const updated = await this.transactions.update(userId, transactionId, {
      categorySlug,
      categorySource: 'user_manual',
      categoryConfidence: 1,
    });

    let alsoUpdated = 0;

    if (createRule) {
      const rule = ruleFromCorrection(
        existing.rawDescriptor,
        categorySlug,
        `rule_${Date.now()}_${existing.id.slice(-6)}`,
      );
      await this.rules.create(userId, rule);

      const all = await this.transactions.list(userId);
      for (const txn of all) {
        if (txn.id === transactionId) continue;
        if (txn.categorySource === 'user_manual') continue; // never override an explicit choice
        if (!txn.normalizedDescriptor.includes(rule.pattern)) continue;
        await this.transactions.update(userId, txn.id, {
          categorySlug,
          categorySource: 'user_rule',
          categoryConfidence: 1,
        });
        alsoUpdated += 1;
      }
    }

    this.events.publish({
      type: 'TransactionCategorized',
      userId,
      at: this.clock.now().toISOString(),
      transactionIds: [transactionId],
      updated: alsoUpdated + 1,
    });
    return { transaction: updated!, alsoUpdated };
  }

  today(): string {
    return this.clock.today();
  }
}
