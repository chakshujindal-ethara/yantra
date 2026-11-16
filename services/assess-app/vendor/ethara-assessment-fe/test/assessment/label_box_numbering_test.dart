// Every numbered box must show a READABLE number.
//
// THE DEFECT THIS LOCKS DOWN. Chips were pinned to each box's own top-left
// corner with no regard for the chips already drawn, so overlapping detections
// stacked their chips and the upper one hid the lower. A six-box market image
// rendered as 1,2,3,3,5,6 - one number duplicated, one gone - and a candidate
// asked to categorise "box 4" had no box 4 to look at. The server-side overlay
// (services/imaging.py place_badge) had solved this; the client overlay had not,
// so the SAME question was readable as a baked PNG and unreadable drawn live.
//
// The geometry below is the real draft-199 detection set - a fedora inside a
// person, a sign on a building, apples over a storefront - converted from
// box_2d [ymin,xmin,ymax,xmax] on a 0-1000 grid to the x/y/w/h fractions the
// client overlay consumes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/exam/stimulus.dart';

/// The overlapping set that produced the duplicate on screen.
List<LabelRegion> _marketBoxes() => const <LabelRegion>[
  LabelRegion(number: 1, x: .150, y: .200, w: .250, h: .600),
  LabelRegion(number: 2, x: .250, y: .200, w: .100, h: .100),
  LabelRegion(number: 3, x: .600, y: .150, w: .250, h: .250),
  LabelRegion(number: 4, x: .500, y: .050, w: .450, h: .450),
  LabelRegion(number: 5, x: .450, y: .600, w: .300, h: .250),
  LabelRegion(number: 6, x: .700, y: .100, w: .150, h: .100),
];

List<Rect> _placeAll(List<LabelRegion> boxes, Size size) {
  final List<Rect> placed = <Rect>[];
  for (final LabelRegion r in boxes) {
    final Rect box = Rect.fromLTWH(
      r.x * size.width,
      r.y * size.height,
      r.w * size.width,
      r.h * size.height,
    );
    placed.add(debugPlaceLabelChip(box, 20, 16, placed, size));
  }
  return placed;
}

void main() {
  group('A labelling stimulus overlay', () {
    test('never draws two numbers on the same pixels', () {
      const Size size = Size(800, 600);
      final List<LabelRegion> boxes = _marketBoxes();
      final List<Rect> placed = _placeAll(boxes, size);

      for (int i = 0; i < placed.length; i++) {
        for (int j = i + 1; j < placed.length; j++) {
          expect(
            placed[i].overlaps(placed[j]),
            isFalse,
            reason: 'the chip for box ${boxes[j].number} lands on the chip for '
                'box ${boxes[i].number} - one number would be hidden and the '
                'image would read with a duplicate',
          );
        }
      }
      expect(placed.length, 6);
    });

    test('keeps every chip inside the image', () {
      const Size size = Size(800, 600);
      for (final Rect c in _placeAll(_marketBoxes(), size)) {
        expect(c.left, greaterThanOrEqualTo(0));
        expect(c.top, greaterThanOrEqualTo(0));
        expect(c.right, lessThanOrEqualTo(size.width));
        expect(c.bottom, lessThanOrEqualTo(size.height));
      }
    });

    test('a box in the top-left corner still gets an on-canvas chip', () {
      // "Above the box" is off-canvas here, so the first anchor must be
      // rejected rather than drawn at a negative offset.
      const Size size = Size(400, 300);
      final Rect chip =
          debugPlaceLabelChip(Rect.fromLTWH(0, 0, 40, 40), 20, 16, <Rect>[],
              size);
      expect(chip.top, greaterThanOrEqualTo(0));
      expect(chip.left, greaterThanOrEqualTo(0));
    });

    test('two identical boxes get two different chips', () {
      // The worst case: same geometry twice. Without displacement both numbers
      // occupy the same rect and only one is ever visible.
      const Size size = Size(800, 600);
      final Rect box = Rect.fromLTWH(100, 100, 80, 80);
      final List<Rect> placed = <Rect>[];
      final Rect a = debugPlaceLabelChip(box, 20, 16, placed, size);
      placed.add(a);
      final Rect b = debugPlaceLabelChip(box, 20, 16, placed, size);
      expect(a.overlaps(b), isFalse,
          reason: 'identical boxes must still get distinguishable numbers');
    });

    test('a single box gets the preferred anchor above itself', () {
      // Nothing to avoid, so placement must not wander: the number belongs
      // immediately above its own box.
      const Size size = Size(800, 600);
      final Rect box = Rect.fromLTWH(200, 200, 100, 100);
      final Rect chip = debugPlaceLabelChip(box, 20, 16, <Rect>[], size);
      expect(chip.left, box.left);
      expect(chip.bottom, box.top);
    });
  });
}
