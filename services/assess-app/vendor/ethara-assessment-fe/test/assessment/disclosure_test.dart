// The fold-away block: one control, not two.
//
// THE BUGS THESE EXIST FOR, both reported from the question sheet:
//
//  1. The chevron drifted. The header was `Flexible(label) + Spacer() + Icon`,
//     and Flexible and Spacer are BOTH flex children, so they shared the free
//     space: a longer label grew into its share and carried the arrow rightward
//     with it. Two stacked disclosures showed their arrows at different x.
//
//  2. Only the words were tappable. The tap sat on the LinkBtn, so clicking
//     the empty space beside the label - or the chevron itself, the part that
//     most looks like the control - did nothing.
library;

import 'package:ethara_assessment/assessment/widgets/disclosure.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A REALISTIC WIDTH. At 600px both labels overflow their flex share and get
// clamped to the same width, so the old buggy layout aligned the chevrons by
// accident and a narrow test passed against it. The drift only appears when
// there is room for a longer label to grow into: measured on the real sheet,
// the two arrows sat at 1171 and 1371.
Widget mount(List<Widget> children) => MaterialApp(
  theme: ThemeData.light(),
  home: Scaffold(
    body: SizedBox(
      width: 1700,
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    ),
  ),
);

void wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('the chevron sits at the same edge whatever the label says', (
    WidgetTester tester,
  ) async {
    wide(tester);
    await tester.pumpWidget(
      mount(<Widget>[
        Disclosure(
          showLabel: 'Show the golden answer',
          builder: (_) => const Text('a'),
        ),
        Disclosure(
          showLabel: 'Show advanced (raw generator output)',
          builder: (_) => const Text('b'),
        ),
      ]),
    );

    expect(find.byIcon(Icons.expand_more), findsNWidgets(2));
    final double a = tester.getRect(find.byIcon(Icons.expand_more).at(0)).right;
    final double b = tester.getRect(find.byIcon(Icons.expand_more).at(1)).right;

    expect(
      a,
      moreOrLessEquals(b, epsilon: 0.5),
      reason: 'a longer label must not drag the chevron rightward',
    );
  });

  testWidgets('tapping the strip beside the label toggles it', (
    WidgetTester tester,
  ) async {
    wide(tester);
    await tester.pumpWidget(
      mount(<Widget>[
        Disclosure(
          showLabel: 'Show the golden answer',
          builder: (_) => const Text('the body'),
        ),
      ]),
    );

    expect(find.text('the body'), findsNothing);

    // Deliberately NOT on the words: just inside the right edge, where the old
    // build had no hit target at all.
    final Rect box = tester.getRect(find.byType(Disclosure));
    await tester.tapAt(Offset(box.right - 40, box.center.dy));
    await tester.pumpAndSettle();

    expect(
      find.text('the body'),
      findsOneWidget,
      reason: 'the whole strip is the control, not only its label',
    );
  });

  testWidgets('tapping the chevron toggles it', (WidgetTester tester) async {
    wide(tester);
    await tester.pumpWidget(
      mount(<Widget>[
        Disclosure(
          showLabel: 'Show the golden answer',
          builder: (_) => const Text('the body'),
        ),
      ]),
    );

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    expect(find.text('the body'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pumpAndSettle();
    expect(find.text('the body'), findsNothing);
  });

  testWidgets('a click inside the opened body does not fold it away', (
    WidgetTester tester,
  ) async {
    wide(tester);
    await tester.pumpWidget(
      mount(<Widget>[
        Disclosure(
          showLabel: 'Show the golden answer',
          builder: (_) => const SizedBox(height: 80, child: Text('the body')),
        ),
      ]),
    );

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();

    await tester.tap(find.text('the body'));
    await tester.pumpAndSettle();

    expect(
      find.text('the body'),
      findsOneWidget,
      reason: 'the body is outside the gesture; reading it must not close it',
    );
  });
}

