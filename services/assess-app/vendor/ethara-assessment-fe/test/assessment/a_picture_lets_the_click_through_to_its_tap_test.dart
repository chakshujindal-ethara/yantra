// A picture shown by `ImagePlate` is an `<img>` in a platform view. Flutter
// mounts it inside a `flt-platform-view` host, and that host takes the pointer
// unless it is switched off - so a click on a proctoring snapshot never reached
// the tap that opens the viewer (21 Oct 2026). Tests in the VM and screen-reader
// mode route around the host, so this runs in a browser:
//
//   flutter test --platform chrome test/assessment/a_picture_lets_the_click_through_to_its_tap_test.dart
@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'package:ethara_assessment/assessment/screens/exam/image_plate_web.dart';

void main() {
  test('the host a picture is mounted in lets the pointer through', () async {
    final web.HTMLDivElement host = web.HTMLDivElement();
    final web.HTMLImageElement img = web.HTMLImageElement();
    passHostPointersThrough(img);
    // Flutter mounts the element in its host right after the factory returns.
    host.appendChild(img);
    await Future<void>.delayed(Duration.zero);

    expect(
      host.style.pointerEvents,
      'none',
      reason: 'the flt-platform-view host must not take the click',
    );
  });

  // AND FLUTTER LETS IT REACH THE TAP. The platform view would otherwise win
  // the tap in the gesture arena: a click on the picture did nothing, a click
  // on its caption opened the viewer.
  testWidgets('a tap on the picture reaches the tap around it', (
    WidgetTester t,
  ) async {
    int taps = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Center(
          // As the snapshot tile does: the tap around a plate on a painted
          // box (ColoredBox hit-tests itself).
          child: GestureDetector(
            onTap: () => taps++,
            child: const ColoredBox(
              color: Color(0xFF000000),
              child: SizedBox(
                width: 160,
                height: 120,
                child: ImagePlate(url: 'about:blank'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tapAt(t.getCenter(find.byType(ImagePlate)));
    expect(taps, 1);
    expect(
      find.ancestor(
        of: find.byType(HtmlElementView),
        matching: find.byWidgetPredicate(
          (Widget w) => w is IgnorePointer && w.ignoring,
        ),
      ),
      findsOneWidget,
    );
  });
}
