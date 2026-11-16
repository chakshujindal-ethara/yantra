// The dark/light choice is kept in the browser (`etp.theme`) and read back on
// the next load, so a refresh no longer drops a light-mode user back to dark.
// Ported from stage (`exam_top_bar_has_the_theme_toggle_test.dart`).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/main.dart';

void main() {
  test('stored theme: only "light" is light, anything else is dark', () {
    expect(themeFromPref('light'), ThemeMode.light);
    expect(themeFromPref('dark'), ThemeMode.dark);
    expect(themeFromPref(null), ThemeMode.dark);
    expect(themeFromPref('purple'), ThemeMode.dark);
    expect(themeFromPref(''), ThemeMode.dark);
  });

  test('the preference key is stable, so an earlier choice is still read', () {
    expect(kThemePrefKey, 'etp.theme');
  });
}
