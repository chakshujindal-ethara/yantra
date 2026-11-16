// UI-report fixes, pinned so they cannot silently regress.
//
// Each group corresponds to a reported defect. The mutation battery in the
// session notes confirms every expect here fails when its fix is reverted.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/exam/stimulus.dart';
import 'package:ethara_assessment/assessment/widgets/data_grid.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';

/// A real 1x1 PNG as the module emits it.
const String kPng =
    'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

Widget host(Widget child, {double width = 1600, double height = 700}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(width: width, height: height, child: child),
      ),
    );

/// Widen the test surface.
///
/// `flutter_test` pins the window to 800x600, so a `SizedBox(width: 1600)`
/// inside it is CLIPPED to 800 and every layout measurement comes back 800 -
/// which silently invalidates any "is this at the right edge" assertion. The
/// view has to be resized for real.
Future<void> setSurface(WidgetTester tester, double w, double h) async {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('stimulus image does not flicker', () {
    testWidgets('the same data URL yields the SAME byte list across rebuilds', (
      WidgetTester tester,
    ) async {
      // The flicker: every rebuild decoded the base64 afresh, so `Image.memory`
      // saw a new cache key, dropped the painted frame and re-decoded ~3.7MB.
      // Identical bytes across rebuilds is what keeps the key stable.
      final Asset a = Asset(id: 'x', label: 'Shot', url: kPng);

      await tester.pumpWidget(host(StimulusArt(asset: a)));
      await tester.pump();
      final Image first = tester.widget<Image>(find.byType(Image));

      // Force a rebuild the way the 2s store refresh does.
      await tester.pumpWidget(host(StimulusArt(asset: a)));
      await tester.pump();
      final Image second = tester.widget<Image>(find.byType(Image));

      // The BYTES must be the same instance - that is what keeps the image
      // cache key stable. (`MemoryImage` itself is a fresh wrapper each build
      // but compares equal, so `same()` on the provider proves nothing.)
      expect(
        (first.image as MemoryImage).bytes,
        same((second.image as MemoryImage).bytes),
        reason: 'a re-decode on rebuild is the flicker',
      );
      expect(
        first.image,
        equals(second.image),
        reason: 'equal providers hit the image cache instead of re-decoding',
      );
    });

    testWidgets('gaplessPlayback is on, so a rebuild never flashes empty', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          StimulusArt(
            asset: Asset(id: 'x', label: 'S', url: kPng),
          ),
        ),
      );
      await tester.pump();
      expect(tester.widget<Image>(find.byType(Image)).gaplessPlayback, isTrue);
    });

    testWidgets('a malformed data URL still degrades, not throws', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const StimulusArt(
            asset: Asset(
              id: 'x',
              label: 'bad',
              url: 'data:image/png;base64,!!!',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(Image), findsNothing);
    });
  });

  group('page actions sit at the right edge', () {
    testWidgets('a head action is flush right, not mid-page', (
      WidgetTester tester,
    ) async {
      // The bug: heading (Expanded) and actions (Flexible) both defaulted to
      // flex 1, so they split the row 50/50 and `WrapAlignment.end` aligned the
      // button to the middle of the page rather than its edge.
      const double width = 1000;
      await setSurface(tester, width, 700);
      await tester.pumpWidget(
        host(
          const PageBody(
            children: <Widget>[
              PageHead(
                'Generators',
                actions: <Widget>[
                  SizedBox(width: 160, height: 32, child: Placeholder()),
                ],
              ),
            ],
          ),
          width: width,
        ),
      );
      await tester.pump();

      final double actionRight = tester
          .getBottomRight(find.byType(Placeholder))
          .dx;

      // Flush against the page's own right edge. Under the old 50/50 split the
      // button landed at ~width/2 + its own width, i.e. nowhere near this.
      expect(
        actionRight,
        closeTo(width, 1.0),
        reason: 'the action must reach the content edge',
      );
      expect(
        actionRight,
        greaterThan(width * 0.8),
        reason: 'mid-page placement is the reported defect',
      );
    });

    testWidgets('a wide page is left-aligned, not a narrow centred column', (
      WidgetTester tester,
    ) async {
      await setSurface(tester, 1600, 700);
      await tester.pumpWidget(
        host(
          const PageBody(children: <Widget>[PageHead('Generators')]),
          width: 1600,
        ),
      );
      await tester.pump();
      expect(tester.getTopLeft(find.byType(PageBody)).dx, 0);
      // And it fills the room it is given rather than stopping at 1320.
      expect(tester.getSize(find.byType(PageHead)).width, 1600);
    });

    testWidgets('narrow pages stay centred for a reading measure', (
      WidgetTester tester,
    ) async {
      await setSurface(tester, 1600, 700);
      await tester.pumpWidget(
        host(
          const PageBody(narrow: true, children: <Widget>[PageHead('About')]),
          width: 1600,
        ),
      );
      await tester.pump();
      // 900 wide inside 1600 leaves 350 either side, so the head is inset and
      // narrower than the viewport.
      expect(tester.getSize(find.byType(PageHead)).width, 900);
      expect(tester.getTopLeft(find.byType(PageHead)).dx, closeTo(350, 1.0));
    });
  });

  group('a table row opens its record', () {
    testWidgets('GridRow.onTap fires from the row, with no View button', (
      WidgetTester tester,
    ) async {
      int taps = 0;
      await tester.pumpWidget(
        host(
          DataGrid(
            cols: const <Col>[Col('Draft', flex: 3), Col('State', width: 120)],
            rows: <GridRow>[
              GridRow(const <Widget>[
                Text('Task: Label Wikipedia'),
                Text('Awaiting'),
              ], onTap: () => taps++),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text('View'),
        findsNothing,
        reason: 'the row is the click target now',
      );
      await tester.tap(find.text('Task: Label Wikipedia'));
      await tester.pump();
      expect(taps, 1);
    });
  });
}
