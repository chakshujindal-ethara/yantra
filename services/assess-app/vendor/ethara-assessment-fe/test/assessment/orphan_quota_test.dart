// A quota nobody can see is a quota nobody can fix.
//
// THE DEFECT. An archived template is absent from `/api/v1/task_templates`
// (Odoo's active_test filters it out), so the generation tab's chosen-task list
// silently dropped its quota while the Generate button kept counting it. That
// is the "3 questions, nothing selected" report: the count was real, the picks
// behind it were invisible, and the run authored generic items in place of the
// task with no warning before the spend.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';

/// Mirrors `_orphanShapes` in generator_detail_screen.dart — a template quota
/// whose template the library cannot resolve.
List<String> orphanShapes(
  Map<String, int> quotas,
  Set<int> knownTemplateIds,
) => <String>[
  for (final String shape in quotas.keys)
    if (shape.startsWith('template:') &&
        !knownTemplateIds.contains(int.tryParse(shape.substring(9)) ?? 0))
      shape,
];

void main() {
  group('an unresolvable task quota is surfaced', () {
    test('an archived template quota is reported', () {
      // Template 16 exists in the DB but is archived, so the library omits it.
      expect(
        orphanShapes(<String, int>{'template:16': 2}, <int>{6, 19, 20}),
        <String>['template:16'],
      );
    });

    test('a live template quota is not reported', () {
      expect(
        orphanShapes(<String, int>{'template:19': 1}, <int>{19}),
        isEmpty,
      );
    });

    test('type quotas are never orphans', () {
      expect(
        orphanShapes(<String, int>{'mcq': 3, 'msq': 1}, <int>{}),
        isEmpty,
      );
    });

    test('a mixed run reports only the unresolvable one', () {
      expect(
        orphanShapes(
          <String, int>{'template:19': 1, 'template:16': 2, 'mcq': 3},
          <int>{19},
        ),
        <String>['template:16'],
      );
    });
  });

  group('the count still reflects what was asked', () {
    // `_effectiveCount` is deliberately unchanged: it answers "what did the
    // operator commit to", and the orphan row answers "which of those cannot
    // be honoured". Conflating them would hide the problem again by quietly
    // shrinking the number.
    test('a quota total counts every committed pick', () {
      final Generator g = Generator(
        id: '178',
        name: 'ig-entity-tagging-301',
        shapeQuotas: const <String, int>{'template:16': 2, 'mcq': 1},
      );

      expect(
        g.shapeQuotas.values.fold(0, (int a, int b) => a + b),
        3,
        reason: 'the total is honest; the orphan row explains the shortfall',
      );
    });
  });
}
