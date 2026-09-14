/**
 * The seeded category tree. Two levels: a top-level group and its children.
 * Slugs are the stable identifier used everywhere in code — display names can
 * change and be localised, slugs cannot.
 */

export interface CategoryDef {
  slug: string;
  name: string;
  parent: string | null;
  /** Income categories are excluded from spending totals and budgets. */
  kind: 'expense' | 'income' | 'transfer' | 'special';
}

export const UNKNOWN_CATEGORY = 'unknown';

export const CATEGORIES: readonly CategoryDef[] = [
  // ---- Housing
  { slug: 'housing', name: 'Housing', parent: null, kind: 'expense' },
  { slug: 'rent', name: 'Rent', parent: 'housing', kind: 'expense' },
  { slug: 'mortgage', name: 'Mortgage', parent: 'housing', kind: 'expense' },
  { slug: 'utilities', name: 'Utilities', parent: 'housing', kind: 'expense' },
  { slug: 'internet', name: 'Internet', parent: 'housing', kind: 'expense' },
  { slug: 'phone', name: 'Phone', parent: 'housing', kind: 'expense' },

  // ---- Food
  { slug: 'food', name: 'Food', parent: null, kind: 'expense' },
  { slug: 'groceries', name: 'Groceries', parent: 'food', kind: 'expense' },
  { slug: 'restaurants', name: 'Restaurants', parent: 'food', kind: 'expense' },
  { slug: 'coffee', name: 'Coffee', parent: 'food', kind: 'expense' },
  { slug: 'fast_food', name: 'Fast Food', parent: 'food', kind: 'expense' },
  { slug: 'food_delivery', name: 'Food Delivery', parent: 'food', kind: 'expense' },

  // ---- Transport
  { slug: 'transportation', name: 'Transportation', parent: null, kind: 'expense' },
  { slug: 'fuel', name: 'Fuel', parent: 'transportation', kind: 'expense' },
  { slug: 'public_transit', name: 'Public Transit', parent: 'transportation', kind: 'expense' },
  { slug: 'rideshare', name: 'Ride Sharing', parent: 'transportation', kind: 'expense' },
  { slug: 'parking', name: 'Parking', parent: 'transportation', kind: 'expense' },

  // ---- Health
  { slug: 'healthcare', name: 'Healthcare', parent: null, kind: 'expense' },
  { slug: 'pharmacy', name: 'Pharmacy', parent: 'healthcare', kind: 'expense' },
  { slug: 'insurance', name: 'Insurance', parent: 'healthcare', kind: 'expense' },

  // ---- Lifestyle
  { slug: 'shopping', name: 'Shopping', parent: null, kind: 'expense' },
  { slug: 'clothing', name: 'Clothing', parent: 'shopping', kind: 'expense' },
  { slug: 'electronics', name: 'Electronics', parent: 'shopping', kind: 'expense' },
  { slug: 'entertainment', name: 'Entertainment', parent: null, kind: 'expense' },
  { slug: 'streaming', name: 'Streaming', parent: 'entertainment', kind: 'expense' },
  { slug: 'gaming', name: 'Gaming', parent: 'entertainment', kind: 'expense' },
  { slug: 'fitness', name: 'Fitness', parent: 'entertainment', kind: 'expense' },
  { slug: 'travel', name: 'Travel', parent: null, kind: 'expense' },
  { slug: 'subscriptions', name: 'Subscriptions', parent: null, kind: 'expense' },
  { slug: 'software', name: 'Software', parent: 'subscriptions', kind: 'expense' },
  { slug: 'other_expenses', name: 'Other Expenses', parent: null, kind: 'expense' },

  // ---- Obligations
  { slug: 'debt', name: 'Debt', parent: null, kind: 'expense' },
  { slug: 'loan_payment', name: 'Loan Payment', parent: 'debt', kind: 'expense' },
  { slug: 'credit_card_payment', name: 'Credit Card Payment', parent: 'debt', kind: 'transfer' },
  { slug: 'taxes', name: 'Taxes', parent: null, kind: 'expense' },
  { slug: 'fees', name: 'Fees & Interest', parent: null, kind: 'expense' },

  // ---- Money in / money moved
  { slug: 'income', name: 'Income', parent: null, kind: 'income' },
  { slug: 'salary', name: 'Salary', parent: 'income', kind: 'income' },
  { slug: 'freelance', name: 'Freelance', parent: 'income', kind: 'income' },
  { slug: 'refunds', name: 'Refunds', parent: 'income', kind: 'income' },
  { slug: 'interest_income', name: 'Interest', parent: 'income', kind: 'income' },
  { slug: 'savings', name: 'Savings', parent: null, kind: 'transfer' },
  { slug: 'investments', name: 'Investments', parent: null, kind: 'transfer' },
  { slug: 'transfer', name: 'Transfer', parent: null, kind: 'transfer' },

  // ---- Fallback
  //
  // Deliberately `expense`, not `special`. An uncategorized outflow is still
  // money that left the account. Excluding it from spending totals inflates
  // savings rate and the health score — a rent payment we failed to recognize
  // would simply vanish from the user's expenses, which is worse than
  // attributing it to a vague bucket.
  { slug: UNKNOWN_CATEGORY, name: 'Unknown', parent: null, kind: 'expense' },
];

const BY_SLUG = new Map(CATEGORIES.map((c) => [c.slug, c]));

export function getCategory(slug: string): CategoryDef | undefined {
  return BY_SLUG.get(slug);
}

export function isKnownCategory(slug: string): boolean {
  return BY_SLUG.has(slug);
}

/** True for categories that count toward spending totals and budgets.
 *  Transfers are excluded deliberately: moving $500 into savings is not
 *  spending, and counting it as such makes every budget wrong. */
export function isSpendingCategory(slug: string): boolean {
  return BY_SLUG.get(slug)?.kind === 'expense';
}

export function isIncomeCategory(slug: string): boolean {
  return BY_SLUG.get(slug)?.kind === 'income';
}

/** Categories that normally represent necessary living costs. This is a
 * transparent product convention, not a judgement about an individual user's
 * choices; unknown and discretionary categories stay separate in analytics. */
const ESSENTIAL_ROOTS = new Set([
  'housing',
  'food',
  'transportation',
  'healthcare',
  'debt',
  'taxes',
  'fees',
]);

const DISCRETIONARY_CATEGORIES = new Set([
  'restaurants',
  'coffee',
  'fast_food',
  'food_delivery',
  'parking',
  'rideshare',
  'shopping',
  'clothing',
  'electronics',
  'entertainment',
  'streaming',
  'gaming',
  'fitness',
  'travel',
  'subscriptions',
  'software',
]);

export function isEssentialCategory(slug: string): boolean {
  return !DISCRETIONARY_CATEGORIES.has(slug) && ESSENTIAL_ROOTS.has(rootCategoryOf(slug));
}

/** Walks to the top-level ancestor. Returns the slug itself if already top-level. */
export function rootCategoryOf(slug: string): string {
  let current = BY_SLUG.get(slug);
  if (!current) return UNKNOWN_CATEGORY;
  while (current.parent) {
    const parent = BY_SLUG.get(current.parent);
    if (!parent) break;
    current = parent;
  }
  return current.slug;
}

export function displayName(slug: string): string {
  return BY_SLUG.get(slug)?.name ?? 'Unknown';
}
