// "Re-score N answer(s)" only QUEUES now, and the candidate page has to say so.
//
// The route used to grade inside the request, so a page that re-read nothing
// and showed the new mark afterwards was telling the truth. It no longer is:
// the answers are queued for the grading lane, and this page rendered the old
// state with the same enabled button and never re-read - so an operator saw
// nothing move, pressed again, and read stale marks as the result of the
// re-grade.
//
// Three things close it: a per-answer chip saying the re-score is queued, a
// button that will not re-send what is already queued, and a watch that
// re-reads the attempt while anything on it is waiting.
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
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/marks.dart';

class _Spy {
  final List<String> paths = <String>[];
  final Map<String, Map<String, dynamic>> canned =
      <String, Map<String, dynamic>>{};

  int hits(String suffix) =>
      paths.where((String p) => p.endsWith(suffix)).length;

  http.Client get client => MockClient((http.Request req) async {
    paths.add(req.url.path);
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

Map<String, dynamic> _answer(
  int qid, {
  required String state,
  bool queued = false,
}) => <String, dynamic>{
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
  'rescore_requested': queued,
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
    <String, dynamic>{
      'id': 206,
      'name': 'Q206',
      'question_type': 'subjective_rubric',
    },
  ],
});

/// Asha: Q205 scored, Q206 failed. [queued] names the answers already asked
/// for, as the server reports them on a re-read.
Map<String, dynamic> _ashaJson({Set<int> queued = const <int>{}}) =>
    <String, dynamic>{
      'id': 90,
      'assessment_id': 7,
      'candidate': <String, dynamic>{'id': 'p90', 'name': 'Asha'},
      'state': 'submitted',
      'answers': <dynamic>[
        _answer(205, state: 'scored', queued: queued.contains(205)),
        _answer(206, state: 'failed', queued: queued.contains(206)),
      ],
    };

AppStore _live(_Spy spy, {Set<int> queued = const <int>{}}) {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: spy.client),
  );
  s.caps = Capability.values.toSet();
  s.people = <Person>[const Person(id: 'p90', name: 'Asha', email: 'a@x.io')];
  s.assessments = <Assessment>[_paper()];
  s.attempts = <Attempt>[Attempt.fromJson(_ashaJson(queued: queued))];
  return s;
}

Future<void> _open(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1800, 4000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.light(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: AttemptDetailScreen(
            store: s,
            portal: Portal.admin,
            attemptId: '90',
          ),
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump();
}

Future<void> _drain(WidgetTester t) async {
  await t.pump(const Duration(seconds: 25));
  await t.pumpWidget(const SizedBox.shrink());
}

void main() {
  testWidgets('a queued answer wears a chip saying so', (
    WidgetTester t,
  ) async {
    final _Spy spy = _Spy()
      ..canned['/attempts/90'] = _ashaJson(queued: <int>{206});
    await _open(t, _live(spy, queued: <int>{206}));

    expect(
      find.widgetWithText(Pill, 'Re-score queued'),
      findsOneWidget,
      reason:
          'the marking table showed only the OLD llm_state, so a queued '
          'answer was indistinguishable from one nobody had touched',
    );
    await _drain(t);
  });

  testWidgets('the button will not re-send what is already queued', (
    WidgetTester t,
  ) async {
    final _Spy spy = _Spy()
      ..canned['/attempts/90'] = _ashaJson(queued: <int>{206});
    await _open(t, _live(spy, queued: <int>{206}));

    expect(
      find.widgetWithText(Btn, 'Re-score 1 answer(s)'),
      findsNothing,
      reason: 'Q206 is the only unresolved answer and it is already queued',
    );
    final Finder queued = find.widgetWithText(Btn, 'Re-score queued');
    expect(queued, findsOneWidget);
    expect(
      t.widget<Btn>(queued).onPressed,
      isNull,
      reason: 'a second press would only join the request already queued',
    );
    await _drain(t);
  });

  testWidgets('an answer NOT yet queued is still offered', (
    WidgetTester t,
  ) async {
    // Q205 was asked for from the answer page; Q206 is still unresolved and
    // unasked. Disabling the whole button here would strand it.
    final _Spy spy = _Spy()
      ..canned['/attempts/90'] = _ashaJson(queued: <int>{205});
    await _open(t, _live(spy, queued: <int>{205}));

    expect(find.widgetWithText(Btn, 'Re-score 1 answer(s)'), findsOneWidget);
    await _drain(t);
  });

  testWidgets('the page re-reads itself while a re-score is queued', (
    WidgetTester t,
  ) async {
    final _Spy spy = _Spy()
      ..canned['/attempts/90'] = _ashaJson(queued: <int>{206});
    await _open(t, _live(spy, queued: <int>{206}));

    final int afterOpen = spy.hits('/attempts/90');
    await t.pump(const Duration(seconds: 11));
    await t.pump();

    expect(
      spy.hits('/attempts/90'),
      greaterThan(afterOpen),
      reason:
          'nothing re-read the attempt when the grade landed, so the page '
          'held stale marks until somebody reloaded by hand',
    );
    await _drain(t);
  });

  testWidgets('and stops once nothing is queued', (WidgetTester t) async {
    final _Spy spy = _Spy()..canned['/attempts/90'] = _ashaJson();
    await _open(t, _live(spy));

    final int afterOpen = spy.hits('/attempts/90');
    await t.pump(const Duration(seconds: 60));
    await t.pump();

    expect(
      spy.hits('/attempts/90'),
      afterOpen,
      reason: 'a candidate page with nothing waiting must not poll',
    );
    await _drain(t);
  });
}
