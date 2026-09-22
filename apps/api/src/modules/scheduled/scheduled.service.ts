import { randomUUID } from 'node:crypto';
import { BadRequestException, Inject, Injectable, NotFoundException } from '@nestjs/common';

import { isKnownCategory } from '../../domain/categories';
import {
  committedOutflow,
  nextOccurrence,
  upcomingOccurrences,
  validateSchedule,
  type Occurrence,
  type ScheduleCadence,
  type ScheduledTransaction,
} from '../../domain/scheduled/schedule';
import {
  ACCOUNT_STORE,
  CLOCK,
  SCHEDULE_STORE,
  type AccountStore,
  type ClockPort,
  type ScheduleStore,
} from '../../ports';

export interface CreateScheduleInput {
  accountId: string;
  name: string;
  amount: number;
  categorySlug?: string;
  cadence: ScheduleCadence;
  startDate: string;
  endDate?: string | null;
  reminderDays?: number;
}

export interface ScheduleView extends ScheduledTransaction {
  accountName: string;
  nextDate: string | null;
  /** True when the next occurrence falls inside the reminder window. */
  dueSoon: boolean;
}

export interface UpcomingEntry extends Occurrence {
  scheduleId: string;
  name: string;
  amount: number;
  currency: string;
  categorySlug: string;
  accountId: string;
  accountName: string;
}

const MAX_HORIZON_DAYS = 365;

@Injectable()
export class ScheduledService {
  constructor(
    @Inject(SCHEDULE_STORE) private readonly schedules: ScheduleStore,
    @Inject(ACCOUNT_STORE) private readonly accounts: AccountStore,
    @Inject(CLOCK) private readonly clock: ClockPort,
  ) {}

  async list(userId: string, includeArchived = false): Promise<ScheduleView[]> {
    const [rows, accounts] = await Promise.all([
      this.schedules.list(userId, includeArchived),
      this.accounts.list(userId),
    ]);

    const names = new Map(accounts.map((a) => [a.id, a.name]));
    const today = this.clock.today();

    return rows.map((schedule) => {
      const next = nextOccurrence(schedule, today);
      const upcoming = upcomingOccurrences(schedule, today, schedule.reminderDays);

      return {
        ...schedule,
        accountName: names.get(schedule.accountId) ?? 'Closed account',
        nextDate: next,
        dueSoon: upcoming.some((o) => o.due),
      };
    });
  }

  async create(userId: string, input: CreateScheduleInput): Promise<ScheduleView> {
    const account = await this.requireAccount(userId, input.accountId);

    const check = validateSchedule(input);
    if (!check.ok) {
      throw new BadRequestException({ message: 'Schedule rejected.', problems: check.problems });
    }

    const categorySlug = input.categorySlug ?? 'unknown';
    if (!isKnownCategory(categorySlug)) {
      throw new BadRequestException(`Unknown category "${categorySlug}".`);
    }

    const schedule: ScheduledTransaction = {
      id: randomUUID(),
      accountId: account.id,
      name: input.name.trim(),
      amount: input.amount,
      // Taken from the account, never from the request. A schedule in a
      // currency the account does not hold would silently corrupt every
      // committed-outflow total that sums them.
      currency: account.currency,
      categorySlug,
      cadence: input.cadence,
      startDate: input.startDate,
      endDate: input.endDate ?? null,
      reminderDays: input.reminderDays ?? 3,
      archivedAt: null,
    };

    const saved = await this.schedules.create(userId, schedule);
    const today = this.clock.today();

    return {
      ...saved,
      accountName: account.name,
      nextDate: nextOccurrence(saved, today),
      dueSoon: upcomingOccurrences(saved, today, saved.reminderDays).some((o) => o.due),
    };
  }

  async update(
    userId: string,
    id: string,
    patch: Partial<CreateScheduleInput>,
  ): Promise<ScheduleView> {
    const existing = await this.schedules.get(userId, id);
    if (!existing) throw new NotFoundException('No such schedule.');

    // Validate the merged result, not the patch: a partial update can still
    // produce an invalid schedule, such as an end date before an unchanged start.
    if (patch.accountId !== undefined && patch.accountId !== existing.accountId) {
      throw new BadRequestException('A schedule account cannot be changed. Create a new schedule for the other account.');
    }
    const allowed = ['name', 'amount', 'categorySlug', 'cadence', 'startDate', 'endDate', 'reminderDays'];
    const safePatch = Object.fromEntries(Object.entries(patch).filter(([key]) => allowed.includes(key)));
    const merged = { ...existing, ...safePatch };
    const check = validateSchedule(merged);
    if (!check.ok) {
      throw new BadRequestException({ message: 'Schedule rejected.', problems: check.problems });
    }

    if (!isKnownCategory(merged.categorySlug)) {
      throw new BadRequestException('Unknown schedule category.');
    }
    const updated = await this.schedules.update(userId, id, {
      ...safePatch,
      name: merged.name.trim(),
      currency: existing.currency,
    });

    if (!updated) throw new NotFoundException('No such schedule.');

    const accounts = await this.accounts.list(userId);
    const today = this.clock.today();

    return {
      ...updated,
      accountName: accounts.find((a) => a.id === updated.accountId)?.name ?? 'Closed account',
      nextDate: nextOccurrence(updated, today),
      dueSoon: upcomingOccurrences(updated, today, updated.reminderDays).some((o) => o.due),
    };
  }

  async archive(userId: string, id: string): Promise<void> {
    const archived = await this.schedules.archive(userId, id, this.clock.now().toISOString());
    if (!archived) {
      throw new NotFoundException('No such schedule, or it is already archived.');
    }
  }

  /**
   * Every occurrence across every live schedule, in date order.
   *
   * This is the number that answers "what is already spoken for" — the one a
   * cash-flow view needs and a detected-subscription list cannot supply,
   * because detection only knows what has happened before.
   */
  async upcoming(
    userId: string,
    days: number,
  ): Promise<{ entries: UpcomingEntry[]; committedOutflow: number | null; currency: string | null; committedOutflowByCurrency: Record<string, number>; horizonDays: number }> {
    if (!Number.isSafeInteger(days) || days < 1 || days > MAX_HORIZON_DAYS) {
      throw new BadRequestException(`days must be between 1 and ${MAX_HORIZON_DAYS}.`);
    }

    const [schedules, accounts] = await Promise.all([
      this.schedules.list(userId),
      this.accounts.list(userId),
    ]);

    const names = new Map(accounts.map((a) => [a.id, a.name]));
    const today = this.clock.today();

    const entries = schedules
      .flatMap((schedule) =>
        upcomingOccurrences(schedule, today, days).map((occurrence) => ({
          ...occurrence,
          scheduleId: schedule.id,
          name: schedule.name,
          amount: schedule.amount,
          currency: schedule.currency,
          categorySlug: schedule.categorySlug,
          accountId: schedule.accountId,
          accountName: names.get(schedule.accountId) ?? 'Closed account',
        })),
      )
      .sort((a, b) => a.date.localeCompare(b.date) || a.name.localeCompare(b.name));

    const currencies = [...new Set(schedules.map((schedule) => schedule.currency))].sort();
    const committedOutflowByCurrency = Object.fromEntries(currencies.map((currency) => [
      currency,
      committedOutflow(schedules.filter((schedule) => schedule.currency === currency), today, days),
    ]));
    const currency = currencies.length === 1 ? currencies[0]! : currencies.length === 0 ? 'USD' : null;
    return {
      entries,
      currency,
      committedOutflow: currency === null ? null : committedOutflowByCurrency[currency] ?? 0,
      committedOutflowByCurrency,
      horizonDays: days,
    };
  }

  private async requireAccount(userId: string, accountId: string) {
    const account = await this.accounts.get(userId, accountId);
    if (!account) throw new NotFoundException('No such account.');
    return account;
  }
}
