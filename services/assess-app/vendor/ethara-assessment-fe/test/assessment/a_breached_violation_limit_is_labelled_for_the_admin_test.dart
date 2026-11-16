// An attempt that reached its violation limit is labelled for the admin, in
// BOTH modes (A-074). Log only never ends the paper, so the label is the only
// sign the cap was passed; Auto-submit ends it there, and the label says why.
// It follows the SAME rule the candidate's notice does (L4): the server's
// `violation_limit_breached`, or the count at the limit.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Future<void> open(
  WidgetTester t, {
  required bool breached,
  int count = 6,
  String action = 'log_only',
  Map<String, dynamic> extra = const <String, dynamic>{},
}) async {
  t.view.physicalSize = const Size(1440, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  final AppStore s = AppStore()
    ..people = <Person>[
      const Person(id: 'p1', name: 'Anita Rao', email: 'anita@example.com'),
    ]
    ..assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': 'a1',
        'name': 'Log Only Paper',
        'state': 'in_progress',
        'violation_action': action,
        'max_violations': 5,
      }),
    ]
    ..attempts = <Attempt>[
      Attempt.fromJson(<String, dynamic>{
        'id': '80',
        'assessment_id': 'a1',
        'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita Rao'},
        'state': 'in_progress',
        'violation_count': count,
        'violation_limit_breached': breached,
        ...extra,
      }),
    ];

  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: AttemptDetailScreen(
            store: s,
            portal: Portal.admin,
            attemptId: '80',
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('the flag shows the label, with the count against the cap', (
    WidgetTester t,
  ) async {
    await open(t, breached: true);
    expect(find.text('Violation Limit Breached - 6 / 5'), findsOneWidget);
  });

  testWidgets('the count at the cap shows it without the flag (L4)', (
    WidgetTester t,
  ) async {
    // What the candidate was already told on their own screen.
    await open(t, breached: false, count: 5);
    expect(find.text('Violation Limit Breached - 5 / 5'), findsOneWidget);
  });

  testWidgets('under the cap and no flag, no label', (WidgetTester t) async {
    await open(t, breached: false, count: 4);
    expect(find.textContaining('Violation Limit Breached'), findsNothing);
  });

  testWidgets('Auto-submit at the cap shows it beside the auto-submit', (
    WidgetTester t,
  ) async {
    await open(
      t,
      breached: false,
      count: 5,
      action: 'auto_submit',
      extra: <String, dynamic>{
        'state': 'submitted',
        'auto_submit_reason': 'violation',
      },
    );
    expect(find.text('Violation Limit Breached - 5 / 5'), findsOneWidget);
    // Next to the existing "Auto-submitted: Violations" KPI, not instead.
    expect(find.text('AUTO-SUBMITTED'), findsOneWidget);
    expect(find.text('Violations'), findsOneWidget);
  });

  test('one rule: the limit reached in either mode - or the flag', () {
    Assessment paper(String action, int cap) =>
        Assessment.fromJson(<String, dynamic>{
          'id': 'a1',
          'violation_action': action,
          'max_violations': cap,
        });
    Attempt sitting(int count, {bool flag = false}) =>
        Attempt.fromJson(<String, dynamic>{
          'id': '80',
          'assessment_id': 'a1',
          'violation_count': count,
          'violation_limit_breached': flag,
        });

    expect(sitting(5).limitBreached(paper('log_only', 5)), isTrue);
    expect(sitting(4).limitBreached(paper('log_only', 5)), isFalse);
    // Auto-submit ends the paper at the cap AND carries the label.
    expect(sitting(5).limitBreached(paper('auto_submit', 5)), isTrue);
    expect(sitting(4).limitBreached(paper('auto_submit', 5)), isFalse);
    // Auto-submit with no cap: the first violation is the limit.
    expect(sitting(1).limitBreached(paper('auto_submit', 0)), isTrue);
    expect(sitting(0).limitBreached(paper('auto_submit', 0)), isFalse);
    // Log only with no cap: nothing to breach, ever.
    expect(sitting(9).limitBreached(paper('log_only', 0)), isFalse);
    // The owner's case: Log only, cap 20 - labelled, never ended.
    expect(sitting(20).limitBreached(paper('log_only', 20)), isTrue);
    // Without the paper there is no cap to test: the flag alone.
    expect(sitting(9).limitBreached(null), isFalse);
    expect(sitting(1, flag: true).limitBreached(null), isTrue);
  });
}
