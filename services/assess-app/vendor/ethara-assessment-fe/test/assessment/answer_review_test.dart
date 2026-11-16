// The candidate's answer review, against the payload the server really sends.
//
// THE BUG THIS EXISTS FOR. `exam_screen.dart` looked the Assessment record up
// by `ev.assessmentId` and returned the `invalid` gate when it was missing -
// so a candidate clicking "See my answers" on her own completed sitting was
// told "This link does not work". Her link was fine; `/api/v1/assessments` is
// simply a manager route, so a candidate NEVER has an Assessment loaded.
//
// This is the third instance of one defect class ("skip when the Assessment is
// missing"); the other two were fixed in my_performance_screen.dart and
// my_assessments_screen.dart the same way - by reading the server's own
// precomputed values instead of requiring a record the caller cannot load.
//
// The payload below is copied verbatim from a live curl of
// `GET /api/v1/exam/00000000-0000-4000-8000-000000000001/answers`.
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
import 'package:ethara_assessment/assessment/screens/exam/stimulus.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/marks.dart';

/// Two different 1x1 PNGs, so the test can tell which plate was painted.
const String kPlainPlate =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGM4ceIEAAS0AlkWLoFAAAAAAElFTkSuQmCC';
const String kMarkedPlate =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGM4wXACAAMkAZGwgErnAAAAAElFTkSuQmCC';

const String kToken = '00000000-0000-4000-8000-000000000001';

/// The wording the broken screen showed. Asserted against by name so a
/// regression cannot pass by rendering the gate with different copy.
const String kDeadLink = 'This link does not work';

/// `/api/v1/exam/<token>/answers`, exactly as the live module answers it.
Map<String, dynamic> answersPayload({
  bool released = true,
  bool graded = false,
  bool labelRow = false,
}) => <String, dynamic>{
  'assessment': <String, dynamic>{
    'id': 18,
    'name': 'Forklift Safety - Induction E2E',
  },
  'result': <String, dynamic>{
    'released': released,
    'status': released ? 'released' : 'awaiting_results',
    // The server omits every scoring field before release; the fixture
    // omits them too, or it would be testing a payload that never exists.
    if (released) 'score_marks': '0 / 3',
    if (released) 'result': 'fail',
    if (released) 'verdict': 'fail',
    'is_pending': !released,
    'subjective_pending': 0,
    if (released) 'label': '0 / 3 - FAIL',
  },
  'rows': <Map<String, dynamic>>[
    <String, dynamic>{
      'index': 1,
      'question_id': 10,
      'name': 'End of Shift Parking Procedure',
      'prompt':
          'An operator is finishing their shift and parking their '
          'counterbalance forklift in the designated bay. Describe the '
          'exact physical state the forklift must be left in before the '
          'operator walks away.',
      'question_type': 'subjective_rubric',
      'chosen': <String>[],
      'correct': <String>[],
      // `graded`: the same row once the grader has marked a real answer - the
      // shape a released subjective row takes on the live server.
      'justification': graded
          ? 'Forks lowered to the floor, parking brake on, key removed.'
          : '[Auto-submitted: time expired]',
      'verdict': released ? (graded ? 'Passed' : 'No Grade') : '',
      'kind': graded ? 'pass' : 'info',
      'score_raw': null,
      'feedback': graded && released
          ? 'You named the three things that make a parked truck safe.'
          : '',
      'score_verdict': graded && released
          ? 'Complete and correct parking procedure.'
          : '',
      'deductions': <String>[],
      'credit': graded && released
          ? <String>['Forks lowered and brake set']
          : <String>[],
    },
    <String, dynamic>{
      'index': 2,
      'question_id': 8,
      'name': 'Pedestrian Near Miss Action',
      'prompt':
          'An operator is driving a counterbalance forklift at 5 '
          'km/h near a pedestrian walkway. A pedestrian steps out '
          'unexpectedly, and the operator brakes hard, stopping just short '
          'of the pedestrian. What is the immediate required action '
          "regarding the operator's status?",
      'question_type': 'mcq',
      // ANSWERED, AND WRONG - which is what "Incorrect" is for. The other two
      // rows are the clock's placeholders, and a placeholder is not a wrong
      // answer: see `a_question_the_clock_took_away_is_not_an_answer_test`.
      'chosen': <String>['They may continue operating as normal'],
      'correct': released
          ? <String>[
              'They must complete a re-certification before operating again',
            ]
          : <String>[],
      'justification': '',
      'verdict': released ? 'Incorrect' : '',
      'kind': 'fail',
      'score_raw': null,
      'feedback': '',
      'score_verdict': '',
      'deductions': <String>[],
      'credit': <String>[],
    },
    <String, dynamic>{
      'index': 3,
      'question_id': 9,
      'name': 'Pre-Operational Inspection Timing',
      'prompt':
          'A forklift has just been repaired and returned to the '
          'warehouse floor. Under which conditions is a documented '
          'pre-operational inspection mandatory? (Select all that apply)',
      'question_type': 'msq',
      'chosen': <String>[],
      'correct': released
          ? <String>[
              'At the start of every shift',
              'Before the truck is used for the first time',
              'After any change of operator',
            ]
          : <String>[],
      'justification': '[Auto-submitted: time expired]',
      'verdict': released ? 'Incorrect' : '',
      'kind': 'fail',
      'score_raw': null,
      'feedback': '',
      'score_verdict': '',
      'deductions': <String>[],
      'credit': <String>[],
    },
    // A LABELLING ROW, whose answers read "Box 1: ..." and so need the
    // numbered boxes: the server sends the plain plate AND the marked one.
    if (labelRow)
      <String, dynamic>{
        'index': 4,
        'question_id': 20,
        'name': 'Identify interface elements',
        'prompt': 'Box and describe the functionality of each main panel.',
        'question_type': 'image_label',
        'chosen': <String>[],
        'correct': <String>[],
        'justification': '1. Player and timeline',
        'verdict': released ? 'Passed' : '',
        'kind': 'pass',
        'score_raw': null,
        'feedback': '',
        'score_verdict': '',
        'deductions': <String>[],
        'credit': <String>[],
        'images': <Map<String, dynamic>>[
          <String, dynamic>{
            'slot': 'single',
            'url': kPlainPlate,
            'annotated_url': kMarkedPlate,
          },
        ],
        'videos': <Map<String, dynamic>>[],
      },
  ],
};

/// `/api/v1/me/assessments` - the candidate's own list. It carries NO
/// assessment records, which is the whole point: the store ends up with an
/// attempt whose `asmById` lookup returns null.
Map<String, dynamic> meAssessmentsPayload({bool released = true}) =>
    <String, dynamic>{
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
            'name': 'Forklift Safety - Induction E2E',
            'state': 'completed',
            'duration_minutes': 30,
            'submitted_at': '2026-08-05T07:58:23Z',
            'result': <String, dynamic>{
              'released': released,
              if (released) 'score_marks': '0 / 3',
              if (released) 'result': 'fail',
            },
            'can_review_answers': released,
          },
        ],
        'closed': <dynamic>[],
      },
      'total_count': 1,
    };

http.Client _candidateServer({
  bool released = true,
  bool graded = false,
  bool labelRow = false,
}) =>
    MockClient((http.Request req) async {
      final String p = req.url.path;
      late final Map<String, dynamic> data;
      if (p.endsWith('/answers')) {
        data = answersPayload(
          released: released,
          graded: graded,
          labelRow: labelRow,
        );
      } else if (p.endsWith('/api/v1/me/assessments')) {
        data = meAssessmentsPayload(released: released);
      } else {
        // Every manager route 403s for a candidate. Returning an empty object
        // instead would quietly make the test easier than reality.
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': <String, dynamic>{
              'code': 'forbidden',
              'message': 'You are not allowed to access this resource.',
            },
          }),
          403,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

/// A store loaded exactly as a signed-in candidate's is: her attempt, and no
/// assessments at all.
Future<AppStore> candidateStore(
  WidgetTester t, {
  bool released = true,
  bool graded = false,
  bool labelRow = false,
}) async {
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      client: _candidateServer(
        released: released,
        graded: graded,
        labelRow: labelRow,
      ),
      bearer: 'access_token_stub',
    ),
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  await t.runAsync(() => s.refresh());
  return s;
}

Widget mount(AppStore s) => MaterialApp(
  theme: ThemeData.dark(),
  home: AssessmentNavScope(
    nav: AssessmentNav(),
    child: ExamScreen(store: s, token: kToken, sub: ExamSub.answers),
  ),
);

/// Everything the screen actually painted, as strings.
List<String> screenText(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((Text w) => w.data ?? w.textSpan?.toPlainText() ?? '')
    .where((String s) => s.isNotEmpty)
    .toList();

void main() {
  testWidgets('a candidate with no Assessment record sees her answers', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final AppStore s = await candidateStore(t);

    // The precondition that broke the screen: the attempt resolves, the
    // assessment does not.
    expect(s.attemptByToken(kToken), isNotNull);
    expect(
      s.asmById('18'),
      isNull,
      reason:
          'a candidate cannot load assessment records at all; if this '
          'ever becomes non-null the test has stopped reproducing the bug',
    );

    await t.pumpWidget(mount(s));
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await t.pumpAndSettle();

    final List<String> text = screenText(t);

    expect(
      text,
      isNot(contains(kDeadLink)),
      reason: 'a valid token must never resolve to the invalid-link gate',
    );

    // The name, off the answers payload rather than an Assessment record.
    expect(find.text('Forklift Safety - Induction E2E'), findsOneWidget);

    // All 3 questions, by their real prompts.
    expect(
      find.textContaining('parking their counterbalance forklift'),
      findsOneWidget,
    );
    expect(find.textContaining('A pedestrian steps out'), findsOneWidget);
    expect(
      find.textContaining('pre-operational inspection mandatory'),
      findsOneWidget,
    );
    expect(find.textContaining('Question '), findsNWidgets(3));

    // The released marks, as MARKS and never a percentage (invariant 2).
    expect(text, contains('0 / 3'));
    expect(text.where((String s) => s.contains('%')), isEmpty);
  });

  // A released sheet carries the grader's one-line verdict (`score_verdict`,
  // '' when the server withholds it), shown under "The judge's verdict". The
  // app used to drop it, so candidates saw feedback without the judgement it
  // explains.
  test('a released row carries the judge\'s verdict; a held one does not', () {
    final AnswerSheet released = AnswerSheet.fromJson(
      answersPayload(graded: true),
    );
    expect(
      released.rows.first.scoreVerdict,
      'Complete and correct parking procedure.',
    );
    final AnswerSheet held = AnswerSheet.fromJson(
      answersPayload(released: false, graded: true),
    );
    expect(held.rows.first.scoreVerdict, isEmpty);
  });

  testWidgets('the candidate sees the judge\'s verdict once released', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final AppStore s = await candidateStore(t, graded: true);
    await t.pumpWidget(mount(s));
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await t.pumpAndSettle();

    // `Eyebrow` paints its label upper-cased.
    expect(find.text("THE JUDGE'S VERDICT"), findsOneWidget);
    expect(
      find.text('Complete and correct parking procedure.'),
      findsOneWidget,
    );
    expect(
      find.text('You named the three things that make a parked truck safe.'),
      findsOneWidget,
    );
  });

  testWidgets('the server verdict for each row is a pill, never bare text', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final AppStore s = await candidateStore(t);
    await t.pumpWidget(mount(s));
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await t.pumpAndSettle();

    final List<Pill> pills = t.widgetList<Pill>(find.byType(Pill)).toList();
    expect(
      pills.map((Pill p) => p.label),
      containsAll(<String>['Not answered', 'Incorrect']),
    );

    // THE TONE RULE. A question the clock took away is not a failure and must
    // not be painted red - whatever verdict an unfixed server put on the row.
    final Pill unanswered = pills.firstWhere(
      (Pill p) => p.label == 'Not answered',
    );
    expect(
      unanswered.tone,
      isNot(Tone.bad),
      reason: 'never answered is never red',
    );
  });

  group('Invariant 3 - no score before release', () {
    test('the parser drops every scoring field on an unreleased sheet', () {
      final AnswerSheet held = AnswerSheet.fromJson(
        answersPayload(released: false),
      );

      expect(held.released, isFalse);
      expect(
        held.earned,
        isNull,
        reason: 'a held result has no marks to show, not a zero',
      );
      expect(held.total, isNull);
      expect(held.hasMarks, isFalse);
      expect(held.result, ResultState.pending);
      for (final AnswerSheetRow r in held.rows) {
        expect(
          r.correct,
          isEmpty,
          reason: 'the answer key states whether the candidate was right',
        );
        expect(r.verdict, isEmpty);
        expect(r.tone, Tone.inert);
        expect(r.scoreVerdict, isEmpty);
        expect(r.feedback, isEmpty);
        expect(r.credit, isEmpty);
        expect(r.deductions, isEmpty);
      }
    });

    testWidgets('an unreleased sheet renders the gate, not a score', (
      WidgetTester t,
    ) async {
      t.view.physicalSize = const Size(1400, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final AppStore s = await candidateStore(t, released: false);
      await t.pumpWidget(mount(s));
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await t.pumpAndSettle();

      final List<String> text = screenText(t);

      expect(find.text('Results not released yet'), findsOneWidget);

      // Not the dead-link gate either: the link is valid, the marks are held.
      expect(text, isNot(contains(kDeadLink)));

      // Nothing that discloses a score or a per-question outcome.
      expect(find.byType(Marks), findsNothing);
      expect(text.where((String s) => s.contains('/ 3')), isEmpty);
      for (final String s in <String>['Incorrect', 'Correct Answer', 'FAIL']) {
        expect(
          text,
          isNot(contains(s)),
          reason: 'an unreleased review must disclose no correctness',
        );
      }
    });
  });

  testWidgets('a released labelling row shows the MARKED plate', (
    WidgetTester t,
  ) async {
    // Owner, 2026-09-29: the numbered boxes were on the exam and in the bank,
    // but the released answer sheet showed the plain screenshot, so "Box 1:
    // ..." pointed at nothing.
    t.view.physicalSize = const Size(1400, 3200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final AppStore s = await candidateStore(t, graded: true, labelRow: true);
    await t.pumpWidget(mount(s));
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await t.pumpAndSettle();

    final List<String?> painted = t
        .widgetList<StimulusPlate>(find.byType(StimulusPlate))
        .map((StimulusPlate p) => p.asset.url)
        .toList();
    expect(painted, contains(kMarkedPlate));
    expect(painted, isNot(contains(kPlainPlate)));
  });

  testWidgets('a sheet released without its key shows marks, not verdicts', (
    WidgetTester t,
  ) async {
    // R6: `results_show_answers` off. The server keeps every key on the row,
    // blanks the key and the judge, and clears the verdict to an info tone
    // (`released_answer_review_row(..., reveal=False)`); the marks and the
    // tags stay.
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    Map<String, dynamic> row(
      int i,
      String type,
      double earned,
      int available, {
      List<String> chosen = const <String>[],
      String justification = '',
    }) => <String, dynamic>{
      'index': i,
      'question_id': 100 + i,
      'name': 'Question $i',
      'prompt': 'Prompt $i.',
      'question_type': type,
      'chosen': chosen,
      'correct': <String>[],
      'justification': justification,
      'verdict': '',
      'kind': 'info',
      'score_raw': null,
      'feedback': '',
      'score_verdict': '',
      'deductions': <String>[],
      'credit': <String>[],
      'marks_earned': earned,
      'marks_available': available,
      'tags': <String>['skill:incident-response'],
    };
    final Map<String, dynamic> sheet = <String, dynamic>{
      ...answersPayload(),
      'rows': <Map<String, dynamic>>[
        row(1, 'mcq', 2.0, 3, chosen: <String>['Stop and report']),
        row(2, 'subjective_rubric', 1.5, 2, justification: 'Brake on.'),
      ],
    };
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        bearer: 'access_token_stub',
        client: MockClient((http.Request req) async {
          final String p = req.url.path;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': p.endsWith('/answers') ? sheet : meAssessmentsPayload(),
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
    s.portal = Portal.member;
    s.source = DataSource.live;
    s.meId = '2';
    await t.runAsync(() => s.refresh());
    await t.pumpWidget(mount(s));
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await t.pumpAndSettle();

    final List<String> pills = t
        .widgetList<Pill>(find.byType(Pill))
        .map((Pill p) => p.label)
        .toList();
    expect(pills, containsAll(<String>['2 / 3 marks', '1.5 / 2 marks']));
    expect(pills, isNot(contains('Answered')));
    expect(find.text('CORRECT ANSWER'), findsNothing);
    expect(find.text("THE JUDGE'S VERDICT"), findsNothing);
    // The categories still add up from the marks.
    expect(find.textContaining('Strengths and Weaknesses'), findsWidgets);
  });
}
