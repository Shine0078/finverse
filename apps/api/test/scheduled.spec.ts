import { describe, expect, it } from 'vitest';

import {
  committedOutflow,
  nextOccurrence,
  occurrenceAt,
  upcomingOccurrences,
  validateSchedule,
  type ScheduledTransaction,
} from '../src/domain/scheduled/schedule';

function schedule(overrides: Partial<ScheduledTransaction> = {}): ScheduledTransaction {
  return {
    id: 's1',
    accountId: 'acc_checking',
    name: 'Rent',
    amount: -218_000,
    currency: 'USD',
    categorySlug: 'rent',
    cadence: 'monthly',
    startDate: '2026-01-15',
    endDate: null,
    reminderDays: 3,
    archivedAt: null,
    ...overrides,
  };
}

describe('occurrenceAt', () => {
  it('returns the start date for index zero', () => {
    expect(occurrenceAt(schedule(), 0)).toBe('2026-01-15');
  });

  it('advances monthly by calendar month', () => {
    expect(occurrenceAt(schedule(), 1)).toBe('2026-02-15');
    expect(occurrenceAt(schedule(), 2)).toBe('2026-03-15');
  });

  it('advances weekly and fortnightly by days', () => {
    expect(occurrenceAt(schedule({ cadence: 'weekly' }), 2)).toBe('2026-01-29');
    expect(occurrenceAt(schedule({ cadence: 'fortnightly' }), 2)).toBe('2026-02-12');
  });

  it('advances quarterly and yearly', () => {
    expect(occurrenceAt(schedule({ cadence: 'quarterly' }), 1)).toBe('2026-04-15');
    expect(occurrenceAt(schedule({ cadence: 'yearly' }), 1)).toBe('2027-01-15');
  });

  it('clamps a 31st anchor into a shorter month', () => {
    const s = schedule({ startDate: '2026-01-31' });
    expect(occurrenceAt(s, 1)).toBe('2026-02-28');
    expect(occurrenceAt(s, 3)).toBe('2026-04-30');
  });

  it('returns to the 31st after a short month', () => {
    // The clamp applies to the derived date, not carried forward. Carrying it
    // would permanently move a bill due on the 31st to the 28th.
    const s = schedule({ startDate: '2026-01-31' });
    expect(occurrenceAt(s, 2)).toBe('2026-03-31');
    expect(occurrenceAt(s, 4)).toBe('2026-05-31');
  });

  it('handles a 29 February anchor in a leap year', () => {
    const s = schedule({ startDate: '2028-02-29', cadence: 'yearly' });
    expect(occurrenceAt(s, 1)).toBe('2029-02-28');
    expect(occurrenceAt(s, 4)).toBe('2032-02-29');
  });

  it('does not drift a monthly schedule across a year', () => {
    // Adding 30 days repeatedly walks a monthly bill backwards until it lands
    // in the wrong month entirely.
    expect(occurrenceAt(schedule(), 12)).toBe('2027-01-15');
  });

  it('crosses a year boundary', () => {
    expect(occurrenceAt(schedule({ startDate: '2026-11-15' }), 3)).toBe('2027-02-15');
  });
});

describe('upcomingOccurrences', () => {
  it('lists occurrences inside the horizon', () => {
    const dates = upcomingOccurrences(schedule(), '2026-01-01', 90).map((o) => o.date);
    expect(dates).toEqual(['2026-01-15', '2026-02-15', '2026-03-15']);
  });

  it('excludes dates already past', () => {
    const dates = upcomingOccurrences(schedule(), '2026-02-20', 60).map((o) => o.date);
    expect(dates[0]).toBe('2026-03-15');
  });

  it('includes an occurrence falling today', () => {
    expect(upcomingOccurrences(schedule(), '2026-01-15', 1)[0]?.date).toBe('2026-01-15');
  });

  it('marks an occurrence due inside the reminder window', () => {
    const [first] = upcomingOccurrences(schedule({ reminderDays: 3 }), '2026-01-13', 30);
    expect(first?.due).toBe(true);
    expect(first?.daysUntil).toBe(2);
  });

  it('does not mark one outside the reminder window', () => {
    const [first] = upcomingOccurrences(schedule({ reminderDays: 3 }), '2026-01-05', 30);
    expect(first?.due).toBe(false);
  });

  it('stops at the end date', () => {
    const s = schedule({ endDate: '2026-02-20' });
    const dates = upcomingOccurrences(s, '2026-01-01', 365).map((o) => o.date);
    expect(dates).toEqual(['2026-01-15', '2026-02-15']);
  });

  it('returns nothing for an archived schedule', () => {
    const s = schedule({ archivedAt: '2026-01-02T00:00:00.000Z' });
    expect(upcomingOccurrences(s, '2026-01-01', 365)).toEqual([]);
  });

  it('returns nothing when the horizon is before the first occurrence', () => {
    expect(upcomingOccurrences(schedule(), '2026-01-01', 5)).toEqual([]);
  });

  it('stays bounded for a weekly schedule over a long horizon', () => {
    // An unbounded loop here would be a denial of service via a large horizon.
    const weekly = schedule({ cadence: 'weekly', startDate: '2020-01-01' });
    const result = upcomingOccurrences(weekly, '2026-01-01', 100_000);
    expect(result.length).toBeLessThanOrEqual(1_000);
  });
});

describe('nextOccurrence', () => {
  it('finds the next date', () => {
    expect(nextOccurrence(schedule(), '2026-02-20')).toBe('2026-03-15');
  });

  it('is null once the schedule has ended', () => {
    expect(nextOccurrence(schedule({ endDate: '2026-02-01' }), '2026-06-01')).toBeNull();
  });

  it('is null for an archived schedule', () => {
    expect(nextOccurrence(schedule({ archivedAt: 'x' }), '2026-01-01')).toBeNull();
  });
});

describe('validateSchedule', () => {
  const valid = {
    name: 'Rent',
    amount: -218_000,
    cadence: 'monthly',
    startDate: '2026-01-15',
    reminderDays: 3,
  };

  it('accepts a well-formed schedule', () => {
    expect(validateSchedule(valid).ok).toBe(true);
  });

  it('rejects a zero amount', () => {
    // Zero is not a commitment.
    expect(validateSchedule({ ...valid, amount: 0 }).ok).toBe(false);
  });

  it('accepts a positive amount as expected income', () => {
    expect(validateSchedule({ ...valid, amount: 500_000 }).ok).toBe(true);
  });

  it('rejects a fractional amount', () => {
    expect(validateSchedule({ ...valid, amount: 10.5 }).ok).toBe(false);
  });

  it('rejects an empty name', () => {
    expect(validateSchedule({ ...valid, name: '  ' }).ok).toBe(false);
  });

  it('rejects an unknown cadence', () => {
    expect(validateSchedule({ ...valid, cadence: 'whenever' }).ok).toBe(false);
  });

  it('rejects an end date before the start', () => {
    // Produces a schedule with no occurrences at all.
    expect(validateSchedule({ ...valid, endDate: '2025-12-01' }).ok).toBe(false);
  });

  it('accepts an end date equal to the start', () => {
    expect(validateSchedule({ ...valid, endDate: '2026-01-15' }).ok).toBe(true);
  });

  it('rejects an out-of-range reminder', () => {
    expect(validateSchedule({ ...valid, reminderDays: -1 }).ok).toBe(false);
    expect(validateSchedule({ ...valid, reminderDays: 60 }).ok).toBe(false);
  });

  it('reports every problem at once', () => {
    const result = validateSchedule({ name: '', amount: 0, cadence: 'nope', startDate: 'x' });
    expect(result.problems.length).toBeGreaterThanOrEqual(4);
  });
});

describe('committedOutflow', () => {
  it('sums outflows over the horizon', () => {
    const rent = schedule({ amount: -100_000, startDate: '2026-01-15' });
    expect(committedOutflow([rent], '2026-01-01', 90)).toBe(300_000);
  });

  it('ignores expected income', () => {
    // A commitment is money leaving; counting salary would understate the risk.
    const salary = schedule({ amount: 500_000, startDate: '2026-01-15' });
    expect(committedOutflow([salary], '2026-01-01', 90)).toBe(0);
  });

  it('ignores archived schedules', () => {
    const archived = schedule({ amount: -100_000, archivedAt: 'x' });
    expect(committedOutflow([archived], '2026-01-01', 90)).toBe(0);
  });

  it('is empty-safe', () => {
    expect(committedOutflow([], '2026-01-01', 90)).toBe(0);
  });
});

describe('long-lived obligations', () => {
  it('keeps weekly schedules visible after more than 1000 occurrences', () => {
    const old = schedule({ cadence: 'weekly', startDate: '2000-01-03' });
    expect(upcomingOccurrences(old, '2026-01-05', 21).map(o => o.date)).toEqual([
      '2026-01-05', '2026-01-12', '2026-01-19', '2026-01-26',
    ]);
  });
  it('preserves the original month-end anchor after many years', () => {
    expect(nextOccurrence(schedule({ startDate: '1900-01-31' }), '2026-02-01')).toBe('2026-02-28');
  });
  it('rejects a commitment total that exceeds exact integer precision', () => {
    expect(() => committedOutflow([schedule({ amount: -Number.MAX_SAFE_INTEGER })], '2026-01-01', 90)).toThrow();
  });
});
