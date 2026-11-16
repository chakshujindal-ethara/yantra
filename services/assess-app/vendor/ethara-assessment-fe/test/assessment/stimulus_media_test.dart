// The stimulus pipeline: server bytes -> parsed asset -> painted image.
//
// Four separate breaks sat between a rendered PNG on the server and a blank
// panel in the reviewer's face. Each is guarded here, because none of them
// raised an error - the panel just drew its "has not rendered" empty state
// over an image the API had already sent.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

/// A real 1x1 PNG, base64, as the module returns it.
const String _png1x1 =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
    'C0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

void main() {
  group('An asset reads the key the module actually sends', () {
    test('an inline image arrives under `data`, not `url`', () {
      // The module renders question images itself and returns them inline.
      // Reading `url` alone left every generated image with a null source.
      final Asset a = Asset.fromJson(<String, dynamic>{
        'slot': 'single',
        'label': 'Screenshot',
        'data': _png1x1,
      });
      expect(a.url, _png1x1);
      expect(a.label, 'Screenshot');
    });

    test('an external url still wins when there is no inline data', () {
      final Asset a = Asset.fromJson(<String, dynamic>{
        'url': 'https://example.com/x.png',
      });
      expect(a.url, 'https://example.com/x.png');
    });

    test('the base64 payload decodes to real bytes', () {
      // If this throws, the panel shows its empty state - so the decode has to
      // be proven, not assumed.
      final int comma = _png1x1.indexOf(',');
      final List<int> bytes = base64Decode(_png1x1.substring(comma + 1));
      expect(bytes.length, greaterThan(8));
      // PNG magic number.
      expect(bytes.take(4).toList(), <int>[0x89, 0x50, 0x4E, 0x47]);
    });
  });

  group('Label boxes parse the wire shape', () {
    test('box_2d is read Y-FIRST and scaled from 0-1000', () {
      // The API sends Gemini's convention: [y0, x0, y1, x1] out of 1000.
      // Reading it as x,y transposes every box - plausible on a square image,
      // wrong on every other one.
      final LabelRegion r = LabelRegion.fromJson(<String, dynamic>{
        'number': 3,
        'box_2d': <int>[400, 300, 450, 650],
        'label': 'Search Input',
      });
      expect(r.number, 3);
      expect(r.x, closeTo(0.300, 0.001), reason: 'x comes from index 1');
      expect(r.y, closeTo(0.400, 0.001), reason: 'y comes from index 0');
      expect(r.w, closeTo(0.350, 0.001));
      expect(r.h, closeTo(0.050, 0.001));
    });

    test('a fractional coordinate is not truncated to zero on web', () {
      // `0.0 is int` is true on the JS runtime: an int-first check would round
      // every fraction to 0 and stack all the boxes at the origin.
      final LabelRegion r = LabelRegion.fromJson(<String, dynamic>{
        'number': 1,
        'box_2d': <double>[125.5, 250.5, 375.5, 500.5],
      });
      expect(r.y, closeTo(0.1255, 0.0001));
      expect(r.x, closeTo(0.2505, 0.0001));
    });

    test('the older n/x/y/w/h fixture shape still parses', () {
      final LabelRegion r = LabelRegion.fromJson(<String, dynamic>{
        'n': 2,
        'x': 0.1,
        'y': 0.2,
        'w': 0.3,
        'h': 0.4,
      });
      expect(<num>[r.number, r.x, r.y, r.w, r.h], <num>[2, 0.1, 0.2, 0.3, 0.4]);
    });
  });

  group('A question binds its media to the image it belongs to', () {
    test('label_boxes are attached to the image, not left beside it', () {
      // The API keeps them apart; the UI needs them together, because a box is
      // drawn ON the stimulus. Unattached, the candidate saw a bare screenshot
      // with nothing to label.
      final Question q = Question.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'Label the homepage',
        'question_type': 'image_label',
        'images': <dynamic>[
          <String, dynamic>{'slot': 'single', 'data': _png1x1},
        ],
        'label_boxes': <dynamic>[
          <String, dynamic>{
            'number': 1,
            'box_2d': <int>[0, 0, 500, 500],
          },
          <String, dynamic>{
            'number': 2,
            'box_2d': <int>[500, 500, 900, 900],
          },
        ],
      });
      expect(q.images.length, 1);
      expect(
        q.images.first.regions.length,
        2,
        reason: 'the boxes must land on the image',
      );
      expect(q.images.first.url, _png1x1);
    });

    test('videos arrive under video_files on the wire', () {
      final Question q = Question.fromJson(<String, dynamic>{
        'id': 2,
        'question_type': 'video_prompt',
        'video_files': <dynamic>[
          <String, dynamic>{
            'slot': 'single',
            'data': 'data:video/mp4;base64,AA',
          },
        ],
      });
      expect(q.videos.length, 1);
      expect(q.videos.first.url, startsWith('data:video/mp4'));
    });

    test('dimensions arrive under `dimensions`, not `dims`', () {
      final Question q = Question.fromJson(<String, dynamic>{
        'id': 3,
        'question_type': 'mcq',
        'dimensions': <dynamic>[
          <String, dynamic>{
            'id': 9,
            'name': 'Question 1',
            'options': <dynamic>[
              <String, dynamic>{'id': 1, 'name': 'Yes'},
              <String, dynamic>{'id': 2, 'name': 'No'},
            ],
          },
        ],
      });
      expect(
        q.dims.length,
        1,
        reason: 'an mcq with no parsed dimension has no options to pick',
      );
    });
  });
}
