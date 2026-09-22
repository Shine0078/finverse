/**
 * Scheduled obligations — bills and transfers a user has declared.
 *
 * Deliberately separate from the recurrence *detected* in `insights/subscriptions`.
 * Detection says "this looks like it repeats"; a schedule says "I have committed
 * to this". Conflating them means either a detection error creates a commitment
 * the user never made, or a genuine commitment disappears the month a charge is
 * missed. ADR-0004's tier ordering makes the same distinction for categories.
 *
 * Pure: no store, no clock. Every date is passed in.
 */

import { assertIsoDate, addMonths, daysInMonth, toUtcDate } from '../dates';
import { money } from '../money';
import type { IsoDate } from '../types';

export type ScheduleCadence = 'weekly' | 'fortnightly' | 'monthly' | 'quarterly' | 'yearly';

export const SCHEDULE_CADENCES: readonly ScheduleCadence[] = [
  'weekly',
  'fortnightly',
  'monthly',
  'quarterly',
  'yearly',
];

export interface ScheduledTransaction {
  id: string;
  accountId: string;
  name: string;
  /** Minor units, signed. Negative is money leaving, as everywhere else. */
  amount: number;
  currency: string;
  categorySlug: string;
  cadence: ScheduleCadence;
  /** First occurrence. Every later one is derived from this. */
  startDate: IsoDate;
  /** Inclusive. Null means indefinite. */
  endDate: IsoDate | null;
  /** How many days ahead to surface a reminder. */
  reminderDays: number;
  archivedAt: string | null;
}

export interface Occurrence {
  date: IsoDate;
  /** True once `today` is at or past the reminder window. */
  due: boolean;
  daysUntil: number;
}

const MONTHS_PER_CADENCE: Readonly<Record<ScheduleCadence, number>> = {
  weekly: 0,
  fortnightly: 0,
  monthly: 1,
  quarterly: 3,
  yearly: 12,
};

const DAYS_PER_CADENCE: Readonly<Record<ScheduleCadence, number>> = {
  weekly: 7,
  fortnightly: 14,
  monthly: 0,
  quarterly: 0,
  yearly: 0,
};

function addDaysIso(date: IsoDate, days: number): IsoDate {
  const d = toUtcDate(date);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

/**
 * The nth occurrence after the start date.
 *
 * Monthly and longer cadences advance in **calendar months anchored to the
 * start day**, not by a fixed day count. Two consequences that matter:
 *
 *   - A bill due on the 31st falls on the 30th in April and the 28th in
 *     February, then returns to the 31st. Clamping the *derived* date rather
 *     than carrying the clamp forward is what makes it return.
 *   - Adding 30 days repeatedly drifts a monthly bill backwards through the
 *     year until it lands in the wrong month entirely.
 */
export function occurrenceAt(schedule: ScheduledTransaction, index: number): IsoDate {
  if (index <= 0) return schedule.startDate;

  const dayStep = DAYS_PER_CADENCE[schedule.cadence];
  if (dayStep > 0) return addDaysIso(schedule.startDate, dayStep * index);

  const monthStep = MONTHS_PER_CADENCE[schedule.cadence];
  const anchorDay = Number(schedule.startDate.slice(8, 10));

  // Advance from the first of the month so the anchor day cannot be lost on
  // the way, then clamp once at the end.
  const firstOfStart = `${schedule.startDate.slice(0, 7)}-01`;
  const advanced = addMonths(firstOfStart, monthStep * index);

  const year = Number(advanced.slice(0, 4));
  const month = Number(advanced.slice(5, 7));
  const day = Math.min(anchorDay, daysInMonth(year, month));

  return `${advanced.slice(0, 7)}-${String(day).padStart(2, '0')}`;
}

/**
 * Upcoming occurrences within `days` of `today`.
 *
 * Starts near today and keeps the original calendar anchor. The bounded scan
 * depends on the requested horizon rather than the age of the schedule.
 */
export function upcomingOccurrences(
  schedule: ScheduledTransaction,
  today: IsoDate,
  days: number,
): Occurrence[] {
  if (schedule.archivedAt !== null) return [];

  const horizon = addDaysIso(today, days);
  const occurrences: Occurrence[] = [];

  // Hard cap: a weekly schedule over a long horizon is the worst case, and an
  // unbounded loop here would be a denial of service via a large `days`.
  const maxIterations = 1_000;

  const dayStep = DAYS_PER_CADENCE[schedule.cadence];
  const elapsedDays = Math.floor((toUtcDate(today).getTime() - toUtcDate(schedule.startDate).getTime()) / 86_400_000);
  const elapsedMonths = (Number(today.slice(0, 4)) - Number(schedule.startDate.slice(0, 4))) * 12
    + Number(today.slice(5, 7)) - Number(schedule.startDate.slice(5, 7));
  // Start near today, retaining the original anchor for month-end clamping.
  const firstIndex = Math.max(0, dayStep > 0
    ? Math.floor(elapsedDays / dayStep)
    : Math.floor(elapsedMonths / MONTHS_PER_CADENCE[schedule.cadence]) - 1);
  for (let index = firstIndex; index < firstIndex + maxIterations; index += 1) {
    const date = occurrenceAt(schedule, index);

    if (date > horizon) break;
    if (schedule.endDate && date > schedule.endDate) break;
    if (date < today) continue;

    const daysUntil = Math.round(
      (toUtcDate(date).getTime() - toUtcDate(today).getTime()) / 86_400_000,
    );

    occurrences.push({
      date,
      due: daysUntil <= schedule.reminderDays,
      daysUntil,
    });
  }

  return occurrences;
}

/** The next occurrence on or after `today`, or null when the schedule has ended. */
export function nextOccurrence(
  schedule: ScheduledTransaction,
  today: IsoDate,
): IsoDate | null {
  // A year covers every supported cadence, so one occurrence must fall inside
  // it unless the schedule has genuinely finished.
  const upcoming = upcomingOccurrences(schedule, today, 366);
  return upcoming[0]?.date ?? null;
}

export interface ScheduleValidation {
  ok: boolean;
  problems: string[];
}

export const MAX_SCHEDULE_NAME_LENGTH = 80;
export const MAX_REMINDER_DAYS = 30;

export function validateSchedule(input: {
  name?: string;
  amount?: number;
  cadence?: string;
  startDate?: string;
  endDate?: string | null;
  reminderDays?: number;
}): ScheduleValidation {
  const problems: string[] = [];
  const validDate = (value: unknown): boolean => {
    try { assertIsoDate(value as string); return true; } catch { return false; }
  };

  const name = typeof input.name === 'string' ? input.name.trim() : '';
  if (name.length === 0) problems.push('Give the schedule a name.');
  if (name.length > MAX_SCHEDULE_NAME_LENGTH) {
    problems.push(`Use ${MAX_SCHEDULE_NAME_LENGTH} characters or fewer.`);
  }

  if (!Number.isSafeInteger(input.amount) || input.amount === 0) {
    problems.push('Enter an amount in whole minor units. Zero is not a commitment.');
  }

  if (!input.cadence || !SCHEDULE_CADENCES.includes(input.cadence as ScheduleCadence)) {
    problems.push(`Cadence must be one of: ${SCHEDULE_CADENCES.join(', ')}.`);
  }

  if (!validDate(input.startDate)) {
    problems.push('startDate must be a calendar date (YYYY-MM-DD).');
  }

  if (input.endDate !== undefined && input.endDate !== null) {
    if (!validDate(input.endDate)) {
      problems.push('endDate must be a calendar date (YYYY-MM-DD).');
    } else if (input.startDate && input.endDate < input.startDate) {
      // Produces a schedule with no occurrences, which is always a mistake.
      problems.push('endDate must not be before startDate.');
    }
  }

  const reminder = input.reminderDays ?? 0;
  if (!Number.isSafeInteger(reminder) || reminder < 0 || reminder > MAX_REMINDER_DAYS) {
    problems.push(`reminderDays must be between 0 and ${MAX_REMINDER_DAYS}.`);
  }

  return { ok: problems.length === 0, problems };
}

/** Total committed outflow across schedules over a horizon. Positive minor units. */
export function committedOutflow(
  schedules: readonly ScheduledTransaction[],
  today: IsoDate,
  days: number,
): number {
  let total = 0;

  for (const schedule of schedules) {
    if (schedule.amount >= 0) continue;
    total = money(total + Math.abs(schedule.amount) * upcomingOccurrences(schedule, today, days).length, schedule.currency).amount;
  }

  return total;
}
