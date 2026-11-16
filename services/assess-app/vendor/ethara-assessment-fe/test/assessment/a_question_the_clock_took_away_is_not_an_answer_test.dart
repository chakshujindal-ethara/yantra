// The answer sheet for a sitting the clock ended.
//
// TWO DEFECTS, ONE ROW. When an attempt settles, `_auto_submit_expired` writes
// a Response for every question the candidate never reached, with
// `justification = "[Auto-submitted: time expired]"` (or the force-submit /
// proctoring variant). On the candidate's own answer sheet that row used to
// render as:
//
//   * "Your answer" followed by the bracketed system string - the module's
//     bookkeeping quoted back at the candidate as their own words; and
//   * a red "Incorrect" pill beside "Correct Answer: ...", because the
//     mcq/msq branch of `released_answer_review_row` tests only score >= max
//     and falls through to Incorrect for a placeholder that IS a response.
//
// Both are fixed server-side (blank `justification` and a `Not answered`
// verdict when `response.auto_submitted`). The client refuses the placeholder
// too, so an older backend - or one of the three placeholder spellings a later
// fix forgets - cannot put it back on screen. `_compute_scoring_kind` in
// `models/assessment.py` recognises it by the same prefix, so this is the
// client's copy of a rule the module already applies to itself.
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
import 'package:ethara_assessment/assessment/widgets/marks.dart';

const String kToken = '00000000-0000-4000-8000-000000000009';

/// Every spelling `_auto_submit_expired` can stamp on an unanswered question.
const List<String> kPlaceholders = <String>[
  '[Auto-submitted: time expired]',
  '[Submitted with unanswered questions]',
  '[Auto-submitted: proctoring violation (exited fullscreen)]',
];

/// `/api/v1/exam/<token>/answers` for a paper the clock ended at question 1:
/// one real answer, one placeholder the old serializer called "Incorrect".
Map<String, dynamic> answersPayload() => <String, dynamic>{
  'assessment': <String, dynamic>{'id': 21, 'name': 'Forklift Safety'},
  'result': <String, dynamic>{
    'released': true,
    'status': 'released',
    'score_marks': '1 / 2',
    'result': 'fail',
    'subjective_pending': 0,
  },
  'rows': <Map<String, dynamic>>[
    <String, dynamic>{
      'index': 1,
      'question_id': 1,
      'name': 'Parking',
      'prompt': 'How is a forklift parked at end of shift?',
      'question_type': 'mcq',
      'chosen': <String>['Forks lowered, brake on, key out'],
      'correct': <String>['Forks lowered, brake on, key out'],
      'justification': '',
      'verdict': 'Correct',
      'kind': 'pass',
    },
    <String, dynamic>{
      'index': 2,
      'question_id': 2,
      'name': 'Near miss',
      'prompt': 'What must the operator do after a near miss?',
      'question_type': 'mcq',
      'chosen': <String>[],
      'correct': <String>['Report it before operating again'],
      // The row as an UNFIXED server sends it.
      'justification': '[Auto-submitted: time expired]',
      'verdict': 'Incorrect',
      'kind': 'fail',
    },
  ],
};

http.Client _server() => MockClient((http.Request req) async {
  final String p = req.url.path;
  if (p.endsWith('/answers')) {
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': answersPayload()}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
  if (p.endsWith('/api/v1/me/assessments')) {
    return http.Response(
      jsonEncode(<String, dynamic>{
        'ok': true,
        'data': <String, dynamic>{
          'applicant': <String, dynamic>{'id': 2, 'name': 'Priya Sharma'},
          'buckets': <String, dynamic>{
            'completed': <dynamic>[
              <String, dynamic>{
                'id': 7,
                'token': kToken,
                'assessment_id': 21,
                'name': 'Forklift Safety',
                'state': 'completed',
                'submitted_at': '2026-08-05T07:58:23Z',
                'result': <String, dynamic>{
                  'released': true,
                  'score_marks': '1 / 2',
                  'result': 'fail',
                },
                'can_review_answers': true,
              },
            ],
          },
          'total_count': 1,
        },
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
  return http.Response(
    jsonEncode(<String, dynamic>{
      'ok': false,
      'error': <String, dynamic>{'code': 'forbidden', 'message': 'No.'},
    }),
    403,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

void main() {
  test('the system placeholder is not read as the candidate\'s answer', () {
    for (final String placeholder in kPlaceholders) {
      final AnswerSheetRow row = AnswerSheetRow.fromJson(<String, dynamic>{
        'index': 1,
        'question_type': 'mcq',
        'justification': placeholder,
        'verdict': 'Incorrect',
        'kind': 'fail',
      }, released: true);

      expect(
        row.justification,
        isEmpty,
        reason: '"$placeholder" is the module\'s bookkeeping, not an answer',
      );
      expect(
        row.hasInput,
        isFalse,
        reason:
            'hasInput drives both the "You did not answer this question." '
            'branch and the "Not answered" pill',
      );
    }
  });

  test('a real answer still reads as one', () {
    final AnswerSheetRow row = AnswerSheetRow.fromJson(<String, dynamic>{
      'index': 1,
      'question_type': 'subjective_rubric',
      'justification': 'Forks lowered, brake on, key removed.',
      'verdict': 'Passed',
      'kind': 'pass',
    }, released: true);
    expect(row.hasInput, isTrue);
    expect(row.justification, 'Forks lowered, brake on, key removed.');
  });

  testWidgets('a question the clock took away is not printed as an answer', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        client: _server(),
        bearer: 'access_token_stub',
      ),
    );
    s.portal = Portal.member;
    s.source = DataSource.live;
    s.meId = '2';
    await t.runAsync(() => s.refresh());

    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AssessmentNavScope(
          nav: AssessmentNav(),
          child: ExamScreen(store: s, token: kToken, sub: ExamSub.answers),
        ),
      ),
    );
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await t.pumpAndSettle();

    final List<String> text = t
        .widgetList<Text>(find.byType(Text))
        .map((Text w) => w.data ?? w.textSpan?.toPlainText() ?? '')
        .toList();

    // The string the candidate was being shown as their own answer.
    expect(
      text.where((String s) => s.contains('[Auto-submitted')),
      isEmpty,
      reason: 'the candidate never typed the module\'s placeholder',
    );
    expect(find.text('You did not answer this question.'), findsOneWidget);

    // And the row is not recorded against them as a wrong answer.
    final List<Pill> pills = t.widgetList<Pill>(find.byType(Pill)).toList();
    expect(pills.map((Pill p) => p.label), contains('Not answered'));
    expect(
      pills.where((Pill p) => p.tone == Tone.bad),
      isEmpty,
      reason: 'a question the clock took away is not a failure',
    );
  });
}
