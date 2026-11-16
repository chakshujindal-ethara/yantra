// The dashboard reads the server's whole-cohort totals, and says what they are.
//
// THE BUG THIS EXISTS FOR. Submitted, "% of assigned", Needs review and its
// three rows were counted off the cached attempt rows, a walk capped at 5,000,
// while `/api/v1/analytics` already sent `totals.submitted`, `completion_rate`
// and the flag counts. The cohort bar called every unsubmitted sitting "Not
// started", so a paper half written read as unopened. The leaderboard said
// "of 822 submitted attempts" over 822 PEOPLE holding 2,101 attempts. "Pass
// threshold" was the mean of the visible bars, a figure no assessment was set
// to, and the pass rate was coloured against it.
//
// Every server figure below differs from what the cache would give, so each
// assertion fails if the screen falls back to the rows when it should not.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/dashboard_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/charts.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';

Widget mount(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: AssessmentNavScope(nav: AssessmentNav(), child: child),
  ),
);

Future<void> surface(WidgetTester t) async {
  t.view.physicalSize = const Size(1600, 3400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

Kpi kpi(WidgetTester t, String label) => t
    .widgetList<Kpi>(find.byType(Kpi))
    .singleWhere((Kpi k) => k.label == label);

/// The value shown in the key/value row labelled [label].
Finder kv(String label, String value) => find.descendant(
  of: find.widgetWithText(KvRow, label),
  matching: find.text(value),
);

double slice(WidgetTester t, String label) => t
    .widget<StackedBar>(find.byType(StackedBar))
    .slices
    .singleWhere((Slice s) => s.label == label)
    .value;

Map<String, dynamic> asm(String id, String name, double threshold) =>
    <String, dynamic>{
      'id': id,
      'name': name,
      'state': 'done',
      'assigned_count': 2,
      'submitted_count': 1,
      'released_count': 1,
      'pass_threshold': threshold,
    };

String ago(int days) =>
    DateTime.now().subtract(Duration(days: days)).toIso8601String();

/// THE CACHE: one submitted and flagged, one in progress, one never opened.
List<Attempt> cache() => <Attempt>[
  Attempt.fromJson(<String, dynamic>{
    'id': 'e1',
    'assessment_id': 'a1',
    'employee_id': 'p1',
    'state': 'submitted',
    'started_at': ago(1),
    'submitted_at': ago(1),
    'integrity_alert': true,
  }),
  Attempt.fromJson(<String, dynamic>{
    'id': 'e2',
    'assessment_id': 'a1',
    'employee_id': 'p2',
    'state': 'in_progress',
    'started_at': ago(1),
  }),
  Attempt.fromJson(<String, dynamic>{
    'id': 'e3',
    'assessment_id': 'a2',
    'employee_id': 'p3',
    'state': 'pending',
  }),
];

/// [newFields] false builds the payload of a server that predates
/// `in_progress`, `not_started` and `needs_review`.
AppStore seeded({
  bool newFields = true,
  double alpha = 70,
  double bravo = 70,
  int awaiting = 10,
  List<Attempt>? attempts,
}) {
  final AppStore s = AppStore();
  s.assessments = <Assessment>[
    Assessment.fromJson(asm('a1', 'Alpha', alpha)),
    Assessment.fromJson(asm('a2', 'Bravo', bravo)),
  ];
  s.attempts = attempts ?? cache();
  s.analytics = CohortAnalytics.fromJson(<String, dynamic>{
    'totals': <String, dynamic>{
      'assigned': 50,
      'people': 40,
      'submitted': 40,
      'decided': 30,
      'passed': 20,
      'failed': 10,
      'awaiting_result': awaiting,
      'avg_score': 60.0,
      'pass_rate': 66.7,
      'completion_rate': 80.0,
      if (newFields) 'in_progress': 6,
      if (newFields) 'not_started': 4,
    },
    'flags': <String, dynamic>{
      'integrity_alert': 7,
      'score_outlier': 2,
      'violated': 3,
      if (newFields) 'needs_review': 9,
    },
    'by_assessment': <dynamic>[],
  });
  s.leaderboardTotal = 822;
  s.leaderboardReturned = 200;
  return s;
}

Future<void> show(WidgetTester t, AppStore s) async {
  await surface(t);
  await t.pumpWidget(mount(DashboardScreen(store: s)));
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
}

Future<void> lastSevenDays(WidgetTester t) async {
  await t.tap(find.text('Any date'));
  await t.pumpAndSettle();
  await t.tap(find.text('Last 7 days').last);
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
}

void main() {
  group('the words on the dashboard', () {
    testWidgets('the page is called Dashboard', (WidgetTester t) async {
      await show(t, seeded());
      // One title line carrying both names at page-title size, then the
      // explainer at the usual sub size.
      expect(find.text('Dashboard - Assessment Analytics'), findsOneWidget);
      expect(
        find.text('Cohort performance across every assessment.'),
        findsOneWidget,
      );
      final double titleSize = t
          .widget<Text>(find.text('Dashboard - Assessment Analytics'))
          .style!
          .fontSize!;
      final double subSize = t
          .widget<Text>(
            find.text('Cohort performance across every assessment.'),
          )
          .style!
          .fontSize!;
      expect(titleSize, greaterThan(subSize));
    });

    testWidgets('the leaderboard counts candidates, not attempts', (
      WidgetTester t,
    ) async {
      await show(t, seeded());
      expect(
        find.text('top 200 of 822 candidates with a submitted attempt'),
        findsOneWidget,
      );
      expect(find.textContaining('822 submitted attempts'), findsNothing);
    });

    testWidgets('awaiting result says the result is not released', (
      WidgetTester t,
    ) async {
      await show(t, seeded());
      expect(kpi(t, 'Awaiting result').sub, 'submitted, not released');
      expect(find.text('submitted, not scored'), findsNothing);
    });

    testWidgets('the analytics band says scoring or release holds a result', (
      WidgetTester t,
    ) async {
      await show(t, seeded());
      expect(
        find.text(
          '10 submitted attempt(s) are waiting on scoring or release before '
          'a result is out.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('an untruncated leaderboard says every candidate', (
      WidgetTester t,
    ) async {
      await show(t, seeded()..leaderboardReturned = 822);
      expect(
        find.text('every candidate with a submitted attempt'),
        findsOneWidget,
      );
    });
  });

  group('the pass threshold is one bar or a named range', () {
    testWidgets('mixed bars read as a range and colour nothing', (
      WidgetTester t,
    ) async {
      await show(t, seeded(alpha: 70, bravo: 50));
      expect(kv('Pass threshold', 'Mixed (50-70%)'), findsOneWidget);
      expect(
        kpi(t, 'Pass rate').valueColor,
        isNull,
        reason: 'no single bar exists to colour the rate against',
      );
    });

    testWidgets('one shared bar is shown and judged as before', (
      WidgetTester t,
    ) async {
      await show(t, seeded(alpha: 70, bravo: 70));
      expect(kv('Pass threshold', '70.0%'), findsOneWidget);
      // 66.7% under a 70% bar is a fail, so the rate takes a colour.
      expect(kpi(t, 'Pass rate').valueColor, isNotNull);
    });
  });

  group('server totals win over the cached rows', () {
    testWidgets('with no date window every figure is the server one', (
      WidgetTester t,
    ) async {
      await show(t, seeded());
      expect(kpi(t, 'Submitted').value, '40');
      expect(kpi(t, 'Submitted').sub, '80.0% of assigned');
      expect(kpi(t, 'Needs review').value, '9');
      expect(kv('Answers to review', '7'), findsOneWidget);
      expect(kv('Unusually high scores', '2'), findsOneWidget);
      expect(kv('Exam rules broken', '3'), findsOneWidget);
      expect(slice(t, 'In progress'), 6);
      expect(slice(t, 'Not started'), 4);
    });

    testWidgets('an older server without the new fields falls back to rows', (
      WidgetTester t,
    ) async {
      await show(t, seeded(newFields: false));
      // The fields it does send still win.
      expect(kpi(t, 'Submitted').value, '40');
      expect(kv('Answers to review', '7'), findsOneWidget);
      // The ones it does not are counted from the cache: one flagged
      // sitting, one in progress, one never opened.
      expect(kpi(t, 'Needs review').value, '1');
      expect(slice(t, 'In progress'), 1);
      expect(slice(t, 'Not started'), 1);
    });

    testWidgets('a date window falls back to the rows in the window', (
      WidgetTester t,
    ) async {
      await show(t, seeded());
      await lastSevenDays(t);

      // The route takes no dates, so its all-time 40 and 9 would describe a
      // different cohort from the windowed bar.
      expect(kpi(t, 'Submitted').value, '1');
      expect(kpi(t, 'Needs review').value, '1');
      expect(kv('Answers to review', '1'), findsOneWidget);
      expect(slice(t, 'In progress'), 1);
    });

    testWidgets('the bar sentence counts the sittings in the window', (
      WidgetTester t,
    ) async {
      // Four cached sittings in the window: one submitted, one in progress,
      // two never opened. The server still sends all-time passed 20 and
      // failed 10, so a sum of the slices would read "2 of 33".
      await show(
        t,
        seeded(
          awaiting: 0,
          attempts: <Attempt>[
            ...cache(),
            Attempt.fromJson(<String, dynamic>{
              'id': 'e4',
              'assessment_id': 'a2',
              'employee_id': 'p4',
              'state': 'pending',
            }),
          ],
        ),
      );
      await lastSevenDays(t);

      expect(
        find.text('2 of 4 sittings have not been started yet.'),
        findsOneWidget,
      );
    });

    testWidgets('an empty window shows the empty state, not the all-time bar', (
      WidgetTester t,
    ) async {
      await show(
        t,
        seeded(
          attempts: <Attempt>[
            Attempt.fromJson(<String, dynamic>{
              'id': 'old',
              'assessment_id': 'a1',
              'employee_id': 'p1',
              'state': 'submitted',
              'started_at': ago(60),
              'submitted_at': ago(60),
            }),
          ],
        ),
      );
      // Unwindowed the server's cohort is drawn.
      expect(find.byType(StackedBar), findsOneWidget);

      await lastSevenDays(t);

      expect(find.text('Nobody is assigned yet.'), findsOneWidget);
      expect(find.byType(StackedBar), findsNothing);
    });
  });
}
