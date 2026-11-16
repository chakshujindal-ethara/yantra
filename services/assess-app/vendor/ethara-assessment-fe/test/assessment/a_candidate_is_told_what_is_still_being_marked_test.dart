// "Pending" over a real number, with nothing to say why.
//
// THE BUG. `candidate_result` puts the count of unmarked written answers at
// `result.subjective_pending`; `Attempt.fromJson` read `subjective['pending']`
// - the ADMIN roster's shape. A candidate payload carries no `subjective`
// object at all, so `subjectivePending` was 0 on every candidate surface and
// the card showed a grey "Pending" pill over "3 / 10" with no explanation. A
// candidate reads that as a fail; in fact four written answers are unmarked
// and the total can only rise.
//
// Two halves, both pinned here: the parse off the CANDIDATE shape, and the
// sentence the card says once it has the number.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/member/my_assessments_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// One row of `/api/v1/me/assessments`, as `serializers.attempt` sends it:
/// the pending count nested inside `result`, and NO `subjective` object.
Map<String, dynamic> _attempt({int pending = 4}) => <String, dynamic>{
  'id': 'EV-1',
  'assessment_id': 'A-1',
  'name': 'Warehouse Safety',
  'state': 'completed',
  'started_at': '2026-08-11T10:00:00Z',
  'submitted_at': '2026-08-11T10:30:00Z',
  'is_locked': true,
  'results_released': true,
  'progress': <String, dynamic>{'answered': 10, 'total': 10, 'percent': 100},
  'duration_minutes': 45,
  'result': <String, dynamic>{
    'released': true,
    'status': 'released',
    'score_marks': '3 / 10',
    'result': 'pending',
    'pass_threshold': 60.0,
    'is_pending': true,
    'subjective_pending': pending,
  },
};

AppStore _store({int pending = 4}) {
  final AppStore s = AppStore();
  s.assessments = <Assessment>[];
  s.attempts = <Attempt>[Attempt.fromJson(_attempt(pending: pending))];
  return s;
}

Future<void> _open(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1600, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: MyAssessmentsScreen(store: s),
        ),
      ),
    ),
  );
  await t.pump();
}

void main() {
  test('result.subjective_pending is what a candidate payload carries', () {
    expect(
      Attempt.fromJson(_attempt()).subjectivePending,
      4,
      reason:
          'the candidate route nests the count under `result`; reading only '
          'the admin `subjective` object parsed 0 on every candidate payload',
    );
    expect(Attempt.fromJson(_attempt(pending: 0)).subjectivePending, 0);
  });

  test('the admin roster shape still wins where it is sent', () {
    final Attempt a = Attempt.fromJson(<String, dynamic>{
      'id': 'EV-2',
      'assessment_id': 'A-1',
      'subjective': <String, dynamic>{'pending': 2},
      'result': <String, dynamic>{'subjective_pending': 9},
    });
    expect(a.subjectivePending, 2);
  });

  testWidgets('the card says the total may still rise', (WidgetTester t) async {
    await _open(t, _store());

    // R8-07: "not marked yet", which stays true for an errored answer.
    expect(
      find.text(
        '4 written answers have not been marked yet - your total may rise '
        'when they are.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('still being marked'), findsNothing);
  });

  testWidgets('a fully marked sitting says nothing of the sort', (
    WidgetTester t,
  ) async {
    await _open(t, _store(pending: 0));
    expect(find.textContaining('not been marked yet'), findsNothing);
  });

  test('one answer reads in the singular', () {
    expect(
      Attempt.fromJson(_attempt(pending: 1)).pendingMarkingNote,
      '1 written answer has not been marked yet - your total may rise when '
      'it is.',
    );
  });
}
