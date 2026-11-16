// R9b/d: AI proctoring starts late because its models download at Begin.
// The instructions page now asks for them early (once, and only on a paper
// with AI proctoring), and ticking the acknowledgement asks for the camera,
// so the permission prompt comes before Begin and fullscreen.
//
// Leaving the page lets the warmed models go (about 30 MB): only a bridge
// that started used to release them, so "Not Now" kept them resident.
//
// While the exam is watched, the AI's status (`running`, `failed`)
// reaches the server through `aiStatusSink`, which the screen sets and clears.
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
import 'package:ethara_assessment/assessment/widgets/controls.dart';
import 'package:ethara_assessment/services/proctor_stub.dart';

const String kToken = 'tok-warm';

class _Watch implements ProctorWatch {
  final List<ProctorRules> started = <ProctorRules>[];
  final List<Map<String, Object?>> policies = <Map<String, Object?>>[];

  @override
  void start({
    required ProctorRules rules,
    required void Function(String reason) onViolation,
    void Function()? onCameraChanged,
  }) => started.add(rules);
  @override
  void stop() {}
  @override
  void setEvidencePolicy(Map<String, Object?> policy) => policies.add(policy);
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

AppStore _store(
  List<String> paths, {
  required bool ai,
  bool webcam = true,
  bool started = false,
  bool evidence = false,
}) {
  final AppStore s =
      AppStore(
          api: ApiClient(
            baseUrl: 'http://stub',
            bearer: 't',
            client: MockClient((http.Request req) async {
              paths.add(req.url.path);
              return http.Response(
                jsonEncode(<String, dynamic>{
                  'ok': true,
                  'data': <String, dynamic>{},
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
    }),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 21,
      'name': 'warm paper',
      'state': 'in_progress',
      'duration_minutes': 45,
      'rules': <String, dynamic>{
        'webcam': webcam,
        'ai_proctor': ai,
        // An old paper: eye movement is gone, so this asks for nothing more.
        'gaze_review': ai,
      },
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
    'instructions': <String, dynamic>{'total_questions': 1},
    if (evidence)
      'evidence_upload': <String, dynamic>{
        'url': 'https://bucket.example/',
        'fields': <String, dynamic>{'policy': 'p'},
        'prefix': 'evidence/7/',
        'expires_at': '2099-01-01T00:00:00Z',
        'max_bytes': 400000,
        'content_type': 'image/jpeg',
      },
  });
  return s;
}

Future<void> _mount(
  WidgetTester t,
  AppStore s, {
  required ExamSub sub,
  List<int>? warmed,
  List<int>? cameraAsked,
  List<int>? released,
  ProctorWatch? watch,
}) async {
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
          warmAi: () async => warmed?.add(1),
          releaseWarmAi: () => released?.add(1),
          askCamera: () async {
            cameraAsked?.add(1);
            return null;
          },
        ),
      ),
    ),
  );
  await t.pump();
}

void main() {
  testWidgets('the models are asked for once, on a paper with AI', (
    WidgetTester t,
  ) async {
    final List<int> warmed = <int>[];
    final AppStore s = _store(<String>[], ai: true);
    await _mount(t, s, sub: ExamSub.instructions, warmed: warmed);

    // Rebuilds of the page ask nothing more.
    s.notifyListeners();
    await t.pump();
    s.notifyListeners();
    await t.pump();

    expect(warmed, <int>[1], reason: 'once, and never an eye model');
  });

  testWidgets('never on a paper without AI', (WidgetTester t) async {
    final List<int> warmed = <int>[];
    await _mount(
      t,
      _store(<String>[], ai: false),
      sub: ExamSub.instructions,
      warmed: warmed,
    );
    expect(warmed, isEmpty);
  });

  testWidgets('leaving the page lets the warmed models go, once', (
    WidgetTester t,
  ) async {
    final List<int> released = <int>[];
    await _mount(
      t,
      _store(<String>[], ai: true),
      sub: ExamSub.instructions,
      released: released,
    );
    expect(released, isEmpty, reason: 'kept while the page is open');

    await t.pumpWidget(const SizedBox());
    expect(released, <int>[1]);
  });

  testWidgets('nothing to let go on a paper without AI', (
    WidgetTester t,
  ) async {
    final List<int> released = <int>[];
    await _mount(
      t,
      _store(<String>[], ai: false),
      sub: ExamSub.instructions,
      released: released,
    );
    await t.pumpWidget(const SizedBox());
    expect(released, isEmpty);
  });

  testWidgets('the tick asks for the camera once when the webcam rule is on', (
    WidgetTester t,
  ) async {
    final List<int> asked = <int>[];
    await _mount(
      t,
      _store(<String>[], ai: true),
      sub: ExamSub.instructions,
      cameraAsked: asked,
    );
    expect(asked, isEmpty, reason: 'not before the tick');

    // Tick, untick, tick.
    for (int i = 0; i < 3; i++) {
      await t.tap(find.byType(AckBox));
      await t.pump();
    }
    expect(asked, hasLength(1));
  });

  testWidgets('no camera question on a paper without the webcam rule', (
    WidgetTester t,
  ) async {
    final List<int> asked = <int>[];
    await _mount(
      t,
      _store(<String>[], ai: false, webcam: false),
      sub: ExamSub.instructions,
      cameraAsked: asked,
    );
    await t.tap(find.byType(AckBox));
    await t.pump();
    expect(asked, isEmpty);
  });

  testWidgets('the screen sets the AI status sink while it watches', (
    WidgetTester t,
  ) async {
    final List<String> paths = <String>[];
    await _mount(
      t,
      _store(paths, ai: true, started: true),
      sub: ExamSub.question,
      watch: _Watch(),
    );
    expect(aiStatusSink, isNotNull);

    aiStatusSink!('running');
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(paths, contains('/api/v1/exam/$kToken/ai-status'));

    await t.pumpWidget(const SizedBox());
    expect(aiStatusSink, isNull, reason: 'cleared with the screen');
  });

  testWidgets('it clears only its own sink', (WidgetTester t) async {
    await _mount(
      t,
      _store(<String>[], ai: true, started: true),
      sub: ExamSub.question,
      watch: _Watch(),
    );
    void other(String _) {}
    aiStatusSink = other;

    await t.pumpWidget(const SizedBox());
    expect(aiStatusSink, other, reason: 'a newer screen set this one');
    aiStatusSink = null;
  });

  testWidgets('a started paper with AI hands the watcher the rule and policy', (
    WidgetTester t,
  ) async {
    final _Watch watch = _Watch();
    await _mount(
      t,
      _store(<String>[], ai: true, started: true, evidence: true),
      sub: ExamSub.question,
      watch: watch,
    );
    expect(watch.started.single.aiProctor, isTrue);
    expect(watch.policies, hasLength(1));
    expect(watch.policies.single['prefix'], 'evidence/7/');
    expect(watch.policies.single['landed'], isNotNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('without ai_proctor nothing AI starts, policy or not', (
    WidgetTester t,
  ) async {
    final List<String> paths = <String>[];
    final List<int> warmed = <int>[];
    final _Watch watch = _Watch();
    await _mount(
      t,
      _store(paths, ai: false, started: true, evidence: true),
      sub: ExamSub.question,
      watch: watch,
      warmed: warmed,
    );
    expect(watch.started.single.webcam, isTrue, reason: 'the camera still');
    expect(watch.started.single.aiProctor, isFalse);
    expect(aiStatusSink, isNull);
    expect(warmed, isEmpty);
    expect(watch.policies, isEmpty, reason: 'no snapshots without the rule');
    expect(paths.where((String p) => p.endsWith('/ai-status')), isEmpty);
    await t.pumpWidget(const SizedBox());
  });
}
