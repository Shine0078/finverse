// Wire models mirroring the API's response shapes.
//
// Monetary fields arrive twice: an integer in minor units for arithmetic and
// comparison, and a preformatted display string. The client renders the
// string and never re-derives it, so currency formatting stays consistent
// across platforms and never drifts from the server's view (ADR-0003).

/// A recorded claim about what an account actually held on a date, alongside
/// what FINVERSE derived. Evidence, not a correction — recording one never
/// edits the ledger.
class Reconciliation {
  const Reconciliation({
    required this.id,
    required this.accountId,
    required this.accountName,
    required this.statementDate,
    required this.observedBalance,
    required this.computedBalance,
    required this.difference,
    required this.observedFormatted,
    required this.computedFormatted,
    required this.differenceFormatted,
    required this.status,
    required this.source,
    required this.createdAt,
    this.note,
    this.archivedAt,
  });

  factory Reconciliation.fromJson(Map<String, dynamic> json) => Reconciliation(
        id: json['id'] as String,
        accountId: json['accountId'] as String,
        accountName: json['accountName'] as String? ?? '',
        statementDate: json['statementDate'] as String,
        observedBalance: json['observedBalance'] as int,
        computedBalance: json['computedBalance'] as int,
        difference: json['difference'] as int,
        observedFormatted: json['observedFormatted'] as String? ?? '',
        computedFormatted: json['computedFormatted'] as String? ?? '',
        differenceFormatted: json['differenceFormatted'] as String? ?? '',
        status: json['status'] as String? ?? 'unbalanced',
        source: json['source'] as String? ?? 'statement',
        createdAt: json['createdAt'] as String? ?? '',
        note: json['note'] as String?,
        archivedAt: json['archivedAt'] as String?,
      );

  final String id;
  final String accountId;
  final String accountName;
  final String statementDate;
  final int observedBalance;
  final int computedBalance;
  final int difference;
  final String observedFormatted;
  final String computedFormatted;
  final String differenceFormatted;
  final String status;
  final String source;
  final String createdAt;
  final String? note;
  final String? archivedAt;

  bool get balanced => difference == 0;
  bool get withdrawn => archivedAt != null;
}

/// What a comparison would say, without recording it.
class ReconciliationPreview {
  const ReconciliationPreview({
    required this.computedBalance,
    required this.difference,
    required this.status,
    required this.explanation,
    required this.transactionsConsidered,
    required this.computedFormatted,
    required this.differenceFormatted,
    required this.accountName,
    required this.currency,
  });

  factory ReconciliationPreview.fromJson(Map<String, dynamic> json) =>
      ReconciliationPreview(
        computedBalance: json['computedBalance'] as int,
        difference: json['difference'] as int,
        status: json['status'] as String? ?? 'unbalanced',
        explanation: json['explanation'] as String? ?? '',
        transactionsConsidered: json['transactionsConsidered'] as int? ?? 0,
        computedFormatted: json['computedFormatted'] as String? ?? '',
        differenceFormatted: json['differenceFormatted'] as String? ?? '',
        accountName: json['accountName'] as String? ?? '',
        currency: json['currency'] as String? ?? 'USD',
      );

  final int computedBalance;
  final int difference;
  final String status;

  /// Plain-language reading of the number, supplied by the API so the phone and
  /// any future client cannot describe the same figure differently.
  final String explanation;
  final int transactionsConsidered;
  final String computedFormatted;
  final String differenceFormatted;
  final String accountName;
  final String currency;

  bool get balanced => difference == 0;
}

/// Per-account reconciliation state for the "what needs checking" view.
class ReconciliationSummary {
  const ReconciliationSummary({
    required this.accountId,
    required this.accountName,
    required this.currency,
    required this.currentBalance,
    required this.currentBalanceFormatted,
    required this.overdue,
    this.lastStatementDate,
    this.lastDifference,
    this.lastDifferenceFormatted,
    this.daysSinceReconciled,
  });

  factory ReconciliationSummary.fromJson(Map<String, dynamic> json) =>
      ReconciliationSummary(
        accountId: json['accountId'] as String,
        accountName: json['accountName'] as String,
        currency: json['currency'] as String? ?? 'USD',
        currentBalance: json['currentBalance'] as int,
        currentBalanceFormatted:
            json['currentBalanceFormatted'] as String? ?? '',
        overdue: json['overdue'] as bool? ?? false,
        lastStatementDate: json['lastStatementDate'] as String?,
        lastDifference: json['lastDifference'] as int?,
        lastDifferenceFormatted: json['lastDifferenceFormatted'] as String?,
        daysSinceReconciled: json['daysSinceReconciled'] as int?,
      );

  final String accountId;
  final String accountName;
  final String currency;
  final int currentBalance;
  final String currentBalanceFormatted;
  final bool overdue;
  final String? lastStatementDate;
  final int? lastDifference;
  final String? lastDifferenceFormatted;
  final int? daysSinceReconciled;

  bool get neverReconciled => lastStatementDate == null;
}

/// The signed-in user. Never carries a password hash — the API does not send one.
class PublicUser {
  const PublicUser({
    required this.id,
    required this.email,
    required this.emailVerified,
    this.displayName,
  });

  factory PublicUser.fromJson(Map<String, dynamic> json) => PublicUser(
        id: json['id'] as String,
        email: json['email'] as String,
        emailVerified: json['emailVerified'] as bool? ?? false,
        displayName: json['displayName'] as String?,
      );

  final String id;
  final String email;
  final bool emailVerified;
  final String? displayName;

  String get label => displayName?.isNotEmpty == true ? displayName! : email;
}

class LegalDocumentPolicy {
  const LegalDocumentPolicy({required this.version, required this.url});

  factory LegalDocumentPolicy.fromJson(Map<String, dynamic> json) =>
      LegalDocumentPolicy(
        version: json['version'] as String,
        url: json['url'] as String,
      );

  final String version;
  final String url;
}

class LegalPolicies {
  const LegalPolicies({
    required this.registrationRequired,
    this.terms,
    this.privacyNotice,
  });

  factory LegalPolicies.fromJson(Map<String, dynamic> json) => LegalPolicies(
        registrationRequired: json['registrationRequired'] as bool? ?? false,
        terms: json['terms'] == null
            ? null
            : LegalDocumentPolicy.fromJson(
                json['terms'] as Map<String, dynamic>),
        privacyNotice: json['privacyNotice'] == null
            ? null
            : LegalDocumentPolicy.fromJson(
                json['privacyNotice'] as Map<String, dynamic>),
      );

  final bool registrationRequired;
  final LegalDocumentPolicy? terms;
  final LegalDocumentPolicy? privacyNotice;
}

class AppSession {
  const AppSession({
    required this.id,
    required this.issuedAt,
    required this.expiresAt,
    required this.current,
    this.lastUsedAt,
    this.userAgent,
    this.ipAddress,
  });

  factory AppSession.fromJson(Map<String, dynamic> json) => AppSession(
        id: json['id'] as String,
        issuedAt: json['issuedAt'] as String,
        expiresAt: json['expiresAt'] as String,
        lastUsedAt: json['lastUsedAt'] as String?,
        userAgent: json['userAgent'] as String?,
        ipAddress: json['ipAddress'] as String?,
        current: json['current'] as bool,
      );

  final String id;
  final String issuedAt;
  final String expiresAt;
  final String? lastUsedAt;
  final String? userAgent;
  final String? ipAddress;
  final bool current;
}

class BankLink {
  const BankLink({
    required this.id,
    required this.institutionName,
    required this.status,
    required this.createdAt,
    this.institutionId,
    this.errorCode,
    this.lastSyncedAt,
  });

  factory BankLink.fromJson(Map<String, dynamic> json) => BankLink(
        id: json['id'] as String,
        institutionName: json['institutionName'] as String,
        institutionId: json['institutionId'] as String?,
        status: json['status'] as String,
        errorCode: json['errorCode'] as String?,
        lastSyncedAt: json['lastSyncedAt'] as String?,
        createdAt: json['createdAt'] as String,
      );

  final String id;
  final String institutionName;
  final String? institutionId;
  final String status;
  final String? errorCode;
  final String? lastSyncedAt;
  final String createdAt;

  /// A revoked Item cannot be updated in place. It still represents the
  /// user's institution in the list, but reconnecting must start a fresh Link
  /// session after account-deletion recovery or an owner-side revocation.
  bool get needsReconnect => status == 'needs_reauth' || status == 'revoked';
}

class DataQualityIssue {
  const DataQualityIssue({
    required this.code,
    required this.severity,
    required this.title,
    required this.message,
    required this.affectedCount,
  });

  factory DataQualityIssue.fromJson(Map<String, dynamic> json) =>
      DataQualityIssue(
        code: json['code'] as String,
        severity: json['severity'] as String,
        title: json['title'] as String,
        message: json['message'] as String,
        affectedCount: json['affectedCount'] as int,
      );

  final String code;
  final String severity;
  final String title;
  final String message;
  final int affectedCount;
}

class DataQualityReport {
  const DataQualityReport({
    required this.status,
    required this.score,
    required this.checkedAt,
    required this.transactionCount,
    required this.accountCoverage,
    required this.issues,
  });

  factory DataQualityReport.fromJson(Map<String, dynamic> json) =>
      DataQualityReport(
        status: json['status'] as String,
        score: json['score'] as int,
        checkedAt: DateTime.parse(json['checkedAt'] as String),
        transactionCount: json['transactionCount'] as int,
        accountCoverage: (json['accountCoverage'] as num).toDouble(),
        issues: (json['issues'] as List<dynamic>)
            .map((issue) =>
                DataQualityIssue.fromJson(issue as Map<String, dynamic>))
            .toList(),
      );

  final String status;
  final int score;
  final DateTime checkedAt;
  final int transactionCount;
  final double accountCoverage;
  final List<DataQualityIssue> issues;

  bool get needsAttention => status == 'attention';
}

class FinanceNotification {
  const FinanceNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.message,
    required this.severity,
    required this.createdAt,
    this.readAt,
  });

  factory FinanceNotification.fromJson(Map<String, dynamic> json) =>
      FinanceNotification(
        id: json['id'] as String,
        kind: json['kind'] as String,
        title: json['title'] as String,
        message: json['message'] as String,
        severity: json['severity'] as String,
        createdAt: json['createdAt'] as String,
        readAt: json['readAt'] as String?,
      );

  final String id;
  final String kind;
  final String title;
  final String message;
  final String severity;
  final String createdAt;
  final String? readAt;

  bool get unread => readAt == null;

  FinanceNotification asRead() => FinanceNotification(
        id: id,
        kind: kind,
        title: title,
        message: message,
        severity: severity,
        createdAt: createdAt,
        readAt: DateTime.now().toUtc().toIso8601String(),
      );
}

class NotificationPreferences {
  const NotificationPreferences({
    required this.budget,
    required this.bills,
    required this.creditUtilization,
    required this.subscriptions,
    required this.lowBalance,
    required this.unusualTransactions,
    required this.bankSync,
    required this.security,
  });

  factory NotificationPreferences.fromJson(Map<String, dynamic> json) =>
      NotificationPreferences(
        budget: json['budget'] as bool,
        bills: json['bills'] as bool,
        creditUtilization: json['creditUtilization'] as bool,
        subscriptions: json['subscriptions'] as bool,
        lowBalance: json['lowBalance'] as bool,
        unusualTransactions: json['unusualTransactions'] as bool,
        bankSync: json['bankSync'] as bool,
        security: json['security'] as bool,
      );

  final bool budget;
  final bool bills;
  final bool creditUtilization;
  final bool subscriptions;
  final bool lowBalance;
  final bool unusualTransactions;
  final bool bankSync;
  final bool security;

  Map<String, bool> toJson() => {
        'budget': budget,
        'bills': bills,
        'creditUtilization': creditUtilization,
        'subscriptions': subscriptions,
        'lowBalance': lowBalance,
        'unusualTransactions': unusualTransactions,
        'bankSync': bankSync,
        'security': security,
      };
}

class SyncResult {
  SyncResult({
    required this.accounts,
    required this.fetched,
    required this.inserted,
    required this.updated,
    required this.coverage,
    required this.needsReview,
  });

  factory SyncResult.fromJson(Map<String, dynamic> json) => SyncResult(
        accounts: json['accounts'] as int,
        fetched: json['fetched'] as int,
        inserted: json['inserted'] as int,
        updated: json['updated'] as int,
        coverage: (json['coverage'] as num).toDouble(),
        needsReview: json['needsReview'] as int,
      );

  final int accounts;
  final int fetched;
  final int inserted;
  final int updated;
  final double coverage;
  final int needsReview;
}

class Account {
  Account({
    required this.id,
    required this.name,
    required this.type,
    required this.mask,
    required this.currency,
    required this.balanceCurrent,
    required this.balanceFormatted,
    required this.source,
    this.utilization,
  });

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        id: json['id'] as String,
        name: json['name'] as String,
        type: json['type'] as String,
        mask: json['mask'] as String,
        // Older offline-cache entries predate the currency field. Keep those
        // readable, then replace them on the next successful API refresh.
        currency: json['currency'] as String? ?? 'USD',
        balanceCurrent: json['balanceCurrent'] as int,
        balanceFormatted: json['balanceFormatted'] as String,
        source: json['source'] as String? ?? 'provider',
        utilization: (json['utilization'] as num?)?.toDouble(),
      );

  final String id;
  final String name;
  final String type;
  final String mask;
  final String currency;
  final int balanceCurrent;
  final String balanceFormatted;
  final String source;

  /// Credit cards only; null everywhere else.
  final double? utilization;

  bool get isCreditCard => type == 'credit_card';
  bool get isManual => source == 'manual';
}

class NetWorthSnapshot {
  const NetWorthSnapshot({
    required this.recordedOn,
    required this.currency,
    required this.assets,
    required this.assetsFormatted,
    required this.debts,
    required this.debtsFormatted,
    required this.netPosition,
    required this.netPositionFormatted,
  });

  factory NetWorthSnapshot.fromJson(Map<String, dynamic> json) =>
      NetWorthSnapshot(
        recordedOn: json['recordedOn'] as String,
        currency: json['currency'] as String,
        assets: json['assets'] as int,
        assetsFormatted: json['assetsFormatted'] as String,
        debts: json['debts'] as int,
        debtsFormatted: json['debtsFormatted'] as String,
        netPosition: json['netPosition'] as int,
        netPositionFormatted: json['netPositionFormatted'] as String,
      );

  final String recordedOn;
  final String currency;
  final int assets;
  final String assetsFormatted;
  final int debts;
  final String debtsFormatted;
  final int netPosition;
  final String netPositionFormatted;
}

class Transaction {
  Transaction({
    required this.id,
    required this.accountId,
    required this.postedAt,
    required this.amount,
    required this.currency,
    required this.amountFormatted,
    required this.rawDescriptor,
    required this.normalizedDescriptor,
    required this.categorySlug,
    required this.categorySource,
    required this.categoryConfidence,
    required this.pending,
    required this.isRecurring,
    this.merchant,
    this.merchantOverride,
    this.note,
    this.recurringOverride,
    this.duplicateReported = false,
    this.excludedFromAnalytics = false,
    this.tags = const [],
  });

  factory Transaction.fromJson(Map<String, dynamic> json) => Transaction(
        id: json['id'] as String,
        accountId: json['accountId'] as String? ?? '',
        postedAt: json['postedAt'] as String,
        amount: json['amount'] as int,
        currency: json['currency'] as String? ?? 'USD',
        amountFormatted: json['amountFormatted'] as String,
        rawDescriptor: json['rawDescriptor'] as String,
        normalizedDescriptor: json['normalizedDescriptor'] as String,
        categorySlug: json['categorySlug'] as String,
        categorySource: json['categorySource'] as String,
        categoryConfidence: (json['categoryConfidence'] as num).toDouble(),
        pending: json['pending'] as bool,
        isRecurring: json['isRecurring'] as bool,
        recurringOverride: json['recurringOverride'] as bool?,
        duplicateReported: json['duplicateReported'] as bool? ?? false,
        merchant: json['merchant'] as String?,
        merchantOverride: json['merchantOverride'] as String?,
        note: json['note'] as String?,
        excludedFromAnalytics: json['excludedFromAnalytics'] as bool? ?? false,
        tags: (json['tags'] as List<dynamic>?)?.whereType<String>().toList() ??
            const [],
      );

  final String id;
  final String accountId;
  final String postedAt;
  final int amount;
  final String currency;
  final String amountFormatted;
  final String rawDescriptor;
  final String normalizedDescriptor;
  final String categorySlug;
  final String categorySource;
  final double categoryConfidence;
  final bool pending;
  final bool isRecurring;
  final bool? recurringOverride;
  final bool duplicateReported;
  final String? merchant;
  final String? merchantOverride;
  final String? note;
  final bool excludedFromAnalytics;
  final List<String> tags;

  String get displayName => merchantOverride ?? merchant ?? rawDescriptor;

  /// True when the user set this category themselves. The UI should never
  /// present a user's own choice as a suggestion.
  bool get isUserSet =>
      categorySource == 'user_manual' || categorySource == 'user_rule';

  bool get needsReview => categorySource == 'unknown';
}

class CategoryDefinition {
  const CategoryDefinition({
    required this.slug,
    required this.name,
    required this.kind,
    this.parent,
  });

  factory CategoryDefinition.fromJson(Map<String, dynamic> json) =>
      CategoryDefinition(
        slug: json['slug'] as String,
        name: json['name'] as String,
        parent: json['parent'] as String?,
        kind: json['kind'] as String,
      );

  final String slug;
  final String name;
  final String? parent;
  final String kind;
}

class CategorizationRule {
  const CategorizationRule({
    required this.id,
    required this.matchType,
    required this.pattern,
    required this.categorySlug,
    required this.priority,
  });

  factory CategorizationRule.fromJson(Map<String, dynamic> json) =>
      CategorizationRule(
        id: json['id'] as String,
        matchType: json['matchType'] as String,
        pattern: json['pattern'] as String,
        categorySlug: json['categorySlug'] as String,
        priority: (json['priority'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String matchType;
  final String pattern;
  final String categorySlug;
  final int priority;
}

class Budget {
  Budget({
    required this.id,
    required this.categorySlug,
    required this.limitAmount,
    required this.period,
  });

  factory Budget.fromJson(Map<String, dynamic> json) => Budget(
        id: json['id'] as String,
        categorySlug: json['categorySlug'] as String,
        limitAmount: json['limitAmount'] as int,
        period: json['period'] as String,
      );

  final String id;
  final String categorySlug;
  final int limitAmount;
  final String period;
}

class BudgetProgress {
  BudgetProgress({
    required this.budgetId,
    required this.categorySlug,
    required this.categoryName,
    required this.spentFormatted,
    required this.limitFormatted,
    required this.remainingFormatted,
    required this.percentUsed,
    required this.status,
    required this.daysRemaining,
    required this.projectedToExceed,
  });

  factory BudgetProgress.fromJson(Map<String, dynamic> json) => BudgetProgress(
        budgetId: json['budgetId'] as String,
        categorySlug: json['categorySlug'] as String,
        categoryName: json['categoryName'] as String,
        spentFormatted: json['spentFormatted'] as String,
        limitFormatted: json['limitFormatted'] as String,
        remainingFormatted: json['remainingFormatted'] as String,
        percentUsed: (json['percentUsed'] as num).toDouble(),
        status: json['status'] as String,
        daysRemaining: json['daysRemaining'] as int,
        projectedToExceed: json['projectedToExceed'] as bool,
      );

  final String budgetId;
  final String categorySlug;
  final String categoryName;
  final String spentFormatted;
  final String limitFormatted;
  final String remainingFormatted;
  final double percentUsed;
  final String status;
  final int daysRemaining;
  final bool projectedToExceed;

  bool get isExceeded => status == 'exceeded';
}

class GoalProgress {
  GoalProgress({
    required this.id,
    required this.name,
    required this.targetAmount,
    required this.savedAmount,
    required this.remainingAmount,
    required this.targetFormatted,
    required this.savedFormatted,
    required this.remainingFormatted,
    required this.percentComplete,
    this.targetDate,
    this.suggestedMonthlyFormatted,
    this.projectedCompletionDate,
  });

  factory GoalProgress.fromJson(Map<String, dynamic> json) {
    final goal = json['goal'] as Map<String, dynamic>;
    return GoalProgress(
      id: goal['id'] as String,
      name: goal['name'] as String,
      targetAmount: goal['targetAmount'] as int,
      savedAmount: json['savedAmount'] as int,
      remainingAmount: json['remainingAmount'] as int,
      targetFormatted: json['targetFormatted'] as String,
      savedFormatted: json['savedFormatted'] as String,
      remainingFormatted: json['remainingFormatted'] as String,
      percentComplete: (json['percentComplete'] as num).toDouble(),
      targetDate: goal['targetDate'] as String?,
      suggestedMonthlyFormatted: json['suggestedMonthlyFormatted'] as String?,
      projectedCompletionDate: json['projectedCompletionDate'] as String?,
    );
  }

  final String id;
  final String name;
  final int targetAmount;
  final int savedAmount;
  final int remainingAmount;
  final String targetFormatted;
  final String savedFormatted;
  final String remainingFormatted;
  final double percentComplete;
  final String? targetDate;
  final String? suggestedMonthlyFormatted;
  final String? projectedCompletionDate;

  bool get complete => remainingAmount == 0;
}

class ScoreComponent {
  ScoreComponent({
    required this.key,
    required this.label,
    required this.points,
    required this.maxPoints,
    required this.detail,
    this.action,
  });

  factory ScoreComponent.fromJson(Map<String, dynamic> json) => ScoreComponent(
        key: json['key'] as String,
        label: json['label'] as String,
        points: json['points'] as int,
        maxPoints: json['maxPoints'] as int,
        detail: json['detail'] as String,
        action: json['action'] as String?,
      );

  final String key;
  final String label;
  final int points;
  final int maxPoints;
  final String detail;
  final String? action;

  double get ratio => maxPoints == 0 ? 0 : points / maxPoints;
}

class HealthScore {
  HealthScore({
    required this.score,
    required this.band,
    required this.components,
    required this.topActions,
  });

  factory HealthScore.fromJson(Map<String, dynamic> json) => HealthScore(
        score: json['score'] as int,
        band: json['band'] as String,
        components: (json['components'] as List<dynamic>)
            .map((e) => ScoreComponent.fromJson(e as Map<String, dynamic>))
            .toList(),
        topActions: (json['topActions'] as List<dynamic>)
            .map((e) => e as String)
            .toList(),
      );

  final int score;
  final String band;
  final List<ScoreComponent> components;
  final List<String> topActions;
}

class Insight {
  Insight({
    required this.kind,
    required this.severity,
    required this.title,
    required this.detail,
    required this.evidenceCount,
    this.priority = 'informational',
    this.priorityScore = 0,
  });

  factory Insight.fromJson(Map<String, dynamic> json) => Insight(
        kind: json['kind'] as String,
        severity: json['severity'] as String,
        title: json['title'] as String,
        detail: json['detail'] as String,
        evidenceCount: (json['evidenceTransactionIds'] as List<dynamic>).length,
        priority: json['priority'] as String? ?? 'informational',
        priorityScore: (json['priorityScore'] as num?)?.toInt() ?? 0,
      );

  final String kind;
  final String severity;
  final String title;
  final String detail;
  final String priority;
  final int priorityScore;

  /// How many transactions produced this insight. Every insight must be
  /// traceable back to the data behind it.
  final int evidenceCount;
}

class InsightsReport {
  InsightsReport({
    required this.income,
    required this.expenses,
    required this.netCashFlow,
    required this.savingsRate,
    required this.topCategories,
    required this.insights,
    this.comparison,
  });

  factory InsightsReport.fromJson(Map<String, dynamic> json) {
    final headline = json['headline'] as Map<String, dynamic>;
    return InsightsReport(
      income: headline['income'] as String,
      expenses: headline['expenses'] as String,
      netCashFlow: headline['netCashFlow'] as String,
      savingsRate: headline['savingsRate'] as String,
      topCategories: (json['topCategories'] as List<dynamic>)
          .map((e) => CategorySpend.fromJson(e as Map<String, dynamic>))
          .toList(),
      insights: (json['insights'] as List<dynamic>)
          .map((e) => Insight.fromJson(e as Map<String, dynamic>))
          .toList(),
      comparison: json['comparison'] == null
          ? null
          : InsightsComparison.fromJson(
              json['comparison'] as Map<String, dynamic>),
    );
  }

  final String income;
  final String expenses;
  final String netCashFlow;
  final String savingsRate;
  final List<CategorySpend> topCategories;
  final List<Insight> insights;
  final InsightsComparison? comparison;
}

class InsightsComparison {
  const InsightsComparison({
    this.income,
    this.expenses,
    this.netCashFlow,
    this.savingsRate,
  });

  factory InsightsComparison.fromJson(Map<String, dynamic> json) =>
      InsightsComparison(
        income: json['income'] as String?,
        expenses: json['expenses'] as String?,
        netCashFlow: json['netCashFlow'] as String?,
        savingsRate: json['savingsRate'] as String?,
      );

  final String? income;
  final String? expenses;
  final String? netCashFlow;
  final String? savingsRate;

  bool get hasAny =>
      income != null ||
      expenses != null ||
      netCashFlow != null ||
      savingsRate != null;
}

class AnalyticsBucket {
  const AnalyticsBucket({
    required this.key,
    required this.label,
    required this.total,
    required this.totalFormatted,
    required this.transactionCount,
  });

  final String key;
  final String label;
  final int total;
  final String totalFormatted;
  final int transactionCount;
}

class AnalyticsTimelineEvent {
  const AnalyticsTimelineEvent({
    required this.id,
    required this.date,
    required this.label,
    required this.kind,
    required this.amount,
    required this.amountFormatted,
    required this.accountId,
  });

  factory AnalyticsTimelineEvent.fromJson(Map<String, dynamic> json) =>
      AnalyticsTimelineEvent(
        id: json['id'] as String,
        date: json['date'] as String,
        label: json['label'] as String,
        kind: json['kind'] as String,
        amount: json['amount'] as int,
        amountFormatted: json['amountFormatted'] as String,
        accountId: json['accountId'] as String,
      );

  final String id;
  final String date;
  final String label;
  final String kind;
  final int amount;
  final String amountFormatted;
  final String accountId;
}

class AnalyticsTrendPoint {
  const AnalyticsTrendPoint({
    required this.date,
    required this.income,
    required this.incomeFormatted,
    required this.expenses,
    required this.expensesFormatted,
    required this.refunds,
    required this.refundsFormatted,
    required this.net,
    required this.netFormatted,
  });

  factory AnalyticsTrendPoint.fromJson(Map<String, dynamic> json) =>
      AnalyticsTrendPoint(
        date: json['date'] as String,
        income: json['income'] as int,
        incomeFormatted: json['incomeFormatted'] as String? ?? '',
        expenses: json['expenses'] as int,
        expensesFormatted: json['expensesFormatted'] as String? ?? '',
        refunds: json['refunds'] as int,
        refundsFormatted: json['refundsFormatted'] as String? ?? '',
        net: json['net'] as int,
        netFormatted: json['netFormatted'] as String? ?? '',
      );

  final String date;
  final int income;
  final String incomeFormatted;
  final int expenses;
  final String expensesFormatted;
  final int refunds;
  final String refundsFormatted;
  final int net;
  final String netFormatted;
}

class AnalyticsVelocity {
  const AnalyticsVelocity({
    required this.currentPeriodSpend,
    required this.currentPeriodSpendFormatted,
    required this.projectedPeriodSpend,
    required this.projectedPeriodSpendFormatted,
    required this.historicalAverageSpend,
    required this.historicalAverageSpendFormatted,
    required this.percentDelta,
    required this.enoughHistory,
  });

  factory AnalyticsVelocity.fromJson(Map<String, dynamic> json) =>
      AnalyticsVelocity(
        currentPeriodSpend: json['currentPeriodSpend'] as int,
        currentPeriodSpendFormatted:
            json['currentPeriodSpendFormatted'] as String,
        projectedPeriodSpend: json['projectedPeriodSpend'] as int,
        projectedPeriodSpendFormatted:
            json['projectedPeriodSpendFormatted'] as String,
        historicalAverageSpend: json['historicalAverageSpend'] as int?,
        historicalAverageSpendFormatted:
            json['historicalAverageSpendFormatted'] as String?,
        percentDelta: (json['percentDelta'] as num?)?.toDouble(),
        enoughHistory: json['enoughHistory'] as bool,
      );

  final int currentPeriodSpend;
  final String currentPeriodSpendFormatted;
  final int projectedPeriodSpend;
  final String projectedPeriodSpendFormatted;
  final int? historicalAverageSpend;
  final String? historicalAverageSpendFormatted;
  final double? percentDelta;
  final bool enoughHistory;
}

class AnalyticsRefundMatch {
  const AnalyticsRefundMatch({
    required this.refundId,
    required this.purchaseId,
    required this.amountFormatted,
    required this.purchaseAmountFormatted,
    required this.merchant,
    required this.purchaseDate,
    required this.refundDate,
    required this.daysAfterPurchase,
    required this.confidence,
  });

  factory AnalyticsRefundMatch.fromJson(Map<String, dynamic> json) =>
      AnalyticsRefundMatch(
        refundId: json['refundId'] as String,
        purchaseId: json['purchaseId'] as String,
        amountFormatted: json['amountFormatted'] as String,
        purchaseAmountFormatted: json['purchaseAmountFormatted'] as String,
        merchant: json['merchant'] as String,
        purchaseDate: json['purchaseDate'] as String,
        refundDate: json['refundDate'] as String,
        daysAfterPurchase: json['daysAfterPurchase'] as int,
        confidence: (json['confidence'] as num).toDouble(),
      );

  final String refundId;
  final String purchaseId;
  final String amountFormatted;
  final String purchaseAmountFormatted;
  final String merchant;
  final String purchaseDate;
  final String refundDate;
  final int daysAfterPurchase;
  final double confidence;
}

class AnalyticsReport {
  AnalyticsReport({
    required this.periodStart,
    required this.periodEnd,
    required this.currency,
    required this.grossExpenses,
    required this.grossExpensesFormatted,
    required this.refundsFormatted,
    required this.refundMatches,
    required this.netExpensesFormatted,
    required this.expenseCount,
    required this.averageExpenseFormatted,
    required this.medianExpenseFormatted,
    required this.largestExpense,
    required this.spendingByCategory,
    required this.spendingByMerchant,
    required this.spendingByAccount,
    required this.recurringSpendingFormatted,
    required this.discretionarySpendingFormatted,
    required this.essentialSpendingFormatted,
    required this.totalIncomeFormatted,
    required this.recurringIncomeFormatted,
    required this.irregularIncomeFormatted,
    required this.incomeBySource,
    required this.savingsFormatted,
    required this.savingsRate,
    required this.averageMonthlySavingsFormatted,
    required this.trend,
    required this.velocity,
    required this.timeline,
  });

  factory AnalyticsReport.fromJson(Map<String, dynamic> json) {
    final period = json['period'] as Map<String, dynamic>;
    AnalyticsBucket category(Map<String, dynamic> row) => AnalyticsBucket(
          key: row['categorySlug'] as String,
          label: row['categoryName'] as String,
          total: row['total'] as int,
          totalFormatted: row['totalFormatted'] as String,
          transactionCount: row['transactionCount'] as int,
        );
    AnalyticsBucket merchant(Map<String, dynamic> row) => AnalyticsBucket(
          key: row['merchant'] as String,
          label: row['merchant'] as String,
          total: row['total'] as int,
          totalFormatted: row['totalFormatted'] as String,
          transactionCount: row['transactionCount'] as int,
        );
    AnalyticsBucket account(Map<String, dynamic> row) => AnalyticsBucket(
          key: row['accountId'] as String,
          label: row['accountId'] as String,
          total: row['total'] as int,
          totalFormatted: row['totalFormatted'] as String,
          transactionCount: row['transactionCount'] as int,
        );
    AnalyticsBucket source(Map<String, dynamic> row) => AnalyticsBucket(
          key: row['source'] as String,
          label: row['source'] as String,
          total: row['total'] as int,
          totalFormatted: row['totalFormatted'] as String,
          transactionCount: row['transactionCount'] as int,
        );
    return AnalyticsReport(
      periodStart: period['start'] as String,
      periodEnd: period['end'] as String,
      currency: json['currency'] as String,
      grossExpenses: json['grossExpenses'] as int,
      grossExpensesFormatted: json['grossExpensesFormatted'] as String,
      refundsFormatted: json['refundsFormatted'] as String,
      refundMatches: (json['refundMatches'] as List<dynamic>? ?? const [])
          .map((row) =>
              AnalyticsRefundMatch.fromJson(row as Map<String, dynamic>))
          .toList(),
      netExpensesFormatted: json['netExpensesFormatted'] as String,
      expenseCount: json['expenseCount'] as int,
      averageExpenseFormatted: json['averageExpenseFormatted'] as String,
      medianExpenseFormatted: json['medianExpenseFormatted'] as String,
      largestExpense: json['largestExpense'] == null
          ? null
          : AnalyticsTimelineEvent.fromJson(
              json['largestExpense'] as Map<String, dynamic>),
      spendingByCategory: (json['spendingByCategory'] as List<dynamic>)
          .map((row) => category(row as Map<String, dynamic>))
          .toList(),
      spendingByMerchant: (json['spendingByMerchant'] as List<dynamic>)
          .map((row) => merchant(row as Map<String, dynamic>))
          .toList(),
      spendingByAccount: (json['spendingByAccount'] as List<dynamic>)
          .map((row) => account(row as Map<String, dynamic>))
          .toList(),
      recurringSpendingFormatted: json['recurringSpendingFormatted'] as String,
      discretionarySpendingFormatted:
          json['discretionarySpendingFormatted'] as String,
      essentialSpendingFormatted: json['essentialSpendingFormatted'] as String,
      totalIncomeFormatted: json['totalIncomeFormatted'] as String,
      recurringIncomeFormatted: json['recurringIncomeFormatted'] as String,
      irregularIncomeFormatted: json['irregularIncomeFormatted'] as String,
      incomeBySource: (json['incomeBySource'] as List<dynamic>)
          .map((row) => source(row as Map<String, dynamic>))
          .toList(),
      savingsFormatted: json['savingsFormatted'] as String,
      savingsRate: (json['savingsRate'] as num).toDouble(),
      averageMonthlySavingsFormatted:
          json['averageMonthlySavingsFormatted'] as String,
      trend: (json['trend'] as List<dynamic>? ?? const [])
          .map((row) =>
              AnalyticsTrendPoint.fromJson(row as Map<String, dynamic>))
          .toList(),
      velocity:
          AnalyticsVelocity.fromJson(json['velocity'] as Map<String, dynamic>),
      timeline: (json['timeline'] as List<dynamic>)
          .map((row) =>
              AnalyticsTimelineEvent.fromJson(row as Map<String, dynamic>))
          .toList(),
    );
  }

  final String periodStart;
  final String periodEnd;
  final String currency;
  final int grossExpenses;
  final String grossExpensesFormatted;
  final String refundsFormatted;
  final List<AnalyticsRefundMatch> refundMatches;
  final String netExpensesFormatted;
  final int expenseCount;
  final String averageExpenseFormatted;
  final String medianExpenseFormatted;
  final AnalyticsTimelineEvent? largestExpense;
  final List<AnalyticsBucket> spendingByCategory;
  final List<AnalyticsBucket> spendingByMerchant;
  final List<AnalyticsBucket> spendingByAccount;
  final String recurringSpendingFormatted;
  final String discretionarySpendingFormatted;
  final String essentialSpendingFormatted;
  final String totalIncomeFormatted;
  final String recurringIncomeFormatted;
  final String irregularIncomeFormatted;
  final List<AnalyticsBucket> incomeBySource;
  final String savingsFormatted;
  final double savingsRate;
  final String averageMonthlySavingsFormatted;
  final List<AnalyticsTrendPoint> trend;
  final AnalyticsVelocity velocity;
  final List<AnalyticsTimelineEvent> timeline;
}

class AssistantFact {
  const AssistantFact({required this.label, required this.value});

  factory AssistantFact.fromJson(Map<String, dynamic> json) => AssistantFact(
        label: json['label'] as String,
        value: json['value'] as String,
      );

  final String label;
  final String value;
}

class AssistantAnswer {
  const AssistantAnswer({
    required this.question,
    required this.intent,
    required this.answer,
    required this.facts,
    required this.source,
    required this.caveat,
  });

  factory AssistantAnswer.fromJson(Map<String, dynamic> json) =>
      AssistantAnswer(
        question: json['question'] as String,
        intent: json['intent'] as String,
        answer: json['answer'] as String,
        facts: (json['facts'] as List<dynamic>? ?? const [])
            .map((row) => AssistantFact.fromJson(row as Map<String, dynamic>))
            .toList(),
        source: json['source'] as String,
        caveat: json['caveat'] as String,
      );

  final String question;
  final String intent;
  final String answer;
  final List<AssistantFact> facts;
  final String source;
  final String caveat;
}

class CategorySpend {
  CategorySpend({
    required this.categorySlug,
    required this.categoryName,
    required this.total,
    required this.totalFormatted,
    required this.transactionCount,
  });

  factory CategorySpend.fromJson(Map<String, dynamic> json) => CategorySpend(
        categorySlug: json['categorySlug'] as String,
        categoryName: json['categoryName'] as String,
        total: json['total'] as int,
        totalFormatted: json['totalFormatted'] as String,
        transactionCount: json['transactionCount'] as int,
      );

  final String categorySlug;
  final String categoryName;
  final int total;
  final String totalFormatted;
  final int transactionCount;
}

class ForecastPoint {
  const ForecastPoint({
    required this.date,
    required this.balance,
    required this.balanceFormatted,
  });

  factory ForecastPoint.fromJson(Map<String, dynamic> json) => ForecastPoint(
        date: json['date'] as String,
        balance: json['balance'] as int,
        balanceFormatted: json['balanceFormatted'] as String? ?? '',
      );

  final String date;
  final int balance;
  final String balanceFormatted;
}

class ForecastEvent {
  const ForecastEvent({
    required this.date,
    required this.merchant,
    required this.kind,
    required this.amountFormatted,
    required this.confidence,
  });

  factory ForecastEvent.fromJson(Map<String, dynamic> json) => ForecastEvent(
        date: json['date'] as String,
        merchant: json['merchant'] as String,
        kind: json['kind'] as String,
        amountFormatted: json['amountFormatted'] as String,
        confidence: (json['confidence'] as num).toDouble(),
      );

  final String date;
  final String merchant;
  final String kind;
  final String amountFormatted;
  final double confidence;
}

class CashFlowForecast {
  const CashFlowForecast({
    required this.currency,
    required this.startingBalanceFormatted,
    required this.endingBalanceFormatted,
    required this.points,
    required this.events,
    required this.lowBalanceDates,
  });

  factory CashFlowForecast.fromJson(Map<String, dynamic> json) =>
      CashFlowForecast(
        currency: json['currency'] as String,
        startingBalanceFormatted: json['startingBalanceFormatted'] as String,
        endingBalanceFormatted: json['endingBalanceFormatted'] as String,
        points: (json['points'] as List<dynamic>)
            .map((row) => ForecastPoint.fromJson(row as Map<String, dynamic>))
            .toList(),
        events: (json['events'] as List<dynamic>)
            .map((row) => ForecastEvent.fromJson(row as Map<String, dynamic>))
            .toList(),
        lowBalanceDates:
            (json['lowBalanceDates'] as List<dynamic>).cast<String>(),
      );

  final String currency;
  final String startingBalanceFormatted;
  final String endingBalanceFormatted;
  final List<ForecastPoint> points;
  final List<ForecastEvent> events;
  final List<String> lowBalanceDates;
}

class PurchaseScenario {
  const PurchaseScenario({
    required this.currency,
    required this.balanceBeforePurchaseFormatted,
    required this.balanceAfterPurchaseFormatted,
    required this.endingBalanceFormatted,
    required this.lowBalanceDates,
    required this.warnings,
  });

  factory PurchaseScenario.fromJson(Map<String, dynamic> json) =>
      PurchaseScenario(
        currency: json['currency'] as String,
        balanceBeforePurchaseFormatted:
            json['balanceBeforePurchaseFormatted'] as String,
        balanceAfterPurchaseFormatted:
            json['balanceAfterPurchaseFormatted'] as String,
        endingBalanceFormatted: json['endingBalanceFormatted'] as String,
        lowBalanceDates:
            (json['lowBalanceDates'] as List<dynamic>).cast<String>(),
        warnings: (json['warnings'] as List<dynamic>).cast<String>(),
      );

  final String currency;
  final String balanceBeforePurchaseFormatted;
  final String balanceAfterPurchaseFormatted;
  final String endingBalanceFormatted;
  final List<String> lowBalanceDates;
  final List<String> warnings;
}

class Subscription {
  Subscription({
    required this.merchant,
    required this.cadence,
    required this.typicalAmountFormatted,
    required this.annualCostFormatted,
    required this.nextExpected,
    required this.hasPriceIncrease,
  });

  factory Subscription.fromJson(Map<String, dynamic> json) => Subscription(
        merchant: json['merchant'] as String,
        cadence: json['cadence'] as String,
        typicalAmountFormatted: json['typicalAmountFormatted'] as String,
        annualCostFormatted: json['annualCostFormatted'] as String,
        nextExpected: json['nextExpected'] as String,
        hasPriceIncrease: json['priceIncrease'] != null,
      );

  final String merchant;
  final String cadence;
  final String typicalAmountFormatted;
  final String annualCostFormatted;
  final String nextExpected;
  final bool hasPriceIncrease;
}

class SubscriptionsReport {
  SubscriptionsReport({
    required this.count,
    required this.currency,
    required this.monthlyTotalFormatted,
    required this.annualTotalFormatted,
    required this.subscriptions,
    required this.priceIncreases,
    required this.possiblyCancelled,
  });

  factory SubscriptionsReport.fromJson(Map<String, dynamic> json) =>
      SubscriptionsReport(
        count: json['count'] as int,
        currency: json['currency'] as String? ?? 'USD',
        monthlyTotalFormatted: json['monthlyTotalFormatted'] as String,
        annualTotalFormatted: json['annualTotalFormatted'] as String,
        subscriptions: (json['subscriptions'] as List<dynamic>)
            .map((e) => Subscription.fromJson(e as Map<String, dynamic>))
            .toList(),
        priceIncreases: (json['priceIncreases'] as List<dynamic>? ?? const [])
            .map((e) =>
                SubscriptionPriceIncrease.fromJson(e as Map<String, dynamic>))
            .toList(),
        possiblyCancelled:
            (json['possiblyCancelled'] as List<dynamic>? ?? const [])
                .cast<String>(),
      );

  final int count;
  final String currency;
  final String monthlyTotalFormatted;
  final String annualTotalFormatted;
  final List<Subscription> subscriptions;
  final List<SubscriptionPriceIncrease> priceIncreases;
  final List<String> possiblyCancelled;
}

class SubscriptionPriceIncrease {
  SubscriptionPriceIncrease({
    required this.merchant,
    required this.from,
    required this.to,
    required this.percent,
    required this.annualImpact,
  });

  factory SubscriptionPriceIncrease.fromJson(Map<String, dynamic> json) =>
      SubscriptionPriceIncrease(
        merchant: json['merchant'] as String,
        from: json['from'] as String,
        to: json['to'] as String,
        percent: json['percent'] as int,
        annualImpact: json['annualImpact'] as String,
      );

  final String merchant;
  final String from;
  final String to;
  final int percent;
  final String annualImpact;
}

class ConsentChoice {
  const ConsentChoice({
    required this.granted,
    required this.policyVersion,
    this.updatedAt,
  });

  factory ConsentChoice.fromJson(Map<String, dynamic> json) => ConsentChoice(
        granted: json['granted'] as bool,
        policyVersion: json['policyVersion'] as String,
        updatedAt: json['updatedAt'] as String?,
      );

  final bool granted;
  final String policyVersion;
  final String? updatedAt;
}

class ConsentHistoryEntry {
  const ConsentHistoryEntry({
    required this.kind,
    required this.granted,
    required this.policyVersion,
    required this.createdAt,
  });

  factory ConsentHistoryEntry.fromJson(Map<String, dynamic> json) =>
      ConsentHistoryEntry(
        kind: json['kind'] as String,
        granted: json['granted'] as bool,
        policyVersion: json['policyVersion'] as String,
        createdAt: json['createdAt'] as String,
      );

  final String kind;
  final bool granted;
  final String policyVersion;
  final String createdAt;
}

class SecurityActivity {
  const SecurityActivity({
    required this.kind,
    required this.succeeded,
    required this.createdAt,
    this.ipAddress,
    this.userAgent,
    this.detail,
  });

  factory SecurityActivity.fromJson(Map<String, dynamic> json) =>
      SecurityActivity(
        kind: json['kind'] as String,
        succeeded: json['succeeded'] as bool,
        createdAt: json['createdAt'] as String,
        ipAddress: json['ipAddress'] as String?,
        userAgent: json['userAgent'] as String?,
        detail: json['detail'] as String?,
      );

  final String kind;
  final bool succeeded;
  final String createdAt;
  final String? ipAddress;
  final String? userAgent;
  final String? detail;
}

class PrivacyDashboard {
  const PrivacyDashboard({
    required this.analytics,
    required this.productUpdates,
    required this.consentHistory,
    required this.securityActivity,
    required this.accountDeletionRecoveryDays,
    required this.offlineCacheMaximumDays,
  });

  factory PrivacyDashboard.fromJson(Map<String, dynamic> json) {
    final choices = json['optionalConsents'] as Map<String, dynamic>;
    final retention = json['retention'] as Map<String, dynamic>;
    return PrivacyDashboard(
      analytics:
          ConsentChoice.fromJson(choices['analytics'] as Map<String, dynamic>),
      productUpdates: ConsentChoice.fromJson(
          choices['productUpdates'] as Map<String, dynamic>),
      consentHistory: (json['consentHistory'] as List<dynamic>)
          .map((row) =>
              ConsentHistoryEntry.fromJson(row as Map<String, dynamic>))
          .toList(),
      securityActivity: (json['securityActivity'] as List<dynamic>)
          .map((row) => SecurityActivity.fromJson(row as Map<String, dynamic>))
          .toList(),
      accountDeletionRecoveryDays:
          retention['accountDeletionRecoveryDays'] as int,
      offlineCacheMaximumDays: retention['offlineCacheMaximumDays'] as int,
    );
  }

  final ConsentChoice analytics;
  final ConsentChoice productUpdates;
  final List<ConsentHistoryEntry> consentHistory;
  final List<SecurityActivity> securityActivity;
  final int accountDeletionRecoveryDays;
  final int offlineCacheMaximumDays;
}

class MfaStatus {
  const MfaStatus(
      {required this.enabled,
      required this.available,
      required this.recoveryCodesRemaining});

  factory MfaStatus.fromJson(Map<String, dynamic> json) => MfaStatus(
        enabled: json['enabled'] as bool,
        available: json['available'] as bool,
        recoveryCodesRemaining: json['recoveryCodesRemaining'] as int,
      );

  final bool enabled;
  final bool available;
  final int recoveryCodesRemaining;
}

class MfaEnrollment {
  const MfaEnrollment({required this.secret, required this.otpauthUri});

  factory MfaEnrollment.fromJson(Map<String, dynamic> json) => MfaEnrollment(
        secret: json['secret'] as String,
        otpauthUri: json['otpauthUri'] as String,
      );

  final String secret;
  final String otpauthUri;
}

// --------------------------------------------------------------------- plans

/// One tier from the public catalogue at `GET /billing/plans`.
///
/// The catalogue is served rather than hardcoded here on purpose: the server's
/// `domain/billing/plans.ts` is the single place tiering is decided, and a copy
/// in the client would drift the moment a limit changed. A shipped app cannot
/// be updated as fast as a deployment.
class BillingPlan {
  const BillingPlan({
    required this.id,
    required this.name,
    required this.bankLinkLimit,
    required this.entitlements,
    required this.purchasable,
  });

  factory BillingPlan.fromJson(Map<String, dynamic> json) => BillingPlan(
        id: json['id'] as String,
        name: json['name'] as String,
        bankLinkLimit: json['bankLinkLimit'] as int? ?? 0,
        entitlements:
            (json['entitlements'] as List<dynamic>? ?? const []).cast<String>(),
        purchasable: json['purchasable'] as bool? ?? false,
      );

  final String id;
  final String name;
  final int bankLinkLimit;
  final List<String> entitlements;
  final bool purchasable;
}

/// The signed-in user's plan, from `GET /billing/subscription`.
class PlanSummary {
  const PlanSummary({
    required this.plan,
    required this.planName,
    required this.status,
    required this.bankLinkLimit,
    required this.entitlements,
    required this.cancelAtPeriodEnd,
    required this.purchaseAvailable,
    this.gatesEnforced = true,
    this.intervals = const ['month'],
    this.trialDays = 0,
    this.currentPeriodEnd,
    this.trialEnd,
  });

  factory PlanSummary.fromJson(Map<String, dynamic> json) => PlanSummary(
        plan: json['plan'] as String,
        planName: json['planName'] as String,
        status: json['status'] as String,
        bankLinkLimit: json['bankLinkLimit'] as int? ?? 0,
        entitlements:
            (json['entitlements'] as List<dynamic>? ?? const []).cast<String>(),
        cancelAtPeriodEnd: json['cancelAtPeriodEnd'] as bool? ?? false,
        // False when the server has no payment provider configured, which is a
        // supported deployment rather than an error — the UI hides buying
        // instead of offering something that would 503.
        purchaseAvailable: json['purchaseAvailable'] as bool? ?? false,
        // Defaults to true so an older server that does not send the field is
        // treated as enforcing. Assuming the permissive case would show a free
        // user a "everything included" screen that the API then contradicts.
        gatesEnforced: json['gatesEnforced'] as bool? ?? true,
        intervals: (json['intervals'] as List<dynamic>? ?? const ['month'])
            .cast<String>(),
        trialDays: json['trialDays'] as int? ?? 0,
        currentPeriodEnd: _parseDate(json['currentPeriodEnd']),
        trialEnd: _parseDate(json['trialEnd']),
      );

  final String plan;
  final String planName;

  /// Mirrors the provider's vocabulary: `none`, `trialing`, `active`,
  /// `past_due`, `canceled`, and so on.
  final String status;
  final int bankLinkLimit;
  final List<String> entitlements;
  final bool cancelAtPeriodEnd;
  final bool purchaseAvailable;

  /// False when this deployment applies no plan limits, so the UI says
  /// "everything is available here" rather than showing a tier comparison
  /// nobody can act on.
  final bool gatesEnforced;

  /// Billing intervals this deployment can sell, e.g. `['month', 'year']`.
  final List<String> intervals;

  /// Days of free trial on a new subscription. Zero means none.
  final int trialDays;

  final DateTime? currentPeriodEnd;
  final DateTime? trialEnd;

  bool get isFree => plan == 'free';
  bool get isTrialing => status == 'trialing';

  /// A renewal payment has failed and the provider is still retrying.
  ///
  /// Access deliberately continues meanwhile (see ADR-0007), so this is a
  /// prompt to fix a card rather than a lockout — and saying so plainly is the
  /// difference between a customer updating their card and one who thinks they
  /// have already been cut off.
  bool get needsPaymentAttention => status == 'past_due' || status == 'unpaid';

  bool has(String entitlement) => entitlements.contains(entitlement);

  static DateTime? _parseDate(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

/// Where to send the customer to pay, from `POST /billing/checkout-session`.
class CheckoutSession {
  const CheckoutSession({required this.url, this.expiresAt});

  factory CheckoutSession.fromJson(Map<String, dynamic> json) =>
      CheckoutSession(
        url: json['url'] as String,
        expiresAt: PlanSummary._parseDate(json['expiresAt']),
      );

  final String url;
  final DateTime? expiresAt;
}

/// Extracted fields from a receipt, from `POST /receipts/scan`.
class ReceiptScan {
  const ReceiptScan({
    this.merchant,
    this.date,
    this.totalMinor,
    this.taxMinor,
    this.currency,
    this.items = const [],
    this.confidence = 0,
  });

  factory ReceiptScan.fromJson(Map<String, dynamic> json) => ReceiptScan(
        merchant: json['merchant'] as String?,
        date: json['date'] as String?,
        totalMinor: (json['totalMinor'] as num?)?.toInt(),
        taxMinor: (json['taxMinor'] as num?)?.toInt(),
        currency: json['currency'] as String?,
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(),
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      );

  final String? merchant;
  final String? date;
  final int? totalMinor;
  final int? taxMinor;
  final String? currency;
  final List<String> items;
  final double confidence;
}

/// A stored receipt attached to one transaction, from `PUT /receipts/:id`.
class ReceiptRecord {
  const ReceiptRecord({
    required this.transactionId,
    this.merchant,
    this.receiptDate,
    this.totalMinor,
    this.taxMinor,
    this.currency,
    this.items = const [],
  });

  factory ReceiptRecord.fromJson(Map<String, dynamic> json) => ReceiptRecord(
        transactionId: json['transactionId'] as String? ?? '',
        merchant: json['merchant'] as String?,
        receiptDate: json['receiptDate'] as String?,
        totalMinor: (json['totalMinor'] as num?)?.toInt(),
        taxMinor: (json['taxMinor'] as num?)?.toInt(),
        currency: json['currency'] as String?,
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(),
      );

  final String transactionId;
  final String? merchant;
  final String? receiptDate;
  final int? totalMinor;
  final int? taxMinor;
  final String? currency;
  final List<String> items;
}

class StatementDocumentDetails {
  const StatementDocumentDetails({
    this.issuer,
    this.accountReferenceLast4,
    this.statementDate,
    this.periodStart,
    this.periodEnd,
    this.currency,
  });

  factory StatementDocumentDetails.fromJson(Map<String, dynamic> json) =>
      StatementDocumentDetails(
        issuer: json['issuer'] as String?,
        accountReferenceLast4: json['accountReferenceLast4'] as String?,
        statementDate: json['statementDate'] as String?,
        periodStart: json['periodStart'] as String?,
        periodEnd: json['periodEnd'] as String?,
        currency: json['currency'] as String?,
      );

  final String? issuer;
  final String? accountReferenceLast4;
  final String? statementDate;
  final String? periodStart;
  final String? periodEnd;
  final String? currency;
}

class StatementImport {
  const StatementImport({
    required this.id,
    required this.accountId,
    required this.filename,
    required this.mimeType,
    required this.format,
    required this.status,
    required this.rowsTotal,
    required this.rowsIncluded,
    required this.rowsExcluded,
    required this.rowsNeedsReview,
    required this.createdAt,
    this.sourceDeletedAt,
    this.error,
    this.documentDetails,
  });

  factory StatementImport.fromJson(Map<String, dynamic> json) =>
      StatementImport(
        id: json['id'] as String,
        accountId: json['accountId'] as String,
        filename: json['filename'] as String,
        mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
        format: json['format'] as String? ?? 'unknown',
        status: json['status'] as String? ?? 'ready',
        rowsTotal: (json['rowsTotal'] as num?)?.toInt() ?? 0,
        rowsIncluded: (json['rowsIncluded'] as num?)?.toInt() ?? 0,
        rowsExcluded: (json['rowsExcluded'] as num?)?.toInt() ?? 0,
        rowsNeedsReview: (json['rowsNeedsReview'] as num?)?.toInt() ?? 0,
        createdAt: json['createdAt'] as String? ?? '',
        sourceDeletedAt: json['sourceDeletedAt'] as String?,
        error: json['error'] as String?,
        documentDetails: json['documentDetails'] is Map<String, dynamic>
            ? StatementDocumentDetails.fromJson(
                json['documentDetails'] as Map<String, dynamic>)
            : null,
      );

  final String id;
  final String accountId;
  final String filename;
  final String mimeType;
  final String format;
  final String status;
  final int rowsTotal;
  final int rowsIncluded;
  final int rowsExcluded;
  final int rowsNeedsReview;
  final String createdAt;
  final String? sourceDeletedAt;
  final String? error;
  final StatementDocumentDetails? documentDetails;
}

class StatementRow {
  const StatementRow({
    required this.id,
    required this.importId,
    required this.sourceLine,
    required this.description,
    required this.amount,
    required this.currency,
    required this.direction,
    this.merchant,
    required this.categorySlug,
    required this.categorySource,
    required this.categoryConfidence,
    required this.decision,
    required this.flags,
    required this.postedAt,
    required this.isRecurring,
  });

  factory StatementRow.fromJson(Map<String, dynamic> json) => StatementRow(
        id: json['id'] as String,
        importId: json['importId'] as String,
        sourceLine: (json['sourceLine'] as num?)?.toInt() ?? 0,
        description: json['description'] as String? ?? '',
        amount: (json['amount'] as num?)?.toInt(),
        currency: json['currency'] as String? ?? 'USD',
        direction: json['direction'] as String? ?? 'unknown',
        merchant: json['merchant'] as String?,
        categorySlug: json['categorySlug'] as String? ?? 'unknown',
        categorySource: json['categorySource'] as String? ?? 'unknown',
        categoryConfidence:
            (json['categoryConfidence'] as num?)?.toDouble() ?? 0,
        decision: json['decision'] as String? ?? 'needs_review',
        flags: (json['flags'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(),
        postedAt: json['postedAt'] as String?,
        isRecurring: json['isRecurring'] as bool? ?? false,
      );

  final String id;
  final String importId;
  final int sourceLine;
  final String description;
  final int? amount;
  final String currency;
  final String direction;
  final String? merchant;
  final String categorySlug;
  final String categorySource;
  final double categoryConfidence;
  final String decision;
  final List<String> flags;
  final String? postedAt;
  final bool isRecurring;
}

class StatementImportDetail {
  const StatementImportDetail({required this.statement, required this.rows});
  factory StatementImportDetail.fromJson(Map<String, dynamic> json) =>
      StatementImportDetail(
        statement:
            StatementImport.fromJson(json['statement'] as Map<String, dynamic>),
        rows: (json['rows'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(StatementRow.fromJson)
            .toList(),
      );
  final StatementImport statement;
  final List<StatementRow> rows;
}

class StatementSummary {
  const StatementSummary({
    required this.currency,
    required this.income,
    required this.expenses,
    required this.netCashFlow,
    required this.savings,
    required this.recurringCount,
    required this.duplicateCount,
    required this.unusualCount,
    required this.categoryTotals,
  });

  factory StatementSummary.fromJson(Map<String, dynamic> json) =>
      StatementSummary(
        currency: json['currency'] as String? ?? 'USD',
        income: (json['income'] as num?)?.toInt() ?? 0,
        expenses: (json['expenses'] as num?)?.toInt() ?? 0,
        netCashFlow: (json['netCashFlow'] as num?)?.toInt() ??
            ((json['income'] as num?)?.toInt() ?? 0) -
                ((json['expenses'] as num?)?.toInt() ?? 0),
        savings: (json['savings'] as num?)?.toInt() ?? 0,
        recurringCount: (json['recurringCount'] as num?)?.toInt() ?? 0,
        duplicateCount: (json['duplicateCount'] as num?)?.toInt() ?? 0,
        unusualCount: (json['unusualCount'] as num?)?.toInt() ?? 0,
        categoryTotals: (json['categoryTotals'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((value) => {
                  'categorySlug': value['categorySlug'] as String? ?? 'unknown',
                  'amount': (value['amount'] as num?)?.toInt() ?? 0,
                  'count': (value['count'] as num?)?.toInt() ?? 0,
                  'label': value['label'] as String? ??
                      value['categorySlug'] as String? ??
                      'Unknown',
                })
            .toList(),
      );

  final String currency;
  final int income;
  final int expenses;
  final int netCashFlow;
  final int savings;
  final int recurringCount;
  final int duplicateCount;
  final int unusualCount;
  final List<Map<String, dynamic>> categoryTotals;
}

class SplitGroup {
  SplitGroup({
    required this.id,
    required this.name,
    required this.currency,
    this.createdBy,
    this.createdAt,
    this.archivedAt,
  });

  factory SplitGroup.fromJson(Map<String, dynamic> json) => SplitGroup(
        id: json['id'] as String,
        name: json['name'] as String,
        currency: json['currency'] as String? ?? 'USD',
        createdBy: json['createdBy'] as String?,
        createdAt: json['createdAt'] as String?,
        archivedAt: json['archivedAt'] as String?,
      );

  final String id;
  final String name;
  final String currency;
  final String? createdBy;
  final String? createdAt;
  final String? archivedAt;
}

class SplitMember {
  SplitMember(
      {required this.userId, required this.role, this.email, this.joinedAt});

  factory SplitMember.fromJson(Map<String, dynamic> json) => SplitMember(
        userId: json['userId'] as String,
        role: json['role'] as String? ?? 'member',
        email: json['email'] as String?,
        joinedAt: json['joinedAt'] as String?,
      );

  final String userId;
  final String role;
  final String? email;
  final String? joinedAt;
}

class SplitInvitation {
  SplitInvitation({
    required this.id,
    required this.groupId,
    required this.status,
    this.groupName,
    this.currency,
    this.invitedByEmail,
    this.createdAt,
  });

  factory SplitInvitation.fromJson(Map<String, dynamic> json) =>
      SplitInvitation(
        id: json['id'] as String,
        groupId: json['groupId'] as String,
        status: json['status'] as String? ?? 'pending',
        groupName: json['groupName'] as String?,
        currency: json['currency'] as String?,
        invitedByEmail: json['invitedByEmail'] as String?,
        createdAt: json['createdAt'] as String?,
      );

  final String id;
  final String groupId;
  final String status;
  final String? groupName;
  final String? currency;
  final String? invitedByEmail;
  final String? createdAt;
}

class SplitParticipant {
  SplitParticipant(
      {required this.userId,
      required this.amount,
      this.email,
      this.amountFormatted});

  factory SplitParticipant.fromJson(Map<String, dynamic> json) =>
      SplitParticipant(
        userId: json['userId'] as String,
        amount: (json['amount'] as num?)?.toInt() ?? 0,
        email: json['email'] as String?,
        amountFormatted: json['amountFormatted'] as String?,
      );

  final String userId;
  final int amount;
  final String? email;
  final String? amountFormatted;
}

class SplitExpense {
  SplitExpense({
    required this.id,
    required this.description,
    required this.category,
    required this.amount,
    required this.paidByUserId,
    required this.splitMethod,
    required this.date,
    this.amountFormatted,
    this.paidByEmail,
    this.participants = const [],
  });

  factory SplitExpense.fromJson(Map<String, dynamic> json) => SplitExpense(
        id: json['id'] as String,
        description: json['description'] as String,
        category: json['category'] as String? ?? 'other',
        amount: (json['amount'] as num?)?.toInt() ?? 0,
        amountFormatted: json['amountFormatted'] as String?,
        paidByUserId: json['paidByUserId'] as String,
        paidByEmail: json['paidByEmail'] as String?,
        splitMethod: json['splitMethod'] as String? ?? 'equal',
        date: json['date'] as String? ?? '',
        participants: (json['participants'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SplitParticipant.fromJson)
            .toList(),
      );

  final String id;
  final String description;
  final String category;
  final int amount;
  final String? amountFormatted;
  final String paidByUserId;
  final String? paidByEmail;
  final String splitMethod;
  final String date;
  final List<SplitParticipant> participants;
}

class SplitSettlement {
  SplitSettlement({
    required this.id,
    required this.fromUserId,
    required this.toUserId,
    required this.amount,
    this.fromEmail,
    this.toEmail,
    this.amountFormatted,
    this.note = '',
    this.createdAt,
  });

  factory SplitSettlement.fromJson(Map<String, dynamic> json) =>
      SplitSettlement(
        id: json['id'] as String,
        fromUserId: json['fromUserId'] as String,
        toUserId: json['toUserId'] as String,
        amount: (json['amount'] as num?)?.toInt() ?? 0,
        fromEmail: json['fromEmail'] as String?,
        toEmail: json['toEmail'] as String?,
        amountFormatted: json['amountFormatted'] as String?,
        note: json['note'] as String? ?? '',
        createdAt: json['createdAt'] as String?,
      );

  final String id;
  final String fromUserId;
  final String toUserId;
  final int amount;
  final String? fromEmail;
  final String? toEmail;
  final String? amountFormatted;
  final String note;
  final String? createdAt;
}

class SplitBalance {
  SplitBalance(
      {required this.userId,
      required this.netAmount,
      this.email,
      this.netFormatted});

  factory SplitBalance.fromJson(Map<String, dynamic> json) => SplitBalance(
        userId: json['userId'] as String,
        netAmount: (json['netAmount'] as num?)?.toInt() ?? 0,
        email: json['email'] as String?,
        netFormatted: json['netFormatted'] as String?,
      );

  final String userId;
  final int netAmount;
  final String? email;
  final String? netFormatted;
}

class SplitSuggestion {
  SplitSuggestion(
      {required this.fromUserId,
      required this.toUserId,
      required this.amount,
      this.amountFormatted});

  factory SplitSuggestion.fromJson(Map<String, dynamic> json) =>
      SplitSuggestion(
        fromUserId: json['fromUserId'] as String,
        toUserId: json['toUserId'] as String,
        amount: (json['amount'] as num?)?.toInt() ?? 0,
        amountFormatted: json['amountFormatted'] as String?,
      );

  final String fromUserId;
  final String toUserId;
  final int amount;
  final String? amountFormatted;
}

class SplitGroupDetail {
  SplitGroupDetail({
    required this.group,
    required this.members,
    required this.expenses,
    required this.settlements,
    required this.balances,
    required this.suggestions,
  });

  factory SplitGroupDetail.fromJson(Map<String, dynamic> json) =>
      SplitGroupDetail(
        group: SplitGroup.fromJson(json['group'] as Map<String, dynamic>),
        members: (json['members'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SplitMember.fromJson)
            .toList(),
        expenses: (json['expenses'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SplitExpense.fromJson)
            .toList(),
        settlements: (json['settlements'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SplitSettlement.fromJson)
            .toList(),
        balances: (json['balances'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SplitBalance.fromJson)
            .toList(),
        suggestions: (json['suggestions'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SplitSuggestion.fromJson)
            .toList(),
      );

  final SplitGroup group;
  final List<SplitMember> members;
  final List<SplitExpense> expenses;
  final List<SplitSettlement> settlements;
  final List<SplitBalance> balances;
  final List<SplitSuggestion> suggestions;
}
