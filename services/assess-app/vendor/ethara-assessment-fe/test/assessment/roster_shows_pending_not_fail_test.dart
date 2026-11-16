// The ROSTER PILL itself: a held candidate reads Pending, not Fail.
//
// The companion to `roster_verdict_is_not_a_fail_test.dart`, which pins the
// model. This one pins the SURFACE THAT WAS REPORTED - the Candidates tab of the
// assessment detail screen, where production drew a red **Fail** on a candidate
// the module was reporting as `pending` because ten of their answers were parked
// on a Vertex outage.
//
// Two separate mistakes had to line up to produce that pill, so both are
// asserted here:
//
//   1. the screen called `Attempt.result(asm)` - the local recomputation -
//      rather than `Attempt.verdict(asm)`, which prefers the server's answer;
//   2. the recomputation could not see the held answers anyway, because its
//      guard walks `resp` and a roster row carries none.
//
// Fixing only (2) would leave the screen re-deriving a verdict it has been given;
// fixing only (1) would leave every other recomputing surface wrong. The last
// test below is the one that specifically catches a regression of (1): the server
// says pending while a recomputation would say fail, and the pill must follow the
// server.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Assessment _paper() => Assessment(
  id: 'A-1',
  name: 'import and all elements test',
  state: AsmState.done,
  passThreshold: 70,
);

/// The production attempt: submitted, 3 of 34 marks (8.8%, well under the 70%
/// bar), ten subjective answers unresolved, a terminal grader error, and the
/// module's own verdict of `pending`.
///
/// `resp` IS LEFT EMPTY, which is what a roster row actually carries and the
/// precondition for the bug.
Attempt _held({
  ResultState? serverResult = ResultState.pending,
  int pending = 10,
  bool? terminalError = true,
}) => Attempt(
  id: 'E-1754',
  assessmentId: 'A-1',
  employeeId: 'chakshu.jindal@ethara.ai',
  token: 'tok-1754',
  state: AttemptState.submitted,
  isLocked: true,
  serverEarned: 3,
  serverTotal: 34,
  serverPassThreshold: 70,
  subjectivePending: pending,
  subjectiveHasError: terminalError,
  subjectiveState: LlmState.error,
  serverResult: serverResult,
);

AppStore _seed(Attempt a) {
  final AppStore s = AppStore();
  s.assessments = <Assessment>[_paper()];
  s.attempts = <Attempt>[a];
  return s;
}

Future<void> _openRoster(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1800, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: AssessmentDetailScreen(
            store: s,
            portal: Portal.admin,
            asmId: 'A-1',
            tab: 'candidates',
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('a held candidate is Pending on the roster, never Fail', (
    WidgetTester t,
  ) async {
    await _openRoster(t, _seed(_held()));

    expect(
      find.text('Fail'),
      findsNothing,
      reason:
          'this is the reported pill: 3 / 34 held on a grader outage was drawn '
          'as a hard Fail, contradicting the module on the same record',
    );
    expect(find.text('Pending'), findsWidgets);
  });

  testWidgets('the banner names how many candidates are held', (
    WidgetTester t,
  ) async {
    await _openRoster(t, _seed(_held()));

    // The count, and the word the roster pill uses, so the two surfaces cannot
    // be read as describing different candidates.
    expect(
      find.textContaining('1 candidate held on a scoring error'),
      findsOneWidget,
    );
  });

  testWidgets("the server's pending outranks a recomputed fail", (
    WidgetTester t,
  ) async {
    // The DISCRIMINATING case. Nothing is flagged unresolved on this row, so a
    // recomputation reaches 8.8% vs 70% and answers fail - but the server said
    // pending, and the server is the one that applied the bar. A screen that
    // re-derives instead of reading `verdict` fails here.
    final Attempt a = _held(pending: 0, terminalError: false);

    expect(
      a.result(_paper()),
      ResultState.fail,
      reason: 'the recomputation genuinely disagrees; that is the point',
    );
    expect(a.verdict(_paper()), ResultState.pending);

    await _openRoster(t, _seed(a));

    expect(find.text('Fail'), findsNothing);
    expect(find.text('Pending'), findsWidgets);
  });
}
