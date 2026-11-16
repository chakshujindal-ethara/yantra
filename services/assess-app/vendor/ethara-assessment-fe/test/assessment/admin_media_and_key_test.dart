// Three ways an ADMIN-side question lost the thing it was opened to show.
//
// All three were found by running real serializer output through the parser,
// not by inventing payloads: `draft_detail(11)` and `bank_question_detail(14,
// 15, 16, 17)` off the live database. The shapes below are trimmed copies.
//
//   1. A generated draft stores its axes as
//      `{"label": ..., "options": ["YES", "NO"], "correct": ["YES"]}`. Every
//      option was cast to a Map, so the cast threw on the first one and the
//      hydration catch discarded the WHOLE draft - the reviewer got a thin
//      list row with no image, no axes and no key, under a "Rendered" badge,
//      plus a "Could not load the full record" toast per card.
//   2. The bank spells the rubric `subjective_rubric`; only the draft's
//      `rubric` was read, so an approved subjective question claimed to have
//      no answer key while the database held a full one.
//   3. Bank media arrives as `admin_url` and nothing read it into `url`.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';

void main() {
  group('A draft axis with bare-string options', () {
    // Verbatim from draft 11, "Task: Perfect Edit Evaluation".
    Map<String, dynamic> draft() => <String, dynamic>{
      'id': 11,
      'name': 'Task: Perfect Edit Evaluation',
      'state': 'draft',
      'question_type': 'image_ab',
      'dimensions': <dynamic>[
        <String, dynamic>{
          'label': 'Q1 Instruction Aligned',
          'options': <dynamic>['YES', 'NO'],
          'correct': <dynamic>['YES'],
        },
        <String, dynamic>{
          'label': 'Q2 Image Aligned (pixel Alignment)',
          'options': <dynamic>['YES', 'NO'],
          'correct': <dynamic>['NO'],
        },
      ],
      'images': <dynamic>[
        <String, dynamic>{
          'slot': 'a',
          'label': 'Response A',
          'data':
              'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYA'
              'AAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
        },
      ],
    };

    test('parses instead of throwing away the whole record', () {
      // The regression in one line: this used to raise "type 'String' is not a
      // subtype of type 'Map<String, dynamic>'", and everything below it -
      // including the image - was lost with it.
      final Question q = Question.fromJson(draft());

      expect(q.images, hasLength(1));
      expect(q.images.single.url, startsWith('data:image/png;base64,'));
    });

    test('keeps the axis name the draft spells as `label`', () {
      final Question q = Question.fromJson(draft());

      expect(q.dims.map((QDimension d) => d.name), <String>[
        'Q1 Instruction Aligned',
        'Q2 Image Aligned (pixel Alignment)',
      ]);
    });

    test('resolves the answer key from the sibling `correct` list', () {
      // Bare strings carry no verdict of their own; the correct option is
      // named beside them, and nothing else in the payload records it.
      final Question q = Question.fromJson(draft());

      final QDimension q1 = q.dims.first;
      expect(q1.options.map((QOption o) => o.label), <String>['YES', 'NO']);
      expect(q1.options.map((QOption o) => o.correct), <bool>[true, false]);

      final QDimension q2 = q.dims[1];
      expect(
        q2.options.map((QOption o) => o.correct),
        <bool>[false, true],
        reason: 'Q2 keys NO, so the verdict must follow the value, not order',
      );
    });

    test('an object-shaped option still works', () {
      final Question q = Question.fromJson(<String, dynamic>{
        'id': 1,
        'dimensions': <dynamic>[
          <String, dynamic>{
            'name': 'Overall Choice (OC)',
            'options': <dynamic>[
              <String, dynamic>{
                'id': 5,
                'label': 'Response A',
                'correct': true,
              },
              <String, dynamic>{'id': 6, 'label': 'Response B'},
            ],
          },
        ],
      });

      final QDimension d = q.dims.single;
      expect(d.options.map((QOption o) => o.label), <String>[
        'Response A',
        'Response B',
      ]);
      expect(d.options.map((QOption o) => o.correct), <bool>[true, false]);
    });
  });

  group('The bank spelling of a rubric', () {
    test('subjective_rubric is read as the answer key', () {
      // Bank 17, "Uncertainty in Alignment", which displayed "No rubric. The
      // generic grader profile applies." over exactly this stored key.
      final Question q = Question.fromJson(<String, dynamic>{
        'id': 17,
        'question_type': 'subjective_rubric',
        'subjective_rubric': <String, dynamic>{
          'checklist': <dynamic>[
            'States that Q2 must be marked as NO',
            'Cites the principle that if unsure, the answer must be NO',
          ],
          'constraints': <dynamic>['Do not assume alignment if uncertain'],
          'pass_condition': 'The response identifies that Q2 should be NO.',
        },
      });

      expect(q.rubric, hasLength(4));
      expect(q.rubric.first, 'States that Q2 must be marked as NO');
    });

    test('the draft spelling keeps precedence', () {
      final Question q = Question.fromJson(<String, dynamic>{
        'id': 1,
        'rubric': <dynamic>['from the draft'],
        'subjective_rubric': <dynamic>['from the bank'],
      });

      expect(q.rubric, <String>['from the draft']);
    });
  });

  group('Bank media', () {
    test('admin_url becomes the asset url', () {
      final Asset a = Asset.fromJson(<String, dynamic>{
        'id': 2,
        'slot': 'reference',
        'label': 'Original Image',
        'admin_url': '/etp_assessment/admin_qimage/2?v=1786452318',
      });

      expect(a.url, '/etp_assessment/admin_qimage/2?v=1786452318');
    });

    test('an empty admin_url counts as no image at all', () {
      // `image_admin_url` computes to False when the record holds no picture
      // and is serialized as "". Taken literally that is a URL which can never
      // load, and the panel would draw a blank frame rather than say so.
      final Asset a = Asset.fromJson(<String, dynamic>{
        'id': 9,
        'slot': 'single',
        'admin_url': '',
      });

      expect(a.url, isNull);
    });

    test('an inline data URL still wins over admin_url', () {
      final Asset a = Asset.fromJson(<String, dynamic>{
        'data': 'data:image/png;base64,AAAA',
        'admin_url': '/etp_assessment/admin_qimage/2',
      });

      expect(a.url, 'data:image/png;base64,AAAA');
    });
  });
}
