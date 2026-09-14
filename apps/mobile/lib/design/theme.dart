/// The FINVERSE theme, assembled from the tokens.
///
/// Everything visual is decided here so screens contain layout and content
/// rather than styling. A screen that sets its own colours is a screen that
/// will look wrong the first time the palette changes.
library;

import 'package:flutter/material.dart';

import 'colors.dart';
import 'tokens.dart';
import 'typography.dart';

abstract final class FinTheme {
  /// Interactive cyan-blue is kept separate from financial green and red.
  /// Deep navy carries the persistent app chrome; white and cool grey keep the
  /// working surface quiet and easy to scan.
  static const Color seed = Color(0xFF0E7490);
  static const Color navy = Color(0xFF0B1F33);
  static const Color slate = Color(0xFF102A43);
  static const Color canvas = Color(0xFFF3F6FA);

  static ThemeData light([Color? brandSeed]) => _build(brandSeed);

  static ThemeData _build(Color? brandSeed) {
    final selectedSeed = brandSeed ?? seed;
    final scheme = ColorScheme.fromSeed(
      seedColor: selectedSeed,
      brightness: Brightness.light,
    ).copyWith(
      primary: selectedSeed,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFCFFAFE),
      onPrimaryContainer: const Color(0xFF083344),
      secondary: const Color(0xFF0F766E),
      onSecondary: Colors.white,
      surface: Colors.white,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFF8FAFC),
      surfaceContainer: const Color(0xFFF1F5F9),
      surfaceContainerHigh: const Color(0xFFE8EEF5),
      surfaceContainerHighest: const Color(0xFFDDE6EF),
      outline: const Color(0xFF64748B),
      outlineVariant: const Color(0xFFCBD5E1),
      error: const Color(0xFFC2413B),
      errorContainer: const Color(0xFFFFE4E1),
      onErrorContainer: const Color(0xFF7F1D1D),
    );
    final themedFin = FinColors.light.copyWith(
      heroGradientStart: slate,
      heroGradientEnd: navy,
      onHero: Colors.white,
      onHeroMuted: const Color(0xFFCED9E5),
    );
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);

    return base.copyWith(
      extensions: [themedFin],
      textTheme: FinType.textTheme(base.textTheme),
      scaffoldBackgroundColor: canvas,

      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: navy,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        actionsIconTheme: const IconThemeData(color: Colors.white),
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: Colors.white,
        ),
      ),

      // Outlined rather than elevated. Stacked shadows on a scrolling list of
      // financial cards read as clutter; a hairline border separates content
      // without adding visual weight to every row.
      cardTheme: CardThemeData(
        elevation: 1.5,
        shadowColor: navy.withValues(alpha: 0.10),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: FinRadius.cardBorder,
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),

      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: FinSpace.lg,
          vertical: FinSpace.xs,
        ),
        minVerticalPadding: FinSpace.md,
        shape: const RoundedRectangleBorder(borderRadius: FinRadius.cardBorder),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, FinTouch.minTarget),
          padding: const EdgeInsets.symmetric(horizontal: FinSpace.xl),
          shape:
              const RoundedRectangleBorder(borderRadius: FinRadius.pillBorder),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, FinTouch.minTarget),
          padding: const EdgeInsets.symmetric(horizontal: FinSpace.xl),
          shape:
              const RoundedRectangleBorder(borderRadius: FinRadius.pillBorder),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, FinTouch.minTarget),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: FinSpace.lg,
          vertical: FinSpace.lg,
        ),
        border: const OutlineInputBorder(
          borderRadius: FinRadius.cardBorder,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: FinRadius.cardBorder,
          borderSide:
              BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: FinRadius.cardBorder,
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        // Errors are stated in words, never by colouring the field alone.
        errorBorder: OutlineInputBorder(
          borderRadius: FinRadius.cardBorder,
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape:
            const RoundedRectangleBorder(borderRadius: FinRadius.sheetBorder),
        showDragHandle: true,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: FinRadius.cardBorder),
      ),

      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        elevation: 0,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        indicatorShape:
            const RoundedRectangleBorder(borderRadius: FinRadius.pillBorder),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11.5,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        ),
      ),

      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: navy,
        indicatorColor: const Color(0xFF155E75),
        selectedIconTheme: const IconThemeData(color: Colors.white),
        unselectedIconTheme: const IconThemeData(color: Color(0xFFAFC0D1)),
        selectedLabelTextStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
        unselectedLabelTextStyle: const TextStyle(
          color: Color(0xFFCED9E5),
          fontWeight: FontWeight.w500,
          fontSize: 13,
        ),
      ),

      chipTheme: base.chipTheme.copyWith(
        shape: const RoundedRectangleBorder(borderRadius: FinRadius.pillBorder),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: FinRadius.cardBorder),
        insetPadding: const EdgeInsets.all(FinSpace.lg),
      ),

      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: scheme.outlineVariant.withValues(alpha: 0.5),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearMinHeight: 8,
        borderRadius: const BorderRadius.all(FinRadius.pill),
        linearTrackColor: scheme.surfaceContainerHighest,
      ),
    );
  }
}
