// The question editor - the half of review that was missing.
//
// The riskiest thing here is not the layout, it is the two answer-key SHAPES:
// a draft carries a flat list of option strings with the correct one named by
// TEXT, a bank question carries dimension and option records with ids. Sending
// one shape's payload for the other silently destroys an answer key, so the
// parsing that decides which is which is what these pin.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';

void main() {
  group('a draft carries its answer key as flat text', () {
    test('options and the correct answer are parsed from the wire', () {
      final Question q = Question.fromJson(<String, dynamic>{
        'id': '8',
        'name': 'Obstructed view',
        'question_type': 'mcq',
        'options': <String>['Reverse', 'Forward', 'Raise the load'],
        'correct_answer': 'Reverse',
      });
      expect(q.options, <String>['Reverse', 'Forward', 'Raise the load']);
      expect(q.correctAnswers, <String>['Reverse']);
    });

    test('msq sends a list and it stays a list', () {
      final Question q = Question.fromJson(<String, dynamic>{
        'id': '9',
        'question_type': 'msq',
        'options': <String>['A', 'B', 'C'],
        'correct_answer': <String>['A', 'C'],
      });
      expect(q.correctAnswers, <String>['A', 'C']);
    });

    test('a missing or empty correct answer is empty, not a blank entry', () {
      // The distinction matters: [''] would look like one correct option
      // whose text happens to be empty, and the editor would render a ticked
      // row for it.
      expect(
        Question.fromJson(<String, dynamic>{'id': '1'}).correctAnswers,
        isEmpty,
      );
      expect(
        Question.fromJson(<String, dynamic>{
          'id': '1',
          'correct_answer': '',
        }).correctAnswers,
        isEmpty,
      );
    });
  });

  group('a bank question carries record ids', () {
    test('the dimension id survives parsing', () {
      // `code` defaults to 'D1' and is a LABEL. Nothing carried the real id,
      // so an edit could only replace the whole dimension - which deletes its
      // options, and the submitted answers pointing at them go with it.
      final Question q = Question.fromJson(<String, dynamic>{
        'id': '1',
        'question_type': 'msq',
        'dimensions': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 42,
            'name': 'Answer',
            'options': <Map<String, dynamic>>[
              <String, dynamic>{'id': 7, 'name': 'Alpha', 'is_correct': true},
              <String, dynamic>{'id': 8, 'name': 'Bravo', 'is_correct': false},
            ],
          },
        ],
      });
      expect(q.dims, hasLength(1));
      expect(q.dims.first.id, '42', reason: 'the dimension id must survive');
      expect(q.dims.first.options.first.id, '7');
      expect(q.dims.first.options.first.label, 'Alpha');
      expect(q.dims.first.options.first.correct, isTrue);
    });

    test('a dimension with no id reports an empty one, not "D1"', () {
      // So the editor can tell "new axis" from "axis 1" and decide between
      // creating and updating.
      final Question q = Question.fromJson(<String, dynamic>{
        'id': '1',
        'dimensions': <Map<String, dynamic>>[
          <String, dynamic>{'name': 'Answer'},
        ],
      });
      expect(q.dims.first.id, isEmpty);
    });
  });
}
