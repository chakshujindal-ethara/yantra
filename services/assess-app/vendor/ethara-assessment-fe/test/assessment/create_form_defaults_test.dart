// The DEFAULTS a fresh create form ships, pinned at the wire.
//
// Three defaults were flipped on the operator's instruction, and a default is
// exactly the kind of thing that regresses silently - nobody sets it, so
// nobody notices when it drifts. So rather than eyeball the switches, this
// opens the real New assessment form, gives it only a name, presses Save, and
// reads the CREATE payload:
//
//   - webcam proctoring is ON     (rule_webcam: true)
//   - automatic grading is OFF    (llm_auto_score: false)
//   - question shuffle is ON      (shuffle_questions: true)
//   - answers and feedback SHOWN  (results_show_answers: true)
//
// The `?` collapsing in the api client omits a null, never a false, so a
// `false` that reaches the wire is a decision the form made - which is the
// whole point of asserting it rather than the widget's own state.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/new_assessment_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';

/// Records every path and body, answers with an empty envelope. The empty
/// `data` means `addAssessment` gets no id back and returns before it
/// navigates, so no route stack is needed for this test.
class _Spy {
  final List<String> paths = <String>[];
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  http.Client get client => MockClient((http.Request req) async {
    paths.add(req.url.path);
    try {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
    } on FormatException {
      bodies.add(<String, dynamic>{});
    }
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });

  Map<String, dynamic> bodyFor(String fragment) {
    for (int i = paths.length - 1; i >= 0; i--) {
      if (paths[i].contains(fragment)) return bodies[i];
    }
    return <String, dynamic>{};
  }
}

AppStore _live(_Spy spy) {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: spy.client),
  );
  s.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
  return s;
}

void main() {
  testWidgets(
    'a fresh create form ships webcam ON, auto-grade OFF, shuffle ON',
    (WidgetTester t) async {
      t.view.physicalSize = const Size(1600, 3200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final _Spy spy = _Spy();
      final AppStore s = _live(spy);

      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: AssessmentNavScope(
              nav: AssessmentNav(),
              child: NewAssessmentScreen(store: s),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      // A NAME is the only thing the server requires to create a draft, so it
      // is the only thing this touches - everything else must stay at its
      // default for the assertion to mean anything.
      await t.enterText(find.byType(TextField).first, 'Warehouse Safety');
      await t.pumpAndSettle();

      // The readiness button reads 'Save as draft' with no generator picked.
      await t.tap(find.widgetWithText(Btn, 'Save as draft'));
      await t.pumpAndSettle();
      // Drain the success toast's own dismiss timer, which outlives the frame
      // and fails the test at teardown if it is still pending.
      await t.pump(const Duration(seconds: 4));

      final Map<String, dynamic> body = spy.bodyFor('/assessments/create');
      expect(body['name'], 'Warehouse Safety');
      expect(
        body['rule_webcam'],
        isTrue,
        reason: 'the operator asked for webcam on out of the box',
      );
      expect(
        body['llm_auto_score'],
        isFalse,
        reason:
            'grading is off until they choose to grade - and false must '
            'reach the wire, not be omitted',
      );
      expect(
        body['shuffle_questions'],
        isTrue,
        reason: 'same questions in a fixed order is a side-by-side leak',
      );
      // A-074: Log only and 5 violations by default.
      expect(body['violation_action'], 'log_only');
      expect(body['max_violations'], 5);
      // Retired: everybody gets the same questions, so
      // there is no switch to show and no key to send.
      expect(find.text('Same questions for everybody'), findsNothing);
      expect(body.containsKey('same_questions_for_all'), isFalse);
      expect(
        body['results_show_answers'],
        isTrue,
        reason: 'the assessment default: a release shows the key',
      );
      // 70, the server's own default (`DEFAULT_SUBJECTIVE_THRESHOLD`).
      expect(body['subjective_threshold'], 70);
    },
  );

  testWidgets(
    'the show-answers switch is on the form, worded as on the Config tab, '
    'and turning it off reaches the wire',
    (WidgetTester t) async {
      t.view.physicalSize = const Size(1600, 3200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: AssessmentNavScope(
              nav: AssessmentNav(),
              child: NewAssessmentScreen(store: s),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      final Finder switchRow = find.byWidgetPredicate(
        (Widget w) =>
            w is SwitchRow &&
            w.name == 'Show correct answers and feedback' &&
            w.hint ==
                "On, released candidates see the correct answers, each "
                    "answer's verdict and the grader's feedback. Off, they "
                    'see their own answers and marks only. Read when they '
                    'open the review, so a change applies at once.' &&
            w.value,
      );
      expect(switchRow, findsOneWidget, reason: 'on by default');

      await t.enterText(find.byType(TextField).first, 'Warehouse Safety');
      await t.pumpAndSettle();
      await t.ensureVisible(switchRow);
      await t.pumpAndSettle();
      await t.tap(
        find.descendant(of: switchRow, matching: find.byType(Switcher)),
      );
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(Btn, 'Save as draft'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 4));

      expect(spy.bodyFor('/assessments/create')['results_show_answers'], false);
    },
  );

  testWidgets(
    'the auto-grade switch is ON THE FORM, and turning it on reaches the wire',
    (WidgetTester t) async {
      // It was a hard-coded literal in `_create`, so this panel offered no way
      // to see or set it while the assessment's own Config tab did - two
      // screens disagreeing about one setting, with the invisible one winning.
      t.view.physicalSize = const Size(1600, 3200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final _Spy spy = _Spy();
      final AppStore s = _live(spy);

      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: AssessmentNavScope(
              nav: AssessmentNav(),
              child: NewAssessmentScreen(store: s),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      final Finder switchRow = find.byWidgetPredicate(
        (Widget w) =>
            w is SwitchRow &&
            w.name == 'Grade subjective answers automatically',
      );
      expect(
        switchRow,
        findsOneWidget,
        reason:
            'the create form must offer the same switch the Config tab does',
      );

      await t.enterText(find.byType(TextField).first, 'Warehouse Safety');
      await t.pumpAndSettle();
      // The label is not the target - `SwitchRow` puts the gesture on its
      // trailing `Switcher`, so tapping the text does nothing at all.
      await t.ensureVisible(switchRow);
      await t.pumpAndSettle();
      await t.tap(
        find.descendant(of: switchRow, matching: find.byType(Switcher)),
      );
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(Btn, 'Save as draft'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 4));

      expect(
        spy.bodyFor('/assessments/create')['llm_auto_score'],
        isTrue,
        reason: 'flipping the switch on must actually reach the server',
      );
    },
  );
}
