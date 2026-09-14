import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:cryptography/cryptography.dart';

import 'package:finverse/api/billing_policy.dart';
import 'package:finverse/api/client.dart';
import 'package:finverse/api/app_lock.dart';
import 'package:finverse/api/local_notifications.dart';
import 'package:finverse/api/onboarding_store.dart';
import 'package:finverse/api/offline_cache.dart';
import 'package:finverse/api/passkey_ceremony.dart';
import 'package:finverse/api/session_store.dart';
import 'package:finverse/app_theme.dart';
import 'package:finverse/dashboard_layout.dart';
import 'package:finverse/design/design.dart';
import 'package:finverse/l10n/app_localizations.dart';
import 'package:finverse/main.dart';
import 'package:finverse/models/models.dart';
import 'package:finverse/screens/home_screen.dart';
import 'package:finverse/screens/offline_conflict_screen.dart';
import 'package:finverse/screens/bank_connections_screen.dart';
import 'package:finverse/screens/dashboard_screen.dart';
import 'package:finverse/screens/help_support_screen.dart';
import 'package:finverse/screens/login_screen.dart';
import 'package:finverse/screens/plan_screen.dart';
import 'package:finverse/screens/split_screen.dart';
import 'package:finverse/screens/statement_import_screen.dart';
import 'package:finverse/screens/transaction_detail_screen.dart';
import 'package:finverse/widgets/budget_tile.dart';
import 'package:finverse/widgets/health_score_card.dart';
import 'package:finverse/widgets/net_position_card.dart';
import 'package:finverse/widgets/spending_chart.dart';
import 'package:finverse/widgets/trend_chart.dart';
import 'package:finverse/widgets/spending_heatmap.dart';

/// An in-memory session store keeps these tests off the platform keystore,
/// which has no implementation in the widget-test host.
ApiClient clientWith(MockClient http,
        {SessionStore? store, OfflineCacheStore? offlineCache}) =>
    ApiClient(
      httpClient: http,
      baseUrl: 'http://localhost:9999',
      sessionStore: store ?? InMemorySessionStore(),
      offlineCache: offlineCache,
    );

Widget statementImportHarness(ApiClient api) => MaterialApp(
      home: StatementImportScreen(api: api),
    );

class LocalizationProbe extends StatelessWidget {
  const LocalizationProbe({super.key});

  @override
  Widget build(BuildContext context) =>
      Text(AppLocalizations.of(context).navHome);
}

class FakeDeviceAuthenticator implements DeviceAuthenticator {
  FakeDeviceAuthenticator({this.supported = true, this.result = true});

  bool supported;
  bool result;
  int calls = 0;

  @override
  Future<bool> authenticate(String reason) async {
    calls += 1;
    return result;
  }

  @override
  Future<bool> isSupported() async => supported;
}

class FakePasskeyCeremony implements PasskeyCeremony {
  FakePasskeyCeremony({this.supported = true});

  final bool supported;
  Map<String, dynamic>? lastOptions;

  @override
  bool get isSupported => supported;

  @override
  Future<PasskeyAssertion> authenticate(Map<String, dynamic> options) async {
    lastOptions = options;
    return const PasskeyAssertion(
      id: 'cred-login',
      clientDataJson: 'client-data',
      authenticatorData: 'auth-data',
      signature: 'sig',
    );
  }

  @override
  Future<PasskeyAttestation> register(Map<String, dynamic> options) async {
    lastOptions = options;
    return const PasskeyAttestation(
      id: 'cred-register',
      clientDataJson: 'client-data',
      attestationObject: 'attestation',
    );
  }
}

class UnavailableSessionStore implements SessionStore {
  @override
  Future<SessionTokens?> read() => Future<SessionTokens?>.error(
        const SessionStoreUnavailableException('keystore locked'),
      );

  @override
  Future<void> write(SessionTokens tokens) async {}

  @override
  Future<void> clear() async {}
}

class FailingClearSessionStore extends InMemorySessionStore {
  bool signedOut = false;

  @override
  Future<SessionTokens?> read() async => signedOut ? null : super.read();

  @override
  Future<void> write(SessionTokens tokens) async {
    signedOut = false;
    await super.write(tokens);
  }

  @override
  Future<void> clear() async {
    signedOut = true;
    throw StateError('keystore locked');
  }
}

class FailingWriteSessionStore extends InMemorySessionStore {
  FailingWriteSessionStore({this.failuresRemaining = 1});

  int failuresRemaining;

  @override
  Future<void> write(SessionTokens tokens) async {
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw const SessionStoreUnavailableException('keystore locked');
    }
    await super.write(tokens);
  }
}

class FailingClearCacheStore extends InMemoryOfflineCacheStore {
  @override
  Future<void> clearOwner(String owner) =>
      Future<void>.error(StateError('cache unavailable'));
}

/// Canned billing responses, so each test only overrides what it cares about.
const _freePlanJson = '{"plan":"free","planName":"Free","status":"none",'
    '"bankLinkLimit":1,"entitlements":["data_export"],'
    '"cancelAtPeriodEnd":false,"purchaseAvailable":true,"gatesEnforced":true,'
    '"intervals":["month","year"],"trialDays":14,'
    '"currentPeriodEnd":null,"trialEnd":null}';

const _plansJson = '{"plans":['
    '{"id":"free","name":"Free","bankLinkLimit":1,'
    '"entitlements":["data_export"],"purchasable":false},'
    '{"id":"pro","name":"Pro","bankLinkLimit":25,'
    '"entitlements":["unlimited_bank_links","monthly_pdf_report","data_export"],'
    '"purchasable":true}]}';

http.Response? _billingResponse(http.BaseRequest request,
    {String subscription = _freePlanJson}) {
  final path = request.url.path;
  if (path.endsWith('/billing/subscription')) {
    return http.Response(subscription, 200);
  }
  if (path.endsWith('/billing/plans')) return http.Response(_plansJson, 200);
  return null;
}

void main() {
  testWidgets('help centre explains connectivity and keeps diagnostics safe',
      (tester) async {
    final api = clientWith(MockClient((request) async =>
        request.url.path == '/healthz'
            ? http.Response('{"status":"ok"}', 200)
            : http.Response('{}', 404)));

    await tester.pumpWidget(MaterialApp(home: HelpSupportScreen(api: api)));
    expect(find.text('Help & support'), findsOneWidget);
    expect(find.text('My iPhone cannot connect'), findsOneWidget);
    expect(find.text('Connection not checked yet'), findsOneWidget);

    await tester.tap(find.byTooltip('Check connection'));
    await tester.pumpAndSettle();
    expect(find.text('The API is online.'), findsOneWidget);
  });

  test('local alerts fail closed on unsupported targets', () async {
    final original = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final service = LocalNotificationService();

      expect(service.supported, isFalse);
      expect(await service.initialize(), isFalse);
      expect(service.permissionGranted.value, isFalse);
      await service.presentUnread([
        const FinanceNotification(
          id: 'alert-1',
          kind: 'budget',
          title: 'Budget check',
          message: 'A budget needs your attention.',
          severity: 'warning',
          createdAt: '2026-08-10T12:00:00.000Z',
        ),
      ]);
    } finally {
      debugDefaultTargetPlatformOverride = original;
    }
  });

  // ------------------------------------------------------------ plan and paywall

  testWidgets('shows the current plan and what each tier includes',
      (tester) async {
    final api = clientWith(MockClient((request) async =>
        _billingResponse(request) ?? http.Response('{}', 404)));

    await tester.pumpWidget(MaterialApp(home: PlanScreen(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('Free'), findsWidgets);
    expect(find.text('Connect up to 1 institution.'), findsOneWidget);
    expect(find.text('Pro'), findsOneWidget);
    // Entitlement slugs are never shown raw to a user.
    expect(find.text('Connect multiple institutions'), findsOneWidget);
    expect(find.text('unlimited_bank_links'), findsNothing);
  });

  testWidgets('offers no in-app purchase in the default build', (tester) async {
    // The default mode is the only one safe in every distribution channel:
    // Apple and Google require their own billing for digital subscriptions, so
    // a checkout button shipped by default is a store-rejection risk.
    final api = clientWith(MockClient((request) async =>
        _billingResponse(request) ?? http.Response('{}', 404)));

    await tester.pumpWidget(MaterialApp(home: PlanScreen(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('Upgrade to Pro'), findsNothing);
    // …but the user is still told how to get it, rather than hitting a dead end.
    expect(find.textContaining('managed on the web'), findsOneWidget);
  });

  testWidgets('offers checkout when the build is configured to link out',
      (tester) async {
    http.Request? checkout;
    final api = clientWith(MockClient((request) async {
      final billing = _billingResponse(request);
      if (billing != null) return billing;
      if (request.url.path.endsWith('/billing/checkout-session')) {
        checkout = request;
        return http.Response(
            '{"url":"https://checkout.test/session","expiresAt":null}', 200);
      }
      return http.Response('{}', 404);
    }));

    await tester.pumpWidget(MaterialApp(
      home: PlanScreen(api: api, purchaseMode: BillingPurchaseMode.linkOut),
    ));
    await tester.pumpAndSettle();

    // Annual is preselected: the better deal for the customer, and the default
    // nobody changes is the most-taken path.
    expect(find.text('Start 14-day free trial'), findsOneWidget);
    expect(find.textContaining('Then billed yearly'), findsOneWidget);

    await tester.ensureVisible(find.text('Start 14-day free trial'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start 14-day free trial'));
    await tester.pumpAndSettle();

    // A plan id and an interval cross the wire, never a price — the server
    // decides what to charge, so a tampered client cannot ask for a cheaper one.
    expect(checkout, isNotNull);
    expect(checkout!.body, contains('"plan":"pro"'));
    expect(checkout!.body, contains('"interval":"year"'));
    expect(checkout!.body, isNot(contains('price')));
  });

  testWidgets('sells the interval the customer picks', (tester) async {
    http.Request? checkout;
    final api = clientWith(MockClient((request) async {
      final billing = _billingResponse(request);
      if (billing != null) return billing;
      if (request.url.path.endsWith('/billing/checkout-session')) {
        checkout = request;
        return http.Response(
            '{"url":"https://checkout.test/s","expiresAt":null}', 200);
      }
      return http.Response('{}', 404);
    }));

    await tester.pumpWidget(MaterialApp(
      home: PlanScreen(api: api, purchaseMode: BillingPurchaseMode.linkOut),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Monthly'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Then billed monthly'), findsOneWidget);

    await tester.ensureVisible(find.text('Start 14-day free trial'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start 14-day free trial'));
    await tester.pumpAndSettle();
    expect(checkout!.body, contains('"interval":"month"'));
  });

  testWidgets('says everything is available where no plan limits apply',
      (tester) async {
    // Every developer checkout, CI run, and self-hosted instance is in this
    // state. Showing them a tier comparison for a paywall that does not exist
    // would be describing someone else's deployment.
    const ungated = '{"plan":"free","planName":"Free","status":"none",'
        '"bankLinkLimit":25,"entitlements":["data_export","cash_flow_planning"],'
        '"cancelAtPeriodEnd":false,"purchaseAvailable":false,'
        '"gatesEnforced":false,"intervals":[],"trialDays":0,'
        '"currentPeriodEnd":null,"trialEnd":null}';
    final api = clientWith(MockClient((request) async =>
        _billingResponse(request, subscription: ungated) ??
        http.Response('{}', 404)));

    await tester.pumpWidget(MaterialApp(home: PlanScreen(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('Everything is available'), findsOneWidget);
    expect(find.text('WHAT EACH PLAN INCLUDES'), findsNothing);
  });

  testWidgets(
      'tells a subscriber their payment failed without implying lockout',
      (tester) async {
    const pastDue = '{"plan":"pro","planName":"Pro","status":"past_due",'
        '"bankLinkLimit":25,"entitlements":["unlimited_bank_links"],'
        '"cancelAtPeriodEnd":false,"purchaseAvailable":true,'
        '"currentPeriodEnd":"2026-09-08T00:00:00.000Z","trialEnd":null}';
    final api = clientWith(MockClient((request) async =>
        _billingResponse(request, subscription: pastDue) ??
        http.Response('{}', 404)));

    await tester.pumpWidget(MaterialApp(home: PlanScreen(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('Payment problem'), findsOneWidget);
    // Access continues while the provider retries (ADR-0007). Saying otherwise
    // loses a customer who would have simply updated their card.
    expect(find.textContaining('still active'), findsOneWidget);
  });

  testWidgets('turns a plan refusal into an offer, not a raw error',
      (tester) async {
    final api = clientWith(MockClient((request) async {
      final billing = _billingResponse(request);
      if (billing != null) return billing;
      if (request.url.path.endsWith('/bank-links')) {
        return http.Response('{"count":0,"links":[]}', 200);
      }
      if (request.url.path.endsWith('/accounts')) {
        return http.Response('[]', 200);
      }
      if (request.url.path.endsWith('/bank-links/link-token')) {
        return http.Response(
          '{"error":"plan_upgrade_required","message":"Your Free plan allows 1 institution.",'
          '"entitlement":"unlimited_bank_links","requiredPlan":"pro"}',
          403,
        );
      }
      return http.Response('{}', 200);
    }));

    await tester.pumpWidget(MaterialApp(home: BankConnectionsScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect bank'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField).last, 'correct horse battery staple');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // The named capability, not the JSON body, and a way forward.
    expect(find.text('Connect multiple institutions'), findsOneWidget);
    expect(find.text('See plans'), findsOneWidget);
    expect(find.textContaining('plan_upgrade_required'), findsNothing);
  });

  testWidgets('stops at the link limit before asking for a password',
      (tester) async {
    // The server refuses over-limit connections anyway, but discovering that
    // only after the user has typed their password and authenticated with
    // their bank wastes the most effortful part of the flow.
    var linkTokenRequested = false;
    final api = clientWith(MockClient((request) async {
      final billing = _billingResponse(request);
      if (billing != null) return billing;
      if (request.url.path.endsWith('/bank-links')) {
        return http.Response(
          '{"count":1,"links":[{"id":"link-1","provider":"plaid",'
          '"institutionName":"First Platypus Bank","status":"healthy",'
          '"errorCode":null,"lastSyncedAt":null,"createdAt":"2026-08-01T00:00:00.000Z"}]}',
          200,
        );
      }
      if (request.url.path.endsWith('/accounts')) {
        return http.Response('[]', 200);
      }
      if (request.url.path.endsWith('/bank-links/link-token')) {
        linkTokenRequested = true;
        return http.Response('{"token":"link-sandbox"}', 200);
      }
      return http.Response('{}', 200);
    }));

    await tester.pumpWidget(MaterialApp(home: BankConnectionsScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect bank'));
    await tester.pumpAndSettle();

    expect(find.text('Confirm it’s you'), findsNothing);
    expect(linkTokenRequested, isFalse);
    expect(find.textContaining('connects up to 1 institution'), findsOneWidget);
  });

  testWidgets('shows the Plaid Android allowlist guidance from the API',
      (tester) async {
    final api = clientWith(MockClient((request) async {
      final billing = _billingResponse(request);
      if (billing != null) return billing;
      if (request.url.path.endsWith('/bank-links')) {
        return http.Response('{"count":0,"links":[]}', 200);
      }
      if (request.url.path.endsWith('/accounts')) {
        return http.Response('[]', 200);
      }
      if (request.url.path.endsWith('/bank-links/link-token')) {
        return http.Response(
          '{"code":"PLAID_CONFIGURATION","message":"Android bank connection setup is incomplete. Save com.finverse.finance under Plaid Dashboard > Developers > API > Allowed Android package names, then try again."}',
          503,
        );
      }
      return http.Response('{}', 200);
    }));

    await tester.pumpWidget(MaterialApp(home: BankConnectionsScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect bank'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField).last, 'correct horse battery staple');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Save com.finverse.finance'), findsOneWidget);
  });

  testWidgets('never waits forever on a server that accepts and goes quiet',
      (tester) async {
    // The failure this guards against is not an error, it is silence: a host
    // that sleeps mid-request accepts the connection and never answers. Without
    // a timeout the sign-in button spins forever with no error and no way back,
    // which is indistinguishable from a crashed app.
    //
    // Registration and sign-in bypass the authenticated request path, so they
    // need the timeout applied separately — that is exactly how they lost it.
    // A future that never completes, rather than a long delay: it models the
    // silence exactly and leaves no pending timer behind.
    final api =
        clientWith(MockClient((_) => Completer<http.Response>().future));

    // The matcher is attached before time advances, so the failure is observed
    // rather than surfacing as an unhandled async error.
    final expectation = expectLater(
      api.signIn('sam@example.com', 'correct horse battery staple'),
      throwsA(isA<TimeoutException>()),
    );
    await tester.pump(kRequestTimeout + const Duration(seconds: 1));
    await expectation;
  });

  testWidgets('does not mistake an ordinary 403 for a paywall', (tester) async {
    // Only the server's explicit marker means "upgrade". Dressing every
    // authorisation failure up as an upsell would hide real bugs.
    final response = http.Response('{"message":"Forbidden"}', 403);
    expect(
      PlanUpgradeRequiredException.maybeFrom('/anything', response),
      isNull,
    );
  });

  testWidgets('net position never mixes currencies and exposes chart semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NetPositionCard(accounts: [
          Account(
            id: 'cad-chequing',
            name: 'Chequing',
            type: 'checking',
            mask: '1234',
            currency: 'CAD',
            balanceCurrent: 250000,
            balanceFormatted: r'$2,500.00',
            source: 'provider',
          ),
          Account(
            id: 'cad-card',
            name: 'Card',
            type: 'credit_card',
            mask: '4321',
            currency: 'CAD',
            balanceCurrent: -50000,
            balanceFormatted: r'-$500.00',
            source: 'provider',
          ),
          Account(
            id: 'usd-savings',
            name: 'US savings',
            type: 'savings',
            mask: '9876',
            currency: 'USD',
            balanceCurrent: 100000,
            balanceFormatted: r'$1,000.00',
            source: 'provider',
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('CAD'), findsOneWidget);
    expect(find.text('USD'), findsOneWidget);
    expect(
      find.text(
          'Currencies are shown separately; no estimated exchange rate is applied.'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^CAD net position')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^USD net position')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('manual account controls survive 200% text scaling',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = clientWith(MockClient((request) async {
      if (request.url.path.endsWith('/bank-links')) {
        return http.Response('{"links":[]}', 200);
      }
      if (request.url.path.endsWith('/accounts')) {
        return http.Response(
          '[{"id":"manual-1","name":"Emergency cash reserve","type":"cash","mask":"manual","currency":"CAD","balanceCurrent":125000,"balanceFormatted":"\$1,250.00","source":"manual","utilization":null}]',
          200,
        );
      }
      return http.Response('{}', 200);
    }));

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: BankConnectionsScreen(api: api),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -350));
    await tester.pumpAndSettle();

    expect(find.text('Emergency cash reserve'), findsOneWidget);
    expect(find.text('Add manual'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('dashboard layout hides selected cards without deleting data', () async {
    final layout = DashboardLayoutController.inMemory();
    expect(layout.isVisible(DashboardCard.budgets), isTrue);
    await layout.setVisible(DashboardCard.budgets, false);
    expect(layout.isVisible(DashboardCard.budgets), isFalse);
    expect(layout.isVisible(DashboardCard.transactions), isTrue);
    await layout.setVisible(DashboardCard.budgets, true);
    expect(layout.isVisible(DashboardCard.budgets), isTrue);
  });

  testWidgets('category spending legend reports the selected category',
      (tester) async {
    String? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SpendingChart(
          categories: [
            CategorySpend(
              categorySlug: 'groceries',
              categoryName: 'Groceries',
              total: 12550,
              totalFormatted: r'$125.50',
              transactionCount: 4,
            ),
          ],
          onCategorySelected: (category) => selected = category.categorySlug,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Groceries'));
    expect(selected, 'groceries');
  });

  testWidgets(
      'financial visuals have spoken equivalents and survive 200% text scaling',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: Scaffold(
          body: SingleChildScrollView(
            child: Column(children: [
              SpendingChart(categories: [
                CategorySpend(
                  categorySlug: 'groceries',
                  categoryName: 'Groceries',
                  total: 12550,
                  totalFormatted: r'$125.50',
                  transactionCount: 4,
                ),
              ]),
              BudgetTile(
                progress: BudgetProgress(
                  budgetId: 'budget-groceries',
                  categorySlug: 'groceries',
                  categoryName: 'Groceries',
                  spentFormatted: r'$125.50',
                  limitFormatted: r'$300.00',
                  remainingFormatted: r'$174.50',
                  percentUsed: 41.8,
                  status: 'on_track',
                  daysRemaining: 12,
                  projectedToExceed: false,
                ),
              ),
              HealthScoreCard(
                score: HealthScore(
                  score: 742,
                  band: 'good',
                  components: [
                    ScoreComponent(
                      key: 'cash_flow',
                      label: 'Cash flow',
                      points: 160,
                      maxPoints: 200,
                      detail: 'Income is above expenses.',
                    ),
                  ],
                  topActions: const [],
                ),
              ),
            ]),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.bySemanticsLabel(r'Groceries: $125.50 across 4 transactions.'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
          r'Groceries budget. $125.50 spent of $300.00. 42 percent used. $174.50 left. 12 days left.'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Financial health score 742 out of 1000, good.'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
          'Cash flow: 160 of 200 points. Income is above expenses.'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('financial visuals keep spoken labels under high contrast',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(highContrast: true),
        child: Scaffold(
          body: SpendingChart(categories: [
            CategorySpend(
              categorySlug: 'groceries',
              categoryName: 'Groceries',
              total: 12550,
              totalFormatted: r'$125.50',
              transactionCount: 4,
            ),
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel(r'Groceries: $125.50 across 4 transactions.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('spending heatmap exposes daily intensity semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SpendingHeatmap(points: const [
          AnalyticsTrendPoint(
            date: '2026-08-02',
            income: 0,
            incomeFormatted: r'$0.00',
            expenses: 5000,
            expensesFormatted: r'$50.00',
            refunds: 0,
            refundsFormatted: r'$0.00',
            net: -5000,
            netFormatted: r'-$50.00',
          ),
          AnalyticsTrendPoint(
            date: '2026-08-03',
            income: 0,
            incomeFormatted: r'$0.00',
            expenses: 8000,
            expensesFormatted: r'$80.00',
            refunds: 0,
            refundsFormatted: r'$0.00',
            net: -8000,
            netFormatted: r'-$80.00',
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Daily spending'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        r'Daily spending heatmap across 2 days. 2 days had spending. Highest spending $80.00 on 2026-08-03.',
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('trend chart exposes income and spending semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TrendChart(points: const [
          AnalyticsTrendPoint(
            date: '2026-08-01',
            income: 10000,
            incomeFormatted: r'$100.00',
            expenses: 5000,
            expensesFormatted: r'$50.00',
            refunds: 0,
            refundsFormatted: r'$0.00',
            net: 5000,
            netFormatted: r'$50.00',
          ),
          AnalyticsTrendPoint(
            date: '2026-08-02',
            income: 20000,
            incomeFormatted: r'$200.00',
            expenses: 8000,
            expensesFormatted: r'$80.00',
            refunds: 0,
            refundsFormatted: r'$0.00',
            net: 12000,
            netFormatted: r'$120.00',
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel(
        r'Income versus spending line chart across 2 periods. Highest income $200.00; highest spending $80.00.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('analytics-trend-chart')), findsOneWidget);
    semantics.dispose();
  });

  test('device app lock authenticates before enable and after backgrounding',
      () async {
    final authenticator = FakeDeviceAuthenticator();
    final controller = AppLockController(
      store: InMemoryAppLockStore(),
      authenticator: authenticator,
    );

    await controller.initialize();
    expect(controller.enabled, isFalse);
    expect(await controller.setEnabled(true), AppLockChangeResult.changed);
    expect(controller.enabled, isTrue);
    expect(authenticator.calls, 1);

    controller.lock();
    expect(controller.locked, isTrue);
    expect(await controller.unlock(), isTrue);
    expect(controller.locked, isFalse);
    expect(authenticator.calls, 2);
  });

  testWidgets(
      'app lock hides financial UI until device authentication succeeds',
      (tester) async {
    final authenticator = FakeDeviceAuthenticator(result: false);
    final controller = AppLockController(
      store: InMemoryAppLockStore(enabled: true),
      authenticator: authenticator,
    );
    await controller.initialize();

    await tester.pumpWidget(MaterialApp(
      home: AppLockGate(
        controller: controller,
        onSignOut: () async {},
        child: const Text('Sensitive financial dashboard'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('FINVERSE is locked'), findsOneWidget);
    expect(find.text('Sensitive financial dashboard'), findsNothing);
    authenticator.result = true;
    await tester.tap(find.text('Unlock FINVERSE'));
    await tester.pumpAndSettle();
    expect(find.text('Sensitive financial dashboard'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('FINVERSE is locked'), findsOneWidget);
    expect(find.text('Sensitive financial dashboard'), findsNothing);
  });

  test('offline payload encryption authenticates ciphertext and context',
      () async {
    final cipher = OfflineCachePayloadCipher();
    final key = SecretKey(List<int>.generate(32, (index) => index));
    final envelope = await cipher.encrypt('financial-data', key, [1, 2, 3]);

    expect(await cipher.decrypt(envelope, key, [1, 2, 3]), 'financial-data');
    final tampered = EncryptedCacheEnvelope(
      nonce: envelope.nonce,
      mac: envelope.mac,
      ciphertext: [...envelope.ciphertext]..[0] = envelope.ciphertext[0] ^ 1,
    );
    await expectLater(
      cipher.decrypt(tampered, key, [1, 2, 3]),
      throwsA(anything),
    );
    await expectLater(
      cipher.decrypt(envelope, key, [9, 9, 9]),
      throwsA(anything),
    );
  });

  test('falls back to user-scoped cached reads and purges them on sign-out',
      () async {
    final store = InMemorySessionStore();
    final cache = InMemoryOfflineCacheStore();
    await store.write(const SessionTokens(
      accessToken: 'access',
      refreshToken: 'refresh',
      refreshExpiresAt: '2099-09-08T00:00:00.000Z',
      userId: 'user-1',
    ));
    var requests = 0;
    final api = clientWith(
      MockClient((request) async {
        requests++;
        if (request.method == 'POST') throw http.ClientException('offline');
        if (requests == 1) return http.Response('[]', 200);
        throw http.ClientException('offline');
      }),
      store: store,
      offlineCache: cache,
    );
    await api.restoreSession();

    expect(await api.accounts(), isEmpty);
    api.resetOfflineStatus();
    expect(await api.accounts(), isEmpty);
    expect(api.usedOfflineCache, isTrue);

    await api.signOut();
    expect(await cache.read('user-1', '/accounts'), isNull);
  });

  test('sign out clears the active session even when local cleanup fails',
      () async {
    final store = FailingClearSessionStore();
    final cache = FailingClearCacheStore();
    await store.write(const SessionTokens(
      accessToken: 'access',
      refreshToken: 'refresh',
      refreshExpiresAt: '2099-09-08T00:00:00.000Z',
      userId: 'user-1',
    ));
    final api = clientWith(
      MockClient((request) async => http.Response('{}', 200)),
      store: store,
      offlineCache: cache,
    );
    expect(await api.restoreSession(), isTrue);

    await expectLater(api.signOut(), completes);
    expect(api.isAuthenticated, isFalse);
    final nextLaunch = clientWith(
      MockClient((request) async => http.Response('{}', 200)),
      store: store,
      offlineCache: cache,
    );
    expect(await nextLaunch.restoreSession(), isFalse);
  });

  test('account deletion still completes when local cleanup is unavailable',
      () async {
    final store = FailingClearSessionStore();
    await store.write(const SessionTokens(
      accessToken: 'active-access',
      refreshToken: 'active-refresh',
      refreshExpiresAt: '',
      userId: 'user-1',
    ));
    final api = clientWith(
      MockClient((request) async => http.Response(
            '{"purgeScheduledFor":"2026-09-07T00:00:00.000Z"}',
            202,
          )),
      store: store,
    );
    await api.restoreSession();

    await expectLater(
        api.requestAccountDeletion('my current password'), completes);
    expect(api.isAuthenticated, isFalse);
    final nextLaunch = clientWith(
      MockClient((request) async => http.Response('{}', 200)),
      store: store,
    );
    expect(await nextLaunch.restoreSession(), isFalse);
  });

  test('queues offline preference edits and replays the latest value',
      () async {
    final store = InMemorySessionStore();
    final cache = InMemoryOfflineCacheStore();
    await store.write(const SessionTokens(
      accessToken: 'access',
      refreshToken: 'refresh',
      refreshExpiresAt: '2099-09-08T00:00:00.000Z',
      userId: 'user-1',
    ));
    var online = false;
    var replayRequests = 0;
    final api = clientWith(
      MockClient((request) async {
        if (!online) throw http.ClientException('offline');
        replayRequests++;
        return http.Response('{"transaction":{}}', 200);
      }),
      store: store,
      offlineCache: cache,
    );
    await api.restoreSession();

    await expectLater(
      api.updateTransactionPreferences('txn-1', isRecurring: false),
      throwsA(isA<OfflineMutationQueuedException>()),
    );
    await expectLater(
      api.updateTransactionPreferences('txn-1', isRecurring: true),
      throwsA(isA<OfflineMutationQueuedException>()),
    );
    await expectLater(
      api.updateTransactionPreferences('txn-1', duplicateReported: true),
      throwsA(isA<OfflineMutationQueuedException>()),
    );
    expect(api.pendingMutationCount.value, 1);
    final pending = await cache.pendingMutations('user-1');
    expect(pending, hasLength(1));
    expect(pending.single.body, contains('"isRecurring":true'));
    expect(pending.single.body, contains('"duplicateReported":true'));

    online = true;
    expect(await api.replayOfflineMutations(), 1);
    expect(replayRequests, 1);
    expect(api.pendingMutationCount.value, 0);
    expect(await cache.pendingMutations('user-1'), isEmpty);
  });

  test(
      'keeps throttled offline mutations queued instead of permanently rejecting them',
      () async {
    final store = InMemorySessionStore();
    final cache = InMemoryOfflineCacheStore();
    await store.write(const SessionTokens(
      accessToken: 'access',
      refreshToken: 'refresh',
      refreshExpiresAt: '2099-09-08T00:00:00.000Z',
      userId: 'user-1',
    ));
    final api = clientWith(
      MockClient((request) async =>
          http.Response('{"message":"Too many requests"}', 429)),
      store: store,
      offlineCache: cache,
    );
    await api.restoreSession();
    await cache.enqueueMutation(
      'user-1',
      'PATCH',
      '/transactions/txn-1/preferences',
      '{"notes":"keep"}',
    );
    expect(await api.replayOfflineMutations(), 0);
    expect(api.rejectedMutationCount.value, 0);
    expect(await cache.pendingMutations('user-1'), hasLength(1));
  });

  test('keeps rejected offline mutations visible and isolated by account',
      () async {
    final store = InMemorySessionStore();
    final cache = InMemoryOfflineCacheStore();
    await store.write(const SessionTokens(
      accessToken: 'access',
      refreshToken: 'refresh',
      refreshExpiresAt: '2099-09-08T00:00:00.000Z',
      userId: 'user-1',
    ));
    await cache.enqueueMutation(
      'user-2',
      'PATCH',
      '/transactions/txn-other',
      '{"notes":"other-user"}',
    );
    var online = false;
    final api = clientWith(
      MockClient((request) async {
        if (!online) throw http.ClientException('offline');
        return http.Response('{"message":"validation failed"}', 422);
      }),
      store: store,
      offlineCache: cache,
    );
    await api.restoreSession();

    await expectLater(
      api.updateTransactionPreferences('txn-1', note: 'queued'),
      throwsA(isA<OfflineMutationQueuedException>()),
    );
    expect(api.pendingMutationCount.value, 1);
    expect(await cache.pendingMutations('user-2'), hasLength(1));

    online = true;
    expect(await api.replayOfflineMutations(), 0);
    expect(api.pendingMutationCount.value, 0);
    expect(api.rejectedMutationCount.value, 1);
    expect(await cache.pendingMutations('user-1'), isEmpty);
    expect(await cache.pendingMutations('user-2'), hasLength(1));
    expect(api.rejectedMutations.single.reason, contains('no longer valid'));
  });

  testWidgets('opens the offline conflict center from the rejected banner',
      (tester) async {
    final store = InMemorySessionStore();
    final cache = InMemoryOfflineCacheStore();
    await store.write(const SessionTokens(
      accessToken: 'access',
      refreshToken: 'refresh',
      refreshExpiresAt: '2099-09-08T00:00:00.000Z',
      userId: 'user-1',
    ));
    var online = false;
    final api = clientWith(
      MockClient((request) async {
        if (!online) throw http.ClientException('offline');
        return http.Response('{"message":"validation failed"}', 422);
      }),
      store: store,
      offlineCache: cache,
    );
    await api.restoreSession();
    await expectLater(
      api.updateTransactionPreferences('txn-1', note: 'queued'),
      throwsA(isA<OfflineMutationQueuedException>()),
    );
    online = true;
    expect(await api.replayOfflineMutations(), 0);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        AppLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: OfflineConflictScreen(api: api),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Offline changes'), findsOneWidget);
    expect(find.text('/transactions/txn-1/preferences'), findsOneWidget);
    expect(find.textContaining('no longer valid'), findsOneWidget);
  });

  testWidgets('spending heatmap survives 200% text scaling', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: Scaffold(
          body: SingleChildScrollView(
            child: SpendingHeatmap(points: const [
              AnalyticsTrendPoint(
                date: '2026-08-02',
                income: 0,
                incomeFormatted: r'$0.00',
                expenses: 5000,
                expensesFormatted: r'$50.00',
                refunds: 0,
                refundsFormatted: r'$0.00',
                net: -5000,
                netFormatted: r'-$50.00',
              ),
            ]),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Daily spending'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('portable export confirms the password and attaches the active session',
      () async {
    final store = InMemorySessionStore();
    await store.write(const SessionTokens(
      accessToken: 'active-access',
      refreshToken: 'active-refresh',
      refreshExpiresAt: '2099-09-08T00:00:00.000Z',
      userId: 'user-1',
    ));
    late http.Request seen;
    final api = clientWith(MockClient((request) async {
      seen = request;
      return http.Response('{"format":"finverse-portable-export"}', 200);
    }), store: store);
    await api.restoreSession();

    final exported = await api.exportData('correct horse battery staple');

    expect(exported, contains('finverse-portable-export'));
    expect(seen.headers['authorization'], 'Bearer active-access');
    expect(seen.body, contains('correct horse battery staple'));
  });

  test('signing out everywhere clears this device when the server is offline',
      () async {
    final store = InMemorySessionStore();
    await store.write(const SessionTokens(
      accessToken: 'active-access',
      refreshToken: 'active-refresh',
      refreshExpiresAt: '2099-09-08T00:00:00.000Z',
      userId: 'user-1',
    ));
    final api = clientWith(
      MockClient((_) => throw http.ClientException('offline')),
      store: store,
    );
    expect(await api.restoreSession(), isTrue);

    expect(await api.signOutEverywhere(), isFalse);
    expect(api.isAuthenticated, isFalse);
    expect(await store.read(), isNull);
  });

  testWidgets('first launch explains the product before sign-in',
      (tester) async {
    final api = clientWith(MockClient((_) async => http.Response('{}', 200)));
    final onboarding = InMemoryOnboardingStore();

    await tester.pumpWidget(
      FinverseApp(api: api, onboardingStore: onboarding),
    );
    await tester.pumpAndSettle();

    expect(find.text('See your money clearly'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsWidgets);
    expect(await onboarding.isComplete(), isTrue);
  });

  testWidgets('shows sign-in when there is no stored session', (tester) async {
    final api = clientWith(MockClient((_) async => http.Response('{}', 200)));

    await tester.pumpWidget(FinverseApp(api: api));
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('FINVERSE'), findsOneWidget);
    expect(find.text('Sign in'), findsWidgets);
  });

  testWidgets('toggles between sign in and registration', (tester) async {
    final api = clientWith(MockClient((_) async => http.Response('{}', 200)));

    await tester.pumpWidget(FinverseApp(api: api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle();

    expect(find.text('Create your account'), findsOneWidget);
    expect(find.text('At least 12 characters'), findsOneWidget);
  });

  testWidgets('rejects a short password before contacting the server',
      (tester) async {
    var registrationRequests = 0;
    final api = clientWith(MockClient((request) async {
      if (!request.url.path.endsWith('/legal')) registrationRequests += 1;
      return http.Response('{}', 200);
    }));

    await tester.pumpWidget(FinverseApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'sam@example.com');
    await tester.enterText(find.byType(TextFormField).last, 'short');
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    expect(find.text('Use at least 12 characters.'), findsOneWidget);
    expect(registrationRequests, 0);
  });

  testWidgets('requires both configured legal documents before registration',
      (tester) async {
    final api = clientWith(MockClient((request) async {
      if (request.url.path.endsWith('/legal')) {
        return http.Response(
          '{"registrationRequired":true,"terms":{"version":"terms-v1","url":"https://finverse.example/terms-v1"},"privacyNotice":{"version":"privacy-v1","url":"https://finverse.example/privacy-v1"}}',
          200,
        );
      }
      return http.Response('{}', 200);
    }));

    await tester.pumpWidget(FinverseApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle();

    expect(find.text('I accept the Terms of Service'), findsOneWidget);
    expect(find.text('I acknowledge the Privacy Notice'), findsOneWidget);
    expect(find.text('Read Terms (terms-v1)'), findsOneWidget);
    expect(find.text('Read Privacy Notice (privacy-v1)'), findsOneWidget);

    FilledButton create =
        tester.widget(find.widgetWithText(FilledButton, 'Create account'));
    expect(create.onPressed, isNull);
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    create = tester.widget(find.widgetWithText(FilledButton, 'Create account'));
    expect(create.onPressed, isNotNull);
  });

  testWidgets('bank linking requires FINVERSE password step-up',
      (tester) async {
    http.Request? linkRequest;
    final api = clientWith(MockClient((request) async {
      if (request.method == 'GET' && request.url.path.endsWith('/bank-links')) {
        return http.Response('{"count":0,"links":[]}', 200);
      }
      if (request.url.path.endsWith('/bank-links/link-token')) {
        linkRequest = request;
        return http.Response('{"message":"not configured"}', 503);
      }
      return http.Response('{}', 200);
    }));

    await tester.pumpWidget(MaterialApp(home: BankConnectionsScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect bank'));
    await tester.pumpAndSettle();

    expect(find.text('Confirm it’s you'), findsOneWidget);
    expect(find.text('FINVERSE password'), findsOneWidget);
    await tester.enterText(
        find.byType(TextField).last, 'correct horse battery staple');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(linkRequest, isNotNull);
    expect(linkRequest!.body, contains('correct horse battery staple'));
  });

  testWidgets('surfaces the server message when sign-in is rejected',
      (tester) async {
    final api = clientWith(MockClient((_) async => http.Response(
          '{"message":"Incorrect email or password."}',
          401,
        )));

    await tester.pumpWidget(FinverseApp(api: api));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'sam@example.com');
    await tester.enterText(
        find.byType(TextFormField).last, 'correct horse battery staple');
    await tester.tap(find.text('Sign in').last);
    await tester.pumpAndSettle();

    expect(find.text('Incorrect email or password.'), findsOneWidget);
  });

  testWidgets('explains secure-session persistence failures after login',
      (tester) async {
    final api = clientWith(
      MockClient((request) async => http.Response(
            '{"user":{"id":"user-1","email":"sam@example.com"},'
            '"tokens":{"accessToken":"access","refreshToken":"refresh",'
            '"refreshExpiresAt":"2099-01-01T00:00:00.000Z"}}',
            200,
          )),
      store: FailingWriteSessionStore(failuresRemaining: 99),
    );

    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(api: api, onSignedIn: () => fail('must not sign in')),
    ));
    await tester.enterText(find.byType(TextFormField).first, 'sam@example.com');
    await tester.enterText(
        find.byType(TextFormField).last, 'correct horse battery staple');
    await tester.tap(find.text('Sign in').last);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Your credentials were accepted, but this device could not save the secure session. Unlock your phone and try again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('completes an authenticator challenge before signing in',
      (tester) async {
    var signedIn = false;
    http.Request? verification;
    final api = clientWith(MockClient((request) async {
      if (request.url.path.endsWith('/auth/login')) {
        return http.Response(
          '{"mfaRequired":true,"challengeToken":"opaque-challenge","expiresAt":"2026-08-08T13:00:00.000Z"}',
          200,
        );
      }
      verification = request;
      return http.Response(
        '{"user":{"id":"user-1","email":"sam@example.com","emailVerified":true},"tokens":{"accessToken":"access","refreshToken":"refresh","refreshExpiresAt":"2099-09-08T00:00:00.000Z"}}',
        200,
      );
    }));

    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(api: api, onSignedIn: () => signedIn = true),
    ));
    await tester.enterText(find.byType(TextFormField).first, 'sam@example.com');
    await tester.enterText(
        find.byType(TextFormField).last, 'correct horse battery staple');
    await tester.tap(find.text('Sign in').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Verify it\'s you'), findsOneWidget);
    expect(signedIn, isFalse);
    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.tap(find.text('Verify'));
    await tester.pumpAndSettle();

    expect(signedIn, isTrue);
    expect(verification?.url.path, endsWith('/auth/mfa/verify'));
    expect(verification?.body, contains('opaque-challenge'));
    expect(verification?.body, contains('123456'));
  });

  test('does not keep a fresh login in memory when secure storage fails',
      () async {
    final store = FailingWriteSessionStore(failuresRemaining: 99);
    final api = clientWith(
      MockClient((request) async {
        expect(request.url.path, endsWith('/auth/login'));
        return http.Response(
          '{"user":{"id":"user-1","email":"sam@example.com"},'
          '"tokens":{"accessToken":"access","refreshToken":"refresh",'
          '"refreshExpiresAt":"2099-01-01T00:00:00.000Z"}}',
          200,
        );
      }),
      store: store,
    );

    await expectLater(
      api.signIn('sam@example.com', 'correct horse battery staple'),
      throwsA(isA<SessionStoreUnavailableException>()),
    );
    expect(api.isAuthenticated, isFalse);
    expect(await store.read(), isNull);
  });

  testWidgets('restores a stored session straight to the dashboard',
      (tester) async {
    final store = InMemorySessionStore();
    await store.write(const SessionTokens(
      accessToken: 'stored-access',
      refreshToken: 'stored-refresh',
      refreshExpiresAt: '',
    ));

    // Every dashboard call returns an empty payload; the point is which screen
    // renders, not what it renders.
    final api = clientWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/auth/me')) {
          return http.Response('{"id":"u1","email":"sam@example.com"}', 200);
        }
        return http.Response('{"transactions":[],"budgets":[],"count":0}', 200);
      }),
      store: store,
    );

    await tester.pumpWidget(FinverseApp(api: api));
    await tester.pump();

    expect(find.byType(LoginScreen), findsNothing);
  });

  test('refreshes an expired access token during session restore', () async {
    String segment(Map<String, dynamic> value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final expiredAccess = '${segment({
          'alg': 'HS256',
          'typ': 'JWT'
        })}.${segment({'sub': 'user-1', 'exp': 1})}.signature';
    final store = InMemorySessionStore();
    await store.write(SessionTokens(
      accessToken: expiredAccess,
      refreshToken: 'stored-refresh',
      refreshExpiresAt: '2099-01-01T00:00:00.000Z',
      userId: 'user-1',
    ));
    var refreshCalls = 0;
    final api = clientWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/auth/refresh')) {
          refreshCalls++;
          return http.Response(
            '{"tokens":{"accessToken":"fresh","refreshToken":"next","refreshExpiresAt":"2099-01-01T00:00:00.000Z"}}',
            200,
          );
        }
        return http.Response('{}', 200);
      }),
      store: store,
    );

    expect(await api.restoreSession(), isTrue);
    expect(refreshCalls, 1);
    expect((await store.read())?.accessToken, 'fresh');
  });

  test('keeps a rotated token in memory until secure storage recovers',
      () async {
    String segment(Map<String, dynamic> value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final expiredAccess = '${segment({
          'alg': 'HS256',
          'typ': 'JWT'
        })}.${segment({'sub': 'user-1', 'exp': 1})}.signature';
    final store = FailingWriteSessionStore(failuresRemaining: 0);
    await store.write(SessionTokens(
      accessToken: expiredAccess,
      refreshToken: 'stored-refresh',
      refreshExpiresAt: '2099-01-01T00:00:00.000Z',
      userId: 'user-1',
    ));
    store.failuresRemaining = 1;

    final api = clientWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/auth/refresh')) {
          return http.Response(
            '{"tokens":{"accessToken":"fresh","refreshToken":"next",'
            '"refreshExpiresAt":"2099-01-01T00:00:00.000Z"}}',
            200,
          );
        }
        if (request.url.path.endsWith('/accounts')) {
          return http.Response('[]', 200);
        }
        return http.Response('{}', 200);
      }),
      store: store,
    );

    expect(await api.restoreSession(), isTrue);
    expect(api.isAuthenticated, isTrue);
    expect((await store.read())?.refreshToken, 'stored-refresh');

    await api.accounts();
    expect((await store.read())?.refreshToken, 'next');
  });

  test('keeps an expired session when refresh is unavailable offline',
      () async {
    String segment(Map<String, dynamic> value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final expiredAccess = '${segment({
          'alg': 'HS256',
          'typ': 'JWT'
        })}.${segment({'sub': 'user-1', 'exp': 1})}.signature';
    final store = InMemorySessionStore();
    final original = SessionTokens(
      accessToken: expiredAccess,
      refreshToken: 'stored-refresh',
      refreshExpiresAt: '2099-01-01T00:00:00.000Z',
      userId: 'user-1',
    );
    await store.write(original);
    final api = clientWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/auth/refresh')) {
          throw http.ClientException('offline');
        }
        return http.Response('{}', 200);
      }),
      store: store,
    );

    expect(await api.restoreSession(), isTrue);
    expect(api.isAuthenticated, isTrue);
    expect((await store.read())?.refreshToken, original.refreshToken);
  });

  test('serves cached reads when a stale access token cannot refresh offline',
      () async {
    String segment(Map<String, dynamic> value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final expiredAccess = '${segment({
          'alg': 'HS256',
          'typ': 'JWT'
        })}.${segment({'sub': 'user-1', 'exp': 1})}.signature';
    final store = InMemorySessionStore();
    await store.write(SessionTokens(
      accessToken: expiredAccess,
      refreshToken: 'stored-refresh',
      refreshExpiresAt: '2099-01-01T00:00:00.000Z',
      userId: 'user-1',
    ));
    final cache = InMemoryOfflineCacheStore();
    await cache.write('user-1', '/accounts', '[]');

    final api = clientWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/auth/refresh')) {
          throw http.ClientException('offline');
        }
        return http.Response('expired', 401);
      }),
      store: store,
      offlineCache: cache,
    );

    expect(await api.restoreSession(), isTrue);
    expect(await api.accounts(), isEmpty);
    expect(api.isAuthenticated, isTrue);
  });

  testWidgets('shows a retry state when secure session storage is unavailable',
      (tester) async {
    final api = clientWith(
      MockClient((_) async => http.Response('{}', 200)),
      store: UnavailableSessionStore(),
    );
    final appLock = AppLockController(
      store: InMemoryAppLockStore(),
      authenticator: FakeDeviceAuthenticator(),
    );

    await tester.pumpWidget(MaterialApp(
      home: AuthGate(api: api, appLockController: appLock),
    ));
    await tester.pumpAndSettle();

    expect(find.text('FINVERSE is waiting for secure storage'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
  });

  test('clears a session whose refresh expiry is already past', () async {
    final store = InMemorySessionStore();
    await store.write(const SessionTokens(
      accessToken: 'stored-access',
      refreshToken: 'stored-refresh',
      refreshExpiresAt: '2020-01-01T00:00:00.000Z',
    ));
    var requests = 0;
    final api = clientWith(
      MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
      store: store,
    );

    expect(await api.restoreSession(), isFalse);
    expect(requests, 0);
    expect(await store.read(), isNull);
  });

  testWidgets('attaches the bearer token to API calls', (tester) async {
    final store = InMemorySessionStore();
    await store.write(const SessionTokens(
      accessToken: 'stored-access',
      refreshToken: 'stored-refresh',
      refreshExpiresAt: '',
    ));

    String? seenAuthorization;
    final api = clientWith(
      MockClient((request) async {
        seenAuthorization ??= request.headers['authorization'];
        return http.Response('[]', 200);
      }),
      store: store,
    );

    await api.restoreSession();
    await api.accounts();

    expect(seenAuthorization, 'Bearer stored-access');
  });

  test('broadcasts a revision after a successful authenticated write',
      () async {
    final api = clientWith(
      MockClient((_) async => http.Response('{}', 200)),
    );
    var revisions = 0;
    api.dataRevision.addListener(() => revisions++);

    await api.deleteManualAccount('manual-1');

    expect(revisions, 1);
  });

  testWidgets('refreshes once on 401, then retries the original call',
      (tester) async {
    final store = InMemorySessionStore();
    await store.write(const SessionTokens(
      accessToken: 'expired',
      refreshToken: 'good-refresh',
      refreshExpiresAt: '',
    ));

    final calls = <String>[];
    final api = clientWith(
      MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');

        if (request.url.path.endsWith('/auth/refresh')) {
          return http.Response(
            '{"tokens":{"accessToken":"fresh","refreshToken":"next","refreshExpiresAt":""}}',
            200,
          );
        }
        // Reject the stale token once, accept the refreshed one.
        if (request.headers['authorization'] == 'Bearer expired') {
          return http.Response('{"message":"expired"}', 401);
        }
        return http.Response('[]', 200);
      }),
      store: store,
    );

    await api.restoreSession();
    final accounts = await api.accounts();

    expect(accounts, isEmpty);
    expect(calls.where((c) => c.contains('/auth/refresh')), hasLength(1));
    // Original call, refresh, retry — not an endless loop.
    expect(calls, hasLength(3));
  });

  test('shares one refresh rotation across concurrent 401 responses', () async {
    final store = InMemorySessionStore();
    await store.write(const SessionTokens(
      accessToken: 'expired',
      refreshToken: 'good-refresh',
      refreshExpiresAt: '',
    ));

    var refreshCalls = 0;
    var staleCalls = 0;
    final api = clientWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/auth/refresh')) {
          refreshCalls += 1;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return http.Response(
            '{"tokens":{"accessToken":"fresh","refreshToken":"next","refreshExpiresAt":""}}',
            200,
          );
        }
        if (request.headers['authorization'] == 'Bearer expired') {
          staleCalls += 1;
          return http.Response('{"message":"expired"}', 401);
        }
        return http.Response('[]', 200);
      }),
      store: store,
    );

    await api.restoreSession();
    await Future.wait([api.accounts(), api.accounts()]);

    expect(refreshCalls, 1);
    expect(staleCalls, 2);
    expect(api.isAuthenticated, isTrue);
    expect((await store.read())?.refreshToken, 'next');
  });

  test('canonicalises API origins and rejects unsafe values', () {
    expect(normalizeBaseUrl('https://api.example.com/'),
        'https://api.example.com');
    expect(normalizeBaseUrl('https://api.example.com/v1/'),
        'https://api.example.com/v1');
    expect(() => normalizeBaseUrl('api.example.com'), throwsArgumentError);
    expect(() => normalizeBaseUrl('https://api.example.com/?token=x'),
        throwsArgumentError);
    expect(() => normalizeBaseUrl('https://user:pass@api.example.com'),
        throwsArgumentError);
    expect(
      () => normalizeBaseUrl('http://localhost:3000', release: true),
      throwsArgumentError,
    );
    expect(
      () => normalizeBaseUrl('https://127.0.0.1:3000', release: true),
      throwsArgumentError,
    );
    expect(
      normalizeBaseUrl('https://api.example.com/', release: true),
      'https://api.example.com',
    );
  });

  test('formats date filters as local calendar dates', () {
    expect(dateOnly(DateTime(2026, 1, 2, 23, 59)), '2026-01-02');
    expect(dateOnly(DateTime.utc(2026, 12, 31)), '2026-12-31');
  });

  test('turns API failures into user-friendly messages', () {
    expect(
      friendlyErrorMessage(ApiException('/api/x', 500, '{"message":"boom"}')),
      'boom',
    );
    expect(
      friendlyErrorMessage(ApiException('/api/x', 503, '')),
      'The server is temporarily unavailable. Try again shortly.',
    );
    expect(
      friendlyErrorMessage(ApiException('/api/x', 401, '')),
      'Your session is no longer valid. Sign in again.',
    );
    expect(
      friendlyErrorMessage(AuthException('Wrong password.')),
      'Wrong password.',
    );
    expect(
      friendlyErrorMessage(TimeoutException('late')),
      'The server did not respond. Check your connection and try again.',
    );
    expect(
      friendlyErrorMessage(http.ClientException('down')),
      "Couldn't reach the server. Check your connection.",
    );
    expect(
      friendlyErrorMessage(PlanUpgradeRequiredException(
        path: '/api/x',
        message: 'Your plan does not include this feature.',
      )),
      'Your plan does not include this feature.',
    );
  });

  testWidgets('explains that an unsupported passkey ceremony cannot sign in',
      (tester) async {
    final api = clientWith(MockClient((request) async {
      if (request.url.path.endsWith('/webauthn/status')) {
        return http.Response('{"available":true}', 200);
      }
      fail('unsupported ceremony must not start a request');
    }));

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        AppLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: LoginScreen(
        api: api,
        passkeyCeremony: FakePasskeyCeremony(supported: false),
        onSignedIn: () => fail('must not sign in'),
      ),
    ));
    await tester.tap(find.text('Use a passkey'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('not available on this device'),
      findsOneWidget,
    );
  });

  testWidgets('completes passkey login through the platform ceremony',
      (tester) async {
    var signedIn = false;
    http.Request? verify;
    final ceremony = FakePasskeyCeremony();
    final api = clientWith(MockClient((request) async {
      if (request.url.path.endsWith('/webauthn/status')) {
        return http.Response('{"available":true}', 200);
      }
      if (request.url.path.endsWith('/webauthn/login/options')) {
        return http.Response(
          '{"ceremonyId":"cer-1","challenge":"abc","rp":{"id":"finverse.test","name":"FINVERSE"},"userVerification":"required"}',
          200,
        );
      }
      if (request.url.path.endsWith('/webauthn/login/verify')) {
        verify = request;
        return http.Response(
          '{"user":{"id":"user-1","email":"sam@example.com","emailVerified":true},"tokens":{"accessToken":"access","refreshToken":"refresh","refreshExpiresAt":"2099-01-01T00:00:00.000Z"}}',
          200,
        );
      }
      return http.Response('{}', 200);
    }));

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        AppLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: LoginScreen(
        api: api,
        passkeyCeremony: ceremony,
        onSignedIn: () => signedIn = true,
      ),
    ));
    await tester.enterText(find.byType(TextFormField).first, 'sam@example.com');
    await tester.tap(find.text('Use a passkey'));
    await tester.pumpAndSettle();

    expect(signedIn, isTrue);
    expect(ceremony.lastOptions?['ceremonyId'], 'cer-1');
    expect(verify?.url.path, endsWith('/webauthn/login/verify'));
    expect(verify?.body, contains('cred-login'));
    expect(verify?.body, contains('cer-1'));
  });
  test('carries passkey and push registration protocol', () async {
    var sawRegisterOptions = false;
    final api = clientWith(MockClient((request) async {
      if (request.url.path.endsWith('/webauthn/status')) {
        return http.Response('{"available":true}', 200);
      }
      if (request.url.path.endsWith('/webauthn/register/options')) {
        sawRegisterOptions = true;
        return http.Response(
          '{"challenge":"abc","rp":{"id":"api.test","name":"FINVERSE"}}',
          201,
        );
      }
      if (request.url.path.endsWith('/push/device')) {
        return request.method == 'DELETE'
            ? http.Response('', 204)
            : http.Response('', 201);
      }
      if (request.url.path.endsWith('/webauthn/credentials')) {
        return http.Response(
          '{"credentials":[{"credentialId":"cred-1","createdAt":"2026-08-10T00:00:00.000Z","lastUsedAt":null}]}',
          200,
        );
      }
      return http.Response('{}', 200);
    }));

    expect(await api.passkeysAvailable(), isTrue);
    final options = await api.passkeyRegisterOptions(
        password: 'correct horse battery staple');
    expect(options['challenge'], 'abc');
    expect(sawRegisterOptions, isTrue);

    await api.registerPushToken('fcm-token-00000000000000000000', 'android');
    await api.unregisterPushToken('fcm-token-00000000000000000000');

    final credentials = await api.passkeyCredentials();
    expect(credentials, hasLength(1));
    expect(credentials.first['credentialId'], 'cred-1');
  });

  testWidgets('localizations resolve translated strings for a second locale',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        AppLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('fr'),
      home: LocalizationProbe(),
    ));

    expect(find.text('Accueil'), findsOneWidget);
    expect(find.text('Transactions'), findsNothing);
  });

  testWidgets('dashboard account menu and sign-out dialog speak French',
      (tester) async {
    final api = clientWith(MockClient((request) async {
      if (request.url.path.endsWith('/accounts')) {
        return http.Response('[]', 200);
      }
      return http.Response('{"transactions":[],"budgets":[],"count":0}', 200);
    }));

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        AppLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('fr'),
      home: DashboardScreen(
        api: api,
        onSignOut: () async {},
        onAccountDeleted: () async {},
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Menu du compte'));
    await tester.pumpAndSettle();
    expect(find.text('Se déconnecter'), findsOneWidget);
    expect(find.text('Vérifier le courriel'), findsOneWidget);
    expect(find.text('Supprimer le compte'), findsOneWidget);

    await tester.tap(find.text('Se déconnecter'));
    await tester.pumpAndSettle();
    expect(find.text('Se déconnecter ?'), findsOneWidget);
    expect(find.text('Annuler'), findsOneWidget);
  });

  testWidgets('shared expenses screen lists groups and speaks French',
      (tester) async {
    final api = clientWith(MockClient((request) async {
      if (request.url.path.endsWith('/split/groups')) {
        return http.Response('{"count":0,"groups":[]}', 200);
      }
      return http.Response('{}', 200);
    }));

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        AppLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('fr'),
      home: SplitScreen(api: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Dépenses partagées'), findsOneWidget);
    expect(find.text('Aucun groupe partagé'), findsOneWidget);
    expect(find.text('Nouveau groupe'), findsOneWidget);
  });

  test('parses scanned and stored receipts', () async {
    var sawPut = false;
    final api = clientWith(MockClient((request) async {
      if (request.url.path.endsWith('/receipts/scan')) {
        return http.Response(
          '{"scan":{"merchant":"Blue Bottle Coffee","date":"2026-08-10",'
          '"totalMinor":1142,"taxMinor":92,"currency":"USD",'
          '"items":["Cappuccino 4.50"],"confidence":0.9}}',
          201,
        );
      }
      if (request.url.path.contains('/receipts/txn-1') &&
          request.method == 'PUT') {
        sawPut = true;
        return http.Response(
          '{"receipt":{"transactionId":"txn-1","merchant":"Blue Bottle Coffee",'
          '"totalMinor":1142,"taxMinor":92,"currency":"USD",'
          '"items":["Cappuccino 4.50"]}}',
          200,
        );
      }
      if (request.url.path.contains('/receipts/txn-2') &&
          request.method == 'GET') {
        return http.Response('{"message":"No receipt"}', 404);
      }
      return http.Response('{}', 200);
    }));

    final scan = await api.scanReceipt('Blue Bottle Coffee\nTotal Due 11.42');
    expect(scan.merchant, 'Blue Bottle Coffee');
    expect(scan.totalMinor, 1142);

    final receipt = await api.attachReceipt('txn-1', 'Blue Bottle Coffee');
    expect(sawPut, isTrue);
    expect(receipt.merchant, 'Blue Bottle Coffee');

    expect(await api.receiptForTransaction('txn-2'), isNull);
  });

  test(
      'account deletion is confirmed server-side before credentials are cleared',
      () async {
    final store = InMemorySessionStore();
    await store.write(const SessionTokens(
      accessToken: 'active-access',
      refreshToken: 'active-refresh',
      refreshExpiresAt: '',
    ));

    late http.Request seen;
    final api = clientWith(
      MockClient((request) async {
        seen = request;
        return http.Response(
          '{"purgeScheduledFor":"2026-09-07T00:00:00.000Z"}',
          202,
        );
      }),
      store: store,
    );
    await api.restoreSession();

    final scheduled = await api.requestAccountDeletion('my current password');

    expect(seen.method, 'DELETE');
    expect(seen.url.path, '/api/auth/account');
    expect(seen.headers['authorization'], 'Bearer active-access');
    expect(seen.body, contains('"confirmation":"DELETE"'));
    expect(scheduled.toUtc().toIso8601String(), '2026-09-07T00:00:00.000Z');
    expect(await store.read(), isNull);
    expect(api.isAuthenticated, isFalse);
  });

  testWidgets('offers recovery for a scheduled account deletion',
      (tester) async {
    final api = clientWith(MockClient((_) async => http.Response('{}', 200)));

    await tester.pumpWidget(FinverseApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel scheduled account deletion'));
    await tester.pumpAndSettle();

    expect(find.text('Restore your account'), findsOneWidget);
    expect(find.text('Restore account'), findsOneWidget);
    expect(find.text('Back to sign in'), findsOneWidget);
  });

  testWidgets('shows transaction evidence and category controls',
      (tester) async {
    final preferenceRequests = <http.Request>[];
    final api = clientWith(MockClient((request) async {
      if (request.url.path.endsWith('/categories')) {
        return http.Response(
          '{"count":2,"categories":[{"slug":"food","name":"Food","parent":null,"kind":"expense"},{"slug":"groceries","name":"Groceries","parent":"food","kind":"expense"}]}',
          200,
        );
      }
      if (request.url.path.endsWith('/preferences')) {
        preferenceRequests.add(request);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final recurring = body['isRecurring'] as bool? ?? false;
        final duplicate = body['duplicateReported'] as bool? ?? false;
        return http.Response(
          jsonEncode({
            'transaction': {
              'id': 'txn-1',
              'accountId': 'account-1',
              'postedAt': '2026-08-08',
              'amount': -1299,
              'currency': 'CAD',
              'amountFormatted': '-12.99',
              'rawDescriptor': 'POS GROCERY STORE 1234',
              'normalizedDescriptor': 'grocery store',
              'merchant': 'Grocery Store',
              'categorySlug': 'groceries',
              'categorySource': 'merchant_rule',
              'categoryConfidence': 0.91,
              'pending': false,
              'isRecurring': recurring,
              'recurringOverride':
                  body.containsKey('isRecurring') ? recurring : null,
              'duplicateReported': duplicate,
            },
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    }));
    final transaction = Transaction.fromJson({
      'id': 'txn-1',
      'accountId': 'account-1',
      'postedAt': '2026-08-08',
      'amount': -1299,
      'currency': 'CAD',
      'amountFormatted': '-\$12.99',
      'rawDescriptor': 'POS GROCERY STORE 1234',
      'normalizedDescriptor': 'grocery store',
      'merchant': 'Grocery Store',
      'categorySlug': 'groceries',
      'categorySource': 'merchant_rule',
      'categoryConfidence': 0.91,
      'pending': false,
      'isRecurring': false,
      'recurringOverride': null,
    });

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: TransactionDetailScreen(api: api, transaction: transaction),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Transaction details'), findsOneWidget);
    expect(find.text('Grocery Store'), findsOneWidget);
    expect(find.text('Bank description'), findsOneWidget);
    expect(find.textContaining('91% confidence'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Mark as recurring'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView).first, const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark as recurring'));
    await tester.pumpAndSettle();
    expect(preferenceRequests.single.body, contains('"isRecurring":true'));

    await tester.tap(find.text('Flag possible duplicate'));
    await tester.pumpAndSettle();
    expect(preferenceRequests.last.body, contains('"duplicateReported":true'));
    expect(find.textContaining('Kept as a review marker'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Attach a receipt'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Attach a receipt'));
    await tester.pumpAndSettle();
    expect(
        find.bySemanticsLabel(RegExp('Scan a receipt photo')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Paste receipt text')), findsOneWidget);
  });

  testWidgets('keeps primary navigation simple and exposes secondary tools',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var manualAccountCreated = false;
    final api = clientWith(MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/sync')) {
        return http.Response(
          '{"accounts":0,"fetched":0,"inserted":0,"updated":0,"coverage":0,"needsReview":0}',
          201,
        );
      }
      if (path.endsWith('/accounts/net-worth-history')) {
        return http.Response('[]', 200);
      }
      if (path.endsWith('/accounts')) {
        return http.Response(
          manualAccountCreated
              ? '[{"id":"manual-1","name":"Wallet cash","type":"cash","mask":"manual","currency":"USD","balanceCurrent":12500,"balanceFormatted":"\$125.00","source":"manual","utilization":null}]'
              : '[]',
          200,
        );
      }
      if (path.endsWith('/accounts/manual') && request.method == 'POST') {
        manualAccountCreated = true;
        return http.Response(
          '{"id":"manual-1","name":"Wallet cash","type":"cash","mask":"manual","currency":"USD","balanceCurrent":12500,"balanceFormatted":"\$125.00","source":"manual","utilization":null}',
          201,
        );
      }
      if (path.endsWith('/bank-links')) {
        return http.Response('{"links":[]}', 200);
      }
      if (path.endsWith('/health-score')) {
        return http.Response(
          '{"score":500,"band":"fair","components":[],"topActions":[]}',
          200,
        );
      }
      if (path.endsWith('/cash-flow-forecast')) {
        return http.Response(
          '{"asOf":"2026-08-08","currency":"USD","startingBalance":100000,"startingBalanceFormatted":"\$1,000.00","endingBalanceFormatted":"\$850.00","lowBalanceDates":[],"events":[{"date":"2026-08-12","amount":-15000,"merchant":"Internet","kind":"expense","confidence":0.92,"transactionIds":["txn-1"],"amountFormatted":"-\$150.00"}],"points":[{"date":"2026-08-09","balance":100000,"balanceFormatted":"\$1,000.00"},{"date":"2026-08-12","balance":85000,"balanceFormatted":"\$850.00"}]}',
          200,
        );
      }
      if (path.endsWith('/purchase-scenario')) {
        return http.Response(
          '{"currency":"USD","balanceBeforePurchaseFormatted":"\$1,000.00","balanceAfterPurchaseFormatted":"\$900.00","endingBalanceFormatted":"\$750.00","lowBalanceDates":[],"warnings":["Known recurring commitments remain covered in this conservative scenario.","This scenario includes repeatable income and bills only; it does not predict everyday discretionary spending."]}',
          200,
        );
      }
      if (path.endsWith('/budgets/progress')) {
        return http.Response('{"budgets":[],"count":0}', 200);
      }
      if (path.endsWith('/transactions')) {
        return http.Response('{"transactions":[],"count":0}', 200);
      }
      if (path.endsWith('/goals')) {
        return http.Response('{"goals":[],"count":0}', 200);
      }
      if (path.endsWith('/notifications/preferences')) {
        return http.Response(
          '{"budget":true,"bills":true,"creditUtilization":true,"subscriptions":true,"lowBalance":true,"unusualTransactions":true,"bankSync":true,"security":true}',
          200,
        );
      }
      if (path.endsWith('/notifications')) {
        return http.Response('{"notifications":[],"count":0,"unread":0}', 200);
      }
      if (path.endsWith('/subscriptions')) {
        return http.Response(
          '{"count":0,"monthlyTotalFormatted":"\$0.00","annualTotalFormatted":"\$0.00","subscriptions":[],"priceIncreases":[],"possiblyCancelled":[]}',
          200,
        );
      }
      if (path.endsWith('/auth/me')) {
        return http.Response(
          '{"id":"user-1","email":"sam@example.com","emailVerified":true}',
          200,
        );
      }
      if (path.endsWith('/auth/sessions')) {
        return http.Response(
          '[{"id":"session-1","issuedAt":"2026-08-08T00:00:00.000Z","expiresAt":"2026-09-08T00:00:00.000Z","lastUsedAt":"2026-08-08T00:00:00.000Z","userAgent":"FINVERSE Android","ipAddress":"127.0.0.1","current":true}]',
          200,
        );
      }
      if (path.endsWith('/auth/mfa')) {
        return http.Response(
          '{"enabled":false,"available":true,"recoveryCodesRemaining":0}',
          200,
        );
      }
      if (path.endsWith('/privacy')) {
        return http.Response(
          '{"user":{"id":"user-1","email":"sam@example.com","emailVerified":true},"optionalConsents":{"analytics":{"granted":false,"policyVersion":"preference-v1","updatedAt":null},"productUpdates":{"granted":false,"policyVersion":"preference-v1","updatedAt":null}},"consentHistory":[],"securityActivity":[{"id":"event-1","kind":"login","succeeded":true,"ipAddress":"127.0.0.1","userAgent":"FINVERSE Android","detail":null,"createdAt":"2026-08-08T00:00:00.000Z"}],"retention":{"accountDeletionRecoveryDays":30,"offlineCacheMaximumDays":30}}',
          200,
        );
      }
      if (path.endsWith('/insights')) {
        return http.Response(
          '{"headline":{"income":"\$0.00","expenses":"\$0.00","netCashFlow":"\$0.00","savingsRate":"0.0%"},"comparison":{"income":"\$100.00 (10%) higher than last period","expenses":null,"netCashFlow":null,"savingsRate":"2.0 percentage points higher than last period"},"topCategories":[],"insights":[]}',
          200,
        );
      }
      return http.Response('{}', 200);
    }));

    final appLock = AppLockController(
      store: InMemoryAppLockStore(),
      authenticator: FakeDeviceAuthenticator(),
    );
    await appLock.initialize();
    final themeColors = ThemeColorController.inMemory();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        AppLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => ThemeColorControllerScope(
        controller: themeColors,
        child: child ?? const SizedBox.shrink(),
      ),
      home: HomeScreen(
        api: api,
        appLockController: appLock,
        onSignOut: () async {},
        onAccountDeleted: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Compared with last period'), findsOneWidget);

    // Every primary destination carries a spoken label — navigation must not
    // rely on an unlabeled icon (MISSION2 §41 accessibility).
    for (final label in [
      'Home',
      'Transactions',
      'Analytics',
      'Accounts',
      'Profile'
    ]) {
      expect(
        tester.getSemantics(find.text(label)).label,
        contains(label),
        reason: 'missing nav semantics: $label',
      );
    }

    await tester.tap(find.byTooltip('Cash-flow planning'));
    await tester.pumpAndSettle();
    expect(find.text('Conservative forecast'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('cash-flow-chart')),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    final chartSemantics = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.byKey(const Key('cash-flow-chart')),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(
      chartSemantics.properties.label,
      contains(r'Cash flow forecast from $1,000.00 to $850.00'),
    );
    expect(find.text('Internet'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '100');
    await tester.tap(find.text('Check scenario'));
    await tester.pumpAndSettle();
    expect(find.text('\$900.00'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Notifications'));
    await tester.pumpAndSettle();
    expect(find.text('You are all caught up'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Subscriptions'));
    await tester.pumpAndSettle();
    expect(find.text('No recurring subscriptions detected.'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Account menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings and privacy'));
    await tester.pumpAndSettle();
    expect(find.text('sam@example.com'), findsOneWidget);
    expect(find.text('Your plan'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    // Scrolled to rather than asserted in place: the account card grows as
    // settings are added, and a test that depends on what fits above the fold
    // breaks every time one is.
    await tester.scrollUntilVisible(
      find.text('Theme color'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.text('Theme color'), findsOneWidget);
    expect(find.text('Emerald'), findsOneWidget);
    expect(find.text('Indigo'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Authenticator security'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.text('Authenticator security'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Device app lock'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.text('Device app lock'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Usage analytics'),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.text('Usage analytics'), findsOneWidget);
    expect(find.text('Export my data'), findsOneWidget);
    expect(find.text('Monthly financial report'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('RECENT SECURITY ACTIVITY'),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.text('RECENT SECURITY ACTIVITY'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    expect(find.text('Try ‘coffee over \$20 last month’'), findsOneWidget);
    expect(find.text('No matching transactions.'), findsOneWidget);
    await tester.tap(find.byTooltip('Filter transactions'));
    await tester.pumpAndSettle();
    expect(find.text('Filter transactions'), findsOneWidget);
    expect(find.text('Apply filters'), findsOneWidget);
    await tester.tap(find.text('Clear all'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Analytics'));
    await tester.pumpAndSettle();
    expect(find.text('Analytics'), findsWidgets);

    await tester.tap(find.text('Profile').last);
    await tester.pumpAndSettle();
    expect(find.text('Settings and privacy'), findsOneWidget);
    expect(find.text('Budgets'), findsOneWidget);
    expect(find.text('Goals'), findsOneWidget);
    await tester.tap(find.text('Budgets'));
    await tester.pumpAndSettle();
    expect(find.text('New budget'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Profile').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Goals'));
    await tester.pumpAndSettle();
    expect(find.text('New goal'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    expect(find.text('No balances yet'), findsOneWidget);
    await tester.tap(find.text('Add manual'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cash or wallet'));
    await tester.pumpAndSettle();
    expect(find.text('Property value'), findsOneWidget);
    await tester.tap(find.text('Property value'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Wallet cash');
    await tester.enterText(find.byType(TextField).at(1), '125');
    await tester.enterText(find.byType(TextField).at(2), 'USD');
    await tester.tap(find.text('Add account'));
    await tester.pumpAndSettle();
    expect(find.text('Wallet cash'), findsOneWidget);
    expect(find.text('\$125.00'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('dashboard header stays compact at iPhone and Android widths',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final api = clientWith(
      MockClient((_) async => http.Response('{}', 500)),
    );

    await tester.pumpWidget(MaterialApp(
      theme: FinTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DashboardScreen(api: api),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byTooltip('Cash-flow planning'), findsNothing);
    expect(
      find.byWidgetPredicate((widget) => widget is PopupMenuButton),
      findsOneWidget,
    );
    expect(find.byTooltip('Sync accounts'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'statement import offers account creation instead of a disabled upload',
      (tester) async {
    final api = clientWith(MockClient((request) async {
      if (request.url.path == '/api/accounts') {
        return http.Response('[]', 200);
      }
      if (request.url.path == '/api/imports/statements') {
        return http.Response('[]', 200);
      }
      return http.Response('{}', 404);
    }));

    await tester.pumpWidget(statementImportHarness(api));
    await tester.pumpAndSettle();

    expect(find.text('Add an account first'), findsOneWidget);
    final action = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Add account and choose statement'),
    );
    expect(action.onPressed, isNotNull);

    await tester.tap(find.text('Add account and choose statement'));
    await tester.pumpAndSettle();
    expect(find.text('Add account for this statement'), findsOneWidget);
  });

  testWidgets('statement import keeps the browser picker tied to a click',
      (tester) async {
    var accountReads = 0;
    const account =
        '{"id":"acc-1","name":"CAD checking","type":"checking","mask":"manual","currency":"CAD","balanceCurrent":0,"balanceFormatted":"CA\$0.00","source":"manual"}';
    final api = clientWith(MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/accounts') {
        accountReads += 1;
        return http.Response(accountReads == 1 ? '[]' : '[$account]', 200);
      }
      if (request.method == 'GET' && request.url.path == '/api/imports/statements') {
        return http.Response('[]', 200);
      }
      if (request.method == 'POST' &&
          request.url.path == '/api/accounts/manual') {
        return http.Response(account, 201);
      }
      return http.Response('{}', 404);
    }));

    await tester.pumpWidget(statementImportHarness(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add account and choose statement'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'CAD checking');
    await tester.enterText(find.byType(TextFormField).at(1), '0');
    await tester.enterText(find.byType(TextFormField).at(2), 'CAD');
    await tester.tap(find.text('Add account'));
    await tester.pumpAndSettle();

    expect(find.text('Account added. Tap Choose statement to select the file.'),
        findsOneWidget);
    expect(
        find.widgetWithText(FilledButton, 'Choose statement'), findsOneWidget);
  });

  testWidgets('statement import selects all rows for one bulk decision',
      (tester) async {
    const detail = '{"statement":{"id":"stmt-1","accountId":"acc-1","filename":"july.csv","mimeType":"text/csv","format":"csv","status":"ready","rowsTotal":2,"rowsIncluded":0,"rowsExcluded":0,"rowsNeedsReview":2,"createdAt":"2026-08-01T00:00:00Z","documentDetails":{"currency":"CAD","periodStart":"2026-07-01","periodEnd":"2026-07-31"}},"rows":[{"id":"row-1","importId":"stmt-1","sourceLine":2,"description":"Unknown vending","amount":-1000,"currency":"CAD","direction":"debit","categorySlug":"unknown","categorySource":"unknown","categoryConfidence":0,"decision":"needs_review","flags":["low_confidence","uncategorized"],"postedAt":"2026-07-01","isRecurring":false},{"id":"row-2","importId":"stmt-1","sourceLine":3,"description":"Unknown shop","amount":-500,"currency":"CAD","direction":"debit","categorySlug":"unknown","categorySource":"unknown","categoryConfidence":0,"decision":"needs_review","flags":["low_confidence","uncategorized"],"postedAt":"2026-07-02","isRecurring":false}]}';
    final api = clientWith(MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/accounts') {
        return http.Response('[{"id":"acc-1","name":"CAD checking","type":"checking","mask":"manual","currency":"CAD","balanceCurrent":0,"balanceFormatted":"CA\$0.00","source":"manual"}]', 200);
      }
      if (request.method == 'GET' && request.url.path == '/api/imports/statements') {
        return http.Response('[{"id":"stmt-1","accountId":"acc-1","filename":"july.csv","mimeType":"text/csv","format":"csv","status":"ready","rowsTotal":2,"rowsIncluded":0,"rowsExcluded":0,"rowsNeedsReview":2,"createdAt":"2026-08-01T00:00:00Z"}]', 200);
      }
      if (request.method == 'GET' && request.url.path == '/api/imports/statements/stmt-1') {
        return http.Response(detail, 200);
      }
      if (request.method == 'GET' && request.url.path == '/api/imports/statements/stmt-1/summary') {
        return http.Response('{"currency":"CAD","income":0,"expenses":1500,"netCashFlow":-1500,"savings":0,"recurringCount":0,"duplicateCount":0,"unusualCount":0,"categoryTotals":[]}', 200);
      }
      return http.Response('{}', 404);
    }));

    await tester.pumpWidget(statementImportHarness(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('july.csv'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Select all transactions'), findsOneWidget);
    await tester.ensureVisible(find.text('Select all transactions'));
    await tester.pump();
    await tester.tap(find.text('Select all transactions'));
    await tester.pump();
    expect(find.text('Include selected'), findsOneWidget);
    expect(find.text('Exclude selected'), findsOneWidget);
    expect(find.textContaining('unknown · 0% confidence'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Approve transactions now'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    final approve = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Approve transactions now'),
    );
    expect(approve.onPressed, isNotNull);
  });

  testWidgets('statement import can remove an empty result for reanalysis',
      (tester) async {
    var deleted = false;
    const statement =
        '{"id":"stmt-empty","accountId":"acc-1","filename":"statement.pdf","mimeType":"application/pdf","format":"pdf","status":"ready","rowsTotal":0,"rowsIncluded":0,"rowsExcluded":0,"rowsNeedsReview":0,"createdAt":"2026-09-07T00:00:00Z"}';
    final api = clientWith(MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/accounts') {
        return http.Response(
            '[{"id":"acc-1","name":"CAD checking","type":"checking","mask":"manual","currency":"CAD","balanceCurrent":0,"balanceFormatted":"CA\$0.00","source":"manual"}]',
            200);
      }
      if (request.method == 'GET' &&
          request.url.path == '/api/imports/statements') {
        return http.Response(deleted ? '[]' : '[$statement]', 200);
      }
      if (request.method == 'GET' &&
          request.url.path == '/api/imports/statements/stmt-empty') {
        return http.Response('{"statement":$statement,"rows":[]}', 200);
      }
      if (request.method == 'GET' &&
          request.url.path == '/api/imports/statements/stmt-empty/summary') {
        return http.Response(
            '{"currency":"CAD","income":0,"expenses":0,"netCashFlow":0,"savings":0,"recurringCount":0,"duplicateCount":0,"unusualCount":0,"categoryTotals":[]}',
            200);
      }
      if (request.method == 'DELETE' &&
          request.url.path == '/api/imports/statements/stmt-empty') {
        deleted = true;
        return http.Response('', 204);
      }
      return http.Response('{}', 404);
    }));

    await tester.pumpWidget(statementImportHarness(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('statement.pdf'));
    await tester.pumpAndSettle();

    expect(find.text('No transactions were extracted'), findsOneWidget);

    await tester.tap(find.text('Remove empty import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove import'));
    await tester.pumpAndSettle();

    expect(deleted, isTrue);
    expect(find.text('Previous imports'), findsNothing);
  });
}
