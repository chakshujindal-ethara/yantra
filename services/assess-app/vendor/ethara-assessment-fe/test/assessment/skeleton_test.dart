// Chatter write path and loading skeletons.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/widgets/skeleton.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('skeletons stand in for the shape being fetched', () {
    testWidgets('a table skeleton renders one block per cell', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 900,
            height: 600,
            child: TableSkeleton(rows: 4, columns: 5),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Skeleton), findsNWidgets(20));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the KPI strip skeleton renders one card per KPI', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 1200,
            height: 300,
            child: KpiStripSkeleton(count: 5),
          ),
        ),
      );
      await tester.pump();
      // Three blocks per card: label, number, sub.
      expect(find.byType(Skeleton), findsNWidgets(15));
    });

    testWidgets('the chatter skeleton renders a rail line per entry', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 600,
            height: 400,
            child: ChatterSkeleton(lines: 3),
          ),
        ),
      );
      await tester.pump();
      // Three blocks per entry: the rail dot, the author line, the body line.
      // The dot is a Skeleton rather than a plain Container so it pulses with
      // the text instead of sitting still beside it.
      expect(find.byType(Skeleton), findsNWidgets(9));
    });

    testWidgets('a skeleton outside a SkeletonTheme still renders, just flat', (
      WidgetTester tester,
    ) async {
      // Callers should not have to install scaffolding to use one.
      await tester.pumpWidget(host(const Skeleton(width: 40)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(Opacity), findsNothing);
    });

    testWidgets('inside a SkeletonTheme it pulses', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(const SkeletonTheme(child: Skeleton(width: 40))),
      );
      await tester.pump();
      final double first = tester.widget<Opacity>(find.byType(Opacity)).opacity;
      await tester.pump(const Duration(milliseconds: 400));
      final double later = tester.widget<Opacity>(find.byType(Opacity)).opacity;
      expect(
        first,
        isNot(closeTo(later, 0.001)),
        reason: 'a static skeleton reads as a broken screen, not a wait',
      );
      // Never invisible, or the layout looks like it is missing.
      expect(later, greaterThan(0.2));
    });
  });
}
