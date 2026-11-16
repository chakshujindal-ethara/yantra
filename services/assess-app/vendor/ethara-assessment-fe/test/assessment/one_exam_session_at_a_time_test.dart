// One exam session at a time; the newest tab wins.
//
// Every runner call carries this tab's `session_key`. `/state` and `/begin`
// make the tab the one holding the sitting, and a write from a tab that no
// longer holds it is refused with 409 `session_replaced` and stores nothing.
// That tab then stops saving and stops proctoring - no violation, no end - and
// shows a blocking notice whose "Continue Here" re-reads `/state`, which takes
// the sitting back.
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

const String kToken = 'tok-one-tab';
const String kReplaced =
    'This exam is open in another tab or device. You can continue there, or '
    'continue here instead.';

http.Response _reply(int status, Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

http.Response _ok(Map<String, dynamic> data) =>
    _reply(200, <String, dynamic>{'ok': true, 'data': data});

final http.Response _replacedReply = _reply(409, <String, dynamic>{
  'ok': false,
  'error': <String, dynamic>{
    'code': 'session_replaced',
    'message': 'This exam is now open in another tab or device.',
  },
});

/// The route's last segment and the key its body carried.
typedef Sent = ({String route, String? key});

Sent _sent(http.Request req) => (
  route: req.url.path.split('/').last,
  key:
      (req.body.isEmpty
              ? null
              : jsonDecode(req.body) as Map<String, dynamic>)?['session_key']
          as String?,
);

Map<String, dynamic> get _attempt => <String, dynamic>{
  'id': 7,
  'access_token': kToken,
  'assessment_id': 21,
  'state': 'in_progress',
  'started_at': DateTime.now().toUtc().toIso8601String(),
  'deadline': DateTime.now()
      .add(const Duration(hours: 1))
      .toUtc()
      .toIso8601String(),
};

Map<String, dynamic> get _asm => <String, dynamic>{
  'id': 21,
  'name': 'sample test',
  'state': 'in_progress',
  'duration_minutes': 60,
  'rules': <String, dynamic>{'fullscreen': true, 'tab_switch': true},
  'violation_action': 'auto_submit',
  'max_violations': 1,
};

Map<String, dynamic> get _question => <String, dynamic>{
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
};

/// The `question` gate envelope, as `/state` and `/begin` answer it.
Map<String, dynamic> get _envelope => <String, dynamic>{
  'outcome': 'question',
  'attempt': _attempt,
  'assessment': _asm,
  'question': _question,
  'answered_question_ids': <dynamic>[],
};

/// Stands in for the browser watcher. Like the real one, a stopped watcher
/// reports nothing: `stop()` drops the callback.
class _FakeProctor implements ProctorWatch {
  void Function(String reason)? onViolation;
  int stops = 0;

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

AppStore _store(http.Client client) {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', bearer: 't', client: client),
    answerDebounce: const Duration(milliseconds: 10),
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  return s;
}

/// Let the mock's replies land, then paint what they changed.
Future<void> _settle(WidgetTester t) async {
  await t.pump(const Duration(milliseconds: 20));
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 40)),
  );
  await t.pump();
}

/// A sitting on screen whose first autosave another tab has refused.
Future<(AppStore, List<Sent>, _FakeProctor)> _replacedSitting(
  WidgetTester t,
) async {
  t.view.physicalSize = const Size(1400, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  final List<Sent> sent = <Sent>[];
  final AppStore s = _store(
    MockClient((http.Request req) async {
      final Sent one = _sent(req);
      sent.add(one);
      if (one.route == 'answer') return _replacedReply;
      if (one.route == 'state') return _ok(_envelope);
      if (one.route == 'assessments') {
        return _ok(<String, dynamic>{
          'buckets': <String, dynamic>{
            'in_progress': <dynamic>[_attempt],
          },
        });
      }
      return _ok(<String, dynamic>{});
    }),
  );
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{..._attempt, 'access_token': kToken}),
  ];
  s.assessments = <Assessment>[Assessment.fromJson(_asm)];
  s.examByToken[kToken] = ExamView.fromJson(_envelope);

  final _FakeProctor proctor = _FakeProctor();
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
  expect(proctor.onViolation, isNotNull, reason: 'the watcher is armed');
  expect(find.text(kReplaced), findsNothing);

  s.saveAnswerQuiet('7', '10', Response(justification: 'typed here'));
  await _settle(t);
  return (s, sent, proctor);
}

void main() {
  test('the key rides on every runner call and survives a reload', () async {
    final List<Sent> sent = <Sent>[];
    ApiClient client() => ApiClient(
      baseUrl: 'http://stub',
      bearer: 't',
      client: MockClient((http.Request req) async {
        sent.add(_sent(req));
        return _ok(<String, dynamic>{});
      }),
    );

    final ApiClient tab = client();
    await tab.examState(kToken);
    await tab.examState(kToken, q: 2);
    await tab.examBegin(kToken);
    await tab.examAnswer(kToken, questionId: '10', justification: 'x');
    await tab.examReview(kToken);
    await tab.examSubmit(kToken);
    await tab.examViolation(kToken, 'Tab switched');
    // A reload: a new client, and a new store, in the same tab.
    await client().examState(kToken);

    expect(sent.map((Sent s) => s.route), <String>[
      'state',
      'state',
      'begin',
      'answer',
      'review',
      'submit',
      'violation',
      'state',
    ]);
    final String? key = sent.first.key;
    expect(key, isNotNull);
    expect(key, hasLength(32));
    expect(sent.map((Sent s) => s.key).toSet(), <String?>{key});
  });

  testWidgets('a 409 session_replaced blocks the sitting and stops writing', (
    WidgetTester t,
  ) async {
    final (AppStore s, List<Sent> sent, _FakeProctor proctor) =
        await _replacedSitting(t);

    expect(find.text(kReplaced), findsOneWidget);
    expect(find.text('Continue Here'), findsOneWidget);
    expect(proctor.stops, greaterThan(0), reason: 'the watch is stopped');
    expect(proctor.onViolation, isNull);
    // Not a locked attempt: the exam is not ended.
    expect(s.attemptById('7')!.isDone, isFalse);
    expect(s.examView(kToken)!.outcome, 'question');

    final int answers = sent.where((Sent x) => x.route == 'answer').length;
    expect(answers, 1);
    s.saveAnswerQuiet('7', '10', Response(justification: 'typed again'));
    await _settle(t);
    await t.pump(const Duration(seconds: 1));
    expect(sent.where((Sent x) => x.route == 'answer').length, answers);
    expect(s.recordViolation('7', 'Tab switched'), isFalse);
    expect(sent.map((Sent x) => x.route), isNot(contains('violation')));
    expect(sent.map((Sent x) => x.route), isNot(contains('submit')));

    // Any `/state` from this tab takes the sitting back, so nothing automatic
    // may send one: not a quiet refresh, not a focus return, not a re-read.
    await s.refresh(background: true);
    await s.loadExamByToken(kToken);
    await s.loadExamQuestion(kToken, 2);
    for (final AppLifecycleState step in <AppLifecycleState>[
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      t.binding.handleAppLifecycleStateChanged(step);
    }
    await _settle(t);
    expect(sent.map((Sent x) => x.route), contains('assessments'));
    expect(sent.map((Sent x) => x.route), isNot(contains('state')));
    expect(find.text(kReplaced), findsOneWidget);

    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('Continue Here re-reads /state with the same key', (
    WidgetTester t,
  ) async {
    final (AppStore s, List<Sent> sent, _FakeProctor proctor) =
        await _replacedSitting(t);
    final String? key = sent.single.key;
    expect(key, isNotNull);

    await t.tap(find.text('Continue Here'));
    await _settle(t);

    final Sent state = sent.last;
    expect(state.route, 'state');
    expect(state.key, key);
    expect(find.text(kReplaced), findsNothing);
    expect(s.sessionReplaced, isEmpty);
    expect(proctor.onViolation, isNotNull, reason: 'the watch is back');

    await t.pump(const Duration(seconds: 4));
  });

  test(
    'a Next refused as replaced stands down without ending the exam',
    () async {
      final List<Sent> sent = <Sent>[];
      final AppStore s = _store(
        MockClient((http.Request req) async {
          final Sent one = _sent(req);
          sent.add(one);
          return one.route == 'answer'
              ? _replacedReply
              : _ok(<String, dynamic>{});
        }),
      );
      s.attempts = <Attempt>[Attempt.fromJson(_attempt)];
      s.assessments = <Assessment>[Assessment.fromJson(_asm)];
      s.examByToken[kToken] = ExamView.fromJson(_envelope);

      final bool toReview = await s.examAdvance(
        kToken,
        '10',
        Response(justification: 'an answer'),
      );

      expect(toReview, isFalse);
      expect(s.sessionReplaced, <String>{kToken});
      // Any other 409 on `/answer` means "locked": complete, then a `/state`
      // re-read. Neither may happen here.
      expect(s.examView(kToken)!.outcome, 'question');
      expect(sent.map((Sent x) => x.route), <String>['answer']);
      s.dispose();
    },
  );

  test(
    'a normal single-tab sit keeps one key and is never stood down',
    () async {
      final List<Sent> sent = <Sent>[];
      final AppStore s = _store(
        MockClient((http.Request req) async {
          final Sent one = _sent(req);
          sent.add(one);
          return switch (one.route) {
            'state' || 'begin' => _ok(_envelope),
            'answer' => _ok(<String, dynamic>{
              'next': <String, dynamic>{
                'outcome': 'question',
                'question': <String, dynamic>{..._question, 'id': '11'},
              },
            }),
            'review' => _ok(<String, dynamic>{'rows': <dynamic>[]}),
            _ => _ok(<String, dynamic>{}),
          };
        }),
      );

      await s.loadExamByToken(kToken);
      await s.beginExam('7');
      await s.examAdvance(kToken, '10', Response(justification: 'an answer'));
      await s.loadExamReview(kToken);
      s.finishExam('7', force: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        sent.map((Sent x) => x.route),
        containsAll(<String>['state', 'begin', 'answer', 'review', 'submit']),
      );
      // The runner's calls; `/me/assessments` after the submit is not one.
      final Iterable<Sent> runner = sent.where(
        (Sent x) => x.route != 'assessments',
      );
      expect(runner.map((Sent x) => x.key).toSet(), hasLength(1));
      expect(runner.first.key, isNotNull);
      expect(s.sessionReplaced, isEmpty);
      s.dispose();
    },
  );
}
