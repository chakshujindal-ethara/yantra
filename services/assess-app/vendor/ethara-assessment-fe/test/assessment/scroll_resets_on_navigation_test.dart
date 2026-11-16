// A NEW PAGE OPENS AT ITS TOP.
//
// THE BUG THIS EXISTS FOR. One `SingleChildScrollView` in `AssessmentSection`
// serves every route. Without a key Flutter reuses the same `ScrollPosition`
// across a navigation, so the offset you were at survived into the next
// screen. From the dashboard leaderboard - which sits well below the fold -
// opening a candidate landed you partway down THEIR page, past its heading and
// KPI strip, in the middle of the score breakdown table. It read as having
// gone to the wrong screen entirely.
//
// It was reported as two candidates behaving differently, which is exactly how
// it presents: a candidate with one sitting has a page too short to hold the
// offset, so it clamps to zero and looks correct, while a candidate with four
// keeps it and looks broken. The difference is page height, not the candidate.
//
// The key is on the ROUTE, so a rebuild in place - a refresh landing, a search
// box being typed into - must NOT throw the reader back to the top. Both
// halves are asserted here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/assessment_section.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// Enough rows that every screen involved is taller than the viewport.
AppStore _store() {
  final AppStore s = AppStore();
  s.people = <Person>[
    for (int i = 0; i < 12; i++)
      Person(id: 'p$i', name: 'Person $i', email: 'p$i@example.com'),
  ];
  s.assessments = <Assessment>[
    for (int i = 0; i < 12; i++)
      Assessment.fromJson(<String, dynamic>{
        'id': 'a$i',
        'name': 'Assessment number $i',
        'state': 'done',
      }),
  ];
  return s;
}

/// The live scroll offset of the section's one scroll view.
double _offset(WidgetTester t) =>
    t.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;

Future<AssessmentNav> _mount(WidgetTester t) async {
  t.view.physicalSize = const Size(1400, 700);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  final AppStore s = _store();
  addTearDown(s.dispose);

  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentSection(store: s, entry: AssessmentEntry.analytics),
      ),
    ),
  );
  await t.pumpAndSettle();

  return t.widget<AssessmentNavScope>(find.byType(AssessmentNavScope)).notifier!;
}

void main() {
  testWidgets('navigating away lands at the top of the new page', (
    WidgetTester t,
  ) async {
    final AssessmentNav nav = await _mount(t);

    await t.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await t.pumpAndSettle();
    expect(
      _offset(t),
      greaterThan(0),
      reason: 'the fixture must be tall enough to scroll, or this proves '
          'nothing',
    );

    nav.assessments();
    await t.pumpAndSettle();

    expect(
      _offset(t),
      0,
      reason: 'a screen opened from a control low on the previous page must '
          'start at its own heading, not at the offset the reader left',
    );
  });

  testWidgets('a rebuild in place keeps the reader where they were', (
    WidgetTester t,
  ) async {
    final AssessmentNav nav = await _mount(t);

    await t.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await t.pumpAndSettle();
    final double was = _offset(t);
    expect(was, greaterThan(0));

    // Same route, rebuilt - what a refresh landing or a keystroke in a search
    // box does. Resetting here would yank the page out from under a reader.
    nav.go(nav.current);
    await t.pumpAndSettle();

    expect(
      _offset(t),
      was,
      reason: 'the key is on the route, so an in-place rebuild must not scroll',
    );
  });
}
