// Design-system guarantees.
//
// These pin the properties that are easy to lose one screen at a time and
// impossible to notice going: tabular figures, direction that survives
// colour-blindness, and money that reads correctly aloud.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:finverse/design/design.dart';

Widget host(Widget child) => MaterialApp(
      theme: FinTheme.light(),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('MoneyText', () {
    testWidgets('sets money in tabular figures so columns line up',
        (tester) async {
      // The single most visible typographic choice in a finance app. Without
      // it a 1 is narrower than a 0, decimal points wander, and a transaction
      // list stops being scannable.
      await tester.pumpWidget(host(
        const MoneyText(formatted: r'$1,111.11', amountMinor: 111111),
      ));

      final style = tester.widget<Text>(find.byType(Text)).style!;
      expect(
        style.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });

    testWidgets('marks direction with a sign, not only a colour',
        (tester) async {
      // Roughly one man in twelve cannot separate red from green. Without the
      // sign, money in and money out render as identical strings.
      await tester.pumpWidget(host(
        const Column(children: [
          MoneyText(formatted: r'$4.50', amountMinor: 450),
          MoneyText(formatted: r'-$4.50', amountMinor: -450),
        ]),
      ));

      expect(find.text(r'+$4.50'), findsOneWidget);
      expect(find.text(r'-$4.50'), findsOneWidget);
    });

    testWidgets('never renders a doubled sign', (tester) async {
      // The API already includes the minus. Prefixing another would print
      // "+-$4.50".
      await tester.pumpWidget(host(
        const MoneyText(formatted: r'-$4.50', amountMinor: -450),
      ));

      expect(find.text(r'+-$4.50'), findsNothing);
    });

    testWidgets('reads aloud as direction rather than punctuation',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(host(
        const MoneyText(
          formatted: r'-$4.50',
          amountMinor: -450,
          semanticsPrefix: 'Coffee',
        ),
      ));

      // A screen reader given "-$4.50" says something unhelpful about hyphens.
      expect(find.bySemanticsLabel(r'Coffee, $4.50 out'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('treats a balance as neutral, not as income', (tester) async {
      // A £500 credit limit is not £500 of income, and must not be green with
      // a plus in front of it.
      await tester.pumpWidget(host(
        const MoneyText(
          formatted: r'$500.00',
          amountMinor: 50000,
          tone: MoneyTone.neutral,
        ),
      ));

      expect(find.text(r'$500.00'), findsOneWidget);
      expect(find.text(r'+$500.00'), findsNothing);
    });
  });

  group('FinMetricTile', () {
    testWidgets('shows spending less than last month as good news',
        (tester) async {
      // Sign and meaning disagree here: the change is negative and that is
      // positive. Only the caller knows which, hence TrendMeaning.
      await tester.pumpWidget(host(
        const SizedBox(
          width: 320,
          child: FinMetricTile(
            label: 'Spent this month',
            formatted: r'$1,240.00',
            amountMinor: -124000,
            comparison: r'$120 less than last month',
            comparisonAmountMinor: -12000,
            trendMeaning: TrendMeaning.lowerIsBetter,
          ),
        ),
      ));

      final icon = tester.widget<Icon>(find.byIcon(Icons.arrow_downward));
      final good = FinColors.light.positiveTrend;
      expect(icon.color, good);
    });

    testWidgets('pairs every trend colour with an arrow', (tester) async {
      // Colour alone would vanish in greyscale or to a colour-blind reader.
      await tester.pumpWidget(host(
        const SizedBox(
          width: 320,
          child: FinMetricTile(
            label: 'Income',
            formatted: r'$4,200.00',
            amountMinor: 420000,
            comparison: r'$200 more than last month',
            comparisonAmountMinor: 20000,
            trendMeaning: TrendMeaning.higherIsBetter,
          ),
        ),
      ));

      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    });
  });

  group('FinSummaryTile', () {
    testWidgets('keeps a formatted financial value readable and announced',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(host(
        const SizedBox(
          width: 180,
          child: FinSummaryTile(
            label: 'Net cash flow',
            value: r'$1,240.00',
            supporting: 'This month',
            icon: Icons.swap_vert,
          ),
        ),
      ));

      expect(find.text(r'$1,240.00'), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(FinSummaryTile)).label,
        startsWith('Net cash flow: \$1,240.00, This month'),
      );
      semantics.dispose();
    });
  });

  group('states', () {
    testWidgets('an empty state always offers a way forward', (tester) async {
      // MISSION2 §35: an empty screen with no exit is a dead end.
      var tapped = false;
      await tester.pumpWidget(host(
        FinEmptyState(
          icon: Icons.account_balance_outlined,
          title: 'No transactions yet',
          message: 'Connect a bank to start tracking your finances.',
          actionLabel: 'Connect a bank',
          onAction: () => tapped = true,
        ),
      ));

      await tester.tap(find.text('Connect a bank'));
      expect(tapped, isTrue);
    });

    testWidgets('an error state keeps the technical detail out of the way',
        (tester) async {
      // §34: never lead with `HTTP 500`. It stays available, one tap down.
      await tester.pumpWidget(host(
        const FinErrorState(
          title: "We couldn't load your finances",
          message: 'Check your connection and try again.',
          technicalDetail: 'ApiException(500 on /insights)',
        ),
      ));

      expect(find.textContaining('Check your connection'), findsOneWidget);
      expect(find.textContaining('ApiException'), findsNothing);

      await tester.tap(find.text('Technical details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('ApiException'), findsOneWidget);
    });

    testWidgets('the skeleton stops animating when motion is reduced',
        (tester) async {
      // A looping shimmer is precisely what this accessibility setting exists
      // to stop, and it would otherwise never settle in a test either.
      await tester.pumpWidget(MaterialApp(
        theme: FinTheme.light(),
        home: const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: FinSkeleton(width: 100)),
        ),
      ));

      await tester.pumpAndSettle();
      expect(find.byType(FinSkeleton), findsOneWidget);
    });
  });

  group('theme', () {
    testWidgets('supplies the financial palette on the cool canvas theme',
        (tester) async {
      late FinColors fin;
      late ThemeData theme;
      await tester.pumpWidget(host(
        Builder(builder: (context) {
          fin = context.finColors;
          theme = Theme.of(context);
          return const SizedBox();
        }),
      ));

      expect(fin.income, isNot(fin.expense));
      expect(theme.brightness, Brightness.light);
      expect(theme.scaffoldBackgroundColor, const Color(0xFFF3F6FA));
    });

    testWidgets('gives every button a reachable tap target', (tester) async {
      // 48dp is the Material and WCAG floor, and this app is used one-handed.
      await tester.pumpWidget(host(
        FilledButton(onPressed: () {}, child: const Text('Connect')),
      ));

      final size = tester.getSize(find.byType(FilledButton));
      expect(size.height, greaterThanOrEqualTo(FinTouch.minTarget));
    });
  });
}
