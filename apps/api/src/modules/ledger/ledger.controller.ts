import { Body, Controller, Get, Header, Param, Patch, Post, Query } from '@nestjs/common';

import { BadRequestException, Delete, HttpCode } from '@nestjs/common';

import { loadConfig } from '../../config';
import { transactionsToCsv } from '../../domain/exports/transactions-csv';
import { exponentOf, formatMoney, money } from '../../domain/money';
import type { Transaction } from '../../domain/types';
import { CurrentUser } from '../auth/auth.guard';
import { LedgerService } from './ledger.service';

/** Adds a display string alongside the integer. The client never does money
 *  math on the formatted value â€” it is for rendering only (ADR-0003). */
function present(txn: Transaction) {
  return {
    ...txn,
    amountFormatted: formatMoney(money(txn.amount, txn.currency)),
  };
}

function presentAccount(account: Awaited<ReturnType<LedgerService['listAccounts']>>[number]) {
  return {
    ...account,
    source: account.source ?? 'provider',
    minorUnitExponent: exponentOf(account.currency),
    balanceFormatted: formatMoney(money(account.balanceCurrent, account.currency)),
    utilization:
      account.type === 'credit_card' && account.creditLimit
        ? Math.max(0, -account.balanceCurrent) / account.creditLimit
        : null,
  };
}

/**
 * Account kinds a user can enter by hand.
 *
 * `credit_card` belongs here even though it is the one type an aggregator
 * normally supplies: the whole credit-card surface — utilisation, the pay-down
 * target, the safe payment window — is useless to anyone who has not connected
 * a bank, and connecting a bank is gated on a commercial agreement. Leaving it
 * out meant "add your credit card" had no answer at all.
 */
const MANUAL_TYPES = new Set([
  'cash',
  'checking',
  'savings',
  'investment',
  'property',
  'loan',
  'credit_card',
]);

/** Balances that are money owed rather than money held. */
const LIABILITY_TYPES = new Set(['loan', 'credit_card']);

type ManualAccountBody = {
  name?: unknown;
  type?: unknown;
  currency?: unknown;
  balanceCurrent?: unknown;
  creditLimit?: unknown;
  statementDay?: unknown;
  paymentDueDay?: unknown;
};

/** Optional whole number in an inclusive range, or undefined. */
function optionalInt(
  value: unknown,
  field: string,
  min: number,
  max: number,
): number | undefined {
  if (value === undefined || value === null || value === '') return undefined;
  if (!Number.isSafeInteger(value) || (value as number) < min || (value as number) > max) {
    throw new BadRequestException(`${field} must be a whole number from ${min} through ${max}`);
  }
  return value as number;
}

function manualAccountDetails(body: ManualAccountBody) {
  const name = typeof body.name === 'string' ? body.name.trim() : '';
  const type = typeof body.type === 'string' ? body.type : '';
  const currency = typeof body.currency === 'string' ? body.currency.trim().toUpperCase() : '';
  const balance = body.balanceCurrent;
  if (name.length < 1 || name.length > 80) {
    throw new BadRequestException('name must be from 1 through 80 characters');
  }
  if (!MANUAL_TYPES.has(type)) {
    throw new BadRequestException(
      `type must be one of ${[...MANUAL_TYPES].join(', ')}`,
    );
  }
  if (!/^[A-Z]{3}$/.test(currency)) {
    throw new BadRequestException('currency must be a 3-letter ISO code');
  }
  if (!Number.isSafeInteger(balance) || Math.abs(balance as number) > 10_000_000_000_000) {
    throw new BadRequestException('balanceCurrent must be a safe minor-unit integer');
  }

  // Sign carries meaning throughout the domain: negative is money owed
  // (ADR-0003). A credit card entered as a positive balance would count as an
  // asset and inflate net position by twice the debt.
  const isLiability = LIABILITY_TYPES.has(type);
  if (isLiability && (balance as number) > 0) {
    throw new BadRequestException(
      `a ${type === 'loan' ? 'loan' : 'credit card'} balance must be zero or negative`,
    );
  }
  if (!isLiability && (balance as number) < 0) {
    throw new BadRequestException('an asset balance must be zero or positive');
  }

  const creditLimit = optionalInt(body.creditLimit, 'creditLimit', 0, 10_000_000_000_000);
  const statementDay = optionalInt(body.statementDay, 'statementDay', 1, 31);
  const paymentDueDay = optionalInt(body.paymentDueDay, 'paymentDueDay', 1, 31);

  if (type !== 'credit_card' && (creditLimit !== undefined || statementDay !== undefined || paymentDueDay !== undefined)) {
    throw new BadRequestException(
      'creditLimit, statementDay and paymentDueDay apply only to a credit_card',
    );
  }

  return {
    name,
    type: type as 'cash' | 'checking' | 'savings' | 'investment' | 'property' | 'loan' | 'credit_card',
    currency,
    balanceCurrent: balance as number,
    ...(creditLimit === undefined ? {} : { creditLimit }),
    ...(statementDay === undefined ? {} : { statementDay }),
    ...(paymentDueDay === undefined ? {} : { paymentDueDay }),
  };
}

@Controller()
export class LedgerController {
  constructor(private readonly ledger: LedgerService) {}

  @Post('sync')
  sync(@CurrentUser() userId: string) {
    const config = loadConfig();
    // The legacy route is deliberately retained for the in-memory demo and
    // its contract tests, but it must never be able to populate a persistent
    // user account with fabricated balances or transactions. Real Postgres
    // deployments use the provider-backed /bank-links/:id/sync flow only.
    if (config.isProduction || config.store !== 'memory') {
      throw new BadRequestException(
        'Development sample sync is disabled. Connect a bank account.',
      );
    }
    return this.ledger.sync(userId);
  }

  @Get('accounts')
  async accounts(@CurrentUser() userId: string) {
    const accounts = await this.ledger.listAccounts(userId);
    return accounts.map(presentAccount);
  }

  @Get('accounts/net-worth-history')
  async netWorthHistory(
    @CurrentUser() userId: string,
    @Query('currency') requestedCurrency?: string,
    @Query('limit') requestedLimit?: string,
  ) {
    const currency = requestedCurrency?.trim().toUpperCase();
    if (currency && !/^[A-Z]{3}$/.test(currency)) {
      throw new BadRequestException('currency must be a 3-letter ISO code');
    }
    const limit = requestedLimit === undefined ? 365 : Number(requestedLimit);
    if (!Number.isInteger(limit) || limit < 1 || limit > 730) {
      throw new BadRequestException('limit must be a whole number from 1 through 730');
    }
    const rows = await this.ledger.listNetWorthHistory(userId, limit);
    return rows
      .filter((row) => !currency || row.currency === currency)
      .map((row) => ({
        ...row,
        assetsFormatted: formatMoney(money(row.assets, row.currency)),
        debtsFormatted: formatMoney(money(row.debts, row.currency)),
        netPositionFormatted: formatMoney(money(row.netPosition, row.currency)),
      }));
  }

  @Post('accounts/manual')
  async createManualAccount(
    @CurrentUser() userId: string,
    @Body() body: ManualAccountBody,
  ) {
    return presentAccount(
      await this.ledger.createManualAccount(userId, manualAccountDetails(body)),
    );
  }

  @Patch('accounts/manual/:id')
  async updateManualAccount(
    @CurrentUser() userId: string,
    @Param('id') id: string,
    @Body() body: ManualAccountBody,
  ) {
    return presentAccount(
      await this.ledger.updateManualAccount(userId, id, manualAccountDetails(body)),
    );
  }

  @Delete('accounts/manual/:id')
  async removeManualAccount(
    @CurrentUser() userId: string,
    @Param('id') id: string,
  ) {
    await this.ledger.removeManualAccount(userId, id);
    return { removed: true };
  }

  @Post('transactions/manual')
  async createManualTransaction(@CurrentUser() userId: string, @Body() body: Record<string, unknown>) {
    return present(await this.ledger.createManualTransaction(userId, body));
  }

  @Get('transactions')
  async transactions(
    @CurrentUser() userId: string,
    @Query('search') search?: string,
    @Query('category') category?: string,
    @Query('account') account?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('limit') limit?: string,
    @Query('before') before?: string,
    @Query('kind') kind?: string,
    @Query('pending') pending?: string,
    @Query('recurring') recurring?: string,
    @Query('minAmount') minAmount?: string,
    @Query('maxAmount') maxAmount?: string,
    @Query('tag') tag?: string,
  ) {
    const cursor = decodeCursor(before);
    const pageSize = parseLimit(limit);
    const parsedFrom = parseDate(from, 'from');
    const parsedTo = parseDate(to, 'to');
    const parsedMinAmount = parseAmount(minAmount, 'minAmount');
    const parsedMaxAmount = parseAmount(maxAmount, 'maxAmount');
    if ((parsedFrom === undefined) !== (parsedTo === undefined)) {
      throw new BadRequestException('from and to must be provided together.');
    }
    if (parsedMinAmount !== undefined && parsedMaxAmount !== undefined && parsedMinAmount > parsedMaxAmount) {
      throw new BadRequestException('minAmount cannot be greater than maxAmount.');
    }
    const interpreted = search?.trim()
      ? this.ledger.interpretTransactionSearch(search)
      : null;
    const rows = await this.ledger.listTransactions(userId, {
      search: interpreted?.query.search ?? search,
      categorySlug: category ?? interpreted?.query.categorySlug,
      accountId: account,
      categoryKind: parseCategoryKind(kind),
      pending: parseOptionalBoolean(pending, 'pending') ?? interpreted?.query.pending,
      recurring: parseOptionalBoolean(recurring, 'recurring') ?? interpreted?.query.recurring,
      amountMin: parsedMinAmount ?? interpreted?.query.amountMin,
      amountMax: parsedMaxAmount ?? interpreted?.query.amountMax,
      tag: tag?.trim().toLowerCase() || undefined,
      range: parsedFrom && parsedTo
        ? { start: parsedFrom, end: parsedTo }
        : interpreted?.query.range,
      before: cursor,
      limit: pageSize,
    });
    return {
      count: rows.length,
      transactions: rows.map(present),
      nextCursor: rows.length > 0 && rows.length === pageSize
        ? encodeCursor(rows[rows.length - 1]!)
        : null,
      interpretation: interpreted?.explanation ?? null,
    };
  }

  @Get('transactions/export.csv')
  @Header('Content-Type', 'text/csv; charset=utf-8')
  @Header('Content-Disposition', 'attachment; filename="finverse-transactions.csv"')
  async exportTransactions(
    @CurrentUser() userId: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
  ) {
    const rows = await this.ledger.listTransactions(userId, {
      range: from && to ? { start: from, end: to } : undefined,
      limit: 100_000,
    });
    return transactionsToCsv(rows);
  }

  /** The review queue: everything the categorizer refused to guess at. */
  @Get('transactions/needs-review')
  async needsReview(@CurrentUser() userId: string) {
    const rows = await this.ledger.listNeedsReview(userId);
    return { count: rows.length, transactions: rows.map(present) };
  }

  @Get('categorization-rules')
  async categorizationRules(@CurrentUser() userId: string) {
    return {
      rules: await this.ledger.listCategorizationRules(userId),
    };
  }

  @Delete('categorization-rules/:id')
  @HttpCode(204)
  removeCategorizationRule(
    @CurrentUser() userId: string,
    @Param('id') id: string,
  ) {
    return this.ledger.removeCategorizationRule(userId, id);
  }

  @Patch('transactions/:id/category')
  async recategorize(
    @CurrentUser() userId: string,
    @Param('id') id: string,
    @Body() body: { categorySlug?: string; createRule?: boolean },
  ) {
    const result = await this.ledger.recategorize(
      userId,
      id,
      body.categorySlug ?? '',
      body.createRule ?? false,
    );
    return {
      transaction: present(result.transaction),
      alsoUpdated: result.alsoUpdated,
      message:
        result.alsoUpdated > 0
          ? `Updated this and ${result.alsoUpdated} past transaction(s) from the same merchant.`
          : 'Updated.',
    };
  }

  @Patch('transactions/:id/preferences')
  async updateTransactionPreferences(
    @CurrentUser() userId: string,
    @Param('id') id: string,
    @Body()
    body: {
      merchantOverride?: unknown;
      note?: unknown;
      excludedFromAnalytics?: unknown;
      isRecurring?: unknown;
      duplicateReported?: unknown;
    },
  ) {
    const transaction = await this.ledger.updatePreferences(userId, id, body);
    return { transaction: present(transaction) };
  }

  @Patch('transactions/:id/tags')
  async updateTransactionTags(
    @CurrentUser() userId: string,
    @Param('id') id: string,
    @Body() body: { tags?: unknown },
  ) {
    return {
      transaction: present(await this.ledger.updateTransactionTags(userId, id, body.tags)),
    };
  }
}

function encodeCursor(transaction: Pick<Transaction, 'postedAt' | 'id'>): string {
  return Buffer.from(
    JSON.stringify({ postedAt: transaction.postedAt, id: transaction.id }),
    'utf8',
  ).toString('base64url');
}

function decodeCursor(value: string | undefined): { postedAt: string; id: string } | undefined {
  if (!value) return undefined;
  try {
    const decoded = JSON.parse(Buffer.from(value, 'base64url').toString('utf8')) as Record<string, unknown>;
    if (
      typeof decoded.postedAt !== 'string' ||
      !/^\d{4}-\d{2}-\d{2}$/.test(decoded.postedAt) ||
      typeof decoded.id !== 'string' ||
      decoded.id.length < 1 ||
      decoded.id.length > 200
    ) throw new Error('invalid');
    return { postedAt: decoded.postedAt, id: decoded.id };
  } catch {
    throw new BadRequestException('before must be a valid transaction cursor.');
  }
}

function parseLimit(value: string | undefined): number {
  if (value === undefined) return 50;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > 1_000) {
    throw new BadRequestException('limit must be a whole number from 1 through 1000.');
  }
  return parsed;
}

function parseOptionalBoolean(value: string | undefined, field: string): boolean | undefined {
  if (value === undefined || value === '') return undefined;
  if (value !== 'true' && value !== 'false') {
    throw new BadRequestException(`${field} must be true or false.`);
  }
  return value === 'true';
}

function parseCategoryKind(
  value: string | undefined,
): 'expense' | 'income' | 'transfer' | 'special' | undefined {
  if (value === undefined || value === '') return undefined;
  if (!['expense', 'income', 'transfer', 'special'].includes(value)) {
    throw new BadRequestException('kind must be expense, income, transfer, or special.');
  }
  return value as 'expense' | 'income' | 'transfer' | 'special';
}

function parseDate(value: string | undefined, field: string): string | undefined {
  if (value === undefined || value === '') return undefined;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new BadRequestException(`${field} must be an ISO date (YYYY-MM-DD).`);
  }
  const parsed = new Date(`${value}T00:00:00.000Z`);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) {
    throw new BadRequestException(`${field} must be a real calendar date.`);
  }
  return value;
}

function parseAmount(value: string | undefined, field: string): number | undefined {
  if (value === undefined || value === '') return undefined;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed > 10_000_000_000_000) {
    throw new BadRequestException(`${field} must be a non-negative minor-unit integer.`);
  }
  return parsed;
}
