// Eye movement (`gaze_review`) is gone (19 Oct): stage recorded no review
// flag in 4 sittings with it "running", so it bought a 3.7 MB model download
// and a switch that did nothing.
//
// A server that still sends `gaze_review: true` on an old paper must change
// nothing here: no switch, no `rule_gaze_review` write, no line for the
// candidate. That no eye model is ever loaded is the bridge's half,
// `node tool/proctor_ai_rules_test.mjs`. The cascade it shared with AI
// proctoring stays, for the two rules left.
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
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:ethara_assessment/services/proctor_stub.dart';

const String kToken = 'tok-eyes';

/// A watcher that keeps the rules the screen hands it.
class _Watch implements ProctorWatch {
  ProctorRules? rules;

  @override
  void start({
    required ProctorRules rules,
    required void Function(String reason) onViolation,
    void Function()? onCameraChanged,
  }) {
    this.rules = rules;
  }

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

/// A live store whose every request is recorded in [paths].
AppStore _store(List<String> paths) =>
    AppStore(
        api: ApiClient(
          baseUrl: 'http://stub',
          bearer: 't',
          client: MockClient((http.Request req) async {
            paths.add(req.url.path);
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': true,
                'data': <String, dynamic>{'recorded': true},
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

/// One sitting on an AI paper the server still marks `gaze_review`.
void _seed(AppStore s, {bool started = true}) {
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
      'name': 'old paper',
      'state': 'in_progress',
      'duration_minutes': 45,
      'violation_action': 'auto_submit',
      'max_violations': 1,
      'rules': <String, dynamic>{
        'webcam': true,
        'ai_proctor': true,
        // An old paper: the server may still send it.
        'gaze_review': true,
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
    'progress_percent': 0,
    'instructions': <String, dynamic>{'total_questions': 1},
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

Iterable<String> _texts(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((Text w) => w.data ?? w.textSpan?.toPlainText() ?? '');

void main() {
  test('no rule is eye movement, and a paper still marked gaze_review reads '
      'without it', () {
    expect(
      ProctorRule.values.map((ProctorRule r) => r.wire),
      isNot(contains('gaze_review')),
    );
    final RuleSet old = RuleSet.fromJson(<String, dynamic>{
      'webcam': true,
      'ai_proctor': true,
      'gaze_review': true,
    });
    expect(old.toJson().containsKey('gaze_review'), isFalse);
    expect(old[ProctorRule.aiProctor], isTrue);
  });

  test(
    'turning the webcam off turns AI proctoring off in the same rule set',
    () {
      final RuleSet all = RuleSet.fromJson(<String, dynamic>{
        'webcam': true,
        'ai_proctor': true,
      });
      final RuleSet noCam = all.set(ProctorRule.webcam, false);
      expect(noCam[ProctorRule.aiProctor], isFalse);
      // Turning a parent ON leaves the child as it was.
      expect(
        noCam.set(ProctorRule.webcam, true)[ProctorRule.aiProctor],
        isFalse,
      );
      expect(
        noCam.needsFirst(ProctorRule.aiProctor),
        'Turn on Require webcam first.',
      );
      expect(all.needsFirst(ProctorRule.aiProctor), isNull);
    },
  );

  testWidgets('a gaze_review paper: no switch on the Config tab, and webcam '
      'off is ONE write with no eye-movement key', (WidgetTester t) async {
    final List<Map<String, dynamic>> writes = <Map<String, dynamic>>[];
    final AppStore store = await _config(t, <String, dynamic>{
      'webcam': true,
      'ai_proctor': true,
      'gaze_review': true,
    }, writes);
    expect(find.text('Eye movement (review only)'), findsNothing);
    await _flip(t, 'Require webcam');
    await t.pump(const Duration(milliseconds: 3300));

    expect(writes, hasLength(1), reason: 'one save, not one per switch');
    expect(writes.single['rule_webcam'], isFalse);
    expect(writes.single['rule_ai_proctor'], isFalse);
    expect(writes.single.containsKey('rule_gaze_review'), isFalse);
    expect(
      store.toaster.items.where((ToastMsg m) => m.tone == Tone.bad),
      isEmpty,
    );
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('AI proctoring with the webcam off says why and writes nothing', (
    WidgetTester t,
  ) async {
    final List<Map<String, dynamic>> writes = <Map<String, dynamic>>[];
    final AppStore store = await _config(t, <String, dynamic>{
      'webcam': false,
      'ai_proctor': false,
    }, writes);
    await _flip(t, 'AI proctoring');
    expect(store.toaster.items.map((ToastMsg m) => m.message), <String>[
      'Turn on Require webcam first.',
    ]);
    await t.pump(const Duration(milliseconds: 3300));
    expect(writes, isEmpty);
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('a gaze_review paper tells the candidate nothing about where '
      'they look, and its watcher runs AI proctoring alone', (
    WidgetTester t,
  ) async {
    final AppStore s = _store(<String>[]);
    _seed(s, started: false);
    await _mount(t, s, ExamSub.instructions);
    await t.pumpAndSettle();
    expect(
      _texts(t).where((String x) => x.contains('Where you look')),
      isEmpty,
    );
    await t.pumpWidget(const SizedBox());

    final AppStore live = _store(<String>[]);
    _seed(live);
    final _Watch w = _Watch();
    await _mount(t, live, ExamSub.question, w);
    expect(w.rules!.aiProctor, isTrue);
  });
}

/// The Configuration tab on a draft whose server copy has [rules]; every
/// `/update` body lands in [writes].
Future<AppStore> _config(
  WidgetTester t,
  Map<String, dynamic> rules,
  List<Map<String, dynamic>> writes,
) async {
  t.view.physicalSize = const Size(1600, 3200);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
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
              'name': 'old_paper',
              'state': 'draft',
              'duration_minutes': 45,
              'question_limit': 6,
              'total_questions': 6,
              'subjective_threshold': 0.6,
              'violation_action': 'log_only',
              'max_violations': 3,
              'rules': rules,
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
  return store;
}

Future<void> _flip(WidgetTester t, String label) async {
  final Finder row = find.ancestor(
    of: find.text(label),
    matching: find.byType(SwitchRow),
  );
  await t.tap(find.descendant(of: row, matching: find.byType(Switcher)));
  await t.pump();
}
