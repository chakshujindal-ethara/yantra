// A candidate's pass or fail comes from the SERVER, and does not move.
//
// THE BUG THIS EXISTS FOR. Both candidate screens picked their verdict source
// by asking whether an Assessment happened to be in the store:
//
//     asm == null ? (serverPassed ?? false) : ev.result(asm)
//
// A candidate never loads the assessment list - it is a manager route - so the
// first branch was the normal case and it read the server correctly. But
// `loadExamByToken` caches the assessment BRIEF from the exam gate, and that
// brief carried no pass threshold, so `Assessment.passThreshold` fell back to
// the 70% default. The moment a candidate opened the runner, the second branch
// took over and re-derived every released result against a bar that was not
// the one applied.
//
// Reported as My performance showing a released 6 / 10 as a red FAIL and a
// green PASS on alternating loads. The server had judged it a pass at 60% and
// never changed its mind; only which of the two answers the screen consulted
// changed. Both screens now read `Attempt.verdict`, which prefers the server.
//
// The payload shapes below are the module's own: `candidate_result` for the
// nested form, `evaluator_admin_row` for the flat one.
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

/// The reported sitting: 6 of 10 marks, released, and a PASS at a 60% bar.
Map<String, dynamic> sitting({
  String result = 'pass',
  String marks = '6 / 10',
  double? passThreshold = 60.0,
}) => <String, dynamic>{
  'id': 79,
  'assessment_id': 21,
  'name': 'Text to Image Assessment',
  'state': 'completed',
  'progress': <String, dynamic>{'answered': 10, 'total': 10, 'percent': 100},
  'submitted_at': '2026-08-13T06:12:00Z',
  'result': <String, dynamic>{
    'released': true,
    'status': 'released',
    'score_marks': marks,
    'result': result,
    'pass_threshold': ?passThreshold,
  },
};

/// The exam gate's assessment brief, as a candidate receives it. Its question
/// list is empty and - before the fix - it stated no pass mark either, which is
/// what made a client recomputation impossible to get right.
Assessment brief({double? passThreshold}) =>
    Assessment.fromJson(<String, dynamic>{
      'id': 21,
      'name': 'Text to Image Assessment',
      'state': 'in_progress',
      'duration_minutes': 30,
      'pass_threshold': ?passThreshold,
    });

void main() {
  group("The server's verdict is the verdict", () {
    test('a released pass reads Pass with no assessment loaded', () {
      final Attempt a = Attempt.fromJson(sitting());

      expect(a.serverResult, ResultState.pass);
      expect(a.verdict(null), ResultState.pass);
      expect(a.serverEarned, 6);
      expect(a.serverTotal, 10);
    });

    test('and STILL reads Pass once the exam brief is cached', () {
      // The exact flip that was reported. 6 / 10 is 60%: against the brief's
      // defaulted 70% threshold a recomputation says FAIL, so this assertion
      // fails on the old code and passes on the new.
      final Attempt a = Attempt.fromJson(sitting());

      expect(
        a.verdict(brief()),
        ResultState.pass,
        reason:
            'opening the exam route must not turn a released pass into a '
            'fail; the assessment brief carries no threshold to judge by',
      );
      expect(
        a.result(brief()),
        ResultState.fail,
        reason:
            'the recomputation itself is unchanged - it is judging 60% '
            'against the 70% default, which is why nothing may consult it '
            'when the server has already answered',
      );
    });

    test('a released fail is not softened either', () {
      final Attempt a = Attempt.fromJson(
        sitting(result: 'fail', marks: '3 / 10'),
      );

      expect(a.verdict(null), ResultState.fail);
      expect(a.verdict(brief()), ResultState.fail);
    });

    test('pending survives as pending, and is never reported as a fail', () {
      // INVARIANT 4: an unresolved subjective answer holds the result at
      // pending whatever the score - including a grader outage, which is not
      // the candidate's failure. The bool this replaced had no third state, so
      // `(serverPassed ?? false) ? pass : fail` showed FAIL to a candidate
      // whose paper was still being marked.
      final Attempt a = Attempt.fromJson(sitting(result: 'pending'));

      expect(a.serverResult, ResultState.pending);
      expect(a.verdict(null), ResultState.pending);
      expect(a.verdict(brief()), ResultState.pending);
    });

    test('the flat admin spelling is read too', () {
      final Map<String, dynamic> row = <String, dynamic>{
        'id': 79,
        'assessment_id': 21,
        'state': 'submitted',
        'result': 'pass',
        'score_marks': '6 / 10',
        'pass_threshold': 60.0,
      };
      final Attempt a = Attempt.fromJson(row);

      expect(a.serverResult, ResultState.pass);
      expect(a.serverPassThreshold, 60.0);
    });

    test('no verdict sent leaves the recomputation in charge', () {
      // The seed fixtures and the admin detail routes carry responses instead
      // of a verdict. Those surfaces must keep re-deriving, or an operator who
      // has just changed the threshold sees a stale answer.
      final Map<String, dynamic> row = sitting()
        ..['result'] = <String, dynamic>{'released': true, 'status': 'released'};
      final Attempt a = Attempt.fromJson(row);

      expect(a.serverResult, isNull);
      expect(
        a.verdict(null),
        ResultState.pending,
        reason:
            'with no verdict and no assessment there is nothing to claim; '
            'pending is the only honest answer',
      );
    });
  });

  group('The threshold marker is drawn against the real pass mark', () {
    test("the server's mark is preferred over any assessment", () {
      final Attempt a = Attempt.fromJson(sitting());

      expect(a.serverPassThreshold, 60.0);
      expect(a.passMarkPercent(null), 60.0);
      expect(
        a.passMarkPercent(brief(passThreshold: 75)),
        60.0,
        reason: 'the bar that was applied wins over any cached brief',
      );
    });

    test('a brief that states the mark is used when the result does not', () {
      final Attempt a = Attempt.fromJson(sitting(passThreshold: null));

      expect(a.serverPassThreshold, isNull);
      expect(a.passMarkPercent(brief(passThreshold: 60)), 60.0);
      expect(
        a.passMarkPercent(null),
        70.0,
        reason:
            'the module DEFAULT_SUBJECTIVE_THRESHOLD, and now only a last '
            'resort rather than the value every candidate screen used',
      );
    });
  });
}
