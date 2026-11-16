// "Re-score queued" clears when the new mark lands, without a reload.
//
// THE BUG. The label is the server's `rescore_requested`, read when the answer
// page loads - and nothing read it again. The scoring watch that notices a run
// ending lives on the assessment page and reloads the ASSESSMENT, so an answer
// page left open kept "Re-score queued" (and the old mark) long after the
// grader had written the new one.
//
// THE FIX, kept cheap: only while the label is shown, the page reads the light
// `/scoring` counters for its paper and re-reads the one answer when they move
// or the run is over.
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
import 'package:ethara_assessment/assessment/screens/admin/response_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';

/// The page's watch interval, as the screen declares it.
const Duration _tick = Duration(seconds: 10);

/// Serves the answer and the paper's scoring counters from fields a test can
/// change between ticks.
class _Server {
  final List<String> paths = <String>[];
  Map<String, dynamic> answer = _answer(queued: true);
  Map<String, dynamic> scoring = <String, dynamic>{
    'phase': 'scoring',
    'summary': '1 queued',
    'queued': 1,
  };

  http.Client get client => MockClient((http.Request req) async {
    paths.add(req.url.path);
    final Map<String, dynamic> data = req.url.path.endsWith('/responses/90/205')
        ? answer
        : req.url.path.endsWith('/scoring')
        ? scoring
        : <String, dynamic>{};
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });

  int hits(String suffix) =>
      paths.where((String p) => p.endsWith(suffix)).length;
}

Map<String, dynamic> _answer({required bool queued}) => <String, dynamic>{
  'id': 90205,
  'evaluator_id': 90,
  'assessment_id': 7,
  'question_id': 205,
  'question_type': 'subjective_rubric',
  'state': 'submitted',
  'needs_llm': true,
  'llm_state': 'scored',
  'rescore_requested': queued,
};

AppStore _live(_Server server) {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: server.client),
  );
  s.caps = Capability.values.toSet();
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
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
    }),
  ];
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': 90,
      'assessment_id': 7,
      'state': 'submitted',
      'answers': <dynamic>[_answer(queued: false)],
    }),
  ];
  return s;
}

Future<void> _mount(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1800, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.light(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: ResponseDetailScreen(
            store: s,
            attemptId: '90',
            questionId: '205',
          ),
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump();
}

bool _shows(String label) =>
    find.widgetWithText(Btn, label).evaluate().isNotEmpty;

void main() {
  testWidgets('the label clears on its own when the run ends', (
    WidgetTester t,
  ) async {
    final _Server server = _Server();
    await _mount(t, _live(server));
    expect(_shows('Re-score queued'), isTrue);
    final int opened = server.hits('/responses/90/205');

    // First read of the counters: they moved (from nothing), so the answer is
    // re-read - still queued.
    await t.pump(_tick);
    await t.pump();
    expect(server.hits('/scoring'), 1);
    expect(server.hits('/responses/90/205'), opened + 1);
    expect(_shows('Re-score queued'), isTrue);

    // The same numbers while the run is busy: the answer is not re-read.
    await t.pump(_tick);
    await t.pump();
    expect(server.hits('/scoring'), 2);
    expect(
      server.hits('/responses/90/205'),
      opened + 1,
      reason: 'cheap: nothing moved, so the answer cannot have changed',
    );

    // The grader writes the new mark and the paper goes idle.
    server
      ..answer = _answer(queued: false)
      ..scoring = <String, dynamic>{'phase': 'idle', 'queued': 0};
    await t.pump(_tick);
    await t.pump();
    expect(_shows('Re-score queued'), isFalse);
    expect(_shows('Re-score'), isTrue);

    // And the watch stops with the label.
    final int reads = server.hits('/scoring');
    await t.pump(_tick * 6);
    expect(server.hits('/scoring'), reads);

    await t.pump(const Duration(seconds: 25));
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('no label, no watch', (WidgetTester t) async {
    final _Server server = _Server()..answer = _answer(queued: false);
    await _mount(t, _live(server));
    expect(_shows('Re-score queued'), isFalse);

    await t.pump(_tick * 6);
    expect(server.hits('/scoring'), 0);

    await t.pump(const Duration(seconds: 25));
    await t.pumpWidget(const SizedBox.shrink());
  });
}
