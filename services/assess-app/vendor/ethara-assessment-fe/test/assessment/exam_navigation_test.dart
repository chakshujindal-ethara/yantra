// Moving through the paper, and what the candidate is told before submitting.
//
// THE BUGS THESE EXIST FOR, all on the same screen:
//
//  1. SAVING AND MOVING WERE ONE CALL. `/answer` saves and returns the next
//     question, and it refuses to do either when the answer is incomplete
//     (candidate.py:660 -> 422). So a blank question was a dead end: Next,
//     Previous and "Review & submit" all returned the same refusal, and a
//     candidate who wanted to skip a question - or who cleared a box to think
//     again - could not leave it by any route.
//
//  2. THE ANSWER EDITORS KEPT THEIR STATE ACROSS QUESTIONS. `AnswerArea` had
//     no key, so moving from question 1 to question 2 rebuilt the same widget
//     type at the same position and Flutter REUSED the State - including the
//     text controller. Question 2 opened holding question 1's prose, and
//     because the editor saves against the CURRENT question id, one keystroke
//     stored question 1's answer as question 2's. Free navigation (1) makes
//     that reachable constantly, which is why they are fixed together.
//
//  3. THE REVIEW MATRIX JUMPED NOWHERE. Each cell called `nav.examQuestion`,
//     but the route only says "a question screen" - WHICH question comes from
//     the runner's envelope. Every cell opened whichever question happened to
//     be loaded.
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
import 'package:ethara_assessment/assessment/widgets/feedback.dart'
    show ToastMsg;

const String kToken = '65a12c11-fb40-48b5-af51-3f3c6822b65f';

/// Every request the client made: path plus decoded params.
final List<({String path, Map<String, dynamic> body})> calls =
    <({String path, Map<String, dynamic> body})>[];

Map<String, dynamic> _question(int index, String id) => <String, dynamic>{
  'id': id,
  'index': index,
  'total': 3,
  'name': 'Question $index',
  'prompt': 'Prompt for question $index.',
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
};

Map<String, dynamic> _envelope(int index, String id) => <String, dynamic>{
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
    'total_questions': 3,
    'answered_count': 0,
    'results_released': false,
  },
  'question': _question(index, id),
  'answered_question_ids': <dynamic>[],
  'progress_percent': 0,
};

/// The review checklist: question 2 is the gap.
Map<String, dynamic> _reviewPayload() => <String, dynamic>{
  'rows': <Map<String, dynamic>>[
    <String, dynamic>{
      'index': 1,
      'question_id': 10,
      'name': 'Question 1',
      'answered': true,
    },
    <String, dynamic>{
      'index': 2,
      'question_id': 11,
      'name': 'Question 2',
      'answered': false,
    },
    <String, dynamic>{
      'index': 3,
      'question_id': 12,
      'name': 'Question 3',
      'answered': true,
    },
  ],
  'answered_count': 2,
  'total_questions': 3,
  'unanswered': <int>[11],
};

http.Client _server() => MockClient((http.Request req) async {
  final String path = req.url.path;
  final Map<String, dynamic> raw = req.body.isEmpty
      ? <String, dynamic>{}
      : jsonDecode(req.body) as Map<String, dynamic>;
  final Object? params = raw['params'];
  final Map<String, dynamic> body = params is Map<String, dynamic>
      ? params
      : raw;
  calls.add((path: path, body: body));

  Map<String, dynamic> data;
  if (path.endsWith('/state')) {
    final int q = (body['q'] as num?)?.toInt() ?? 1;
    data = _envelope(q, '${9 + q}');
  } else if (path.endsWith('/review')) {
    data = _reviewPayload();
  } else if (path.endsWith('/answer')) {
    // The SERVER's rule, reproduced: an empty subjective answer is refused,
    // and the refusal blocks the move as well as the save.
    if ('${body['justification'] ?? ''}'.isEmpty) {
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
    data = <String, dynamic>{'saved': true, 'next': _envelope(2, '11')};
  } else {
    data = <String, dynamic>{};
  }
  return http.Response(
    jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

AppStore runnerStore({int atQuestion = 1}) {
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
      'total_questions': 3,
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
  s.examByToken[kToken] = ExamView.fromJson(
    _envelope(atQuestion, '${9 + atQuestion}'),
  );
  return s;
}

Widget mount(AppStore s, AssessmentNav nav, ExamSub sub) => MaterialApp(
  theme: ThemeData.dark(),
  home: AssessmentNavScope(
    nav: nav,
    child: ExamScreen(store: s, token: kToken, sub: sub, questionNumber: 1),
  ),
);

Future<void> settle(WidgetTester t) async {
  await t.pumpAndSettle();
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 40)),
  );
  await t.pumpAndSettle();
}

Future<void> openQuestion(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1400, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(mount(s, AssessmentNav(), ExamSub.question));
  await settle(t);
}

/// A side-by-side comparison, which is the only kind whose written half is
/// optional. `requires` is the answer the server derives from Form Studio's
/// "Require justification" switch.
Map<String, dynamic> _abQuestion({required bool requires}) =>
    <String, dynamic>{
      'id': '10',
      'index': 1,
      'total': 3,
      'name': 'Which render is better?',
      'prompt': 'Pick the better render.',
      'question_type': 'image_ab',
      'requires_justification': requires,
      'dimensions': <dynamic>[
        <String, dynamic>{
          'code': 'D1',
          'name': 'Overall Choice',
          'options': <dynamic>[
            <String, dynamic>{'id': 'o-a', 'label': 'A is better'},
            <String, dynamic>{'id': 'o-b', 'label': 'B is better'},
          ],
        },
      ],
      'images': <dynamic>[
        <String, dynamic>{'slot': 'a', 'url': 'https://img.test/a.png'},
        <String, dynamic>{'slot': 'b', 'url': 'https://img.test/b.png'},
      ],
      'videos': <dynamic>[],
      'label_boxes': <dynamic>[],
      'answer': <String, dynamic>{
        'answered': false,
        'selected_option_ids': <dynamic>[],
        'justification': '',
        'label_answers': <String, dynamic>{},
      },
    };

/// The comparison runner: question 1 is the A/B, and the store is seeded with
/// the verdict already picked so the ONLY thing missing is the prose.
AppStore abStore({required bool requires, String justification = ''}) {
  final AppStore s = runnerStore();
  final Map<String, dynamic> env = _envelope(1, '10')
    ..['question'] = _abQuestion(requires: requires);
  s.examByToken[kToken] = ExamView.fromJson(env);
  final Attempt a = s.attempts.first;
  a.resp['10'] = Response(
    lines: const <String>['o-a'],
    justification: justification,
  );
  return s;
}

/// Let any toast this screen raised expire. `Toaster.show` arms a 3200ms
/// dismissal timer and the test binding refuses to end a test with one still
/// pending - so a test that asserts a toast has to outlive it.
Future<void> drainToasts(WidgetTester t) async {
  await t.pump(const Duration(milliseconds: 3400));
  await t.pumpAndSettle();
}

void main() {
  setUp(calls.clear);

  group('a blank answer never traps the candidate', () {
    testWidgets('Next moves without posting an answer', (WidgetTester t) async {
      final AppStore s = runnerStore();
      await openQuestion(t, s);
      calls.clear();

      await t.tap(find.text('Next'));
      await settle(t);

      expect(
        calls.where(
          (({String path, Map<String, dynamic> body}) c) =>
              c.path.endsWith('/answer'),
        ),
        isEmpty,
        reason:
            'posting a blank answer is what produced the 422 that blocked the '
            'move; there is nothing to save, so nothing should be sent',
      );
      final Iterable<({String path, Map<String, dynamic> body})> states = calls
          .where(
            (({String path, Map<String, dynamic> body}) c) =>
                c.path.endsWith('/state'),
          );
      expect(states, hasLength(1));
      expect(
        states.single.body['q'],
        2,
        reason: 'the move goes through /state?q=, which does not save',
      );
      expect(s.examView(kToken)!.index, 2);
    });

    testWidgets('Previous moves back without posting an answer', (
      WidgetTester t,
    ) async {
      final AppStore s = runnerStore(atQuestion: 2);
      await openQuestion(t, s);
      calls.clear();

      await t.tap(find.text('Previous'));
      await settle(t);

      expect(
        calls.where(
          (({String path, Map<String, dynamic> body}) c) =>
              c.path.endsWith('/answer'),
        ),
        isEmpty,
      );
      expect(
        calls
            .firstWhere(
              (({String path, Map<String, dynamic> body}) c) =>
                  c.path.endsWith('/state'),
            )
            .body['q'],
        1,
      );
    });

    testWidgets('Review & submit is reachable from a blank question', (
      WidgetTester t,
    ) async {
      final AppStore s = runnerStore();
      final AssessmentNav nav = AssessmentNav();
      t.view.physicalSize = const Size(1400, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      // Mounted directly rather than through the section, so the sub is fixed
      // and the route change cannot re-render this widget. The contract at
      // this level is what was asked of the server and where the navigator
      // was sent - the review SCREEN itself is covered below.
      await t.pumpWidget(mount(s, nav, ExamSub.question));
      await settle(t);
      calls.clear();

      await t.tap(find.text('Review & Submit'));
      await settle(t);

      expect(
        calls.where(
          (({String path, Map<String, dynamic> body}) c) =>
              c.path.endsWith('/answer'),
        ),
        isEmpty,
        reason: 'the 422 used to block the way to the review page too',
      );
      expect(
        calls.any(
          (({String path, Map<String, dynamic> body}) c) =>
              c.path.endsWith('/review'),
        ),
        isTrue,
        reason: 'the checklist must be fetched before it is shown',
      );
      expect(nav.current, isA<Exam>());
      expect((nav.current as Exam).stage, ExamStage.review);
    });
  });

  testWidgets('an answer that HAS content is still saved on the way', (
    WidgetTester t,
  ) async {
    final AppStore s = runnerStore();
    await openQuestion(t, s);

    await t.enterText(find.byType(TextField).first, 'A real answer.');
    await t.pump();
    calls.clear();

    await t.tap(find.text('Next'));
    await settle(t);

    final Iterable<({String path, Map<String, dynamic> body})> answers = calls
        .where(
          (({String path, Map<String, dynamic> body}) c) =>
              c.path.endsWith('/answer'),
        );
    expect(answers, isNotEmpty, reason: 'skipping must not become discarding');
    expect(answers.first.body['justification'], 'A real answer.');
  });

  testWidgets('moving to the next question clears the previous answer box', (
    WidgetTester t,
  ) async {
    // Without a key on AnswerArea the controller survives the move, so the
    // next question opens holding the previous one's prose - and saves it.
    final AppStore s = runnerStore();
    await openQuestion(t, s);

    await t.enterText(find.byType(TextField).first, 'Answer to question one.');
    await t.pump();

    await t.tap(find.text('Next'));
    await settle(t);

    expect(s.examView(kToken)!.index, 2);
    final TextField box = t.widget<TextField>(find.byType(TextField).first);
    expect(
      box.controller?.text ?? '',
      isEmpty,
      reason:
          'question 2 opened showing question 1 answer, and one keystroke '
          'would have stored it against question 2',
    );
  });

  group('submitting names the gaps', () {
    testWidgets('the review matrix jump fetches that question', (
      WidgetTester t,
    ) async {
      final AppStore s = runnerStore();
      t.view.physicalSize = const Size(1400, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await s.loadExamReview(kToken);
      await t.pumpWidget(mount(s, AssessmentNav(), ExamSub.review));
      await settle(t);
      calls.clear();

      // Cell 3 - the matrix renders one numbered cell per row.
      await t.tap(find.text('3'));
      await settle(t);

      expect(
        calls
            .firstWhere(
              (({String path, Map<String, dynamic> body}) c) =>
                  c.path.endsWith('/state'),
            )
            .body['q'],
        3,
        reason: 'every cell used to open whichever question was already loaded',
      );
    });

    testWidgets('submitting with a gap warns and names the question', (
      WidgetTester t,
    ) async {
      final AppStore s = runnerStore();
      t.view.physicalSize = const Size(1400, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await s.loadExamReview(kToken);
      await t.pumpWidget(mount(s, AssessmentNav(), ExamSub.review));
      await settle(t);

      await t.tap(find.text('Submit Assessment'));
      await settle(t);

      expect(find.text('Submit with 1 unanswered?'), findsOneWidget);
      expect(
        find.textContaining('Question 2 has no answer'),
        findsOneWidget,
        reason: 'the candidate must be told WHICH question, not just how many',
      );

      // And it is a real gate: backing out submits nothing.
      await t.tap(find.text('Go Back and Answer'));
      await settle(t);
      expect(
        calls.where(
          (({String path, Map<String, dynamic> body}) c) =>
              c.path.endsWith('/submit'),
        ),
        isEmpty,
      );
    });
  });

  // A COMPARISON'S JUSTIFICATION IS ASKED FOR, OR IT IS NOT THERE AT ALL.
  //
  // The box used to be unconditional and its placeholder promised the prose was
  // marked. On a comparison with no answer rationale that was false - the
  // backend drops the mark and never calls the judge - so the candidate wrote
  // for nobody. Form Studio's switch now decides it, and the server sends the
  // answer as `requires_justification`.
  group('the justification box appears only when it is required', () {
    testWidgets('the box is hidden when no justification is required', (
      WidgetTester t,
    ) async {
      await openQuestion(t, abStore(requires: false));
      expect(find.text('JUSTIFICATION (REQUIRED)'), findsNothing);
    });

    testWidgets('the box is shown when a justification is required', (
      WidgetTester t,
    ) async {
      await openQuestion(t, abStore(requires: true));
      expect(find.text('JUSTIFICATION (REQUIRED)'), findsOneWidget);
    });

    testWidgets('a required box says it is needed before moving on', (
      WidgetTester t,
    ) async {
      await openQuestion(t, abStore(requires: true));
      // The box carries no hint text (owner, 2026-09-29), so the LABEL says
      // it is required - that keeps the refusal on Next predictable.
      expect(find.textContaining('(REQUIRED)'), findsOneWidget);
      expect(find.textContaining('before you can move on'), findsNothing);
    });

    testWidgets('Next on a blank required box is told, not silently refused', (
      WidgetTester t,
    ) async {
      final AppStore s = abStore(requires: true);
      await openQuestion(t, s);
      calls.clear();

      await t.tap(find.text('Next'));
      await settle(t);

      // `hasInput` is already true - a verdict is picked - so without this
      // check the runner would POST and take a 422 back. The client asks the
      // same question the server does, and says so in the candidate's words.
      final String toasts = s.toaster.items
          .map((ToastMsg m) => m.message)
          .join(' | ');
      expect(toasts, contains('needs a justification'));
      expect(
        calls.where(
          (({String path, Map<String, dynamic> body}) c) =>
              c.path.endsWith('/answer'),
        ),
        isEmpty,
        reason: 'the server would refuse this answer, so it is not posted',
      );
      // AND THE CANDIDATE IS NOT STUCK ON IT. Being unable to leave a question
      // is the dead end this whole screen was fixed to remove; the verdict they
      // picked stays in the store, so they can come back and type.
      expect(s.examView(kToken)!.index, 2);
      await drainToasts(t);
    });

    testWidgets('Next posts once the required box is written', (
      WidgetTester t,
    ) async {
      final AppStore s = abStore(
        requires: true,
        justification: 'A holds detail in the shadows.',
      );
      await openQuestion(t, s);
      calls.clear();

      await t.tap(find.text('Next'));
      await settle(t);

      expect(
        s.toaster.items.map((ToastMsg m) => m.message).join(' | '),
        isNot(contains('needs a justification')),
      );
      final Iterable<({String path, Map<String, dynamic> body})> saves = calls
          .where(
            (({String path, Map<String, dynamic> body}) c) =>
                c.path.endsWith('/answer'),
          );
      expect(saves, hasLength(1));
      expect(saves.single.body['justification'], 'A holds detail in the shadows.');
      await drainToasts(t);
    });

    testWidgets('a blank box that was never asked for saves the verdict alone', (
      WidgetTester t,
    ) async {
      // THE OFF PATH WORKING IS HALF THE FEATURE. Demanding prose here would
      // refuse a paper the examiner deliberately authored as verdict-only, over
      // a box the candidate was never shown - unescapable from their side.
      final AppStore s = abStore(requires: false);
      await openQuestion(t, s);
      calls.clear();

      await t.tap(find.text('Next'));
      await settle(t);

      expect(
        s.toaster.items.map((ToastMsg m) => m.message).join(' | '),
        isNot(contains('needs a justification')),
      );
      final Iterable<({String path, Map<String, dynamic> body})> saves = calls
          .where(
            (({String path, Map<String, dynamic> body}) c) =>
                c.path.endsWith('/answer'),
          );
      expect(saves, hasLength(1), reason: 'the verdict is a real answer');
      expect(saves.single.body['justification'], '');
      await drainToasts(t);
    });
  });
}
