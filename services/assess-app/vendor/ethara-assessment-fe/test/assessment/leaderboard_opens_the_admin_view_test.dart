// The candidate's own performance route stays theirs.
//
// A leaderboard row now opens `CandidatePerformance` (A-133; see
// leaderboard_opens_the_candidates_performance_page_test.dart). This pins the
// other half: a candidate's `MyPerformance` never resolves to the operator
// view.

import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/nav.dart';

void main() {
  group('the candidate\'s performance route', () {
    testWidgets('the candidate\'s own route is untouched', (
      WidgetTester t,
    ) async {
      // THE GUARD ON THE FIX. Invariant 3 is real: a candidate must not see a
      // mark before it is released. This fix widens what an OPERATOR sees and
      // must leave the candidate's own surface exactly as it was - so
      // `MyPerformance` still resolves to the gated screen.
      //
      // Asserted through the nav rather than by pumping the screen, which
      // needs a signed-in session this test has no business building.
      final AssessmentNav nav = AssessmentNav();
      nav.go(const MyPerformance());

      expect(nav.current, isA<MyPerformance>());
      expect(
        nav.current,
        isNot(isA<CandidateDetail>()),
        reason: 'a candidate must not be handed the operator view',
      );
    });
  });
}
