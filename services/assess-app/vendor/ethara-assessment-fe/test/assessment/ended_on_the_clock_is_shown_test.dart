// Owner Q12, the candidate's after-screens: a sitting the deadline ended says
// "Ended on the clock", and every submitted sitting says "Time used: X of Y
// min" - on the completion screen, the answer review, My Assessments and My
// Performance.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/category_scores.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/screens/member/my_assessments_screen.dart';
import 'package:ethara_assessment/assessment/screens/member/my_performance_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

const String kToken = 'tok-clock';

/// One `/api/v1/me/assessments` row. Settled by the cron two minutes after a
/// 45-minute deadline, so the raw span is 47 min.
Map<String, dynamic> _row({
  String reason = 'expired',
  String submitted = '2026-08-11T10:47:00Z',
  bool released = false,
}) => <String, dynamic>{
  'id': 'EV-1',
  'token': kToken,
  'assessment_id': 'A-1',
  'name': 'Warehouse Safety',
  'state': 'completed',
  'is_locked': true,
  'started_at': '2026-08-11T10:00:00Z',
  'submitted_at': submitted,
  'duration_minutes': 45,
  'progress': <String, dynamic>{'answered': 3, 'total': 3, 'percent': 100},
  'auto_submitted': reason.isNotEmpty,
  'auto_submit_reason': reason,
  'result': <String, dynamic>{
    'released': released,
    if (released) 'score_marks': '2 / 3',
    if (released) 'result': 'pass',
  },
};

AppStore _store(Map<String, dynamic> row, {bool withAsm = false}) {
  final AppStore s = AppStore();
  s.meId = '2';
  s.assessments = <Assessment>[
    if (withAsm)
      Assessment(
        id: 'A-1',
        name: 'Warehouse Safety',
        state: AsmState.done,
        durationMinutes: 45,
      ),
  ];
  s.attempts = <Attempt>[Attempt.fromJson(row)];
  return s;
}

Future<void> _open(WidgetTester t, Widget screen) async {
  t.view.physicalSize = const Size(1600, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(nav: AssessmentNav(), child: screen),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  group('timeUsed', () {
    test('caps a late-settled expiry at the limit', () {
      expect(timeUsed(Attempt.fromJson(_row()), null), '45 of 45 min');
    });

    test('reads the real span under the limit', () {
      final Attempt a = Attempt.fromJson(
        _row(reason: '', submitted: '2026-08-11T10:38:40Z'),
      );
      expect(timeUsed(a, null), '38 of 45 min');
    });

    test('falls back to the paper, then to no limit', () {
      final Attempt a = Attempt(
        id: '1',
        assessmentId: 'A-1',
        employeeId: '',
        token: 't',
        startedAt: DateTime.utc(2026, 8, 11, 10),
        submittedAt: DateTime.utc(2026, 8, 11, 10, 0, 20),
      );
      expect(
        timeUsed(a, Assessment(id: 'A-1', name: 'x', durationMinutes: 30)),
        '<1 of 30 min',
      );
      expect(
        timeUsed(a, Assessment(id: 'A-1', name: 'x', durationMinutes: 0)),
        '<1 min',
      );
    });

    test('an unfinished sitting has no time used', () {
      expect(
        timeUsed(Attempt.fromJson(_row()..remove('submitted_at')), null),
        isNull,
      );
    });
  });

  testWidgets('completion screen: ended on the clock, time used', (
    WidgetTester t,
  ) async {
    final AppStore s = _store(_row(), withAsm: true);
    await _open(t, ExamScreen(store: s, token: kToken, sub: ExamSub.complete));

    expect(
      find.textContaining('Ended on the clock.', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Time used: 45 of 45 min'), findsOneWidget);
    expect(find.textContaining('violation', findRichText: true), findsNothing);
  });

  testWidgets('completion screen: a candidate submit says no clock line', (
    WidgetTester t,
  ) async {
    final AppStore s = _store(
      _row(reason: '', submitted: '2026-08-11T10:38:00Z'),
      withAsm: true,
    );
    await _open(t, ExamScreen(store: s, token: kToken, sub: ExamSub.complete));

    expect(
      find.textContaining('Ended on the clock', findRichText: true),
      findsNothing,
    );
    expect(find.text('Time used: 38 of 45 min'), findsOneWidget);
  });

  testWidgets('answer review (result): time used KPI names the clock', (
    WidgetTester t,
  ) async {
    final AppStore s = _store(_row(released: true), withAsm: true);
    await _open(t, ExamScreen(store: s, token: kToken, sub: ExamSub.answers));

    expect(find.text('TIME USED'), findsOneWidget);
    expect(find.text('45 of 45 min'), findsOneWidget);
    expect(find.text('Ended on the clock'), findsOneWidget);
  });

  testWidgets('My Assessments card', (WidgetTester t) async {
    await _open(t, MyAssessmentsScreen(store: _store(_row())));

    expect(
      find.text('Ended on the clock. Time used: 45 of 45 min.'),
      findsOneWidget,
    );
  });

  testWidgets('My Performance time panel', (WidgetTester t) async {
    await _open(t, MyPerformanceScreen(store: _store(_row())));

    expect(find.text('Ended on the clock'), findsOneWidget);
    expect(find.text('45 of 45 min'), findsOneWidget);
  });
}
