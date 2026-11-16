// AI proctoring (`ai_proctor`): the rule, its upload policy, and the copy that
// changes with it.
//
// The detection itself runs in `web/proctor_ai.js` and is checked by
// `node tool/proctor_ai_rules_test.mjs`; nothing here can reach a camera.
// What CAN break on this side: the rule not round-tripping (the switch saves
// nothing), the policy not reaching the watcher (no snapshot is ever stored),
// and a camera overlay still promising "no video is stored" while snapshots
// are being taken.
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
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/services/proctor_stub.dart';

const String kToken = 'tok-ai';

/// When `proctor_ai.js` takes one: at the start, every 2 minutes, and when
/// a check trips (again every 30 s while it holds).
const String kSnapshots =
    'Camera snapshots are saved at the start, every 2 minutes and when a rule '
    'is tripped.';
const String kAiCopy =
    'Your camera is watched for a second person, a phone, or an empty seat. '
    '$kSnapshots';
const String kOnOffCopy =
    'Only the on-off state is monitored. No video is recorded or stored.';

/// `evidence_upload` as Task 7's server sends it (boto3's presigned POST).
Map<String, dynamic> policyJson() => <String, dynamic>{
  'url': 'https://bucket.s3.ap-south-1.amazonaws.com/',
  'fields': <String, dynamic>{
    'Content-Type': 'image/jpeg',
    'key': r'etp_assessment/proctoring/etp/7/${filename}',
    'policy': 'eyJ...',
    'x-amz-signature': 'abc',
  },
  'prefix': 'etp_assessment/proctoring/etp/7/',
  'expires_at': '2026-10-06T12:00:00+00:00',
  'max_bytes': 400000,
  'content_type': 'image/jpeg',
};

/// A watcher whose camera the test switches, and which records policies.
class _Watch implements ProctorWatch {
  CameraState camera = CameraState.on;
  void Function()? changed;
  ProctorRules? rules;
  final List<Map<String, Object?>> policies = <Map<String, Object?>>[];

  @override
  void start({
    required ProctorRules rules,
    required void Function(String reason) onViolation,
    void Function()? onCameraChanged,
  }) {
    this.rules = rules;
    changed = onCameraChanged;
  }

  @override
  void stop() => changed = null;
  @override
  void setEvidencePolicy(Map<String, Object?> policy) => policies.add(policy);
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
  String get cameraMessage => 'Your camera was turned off.';
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

/// [data] answers a request's `data`; empty when omitted.
AppStore _store([Map<String, dynamic> Function(http.Request req)? data]) =>
    AppStore(
        api: ApiClient(
          baseUrl: 'http://stub',
          bearer: 't',
          client: MockClient(
            (http.Request req) async => http.Response(
              jsonEncode(<String, dynamic>{
                'ok': true,
                'data': data?.call(req) ?? <String, dynamic>{},
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            ),
          ),
        ),
      )
      ..portal = Portal.member
      ..source = DataSource.live
      ..meId = '2';

Map<String, dynamic> _question(int n) => <String, dynamic>{
  'id': '${9 + n}',
  'index': n,
  'total': 3,
  'name': 'Question $n',
  'prompt': 'Prompt.',
  'question_type': 'subjective_rubric',
  'dimensions': <dynamic>[],
  'images': <dynamic>[],
  'videos': <dynamic>[],
  'label_boxes': <dynamic>[],
};

/// Seeds one sitting. [started] false leaves it on the instructions page.
/// [policy] false is a server with no evidence storage: the rule is on, and
/// no upload policy comes with it.
void _seed(
  AppStore s, {
  required bool ai,
  bool started = true,
  bool policy = true,
}) {
  final DateTime end = DateTime.now().add(const Duration(minutes: 30));
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': 7,
      'access_token': kToken,
      'assessment_id': 21,
      'state': started ? 'in_progress' : 'pending',
      'started_at': started ? DateTime.now().toUtc().toIso8601String() : null,
      'deadline': started ? end.toUtc().toIso8601String() : null,
    }),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 21,
      'name': 'sample test',
      'state': 'in_progress',
      'duration_minutes': 45,
      'rules': <String, dynamic>{'webcam': true, 'ai_proctor': ai},
    }),
  ];
  s.examByToken[kToken] = ExamView.fromJson(<String, dynamic>{
    'outcome': started ? 'question' : 'instructions',
    if (started) 'question': _question(1),
    'answered_question_ids': <dynamic>[],
    'progress_percent': 0,
    'instructions': <String, dynamic>{'total_questions': 3},
    if (ai && policy) 'evidence_upload': policyJson(),
  });
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
        child: ExamScreen(store: s, token: kToken, sub: sub, proctor: watch),
      ),
    ),
  );
  await t.pump();
}

/// Every string on screen, rich text included.
Iterable<String> _texts(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((Text w) => w.data ?? w.textSpan?.toPlainText() ?? '');

void main() {
  group('the rule', () {
    test('round-trips as ai_proctor and writes rule_ai_proctor', () {
      expect(ProctorRule.parse('ai_proctor'), ProctorRule.aiProctor);
      expect(ProctorRule.aiProctor.wire, 'ai_proctor');
      expect(ProctorRule.aiProctor.field, 'rule_ai_proctor');
      expect(ProctorRule.aiProctor.label, 'AI proctoring');
      expect(ProctorRule.aiProctor.firesViolation, isTrue);
      expect(ProctorRule.aiProctor.violationLabel, startsWith('AI: '));

      final RuleSet on = RuleSet.fromJson(<String, dynamic>{
        'webcam': true,
        'ai_proctor': true,
      });
      expect(on[ProctorRule.aiProctor], isTrue);
      expect(on.toJson()['ai_proctor'], isTrue);
      expect(RuleSet.fromJson(on.toJson())[ProctorRule.aiProctor], isTrue);
      // Absent means off: an older server never switches it on by accident.
      expect(RuleSet.defaults()[ProctorRule.aiProctor], isFalse);
      expect(
        RuleSet.fromJson(<String, dynamic>{})[ProctorRule.aiProctor],
        isFalse,
      );
    });

    test('the operator hint says when snapshots are stored', () {
      expect(
        ProctorRule.aiProctor.hint,
        'Flags an empty seat, a second person or a phone on camera. Stores a '
        'camera snapshot at the start, every 2 minutes, and when a check '
        'trips (every 30 seconds while it lasts). Needs Require webcam. Made '
        'for Chrome.',
      );
      // The webcam hint no longer claims on-off only unconditionally.
      expect(ProctorRule.webcam.hint, contains('unless AI proctoring'));
    });
  });

  group('EvidenceUploadPolicy', () {
    test('parses the evidence_upload block', () {
      final ExamView v = ExamView.fromJson(<String, dynamic>{
        'outcome': 'question',
        'evidence_upload': policyJson(),
      });
      final EvidenceUploadPolicy p = v.evidenceUpload!;
      expect(p.url, 'https://bucket.s3.ap-south-1.amazonaws.com/');
      expect(p.prefix, 'etp_assessment/proctoring/etp/7/');
      expect(p.fields['Content-Type'], 'image/jpeg');
      expect(p.fields['x-amz-signature'], 'abc');
      expect(p.expiresAt, '2026-10-06T12:00:00+00:00');
      expect(p.maxBytes, 400000);
      expect(p.contentType, 'image/jpeg');
      // The bridge gets the wire shape back.
      expect(p.toJson()['max_bytes'], 400000);
      expect(p.toJson()['prefix'], p.prefix);
    });

    test('a missing or empty block is no policy', () {
      expect(
        ExamView.fromJson(<String, dynamic>{
          'outcome': 'question',
        }).evidenceUpload,
        isNull,
      );
      expect(
        EvidenceUploadPolicy.fromJson(<String, dynamic>{'url': ''}),
        isNull,
      );
    });

    test('an /answer step keeps the policy it had', () {
      final ExamView v = ExamView.fromJson(<String, dynamic>{
        'outcome': 'question',
        'evidence_upload': policyJson(),
      });
      expect(
        identical(v.copyWith(index: 2).evidenceUpload, v.evidenceUpload),
        isTrue,
      );
    });
  });

  group('the exam screen', () {
    testWidgets('the camera overlay copy switches with the rule', (
      WidgetTester t,
    ) async {
      for (final bool ai in <bool>[false, true]) {
        final AppStore s = _store();
        _seed(s, ai: ai);
        final _Watch w = _Watch()..camera = CameraState.off;
        await _mount(t, s, ExamSub.question, w);
        await t.pump();

        expect(find.text('Your camera is off'), findsOneWidget);
        final String body = _texts(
          t,
        ).firstWhere((String x) => x.contains('Your camera was turned off.'));
        expect(body, contains(ai ? kAiCopy : kOnOffCopy));
        expect(body, isNot(contains(ai ? kOnOffCopy : kAiCopy)));
        expect(body, contains('The clock keeps running'));
        expect(w.rules!.aiProctor, ai);
        await t.pumpWidget(const SizedBox());
      }
    });

    testWidgets('the upload policy reaches the watcher once per payload', (
      WidgetTester t,
    ) async {
      // What `/answer` puts in `next`: the following question, plus a policy
      // when the server re-minted one.
      Map<String, dynamic>? answerPolicy;
      final AppStore s = _store(
        (http.Request req) => req.url.path.endsWith('/answer')
            ? <String, dynamic>{
                'saved': true,
                'next': <String, dynamic>{
                  'outcome': 'question',
                  'question': _question(2),
                  'evidence_upload': ?answerPolicy,
                },
              }
            : <String, dynamic>{},
      );
      _seed(s, ai: true);
      final _Watch w = _Watch();
      await _mount(t, s, ExamSub.question, w);
      // Two real rebuilds (the watcher's own repaint hook calls setState).
      for (int i = 0; i < 2; i++) {
        w.changed!();
        await t.pump();
      }

      expect(w.policies, hasLength(1), reason: 'rebuilds must not re-send');
      expect(w.policies.single['prefix'], 'etp_assessment/proctoring/etp/7/');
      expect(w.policies.single['url'], policyJson()['url']);

      // A fresh `/state` brings a fresh policy, and that one is sent.
      s.examByToken[kToken] = ExamView.fromJson(<String, dynamic>{
        'outcome': 'question',
        'evidence_upload': policyJson()..['expires_at'] = 'later',
      });
      w.changed!();
      await t.pump();
      expect(w.policies, hasLength(2));
      expect(w.policies.last['expires_at'], 'later');

      // So does `/answer`: its `next` is merged into the envelope, and the
      // merge used to drop the policy it carried.
      answerPolicy = policyJson()..['expires_at'] = 'from-answer';
      await t.runAsync(
        () => s.examAdvance(kToken, '10', const Response(justification: 'x')),
      );
      expect(s.examView(kToken)!.index, 2, reason: 'the step was merged');
      w.changed!();
      await t.pump();
      expect(w.policies, hasLength(3));
      expect(w.policies.last['expires_at'], 'from-answer');

      // A `next` without one keeps the policy the sitting holds.
      answerPolicy = null;
      await t.runAsync(
        () => s.examAdvance(kToken, '11', const Response(justification: 'y')),
      );
      expect(s.examView(kToken)!.evidenceUpload?.expiresAt, 'from-answer');
      w.changed!();
      await t.pump();
      expect(w.policies, hasLength(3), reason: 'nothing new to send');
    });

    // `proctor_ai.js` calls `policy.landed(key)` after an upload whose S3
    // reply it could not read; false makes it send the snapshot again.
    testWidgets('the policy carries a landed check that asks the server', (
      WidgetTester t,
    ) async {
      final List<Map<String, dynamic>> asked = <Map<String, dynamic>>[];
      Object? landed = true;
      final AppStore s = _store((http.Request req) {
        if (!req.url.path.endsWith('/evidence/landed')) {
          return <String, dynamic>{};
        }
        expect(req.url.path, '/api/v1/exam/$kToken/evidence/landed');
        asked.add(jsonDecode(req.body) as Map<String, dynamic>);
        return <String, dynamic>{'landed': landed};
      });
      _seed(s, ai: true);
      final _Watch w = _Watch();
      await _mount(t, s, ExamSub.question, w);

      final Future<bool> Function(String) check =
          w.policies.single['landed']! as Future<bool> Function(String);
      const String key = 'etp_assessment/proctoring/etp/7/1_phone.jpg';
      expect(await t.runAsync(() => check(key)), isTrue);
      expect(asked.single['key'], key);
      expect(asked.single['session_key'], isA<String>());

      // Anything but a literal true is "not there": send it again.
      for (final Object? reply in <Object?>[false, null, 'true']) {
        landed = reply;
        expect(await t.runAsync(() => check(key)), isFalse, reason: '$reply');
      }
    });

    testWidgets('the instructions page lists the rule and the snapshots', (
      WidgetTester t,
    ) async {
      final AppStore s = _store();
      _seed(s, ai: true, started: false);
      await _mount(t, s, ExamSub.instructions);
      await t.pumpAndSettle();

      final List<String> all = _texts(t).toList();
      expect(all, contains(ProctorRule.aiProctor.candidateRule.text));
      expect(all.where((String x) => x.contains(kSnapshots)), isNotEmpty);
      expect(all.where((String x) => x.contains('if the AI check')), isEmpty);
    });

    // BR-D8: "A camera snapshot is saved" only where one can be. With no
    // storage the server sends no upload policy and nothing is kept.
    testWidgets('with the rule but no storage, no snapshot is promised', (
      WidgetTester t,
    ) async {
      final AppStore s = _store();
      _seed(s, ai: true, started: false, policy: false);
      await _mount(t, s, ExamSub.instructions);
      await t.pumpAndSettle();

      final List<String> all = _texts(t).toList();
      expect(all, contains(ProctorRule.aiProctor.candidateRule.text));
      expect(all.where((String x) => x.contains('snapshot')), isEmpty);
      await t.pumpWidget(const SizedBox());

      final AppStore live = _store();
      _seed(live, ai: true, policy: false);
      await _mount(
        t,
        live,
        ExamSub.question,
        _Watch()..camera = CameraState.off,
      );
      await t.pump();
      final String body = _texts(
        t,
      ).firstWhere((String x) => x.contains('Your camera was turned off.'));
      expect(
        body,
        contains(
          'Your camera is watched for a second person, a phone, or an '
          'empty seat. The clock',
        ),
      );
      expect(body, isNot(contains('snapshot')));
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('without the rule the instructions page says nothing of it', (
      WidgetTester t,
    ) async {
      final AppStore s = _store();
      _seed(s, ai: false, started: false);
      await _mount(t, s, ExamSub.instructions);
      await t.pumpAndSettle();

      final List<String> all = _texts(t).toList();
      expect(all, isNot(contains(ProctorRule.aiProctor.candidateRule.text)));
      expect(all.where((String x) => x.contains('snapshot')), isEmpty);
    });
  });

  testWidgets('the Configuration tab shows the switch, and it saves', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1600, 3200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final List<Map<String, dynamic>> writes = <Map<String, dynamic>>[];
    final AppStore store = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          if (req.url.path.endsWith('/update')) {
            writes.add(jsonDecode(req.body) as Map<String, dynamic>);
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{
                'id': '7',
                'name': 'test_cj',
                'state': 'draft',
                'duration_minutes': 45,
                'question_limit': 6,
                'total_questions': 6,
                'subjective_threshold': 0.6,
                'violation_action': 'log_only',
                'max_violations': 3,
                'rules': <String, dynamic>{'webcam': true, 'ai_proctor': false},
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: AssessmentNavScope(
            nav: AssessmentNav(),
            child: AssessmentDetailScreen(
              store: store,
              portal: Portal.admin,
              asmId: '7',
            ),
          ),
        ),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    final Finder row = find.ancestor(
      of: find.text('AI proctoring'),
      matching: find.byType(SwitchRow),
    );
    expect(row, findsOneWidget);
    expect(find.text(ProctorRule.aiProctor.hint), findsOneWidget);

    await t.tap(find.descendant(of: row, matching: find.byType(Switcher)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 3300));

    expect(writes, isNotEmpty, reason: 'the switch must reach the server');
    expect(writes.last['rule_ai_proctor'], isTrue);
  });
}
