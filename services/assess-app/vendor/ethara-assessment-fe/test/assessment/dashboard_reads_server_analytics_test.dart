// The cohort totals come from the SERVER, and do not move under navigation.
//
// THE BUG THIS EXISTS FOR. The dashboard derived every cohort figure from the
// tables the store happened to hold, reaching a verdict per attempt through
// `Attempt.result`. That divides by the assessment's frozen question count,
// and a row from the LIST endpoint carries no questions - so every attempt of
// an assessment the operator had not yet opened counted as undecided. Opening
// one assessment's detail page hydrated its questions and RETROACTIVELY moved
// the totals: the same dashboard reported "nothing decided yet", then 0 of 1
// decided, then 3 of 6, purely as a function of where the operator had
// browsed. Cohort outcome and Decided outcomes disagreed with each other and
// with themselves between visits.
//
// `GET /api/v1/analytics` reads the stored `result` on each evaluator, so its
// counts are complete. The screen now prefers them, and the test that matters
// is the one below: hydrating an assessment must change NOTHING.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/dashboard_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Widget mount(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: AssessmentNavScope(nav: AssessmentNav(), child: child)),
);

Future<void> surface(WidgetTester t) async {
  t.view.physicalSize = const Size(1600, 3400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

/// An assessment exactly as `/api/v1/assessments` sends it: NO questions.
Map<String, dynamic> listRow(String id, String name) => <String, dynamic>{
  'id': id,
  'name': name,
  'state': 'done',
  'assigned_count': 2,
  'submitted_count': 2,
  'released_count': 2,
};

/// The same assessment after its detail page has been opened.
Map<String, dynamic> hydrated(String id, String name) => <String, dynamic>{
  ...listRow(id, name),
  'questions': <dynamic>[
    for (int i = 0; i < 10; i++)
      <String, dynamic>{'id': 'q$i', 'name': 'Q$i', 'question_type': 'mcq'},
  ],
};

AppStore seeded({required bool hydratedAssessments}) {
  final AppStore s = AppStore();
  s.assessments = <Assessment>[
    Assessment.fromJson(
      hydratedAssessments ? hydrated('a1', 'Alpha') : listRow('a1', 'Alpha'),
    ),
  ];
  // Straight off the wire, snake_case, exactly as the route answers.
  s.analytics = CohortAnalytics.fromJson(<String, dynamic>{
    'totals': <String, dynamic>{
      'assigned': 12,
      'submitted': 6,
      'decided': 6,
      'passed': 3,
      'failed': 3,
      'awaiting_result': 0,
      'avg_score': 41.7,
      'pass_rate': 50.0,
      'completion_rate': 50.0,
    },
    'flags': <String, dynamic>{'violated': 5},
    'by_assessment': <dynamic>[
      <String, dynamic>{
        'id': 'a1',
        'name': 'Alpha',
        'decided': 4,
        'passed': 2,
        'avg_score': 62.5,
      },
    ],
  });
  return s;
}

void main() {
  group('Cohort figures come from the server, not a local recount', () {
    testWidgets('the parsed payload reaches the panels', (
      WidgetTester t,
    ) async {
      await surface(t);
      await t.pumpWidget(
        mount(DashboardScreen(store: seeded(hydratedAssessments: false))),
      );
      await t.pumpAndSettle();

      expect(t.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      // Pass rate KPI, Cohort outcome and Decided outcomes all read the same
      // decided/passed pair, so one wrong source shows up in all three.
      expect(find.text('3 of 6 decided'), findsOneWidget);
      expect(find.text('3 passed'), findsWidgets);
      expect(find.text('3 failed'), findsWidgets);
      expect(find.text('50.0%'), findsWidgets);
    });

    testWidgets('hydrating an assessment does not move the totals', (
      WidgetTester t,
    ) async {
      await surface(t);

      // The state the operator has never opened an assessment in.
      await t.pumpWidget(
        mount(DashboardScreen(store: seeded(hydratedAssessments: false))),
      );
      await t.pumpAndSettle();
      expect(find.text('3 of 6 decided'), findsOneWidget);

      // Now the same cohort, with the questions a detail visit hydrates. This
      // is the exact transition that used to rewrite every figure.
      await t.pumpWidget(
        mount(DashboardScreen(store: seeded(hydratedAssessments: true))),
      );
      await t.pumpAndSettle();

      expect(
        find.text('3 of 6 decided'),
        findsOneWidget,
        reason: 'opening an assessment must not change the cohort totals',
      );
      expect(find.text('3 passed'), findsWidgets);
      expect(find.text('3 failed'), findsWidgets);
    });

    testWidgets('a seed store with no analytics still renders', (
      WidgetTester t,
    ) async {
      await surface(t);
      final AppStore s = seeded(hydratedAssessments: true)..analytics = null;

      await t.pumpWidget(mount(DashboardScreen(store: s)));
      await t.pumpAndSettle();

      // The local arithmetic is the fallback, so the fixtures keep working.
      expect(t.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
    });
  });
}
