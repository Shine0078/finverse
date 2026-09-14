import 'package:finverse/models/models.dart';
import 'package:finverse/widgets/cash_flow_sankey.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows a CAD cash flow from income through categories',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CashFlowSankey(
          currency: 'CAD',
          totalIncome: 500000,
          totalExpenses: 320000,
          incomeSources: const [
            AnalyticsBucket(
              key: 'salary',
              label: 'Salary',
              total: 500000,
              totalFormatted: r'$5,000.00',
              transactionCount: 1,
            ),
          ],
          expenseCategories: const [
            AnalyticsBucket(
              key: 'rent',
              label: 'Rent',
              total: 200000,
              totalFormatted: r'$2,000.00',
              transactionCount: 1,
            ),
            AnalyticsBucket(
              key: 'groceries',
              label: 'Groceries',
              total: 120000,
              totalFormatted: r'$1,200.00',
              transactionCount: 8,
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Money flow'), findsOneWidget);
    expect(find.byKey(const Key('cash-flow-sankey')), findsOneWidget);
    expect(find.textContaining('Rent'), findsOneWidget);
    expect(find.textContaining('Savings / remaining'), findsOneWidget);
    expect(
      find.byTooltip(
        'Rent: CAD 2,000.00 · 40% of available cash',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Money flow for this period in CAD. Income CAD 5,000.00; spending CAD 3,200.00; savings CAD 1,800.00.',
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('labels expenses beyond recorded income as a funding gap',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CashFlowSankey(
          currency: 'CAD',
          totalIncome: 0,
          totalExpenses: 168394,
          incomeSources: const [],
          expenseCategories: const [
            AnalyticsBucket(
              key: 'shopping',
              label: 'Shopping',
              total: 168394,
              totalFormatted: r'$1,683.94',
              transactionCount: 71,
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Money flow'), findsOneWidget);
    expect(find.textContaining('Shopping'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Money flow for this period in CAD. Income CAD 0.00; spending CAD 1,683.94; funding gap CAD 1,683.94.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('remains usable on a narrow screen with large text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: Scaffold(
          body: SingleChildScrollView(
            child: CashFlowSankey(
              currency: 'CAD',
              totalIncome: 100000,
              totalExpenses: 50000,
              incomeSources: const [],
              expenseCategories: const [],
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(find.byKey(const Key('cash-flow-sankey')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stays bounded without horizontal scrolling at phone width',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: CashFlowSankey(
            currency: 'USD',
            totalIncome: 420000,
            totalExpenses: 280000,
            incomeSources: const [
              AnalyticsBucket(
                key: 'salary',
                label: 'Salary',
                total: 420000,
                totalFormatted: r'$4,200.00',
                transactionCount: 1,
              ),
            ],
            expenseCategories: const [
              AnalyticsBucket(
                key: 'housing',
                label: 'Housing',
                total: 180000,
                totalFormatted: r'$1,800.00',
                transactionCount: 1,
              ),
              AnalyticsBucket(
                key: 'groceries',
                label: 'Groceries',
                total: 100000,
                totalFormatted: r'$1,000.00',
                transactionCount: 8,
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final chart = tester.getSize(find.byKey(const Key('cash-flow-sankey')));
    expect(chart.width, lessThanOrEqualTo(326));
    expect(chart.height, inInclusiveRange(230, 300));
    expect(tester.takeException(), isNull);
  });
}
