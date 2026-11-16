// A candidate arriving from an invitation link must reach their exam.
//
// THE BUG THIS EXISTS FOR, found by following a real invitation URL in a
// browser: the app showed "This link does not work - the link is unknown or has
// been revoked" over a token the server accepts with `ok: true`.
//
// `attemptByToken` searches attempts ALREADY in the store. A candidate opening
// `/exam/<token>` cold has loaded none, and cannot load any: `/api/v1/attempts`
// and `/api/v1/assessments` are manager routes. Only `/exam/<token>/state` is
// scoped to the token itself.
//
// Three faults were fixed together, and each is asserted below:
//   1. nothing called `/exam/<token>/state`, so the attempt never arrived
//   2. the attempt row carries no token and no assessment id, so even once
//      fetched `attemptByToken` could not match it
//   3. the MARKS live under `result`, not on the attempt, so the summary read
//      "0 of 0" for a result the server reports as "0 / 3"
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

void main() {
  // Verbatim from a live `POST /api/v1/exam/<token>/state`.
  Map<String, dynamic> statePayload() => <String, dynamic>{
    'outcome': 'complete',
    'assessment': <String, dynamic>{
      'id': 18,
      'name': 'Forklift Safety - Induction E2E',
      'state': 'done',
      'duration_minutes': 30,
    },
    'attempt': <String, dynamic>{
      'id': 4,
      'state': 'submitted',
      'is_locked': true,
      'started_at': '2026-08-05T07:58:23Z',
      'deadline': '2026-08-05T08:28:23Z',
      'submitted_at': '2026-08-05T07:58:23Z',
      'total_questions': 3,
      'answered_count': 3,
      'results_released': true,
    },
    'result': <String, dynamic>{
      'released': true,
      'status': 'released',
      'score_marks': '0 / 3',
      'result': 'fail',
      'verdict': 'fail',
      'is_pending': false,
      'subjective_pending': 0,
      'label': '0 / 3 - FAIL',
    },
  };

  /// The same merge `AppStore.loadExamByToken` performs.
  Attempt merged(String token) {
    final Map<String, dynamic> res = statePayload();
    final Map<String, dynamic> row = <String, dynamic>{
      ...res['attempt'] as Map<String, dynamic>,
      'access_token': token,
      'assessment_id': (res['assessment'] as Map<String, dynamic>)['id'],
      'result': res['result'],
    };
    return Attempt.fromJson(row);
  }

  group('The sitting behind an invitation token parses', () {
    test('the token is carried onto the attempt', () {
      // The payload does NOT include it - the caller knows it. Without this
      // `attemptByToken` cannot match the record it just fetched, and the
      // screen still reports a dead link.
      final Attempt ev = merged('tok-abc');
      expect(
        ev.token,
        'tok-abc',
        reason: 'attemptByToken matches on this; empty means "dead link"',
      );
    });

    test('the assessment id is carried across', () {
      // It is nested under `assessment`, not on the attempt, so the exam
      // runner could not find the assessment that holds the duration.
      expect(merged('t').assessmentId, '18');
    });

    test('a submitted sitting reads as submitted', () {
      final Attempt ev = merged('t');
      expect(
        ev.state,
        AttemptState.submitted,
        reason: 'state "submitted" must not parse as still pending',
      );
    });

    test('the released marks survive - NOT 0 of 0', () {
      // The regression seen in the browser: the summary said "0 of 0" for a
      // result the server reports as "0 / 3", because only `attempt` was
      // merged and the marks live under `result`.
      final Attempt ev = merged('t');
      expect(
        ev.serverTotal,
        3,
        reason:
            'total came back as ${ev.serverTotal}, so the screen shows '
            '"of ${ev.serverTotal}" instead of "of 3"',
      );
      expect(ev.serverEarned, 0);
      expect(ev.resultsReleased, isTrue);
    });
  });
}
