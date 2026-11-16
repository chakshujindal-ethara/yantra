// Candidate-facing wording found in product testing of the exam.
//
//   a. "Your answers are recorded and marked" was said while written answers
//      were still ungraded. "Marked" only where it is known to be true.
//   b. The violation consequence spoke about "Candidates" in the third person
//      to the candidate. The admin wording is pinned elsewhere, unchanged.
//   c. "1 questions".
//   d. The closed-link sentence ("may have been closed/expired and may not
//      have opened yet, or finished") is one clear sentence now.
//   e. An operator reading someone else's performance was told "your time".
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/screens/exam/gate_screen.dart';
import 'package:ethara_assessment/assessment/screens/member/my_assessments_screen.dart';
import 'package:ethara_assessment/assessment/screens/member/my_performance_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Future<void> _pump(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1600, 3200);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(nav: AssessmentNav(), child: child),
      ),
    ),
  );
  await t.pump();
}

/// One submitted, unreleased sitting of a one-question paper.
AppStore _awaiting() {
  final AppStore s = AppStore();
  final Attempt first = s.attemptsForPerson(s.meId).first;
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': 'EV-DONE-1',
      'assessment_id': first.assessmentId,
      'name': 'test assessment',
      'state': 'completed',
      'progress': <String, dynamic>{'answered': 1, 'total': 1, 'percent': 100},
      'duration_minutes': 45,
      'results_released': false,
    }),
  ];
  return s;
}

/// [who]'s sittings, seen by [viewer] (the candidate themself when equal).
AppStore _perf({
  required bool released,
  int pending = 0,
  String viewer = 'p1',
}) {
  final Assessment asm = Assessment(
    id: 'a1',
    name: 'Test 17/8',
    state: AsmState.done,
    durationMinutes: 45,
  );
  final AppStore s = AppStore();
  s.people = <Person>[
    const Person(id: 'p1', name: 'Priya Sharma', email: 'priya@example.com'),
  ];
  s.meId = viewer;
  s.assessments = <Assessment>[asm];
  s.attempts = <Attempt>[
    Attempt(
      id: 'e1',
      assessmentId: 'a1',
      employeeId: 'p1',
      token: 'e1',
      state: AttemptState.submitted,
      resultsReleased: released,
      subjectivePending: pending,
      startedAt: DateTime.parse('2026-08-17T13:00:00Z'),
      submittedAt: DateTime.parse('2026-08-17T13:31:00Z'),
    ),
  ];
  return s;
}

void main() {
  group('a. "marked" only when it is', () {
    testWidgets('the awaiting-release card does not claim marking', (
      WidgetTester t,
    ) async {
      await _pump(t, MyAssessmentsScreen(store: _awaiting()));
      expect(
        find.text(
          'Awaiting release. Your answers are recorded; your result is held '
          'until an administrator releases it.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('recorded and marked'), findsNothing);
    });

    testWidgets('the not-released gate does not claim marking', (
      WidgetTester t,
    ) async {
      await _pump(t, const GateScreen(kind: GateKind.notReleased));
      expect(
        find.textContaining(
          'Your answers are recorded, and your '
          'result is held',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('recorded and marked'), findsNothing);
    });

    testWidgets('My Performance: never to the candidate, and to an operator '
        'only when nothing is ungraded', (WidgetTester t) async {
      await _pump(t, MyPerformanceScreen(store: _perf(released: false)));
      expect(find.textContaining('Your answers are recorded.'), findsOneWidget);
      expect(find.textContaining('and marked'), findsNothing);

      await _pump(
        t,
        MyPerformanceScreen(
          store: _perf(released: false, pending: 2, viewer: 'admin'),
          personId: 'p1',
        ),
      );
      expect(find.textContaining('and marked'), findsNothing);

      await _pump(
        t,
        MyPerformanceScreen(
          store: _perf(released: false, viewer: 'admin'),
          personId: 'p1',
        ),
      );
      expect(
        find.textContaining(
          "This candidate's answers are recorded and marked.",
        ),
        findsOneWidget,
      );
    });
  });

  test('b. the candidate is spoken to; the admin text is unchanged', () {
    final String you = violationConsequence(
      ViolationAction.autoSubmit,
      2,
      candidate: true,
    ).text;
    expect(you, contains('You get 1 warned violation first.'));
    expect(you, contains('shown to you and the organiser'));
    expect(you, isNot(contains('Candidates')));
    expect(
      violationConsequence(ViolationAction.autoSubmit, 3, candidate: true).text,
      contains('You get 2 warned violations first.'),
    );
    expect(
      violationConsequence(ViolationAction.autoSubmit, 2).text,
      'Candidates get 1 warned violation(s) first. Reaching 2 also marks the '
      'attempt Violation Limit Breached for the candidate and the organiser.',
    );
  });

  testWidgets('c. one question reads in the singular', (WidgetTester t) async {
    await _pump(t, MyAssessmentsScreen(store: _awaiting()));
    expect(find.textContaining('1 question  ·  '), findsOneWidget);
    expect(find.textContaining('1 questions'), findsNothing);
  });

  testWidgets('d. a closed paper says it has closed', (WidgetTester t) async {
    await _pump(t, const GateScreen(kind: GateKind.closed));
    expect(find.text('This assessment has closed.'), findsOneWidget);
    expect(find.textContaining('not started yet'), findsNothing);
    expect(find.textContaining('closed/expired'), findsNothing);
  });

  // Owner rule: a draft is never shown to a candidate, so an old server's
  // `closed` over a draft reads as an unknown link, not "not open yet".
  testWidgets('d. a draft paper reads as a link that does not work', (
    WidgetTester t,
  ) async {
    final AppStore s = AppStore()
      ..attempts = <Attempt>[
        Attempt.fromJson(<String, dynamic>{
          'id': 7,
          'access_token': 'tok-d',
          'assessment_id': 21,
          'state': 'pending',
        }),
      ]
      ..assessments = <Assessment>[
        Assessment.fromJson(<String, dynamic>{
          'id': 21,
          'name': 'Draft Paper',
          'state': 'draft',
        }),
      ];
    s.examByToken['tok-d'] = ExamView.fromJson(<String, dynamic>{
      'outcome': 'closed',
    });
    await _pump(t, ExamScreen(store: s, token: 'tok-d'));
    expect(find.text('This link does not work'), findsOneWidget);
    expect(find.textContaining('not open yet'), findsNothing);
    expect(find.text('This assessment is closed'), findsNothing);
  });

  testWidgets('e. an operator is not told "your time"', (WidgetTester t) async {
    await _pump(
      t,
      MyPerformanceScreen(
        store: _perf(released: true, viewer: 'admin'),
        personId: 'p1',
      ),
    );
    expect(find.text('Time Taken'), findsWidgets);
    expect(find.textContaining('time is never scored'), findsWidgets);
    expect(find.textContaining('your time'), findsNothing);

    await _pump(t, MyPerformanceScreen(store: _perf(released: true)));
    expect(find.textContaining('your time is never scored'), findsWidgets);
  });
}
