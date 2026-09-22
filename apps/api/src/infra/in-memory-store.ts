/**
 * In-memory implementations of the store ports.
 *
 * These are not a toy: they are the reference implementation that defines the
 * contract Postgres must satisfy, and they are what lets the vertical slice run
 * and be tested without a database (ADR-0002).
 *
 * Data is per-user-keyed exactly as the Postgres adapter will be, so a missing
 * user scope shows up here rather than in production.
 */

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
} from '../domain/types';
import { isWithin } from '../domain/dates';
import { getCategory } from '../domain/categories';
import type {
  SplitExpense,
  SplitGroupInvitation,
  SplitGroup,
  SplitGroupMember,
  SplitSettlement,
} from '../domain/split/types';
import type { Reconciliation } from '../domain/reconciliation/types';
import { normalizeViewName, type SavedView } from '../domain/transactions/saved-view';
import type { ScheduledTransaction } from '../domain/scheduled/schedule';
import type { FxRate } from '../domain/fx/rates';
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
} from '../ports';

function bucket<T>(map: Map<string, T[]>, userId: string): T[] {
  const existing = map.get(userId);
  if (existing) return existing;
  const fresh: T[] = [];
  map.set(userId, fresh);
  return fresh;
}

export class InMemoryAccountStore implements AccountStore {
  private readonly byUser = new Map<string, Account[]>();
  private readonly snapshotsByUser = new Map<string, NetWorthSnapshot[]>();

  async list(userId: string): Promise<Account[]> {
    return [...bucket(this.byUser, userId)];
  }

  async get(userId: string, accountId: string): Promise<Account | null> {
    return bucket(this.byUser, userId).find((a) => a.id === accountId) ?? null;
  }

  async upsertMany(userId: string, accounts: readonly Account[]): Promise<void> {
    const rows = bucket(this.byUser, userId);
    for (const account of accounts) {
      const index = rows.findIndex((a) => a.id === account.id);
      if (index >= 0) rows[index] = account;
      else rows.push(account);
    }
  }

  async remove(userId: string, accountId: string): Promise<boolean> {
    const rows = bucket(this.byUser, userId);
    const index = rows.findIndex((account) => account.id === accountId);
    if (index < 0) return false;
    rows.splice(index, 1);
    return true;
  }

  async recordNetWorthSnapshot(
    userId: string,
    recordedOn: string,
  ): Promise<NetWorthSnapshot[]> {
    const totals = netWorthByCurrency(bucket(this.byUser, userId), recordedOn);
    const history = bucket(this.snapshotsByUser, userId);
    for (let index = history.length - 1; index >= 0; index -= 1) {
      const row = history[index];
      if (row?.recordedOn === recordedOn) history.splice(index, 1);
    }
    history.push(...totals);
    history.sort(
      (a, b) => a.recordedOn.localeCompare(b.recordedOn) || a.currency.localeCompare(b.currency),
    );
    return totals;
  }

  async listNetWorthHistory(userId: string, limit = 365): Promise<NetWorthSnapshot[]> {
    const history = [...bucket(this.snapshotsByUser, userId)];
    return history.slice(Math.max(0, history.length - limit));
  }

  purgeUser(userId: string): void {
    this.byUser.delete(userId);
    this.snapshotsByUser.delete(userId);
  }
}

function netWorthByCurrency(
  accounts: readonly Account[],
  recordedOn: string,
): NetWorthSnapshot[] {
  const totals = new Map<string, { assets: number; debts: number }>();
  for (const account of accounts) {
    const currency = account.currency.toUpperCase();
    const current = totals.get(currency) ?? { assets: 0, debts: 0 };
    if (account.balanceCurrent >= 0) current.assets += account.balanceCurrent;
    else current.debts += Math.abs(account.balanceCurrent);
    totals.set(currency, current);
  }
  return [...totals.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([currency, total]) => ({
      recordedOn,
      currency,
      assets: total.assets,
      debts: total.debts,
      netPosition: total.assets - total.debts,
    }));
}

export class InMemoryTransactionStore implements TransactionStore {
  async insertIfAbsent(userId: string, transaction: Transaction): Promise<{ transaction: Transaction; inserted: boolean }> {
    const rows = bucket(this.byUser, userId);
    const existing = rows.find(row => row.id === transaction.id);
    if (existing) return { transaction: existing, inserted: false };
    rows.push({ ...transaction });
    return { transaction: { ...transaction }, inserted: true };
  }

  private readonly byUser = new Map<string, Transaction[]>();

  async list(userId: string, query: TransactionQuery = {}): Promise<Transaction[]> {
    let rows = [...bucket(this.byUser, userId)];

    if (query.accountId) rows = rows.filter((t) => t.accountId === query.accountId);
    if (query.categorySlug) rows = rows.filter((t) => t.categorySlug === query.categorySlug);
    if (query.categoryKind) {
      rows = rows.filter((t) => getCategory(t.categorySlug)?.kind === query.categoryKind);
    }
    if (query.range) {
      const range = query.range;
      rows = rows.filter((t) => isWithin(t.postedAt, range));
    }
    if (query.before) {
      const { postedAt, id } = query.before;
      rows = rows.filter(
        (t) => t.postedAt < postedAt || (t.postedAt === postedAt && t.id < id),
      );
    }
    if (query.search) {
      const needle = query.search.toLowerCase();
      rows = rows.filter(
        (t) =>
          t.normalizedDescriptor.includes(needle) ||
          t.rawDescriptor.toLowerCase().includes(needle) ||
          (t.merchant?.toLowerCase().includes(needle) ?? false) ||
          (t.merchantOverride?.toLowerCase().includes(needle) ?? false) ||
          (t.note?.toLowerCase().includes(needle) ?? false),
      );
    }
    if (query.pending !== undefined) rows = rows.filter((t) => t.pending === query.pending);
    if (query.recurring !== undefined) {
      rows = rows.filter((t) => t.isRecurring === query.recurring);
    }
    if (query.amountMin !== undefined) {
      rows = rows.filter((t) => Math.abs(t.amount) >= query.amountMin!);
    }
    if (query.amountMax !== undefined) {
      rows = rows.filter((t) => Math.abs(t.amount) <= query.amountMax!);
    }
    if (query.tag) {
      const wanted = query.tag.trim().toLowerCase();
      rows = rows.filter((t) => t.tags?.some((tag) => tag === wanted) ?? false);
    }

    rows.sort((a, b) => b.postedAt.localeCompare(a.postedAt) || b.id.localeCompare(a.id));
    return query.limit ? rows.slice(0, query.limit) : rows;
  }

  async get(userId: string, id: string): Promise<Transaction | null> {
    return bucket(this.byUser, userId).find((t) => t.id === id) ?? null;
  }

  /** Idempotent on (accountId, providerTxnId) â€” mirrors the unique index. */
  async upsertMany(
    userId: string,
    transactions: readonly Transaction[],
  ): Promise<{ inserted: number; updated: number }> {
    const rows = bucket(this.byUser, userId);
    let inserted = 0;
    let updated = 0;

    for (const txn of transactions) {
      const index = rows.findIndex(
        (t) => t.accountId === txn.accountId && t.providerTxnId === txn.providerTxnId,
      );
      if (index >= 0) {
        // Preserve a manual category across re-sync. The aggregator resending a
        // transaction must never silently undo a user's correction.
        const existing = rows[index]!;
        const keepsUserCategory =
          existing.categorySource === 'user_manual' || existing.categorySource === 'user_rule';
        rows[index] = keepsUserCategory
          ? {
              ...txn,
              id: existing.id,
              merchantOverride: existing.merchantOverride,
              note: existing.note,
              excludedFromAnalytics: existing.excludedFromAnalytics,
              categorySlug: existing.categorySlug,
              categorySource: existing.categorySource,
              categoryConfidence: existing.categoryConfidence,
              recurringOverride: existing.recurringOverride,
              duplicateReported: existing.duplicateReported,
              tags: existing.tags,
              isRecurring: existing.recurringOverride ?? txn.isRecurring,
            }
          : {
              ...txn,
              id: existing.id,
              recurringOverride: existing.recurringOverride,
              duplicateReported: existing.duplicateReported,
              tags: existing.tags,
              isRecurring: existing.recurringOverride ?? txn.isRecurring,
            };
        updated += 1;
      } else {
        rows.push(txn);
        inserted += 1;
      }
    }

    return { inserted, updated };
  }

  async update(
    userId: string,
    id: string,
    patch: Partial<Transaction>,
  ): Promise<Transaction | null> {
    const rows = bucket(this.byUser, userId);
    const index = rows.findIndex((t) => t.id === id);
    if (index < 0) return null;
    const next = { ...rows[index]!, ...patch, id };
    rows[index] = next;
    return next;
  }

  async removeByProviderIds(userId: string, providerTxnIds: readonly string[]): Promise<number> {
    if (providerTxnIds.length === 0) return 0;
    const ids = new Set(providerTxnIds);
    const rows = bucket(this.byUser, userId);
    let removed = 0;
    for (let index = rows.length - 1; index >= 0; index -= 1) {
      if (!ids.has(rows[index]!.providerTxnId)) continue;
      rows.splice(index, 1);
      removed += 1;
    }
    return removed;
  }

  async removeByImportBatch(userId: string, importBatchId: string): Promise<number> {
    const rows = bucket(this.byUser, userId);
    let removed = 0;
    for (let index = rows.length - 1; index >= 0; index -= 1) {
      // Only rows carrying this batch id. A provider-synced transaction has
      // none, so an undo can never reach one.
      if (rows[index]!.importBatchId !== importBatchId) continue;
      rows.splice(index, 1);
      removed += 1;
    }
    return removed;
  }

  purgeUser(userId: string): void {
    this.byUser.delete(userId);
  }
}

export class InMemoryBudgetStore implements BudgetStore {
  private readonly byUser = new Map<string, Budget[]>();

  async list(userId: string): Promise<Budget[]> {
    return [...bucket(this.byUser, userId)];
  }

  async get(userId: string, id: string): Promise<Budget | null> {
    return bucket(this.byUser, userId).find((b) => b.id === id) ?? null;
  }

  async create(userId: string, budget: Budget): Promise<Budget> {
    const rows = bucket(this.byUser, userId);
    const index = rows.findIndex((b) => b.id === budget.id);
    if (index >= 0) rows[index] = budget;
    else rows.push(budget);
    return budget;
  }

  async remove(userId: string, id: string): Promise<boolean> {
    const rows = bucket(this.byUser, userId);
    const index = rows.findIndex((b) => b.id === id);
    if (index < 0) return false;
    rows.splice(index, 1);
    return true;
  }

  purgeUser(userId: string): void {
    this.byUser.delete(userId);
  }
}

export class InMemoryGoalStore implements GoalStore {
  private readonly goals = new Map<string, SavingsGoal[]>();
  private readonly contributions = new Map<string, GoalContribution[]>();

  async list(userId: string): Promise<SavingsGoal[]> {
    return [...bucket(this.goals, userId)].sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }

  async get(userId: string, id: string): Promise<SavingsGoal | null> {
    return bucket(this.goals, userId).find((goal) => goal.id === id) ?? null;
  }

  async create(userId: string, goal: SavingsGoal): Promise<SavingsGoal> {
    const rows = bucket(this.goals, userId);
    const index = rows.findIndex((candidate) => candidate.id === goal.id);
    if (index >= 0) rows[index] = goal;
    else rows.push(goal);
    return goal;
  }

  async remove(userId: string, id: string): Promise<boolean> {
    const rows = bucket(this.goals, userId);
    const index = rows.findIndex((goal) => goal.id === id);
    if (index < 0) return false;
    rows.splice(index, 1);
    const contributionRows = bucket(this.contributions, userId);
    for (let i = contributionRows.length - 1; i >= 0; i -= 1) {
      if (contributionRows[i]?.goalId === id) contributionRows.splice(i, 1);
    }
    return true;
  }

  async listContributions(userId: string, goalId: string): Promise<GoalContribution[]> {
    return bucket(this.contributions, userId)
      .filter((row) => row.goalId === goalId)
      .sort((a, b) => a.contributedAt.localeCompare(b.contributedAt) || a.id.localeCompare(b.id));
  }

  async addContribution(
    userId: string,
    contribution: GoalContribution,
  ): Promise<GoalContribution> {
    if (!(await this.get(userId, contribution.goalId))) throw new Error('Goal does not exist.');
    bucket(this.contributions, userId).push(contribution);
    return contribution;
  }

  purgeUser(userId: string): void {
    this.goals.delete(userId);
    this.contributions.delete(userId);
  }
}

export const DEFAULT_NOTIFICATION_PREFERENCES: NotificationPreferences = {
  budget: true,
  bills: true,
  creditUtilization: true,
  subscriptions: true,
  lowBalance: true,
  unusualTransactions: true,
  bankSync: true,
  security: true,
};

export class InMemoryNotificationStore implements NotificationStore {
  private readonly rows = new Map<string, UserNotification[]>();
  private readonly preferences = new Map<string, NotificationPreferences>();

  async list(userId: string): Promise<UserNotification[]> {
    return [...bucket(this.rows, userId)].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  }

  async upsert(userId: string, notification: UserNotification): Promise<boolean> {
    const rows = bucket(this.rows, userId);
    if (rows.some((row) => row.dedupeKey === notification.dedupeKey)) return false;
    rows.push(notification);
    return true;
  }

  async markRead(userId: string, id: string, at: string): Promise<boolean> {
    const row = bucket(this.rows, userId).find((candidate) => candidate.id === id);
    if (!row) return false;
    row.readAt ??= at;
    return true;
  }

  async getPreferences(userId: string): Promise<NotificationPreferences> {
    return { ...(this.preferences.get(userId) ?? DEFAULT_NOTIFICATION_PREFERENCES) };
  }

  async updatePreferences(
    userId: string,
    preferences: NotificationPreferences,
  ): Promise<NotificationPreferences> {
    this.preferences.set(userId, { ...preferences });
    return { ...preferences };
  }

  purgeUser(userId: string): void {
    this.rows.delete(userId);
    this.preferences.delete(userId);
  }
}

export class InMemoryRuleStore implements RuleStore {
  private readonly byUser = new Map<string, CategorizationRule[]>();

  /** Priority order, ties broken by id â€” the same ordering the Postgres
   *  adapter's index gives. Returning insertion order here would make rule
   *  precedence depend on which store happened to be running. */
  async list(userId: string): Promise<CategorizationRule[]> {
    return [...bucket(this.byUser, userId)].sort(
      (a, b) => a.priority - b.priority || a.id.localeCompare(b.id),
    );
  }

  async create(userId: string, rule: CategorizationRule): Promise<CategorizationRule> {
    const rows = bucket(this.byUser, userId);
    const index = rows.findIndex((r) => r.id === rule.id);
    if (index >= 0) rows[index] = rule;
    else rows.push(rule);
    return rule;
  }

  async remove(userId: string, id: string): Promise<boolean> {
    const rows = bucket(this.byUser, userId);
    const index = rows.findIndex((r) => r.id === id);
    if (index < 0) return false;
    rows.splice(index, 1);
    return true;
  }

  purgeUser(userId: string): void {
    this.byUser.delete(userId);
  }
}

// ------------------------------------------------------------------- splits

export class InMemorySplitStore implements SplitStore {
  private readonly groups = new Map<string, SplitGroup>();
  private readonly members = new Map<string, SplitGroupMember[]>();
  private readonly expenses = new Map<string, SplitExpense[]>();
  private readonly settlements = new Map<string, SplitSettlement[]>();
  private readonly invitations = new Map<string, SplitGroupInvitation>();

  private memberIds(groupId: string): string[] {
    return (this.members.get(groupId) ?? []).map((m) => m.userId);
  }

  async listGroups(userId: string): Promise<SplitGroup[]> {
    return [...this.groups.values()]
      .filter((group) => !group.archivedAt && this.memberIds(group.id).includes(userId))
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id));
  }

  async getGroup(userId: string, groupId: string): Promise<SplitGroup | null> {
    const group = this.groups.get(groupId);
    if (!group || !this.memberIds(groupId).includes(userId)) return null;
    return group;
  }

  async createGroup(
    userId: string,
    group: SplitGroup,
    membership: SplitGroupMember,
  ): Promise<SplitGroup> {
    this.groups.set(group.id, group);
    this.members.set(group.id, [membership]);
    return group;
  }

  async archiveGroup(userId: string, groupId: string): Promise<boolean> {
    const group = await this.getGroup(userId, groupId);
    if (!group || group.archivedAt) return false;
    group.archivedAt = new Date().toISOString();
    return true;
  }

  async listMembers(userId: string, groupId: string): Promise<SplitGroupMember[]> {
    if (!(await this.getGroup(userId, groupId))) return [];
    return [...(this.members.get(groupId) ?? [])].sort((a, b) =>
      a.joinedAt.localeCompare(b.joinedAt) || a.userId.localeCompare(b.userId),
    );
  }

  async createInvitation(userId: string, invitation: SplitGroupInvitation): Promise<SplitGroupInvitation> {
    const group = await this.getGroup(userId, invitation.groupId);
    if (!group || group.archivedAt) throw new Error('Not an active member of this group.');
    const admin = (this.members.get(invitation.groupId) ?? []).some(
      (member) => member.userId === userId && member.role === 'admin',
    );
    if (!admin) throw new Error('Only a group administrator can invite members.');
    if ((this.members.get(invitation.groupId) ?? []).some((member) => member.userId === invitation.inviteeUserId)) {
      throw new Error('Unable to add that account.');
    }
    if ([...this.invitations.values()].some((existing) =>
      existing.groupId === invitation.groupId &&
      existing.inviteeUserId === invitation.inviteeUserId &&
      existing.status === 'pending')) {
      throw new Error('An invitation is already pending.');
    }
    this.invitations.set(invitation.id, { ...invitation });
    return { ...invitation };
  }

  async listInvitations(userId: string): Promise<SplitGroupInvitation[]> {
    return [...this.invitations.values()]
      .filter((invitation) => invitation.inviteeUserId === userId && invitation.status === 'pending')
      .map((invitation) => ({ ...invitation }));
  }

  async listGroupInvitations(userId: string, groupId: string): Promise<SplitGroupInvitation[]> {
    const group = await this.getGroup(userId, groupId);
    const admin = (this.members.get(groupId) ?? []).some(
      (member) => member.userId === userId && member.role === 'admin',
    );
    if (!group || !admin) return [];
    return [...this.invitations.values()]
      .filter((invitation) => invitation.groupId === groupId)
      .map((invitation) => ({ ...invitation }));
  }

  async acceptInvitation(userId: string, invitationId: string): Promise<SplitGroupMember | null> {
    const invitation = this.invitations.get(invitationId);
    if (!invitation || invitation.inviteeUserId !== userId || invitation.status !== 'pending') return null;
    const group = this.groups.get(invitation.groupId);
    if (!group || group.archivedAt) return null;
    const membership: SplitGroupMember = {
      groupId: invitation.groupId,
      userId,
      role: 'member',
      joinedAt: new Date().toISOString(),
    };
    const rows = this.members.get(invitation.groupId) ?? [];
    if (!rows.some((member) => member.userId === userId)) rows.push(membership);
    this.members.set(invitation.groupId, rows);
    invitation.status = 'accepted';
    invitation.decidedAt = new Date().toISOString();
    return { ...membership };
  }

  async declineInvitation(userId: string, invitationId: string): Promise<boolean> {
    const invitation = this.invitations.get(invitationId);
    if (!invitation || invitation.inviteeUserId !== userId || invitation.status !== 'pending') return false;
    invitation.status = 'declined';
    invitation.decidedAt = new Date().toISOString();
    return true;
  }

  async revokeInvitation(userId: string, groupId: string, invitationId: string): Promise<boolean> {
    const invitation = this.invitations.get(invitationId);
    const group = await this.getGroup(userId, groupId);
    const admin = (this.members.get(groupId) ?? []).some(
      (member) => member.userId === userId && member.role === 'admin',
    );
    if (!group || !admin || !invitation || invitation.groupId !== groupId || invitation.status !== 'pending') return false;
    invitation.status = 'revoked';
    invitation.decidedAt = new Date().toISOString();
    return true;
  }

  async removeMember(
    userId: string,
    groupId: string,
    targetUserId: string,
  ): Promise<'removed' | 'not_found' | 'creator' | 'balance_nonzero' | 'forbidden'> {
    const group = await this.getGroup(userId, groupId);
    if (!group || group.archivedAt) return 'not_found';
    const members = this.members.get(groupId) ?? [];
    const actor = members.find((member) => member.userId === userId);
    const target = members.find((member) => member.userId === targetUserId);
    if (!target) return 'not_found';
    if (group.createdBy === targetUserId) return 'creator';
    if (userId !== targetUserId && actor?.role !== 'admin') return 'forbidden';

    let net = 0;
    for (const expense of this.expenses.get(groupId) ?? []) {
      if (expense.currency !== group.currency) continue;
      if (expense.paidByUserId === targetUserId) net += expense.amount;
      for (const participant of expense.participants) {
        if (participant.userId === targetUserId) net -= participant.amount;
      }
    }
    for (const settlement of this.settlements.get(groupId) ?? []) {
      if (settlement.currency !== group.currency) continue;
      if (settlement.fromUserId === targetUserId) net += settlement.amount;
      if (settlement.toUserId === targetUserId) net -= settlement.amount;
    }
    if (net !== 0) return 'balance_nonzero';

    this.members.set(groupId, members.filter((member) => member.userId !== targetUserId));
    for (const invitation of this.invitations.values()) {
      if (invitation.groupId === groupId && invitation.inviteeUserId === targetUserId && invitation.status === 'accepted') {
        invitation.status = userId === targetUserId ? 'left' : 'removed';
        invitation.decidedAt = new Date().toISOString();
      }
    }
    return 'removed';
  }

  async listExpenses(userId: string, groupId: string): Promise<SplitExpense[]> {
    if (!(await this.getGroup(userId, groupId))) return [];
    return [...(this.expenses.get(groupId) ?? [])].sort((a, b) =>
      b.date.localeCompare(a.date) || b.id.localeCompare(a.id),
    );
  }

  async addExpense(userId: string, expense: SplitExpense): Promise<SplitExpense> {
    if (!(await this.getGroup(userId, expense.groupId))) {
      throw new Error('Not a member of this group.');
    }
    const rows = this.expenses.get(expense.groupId) ?? [];
    rows.push(expense);
    this.expenses.set(expense.groupId, rows);
    return expense;
  }

  async listSettlements(userId: string, groupId: string): Promise<SplitSettlement[]> {
    if (!(await this.getGroup(userId, groupId))) return [];
    return [...(this.settlements.get(groupId) ?? [])].sort((a, b) =>
      b.createdAt.localeCompare(a.createdAt) || b.id.localeCompare(a.id),
    );
  }

  async addSettlement(
    userId: string,
    settlement: SplitSettlement,
  ): Promise<SplitSettlement> {
    if (!(await this.getGroup(userId, settlement.groupId))) {
      throw new Error('Not a member of this group.');
    }
    const rows = this.settlements.get(settlement.groupId) ?? [];
    rows.push(settlement);
    this.settlements.set(settlement.groupId, rows);
    return settlement;
  }

  purgeUser(userId: string): void {
    for (const [groupId, memberRows] of this.members) {
      this.members.set(groupId, memberRows.filter((m) => m.userId !== userId));
    }
    for (const [groupId, expenseRows] of this.expenses) {
      const kept: SplitExpense[] = [];
      for (const expense of expenseRows) {
        if (expense.paidByUserId === userId) continue;
        expense.participants = expense.participants.filter((p) => p.userId !== userId);
        kept.push(expense);
      }
      this.expenses.set(groupId, kept);
    }
    for (const [groupId, settlementRows] of this.settlements) {
      this.settlements.set(
        groupId,
        settlementRows.filter((s) => s.fromUserId !== userId && s.toUserId !== userId),
      );
    }
  }
}

/**
 * Balance assertions kept per user.
 *
 * Mirrors the partial unique index in 023: only a *live* assertion collides, so
 * archiving one frees its date to be asserted again.
 */
export class InMemoryReconciliationStore implements ReconciliationStore {
  private readonly byUser = new Map<string, Reconciliation[]>();

  private rows(userId: string): Reconciliation[] {
    const existing = this.byUser.get(userId);
    if (existing) return existing;
    const fresh: Reconciliation[] = [];
    this.byUser.set(userId, fresh);
    return fresh;
  }

  async list(userId: string, accountId?: string): Promise<Reconciliation[]> {
    return this.rows(userId)
      .filter((r) => (accountId ? r.accountId === accountId : true))
      .sort(
        (a, b) =>
          b.statementDate.localeCompare(a.statementDate) || b.createdAt.localeCompare(a.createdAt),
      )
      .map((r) => ({ ...r }));
  }

  async get(userId: string, id: string): Promise<Reconciliation | null> {
    const found = this.rows(userId).find((r) => r.id === id);
    return found ? { ...found } : null;
  }

  async create(userId: string, reconciliation: Reconciliation): Promise<Reconciliation> {
    const rows = this.rows(userId);

    // A second observation of the same closing date is a correction, not a
    // second fact. Archive the previous one so history keeps both, but only the
    // newest is live.
    const superseded = rows.findIndex(
      (r) =>
        r.accountId === reconciliation.accountId &&
        r.statementDate === reconciliation.statementDate &&
        r.archivedAt === null,
    );
    if (superseded >= 0) {
      rows[superseded] = { ...rows[superseded]!, archivedAt: reconciliation.createdAt };
    }

    rows.push({ ...reconciliation });
    return { ...reconciliation };
  }

  async archive(userId: string, id: string, at: string): Promise<boolean> {
    const rows = this.rows(userId);
    const index = rows.findIndex((r) => r.id === id && r.archivedAt === null);
    if (index < 0) return false;
    rows[index] = { ...rows[index]!, archivedAt: at };
    return true;
  }
}

/**
 * Named transaction filters.
 *
 * Name uniqueness is case-insensitive, matching the functional unique index in
 * 024 â€” otherwise a user could hold "Coffee" and "coffee" in memory but not in
 * PostgreSQL, and the contract suite would be the only thing to notice.
 */
export class InMemorySavedViewStore implements SavedViewStore {
  private readonly byUser = new Map<string, SavedView[]>();

  async list(userId: string): Promise<SavedView[]> {
    return [...bucket(this.byUser, userId)]
      .sort((a, b) => a.name.localeCompare(b.name))
      .map((v) => ({ ...v, filter: { ...v.filter } }));
  }

  async get(userId: string, id: string): Promise<SavedView | null> {
    const found = bucket(this.byUser, userId).find((v) => v.id === id);
    return found ? { ...found, filter: { ...found.filter } } : null;
  }

  async create(userId: string, view: SavedView): Promise<SavedView> {
    const rows = bucket(this.byUser, userId);
    const wanted = normalizeViewName(view.name).toLowerCase();

    if (rows.some((v) => normalizeViewName(v.name).toLowerCase() === wanted)) {
      throw new DuplicateViewNameError(view.name);
    }

    rows.push({ ...view, filter: { ...view.filter } });
    return { ...view, filter: { ...view.filter } };
  }

  async remove(userId: string, id: string): Promise<boolean> {
    const rows = bucket(this.byUser, userId);
    const index = rows.findIndex((v) => v.id === id);
    if (index < 0) return false;
    rows.splice(index, 1);
    return true;
  }
}

/**
 * Manual import batches.
 *
 * Holds its own reference to the transaction store because a revert has to
 * remove rows, and routing that through the ports keeps the in-memory adapter
 * honest about the same cascade PostgreSQL performs in one statement.
 */
export class InMemoryImportBatchStore implements ImportBatchStore {
  constructor(private readonly transactions: InMemoryTransactionStore) {}

  private readonly byUser = new Map<string, ImportBatch[]>();

  async list(userId: string): Promise<ImportBatch[]> {
    return [...bucket(this.byUser, userId)]
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
      .map((b) => ({ ...b }));
  }

  async get(userId: string, id: string): Promise<ImportBatch | null> {
    const found = bucket(this.byUser, userId).find((b) => b.id === id);
    return found ? { ...found } : null;
  }

  async commit(
    userId: string,
    batch: ImportBatch,
    transactions: readonly Transaction[],
  ): Promise<ImportBatch> {
    await this.transactions.upsertMany(userId, transactions);
    bucket(this.byUser, userId).push({ ...batch });
    return { ...batch };
  }

  async revert(userId: string, id: string, at: string): Promise<number | null> {
    const rows = bucket(this.byUser, userId);
    const index = rows.findIndex((b) => b.id === id);
    if (index < 0) return null;

    const batch = rows[index]!;
    // Already undone. Reverting twice would report a second removal that never
    // happened.
    if (batch.status === 'reverted') return null;

    const removed = await this.transactions.removeByImportBatch(userId, id);
    rows[index] = { ...batch, status: 'reverted', revertedAt: at };
    return removed;
  }
}

/** Declared obligations, archived rather than deleted. */
export class InMemoryScheduleStore implements ScheduleStore {
  private readonly byUser = new Map<string, ScheduledTransaction[]>();

  async list(userId: string, includeArchived = false): Promise<ScheduledTransaction[]> {
    return bucket(this.byUser, userId)
      .filter((s) => includeArchived || s.archivedAt === null)
      .sort((a, b) => a.startDate.localeCompare(b.startDate) || a.name.localeCompare(b.name))
      .map((s) => ({ ...s }));
  }

  async get(userId: string, id: string): Promise<ScheduledTransaction | null> {
    const found = bucket(this.byUser, userId).find((s) => s.id === id);
    return found ? { ...found } : null;
  }

  async create(
    userId: string,
    schedule: ScheduledTransaction,
  ): Promise<ScheduledTransaction> {
    bucket(this.byUser, userId).push({ ...schedule });
    return { ...schedule };
  }

  async update(
    userId: string,
    id: string,
    patch: Partial<ScheduledTransaction>,
  ): Promise<ScheduledTransaction | null> {
    const rows = bucket(this.byUser, userId);
    const index = rows.findIndex((s) => s.id === id);
    if (index < 0) return null;
    // `id` is never patchable: rewriting it would orphan anything referencing it.
    const next = { ...rows[index]!, ...patch, id };
    rows[index] = next;
    return { ...next };
  }

  async archive(userId: string, id: string, at: string): Promise<boolean> {
    const rows = bucket(this.byUser, userId);
    const index = rows.findIndex((s) => s.id === id && s.archivedAt === null);
    if (index < 0) return false;
    rows[index] = { ...rows[index]!, archivedAt: at };
    return true;
  }
}

/**
 * Bulk recategorizations and their undo.
 *
 * Holds the transaction store so a revert can restore prior categories through
 * the same port PostgreSQL uses, keeping both adapters honest about the effect.
 */
export class InMemoryRuleApplicationStore implements RuleApplicationStore {
  constructor(private readonly transactions: InMemoryTransactionStore) {}

  private readonly byUser = new Map<string, RuleApplication[]>();
  private readonly changesByApplication = new Map<string, RuleApplicationChange[]>();

  async list(userId: string): Promise<RuleApplication[]> {
    return [...bucket(this.byUser, userId)]
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
      .map((a) => ({ ...a }));
  }

  async apply(
    userId: string,
    application: RuleApplication,
    changes: readonly RuleApplicationChange[],
  ): Promise<RuleApplication> {
    for (const change of changes) {
      await this.transactions.update(userId, change.transactionId, {
        categorySlug: application.categorySlug,
        categorySource: 'user_rule',
        categoryConfidence: 1,
      });
    }

    bucket(this.byUser, userId).push({ ...application });
    this.changesByApplication.set(
      `${userId}:${application.id}`,
      changes.map((c) => ({ ...c })),
    );

    return { ...application };
  }

  async revert(userId: string, id: string, at: string): Promise<number | null> {
    const rows = bucket(this.byUser, userId);
    const index = rows.findIndex((a) => a.id === id);
    if (index < 0) return null;
    // Already undone; reverting twice would report a restoration that did not
    // happen.
    if (rows[index]!.revertedAt !== null) return null;

    const changes = this.changesByApplication.get(`${userId}:${id}`) ?? [];
    let restored = 0;

    for (const change of changes) {
      const updated = await this.transactions.update(userId, change.transactionId, {
        categorySlug: change.previousCategorySlug,
        categorySource: change.previousCategorySource,
        categoryConfidence: change.previousConfidence,
      });
      // A row deleted since the apply cannot be restored, and counting it would
      // overstate what the undo achieved.
      if (updated) restored += 1;
    }

    rows[index] = { ...rows[index]!, revertedAt: at };
    return restored;
  }
}

/** Exchange rates. One per pair per day, matching the unique index in 028. */
export class InMemoryFxRateStore implements FxRateStore {
  private readonly byUser = new Map<string, FxRate[]>();

  async list(userId: string): Promise<FxRate[]> {
    return [...bucket(this.byUser, userId)]
      .sort((a, b) => b.asOf.localeCompare(a.asOf) || a.base.localeCompare(b.base))
      .map((r) => ({ ...r }));
  }

  async upsert(userId: string, rate: FxRate): Promise<FxRate> {
    const rows = bucket(this.byUser, userId);
    const base = rate.base.toUpperCase();
    const quote = rate.quote.toUpperCase();

    // A second rate for the same pair and day is a correction, not a second
    // truth; leaving both would make the lookup depend on insertion order.
    const existing = rows.findIndex(
      (r) =>
        r.base.toUpperCase() === base &&
        r.quote.toUpperCase() === quote &&
        r.asOf === rate.asOf,
    );

    const stored = { ...rate, base, quote };
    if (existing >= 0) rows[existing] = { ...stored, id: rows[existing]!.id };
    else rows.push(stored);

    return { ...(existing >= 0 ? rows[existing]! : stored) };
  }

  async remove(userId: string, id: string): Promise<boolean> {
    const rows = bucket(this.byUser, userId);
    const index = rows.findIndex((r) => r.id === id);
    if (index < 0) return false;
    rows.splice(index, 1);
    return true;
  }
}
