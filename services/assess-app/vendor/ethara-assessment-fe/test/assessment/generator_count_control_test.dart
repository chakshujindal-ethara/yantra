/// "Questions to generate" is typeable, like the field beside it.
///
/// THE DEFECT. The count was a printed number with a `-` and a `+` either
/// side, so asking for thirty questions cost twenty-two clicks and nothing on
/// screen suggested the number could be edited at all - while "Image labelling
/// count", the field directly next to it, was a real text box the whole time.
/// Two controls answering the same shape of question, behaving differently.
library;

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _coverageFloorTests();
  group('Setting the count keeps the control honest while it saves', () {
    test('a typed number shows immediately, without waiting for the server',
        () {
      // The control posts on every change and its steppers compute the next
      // value from the one on screen. Leaving the display on the server's old
      // number until the reload lands lets two quick presses both compute from
      // the same stale figure, and the second write undoes the first.
      final AppStore store = AppStore();
      final Generator before = store.generators.first;

      store.updateGenerator(
        before.copyWith(sopQuestionCount: 30, questionCountMode: 'fixed'),
      );

      final Generator after = store.genById(before.id)!;
      expect(after.sopQuestionCount, 30);
      expect(after.countIsAuto, isFalse);
    });

    test('Auto and the number move together', () {
      // `countIsAuto` reads `questionCountMode`, NOT the count - so updating
      // one without the other showed "Auto" over a number the user had just
      // typed.
      final AppStore store = AppStore();
      final Generator g = store.generators.first;

      store.updateGenerator(
        g.copyWith(sopQuestionCount: 0, questionCountMode: 'auto'),
      );
      expect(store.genById(g.id)!.countIsAuto, isTrue);

      store.updateGenerator(
        g.copyWith(sopQuestionCount: 12, questionCountMode: 'fixed'),
      );
      final Generator fixed = store.genById(g.id)!;
      expect(fixed.countIsAuto, isFalse);
      expect(fixed.sopQuestionCount, 12);
    });
  });
}

/// The coverage floor: a ticked type with no count is worth one.
///
/// Its chip reads "any", and `_TypeQuotaChip` has always documented that "a
/// type with no explicit count still gets at least one item (the coverage
/// floor)". The total never counted it, so `MSQ x3` plus `Rubric x any` read
/// as 7 on a run that asked for 8 - and ticking another type moved nothing on
/// screen.
///
/// The arithmetic is asserted through the SAME public surface the panel reads,
/// so a change to one and not the other shows up here. The server's own copy
/// of this rule is pinned in `tests/test_shape_quotas.py`; the two must agree
/// or the number shown is not the number requested.
void _coverageFloorTests() {
  Generator gen({
    required List<QType> types,
    Map<String, int> quotas = const <String, int>{},
    int pinned = 0,
  }) => Generator(
    id: 'g1',
    name: 'Floor fixture',
    owner: '',
    created: '',
    sopFile: '',
    questionCount: 0,
    plannedCount: 0,
    allowedTypes: types,
    shapeQuotas: quotas,
    sopQuestionCount: pinned,
    questionCountMode: pinned == 0 ? 'auto' : 'fixed',
  );

  group('A type with no quota counts as one', () {
    test('"any" beside a quota adds to the total', () {
      final Generator g = gen(
        types: <QType>[QType.msq, QType.subjectiveRubric],
        quotas: <String, int>{QType.msq.wire: 3},
      );
      expect(g.effectiveQuestionCount, 4);
    });

    test('a type carrying a quota is not counted twice', () {
      final Generator g = gen(
        types: <QType>[QType.msq],
        quotas: <String, int>{QType.msq.wire: 3},
      );
      expect(g.effectiveQuestionCount, 3);
    });

    test('ticking another type moves the total by one', () {
      final Map<String, int> quotas = <String, int>{QType.msq.wire: 3};
      final int before = gen(types: <QType>[QType.msq], quotas: quotas).effectiveQuestionCount;
      final int after = gen(types: <QType>[QType.msq, QType.imageAb], quotas: quotas).effectiveQuestionCount;

      expect(before, 3);
      expect(after, before + 1);
    });

    test('a bigger pinned total still wins', () {
      // "20 across these three types" stays expressible: the floor raises a
      // total that is too small, it never caps one that is large enough.
      final Generator g = gen(
        types: <QType>[QType.mcq, QType.msq, QType.subjectiveRubric],
        pinned: 20,
      );
      expect(g.effectiveQuestionCount, 20);
    });

    test('no types and no quotas leaves the pinned number alone', () {
      expect(gen(types: <QType>[], pinned: 6).effectiveQuestionCount, 6);
    });
  });
}
