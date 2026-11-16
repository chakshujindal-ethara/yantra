// L6: behind a blocking overlay the clock is still heard, and the focus
// comes back when the overlay clears.
//
// The camera and fullscreen gates both say "The clock keeps running", but the
// exclusion that keeps the paper out of reach covered the top bar too, so a
// screen-reader user could not hear how long they had left. And when the gate
// cleared, the answer box they had been typing in did not get the focus back.
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

const String kToken = 'tok-l6';

/// A watcher whose camera the test turns off and on.
class _Camera implements ProctorWatch {
  CameraState camera = CameraState.on;
  void Function()? changed;

  @override
  void start({
    required ProctorRules rules,
    required void Function(String reason) onViolation,
    void Function()? onCameraChanged,
  }) => changed = onCameraChanged;

  @override
  void stop() => changed = null;
  @override
  void setEvidencePolicy(Map<String, Object?> policy) {}
  @override
  CameraState get cameraState => camera;
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

void main() {
  testWidgets('the clock is heard behind the camera gate, and the answer box '
      'gets the focus back when it clears', (WidgetTester t) async {
    final SemanticsHandle sem = t.ensureSemantics();
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        bearer: 't',
        client: MockClient(
          (http.Request req) async => http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          ),
        ),
      ),
    );
    s.portal = Portal.member;
    s.source = DataSource.live;
    s.meId = '2';
    final DateTime end = DateTime.now().add(const Duration(minutes: 30));
    s.attempts = <Attempt>[
      Attempt.fromJson(<String, dynamic>{
        'id': 7,
        'access_token': kToken,
        'assessment_id': 21,
        'state': 'in_progress',
        'started_at': DateTime.now().toUtc().toIso8601String(),
        'deadline': end.toUtc().toIso8601String(),
      }),
    ];
    s.assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': 21,
        'name': 'sample test',
        'state': 'in_progress',
        'duration_minutes': 45,
        'rules': <String, dynamic>{'webcam': true},
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
    final _Camera camera = _Camera();

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
            proctor: camera,
          ),
        ),
      ),
    );
    await t.pump();

    await t.showKeyboard(find.byType(TextField).first);
    final FocusNode field = t
        .widget<EditableText>(find.byType(EditableText).first)
        .focusNode;
    expect(field.hasFocus, isTrue);

    // The camera drops: the gate goes up over the paper.
    camera.camera = CameraState.off;
    camera.changed!();
    await t.pump();
    await t.pump();
    expect(find.text('Your camera is off'), findsOneWidget);
    expect(field.hasFocus, isFalse, reason: 'the paper is out of reach');
    expect(
      t.getSemantics(find.text('Your camera is off')),
      isSemantics(isHeader: true, isFocused: true),
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^Time remaining: ')),
      findsOneWidget,
      reason: 'the clock keeps running, so a screen reader must hear it',
    );

    // The camera is back: the answer box has the focus it had.
    camera.camera = CameraState.on;
    camera.changed!();
    await t.pump();
    await t.pump();
    expect(find.text('Your camera is off'), findsNothing);
    expect(field.hasFocus, isTrue);

    sem.dispose();
  });
}
