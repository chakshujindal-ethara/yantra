// The camera preview can be dragged anywhere on screen and stays on screen.
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

const String kToken = 'tok-cam-a';
const String kToken2 = 'tok-cam-b';

http.Response _reply(int status, Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

/// Stands in for the browser watcher. Like the real one, a stopped watcher
/// reports nothing: `stop()` drops the callback.
class _FakeProctor implements ProctorWatch {
  void Function(String reason)? onViolation;
  int stops = 0;

  void fire(String reason) => onViolation?.call(reason);

  @override
  void start({
    required ProctorRules rules,
    required void Function(String reason) onViolation,
    void Function()? onCameraChanged,
  }) => this.onViolation = onViolation;

  @override
  void stop() {
    stops++;
    onViolation = null;
  }

  @override
  void setEvidencePolicy(Map<String, Object?> policy) {}

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
  CameraState get cameraState => CameraState.idle;
  @override
  String get cameraMessage => '';
  @override
  String? get cameraViewType => 'cam-test-view';
  @override
  String? fullscreenButtonView() => null;
  @override
  bool get fullscreenRefused => false;
  @override
  bool get fullscreenExitRecorded => false;
  @override
  bool get escapeCaptured => false;
}

Map<String, dynamic> _attemptRow(String token, int id) => <String, dynamic>{
  'id': id,
  'access_token': token,
  'assessment_id': 21,
  'state': 'in_progress',
  'is_locked': false,
  'started_at': DateTime.now()
      .subtract(const Duration(minutes: 1))
      .toUtc()
      .toIso8601String(),
  'deadline': DateTime.now()
      .add(const Duration(minutes: 44))
      .toUtc()
      .toIso8601String(),
  'total_questions': 3,
};

ExamView _view() => ExamView.fromJson(<String, dynamic>{
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

AppStore _store() {
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      client: MockClient(
        (http.Request _) async => _reply(200, <String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{},
        }),
      ),
      bearer: 't',
    ),
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  s.attempts = <Attempt>[
    Attempt.fromJson(_attemptRow(kToken, 7)),
    Attempt.fromJson(_attemptRow(kToken2, 8)),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 21,
      'name': 'sample test',
      'state': 'in_progress',
      'duration_minutes': 45,
      'rules': <String, dynamic>{'fullscreen': true},
      'violation_action': 'auto_submit',
      'max_violations': 3,
    }),
  ];
  s.examByToken[kToken] = _view();
  s.examByToken[kToken2] = _view();
  return s;
}

void main() {
  testWidgets('the camera preview can be dragged but never off screen', (
    WidgetTester t,
  ) async {
    final original = cameraVideoBuilder;
    cameraVideoBuilder = (String _) => const SizedBox.expand();
    addTearDown(() => cameraVideoBuilder = original);
    final AppStore s = _store();
    final _FakeProctor proctor = _FakeProctor();
    t.view.physicalSize = const Size(1000, 700);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    Future<void> show(String token) => t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AssessmentNavScope(
          nav: AssessmentNav(),
          child: ExamScreen(
            store: s,
            token: token,
            sub: ExamSub.question,
            proctor: proctor,
          ),
        ),
      ),
    );

    const Key plate = ValueKey<String>('camera-plate');
    Offset topLeft() => t.getTopLeft(find.byKey(plate));

    await show(kToken);
    await t.pump();
    expect(find.byKey(plate), findsOneWidget);
    expect(
      find.bySemanticsLabel('Camera preview, drag to move'),
      findsOneWidget,
    );
    final Element before = t.element(find.byKey(plate));
    final Offset corner = topLeft();
    expect(corner.dx, 14);

    // A drag moves it by the drag distance.
    await t.dragFrom(corner + const Offset(20, 20), const Offset(300, -200));
    await t.pump();
    // The pan recogniser swallows the touch slop, so allow for it.
    expect(topLeft().dx, closeTo(corner.dx + 300, 40));
    expect(topLeft().dy, closeTo(corner.dy - 200, 40));
    expect(
      t.element(find.byKey(plate)),
      same(before),
      reason: 'a move must not remount the live video',
    );

    // Far past every edge: it stops at the screen bounds - and at the top,
    // under the top bar, never over its title, count and clock (BR-D6).
    await t.dragFrom(
      topLeft() + const Offset(20, 20),
      const Offset(5000, -5000),
    );
    await t.pump();
    expect(topLeft().dx, 1000 - kCameraPlateSize.width);
    final double underBar = t.getBottomLeft(find.byType(ExamTopBar)).dy;
    expect(underBar, greaterThan(0));
    expect(topLeft().dy, underBar);
    await t.dragFrom(
      topLeft() + const Offset(20, 20),
      const Offset(-5000, 5000),
    );
    await t.pump();
    expect(topLeft().dx, 0);
    expect(
      topLeft().dy + kCameraPlateSize.height,
      lessThanOrEqualTo(700 - 72),
      reason: 'never under the action bar',
    );

    // Same sitting, screen rebuilt (question navigation): position kept.
    final Offset moved = topLeft();
    await show(kToken);
    await t.pump();
    expect(topLeft(), moved);

    // A different sitting starts in the corner again.
    await show(kToken2);
    await t.pump();
    expect(topLeft(), corner);
  });

  testWidgets('on a phone and on a desktop the preview stays on screen and '
      'under the top bar', (WidgetTester t) async {
    final original = cameraVideoBuilder;
    cameraVideoBuilder = (String _) => const SizedBox.expand();
    addTearDown(() => cameraVideoBuilder = original);
    addTearDown(t.view.reset);
    const Key plate = ValueKey<String>('camera-plate');
    for (final Size screen in const <Size>[Size(390, 844), Size(1440, 900)]) {
      t.view.physicalSize = screen;
      t.view.devicePixelRatio = 1.0;
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          // The test font draws every glyph a full em wide, nearly twice a
          // real one, so at 390 px the bar's counts and the footer would
          // overflow here and not in a browser. Scaled to real widths.
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(0.55)),
            child: child!,
          ),
          home: AssessmentNavScope(
            nav: AssessmentNav(),
            child: ExamScreen(
              store: _store(),
              token: kToken,
              sub: ExamSub.question,
              proctor: _FakeProctor(),
            ),
          ),
        ),
      );
      await t.pump();
      final double underBar = t.getBottomLeft(find.byType(ExamTopBar)).dy;
      for (final Offset push in const <Offset>[
        Offset(-5000, -5000),
        Offset(5000, -5000),
        Offset(5000, 5000),
        Offset(-5000, 5000),
      ]) {
        final Rect at = t.getRect(find.byKey(plate));
        await t.dragFrom(at.topLeft + const Offset(20, 20), push);
        await t.pump();
        final Rect now = t.getRect(find.byKey(plate));
        expect(now.top, greaterThanOrEqualTo(underBar), reason: '$screen');
        expect(now.left, greaterThanOrEqualTo(0), reason: '$screen');
        expect(now.right, lessThanOrEqualTo(screen.width), reason: '$screen');
        expect(
          now.bottom,
          lessThanOrEqualTo(screen.height - 72),
          reason: '$screen',
        );
      }
      await t.pumpWidget(const SizedBox());
    }
  });
}
