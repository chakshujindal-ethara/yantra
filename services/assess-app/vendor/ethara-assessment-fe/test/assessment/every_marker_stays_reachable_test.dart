// Every numbered marker on a plate must be readable and clickable - SNo 171.
//
// THE REPORTED DEFECT: "overlapping regions make number badges unreachable". Two
// distinct failures were behind it, and both matter because the answer key is keyed
// BY MARKER NUMBER - a marker an examiner cannot see or select is a mark they cannot
// key, and every unkeyed point is a mark no candidate can earn.
//
//  1. THE BADGE. Every chip was drawn at (box.left, box.top - 16). Markers on the
//     same defect - normal, an examiner marks a cluster of related flaws - drew
//     their chips on exactly the same pixels, so a cluster read as ONE marker with
//     one number and the others were invisible.
//
//  2. THE HIT TEST. `_hit` broke ties with a strict `area < bestArea`, preferring
//     the smallest box so a nested box stays reachable. But click-placed points are
//     all `pointSize` square, so two overlapping points TIE on area, the strict
//     comparison keeps whichever came first in the list, and every other marker in
//     the cluster became permanently unselectable. The examiner could see point 5
//     and only ever select point 4.
//
// HOW THESE TESTS WORK. The chips are painted by a CustomPainter, so there is no
// widget to find - the badge test records real canvas calls through a fake Canvas
// and asserts on the rects that were actually drawn. The hit test is exercised
// through the real gesture path (t.tapAt on the widget), so it proves the behaviour
// an examiner gets, not an internal helper's return value.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/exam/stimulus.dart';

/// A real image, built WITHOUT a codec.
///
/// The overlay draws nothing until its ImageStream reports a size - that is how it
/// knows a fraction of the canvas is a fraction of the picture. Measured with a
/// probe: PNG decoding never completes under the test binding (`instantiateImageCodec`
/// does not resolve even inside `runAsync`), so a MemoryImage leaves the widget
/// permanently in its pre-aspect branch and every marker assertion reads zero.
/// Recording a picture and calling `toImageSync` gives a genuine `ui.Image` with no
/// async at all.
ui.Image squarePlate(int side) {
  final ui.PictureRecorder rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    Paint()..color = const Color(0xFF334455),
  );
  return rec.endRecording().toImageSync(side, side);
}

/// Serves an already-decoded image synchronously, so the overlay has its aspect
/// ratio on the first pump.
class _ReadyImage extends ImageProvider<_ReadyImage> {
  _ReadyImage(this.image);

  final ui.Image image;

  @override
  Future<_ReadyImage> obtainKey(ImageConfiguration c) =>
      SynchronousFuture<_ReadyImage>(this);

  @override
  ImageStreamCompleter loadImage(_ReadyImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(
        SynchronousFuture<ImageInfo>(ImageInfo(image: image)),
      );
}

/// Records every rounded-rect the painter draws, which is how the number chips
/// are rendered. Only the calls this test reasons about are implemented; the rest
/// are swallowed, because a Canvas has a large surface and none of the others
/// carry the fact under test.
class _ChipRecorder implements Canvas {
  final List<RRect> chips = <RRect>[];

  @override
  void drawRRect(RRect rrect, Paint paint) => chips.add(rrect);

  @override
  void noSuchMethod(Invocation invocation) {}
}

Widget host(Widget child, {double side = 400}) => MaterialApp(
  theme: ThemeData(brightness: Brightness.dark),
  home: Scaffold(
    body: Center(
      child: SizedBox(width: side, height: side, child: child),
    ),
  ),
);

/// Mount the overlay and get its image DECODED, which is the precondition for
/// markers existing at all.
///
/// `RegionOverlayImage` renders a plain Image until its ImageStream reports a
/// size - only then does it know that a fraction of the canvas is a fraction of
/// the picture, and only then does it draw markers or hit-test them. Pumping
/// alone never resolves it: real decoding needs the actual async machinery, which
/// in a widget test means `runAsync`.
Future<void> mountOverlay(WidgetTester t, Widget overlay) async {
  await t.pumpWidget(host(overlay));
  await t.pump();
  // Guard the harness itself: every assertion below is vacuous if the widget is
  // still showing its plain-Image fallback.
  expect(find.byType(AspectRatio), findsWidgets,
      reason: 'the overlay has not resolved its image, so it is drawing no '
          'markers and nothing below is being tested');
}

/// The live region painter behind the mounted overlay.
///
/// Scoped to the overlay's subtree: a MaterialApp in a test also mounts a
/// BannerPainter and a placeholder, and picking the first CustomPaint on the page
/// records zero chips while looking like it worked.
CustomPainter overlayPainter(WidgetTester t) => t
    .widgetList<CustomPaint>(find.descendant(
      of: find.byType(RegionOverlayImage),
      matching: find.byType(CustomPaint),
    ))
    .map((CustomPaint c) => c.painter)
    .whereType<CustomPainter>()
    .single;

/// The chips that painter actually draws at [size].
List<Rect> chipsAt(WidgetTester t, Size size) {
  final _ChipRecorder rec = _ChipRecorder();
  overlayPainter(t).paint(rec as Canvas, size);
  return rec.chips.map((RRect r) => r.outerRect).toList();
}

void main() {
  group('the number badges', () {
    testWidgets('two markers on the same defect do not stack their chips',
        (WidgetTester t) async {
      // Two points at very nearly the same place - what an examiner draws when
      // two flaws sit on one feature. Unfixed, both chips land on identical
      // pixels and the plate shows one number for two markers.
      final List<LabelRegion> regions = <LabelRegion>[
        const LabelRegion(number: 1, x: 0.40, y: 0.40, w: 0.035, h: 0.035),
        const LabelRegion(number: 2, x: 0.405, y: 0.402, w: 0.035, h: 0.035),
        const LabelRegion(number: 3, x: 0.41, y: 0.404, w: 0.035, h: 0.035),
      ];

      await mountOverlay(t, RegionOverlayImage(
        provider: _ReadyImage(squarePlate(400)),
        regions: regions,
        onRegionTap: (_) {},
      ));

      final List<Rect> chips = chipsAt(t, const Size(400, 400));
      expect(chips.length, 3, reason: 'one chip per marker');
      for (int i = 0; i < chips.length; i++) {
        for (int j = i + 1; j < chips.length; j++) {
          final Rect a = chips[i];
          final Rect b = chips[j];
          expect(
            a.overlaps(b),
            isFalse,
            reason: 'chip $i ($a) and chip $j ($b) overlap - a cluster whose '
                'numbers sit on top of each other reads as a single marker, '
                'and the answer key is keyed by number',
          );
        }
      }
    });

    testWidgets('a chip never leaves the picture', (WidgetTester t) async {
      // Stepping a chip aside must not push it off the frame: a chip clipped to
      // nothing is the same invisible-number failure by another route. Markers
      // hard against the right edge are the case.
      final List<LabelRegion> regions = <LabelRegion>[
        const LabelRegion(number: 1, x: 0.95, y: 0.5, w: 0.035, h: 0.035),
        const LabelRegion(number: 2, x: 0.955, y: 0.502, w: 0.035, h: 0.035),
        const LabelRegion(number: 3, x: 0.96, y: 0.504, w: 0.035, h: 0.035),
      ];

      await mountOverlay(t, RegionOverlayImage(
        provider: _ReadyImage(squarePlate(400)),
        regions: regions,
        onRegionTap: (_) {},
      ));

      final List<Rect> chips = chipsAt(t, const Size(400, 400));
      expect(chips, isNotEmpty);
      for (final Rect chip in chips) {
        expect(chip.right, lessThanOrEqualTo(400.5),
            reason: 'a chip pushed past the edge is clipped to nothing');
        expect(chip.left, greaterThanOrEqualTo(-0.5));
        expect(chip.top, greaterThanOrEqualTo(-0.5));
        expect(chip.bottom, lessThanOrEqualTo(400.5));
      }
    });

    testWidgets('a number is never dropped, however dense the plate',
        (WidgetTester t) async {
      // THE CEILING CASE. When a plate is dense enough that no candidate
      // position is clear, the chip must still be drawn - an unnumbered box is
      // worse than a crowded one, because the key is keyed by number.
      final List<LabelRegion> regions = <LabelRegion>[
        for (int i = 1; i <= 8; i++)
          LabelRegion(
            number: i,
            x: 0.45 + i * 0.001,
            y: 0.45 + i * 0.001,
            w: 0.035,
            h: 0.035,
          ),
      ];

      await mountOverlay(t, RegionOverlayImage(
        provider: _ReadyImage(squarePlate(400)),
        regions: regions,
        onRegionTap: (_) {},
      ));

      expect(chipsAt(t, const Size(400, 400)).length, 8,
          reason: 'every marker keeps its number even when nothing is clear');
    });
  });

  group('the hit test', () {
    testWidgets('each overlapping point of equal size can be selected',
        (WidgetTester t) async {
      // THE HEADLINE. Three equal-size points overlapping; a tap nearest each
      // one must select THAT one. Unfixed, the strict area comparison returns
      // the first in list order for all three taps.
      final List<LabelRegion> regions = <LabelRegion>[
        const LabelRegion(number: 4, x: 0.30, y: 0.30, w: 0.10, h: 0.10),
        const LabelRegion(number: 5, x: 0.34, y: 0.30, w: 0.10, h: 0.10),
        const LabelRegion(number: 6, x: 0.38, y: 0.30, w: 0.10, h: 0.10),
      ];
      final List<int> tapped = <int>[];

      await mountOverlay(t, RegionOverlayImage(
        provider: _ReadyImage(squarePlate(400)),
        regions: regions,
        onRegionTap: tapped.add,
      ));

      final Rect box = t.getRect(find.byType(RegionOverlayImage));
      // The centre of each region, in widget coordinates. The overlay is square
      // here (1x1 png -> aspect 1), so the whole 400x400 box is the picture.
      for (final LabelRegion r in regions) {
        await t.tapAt(Offset(
          box.left + (r.x + r.w / 2) * box.width,
          box.top + (r.y + r.h / 2) * box.height,
        ));
        await t.pump();
      }

      expect(tapped, <int>[4, 5, 6],
          reason: 'a tap nearest a marker centre must select that marker - '
              'equal-size overlapping points used to all resolve to the first '
              'in list order, leaving the rest permanently unselectable');
    });

    testWidgets('a small box nested in a big one still wins its own taps',
        (WidgetTester t) async {
      // THE PROPERTY THE OLD CODE GOT RIGHT, which the tie-break must not
      // break: smallest-area first, so a box inside a box is still reachable.
      final List<LabelRegion> regions = <LabelRegion>[
        const LabelRegion(number: 1, x: 0.10, y: 0.10, w: 0.70, h: 0.70),
        const LabelRegion(number: 2, x: 0.40, y: 0.40, w: 0.08, h: 0.08),
      ];
      final List<int> tapped = <int>[];

      await mountOverlay(t, RegionOverlayImage(
        provider: _ReadyImage(squarePlate(400)),
        regions: regions,
        onRegionTap: tapped.add,
      ));

      final Rect box = t.getRect(find.byType(RegionOverlayImage));
      // Inside the small box: must be the small one, even though the big box
      // contains this point too and its centre is further away.
      await t.tapAt(Offset(
        box.left + 0.44 * box.width,
        box.top + 0.44 * box.height,
      ));
      await t.pump();
      // Inside the big box only.
      await t.tapAt(Offset(
        box.left + 0.15 * box.width,
        box.top + 0.15 * box.height,
      ));
      await t.pump();

      expect(tapped, <int>[2, 1],
          reason: 'the inner box must not be shadowed by the outer one');
    });

    testWidgets('a tap on empty picture still places a point',
        (WidgetTester t) async {
      // The author gesture has to survive the tie-break change: a tap that
      // misses every marker places a new point rather than selecting one.
      final List<LabelRegion> drawn = <LabelRegion>[];
      final List<int> tapped = <int>[];

      await mountOverlay(t, RegionOverlayImage(
        provider: _ReadyImage(squarePlate(400)),
        regions: const <LabelRegion>[
          LabelRegion(number: 1, x: 0.10, y: 0.10, w: 0.05, h: 0.05),
        ],
        onRegionTap: tapped.add,
        onRegionDrawn: drawn.add,
      ));

      final Rect box = t.getRect(find.byType(RegionOverlayImage));
      await t.tapAt(Offset(
        box.left + 0.80 * box.width,
        box.top + 0.80 * box.height,
      ));
      await t.pump();

      expect(tapped, isEmpty, reason: 'nothing was under that tap');
      expect(drawn, hasLength(1));
      expect(drawn.single.number, 0,
          reason: 'the caller assigns the real number');
    });
  });
}
