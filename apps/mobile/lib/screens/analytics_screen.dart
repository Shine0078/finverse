import 'package:flutter/material.dart';

import '../api/client.dart';
import '../design/design.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../widgets/health_score_card.dart';
import '../widgets/cash_flow_sankey.dart';
import '../widgets/spending_chart.dart';
import '../widgets/trend_chart.dart';
import '../widgets/spending_heatmap.dart';
import 'planning_screen.dart';
import 'transactions_screen.dart';

/// A dedicated, explainable analytics view. The dashboard stays a quick
/// overview; this screen gives the user the evidence behind the numbers and a
/// direct path to the forecast simulator.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({required this.api, super.key});

  final ApiClient api;

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  AnalyticsReport? _analytics;
  InsightsReport? _insights;
  HealthScore? _health;
  SubscriptionsReport? _subscriptions;
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  String? _refreshError;
  String _period = 'month';
  String _currency = 'USD';
  DateTime? _customFrom;
  DateTime? _customTo;
  StatementImport? _latestApprovedImport;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.api.dataRevision.addListener(_onDataChanged);
    _load();
  }

  @override
  void dispose() {
    widget.api.dataRevision.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (!mounted || _loading) return;
    _load();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final initialLoad = _analytics == null;
    widget.api.resetOfflineStatus();
    setState(() {
      _loading = initialLoad;
      _refreshing = !initialLoad;
      _error = null;
      _refreshError = null;
    });
    try {
      final accounts = await widget.api.accounts();
      final currencies = accounts
          .map((account) => account.currency)
          .where((currency) => currency.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      if (currencies.isNotEmpty) _currency = currencies.first;
      final results = await Future.wait([
        widget.api.analytics(
          period: _period,
          currency: _currency,
          from: _period == 'custom' ? _customFrom : null,
          to: _period == 'custom' ? _customTo : null,
        ),
        widget.api.insights(currency: _currency),
        widget.api.healthScore(currency: _currency),
        widget.api.subscriptions(currency: _currency),
        widget.api.statementImports(),
      ]);
      if (!mounted || generation != _loadGeneration) return;
      final imports = results[4] as List<StatementImport>;
      StatementImport? latestApproved;
      for (final item in imports) {
        if (item.status == 'approved' &&
            item.documentDetails?.periodStart != null &&
            item.documentDetails?.periodEnd != null) {
          latestApproved = item;
          break;
        }
      }
      setState(() {
        _analytics = results[0] as AnalyticsReport;
        _insights = results[1] as InsightsReport;
        _health = results[2] as HealthScore;
        _subscriptions = results[3] as SubscriptionsReport;
        _latestApprovedImport = latestApproved;
        _loading = false;
        _refreshing = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        if (initialLoad) {
          _error = friendlyErrorMessage(error);
        } else {
          _refreshError = friendlyErrorMessage(error);
        }
        _loading = false;
        _refreshing = false;
      });
    }
  }

  Future<void> _changePeriod(String? value) async {
    if (value == null || value == _period) return;
    if (value == 'custom') {
      final now = DateTime.now();
      final start = await showDatePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: now,
        initialDate: _customFrom ?? DateTime(now.year, now.month, 1),
        helpText: AppLocalizations.of(context).analyticsChooseFirstDay,
      );
      if (!mounted || start == null) return;
      final end = await showDatePicker(
        context: context,
        firstDate: start,
        lastDate: now,
        initialDate: _customTo ?? now,
        helpText: AppLocalizations.of(context).analyticsChooseLastDay,
      );
      if (!mounted || end == null) return;
      setState(() {
        _period = value;
        _customFrom = start;
        _customTo = end;
      });
    } else {
      setState(() => _period = value);
    }
    await _load();
  }

  Future<void> _viewLatestStatementPeriod() async {
    final details = _latestApprovedImport?.documentDetails;
    final from = details?.periodStart == null
        ? null
        : DateTime.tryParse(details!.periodStart!);
    final to = details?.periodEnd == null
        ? null
        : DateTime.tryParse(details!.periodEnd!);
    if (from == null || to == null) return;
    setState(() {
      _period = 'custom';
      _customFrom = from;
      _customTo = to;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navAnalytics),
        actions: [
          IconButton(
            tooltip: l10n.analyticsRefreshTooltip,
            onPressed: _loading || _refreshing ? null : _load,
            icon: _refreshing
                ? const SizedBox(
                    width: 19,
                    height: 19,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const FinDashboardSkeleton();
    if (_error != null) {
      return SingleChildScrollView(
        child: FinErrorState(
          title: AppLocalizations.of(context).analyticsUnavailable,
          message: AppLocalizations.of(context).analyticsUnavailableDetail,
          onRetry: _load,
          technicalDetail: _error,
        ),
      );
    }

    final analytics = _analytics!;
    final insights = _insights!;
    final categories = analytics.spendingByCategory
        .map((row) => CategorySpend(
              categorySlug: row.key,
              categoryName: row.label,
              total: row.total,
              totalFormatted: row.totalFormatted,
              transactionCount: row.transactionCount,
            ))
        .toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: LayoutBuilder(
        builder: (context, constraints) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            constraints.maxWidth >= 720 ? 24 : 16,
            16,
            constraints.maxWidth >= 720 ? 24 : 16,
            36,
          ),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1240),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _periodControlCard(context, analytics),
                    if (_refreshing) ...[
                      const SizedBox(height: 12),
                      const FinSyncingChip(label: 'Refreshing analytics…'),
                    ],
                    if (_refreshError != null) ...[
                      const SizedBox(height: 12),
                      _refreshFailureCard(context),
                    ],
                    const SizedBox(height: 16),
                    if (_period == 'month' &&
                        analytics.spendingByCategory.isEmpty &&
                        _latestApprovedImport?.documentDetails?.periodStart !=
                            null &&
                        _latestApprovedImport?.documentDetails?.periodEnd !=
                            null)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.info_outline),
                          title: const Text('No activity in this period'),
                          subtitle: Text(
                            'Your approved statement covers ${_latestApprovedImport!.documentDetails!.periodStart} to ${_latestApprovedImport!.documentDetails!.periodEnd}.',
                          ),
                          trailing: TextButton(
                            onPressed:
                                _loading ? null : _viewLatestStatementPeriod,
                            child: const Text('View statement period'),
                          ),
                        ),
                      ),
                    if (_period == 'month' &&
                        analytics.spendingByCategory.isEmpty &&
                        _latestApprovedImport?.documentDetails?.periodStart !=
                            null &&
                        _latestApprovedImport?.documentDetails?.periodEnd !=
                            null)
                      const SizedBox(height: 12),
                    _metricGrid(context, analytics),
                    const SizedBox(height: 20),
                    CashFlowSankey(
                      incomeSources: analytics.incomeBySource,
                      expenseCategories: analytics.spendingByCategory,
                      currency: analytics.currency,
                      totalIncome: analytics.trend.fold<int>(
                        0,
                        (sum, point) => sum + point.income,
                      ),
                      totalExpenses: analytics.grossExpenses,
                    ),
                    const SizedBox(height: 20),
                    if (analytics.trend.isNotEmpty) ...[
                      TrendChart(points: analytics.trend),
                      const SizedBox(height: 20),
                      SpendingHeatmap(points: analytics.trend),
                      const SizedBox(height: 20),
                    ],
                    if (categories.isNotEmpty) ...[
                      SpendingChart(
                        categories: categories,
                        onCategorySelected: (category) =>
                            Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => TransactionsScreen(
                              api: widget.api,
                              initialCategorySlug: category.categorySlug,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ] else
                      FinEmptyState(
                        icon: Icons.insights_outlined,
                        title: AppLocalizations.of(context)
                            .analyticsHistoryEmptyTitle,
                        message: AppLocalizations.of(context)
                            .analyticsHistoryEmptyDetail,
                      ),
                    if (analytics.spendingByMerchant.isNotEmpty) ...[
                      Text('Spending by merchant',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Card(
                        child: Column(
                          children: analytics.spendingByMerchant
                              .take(8)
                              .map((merchant) => ListTile(
                                    leading:
                                        const Icon(Icons.storefront_outlined),
                                    title: Text(merchant.label),
                                    trailing: Text(merchant.totalFormatted),
                                    onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => TransactionsScreen(
                                          api: widget.api,
                                          initialSearch: merchant.label,
                                        ),
                                      ),
                                    ),
                                  ))
                              .toList(),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                    _velocityCard(context, analytics.velocity),
                    if (analytics.refundMatches.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      _refundCard(context, analytics.refundMatches),
                    ],
                    if (_health != null) ...[
                      const SizedBox(height: 4),
                      HealthScoreCard(score: _health!),
                      const SizedBox(height: 20),
                    ],
                    if (_subscriptions != null) _subscriptionCard(context),
                    if (insights.insights.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                          AppLocalizations.of(context)
                              .analyticsExplainableInsights,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      ...insights.insights.map((insight) => Card(
                            child: ListTile(
                              leading: Icon(
                                insight.severity == 'positive'
                                    ? Icons.trending_down
                                    : Icons.info_outline,
                                color: insight.severity == 'positive'
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).colorScheme.tertiary,
                              ),
                              title: Text(insight.title),
                              trailing: _priorityChip(
                                  Theme.of(context), insight.priority),
                              subtitle: Text(
                                '${insight.detail}\n${AppLocalizations.of(context).analyticsEvidenceCount(insight.evidenceCount)}',
                              ),
                              isThreeLine: true,
                            ),
                          )),
                    ],
                    if (analytics.timeline.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(AppLocalizations.of(context).analyticsTimeline,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Card(
                        child: Column(
                          children: analytics.timeline
                              .take(8)
                              .map((event) => ListTile(
                                    dense: true,
                                    leading: Icon(_timelineIcon(event.kind)),
                                    title: Text(event.label),
                                    subtitle: Text(
                                        '${event.date} · ${_timelineKind(event.kind)}'),
                                    trailing: Text(event.amountFormatted),
                                  ))
                              .toList(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () =>
                          Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => PlanningScreen(api: widget.api),
                      )),
                      icon: const Icon(Icons.show_chart),
                      label: Text(
                          AppLocalizations.of(context).analyticsPlanAction),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _periodControlCard(
    BuildContext context,
    AnalyticsReport analytics,
  ) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final selector = SizedBox(
      width: 280,
      child: DropdownButtonFormField<String>(
        key: ValueKey(_period),
        initialValue: _period,
        decoration: InputDecoration(labelText: l10n.analyticsPeriodLabel),
        items: [
          DropdownMenuItem(value: 'week', child: Text(l10n.analyticsThisWeek)),
          DropdownMenuItem(
              value: 'month', child: Text(l10n.analyticsThisMonth)),
          DropdownMenuItem(
              value: '3m', child: Text(l10n.analyticsLastThreeMonths)),
          DropdownMenuItem(
              value: '6m', child: Text(l10n.analyticsLastSixMonths)),
          DropdownMenuItem(value: 'year', child: Text(l10n.analyticsLastYear)),
          DropdownMenuItem(
              value: 'lifetime', child: Text(l10n.analyticsAllHistory)),
          DropdownMenuItem(
              value: 'custom', child: Text(l10n.analyticsCustomRange)),
        ],
        onChanged: _refreshing ? null : _changePeriod,
      ),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(FinSpace.lg),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final details = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_periodLabel(_period), style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '${analytics.periodStart} to ${analytics.periodEnd} · ${analytics.currency}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            );
            if (constraints.maxWidth < 620) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  details,
                  const SizedBox(height: 14),
                  SizedBox(width: double.infinity, child: selector),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: details),
                const SizedBox(width: 20),
                selector,
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _refreshFailureCard(BuildContext context) => Card(
        color: context.finColors.warningContainer,
        child: ListTile(
          leading: Icon(Icons.sync_problem,
              color: context.finColors.onWarningContainer),
          title: Text(
            'Latest refresh did not finish',
            style: TextStyle(color: context.finColors.onWarningContainer),
          ),
          subtitle: Text(
            'The report below is still your last successfully loaded data.',
            style: TextStyle(color: context.finColors.onWarningContainer),
          ),
          trailing:
              TextButton(onPressed: _load, child: const Text('Try again')),
        ),
      );

  Widget _metricGrid(BuildContext context, AnalyticsReport analytics) {
    final l10n = AppLocalizations.of(context);
    final values = [
      (
        l10n.analyticsIncome,
        analytics.totalIncomeFormatted,
        Icons.south_west,
        context.finColors.income,
        analytics.recurringIncomeFormatted,
      ),
      (
        l10n.analyticsNetExpenses,
        analytics.netExpensesFormatted,
        Icons.north_east,
        context.finColors.expense,
        '${analytics.expenseCount} transactions',
      ),
      (
        l10n.analyticsSavings,
        analytics.savingsFormatted,
        Icons.savings_outlined,
        context.finColors.positiveTrend,
        analytics.averageMonthlySavingsFormatted,
      ),
      (
        l10n.analyticsSavingsRate,
        '${analytics.savingsRate.toStringAsFixed(1)}%',
        Icons.percent,
        Theme.of(context).colorScheme.primary,
        'For this period',
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1040
            ? 4
            : constraints.maxWidth >= 560
                ? 2
                : 1;
        const gap = 12.0;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final value in values)
              SizedBox(
                width: width,
                height: 70,
                child: FinSummaryTile(
                  label: value.$1,
                  value: value.$2,
                  icon: value.$3,
                  accent: value.$4,
                  supporting: value.$5,
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _velocityCard(BuildContext context, AnalyticsVelocity velocity) {
    final l10n = AppLocalizations.of(context);
    final detail = !velocity.enoughHistory
        ? l10n.analyticsPaceNoHistory
        : velocity.percentDelta == null
            ? l10n.analyticsPaceNoComparison
            : l10n.analyticsPaceProjected(
                velocity.percentDelta!.abs().toStringAsFixed(1),
                velocity.percentDelta! >= 0
                    ? l10n.analyticsPaceAbove
                    : l10n.analyticsPaceBelow,
              );
    return Card(
      child: ListTile(
        leading: const Icon(Icons.speed),
        title: Text(
            l10n.analyticsPaceTitle(velocity.projectedPeriodSpendFormatted)),
        subtitle: Text(
            '$detail\n${l10n.analyticsPaceCurrent(velocity.currentPeriodSpendFormatted)}'),
        isThreeLine: true,
      ),
    );
  }

  Widget _refundCard(BuildContext context, List<AnalyticsRefundMatch> matches) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppLocalizations.of(context).analyticsRefundsMatched,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              AppLocalizations.of(context).analyticsRefundsDetail,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final match in matches.take(4))
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.undo_outlined),
                title: Text(match.merchant),
                subtitle: Text(
                  '${match.amountFormatted} refunded · ${match.daysAfterPurchase} days after purchase',
                ),
                trailing: Text(match.purchaseAmountFormatted),
              ),
          ],
        ),
      ),
    );
  }

  String _periodLabel(String period) {
    final l10n = AppLocalizations.of(context);
    switch (period) {
      case 'week':
        return l10n.analyticsThisWeek;
      case '3m':
        return l10n.analyticsLastThreeMonths;
      case '6m':
        return l10n.analyticsLastSixMonths;
      case 'year':
        return l10n.analyticsLastYear;
      case 'lifetime':
        return l10n.analyticsAllHistory;
      case 'custom':
        return l10n.analyticsCustomRange;
      default:
        return l10n.analyticsThisMonth;
    }
  }

  IconData _timelineIcon(String kind) {
    switch (kind) {
      case 'income':
        return Icons.south_west;
      case 'refund':
        return Icons.undo_outlined;
      case 'transfer':
        return Icons.swap_horiz;
      case 'subscription':
        return Icons.autorenew;
      case 'bill':
        return Icons.receipt_long;
      case 'unusual':
        return Icons.warning_amber;
      default:
        return Icons.shopping_bag_outlined;
    }
  }

  String _timelineKind(String kind) {
    final l10n = AppLocalizations.of(context);
    switch (kind) {
      case 'income':
        return l10n.analyticsTimelineKindIncome;
      case 'refund':
        return l10n.analyticsTimelineKindRefund;
      case 'transfer':
        return l10n.analyticsTimelineKindTransfer;
      case 'subscription':
        return l10n.analyticsTimelineKindSubscription;
      case 'bill':
        return l10n.analyticsTimelineKindBill;
      case 'unusual':
        return l10n.analyticsTimelineKindUnusual;
      default:
        return l10n.analyticsTimelineKindSpending;
    }
  }

  Widget _subscriptionCard(BuildContext context) {
    final report = _subscriptions!;
    final l10n = AppLocalizations.of(context);
    return Card(
      child: ListTile(
        leading: const Icon(Icons.autorenew),
        title: Text(l10n.analyticsRecurringCharges(report.count)),
        subtitle: Text(
          '${report.monthlyTotalFormatted}/month · ${report.annualTotalFormatted}/year',
        ),
        trailing: report.priceIncreases.isEmpty
            ? null
            : Chip(
                label: Text(l10n
                    .analyticsPriceRiseCount(report.priceIncreases.length))),
      ),
    );
  }

  Widget _priorityChip(ThemeData theme, String priority) {
    final l10n = AppLocalizations.of(context);
    final (label, color) = switch (priority) {
      'critical' => (l10n.analyticsPriorityCritical, theme.colorScheme.error),
      'important' => (
          l10n.analyticsPriorityImportant,
          theme.colorScheme.tertiary
        ),
      _ => (l10n.analyticsPriorityInfo, theme.colorScheme.outline),
    };
    return Chip(
      label: Text(label),
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: color.withValues(alpha: 0.35)),
      labelStyle: TextStyle(color: color, fontSize: 11),
    );
  }
}
