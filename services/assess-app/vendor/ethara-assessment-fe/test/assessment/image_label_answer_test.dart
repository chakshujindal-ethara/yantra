// Answering an image-labelling question, end to end on the client.
//
// The app has always rendered these: `_ImageLabelLayout` builds one input per
// entry in `label_boxes`, prefills from the stored answer and pages at eight.
// What was never proven is that what the candidate types LEAVES the client in
// the shape the route reads.
//
// `_collect_label_answers` (candidate.py:596) reads ONE key, `label_answers`,
// and requires an object keyed by box number:
//
//     raw = arg("label_answers")
//     if not isinstance(raw, dict): return {}
//
// and `_record_response` then stores it as JSON in the shared `justification`
// column, so a labelling question with no labels is an EMPTY justification and
// the subjective guard at candidate.py:660 refuses it as incomplete.
//
// The backend harness `tools/e2e_exam.py` was sending `label_1`, `label_2`
// scalars instead, against a `label_slots` field the module does not have. So
// every labelling question 422'd there and this type had never once been
// exercised end to end. These tests pin the client half.
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

final List<Map<String, dynamic>> answerBodies = <Map<String, dynamic>>[];

/// A real `image_label` question as `/exam/<token>/state` sends one. The box
/// numbers are the seven the live database actually holds for question 14.
Map<String, dynamic> _labelQuestion() => <String, dynamic>{
  'id': '14',
  'index': 1,
  'total': 1,
  'name': 'Label the scene',
  'prompt': 'Name every marked region.',
  'question_type': 'image_label',
  'dimensions': <dynamic>[],
  'images': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': '1',
      'slot': 'single',
      // A real 1x1 PNG. A malformed one throws in the image codec and buries
      // the assertion this test is actually about.
      'data':
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
          'AAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      'label': 'Scene',
    },
  ],
  'videos': <dynamic>[],
  'label_boxes': <int>[1, 2, 3, 4, 5, 6, 7],
  'answer': <String, dynamic>{
    'answered': false,
    'selected_option_ids': <dynamic>[],
    'justification': '',
    'label_answers': <String, dynamic>{},
  },
};

Map<String, dynamic> _envelope() => <String, dynamic>{
  'outcome': 'question',
  'assessment': <String, dynamic>{
    'id': 21,
    'name': 'sample test',
    'state': 'in_progress',
    'duration_minutes': 45,
  },
  'attempt': <String, dynamic>{
    'id': 7,
    'state': 'in_progress',
    'is_locked': false,
    'started_at': '2026-08-11T10:00:00Z',
    'total_questions': 1,
    'answered_count': 0,
    'results_released': false,
  },
  'question': _labelQuestion(),
  'answered_question_ids': <dynamic>[],
  'progress_percent': 0,
};

http.Client _server() => MockClient((http.Request req) async {
  final Map<String, dynamic> raw = req.body.isEmpty
      ? <String, dynamic>{}
      : jsonDecode(req.body) as Map<String, dynamic>;
  final Object? params = raw['params'];
  final Map<String, dynamic> body = params is Map<String, dynamic>
      ? params
      : raw;

  if (req.url.path.endsWith('/answer')) {
    answerBodies.add(body);
    // The server's own rule: labels become the justification, and an empty
    // justification on a labelling question is refused.
    final Object? labels = body['label_answers'];
    final bool any =
        labels is Map<String, dynamic> &&
        labels.values.any((Object? v) => '${v ?? ''}'.trim().isNotEmpty);
    if (!any) {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'incomplete_answer',
            'message': 'This answer is incomplete for its question type',
          },
        }),
        422,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    return http.Response(
      jsonEncode(<String, dynamic>{
        'ok': true,
        'data': <String, dynamic>{'saved': true, 'next': null, 'review': null},
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
  return http.Response(
    jsonEncode(<String, dynamic>{'ok': true, 'data': _envelope()}),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

AppStore labelStore() {
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
      'total_questions': 1,
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
  s.examByToken[kToken] = ExamView.fromJson(_envelope());
  return s;
}

void main() {
  setUp(answerBodies.clear);

  test('the question parses its box numbers off label_boxes', () {
    final Question q = Question.fromJson(_labelQuestion());
    expect(q.type, QType.imageLabel);
    expect(
      q.labelBoxes,
      <int>[1, 2, 3, 4, 5, 6, 7],
      reason: 'no boxes means no inputs, and a plate nobody can label',
    );
  });

  testWidgets('one input per box, and typing leaves as label_answers', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1500, 2600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final AppStore s = labelStore();
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AssessmentNavScope(
          nav: AssessmentNav(),
          child: ExamScreen(
            store: s,
            token: kToken,
            sub: ExamSub.question,
            questionNumber: 1,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    // Seven boxes, paged at eight, so all seven inputs are on one page.
    expect(
      find.byType(TextField),
      findsNWidgets(7),
      reason: 'one input per marked region',
    );

    await t.enterText(find.byType(TextField).at(0), 'sign');
    await t.pump();
    await t.enterText(find.byType(TextField).at(2), 'cup');
    await t.pump();

    // The store holds them keyed by BOX NUMBER, 1-based.
    final Response r = s.responseFor(
      s.attemptByToken(kToken)!,
      Question.fromJson(_labelQuestion()),
    );
    expect(r.labels?[1], 'sign');
    expect(r.labels?[3], 'cup');
    expect(r.hasInput, isTrue, reason: 'labels alone make this answered');

    // And the wire shape the route actually reads.
    await t.tap(find.text('Review & Submit'));
    await t.pumpAndSettle();
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pumpAndSettle();

    expect(answerBodies, isNotEmpty, reason: 'the labels must be sent');
    final Object? sent = answerBodies.last['label_answers'];
    expect(
      sent,
      isA<Map<String, dynamic>>(),
      reason:
          'candidate.py rejects anything that is not a dict, and the old '
          'harness sent label_1/label_2 scalars instead',
    );
    expect((sent! as Map<String, dynamic>)['1'], 'sign');
    expect((sent as Map<String, dynamic>)['3'], 'cup');
  });

  test('a labelling question with no labels counts as unanswered', () {
    // The labels map exists from `Response.seed` the moment the question is
    // opened, so its PRESENCE cannot mean answered - only a non-empty value.
    final Response seeded = Response.seed(Question.fromJson(_labelQuestion()));
    expect(seeded.labels, isNotNull);
    expect(seeded.hasInput, isFalse);

    const Response blanked = Response(labels: <int, String>{1: '   '});
    expect(
      blanked.hasInput,
      isFalse,
      reason: 'whitespace is what the server strips before deciding',
    );
  });
}
