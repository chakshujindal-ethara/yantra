// Every time the console prints is India time, and says so.
//
// Two screens formatted their own times - `d/m/y HH:mm` straight off the
// parsed DateTime, i.e. in the BROWSER's zone with no zone named - after the
// rest of the app had moved to `istTimestamp`: the attempt page (Started,
// Submitted, Deadline) and the spend ledger's "When". An operator comparing
// "Submitted 13/8/2026 06:11" on one page with "11:41 AM" on the next could
// not tell they were the same moment. Both now go through the one helper that
// carries the "IST" label.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/ledger_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Widget mount(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: AssessmentNavScope(nav: AssessmentNav(), child: child),
  ),
);

void main() {
  void desktop(WidgetTester t) {
    t.view.physicalSize = const Size(1800, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
  }

  testWidgets('the attempt page names Started and Submitted in IST', (
    WidgetTester t,
  ) async {
    desktop(t);
    final AppStore s = AppStore();
    s.people = <Person>[
      const Person(id: 'p1', name: 'Anita Rao', email: 'anita@example.com'),
    ];
    s.assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': 'a1',
        'name': 'ETP Assessment Pro',
        'state': 'done',
      }),
    ];
    s.attempts = <Attempt>[
      Attempt.fromJson(<String, dynamic>{
        'id': '80',
        'assessment_id': 'a1',
        'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita Rao'},
        'state': 'submitted',
        'is_locked': true,
        // The wire's shape: UTC with a `Z` (`serializers.iso`).
        'started_at': '2026-08-13T06:04:00Z',
        'submitted_at': '2026-08-13T06:11:00Z',
      }),
    ];
    await t.pumpWidget(
      mount(
        AttemptDetailScreen(store: s, portal: Portal.admin, attemptId: '80'),
      ),
    );
    await t.pumpAndSettle();

    expect(find.textContaining('11:34 AM IST'), findsOneWidget);
    expect(find.textContaining('11:41 AM IST'), findsOneWidget);
  });

  testWidgets('a ledger call says when it ran, in IST', (WidgetTester t) async {
    desktop(t);
    final AppStore s = AppStore();
    s.ledger = <LedgerRow>[
      LedgerRow(
        id: '1',
        op: LedgerOp.generateQuestions,
        model: 'gemini-3.1-pro-preview',
        at: DateTime.utc(2026, 8, 13, 4, 33),
      ),
    ];
    await t.pumpWidget(mount(LedgerScreen(store: s)));
    await t.pumpAndSettle();

    await t.tap(find.text(LedgerOp.generateQuestions.label).first);
    await t.pumpAndSettle();

    expect(find.textContaining('10:03 AM IST'), findsOneWidget);
  });
}
