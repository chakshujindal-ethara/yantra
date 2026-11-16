import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The worker's theme choice (system, light, dark), remembered on the device.
class ThemeController extends ChangeNotifier {
  ThemeController({ThemeMode initial = ThemeMode.system, this.persist = true}) : _mode = initial;

  static const _key = 'yantra.theme';

  final bool persist;
  ThemeMode _mode;

  ThemeMode get mode => _mode;

  Future<void> restore() async {
    if (!persist) return;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key);
    final found = ThemeMode.values.where((m) => m.name == stored);
    if (found.isNotEmpty && found.first != _mode) {
      _mode = found.first;
      notifyListeners();
    }
  }

  Future<void> set(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    if (!persist) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }

  /// Light and dark alternate; from system, the first tap goes to the opposite of what is painted now.
  Future<void> toggle(Brightness current) => set(current == Brightness.dark ? ThemeMode.light : ThemeMode.dark);
}
