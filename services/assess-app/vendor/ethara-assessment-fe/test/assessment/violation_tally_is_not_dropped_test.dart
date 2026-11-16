// The proctoring tally is nested under `flags`, and must survive the parse.
//
// THE BUG THIS EXISTS FOR. The attempt screen printed
//
//     9 proctoring violations recorded. Last reason: Clipboard action: paste.
//
// on an attempt whose log held three distinct reasons. Everything needed to say
// so was already built and already on the wire: `violation_tally` aggregates the
// log, `evaluator_admin_row` serialises it, and `proctoringViolationNotice`
// renders it. `Attempt.fromJson` read a TOP-LEVEL `violations` key while the
// module nests it inside `flags`, beside `integrity_alert` and `score_outlier` -
// so it parsed empty on every real payload and the notice fell through to its
// legacy "last reason" branch, which exists only for rows recorded before the
// log did.
//
// Measured against production `/api/v1/attempts/188`:
//
//     flags.violations = [
//       {"reason": "Clipboard action: paste", "count": 6},
//       {"reason": "Clipboard action: copy",  "count": 2},
//       {"reason": "Exited fullscreen",       "count": 1}]
//     top-level "violations": absent
//
// That payload is the fixture below.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';

/// `evaluator_admin_row` for production attempt 188, trimmed to the keys this
/// notice reads. The tally is nested exactly as the module sends it.
Map<String, dynamic> attempt188({bool withTally = true}) => <String, dynamic>{
  'id': 188,
  'assessment_id': 1133,
  'state': 'submitted',
  'flags': <String, dynamic>{
    'is_violated': true,
    'violation_count': 9,
    'violation_reason': 'Clipboard action: paste',
    if (withTally)
      'violations': <Map<String, dynamic>>[
        <String, dynamic>{'reason': 'Clipboard action: paste', 'count': 6},
        <String, dynamic>{'reason': 'Clipboard action: copy', 'count': 2},
        <String, dynamic>{'reason': 'Exited fullscreen', 'count': 1},
      ],
  },
};

void main() {
  group('The tally arrives', () {
    test('the nested `flags.violations` is parsed', () {
      final Attempt a = Attempt.fromJson(attempt188());

      expect(a.violationCount, 9);
      expect(a.violations.length, 3);
      expect(a.violations.first.reason, 'Clipboard action: paste');
      expect(a.violations.first.count, 6);
    });

    test('every reason is named, not just the last one', () {
      final Attempt a = Attempt.fromJson(attempt188());
      final ({String strong, String text}) notice = proctoringViolationNotice(
        count: a.violationCount,
        violations: a.violations,
        violationReason: a.violationReason,
        autoSubmitReason: a.autoSubmitReason,
        maxViolations: 0,
      );

      expect(notice.strong, '9 proctoring violations recorded.');
      expect(
        notice.text,
        contains('Clipboard action: paste (x6)'),
        reason: 'the reported banner named this one and nothing else',
      );
      expect(notice.text, contains('Clipboard action: copy (x2)'));
      expect(notice.text, contains('Exited fullscreen (x1)'));
      expect(
        notice.text,
        isNot(contains('Last reason')),
        reason:
            'the legacy fallback is for rows with no log; this attempt has one',
      );
    });
  });

  // `toJson` is what the device cache keeps. The AI tally is its own list
  // (R5); dropping it there would lose the per-reason breakdown on reload.
  test('the AI tally survives the device cache round trip', () {
    final Attempt a = Attempt.fromJson(<String, dynamic>{
      ...attempt188(),
      'ai_violation_count': 3,
      'ai_violations': <Map<String, dynamic>>[
        <String, dynamic>{'reason': 'AI: phone detected', 'count': 2},
        <String, dynamic>{'reason': 'AI: no face for 5s', 'count': 1},
      ],
    });
    expect(a.aiViolations, hasLength(2));

    final Attempt back = Attempt.fromJson(a.toJson());
    expect(back.aiViolations, <({String reason, int count})>[
      (reason: 'AI: phone detected', count: 2),
      (reason: 'AI: no face for 5s', count: 1),
    ]);
    expect(back.aiViolationCount, 3);
    // And the regular tally stays apart.
    expect(back.violations, hasLength(3));
  });

  group('The legacy fallback is untouched', () {
    test('an attempt with no log still reads sensibly', () {
      // A row recorded before the module kept a log. There is no distribution
      // to show, so naming the last reason is the honest answer - and this is
      // the branch the bug was wrongly taking for everybody.
      final Attempt a = Attempt.fromJson(attempt188(withTally: false));

      expect(a.violations, isEmpty);
      final ({String strong, String text}) notice = proctoringViolationNotice(
        count: a.violationCount,
        violations: a.violations,
        violationReason: a.violationReason,
        autoSubmitReason: a.autoSubmitReason,
        maxViolations: 0,
      );

      expect(notice.text, contains('Last reason: Clipboard action: paste.'));
    });
  });
}
