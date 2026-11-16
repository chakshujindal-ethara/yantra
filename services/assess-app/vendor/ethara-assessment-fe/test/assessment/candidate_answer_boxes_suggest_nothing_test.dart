// Candidate answer boxes carry no hint text (owner, 2026-09-29): a
// placeholder in a box the candidate answers in is a suggestion of what to
// write. Pinned at the source, like fullscreen_source_invariants_test.
// VM only: it reads the source files, which a browser test cannot.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no answer box on the exam screens sets hint text', () {
    for (final String path in <String>[
      'lib/assessment/screens/exam/answer_layouts.dart',
      'lib/assessment/screens/exam/exam_screen.dart',
    ]) {
      final String src = File(path).readAsStringSync();
      expect(RegExp(r'\bhintText\s*:').hasMatch(src), isFalse,
          reason: '$path sets hintText on a candidate input');
      expect(RegExp(r'\bplaceholder\s*:').hasMatch(src), isFalse,
          reason: '$path passes a placeholder to a candidate input');
    }
  });

  test('the check catches the copy that was actually there', () {
    expect(RegExp(r'\bhintText\s*:').hasMatch("hintText: 'Describe this box...',"),
        isTrue);
    expect(
        RegExp(r'\bplaceholder\s*:')
            .hasMatch("placeholder: 'Write the image-generation prompt.',"),
        isTrue);
  });
}
