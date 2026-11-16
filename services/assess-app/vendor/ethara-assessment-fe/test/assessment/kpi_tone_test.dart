@TestOn('vm')
// Reads the SOURCE TREE through dart:io, so it can only run on the VM.
// Under `--platform chrome` there is no filesystem and it fails with
// "Unsupported operation: _Namespace" - a harness limit, not a defect.
// Tagging it keeps a chrome run honest: real failures stay visible
// instead of being lost in a dozen expected ones.
// Colour must carry information, not decoration.
//
// THE BUG THIS EXISTS FOR: eight KPI cards were written as
// `count == 0 ? successText : warnText`. On an empty install every one of
// those conditions is trivially true, so a fresh database rendered a wall of
// green zeros celebrating the absence of data. Green has to mean "a real
// thing is in good order", never "there is nothing here".
//
// The rule this enforces: a KPI that tones ITSELF green on a zero value must
// first check that the underlying collection is non-empty. Expressed as a
// source check because the condition lives in the screen, not in a widget
// that could assert at runtime.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no KPI paints green when its collection is empty', () {
    final Directory screens = Directory('lib/assessment/screens');
    expect(screens.existsSync(), isTrue, reason: 'run from the package root');

    // `x == 0 ? successText` or `x.isEmpty ? successText` with no
    // emptiness guard in front of it.
    final RegExp unguarded = RegExp(
      r'valueColor:\s*(?!\w+\.isEmpty\s*\?\s*null)'
      r'[^,\n]*?(?:==\s*0|\.isEmpty)\s*\?\s*t\.successText',
    );

    final List<String> offenders = <String>[];
    for (final FileSystemEntity f in screens.listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final String src = f.readAsStringSync();
      for (final RegExpMatch m in unguarded.allMatches(src)) {
        final int line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
        offenders.add('${f.path}:$line');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'these KPIs go green on an empty collection, which reads as '
          '"all clear" when it means "no data yet":\n  '
          '${offenders.join("\n  ")}',
    );
  });
}
