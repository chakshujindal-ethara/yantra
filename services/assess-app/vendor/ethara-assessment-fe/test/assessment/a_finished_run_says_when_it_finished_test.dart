// The last finished grading result, and when:
// "Scored 630/630 candidates on Sep 21, 2026 at 10:04pm", above the scoring
// banners - and while a new run grades, the tally from before it.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// Every call answers an empty envelope: the record under test is the one
/// seeded, and the detail reload must not wipe what it does not re-send.
http.Client _quiet() => MockClient(
  (http.Request req) async => http.Response(
    jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  ),
);

/// The record as `assessment_row` sends it, snake_case keys and all.
Assessment _paper({
  required String phase,
  int scored = 630,
  int candidates = 630,
  String? finishedAt = '2026-09-21T16:34:00Z',
}) => Assessment.fromJson(<String, dynamic>{
  'id': 'A-1',
  'name': 'Q7r + Grade & Fix Quality Sprint #3',
  'state': 'done',
  'active': true,
  'scoring_phase': phase,
  'scoring_summary': phase == 'queued' ? '352 queued  ·  278 scored' : '',
  'scoring_scored': scored,
  'scoring_candidates': candidates,
  'scoring_finished_at': finishedAt,
});

Future<void> _open(WidgetTester t, Assessment asm) async {
  t.view.physicalSize = const Size(1600, 2600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: _quiet()),
  )..assessments = <Assessment>[asm];
  s.accessRole = AccessRole.admin;
  s.caps = Capability.values.toSet();
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
            tab: 'config',
          ),
        ),
      ),
    ),
  );
  await t.pump();
  addTearDown(() async => t.pumpWidget(const SizedBox.shrink()));
}

void main() {
  testWidgets('a finished run says how many and when, in IST', (
    WidgetTester t,
  ) async {
    await _open(t, _paper(phase: 'idle'));
    expect(
      find.textContaining('Scored 630/630 candidates on Sep 21, 2026 at 10:04pm IST'),
      findsOneWidget,
    );
  });

  testWidgets('a run in flight keeps the last finished tally beside it', (
    WidgetTester t,
  ) async {
    // 400 of 650 graded, then Score All for the rest: the server sends the
    // tally saved when that run started, and the line keeps it.
    await _open(t, _paper(phase: 'queued', scored: 400, candidates: 650));
    expect(
      find.textContaining('Scored 400/650 candidates on Sep 21, 2026 at 10:04pm IST'),
      findsOneWidget,
    );
    expect(find.textContaining('Queued.'), findsOneWidget);
  });

  testWidgets('a paper nobody has graded says nothing', (WidgetTester t) async {
    await _open(t, _paper(phase: 'idle', scored: 0, finishedAt: null));
    expect(find.textContaining('Scored 0/'), findsNothing);
  });
}
