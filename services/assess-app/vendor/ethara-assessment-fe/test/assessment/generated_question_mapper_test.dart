// THE MODEL-RESPONSE -> FORM STUDIO BLOCK MAPPING.
//
// `generated_question_mapper.dart` is what lets a generated question set open
// in the SAME blocks Form Studio draws, instead of a second editor built
// beside the first. These tests pin the two things that make it trustworthy:
//
//  1. Every backend question type resolves to a block - including the two
//     (`image_prompt`, `video_prompt`) that have NO native Form Studio kind
//     and must degrade to a paragraph WITH a note rather than silently.
//  2. The answer key survives the trip in every shape the wire uses: a
//     dimension tree (bank), a flat option list + correct TEXT (draft), a
//     grid's row->column key, a scale/rating's numeric options, an A/B's
//     official reasoning, and a labelling question's per-box key.
//
// The type table this asserts is the reverse of `studio_form._item_spec` on
// the server; if that mapping changes, these fail rather than the two sides
// drifting apart quietly.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/domain/generated_question_mapper.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

Question _q({
  required QType type,
  String name = 'A generated question',
  String prompt = 'What does the SOP require here?',
  String desc = '',
  List<QDimension> dims = const <QDimension>[],
  List<String> options = const <String>[],
  List<String> correctAnswers = const <String>[],
  List<String> rubric = const <String>[],
  List<Asset> images = const <Asset>[],
  List<Asset> videos = const <Asset>[],
  Map<int, String> boxKey = const <int, String>{},
  List<int> labelBoxes = const <int>[],
  String officialReasoning = '',
  String solutionRationale = '',
}) => Question(
  id: 'q-1',
  genId: 'gen-1',
  type: type,
  name: name,
  prompt: prompt,
  desc: desc,
  dims: dims,
  options: options,
  correctAnswers: correctAnswers,
  rubric: rubric,
  images: images,
  videos: videos,
  boxKey: boxKey,
  labelBoxes: labelBoxes,
  officialReasoning: officialReasoning,
  solutionRationale: solutionRationale,
);

QDimension _dim(
  String name,
  List<(String, bool)> opts, {
  String inputKind = '',
}) => QDimension(
  code: 'D1',
  name: name,
  inputKind: inputKind,
  options: <QOption>[
    for (final (String label, bool correct) o in opts)
      QOption(id: 'o-${o.$1}', label: o.$1, correct: o.$2),
  ],
);

void main() {
  group('every backend question type resolves to a block', () {
    test('mcq with one axis is a multiple choice', () {
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.mcq,
          dims: <QDimension>[
            _dim('Answer', <(String, bool)>[('Yes', true), ('No', false)]),
          ],
        ),
      );
      expect(m.item.kind, FormItemKind.multipleChoice);
      expect(m.notes, isEmpty);
    });

    test('msq with one axis is checkboxes', () {
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.msq,
          dims: <QDimension>[
            _dim('Answer', <(String, bool)>[('A', true), ('B', true)]),
          ],
        ),
      );
      expect(m.item.kind, FormItemKind.checkboxes);
    });

    test('mcq with several axes is a choice GRID, one row per axis', () {
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.mcq,
          dims: <QDimension>[
            _dim('Sharpness', <(String, bool)>[('Pass', true), ('Fail', false)]),
            _dim('Colour', <(String, bool)>[('Pass', false), ('Fail', true)]),
          ],
        ),
      );
      expect(m.item.kind, FormItemKind.choiceGrid);
      expect(m.item.rows, <String>['Sharpness', 'Colour']);
      expect(m.item.columns, <String>['Pass', 'Fail']);
      // The key is row index -> the correct COLUMN LABEL(s). A set even here,
      // where a radio grid can only ever have one: both grid kinds share the
      // field, and publish is what refuses a second column on this kind.
      expect(m.item.gridKey[0], <String>{'Pass'});
      expect(m.item.gridKey[1], <String>{'Fail'});
    });

    test('a checkbox GRID row keeps EVERY correct column, not the first', () {
      // THE DEFECT. `_fillGrid` took `.where(correct).firstOrNull`, so reading a
      // published checkbox grid back into the designer kept one column per row
      // and silently dropped the rest - and the next save wrote that loss back
      // as the truth. Both editors that host this sheet round-trip through here.
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.msq,
          dims: <QDimension>[
            _dim('Office', <(String, bool)>[
              ('People', false),
              ('Cubicles', true),
              ('Laptops', true),
            ]),
            _dim('Warehouse', <(String, bool)>[
              ('People', true),
              ('Cubicles', false),
              ('Laptops', false),
            ]),
          ],
        ),
      );
      expect(m.item.kind, FormItemKind.checkboxGrid);
      expect(m.item.gridKey[0], <String>{'Cubicles', 'Laptops'});
      // A single-key row still reads as a one-element set, so the two shapes
      // do not need telling apart anywhere downstream.
      expect(m.item.gridKey[1], <String>{'People'});
    });

    test('a multi-key grid survives a JSON round trip', () {
      // `toJson`/`fromJson` is how duplicating an item works, so a key shape
      // either side does not understand is lost silently - the failure mode
      // `form_models` warns about for every other field.
      // TWO axes, because one axis is `checkboxes` rather than a grid - see
      // the test above. A grid needs at least two rows to be one.
      final FormItem before = formItemFromQuestion(
        _q(
          type: QType.msq,
          dims: <QDimension>[
            _dim('Office', <(String, bool)>[
              ('Cubicles', true),
              ('Laptops', true),
            ]),
            _dim('Warehouse', <(String, bool)>[
              ('Cubicles', false),
              ('Laptops', true),
            ]),
          ],
        ),
      ).item;
      expect(before.kind, FormItemKind.checkboxGrid, reason: 'fixture check');
      final FormItem after = FormItem.fromJson(before.toJson());
      expect(after.gridKey[0], <String>{'Cubicles', 'Laptops'});
      expect(after.gridKey[1], <String>{'Laptops'});
    });

    test('a form saved before multi-select reads its scalar key back', () {
      // Backward compatibility, and it is the common case: every grid authored
      // to date carries `{"0": "Cubicles"}`, not a list. Forms are loaded far
      // more often than they are re-saved, so dropping this would blank the key
      // on every existing grid the moment someone opened it.
      final FormItem legacy = FormItem.fromJson(<String, dynamic>{
        'id': 'i1',
        'kind': 'checkboxGrid',
        'rows': <String>['Office'],
        'columns': <String>['Cubicles', 'Laptops'],
        'grid_key': <String, dynamic>{'0': 'Cubicles'},
      });
      expect(legacy.gridKey[0], <String>{'Cubicles'});
    });

    test('subjective_rubric is a paragraph carrying the rubric as golden', () {
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.subjectiveRubric,
          rubric: <String>['States the tolerance.', 'Names the step.'],
        ),
      );
      expect(m.item.kind, FormItemKind.paragraph);
      expect(m.item.goldenAnswer, contains('States the tolerance.'));
      expect(m.item.goldenAnswer, contains('Names the step.'));
    });

    test('image_ab is a comparison with both sides and the rationale', () {
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.imageAb,
          images: <Asset>[
            const Asset(id: 'a', label: 'A', url: 'https://x/a.png', slot: 'a'),
            const Asset(id: 'b', label: 'B', url: 'https://x/b.png', slot: 'b'),
          ],
          dims: <QDimension>[
            _dim('Overall Choice', <(String, bool)>[
              ('Response A', true),
              ('Response B', false),
            ]),
          ],
          officialReasoning: 'A is sharper at the edge.',
        ),
      );
      expect(m.item.kind, FormItemKind.comparePair);
      expect(m.item.mediaUrl, 'https://x/a.png');
      expect(m.item.mediaUrlB, 'https://x/b.png');
      expect(m.item.goldenAnswer, 'A is sharper at the edge.');
      expect(m.notes, isEmpty);
    });

    test('image_label is an annotation carrying the per-box key', () {
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.imageLabel,
          images: <Asset>[
            const Asset(
              id: 'p',
              label: 'plate',
              url: 'https://x/plate.png',
              slot: 'single',
            ),
          ],
          labelBoxes: <int>[1, 2, 3],
          boxKey: <int, String>{1: 'Torn seal', 2: 'Bent pin', 3: 'Smudge'},
        ),
      );
      expect(m.item.kind, FormItemKind.imageAnnotation);
      expect(m.item.mediaUrl, 'https://x/plate.png');
      expect(m.item.annotationCount, 3);
      expect(m.item.goldenLabels[2], 'Bent pin');
    });
  });

  group('the prompt-writing types now have a real block', () {
    // These two used to have NO Form Studio kind and opened as a lossy
    // paragraph with a warning. `FormItemKind.promptWriting` closed that gap,
    // so the mapping is now exact and silent.
    test('image_prompt is a promptWriting block, no note', () {
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.imagePrompt,
          images: <Asset>[
            const Asset(
              id: 'i',
              label: 'ref',
              url: 'https://x/ref.png',
              slot: 'single',
            ),
          ],
        ),
      );
      expect(m.item.kind, FormItemKind.promptWriting);
      expect(m.item.mediaUrl, 'https://x/ref.png');
      // The from-scratch form has no second plate.
      expect(m.item.mediaUrlB, isEmpty);
      expect(m.notes, isEmpty);
    });

    test('video_prompt is the SAME kind, carrying the clip', () {
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.videoPrompt,
          videos: <Asset>[
            const Asset(
              id: 'v',
              label: 'clip',
              url: 'https://x/clip.mp4',
              slot: 'single',
            ),
          ],
        ),
      );
      expect(m.item.kind, FormItemKind.promptWriting);
      expect(m.item.mediaUrl, 'https://x/clip.mp4');
      expect(m.notes, isEmpty);
    });

    test('a reference -> output pair fills BOTH slots, in that order', () {
      // The transform form: "write the prompt that turns A into B". Read by
      // SLOT, not list order - positional reading would reverse the question.
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.imagePrompt,
          images: <Asset>[
            const Asset(
              id: 'o',
              label: 'out',
              url: 'https://x/out.png',
              slot: 'output',
            ),
            const Asset(
              id: 'r',
              label: 'ref',
              url: 'https://x/ref.png',
              slot: 'reference',
            ),
          ],
        ),
      );
      expect(m.item.mediaUrl, 'https://x/ref.png');
      expect(m.item.mediaUrlB, 'https://x/out.png');
    });

    test('the golden prompt and optional rating axes both survive', () {
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.imagePrompt,
          images: <Asset>[
            const Asset(
              id: 'i',
              label: 'ref',
              url: 'https://x/ref.png',
              slot: 'single',
            ),
          ],
          rubric: <String>['A wide shot of a red barn at dusk.'],
          dims: <QDimension>[
            _dim('Visual quality', <(String, bool)>[
              ('Good', true),
              ('Poor', false),
            ]),
          ],
        ),
      );
      expect(m.item.goldenAnswer, 'A wide shot of a red barn at dusk.');
      expect(m.item.options, hasLength(2));
      expect(
        m.item.options.where((FormOption o) => o.correct).single.label,
        'Good',
      );
    });

    test('a prompt question with no rendered media says so', () {
      final MappedFormItem m = formItemFromQuestion(
        _q(type: QType.videoPrompt),
      );
      expect(m.item.kind, FormItemKind.promptWriting);
      expect(m.notes.single, contains('not been rendered'));
    });

    test('no backend type is left without a block', () {
      // The whole point: whatever the model returns, SOMETHING can edit it.
      for (final QType t in QType.values) {
        final MappedFormItem m = formItemFromQuestion(_q(type: t));
        expect(
          m.item.kind,
          isNotNull,
          reason: '$t must resolve to a Form Studio block',
        );
      }
    });
  });

  group("a template's own control wins over the engine type", () {
    test('an mcq axis drawn as a rating opens as a rating', () {
      // A templated question REMEMBERS the control the examiner drew, so it
      // round-trips exactly instead of collapsing onto `mcq`'s default.
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.mcq,
          dims: <QDimension>[
            _dim(
              'Answer',
              <(String, bool)>[
                ('1', false),
                ('2', false),
                ('3', false),
                ('4', true),
                ('5', false),
              ],
              inputKind: 'rating',
            ),
          ],
        ),
      );
      expect(m.item.kind, FormItemKind.rating);
      expect(m.item.ratingMax, 5);
      expect(m.item.ratingGolden, 4);
    });

    test('an mcq axis drawn as a linear scale opens as one', () {
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.mcq,
          dims: <QDimension>[
            _dim(
              'Answer',
              <(String, bool)>[
                ('1', false),
                ('2', true),
                ('3', false),
              ],
              inputKind: 'linearScale',
            ),
          ],
        ),
      );
      expect(m.item.kind, FormItemKind.linearScale);
      expect(m.item.scaleMin, 1);
      expect(m.item.scaleMax, 3);
      expect(m.item.scaleGolden, 2);
    });

    test('a control this build no longer offers falls back and says so', () {
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.mcq,
          dims: <QDimension>[
            _dim(
              'Answer',
              <(String, bool)>[('Yes', true)],
              inputKind: 'someKindFromTheFuture',
            ),
          ],
        ),
      );
      expect(m.item.kind, FormItemKind.multipleChoice);
      expect(m.notes.single, contains('someKindFromTheFuture'));
    });
  });

  group('the DRAFT wire shape works too, not just the bank shape', () {
    test('a flat option list with correct TEXT still keys the options', () {
      // A draft has no dimension records yet: `options_json` is a flat list
      // and `correct_answer_json` is the TEXT of the right one.
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.mcq,
          options: <String>['Tighten to 4Nm', 'Tighten to 40Nm', 'Leave it'],
          correctAnswers: <String>['Tighten to 4Nm'],
        ),
      );
      expect(m.item.options, hasLength(3));
      expect(
        m.item.options.where((FormOption o) => o.correct).single.label,
        'Tighten to 4Nm',
      );
    });

    test('matching is tolerant of the case and spacing the model wrote', () {
      final MappedFormItem m = formItemFromQuestion(
        _q(
          type: QType.mcq,
          options: <String>['Yes', 'No'],
          correctAnswers: <String>['  yes '],
        ),
      );
      expect(
        m.item.options.where((FormOption o) => o.correct).single.label,
        'Yes',
      );
    });
  });

  group('a whole generated set becomes one editable form', () {
    test('every question lands as an item in one section', () {
      final ({FormDef form, List<String> notes}) out =
          formFromGeneratedQuestions(
            title: 'Torque SOP - generated',
            questions: <Question>[
              _q(type: QType.mcq, name: 'Q1', options: <String>['a', 'b']),
              _q(type: QType.subjectiveRubric, name: 'Q2'),
              _q(type: QType.videoPrompt, name: 'Q3'),
            ],
          );

      expect(out.form.title, 'Torque SOP - generated');
      expect(out.form.sections, hasLength(1));
      expect(out.form.sections.single.items, hasLength(3));
      expect(out.form.questionCount, 3);

      // The one lossy conversion is reported, and NAMED so it is actionable
      // in a set of many.
      expect(out.notes, hasLength(1));
      expect(out.notes.single, startsWith('Q3:'));
    });

    test('the mapped form round-trips through JSON like any other', () {
      final ({FormDef form, List<String> notes}) out =
          formFromGeneratedQuestions(
            title: 'Set',
            questions: <Question>[
              _q(
                type: QType.mcq,
                options: <String>['a', 'b'],
                correctAnswers: <String>['b'],
              ),
            ],
          );
      final FormDef back = FormDef.fromJson(out.form.toJson());
      expect(back.sections.single.items.single.kind,
          FormItemKind.multipleChoice);
      expect(
        back.sections.single.items.single.options
            .where((FormOption o) => o.correct)
            .single
            .label,
        'b',
      );
    });
  });

  group('a generated question can seed a TASK TEMPLATE', () {
    // A question the examiner judges good describes the shape they want more
    // of, which is what a template is. The one rule that matters: a template
    // is a SHAPE, so the answer key must NOT come along - the key belongs to
    // each generated instance, because the model decides per item which
    // option is right for the stimulus it just invented.
    FormItem soleItem(TaskTemplate tpl) {
      final Map<dynamic, dynamic> section =
          tpl.structure.single as Map<dynamic, dynamic>;
      final List<dynamic> items = section['items'] as List<dynamic>;
      return FormItem.fromJson(items.single as Map<String, dynamic>);
    }

    test('it opens as UNSAVED work, never overwriting a stored template', () {
      final TaskTemplate tpl = taskTemplateFromQuestion(
        _q(type: QType.mcq, options: <String>['a', 'b']),
      );
      expect(tpl.id, 0, reason: "id 0 is the editor's own 'not saved yet'");
      expect(tpl.itemCount, 1);
    });

    test('the primitive matches the question type', () {
      expect(
        taskTemplateFromQuestion(_q(type: QType.msq)).response,
        'multi_choice',
      );
      expect(
        taskTemplateFromQuestion(_q(type: QType.imageAb)).response,
        'compare_two',
      );
      expect(
        taskTemplateFromQuestion(_q(type: QType.imageLabel)).response,
        'annotate_image',
      );
      expect(
        taskTemplateFromQuestion(_q(type: QType.imagePrompt)).response,
        'author_prompt',
      );
      expect(
        taskTemplateFromQuestion(_q(type: QType.videoPrompt)).response,
        'author_video_prompt',
      );
    });

    test('every question type maps to a real primitive', () {
      for (final QType t in QType.values) {
        expect(
          kQTypeToTaskPrimitive[t],
          isNotNull,
          reason: '$t must map to a task response primitive',
        );
      }
    });

    test('the OPTION SHAPE survives but the correct flags do NOT', () {
      final TaskTemplate tpl = taskTemplateFromQuestion(
        _q(
          type: QType.mcq,
          options: <String>['Tighten to 4Nm', 'Tighten to 40Nm'],
          correctAnswers: <String>['Tighten to 4Nm'],
        ),
      );
      final FormItem item = soleItem(tpl);
      expect(
        item.options.map((FormOption o) => o.label),
        <String>['Tighten to 4Nm', 'Tighten to 40Nm'],
        reason: 'the shape - how many options and their wording - is the '
            'point of the template',
      );
      expect(
        item.options.where((FormOption o) => o.correct),
        isEmpty,
        reason: 'a template carries NO answer key; the key belongs to each '
            'generated instance',
      );
    });

    test('no golden answer, grid key, scale or rating key comes along', () {
      final TaskTemplate fromText = taskTemplateFromQuestion(
        _q(type: QType.subjectiveRubric, rubric: <String>['The ideal.']),
      );
      expect(soleItem(fromText).goldenAnswer, isEmpty);

      final TaskTemplate fromGrid = taskTemplateFromQuestion(
        _q(
          type: QType.mcq,
          dims: <QDimension>[
            _dim('Row A', <(String, bool)>[('Yes', true), ('No', false)]),
            _dim('Row B', <(String, bool)>[('Yes', false), ('No', true)]),
          ],
        ),
      );
      expect(soleItem(fromGrid).gridKey, isEmpty);

      final TaskTemplate fromRating = taskTemplateFromQuestion(
        _q(
          type: QType.mcq,
          dims: <QDimension>[
            _dim(
              'Answer',
              <(String, bool)>[('1', false), ('2', true), ('3', false)],
              inputKind: 'rating',
            ),
          ],
        ),
      );
      expect(soleItem(fromRating).ratingGolden, isNull);
    });

    test('a labelling question keeps its box COUNT but not the labels', () {
      final TaskTemplate tpl = taskTemplateFromQuestion(
        _q(
          type: QType.imageLabel,
          images: <Asset>[
            const Asset(
              id: 'p',
              label: 'plate',
              url: 'https://x/plate.png',
              slot: 'single',
            ),
          ],
          labelBoxes: <int>[1, 2, 3],
          boxKey: <int, String>{1: 'Torn seal', 2: 'Bent pin', 3: 'Smudge'},
        ),
      );
      final FormItem item = soleItem(tpl);
      expect(item.annotationCount, 3, reason: 'the shape is three boxes');
      expect(
        item.goldenLabels,
        isEmpty,
        reason: 'what is AT each box is the instance answer, not the shape',
      );
    });

    test('the template is named for the task when one authored it', () {
      const Question templated = Question(
        id: 'q-1',
        genId: 'gen-1',
        type: QType.mcq,
        name: 'Q17',
        prompt: 'Which torque?',
        sourceTemplateName: 'Torque decision',
      );
      expect(taskTemplateFromQuestion(templated).name, 'Torque decision');
      // Falling back to the question's own name when it was written freely.
      expect(
        taskTemplateFromQuestion(_q(type: QType.mcq, name: 'Q9')).name,
        'Q9',
      );
    });

    test("the generator's instructions carry the question's prompt", () {
      final TaskTemplate tpl = taskTemplateFromQuestion(
        _q(type: QType.mcq, prompt: 'Which torque setting applies?'),
      );
      expect(tpl.instructions, 'Which torque setting applies?');
    });
  });
}
