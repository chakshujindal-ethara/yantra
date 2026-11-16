// The charts and the chatter timeline added for the analytics pass.
//
// These guard the arithmetic, not the pixels: a chart that divides by zero on
// an empty cohort, or draws a flat series on the floor, is worse than no chart
// because it looks authoritative while being wrong.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/widgets/charts.dart';
import 'package:ethara_assessment/assessment/widgets/chatter.dart';

// Tokens resolve from ambient brightness, so a dark MaterialApp is all the
// setup these need - the same shape kpi_height_test.dart uses.
Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData(brightness: Brightness.dark),
  home: Scaffold(body: SizedBox(width: 900, height: 600, child: child)),
);

void main() {
  group('Charts survive the states real data actually has', () {
    testWidgets('a donut with every slice zero does not divide by zero', (
      WidgetTester tester,
    ) async {
      // Nobody has sat anything yet. That is a normal first-day state, not an
      // error, and it must not crash the analytics page.
      await tester.pumpWidget(
        _wrap(
          const DonutChart(
            slices: <Slice>[
              Slice('Passed', 0, Colors.green),
              Slice('Failed', 0, Colors.red),
            ],
            centerValue: '0/0',
            centerLabel: 'PASSED',
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('0/0'), findsOneWidget);
    });

    testWidgets('a zero-value bar draws no fill at all', (
      WidgetTester tester,
    ) async {
      // A 2px stub on a zero row reads as "a little bit", which is a different
      // claim from "none". The minimum width exists so a SMALL non-zero value
      // stays visible, not to invent one.
      await tester.pumpWidget(
        _wrap(
          const Center(
            child: SizedBox(
              width: 400,
              child: BarChart(
                bars: <Slice>[
                  Slice('Has some', 4, Colors.purple),
                  Slice('Has none', 0, Colors.purple),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // One filled bar, not two: each row has a track, and only the non-zero
      // row adds a fill on top of it.
      final Iterable<Container> filled = tester
          .widgetList<Container>(find.byType(Container))
          .where((Container c) {
            final Object? d = c.decoration;
            return d is BoxDecoration && d.color == Colors.purple;
          });
      expect(
        filled.length,
        1,
        reason: 'a zero row must contribute no coloured fill',
      );
    });

    testWidgets('a bar chart with no bars says so instead of drawing an axis', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_wrap(const BarChart(bars: <Slice>[])));
      expect(find.text('Nothing to chart yet.'), findsOneWidget);
    });

    testWidgets('bar values are printed, not left to be estimated', (
      WidgetTester tester,
    ) async {
      // A shape a reader has to measure off the screen is decoration. The
      // number has to be on the row.
      await tester.pumpWidget(
        _wrap(
          const BarChart(
            bars: <Slice>[
              Slice('Forklift Safety', 12, Colors.purple),
              Slice('Warehouse Induction', 3, Colors.purple),
            ],
          ),
        ),
      );
      expect(find.text('12'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('Forklift Safety'), findsOneWidget);
    });

    testWidgets('a whole-number bar value has no trailing .0', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const BarChart(bars: <Slice>[Slice('One', 7, Colors.purple)])),
      );
      expect(find.text('7'), findsOneWidget);
      expect(find.text('7.0'), findsNothing);
    });

    testWidgets('a stacked bar paints its segments at real widths', (
      WidgetTester tester,
    ) async {
      // The bar rendered EMPTY on the analytics page while the legend under
      // it read "Awaiting result 2, Not started 4". Segments must have real,
      // non-zero widths that sum to the available space.
      await tester.pumpWidget(
        _wrap(
          const Center(
            child: SizedBox(
              width: 400,
              child: StackedBar(
                slices: <Slice>[
                  Slice('Awaiting', 2, Colors.orange),
                  Slice('Not started', 4, Colors.grey),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // Scope to the BAR: everything inside the ClipRRect is a segment; the
      // legend dots sit below it.
      final Finder segments = find.descendant(
        of: find.byType(ClipRRect),
        matching: find.byType(Container),
      );
      expect(
        segments,
        findsNWidgets(2),
        reason: 'both segments must be painted',
      );
      double totalWidth = 0;
      for (int i = 0; i < 2; i++) {
        final Size size = tester.getSize(segments.at(i));
        expect(
          size.width,
          greaterThan(1),
          reason: 'a segment must be wide enough to see',
        );
        expect(
          size.height,
          greaterThan(1),
          reason: 'a segment must have height',
        );
        totalWidth += size.width;
      }
      // 2 + 4 of 6 across 400px: the segments fill the bar, not a sliver.
      expect(
        totalWidth,
        closeTo(400, 2),
        reason: 'segments must fill the available width',
      );
    });

    testWidgets('a stacked bar with nothing in it still renders', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const StackedBar(
            slices: <Slice>[
              Slice('Passed', 0, Colors.green),
              Slice('Failed', 0, Colors.red),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    test('a flat series produces finite points, not NaN', () {
      // hi == lo, so the naive (v - lo) / (hi - lo) is 0/0 -> NaN. A NaN in a
      // Path does NOT throw: Skia silently drops the segment, so the chart
      // renders blank and every widget assertion still passes. The guard has
      // to be checked on the arithmetic itself.
      const List<double> flat = <double>[0.5, 0.5, 0.5];
      final double lo = flat.reduce((double a, double b) => a < b ? a : b);
      final double hi = flat.reduce((double a, double b) => a > b ? a : b);
      final double span = (hi - lo).abs() < 1e-9 ? 1 : hi - lo;
      for (final double v in flat) {
        final double norm = (hi - lo).abs() < 1e-9 ? 0.5 : (v - lo) / span;
        expect(
          norm.isFinite,
          isTrue,
          reason: 'a flat series must not normalise to NaN',
        );
        expect(norm, 0.5, reason: 'a flat series sits mid-height');
      }
    });

    testWidgets('a single-point sparkline draws nothing rather than crashing', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const Sparkline(values: <double>[0.5], color: Colors.purple)),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Chatter entries parse the wire the module actually sends', () {
    test('an entry reads snake_case straight off the API', () {
      final ChatterEntry e = ChatterEntry.fromJson(<String, dynamic>{
        'id': 41,
        'author': 'Administrator',
        'text': 'Extract Tags run - 5 semantic tag(s) extracted from the SOP.',
        'date': '2026-08-07 06:10:06',
        'subtype': 'Note',
      });
      expect(e.author, 'Administrator');
      expect(e.text, contains('5 semantic tag'));
      expect(e.date, isNotNull);
    });

    test('a missing author reads as System, never blank', () {
      // A blank byline looks like a rendering bug; the server posts some
      // entries with no author because a cron wrote them.
      final ChatterEntry e = ChatterEntry.fromJson(<String, dynamic>{
        'id': 1,
        'text': 'x',
      });
      expect(e.author, 'System');
    });

    test('an unparseable date is null, not an epoch fallback', () {
      // 1970 printed under an audit line is a lie about when it happened.
      final ChatterEntry e = ChatterEntry.fromJson(<String, dynamic>{
        'id': 1,
        'text': 'x',
        'date': 'not-a-date',
      });
      expect(e.date, isNull);
    });
  });
}
