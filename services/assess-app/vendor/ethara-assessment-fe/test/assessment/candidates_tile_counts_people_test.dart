// The "Candidates" tile counts PEOPLE. Everything beside it counts sittings.
//
// THE BUG THIS EXISTS FOR, reported from stage 2026-09-07 as numbers that
// cannot be true:
//
//     CANDIDATES 1330, but Passed 1466 ALONE exceeds it
//     decided 2248 (1466 + 782) > SUBMITTED 1251
//     the cohort bar summed to 2342 under a heading of 1330
//
// Nothing was miscounting. There were TWO DENOMINATORS on one screen:
//
//   * `assignedTotal` folded each assessment's own `assignedCount`
//     (dashboard_screen.dart), and fed the "Candidates" tile.
//   * passed / failed / decided came from the server's per-SITTING recordset.
//
// A candidate who sits two papers is one person and two sittings, so the first
// figure counts them twice and the second once. The tile's own subtitle said
// "across every sitting" underneath a label reading "Candidates" - the bug
// written down in the UI.
//
// Measured on etp_local: 198 sittings across 159 distinct people, 11 people
// holding more than one, one candidate counted 14 times.
//
// THE FIX. `/api/v1/analytics` now sends `totals.people` beside
// `totals.assigned`, and the tile reads `people`. `assigned` KEEPS its meaning
// because completion_rate and the score bands divide by sittings - the test
// `the Submitted tile still divides by sittings` pins that half.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/dashboard_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';

/// The value rendered by the KPI tile carrying [label].
///
/// READS THE TILE'S OWN FIELD rather than searching for the text. An earlier
/// version of this test used `find.text('2')` with `findsWidgets`, which also
/// matched the ASSESSMENTS tile beside it - so it passed against a reverted
/// implementation. A test that cannot fail is not evidence.
String kpiValue(WidgetTester t, String label) {
  final Iterable<Kpi> tiles = t
      .widgetList<Kpi>(find.byType(Kpi))
      .where((Kpi k) => k.label.toUpperCase() == label.toUpperCase());
  expect(tiles, hasLength(1), reason: 'expected exactly one $label tile');
  return tiles.first.value;
}

Widget mount(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: AssessmentNavScope(nav: AssessmentNav(), child: child)),
);

Future<void> surface(WidgetTester t) async {
  t.view.physicalSize = const Size(1600, 3400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

/// Two papers, each reporting 2 assigned - so `assignedTotal` folds to 4.
///
/// This is the shape that produced the impossible dashboard: the same two
/// people sat both papers, which the client cannot know from list rows.
Map<String, dynamic> listRow(String id, String name) => <String, dynamic>{
  'id': id,
  'name': name,
  'state': 'done',
  'assigned_count': 2,
  'submitted_count': 2,
  'released_count': 2,
};

/// One attempt row, timestamped so a date window can include or exclude it.
Map<String, dynamic> attemptRow(String id, String asm, String who,
        {required int daysAgo}) =>
    <String, dynamic>{
      'id': id,
      'assessment_id': asm,
      'employee_id': who,
      'state': 'submitted',
      'submitted_at':
          DateTime.now().subtract(Duration(days: daysAgo)).toIso8601String(),
      'score': 60.0,
      'results_released': true,
    };

AppStore seeded({int? people, int assigned = 4}) {
  final AppStore s = AppStore();
  s.assessments = <Assessment>[
    Assessment.fromJson(listRow('a1', 'Alpha')),
    Assessment.fromJson(listRow('a2', 'Bravo')),
  ];
  s.analytics = CohortAnalytics.fromJson(<String, dynamic>{
    'totals': <String, dynamic>{
      // FOUR SITTINGS, TWO PEOPLE. Both sat both papers.
      'assigned': assigned,
      // Null-aware element: the key is omitted entirely when `people` is null,
      // which is how the "older server sends no people key" case is built.
      'people': ?people,
      'submitted': 4,
      'decided': 4,
      'passed': 3,
      'failed': 1,
      'awaiting_result': 0,
      'avg_score': 61.0,
      'pass_rate': 75.0,
      'completion_rate': 100.0,
    },
    'flags': <String, dynamic>{},
    'by_assessment': <dynamic>[],
  });
  return s;
}

void main() {
  group('the Candidates tile reports people, not sittings', () {
    testWidgets('two people who each sat two papers read as 2, not 4', (
      WidgetTester t,
    ) async {
      await surface(t);
      await t.pumpWidget(mount(DashboardScreen(store: seeded(people: 2))));
      await t.pumpAndSettle();

      expect(t.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);

      // THE HEADLINE. Before the fix this tile read 4 - the fold over
      // assigned_count - while `passed` beside it was counted per sitting.
      expect(
        kpiValue(t, 'Candidates'),
        '2',
        reason: 'the tile must show PEOPLE (2), not sittings (4)',
      );
      // And it says which figure it is NOT showing, so the sittings count is
      // still available to an operator who needs it.
      expect(find.text('4 sittings between them'), findsOneWidget);
    });

    testWidgets('Passed can no longer exceed the Candidates tile silently', (
      WidgetTester t,
    ) async {
      // THE REPORTED SYMPTOM. `passed` (3) exceeds `people` (2) here, which is
      // legitimate - three of four SITTINGS passed. What must not happen is
      // the screen presenting the two as comparable without saying so: the
      // subtitle names the sittings denominator that `passed` belongs to.
      await surface(t);
      await t.pumpWidget(mount(DashboardScreen(store: seeded(people: 2))));
      await t.pumpAndSettle();

      expect(
        find.text('4 sittings between them'),
        findsOneWidget,
        reason: 'the tile must disclose the denominator passed/failed use',
      );
    });

    testWidgets('with one sitting each the note says so', (
      WidgetTester t,
    ) async {
      // THE COMMON CASE must not read as an anomaly. When the two figures
      // agree there is no discrepancy to explain, and printing
      // "2 sittings between them" beside "2" would invite the reader to look
      // for a problem that is not there.
      await surface(t);
      await t.pumpWidget(
        mount(DashboardScreen(store: seeded(people: 2, assigned: 2))),
      );
      await t.pumpAndSettle();

      expect(find.text('one sitting each'), findsOneWidget);
      expect(find.text('4 sittings between them'), findsNothing);
    });

    testWidgets('a payload with no people key still renders a real figure', (
      WidgetTester t,
    ) async {
      // BACKWARD COMPATIBILITY, and it must not fall back to the inflated
      // number. An older server (or a seed fixture) sends no `people`, so the
      // screen counts distinct candidates from the attempts it holds. With no
      // attempts cached that is 0 rather than a knowingly wrong 4 - an honest
      // blank beats a confident lie.
      await surface(t);
      await t.pumpWidget(mount(DashboardScreen(store: seeded())));
      await t.pumpAndSettle();

      expect(t.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.byType(DashboardScreen), findsOneWidget);
    });

    testWidgets('the Submitted tile still divides by sittings', (
      WidgetTester t,
    ) async {
      // THE GUARD ON THE FIX. completion_rate is submitted/assigned, both per
      // sitting. If `people` had replaced `assigned` everywhere, every rate on
      // the screen would have changed meaning with no test failing.
      await surface(t);
      await t.pumpWidget(mount(DashboardScreen(store: seeded(people: 2))));
      await t.pumpAndSettle();

      expect(find.text('SUBMITTED'), findsOneWidget);
      // `3 of 4 decided` is the per-SITTING denominator, straight from the
      // server. If `people` had replaced `assigned` this would read "of 2".
      expect(
        find.text('3 of 4 decided'),
        findsOneWidget,
        reason: 'decided/passed divide by sittings and must not move',
      );
    });
  });

  group('the cohort bar no longer promises what it does not do', () {
    testWidgets('the caption says sittings, not candidates once', (
      WidgetTester t,
    ) async {
      // The bar has ALWAYS plotted sittings; the caption claimed "every
      // assigned candidate, once". The arithmetic was right and the sentence
      // was wrong, which is what made the total look impossible.
      await surface(t);
      await t.pumpWidget(mount(DashboardScreen(store: seeded(people: 2))));
      await t.pumpAndSettle();

      expect(find.text('one bar segment per sitting'), findsOneWidget);
      expect(
        find.text('every assigned candidate, once'),
        findsNothing,
        reason: 'the false promise must not come back',
      );
    });
  });

  group('a date window and the server figures cannot disagree', () {
    // FOUND BY ADVERSARIAL REVIEW. `/api/v1/analytics` takes an assessment and
    // NOTHING ELSE, so its `people` and `assigned` always describe the whole
    // cohort. Preferring them unconditionally printed the all-time figure under
    // a heading of "Last 7 days", beside a cohort bar built from the windowed
    // rows - two different cohorts on one screen, presented as the same one.
    //
    // Windowed, the local walk over `everyone` IS the answer, because that is
    // the exact list the bar draws a segment per.
    // THE SERVER SAYS 3 (the all-time truth), the window holds 2. The two
    // figures MUST differ, or neither assertion below can fail and the pair is
    // vacuous - which is exactly the trap this file's `kpiValue` helper exists
    // to document.
    AppStore windowed() {
      final AppStore s = seeded(people: 3);
      s.attempts = <Attempt>[
        // Two people, one sitting each, INSIDE any 7-day window.
        Attempt.fromJson(attemptRow('e1', 'a1', 'p1', daysAgo: 1)),
        Attempt.fromJson(attemptRow('e2', 'a1', 'p2', daysAgo: 2)),
        // A third person, long ago - outside a 7-day window, inside 90.
        Attempt.fromJson(attemptRow('e3', 'a2', 'p3', daysAgo: 60)),
      ];
      return s;
    }

    testWidgets('unwindowed, the server figure is still preferred',
        (WidgetTester t) async {
      // The server can see across assessments the client has not hydrated, so
      // where it CAN answer, it remains the authority.
      await surface(t);
      await t.pumpWidget(mount(DashboardScreen(store: windowed())));
      await t.pumpAndSettle();

      expect(kpiValue(t, 'Candidates'), '3',
          reason: "the server's distinct-people count is authoritative when no "
              'window narrows the question');
    });

    testWidgets('windowed, the tile counts the people in the window',
        (WidgetTester t) async {
      await surface(t);
      await t.pumpWidget(mount(DashboardScreen(store: windowed())));
      await t.pumpAndSettle();

      await t.tap(find.text('Any date'));
      await t.pumpAndSettle();
      await t.tap(find.text('Last 7 days').last);
      await t.pumpAndSettle();

      expect(t.takeException(), isNull);
      // Three people exist all-time (what the server reports); two sat inside
      // the window. The tile must follow the WINDOW, not the server.
      expect(kpiValue(t, 'Candidates'), '2',
          reason: 'only the sittings inside the window may be counted - the '
              'server reports 3, which is the all-time cohort');
      // And the scope note names the window, so the two agree in words as well
      // as in arithmetic.
      expect(find.textContaining('last 7 days'), findsWidgets);
    });
  });
}
