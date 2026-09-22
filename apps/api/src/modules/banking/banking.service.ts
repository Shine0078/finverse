import { createHash, randomUUID } from 'node:crypto';
import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Inject,
  Injectable,
  Logger,
  NotFoundException,
  ServiceUnavailableException,
  type OnModuleDestroy,
  type OnModuleInit,
} from '@nestjs/common';

import { categorizeDescriptor, type ModelClassifier } from '../../domain/categorization/categorize';
import { UserCorrectionClassifier } from '../../domain/categorization/user-correction-classifier';
import { normalizeDescriptor } from '../../domain/categorization/normalize';
import { detectSubscriptions } from '../../domain/insights/subscriptions';
import { FinanceEventBus } from '../../infra/events/finance-event-bus';
import {
  detectInternalTransfers,
  internalTransferIds,
  isUserCategorised,
} from '../../domain/transactions/internal-transfers';
import type { RawTransaction, Transaction, UserNotification } from '../../domain/types';
import {
  ACCOUNT_STORE,
  CLOCK,
  NOTIFICATION_STORE,
  RULE_STORE,
  TRANSACTION_STORE,
  type AccountStore,
  type ClockPort,
  type NotificationStore,
  type RuleStore,
  type TransactionStore,
} from '../../ports';
import {
  BANK_LINK_STORE,
  BANK_PROVIDER,
  BANK_TOKEN_CIPHER,
  BANK_WEBHOOK_STORE,
  type BankLink,
  type BankLinkStore,
  type BankProvider,
  type BankTokenCipher,
  type BankWebhookStore,
  type LinkPlatform,
} from '../../ports/banking';
import { BillingService } from '../billing/billing.service';
import { NotificationsService } from '../notifications/notifications.service';

@Injectable()
export class BankingService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(BankingService.name);
  private webhookTimer?: NodeJS.Timeout;
  private drainingWebhooks = false;
  private stopping = false;

  constructor(
    @Inject(BANK_LINK_STORE) private readonly links: BankLinkStore,
    @Inject(BANK_PROVIDER) private readonly provider: BankProvider,
    @Inject(BANK_TOKEN_CIPHER) private readonly cipher: BankTokenCipher,
    @Inject(BANK_WEBHOOK_STORE) private readonly webhooks: BankWebhookStore,
    @Inject(ACCOUNT_STORE) private readonly accounts: AccountStore,
    @Inject(TRANSACTION_STORE) private readonly transactions: TransactionStore,
    @Inject(RULE_STORE) private readonly rules: RuleStore,
    @Inject(NOTIFICATION_STORE) private readonly notifications: NotificationStore,
    @Inject(CLOCK) private readonly clock: ClockPort,
    private readonly billing: BillingService,
    private readonly notificationAlerts?: NotificationsService,
    private readonly events?: FinanceEventBus,
  ) {}

  onModuleInit(): void {
    this.stopping = false;
    this.webhookTimer = setInterval(() => void this.drainWebhookQueue(), 30_000);
    this.webhookTimer.unref();
    void this.drainWebhookQueue();
  }

  onModuleDestroy(): void {
    this.stopping = true;
    if (this.webhookTimer) clearInterval(this.webhookTimer);
  }

  list(userId: string): Promise<BankLink[]> {
    return this.links.list(userId);
  }

  async createLinkToken(userId: string, linkId?: string, platform: LinkPlatform = 'android') {
    this.requireConfigured();
    let accessToken: string | undefined;
    if (linkId) {
      const link = await this.links.get(userId, linkId);
      if (!link) throw new NotFoundException('Bank connection not found.');
      // A link revoked during account deletion no longer has a valid provider
      // Item. Reusing it in Plaid update mode would send a known-dead token and
      // leave a recovered account with no way to reconnect. Start a fresh Link
      // flow for revoked rows; healthy and needs_reauth rows still use update
      // mode so the provider can preserve the existing Item where possible.
      if (link.status !== 'revoked') {
        accessToken = this.cipher.decrypt(link.encryptedAccessToken);
      }
    }
    try {
      return await this.provider.createLinkToken(userId, accessToken, platform);
    } catch (error) {
      throw this.providerFailure(error, 'Could not start the bank connection.', platform);
    }
  }

  async exchange(
    userId: string,
    publicToken: string,
    institutionName: string,
    institutionId: string | null,
  ): Promise<BankLink> {
    this.requireConfigured();
    if (!publicToken || publicToken.length > 500) throw new BadRequestException('Invalid public token.');

    // Checked *before* the exchange, deliberately. Exchanging first would
    // create a live Plaid Item that we then refuse to store — an orphan that
    // keeps pulling data we have no record of and no way to revoke.
    const connected = (await this.links.list(userId)).filter((link) => link.status !== 'revoked');
    if ((await this.billing.remainingBankLinks(userId, connected.length)) <= 0) {
      throw new ForbiddenException({
        error: 'plan_upgrade_required',
        message: `Your plan allows ${connected.length} connected institution(s).`,
        entitlement: 'unlimited_bank_links',
        requiredPlan: 'pro',
      });
    }

    let exchanged: Awaited<ReturnType<BankProvider['exchangePublicToken']>>;
    try {
      exchanged = await this.provider.exchangePublicToken(publicToken);
    } catch (error) {
      throw this.providerFailure(error, 'That bank connection could not be completed.');
    }
    const now = this.clock.now().toISOString();
    const link = await this.links.create(userId, {
      id: randomUUID(),
      provider: 'plaid',
      providerItemId: exchanged.itemId,
      institutionId,
      institutionName: institutionName.trim().slice(0, 160) || 'Connected institution',
      encryptedAccessToken: this.cipher.encrypt(exchanged.accessToken),
      cursor: null,
      status: 'healthy',
      errorCode: null,
      lastSyncedAt: null,
      createdAt: now,
    });
    try {
      await this.sync(userId, link.id);
    } catch {
      // The Item and encrypted token are already durable. Returning the
      // connection lets the client show its recoverable state instead of
      // encouraging a second Link flow and an orphaned Plaid Item.
      this.logger.warn('Initial Plaid synchronization failed; connection retained for retry.');
    }
    this.events?.publish({
      type: 'AccountConnected',
      userId,
      at: this.clock.now().toISOString(),
      linkId: link.id,
    });
    return (await this.links.get(userId, link.id))!;
  }

  /**
   * Re-categorises detected internal transfers so they stop being counted as
   * income and spending.
   *
   * Considers a recent window rather than the whole ledger: transfers pair
   * within days, and re-examining years of history on every sync would grow
   * without bound for no benefit.
   *
   * A transaction the user has categorised themselves is never touched. Their
   * correction is the most reliable signal in the system, and silently
   * overriding it is the one behaviour ADR-0004 exists to prevent.
   */
  private async reconcileInternalTransfers(userId: string): Promise<number> {
    const today = this.clock.today();
    const since = new Date(Date.parse(`${today}T00:00:00Z`) - 45 * 86_400_000)
      .toISOString()
      .slice(0, 10);

    const recent = await this.transactions.list(userId, {
      range: { start: since, end: today },
    });

    const pairs = detectInternalTransfers(recent);
    if (pairs.length === 0) return 0;

    const byId = new Map(recent.map((row) => [row.id, row]));
    let updated = 0;

    for (const id of internalTransferIds(pairs)) {
      const txn = byId.get(id);
      if (!txn || isUserCategorised(txn)) continue;
      if (txn.categorySlug === 'transfer') continue;

      await this.transactions.update(userId, id, {
        categorySlug: 'transfer',
        categorySource: 'transfer_pairing',
        categoryConfidence: 0.95,
      });
      updated += 1;
    }

    return updated;
  }

  async sync(userId: string, linkId: string) {
    this.requireConfigured();
    const existing = await this.links.get(userId, linkId);
    if (!existing) throw new NotFoundException('Bank connection not found.');
    const link = await this.links.startSync(userId, linkId);
    if (!link) throw new ConflictException('A synchronization is already in progress.');

    let cursor = link.cursor;
    let inserted = 0;
    let updated = 0;
    let removed = 0;
    let fetched = 0;
    let categorized = 0;
    try {
      const accessToken = this.cipher.decrypt(link.encryptedAccessToken);
      // Plaid's /transactions/sync response only includes accounts that have
      // transactions in that response. Reconcile the complete active account
      // list on every pull so quiet accounts appear immediately and balances
      // stay fresh even when there are no transaction deltas. This auxiliary
      // request is deliberately best-effort: a transient listing failure must
      // never block the durable transaction cursor from advancing.
      if (this.provider.listAccounts) {
        try {
          await this.accounts.upsertMany(userId, await this.provider.listAccounts(accessToken));
        } catch {
          this.logger.warn('Complete bank account listing unavailable; continuing transaction sync.');
        }
      }
      const [rules, historicalTransactions] = await Promise.all([
        this.rules.list(userId),
        this.transactions.list(userId),
      ]);
      // This learner is rebuilt per sync from durable explicit corrections.
      // It has no global model and never sends transaction text to a third
      // party. Rebuilding also means deletion automatically removes training
      // data without a second retention path to purge.
      const model = UserCorrectionClassifier.fromTransactions(historicalTransactions);
      const startingCursor = cursor;
      let mutationRetries = 0;
      for (let pageNumber = 0; pageNumber < 100; pageNumber += 1) {
        let page: Awaited<ReturnType<BankProvider['sync']>>;
        try {
          page = await this.provider.sync(accessToken, cursor);
        } catch (error) {
          if (
            plaidErrorCode(error) === 'TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION' &&
            mutationRetries < 3
          ) {
            // Plaid requires the entire pagination cycle to restart from the
            // cursor used on its first page. Prior upserts are idempotent.
            mutationRetries += 1;
            cursor = startingCursor;
            inserted = 0;
            updated = 0;
            removed = 0;
            fetched = 0;
            categorized = 0;
            pageNumber = -1;
            continue;
          }
          throw error;
        }
        await this.accounts.upsertMany(userId, page.accounts);
        const raw = [...page.added, ...page.modified];
        const mapped = raw.map((row) => this.mapTransaction(row, rules, model));
        categorized += mapped.filter((row) => row.categorySlug !== 'unknown').length;
        const result = await this.transactions.upsertMany(userId, mapped);
        inserted += result.inserted;
        updated += result.updated;
        removed += await this.transactions.removeByProviderIds(userId, page.removedProviderTxnIds);
        fetched += raw.length;
        cursor = page.nextCursor;
        if (!page.hasMore) break;
        if (pageNumber === 99) throw new Error('Plaid sync exceeded 100 pages.');
      }
      await this.links.update(userId, linkId, {
        cursor,
        status: 'healthy',
        errorCode: null,
        lastSyncedAt: this.clock.now().toISOString(),
      });

      // Runs after every page is in, not per page: the two sides of a transfer
      // routinely arrive in different pages, and often from different
      // institutions entirely.
      const transfers = await this.reconcileInternalTransfers(userId);
      const recurringDetected = await this.reconcileRecurring(userId);
      await this.accounts.recordNetWorthSnapshot(userId, this.clock.today());

      const result = {
        fetched,
        inserted,
        updated,
        removed,
        transfersDetected: transfers,
        recurringDetected,
        coverage: fetched === 0 ? 1 : categorized / fetched,
      };
      this.events?.publish({
        type: 'BankSyncCompleted',
        userId,
        at: this.clock.now().toISOString(),
        linkId,
        fetched: result.fetched,
        inserted: result.inserted,
        updated: result.updated,
        removed: result.removed,
      });
      if (result.inserted > 0) {
        this.events?.publish({
          type: 'TransactionImported',
          userId,
          at: this.clock.now().toISOString(),
          linkId,
          inserted: result.inserted,
        });
      }
      if (result.updated > 0 || result.removed > 0) {
        this.events?.publish({
          type: 'TransactionUpdated',
          userId,
          at: this.clock.now().toISOString(),
          linkId,
          updated: result.updated,
          removed: result.removed,
        });
      }
      return result;
    } catch (error) {
      const code = plaidErrorCode(error);
      await this.links.update(userId, linkId, {
        status: code === 'ITEM_LOGIN_REQUIRED' ? 'needs_reauth' : 'error',
        errorCode: code,
      });
      try {
        await this.notifySyncFailure(userId, link, code);
      } catch {
        this.logger.warn('Could not persist a bank-sync alert.');
      }
      throw new ServiceUnavailableException({ message: 'Bank synchronization failed.', code });
    }
  }

  /**
   * Recompute recurring flags after the complete incremental cycle is stored.
   *
   * Recurrence detection needs the whole history for a merchant, not one
   * provider page. Keeping this here (rather than in the mapper) also makes
   * webhook-driven syncs behave exactly like a manual refresh. The flags are
   * derived state: a later correction, exclusion, or removed transaction can
   * make a series stop qualifying, so stale `true` values are cleared too.
   */
  private async reconcileRecurring(userId: string): Promise<number> {
    const rows = await this.transactions.list(userId);
    const recurringIds = new Set(
      detectSubscriptions(rows).flatMap((subscription) => subscription.transactionIds),
    );
    let updated = 0;
    for (const transaction of rows) {
      if (transaction.recurringOverride !== undefined) continue;
      const shouldBeRecurring = recurringIds.has(transaction.id);
      if (transaction.isRecurring === shouldBeRecurring) continue;
      await this.transactions.update(userId, transaction.id, {
        isRecurring: shouldBeRecurring,
      });
      updated += 1;
    }
    return updated;
  }

  async acceptWebhook(rawBody: Buffer, signature: string) {
    this.requireConfigured();
    if (!(await this.provider.verifyWebhook(rawBody, signature))) {
      throw new ForbiddenException('Invalid Plaid webhook signature.');
    }

    let payload: unknown;
    try {
      payload = JSON.parse(rawBody.toString('utf8'));
    } catch {
      throw new BadRequestException('Invalid webhook JSON.');
    }
    const message = payload as Record<string, unknown>;
    const itemId = typeof message.item_id === 'string' ? message.item_id : null;
    const type = typeof message.webhook_type === 'string' ? message.webhook_type : null;
    const code = typeof message.webhook_code === 'string' ? message.webhook_code : null;

    // Acknowledge every valid Plaid webhook. Only transaction-sync availability
    // creates work; unsupported products must not become a retry storm.
    if (!itemId || type !== 'TRANSACTIONS' || code !== 'SYNC_UPDATES_AVAILABLE') {
      return { accepted: true, queued: false };
    }
    const owner = await this.links.getByProviderItemId(itemId);
    if (!owner) return { accepted: true, queued: false };

    const queued = await this.webhooks.enqueue({
      id: randomUUID(),
      userId: owner.userId,
      linkId: owner.link.id,
      bodyHash: createHash('sha256').update(rawBody).digest('hex'),
      attempts: 0,
      availableAt: this.clock.now().toISOString(),
    });
    if (queued) setImmediate(() => void this.drainWebhookQueue());
    return { accepted: true, queued };
  }

  async disconnect(userId: string, linkId: string): Promise<void> {
    this.requireConfigured();
    const link = await this.links.get(userId, linkId);
    if (!link) throw new NotFoundException('Bank connection not found.');
    try {
      await this.provider.removeItem(this.cipher.decrypt(link.encryptedAccessToken));
    } catch (error) {
      const code = plaidErrorCode(error);
      if (code !== 'ITEM_NOT_FOUND') {
        throw new ServiceUnavailableException({ message: 'Could not revoke bank access.', code });
      }
    }
    await this.webhooks.purgeLink(userId, linkId);
    await this.links.remove(userId, linkId);
    this.events?.publish({
      type: 'AccountDisconnected',
      userId,
      at: this.clock.now().toISOString(),
      linkId,
    });
  }

  async drainWebhookQueue(): Promise<void> {
    if (this.stopping || this.drainingWebhooks || !this.provider.configured) return;
    this.drainingWebhooks = true;
    try {
      const jobs = await this.webhooks.claim(10);
      for (const job of jobs) {
        try {
          await this.sync(job.userId, job.linkId);
          await this.webhooks.complete(job.userId, job.id);
        } catch {
          const terminal = job.attempts >= 5;
          const delayMs = Math.min(60 * 60_000, 30_000 * 2 ** Math.max(0, job.attempts - 1));
          const availableAt = new Date(this.clock.now().getTime() + delayMs).toISOString();
          await this.webhooks.retry(job.userId, job.id, availableAt, terminal);
          this.logger.warn(`Plaid webhook sync ${terminal ? 'failed' : 'will retry'} (attempt ${job.attempts}).`);
        }
      }
      if (jobs.length === 10 && !this.stopping) setImmediate(() => void this.drainWebhookQueue());
    } catch {
      this.logger.warn('Bank webhook queue is unavailable; pending work will be retried.');
    } finally {
      this.drainingWebhooks = false;
    }
  }

  private mapTransaction(
    raw: RawTransaction,
    rules: Awaited<ReturnType<RuleStore['list']>>,
    model: ModelClassifier,
  ): Transaction {
    const category = categorizeDescriptor(raw.descriptor, { rules, model });
    return {
      id: `txn_${raw.accountId}_${raw.providerTxnId}`,
      accountId: raw.accountId,
      providerTxnId: raw.providerTxnId,
      postedAt: raw.postedAt,
      amount: raw.amount,
      currency: raw.currency,
      rawDescriptor: raw.descriptor,
      normalizedDescriptor: normalizeDescriptor(raw.descriptor),
      merchant: category.merchant,
      categorySlug: category.categorySlug,
      categorySource: category.source,
      categoryConfidence: category.confidence,
      isRecurring: false,
      pending: raw.pending,
    };
  }

  private async notifySyncFailure(userId: string, link: BankLink, code: string): Promise<void> {
    const preferences = this.notificationAlerts
      ? await this.notificationAlerts.preferences(userId)
      : await this.notifications.getPreferences(userId);
    if (!preferences.bankSync) return;
    const reauth = code === 'ITEM_LOGIN_REQUIRED';
    const today = this.clock.today();
    const notification: UserNotification = {
      id: randomUUID(),
      kind: 'bank_sync',
      title: reauth ? 'Reconnect your bank' : 'Bank sync needs attention',
      message: reauth
        ? `${link.institutionName} needs you to sign in again before transactions can update.`
        : `${link.institutionName} could not update. FINVERSE will retry automatically.`,
      severity: reauth ? 'critical' : 'warning',
      dedupeKey: `bank-sync:${link.id}:${today}:${code}`,
      readAt: null,
      createdAt: this.clock.now().toISOString(),
    };
    if (this.notificationAlerts) {
      await this.notificationAlerts.create(userId, notification);
    } else {
      await this.notifications.upsert(userId, notification);
    }
  }

  private requireConfigured(): void {
    if (!this.provider.configured) {
      throw new ServiceUnavailableException('Plaid is not configured on this server.');
    }
  }

  /**
   * Provider SDK errors contain the request config, including authentication
   * headers. Never let one escape to Nest's generic exception logger: Axios
   * would print the Plaid secret alongside the stack trace. Keep only the
   * provider error code and return a safe, actionable message to the client.
   */
  private providerFailure(error: unknown, fallback: string, platform?: LinkPlatform): Error {
    const code = plaidErrorCode(error);
    this.logger.warn(`Plaid bank operation failed (${code}).`);

    if (code === 'INVALID_FIELD' || isIosRedirectConfigurationError(error)) {
      const message = platform === 'android'
        ? 'Android bank connection setup is incomplete. Save com.finverse.finance under Plaid Dashboard > Developers > API > Allowed Android package names, then try again.'
        : platform === 'ios'
          ? 'iOS bank connection setup is incomplete. Set PLAID_IOS_REDIRECT_URI to a registered Universal Link, then try again.'
          : 'Bank connection setup is incomplete on this server.';
      return new ServiceUnavailableException({
        message,
        code: 'PLAID_CONFIGURATION',
      });
    }
    if (code === 'INVALID_PUBLIC_TOKEN') {
      return new BadRequestException(
        'That bank connection session is invalid or expired. Start again.',
      );
    }
    if (code === 'ITEM_LOGIN_REQUIRED') {
      return new ServiceUnavailableException({
        message: 'This bank connection needs you to sign in again.',
        code,
      });
    }
    return new ServiceUnavailableException({ message: fallback, code });
  }
}

function isIosRedirectConfigurationError(error: unknown): boolean {
  return error instanceof Error && error.message.startsWith('PLAID_IOS_REDIRECT_URI');
}

function plaidErrorCode(error: unknown): string {
  const response = (error as { response?: { data?: { error_code?: unknown } } }).response;
  const code = response?.data?.error_code;
  return typeof code === 'string' ? code : 'PROVIDER_ERROR';
}
