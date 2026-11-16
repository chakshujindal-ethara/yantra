// Leaving the page within the autosave debounce lost what was just typed.
//
// Closing the tab, a reload or browser Back inside the 5s debounce dropped the
// pending save: nothing flushed on the page going away. The exam now flushes
// pending answers when the page is hidden (Flutter web reports the page's
// `visibilitychange` as `hidden`). Hiding the page is not a violation here -
// the proctor watch judges a tab-hide on its own.
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

const String kToken = 'tok-hide';

void main() {
  testWidgets('hiding the page sends the pending answer now', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final List<String> posts = <String>[];
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        bearer: 't',
        client: MockClient((http.Request req) async {
          posts.add(req.url.path.split('/').last);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
      // Far longer than the test: only the page-hide flush can send it.
      answerDebounce: const Duration(minutes: 5),
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
        'started_at': DateTime.now().toUtc().toIso8601String(),
        'deadline': DateTime.now()
            .add(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
      }),
    ];
    s.assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': 21,
        'name': 'sample test',
        'state': 'in_progress',
        'duration_minutes': 60,
        'violation_action': 'auto_submit',
        'max_violations': 1,
      }),
    ];
    s.examByToken[kToken] = ExamView.fromJson(<String, dynamic>{
      'outcome': 'question',
      'question': <String, dynamic>{
        'id': '10',
        'index': 1,
        'total': 3,
        'name': 'Question 1',
        'prompt': 'Prompt.',
        'question_type': 'subjective_rubric',
        'dimensions': <dynamic>[],
        'images': <dynamic>[],
        'videos': <dynamic>[],
        'label_boxes': <dynamic>[],
      },
      'answered_question_ids': <dynamic>[],
      'progress_percent': 0,
    });

    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AssessmentNavScope(
          nav: AssessmentNav(),
          child: ExamScreen(store: s, token: kToken, sub: ExamSub.question),
        ),
      ),
    );
    await t.pump();

    s.saveAnswerQuiet('7', '10', Response(justification: 'just typed'));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    expect(posts, isNot(contains('answer')), reason: 'still debounced');

    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    addTearDown(
      () => t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );

    expect(posts, contains('answer'));
    expect(posts, isNot(contains('violation')));
    expect(s.attemptById('7')!.isDone, isFalse);
  });
}
