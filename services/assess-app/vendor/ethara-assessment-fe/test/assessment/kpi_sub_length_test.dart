@TestOn('vm')
// Reads the SOURCE TREE through dart:io, so it can only run on the VM.
// Under `--platform chrome` there is no filesystem and it fails with
// "Unsupported operation: _Namespace" - a harness limit, not a defect.
// Tagging it keeps a chrome run honest: real failures stay visible
// instead of being lost in a dozen expected ones.
// A KPI sub-line must fit its card on one line.
//
// WHY THIS IS A TEST AND NOT A REVIEW NOTE. Flutter web paints to a canvas, so
// an ellipsised label reports its FULL text in the accessibility tree - the DOM
// says "Held until a person releases them" while the screen shows "Held until a
// person releas...". Every DOM-based check passes. Only a screenshot catches
// it, and screenshots are not run on every change.
//
// The KPI strip is the densest row in the product and the one most likely to
// grow a fifth card, so it is also the easiest place to introduce a truncation
// nobody notices.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // 1280 viewport - 240 sidebar - 44 padding = 996px of content.
  // The widest strip in the product is five cards with 13px gaps, so a card is
  // (996 - 4*13) / 5 = 188px, less 2*13 of internal padding = 162px of text.
  // The sub-line renders at ~11px, averaging ~5.6px per character in this
  // typeface, which is ~28 characters. 26 keeps a margin for wide glyphs.
  const int maxSubChars = 26;

  test('no KPI sub-line is long enough to truncate', () {
    final Directory screens = Directory('lib/assessment/screens');
    expect(
      screens.existsSync(),
      isTrue,
      reason: 'run this from the package root',
    );

    // `sub:` appears on other widgets too (page headers wrap and are fine), so
    // only count one that sits inside a Kpi(...) call.
    final RegExp kpiCall = RegExp(r'Kpi\(');
    final RegExp subLine = RegExp(r"sub:\s*'([^']+)'");

    final List<String> tooLong = <String>[];
    for (final FileSystemEntity f in screens.listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final List<String> lines = f.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (!kpiCall.hasMatch(lines[i])) continue;
        // A Kpi(...) call is short; its sub is within a few lines.
        for (int j = i; j < i + 7 && j < lines.length; j++) {
          final RegExpMatch? m = subLine.firstMatch(lines[j]);
          if (m == null) continue;
          final String text = m.group(1)!;
          // An interpolated value is measured at runtime, not here.
          if (text.contains(r'$')) continue;
          if (text.length > maxSubChars) {
            tooLong.add(
              '${f.path.split('/').last}:${j + 1} '
              '(${text.length} chars) "$text"',
            );
          }
        }
      }
    }

    expect(
      tooLong,
      isEmpty,
      reason:
          'these KPI sub-lines will render with an ellipsis that no DOM '
          'check can see. Shorten to $maxSubChars characters or fewer:\n'
          '${tooLong.join('\n')}',
    );
  });
}
