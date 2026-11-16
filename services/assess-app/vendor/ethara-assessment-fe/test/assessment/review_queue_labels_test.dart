// Two defects seen in the review queue, both about what a REVIEWER is told.
//
// 1. Every A/B question was badged "No answer rationale" while the rationale
//    was rendered on the same page. The list route sent no rationale field at
//    all (it is detail-route only), and the model read camelCase while the
//    module sends snake_case - so the flag defaulted to false everywhere.
// 2. The question type was printed as the RENDERING ENGINE ("Image A/B",
//    "Image · A/B evaluation") rather than the task the examiner named, which
//    reads as plainly wrong when the task is not an A/B comparison at all.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

Question _q(Map<String, dynamic> extra) => Question.fromJson(<String, dynamic>{
      'id': 1,
      'name': 'Task: Verify an object removal',
      'type': 'image_ab',
      ...extra,
    });

void main() {
  group('the rationale badge tells the truth', () {
    test('the module\'s snake_case flag is read', () {
      final Question q = _q(<String, dynamic>{'has_official_reasoning': true});

      expect(q.hasOfficialReasoning, isTrue);
      expect(
        q.warnings.any((QualityWarning w) => w.title == 'No answer rationale'),
        isFalse,
        reason: 'a question WITH a rationale must not be badged as missing one',
      );
    });

    test('a genuinely missing rationale is still flagged', () {
      final Question q = _q(<String, dynamic>{'has_official_reasoning': false});

      expect(
        q.warnings.any((QualityWarning w) => w.title == 'No answer rationale'),
        isTrue,
      );
    });

    test('the camelCase fixture spelling still works', () {
      expect(_q(<String, dynamic>{'hasOfficialReasoning': true})
          .hasOfficialReasoning, isTrue);
    });

    test('the rationale TEXT alone is enough, in either spelling', () {
      expect(
        _q(<String, dynamic>{'official_reasoning': 'A wins by construction.'})
            .hasOfficialReasoning,
        isTrue,
      );
      expect(
        _q(<String, dynamic>{'officialReasoning': 'A wins by construction.'})
            .hasOfficialReasoning,
        isTrue,
      );
    });
  });

  group('a question is labelled with its task, not the engine', () {
    test('the template name wins in both label forms', () {
      final Question q = _q(<String, dynamic>{
        'source_template': <String, dynamic>{
          'id': 16,
          'name': 'Verify a single photo edit',
        },
      });

      expect(q.taskLabel, 'Verify a single photo edit');
      expect(q.taskLabelLong, 'Verify a single photo edit');
      // The engine type is still available to anything that needs it.
      expect(q.type, QType.imageAb);
    });

    test('a model-authored question falls back to the engine type', () {
      final Question q = _q(<String, dynamic>{});

      expect(q.taskLabel, QType.imageAb.short);
      expect(q.taskLabelLong, QType.imageAb.label);
    });
  });

  // 3. THE FORM STUDIO KINDS THAT SHARE ONE ENGINE TYPE.
  //
  // `question_type` is a closed set of seven SCORING primitives, so a dropdown,
  // a linear scale, a rating and a plain multiple choice all store as `mcq` -
  // correctly, since all four are marked the same way. The reported defect is
  // that the admin lists then PRINTED "MCQ" over all four: the Selected
  // Questions tab and the generator's question list had no other field to read,
  // because the bank ROW carried no axes and no kind. `input_kind` (per axis,
  // on a detail or a draft) and `designer_kind` (one scalar, on a row) are the
  // two shapes that answer it.
  group('a Form Studio kind survives the trip through mcq', () {
    Question mcq(Map<String, dynamic> extra) =>
        Question.fromJson(<String, dynamic>{
          'id': 7,
          'name': 'Rating Ques',
          'type': 'mcq',
          ...extra,
        });

    // The ROW shape: one scalar, no axis tree. This is the payload the
    // Selected Questions tab and the bank list actually receive.
    for (final (String kind, String label) in <(String, String)>[
      ('dropdown', 'Dropdown'),
      ('linearScale', 'Linear scale'),
      ('rating', 'Rating'),
      ('checkboxes', 'Checkboxes'),
    ]) {
      test('a row naming $kind is not called MCQ', () {
        final Question q = mcq(<String, dynamic>{'designer_kind': kind});

        expect(q.designerKind?.name, kind);
        expect(q.taskLabel, label);
        expect(q.taskLabelLong, label);
        // The engine type is untouched - it is what scores the question.
        expect(q.type, QType.mcq);
      });
    }

    // The DETAIL / DRAFT shape: the kind is stamped on each axis instead.
    test('an axis naming the kind works with no row scalar', () {
      final Question q = mcq(<String, dynamic>{
        'dimensions': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 3,
            'name': 'Answer',
            'input_kind': 'linearScale',
            'options': <Map<String, dynamic>>[
              <String, dynamic>{'id': 1, 'name': '1', 'is_correct': false},
              <String, dynamic>{'id': 2, 'name': '2', 'is_correct': true},
            ],
          },
        ],
      });

      expect(q.taskLabel, 'Linear scale');
    });

    // A multipleChoice really is an MCQ, and must keep reading as one rather
    // than acquiring a second name for the same thing.
    test('multipleChoice still reads as its own label', () {
      expect(
        mcq(<String, dynamic>{'designer_kind': 'multipleChoice'}).taskLabel,
        'Multiple choice',
      );
    });

    test('a question with no kind on the wire still falls back', () {
      expect(mcq(<String, dynamic>{}).taskLabel, QType.mcq.short);
      expect(mcq(<String, dynamic>{'designer_kind': ''}).taskLabel,
          QType.mcq.short);
    });

    // A kind this build cannot draw must not blank the label.
    test('an unknown kind falls back rather than printing nothing', () {
      final Question q = mcq(<String, dynamic>{'designer_kind': 'holoDial'});

      expect(q.designerKind, isNull);
      expect(q.taskLabel, QType.mcq.short);
    });

    // The examiner's own task name still outranks the control, as it does for
    // the engine type - a reviewer needs the task, not the widget.
    test('a template name still wins over the designer kind', () {
      final Question q = mcq(<String, dynamic>{
        'designer_kind': 'rating',
        'source_template': <String, dynamic>{'id': 4, 'name': 'Rate sharpness'},
      });

      expect(q.taskLabel, 'Rate sharpness');
    });
  });
}
