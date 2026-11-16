// Re-scoring an answer the candidate has already been shown is asked about
// first.
//
// Every other re-score moves a number nobody outside this console has seen.
// Once results are released the candidate holds the mark, so a re-grade can
// change what they were told - silently, with no notification - and it spends a
// model call whether or not the new grade differs. The bulk requeue route has
// demanded `force: true` for exactly this act since it shipped; the per-answer
// path asked nothing at all, on three screens.
//
// The confirmation is NOT offered on an unreleased attempt: a dialog people
// dismiss by reflex protects nothing, and re-scoring before release is the
// ordinary act this console is built around.
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
import 'package:ethara_assessment/assessment/widgets/buttons.dart';

class _Spy {
  final List<String> paths = <String>[];
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];
  final Map<String, Map<String, dynamic>> canned =
      <String, Map<String, dynamic>>{};

  http.Client get client => MockClient((http.Request req) async {
    paths.add(req.url.path);
    try {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
    } on FormatException {
      bodies.add(<String, dynamic>{});
    }
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

  /// The body of the one re-score request, or null if none was sent.
  Map<String, dynamic>? get rescore {
    for (int i = 0; i < paths.length; i++) {
      if (paths[i].endsWith('/rescore')) return bodies[i];
    }
    return null;
  }
}

Map<String, dynamic> _answer(int qid, {String state = 'scored'}) =>
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

Map<String, dynamic> _ashaJson({required bool released}) => <String, dynamic>{
  'id': 90,
  'assessment_id': 7,
  'candidate': <String, dynamic>{'id': 'p90', 'name': 'Asha'},
  'state': 'submitted',
  'results_released': released,
  'answers': <dynamic>[_answer(205)],
};

AppStore _live(_Spy spy, {required bool released}) {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: spy.client),
  );
  s.caps = Capability.values.toSet();
  s.people = <Person>[const Person(id: 'p90', name: 'Asha', email: 'a@x.io')];
  s.assessments = <Assessment>[_paper()];
  s.attempts = <Attempt>[Attempt.fromJson(_ashaJson(released: released))];
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

Future<void> _drain(WidgetTester t) async {
  await t.pump(const Duration(seconds: 25));
  await t.pumpWidget(const SizedBox.shrink());
}

/// The answer page for Asha's Q205 on a released or unreleased attempt.
Future<_Spy> _answerPage(WidgetTester t, {required bool released}) async {
  final _Spy spy = _Spy()
    ..canned['/responses/90/205'] = _answer(205)
    ..canned['/attempts/90/rescore'] = <String, dynamic>{'queued': 1};
  await _mount(
    t,
    ResponseDetailScreen(
      store: _live(spy, released: released),
      attemptId: '90',
      questionId: '205',
    ),
  );
  return spy;
}

void main() {
  testWidgets('a released answer asks before it spends', (
    WidgetTester t,
  ) async {
    final _Spy spy = await _answerPage(t, released: true);

    await t.tap(find.widgetWithText(Btn, 'Re-score'));
    await t.pumpAndSettle();

    expect(
      spy.rescore,
      isNull,
      reason: 'nothing may reach the route before the operator confirms',
    );
    expect(
      find.textContaining('released'),
      findsWidgets,
      reason: 'the sheet must name why this re-score is different',
    );
    expect(
      find.textContaining('model call'),
      findsOneWidget,
      reason: 'and that it costs money whether or not the mark moves',
    );

    await t.tap(find.widgetWithText(Btn, 'Re-score Anyway'));
    await t.pumpAndSettle();

    expect(spy.rescore, <String, dynamic>{
      'question_ids': <int>[205],
      // The server's own gate: without it the per-answer route answers 409
      // `released_confirm_required`, as the bulk requeue route does without
      // `force`.
      'confirm': true,
    });
    await _drain(t);
  });

  testWidgets('backing out spends nothing', (WidgetTester t) async {
    final _Spy spy = await _answerPage(t, released: true);

    await t.tap(find.widgetWithText(Btn, 'Re-score'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(Btn, 'Keep the Mark'));
    await t.pumpAndSettle();

    expect(spy.rescore, isNull);
    await _drain(t);
  });

  testWidgets('an unreleased answer is re-scored on the press', (
    WidgetTester t,
  ) async {
    final _Spy spy = await _answerPage(t, released: false);

    await t.tap(find.widgetWithText(Btn, 'Re-score'));
    await t.pumpAndSettle();

    expect(
      spy.rescore,
      <String, dynamic>{
        'question_ids': <int>[205],
      },
      reason:
          'no confirmation and no flag: the candidate has seen nothing yet, '
          'and a confirm on every re-score is one people learn to dismiss',
    );
    await _drain(t);
  });

  testWidgets('the candidate page asks for the same reason', (
    WidgetTester t,
  ) async {
    // One unresolved answer, so the bulk button is on the page.
    final Map<String, dynamic> held = <String, dynamic>{
      ..._ashaJson(released: true),
      'answers': <dynamic>[_answer(205, state: 'failed')],
    };
    final _Spy spy = _Spy()
      ..canned['/attempts/90'] = held
      ..canned['/attempts/90/rescore'] = <String, dynamic>{'queued': 1};
    final AppStore s = _live(spy, released: true);
    s.attempts = <Attempt>[Attempt.fromJson(held)];
    await _mount(
      t,
      AttemptDetailScreen(store: s, portal: Portal.admin, attemptId: '90'),
    );

    await t.tap(find.widgetWithText(Btn, 'Re-score 1 answer(s)'));
    await t.pumpAndSettle();

    expect(spy.rescore, isNull);
    expect(find.widgetWithText(Btn, 'Re-score Anyway'), findsOneWidget);
    await t.tap(find.widgetWithText(Btn, 'Re-score Anyway'));
    await t.pumpAndSettle();

    expect(spy.rescore?['confirm'], isTrue);
    await _drain(t);
  });
}
