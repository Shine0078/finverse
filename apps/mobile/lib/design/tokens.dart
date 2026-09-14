/// The measurements every FINVERSE surface is built from.
///
/// One scale, used everywhere. The point is not that 12 is better than 13 — it
/// is that a screen assembled from four arbitrary paddings looks assembled from
/// four arbitrary paddings, and that is most of what "feels like a dev
/// dashboard" actually means (MISSION2 §2).
library;

import 'package:flutter/widgets.dart';

/// Spacing, on a 4pt grid.
///
/// Named by role rather than size so the intent survives a change of value: a
/// future decision that cards should breathe more is one edit here, not a
/// hundred edits to `EdgeInsets.all(16)`.
abstract final class FinSpace {
  /// 4 — between a label and the thing it labels.
  static const double xs = 4;

  /// 8 — between tightly related items in a row.
  static const double sm = 8;

  /// 12 — inside compact components.
  static const double md = 12;

  /// 16 — the default. Card padding, screen gutters.
  static const double lg = 16;

  /// 20 — between distinct cards.
  static const double xl = 20;

  /// 28 — between sections of a screen.
  static const double xxl = 28;

  /// 48 — around an empty state, where the emptiness is the point.
  static const double huge = 48;
}

/// Corner radii. Financial products read as trustworthy when they are calm;
/// heavily rounded corners read as playful, which is the wrong register for
/// somebody's mortgage.
abstract final class FinRadius {
  static const Radius sm = Radius.circular(8);
  static const Radius md = Radius.circular(12);
  static const Radius lg = Radius.circular(16);
  static const Radius pill = Radius.circular(999);

  static const BorderRadius cardBorder = BorderRadius.all(lg);
  static const BorderRadius sheetBorder =
      BorderRadius.vertical(top: Radius.circular(20));
  static const BorderRadius pillBorder = BorderRadius.all(pill);
}

/// Motion. Short and unshowy: an animation the user waits for is a cost, and
/// this app's job is to answer a question quickly.
abstract final class FinDuration {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 220);

  /// One sweep of a skeleton shimmer.
  static const Duration shimmer = Duration(milliseconds: 1200);
}

/// Minimum interactive size.
///
/// 48dp is the Material and WCAG floor and it is not negotiable here: this app
/// is used one-handed, on a phone, often while standing in a shop.
abstract final class FinTouch {
  static const double minTarget = 48;
}
