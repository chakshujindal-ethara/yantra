// Does a REAL /api/v1/drafts/<id> payload reach the screen as a drawable
// image? The stimulus panel rendered an empty frame under a badge that
// correctly read "Rendered", so the question is where the PNG is lost:
// parsing, or the widget's own choice of what to draw.
//
// The payload shape here is copied from the live backend, not invented: the
// image carries `data` (a base64 data URL), no `id` and no `url`, and the
// boxes arrive BESIDE it under `label_boxes`.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

/// A trimmed copy of the real draft 76 payload.
Map<String, dynamic> livePayload() => <String, dynamic>{
  'id': 76,
  'name': 'Task: Label Wikipedia Homepage UI',
  'generator': <String, dynamic>{'id': 59, 'name': 'test'},
  'state': 'draft',
  'question_type': 'image_label',
  'image_state': 'rendered',
  'prompt': 'Review the application screenshot.',
  'images': <dynamic>[
    <String, dynamic>{
      'slot': 'single',
      'label': 'Screenshot',
      // A 1x1 PNG: short, but a genuine data URL of the same shape.
      'data':
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYA'
          'AAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    },
  ],
  'label_boxes': <dynamic>[
    <String, dynamic>{
      'number': 1,
      'box_2d': <int>[400, 300, 450, 650],
      'label': 'Search Input',
      'description': 'Accepts text input for search query',
    },
    <String, dynamic>{
      'number': 2,
      'box_2d': <int>[400, 660, 450, 700],
      'label': 'Language Dropdown',
      'description': 'Opens language selection menu',
    },
  ],
  // The module sends the rubric as an OBJECT. Casting it to a list threw
  // mid-parse, the store swallowed the error, and the whole hydrated
  // record was discarded - taking the image with it.
  'rubric': <String, dynamic>{
    'ideal_labels': '1. Accepts text input for search query',
    'mandatory_elements': <String>['Action-based language'],
  },
};

void main() {
  group('draft image reaches the screen', () {
    test('a real draft payload parses without throwing', () {
      // The whole bug in one line: this used to throw a TypeError, which the
      // store caught silently and turned into "no image".
      expect(() => Question.fromJson(livePayload()), returnsNormally);
    });

    test('an object-shaped rubric becomes display lines', () {
      final Question q = Question.fromJson(livePayload());
      expect(
        q.rubric,
        isNotEmpty,
        reason: 'the module sends a Map here, not a List',
      );
      expect(q.rubric.join(' '), contains('Accepts text input'));
    });

    test('a list-shaped rubric still works', () {
      // The fixtures use the plain list form; both shapes must parse.
      final Map<String, dynamic> j = livePayload()
        ..['rubric'] = <dynamic>['First criterion', 'Second criterion'];
      expect(Question.fromJson(j).rubric, <String>[
        'First criterion',
        'Second criterion',
      ]);
    });

    test('the image is parsed off `data`, which carries no id and no url', () {
      final Question q = Question.fromJson(livePayload());

      expect(
        q.images,
        hasLength(1),
        reason: 'the server sent one image; it must survive parsing',
      );
      expect(q.images.first.url, isNotNull);
      expect(
        q.images.first.url,
        startsWith('data:image/png;base64,'),
        reason: 'the data URL is what Image.memory decodes',
      );
    });

    test('an image with no `id` still renders', () {
      // The live payload omits `id` entirely. If anything downstream keys off
      // it, the plate silently falls back to the placeholder painter.
      final Map<String, dynamic> j = livePayload();
      expect((j['images']! as List<dynamic>).first, isNot(contains('id')));

      final Question q = Question.fromJson(j);
      final Asset a = q.images.first;
      expect(
        a.url,
        isNotNull,
        reason: 'a missing id must not blank the stimulus',
      );
    });

    test('label boxes are attached to the image, not left beside it', () {
      final Question q = Question.fromJson(livePayload());
      expect(
        q.images.first.regions,
        hasLength(2),
        reason: 'box_2d arrives under label_boxes and must be attached',
      );
      expect(q.images.first.regions.first.number, 1);
    });

    test('box_2d is read Y-first in 0-1000 and normalised to fractions', () {
      final Question q = Question.fromJson(livePayload());
      final LabelRegion r = q.images.first.regions.first;
      // box_2d = [yMin, xMin, yMax, xMax] = [400, 300, 450, 650].
      expect(r.y, closeTo(0.400, 0.001));
      expect(r.x, closeTo(0.300, 0.001));
      expect(r.h, closeTo(0.050, 0.001));
      expect(r.w, closeTo(0.350, 0.001));
    });

    test('the question reports itself as having a rendered stimulus', () {
      final Question q = Question.fromJson(livePayload());
      expect(q.type, QType.imageLabel);
      expect(
        q.imageState,
        AssetState.rendered,
        reason: 'the badge reads Rendered; the panel must agree',
      );
    });
  });
}
