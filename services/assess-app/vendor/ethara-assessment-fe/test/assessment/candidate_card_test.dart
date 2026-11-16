// A candidate's own card parses into a usable Attempt.
//
// THE BUGS THIS EXISTS FOR. `/api/v1/me/assessments` is the ONE endpoint a
// candidate can call, and its rows are shaped differently from the admin
// roster. Four separate mismatches each independently blanked the candidate's
// own screens, and every one of them looked like "no data yet" rather than an
// error:
//
//   1. `state` is the BUCKET name ("completed"), not the model state
//      ("submitted"), so AttemptState.parse fell back to `pending` and
//      `isDone` was false for a submitted attempt.
//   2. `results_released` is nested as `result.released`, so every released
//      result rendered as "awaiting release".
//   3. `score_marks` ("0 / 3") was dropped entirely; marks were only ever
//      recomputed from per-question responses, which this endpoint does not
//      send, so a released result showed no number.
//   4. There is no `candidate` object (the endpoint is already scoped to the
//      caller), so `employeeId` was empty and `attemptsForPerson` matched
//      nothing.
//
// The payload below is copied from a live server response.
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

/// A completed, released sitting exactly as the candidate endpoint sends it.
Map<String, dynamic> card({bool released = true}) => <String, dynamic>{
  'id': 4,
  'token': '00000000-0000-4000-8000-000000000001',
  'assessment_id': 18,
  'name': 'Forklift Safety - Induction E2E',
  'state': 'completed',
  'state_label': 'Completed',
  'status_kind': 'done',
  'progress': <String, dynamic>{'answered': 3, 'total': 3, 'percent': 100},
  'duration_minutes': 30,
  'submitted_at': '2026-08-05T07:58:23Z',
  'result': <String, dynamic>{
    'released': released,
    'status': released ? 'released' : 'awaiting_results',
    if (released) 'score_marks': '0 / 3',
    if (released) 'result': 'fail',
  },
  'can_review_answers': released,
};

void main() {
  group('A candidate card parses into a usable attempt', () {
    test('the bucket name "completed" counts as submitted', () {
      final Attempt a = Attempt.fromJson(card());

      expect(
        a.state,
        AttemptState.submitted,
        reason:
            'the candidate endpoint sends a bucket name, not the model '
            'state; falling back to pending hid every finished sitting',
      );
      expect(a.isDone, isTrue);
    });

    test('release is read from the nested result object', () {
      expect(
        Attempt.fromJson(card()).resultsReleased,
        isTrue,
        reason: 'released is nested as result.released on this endpoint',
      );
      expect(Attempt.fromJson(card(released: false)).resultsReleased, isFalse);
    });

    test('the server marks survive, since responses do not arrive', () {
      final Attempt a = Attempt.fromJson(card());

      expect(a.serverEarned, 0);
      expect(a.serverTotal, 3);
      expect(
        a.resp,
        isEmpty,
        reason:
            'this endpoint sends no per-question answers at all, which '
            'is exactly why the server marks have to be kept',
      );
    });

    test('an unreleased card discloses no marks but still counts questions', () {
      final Attempt a = Attempt.fromJson(card(released: false));

      expect(
        a.serverEarned,
        isNull,
        reason:
            'the server omits score_marks before release, and the '
            'client must not invent a zero in its place',
      );
      // INVARIANT 3 is about the MARK, not the paper. How many questions an
      // attempt holds is not a disclosure - the endpoint sends it openly as
      // `progress.total`, on every bucket, released or not.
      //
      // This used to expect isNull, which locked in the bug it was written
      // beside: with no released score_marks to parse, nothing read the count
      // at all, so every "Available" and "In progress" card on My assessments
      // rendered "0 questions" and the progress bar divided by zero. Asserting
      // the blank made it look intended.
      expect(
        a.serverTotal,
        3,
        reason: 'progress.total carries the count before any release',
      );
      expect(a.serverAnswered, 3);
    });

    test('the question count is read from progress on an available card', () {
      // The reported symptom, at its own shape: an attempt that has not been
      // started has no marks anywhere on the row, so `progress` is the ONLY
      // place the count exists.
      final Map<String, dynamic> row = card(released: false)
        ..['state'] = 'available'
        ..['progress'] = <String, dynamic>{
          'answered': 0,
          'total': 6,
          'percent': 0,
        };
      final Attempt a = Attempt.fromJson(row);

      expect(a.serverTotal, 6);
      expect(a.serverAnswered, 0);
    });

    test('a flat total_questions still wins over progress', () {
      // The admin roster spells it flat, and that spelling must keep
      // precedence so this fallback cannot change what those screens show.
      final Map<String, dynamic> row = card(released: false)
        ..['total_questions'] = 9;

      expect(Attempt.fromJson(row).serverTotal, 9);
    });

    test('the assessment name is carried for a screen that cannot join', () {
      expect(
        Attempt.fromJson(card()).assessmentName,
        'Forklift Safety - Induction E2E',
      );
    });
  });
}
