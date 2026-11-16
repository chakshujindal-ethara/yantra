// What the violation settings PROMISE has to match what they do.
//
// The rule: `violationAction` decides WHETHER proctoring may end a sitting,
// the cap decides WHEN. Log only never ends one, whatever the cap says - the
// operator picked the option whose whole promise is "record it, do not act on
// it", and a limit under it is a tally they read afterwards.
//
// Both directions of this have been wrong in the past, and both are pinned
// below. Promising "never ended automatically" and then ending it at 20 costs
// a candidate their paper AND the grounds to argue. Promising an auto-submit
// that never comes is milder but still a lie on the instructions page.
//
// The sentence is derived once by `violationConsequence`, read by the exam
// instructions, the assessment detail and the new-assessment form, so no
// surface gets to have its own opinion.
library;

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('violationConsequence', () {
    test('a cap set under Log only still says the exam never ends', () {
      final ({String strong, String text}) c = violationConsequence(
        ViolationAction.logOnly,
        20,
      );

      expect(c.strong, contains('never ended automatically'));
      expect(
        c.text,
        contains('20'),
        reason: 'the cap is still named - it is the tally the operator reads',
      );
      expect(
        c.text,
        contains('marks the attempt Violation Limit Breached'),
        reason: 'and says what reaching it does instead of ending the exam',
      );
    });

    test('the limit is labelled in BOTH modes, and ends only Auto-submit', () {
      for (final int cap in <int>[0, 1, 5]) {
        expect(
          violationConsequence(ViolationAction.autoSubmit, cap).text,
          contains('Violation Limit Breached'),
          reason: 'cap=$cap - Auto-submit also marks the attempt',
        );
      }
      expect(
        violationConsequence(ViolationAction.logOnly, 5).text,
        contains('only Auto-submit ends the exam'),
      );
      // Log only with no cap has no limit to breach.
      expect(
        violationConsequence(ViolationAction.logOnly, 0).text,
        isNot(contains('Violation Limit Breached')),
      );
    });

    test(
      'a cap of 1 ends it on the first violation ONLY under auto-submit',
      () {
        expect(
          violationConsequence(ViolationAction.autoSubmit, 1).text,
          contains('first violation ends the exam'),
        );
        expect(
          violationConsequence(ViolationAction.logOnly, 1).strong,
          contains('never ended automatically'),
        );
      },
    );

    test('no cap under Auto-submit ends on the first violation', () {
      final ({String strong, String text}) c = violationConsequence(
        ViolationAction.autoSubmit,
        0,
      );

      expect(c.strong, contains('first violation'));
      expect(
        c.strong,
        isNot(contains('violation 0')),
        reason: 'a cap of 0 means "end on the first one", not "a limit of 0"',
      );
    });

    test('no cap under Log only never ends either', () {
      final ({String strong, String text}) c = violationConsequence(
        ViolationAction.logOnly,
        0,
      );

      expect(c.strong, contains('never ended automatically'));
      expect(c.text, contains('recorded'));
    });

    test('LOG ONLY never promises an ending, at any cap', () {
      for (final int cap in <int>[0, 1, 2, 20]) {
        expect(
          violationConsequence(ViolationAction.logOnly, cap).strong,
          contains('never'),
          reason: 'cap=$cap - log only does not act, so it must not promise to',
        );
      }
    });

    test('AUTO-SUBMIT always promises an ending, at any cap', () {
      for (final int cap in <int>[0, 1, 2, 20]) {
        expect(
          violationConsequence(ViolationAction.autoSubmit, cap).strong,
          isNot(contains('never')),
          reason: 'cap=$cap - an auto action always ends the sitting somewhere',
        );
      }
    });
  });

  // The attempt-screen Notice, derived once so it can be pinned without
  // pumping the whole screen.
  group('proctoringViolationNotice', () {
    test('prints the full per-reason tally in the exact requested shape', () {
      final ({String strong, String text}) n = proctoringViolationNotice(
        count: 6,
        violations: const <({String reason, int count})>[
          (reason: 'Right-click attempted', count: 3),
          (reason: 'Tab switched/window hidden', count: 2),
          (reason: 'Clipboard action: copy', count: 1),
        ],
        violationReason: 'Clipboard action: copy',
        autoSubmitReason: '',
        maxViolations: 0,
      );

      expect(n.strong, '6 proctoring violations recorded.');
      // EXACTLY what the user asked for.
      expect(
        n.text,
        'Right-click attempted (x3), Tab switched/window hidden (x2), '
        'Clipboard action: copy (x1).',
      );
    });

    test('the singular form drops the "(s)"', () {
      final ({String strong, String text}) n = proctoringViolationNotice(
        count: 1,
        violations: const <({String reason, int count})>[
          (reason: 'Right-click attempted', count: 1),
        ],
        violationReason: 'Right-click attempted',
        autoSubmitReason: '',
        maxViolations: 3,
      );
      expect(n.strong, '1 proctoring violation recorded.');
      expect(n.strong, isNot(contains('(s)')));
    });

    test('an empty log falls back to the last-reason line', () {
      // A legacy attempt recorded before the server kept a per-reason log.
      final ({String strong, String text}) n = proctoringViolationNotice(
        count: 4,
        violations: const <({String reason, int count})>[],
        violationReason: 'Exited fullscreen',
        autoSubmitReason: '',
        maxViolations: 3,
      );
      expect(n.strong, '4 proctoring violations recorded.');
      expect(n.text, 'Last reason: Exited fullscreen.');
    });

    test('the auto-submit clause is appended after the tally, unchanged', () {
      final ({String strong, String text}) n = proctoringViolationNotice(
        count: 3,
        violations: const <({String reason, int count})>[
          (reason: 'Tab switched/window hidden', count: 3),
        ],
        violationReason: 'Tab switched/window hidden',
        autoSubmitReason: 'violation',
        maxViolations: 3,
      );
      expect(n.text, startsWith('Tab switched/window hidden (x3).'));
      expect(n.text, contains('auto-submitted on reaching the limit of 3'));
    });

    test('a time expiry is not blamed on the violations', () {
      final ({String strong, String text}) n = proctoringViolationNotice(
        count: 2,
        violations: const <({String reason, int count})>[
          (reason: 'Right-click attempted', count: 2),
        ],
        violationReason: 'Right-click attempted',
        autoSubmitReason: 'expired',
        maxViolations: 3,
      );
      expect(n.text, contains('when the time ran out, not by these'));
    });
  });
}
