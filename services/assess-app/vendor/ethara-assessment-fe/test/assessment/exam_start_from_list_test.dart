// A candidate must be able to START the exam from their own list.
//
// THE BUG THIS EXISTS FOR, seen in the browser at localhost:8200: a signed-in
// candidate opened "My assessments", pressed "Start assessment" on an
// available sitting, and got "This link does not work - the link is unknown or
// has been revoked". The token was fine; `/exam/<token>/state` resolves it to
// `instructions`. Only the EMAILED link worked, because the two arrivals took
// different paths through the same screen:
//
//   emailed link  -> store is cold -> `attemptByToken` is null
//                 -> initState fetched `/exam/<token>/state` -> assessment
//                    arrives with the envelope -> the runner opens
//   own list      -> `/me/assessments` already put the attempt in the store
//                 -> `attemptByToken` is NOT null -> initState skipped the
//                    fetch -> `assessments` stayed empty (a candidate is 403
//                    on `/api/v1/assessments`) -> `asm == null` -> the
//                    invalid-link gate
//
// So the hydration guard asked about the ATTEMPT while the screen gated on the
// ASSESSMENT. This is the fourth instance of the "skip when the Assessment is
// missing" defect class; see answer_review_test.dart for the third.
//
// Both payloads below are the shapes candidate.py really answers with:
// `exam_state_envelope` (serializers.py:491) and `_question_payload`
// (candidate.py:503).
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
import 'package:ethara_assessment/assessment/widgets/controls.dart';

const String kToken = '65a12c11-fb40-48b5-af51-3f3c6822b65f';

/// The wording the broken screen showed, asserted by name so a regression
/// cannot slip through by rendering the same gate with different copy.
const String kDeadLink = 'This link does not work';

/// `/api/v1/me/assessments`. Carries the token and NO assessment record -
/// that absence is the whole precondition of this bug.
Map<String, dynamic> meAssessmentsPayload() => <String, dynamic>{
  'applicant': <String, dynamic>{'id': 2, 'name': 'Utkarsh Jain E'},
  'buckets': <String, dynamic>{
    'available': <dynamic>[
      <String, dynamic>{
        'id': 7,
        'token': kToken,
        'assessment_id': 21,
        'name': 'Forklift Safety - Induction E2E',
        'state': 'available',
        'state_label': 'Available',
        'status_kind': 'ready',
        'progress': <String, dynamic>{'answered': 0, 'total': 3, 'percent': 0},
        'duration_minutes': 30,
        'started_at': null,
        'submitted_at': null,
        'result': <String, dynamic>{'released': false, 'is_pending': true},
        'can_review_answers': false,
      },
    ],
    'in_progress': <dynamic>[],
    'upcoming': <dynamic>[],
    'completed': <dynamic>[],
    'closed': <dynamic>[],
  },
  'total_count': 1,
};

/// The `assessment` and `rules` blocks every envelope carries, verbatim from
/// `serializers.exam_state_envelope`.
Map<String, dynamic> _assessmentBlock() => <String, dynamic>{
  'id': 21,
  'name': 'Forklift Safety - Induction E2E',
  'state': 'in_progress',
  'duration_minutes': 30,
};

Map<String, dynamic> _rulesBlock() => <String, dynamic>{
  'tab_switch': false,
  'copy_paste': false,
  'right_click': false,
  'devtools': false,
  'fullscreen': false,
  'webcam': false,
  'watermark': false,
  'watermark_label': '',
  'max_violations': 3,
  'violation_action': 'log_only',
  'violation_count': 0,
};

/// `/api/v1/exam/<token>/state` for a sitting that has not been started:
/// outcome `instructions`.
Map<String, dynamic> statePayload() => <String, dynamic>{
  'outcome': 'instructions',
  'assessment': _assessmentBlock(),
  'attempt': <String, dynamic>{
    'id': 7,
    'state': 'pending',
    'is_locked': false,
    'started_at': null,
    'deadline': null,
    'submitted_at': null,
    'total_questions': 3,
    'answered_count': 0,
    'results_released': false,
  },
  'rules': _rulesBlock(),
  'preview': false,
  'instructions': <String, dynamic>{
    'duration_minutes': 30,
    'total_questions': 3,
    'question_limit': 3,
  },
};

/// `/api/v1/exam/<token>/begin`. It answers with the FIRST question envelope,
/// which is the only place a candidate's first question ever comes from - the
/// assessment record they cannot load is the only other source.
Map<String, dynamic> beginPayload() => <String, dynamic>{
  'outcome': 'question',
  'assessment': _assessmentBlock(),
  'attempt': <String, dynamic>{
    'id': 7,
    'state': 'in_progress',
    'is_locked': false,
    'started_at': '2026-08-11T10:00:00Z',
    'deadline': '2026-08-11T10:30:00Z',
    'submitted_at': null,
    'total_questions': 3,
    'answered_count': 0,
    'results_released': false,
  },
  'rules': _rulesBlock(),
  'preview': false,
  'question': <String, dynamic>{
    'id': 10,
    'index': 1,
    'total': 3,
    'name': 'End of Shift Parking Procedure',
    'prompt':
        'An operator is finishing their shift and parking their '
        'counterbalance forklift in the designated bay. Describe the exact '
        'physical state the forklift must be left in.',
    'description': '',
    'question_type': 'subjective_rubric',
    'time_minutes': 0,
    'requires_justification': true,
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

/// Every route a candidate may call, and a 403 for every route they may not -
/// returning an empty object for the manager routes would quietly make the
/// test easier than the system it stands in for.
http.Client _candidateServer(List<String> calls) =>
    MockClient((http.Request req) async {
      final String p = req.url.path;
      calls.add(p);
      late final Map<String, dynamic> data;
      if (p.endsWith('/api/v1/me/assessments')) {
        data = meAssessmentsPayload();
      } else if (p.endsWith('/state')) {
        data = statePayload();
      } else if (p.endsWith('/begin')) {
        data = beginPayload();
      } else {
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

/// A store loaded exactly as a signed-in candidate's is: their attempts, and
/// no assessments at all.
Future<AppStore> candidateStore(WidgetTester t, List<String> calls) async {
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      client: _candidateServer(calls),
      bearer: 'access_token_stub',
    ),
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  await t.runAsync(() => s.refresh());
  return s;
}

/// The screen the "Start assessment" button navigates to: `nav.exam(token)`
/// is `Exam(token)` at `ExamStage.gate`, which the section maps to
/// `ExamSub.instructions`.
Widget mount(
  AppStore s,
  AssessmentNav nav, {
  ExamSub sub = ExamSub.instructions,
}) => MaterialApp(
  theme: ThemeData.dark(),
  home: AssessmentNavScope(
    nav: nav,
    child: ExamScreen(store: s, token: kToken, sub: sub),
  ),
);

List<String> screenText(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((Text w) => w.data ?? w.textSpan?.toPlainText() ?? '')
    .where((String s) => s.isNotEmpty)
    .toList();

Future<void> settle(WidgetTester t) async {
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('pressing Start on a cached attempt opens the instructions', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final List<String> calls = <String>[];
    final AppStore s = await candidateStore(t, calls);

    // The precondition that broke the screen, asserted so the test cannot
    // stop reproducing the bug without failing first.
    expect(
      s.attemptByToken(kToken),
      isNotNull,
      reason: 'the attempt is ALREADY cached - that is what skipped the fetch',
    );
    expect(
      s.asmById('21'),
      isNull,
      reason: '/api/v1/assessments is a manager route; a candidate 403s on it',
    );
    expect(
      calls.any((String c) => c.endsWith('/state')),
      isFalse,
      reason: 'nothing has opened the runner yet',
    );

    await t.pumpWidget(mount(s, AssessmentNav()));
    await settle(t);

    expect(
      calls.any((String c) => c.contains(kToken) && c.endsWith('/state')),
      isTrue,
      reason:
          'the runner must ask /exam/<token>/state even when the attempt is '
          'cached - it is the only route that carries the assessment',
    );
    expect(
      screenText(t),
      isNot(contains(kDeadLink)),
      reason: 'a token the server resolves must never read as a dead link',
    );

    // The instructions page itself, counted off the SERVER's envelope rather
    // than off `asm.questions`, which is empty on a live sitting.
    expect(find.text('Forklift Safety - Induction E2E'), findsOneWidget);
    // `textContaining`, not the whole sentence: the sub-line branches on
    // whether violations end the sitting, and both branches open this way.
    expect(find.textContaining('Follow these rules'), findsOneWidget);
    expect(find.text('3'), findsWidgets, reason: '3 questions, not 0');

    // WHO IS SITTING IT. `/me/assessments` above carries
    // `applicant: {id: 2, name: 'Utkarsh Jain E'}` and NO email, which is the
    // half-populated case: the name renders, and the separator that would join
    // it to an email must not appear on its own.
    expect(
      find.text('Utkarsh Jain E'),
      findsOneWidget,
      reason:
          'the applicant block was parsed and thrown away before - the page '
          'read "the invited candidate" to every real candidate',
    );
    expect(
      screenText(t).where((String s) => s.contains('  -  ')),
      isEmpty,
      reason: 'no email in the payload, so no dangling separator',
    );

    // `_rulesBlock` is `log_only`, so this mount is the suppressed-Notice
    // path: `violationConsequence`'s "The exam is never ended automatically."
    // must not reach a candidate. The function still returns it for the two
    // admin surfaces; `violation_notice_test.dart` pins that.
    expect(
      screenText(t).where((String s) => s.contains('never ended')),
      isEmpty,
      reason: 'the sub-line and the tick label already say this once each',
    );
  });

  testWidgets('Begin adopts the question the server answers with', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final List<String> calls = <String>[];
    final AppStore s = await candidateStore(t, calls);
    final AssessmentNav nav = AssessmentNav();

    await t.pumpWidget(mount(s, nav));
    await settle(t);

    // START IS GATED ON THE TICK. Pressing it before acknowledging must reach
    // no route at all - that is the whole point of the gate, and a `null`
    // `onPressed` is easy to reintroduce as a live one.
    await t.tap(find.text('Start Assessment'));
    await settle(t);
    expect(
      calls.any((String c) => c.endsWith('/begin')),
      isFalse,
      reason: 'Start must do nothing until the rules are acknowledged',
    );

    await t.tap(find.byType(AckBox));
    await settle(t);

    // The instructions page repeats the card's own wording.
    await t.tap(find.text('Start Assessment'));
    await settle(t);

    expect(
      calls.any((String c) => c.endsWith('/begin')),
      isTrue,
      reason: 'Begin must start the clock on the server',
    );

    // `/begin` answers with the first question, and the store used to throw
    // that response away - leaving the question page with nothing to render,
    // because a candidate's Assessment record carries no questions.
    final ExamView? view = s.examView(kToken);
    expect(view, isNotNull);
    expect(
      view!.question?.id,
      '10',
      reason: 'the runner must adopt the question /begin returned',
    );
    expect(view.total, 3);

    // And the navigator moved on to it.
    expect(nav.current, isA<Exam>());
    expect((nav.current as Exam).stage, ExamStage.question);
  });

  testWidgets('an unresolvable token still reads as a dead link', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    // The other half of the fix: loosening the gate must not make every bad
    // token look live. This store has nothing, and the server refuses.
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        client: MockClient((http.Request req) async {
          if (req.url.path.endsWith('/state')) {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': true,
                'data': <String, dynamic>{'outcome': 'invalid'},
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': false,
              'error': <String, dynamic>{'code': 'forbidden', 'message': 'no'},
            }),
            403,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        bearer: 'access_token_stub',
      ),
    );
    s.portal = Portal.member;
    s.source = DataSource.live;
    s.meId = '2';

    await t.pumpWidget(mount(s, AssessmentNav()));
    await settle(t);

    expect(screenText(t), contains(kDeadLink));
  });
}
