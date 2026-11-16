// A question's answer key arrives in two spellings, and both must render.
//
// THE BUG THIS EXISTS FOR. A bank question keys its answer as `dimensions` -
// axes of options, each carrying a correct flag. A generated DRAFT keys the
// same answer as `options` (bare strings) plus `correct_answer` (the correct
// ones by text). Eleven display sites read the first spelling and none read the
// second, so a draft msq with five options and three correct rendered as an
// empty option list, an empty answer-key panel, and a blocking red "No answer
// key - an objective question with no correct option marked can never be
// scored" - over a record the server had sent in full.
//
// Nothing caught it. `live_payload_test` asserted only that parsing did not
// throw, and a parse that returns every field at its default satisfies that.
// So these assert VALUES, and each one is written so it can fail.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

/// A draft as the generator writes one: flat key, no dimension records yet.
Map<String, dynamic> _flatDraft({
  String type = 'msq',
  List<String> options = const <String>[
    'Upload buttons',
    'Navigation elements',
    'Static background images',
    'Tabs',
    'Plain text paragraphs',
  ],
  Object? correct = const <String>[
    'Upload buttons',
    'Navigation elements',
    'Tabs',
  ],
}) => <String, dynamic>{
  'id': 7585,
  'name': 'Identify Interactive Elements',
  'question_type': type,
  'state': 'draft',
  'prompt': 'Which of these are interactive elements?',
  'options': options,
  'correct_answer': correct,
};

void main() {
  group('a draft keyed the flat way still renders as a key', () {
    test('five options and three correct survive into the dimension tree', () {
      final Question q = Question.fromJson(_flatDraft());

      expect(q.options, hasLength(5), reason: 'the flat list was dropped');
      expect(q.correctAnswers, hasLength(3));

      // The shape every renderer actually reads.
      expect(q.dims, hasLength(1), reason: 'no axis was synthesised');
      expect(
        q.dims.single.options,
        hasLength(5),
        reason: 'the option list the candidate would choose from is empty',
      );
      expect(
        q.dims.single.options
            .where((QOption o) => o.correct)
            .map((QOption o) => o.label),
        containsAll(<String>['Upload buttons', 'Navigation elements', 'Tabs']),
      );
      expect(
        q.dims.single.options.where((QOption o) => !o.correct).length,
        2,
        reason: 'the distractors were marked correct',
      );
    });

    test('mcq sends its correct answer as a bare string, not a list', () {
      final Question q = Question.fromJson(
        _flatDraft(type: 'mcq', options: <String>['YES', 'NO'], correct: 'NO'),
      );
      expect(q.correctAnswers, <String>['NO']);
      expect(
        q.dims.single.options.where((QOption o) => o.correct).single.label,
        'NO',
      );
    });

    test('the blocking "No answer key" warning is gone', () {
      final Question q = Question.fromJson(_flatDraft());
      expect(q.hasCompleteKey, isTrue);
      expect(
        q.warnings.map((QualityWarning w) => w.title),
        isNot(contains('No answer key')),
      );
      expect(
        q.blockingWarnings.map((QualityWarning w) => w.title),
        isNot(contains('No answer key')),
      );
    });

    // The negative control. Without it the test above only proves the warning
    // can be absent, not that it still appears when it should.
    test('a draft with nothing marked correct STILL fails', () {
      final Question q = Question.fromJson(
        _flatDraft(correct: const <String>[]),
      );
      expect(q.hasCompleteKey, isFalse);
      expect(
        q.warnings.map((QualityWarning w) => w.title),
        contains('No answer key'),
      );
    });

    test('a correct answer naming no option is refused', () {
      final Question q = Question.fromJson(
        _flatDraft(correct: const <String>['Something else entirely']),
      );
      // Parsed, but nothing in the tree is flagged - so the key is incomplete.
      expect(q.dims.single.options.where((QOption o) => o.correct), isEmpty);
      expect(q.hasCompleteKey, isFalse);
    });

    test('a subjective draft carrying stray options gets no synthetic key', () {
      final Question q = Question.fromJson(
        _flatDraft(type: 'subjective_rubric'),
      );
      expect(
        q.dims,
        isEmpty,
        reason: 'a rubric question must not acquire an option key',
      );
    });

    test('a real dimension tree always wins over the flat shape', () {
      final Map<String, dynamic> j = _flatDraft();
      j['dimensions'] = <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 7296,
          'label': 'Identify Interactive Elements',
          'options': <Map<String, dynamic>>[
            <String, dynamic>{'id': 1, 'name': 'Tabs', 'is_correct': true},
            <String, dynamic>{
              'id': 2,
              'name': 'Paragraphs',
              'is_correct': false,
            },
          ],
        },
      ];
      final Question q = Question.fromJson(j);
      expect(
        q.dims.single.id,
        '7296',
        reason: 'the server tree was replaced by a synthesised one',
      );
      expect(q.dims.single.options, hasLength(2));
      expect(q.dims.single.name, 'Identify Interactive Elements');
    });

    // Gate 6 must behave exactly as before for anything the bank sends. A bank
    // LIST row carries `dimension_count` and no dimensions, and never carries
    // `correct_answer` - so it has to keep falling through to the server's own
    // verdict rather than picking up a key it does not have.
    test('a bank list row still defers to the server verdict', () {
      final Question no = Question.fromJson(<String, dynamic>{
        'id': 24508,
        'question_type': 'mcq',
        'name': 'A bank row',
        'dimension_count': 1,
        'has_valid_key': false,
      });
      expect(no.dims, isEmpty);
      expect(no.hasCompleteKey, isFalse);

      final Question yes = Question.fromJson(<String, dynamic>{
        'id': 24509,
        'question_type': 'mcq',
        'name': 'A bank row',
        'dimension_count': 1,
        'has_valid_key': true,
      });
      expect(yes.hasCompleteKey, isTrue);
    });
  });

  group('a synthesised key is safe to edit through', () {
    test(
      'it carries no server ids, so a write creates rather than collides',
      () {
        final Question q = Question.fromJson(_flatDraft());
        expect(
          q.dims.single.id,
          isEmpty,
          reason: 'a synthetic axis must not claim another record\'s id',
        );
        expect(
          q.dims.single.options.every((QOption o) => o.id == o.label),
          isTrue,
          reason: 'bare-string options are keyed by their own text, not by id',
        );
      },
    );

    test('the flat fields stay populated for the editor to round-trip', () {
      final Question q = Question.fromJson(_flatDraft());
      expect(q.options, isNotEmpty);
      expect(q.correctAnswers, isNotEmpty);
    });
  });

  group('copyWith keeps what it is not asked to change', () {
    test('labelBoxes survives - it used to be silently zeroed', () {
      const Question q = Question(
        id: '1',
        genId: 'g',
        type: QType.imageLabel,
        name: 'n',
        prompt: 'p',
        labelBoxes: <int>[1, 2, 3],
      );
      // This is the call shape that promotes an approved draft into the bank.
      expect(q.copyWith(state: DraftState.approved).labelBoxes, <int>[1, 2, 3]);
    });

    test('the flat answer key survives an unrelated copy', () {
      final Question q = Question.fromJson(_flatDraft());
      final Question copied = q.copyWith(name: 'renamed');
      expect(copied.options, hasLength(5));
      expect(copied.correctAnswers, hasLength(3));
      expect(copied.dims, hasLength(1));
    });
  });

  group('parsing survives shapes the LLM can actually produce', () {
    // These columns are free-form model output. Every one of them used to be
    // an unguarded cast, and one bad field discarded the WHOLE record - the
    // card then reported no image and no key over a payload the server sent in
    // full.
    test(
      'a non-list where a list was expected does not take the record down',
      () {
        final Map<String, dynamic> j = _flatDraft();
        j['options'] = <String, dynamic>{'not': 'a list'};
        j['dimensions'] = 'nonsense';
        j['images'] = <String, dynamic>{};
        j['label_boxes'] = 42;
        j['videos'] = 'nope';
        j['tags'] = 7;

        late final Question q;
        expect(() => q = Question.fromJson(j), returnsNormally);
        // The rest of the record is intact, which is the point.
        expect(q.name, 'Identify Interactive Elements');
        expect(q.prompt, isNotEmpty);
        expect(q.correctAnswers, hasLength(3));
      },
    );

    test('a number where a string was expected does not throw', () {
      final Map<String, dynamic> j = _flatDraft();
      j['difficulty'] = 3;
      j['state'] = false;
      j['image_state'] = 1;
      expect(() => Question.fromJson(j), returnsNormally);
    });

    test('an option list of maps and one of bare strings both parse', () {
      final Map<String, dynamic> j = _flatDraft();
      j['dimensions'] = <Map<String, dynamic>>[
        <String, dynamic>{
          'label': 'Mixed',
          'options': <dynamic>[
            'Bare string',
            <String, dynamic>{'name': 'A map', 'is_correct': true},
          ],
          'correct': <String>['Bare string'],
        },
      ];
      final Question q = Question.fromJson(j);
      expect(q.dims.single.options, hasLength(2));
      expect(
        q.dims.single.options.where((QOption o) => o.correct),
        hasLength(2),
      );
    });
  });

  // THE SKILLS A QUESTION COVERS, which the server never used to send.
  //
  // `Question.tags` and `jtags` have both existed all along; `bank_question_row`
  // simply carried no `tags` key, because `assessments.be.question` had no tag
  // field for it to read - the vocabulary stopped at the generator. So a bank
  // of a hundred questions inherited none of the skills its own SOP was read
  // for, and nothing anywhere reported a gap.
  group('A bank question carries its skill tags', () {
    Map<String, dynamic> row(Object? tags) => <String, dynamic>{
      'id': 9,
      'name': 'Battery charging',
      'question_type': 'mcq',
      'prompt': 'What does the SOP require?',
      'state': 'approved',
      'tags': ?tags,
    };

    test('the canonical names arrive as a list of strings', () {
      final Question q = Question.fromJson(
        row(<String>['domain:forklift', 'modality:image']),
      );
      expect(q.tags, <String>['domain:forklift', 'modality:image']);
    });

    test('a question with none parses to an empty list, never null', () {
      expect(Question.fromJson(row(null)).tags, isEmpty);
      expect(Question.fromJson(row(<dynamic>[])).tags, isEmpty);
    });
  });
}
