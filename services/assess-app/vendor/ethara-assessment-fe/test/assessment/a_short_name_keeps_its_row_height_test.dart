// A name that FITS its column must keep the row it is in exactly as it is.
//
// THE BASELINE FOR D5. `GridLink` hardcodes `maxLines: 1`, so a long name is
// cropped to one ellipsised line and the part that distinguishes two similar
// records is the part that disappears. The fix lets it wrap to a second line -
// and `GridLink` is the primary cell of every grid in 23 admin screens, so the
// change is only safe if the ordinary case is untouched.
//
// This is that ordinary case, MEASURED rather than assumed: one line, a 40px
// row, and every column starting where it started. Recorded against unfixed
// code, so it describes today rather than hoping about tomorrow.
//
// The geometry comes from `data_grid.dart`, not from magic numbers: a cell is
// `BoxConstraints(minHeight: 40)` with `EdgeInsets.symmetric(vertical: 8)`, so
// one line of `bodySm` (13px at 1.45 => 19px) is 35px of content and the 40px
// floor is what decides the row.
//
// EVERY CELL IN THIS FIXTURE IS SHORT. Measured with a probe, the test
// environment's fallback face advances a full em per glyph, so 'Submitted' in a
// 120px column is 126px and wraps - which grew the row to 57px and would have
// had this baseline recording the wrong number as the truth.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/widgets/data_grid.dart';
import 'package:ethara_assessment/core/theme/portal_type.dart';

/// The row floor `_Row` applies when no `rowHeight` is passed.
const double kRowFloor = 40;

/// Short enough to fit its column in any font: 7 glyphs of 13px is ~91px
/// against a ~570px column.
const String kShortName = 'Ana Rao';

Widget host(Widget child, {double width = 900}) => MaterialApp(
  theme: ThemeData(brightness: Brightness.dark),
  home: Scaffold(
    body: Center(child: SizedBox(width: width, child: child)),
  ),
);

/// Two rows, so row height is the distance between them rather than something
/// inferred from a private widget's constraints.
Widget grid() => host(
  DataGrid(
    minWidth: 600,
    cols: const <Col>[Col('Candidate', flex: 1), Col('State', width: 120)],
    rows: <GridRow>[
      GridRow(const <Widget>[GridLink(kShortName), Text('Sent')]),
      GridRow(const <Widget>[GridLink('Bo Li'), Text('Held')]),
    ],
  ),
);

/// The height ONE line of a grid cell occupies, laid out with no width limit so
/// it cannot itself have wrapped.
///
/// Derived from `PortalType.bodySm`, the style `tableCell` and therefore
/// `GridLink` resolve to, so a change to the type scale carries this with it
/// instead of turning into a mystery failure.
double get oneLine {
  final TextPainter tp = TextPainter(
    text: TextSpan(
      text: kShortName,
      style: PortalType.bodySm(
        const Color(0xFFFFFFFF),
      ).copyWith(fontWeight: FontWeight.w600),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final double h = tp.height;
  tp.dispose();
  return h;
}

/// Long enough to exceed any column this grid offers it: 39 glyphs.
const String kLongName = 'DEMO-SOP Forklift Safety Assessment (co)';

/// One row, one narrow column, so the cell has to make a decision about a name
/// that does not fit.
Widget cropped({int? maxLines}) => host(
  DataGrid(
    minWidth: 300,
    cols: const <Col>[Col('Candidate', width: 160), Col('State', width: 80)],
    rows: <GridRow>[
      GridRow(<Widget>[
        maxLines == null
            ? const GridLink(kLongName)
            : GridLink(kLongName, maxLines: maxLines),
        const Text('Sent'),
      ]),
    ],
  ),
  width: 400,
);

void main() {
  testWidgets('a name that fits renders on ONE line', (WidgetTester t) async {
    await t.pumpWidget(grid());
    await t.pump();

    final RenderParagraph p = t.renderObject<RenderParagraph>(
      find.text(kShortName),
    );
    expect(p.didExceedMaxLines, isFalse);
    expect(
      p.text.toPlainText(),
      kShortName,
      reason: 'nothing is elided from a name that fits',
    );
    // A paragraph that wrapped would be a whole line taller than its own
    // unconstrained layout. Expressed this way rather than as a pinned pixel
    // count, so it holds whatever font the environment supplies.
    expect(
      p.size.height,
      closeTo(oneLine, 0.5),
      reason: 'a short name has no reason to wrap: rendered '
          '${p.size.height} against a single line of $oneLine',
    );
  });

  testWidgets('the row keeps its 40px height', (WidgetTester t) async {
    await t.pumpWidget(grid());
    await t.pump();

    final double first = t.getCenter(find.text(kShortName)).dy;
    final double second = t.getCenter(find.text('Bo Li')).dy;

    expect(
      second - first,
      closeTo(kRowFloor, 0.5),
      reason: 'the 40px floor sets the height of a one-line row, and letting '
          'long names wrap must not lift it for short ones',
    );
  });

  testWidgets('column alignment holds', (WidgetTester t) async {
    await t.pumpWidget(grid());
    await t.pump();

    // Widths do not change when a cell grows taller, so the left edge of each
    // column is what proves alignment survived.
    expect(
      t.getTopLeft(find.text(kShortName)).dx,
      t.getTopLeft(find.text('Bo Li')).dx,
      reason: 'both name cells start at the same x',
    );
    expect(
      t.getTopLeft(find.text('Sent')).dx,
      t.getTopLeft(find.text('Held')).dx,
      reason: 'and so do both cells of the fixed-width column',
    );
    // The fixed-width column sits to the RIGHT of the flexible one, which is
    // the order `cols` declares.
    expect(
      t.getTopLeft(find.text('Sent')).dx,
      greaterThan(t.getTopLeft(find.text(kShortName)).dx),
    );

    // Cells are centred within the row (`Align(centerLeft)`), so two cells of
    // different heights share a centre line. That is what keeps a row reading
    // as one record rather than two half-rows.
    expect(
      t.getCenter(find.text('Sent')).dy,
      closeTo(t.getCenter(find.text(kShortName)).dy, 0.5),
    );
  });

  // ── THE FIX ITSELF ────────────────────────────────────────────────────────

  group('a name that does NOT fit', () {
    testWidgets('wraps to a second line', (WidgetTester t) async {
      await t.pumpWidget(cropped());
      await t.pump();

      final RenderParagraph p = t.renderObject<RenderParagraph>(
        find.text(kLongName),
      );
      expect(
        p.size.height,
        greaterThan(oneLine + 1),
        reason: 'one line cropped the part that tells two similar records '
            'apart, which is the defect: rendered ${p.size.height} against a '
            'single line of $oneLine',
      );
      // TWO lines, not unbounded. A cell that grew without limit would push
      // every row apart on a table of long names.
      expect(p.size.height, lessThan(oneLine * 3));
    });

    testWidgets('carries the full name in a tooltip', (WidgetTester t) async {
      await t.pumpWidget(cropped());
      await t.pump();

      // Two lines still are not always enough - 39 glyphs in a 160px column is
      // one such case - so hover is the guarantee that nothing is unrecoverable.
      expect(
        t.widgetList<Tooltip>(find.byType(Tooltip)).map((Tooltip x) => x.message),
        contains(kLongName),
      );
    });

    testWidgets('maxLines: 1 crops exactly as it did before', (
      WidgetTester t,
    ) async {
      await t.pumpWidget(cropped(maxLines: 1));
      await t.pump();

      final RenderParagraph p = t.renderObject<RenderParagraph>(
        find.text(kLongName),
      );
      expect(
        p.size.height,
        closeTo(oneLine, 0.5),
        reason: 'the three fixed-rowHeight dashboard grids depend on this: '
            'their cells are CLIPPED rather than grown, and their panels have '
            'a fixed body height',
      );
      expect(
        p.didExceedMaxLines,
        isTrue,
        reason: 'still ellipsised, which is what the tooltip is for',
      );
      // The opt-out keeps the tooltip: cropping without a way to read the rest
      // is the defect, whatever the line count.
      expect(
        t.widgetList<Tooltip>(find.byType(Tooltip)).map((Tooltip x) => x.message),
        contains(kLongName),
      );
    });

    testWidgets('an empty cell gets no tooltip', (WidgetTester t) async {
      // A name can be missing - `personById(...)?.name ?? employeeId` can
      // resolve to ''. A tooltip with an empty message is an empty black box
      // chasing the pointer.
      await t.pumpWidget(
        host(
          DataGrid(
            minWidth: 300,
            cols: const <Col>[Col('Candidate', width: 160)],
            rows: <GridRow>[
              GridRow(const <Widget>[GridLink('')]),
            ],
          ),
        ),
      );
      await t.pump();

      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets('GridLink.plain takes the same parameter', (
      WidgetTester t,
    ) async {
      // The two constructors share ONE build, so a parameter added to only one
      // of them makes a row with no detail route behave differently from a row
      // with one - for no reason a reader could find.
      await t.pumpWidget(
        host(
          DataGrid(
            minWidth: 300,
            cols: const <Col>[Col('Candidate', width: 160)],
            rows: <GridRow>[
              GridRow(const <Widget>[GridLink.plain(kLongName, maxLines: 1)]),
            ],
          ),
        ),
      );
      await t.pump();

      expect(
        t.renderObject<RenderParagraph>(find.text(kLongName)).size.height,
        closeTo(oneLine, 0.5),
      );
    });
  });
}
