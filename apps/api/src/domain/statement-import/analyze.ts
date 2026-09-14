import { createHash } from 'node:crypto';

import { categorizeDescriptor } from '../categorization/categorize';
import { UNKNOWN_CATEGORY } from '../categories';
import { UserCorrectionClassifier } from '../categorization/user-correction-classifier';
import { normalizeDescriptor } from '../categorization/normalize';
import type { CategorizationRule, Transaction } from '../types';
import { parseAmount, parseDate, suggestMapping, type ColumnMapping } from '../imports/mapping';
import { parseCsv } from '../imports/csv-parse';
import { reviewImport, type ReviewedRow } from '../imports/review';
import type { StatementDocumentDetails, StatementExtraction, StatementFormat, StatementRowDraft } from './types';

const MAX_ROWS = 10_000;
const MAX_DECOMPRESSED_BYTES = 10 * 1024 * 1024;
const MAX_ZIP_ENTRIES = 512;
const MAX_XLSX_COLUMNS = 16_384; // Excel's XFD limit.
const MAX_PDF_OCR_PAGES = 20;
const IMAGE_MIME = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/tiff', 'image/bmp']);
const CURRENCY_CODES = ['CAD', 'USD', 'EUR', 'GBP', 'AUD', 'NZD', 'JPY', 'CHF', 'CNY', 'INR', 'MXN', 'BRL', 'SGD', 'HKD'] as const;

export function formatFor(filename: string, mimeType?: string): StatementFormat {
  const ext = filename.toLowerCase().split('.').pop();
  if (ext === 'csv' || mimeType === 'text/csv' || mimeType === 'text/plain') return 'csv';
  if (ext === 'xlsx' || mimeType === 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet') return 'xlsx';
  if (ext === 'pdf' || mimeType === 'application/pdf') return 'pdf';
  if (IMAGE_MIME.has(mimeType ?? '') || ['png', 'jpg', 'jpeg', 'webp', 'tiff', 'bmp'].includes(ext ?? '')) return 'image';
  throw new Error('Supported statement formats are CSV, XLSX, PDF, PNG, JPEG, WEBP, TIFF, and BMP.');
}

export interface StatementAnalyzeInput {
  filename: string;
  mimeType?: string;
  bytes: Buffer;
  currency: string;
  existing: readonly Transaction[];
  rules: readonly CategorizationRule[];
}

export async function analyzeStatement(input: StatementAnalyzeInput): Promise<StatementExtraction> {
  const format = formatFor(input.filename, input.mimeType);
  const statementHash = createHash('sha256').update(input.bytes).digest('hex');
  if (input.bytes.length === 0) throw new Error('The statement file is empty.');

  // Do not let an extension or user-controlled MIME type select a parser for
  // an unrelated payload. These small signatures also make malformed uploads
  // fail before ZIP/XML/PDF/OCR work begins.
  assertFileSignature(format, input.bytes);
  const model = UserCorrectionClassifier.fromTransactions(input.existing);

  if (format === 'csv') {
    return analyzeTabular(format, input.bytes.toString('utf8'), statementHash, input, model);
  }
  if (format === 'xlsx') {
    return analyzeTabular(format, xlsxToCsv(input.bytes), statementHash, input, model);
  }

  const text = format === 'pdf' ? await extractPdfText(input.bytes) : await extractImageText(input.bytes);
  const documentDetails = extractStatementDetails(text, input.currency);
  assertCurrencyMatchesAccount(documentDetails.currency, input.currency);
  const rows = parseTextRows(text, input.currency, input.rules, input.existing, model);
  return {
    format,
    rows,
    warnings: rows.length === 0 ? ['No transaction rows could be identified. Check the statement quality or review it manually.'] : [],
    statementHash,
    documentDetails,
    sourceText: text.slice(0, 200_000),
  };
}

/**
 * Extract only safe header metadata. Full account/card numbers and addresses
 * are deliberately discarded; the selected FINVERSE account remains the
 * authoritative routing target.
 */
export function extractStatementDetails(text: string, currency: string): StatementDocumentDetails {
  const lines = text.split(/\r?\n/).map((line) => line.replace(/\s+/g, ' ').trim()).filter(Boolean);
  const issuer = [
    ['cibc', 'CIBC'],
    ['neo financial', 'Neo Financial'],
    ['royal bank of canada|\\brbc\\b', 'RBC'],
    ['toronto-dominion|\\btd bank\\b', 'TD'],
    ['bank of montreal|\\bbmo\\b', 'BMO'],
    ['scotiabank', 'Scotiabank'],
    ['desjardins', 'Desjardins'],
    ['tangerine', 'Tangerine'],
    ['simplii', 'Simplii'],
    ['capital one', 'Capital One'],
  ].find(([pattern]) => new RegExp(pattern!, 'i').test(text))?.[1] ?? null;

  const accountLabelIndex = lines.findIndex((line) => /account number|card number|card account|••••/i.test(line));
  const labelledAccountLine = accountLabelIndex < 0 ? '' : lines[accountLabelIndex]!;
  const labelledAccountContext = /\d{4}/.test(labelledAccountLine)
    ? labelledAccountLine
    : accountLabelIndex < 0
      ? ''
      : lines.slice(accountLabelIndex, accountLabelIndex + 2).join(' ');
  const accountLine = labelledAccountContext || (lines.find((line) => {
    const digits = line.replace(/\D/g, '');
    return digits.length >= 4 && digits.length <= 19 && !/^20\d{2}$/.test(digits);
  }) ?? '');
  const accountDigits = accountLine
    .match(/(?:\d[\s-]*){4,}/g)
    ?.map((candidate) => candidate.replace(/\D/g, ''))
    .filter((candidate) => candidate.length >= 4)
    .at(-1);
  const accountReferenceLast4 = accountDigits?.slice(-4) ?? null;

  const statementDateMatch = /\bstatement\s+date\s*:?\s*([A-Za-z]{3,9}\s+\d{1,2},?\s+20\d{2})\b/i.exec(text);
  const statementDate = statementDateMatch ? parseLongDate(statementDateMatch[1]!) : null;
  const periodMatch = /\b([A-Za-z]{3,9}\s+\d{1,2})(?:,?\s*(20\d{2}))?\s+(?:to|[-–])\s+([A-Za-z]{3,9}\s+\d{1,2}),?\s*(20\d{2})\b/i.exec(text);
  const endYear = periodMatch?.[4] ? Number(periodMatch[4]) : null;
  const periodStart = periodMatch ? parseLongDate(periodMatch[1]!, periodMatch[2] ? Number(periodMatch[2]) : endYear) : null;
  const periodEnd = periodMatch ? parseLongDate(periodMatch[3]!, endYear) : null;

  return {
    issuer,
    accountReferenceLast4,
    statementDate,
    periodStart,
    periodEnd,
    currency: detectStatementCurrency(text, currency),
  };
}

/**
 * Detect a currency only from statement-style labels. A merchant description
 * may contain an ISO code, so a broad `\\b[A-Z]{3}\\b` search would silently
 * mislabel an account. The selected account currency remains the fallback and
 * is checked before any rows are staged.
 */
export function detectStatementCurrency(text: string, fallback: string): string | null {
  const normalizedFallback = fallback.trim().toUpperCase();
  const codes = CURRENCY_CODES.join('|');
  const labelled = new RegExp(
    `(?:amount|balance|currency|total|debit|credit|payment)[^\\n]{0,36}\\(\\s*\\$?\\s*(${codes})\\s*\\)`,
    'i',
  ).exec(text)?.[1];
  if (labelled) return labelled.toUpperCase();

  const symbol = /(?:CA\$|C\$)\s*[-+]?\d|(?:US\$)\s*[-+]?\d/i.test(text)
    ? (/(?:CA\$|C\$)\s*[-+]?\d/i.test(text) ? 'CAD' : 'USD')
    : null;
  if (symbol) return symbol;

  const explicit = new RegExp(`(?:statement\\s+)?currency\\s*[:=]?\\s*(${codes})\\b`, 'i').exec(text)?.[1];
  return explicit?.toUpperCase() ?? (normalizedFallback || null);
}

function assertCurrencyMatchesAccount(documentCurrency: string | null, accountCurrency: string): void {
  const documentCode = documentCurrency?.trim().toUpperCase();
  const accountCode = accountCurrency.trim().toUpperCase();
  if (documentCode && accountCode && documentCode !== accountCode) {
    throw new Error(
      `This statement is in ${documentCode}, but the selected account is ${accountCode}. Select or create a ${documentCode} account before uploading it.`,
    );
  }
}

function parseLongDate(value: string, fallbackYear?: number | null): string | null {
  const match = /^([A-Za-z]{3,9})\s+(\d{1,2})(?:,?\s*(20\d{2}))?$/.exec(value.trim());
  if (!match) return null;
  const month = MONTHS[match[1]!.toLowerCase()];
  const day = Number(match[2]);
  const year = match[3] ? Number(match[3]) : fallbackYear;
  return buildTextDate(year ?? null, month, day);
}

function assertFileSignature(format: StatementFormat, bytes: Buffer): void {
  if (format === 'csv') return;
  if (format === 'xlsx') {
    if (bytes[0] !== 0x50 || bytes[1] !== 0x4b) throw new Error('The XLSX upload is not a valid ZIP-based workbook.');
    return;
  }
  if (format === 'pdf') {
    if (bytes.subarray(0, 5).toString('ascii') !== '%PDF-') throw new Error('The PDF upload does not have a valid PDF signature.');
    return;
  }
  const isPng = bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
  const isJpeg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const isWebp = bytes.subarray(0, 4).toString('ascii') === 'RIFF' && bytes.subarray(8, 12).toString('ascii') === 'WEBP';
  const isTiff = bytes.subarray(0, 4).equals(Buffer.from([0x49, 0x49, 0x2a, 0x00])) || bytes.subarray(0, 4).equals(Buffer.from([0x4d, 0x4d, 0x00, 0x2a]));
  const isBmp = bytes.subarray(0, 2).toString('ascii') === 'BM';
  if (!isPng && !isJpeg && !isWebp && !isTiff && !isBmp) throw new Error('The image upload does not have a supported image signature.');
}

function analyzeTabular(
  format: StatementFormat,
  content: string,
  statementHash: string,
  input: StatementAnalyzeInput,
  model: UserCorrectionClassifier,
): StatementExtraction {
  const documentDetails = extractStatementDetails(content, input.currency);
  assertCurrencyMatchesAccount(documentDetails.currency, input.currency);
  const parsed = parseCsv(content);
  if (parsed.rows.length > MAX_ROWS) throw new Error(`A statement may contain at most ${MAX_ROWS} rows.`);
  const suggestion = suggestMapping(parsed.headers, parsed.rows.slice(0, 25));
  if (!suggestion.mapping) {
    return { format, rows: [], warnings: suggestion.warnings, statementHash };
  }
  const review = reviewImport({
    headers: parsed.headers,
    rows: parsed.rows,
    mapping: suggestion.mapping,
    existing: input.existing,
    currency: input.currency,
    raggedLines: parsed.raggedLines,
  });
  const ambiguousDates = suggestion.warnings.some((warning) => /ambiguous/i.test(warning));
  return {
    format,
    rows: review.rows.map((row) => draftFromReviewed(row, input.currency, input.rules, ambiguousDates, model)),
    warnings: suggestion.warnings,
    statementHash,
    documentDetails,
  };
}

function draftFromReviewed(
  row: ReviewedRow,
  currency: string,
  rules: readonly CategorizationRule[],
  ambiguousDates: boolean,
  model: UserCorrectionClassifier,
): StatementRowDraft {
  const description = row.descriptor ?? row.raw.filter(Boolean).join(' ').slice(0, 500);
  const categorized = row.descriptor
    ? categorizeStatementDescriptor(row.descriptor, { rules, model, amount: row.amount })
    : null;
  const flags: string[] = [];
  if (row.decision === 'duplicate') flags.push('possible_duplicate');
  if (row.decision === 'invalid') flags.push('extraction_error');
  if (ambiguousDates && row.postedAt) flags.push('ambiguous_date');
  if (categorized && categorized.confidence < 0.7) flags.push('low_confidence');
  if (!categorized || categorized.categorySlug === 'unknown') flags.push('uncategorized');
  const decision = row.decision === 'import' && flags.length === 0 ? 'include' : 'needs_review';
  const fingerprint = createHash('sha256')
    .update(`${row.line}|${row.postedAt ?? ''}|${row.amount ?? ''}|${normalizeDescriptor(description)}|${currency}`)
    .digest('hex');
  return {
    sourceLine: row.line,
    postedAt: row.postedAt ?? null,
    description,
    merchant: categorized?.merchant ?? null,
    amount: row.amount ?? null,
    currency,
    direction: row.amount === undefined || row.amount === null ? 'unknown' : row.amount < 0 ? 'debit' : 'credit',
    categorySlug: categorized?.categorySlug ?? UNKNOWN_CATEGORY,
    categorySource: categorized?.source ?? 'unknown',
    categoryConfidence: categorized?.confidence ?? 0,
    isRecurring: false,
    flags: [...flags, ...(row.reason ? [row.reason] : [])].slice(0, 8),
    decision,
    fingerprint,
    raw: row.raw.join(' | ').slice(0, 2_000),
  };
}

function parseTextRows(
  text: string,
  currency: string,
  rules: readonly CategorizationRule[],
  existing: readonly Transaction[],
  model: UserCorrectionClassifier,
): StatementRowDraft[] {
  const lines = text.split(/\r?\n/).map((line) => line.replace(/\s+/g, ' ').trim()).filter(Boolean);
  // Deposit-account statements often separate a multiline description from
  // an amount/balance pair and omit the date on subsequent same-day rows.
  // Reconstruct those rows using exact balance arithmetic before trying the
  // generic one-line parser.
  const bankRows = parseBankAccountRows(lines, text, currency, rules, existing, model);
  if (bankRows.length > 0) return bankRows;
  // Many card issuers put two textual dates and a positive charge amount on
  // each row (for example, "Aug 01 Aug 04 MERCHANT Restaurants 7.33").
  // Those amounts are debits even though they do not carry a minus sign. Parse
  // this well-known statement shape before the generic signed-amount parser so
  // charges are not mistaken for income.
  const cardRows = parseCreditCardRows(lines, text, currency, rules, existing, model);
  if (cardRows.length > 0) return cardRows;

  const dates = lines.map((line) => /\b\d{1,4}[\/-]\d{1,2}[\/-]\d{1,4}\b/.exec(line)?.[0] ?? '').filter(Boolean);
  const dateOrder = dates.some((date) => /^\d{4}/.test(date)) ? 'YMD' : 'DMY';
  const ambiguousDate = dates.length > 0 && !dates.some((date) => {
    const match = /^(\d{1,2})[\/-](\d{1,2})/.exec(date);
    return match ? Number(match[1]) > 12 || Number(match[2]) > 12 : /^\d{4}/.test(date);
  });
  const rows: StatementRowDraft[] = [];
  for (let index = 0; index < lines.length && rows.length < MAX_ROWS; index += 1) {
    const line = lines[index]!;
    const dateMatch = /\b(\d{4}[\/-]\d{1,2}[\/-]\d{1,2}|\d{1,2}[\/-]\d{1,2}[\/-]\d{2,4})\b/.exec(line);
    if (!dateMatch) continue;
    const amountMatch = /(?:\(|-)?\s*[$€£]?\d[\d,.]*\.?\d{0,2}\)?\s*$/.exec(line);
    if (!amountMatch) continue;
    const postedAt = parseDate(dateMatch[1]!, dateOrder);
    const amountText = amountMatch[0].trim();
    const amount = parseAmount(amountText, currency);
    const description = line
      .replace(dateMatch[0], '')
      .replace(amountMatch[0], '')
      .replace(/\s{2,}/g, ' ')
      .trim();
    const categorized = description
      ? categorizeStatementDescriptor(description, { rules, model, amount })
      : null;
    const flags = [
      ...(postedAt ? [] : ['extraction_error']),
      ...(amount === null || amount === 0 ? ['extraction_error'] : []),
      ...(ambiguousDate ? ['ambiguous_date'] : []),
      ...(categorized && categorized.confidence < 0.7 ? ['low_confidence'] : []),
      ...(!categorized || categorized.categorySlug === 'unknown' ? ['uncategorized'] : []),
    ];
    const fingerprint = createHash('sha256').update(`${index + 1}|${postedAt ?? ''}|${amount ?? ''}|${normalizeDescriptor(description)}|${currency}`).digest('hex');
    const existingMatch = existing.some((txn) => txn.postedAt === postedAt && txn.amount === amount && txn.normalizedDescriptor === normalizeDescriptor(description));
    if (existingMatch) flags.push('possible_duplicate');
    rows.push({
      sourceLine: index + 1,
      postedAt,
      description: description.slice(0, 500),
      merchant: categorized?.merchant ?? null,
      amount,
      currency,
      direction: amount === null ? 'unknown' : amount < 0 ? 'debit' : 'credit',
      categorySlug: categorized?.categorySlug ?? UNKNOWN_CATEGORY,
      categorySource: categorized?.source ?? 'unknown',
      categoryConfidence: categorized?.confidence ?? 0,
      isRecurring: false,
      flags: flags.slice(0, 8),
      decision: flags.length === 0 ? 'include' : 'needs_review',
      fingerprint,
      raw: line.slice(0, 2_000),
    });
  }
  return rows;
}

const MONTHS: Record<string, number> = {
  jan: 1, january: 1, feb: 2, february: 2, mar: 3, march: 3,
  apr: 4, april: 4, may: 5, jun: 6, june: 6, jul: 7, july: 7,
  aug: 8, august: 8, sep: 9, sept: 9, september: 9, oct: 10,
  october: 10, nov: 11, november: 11, dec: 12, december: 12,
};

const CARD_CATEGORY_LABELS = [
  'Retail and Grocery', 'Restaurants', 'Transportation',
  'Personal and Household Expenses', 'Professional and Financial Services',
  'Home and Office Improvement', 'Entertainment', 'Travel', 'Other',
];

function parseBankAccountRows(
  lines: readonly string[],
  text: string,
  currency: string,
  rules: readonly CategorizationRule[],
  existing: readonly Transaction[],
  model: UserCorrectionClassifier,
): StatementRowDraft[] {
  if (!/\btransaction details\b/i.test(text)
    || !/\bwithdrawals?\s*\([^)]*\)\s+deposits?\s*\([^)]*\)\s+balance\s*\(/i.test(text)
    || !/\baccount statement\b/i.test(text)) return [];

  const details = extractStatementDetails(text, currency);
  const endDate = details.periodEnd ? new Date(`${details.periodEnd}T00:00:00Z`) : null;
  const startDate = details.periodStart ? new Date(`${details.periodStart}T00:00:00Z`) : null;
  const fallbackYear = findStatementYear(text);
  const rows: StatementRowDraft[] = [];
  const pendingDescription: string[] = [];
  const monthPattern = Object.keys(MONTHS).join('|');
  const datedLine = new RegExp(`^(${monthPattern})\\s+(\\d{1,2})(?:\\s+(.+))?$`, 'i');
  const amountBalance = /^(.*?)(?:\$)?(\d[\d,]*\.\d{2})\s+(?:\$)?(\d[\d,]*\.\d{2})$/;
  let inTransactions = false;
  let postedAt: string | null = null;
  let previousBalance: number | null = null;

  const dateFor = (monthName: string, dayText: string): string | null => {
    const month = MONTHS[monthName.toLowerCase()];
    if (month === undefined) return null;
    let year = fallbackYear;
    if (startDate && endDate && startDate.getUTCFullYear() !== endDate.getUTCFullYear()) {
      year = month >= startDate.getUTCMonth() + 1
        ? startDate.getUTCFullYear()
        : endDate.getUTCFullYear();
    }
    return buildTextDate(year, month, Number(dayText));
  };

  const setBalanceMarker = (line: string): boolean => {
    if (!/\b(?:opening|balance forward|closing) balance\b/i.test(line)) return false;
    const balanceText = /(?:\$)?(\d[\d,]*\.\d{2})\s*$/.exec(line)?.[1];
    const balance = balanceText ? parseAmount(balanceText, currency) : null;
    if (balance !== null) previousBalance = balance;
    pendingDescription.length = 0;
    return true;
  };

  for (let index = 0; index < lines.length && rows.length < MAX_ROWS; index += 1) {
    let line = lines[index]!;
    if (/^Transaction details/i.test(line)) {
      inTransactions = true;
      pendingDescription.length = 0;
      continue;
    }
    if (!inTransactions) continue;
    if (/^Important:/i.test(line)) break;
    if (/^Date Description Withdrawals/i.test(line)
      || /^\(continued on next page\)$/i.test(line)
      || /^-- \d+ of \d+ --$/i.test(line)
      || /^CIBC Account Statement/i.test(line)
      || /^Account number:/i.test(line)
      || /^Branch transit number:/i.test(line)
      || /^\w+ PER-\d/i.test(line)) continue;

    const dateMatch = datedLine.exec(line);
    if (dateMatch) {
      postedAt = dateFor(dateMatch[1]!, dateMatch[2]!);
      pendingDescription.length = 0;
      line = dateMatch[3]?.trim() ?? '';
      if (!line) continue;
    }
    if (setBalanceMarker(line)) continue;

    const pair = amountBalance.exec(line);
    if (!pair) {
      pendingDescription.push(line);
      continue;
    }

    const unsignedAmount = parseAmount(pair[2]!, currency);
    const endingBalance = parseAmount(pair[3]!, currency);
    const inlineDescription = pair[1]!.trim();
    const raw = [...pendingDescription, line].join(' | ');
    const description = [...pendingDescription, inlineDescription]
      .filter(Boolean)
      .join(' ')
      .replace(/\s+/g, ' ')
      .trim();
    pendingDescription.length = 0;
    if (!description || unsignedAmount === null || endingBalance === null) {
      if (endingBalance !== null) previousBalance = endingBalance;
      continue;
    }

    let signedAmount: number | null = null;
    if (previousBalance !== null) {
      const isCredit = previousBalance + Math.abs(unsignedAmount) === endingBalance;
      const isDebit = previousBalance - Math.abs(unsignedAmount) === endingBalance;
      if (isCredit !== isDebit) signedAmount = isCredit ? Math.abs(unsignedAmount) : -Math.abs(unsignedAmount);
    }
    rows.push(textDraft({
      sourceLine: index + 1,
      raw,
      postedAt,
      amount: signedAmount,
      currency,
      description,
      rules,
      existing,
      model,
    }));
    previousBalance = endingBalance;
  }
  return rows;
}

function parseCreditCardRows(
  lines: readonly string[],
  text: string,
  currency: string,
  rules: readonly CategorizationRule[],
  existing: readonly Transaction[],
  model: UserCorrectionClassifier,
): StatementRowDraft[] {
  // Require a statement-year anchor. A month/day without a year is not safe
  // to import because a statement can span December and January.
  const year = findStatementYear(text);
  if (year === null || !/(?:credit card|card account|card number|spend categories|new charges and credits)/i.test(text)) return [];

  const rows: StatementRowDraft[] = [];
  const datePattern = Object.keys(MONTHS).join('|');
  const rowPattern = new RegExp(`^(${datePattern})\\s+(\\d{1,2})\\s+(${datePattern})\\s+(\\d{1,2})\\s+(.+?)\\s+((?:\\(?[-+]?[$€£]?\\d[\\d,.]*\\)?))$`, 'i');

  for (let index = 0; index < lines.length && rows.length < MAX_ROWS; index += 1) {
    const line = lines[index]!;
    const match = rowPattern.exec(line);
    if (!match) continue;

    const transactionMonth = MONTHS[match[1]!.toLowerCase()];
    const transactionDay = Number(match[2]);
    const postedAt = buildTextDate(year, transactionMonth, transactionDay);
    const amount = parseAmount(match[6]!, currency);
    let description = match[5]!.trim();
    let issuerCategory: string | undefined;
    // Issuer-provided spend labels are metadata, not part of the merchant
    // name. Strip only a known suffix so a similarly named merchant is kept.
    for (const label of CARD_CATEGORY_LABELS) {
      const suffix = new RegExp(`\\s+${escapeRegExp(label)}$`, 'i');
      if (suffix.test(description)) {
        issuerCategory = label;
        description = description.replace(suffix, '').trim();
        break;
      }
    }

    const normalized = normalizeDescriptor(description);
    const isCredit = /\b(payment|credit|refund|reversal)\b/i.test(normalized);
    const signedAmount = amount === null ? null : isCredit ? Math.abs(amount) : -Math.abs(amount);
    rows.push(textDraft({
      sourceLine: index + 1,
      raw: line,
      postedAt,
      amount: signedAmount,
      currency,
      description,
      issuerCategory,
      rules,
      existing,
      model,
    }));
  }
  return rows;
}

function findStatementYear(text: string): number | null {
  const explicit = /(?:statement date|statement period|to)\b[^\d]*(20\d{2})\b/i.exec(text)?.[1];
  const fallback = /\b(20\d{2})\b/.exec(text)?.[1];
  const year = Number(explicit ?? fallback ?? '');
  return year >= 2000 && year <= 2100 ? year : null;
}

function buildTextDate(year: number | null, month: number | undefined, day: number): string | null {
  if (year === null || month === undefined || day < 1 || day > 31) return null;
  const date = new Date(Date.UTC(year, month - 1, day));
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null;
  return `${year.toString().padStart(4, '0')}-${month.toString().padStart(2, '0')}-${day.toString().padStart(2, '0')}`;
}

function textDraft(input: {
  sourceLine: number;
  raw: string;
  postedAt: string | null;
  amount: number | null;
  currency: string;
  description: string;
  issuerCategory?: string;
  rules: readonly CategorizationRule[];
  existing: readonly Transaction[];
  model: UserCorrectionClassifier;
}): StatementRowDraft {
  const categorizedByMerchant = input.description
    ? categorizeDescriptor(input.description, {
      rules: input.rules,
      model: input.model,
    })
    : null;
  const categorized = categorizedByMerchant?.categorySlug !== UNKNOWN_CATEGORY
    ? categorizedByMerchant
    : issuerCategoryResult(input.issuerCategory) ?? (
      input.description
        ? categorizeStatementDescriptor(input.description, {
          rules: input.rules,
          model: input.model,
          amount: input.amount,
        })
        : categorizedByMerchant
    );
  const normalized = normalizeDescriptor(input.description);
  const flags = [
    ...(input.postedAt ? [] : ['extraction_error']),
    ...(input.amount === null || input.amount === 0 ? ['extraction_error'] : []),
    ...(categorized && categorized.confidence < 0.7 ? ['low_confidence'] : []),
    ...(!categorized || categorized.categorySlug === UNKNOWN_CATEGORY ? ['uncategorized'] : []),
  ];
  if (input.existing.some((txn) => txn.postedAt === input.postedAt && txn.amount === input.amount && txn.normalizedDescriptor === normalized)) {
    flags.push('possible_duplicate');
  }
  const fingerprint = createHash('sha256')
    .update(`${input.sourceLine}|${input.postedAt ?? ''}|${input.amount ?? ''}|${normalized}|${input.currency}`)
    .digest('hex');
  return {
    sourceLine: input.sourceLine,
    postedAt: input.postedAt,
    description: input.description.slice(0, 500),
    merchant: categorized?.merchant ?? null,
    amount: input.amount,
    currency: input.currency,
    direction: input.amount === null ? 'unknown' : input.amount < 0 ? 'debit' : 'credit',
    categorySlug: categorized?.categorySlug ?? UNKNOWN_CATEGORY,
    categorySource: categorized?.source ?? 'unknown',
    categoryConfidence: categorized?.confidence ?? 0,
    isRecurring: false,
    flags: flags.slice(0, 8),
    decision: flags.length === 0 ? 'include' : 'needs_review',
    fingerprint,
    raw: input.raw.slice(0, 2_000),
  };
}

/**
 * Apply statement-specific semantics that a merchant lexicon cannot safely
 * infer. Card payments and account transfers are money movement, not income;
 * leaving a positive payment as unknown would inflate cash flow.
 */
export function categorizeStatementDescriptor(
  description: string,
  options: {
    rules: readonly CategorizationRule[];
    model: UserCorrectionClassifier;
    amount?: number | null;
  },
): ReturnType<typeof categorizeDescriptor> {
  const categorized = categorizeDescriptor(description, options);
  if (categorized.categorySlug !== UNKNOWN_CATEGORY) return categorized;

  const normalized = normalizeDescriptor(description);
  if (/\b(payment received|payment thank you|card payment|credit card payment|minimum payment)\b/i.test(normalized)) {
    return {
      categorySlug: 'credit_card_payment',
      source: 'lexicon',
      confidence: 0.99,
      merchant: 'Credit card payment',
      reason: 'Identified as a payment toward a credit-card balance; excluded from income and spending.',
    };
  }
  if (/\b(e[- ]?transfer|etransfer|interac|transfer from|transfer to|internal transfer)\b/i.test(normalized)) {
    return {
      categorySlug: 'transfer',
      source: 'lexicon',
      confidence: 0.96,
      merchant: 'Account transfer',
      reason: 'Identified as money movement between accounts, not income or spending.',
    };
  }
  if ((options.amount ?? 0) > 0 && /^pay\b/i.test(normalized)) {
    return {
      categorySlug: 'salary',
      source: 'lexicon',
      confidence: 0.78,
      merchant: normalized.replace(/^pay\s+\d+\s*/i, '').trim() || 'Payroll deposit',
      reason: 'Identified as a payroll-style bank deposit; review if this is not employment income.',
    };
  }
  if ((options.amount ?? 0) > 0 && /\bservice charge discount\b/i.test(normalized)) {
    return {
      categorySlug: 'refunds',
      source: 'lexicon',
      confidence: 0.94,
      merchant: 'Fee reversal',
      reason: 'Identified as a reversal of a bank service charge.',
    };
  }
  if ((options.amount ?? 0) < 0 && /\bservice charge\b/i.test(normalized)) {
    return {
      categorySlug: 'fees',
      source: 'lexicon',
      confidence: 0.96,
      merchant: 'Bank service charge',
      reason: 'Identified as a bank service charge.',
    };
  }
  if ((options.amount ?? 0) < 0 && /\binternet bill pay\b.*\b(mastercard|capital one|visa)\b/i.test(normalized)) {
    return {
      categorySlug: 'credit_card_payment',
      source: 'lexicon',
      confidence: 0.96,
      merchant: 'Credit card payment',
      reason: 'Identified as a bill payment toward a credit-card balance.',
    };
  }
  if ((options.amount ?? 0) > 0 && /\bdeposit\b/i.test(normalized)) {
    return {
      categorySlug: 'income',
      source: 'lexicon',
      confidence: 0.72,
      merchant: 'Deposit',
      reason: 'Identified as money deposited into the account.',
    };
  }

  const semanticRules: ReadonlyArray<{
    pattern: RegExp;
    categorySlug: string;
    merchant: string;
    confidence: number;
  }> = [
    { pattern: /\b(vend(?:ing|i)?|snack|soda|convenience|canteen)\b/i, categorySlug: 'fast_food', merchant: 'Food and drink', confidence: 0.84 },
    { pattern: /\b(grocery|grocer|supermarket|food market|produce)\b/i, categorySlug: 'groceries', merchant: 'Grocery store', confidence: 0.82 },
    { pattern: /\b(cafe|coffee|espresso|bakery|diner|restaurant|pizza|burger|kitchen)\b/i, categorySlug: 'restaurants', merchant: 'Dining', confidence: 0.8 },
    { pattern: /\b(bus|train|transit|subway|metro|rail|taxi|cab|rideshare)\b/i, categorySlug: 'public_transit', merchant: 'Transit', confidence: 0.8 },
    { pattern: /\b(parking|parkade|meter)\b/i, categorySlug: 'parking', merchant: 'Parking', confidence: 0.86 },
    { pattern: /\b(gas station|fuel|petrol|service station)\b/i, categorySlug: 'fuel', merchant: 'Fuel', confidence: 0.82 },
    { pattern: /\b(pharmacy|drug store|prescription)\b/i, categorySlug: 'pharmacy', merchant: 'Pharmacy', confidence: 0.84 },
    { pattern: /\b(clinic|medical|dental|optical|health)\b/i, categorySlug: 'healthcare', merchant: 'Healthcare', confidence: 0.78 },
    { pattern: /\b(hydro|electric|energy|water bill|utility)\b/i, categorySlug: 'utilities', merchant: 'Utilities', confidence: 0.82 },
    { pattern: /\b(phone bill|mobile plan|wireless)\b/i, categorySlug: 'phone', merchant: 'Phone service', confidence: 0.8 },
    { pattern: /\b(internet|broadband|fibre|fiber)\b/i, categorySlug: 'internet', merchant: 'Internet service', confidence: 0.8 },
    { pattern: /\b(subscription|membership|monthly plan)\b/i, categorySlug: 'subscriptions', merchant: 'Subscription', confidence: 0.8 },
    { pattern: /\b(software|cloud|hosting|domain renewal)\b/i, categorySlug: 'software', merchant: 'Software', confidence: 0.8 },
    { pattern: /\b(cinema|movie|theatre|theater|concert|museum)\b/i, categorySlug: 'entertainment', merchant: 'Entertainment', confidence: 0.8 },
    { pattern: /\b(hotel|airline|flight|travel|resort)\b/i, categorySlug: 'travel', merchant: 'Travel', confidence: 0.82 },
    { pattern: /\b(apparel|clothing|fashion|shoe|footwear)\b/i, categorySlug: 'clothing', merchant: 'Clothing', confidence: 0.8 },
    { pattern: /\b(electronics|computer|laptop|mobile device)\b/i, categorySlug: 'electronics', merchant: 'Electronics', confidence: 0.8 },
    { pattern: /\b(store|shop|retail|marketplace|mall)\b/i, categorySlug: 'shopping', merchant: 'Retail', confidence: 0.74 },
    { pattern: /\b(insurance|assurance)\b/i, categorySlug: 'insurance', merchant: 'Insurance', confidence: 0.84 },
    { pattern: /\b(tax|revenue agency)\b/i, categorySlug: 'taxes', merchant: 'Taxes', confidence: 0.82 },
    { pattern: /\b(fee|service charge|interest charge)\b/i, categorySlug: 'fees', merchant: 'Fees', confidence: 0.82 },
  ];
  const semantic = semanticRules.find((rule) => rule.pattern.test(normalized));
  if (semantic) {
    return {
      categorySlug: semantic.categorySlug,
      source: 'model',
      confidence: semantic.confidence,
      merchant: semantic.merchant,
      reason: `Inferred ${semantic.categorySlug.replaceAll('_', ' ')} from the transaction description.`,
    };
  }

  if ((options.amount ?? 0) > 0) {
    return {
      categorySlug: 'income',
      source: 'model',
      confidence: 0.7,
      merchant: normalized || 'Income',
      reason: 'Classified as income because the statement records money entering the account.',
    };
  }
  if ((options.amount ?? 0) < 0) {
    return {
      categorySlug: 'other_expenses',
      source: 'model',
      confidence: 0.7,
      merchant: normalized || 'Other expense',
      reason: 'Classified as another expense because the statement records money leaving the account.',
    };
  }
  return categorized;
}

function issuerCategoryResult(label: string | undefined): { categorySlug: string; source: 'lexicon'; confidence: number; merchant?: string; reason: string } | null {
  if (!label) return null;
  if (/restaurant/i.test(label)) return { categorySlug: 'restaurants', source: 'lexicon', confidence: 0.82, merchant: 'Restaurant', reason: 'Matched the issuer-provided spend category.' };
  if (/transportation/i.test(label)) return { categorySlug: 'transportation', source: 'lexicon', confidence: 0.82, merchant: 'Transportation', reason: 'Matched the issuer-provided spend category.' };
  if (/retail and grocery/i.test(label)) return { categorySlug: 'groceries', source: 'lexicon', confidence: 0.72, merchant: 'Retail and Grocery', reason: 'Matched the issuer-provided spend category.' };
  if (/entertainment/i.test(label)) return { categorySlug: 'entertainment', source: 'lexicon', confidence: 0.78, merchant: 'Entertainment', reason: 'Matched the issuer-provided spend category.' };
  return null;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\[\]\\]/g, '\\$&');
}

async function extractPdfText(bytes: Buffer): Promise<string> {
  const module = await import('pdf-parse');
  const parser = new module.PDFParse({ data: bytes });
  try {
    const result = await parser.getText();
    const text = result.text ?? '';
    // Scanned statements have no text layer. Render a bounded number of pages
    // and send only those in-memory images through the same local OCR path used
    // for image uploads. If a text layer already contains transaction-shaped
    // content, avoid OCR so we do not duplicate rows from hybrid PDFs.
    if (hasTransactionText(text)) return text;
    const screenshots = await parser.getScreenshot({
      first: MAX_PDF_OCR_PAGES,
      desiredWidth: 1600,
      imageBuffer: true,
      imageDataUrl: false,
    });
    const images = screenshots.pages
      .map((page) => page.data)
      .filter((image): image is Uint8Array => image instanceof Uint8Array && image.length > 0);
    if (images.length === 0) return text;
    const ocrText = await recognizeImages(images);
    return [text.trim(), ocrText.trim()].filter(Boolean).join('\n');
  } finally {
    await parser.destroy();
  }
}

async function extractImageText(bytes: Buffer): Promise<string> {
  return recognizeImages([bytes]);
}

function hasTransactionText(text: string): boolean {
  return /\b\d{4}[\/-]\d{1,2}[\/-]\d{1,2}\b[^\r\n]*[-+]?[$€£]?\d[\d,.]*\.?\d{0,2}\s*$/m.test(text)
    || /\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{1,2}\s+(?:[A-Za-z]{3,9}\s+\d{1,2}\s+)?[^\r\n]*[-+]?[$€£]?\d[\d,.]*\.?\d{0,2}\s*$/im.test(text);
}

async function recognizeImages(images: readonly Uint8Array[]): Promise<string> {
  // Tesseract ships with the English model in the application image. No
  // network request or third-party model service is involved.
  const tesseract = await import('tesseract.js');
  // The data package intentionally exposes a path rather than embedding a
  // 25MB model in this source tree.
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const lang = require('@tesseract.js-data/eng') as { langPath: string };
  const worker = await tesseract.createWorker('eng', 1, { langPath: lang.langPath, gzip: true, logger: () => undefined });
  try {
    const pages: string[] = [];
    for (const image of images) {
      const result = await worker.recognize(image);
      if (result.data.text) pages.push(result.data.text);
    }
    return pages.join('\n');
  } finally {
    await worker.terminate();
  }
}

function xlsxToCsv(bytes: Buffer): string {
  // XLSX is a ZIP of XML parts. Parsing only worksheet cells and shared strings
  // keeps the attack surface small and lets us bound decompression before XML
  // processing. Formulas are never evaluated.
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { unzipSync } = require('fflate') as { unzipSync(input: Uint8Array): Record<string, Uint8Array> };
  assertZipExpansionBudget(bytes);
  const parts = unzipSync(bytes);
  const total = Object.values(parts).reduce((sum, value) => sum + value.length, 0);
  if (total > MAX_DECOMPRESSED_BYTES) throw new Error('The XLSX decompressed size exceeds the safety limit.');
  const shared = parseSharedStrings(parts['xl/sharedStrings.xml']);
  const sheet = parts['xl/worksheets/sheet1.xml'];
  if (!sheet) throw new Error('The XLSX file does not contain a first worksheet.');
  const xml = Buffer.from(sheet).toString('utf8');
  const rows: string[][] = [];
  const rowMatches = xml.match(/<row\b[^>]*>[\s\S]*?<\/row>/g) ?? [];
  if (rowMatches.length > MAX_ROWS) throw new Error(`An XLSX worksheet may contain at most ${MAX_ROWS} rows.`);
  for (const rowXml of rowMatches) {
    const cells: string[] = [];
    for (const cellXml of rowXml.match(/<c\b[^>]*>[\s\S]*?<\/c>/g) ?? []) {
      const ref = /\br="([A-Z]+)\d+"/.exec(cellXml)?.[1] ?? '';
      const column = columnNumber(ref);
      if (column >= MAX_XLSX_COLUMNS) throw new Error('The XLSX worksheet contains a column beyond Excel\'s XFD limit.');
      while (cells.length < column) cells.push('');
      const type = /\bt="([^" ]+)"/.exec(cellXml)?.[1];
      const value = decodeXml(/<v>([\s\S]*?)<\/v>/.exec(cellXml)?.[1] ?? /<t>([\s\S]*?)<\/t>/.exec(cellXml)?.[1] ?? '');
      cells[column] = type === 's' ? shared[Number(value)] ?? '' : value;
    }
    rows.push(cells);
  }
  normalizeExcelDateColumns(rows);
  return rows.map((row) => row.map(csvEscape).join(',')).join('\n');
}

function normalizeExcelDateColumns(rows: string[][]): void {
  const headers = rows[0] ?? [];
  const dateColumns = headers
    .map((header, index) => /\b(?:date|posted|posting|booking|completed|trans)\b/i.test(header) ? index : -1)
    .filter((index) => index >= 0);
  if (dateColumns.length === 0) return;

  for (const row of rows.slice(1)) {
    for (const column of dateColumns) {
      const value = row[column]?.trim() ?? '';
      if (!/^\d+(?:\.\d+)?$/.test(value)) continue;
      const serial = Number(value);
      if (!Number.isFinite(serial) || serial < 1 || serial > 100_000) continue;
      const date = new Date(Date.UTC(1899, 11, 30) + Math.floor(serial) * 86_400_000);
      if (Number.isNaN(date.getTime())) continue;
      row[column] = `${date.getUTCFullYear().toString().padStart(4, '0')}-${(date.getUTCMonth() + 1).toString().padStart(2, '0')}-${date.getUTCDate().toString().padStart(2, '0')}`;
    }
  }
}

/**
 * Validate ZIP metadata before fflate allocates decompressed buffers. XLSX is
 * user supplied and its central directory is the only bounded source of the
 * entry sizes available before inflation. ZIP64 and multi-disk archives are
 * rejected because they cannot be safely bounded by this parser.
 */
function assertZipExpansionBudget(bytes: Buffer): void {
  if (bytes.length < 22) throw new Error('The XLSX file is missing a valid ZIP directory.');
  const minimumEnd = Math.max(0, bytes.length - (22 + 0xffff));
  let eocd = -1;
  for (let offset = bytes.length - 22; offset >= minimumEnd; offset -= 1) {
    if (bytes.readUInt32LE(offset) === 0x06054b50) {
      eocd = offset;
      break;
    }
  }
  if (eocd < 0) throw new Error('The XLSX file is missing a valid ZIP directory.');

  const disk = bytes.readUInt16LE(eocd + 4);
  const directoryDisk = bytes.readUInt16LE(eocd + 6);
  const entriesOnDisk = bytes.readUInt16LE(eocd + 8);
  const entries = bytes.readUInt16LE(eocd + 10);
  const directorySize = bytes.readUInt32LE(eocd + 12);
  const directoryOffset = bytes.readUInt32LE(eocd + 16);
  if (disk !== 0 || directoryDisk !== 0 || entriesOnDisk !== entries || entries === 0 || entries > MAX_ZIP_ENTRIES) {
    throw new Error('The XLSX ZIP directory is invalid or contains too many entries.');
  }
  if (directorySize > bytes.length || directoryOffset > bytes.length || directoryOffset + directorySize > eocd) {
    throw new Error('The XLSX ZIP directory is outside the uploaded file.');
  }

  let cursor = directoryOffset;
  let total = 0;
  for (let index = 0; index < entries; index += 1) {
    if (cursor + 46 > eocd || bytes.readUInt32LE(cursor) !== 0x02014b50) {
      throw new Error('The XLSX ZIP directory contains a malformed entry.');
    }
    const compressedSize = bytes.readUInt32LE(cursor + 20);
    const uncompressedSize = bytes.readUInt32LE(cursor + 24);
    const nameLength = bytes.readUInt16LE(cursor + 28);
    const extraLength = bytes.readUInt16LE(cursor + 30);
    const commentLength = bytes.readUInt16LE(cursor + 32);
    const localOffset = bytes.readUInt32LE(cursor + 42);
    if (compressedSize === 0xffffffff || uncompressedSize === 0xffffffff || localOffset === 0xffffffff) {
      throw new Error('ZIP64 XLSX archives are not supported.');
    }
    const recordLength = 46 + nameLength + extraLength + commentLength;
    if (cursor + recordLength > eocd || localOffset >= bytes.length) {
      throw new Error('The XLSX ZIP directory contains an out-of-bounds entry.');
    }
    if (uncompressedSize > MAX_DECOMPRESSED_BYTES || compressedSize > bytes.length) {
      throw new Error('The XLSX decompressed size exceeds the safety limit.');
    }
    total += uncompressedSize;
    if (total > MAX_DECOMPRESSED_BYTES) throw new Error('The XLSX decompressed size exceeds the safety limit.');
    cursor += recordLength;
  }
  if (cursor !== directoryOffset + directorySize) throw new Error('The XLSX ZIP directory length is invalid.');
}

function parseSharedStrings(bytes: Uint8Array | undefined): string[] {
  if (!bytes) return [];
  const xml = Buffer.from(bytes).toString('utf8');
  return [...xml.matchAll(/<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g)].map((match) => decodeXml(match[1] ?? ''));
}

function columnNumber(letters: string): number {
  let result = 0;
  for (const char of letters) result = result * 26 + char.charCodeAt(0) - 64;
  return Math.max(0, result - 1);
}

function csvEscape(value: string): string {
  return /[",\n]/.test(value) ? `"${value.replaceAll('"', '""')}"` : value;
}

function decodeXml(value: string): string {
  // Decode each entity exactly once. A chained replace can turn `&amp;lt;`
  // into `<`, even though the XML source only encoded the literal `&lt;`.
  return value.replace(/&(?:amp|lt|gt|quot|apos);/g, (entity) => {
    switch (entity) {
      case '&amp;': return '&';
      case '&lt;': return '<';
      case '&gt;': return '>';
      case '&quot;': return '"';
      case '&apos;': return "'";
      default: return entity;
    }
  });
}
