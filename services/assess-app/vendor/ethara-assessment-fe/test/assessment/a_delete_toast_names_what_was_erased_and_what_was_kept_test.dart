// The toast after a Delete repeats the SERVER's counts: how many were erased
// and how many had to be kept as Deleted because a paper or an answer points
// at them. That split is the one thing the operator could not know before
// pressing Delete, so each sentence is pinned word for word:
//   - a question delete (`outcomeSentence`): all erased, all kept, a mix;
//   - a generator delete (`generatorOutcomeSentence`): the generators first,
//     then the questions they authored, each half naming both counts.
library;

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('a question delete', () {
    test('all erased reads as the plain word', () {
      expect(const DeletePreview(deletedCount: 3).outcomeSentence, 'Deleted');
    });

    test('all kept says the results are kept', () {
      expect(
        const DeletePreview(retiredCount: 2).outcomeSentence,
        '2 moved to Deleted - their results are kept',
      );
    });

    test('a mix names both counts', () {
      expect(
        const DeletePreview(deletedCount: 1, retiredCount: 4).outcomeSentence,
        '1 erased, 4 moved to Deleted with their results kept',
      );
    });
  });

  group('a generator delete', () {
    test('erased and kept generators, erased and kept questions', () {
      expect(
        const DeletePreview(
          deletedGenerators: 2,
          keptGenerators: 1,
          deletedCount: 4,
          retiredCount: 3,
        ).generatorOutcomeSentence,
        '2 generators erased, 1 moved to Deleted with their results kept. '
        '7 questions: 4 erased, 3 moved to Deleted',
      );
    });

    test('one kept generator with nothing erased says "its"', () {
      expect(
        const DeletePreview(keptGenerators: 1).generatorOutcomeSentence,
        '1 generator moved to Deleted - its results are kept',
      );
    });
  });

  // A backend before 19.0.3.27.0 says "archived" where the current one says
  // "kept". Read as erased, an in-use generator that survived was announced
  // as gone for good.
  test('a generator the older server "archived" is counted as kept', () {
    final DeletePreview p = DeletePreview.fromGenerators(<String, dynamic>{
      'generators': <dynamic>[
        <String, dynamic>{'outcome': 'archived', 'draftCount': 4},
        <String, dynamic>{'outcome': 'kept'},
        <String, dynamic>{'outcome': 'deleted', 'draftCount': 2},
      ],
    }, 3);
    expect(p.keptGenerators, 2);
    expect(p.deletedGenerators, 1);
    expect(p.draftCount, 2, reason: 'nothing goes with a kept generator');
    expect(p.keepsHistory, isTrue);
  });
}
