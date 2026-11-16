// The answer sheet has to show the question, not just the answer to it.
//
// THE BUG THIS EXISTS FOR. `released_answer_review_row` was the only
// serializer in the module that rendered a question to a candidate with the
// pictures stripped out - no `images`, no `videos`, no `label_boxes` - and
// `AnswerSheetRow` had no field for them either, so both halves had to be
// added before anything could render.
//
// What the candidate saw: an image_ab row printing "Response A, Both Good,
// Both Good, Response A" over nothing at all, and a labelling row as a
// numbered list of typed descriptions with no screenshot above it. The
// verdict, the score and the judge's feedback all referred to a picture the
// review screen never showed.
//
// The media is NOT gated on release, and one test below pins that: the
// candidate was shown these while sitting the exam. Withholding them
// afterwards would hide the thing every other field on the row talks about.
@TestOn('vm')
library;

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// A review row in the shape `released_answer_review_row` now sends it -
/// snake_case, token-scoped portal URLs, `label_boxes` beside the image
/// rather than inside it.
Map<String, dynamic> reviewRow({
  bool withMedia = true,
  List<int> boxes = const <int>[],
}) => <String, dynamic>{
  'index': 2,
  'question_id': 41,
  'name': 'Pair check',
  'prompt': 'A golden retriever wearing a red bandana.',
  'question_type': 'image_ab',
  'chosen': <String>['Response A', 'Both Good'],
  'correct': <String>['Response A'],
  'verdict': 'Passed',
  'kind': 'pass',
  if (withMedia) ...<String, dynamic>{
    'images': <dynamic>[
      <String, dynamic>{
        'id': 7,
        'slot': 'a',
        'label': 'Response A',
        'url': '/assessments_be/exam/qimage/tok/7',
        'annotated_url': '',
        'has_annotated': false,
      },
      <String, dynamic>{
        'id': 8,
        'slot': 'b',
        'label': 'Response B',
        'url': '/assessments_be/exam/qimage/tok/8',
        'annotated_url': '',
        'has_annotated': false,
      },
    ],
    'videos': <dynamic>[
      <String, dynamic>{
        'id': 3,
        'slot': 'single',
        'label': 'Reference clip',
        'url': '/assessments_be/exam/qvideo/tok/3',
        'poster_url': '',
        'duration_s': 6.0,
        'has_audio': true,
      },
    ],
    'label_boxes': boxes,
  },
};

void main() {
  group('a review row carries its media', () {
    test('images and videos come off the wire in order', () {
      final AnswerSheetRow row = AnswerSheetRow.fromJson(
        reviewRow(),
        released: true,
      );

      expect(row.hasMedia, isTrue);
      expect(row.images.length, 2);
      expect(row.videos.length, 1);
      // The caption is the only thing saying which plate is which on a pair;
      // dropping it lets a candidate read the comparison backwards.
      expect(row.images.map((Asset a) => a.label), <String>[
        'Response A',
        'Response B',
      ]);
      expect(row.videos.single.label, 'Reference clip');
    });

    test('the token-scoped exam URL survives parsing', () {
      final AnswerSheetRow row = AnswerSheetRow.fromJson(
        reviewRow(),
        released: true,
      );

      // Same public, token-scoped route the live exam used. If this ever
      // becomes an admin_url the candidate gets a 403 instead of a picture.
      expect(row.images.first.url, '/assessments_be/exam/qimage/tok/7');
      expect(row.videos.single.url, '/assessments_be/exam/qvideo/tok/3');
    });

    test('label boxes attach to the first image, as in the live exam', () {
      final AnswerSheetRow row = AnswerSheetRow.fromJson(
        reviewRow(boxes: const <int>[1, 2, 3]),
        released: true,
      );

      // `_assetsWithBoxes` merges `label_boxes` onto image[0]. Parsing them as
      // bare ints must not throw, and must not silently drop the image.
      expect(row.images, isNotEmpty);
      expect(row.images.first.url, isNotEmpty);
    });

    test('MEDIA IS NOT GATED ON RELEASE', () {
      // The question is not the answer key. `correct` and `verdict` are
      // withheld before release; the picture the candidate already sat in
      // front of is not.
      final AnswerSheetRow row = AnswerSheetRow.fromJson(
        reviewRow(),
        released: false,
      );

      expect(row.images.length, 2, reason: 'the stimulus is not the key');
      expect(row.videos.length, 1);
      expect(row.correct, isEmpty, reason: 'the key still waits for release');
      expect(row.verdict, isEmpty);
    });

    test('a row with no media says so rather than throwing', () {
      // An mcq review row legitimately has nothing to show, and must not be
      // reported as a broken question the way a live one would be.
      final AnswerSheetRow row = AnswerSheetRow.fromJson(
        reviewRow(withMedia: false),
        released: true,
      );

      expect(row.hasMedia, isFalse);
      expect(row.images, isEmpty);
      expect(row.videos, isEmpty);
    });
  });
}
