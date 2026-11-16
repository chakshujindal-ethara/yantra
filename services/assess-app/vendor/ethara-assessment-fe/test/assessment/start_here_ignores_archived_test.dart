// Start-here counts the LIVE catalogue, never the archived one.
//
// THE BUG THIS EXISTS FOR. `_loadAdmin` fetches assessments with
// `include_archived` on purpose, so the assessment list's "Show archived"
// toggle has rows to reveal and Restore stays reachable. That puts archived
// rows in `store.assessments`, and `visibleAssessments` is the chokepoint that
// drops them again for everybody else.
//
// Stage 4 of this screen read `store.assessments` DIRECTLY and bypassed it. So
// after an operator deliberately filed an assessment away, Start-here still
// counted it as "live now" and still demanded its results be released - the
// screen whose whole job is to say what is outstanding was inventing work that
// somebody had explicitly finished with.
//
// A store-level test does not catch this class of bug: `visibleAssessments`
// filtered correctly the whole time, and the screen simply did not call it.
// Only rendering the screen does, which is why this is a widget test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/start_here_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Widget mount(Widget child, AssessmentNav nav) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: AssessmentNavScope(nav: nav, child: child),
  ),
);

Future<void> setSurface(WidgetTester tester) async {
  // Tall: the screen is a column of five stage cards and overflows a laptop
  // height, which would fail every assertion on a RenderFlex complaint rather
  // than on the thing under test.
  tester.view.physicalSize = const Size(1600, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The rendered "live now" figure on the Assessments stage card.
///
/// The unit label is uppercased at render (`stage.unit.toUpperCase()`), and the
/// numeral is its immediate sibling in the same right-aligned Column - so the
/// label is the anchor and the count is read out of that Column.
String liveNow(WidgetTester tester) {
  final Finder unit = find.text('LIVE NOW');
  expect(unit, findsOneWidget, reason: 'Stage 4 should be on screen');
  final Finder column = find
      .ancestor(of: unit, matching: find.byType(Column))
      .first;
  final Iterable<Text> texts = tester.widgetList<Text>(
    find.descendant(of: column, matching: find.byType(Text)),
  );
  final Iterable<String> numerals = texts
      .map((Text t) => t.data ?? '')
      .where((String d) => int.tryParse(d) != null);
  expect(
    numerals,
    isNotEmpty,
    reason: 'the stage card should carry a numeric count beside its unit',
  );
  return numerals.first;
}

void main() {
  testWidgets('an archived assessment is not counted as live now', (
    WidgetTester tester,
  ) async {
    await setSurface(tester);
    final AppStore store = AppStore();

    // Every in-progress assessment the seed carries, archived. Whatever the
    // seed's shape, the live count must fall to zero.
    store.assessments = store.assessments
        .map(
          (Assessment a) =>
              a.state == AsmState.inProgress ? a.copyWith(active: false) : a,
        )
        .toList();

    await tester.pumpWidget(
      mount(StartHereScreen(store: store), AssessmentNav()),
    );
    await tester.pump();

    expect(
      store
          .visibleAssessments(Portal.admin)
          .where((Assessment a) => a.state == AsmState.inProgress)
          .length,
      0,
      reason: 'precondition: nothing live is left unarchived',
    );
    expect(
      liveNow(tester),
      '0',
      reason:
          'an archived assessment must not be reported as a live sitting - '
          'Stage 4 read store.assessments raw and counted it',
    );
  });

  testWidgets('a live assessment is still counted', (
    WidgetTester tester,
  ) async {
    await setSurface(tester);
    final AppStore store = AppStore();
    final int expected = store
        .visibleAssessments(Portal.admin)
        .where((Assessment a) => a.state == AsmState.inProgress)
        .length;

    await tester.pumpWidget(
      mount(StartHereScreen(store: store), AssessmentNav()),
    );
    await tester.pump();

    expect(
      liveNow(tester),
      contains('$expected'),
      reason: 'the fix must not have zeroed the count for everybody',
    );
  });
}
