// A candidate's own card lists the WHOLE violation tally, not just the last one.
//
// THE BUG THIS EXISTS FOR, on the one screen a candidate can actually see. The
// card under "My Assessments" printed its proctoring line off
// `violation_reason` - the single most recent event - so a candidate who
// breached three different rules was shown one of them and told nothing about
// the other two. The tally was already on the wire: the candidate route nests
// it under `proctoring.violations` (serializers.attempt), beside
// `violation_count` and `violation_reason`.
//
// Two things had to line up, and both are pinned here:
//   1. `Attempt.fromJson` reads the tally out of the `proctoring` group - the
//      admin roster nests it under `flags`, but a candidate's own row groups it
//      under `proctoring`, and only that spelling reaches this screen;
//   2. the card lists every reason with its `(xN)` count, falling back to
//      'Last reason: X.' ONLY when the tally is empty - which is the honest
//      answer for an attempt recorded before the log existed.
//
// The `flags` spelling and `proctoringViolationNotice` itself are pinned by
// `violation_tally_is_not_dropped_test`; this file pins the CANDIDATE surface -
// the parse off `proctoring`, and what the card renders from it.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/member/my_assessments_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// A candidate's own attempt row, as `serializers.attempt` sends it: the
/// proctoring tally nested under `proctoring`, and NO top-level `violations`
/// key - the shape that made the old top-level read parse empty.
Map<String, dynamic> _attempt({required bool withTally}) => <String, dynamic>{
  'id': 'EV-1',
  'assessment_id': 'A-1',
  'name': 'Warehouse Safety',
  'state': 'completed',
  'started_at': '2026-08-11T10:00:00Z',
  'submitted_at': '2026-08-11T10:30:00Z',
  'is_locked': true,
  'results_released': true,
  'progress': <String, dynamic>{'answered': 3, 'total': 3, 'percent': 100},
  'duration_minutes': 45,
  'proctoring': <String, dynamic>{
    'violation_count': 3,
    'violation_reason': 'paste',
    if (withTally)
      'violations': <Map<String, dynamic>>[
        <String, dynamic>{'reason': 'paste', 'count': 1},
        <String, dynamic>{'reason': 'copy', 'count': 1},
        <String, dynamic>{'reason': 'Exited fullscreen', 'count': 1},
      ],
  },
};

/// A store on the candidate surface with one released, three-violation attempt.
/// `employeeId` is left empty by the payload, which is how a self-scoped
/// `/me/assessments` row arrives - `attemptsForPerson` matches it to `meId`.
AppStore _store({required bool withTally}) {
  final AppStore s = AppStore();
  s.assessments = <Assessment>[];
  s.attempts = <Attempt>[Attempt.fromJson(_attempt(withTally: withTally))];
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
  group('the tally is parsed off the candidate shape', () {
    test('proctoring.violations lands in ev.violations', () {
      final Attempt a = Attempt.fromJson(_attempt(withTally: true));

      expect(a.violationCount, 3);
      expect(
        a.violations.length,
        3,
        reason: 'the candidate row nests the tally under `proctoring`; reading '
            'only the top level parsed it empty on every real payload',
      );
      expect(a.violations.first.reason, 'paste');
      expect(a.violations.first.count, 1);
    });

    test('no tally leaves ev.violations empty but keeps the reason', () {
      final Attempt a = Attempt.fromJson(_attempt(withTally: false));
      expect(a.violations, isEmpty);
      expect(a.violationReason, 'paste');
    });
  });

  group('the card renders the tally', () {
    testWidgets('every reason is named with its count, and no "Last reason"', (
      WidgetTester t,
    ) async {
      await _open(t, _store(withTally: true));

      expect(find.textContaining('paste (x1)'), findsOneWidget);
      expect(find.textContaining('copy (x1)'), findsOneWidget);
      expect(find.textContaining('Exited fullscreen (x1)'), findsOneWidget);
      expect(
        find.textContaining('Last reason'),
        findsNothing,
        reason:
            'the fallback is only for rows with no log; this attempt has one, '
            'so listing "Last reason" would drop the other two breaches',
      );
    });

    testWidgets('with no tally the card falls back to the last reason', (
      WidgetTester t,
    ) async {
      // A row recorded before the module kept a log has no distribution to
      // show, so naming the last reason is the honest answer - and this is the
      // branch the bug wrongly took for everybody.
      await _open(t, _store(withTally: false));

      expect(
        find.textContaining('Last reason: paste.'),
        findsOneWidget,
        reason: 'the legacy fallback must survive for rows with no log',
      );
    });

    testWidgets('the AI count has its own line (R5)', (WidgetTester t) async {
      final Map<String, dynamic> row = _attempt(withTally: true);
      (row['proctoring'] as Map<String, dynamic>).addAll(<String, dynamic>{
        'ai_violation_count': 2,
        'ai_violations': <Map<String, dynamic>>[
          <String, dynamic>{'reason': 'AI: phone detected', 'count': 2},
        ],
      });
      final AppStore s = AppStore()
        ..assessments = <Assessment>[]
        ..attempts = <Attempt>[Attempt.fromJson(row)];
      await _open(t, s);

      expect(
        find.textContaining('3 proctoring violations recorded.'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          '2 AI proctoring violations recorded. AI: phone detected (x2).',
        ),
        findsOneWidget,
      );
    });
  });
}
