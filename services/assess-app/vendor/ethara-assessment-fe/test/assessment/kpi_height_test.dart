// What height does a KPI card actually need?
//
// The card has a FIXED height so a row of them shares one baseline. That
// number has to come from measurement, not arithmetic: computing it from the
// nominal type scale (11 * 1.2 + 30 * 1.1 + ...) under-reads, because real
// font ascent and descent exceed the nominal line box. Two guesses overflowed
// by 13px and then 5px before this test was written.
//
// This measures the tallest legitimate card and asserts the constant covers
// it, so changing a type token or adding a taller variant fails here instead
// of painting a yellow overflow stripe in the UI.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';

void main() {
  testWidgets('a KPI card fits its fixed height, sub-line or not', (
    WidgetTester tester,
  ) async {
    // A wide surface: the concern is vertical fit, and a narrow one would
    // ellipsize the label and mask the very overflow being measured.
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Tokens resolve from ambient brightness, so a dark MaterialApp is all
    // the theming this needs.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: KpiStrip(<Widget>[
              // No sub-line: the shortest card.
              Kpi(label: 'Assessments', value: '12'),
              // With a sub-line: the tallest legitimate card.
              Kpi(
                label: 'Awaiting release',
                value: '3',
                sub: 'held until a person releases them',
              ),
            ]),
          ),
        ),
      ),
    );

    // An overflow is reported as an exception during layout, so a clean pump
    // IS the assertion. Stated explicitly so the failure reads properly.
    expect(
      tester.takeException(),
      isNull,
      reason: 'a KPI card overflowed its fixed height',
    );

    // Both cards must agree, or the row is ragged again.
    final Iterable<RenderBox> boxes = tester.renderObjectList<RenderBox>(
      find.byType(Kpi),
    );
    final Set<double> heights = boxes
        .map((RenderBox b) => b.size.height)
        .toSet();
    expect(
      heights.length,
      1,
      reason: 'KPI cards must share one height; found $heights',
    );
  });
}
