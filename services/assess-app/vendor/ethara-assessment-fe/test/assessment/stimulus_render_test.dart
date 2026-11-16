// Does the stimulus actually PAINT, given a payload the server really sent?
//
// Parsing is already proven (draft_image_test.dart): `data` is read, the
// missing `id` is tolerated, `box_2d` normalises. Yet the card drew an empty
// frame under a badge reading "Rendered". So the failure is downstream of
// parsing, in the widget that chooses what to draw - which is what this pins.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/exam/stimulus.dart';

/// A real 1x1 PNG as the module emits it: a `data:` URL under `data`.
const String kPng =
    'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

Map<String, dynamic> draftPayload() => <String, dynamic>{
  'id': 76,
  'name': 'Task: Label Wikipedia Homepage UI',
  'question_type': 'image_label',
  'state': 'draft',
  'image_state': 'rendered',
  'prompt': 'Review the application screenshot.',
  'images': <dynamic>[
    <String, dynamic>{'slot': 'single', 'label': 'Screenshot', 'data': kPng},
  ],
  'label_boxes': <dynamic>[
    <String, dynamic>{
      'number': 1,
      'box_2d': <int>[400, 300, 450, 650],
      'label': 'Search Input',
    },
  ],
};

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: SizedBox(width: 800, height: 600, child: child)),
);

void main() {
  testWidgets('a parsed data-URL asset paints an Image, not a placeholder', (
    WidgetTester tester,
  ) async {
    final Question q = Question.fromJson(draftPayload());
    final Asset a = q.images.first;

    await tester.pumpWidget(host(StimulusArt(asset: a, showRegions: true)));
    await tester.pump();

    // The real check: an actual raster, not the hand-drawn fallback painter
    // that stands in when there is no image.
    expect(
      find.byType(Image),
      findsOneWidget,
      reason: 'the server sent a PNG; the widget must decode and draw it',
    );
  });

  testWidgets('the plate renders the image inside its frame', (
    WidgetTester tester,
  ) async {
    final Question q = Question.fromJson(draftPayload());
    await tester.pumpWidget(
      host(
        StimulusPlate(
          asset: q.images.first,
          caption: q.images.first.label,
          showRegions: true,
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byType(Image),
      findsOneWidget,
      reason: 'the review card draws the plate; a blank frame is the bug',
    );
  });

  testWidgets('the plate fits a SHORT box instead of overflowing it', (
    WidgetTester tester,
  ) async {
    // The review card gives the plate a bounded, shortish box. A Column that
    // claims max height puts the 4:3 plate past the bottom edge, where it is
    // clipped away - the image is "there" and invisible, which is exactly what
    // the operator saw. 180px is tighter than 4:3 wants at this width.
    final Question q = Question.fromJson(draftPayload());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              height: 180,
              child: StimulusPlate(
                asset: q.images.first,
                caption: q.images.first.label,
                showRegions: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.takeException(),
      isNull,
      reason: 'a RenderFlex overflow here is the blank-frame bug',
    );
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('an asset with no image falls back without throwing', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        const StimulusArt(
          asset: Asset(id: 'x', label: 'none'),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a malformed data URL does not throw inside build', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        const StimulusArt(
          asset: Asset(
            id: 'x',
            label: 'bad',
            url: 'data:image/png;base64,!!!!',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.takeException(),
      isNull,
      reason: 'a bad payload must degrade, not crash the review queue',
    );
  });
}
