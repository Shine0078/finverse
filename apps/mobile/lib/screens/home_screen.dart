import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../api/app_lock.dart';
import '../l10n/app_localizations.dart';
import 'bank_connections_screen.dart';
import 'dashboard_screen.dart';
import 'transactions_screen.dart';
import 'analytics_screen.dart';
import 'profile_screen.dart';
import 'offline_conflict_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.api,
    required this.onSignOut,
    required this.onAccountDeleted,
    this.appLockController,
    super.key,
  });

  final ApiClient api;
  final Future<void> Function() onSignOut;
  final Future<void> Function() onAccountDeleted;
  final AppLockController? appLockController;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  var _index = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            final extended = constraints.maxWidth >= 1120;
            final content = _content(l10n);
            if (!wide) return content;

            // Desktop and tablet users get persistent navigation, while the
            // phone layout keeps the thumb-friendly bottom bar. The same
            // IndexedStack is used in both modes, so changing orientation
            // never loses the active screen or its loaded state.
            return Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: (index) =>
                      setState(() => _index = index),
                  extended: extended,
                  labelType: extended ? null : NavigationRailLabelType.all,
                  groupAlignment: -0.72,
                  leading: _BrandMark(extended: extended),
                  destinations: _railDestinations(l10n),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            );
          },
        ),
        bottomNavigationBar: LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth >= 900
              ? const SizedBox.shrink()
              : NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: (index) =>
                      setState(() => _index = index),
                  destinations: _bottomDestinations(l10n),
                ),
        ));
  }

  Widget _content(AppLocalizations l10n) => ValueListenableBuilder<DateTime?>(
        valueListenable: widget.api.offlineCacheStatus,
        builder: (context, cachedAt, _) => ValueListenableBuilder<int>(
          valueListenable: widget.api.pendingMutationCount,
          builder: (context, pending, _) => ValueListenableBuilder<int>(
            valueListenable: widget.api.rejectedMutationCount,
            builder: (context, rejected, _) => Column(
              children: [
                if (cachedAt != null || pending > 0 || rejected > 0)
                  Material(
                    color: rejected > 0
                        ? Theme.of(context).colorScheme.errorContainer
                        : Theme.of(context).colorScheme.tertiaryContainer,
                    child: ListTile(
                      dense: true,
                      leading: Icon(rejected > 0
                          ? Icons.error_outline
                          : Icons.cloud_off_outlined),
                      title: Text(rejected > 0
                          ? l10n.offlineBannerRejected
                          : pending > 0
                              ? l10n.offlineBannerPending
                              : l10n.offlineBannerTitle),
                      subtitle: Text(rejected > 0
                          ? l10n.offlineBannerRejectedDetail(rejected)
                          : pending > 0
                              ? l10n.offlineBannerPendingDetail(pending)
                              : l10n.offlineBannerLastUpdated(DateFormat.yMMMd()
                                  .add_jm()
                                  .format(cachedAt!.toLocal()))),
                      trailing: rejected > 0
                          ? TextButton(
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => OfflineConflictScreen(
                                    api: widget.api,
                                  ),
                                ),
                              ),
                              child: Text(l10n.offlineBannerReviewRejected),
                            )
                          : null,
                    ),
                  ),
                Expanded(
                  child: IndexedStack(
                    index: _index,
                    children: [
                      DashboardScreen(
                        api: widget.api,
                        appLockController: widget.appLockController,
                        onSignOut: widget.onSignOut,
                        onAccountDeleted: widget.onAccountDeleted,
                      ),
                      TransactionsScreen(api: widget.api),
                      AnalyticsScreen(api: widget.api),
                      BankConnectionsScreen(api: widget.api),
                      ProfileScreen(
                        api: widget.api,
                        appLockController: widget.appLockController,
                        onSignOut: widget.onSignOut,
                        onAccountDeleted: widget.onAccountDeleted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  List<NavigationDestination> _bottomDestinations(AppLocalizations l10n) => [
        NavigationDestination(
            icon: const Icon(Icons.home_outlined), label: l10n.navHome),
        NavigationDestination(
            icon: const Icon(Icons.receipt_long_outlined),
            label: l10n.navTransactions),
        NavigationDestination(
            icon: const Icon(Icons.insights_outlined),
            label: l10n.navAnalytics),
        NavigationDestination(
            icon: const Icon(Icons.account_balance_outlined),
            label: l10n.navAccounts),
        NavigationDestination(
            icon: const Icon(Icons.person_outline), label: l10n.navProfile),
      ];

  List<NavigationRailDestination> _railDestinations(AppLocalizations l10n) => [
        NavigationRailDestination(
            icon: const Icon(Icons.home_outlined), label: Text(l10n.navHome)),
        NavigationRailDestination(
            icon: const Icon(Icons.receipt_long_outlined),
            label: Text(l10n.navTransactions)),
        NavigationRailDestination(
            icon: const Icon(Icons.insights_outlined),
            label: Text(l10n.navAnalytics)),
        NavigationRailDestination(
            icon: const Icon(Icons.account_balance_outlined),
            label: Text(l10n.navAccounts)),
        NavigationRailDestination(
            icon: const Icon(Icons.person_outline),
            label: Text(l10n.navProfile)),
      ];
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.extended});

  final bool extended;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 18, 12, 28),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.account_balance_wallet_outlined,
                color: Colors.white,
                size: 21,
              ),
            ),
            if (extended) ...[
              const SizedBox(width: 12),
              const Text(
                'FINVERSE',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ],
        ),
      );
}
