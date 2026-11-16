@TestOn('vm')
library;

// The candidate's release gate, asserted against the SOURCE.
//
// SPLIT OUT OF `leaderboard_opens_the_admin_view_test.dart` so that file runs
// under `--platform chrome` again: this reads lib/ off disk, which a browser
// cannot do. A source assertion because it proves the candidate's release gate
// is still in place, which no tap test can.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the candidate release gate', () {
    test('MyPerformanceScreen still keeps its gate', () {
      // The gate lives in the candidate screen, and this fix did not go near
      // it. If someone later "fixes" the admin case by deleting the gate, the
      // candidate would see unreleased marks - the exact breach Invariant 3
      // exists to prevent - and no other test in this file would notice.
      final File screen = File(
        'lib/assessment/screens/member/my_performance_screen.dart',
      );
      expect(screen.existsSync(), isTrue, reason: 'run from the package root');
      final String src = screen.readAsStringSync();

      // THE TOTALS GATE ITSELF, not the word. `resultsReleased` also appears
      // on the breakdown rows, so a bare `contains` passed with this deleted.
      expect(
        RegExp(
          r'released\s*=\s*completed\s*\.where\(\s*\(_Sitting r\)\s*=>'
          r'\s*r\.ev\.resultsReleased\s*,?\s*\)',
        ).hasMatch(src),
        isTrue,
        reason: 'the candidate-facing release gate must still be there',
      );
      expect(
        src.contains('for (final _Sitting r in released)'),
        isTrue,
        reason: 'the totals must be summed over the released sittings only',
      );
    });
  });
}
