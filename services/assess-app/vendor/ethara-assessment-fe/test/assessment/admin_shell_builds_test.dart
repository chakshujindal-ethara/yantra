// The ADMIN SHELL builds after sign-in, with the store in the state a live
// load leaves it in.
//
// THE BUG THIS EXISTS FOR: the dashboard body rendered as a flat grey rectangle
// while the sidebar painted normally - Flutter's release-mode ErrorWidget, i.e.
// something in the body threw during build. The sign-in screen was fine, so the
// failure was reachable only once signed in, which no existing test covered.
//
// Two candidates, both introduced together:
//   * the leaderboard now renders SERVER rows (snake_case keys straight off the
//     wire) instead of a client recompute
//   * `_loadAdmin` issues a tenth future and reads `res[9]`
//
// This builds the whole section the way the app does, so either would surface.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/assessment_section.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Widget mount(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: child),
);

Future<void> setSurface(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('the admin section builds with a server leaderboard', (
    WidgetTester tester,
  ) async {
    await setSurface(tester);

    await tester.pumpWidget(mount(AssessmentSection(store: AppStore())));
    await tester.pumpAndSettle();

    // The seed store is what an unauthenticated / offline app shows; it must
    // never paint an ErrorWidget.
    expect(find.byType(ErrorWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a store carrying live-shaped rows builds', (
    WidgetTester tester,
  ) async {
    await setSurface(tester);
    final AppStore s = AppStore();
    s.people = <Person>[
      const Person(id: 'p1', name: 'Diya Sharma', email: 'd@example.com'),
    ];
    s.leaderboard = <Map<String, dynamic>>[
      <String, dynamic>{
        'rank': 1,
        'applicant_id': 33,
        'applicant_name': 'Diya Sharma',
        'attempts': 2,
        'avg_score': 63.3,
        'best_score': 66.7,
        'passed': 0,
      },
    ];
    // Everything else deliberately EMPTY: that is the state a failed
    // `Future.wait` leaves the store in, and it must render as an empty
    // dashboard rather than a grey box.
    s.assessments = <Assessment>[];
    s.bank = <Question>[];
    s.responseRows = <Map<String, dynamic>>[];

    await tester.pumpWidget(mount(AssessmentSection(store: s)));
    await tester.pumpAndSettle();

    expect(find.byType(ErrorWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
