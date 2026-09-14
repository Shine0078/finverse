/// Type, and the one detail that matters most in a financial product.
///
/// **Money is set in tabular figures.** By default most fonts give digits
/// proportional widths, so a 1 is narrower than a 0 and a column of amounts
/// wobbles — every row sits at a slightly different place and the eye cannot
/// scan down it. `FontFeature.tabularFigures()` fixes every digit to the same
/// advance width, so decimal points line up and a list of transactions reads as
/// a ledger rather than a paragraph.
///
/// It is the cheapest change in this file and the most visible.
library;

import 'package:flutter/material.dart';

abstract final class FinType {
  /// Applied to anything showing an amount.
  ///
  /// `slashedZero` as well: a slashed zero is unmistakably a zero, which
  /// matters when the number is somebody's balance and the alternative is
  /// reading it as an O.
  static const List<FontFeature> numeric = [
    FontFeature.tabularFigures(),
    FontFeature.slashedZero(),
  ];

  /// The headline balance on the dashboard. Large, tight, unmissable.
  static const TextStyle moneyDisplay = TextStyle(
    fontSize: 34,
    height: 1.1,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    fontFeatures: numeric,
  );

  /// A metric tile's value.
  static const TextStyle moneyLarge = TextStyle(
    fontSize: 22,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    fontFeatures: numeric,
  );

  /// The amount on a transaction row.
  static const TextStyle moneyRow = TextStyle(
    fontSize: 15,
    height: 1.2,
    fontWeight: FontWeight.w600,
    fontFeatures: numeric,
  );

  /// Supporting figures — a limit, a percentage, a due date.
  static const TextStyle moneySmall = TextStyle(
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w500,
    fontFeatures: numeric,
  );

  /// Section headers above a group of cards. Small, spaced, quiet.
  static const TextStyle sectionLabel = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.1,
  );

  /// Builds the Material text theme, leaving Flutter's defaults alone except
  /// where this product has an opinion. Overriding every slot is how you end up
  /// fighting the framework on a platform you have not tested.
  static TextTheme textTheme(TextTheme base) => base.copyWith(
        bodyLarge: base.bodyLarge?.copyWith(fontSize: 16, height: 1.5),
        bodyMedium: base.bodyMedium?.copyWith(fontSize: 16, height: 1.45),
        bodySmall: base.bodySmall?.copyWith(fontSize: 14, height: 1.4),
        headlineSmall: base.headlineSmall?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
        titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        labelLarge: base.labelLarge?.copyWith(fontSize: 14),
        labelMedium: base.labelMedium?.copyWith(fontSize: 14),
        // Labels sit next to numbers constantly; matching their figure style
        // stops a "3 accounts" caption jittering beside a tabular amount.
        labelSmall:
            base.labelSmall?.copyWith(fontSize: 12, fontFeatures: numeric),
      );
}
