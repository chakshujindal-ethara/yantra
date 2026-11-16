// R5 on the candidate's screens: AI proctoring violations ("AI: " reasons)
// have their own count, cap and action. The runner says so per kind ("AI
// proctoring violation 1 of 2"), the instructions name the AI consequence,
// and an exam the AI count ended says it was AI proctoring.
//
// The store half is `ai_violations_count_apart_in_the_store_test.dart`.
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
import 'package:ethara_assessment/services/proctor_stub.dart';

const String kToken = 'tok-ai';
const String kPhone = 'AI: phone detected';

/// A watcher that keeps the violation callback the screen hands it.
class _Watch implements ProctorWatch {
  void Function(String reason)? onViolation;

  @override
  void start({
    required ProctorRules rules,
    required void Function(String reason) onViolation,
    void Function()? onCameraChanged,
  }) => this.onViolation = onViolation;

  @override
  void stop() {}
  @override
  void setEvidencePolicy(Map<String, Object?> policy) {}
  @override
  CameraState get cameraState => CameraState.on;
  @override
  void requestFullscreen() {}
  @override
  bool get isFullscreen => true;
  @override
  bool get needsFullscreenPrompt => false;
  @override
  bool get shouldOfferReturnToFullscreen => false;
  @override
  void exitFullscreen() {}
  @override
  void requestCamera() {}
  @override
  String get cameraMessage => '';
  @override
  String? get cameraViewType => null;
  @override
  String? fullscreenButtonView() => null;
  @override
  bool get fullscreenRefused => false;
  @override
  bool get fullscreenExitRecorded => false;
  @override
  bool get escapeCaptured => false;
}

/// Regular violations Log only (cap 3); AI ones Auto-submit at [aiCap].
/// `/violation` answers [ends]; `/me/...` is refused, so the re-read after an
/// ending keeps the rows on screen.
AppStore _store({
  required int aiCap,
  bool ends = false,
  bool started = true,
  String aiAction = 'auto_submit',
}) {
  final AppStore s =
      AppStore(
          api: ApiClient(
            baseUrl: 'http://stub',
            bearer: 't',
            client: MockClient((http.Request req) async {
              final String p = req.url.path;
              if (p.contains('/me/')) {
                return http.Response(
                  jsonEncode(<String, dynamic>{
                    'ok': false,
                    'error': <String, dynamic>{'code': 'forbidden'},
                  }),
                  403,
                  headers: <String, String>{'content-type': 'application/json'},
                );
              }
              return http.Response(
                jsonEncode(<String, dynamic>{
                  'ok': true,
                  'data': p.endsWith('/violation')
                      ? <String, dynamic>{
                          'recorded': true,
                          'attempt_ended': ends,
                          'violation_count': 0,
                          'ai_violation_count': 1,
                        }
                      : <String, dynamic>{},
                }),
                200,
                headers: <String, String>{'content-type': 'application/json'},
              );
            }),
          ),
        )
        ..portal = Portal.member
        ..source = DataSource.live
        ..meId = '2';
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': 7,
      'access_token': kToken,
      'assessment_id': 21,
      'state': started ? 'in_progress' : 'pending',
      'started_at': started ? DateTime.now().toUtc().toIso8601String() : null,
      'deadline': started
          ? DateTime.now()
                .add(const Duration(minutes: 30))
                .toUtc()
                .toIso8601String()
          : null,
    }),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 21,
      'name': 'ai paper',
      'state': 'in_progress',
      'duration_minutes': 45,
      'violation_action': 'log_only',
      'max_violations': 3,
      'ai_violation_action': aiAction,
      'ai_max_violations': aiCap,
      'rules': <String, dynamic>{'webcam': true, 'ai_proctor': true},
    }),
  ];
  s.examByToken[kToken] = ExamView.fromJson(<String, dynamic>{
    'outcome': started ? 'question' : 'instructions',
    if (started)
      'question': <String, dynamic>{
        'id': '10',
        'index': 1,
        'total': 1,
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
    'instructions': <String, dynamic>{'total_questions': 1},
  });
  return s;
}

Future<void> _mount(
  WidgetTester t,
  AppStore s,
  ExamSub sub, [
  ProctorWatch? watch,
]) async {
  t.view.physicalSize = const Size(1400, 2600);
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
          sub: sub,
          proctor: watch,
          warmAi: () async {},
        ),
      ),
    ),
  );
  await t.pump();
}

Future<void> _settle(WidgetTester t) async {
  for (int i = 0; i < 4; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump();
  }
}

bool _said(WidgetTester t, String line) => t
    .widgetList<RichText>(find.byType(RichText))
    .any((RichText r) => r.text.toPlainText().contains(line));

void main() {
  testWidgets('an AI violation is toasted and counted on its own line', (
    WidgetTester t,
  ) async {
    final AppStore s = _store(aiCap: 2);
    final _Watch w = _Watch();
    await _mount(t, s, ExamSub.question, w);

    w.onViolation!(kPhone);
    await t.pump();

    // The toast compared the regular count alone, which an AI reason never
    // moves, so it stayed silent.
    expect(_said(t, 'Proctoring: $kPhone - this has been noted.'), isTrue);
    expect(_said(t, 'Warning: AI proctoring violation 1 of 2.'), isTrue);
    // Nothing on the regular line: that count did not move.
    expect(_said(t, 'Proctoring violation'), isFalse);
    await _settle(t);
  });

  testWidgets('AI cap 1 under Auto: the ending names AI proctoring', (
    WidgetTester t,
  ) async {
    final AppStore s = _store(aiCap: 1, ends: true);
    final _Watch w = _Watch();
    await _mount(t, s, ExamSub.question, w);

    w.onViolation!(kPhone);
    await _settle(t);

    final Attempt ev = s.attemptByToken(kToken)!;
    expect(ev.isDone, isTrue, reason: 'the server ended it');
    expect(ev.autoSubmitReason, 'ai_violation');
    expect(
      _said(t, 'Auto-submitted: AI proctoring violation limit reached.'),
      isTrue,
    );
    expect(
      _said(t, 'This sitting ends at 1 AI proctoring violation, and 1 was'),
      isTrue,
    );
    expect(
      _said(t, 'You reached the AI proctoring violation limit (1).'),
      isTrue,
    );
    // Not the regular ending, whose limit was never reached.
    expect(_said(t, 'Auto-submitted: proctoring violation'), isFalse);
    expect(_said(t, 'You reached the violation limit'), isFalse);
    // The auto-submit toast runs out.
    await t.pump(const Duration(seconds: 4));
  });

  // A-074 per kind: under Log only the exam goes on past the AI cap, and the
  // page says once that the AI limit (not the regular one) was reached.
  testWidgets('AI cap reached under Log only: the notice names AI proctoring', (
    WidgetTester t,
  ) async {
    final AppStore s = _store(aiCap: 2, aiAction: 'log_only');
    s.attempts = <Attempt>[s.attempts.single.copyWith(aiViolationCount: 2)];
    await _mount(t, s, ExamSub.question, _Watch());

    expect(
      _said(t, 'You have reached the AI proctoring violation limit (2).'),
      isTrue,
    );
    expect(_said(t, 'The exam continues'), isTrue);
    // The regular count is 0: its limit was not reached.
    expect(_said(t, 'You have reached the violation limit'), isFalse);
    // It replaces the per-violation line.
    expect(_said(t, 'AI proctoring violation recorded'), isFalse);
  });

  testWidgets('the simulator rig counts each kind against its own cap', (
    WidgetTester t,
  ) async {
    final AppStore s = _store(aiCap: 2);
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ProctorRig(
            asm: s.assessments.single,
            violations: 1,
            aiViolations: 2,
            minimised: false,
            onToggle: () {},
            onViolate: (_) {},
            onBlockWebcam: () {},
            onBlockDeadline: () {},
          ),
        ),
      ),
    );
    expect(find.text('Violation 1 - log only'), findsOne);
    expect(find.text('AI violation 2 of 2 - auto-submits at 2'), findsOne);
  });

  testWidgets('the instructions name the AI consequence under Auto-submit', (
    WidgetTester t,
  ) async {
    await _mount(t, _store(aiCap: 2, started: false), ExamSub.instructions);
    await t.pump();

    expect(
      _said(t, 'AI proctoring: The exam auto-submits on violation 2.'),
      isTrue,
    );
    // The regular kind is Log only: no consequence of its own.
    expect(_said(t, 'The exam auto-submits on violation 3.'), isFalse);
    // Either kind can end it, so the page says the exam may end early.
    expect(
      find.text('Follow these rules or your exam may end early.'),
      findsOne,
    );
  });
}
