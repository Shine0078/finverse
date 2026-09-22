/**
 * Money arithmetic. See ADR-0003.
 *
 * Amounts are integers in the currency's minor unit (cents, pence, yen).
 * Sign convention: NEGATIVE means money leaving the user. A $4.50 coffee is -450.
 */

export interface Money {
  /** Integer, minor units. Negative = outflow. */
  readonly amount: number;
  /** ISO 4217, uppercase. */
  readonly currency: string;
}

/** Currencies whose minor unit is not 1/100. Everything else defaults to 2. */
const EXPONENT_OVERRIDES: Readonly<Record<string, number>> = {
  JPY: 0,
  KRW: 0,
  VND: 0,
  CLP: 0,
  ISK: 0,
  BHD: 3,
  KWD: 3,
  OMR: 3,
  TND: 3,
};

export class CurrencyMismatchError extends Error {
  constructor(a: string, b: string) {
    super(
      `Cannot combine ${a} and ${b} without an explicit FX conversion. ` +
        `Convert first, recording the rate and quote time.`,
    );
    this.name = 'CurrencyMismatchError';
  }
}

export function exponentOf(currency: string): number {
  return EXPONENT_OVERRIDES[currency.toUpperCase()] ?? 2;
}

export function money(amount: number, currency = 'USD'): Money {
  if (!Number.isSafeInteger(amount)) {
    throw new TypeError(
      `Money must be a safe integer in minor units, received ${amount}. ` +
        `Use majorToMinor() to convert a decimal amount.`,
    );
  }
  return { amount, currency: currency.toUpperCase() };
}

export function zero(currency = 'USD'): Money {
  return money(0, currency);
}

function assertSameCurrency(a: Money, b: Money): void {
  if (a.currency !== b.currency) {
    throw new CurrencyMismatchError(a.currency, b.currency);
  }
}

export function addMoney(a: Money, b: Money): Money {
  assertSameCurrency(a, b);
  return money(a.amount + b.amount, a.currency);
}

export function subtractMoney(a: Money, b: Money): Money {
  assertSameCurrency(a, b);
  return money(a.amount - b.amount, a.currency);
}

export function negateMoney(a: Money): Money {
  return money(-a.amount, a.currency);
}

export function absMoney(a: Money): Money {
  return money(Math.abs(a.amount), a.currency);
}

/**
 * Sums a list. The currency is explicit rather than inferred from the first item
 * so that summing an empty list still produces a well-typed zero.
 */
export function sumMoney(items: readonly Money[], currency: string): Money {
  return items.reduce<Money>((acc, item) => addMoney(acc, item), zero(currency));
}

export function isOutflow(a: Money): boolean {
  return a.amount < 0;
}

export function isInflow(a: Money): boolean {
  return a.amount > 0;
}

/**
 * 12.34 USD -> 1234. Rounds half away from zero.
 *
 * The `toFixed` step is not decoration. `1.005 * 100` evaluates to
 * 100.49999999999999, so a plain `Math.round` yields 100 — a user who types
 * 1.005 gets 1.00 back. Collapsing the float noise at a precision well beyond
 * any real currency first makes the rounding behave the way the person typing
 * the number expects.
 */
export function majorToMinor(major: number, currency = 'USD'): number {
  if (!Number.isFinite(major)) throw new TypeError('Major units must be finite.');
  const factor = 10 ** exponentOf(currency);
  const scaled = Number((major * factor).toFixed(6));
  const rounded = scaled < 0 ? -Math.round(-scaled) : Math.round(scaled);
  return money(rounded, currency).amount;
}

/** 1234 USD -> 12.34. For display and export only — never feed this back into arithmetic. */
export function minorToMajor(minor: number, currency = 'USD'): number {
  return minor / 10 ** exponentOf(currency);
}

/**
 * The single sanctioned place minor units become a human-readable string.
 * Everywhere else in the codebase, money stays an integer.
 */
export function formatMoney(m: Money, locale = 'en-US'): string {
  const digits = exponentOf(m.currency);
  return new Intl.NumberFormat(locale, {
    style: 'currency',
    currency: m.currency,
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(minorToMajor(m.amount, m.currency));
}

/**
 * Splits an amount into n parts that sum exactly back to the original.
 * Remainder cents are distributed one each to the leading parts rather than
 * rounded away — used by expense splitting, where the parts must reconcile.
 */
export function allocate(m: Money, parts: number): Money[] {
  if (!Number.isInteger(parts) || parts < 1) {
    throw new RangeError(`parts must be a positive integer, received ${parts}`);
  }
  const sign = m.amount < 0 ? -1 : 1;
  const total = Math.abs(m.amount);
  const base = Math.floor(total / parts);
  let remainder = total - base * parts;

  return Array.from({ length: parts }, () => {
    const extra = remainder > 0 ? 1 : 0;
    remainder -= extra;
    return money(sign * (base + extra), m.currency);
  });
}

/** Percentage of `part` relative to `whole`, as a float. Guards divide-by-zero. */
export function percentOf(part: number, whole: number): number {
  if (whole === 0) return 0;
  return (part / whole) * 100;
}
