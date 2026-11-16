// The two dashboard tables are the same size as each other.
//
// They sit side by side and are read together, so a height difference reads as
// a broken layout. A minimum height alone does NOT achieve this: it only stops
// a card collapsing, and these two cards' rows are not the same height. A
// Performance row carries a `FunnelCell` - a progress bar over a line of text -
// while a Leaderboard row is a single line, so ten of one is taller than ten of
// the other and the floor is reached by only one of them.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/dashboard_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';

Widget mount(Widget child, AssessmentNav nav) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: AssessmentNavScope(nav: nav, child: child)),
);

/// A store with [assessments] assessments and [candidates] ranked people, so
/// each panel's row count can be driven independently.
AppStore storeWith({required int assessments, required int candidates}) {
  final AppStore s = AppStore();
  s.assessments = <Assessment>[
    for (int i = 0; i < assessments; i++)
      Assessment.fromJson(<String, dynamic>{
        'id': 'a$i',
        'name': 'Assessment $i',
        'state': 'in_progress',
        'assigned_count': 4,
        'submitted_count': 2,
        'released_count': 1,
      }),
  ];
  s.leaderboard = <Map<String, dynamic>>[
    for (int i = 0; i < candidates; i++)
      <String, dynamic>{
        'rank': i + 1,
        'applicant_id': i + 1,
        'applicant_name': 'Candidate $i',
        'avg_score': 50.0,
      },
  ];
  return s;
}

double panelHeight(WidgetTester tester, String title) {
  final Finder panel = find.ancestor(
    of: find.text(title),
    matching: find.byType(Panel),
  );
  expect(panel, findsOneWidget, reason: 'panel "$title" not found');
  return tester.getSize(panel).height;
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required int assessments,
    required int candidates,
  }) async {
    tester.view.physicalSize = const Size(1600, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      mount(
        DashboardScreen(
          store: storeWith(
            assessments: assessments,
            candidates: candidates,
          ),
        ),
        AssessmentNav(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expectMatched(
    WidgetTester tester, {
    required int assessments,
    required int candidates,
  }) async {
    await pump(tester, assessments: assessments, candidates: candidates);
    final double perf = panelHeight(tester, 'Performance by Assessment');
    final double board = panelHeight(tester, 'Leaderboard');
    expect(
      perf,
      board,
      reason:
          'with $assessments assessments and $candidates candidates the two '
          'cards are $perf and $board tall; they are read side by side',
    );
  }

  testWidgets('a full page in both', (WidgetTester tester) async {
    await expectMatched(tester, assessments: 10, candidates: 10);
  });

  testWidgets('a full page against a short list', (WidgetTester tester) async {
    // The reported case: 10 assessments beside 7 candidates.
    await expectMatched(tester, assessments: 10, candidates: 7);
  });

  testWidgets('a short list against a full page', (WidgetTester tester) async {
    await expectMatched(tester, assessments: 3, candidates: 10);
  });

  testWidgets('both empty', (WidgetTester tester) async {
    await expectMatched(tester, assessments: 0, candidates: 0);
  });
}
