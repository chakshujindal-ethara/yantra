// A leaderboard row opens THAT person's own performance page (A-133).
//
// The owner's call (18 Aug): reuse the real My Performance layout, admin-only,
// rather than a separate operator screen. A 2026-09-08 change pointed the row
// at `CandidateDetail` instead, because the page hid a held sitting's marks
// from the admin who decides the release. That reason is fixed on the page
// itself - an operator's breakdown row shows a held mark - so the row goes back
// to `CandidatePerformance`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/dashboard_screen.dart';
import 'package:ethara_assessment/assessment/screens/member/my_performance_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/marks.dart';

Widget mount(Widget child, AssessmentNav nav) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: AssessmentNavScope(nav: nav, child: child)),
);

Future<void> surface(WidgetTester t) async {
  t.view.physicalSize = const Size(1600, 3400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

const String kWho = 'p-77';

AppStore seeded() {
  final AppStore s = AppStore();
  s.people = <Person>[
    const Person(id: kWho, name: 'Priya Sharma', email: 'priya@example.com'),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 'a1',
      'name': 'Alpha',
      'state': 'done',
      'assigned_count': 1,
      'submitted_count': 1,
    }),
  ];
  // Submitted and marked, NOT released: the case the 09-08 change was about.
  s.attempts = <Attempt>[
    Attempt(
      id: 'e1',
      assessmentId: 'a1',
      employeeId: kWho,
      token: 'e1',
      state: AttemptState.submitted,
      submittedAt: DateTime.parse('2026-08-17T13:31:00Z'),
      serverEarned: 7,
      serverTotal: 10,
    ),
  ];
  s.leaderboard = <Map<String, dynamic>>[
    <String, dynamic>{
      'rank': 1,
      'applicant_id': kWho,
      'applicant_name': 'Priya Sharma',
      'attempts': 1,
      'avg_score': 70.0,
      'best_score': 70.0,
      'passed': 1,
    },
  ];
  return s;
}

Finder heldMarks() =>
    find.byWidgetPredicate((Widget w) => w is Marks && w.earned == 7);

void main() {
  testWidgets('tapping a leaderboard row opens that person\'s performance '
      'page', (WidgetTester t) async {
    await surface(t);
    final AssessmentNav nav = AssessmentNav();
    await t.pumpWidget(mount(DashboardScreen(store: seeded()), nav));
    await t.pumpAndSettle();

    await t.tap(find.text('Priya Sharma').first);
    await t.pumpAndSettle();

    expect(nav.current, const CandidatePerformance(kWho));
  });

  testWidgets('an operator sees a held row\'s marks; the candidate does not', (
    WidgetTester t,
  ) async {
    await surface(t);
    final AppStore s = seeded()..meId = 'admin-1';
    await t.pumpWidget(
      mount(MyPerformanceScreen(store: s, personId: kWho), AssessmentNav()),
    );
    await t.pumpAndSettle();
    expect(heldMarks(), findsOneWidget);
    expect(find.text('Awaiting release'), findsOneWidget);

    // Invariant 3: the same sitting on the candidate's own page stays hidden.
    final AppStore own = seeded()..meId = kWho;
    await t.pumpWidget(mount(MyPerformanceScreen(store: own), AssessmentNav()));
    await t.pumpAndSettle();
    expect(heldMarks(), findsNothing);
  });
}
