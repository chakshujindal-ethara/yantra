/// Every section of the Dashboard is spaced from the next one.
///
/// THE DEFECT. `PageBody` is a bare `Column` with no gap of its own, so each
/// space between panels on this page was a hand-placed `SizedBox` - and three
/// of the five boundaries never got one. The analytics band ran straight into
/// Cohort Outcome, the Performance row into Strengths and Weaknesses, and that
/// into Time Analysis, with no seam between a panel's bottom border and the
/// next panel's top. The two boundaries that DID carry a `SizedBox` looked
/// correct, which is what made the other three read as a rendering fault
/// rather than a missing line of layout.
///
/// Asserted as a rule over the whole stack rather than three fixed numbers: a
/// panel added to this page must not be able to arrive flush against its
/// neighbour, and that is only true while the page spaces its sections
/// centrally.
library;

import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/dashboard_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';
import 'package:ethara_assessment/core/theme/portal_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The panels of the section stack, in the order the page lays them out.
/// Panels sharing a row (`Cols2`) are listed together.
const List<List<String>> kRows = <List<String>>[
  <String>['Where the Cohort Stands', 'Decided Outcomes'],
  <String>['Candidates per Assessment'],
  <String>['Cohort Outcome', 'Needs Review'],
  <String>['Performance by Assessment', 'Leaderboard'],
  <String>['Strengths and Weaknesses'],
  <String>['Time Analysis'],
];

/// The rect of the `Panel` carrying this title.
Rect panelRect(WidgetTester tester, String title) {
  final Finder t = find.text(title);
  expect(t, findsWidgets, reason: 'no panel titled "$title" on the dashboard');
  final Element panel = find
      .ancestor(of: t.first, matching: find.byType(Panel))
      .evaluate()
      .first;
  final RenderBox b = panel.renderObject! as RenderBox;
  return b.localToGlobal(Offset.zero) & b.size;
}

void main() {
  testWidgets('no two sections meet flush', (WidgetTester tester) async {
    // Tall enough that the whole page lays out at once - a scrolled-off panel
    // has no rect to measure.
    tester.view.physicalSize = const Size(1600, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final AppStore s = AppStore();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: AssessmentNavScope(
            nav: AssessmentNav(),
            child: DashboardScreen(store: s),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (int i = 0; i + 1 < kRows.length; i++) {
      // A row ends at its TALLEST panel: Needs Review outruns Cohort Outcome
      // beside it, and it is that edge the next row has to clear.
      final double bottom = kRows[i]
          .map((String t) => panelRect(tester, t).bottom)
          .reduce((double a, double b) => a > b ? a : b);
      final double next = kRows[i + 1]
          .map((String t) => panelRect(tester, t).top)
          .reduce((double a, double b) => a < b ? a : b);

      expect(
        next - bottom,
        Layout.gridGap,
        reason:
            '${kRows[i].first} -> ${kRows[i + 1].first} is ${next - bottom}px, '
            'not the ${Layout.gridGap}px every other boundary uses',
      );
    }
    s.dispose();
  });

  testWidgets('the two halves of a row stay level', (
    WidgetTester tester,
  ) async {
    // The gap rule above measures from the taller half, so a row whose halves
    // no longer start together would make those numbers mean something else.
    tester.view.physicalSize = const Size(1600, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final AppStore s = AppStore();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: AssessmentNavScope(
            nav: AssessmentNav(),
            child: DashboardScreen(store: s),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final List<String> row in kRows.where((List<String> r) => r.length > 1)) {
      final double first = panelRect(tester, row.first).top;
      for (final String other in row.skip(1)) {
        expect(panelRect(tester, other).top, first, reason: row.join(' / '));
      }
    }
    s.dispose();
  });
}
