// A task template quota is enough to generate on its own.
//
// THE DEFECT. Every generation gate asked `allowedTypes.isEmpty` - "has the
// operator ticked a legacy question type?" - but a TASK TEMPLATE quota already
// names its own question type. That is precisely what the server's
// `_widen_allowed_for_templates` exists for. So an operator who committed
// `T2I x2` and nothing else got a dead "Generate 2 questions" button with
// "Pick at least one question type" beside it, while the server would have run
// the job happily: an empty allow-list means Auto, and the module logs it as
// "any (model picks)".
//
// Six gates enforced it - four in the generator screen, one tooltip, one in the
// store - so a fix to any single one would have left the others blocking.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

Generator _gen({
  List<QType> allowed = const <QType>[],
  Map<String, int> quotas = const <String, int>{},
}) => Generator(
  id: '177',
  name: 'Photo Edit Verification',
  allowedTypes: allowed,
  shapeQuotas: quotas,
);

/// Mirrors `_canGenerate` in generator_detail_screen.dart and the store's own
/// guard - both express the same rule, so the rule is what this pins.
bool canGenerate(Generator g) =>
    g.allowedTypes.isNotEmpty || g.shapeQuotas.isNotEmpty;

void main() {
  test('a template quota alone is enough', () {
    final Generator g = _gen(quotas: <String, int>{'template:6': 2});

    expect(g.allowedTypes, isEmpty, reason: 'no legacy type ticked');
    expect(canGenerate(g), isTrue,
        reason: 'the template already names its own question type');
  });

  test('a legacy type alone is still enough', () {
    expect(canGenerate(_gen(allowed: <QType>[QType.mcq])), isTrue);
  });

  test('both together is enough', () {
    expect(
      canGenerate(_gen(
        allowed: <QType>[QType.mcq],
        quotas: <String, int>{'template:6': 2},
      )),
      isTrue,
    );
  });

  test('a bare type quota (no template) is enough', () {
    // `{mcq: 3}` is a shape quota too - the operator has committed a split.
    expect(canGenerate(_gen(quotas: <String, int>{'mcq': 3})), isTrue);
  });

  test('nothing chosen is still refused', () {
    // The guard must not become a no-op: with neither, the run has no shape
    // to author and the button stays dead.
    expect(canGenerate(_gen()), isFalse);
  });
}
