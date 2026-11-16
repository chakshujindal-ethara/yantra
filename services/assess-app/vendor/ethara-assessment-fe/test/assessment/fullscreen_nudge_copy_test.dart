/// The offer bar must not tell a candidate they have a violation they do not.
///
/// THE BUG THIS PINS: the bar's only sentence used to be "You left fullscreen.
/// That has been recorded". Two routes now reach it with nothing on the
/// record - a browser that refused the entry outright, so the requirement
/// degraded from a wall to an offer rather than trapping the candidate; and an
/// exit the browser performed itself in order to show a permission prompt. A
/// proctoring notice that can be wrong is worse than none: it is the sentence
/// somebody would quote in an appeal.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';

Widget mount({required bool recorded}) => MaterialApp(
  home: Scaffold(
    body: FullscreenNudge(recorded: recorded, onEnter: () {}),
  ),
);

void main() {
  testWidgets('a refusal is never reported as a recorded violation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(mount(recorded: false));

    // The AFFIRMATIVE claim, not the substring: the honest copy says "Nothing
    // has been recorded", which contains the shorter phrase and would pass a
    // lazier assertion while saying the opposite.
    expect(
      find.textContaining('That has been recorded'),
      findsNothing,
      reason: 'nothing was recorded, so the bar must not claim it was',
    );
    expect(find.textContaining('Nothing has been recorded'), findsOneWidget);
    // And it still offers the way back, or the rule is simply abandoned.
    expect(find.text('Try fullscreen again'), findsOneWidget);
  });

  testWidgets('a real exit still says so', (WidgetTester tester) async {
    await tester.pumpWidget(mount(recorded: true));

    expect(find.textContaining('That has been recorded'), findsOneWidget);
    expect(find.text('Return to fullscreen'), findsOneWidget);
  });

  testWidgets('an exit whose report has not reached the server yet is '
      '"noted", not "recorded" (F4)', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FullscreenNudge(recorded: true, queued: true, onEnter: () {}),
        ),
      ),
    );
    expect(find.textContaining('That has been noted'), findsOneWidget);
    expect(find.textContaining('That has been recorded'), findsNothing);
  });

  testWidgets('neither wording mentions F11', (WidgetTester tester) async {
    // F11 is browser-chrome fullscreen: it does not set
    // `document.fullscreenElement`, so no `fullscreenchange` fires, this bar
    // does not clear, and the tab-switch rule stays disarmed. Telling a
    // candidate to press it hands them an action that visibly does nothing,
    // which is the exact failure this change exists to remove.
    for (final bool recorded in <bool>[true, false]) {
      await tester.pumpWidget(mount(recorded: recorded));
      expect(find.textContaining('F11'), findsNothing);
    }
  });
}
