// A worker who came from Yantra gets a way back from every dead end, and the
// sign-in form offers Yantra instead of a password they never had.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/gate_screen.dart';
import 'package:ethara_assessment/login_screen.dart';
import 'package:ethara_assessment/session.dart';
import 'package:ethara_assessment/yantra_launch.dart';

Future<void> _gate(WidgetTester t, GateKind kind) async {
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: AssessmentNavScope(
        nav: AssessmentNav(),
        child: GateScreen(kind: kind),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  tearDown(() => rememberYantraReturn(null));

  testWidgets('gates offer Back to Yantra only to a Yantra session', (
    WidgetTester t,
  ) async {
    await _gate(t, GateKind.closed);
    expect(find.text('Back to Yantra'), findsNothing);

    rememberYantraReturn('http://localhost:8095/work');
    for (final GateKind k in <GateKind>[
      GateKind.closed,
      GateKind.invalid,
      GateKind.notReleased,
      GateKind.login,
    ]) {
      await _gate(t, k);
      expect(find.text('Back to Yantra'), findsOneWidget, reason: k.name);
    }
    await t.tap(find.text('Back to Yantra'));
    await t.pumpAndSettle();
  });

  testWidgets('the login form offers Yantra when this build knows it', (
    WidgetTester t,
  ) async {
    final Session s = Session();
    addTearDown(s.dispose);
    Future<void> pump(Uri? Function() yantra) => t.pumpWidget(
      MaterialApp(
        home: LoginScreen(session: s, continueWithYantra: yantra),
      ),
    );
    await pump(() => null);
    expect(find.text('Continue with Yantra'), findsNothing);
    await pump(() => Uri.parse('http://localhost:8095'));
    expect(find.text('Continue with Yantra'), findsOneWidget);
    await t.tap(find.text('Continue with Yantra'));
    await t.pump();
  });
}
