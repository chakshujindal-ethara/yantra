// A-068: resuming an exam shows the answer the server already holds.
//
// `loadExamByToken` adopted the question's `answer` block BEFORE it put the
// attempt row in place. Cold (invitation link, reload) there was no attempt to
// seed; warm (opened from "My assessments") the seed was then overwritten by
// the fresh row. Either way the landing question opened blank.
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

const String kToken = 'tok-a068';
const String kSaved = 'Chock the wheels, lower the forks, key out.';

Map<String, dynamic> _attempt() => <String, dynamic>{
  'id': 7,
  'state': 'in_progress',
  'is_locked': false,
  'started_at': DateTime.now().toUtc().toIso8601String(),
  'deadline': DateTime.now()
      .add(const Duration(hours: 1))
      .toUtc()
      .toIso8601String(),
  'total_questions': 3,
};

AppStore _store() {
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      client: MockClient(
        (http.Request req) async => http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{
              'outcome': 'question',
              'assessment': <String, dynamic>{
                'id': 21,
                'name': 'Forklift Safety',
                'state': 'in_progress',
                'duration_minutes': 60,
              },
              'attempt': _attempt(),
              'question': <String, dynamic>{
                'id': 10,
                'index': 1,
                'total': 3,
                'name': 'End of shift',
                'prompt': 'Describe how the forklift is left.',
                'question_type': 'subjective_rubric',
                'dimensions': <dynamic>[],
                'images': <dynamic>[],
                'videos': <dynamic>[],
                'label_boxes': <dynamic>[],
                'answer': <String, dynamic>{
                  'answered': true,
                  'selected_option_ids': <dynamic>[],
                  'justification': kSaved,
                  'label_answers': <String, dynamic>{},
                },
              },
            },
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      ),
      bearer: 't',
    ),
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  return s;
}

void main() {
  testWidgets('a cold resume opens the landing question with its answer', (
    WidgetTester t,
  ) async {
    final AppStore s = _store();
    expect(s.attemptByToken(kToken), isNull, reason: 'nothing loaded yet');

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
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await t.pump();
    await t.pump();

    expect(find.text('Describe how the forklift is left.'), findsOneWidget);
    expect(
      t.widget<EditableText>(find.byType(EditableText).first).controller.text,
      kSaved,
    );
  });

  test('a warm resume keeps the answer too', () async {
    final AppStore s = _store();
    // As "My assessments" leaves it: the row is cached, its answers are not.
    s.attempts = <Attempt>[
      Attempt.fromJson(<String, dynamic>{
        ..._attempt(),
        'access_token': kToken,
        'assessment_id': 21,
      }),
    ];

    await s.loadExamByToken(kToken);

    expect(s.attemptByToken(kToken)!.resp['10']?.justification, kSaved);
  });
}
