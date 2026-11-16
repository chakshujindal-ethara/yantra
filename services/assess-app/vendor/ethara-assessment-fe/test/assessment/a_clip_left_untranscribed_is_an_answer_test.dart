// A transcription answered only by a "not transcribed" category (No Speech,
// Music, ...) has an empty box by design. It is an answer: the candidate's
// review says "Not transcribed: <category>", not "Left blank", and counts it
// as answered. Ticks and speakers alone are not an answer - the server
// refuses them without text - so they do not count.
//
// Also the review grid before Submit: only a question holding real input is
// answered, so an answer erased back to nothing shows unanswered.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/domain/transcription.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/marks.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';

const String kToken = '00000000-0000-4000-8000-0000000000c1';

Map<String, dynamic> _row(int index, Map<String, dynamic> clip) =>
    <String, dynamic>{
      'index': index,
      'question_id': 10 + index,
      'name': 'Clip $index',
      'prompt': 'Listen to the clip and type exactly what is said.',
      'question_type': 'transcription',
      'chosen': <String>[],
      'correct': <String>[],
      'justification': '',
      'clip_answers': clip,
      'verdict': '',
      'kind': 'info',
      'feedback': '',
      'score_verdict': '',
      'deductions': <String>[],
      'credit': <String>[],
    };

/// `/exam/<token>/answers`, released: one clip marked No Speech, one with
/// only a tick.
Map<String, dynamic> _answers() => <String, dynamic>{
  'assessment': <String, dynamic>{'id': 18, 'name': 'Clips'},
  'result': <String, dynamic>{
    'released': true,
    'status': 'released',
    'score_marks': '1 / 2',
    'result': 'fail',
    'verdict': 'fail',
    'is_pending': false,
    'subjective_pending': 0,
  },
  'rows': <Map<String, dynamic>>[
    _row(1, <String, dynamic>{'category': 'no_speech'}),
    _row(2, <String, dynamic>{
      'category': 'none',
      'characteristics': <String>['laughter'],
    }),
  ],
};

Map<String, dynamic> _mine() => <String, dynamic>{
  'applicant': <String, dynamic>{'id': 2, 'name': 'Priya Sharma'},
  'buckets': <String, dynamic>{
    'available': <dynamic>[],
    'in_progress': <dynamic>[],
    'upcoming': <dynamic>[],
    'completed': <dynamic>[
      <String, dynamic>{
        'id': 4,
        'token': kToken,
        'assessment_id': 18,
        'name': 'Clips',
        'state': 'completed',
        'duration_minutes': 30,
        'submitted_at': '2026-10-20T07:58:23Z',
        'result': <String, dynamic>{
          'released': true,
          'score_marks': '1 / 2',
          'result': 'fail',
        },
        'can_review_answers': true,
      },
    ],
    'closed': <dynamic>[],
  },
  'total_count': 1,
};

Future<AppStore> _candidate(WidgetTester t) async {
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      bearer: 't',
      client: MockClient((http.Request req) async {
        final String p = req.url.path;
        final Map<String, dynamic>? data = p.endsWith('/answers')
            ? _answers()
            : p.endsWith('/api/v1/me/assessments')
            ? _mine()
            : null;
        return http.Response(
          jsonEncode(
            data == null
                ? <String, dynamic>{
                    'ok': false,
                    'error': <String, dynamic>{
                      'code': 'forbidden',
                      'message': 'no',
                    },
                  }
                : <String, dynamic>{'ok': true, 'data': data},
          ),
          data == null ? 403 : 200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    ),
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  await t.runAsync(() => s.refresh());
  return s;
}

void main() {
  group('the answer rule', () {
    test('a not-transcribed category alone is an answer; ticks and speakers '
        'alone are not', () {
      expect(
        Response(clip: ClipAnswers(category: 'no_speech')).hasInput,
        isTrue,
      );
      expect(
        Response(
          clip: ClipAnswers(category: 'none')..characteristics.add('laughter'),
        ).hasInput,
        isFalse,
      );
      expect(
        Response(
          clip: ClipAnswers(category: 'none')..setSpeakerCount(1),
        ).hasInput,
        isFalse,
      );
      expect(
        Response(
          justification: 'मेरा नाम',
          clip: ClipAnswers(category: 'none'),
        ).hasInput,
        isTrue,
      );
    });

    test('the answer sheet row reads the clip and follows the same rule', () {
      final AnswerSheet sheet = AnswerSheet.fromJson(_answers());
      expect(sheet.rows.first.clip?.category, 'no_speech');
      expect(sheet.rows.first.hasInput, isTrue);
      expect(sheet.rows.last.clip?.characteristics, <String>['laughter']);
      expect(sheet.rows.last.hasInput, isFalse);
    });
  });

  testWidgets('the review says "Not transcribed: No Speech" and counts it', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final AppStore s = await _candidate(t);
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

    expect(
      find.text('Not transcribed: ${clipCategoryLabel('no_speech')}'),
      findsOneWidget,
    );
    final List<String> pills = t
        .widgetList<Pill>(find.byType(Pill))
        .map((Pill p) => p.label)
        .toList();
    expect(
      pills.where((String l) => l == 'Not answered'),
      hasLength(1),
      reason: 'only the ticks-only clip',
    );
    expect(find.text('of 2'), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(of: find.text('of 2'), matching: find.byType(Kpi)),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the review grid: an erased answer shows unanswered', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    // The fixture store: no backend, so the grid is built from the paper.
    final AppStore s = AppStore();
    addTearDown(s.dispose);
    final Attempt open = s.attempts.firstWhere(
      (Attempt a) =>
          a.state == AttemptState.inProgress &&
          a.startedAt != null &&
          (s.asmById(a.assessmentId)?.questions.length ?? 0) >= 2,
    );
    final List<Question> qs = s.asmById(open.assessmentId)!.questions;
    s.attempts = <Attempt>[
      for (final Attempt a in s.attempts)
        a.id == open.id
            ? a.copyWith(
                resp: <String, Response>{
                  qs[0].id: const Response(justification: 'mine'),
                  // Typed, then erased: the key stays, the input does not.
                  qs[1].id: const Response(),
                },
              )
            : a,
    ];
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AssessmentNavScope(
          nav: AssessmentNav(),
          child: ExamScreen(store: s, token: open.token, sub: ExamSub.review),
        ),
      ),
    );
    await t.pump();

    expect(find.text('1 of ${qs.length} answered'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(minutes: 1));
  });
}
