// A-074: under Log only the exam never ends, but reaching the cap is not
// silent. Once the server reports `violation_limit_breached`, the candidate
// sees it on the exam screen and again on the completion screen. Under
// Auto-submit the limit ends the exam, and the completion screen says so.
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

const String kToken = 'tok-a074';
const String kOnExam = 'You have reached the violation limit (20).';
const String kOnRecord = 'You reached the violation limit (20).';

/// Log only, cap 20, ONE violation so far - so only the server's flag can
/// raise the notice, never the count - unless [count] says otherwise.
AppStore _store({
  required bool breached,
  String state = 'in_progress',
  int count = 1,
  String action = 'log_only',
  int cap = 20,
  Map<String, dynamic> extra = const <String, dynamic>{},
  http.Client? client,
}) {
  final AppStore s = client == null
      ? AppStore()
      : AppStore(
          api: ApiClient(baseUrl: 'http://stub', client: client, bearer: 't'),
        );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': 7,
      'access_token': kToken,
      'assessment_id': 21,
      'state': state,
      'is_locked': state != 'in_progress',
      'started_at': DateTime.now().toUtc().toIso8601String(),
      'deadline': DateTime.now()
          .add(const Duration(hours: 1))
          .toUtc()
          .toIso8601String(),
      'violation_count': count,
      'violation_limit_breached': breached,
      ...extra,
    }),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 21,
      'name': 'sample test',
      'state': 'in_progress',
      'duration_minutes': 60,
      'violation_action': action,
      'max_violations': cap,
    }),
  ];
  s.examByToken[kToken] = ExamView.fromJson(<String, dynamic>{
    'outcome': 'question',
    'question': <String, dynamic>{
      'id': '10',
      'index': 1,
      'total': 3,
      'name': 'Question 1',
      'prompt': 'Prompt.',
      'question_type': 'subjective_rubric',
      'dimensions': <dynamic>[],
      'images': <dynamic>[],
      'videos': <dynamic>[],
      'label_boxes': <dynamic>[],
    },
    'answered_question_ids': <dynamic>[],
    'progress_percent': 0,
  });
  return s;
}

Future<void> _open(WidgetTester t, AppStore s, ExamSub sub) async {
  await t.pumpWidget(const SizedBox());
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: AssessmentNavScope(
        nav: AssessmentNav(),
        child: ExamScreen(store: s, token: kToken, sub: sub),
      ),
    ),
  );
  await t.pump();
}

bool _said(WidgetTester t, String line) => t
    .widgetList<RichText>(find.byType(RichText))
    .any((RichText r) => r.text.toPlainText().contains(line));

void main() {
  testWidgets('the breach notice follows violation_limit_breached', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    await _open(t, _store(breached: false), ExamSub.question);
    expect(_said(t, kOnExam), isFalse);
    expect(_said(t, 'Proctoring violation recorded (1).'), isTrue);

    await _open(t, _store(breached: true), ExamSub.question);
    expect(_said(t, kOnExam), isTrue);
    expect(_said(t, 'The exam continues'), isTrue);

    await _open(
      t,
      _store(breached: true, state: 'submitted'),
      ExamSub.complete,
    );
    expect(_said(t, kOnRecord), isTrue);
  });

  testWidgets('the count at the cap raises it with no flag on the row', (
    WidgetTester t,
  ) async {
    // A `/me/assessments` row, which replaces the attempt after a submit,
    // carries no flag - the same rule has to hold on the counts alone.
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    await _open(t, _store(breached: false, count: 20), ExamSub.question);
    expect(_said(t, kOnExam), isTrue);
  });

  testWidgets('a flag that arrives only in a /violation reply raises it', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    // The server dedups and counts its own way: 2 here, far under 20 on the
    // client's reckoning, and still over ITS limit.
    final AppStore s = _store(
      breached: false,
      client: MockClient(
        (http.Request req) async => http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'data': req.url.path.endsWith('/violation')
                ? <String, dynamic>{
                    'violation_count': 2,
                    'violation_limit_breached': true,
                  }
                : <String, dynamic>{},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      ),
    );
    await _open(t, s, ExamSub.question);
    expect(_said(t, kOnExam), isFalse);

    s.recordViolation('7', 'Tab switched / window hidden');
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump();

    expect(s.attemptByToken(kToken)!.violationLimitBreached, isTrue);
    expect(_said(t, kOnExam), isTrue);
    expect(_said(t, 'The exam continues'), isTrue);
  });

  testWidgets('Auto-submit at the cap: the completion screen says why', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    const Map<String, dynamic> ended = <String, dynamic>{
      'auto_submit_reason': 'violation',
    };
    await _open(
      t,
      _store(
        breached: false,
        state: 'submitted',
        count: 20,
        action: 'auto_submit',
        extra: ended,
      ),
      ExamSub.complete,
    );
    expect(
      _said(t, 'Auto-submitted: proctoring violation limit reached.'),
      isTrue,
    );
    expect(_said(t, kOnRecord), isTrue);
    expect(_said(t, 'Violation Limit Breached'), isTrue);
    expect(_said(t, 'Your answers were kept as they stood.'), isTrue);

    // The last change, flushed as the sitting ended, was refused: not "kept".
    final AppStore refused = _store(
      breached: false,
      state: 'submitted',
      count: 20,
      action: 'auto_submit',
      extra: ended,
    )..unsavedAtEnd.add('7');
    await _open(t, refused, ExamSub.complete);
    expect(_said(t, 'Your answers were kept as they stood.'), isFalse);
    expect(_said(t, 'Your last change may not count'), isTrue);

    // Cap 0 under Auto-submit: the first violation is the limit, and the
    // notice names 1, not 0.
    await _open(
      t,
      _store(
        breached: false,
        state: 'submitted',
        count: 1,
        action: 'auto_submit',
        cap: 0,
        extra: ended,
      ),
      ExamSub.complete,
    );
    expect(_said(t, 'You reached the violation limit (1).'), isTrue);

    // The runner never says "The exam continues" under Auto-submit.
    await _open(
      t,
      _store(breached: true, count: 20, action: 'auto_submit'),
      ExamSub.question,
    );
    expect(_said(t, 'The exam continues'), isFalse);
    expect(_said(t, 'Warning: proctoring violation 20 of 20.'), isTrue);
  });

  // The cap is the violation the exam ENDS at - the runner says "auto-submits
  // at 2" - so the completion screen must not call it an allowance: "allowed 2
  // and 2 were recorded" contradicts the exam having ended. Both kinds.
  testWidgets('the completion screen states the cap as the runner does', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    Future<void> endedBy(String reason, {required int cap, int count = 2}) =>
        _open(
          t,
          _store(
            breached: false,
            state: 'submitted',
            count: count,
            action: 'auto_submit',
            cap: cap,
            extra: <String, dynamic>{
              'auto_submit_reason': reason,
              'ai_violation_count': count,
            },
          ),
          ExamSub.complete,
        );

    await endedBy('violation', cap: 2);
    expect(
      _said(
        t,
        'This sitting ends at 2 proctoring violations, and 2 were recorded, '
        'so the exam ended itself.',
      ),
      isTrue,
    );
    expect(_said(t, 'allowed'), isFalse);

    await endedBy('ai_violation', cap: 2);
    expect(
      _said(
        t,
        'This sitting ends at 2 AI proctoring violations, and 2 were '
        'recorded, so the exam ended itself.',
      ),
      isTrue,
    );
    expect(_said(t, 'allowed'), isFalse);

    // Cap 0: the first violation ends it, named once per kind.
    await endedBy('violation', cap: 0, count: 1);
    expect(
      _said(t, 'This sitting ended on the first proctoring violation.'),
      isTrue,
    );
    await endedBy('ai_violation', cap: 0, count: 1);
    expect(
      _said(t, 'This sitting ended on the first AI proctoring violation.'),
      isTrue,
    );
  });

  testWidgets('the completion screen names an AI proctoring ending', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    Future<void> endedBy(String reason, {required int cap, int count = 2}) =>
        _open(
          t,
          _store(
            breached: false,
            state: 'submitted',
            count: 7,
            action: 'auto_submit',
            cap: cap,
            extra: <String, dynamic>{
              'auto_submit_reason': reason,
              'ai_violation_count': count,
            },
          ),
          ExamSub.complete,
        );

    await endedBy('ai_violation', cap: 2);
    expect(
      _said(t, 'Auto-submitted: AI proctoring violation limit reached.'),
      isTrue,
    );
    expect(
      _said(
        t,
        'This sitting ends at 2 AI proctoring violations, and 2 were '
        'recorded, so the exam ended itself.',
      ),
      isTrue,
      reason: 'the AI count (2), not the regular one (7)',
    );

    await endedBy('ai_violation', cap: 0, count: 1);
    expect(
      _said(t, 'This sitting ended on the first AI proctoring violation.'),
      isTrue,
    );

    // The regular ending reads exactly as before.
    await endedBy('violation', cap: 0, count: 1);
    expect(
      _said(t, 'This sitting ended on the first proctoring violation.'),
      isTrue,
    );
  });

  testWidgets('Log only with no cap never raises it', (WidgetTester t) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    await _open(t, _store(breached: false, count: 9, cap: 0), ExamSub.question);
    expect(_said(t, 'violation limit'), isFalse);
    await _open(
      t,
      _store(breached: false, state: 'submitted', count: 9, cap: 0),
      ExamSub.complete,
    );
    expect(_said(t, 'violation limit'), isFalse);
  });
}
