// Browser campaign, 8 Oct 2026, BR-D9: keyboard and screen reader.
//
// Tab reached the rules checkbox as a button with no name - the focus sat on
// a second, unlabelled node - and never reached the light/dark toggle at all:
// `IconBtn` had no focus node. One named node for the checkbox; any icon
// button is reached by Tab and pressed by Enter or Space. And a select is
// announced by its label: two selects that both read "Unknown" were otherwise
// the same to a screen reader.
//
// The AckBox and IconBtn cases are ported from stage's
// `the_exam_chrome_works_on_a_phone_and_by_keyboard_test` (its BR-D9 group,
// minus the exam top bar's theme toggle, which is ported with that toggle).
import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';

const String kToken = 'tok-chrome';

AppStore _store() {
  final AppStore s = AppStore();
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': 7,
      'access_token': kToken,
      'assessment_id': 21,
      'state': 'pending',
    }),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 21,
      'name': 'Systems Design Screening',
      'state': 'in_progress',
      'duration_minutes': 45,
      'rules': <String, dynamic>{'tab_switch': true},
      'violation_action': 'auto_submit',
      'max_violations': 3,
    }),
  ];
  s.examByToken[kToken] = ExamView.fromJson(<String, dynamic>{
    'outcome': 'instructions',
    'instructions': <String, dynamic>{'total_questions': 3},
  });
  return s;
}

/// Tab until the focus is inside [target], or give up.
Future<bool> _tabTo(WidgetTester t, Finder target) async {
  final Element host = t.element(target);
  for (int i = 0; i < 12; i++) {
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    final BuildContext? at = FocusManager.instance.primaryFocus?.context;
    bool inside = identical(at, host);
    at?.visitAncestorElements((Element e) => !(inside = identical(e, host)));
    if (inside) return true;
  }
  return false;
}

void main() {
  testWidgets('Tab lands on the rules checkbox itself, named and checkable', (
    WidgetTester t,
  ) async {
    final SemanticsHandle sem = t.ensureSemantics();
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AssessmentNavScope(
          nav: AssessmentNav(),
          child: ExamScreen(
            store: _store(),
            token: kToken,
            sub: ExamSub.instructions,
          ),
        ),
      ),
    );
    await t.pump();

    expect(await _tabTo(t, find.byType(AckBox)), isTrue);
    expect(
      t.getSemantics(find.byType(AckBox)),
      matchesSemantics(
        label:
            'I have read the rules and understand my exam can end if '
            'I break them.',
        hasCheckedState: true,
        isChecked: false,
        isFocusable: true,
        isFocused: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );

    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await t.pump();
    expect(
      t
          .getSemantics(find.byType(AckBox))
          .getSemanticsData()
          .flagsCollection
          .isChecked,
      CheckedState.isTrue,
    );

    await t.pumpWidget(const SizedBox());
    sem.dispose();
  });

  testWidgets('any IconBtn: Tab, Enter and Space; a disabled one is skipped', (
    WidgetTester t,
  ) async {
    int presses = 0;
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Row(
            children: <Widget>[
              const IconBtn(Icons.delete_outline, tooltip: 'Off'),
              IconBtn(
                Icons.light_mode_outlined,
                tooltip: 'Switch to light',
                onPressed: () => presses++,
              ),
            ],
          ),
        ),
      ),
    );

    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    final FocusNode? at = FocusManager.instance.primaryFocus;
    expect(
      at?.context?.findAncestorWidgetOfExactType<IconBtn>()?.tooltip,
      'Switch to light',
      reason: 'the first Tab skips the disabled button',
    );
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    // Any other key is not a press.
    await t.sendKeyEvent(LogicalKeyboardKey.keyA);
    await t.pump();
    expect(presses, 2);
  });

  testWidgets(
    'a focused IconBtn draws the focus ring, focus from a click does not',
    (WidgetTester t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Row(
              children: <Widget>[
                IconBtn(Icons.light_mode_outlined, onPressed: () {}),
                IconBtn(Icons.dark_mode_outlined, onPressed: () {}),
              ],
            ),
          ),
        ),
      );
      List<BoxShadow>? ring(IconData icon) {
        final Container box = t.widget<Container>(
          find.ancestor(
            of: find.byIcon(icon),
            matching: find.byType(Container),
          ),
        );
        return (box.decoration! as BoxDecoration).boxShadow;
      }

      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(ring(Icons.light_mode_outlined), hasLength(2));

      // Focus that lands from a click draws no ring: a pointer user needs
      // none, and a ring left behind reads as a stuck state. (The browser
      // focuses the node the click landed on; the request below stands in.)
      await t.tap(find.byIcon(Icons.dark_mode_outlined));
      Focus.of(t.element(find.byIcon(Icons.dark_mode_outlined))).requestFocus();
      await t.pump();
      await t.pump(); // the focus change rebuilds on the next frame
      expect(ring(Icons.dark_mode_outlined), isNull);
      expect(ring(Icons.light_mode_outlined), isNull);

      // Once focus moves on, the keyboard brings the ring back to it.
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(ring(Icons.dark_mode_outlined), hasLength(2));
    },
  );

  testWidgets('two selects that read the same are told apart by their label', (
    WidgetTester t,
  ) async {
    final SemanticsHandle sem = t.ensureSemantics();
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Row(
            children: <Widget>[
              for (final String label in <String>['Gender', 'Nativity'])
                Expanded(
                  child: SelectField<String>(
                    label: label,
                    value: 'u',
                    options: const <(String, String)>[('u', 'Unknown')],
                    onChanged: (_) {},
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel(RegExp('Gender')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Nativity')), findsOneWidget);
    sem.dispose();
  });
}
