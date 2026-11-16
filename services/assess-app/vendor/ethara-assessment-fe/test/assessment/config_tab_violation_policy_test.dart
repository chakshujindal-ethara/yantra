// The violation policy was READ-ONLY on the record it belongs to.
//
// "On violation" and its threshold were collected once, on the New assessment
// form, and then never offered again: the Configuration tab printed the
// consequence ("The exam auto-submits on violation 8") and gave no way to
// change either field. So the setting operators most often want back - stop
// auto-submitting people mid-cohort, or raise a cap that turned out too tight
// - could be read on the record and edited nowhere. The server never refused
// it: both fields are in `assessment_update`'s POST_DRAFT_FIELDS, so the route
// has always accepted them on a RUNNING assessment too.
//
// The second bug is the one the new stepper exposes. Every caller normalised
// the cap as `maxViolations > 0 ? maxViolations : 1` before handing it to
// `violationConsequence`, so that function's "no cap" branch could never run.
// At the module's own default (max_violations = 0) with "Log only", nothing
// ends the exam - and the notice said the first violation would.
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Serves one assessment detail and records every update body.
class _Rig {
  final List<Map<String, dynamic>> writes = <Map<String, dynamic>>[];
  final String state;
  final String violationAction;
  final int maxViolations;
  final Map<String, dynamic>? rules;
  late final AppStore store;

  _Rig({
    this.state = 'draft',
    this.violationAction = 'log_only',
    this.maxViolations = 3,
    this.rules,
  }) {
    store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          if (path.endsWith('/update')) {
            writes.add(
              jsonDecode(req.body) as Map<String, dynamic>,
            );
          }
          return http.Response(
            jsonEncode(<String, dynamic>{'ok': true, 'data': _detail}),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        baseUrl: 'http://x',
      ),
    );
  }

  Map<String, dynamic> get _detail => <String, dynamic>{
    'id': '7',
    'name': 'test_cj',
    'state': state,
    'duration_minutes': 45,
    'question_limit': 6,
    'total_questions': 6,
    'subjective_threshold': 0.6,
    'violation_action': violationAction,
    'max_violations': maxViolations,
    'ai_violation_action': 'auto_submit',
    'ai_max_violations': 4,
    'rules': ?rules,
  };

  Widget get app => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: AssessmentNavScope(
        nav: AssessmentNav(),
        // No `tab:` - the screen opens on Configuration by default, which is
        // the screen under test.
        child: AssessmentDetailScreen(
          store: store,
          portal: Portal.admin,
          asmId: '7',
        ),
      ),
    ),
  );
}

void main() {
  // An admin page on a phone-sized surface overflows during layout, which
  // throws and masks the assertion.
  void desktop(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Past the toast's own 3.2s dismissal timer. A save raises one, and a timer
  /// still pending when the tree is disposed fails the test on teardown.
  Future<void> settleSave(WidgetTester tester) async {
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 3300));
  }

  /// The `Field` that carries this label, so a stepper is addressed by the
  /// thing it edits rather than by its ordinal among four identical ones.
  Finder fieldNamed(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(Field));

  /// `Notice` paints through `Text.rich`, so its sentences are TextSpans and
  /// `find.text` cannot see them. Read the widget instead.
  Finder noticeSaying(String strong) => find.byWidgetPredicate(
    (Widget w) => w is Notice && w.strong == strong,
  );

  testWidgets('Configuration offers both violation controls', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    final _Rig rig = _Rig();
    await tester.pumpWidget(rig.app);
    await settle(tester);

    // `Field` upper-cases its own label, so these are the rendered strings.
    expect(
      find.text('ON VIOLATION'),
      findsOneWidget,
      reason: 'the policy has to be editable on the record it belongs to, not '
          'only on the create form',
    );
    expect(find.text('THRESHOLD'), findsOneWidget);
    expect(find.byType(SelectField<ViolationAction>), findsOneWidget);
  });

  testWidgets('the stepper writes max_violations to the update route', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    final _Rig rig = _Rig(maxViolations: 3);
    await tester.pumpWidget(rig.app);
    await settle(tester);

    // The Threshold stepper is the second NumberField pair on the tab, so it
    // is found through its own Field rather than by ordinal.
    final Finder minus = find.descendant(
      of: fieldNamed('THRESHOLD'),
      matching: find.widgetWithText(Btn, '-'),
    );
    expect(minus, findsOneWidget);
    await tester.tap(minus);
    await settleSave(tester);

    expect(rig.writes, isNotEmpty, reason: 'the edit must reach the server');
    expect(rig.writes.last['max_violations'], 2);
  });

  testWidgets('the selector writes violation_action', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    final _Rig rig = _Rig(violationAction: 'log_only');
    await tester.pumpWidget(rig.app);
    await settle(tester);

    await tester.tap(find.byType(SelectField<ViolationAction>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auto-submit the exam').last);
    await tester.pumpAndSettle();
    await settleSave(tester);

    expect(rig.writes, isNotEmpty);
    expect(rig.writes.last['violation_action'], 'auto_submit');
  });

  testWidgets('at no cap and Log only the notice does not promise an ending', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    // The module's OWN default for this field is 0. Before the fix the tab
    // normalised it to 1 and told the operator the first violation would end
    // the exam, which is the opposite of what log-only-with-no-cap does.
    final _Rig rig = _Rig(maxViolations: 0, violationAction: 'log_only');
    await tester.pumpWidget(rig.app);
    await settle(tester);

    expect(
      noticeSaying('The exam is never ended automatically.'),
      findsOneWidget,
      reason: 'nothing ends this attempt - `recordViolation` requires a cap '
          'or an auto-submit action, and neither is set',
    );
    expect(noticeSaying('The exam auto-submits on violation 1.'), findsNothing);

    // And the read-only rendering of the same 0 says so in words rather than
    // printing a bare "0" beside a field whose minimum reads as 0.
    expect(find.text('No cap'), findsNothing, reason: 'admin can configure');
  });

  testWidgets('read-only, a 0 cap says what 0 does in each mode', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    // 0 ends the exam on the FIRST violation under Auto-submit, and sets no
    // limit under Log only - "No cap" was wrong for the first.
    for (final (String action, String shown) in <(String, String)>[
      ('auto_submit', 'First Violation'),
      ('log_only', 'No Limit'),
    ]) {
      final _Rig rig = _Rig(maxViolations: 0, violationAction: action);
      rig.store.adoptSession(
        orgRole: 'admin',
        capabilities: <Capability>{Capability.lifecycle},
      );
      await tester.pumpWidget(rig.app);
      await settle(tester);
      expect(find.text(shown), findsOneWidget, reason: action);
      expect(find.text('No cap'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    }

    // A real cap is just its number.
    final _Rig capped = _Rig(maxViolations: 3, violationAction: 'auto_submit');
    capped.store.adoptSession(
      orgRole: 'admin',
      capabilities: <Capability>{Capability.lifecycle},
    );
    await tester.pumpWidget(capped.app);
    await settle(tester);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('the On violation help states the owner rule', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    // It said a threshold above 0 ends the exam "whatever this says" - the
    // opposite of A-074, where Log only never ends it at any threshold.
    final _Rig rig = _Rig();
    await tester.pumpWidget(rig.app);
    await settle(tester);

    final String help =
        tester.widget<Field>(fieldNamed('ON VIOLATION')).help ?? '';
    expect(help, contains('Log only never ends the exam'));
    expect(help, contains('Violation Limit Breached'));
    expect(help, contains('0 ends it on the first violation'));
    expect(help, isNot(contains('whatever this says')));
    expect(help, isNot(contains('\u2014')), reason: 'no em dash in UI text');
  });

  // AI proctoring violations count apart (15 Oct, R5), against their own
  // pair, which is offered only where the AI rule is on.
  const Map<String, dynamic> aiOn = <String, dynamic>{
    'webcam': true,
    'ai_proctor': true,
  };

  testWidgets('the AI pair shows only with AI proctoring on', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    await tester.pumpWidget(_Rig().app);
    await settle(tester);
    expect(find.text('ON AI VIOLATION'), findsNothing);
    expect(find.text('AI THRESHOLD'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_Rig(rules: aiOn).app);
    await settle(tester);
    expect(find.text('ON AI VIOLATION'), findsOneWidget);
    expect(find.text('AI THRESHOLD'), findsOneWidget);
    // The regular pair is still there and still says what it did.
    expect(find.text('ON VIOLATION'), findsOneWidget);
    expect(find.byType(SelectField<ViolationAction>), findsNWidgets(2));
    expect(
      noticeSaying('AI proctoring: the exam auto-submits on violation 4.'),
      findsOneWidget,
    );
  });

  testWidgets('the AI stepper writes ai_max_violations alone', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    final _Rig rig = _Rig(rules: aiOn);
    await tester.pumpWidget(rig.app);
    await settle(tester);

    await tester.tap(
      find.descendant(
        of: fieldNamed('AI THRESHOLD'),
        matching: find.widgetWithText(Btn, '-'),
      ),
    );
    await settleSave(tester);

    expect(rig.writes, isNotEmpty);
    expect(rig.writes.last['ai_max_violations'], 3);
    expect(rig.writes.last.containsKey('max_violations'), isFalse);
  });

  // Its OWN dropdown: the paper's AI action is Auto-submit and the regular one
  // Log only, so a dropdown wired to the wrong field (or none) is caught.
  testWidgets('the AI dropdown writes ai_violation_action alone', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    final _Rig rig = _Rig(rules: aiOn);
    await tester.pumpWidget(rig.app);
    await settle(tester);

    await tester.tap(find.byType(SelectField<ViolationAction>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log only').last);
    await tester.pumpAndSettle();
    await settleSave(tester);

    expect(rig.writes, hasLength(1));
    expect(rig.writes.single['ai_violation_action'], 'log_only');
    expect(rig.writes.single.containsKey('violation_action'), isFalse);
  });

  testWidgets('a running assessment still offers the controls', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    // NOT draft. The route's POST_DRAFT_FIELDS names both fields, so freezing
    // them here would be the app refusing an edit the server accepts.
    final _Rig rig = _Rig(state: 'in_progress');
    await tester.pumpWidget(rig.app);
    await settle(tester);

    expect(find.text('ON VIOLATION'), findsOneWidget);
    expect(find.text('THRESHOLD'), findsOneWidget);
  });
}
