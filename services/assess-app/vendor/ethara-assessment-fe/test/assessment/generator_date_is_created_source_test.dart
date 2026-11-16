@TestOn('vm')
library;

// No screen calls a generator's creation date "updated".
//
// SPLIT OUT OF `generator_date_is_created_test.dart` so that file runs under
// `--platform chrome` again. This one reads lib/ off disk, which a browser
// cannot do, and a single such test drags its whole file out of the browser
// run - the five model tests it used to sit beside are pure Dart and are worth
// having on both platforms.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('NO screen still calls a generator date "updated"', () {
    // The label and the field were renamed together on purpose. Leaving one
    // behind is how the header came to disagree with its own source in the
    // first place.
    for (final String path in <String>[
      'lib/assessment/screens/admin/generator_detail_screen.dart',
      'lib/assessment/screens/admin/generator_list_screen.dart',
    ]) {
      final List<String> lines = File(path).readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final String l = lines[i];
        if (l.trimLeft().startsWith('//')) continue;
        expect(l.contains('updated'), isFalse,
            reason: '$path:${i + 1} still says "updated": ${l.trim()}');
      }
    }
  });
}
