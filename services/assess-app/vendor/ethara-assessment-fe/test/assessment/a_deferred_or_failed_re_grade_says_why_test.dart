// The grader writes down WHY it stopped, and an admin gets to read it.
//
// Two things put a sentence on `evaluator.llm_error`, and both of them are the
// admin's business:
//
//   * a queued re-score of an already-scored answer that FAILED - the old mark
//     stands, the request is dropped, and the reason goes on the candidate
//     ("Re-score of Q205 failed, its previous mark was kept: no score");
//   * a call DEFERRED before it was made, for a spend cap or a 429 - no attempt
//     was used and the answers stay pending ("Waiting to be graded, no attempt
//     used: daily budget reached").
//
// The server has sent it as `subjective.error` all along. Nothing parsed it and
// no screen drew it, so both cases presented as a silent Pending - a queue
// waiting on money looked exactly like a broken one, and a failed re-grade
// looked like the re-grade confirming the mark.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/response_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

const String kCapped = 'Waiting to be graded, no attempt used: the daily '
    'budget of \$400 has been reached';
const String kFailed = 'Re-score of Q205 failed, its previous mark was kept: '
    'no score';

class _Spy {
  final Map<String, Map<String, dynamic>> canned =
      <String, Map<String, dynamic>>{};

  http.Client get client => MockClient((http.Request req) async {
    Map<String, dynamic> data = const <String, dynamic>{};
    for (final MapEntry<String, Map<String, dynamic>> e in canned.entries) {
      if (req.url.path.endsWith(e.key)) data = e.value;
    }
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
}

Map<String, dynamic> _answer(int qid, {required String state}) =>
    <String, dynamic>{
      'id': 90000 + qid,
      'evaluator_id': 90,
      'assessment_id': 7,
      'question_id': qid,
      'question_name': 'Q$qid',
      'question_type': 'subjective_rubric',
      'candidate': <String, dynamic>{'id': 'p90', 'name': 'Asha'},
      'state': 'submitted',
      'needs_llm': true,
      'llm_state': state,
    };

Assessment _paper() => Assessment.fromJson(<String, dynamic>{
  'id': '7',
  'name': 'Warehouse Safety',
  'state': 'in_progress',
  'questions': <dynamic>[
    <String, dynamic>{
      'id': 205,
      'name': 'Q205',
      'question_type': 'subjective_rubric',
    },
  ],
});

/// Asha's attempt, carrying whatever the grader last wrote on the candidate.
Map<String, dynamic> _ashaJson(String error) => <String, dynamic>{
  'id': 90,
  'assessment_id': 7,
  'candidate': <String, dynamic>{'id': 'p90', 'name': 'Asha'},
  'state': 'submitted',
  'subjective': <String, dynamic>{
    'score': 0,
    'max': 1,
    'pending': 1,
    'state': 'pending',
    'error': error,
  },
  'answers': <dynamic>[_answer(205, state: 'pending')],
};

AppStore _live(_Spy spy, String error) {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: spy.client),
  );
  s.caps = Capability.values.toSet();
  s.people = <Person>[const Person(id: 'p90', name: 'Asha', email: 'a@x.io')];
  s.assessments = <Assessment>[_paper()];
  s.attempts = <Attempt>[Attempt.fromJson(_ashaJson(error))];
  return s;
}

Future<void> _mount(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1800, 4000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.light(),
      home: Scaffold(
        body: AssessmentNavScope(nav: AssessmentNav(), child: child),
      ),
    ),
  );
  await t.pump();
  await t.pump();
}

/// Lets every toast and watch expire, so no timer outlives the test.
Future<void> _drain(WidgetTester t) async {
  await t.pump(const Duration(seconds: 25));
  await t.pumpWidget(const SizedBox.shrink());
}

void main() {
  test('the parser keeps the reason the server sent', () {
    // `subjective.error` was the one key in that object nothing read.
    expect(Attempt.fromJson(_ashaJson(kCapped)).subjectiveError, kCapped);
    expect(Attempt.fromJson(_ashaJson('')).subjectiveError, '');
  });

  testWidgets('the candidate page says the queue is waiting on money', (
    WidgetTester t,
  ) async {
    final _Spy spy = _Spy()..canned['/attempts/90'] = _ashaJson(kCapped);
    await _mount(
      t,
      AttemptDetailScreen(
        store: _live(spy, kCapped),
        portal: Portal.admin,
        attemptId: '90',
      ),
    );

    expect(
      find.textContaining(kCapped),
      findsOneWidget,
      reason:
          'a queue held by the spend cap must not present as a silent Pending',
    );
    await _drain(t);
  });

  testWidgets('the candidate page says a re-score failed and kept the mark', (
    WidgetTester t,
  ) async {
    final _Spy spy = _Spy()..canned['/attempts/90'] = _ashaJson(kFailed);
    await _mount(
      t,
      AttemptDetailScreen(
        store: _live(spy, kFailed),
        portal: Portal.admin,
        attemptId: '90',
      ),
    );

    expect(
      find.textContaining(kFailed),
      findsOneWidget,
      reason:
          'silence here reads as the re-grade confirming the mark it kept',
    );
    await _drain(t);
  });

  testWidgets('the answer page carries the same reason', (
    WidgetTester t,
  ) async {
    final _Spy spy = _Spy()
      ..canned['/responses/90/205'] = _answer(205, state: 'pending');
    await _mount(
      t,
      ResponseDetailScreen(
        store: _live(spy, kFailed),
        attemptId: '90',
        questionId: '205',
      ),
    );

    expect(
      find.textContaining(kFailed),
      findsOneWidget,
      reason: 'this is the page an admin opens to ask why the mark stood',
    );
    await _drain(t);
  });

  testWidgets('no reason, no notice', (WidgetTester t) async {
    final _Spy spy = _Spy()..canned['/attempts/90'] = _ashaJson('');
    await _mount(
      t,
      AttemptDetailScreen(
        store: _live(spy, ''),
        portal: Portal.admin,
        attemptId: '90',
      ),
    );

    expect(
      find.textContaining('The grader left a reason'),
      findsNothing,
      reason: 'an empty string is the server saying nothing, not a state',
    );
    await _drain(t);
  });
}
