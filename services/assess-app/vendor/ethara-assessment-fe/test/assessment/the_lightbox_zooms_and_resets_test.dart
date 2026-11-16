// The picture lightbox: Zoom in, Zoom out and Reset move the view and put it
// back, Close shuts it, and a single picture opens the same way a gallery
// does (`showImageLightbox`, which the annotation plate uses).
@TestOn('vm')
library;

import 'package:ethara_assessment/assessment/screens/admin/zoomable_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _scale(WidgetTester t) => t
    .widget<InteractiveViewer>(find.byType(InteractiveViewer))
    .transformationController!
    .value
    .getMaxScaleOnAxis();

void main() {
  testWidgets('zoom in, out, reset, close', (WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showImageLightbox(context, ''),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await t.tap(find.text('Open'));
    await t.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(_scale(t), closeTo(1.0, 1e-9));

    await t.tap(find.byTooltip('Zoom in'));
    await t.pump();
    await t.tap(find.byTooltip('Zoom in'));
    await t.pump();
    expect(_scale(t), closeTo(1.96, 1e-6));

    await t.tap(find.byTooltip('Zoom out'));
    await t.pump();
    expect(_scale(t), closeTo(1.4, 1e-6));

    await t.tap(find.byTooltip('Reset'));
    await t.pump();
    expect(_scale(t), closeTo(1.0, 1e-9));

    // Never below the whole picture.
    await t.tap(find.byTooltip('Zoom out'));
    await t.pump();
    expect(_scale(t), closeTo(1.0, 1e-9));

    await t.tap(find.byTooltip('Close'));
    await t.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });
}
