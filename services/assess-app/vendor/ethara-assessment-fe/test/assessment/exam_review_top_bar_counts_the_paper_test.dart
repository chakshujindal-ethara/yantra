// The pre-submit review's top bar counts the SAME questions the panel does.
//
// THE BUG THIS EXISTS FOR, on the last screen a candidate sees before
// submitting. The review stage's top bar read "0 of 0 questions answered" and
// drew an empty progress bar, while the panel three lines below correctly said
// "0 of 9 answered" off the same data. Two denominators for one fact, on the
// screen where a candidate decides whether they are done.
//
// The cause: `_buildChrome` falls back to `asm.questions.length` for its total,
// and that list is EMPTY on a live exam - the payload has never carried a
// question list, the server hands questions out one at a time. The review
// stage was omitting its own total, so the bar fell to that empty fallback and
// read zero. It now passes `total: reviewTotal`, read from the SAME source
// `_Review` builds its rows from (`examReviewByToken`), so the two cannot drift
// apart again.
//
// This pins the top bar's total, not the panel's - the panel was already right,
// and the whole point is that the bar now agrees with it.
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
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

const String kToken = '65a12c11-fb40-48b5-af51-3f3c6822b65f';

/// The review checklist as `/exam/<token>/review` sends it: NINE rows, none
/// answered. Nine is the count the panel reads and the bar must match.
Map<String, dynamic> _reviewPayload() => <String, dynamic>{
  'rows': <Map<String, dynamic>>[
    for (int i = 1; i <= 9; i++)
      <String, dynamic>{
        'index': i,
        'question_id': 100 + i,
        'name': 'Question $i',
        'answered': false,
      },
  ],
  'answered_count': 0,
  'total_questions': 9,
  'unanswered': <int>[for (int i = 1; i <= 9; i++) 100 + i],
};

http.Client _server() => MockClient((http.Request req) async {
  final Map<String, dynamic> data = req.url.path.endsWith('/review')
      ? _reviewPayload()
      : <String, dynamic>{};
  return http.Response(
    jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

/// A candidate mid-exam, on a LIVE paper whose assessment carries no question
/// list - which is every real exam, and the precondition for the fallback that
/// read zero.
AppStore _runnerStore() {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: _server(), bearer: 'tok'),
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': 7,
      'access_token': kToken,
      'assessment_id': 21,
      'state': 'in_progress',
      'started_at': '2026-08-11T10:00:00Z',
      'total_questions': 9,
    }),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 21,
      'name': 'sample test',
      'state': 'in_progress',
      'duration_minutes': 45,
    }),
  ];
  return s;
}

Widget _mount(AppStore s, AssessmentNav nav) => MaterialApp(
  theme: ThemeData.dark(),
  home: AssessmentNavScope(
    nav: nav,
    child: ExamScreen(
      store: s,
      token: kToken,
      sub: ExamSub.review,
      questionNumber: 1,
    ),
  ),
);

Future<void> _settle(WidgetTester t) async {
  await t.pumpAndSettle();
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 40)),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('the review top bar reads 0 of 9, not 0 of 0', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final AppStore s = _runnerStore();
    // `asm.questions` is the empty list the bug's fallback read - guard that
    // the fixture really reproduces the precondition, or the test would pass
    // for the wrong reason.
    expect(s.asmById('21')!.questions, isEmpty);

    await s.loadExamReview(kToken);
    expect(
      s.examReviewByToken[kToken]?.length,
      9,
      reason: 'the review rows are the source the fixed total reads from',
    );

    await t.pumpWidget(_mount(s, AssessmentNav()));
    await _settle(t);

    // ExamTopBar's progress node carries `value: '$answered of $total'`. On a
    // live exam that total came from asm.questions.length (0); it must now be
    // the review row count (9).
    expect(
      find.bySemanticsLabel('0 of 9 questions answered'),
      findsOneWidget,
      reason:
          'the bar fell back to the empty question list and read "0 of 0" '
          'while the panel below correctly read "0 of 9"',
    );
    expect(
      find.bySemanticsLabel('0 of 0 questions answered'),
      findsNothing,
      reason: 'this is the exact string the top bar showed before the fix',
    );
  });
}
