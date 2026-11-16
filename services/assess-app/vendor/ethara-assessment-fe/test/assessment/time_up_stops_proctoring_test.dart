// MT3-01: after the time-up overlay, proctoring is over.
//
// The watcher kept running under the overlay, so Escape or a tab switch there
// still fired a violation - at the cap that auto-submitted the paper as a
// proctoring ending ("Auto-submitted: proctoring violation limit reached")
// instead of "Ended on the clock". And a `/violation` the server answers with
// 409 `time_expired` must settle on the clock, never as a violation.
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
import 'package:ethara_assessment/services/proctor_stub.dart';

const String kToken = 'tok-mt301';

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
  void setEvidencePolicy(Map<String, Object?> policy) {}

  @override
  void stop() {
    stops++;
    onViolation = null;
  }

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

Map<String, dynamic> _attemptRow(
  DateTime deadline, {
  String state = 'in_progress',
}) => <String, dynamic>{
  'id': 7,
  'access_token': kToken,
  'assessment_id': 21,
  'state': state,
  'is_locked': state != 'in_progress',
  'auto_submitted': state != 'in_progress',
  'auto_submit_reason': state != 'in_progress' ? 'expired' : '',
  'started_at': deadline
      .subtract(const Duration(minutes: 45))
      .toUtc()
      .toIso8601String(),
  'deadline': deadline.toUtc().toIso8601String(),
  'total_questions': 3,
};

Map<String, dynamic> _asm({required int cap}) => <String, dynamic>{
  'id': 21,
  'name': 'sample test',
  'state': 'in_progress',
  'duration_minutes': 45,
  'rules': <String, dynamic>{'fullscreen': true, 'tab_switch': true},
  'violation_action': 'auto_submit',
  'max_violations': cap,
};

AppStore _store(
  http.Client client,
  DateTime deadline, {
  int cap = 1,
  Duration answerDebounce = AppStore.answerDebounceDefault,
}) {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: client, bearer: 't'),
    answerDebounce: answerDebounce,
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  s.attempts = <Attempt>[Attempt.fromJson(_attemptRow(deadline))];
  s.assessments = <Assessment>[Assessment.fromJson(_asm(cap: cap))];
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

void main() {
  testWidgets(
    'a fullscreen exit behind the time-up overlay is not a violation',
    (WidgetTester t) async {
      final List<String> violations = <String>[];
      final AppStore s = _store(
        MockClient((http.Request req) async {
          if (req.url.path.endsWith('/violation')) violations.add(req.body);
          return _reply(200, <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{},
          });
        }),
        DateTime.now().subtract(const Duration(minutes: 1)),
      );
      final _FakeProctor proctor = _FakeProctor();

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
              proctor: proctor,
            ),
          ),
        ),
      );
      await t.pump();
      expect(
        proctor.onViolation,
        isNotNull,
        reason: 'the watcher is armed, so the check below is not vacuous',
      );

      await t.pump(const Duration(seconds: 1));
      await t.pump();
      expect(find.text('Time is up'), findsOneWidget);

      // Escape out of fullscreen, then a tab switch, under the overlay.
      proctor.fire('Exited fullscreen');
      proctor.fire('Tab switched / window hidden');
      await t.pump();
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pump();

      expect(violations, isEmpty, reason: 'nothing reaches /violation');
      final Attempt ev = s.attemptByToken(kToken)!;
      expect(ev.violationCount, 0);
      expect(
        ev.isDone,
        isFalse,
        reason: '"See my submission" ends it, not this',
      );
      expect(
        s.toaster.items.map((ToastMsg m) => m.message).join(' | '),
        isNot(contains('violation')),
      );
      expect(find.text('Time is up'), findsOneWidget);
      expect(proctor.stops, greaterThan(0));
      await t.pump(const Duration(seconds: 4));
    },
  );

  test('a /violation answered 409 time_expired ends it on the clock', () async {
    final DateTime gone = DateTime.now().subtract(const Duration(seconds: 5));
    final AppStore s = _store(
      MockClient((http.Request req) async {
        final String path = req.url.path;
        if (path.endsWith('/violation')) {
          return _reply(409, <String, dynamic>{
            'ok': false,
            'error': <String, dynamic>{
              'code': 'time_expired',
              'message': 'Your time has expired; the attempt was submitted.',
            },
          });
        }
        if (path.endsWith('/state')) {
          return _reply(200, <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{
              'outcome': 'complete',
              'attempt': _attemptRow(gone, state: 'submitted'),
            },
          });
        }
        return _reply(200, <String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{},
        });
      }),
      gone,
      cap: 3,
    );

    s.recordViolation('7', 'Exited fullscreen');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final List<String> said = s.toaster.items
        .map((ToastMsg m) => m.message)
        .toList();
    expect(said, contains(AppStore.timeUpMessage));
    expect(said.join(' | '), isNot(contains('violation threshold')));
    expect(s.examView(kToken)?.outcome, 'complete');
    final Attempt ev = s.attemptByToken(kToken)!;
    expect(ev.isDone, isTrue);
    expect(ev.autoSubmitReason, 'expired');
  });

  // M1. Inside its 10s grace the server no longer settles the paper on a
  // `/violation`: it answers 409 `time_expired` with `answer_saved: false`
  // and leaves the paper open, so the typing still pending can land. The
  // client used to mark the sitting complete at once - cancelling that
  // autosave unsent - and then said "your answers are saved".
  for (final bool kept in <bool>[true, false]) {
    test('a /violation 409 in the grace sends the pending answer first '
        '(the flushed save ${kept ? 'kept' : 'refused'})', () async {
      final DateTime gone = DateTime.now().subtract(const Duration(seconds: 3));
      final List<String> answers = <String>[];
      final List<String?> outcomeAtAnswer = <String?>[];
      late final AppStore s;
      s = _store(
        MockClient((http.Request req) async {
          final String path = req.url.path;
          if (path.endsWith('/violation')) {
            return _reply(409, <String, dynamic>{
              'ok': false,
              'error': <String, dynamic>{
                'code': 'time_expired',
                'message': 'Your time has expired.',
              },
              'answer_saved': false,
            });
          }
          if (path.endsWith('/answer')) {
            answers.add(req.body);
            outcomeAtAnswer.add(s.examView(kToken)?.outcome);
            // `/answer` meets the deadline itself, keeps (or refuses) the
            // text, and settles the paper.
            return _reply(409, <String, dynamic>{
              'ok': false,
              'error': <String, dynamic>{
                'code': 'time_expired',
                'message': 'Your time has expired; the attempt was submitted.',
              },
              'answer_saved': kept,
            });
          }
          if (path.endsWith('/state')) {
            return _reply(200, <String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{
                'outcome': 'complete',
                'attempt': _attemptRow(gone, state: 'submitted'),
              },
            });
          }
          return _reply(200, <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{},
          });
        }),
        gone,
        cap: 3,
        // Far longer than the test runs, so only a flush can send it.
        answerDebounce: const Duration(seconds: 30),
      );

      s.saveAnswerQuiet(
        '7',
        '10',
        const Response(justification: 'Typed in time'),
      );
      s.recordViolation('7', 'Exited fullscreen');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(answers, hasLength(1), reason: 'the pending text is sent once');
      expect(answers.single, contains('Typed in time'));
      expect(
        outcomeAtAnswer.single,
        'question',
        reason: 'sent BEFORE the runner was moved to its completion screen',
      );
      expect(s.examView(kToken)?.outcome, 'complete');
      expect(
        s.toaster.items.map((ToastMsg m) => m.message).toList(),
        kept
            ? <String>[AppStore.timeUpMessage]
            : <String>[
                AppStore.timeUpMessage,
                AppStore.timeUpIncompleteMessage,
              ],
        reason: 'the /answer reply decides the wording, once',
      );
    });
  }
}
