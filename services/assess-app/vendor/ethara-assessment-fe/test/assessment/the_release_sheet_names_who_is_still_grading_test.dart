// The Release Results sheet names each candidate still being graded, with how
// many answers are unresolved: the server's count on a roster row, which
// carries no answers to walk.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

void main() {
  testWidgets('a candidate with two answers out is named, with the count', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1800, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final AppStore s = AppStore()
      ..people = <Person>[
        const Person(id: 'p1', name: 'Asha', email: 'a@x.io'),
        const Person(id: 'p2', name: 'Ravi', email: 'r@x.io'),
      ]
      ..assessments = <Assessment>[
        Assessment(id: 'A-1', name: 'Paper one', state: AsmState.done),
      ]
      ..attempts = <Attempt>[
        const Attempt(
          id: 'E-1',
          assessmentId: 'A-1',
          employeeId: 'p1',
          token: 'tok-1',
          state: AttemptState.submitted,
          isLocked: true,
        ),
        const Attempt(
          id: 'E-2',
          assessmentId: 'A-1',
          employeeId: 'p2',
          token: 'tok-2',
          state: AttemptState.submitted,
          isLocked: true,
          subjectivePending: 2,
        ),
      ];
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        // The test font draws every glyph a full em wide, so the sheet's
        // buttons would overflow its 640px; real text fits.
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(0.7)),
          child: child!,
        ),
        home: Scaffold(
          body: AssessmentNavScope(
            nav: AssessmentNav(),
            child: AssessmentDetailScreen(
              store: s,
              portal: Portal.admin,
              asmId: 'A-1',
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    // EVERYONE THE RELEASE WRITES: Asha (scored) and Ravi (still grading).
    // The scored count alone said 1 and the release went out to 2.
    await t.tap(find.text('Release results (2)'));
    await t.pumpAndSettle();
    expect(find.text('Release Results'), findsOneWidget);
    expect(find.text('Ravi'), findsWidgets);
    expect(find.text('2 unresolved'), findsOneWidget);
    expect(find.text('Release 2 (1 still being graded)'), findsOneWidget);
  });
}
