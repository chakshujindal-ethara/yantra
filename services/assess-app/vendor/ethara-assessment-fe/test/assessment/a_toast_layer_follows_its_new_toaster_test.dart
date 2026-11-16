// A toast layer rebuilt with another toaster, or at another depth, moves its
// registration with it. Only the deepest mounted layer paints, so a layer that
// stayed registered under the old pair would leave the new one silent (or a
// stale depth hiding every toast underneath).
//
// Ported from stage, then made able to fail: each step starts from a
// registration that would hide the toast if it were left behind.
@TestOn('vm')
library;

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(List<Widget> layers) => MaterialApp(
  home: Scaffold(body: Stack(children: layers)),
);

void main() {
  testWidgets('a layer moved to another depth takes its registration along', (
    WidgetTester t,
  ) async {
    final Toaster b = Toaster();
    await t.pumpWidget(_app(<Widget>[ToastLayer(b, depth: 1)]));
    await t.pumpWidget(_app(<Widget>[ToastLayer(b)]));
    await t.pump();

    b.show('Back at the screen', Tone.ok);
    await t.pump();
    expect(
      find.text('Back at the screen'),
      findsOneWidget,
      reason: 'a depth-1 registration left behind hides every depth-0 layer',
    );
    await t.pump(const Duration(seconds: 30)); // past the toast's dwell
  });

  testWidgets('a layer given a new toaster lets the old one go', (
    WidgetTester t,
  ) async {
    final Toaster a = Toaster();
    final Toaster b = Toaster();
    // The screen's layer on [a], and a sheet's layer above it, also on [a].
    const Key sheet = ValueKey<String>('sheet');
    await t.pumpWidget(
      _app(<Widget>[ToastLayer(a), ToastLayer(a, key: sheet, depth: 1)]),
    );
    // The sheet's layer moves to [b].
    await t.pumpWidget(
      _app(<Widget>[ToastLayer(a), ToastLayer(b, key: sheet, depth: 1)]),
    );
    await t.pump();

    a.show('On the screen', Tone.ok);
    b.show('From the new toaster', Tone.ok);
    await t.pump();
    expect(
      find.text('On the screen'),
      findsOneWidget,
      reason: "a stale depth-1 registration on [a] would silence a's screen",
    );
    expect(find.text('From the new toaster'), findsOneWidget);
    await t.pump(const Duration(seconds: 30));
  });
}
