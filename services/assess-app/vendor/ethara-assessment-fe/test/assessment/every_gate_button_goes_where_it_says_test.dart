// A dead end's one button has to do what its label says.
//
// THE BUG. `GateScreen` built one action row and both buttons called
// `context.nav.reset(const MyAssessments())` whatever the gate was. The login
// gate's button reads "Sign in" and the wrong-candidate gate's reads "Switch
// account"; neither signed out and neither opened the login form. So a
// candidate signed in as somebody else pressed the one button offered and
// landed on that other person's assessment list - and on the login gate the
// destination fails for exactly the reason the gate appeared.
//
// The file's own header rule is "every dead end is a designed screen with an
// action". An action that does something else is not one.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/gate_screen.dart';

Future<AssessmentNav> _open(
  WidgetTester t,
  GateKind kind, {
  VoidCallback? onSignOut,
}) async {
  final AssessmentNav nav = AssessmentNav();
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: AssessmentNavScope(
        nav: nav,
        child: GateScreen(kind: kind, onSignOut: onSignOut),
      ),
    ),
  );
  await t.pumpAndSettle();
  return nav;
}

void main() {
  testWidgets('"Sign in" signs out rather than opening somebody\'s list', (
    WidgetTester t,
  ) async {
    int signedOut = 0;
    final AssessmentNav nav = await _open(
      t,
      GateKind.login,
      onSignOut: () => signedOut++,
    );

    await t.tap(find.text('Sign in'));
    await t.pumpAndSettle();

    expect(signedOut, 1);
    expect(
      nav.current,
      isNot(const MyAssessments()),
      reason: 'the list is behind the very session this gate says is missing',
    );
  });

  testWidgets('"Switch account" switches the account', (WidgetTester t) async {
    int signedOut = 0;
    final AssessmentNav nav = await _open(
      t,
      GateKind.wrong,
      onSignOut: () => signedOut++,
    );

    await t.tap(find.text('Switch account'));
    await t.pumpAndSettle();

    expect(signedOut, 1);
    expect(
      nav.current,
      isNot(const MyAssessments()),
      reason: 'that list belongs to the person who is still signed in',
    );
  });

  testWidgets('the wrong-candidate gate still offers the list as a way out', (
    WidgetTester t,
  ) async {
    int signedOut = 0;
    final AssessmentNav nav = await _open(
      t,
      GateKind.wrong,
      onSignOut: () => signedOut++,
    );

    await t.tap(find.text('My assessments'));
    await t.pumpAndSettle();

    expect(signedOut, 0);
    expect(nav.current, const MyAssessments());
  });

  testWidgets('a gate with nothing to sign out of keeps its one destination', (
    WidgetTester t,
  ) async {
    for (final GateKind kind in <GateKind>[
      GateKind.invalid,
      GateKind.closed,
      GateKind.notReleased,
    ]) {
      final AssessmentNav nav = await _open(t, kind);
      await t.tap(find.text('Go to my assessments'));
      await t.pumpAndSettle();
      expect(nav.current, const MyAssessments(), reason: '$kind');
    }
  });
}
