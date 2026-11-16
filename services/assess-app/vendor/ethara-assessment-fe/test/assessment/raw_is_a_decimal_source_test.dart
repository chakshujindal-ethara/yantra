@TestOn('vm')
library;

// The grader's 0-100 scale never reaches a screen unformatted.
//
// SPLIT OUT OF `raw_is_a_decimal_test.dart` so that file can run under
// `--platform chrome` again. This is a SOURCE SCAN: it reads lib/ off disk,
// which a browser cannot do, and one such test in a file drags the whole file
// out of the browser run. The formatter tests it used to sit beside are pure
// Dart and belong on both platforms.
//
// The convention it guards is unchanged: the next person to surface `raw100`
// will reach for `.round()` exactly as the four sites this replaced did, and
// nothing but a scan would catch it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('No screen prints the grader scale directly', () {
    test('every raw100 render goes through the formatter', () {
      // A SOURCE SCAN, because this is a convention rather than a function:
      // the next person to surface `raw100` will reach for `.round()` exactly
      // as the four sites this replaced did, and nothing else would catch it.
      final List<String> offenders = <String>[];
      for (final FileSystemEntity f
          in Directory('lib/assessment/screens').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final List<String> lines = f.readAsLinesSync();
        for (int i = 0; i < lines.length; i++) {
          final String line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          // `raw100 / 100` is a METER VALUE, already a 0-1 fraction, and is
          // the one legitimate bare use.
          if (!line.contains('raw100') && !line.contains('llmRaw100')) continue;
          if (line.contains('rawFromHundred')) continue;
          if (line.contains('/ 100')) continue;
          if (line.contains('>=') || line.contains('.compareTo(')) continue;
          // A null GUARD is not a render.
          if (line.contains('null')) continue;
          offenders.add('${f.path.split('/').last}:${i + 1}  ${line.trim()}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'these print the grader\'s 0-100 score where a raw belongs - '
            'pass it through rawFromHundred:\n  ${offenders.join('\n  ')}',
      );
    });
  });
}
