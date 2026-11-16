// Owner Q12: at time-up the candidate hears "Time's up - your answers are
// saved." on every path, and never that proctoring ended the exam.
//
// Three paths meet the deadline, and before this only Next said anything:
//  - Next / Previous after expiry (examAdvance)                    F3-13
//  - the debounced autosave in flight at the deadline, silent      R7-04, G2-03
//  - the deadline overlay's "See my submission" (finishExam flush):
//    "violation threshold" plus a false "could not be re-sent"     G2-04, G2-03
// And an incomplete last answer drew a red "not saved" for an A/B draft the
// server keeps and grades                                          G2-05
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
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

const String kToken = 'tok-q12';

http.Response _reply(int status, Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

Map<String, dynamic> _question({bool ab = false}) => <String, dynamic>{
  'id': '10',
  'index': 1,
  'total': 3,
  'name': 'Question 1',
  'prompt': 'Prompt.',
  'question_type': ab ? 'image_ab' : 'subjective_rubric',
  'requires_justification': ab,
  'dimensions': ab
      ? <dynamic>[
          <String, dynamic>{
            'code': 'D1',
            'name': 'Overall Choice',
            'options': <dynamic>[
              <String, dynamic>{'id': 'o-a', 'label': 'A is better'},
              <String, dynamic>{'id': 'o-b', 'label': 'B is better'},
            ],
          },
        ]
      : <dynamic>[],
  'images': ab
      ? <dynamic>[
          <String, dynamic>{'slot': 'a', 'url': 'https://img.test/a.png'},
          <String, dynamic>{'slot': 'b', 'url': 'https://img.test/b.png'},
        ]
      : <dynamic>[],
  'videos': <dynamic>[],
  'label_boxes': <dynamic>[],
  'answer': <String, dynamic>{
    'answered': false,
    'selected_option_ids': <dynamic>[],
    'justification': '',
    'label_answers': <String, dynamic>{},
  },
};

Map<String, dynamic> _attemptRow(DateTime deadline) => <String, dynamic>{
  'id': 7,
  'access_token': kToken,
  'assessment_id': 21,
  'state': 'in_progress',
  'started_at': deadline
      .subtract(const Duration(minutes: 45))
      .toUtc()
      .toIso8601String(),
  'deadline': deadline.toUtc().toIso8601String(),
  'total_questions': 3,
};

/// `/answer` answers 409 `time_expired` (the server saved first, then
/// settled); `/submit` then finds the attempt locked, or accepts it when
/// nothing was pending.
http.Client _server({required bool answerSaved, bool submitLocked = true}) =>
    MockClient((http.Request req) async {
      final String path = req.url.path;
      if (path.endsWith('/answer')) {
        return _reply(409, <String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'time_expired',
            'message': 'Your time has expired; the attempt was submitted.',
          },
          'answer_saved': answerSaved,
        });
      }
      if (path.endsWith('/submit') && submitLocked) {
        return _reply(409, <String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'attempt_locked',
            'message': 'This attempt is already submitted',
          },
        });
      }
      return _reply(200, <String, dynamic>{
        'ok': true,
        'data': <String, dynamic>{},
      });
    });

AppStore _store({
  required http.Client client,
  required DateTime deadline,
  bool ab = false,
  Response? pending,
}) {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: client, bearer: 't'),
    answerDebounce: const Duration(milliseconds: 10),
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  final Attempt a = Attempt.fromJson(_attemptRow(deadline));
  if (pending != null) a.resp['10'] = pending;
  s.attempts = <Attempt>[a];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 21,
      'name': 'sample test',
      'state': 'in_progress',
      'duration_minutes': 45,
    }),
  ];
  s.examByToken[kToken] = ExamView.fromJson(<String, dynamic>{
    'outcome': 'question',
    'question': _question(ab: ab),
    'answered_question_ids': <dynamic>[],
    'progress_percent': 0,
  });
  return s;
}

Future<void> _settle(WidgetTester t) async {
  await t.pumpAndSettle();
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 40)),
  );
  await t.pumpAndSettle();
}

Future<void> _open(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1400, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
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
  await _settle(t);
}

List<String> _messages(AppStore s) =>
    s.toaster.items.map((ToastMsg m) => m.message).toList();

/// Toasts arm a 3200ms dismissal; the test must outlive them.
Future<void> _drain(WidgetTester t) async {
  await t.pump(const Duration(milliseconds: 3400));
  await t.pumpAndSettle();
}

void _expectNoBlame(AppStore s) {
  final String all = _messages(s).join(' | ');
  expect(all, isNot(contains('violation')));
  expect(all, isNot(contains('could not be re-sent')));
  expect(all, isNot(contains('not saved')));
  expect(
    s.toaster.items.map((ToastMsg m) => m.tone),
    isNot(contains(Tone.bad)),
  );
}

void main() {
  final DateTime later = DateTime.now().add(const Duration(hours: 1));
  final DateTime gone = DateTime.now().subtract(const Duration(minutes: 1));

  testWidgets('Next after the deadline: time is up, answers saved', (
    WidgetTester t,
  ) async {
    final AppStore s = _store(
      client: _server(answerSaved: true),
      deadline: later,
      pending: const Response(justification: 'Last sentence.'),
    );
    await _open(t, s);

    await t.tap(find.text('Next'));
    await _settle(t);

    expect(_messages(s), <String>[AppStore.timeUpMessage]);
    _expectNoBlame(s);
    await _drain(t);
  });

  testWidgets('the autosave that meets the deadline says so too (R7-04)', (
    WidgetTester t,
  ) async {
    final AppStore s = _store(
      client: _server(answerSaved: true),
      deadline: later,
    );
    await _open(t, s);

    await t.enterText(find.byType(TextField).first, 'Typing at the buzzer');
    await t.pump(const Duration(milliseconds: 50));
    await _settle(t);

    expect(
      _messages(s),
      <String>[AppStore.timeUpMessage],
      reason: 'the autosave caught the 409 and moved on without a word',
    );
    _expectNoBlame(s);
    await _drain(t);
  });

  testWidgets('an A/B draft the server keeps is not called "not saved"', (
    WidgetTester t,
  ) async {
    // G2-05: verdicts picked, required justification empty. The server says
    // answer_saved:false but promotes and grades the draft at settlement.
    final AppStore s = _store(
      client: _server(answerSaved: false),
      deadline: later,
      ab: true,
    );
    await _open(t, s);

    await t.tap(find.text('A is better'));
    await t.pump(const Duration(milliseconds: 50));
    await _settle(t);

    expect(_messages(s), <String>[
      AppStore.timeUpMessage,
      AppStore.timeUpIncompleteMessage,
    ]);
    _expectNoBlame(s);
    await _drain(t);
  });

  testWidgets('the buzzer blames the clock, not proctoring (G2-04)', (
    WidgetTester t,
  ) async {
    // An answer typed seconds before the deadline, still in the debounce: the
    // flush gets time_expired + answer_saved:true, the submit attempt_locked.
    final AppStore s = _store(
      client: _server(answerSaved: true),
      deadline: gone,
      pending: const Response(justification: 'Final words before the buzzer.'),
    );
    await _open(t, s);

    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(find.text('Time is up'), findsOneWidget);
    // Nothing is submitted until "See my submission".
    expect(find.textContaining(AppStore.timeUpMessage), findsOneWidget);
    expect(find.textContaining('submitted as they stand'), findsNothing);

    await t.tap(find.text('See my submission'));
    await _settle(t);

    expect(
      _messages(s).where((String m) => m == AppStore.timeUpMessage),
      hasLength(1),
    );
    _expectNoBlame(s);
    await _drain(t);
  });

  testWidgets('the buzzer with nothing pending says the same', (
    WidgetTester t,
  ) async {
    final AppStore s = _store(
      client: _server(answerSaved: true, submitLocked: false),
      deadline: gone,
    );
    await _open(t, s);

    await t.pump(const Duration(seconds: 1));
    await t.pump();
    await t.tap(find.text('See my submission'));
    await _settle(t);

    expect(_messages(s), contains(AppStore.timeUpMessage));
    _expectNoBlame(s);
    await _drain(t);
  });

  test('a manual submit that meets the deadline is told the same', () async {
    final AppStore s = _store(
      client: _server(answerSaved: false),
      deadline: later,
      pending: const Response(justification: 'x'),
    );
    s.finishExam('7');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(_messages(s), <String>[
      AppStore.timeUpMessage,
      AppStore.timeUpIncompleteMessage,
    ]);
  });
}
