// A candidate held on a grader outage is PENDING on the roster, never a FAIL.
//
// THE BUG THIS EXISTS FOR. Reported from production: the admin roster showed
// Chakshu Jindal as `3 / 34` with a red **Fail** pill, while the Odoo list for
// the same evaluator showed **Pending**. The module was right - ten of that
// attempt's subjective answers were parked in `llm_state = 'error'` after Vertex
// was left uncredentialed, so `_compute_result` forced `result = 'pending'`.
//
// The client threw that away. `assessment_detail_screen` drew the pill from
// `Attempt.result(asm)` - the LOCAL recomputation - instead of
// `Attempt.verdict(asm)`, which prefers the server's answer. And the
// recomputation could not see the held answers either: its invariant-4 guard is
// `unresolvedQuestionIds`, which walks `resp`, and `resp` is EMPTY BY DESIGN on
// every list route. So the guard matched nothing, execution fell through to
// `internalPercent >= passThreshold` - 3 / 34 is 8.8% against a 70% bar - and an
// infrastructure fault was rendered as the candidate's failure. That is the one
// outcome invariant 4 exists to prevent.
//
// Two things are asserted here, because either alone would let it back:
//   1. the roster reads the server's verdict (`verdict`);
//   2. the recomputation ITSELF now honours the server-sent counters
//      (`subjective.pending`, `subjective.has_terminal_error`), so a surface
//      that legitimately recomputes cannot skip invariant 4 either.
//
// The payload is `S.evaluator_admin_row` in `controllers/api/serializers.py`.
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// The reported roster row, verbatim in shape: submitted, 3 of 34 marks, ten
/// answers unresolved, a terminal grader error, and the module's own `pending`.
///
/// NO `answers` / `resp` KEY, deliberately - that absence is the bug's
/// precondition, not an omission in the fixture.
Map<String, dynamic> rosterRow({
  String result = 'pending',
  int pending = 10,
  bool terminalError = true,
}) => <String, dynamic>{
  'id': 1754,
  'assessment_id': 2,
  'employee_id': 'chakshu.jindal@ethara.ai',
  'state': 'submitted',
  'invite_state': 'sent',
  'total_questions': 29,
  'answered_count': 29,
  'score_marks': '3 / 34',
  'pass_threshold': 70.0,
  'result': result,
  'results_released': false,
  'subjective': <String, dynamic>{
    'state': 'error',
    'pending': pending,
    'has_terminal_error': terminalError,
  },
};

/// The paper as a roster route describes it: no question list, because that
/// route does not send one.
Assessment paper() => Assessment.fromJson(<String, dynamic>{
  'id': 2,
  'name': 'import and all elements test',
  'state': 'done',
  'total_questions': 29,
  'pass_threshold': 70.0,
});

void main() {
  group('A held attempt is pending on the roster', () {
    test('the server said pending, so the roster says pending', () {
      final Attempt a = Attempt.fromJson(rosterRow());

      expect(a.serverResult, ResultState.pending);
      expect(
        a.verdict(paper()),
        ResultState.pending,
        reason: 'this is the pill the roster draws; it read Fail on production',
      );
    });

    test('the recomputation no longer invents a fail either', () {
      // The assertion that fails on the old code. `result` had nothing to walk,
      // so it went straight to 8.8% vs 70% and answered fail.
      final Attempt a = Attempt.fromJson(rosterRow());

      expect(
        a.result(paper()),
        ResultState.pending,
        reason:
            'invariant 4 must hold from the server-sent counters when there '
            'are no answers on the row to walk',
      );
    });

    test('the held answers actually arrive in the model', () {
      // The counters the guard leans on. Both were already on the wire and
      // already parsed - the recomputation simply never consulted them.
      final Attempt a = Attempt.fromJson(rosterRow());

      expect(a.subjectivePending, 10);
      expect(a.subjectiveHasError, isTrue);
      expect(a.hasScoringError(paper()), isTrue);
    });

    test('the terminal-error flag alone is enough to hold it', () {
      // Belt and braces: even if the count were absent, the flag holds it.
      final Attempt a = Attempt.fromJson(rosterRow(pending: 0));

      expect(a.subjectivePending, 0);
      expect(a.result(paper()), ResultState.pending);
      expect(a.verdict(paper()), ResultState.pending);
    });
  });

  group('Nothing else was softened', () {
    test('a genuinely resolved low score is still a fail', () {
      // THE TEST THAT KEEPS THE OTHERS HONEST. If this passed as `pending` the
      // fix would simply have stopped reporting failures at all: same 3 / 34,
      // same 70% bar, but nothing unresolved and no error flag.
      final Attempt a = Attempt.fromJson(
        rosterRow(result: 'fail', pending: 0, terminalError: false),
      );

      expect(a.result(paper()), ResultState.fail);
      expect(a.verdict(paper()), ResultState.fail);
    });

    test('a resolved pass is still a pass', () {
      final Map<String, dynamic> row =
          rosterRow(result: 'pass', pending: 0, terminalError: false)
            ..['score_marks'] = '30 / 34';
      final Attempt a = Attempt.fromJson(row);

      expect(a.result(paper()), ResultState.pass);
      expect(a.verdict(paper()), ResultState.pass);
    });

    test('an attempt still being sat is pending, as it always was', () {
      final Map<String, dynamic> row = rosterRow(
        pending: 0,
        terminalError: false,
      )..['state'] = 'in_progress';
      final Attempt a = Attempt.fromJson(row);

      expect(a.result(paper()), ResultState.pending);
    });
  });

  group('An ungraded roster row is not offered for release', () {
    test('it is still grading, while a scored row stays releasable', () {
      // Stage attempt 2638: grading off, one written answer never scored. The
      // old `stillGrading` walked `resp`, which a roster row never carries, so
      // the paper offered "Release results (1)" for a `pending` result.
      final Assessment asm = paper();
      final AppStore s = AppStore()
        ..assessments = <Assessment>[asm]
        ..attempts = <Attempt>[
          Attempt.fromJson(rosterRow(pending: 1, terminalError: false)),
          Attempt.fromJson(
            rosterRow(result: 'pass', pending: 0, terminalError: false)
              ..['id'] = 1755,
          ),
        ];

      expect(s.stillGrading(asm).map((Attempt a) => a.id), <String>['1754']);
      expect(s.releasable(asm).map((Attempt a) => a.id), <String>['1755']);
    });
  });
}
