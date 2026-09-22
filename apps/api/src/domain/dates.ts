/**
 * Calendar-date helpers. Everything operates on `YYYY-MM-DD` strings in UTC.
 *
 * Transactions post on a *day*, not an instant. Storing them as timestamps and
 * rendering them in a local timezone shifts some of them across month
 * boundaries, which silently corrupts every monthly total. So: dates only.
 */

import type { DateRange, IsoDate } from './types';

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

export function assertIsoDate(value: string): asserts value is IsoDate {
  const parsed = typeof value === 'string' && ISO_DATE.test(value)
    ? new Date(value + 'T00:00:00.000Z') : null;
  if (!parsed || !Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) {
    throw new TypeError(`Expected an ISO date (YYYY-MM-DD), received "${value}"`);
  }
}

export function toUtcDate(date: IsoDate): Date {
  assertIsoDate(date);
  return new Date(`${date}T00:00:00.000Z`);
}

export function toIsoDate(date: Date): IsoDate {
  return date.toISOString().slice(0, 10);
}

export function addDays(date: IsoDate, days: number): IsoDate {
  const d = toUtcDate(date);
  d.setUTCDate(d.getUTCDate() + days);
  return toIsoDate(d);
}

export function addMonths(date: IsoDate, months: number): IsoDate {
  const d = toUtcDate(date);
  const targetDay = d.getUTCDate();
  d.setUTCDate(1);
  d.setUTCMonth(d.getUTCMonth() + months);
  // Clamp: 2026-01-31 plus one month is 2026-02-28, not 2026-03-03.
  const lastDay = daysInMonth(d.getUTCFullYear(), d.getUTCMonth() + 1);
  d.setUTCDate(Math.min(targetDay, lastDay));
  return toIsoDate(d);
}

export function daysInMonth(year: number, month1to12: number): number {
  return new Date(Date.UTC(year, month1to12, 0)).getUTCDate();
}

/** Inclusive of both ends: 2026-01-01 to 2026-01-01 is 1 day. */
export function daysBetweenInclusive(start: IsoDate, end: IsoDate): number {
  const ms = toUtcDate(end).getTime() - toUtcDate(start).getTime();
  return Math.floor(ms / 86_400_000) + 1;
}

export function isWithin(date: IsoDate, range: DateRange): boolean {
  return date >= range.start && date <= range.end;
}

export function startOfMonth(date: IsoDate): IsoDate {
  assertIsoDate(date);
  return `${date.slice(0, 7)}-01`;
}

export function endOfMonth(date: IsoDate): IsoDate {
  const d = toUtcDate(date);
  const last = daysInMonth(d.getUTCFullYear(), d.getUTCMonth() + 1);
  return `${date.slice(0, 7)}-${String(last).padStart(2, '0')}`;
}

export function monthRange(date: IsoDate): DateRange {
  return { start: startOfMonth(date), end: endOfMonth(date) };
}

export function previousMonthRange(date: IsoDate): DateRange {
  return monthRange(addMonths(startOfMonth(date), -1));
}

/** First of the month through today, inclusive. The honest "this month so far"
 *  window — using the full calendar month would divide spend across days that
 *  have not happened yet and understate the daily average. */
export function monthToDateRange(today: IsoDate): DateRange {
  return { start: startOfMonth(today), end: today };
}

/**
 * The previous month truncated to the same elapsed length as the current
 * month-to-date. On 2026-08-07 this returns 2026-07-01..2026-07-07.
 *
 * Comparing a 7-day month-to-date against a full 31-day month reports every
 * category as "down 100%", which is not an insight — it's an artifact of the
 * calendar. Like-for-like is the only comparison worth showing a user mid-month.
 */
export function comparablePreviousRange(today: IsoDate): DateRange {
  const previous = previousMonthRange(today);
  const dayOfMonth = Number(today.slice(8, 10));
  const previousDate = toUtcDate(previous.start);
  const lastDay = daysInMonth(previousDate.getUTCFullYear(), previousDate.getUTCMonth() + 1);
  const endDay = Math.min(dayOfMonth, lastDay);
  return { start: previous.start, end: `${previous.start.slice(0, 7)}-${String(endDay).padStart(2, '0')}` };
}

/** ISO week, Monday-start. */
export function weekRange(date: IsoDate): DateRange {
  const d = toUtcDate(date);
  const dow = (d.getUTCDay() + 6) % 7; // Monday = 0
  const start = addDays(date, -dow);
  return { start, end: addDays(start, 6) };
}

export function yearRange(date: IsoDate): DateRange {
  assertIsoDate(date);
  const year = date.slice(0, 4);
  return { start: `${year}-01-01`, end: `${year}-12-31` };
}

/** `2026-03` — the grouping key for month-over-month comparisons. */
export function monthKey(date: IsoDate): string {
  assertIsoDate(date);
  return date.slice(0, 7);
}
