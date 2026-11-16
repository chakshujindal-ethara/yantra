// The attempts cache MERGES a list page onto what a detail route hydrated.
//
// THE BUG: `_loadAttempts()` ended `attempts = flat;` - a wholesale replace
// with rows from `/api/v1/attempts`, which is `S.evaluator_admin_row` and
// carries no `answers` and no `token`. Every neighbouring cache in
// `_loadAdmin` had already been given a `_merge*` for exactly this hazard
// (`_mergeAssessments`, `_mergeQuestions`, `_mergeGenerators`); attempts was
// the one left replacing.
//
// It only started to bite once `Attempt.fromJson` learned to read the detail
// route's `answers` list, because before that `resp` was empty either way. The
// symptom: open an attempt, press Re-score or Erase, and `_act`'s trailing
// `refresh(background: true)` empties "Score details" to "This candidate has
// not answered anything yet." underneath a header still reading 10 / 10.
// `pollGeneration` re-ran the same wipe every two seconds during a generation.
//
// The payloads below are the module's own shapes - `S.response_audit`,
// `S.evaluator_admin_row` and `S.assessment_detail` in
// `controllers/api/serializers.py`.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// One `response_audit` row, trimmed to the keys the join needs.
Map<String, dynamic> audit(int questionId) => <String, dynamic>{
  'id': questionId * 10,
  'evaluator_id': 4,
  'question_id': questionId,
  'question_name': 'Q$questionId',
  'question_type': 'subjective_rubric',
  'state': 'submitted',
  'score': 1,
  'max_score': 1,
  'llm_state': 'scored',
  'llm_raw_100': 82.0,
};

/// `evaluator_admin_row` - the LIST shape. No `answers`, and no `token`: the
/// exam link rides only on a detail route, and only for a Manager.
Map<String, dynamic> get listRow => <String, dynamic>{
  'id': 4,
  'assessment_id': 18,
  'candidate': <String, dynamic>{'id': '2', 'name': 'Anita Rao'},
  'state': 'submitted',
  'answered_count': 2,
  'total_questions': 2,
};

/// The same attempt from `/api/v1/attempts/<id>`: the list row plus the two
/// things only this route carries.
Map<String, dynamic> get detailRow => <String, dynamic>{
  ...listRow,
  'access_token': 'tok-abc',
  'answers': <dynamic>[audit(11), audit(12)],
};

Map<String, dynamic> payloadFor(String path) {
  if (path.endsWith('/attempts')) {
    return <String, dynamic>{};
  }
  if (path.contains('/attempts/')) return detailRow;
  if (path.contains('/assessments/')) {
    return <String, dynamic>{
      'id': 18,
      'name': 'Forklift Safety',
      'state': 'done',
      'questions': <dynamic>[
        <String, dynamic>{'id': 11, 'name': 'Q11'},
        <String, dynamic>{'id': 12, 'name': 'Q12'},
      ],
    };
  }
  return <String, dynamic>{};
}

/// The same list row AFTER an Erase: `answers` is PRESENT and empty.
///
/// The key is the signal, so this is the payload that must be allowed to blank
/// the cache - the other side of the merge from [listRow], which omits the key
/// entirely and therefore must not.
Map<String, dynamic> get erasedListRow => <String, dynamic>{
  ...listRow,
  'answers': <dynamic>[],
};

/// A store whose every list route answers with one page, and whose
/// `/api/v1/attempts` page is the thin `evaluator_admin_row` above.
///
/// [erased] switches that page to [erasedListRow], which is what the server
/// sends once an operator has erased the attempt's answers.
AppStore store({bool Function()? erased}) => AppStore(
  api: ApiClient(
    client: MockClient((http.Request req) async {
      final String path = req.url.path;
      final Object body = path.endsWith('/attempts')
          ? <dynamic>[(erased?.call() ?? false) ? erasedListRow : listRow]
          : (path.endsWith('/assessments')
                ? <dynamic>[payloadFor('/assessments/18')]
                : payloadFor(path));
      return http.Response(
        jsonEncode(<String, dynamic>{'ok': true, 'data': body}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }),
    baseUrl: 'http://x',
  ),
);

void main() {
  test('a background refresh does not erase the answers a detail fetch put '
      'on the attempt', () async {
    final AppStore s = store();

    await s.loadAttempt('4');
    expect(
      s.attemptById('4')!.resp.keys.toList()..sort(),
      <String>['11', '12'],
      reason: 'the detail route sends both answers under `answers`',
    );

    // Exactly what `_act` runs after Re-score, Erase, Release and every other
    // attempt-scoped mutation - and what `pollGeneration` runs every 2s.
    await s.refresh(background: true);

    expect(
      s.attemptById('4')!.resp.keys.toList()..sort(),
      <String>['11', '12'],
      reason: 'the list row carries no `answers`, so it must not overwrite them',
    );
  });

  test('the exam link survives the same refresh', () async {
    final AppStore s = store();

    await s.loadAttempt('4');
    expect(s.attemptById('4')!.token, 'tok-abc');

    await s.refresh(background: true);

    // A Manager copies this link when an invitation does not arrive. Wiped, the
    // button greys out on a screen that had just shown it.
    expect(s.attemptById('4')!.token, 'tok-abc');
  });

  // THE OTHER HALF OF THE MERGE, and the half a "keep whatever is longer"
  // implementation gets wrong. Erase is a real operator action: the answers are
  // SUPPOSED to go. `_mergeAttempts` keys on the PRESENCE of `answers` in the
  // incoming row, not on whether it is non-empty, so a row that sends
  // `answers: []` blanks the cache and a row that omits the key does not.
  //
  // Preservation baseline for task 10's roster cache: the roster gets its own
  // store slot precisely so it can never be the thing that empties this one.
  test('an ERASED attempt is allowed to go back to empty', () async {
    bool erased = false;
    final AppStore s = store(erased: () => erased);

    await s.loadAttempt('4');
    expect(s.attemptById('4')!.resp.keys.length, 2);

    // What the console sees after Erase: `_act` runs a background refresh and
    // the list row now carries an empty `answers`.
    erased = true;
    await s.refresh(background: true);

    expect(
      s.attemptById('4')!.resp,
      isEmpty,
      reason: 'the key is the signal, never the value - an operator who erased '
          'the answers must not keep seeing them restored from the cache',
    );
  });

  test('a list row still WINS on the fields it does carry', () async {
    final AppStore s = store();
    await s.loadAttempt('4');
    await s.refresh(background: true);

    final Attempt ev = s.attemptById('4')!;
    // Merging must not freeze the record: the whole point of the refresh is
    // that state, counts and flags track the server.
    expect(ev.state, AttemptState.submitted);
    expect(ev.serverAnswered, 2);
    expect(ev.employeeId, '2');
  });
}
