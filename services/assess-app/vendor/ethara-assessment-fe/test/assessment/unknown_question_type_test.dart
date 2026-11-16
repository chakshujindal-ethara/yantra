// A-053: a question type this build does not know is not an MCQ.
//
// `QType.parse` fell back to mcq, so a new server type rendered as a
// multiple-choice question with nothing to pick. It now says plainly that the
// type is not supported, and the candidate can still move on.
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

const String kToken = 'tok-a053';

void main() {
  test('an unknown wire type is not an mcq, and is never authorable', () {
    expect(QType.parse('something_new'), isNot(QType.mcq));
    expect(QType.parse('something_new'), QType.unsupported);
    expect(QType.parse('msq'), QType.msq);
    expect(QType.generatable, isNot(contains(QType.unsupported)));
    expect(QType.known, isNot(contains(QType.unsupported)));
  });

  testWidgets('the exam shows the not-supported panel and Next still moves', (
    WidgetTester t,
  ) async {
    final List<String> calls = <String>[];
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        client: MockClient((http.Request req) async {
          calls.add('${req.url.path} ${req.body}');
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        bearer: 't',
      ),
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
      }),
    ];
    s.examByToken[kToken] = ExamView.fromJson(<String, dynamic>{
      'outcome': 'question',
      'question': <String, dynamic>{
        'id': '10',
        'index': 1,
        'total': 3,
        'name': 'Question 1',
        'prompt': 'Rank these three clips.',
        'question_type': 'something_new',
        'dimensions': <dynamic>[
          <String, dynamic>{
            'code': 'D1',
            'name': 'Order',
            'options': <dynamic>[
              <String, dynamic>{'id': 'o-1', 'label': 'Clip A first'},
            ],
          },
        ],
        'images': <dynamic>[],
        'videos': <dynamic>[],
        'label_boxes': <dynamic>[],
      },
      'answered_question_ids': <dynamic>[],
      'progress_percent': 0,
    });

    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
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

    expect(
      find.textContaining('not supported in this version of the app'),
      findsOneWidget,
    );
    expect(find.textContaining('contact your assessment organiser'), findsOne);
    expect(
      find.text('Clip A first'),
      findsNothing,
      reason: 'no MCQ option to pick that the server would refuse',
    );

    await t.tap(find.text('Next'));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump();
    expect(
      calls.where((String c) => c.contains('/answer')),
      isEmpty,
      reason: 'nothing to save',
    );
    expect(
      calls.where((String c) => c.contains('/state') && c.contains('"q":2')),
      hasLength(1),
      reason: 'the candidate moves on to question 2',
    );
  });
}
