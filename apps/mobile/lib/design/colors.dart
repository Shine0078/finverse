/// Colours that carry financial meaning.
///
/// Deliberately *not* named for what they look like. `FinColors.income` says
/// what it is for; `green` says what it is, and then somebody uses green for a
/// success toast and the two drift apart.
///
/// These live in a [ThemeExtension] so financial semantics stay centralized
/// and no widget has to choose its own colors.
///
/// **Colour is never the only signal** (MISSION2 §41). Every place these are
/// used also carries a sign, an arrow, or a word, because roughly one in twelve
/// men cannot reliably separate red from green — and in a finance app that is
/// the difference between money arriving and money leaving.
library;

import 'package:flutter/material.dart';

@immutable
class FinColors extends ThemeExtension<FinColors> {
  const FinColors({
    required this.income,
    required this.onIncomeContainer,
    required this.incomeContainer,
    required this.expense,
    required this.onExpenseContainer,
    required this.expenseContainer,
    required this.warning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.positiveTrend,
    required this.negativeTrend,
    required this.neutral,
    required this.skeleton,
    required this.skeletonHighlight,
    required this.chartSeries,
    required this.heroGradientStart,
    required this.heroGradientEnd,
    required this.onHero,
    required this.onHeroMuted,
    required this.heroDebt,
  });

  /// Money arriving.
  final Color income;
  final Color incomeContainer;
  final Color onIncomeContainer;

  /// Money leaving.
  final Color expense;
  final Color expenseContainer;
  final Color onExpenseContainer;

  /// Needs attention but is not yet a failure — a card nearing its limit, a
  /// bank connection that will expire.
  final Color warning;
  final Color warningContainer;
  final Color onWarningContainer;

  /// Direction of travel, which is *not* the same as income and expense:
  /// spending less than last month is a positive trend and an expense.
  final Color positiveTrend;
  final Color negativeTrend;

  /// Deliberately unremarkable. Transfers and other movements that are neither
  /// income nor spending.
  final Color neutral;

  final Color skeleton;
  final Color skeletonHighlight;

  /// Categorical series for charts, in order.
  ///
  /// Ordered so neighbouring entries differ in lightness as well as hue, which
  /// keeps a pie chart readable in greyscale and to a colour-blind reader.
  final List<Color> chartSeries;

  /// The brand gradient behind the net-position hero. Emerald into deep teal —
  /// the one surface in the app allowed to be loud, because it is the single
  /// number every user opens the app to see.
  final Color heroGradientStart;
  final Color heroGradientEnd;

  /// Text on that hero. Always high-contrast against [heroGradientStart].
  final Color onHero;

  /// Secondary text on the hero — the caption under the balance.
  final Color onHeroMuted;

  /// The debts accent on the hero. A warm coral that reads clearly against the
  /// green gradient without vibrating the way a saturated red would.
  final Color heroDebt;

  static const light = FinColors(
    income: Color(0xFF047857),
    incomeContainer: Color(0xFFD1FAE5),
    onIncomeContainer: Color(0xFF064E3B),
    expense: Color(0xFFC2413B),
    expenseContainer: Color(0xFFFFE4E1),
    onExpenseContainer: Color(0xFF7F1D1D),
    warning: Color(0xFF9A5B09),
    warningContainer: Color(0xFFFFF1D6),
    onWarningContainer: Color(0xFF653A00),
    positiveTrend: Color(0xFF047857),
    negativeTrend: Color(0xFFC2413B),
    neutral: Color(0xFF526174),
    skeleton: Color(0xFFDDE4EC),
    skeletonHighlight: Color(0xFFF7F9FC),
    chartSeries: [
      Color(0xFF1479C9),
      Color(0xFF0891B2),
      Color(0xFF0F766E),
      Color(0xFF7C5AC7),
      Color(0xFFD97706),
      Color(0xFFC2413B),
      Color(0xFF526174),
      Color(0xFF0369A1),
    ],
    heroGradientStart: Color(0xFF102A43),
    heroGradientEnd: Color(0xFF0B1F33),
    onHero: Color(0xFFFFFFFF),
    onHeroMuted: Color(0xFFCED9E5),
    heroDebt: Color(0xFFFFB4AC),
  );

  @override
  FinColors copyWith({
    Color? income,
    Color? incomeContainer,
    Color? onIncomeContainer,
    Color? expense,
    Color? expenseContainer,
    Color? onExpenseContainer,
    Color? warning,
    Color? warningContainer,
    Color? onWarningContainer,
    Color? positiveTrend,
    Color? negativeTrend,
    Color? neutral,
    Color? skeleton,
    Color? skeletonHighlight,
    List<Color>? chartSeries,
    Color? heroGradientStart,
    Color? heroGradientEnd,
    Color? onHero,
    Color? onHeroMuted,
    Color? heroDebt,
  }) =>
      FinColors(
        income: income ?? this.income,
        incomeContainer: incomeContainer ?? this.incomeContainer,
        onIncomeContainer: onIncomeContainer ?? this.onIncomeContainer,
        expense: expense ?? this.expense,
        expenseContainer: expenseContainer ?? this.expenseContainer,
        onExpenseContainer: onExpenseContainer ?? this.onExpenseContainer,
        warning: warning ?? this.warning,
        warningContainer: warningContainer ?? this.warningContainer,
        onWarningContainer: onWarningContainer ?? this.onWarningContainer,
        positiveTrend: positiveTrend ?? this.positiveTrend,
        negativeTrend: negativeTrend ?? this.negativeTrend,
        neutral: neutral ?? this.neutral,
        skeleton: skeleton ?? this.skeleton,
        skeletonHighlight: skeletonHighlight ?? this.skeletonHighlight,
        chartSeries: chartSeries ?? this.chartSeries,
        heroGradientStart: heroGradientStart ?? this.heroGradientStart,
        heroGradientEnd: heroGradientEnd ?? this.heroGradientEnd,
        onHero: onHero ?? this.onHero,
        onHeroMuted: onHeroMuted ?? this.onHeroMuted,
        heroDebt: heroDebt ?? this.heroDebt,
      );

  @override
  FinColors lerp(ThemeExtension<FinColors>? other, double t) {
    if (other is! FinColors) return this;
    return FinColors(
      income: Color.lerp(income, other.income, t)!,
      incomeContainer: Color.lerp(incomeContainer, other.incomeContainer, t)!,
      onIncomeContainer:
          Color.lerp(onIncomeContainer, other.onIncomeContainer, t)!,
      expense: Color.lerp(expense, other.expense, t)!,
      expenseContainer:
          Color.lerp(expenseContainer, other.expenseContainer, t)!,
      onExpenseContainer:
          Color.lerp(onExpenseContainer, other.onExpenseContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningContainer:
          Color.lerp(warningContainer, other.warningContainer, t)!,
      onWarningContainer:
          Color.lerp(onWarningContainer, other.onWarningContainer, t)!,
      positiveTrend: Color.lerp(positiveTrend, other.positiveTrend, t)!,
      negativeTrend: Color.lerp(negativeTrend, other.negativeTrend, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
      skeleton: Color.lerp(skeleton, other.skeleton, t)!,
      skeletonHighlight:
          Color.lerp(skeletonHighlight, other.skeletonHighlight, t)!,
      chartSeries: t < 0.5 ? chartSeries : other.chartSeries,
      heroGradientStart:
          Color.lerp(heroGradientStart, other.heroGradientStart, t)!,
      heroGradientEnd: Color.lerp(heroGradientEnd, other.heroGradientEnd, t)!,
      onHero: Color.lerp(onHero, other.onHero, t)!,
      onHeroMuted: Color.lerp(onHeroMuted, other.onHeroMuted, t)!,
      heroDebt: Color.lerp(heroDebt, other.heroDebt, t)!,
    );
  }
}

/// Reads the financial palette. Falls back to the light set rather than
/// throwing, so a widget rendered outside the app theme in a test still paints.
extension FinColorsOf on BuildContext {
  FinColors get finColors =>
      Theme.of(this).extension<FinColors>() ?? FinColors.light;
}
