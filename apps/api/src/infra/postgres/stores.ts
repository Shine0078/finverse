/**
 * Postgres implementations of the four store ports.
 *
 * Every method takes `userId` and every statement filters on it. That is not
 * belt-and-braces: a missing user scope in a finance app leaks one person's
 * transactions to another. The in-memory stores are keyed the same way so the
 * mistake surfaces in tests rather than in production.
 *
 * Since 003_rls.sql there is a second line of defence underneath. Each method
 * runs inside `withUserScope`, which opens a transaction and pins
 * `finverse.user_id`; the row-level security policies compare every row against
 * it. A statement that loses its `WHERE user_id = $1` now returns nothing
 * instead of everything. The explicit predicates stay â€” two independent controls
 * are the point, and dropping the visible one would make these queries look like
 * they leak to anyone reading them.
 */

import type { Pool, PoolClient } from 'pg';

import type {
  Account,
  Budget,
  CategorizationRule,
  GoalContribution,
  NotificationPreferences,
  NetWorthSnapshot,
  SavingsGoal,
  UserNotification,
  Transaction,
} from '../../domain/types';
import { CATEGORIES } from '../../domain/categories';
import type {
  SplitExpense,
  SplitGroupInvitation,
  SplitGroup,
  SplitGroupMember,
  SplitSettlement,
} from '../../domain/split/types';
import type { Reconciliation } from '../../domain/reconciliation/types';
import type { SavedView } from '../../domain/transactions/saved-view';
import type { ScheduledTransaction } from '../../domain/scheduled/schedule';
import type { FxRate } from '../../domain/fx/rates';
import {
  DuplicateViewNameError,
  type ImportBatch,
  type ImportBatchStore,
  type AccountStore,
  type BudgetStore,
  type GoalStore,
  type NotificationStore,
  type ReconciliationStore,
  type RuleStore,
  type SavedViewStore,
  type ScheduleStore,
  type RuleApplication,
  type RuleApplicationChange,
  type RuleApplicationStore,
  type FxRateStore,
  type SplitStore,
  type TransactionQuery,
  type TransactionStore,
} from '../../ports';
import { withUserScope } from './pool';
import {
  chunk,
  placeholders,
  toAccount,
  toBudget,
  toGoal,
  toGoalContribution,
  toNotification,
  toNotificationPreferences,
  toRule,
  toSplitExpense,
  toSplitGroup,
  toSplitMember,
  toSplitParticipant,
  toSplitSettlement,
  toTransaction,
  type AccountRow,
  type BudgetRow,
  type GoalContributionRow,
  type GoalRow,
  type NotificationPreferenceRow,
  type NotificationRow,
  type RuleRow,
  type SplitExpenseRow,
  type SplitGroupRow,
  type SplitMemberRow,
  type SplitParticipantRow,
  type SplitSettlementRow,
  type TransactionRow,
} from './rows';

/**
 * Users are created lazily on first write.
 *
 * Real registration exists now, but the store ports are also driven by the
 * demo seed and the contract suite, which have no account behind them. Without
 * this every such write fails its foreign key, and dropping the FK to avoid
 * that would give up the cascade that makes account deletion actually delete
 * things.
 *
 * `users` carries no RLS policy, so this works inside a scoped transaction:
 * identity has to be readable before the user is known.
 */
async function ensureUser(client: PoolClient, userId: string): Promise<void> {
  await client.query('INSERT INTO users (id) VALUES ($1) ON CONFLICT (id) DO NOTHING', [userId]);
}

// ---------------------------------------------------------------- accounts

const ACCOUNT_COLUMNS = `
  id, name, type, mask, currency, balance_current,
  credit_limit, statement_day, payment_due_day, source
`;

export class PostgresAccountStore implements AccountStore {
  constructor(private readonly pg: Pool) {}

  async list(userId: string): Promise<Account[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<AccountRow>(
        `SELECT ${ACCOUNT_COLUMNS} FROM accounts WHERE user_id = $1 ORDER BY name`,
        [userId],
      );
      return rows.map(toAccount);
    });
  }

  async get(userId: string, accountId: string): Promise<Account | null> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<AccountRow>(
        `SELECT ${ACCOUNT_COLUMNS} FROM accounts WHERE user_id = $1 AND id = $2`,
        [userId, accountId],
      );
      return rows[0] ? toAccount(rows[0]) : null;
    });
  }

  async upsertMany(userId: string, accounts: readonly Account[]): Promise<void> {
    if (accounts.length === 0) return;

    await withUserScope(this.pg, userId, async (client) => {
      await ensureUser(client, userId);

      const values: unknown[] = [];
      const tuples: string[] = [];

      accounts.forEach((account, index) => {
        tuples.push(placeholders(11, index));
        values.push(
          account.id,
          userId,
          account.name,
          account.type,
          account.mask,
          account.currency,
          account.balanceCurrent,
          account.creditLimit ?? null,
          account.statementDay ?? null,
          account.paymentDueDay ?? null,
          account.source ?? 'provider',
        );
      });

      await client.query(
        `INSERT INTO accounts (
           id, user_id, name, type, mask, currency,
           balance_current, credit_limit, statement_day, payment_due_day, source
         ) VALUES ${tuples.join(', ')}
         ON CONFLICT (user_id, id) DO UPDATE SET
           name            = EXCLUDED.name,
           type            = EXCLUDED.type,
           mask            = EXCLUDED.mask,
           currency        = EXCLUDED.currency,
           balance_current = EXCLUDED.balance_current,
           credit_limit    = EXCLUDED.credit_limit,
           statement_day   = EXCLUDED.statement_day,
           payment_due_day = EXCLUDED.payment_due_day,
           source          = EXCLUDED.source,
           updated_at      = now()`,
        values,
      );
    });
  }

  async remove(userId: string, accountId: string): Promise<boolean> {
    return withUserScope(this.pg, userId, async (client) => {
      const result = await client.query(
        'DELETE FROM accounts WHERE user_id = $1 AND id = $2',
        [userId, accountId],
      );
      return (result.rowCount ?? 0) > 0;
    });
  }

  async recordNetWorthSnapshot(
    userId: string,
    recordedOn: string,
  ): Promise<NetWorthSnapshot[]> {
    return withUserScope(this.pg, userId, async (client) => {
      // Replace the whole observation for this day. If the user removed their
      // final CAD account, retaining yesterday's same-day CAD row would show a
      // balance they no longer own.
      await client.query(
        'DELETE FROM net_worth_snapshots WHERE user_id = $1 AND recorded_on = $2::date',
        [userId, recordedOn],
      );
      const { rows } = await client.query<{
        recorded_on: string;
        currency: string;
        assets: number;
        debts: number;
        net_position: number;
      }>(
        `INSERT INTO net_worth_snapshots
           (user_id, recorded_on, currency, assets, debts, net_position)
         SELECT
           $1,
           $2::date,
           currency,
           sum(CASE WHEN balance_current >= 0 THEN balance_current ELSE 0 END),
           sum(CASE WHEN balance_current < 0 THEN -balance_current ELSE 0 END),
           sum(balance_current)
         FROM accounts
         WHERE user_id = $1
         GROUP BY currency
         RETURNING recorded_on, currency, assets, debts, net_position`,
        [userId, recordedOn],
      );
      return rows.map(toNetWorthSnapshot);
    });
  }

  async listNetWorthHistory(userId: string, limit = 365): Promise<NetWorthSnapshot[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<{
        recorded_on: string;
        currency: string;
        assets: number;
        debts: number;
        net_position: number;
      }>(
        `SELECT recorded_on, currency, assets, debts, net_position
         FROM (
           SELECT recorded_on, currency, assets, debts, net_position
           FROM net_worth_snapshots
           WHERE user_id = $1
           ORDER BY recorded_on DESC, currency
           LIMIT $2
         ) recent
         ORDER BY recorded_on, currency`,
        [userId, limit],
      );
      return rows.map(toNetWorthSnapshot);
    });
  }
}

function toNetWorthSnapshot(row: {
  recorded_on: string;
  currency: string;
  assets: number;
  debts: number;
  net_position: number;
}): NetWorthSnapshot {
  return {
    recordedOn: row.recorded_on,
    currency: row.currency,
    assets: row.assets,
    debts: row.debts,
    netPosition: row.net_position,
  };
}

// ------------------------------------------------------------ transactions

const TXN_COLUMNS = `
  id, account_id, provider_txn_id, posted_at, amount, currency,
  raw_descriptor, normalized_descriptor, merchant,
  merchant_override, note, excluded_from_analytics,
  category_slug, category_source, category_confidence, is_recurring, recurring_override,
  duplicate_reported, pending, tags, import_batch_id
`;

const TXN_INSERT_COLUMNS = 22;

export class PostgresTransactionStore implements TransactionStore {
  async insertIfAbsent(userId: string, txn: Transaction): Promise<{ transaction: Transaction; inserted: boolean }> {
    return withUserScope(this.pg, userId, async client => {
      const result = await client.query(
        `INSERT INTO transactions (id, user_id, account_id, provider_txn_id, posted_at,
          amount, currency, raw_descriptor, normalized_descriptor, merchant,
          category_slug, category_source, category_confidence, is_recurring, pending)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,false,false)
         ON CONFLICT DO NOTHING`,
        [txn.id, userId, txn.accountId, txn.providerTxnId, txn.postedAt, txn.amount,
          txn.currency, txn.rawDescriptor, txn.normalizedDescriptor, txn.merchant,
          txn.categorySlug, txn.categorySource, txn.categoryConfidence],
      );
      const stored = await fetchTransaction(client, userId, txn.id);
      if (!stored) throw new Error('Manual transaction insert did not persist.');
      return { transaction: stored, inserted: (result.rowCount ?? 0) === 1 };
    });
  }

  constructor(private readonly pg: Pool) {}

  async list(userId: string, query: TransactionQuery = {}): Promise<Transaction[]> {
    const where: string[] = ['user_id = $1'];
    const values: unknown[] = [userId];

    const bind = (value: unknown): string => {
      values.push(value);
      return `$${values.length}`;
    };

    if (query.accountId) where.push(`account_id = ${bind(query.accountId)}`);
    if (query.categorySlug) where.push(`category_slug = ${bind(query.categorySlug)}`);
    if (query.categoryKind) {
      const slugs = CATEGORIES.filter((category) => category.kind === query.categoryKind)
        .map((category) => category.slug);
      if (slugs.length === 0) return [];
      where.push(`category_slug = ANY(${bind(slugs)}::text[])`);
    }
    if (query.range) {
      where.push(`posted_at >= ${bind(query.range.start)}`);
      where.push(`posted_at <= ${bind(query.range.end)}`);
    }
    if (query.before) {
      const date = bind(query.before.postedAt);
      const id = bind(query.before.id);
      where.push(`(posted_at < ${date} OR (posted_at = ${date} AND id < ${id}))`);
    }
    if (query.search) {
      // ILIKE against provider and user-owned text so search matches what the
      // user sees without losing the original bank descriptor.
      const needle = bind(`%${query.search}%`);
      where.push(
        `(normalized_descriptor ILIKE ${needle} OR raw_descriptor ILIKE ${needle} OR merchant ILIKE ${needle} OR merchant_override ILIKE ${needle} OR note ILIKE ${needle})`,
      );
    }
    if (query.pending !== undefined) where.push(`pending = ${bind(query.pending)}`);
    if (query.recurring !== undefined) where.push(`is_recurring = ${bind(query.recurring)}`);
    if (query.amountMin !== undefined) where.push(`ABS(amount) >= ${bind(query.amountMin)}`);
    if (query.amountMax !== undefined) where.push(`ABS(amount) <= ${bind(query.amountMax)}`);
    if (query.tag) where.push(`${bind(query.tag.trim().toLowerCase())} = ANY(tags)`);

    // Tie-break on id so pagination is stable when many rows share a date.
    let sql = `SELECT ${TXN_COLUMNS} FROM transactions
               WHERE ${where.join(' AND ')}
               ORDER BY posted_at DESC, id DESC`;

    if (query.limit !== undefined) sql += ` LIMIT ${bind(query.limit)}`;

    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<TransactionRow>(sql, values);
      return rows.map(toTransaction);
    });
  }

  async get(userId: string, id: string): Promise<Transaction | null> {
    return withUserScope(this.pg, userId, (client) => fetchTransaction(client, userId, id));
  }

  /**
   * Idempotent on `(user_id, account_id, provider_txn_id)`.
   *
   * Two things the ON CONFLICT clause does that are easy to get wrong:
   *
   *  - It never overwrites a category the user set by hand. An aggregator
   *    resending a transaction must not silently revert a correction.
   *  - It keeps the existing row's `id`, so anything already referencing it
   *    stays valid.
   *
   * `xmax = 0` is Postgres' way of telling insert from update in RETURNING.
   *
   * All batches share one transaction, so a sync that fails halfway leaves no
   * partial history behind.
   */
  async upsertMany(
    userId: string,
    transactions: readonly Transaction[],
  ): Promise<{ inserted: number; updated: number }> {
    if (transactions.length === 0) return { inserted: 0, updated: 0 };

    return withUserScope(this.pg, userId, async (client) => {
      await ensureUser(client, userId);

      let inserted = 0;
      let updated = 0;

      for (const batch of chunk(transactions, 500)) {
        const values: unknown[] = [];
        const tuples: string[] = [];

        batch.forEach((txn, index) => {
          tuples.push(placeholders(TXN_INSERT_COLUMNS, index));
          values.push(
            txn.id,
            userId,
            txn.accountId,
            txn.providerTxnId,
            txn.postedAt,
            txn.amount,
            txn.currency,
            txn.rawDescriptor,
            txn.normalizedDescriptor,
            txn.merchant ?? null,
            txn.merchantOverride ?? null,
            txn.note ?? null,
            txn.excludedFromAnalytics ?? false,
            txn.categorySlug,
            txn.categorySource,
            txn.categoryConfidence,
            txn.isRecurring,
            txn.recurringOverride ?? null,
            txn.duplicateReported ?? false,
            txn.pending,
            txn.tags ?? [],
            txn.importBatchId ?? null,
          );
        });

        const { rows } = await client.query<{ inserted: boolean }>(
          `INSERT INTO transactions (
             id, user_id, account_id, provider_txn_id, posted_at, amount, currency,
             raw_descriptor, normalized_descriptor, merchant,
             merchant_override, note, excluded_from_analytics,
             category_slug, category_source, category_confidence, is_recurring, recurring_override,
             duplicate_reported, pending, tags, import_batch_id
           ) VALUES ${tuples.join(', ')}
           ON CONFLICT (user_id, account_id, provider_txn_id) DO UPDATE SET
             posted_at             = EXCLUDED.posted_at,
             amount                = EXCLUDED.amount,
             currency              = EXCLUDED.currency,
             raw_descriptor        = EXCLUDED.raw_descriptor,
             normalized_descriptor = EXCLUDED.normalized_descriptor,
             pending               = EXCLUDED.pending,
             excluded_from_analytics = transactions.excluded_from_analytics,
             merchant_override = transactions.merchant_override,
             note = transactions.note,
             merchant = CASE
               WHEN transactions.category_source IN ('user_manual', 'user_rule')
                 THEN transactions.merchant
               ELSE EXCLUDED.merchant END,
             category_slug = CASE
               WHEN transactions.category_source IN ('user_manual', 'user_rule')
                 THEN transactions.category_slug
               ELSE EXCLUDED.category_slug END,
             category_source = CASE
               WHEN transactions.category_source IN ('user_manual', 'user_rule')
                 THEN transactions.category_source
               ELSE EXCLUDED.category_source END,
             category_confidence = CASE
               WHEN transactions.category_source IN ('user_manual', 'user_rule')
                 THEN transactions.category_confidence
               ELSE EXCLUDED.category_confidence END,
             recurring_override = transactions.recurring_override,
             duplicate_reported = transactions.duplicate_reported,
             -- Provenance is set once, at insert. A later provider sync that
             -- happens to collide must not claim a hand-imported row, or
             -- reverting the import would delete a transaction the bank sent.
             import_batch_id = transactions.import_batch_id,
             updated_at = now()
           RETURNING (xmax = 0) AS inserted`,
          values,
        );

        for (const row of rows) {
          if (row.inserted) inserted += 1;
          else updated += 1;
        }
      }

      return { inserted, updated };
    });
  }

  async update(
    userId: string,
    id: string,
    patch: Partial<Transaction>,
  ): Promise<Transaction | null> {
    const COLUMN_OF: Partial<Record<keyof Transaction, string>> = {
      postedAt: 'posted_at',
      amount: 'amount',
      currency: 'currency',
      rawDescriptor: 'raw_descriptor',
      normalizedDescriptor: 'normalized_descriptor',
      merchant: 'merchant',
      merchantOverride: 'merchant_override',
      note: 'note',
      excludedFromAnalytics: 'excluded_from_analytics',
      categorySlug: 'category_slug',
      categorySource: 'category_source',
      categoryConfidence: 'category_confidence',
      isRecurring: 'is_recurring',
      recurringOverride: 'recurring_override',
      duplicateReported: 'duplicate_reported',
      pending: 'pending',
      tags: 'tags',
    };

    const assignments: string[] = [];
    const values: unknown[] = [userId, id];

    for (const [key, column] of Object.entries(COLUMN_OF)) {
      if (!(key in patch)) continue;
      const value = patch[key as keyof Transaction];
      values.push(value ?? null);
      assignments.push(`${column} = $${values.length}`);
    }

    return withUserScope(this.pg, userId, async (client) => {
      // Nothing to change â€” return the row as it stands rather than emitting
      // `SET updated_at = now()` on its own.
      if (assignments.length === 0) return fetchTransaction(client, userId, id);

      const { rows } = await client.query<TransactionRow>(
        `UPDATE transactions SET ${assignments.join(', ')}, updated_at = now()
         WHERE user_id = $1 AND id = $2
         RETURNING ${TXN_COLUMNS}`,
        values,
      );

      return rows[0] ? toTransaction(rows[0]) : null;
    });
  }

  async removeByProviderIds(userId: string, providerTxnIds: readonly string[]): Promise<number> {
    if (providerTxnIds.length === 0) return 0;
    return withUserScope(this.pg, userId, async (client) => {
      const result = await client.query(
        'DELETE FROM transactions WHERE user_id = $1 AND provider_txn_id = ANY($2::text[])',
        [userId, providerTxnIds],
      );
      return result.rowCount ?? 0;
    });
  }

  async removeByImportBatch(userId: string, importBatchId: string): Promise<number> {
    return withUserScope(this.pg, userId, async (client) => {
      // `import_batch_id = $2` and nothing else. Scoping an undo by date range
      // or account would sweep up provider-synced rows that happen to fall in
      // the same window.
      const result = await client.query(
        'DELETE FROM transactions WHERE user_id = $1 AND import_batch_id = $2',
        [userId, importBatchId],
      );
      return result.rowCount ?? 0;
    });
  }
}

/** Shared by `get` and the no-op path of `update`, which is already in scope. */
async function fetchTransaction(
  client: PoolClient,
  userId: string,
  id: string,
): Promise<Transaction | null> {
  const { rows } = await client.query<TransactionRow>(
    `SELECT ${TXN_COLUMNS} FROM transactions WHERE user_id = $1 AND id = $2`,
    [userId, id],
  );
  return rows[0] ? toTransaction(rows[0]) : null;
}

// ----------------------------------------------------------------- budgets

const BUDGET_COLUMNS = 'id, category_slug, limit_amount, currency, period, rollover';

export class PostgresBudgetStore implements BudgetStore {
  constructor(private readonly pg: Pool) {}

  async list(userId: string): Promise<Budget[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<BudgetRow>(
        `SELECT ${BUDGET_COLUMNS} FROM budgets WHERE user_id = $1 ORDER BY category_slug`,
        [userId],
      );
      return rows.map(toBudget);
    });
  }

  async get(userId: string, id: string): Promise<Budget | null> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<BudgetRow>(
        `SELECT ${BUDGET_COLUMNS} FROM budgets WHERE user_id = $1 AND id = $2`,
        [userId, id],
      );
      return rows[0] ? toBudget(rows[0]) : null;
    });
  }

  /** Upsert, matching the in-memory store. Budget ids are derived from the
   *  category, so re-creating one edits it rather than duplicating it. */
  async create(userId: string, budget: Budget): Promise<Budget> {
    return withUserScope(this.pg, userId, async (client) => {
      await ensureUser(client, userId);

      const { rows } = await client.query<BudgetRow>(
        `INSERT INTO budgets (id, user_id, category_slug, limit_amount, currency, period, rollover)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         ON CONFLICT (user_id, category_slug) DO UPDATE SET
           limit_amount = EXCLUDED.limit_amount,
           currency     = EXCLUDED.currency,
           period       = EXCLUDED.period,
           rollover     = EXCLUDED.rollover
         RETURNING ${BUDGET_COLUMNS}`,
        [
          budget.id,
          userId,
          budget.categorySlug,
          budget.limitAmount,
          budget.currency,
          budget.period,
          budget.rollover,
        ],
      );

      return toBudget(rows[0]!);
    });
  }

  async remove(userId: string, id: string): Promise<boolean> {
    return withUserScope(this.pg, userId, async (client) => {
      const result = await client.query('DELETE FROM budgets WHERE user_id = $1 AND id = $2', [
        userId,
        id,
      ]);
      return (result.rowCount ?? 0) > 0;
    });
  }
}

// -------------------------------------------------------------------- goals

const GOAL_COLUMNS = 'id, name, target_amount, currency, target_date, created_at';
const CONTRIBUTION_COLUMNS = 'id, goal_id, amount, contributed_at';

export class PostgresGoalStore implements GoalStore {
  constructor(private readonly pg: Pool) {}

  async list(userId: string): Promise<SavingsGoal[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<GoalRow>(
        `SELECT ${GOAL_COLUMNS} FROM goals WHERE user_id = $1 ORDER BY created_at, id`,
        [userId],
      );
      return rows.map(toGoal);
    });
  }

  async get(userId: string, id: string): Promise<SavingsGoal | null> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<GoalRow>(
        `SELECT ${GOAL_COLUMNS} FROM goals WHERE user_id = $1 AND id = $2`,
        [userId, id],
      );
      return rows[0] ? toGoal(rows[0]) : null;
    });
  }

  async create(userId: string, goal: SavingsGoal): Promise<SavingsGoal> {
    return withUserScope(this.pg, userId, async (client) => {
      await ensureUser(client, userId);
      const { rows } = await client.query<GoalRow>(
        `INSERT INTO goals
           (id, user_id, name, target_amount, currency, target_date, created_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         RETURNING ${GOAL_COLUMNS}`,
        [
          goal.id,
          userId,
          goal.name,
          goal.targetAmount,
          goal.currency,
          goal.targetDate,
          goal.createdAt,
        ],
      );
      return toGoal(rows[0]!);
    });
  }

  async remove(userId: string, id: string): Promise<boolean> {
    return withUserScope(this.pg, userId, async (client) => {
      const result = await client.query('DELETE FROM goals WHERE user_id = $1 AND id = $2', [
        userId,
        id,
      ]);
      return (result.rowCount ?? 0) > 0;
    });
  }

  async listContributions(userId: string, goalId: string): Promise<GoalContribution[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<GoalContributionRow>(
        `SELECT ${CONTRIBUTION_COLUMNS} FROM goal_contributions
         WHERE user_id = $1 AND goal_id = $2 ORDER BY contributed_at, id`,
        [userId, goalId],
      );
      return rows.map(toGoalContribution);
    });
  }

  async addContribution(
    userId: string,
    contribution: GoalContribution,
  ): Promise<GoalContribution> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<GoalContributionRow>(
        `INSERT INTO goal_contributions (id, user_id, goal_id, amount, contributed_at)
         VALUES ($1, $2, $3, $4, $5)
         RETURNING ${CONTRIBUTION_COLUMNS}`,
        [
          contribution.id,
          userId,
          contribution.goalId,
          contribution.amount,
          contribution.contributedAt,
        ],
      );
      return toGoalContribution(rows[0]!);
    });
  }
}

// ------------------------------------------------------------ notifications

const NOTIFICATION_COLUMNS =
  'id, kind, title, message, severity, dedupe_key, read_at, created_at';
const PREFERENCE_COLUMNS =
  'budget, bills, credit_utilization, subscriptions, low_balance, unusual_transactions, bank_sync, security';

export class PostgresNotificationStore implements NotificationStore {
  constructor(private readonly pg: Pool) {}

  async list(userId: string): Promise<UserNotification[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<NotificationRow>(
        `SELECT ${NOTIFICATION_COLUMNS} FROM notifications
         WHERE user_id = $1 ORDER BY created_at DESC, id DESC LIMIT 200`,
        [userId],
      );
      return rows.map(toNotification);
    });
  }

  async upsert(userId: string, notification: UserNotification): Promise<boolean> {
    return withUserScope(this.pg, userId, async (client) => {
      await ensureUser(client, userId);
      const result = await client.query(
        `INSERT INTO notifications
           (id, user_id, kind, title, message, severity, dedupe_key, read_at, created_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
         ON CONFLICT (user_id, dedupe_key) DO NOTHING`,
        [
          notification.id,
          userId,
          notification.kind,
          notification.title,
          notification.message,
          notification.severity,
          notification.dedupeKey,
          notification.readAt,
          notification.createdAt,
        ],
      );
      return (result.rowCount ?? 0) > 0;
    });
  }

  async markRead(userId: string, id: string, at: string): Promise<boolean> {
    return withUserScope(this.pg, userId, async (client) => {
      const result = await client.query(
        `UPDATE notifications SET read_at = COALESCE(read_at, $3)
         WHERE user_id = $1 AND id = $2`,
        [userId, id, at],
      );
      return (result.rowCount ?? 0) > 0;
    });
  }

  async getPreferences(userId: string): Promise<NotificationPreferences> {
    return withUserScope(this.pg, userId, async (client) => {
      await ensureUser(client, userId);
      const { rows } = await client.query<NotificationPreferenceRow>(
        `INSERT INTO notification_preferences (user_id) VALUES ($1)
         ON CONFLICT (user_id) DO UPDATE SET user_id = EXCLUDED.user_id
         RETURNING ${PREFERENCE_COLUMNS}`,
        [userId],
      );
      return toNotificationPreferences(rows[0]!);
    });
  }

  async updatePreferences(
    userId: string,
    preferences: NotificationPreferences,
  ): Promise<NotificationPreferences> {
    return withUserScope(this.pg, userId, async (client) => {
      await ensureUser(client, userId);
      const { rows } = await client.query<NotificationPreferenceRow>(
        `INSERT INTO notification_preferences
           (user_id, budget, bills, credit_utilization, subscriptions, low_balance,
            unusual_transactions, bank_sync, security)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
         ON CONFLICT (user_id) DO UPDATE SET
           budget = EXCLUDED.budget,
           bills = EXCLUDED.bills,
           credit_utilization = EXCLUDED.credit_utilization,
           subscriptions = EXCLUDED.subscriptions,
           low_balance = EXCLUDED.low_balance,
           unusual_transactions = EXCLUDED.unusual_transactions,
           bank_sync = EXCLUDED.bank_sync,
           security = EXCLUDED.security,
           updated_at = now()
         RETURNING ${PREFERENCE_COLUMNS}`,
        [
          userId,
          preferences.budget,
          preferences.bills,
          preferences.creditUtilization,
          preferences.subscriptions,
          preferences.lowBalance,
          preferences.unusualTransactions,
          preferences.bankSync,
          preferences.security,
        ],
      );
      return toNotificationPreferences(rows[0]!);
    });
  }
}

// ------------------------------------------------------------------- rules

const RULE_COLUMNS = 'id, match_type, pattern, category_slug, priority';

export class PostgresRuleStore implements RuleStore {
  constructor(private readonly pg: Pool) {}

  async list(userId: string): Promise<CategorizationRule[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<RuleRow>(
        `SELECT ${RULE_COLUMNS} FROM categorization_rules
         WHERE user_id = $1 ORDER BY priority, id`,
        [userId],
      );
      return rows.map(toRule);
    });
  }

  async create(userId: string, rule: CategorizationRule): Promise<CategorizationRule> {
    return withUserScope(this.pg, userId, async (client) => {
      await ensureUser(client, userId);

      const { rows } = await client.query<RuleRow>(
        `INSERT INTO categorization_rules (id, user_id, match_type, pattern, category_slug, priority)
         VALUES ($1, $2, $3, $4, $5, $6)
         ON CONFLICT (user_id, id) DO UPDATE SET
           match_type    = EXCLUDED.match_type,
           pattern       = EXCLUDED.pattern,
           category_slug = EXCLUDED.category_slug,
           priority      = EXCLUDED.priority
         RETURNING ${RULE_COLUMNS}`,
        [rule.id, userId, rule.matchType, rule.pattern, rule.categorySlug, rule.priority],
      );

      return toRule(rows[0]!);
    });
  }

  async remove(userId: string, id: string): Promise<boolean> {
    return withUserScope(this.pg, userId, async (client) => {
      const result = await client.query(
        'DELETE FROM categorization_rules WHERE user_id = $1 AND id = $2',
        [userId, id],
      );
      return (result.rowCount ?? 0) > 0;
    });
  }
}

// ------------------------------------------------------------------- splits

const SPLIT_GROUP_COLUMNS = 'id, name, currency, created_by, created_at, archived_at';
const SPLIT_MEMBER_COLUMNS = 'group_id, user_id, role, joined_at';
const SPLIT_EXPENSE_COLUMNS = `
  id, group_id, description, category, amount, currency,
  paid_by_user_id, split_method, date, created_at
`;
const SPLIT_PARTICIPANT_COLUMNS = 'expense_id, group_id, user_id, amount';
const SPLIT_SETTLEMENT_COLUMNS =
  'id, group_id, from_user_id, to_user_id, amount, currency, note, created_at';

interface SplitInvitationRow {
  id: string;
  group_id: string;
  invitee_user_id: string;
  invited_by_user_id: string | null;
  status: string;
  created_at: Date;
  decided_at: Date | null;
  context: { groupName?: string; currency?: string; invitedByEmail?: string | null } | null;
}

function toSplitInvitation(row: SplitInvitationRow): SplitGroupInvitation {
  return {
    id: row.id,
    groupId: row.group_id,
    inviteeUserId: row.invitee_user_id,
    invitedByUserId: row.invited_by_user_id,
    status: row.status as SplitGroupInvitation['status'],
    createdAt: row.created_at.toISOString(),
    decidedAt: row.decided_at?.toISOString() ?? null,
    groupName: row.context?.groupName,
    currency: row.context?.currency,
    invitedByEmail: row.context?.invitedByEmail ?? null,
  };
}

export class PostgresSplitStore implements SplitStore {
  constructor(private readonly pg: Pool) {}

  async listGroups(userId: string): Promise<SplitGroup[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<SplitGroupRow>(
        `SELECT g.id, g.name, g.currency, g.created_by, g.created_at, g.archived_at
           FROM split_groups g
           JOIN split_group_members m ON m.group_id = g.id
          WHERE m.user_id = $1 AND g.archived_at IS NULL
          ORDER BY g.created_at, g.id`,
        [userId],
      );
      return rows.map(toSplitGroup);
    });
  }

  async getGroup(userId: string, groupId: string): Promise<SplitGroup | null> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<SplitGroupRow>(
        `SELECT ${SPLIT_GROUP_COLUMNS} FROM split_groups
         WHERE id = $1 AND finverse_is_split_member(id)`,
        [groupId],
      );
      return rows[0] ? toSplitGroup(rows[0]) : null;
    });
  }

  async createGroup(
    userId: string,
    group: SplitGroup,
    membership: SplitGroupMember,
  ): Promise<SplitGroup> {
    return withUserScope(this.pg, userId, async (client) => {
      // No RETURNING here: on an RLS table, INSERT ... RETURNING re-checks the
      // row against the SELECT policy, which fails for a group whose membership
      // has not been inserted yet. The full object is already in hand.
      await client.query(
        `INSERT INTO split_groups (id, name, currency, created_by, created_at)
         VALUES ($1, $2, $3, $4, $5)`,
        [group.id, group.name, group.currency, userId, group.createdAt],
      );
      await client.query(
        `INSERT INTO split_group_members (group_id, user_id, role)
         VALUES ($1, $2, $3)`,
        [membership.groupId, membership.userId, membership.role],
      );
      return group;
    });
  }

  async archiveGroup(userId: string, groupId: string): Promise<boolean> {
    return withUserScope(this.pg, userId, async (client) => {
      const result = await client.query(
        `UPDATE split_groups SET archived_at = now()
         WHERE id = $1 AND archived_at IS NULL AND finverse_is_split_member(id)`,
        [groupId],
      );
      return (result.rowCount ?? 0) > 0;
    });
  }

  async listMembers(userId: string, groupId: string): Promise<SplitGroupMember[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<SplitMemberRow>(
        `SELECT ${SPLIT_MEMBER_COLUMNS} FROM split_group_members
         WHERE group_id = $1 ORDER BY joined_at, user_id`,
        [groupId],
      );
      return rows.map(toSplitMember);
    });
  }

  async createInvitation(userId: string, invitation: SplitGroupInvitation): Promise<SplitGroupInvitation> {
    return withUserScope(this.pg, userId, async (client) => {
      await client.query(
        `INSERT INTO split_group_invitations
           (id, group_id, invitee_user_id, invited_by_user_id, status, created_at)
         VALUES ($1, $2, $3, $4, 'pending', $5)
         `,
        [
          invitation.id,
          invitation.groupId,
          invitation.inviteeUserId,
          invitation.invitedByUserId,
          invitation.createdAt,
        ],
      );
      // Read after the insert so the narrow context function can see the
      // committed row through the caller's scoped transaction.
      const { rows } = await client.query<SplitInvitationRow>(
        `SELECT id, group_id, invitee_user_id, invited_by_user_id,
                status, created_at, decided_at,
                finverse_split_invitation_context(id) AS context
           FROM split_group_invitations WHERE id = $1`,
        [invitation.id],
      );
      return rows[0] ? toSplitInvitation(rows[0]) : invitation;
    });
  }

  async listInvitations(userId: string): Promise<SplitGroupInvitation[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<SplitInvitationRow>(
        `SELECT id, group_id, invitee_user_id, invited_by_user_id,
                status, created_at, decided_at,
                finverse_split_invitation_context(id) AS context
           FROM split_group_invitations
          WHERE invitee_user_id = $1 AND status = 'pending'
          ORDER BY created_at DESC, id DESC`,
        [userId],
      );
      return rows.map(toSplitInvitation);
    });
  }

  async listGroupInvitations(userId: string, groupId: string): Promise<SplitGroupInvitation[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<SplitInvitationRow>(
        `SELECT id, group_id, invitee_user_id, invited_by_user_id,
                status, created_at, decided_at,
                finverse_split_invitation_context(id) AS context
           FROM split_group_invitations
          WHERE group_id = $1
          ORDER BY created_at DESC, id DESC`,
        [groupId],
      );
      return rows.map(toSplitInvitation);
    });
  }

  async acceptInvitation(userId: string, invitationId: string): Promise<SplitGroupMember | null> {
    return withUserScope(this.pg, userId, async (client) => {
      // The database command locks the invitation and performs membership
      // creation plus state transition atomically. A revoke racing this call
      // has exactly one winner.
      const membership = await client.query<SplitMemberRow>(
        `SELECT group_id, user_id, role, joined_at
           FROM finverse_accept_split_invitation($1)`,
        [invitationId],
      );
      return membership.rows[0] ? toSplitMember(membership.rows[0]) : null;
    });
  }

  async declineInvitation(userId: string, invitationId: string): Promise<boolean> {
    return withUserScope(this.pg, userId, async (client) => {
      const result = await client.query(
        `UPDATE split_group_invitations
            SET status = 'declined', decided_at = now()
          WHERE id = $1 AND invitee_user_id = $2 AND status = 'pending'`,
        [invitationId, userId],
      );
      return (result.rowCount ?? 0) > 0;
    });
  }

  async revokeInvitation(userId: string, groupId: string, invitationId: string): Promise<boolean> {
    return withUserScope(this.pg, userId, async (client) => {
      const result = await client.query(
        `UPDATE split_group_invitations
            SET status = 'revoked', decided_at = now()
          WHERE id = $1 AND group_id = $2 AND status = 'pending'`,
        [invitationId, groupId],
      );
      return (result.rowCount ?? 0) > 0;
    });
  }

  async removeMember(
    userId: string,
    groupId: string,
    targetUserId: string,
  ): Promise<'removed' | 'not_found' | 'creator' | 'balance_nonzero' | 'forbidden'> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<{ result: string }>(
        `SELECT result FROM finverse_remove_split_member($1, $2)`,
        [groupId, targetUserId],
      );
      const result = rows[0]?.result;
      if (result === 'removed' || result === 'not_found' || result === 'creator' || result === 'balance_nonzero' || result === 'forbidden') {
        return result;
      }
      return 'not_found';
    });
  }

  async listExpenses(userId: string, groupId: string): Promise<SplitExpense[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<SplitExpenseRow>(
        `SELECT ${SPLIT_EXPENSE_COLUMNS} FROM split_expenses
         WHERE group_id = $1 ORDER BY date DESC, id DESC`,
        [groupId],
      );
      const participants = await client.query<SplitParticipantRow>(
        `SELECT ${SPLIT_PARTICIPANT_COLUMNS} FROM split_expense_participants
         WHERE group_id = $1`,
        [groupId],
      );
      const byExpense = new Map<string, typeof participants.rows>();
      for (const row of participants.rows) {
        const list = byExpense.get(row.expense_id) ?? [];
        list.push(row);
        byExpense.set(row.expense_id, list);
      }
      return rows.map((row) =>
        toSplitExpense(row, (byExpense.get(row.id) ?? []).map(toSplitParticipant)),
      );
    });
  }

  async addExpense(userId: string, expense: SplitExpense): Promise<SplitExpense> {
    return withUserScope(this.pg, userId, async (client) => {
      await client.query(
        `INSERT INTO split_expenses
           (id, group_id, description, category, amount, currency,
            paid_by_user_id, split_method, date)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
        [
          expense.id,
          expense.groupId,
          expense.description,
          expense.category,
          expense.amount,
          expense.currency,
          expense.paidByUserId,
          expense.splitMethod,
          expense.date,
        ],
      );
      for (const participant of expense.participants) {
        await client.query(
          `INSERT INTO split_expense_participants (expense_id, group_id, user_id, amount)
           VALUES ($1, $2, $3, $4)`,
          [expense.id, expense.groupId, participant.userId, participant.amount],
        );
      }
      return expense;
    });
  }

  async listSettlements(userId: string, groupId: string): Promise<SplitSettlement[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<SplitSettlementRow>(
        `SELECT ${SPLIT_SETTLEMENT_COLUMNS} FROM split_settlements
         WHERE group_id = $1 ORDER BY created_at DESC, id DESC`,
        [groupId],
      );
      return rows.map(toSplitSettlement);
    });
  }

  async addSettlement(
    userId: string,
    settlement: SplitSettlement,
  ): Promise<SplitSettlement> {
    return withUserScope(this.pg, userId, async (client) => {
      await client.query(
        `INSERT INTO split_settlements
           (id, group_id, from_user_id, to_user_id, amount, currency, note)
         VALUES ($1, $2, $3, $4, $5, $6, $7)`,
        [
          settlement.id,
          settlement.groupId,
          settlement.fromUserId,
          settlement.toUserId,
          settlement.amount,
          settlement.currency,
          settlement.note || null,
        ],
      );
      return settlement;
    });
  }
}

// -------------------------------------------------------- reconciliations

interface ReconciliationRow {
  id: string;
  account_id: string;
  statement_date: string;
  observed_balance: number;
  currency: string;
  computed_balance: number;
  difference: number;
  source: string;
  note: string | null;
  created_at: Date;
  archived_at: Date | null;
}

const RECONCILIATION_COLUMNS = `
  id, account_id, statement_date, observed_balance, currency,
  computed_balance, difference, source, note, created_at, archived_at
`;

function toReconciliation(row: ReconciliationRow): Reconciliation {
  return {
    id: row.id,
    accountId: row.account_id,
    // `statement_date` is a DATE, returned as a YYYY-MM-DD string by the
    // parser registered in pool.ts. Left as a string on purpose.
    statementDate: row.statement_date,
    observedBalance: row.observed_balance,
    currency: row.currency,
    computedBalance: row.computed_balance,
    difference: row.difference,
    source: row.source as Reconciliation['source'],
    note: row.note,
    createdAt: row.created_at.toISOString(),
    archivedAt: row.archived_at ? row.archived_at.toISOString() : null,
  };
}

export class PostgresReconciliationStore implements ReconciliationStore {
  constructor(private readonly pg: Pool) {}

  async list(userId: string, accountId?: string): Promise<Reconciliation[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<ReconciliationRow>(
        `SELECT ${RECONCILIATION_COLUMNS} FROM account_reconciliations
         WHERE user_id = $1 AND ($2::text IS NULL OR account_id = $2)
         ORDER BY statement_date DESC, created_at DESC`,
        [userId, accountId ?? null],
      );
      return rows.map(toReconciliation);
    });
  }

  async get(userId: string, id: string): Promise<Reconciliation | null> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<ReconciliationRow>(
        `SELECT ${RECONCILIATION_COLUMNS} FROM account_reconciliations
         WHERE user_id = $1 AND id = $2`,
        [userId, id],
      );
      return rows[0] ? toReconciliation(rows[0]) : null;
    });
  }

  async create(userId: string, reconciliation: Reconciliation): Promise<Reconciliation> {
    return withUserScope(this.pg, userId, async (client) => {
      await ensureUser(client, userId);

      // Supersede rather than conflict. The partial unique index only covers
      // live rows, so archiving the previous assertion for this closing date
      // both keeps the history and frees the index for the new one. Doing it in
      // the same transaction means there is never a moment with two live rows.
      await client.query(
        `UPDATE account_reconciliations
         SET archived_at = $4
         WHERE user_id = $1 AND account_id = $2 AND statement_date = $3
           AND archived_at IS NULL`,
        [userId, reconciliation.accountId, reconciliation.statementDate, reconciliation.createdAt],
      );

      const { rows } = await client.query<ReconciliationRow>(
        `INSERT INTO account_reconciliations (
           id, user_id, account_id, statement_date, observed_balance, currency,
           computed_balance, difference, source, note, created_at, archived_at
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
         RETURNING ${RECONCILIATION_COLUMNS}`,
        [
          reconciliation.id,
          userId,
          reconciliation.accountId,
          reconciliation.statementDate,
          reconciliation.observedBalance,
          reconciliation.currency,
          reconciliation.computedBalance,
          reconciliation.difference,
          reconciliation.source,
          reconciliation.note,
          reconciliation.createdAt,
          reconciliation.archivedAt,
        ],
      );

      return toReconciliation(rows[0]!);
    });
  }

  async archive(userId: string, id: string, at: string): Promise<boolean> {
    return withUserScope(this.pg, userId, async (client) => {
      const result = await client.query(
        `UPDATE account_reconciliations SET archived_at = $3
         WHERE user_id = $1 AND id = $2 AND archived_at IS NULL`,
        [userId, id, at],
      );
      return (result.rowCount ?? 0) > 0;
    });
  }
}

// ------------------------------------------------------------ saved views

interface SavedViewRow {
  id: string;
  name: string;
  search: string | null;
  category_slug: string | null;
  category_kind: string | null;
  account_id: string | null;
  tag: string | null;
  date_from: string | null;
  date_to: string | null;
  amount_min: number | null;
  amount_max: number | null;
  pending: boolean | null;
  recurring: boolean | null;
  created_at: Date;
}

const SAVED_VIEW_COLUMNS = `
  id, name, search, category_slug, category_kind, account_id, tag,
  date_from, date_to, amount_min, amount_max, pending, recurring, created_at
`;

function toSavedView(row: SavedViewRow): SavedView {
  // Null columns become absent keys rather than explicit undefined values, so a
  // saved view round-trips to exactly the filter object it was created from.
  const filter: Record<string, unknown> = {};
  if (row.search !== null) filter.search = row.search;
  if (row.category_slug !== null) filter.categorySlug = row.category_slug;
  if (row.category_kind !== null) filter.categoryKind = row.category_kind;
  if (row.account_id !== null) filter.accountId = row.account_id;
  if (row.tag !== null) filter.tag = row.tag;
  if (row.date_from !== null) filter.dateFrom = row.date_from;
  if (row.date_to !== null) filter.dateTo = row.date_to;
  if (row.amount_min !== null) filter.amountMin = row.amount_min;
  if (row.amount_max !== null) filter.amountMax = row.amount_max;
  if (row.pending !== null) filter.pending = row.pending;
  if (row.recurring !== null) filter.recurring = row.recurring;

  return {
    id: row.id,
    name: row.name,
    filter: filter as SavedView['filter'],
    createdAt: row.created_at.toISOString(),
  };
}

export class PostgresSavedViewStore implements SavedViewStore {
  constructor(private readonly pg: Pool) {}

  async list(userId: string): Promise<SavedView[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<SavedViewRow>(
        `SELECT ${SAVED_VIEW_COLUMNS} FROM saved_views
         WHERE user_id = $1 ORDER BY name`,
        [userId],
      );
      return rows.map(toSavedView);
    });
  }

  async get(userId: string, id: string): Promise<SavedView | null> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<SavedViewRow>(
        `SELECT ${SAVED_VIEW_COLUMNS} FROM saved_views WHERE user_id = $1 AND id = $2`,
        [userId, id],
      );
      return rows[0] ? toSavedView(rows[0]) : null;
    });
  }

  async create(userId: string, view: SavedView): Promise<SavedView> {
    return withUserScope(this.pg, userId, async (client) => {
      await ensureUser(client, userId);

      try {
        const { rows } = await client.query<SavedViewRow>(
          // `created_at` is written explicitly rather than left to the column
          // default. The service takes it from the injected clock, so letting
          // now() win here would make the adapter override a value the caller
          // deliberately supplied â€” and would be untestable under a fixed clock.
          `INSERT INTO saved_views (
             id, user_id, name, search, category_slug, category_kind, account_id,
             tag, date_from, date_to, amount_min, amount_max, pending, recurring,
             created_at
           ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
           RETURNING ${SAVED_VIEW_COLUMNS}`,
          [
            view.id,
            userId,
            view.name,
            view.filter.search ?? null,
            view.filter.categorySlug ?? null,
            view.filter.categoryKind ?? null,
            view.filter.accountId ?? null,
            view.filter.tag ?? null,
            view.filter.dateFrom ?? null,
            view.filter.dateTo ?? null,
            view.filter.amountMin ?? null,
            view.filter.amountMax ?? null,
            view.filter.pending ?? null,
            view.filter.recurring ?? null,
            view.createdAt,
          ],
        );
        return toSavedView(rows[0]!);
      } catch (error) {
        // The functional unique index is the arbiter. A read-then-write check
        // would let two concurrent requests both pass.
        if (
          typeof error === 'object' &&
          error !== null &&
          'code' in error &&
          (error as { code?: string }).code === '23505'
        ) {
          throw new DuplicateViewNameError(view.name);
        }
        throw error;
      }
    });
  }

  async remove(userId: string, id: string): Promise<boolean> {
    return withUserScope(this.pg, userId, async (client) => {
      const result = await client.query(
        'DELETE FROM saved_views WHERE user_id = $1 AND id = $2',
        [userId, id],
      );
      return (result.rowCount ?? 0) > 0;
    });
  }
}

// -------------------------------------------------------- import batches

interface ImportBatchRow {
  id: string;
  account_id: string;
  statement_import_id: string | null;
  filename: string;
  status: string;
  rows_total: number;
  rows_imported: number;
  rows_duplicate: number;
  rows_invalid: number;
  created_at: Date;
  reverted_at: Date | null;
}

const IMPORT_BATCH_COLUMNS = `
  id, account_id, statement_import_id, filename, status, rows_total, rows_imported,
  rows_duplicate, rows_invalid, created_at, reverted_at
`;

function toImportBatch(row: ImportBatchRow): ImportBatch {
  return {
    id: row.id,
    accountId: row.account_id,
    ...(row.statement_import_id ? { statementImportId: row.statement_import_id } : {}),
    filename: row.filename,
    status: row.status as ImportBatch['status'],
    rowsTotal: row.rows_total,
    rowsImported: row.rows_imported,
    rowsDuplicate: row.rows_duplicate,
    rowsInvalid: row.rows_invalid,
    createdAt: row.created_at.toISOString(),
    revertedAt: row.reverted_at ? row.reverted_at.toISOString() : null,
  };
}

export class PostgresImportBatchStore implements ImportBatchStore {
  constructor(private readonly pg: Pool) {}

  async list(userId: string): Promise<ImportBatch[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<ImportBatchRow>(
        `SELECT ${IMPORT_BATCH_COLUMNS} FROM import_batches
         WHERE user_id = $1 ORDER BY created_at DESC`,
        [userId],
      );
      return rows.map(toImportBatch);
    });
  }

  async get(userId: string, id: string): Promise<ImportBatch | null> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<ImportBatchRow>(
        `SELECT ${IMPORT_BATCH_COLUMNS} FROM import_batches WHERE user_id = $1 AND id = $2`,
        [userId, id],
      );
      return rows[0] ? toImportBatch(rows[0]) : null;
    });
  }

  /**
   * Batch row and transactions in one transaction.
   *
   * withUserScope already opens one, so a failure partway through inserting
   * rolls back the batch record too. A committed batch that names transactions
   * which were never inserted would offer a revert that removes nothing.
   */
  async commit(
    userId: string,
    batch: ImportBatch,
    transactions: readonly Transaction[],
  ): Promise<ImportBatch> {
    return withUserScope(this.pg, userId, async (client) => {
      await ensureUser(client, userId);

      const { rows } = await client.query<ImportBatchRow>(
        `INSERT INTO import_batches (
           id, user_id, account_id, statement_import_id, filename, status,
           rows_total, rows_imported, rows_duplicate, rows_invalid, created_at
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
         RETURNING ${IMPORT_BATCH_COLUMNS}`,
        [
          batch.id,
          userId,
          batch.accountId,
          batch.statementImportId ?? null,
          batch.filename,
          batch.status,
          batch.rowsTotal,
          batch.rowsImported,
          batch.rowsDuplicate,
          batch.rowsInvalid,
          batch.createdAt,
        ],
      );

      for (const chunked of chunk(transactions, 500)) {
        const values: unknown[] = [];
        const tuples: string[] = [];

        chunked.forEach((txn, index) => {
          tuples.push(placeholders(12, index));
          values.push(
            txn.id,
            userId,
            txn.accountId,
            txn.providerTxnId,
            txn.postedAt,
            txn.amount,
            txn.currency,
            txn.rawDescriptor,
            txn.normalizedDescriptor,
            txn.categorySlug,
            txn.categoryConfidence,
            batch.id,
          );
        });

        // ON CONFLICT DO NOTHING rather than an upsert: the review step already
        // decided these are new. If one collides anyway, the existing row is
        // authoritative and must not be overwritten by a file.
        await client.query(
          `INSERT INTO transactions (
             id, user_id, account_id, provider_txn_id, posted_at, amount, currency,
             raw_descriptor, normalized_descriptor, category_slug, category_confidence,
             import_batch_id
           ) VALUES ${tuples.join(', ')}
           ON CONFLICT (user_id, account_id, provider_txn_id) DO NOTHING`,
          values,
        );
      }

      return toImportBatch(rows[0]!);
    });
  }

  async revert(userId: string, id: string, at: string): Promise<number | null> {
    return withUserScope(this.pg, userId, async (client) => {
      // Marking first, conditionally, makes the undo idempotent: a second
      // request updates no row and returns null rather than reporting a
      // removal that never happened.
      const marked = await client.query(
        `UPDATE import_batches SET status = 'reverted', reverted_at = $3
         WHERE user_id = $1 AND id = $2 AND status = 'committed'`,
        [userId, id, at],
      );

      if ((marked.rowCount ?? 0) === 0) return null;

      const removed = await client.query(
        'DELETE FROM transactions WHERE user_id = $1 AND import_batch_id = $2',
        [userId, id],
      );

      return removed.rowCount ?? 0;
    });
  }
}

// --------------------------------------------------- scheduled transactions

interface ScheduleRow {
  id: string;
  account_id: string;
  name: string;
  amount: number;
  currency: string;
  category_slug: string;
  cadence: string;
  start_date: string;
  end_date: string | null;
  reminder_days: number;
  archived_at: Date | null;
}

const SCHEDULE_COLUMNS = `
  id, account_id, name, amount, currency, category_slug,
  cadence, start_date, end_date, reminder_days, archived_at
`;

function toSchedule(row: ScheduleRow): ScheduledTransaction {
  return {
    id: row.id,
    accountId: row.account_id,
    name: row.name,
    amount: row.amount,
    currency: row.currency,
    categorySlug: row.category_slug,
    cadence: row.cadence as ScheduledTransaction['cadence'],
    // DATE columns come back as YYYY-MM-DD strings; see the parser in pool.ts.
    startDate: row.start_date,
    endDate: row.end_date,
    reminderDays: row.reminder_days,
    archivedAt: row.archived_at ? row.archived_at.toISOString() : null,
  };
}

export class PostgresScheduleStore implements ScheduleStore {
  constructor(private readonly pg: Pool) {}

  async list(userId: string, includeArchived = false): Promise<ScheduledTransaction[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<ScheduleRow>(
        `SELECT ${SCHEDULE_COLUMNS} FROM scheduled_transactions
         WHERE user_id = $1 AND ($2::boolean OR archived_at IS NULL)
         ORDER BY start_date, name`,
        [userId, includeArchived],
      );
      return rows.map(toSchedule);
    });
  }

  async get(userId: string, id: string): Promise<ScheduledTransaction | null> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<ScheduleRow>(
        `SELECT ${SCHEDULE_COLUMNS} FROM scheduled_transactions
         WHERE user_id = $1 AND id = $2`,
        [userId, id],
      );
      return rows[0] ? toSchedule(rows[0]) : null;
    });
  }

  async create(
    userId: string,
    schedule: ScheduledTransaction,
  ): Promise<ScheduledTransaction> {
    return withUserScope(this.pg, userId, async (client) => {
      await ensureUser(client, userId);

      const { rows } = await client.query<ScheduleRow>(
        `INSERT INTO scheduled_transactions (
           id, user_id, account_id, name, amount, currency, category_slug,
           cadence, start_date, end_date, reminder_days, archived_at
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
         RETURNING ${SCHEDULE_COLUMNS}`,
        [
          schedule.id,
          userId,
          schedule.accountId,
          schedule.name,
          schedule.amount,
          schedule.currency,
          schedule.categorySlug,
          schedule.cadence,
          schedule.startDate,
          schedule.endDate,
          schedule.reminderDays,
          schedule.archivedAt,
        ],
      );

      return toSchedule(rows[0]!);
    });
  }

  async update(
    userId: string,
    id: string,
    patch: Partial<ScheduledTransaction>,
  ): Promise<ScheduledTransaction | null> {
    const COLUMN_OF: Partial<Record<keyof ScheduledTransaction, string>> = {
      name: 'name',
      amount: 'amount',
      currency: 'currency',
      categorySlug: 'category_slug',
      cadence: 'cadence',
      startDate: 'start_date',
      endDate: 'end_date',
      reminderDays: 'reminder_days',
    };

    const assignments: string[] = [];
    const values: unknown[] = [userId, id];

    for (const [key, column] of Object.entries(COLUMN_OF)) {
      if (!(key in patch)) continue;
      values.push(patch[key as keyof ScheduledTransaction] ?? null);
      assignments.push(`${column} = $${values.length}`);
    }

    if (assignments.length === 0) return this.get(userId, id);

    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<ScheduleRow>(
        `UPDATE scheduled_transactions SET ${assignments.join(', ')}
         WHERE user_id = $1 AND id = $2
         RETURNING ${SCHEDULE_COLUMNS}`,
        values,
      );
      return rows[0] ? toSchedule(rows[0]) : null;
    });
  }

  async archive(userId: string, id: string, at: string): Promise<boolean> {
    return withUserScope(this.pg, userId, async (client) => {
      const result = await client.query(
        `UPDATE scheduled_transactions SET archived_at = $3
         WHERE user_id = $1 AND id = $2 AND archived_at IS NULL`,
        [userId, id, at],
      );
      return (result.rowCount ?? 0) > 0;
    });
  }
}

// ------------------------------------------------------ rule applications

interface RuleApplicationRow {
  id: string;
  pattern: string;
  match_type: string;
  category_slug: string;
  rows_changed: number;
  created_at: Date;
  reverted_at: Date | null;
}

const RULE_APPLICATION_COLUMNS = `
  id, pattern, match_type, category_slug, rows_changed, created_at, reverted_at
`;

function toRuleApplication(row: RuleApplicationRow): RuleApplication {
  return {
    id: row.id,
    pattern: row.pattern,
    matchType: row.match_type as RuleApplication['matchType'],
    categorySlug: row.category_slug,
    rowsChanged: row.rows_changed,
    createdAt: row.created_at.toISOString(),
    revertedAt: row.reverted_at ? row.reverted_at.toISOString() : null,
  };
}

export class PostgresRuleApplicationStore implements RuleApplicationStore {
  constructor(private readonly pg: Pool) {}

  async list(userId: string): Promise<RuleApplication[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<RuleApplicationRow>(
        `SELECT ${RULE_APPLICATION_COLUMNS} FROM rule_applications
         WHERE user_id = $1 ORDER BY created_at DESC`,
        [userId],
      );
      return rows.map(toRuleApplication);
    });
  }

  /**
   * Records the before-state and applies the change in one transaction.
   *
   * withUserScope already opens one, so a failure partway through rolls back
   * both. An application recorded without its changes, or changes without the
   * record, would leave an undo that restores the wrong thing.
   */
  async apply(
    userId: string,
    application: RuleApplication,
    changes: readonly RuleApplicationChange[],
  ): Promise<RuleApplication> {
    return withUserScope(this.pg, userId, async (client) => {
      await ensureUser(client, userId);

      const { rows } = await client.query<RuleApplicationRow>(
        `INSERT INTO rule_applications (
           id, user_id, pattern, match_type, category_slug, rows_changed, created_at
         ) VALUES ($1, $2, $3, $4, $5, $6, $7)
         RETURNING ${RULE_APPLICATION_COLUMNS}`,
        [
          application.id,
          userId,
          application.pattern,
          application.matchType,
          application.categorySlug,
          application.rowsChanged,
          application.createdAt,
        ],
      );

      for (const chunked of chunk(changes, 500)) {
        const values: unknown[] = [];
        const tuples: string[] = [];

        chunked.forEach((change, index) => {
          tuples.push(placeholders(6, index));
          values.push(
            application.id,
            userId,
            change.transactionId,
            change.previousCategorySlug,
            change.previousCategorySource,
            change.previousConfidence,
          );
        });

        await client.query(
          `INSERT INTO rule_application_changes (
             application_id, user_id, transaction_id,
             previous_category_slug, previous_category_source, previous_confidence
           ) VALUES ${tuples.join(', ')}`,
          values,
        );

        const ids = chunked.map((c) => c.transactionId);
        await client.query(
          `UPDATE transactions
           SET category_slug = $3, category_source = 'user_rule',
               category_confidence = 1, updated_at = now()
           WHERE user_id = $1 AND id = ANY($2::text[])`,
          [userId, ids, application.categorySlug],
        );
      }

      return toRuleApplication(rows[0]!);
    });
  }

  async revert(userId: string, id: string, at: string): Promise<number | null> {
    return withUserScope(this.pg, userId, async (client) => {
      // Mark first, conditionally, so a second revert changes nothing and
      // reports null rather than claiming a restoration that never happened.
      const marked = await client.query(
        `UPDATE rule_applications SET reverted_at = $3
         WHERE user_id = $1 AND id = $2 AND reverted_at IS NULL`,
        [userId, id, at],
      );

      if ((marked.rowCount ?? 0) === 0) return null;

      // One statement restores every row from its recorded before-state. Rows
      // deleted since the apply are gone from the change table by cascade, so
      // they cannot be counted as restored.
      const restored = await client.query(
        `UPDATE transactions AS t
         SET category_slug = c.previous_category_slug,
             category_source = c.previous_category_source,
             category_confidence = c.previous_confidence,
             updated_at = now()
         FROM rule_application_changes AS c
         WHERE c.user_id = $1 AND c.application_id = $2
           AND t.user_id = c.user_id AND t.id = c.transaction_id`,
        [userId, id],
      );

      return restored.rowCount ?? 0;
    });
  }
}

// ------------------------------------------------------------- fx rates

interface FxRateRow {
  id: string;
  base: string;
  quote: string;
  rate: number;
  as_of: string;
  source: string;
  note: string | null;
  created_at: Date;
}

const FX_RATE_COLUMNS = `id, base, quote, rate, as_of, source, note, created_at`;

function toFxRate(row: FxRateRow): FxRate {
  return {
    id: row.id,
    base: row.base,
    quote: row.quote,
    rate: row.rate,
    // DATE comes back as YYYY-MM-DD; see the parser in pool.ts.
    asOf: row.as_of,
    source: row.source as FxRate['source'],
    note: row.note,
    createdAt: row.created_at.toISOString(),
  };
}

export class PostgresFxRateStore implements FxRateStore {
  constructor(private readonly pg: Pool) {}

  async list(userId: string): Promise<FxRate[]> {
    return withUserScope(this.pg, userId, async (client) => {
      const { rows } = await client.query<FxRateRow>(
        `SELECT ${FX_RATE_COLUMNS} FROM fx_rates
         WHERE user_id = $1 ORDER BY as_of DESC, base`,
        [userId],
      );
      return rows.map(toFxRate);
    });
  }

  async upsert(userId: string, rate: FxRate): Promise<FxRate> {
    return withUserScope(this.pg, userId, async (client) => {
      await ensureUser(client, userId);

      // A second rate for the same pair and day is a correction, not a second
      // truth. Keeping both would make the lookup depend on insertion order.
      const { rows } = await client.query<FxRateRow>(
        `INSERT INTO fx_rates (id, user_id, base, quote, rate, as_of, source, note, created_at)
         VALUES ($1, $2, upper($3), upper($4), $5, $6, $7, $8, $9)
         ON CONFLICT (user_id, base, quote, as_of) DO UPDATE SET
           rate   = EXCLUDED.rate,
           source = EXCLUDED.source,
           note   = EXCLUDED.note
         RETURNING ${FX_RATE_COLUMNS}`,
        [
          rate.id,
          userId,
          rate.base,
          rate.quote,
          rate.rate,
          rate.asOf,
          rate.source,
          rate.note,
          rate.createdAt,
        ],
      );

      return toFxRate(rows[0]!);
    });
  }

  async remove(userId: string, id: string): Promise<boolean> {
    return withUserScope(this.pg, userId, async (client) => {
      const result = await client.query('DELETE FROM fx_rates WHERE user_id = $1 AND id = $2', [
        userId,
        id,
      ]);
      return (result.rowCount ?? 0) > 0;
    });
  }
}
