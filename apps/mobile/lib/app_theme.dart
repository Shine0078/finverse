import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/platform/shared_preferences_registration.dart';

/// The six accent choices shown in Settings. Presets stay distinct against the
/// app's fixed light surfaces.
abstract final class FinThemeColors {
  static const emerald = 'emerald';
  static const indigo = 'indigo';
  static const ocean = 'ocean';
  static const plum = 'plum';
  static const amber = 'amber';
  static const custom = 'custom';

  static const presets = [emerald, indigo, ocean, plum, amber];

  static Color preset(String id) => switch (id) {
        indigo => const Color(0xFF4F46E5),
        ocean => const Color(0xFF0369A1),
        plum => const Color(0xFF9333EA),
        amber => const Color(0xFFD97706),
        _ => const Color(0xFF0E7490),
      };

  static bool isPreset(String id) => presets.contains(id);
}

abstract interface class ThemeColorPreferenceStore {
  Future<String?> readThemeColor();
  Future<int?> readCustomColor();
  Future<void> writeThemeColor(String id);
  Future<void> writeCustomColor(int value);
}

class SharedPreferencesThemeColorPreferenceStore
    implements ThemeColorPreferenceStore {
  SharedPreferencesThemeColorPreferenceStore(
      {SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? _createPreferences();

  static const _themeKey = 'finverse.theme_color';
  static const _customKey = 'finverse.theme_color.custom';

  final SharedPreferencesAsync _preferences;

  static SharedPreferencesAsync _createPreferences() {
    ensureSharedPreferencesAsyncPlatform();
    return SharedPreferencesAsync();
  }

  @override
  Future<String?> readThemeColor() => _preferences.getString(_themeKey);

  @override
  Future<int?> readCustomColor() => _preferences.getInt(_customKey);

  @override
  Future<void> writeThemeColor(String id) =>
      _preferences.setString(_themeKey, id);

  @override
  Future<void> writeCustomColor(int value) =>
      _preferences.setInt(_customKey, value);
}

class ThemeColorController extends ChangeNotifier {
  ThemeColorController({ThemeColorPreferenceStore? store})
      : _store = store ?? SharedPreferencesThemeColorPreferenceStore();

  ThemeColorController.inMemory({ThemeColorPreferenceStore? store})
      : _store = store ?? InMemoryThemeColorPreferenceStore();

  final ThemeColorPreferenceStore _store;
  String _selected = FinThemeColors.emerald;
  Color _custom = FinThemeColors.preset(FinThemeColors.emerald);
  var _restored = false;

  String get selected => _selected;
  Color get color => _selected == FinThemeColors.custom
      ? _custom
      : FinThemeColors.preset(_selected);
  Color get customColor => _custom;

  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    try {
      final id = await _store.readThemeColor();
      final custom = await _store.readCustomColor();
      if (id != null &&
          (FinThemeColors.isPreset(id) || id == FinThemeColors.custom)) {
        _selected = id;
      }
      if (custom != null && custom >= 0 && custom <= 0xFFFFFFFF) {
        _custom = Color(custom).withValues(alpha: 1);
      }
    } catch (_) {
      // A visual preference must never delay or block the financial UI.
    }
    notifyListeners();
  }

  Future<void> selectPreset(String id) async {
    if (!FinThemeColors.isPreset(id) || id == _selected) return;
    _selected = id;
    notifyListeners();
    try {
      await _store.writeThemeColor(id);
    } catch (_) {
      // Keep the choice for this run if local preferences are unavailable.
    }
  }

  Future<void> selectCustom(Color value) async {
    _custom = value.withValues(alpha: 1);
    _selected = FinThemeColors.custom;
    notifyListeners();
    try {
      await _store.writeCustomColor(_custom.toARGB32());
      await _store.writeThemeColor(FinThemeColors.custom);
    } catch (_) {
      // Keep the choice for this run if local preferences are unavailable.
    }
  }
}

class InMemoryThemeColorPreferenceStore implements ThemeColorPreferenceStore {
  String? themeColor;
  int? customColor;

  @override
  Future<String?> readThemeColor() async => themeColor;

  @override
  Future<int?> readCustomColor() async => customColor;

  @override
  Future<void> writeThemeColor(String id) async => themeColor = id;

  @override
  Future<void> writeCustomColor(int value) async => customColor = value;
}

class ThemeColorControllerScope
    extends InheritedNotifier<ThemeColorController> {
  const ThemeColorControllerScope({
    required ThemeColorController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static ThemeColorController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ThemeColorControllerScope>()
      ?.notifier;
}
