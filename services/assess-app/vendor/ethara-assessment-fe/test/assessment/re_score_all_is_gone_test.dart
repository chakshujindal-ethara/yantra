// "Re-score All" is gone from the Assessments list and the Responses screen.
//
// IT NEVER WORKED. Both copies called `rescore(null)`, which asked
// `/scoring/queue` for no assessment and no candidates - a request the route
// refuses with `missing_target` every time. So the button offered on the
// "held on pending" notice answered every press with an error. Recovery is
// per paper now: "Re-score This Assessment" resets and queues its errors, and
// Responses keeps "Reset & re-score errored".
//
// The NOTICE stays on both screens: how many papers or answers are stuck is
// still what an operator needs to know. Only the dead button goes.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_list_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/responses_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// A seed store holding one paper held on a terminal grader error, run by
/// somebody who holds every capability - so the button's absence cannot be a
/// permission gate.
AppStore _held() {
  final AppStore s = AppStore();
  s.caps = Capability.values.toSet();
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 'A-1',
      'name': 'Warehouse Safety',
      'state': 'in_progress',
      'questions': <dynamic>[
        <String, dynamic>{
          'id': 'q1',
          'name': 'Explain the defect',
          'question_type': 'subjective_rubric',
        },
      ],
    }),
  ];
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': 'E-1',
      'assessment_id': 'A-1',
      'candidate': <String, dynamic>{'id': 'P-1', 'name': 'Asha'},
      'state': 'submitted',
      'answers': <dynamic>[
        <String, dynamic>{
          'question_id': 'q1',
          'needs_llm': true,
          'llm_state': 'error',
          'justification': 'The hands have six fingers.',
        },
      ],
    }),
  ];
  return s;
}

Future<void> _open(WidgetTester t, Widget screen) async {
  t.view.physicalSize = const Size(1800, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: AssessmentNavScope(
        nav: AssessmentNav(),
        child: Scaffold(body: SingleChildScrollView(child: screen)),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('the Assessments list keeps the notice and drops the button', (
    WidgetTester t,
  ) async {
    await _open(t, AssessmentListScreen(store: _held(), portal: Portal.admin));

    expect(
      find.textContaining('assessment(s) are held on pending'),
      findsOneWidget,
      reason: 'how many papers are stuck is still worth saying',
    );
    expect(find.text('Re-score All'), findsNothing);
  });

  testWidgets('the Responses screen keeps its notice and its real recovery', (
    WidgetTester t,
  ) async {
    await _open(t, ResponsesScreen(store: _held()));

    expect(find.textContaining('hit a terminal grader error'), findsOneWidget);
    expect(find.text('Re-score All'), findsNothing);
    expect(
      find.text('Reset & re-score errored (1)'),
      findsOneWidget,
      reason: 'the errored answers keep a button that works',
    );
  });
}
