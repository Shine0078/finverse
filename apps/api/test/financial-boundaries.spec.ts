import { describe, expect, it } from 'vitest';
import { assertIsoDate, addDays, monthToDateRange, yearRange } from '../src/domain/dates';
import { money, majorToMinor, addMoney, subtractMoney } from '../src/domain/money';

describe('financial input boundaries', () => {
  it.each(['2026-02-29', '2026-02-31', '2026-04-31', '2026-00-10', '2026-13-01', '2026-01-00'])('rejects impossible calendar date %s', (date) => {
    expect(() => assertIsoDate(date)).toThrow(TypeError);
    expect(() => addDays(date, 0)).toThrow(TypeError);
    expect(() => monthToDateRange(date)).toThrow(TypeError);
    expect(() => yearRange(date)).toThrow(TypeError);
  });
  it('preserves leap days and dates at a timezone boundary', () => {
    expect(() => assertIsoDate('2028-02-29')).not.toThrow();
    expect(addDays('2028-02-29', 1)).toBe('2028-03-01');
  });
  it.each([Number.MAX_SAFE_INTEGER + 1, Number.MIN_SAFE_INTEGER - 1, NaN, Infinity, -Infinity])('rejects unsafe minor units %s', (amount) => {
    expect(() => money(amount)).toThrow(TypeError);
  });
  it('rejects arithmetic overflow instead of dropping cents', () => {
    expect(() => addMoney(money(Number.MAX_SAFE_INTEGER), money(1))).toThrow(TypeError);
    expect(() => subtractMoney(money(Number.MIN_SAFE_INTEGER), money(1))).toThrow(TypeError);
  });
  it.each([NaN, Infinity, -Infinity, 1e100])('rejects unrepresentable major units %s', (amount) => {
    expect(() => majorToMinor(amount)).toThrow(TypeError);
  });
});
