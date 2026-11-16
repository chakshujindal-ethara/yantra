// A video link in a question's help text opens in an in-app popup, not a
// new browser tab - the popup exists so answering the video never means
// leaving the exam. Covers the tap-to-open path; the actual player content
// (YouTube/Vimeo embed) is web-only and covered by the manual/Playwright
// verification, not this VM suite.
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
const String kVideoUrl = 'https://youtu.be/dQw4w9WgXcQ';

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
  'question': <String, dynamic>{
    'id': '10',
    'index': 1,
    'total': 1,
    'name': 'Question 1',
    'prompt': 'Watch the clip, then answer.',
    'desc': kVideoUrl,
    'question_type': 'subjective_rubric',
    'dimensions': <dynamic>[],
    'images': <dynamic>[],
    'videos': <dynamic>[],
    'label_boxes': <dynamic>[],
    'answer': <String, dynamic>{
      'answered': false,
      'selected_option_ids': <dynamic>[],
      'justification': '',
      'label_answers': <String, dynamic>{},
    },
  },
  'answered_question_ids': <dynamic>[],
  'progress_percent': 0,
};

http.Client _server() => MockClient((http.Request req) async {
  final String path = req.url.path;
  final Map<String, dynamic> data = path.endsWith('/state')
      ? _envelope()
      : <String, dynamic>{};
  return http.Response(
    jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

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

Widget _mount(AppStore s, AssessmentNav nav) => MaterialApp(
  theme: ThemeData.dark(),
  home: AssessmentNavScope(
    nav: nav,
    child: ExamScreen(
      store: s,
      token: kToken,
      sub: ExamSub.question,
      questionNumber: 1,
    ),
  ),
);

void main() {
  testWidgets(
    'a video link in the help text opens a popup, not a new route',
    (WidgetTester t) async {
      t.view.physicalSize = const Size(1400, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final AppStore s = _runnerStore();
      final AssessmentNav nav = AssessmentNav();
      await t.pumpWidget(_mount(s, nav));
      await t.pumpAndSettle();

      // The help text renders (not silently dropped) and carries the link
      // text itself, not a placeholder - a candidate must see IT'S a link.
      final Finder link = find.textContaining(kVideoUrl);
      expect(link, findsOneWidget);

      await t.tap(link);
      await t.pumpAndSettle();

      // A popup, not a page change: the question underneath is still
      // mounted (a real navigation would have torn it down), just covered
      // by the popup's own barrier. Closing it (Esc-equivalent: the Close
      // control) must return to the exact same screen.
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.textContaining('Watch the clip'), findsOneWidget);

      await t.tap(find.text('Close'));
      await t.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(find.textContaining('Watch the clip'), findsOneWidget);
      expect(link, findsOneWidget);
    },
  );

  testWidgets(
    'help text with no video link stays plain, unclickable text',
    (WidgetTester t) async {
      t.view.physicalSize = const Size(1400, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final AppStore s = _runnerStore();
      s.examByToken[kToken] = ExamView.fromJson(<String, dynamic>{
        ..._envelope(),
        'question': <String, dynamic>{
          ..._envelope()['question'] as Map<String, dynamic>,
          'desc': 'See the reference doc at https://example.com/spec.pdf',
        },
      });
      final AssessmentNav nav = AssessmentNav();
      await t.pumpWidget(_mount(s, nav));
      await t.pumpAndSettle();

      final Finder desc = find.textContaining('reference doc');
      expect(desc, findsOneWidget);
      await t.tap(desc);
      await t.pumpAndSettle();

      // Not a video link - no popup, nothing to open.
      expect(find.byType(Dialog), findsNothing);
    },
  );
}
