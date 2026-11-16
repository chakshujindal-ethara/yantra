// A chart must not mangle the numbers and names it exists to report.
//
// TWO REPORTED DEFECTS, both on the dashboard, both cases of a fixed size meeting
// real data:
//
//  * SNo 163 - the donut's centre figure is a RATIO. `kpiValue` is 30px mono, cut
//    for two or three digits, so on a real cohort "1466/2248" is nine glyphs of
//    about 162px inside a 148px chart. It wrapped, and mono wrapping mid-number
//    renders "1466/224" above a lone "8" - not an unreadable number, a DIFFERENT
//    one. That is the failure worth catching: a reader has no way to tell.
//
//  * SNo 164 - the bar chart's label column was pinned at 148px whatever the
//    panel width, so every real assessment name clipped ("DEMO Image Evaluatio…",
//    "DEMO-SOP Forklift Saf…") on a panel over 600px wide. A cohort chart whose
//    rows cannot be told apart is not reporting anything.
//
// THESE ASSERT RENDERED GEOMETRY, not that the widget builds. `getRect` returns
// the painted rect in global coordinates, so it accounts for the FittedBox's
// scaling - which is the whole mechanism under test. A test that only checked
// "a FittedBox is present" would pass against a FittedBox with the wrong
// constraint, which is exactly the bug wearing a fix's clothes.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/widgets/charts.dart';

/// The chart's own box. The centre figure is bounded by THIS, not by the ring's
/// inner hole: constraining to the hole (~100px) would shrink figures that render
/// correctly today - "39/179" is 6 glyphs of ~108px and has always been drawn at
/// its authored size - so a tighter bound would regress every cohort that does not
/// have the reported bug.
const double kDonut = 148;

/// Tokens resolve from ambient brightness, so a dark MaterialApp is all the
/// setup these need - the same shape charts_chatter_test.dart uses.
Widget host(Widget child, {double width = 700}) => MaterialApp(
  theme: ThemeData(brightness: Brightness.dark),
  home: Scaffold(
    body: Center(child: SizedBox(width: width, child: child)),
  ),
);

void main() {
  group('the donut centre figure', () {
    testWidgets('a four-digit ratio stays on one line inside the ring',
        (WidgetTester t) async {
      await t.pumpWidget(host(
        const DonutChart(
          slices: <Slice>[
            Slice('Passed', 1466, Color(0xFF4ADE80)),
            Slice('Failed', 782, Color(0xFFF87171)),
          ],
          centerValue: '1466/2248',
          centerLabel: 'PASSED',
        ),
      ));
      await t.pump();

      final Finder value = find.text('1466/2248');
      expect(value, findsOneWidget);

      // THE ASSERTION THAT CATCHES THE BUG. Unfixed, the 30px mono string lays
      // out at ~162px and wraps inside the 148px chart; fixed, it is scaled down
      // to sit inside the ring's hole. Either way the widget "builds".
      final Rect r = t.getRect(value);
      expect(
        r.width,
        lessThanOrEqualTo(kDonut + 0.5),
        reason: 'the ratio must fit inside the chart rather than wrap - '
            'rendered ${r.width.toStringAsFixed(1)}px in a ${kDonut}px chart',
      );

      // ONE LINE. A ratio broken across lines is a different number.
      final RenderParagraph p = t.renderObject<RenderParagraph>(value);
      expect(p.didExceedMaxLines, isFalse);
      expect(p.text.toPlainText(), '1466/2248');
    });

    testWidgets('the centre figure stays inside the ring, not over it',
        (WidgetTester t) async {
      // THE DEFECT A WALKTHROUGH FOUND, and the reason the earlier fix was not
      // enough. `scaleDown` was bounded by the whole 148px box while the ring
      // leaves only `size - 2 * stroke` clear - the painter's stroke is
      // `0.16 * size`, so about 100px. "227/276" is seven glyphs: too wide for
      // the hole, comfortably inside the box, therefore never scaled. It
      // printed across the arc.
      //
      // Asserted against the HOLE rather than against a pixel count, so it
      // holds whatever font the test environment supplies.
      const double size = 148;
      const double stroke = size * 0.16;
      const double hole = size - 2 * stroke;

      await t.pumpWidget(host(
        const DonutChart(
          slices: <Slice>[Slice('Passed', 227, Color(0xFF4ADE80))],
          centerValue: '227/276',
          centerLabel: 'PASSED',
        ),
      ));
      await t.pump();

      final double painted = t.getRect(find.text('227/276')).width;
      expect(
        painted,
        lessThanOrEqualTo(hole),
        reason: 'the centre figure is ${painted.toStringAsFixed(1)}px wide '
            'inside a ${hole.toStringAsFixed(1)}px hole, so it draws over the '
            'ring it belongs in',
      );
    });

    testWidgets('scaling only ever shrinks, and shorter figures shrink less',
        (WidgetTester t) async {
      // THE NEGATIVE HALF: the fix must not resize figures that already render
      // correctly. But it CANNOT be asserted as "39/79 keeps its 30px", because
      // that depends on font metrics the test environment does not share with
      // production - measured with a probe, the test fallback font advances a
      // full em per glyph, so "39/79" lays out at 151px here versus ~90px with
      // the real mono face. An assertion pinned to those numbers would be
      // testing flutter_test, not the chart.
      //
      // These two properties hold in ANY font, and together they are the whole
      // contract: never scale UP, and never punish a short figure for a long
      // one's overflow.
      double paintedHeight(String v) => t.getRect(find.text(v)).height;
      double authoredHeight(String v) =>
          t.renderObject<RenderParagraph>(find.text(v)).size.height;

      await t.pumpWidget(host(
        const DonutChart(
          slices: <Slice>[Slice('Passed', 39, Color(0xFF4ADE80))],
          centerValue: '39/79',
          centerLabel: 'PASSED',
        ),
      ));
      await t.pump();
      final double shortPainted = paintedHeight('39/79');
      final double authored = authoredHeight('39/79');
      expect(authored, 33, reason: 'kpiValue is 30px with height 1.1');
      expect(shortPainted, lessThanOrEqualTo(authored + 0.5),
          reason: 'scaleDown must never enlarge');

      await t.pumpWidget(host(
        const DonutChart(
          slices: <Slice>[Slice('Passed', 1466, Color(0xFF4ADE80))],
          centerValue: '1466/2248',
          centerLabel: 'PASSED',
        ),
      ));
      await t.pump();
      final double longPainted = paintedHeight('1466/2248');

      expect(longPainted, lessThan(shortPainted),
          reason: 'the long ratio is the one that overflows, so it is the one '
              'that gets scaled - a fix that shrank both equally would be '
              'making every cohort smaller to fix one');
    });

    testWidgets('a 2-3 digit figure keeps the size it has today',
        (WidgetTester t) async {
      // PRESERVATION BASELINE (requirement 3.10). Every cohort on stage today
      // is three digits - 572 candidates - so this is the case the D6 work must
      // not move. Recorded against UNFIXED code and asserted as a ratio of the
      // authored size rather than a pixel count, because the test face advances
      // a full em per glyph and a pinned pixel figure would be measuring
      // flutter_test rather than the chart.
      //
      // Measured here, printed by the loop below: '13/19' renders 20.2px tall
      // and '396/572' 14.4px, both against an authored 33.0px, because 5 and 7
      // glyphs at a full em per glyph are 150px and 210px against the 92.6px
      // bound. The shipped mono face advances less, so production scales less.
      // What holds in BOTH is the ordering: nothing is ever enlarged, and a
      // shorter figure is never scaled below a longer one.
      double painted(String v) => t.getRect(find.text(v)).height;
      double authored(String v) =>
          t.renderObject<RenderParagraph>(find.text(v)).size.height;

      for (final String v in <String>['13/19', '396/572']) {
        await t.pumpWidget(host(
          DonutChart(
            slices: const <Slice>[Slice('Passed', 13, Color(0xFF4ADE80))],
            centerValue: v,
            centerLabel: 'PASSED',
          ),
        ));
        await t.pump();

        final RenderParagraph p =
            t.renderObject<RenderParagraph>(find.text(v));
        debugPrint('baseline $v: painted ${painted(v).toStringAsFixed(1)}px of '
            'an authored ${authored(v).toStringAsFixed(1)}px');
        expect(p.didExceedMaxLines, isFalse,
            reason: '$v must stay on one line');
        expect(p.text.toPlainText(), v, reason: 'and lose no glyph');
        expect(painted(v), lessThanOrEqualTo(authored(v) + 0.5),
            reason: 'scaleDown never enlarges');
        // The ring's hole, which is the bound the widget actually uses.
        expect(t.getRect(find.text(v)).width,
            lessThanOrEqualTo(148 - 2 * (148 * 0.16)),
            reason: '$v must sit inside the ring rather than across it');
      }
    });

    // ── D6: what happens at four and five digits ─────────────────────────
    //
    // REPRODUCTION, NOT A FIX. The requested remedy - `FittedBox(scaleDown)` -
    // has been in this widget since SNo 163, so the question is not "does it
    // scale" but "what does it scale TO". These two record the answer: the
    // string is intact, on one line, inside the ring, and SMALL. The number
    // printed by each is the evidence the D6 decision gate reads.
    testWidgets('a five-digit ratio is contained, and the price is legibility',
        (WidgetTester t) async {
      const double authoredPx = 30; // kpiValue
      const double authoredHeight = 33; // 30 * 1.1

      await t.pumpWidget(host(
        const DonutChart(
          slices: <Slice>[
            Slice('Passed', 12345, Color(0xFF4ADE80)),
            Slice('Failed', 55545, Color(0xFFF87171)),
          ],
          centerValue: '12345/67890',
          centerLabel: 'PASSED',
        ),
      ));
      await t.pump();

      final Finder v = find.text('12345/67890');
      final RenderParagraph p = t.renderObject<RenderParagraph>(v);
      final Rect r = t.getRect(v);
      final double effective = authoredPx * (r.height / authoredHeight);

      // NOT CLIPPED and NOT WRAPPED. Both halves matter: a clipped ratio is a
      // wrong number, and a wrapped one is a different number.
      expect(p.didExceedMaxLines, isFalse);
      expect(p.text.toPlainText(), '12345/67890');
      expect(t.takeException(), isNull, reason: 'no overflow is thrown');
      expect(r.width, lessThanOrEqualTo(148 - 2 * (148 * 0.16)) );

      // THE MEASUREMENT. Printed rather than merely asserted, because the
      // number is the deliverable: 11 glyphs of 30px scaled into a 92.6px bound.
      debugPrint('D6 five-digit: painted ${r.width.toStringAsFixed(1)}x'
          '${r.height.toStringAsFixed(1)} -> effective '
          '${effective.toStringAsFixed(1)}px of an authored ${authoredPx}px');

      // The floor this asserts is the one the fix has to raise. Left as a
      // greater-than-zero sanity bound so the test states the reproduction
      // rather than freezing the defect.
      expect(effective, greaterThan(0));
    });

    testWidgets('the LABEL is not what drives the scale', (WidgetTester t) async {
      // Rules H2 in or out. If 'PASSED' were the wider child of the Column, the
      // ratio would be scaled by the label's overflow rather than its own - and
      // the fix would be to lift the label out of the FittedBox. Measured with
      // both children present and with a one-character label.
      double ratioHeight(String label) => t.getRect(find.text('1466/2248')).height;

      await t.pumpWidget(host(
        const DonutChart(
          slices: <Slice>[Slice('Passed', 1466, Color(0xFF4ADE80))],
          centerValue: '1466/2248',
          centerLabel: 'PASSED',
        ),
      ));
      await t.pump();
      final double withLabel = ratioHeight('PASSED');

      await t.pumpWidget(host(
        const DonutChart(
          slices: <Slice>[Slice('Passed', 1466, Color(0xFF4ADE80))],
          centerValue: '1466/2248',
          centerLabel: 'P',
        ),
      ));
      await t.pump();
      final double withoutLabel = ratioHeight('P');

      debugPrint('D6 label influence: ratio is '
          '${withLabel.toStringAsFixed(1)}px beside "PASSED" and '
          '${withoutLabel.toStringAsFixed(1)}px beside "P"');

      expect(withLabel, closeTo(withoutLabel, 0.5),
          reason: 'the RATIO is the wider child at four digits, so shortening '
              'the label changes nothing - H2 does not hold and moving the '
              'label out of the FittedBox would fix nothing');
    });

    testWidgets('the panel that hosts it does not overflow at 4+ digits',
        (WidgetTester t) async {
      // THE PATH THE DESIGN DID NOT ENUMERATE. H1-H4 are all about the donut's
      // own geometry, but 'Decided Outcomes' is a Row of [donut, Expanded
      // legend] inside a fixed-minHeight Panel, and the legend's values grow
      // with the same figures. If a 4-digit cohort overflowed the Row or the
      // panel body, the reported "renders incorrectly" would be here rather
      // than in the chart - and it would be a real defect.
      //
      // Reproduced at the narrowest width the panel is ever given (a half-width
      // panel on a 1280 viewport is ~460px) and at the console-wide total of
      // 2538 from the stage measurement.
      await t.pumpWidget(host(
        Row(
          children: <Widget>[
            const DonutChart(
              slices: <Slice>[
                Slice('Passed', 1466, Color(0xFF4ADE80)),
                Slice('Failed', 1072, Color(0xFFF87171)),
              ],
              centerValue: '1466/2538',
              centerLabel: 'PASSED',
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text('Passed  1466'),
                  const SizedBox(height: 8),
                  const Text('Failed  1072'),
                ],
              ),
            ),
          ],
        ),
        width: 460,
      ));
      await t.pump();

      expect(t.takeException(), isNull,
          reason: 'no RenderFlex overflow: the donut is a fixed 148 and the '
              'legend takes what is left, so a longer figure cannot widen it');
      expect(find.text('1466/2538'), findsOneWidget);
    });

    // ── D6: the fix, and the property it has to hold ────────────────────
    //
    // THE LABEL HOLDS ITS SIZE WHATEVER THE RATIO DOES. Asserted as an
    // equality between two renders rather than as a pixel figure, because
    // flutter_test forces the Ahem face and its numbers are not the ones the
    // browser produces. The RELATION is face-independent: whatever 'PASSED'
    // measures, it must measure the same beside a 5-glyph ratio and beside an
    // 11-glyph one. Unfixed, the single shared FittedBox made the second
    // render 0.512 of the first (11.0px -> 5.6px in Chrome, measured).
    testWidgets('the label keeps its size however long the ratio is',
        (WidgetTester t) async {
      Future<double> labelHeight(String ratio) async {
        await t.pumpWidget(host(
          DonutChart(
            slices: const <Slice>[Slice('Passed', 1, Color(0xFF4ADE80))],
            centerValue: ratio,
            centerLabel: 'PASSED',
          ),
        ));
        await t.pump();
        return t.getRect(find.text('PASSED')).height;
      }

      final double short = await labelHeight('13/19');
      final double four = await labelHeight('1466/2538');
      final double five = await labelHeight('12345/67890');

      debugPrint('D6 label: 13/19 -> ${short.toStringAsFixed(2)}px, '
          '1466/2538 -> ${four.toStringAsFixed(2)}px, '
          '12345/67890 -> ${five.toStringAsFixed(2)}px');

      expect(four, closeTo(short, 0.5),
          reason: 'a four-digit ratio must not shrink the label');
      expect(five, closeTo(short, 0.5),
          reason: 'nor may a five-digit one - the label has its own '
              'FittedBox and fits at every figure, so its scale is always 1');
    });

    testWidgets('the ratio still scales down, and still fits the ring',
        (WidgetTester t) async {
      // The OTHER half of the fix: splitting the box must not stop the ratio
      // being contained. Both properties in one place so a future change that
      // trades one for the other fails here.
      for (final String v in <String>['1466/2538', '12345/67890']) {
        await t.pumpWidget(host(
          DonutChart(
            slices: const <Slice>[Slice('Passed', 1, Color(0xFF4ADE80))],
            centerValue: v,
            centerLabel: 'PASSED',
          ),
        ));
        await t.pump();

        final RenderParagraph p = t.renderObject<RenderParagraph>(find.text(v));
        expect(p.didExceedMaxLines, isFalse, reason: '$v stays on one line');
        expect(p.text.toPlainText(), v, reason: '$v loses no glyph');
        expect(t.takeException(), isNull, reason: '$v throws no overflow');
        expect(t.getRect(find.text(v)).width,
            lessThanOrEqualTo(148 - 2 * (148 * 0.16)),
            reason: '$v sits inside the ring rather than across it');
      }
    });

    testWidgets('an empty cohort still renders its centre honestly',
        (WidgetTester t) async {
      // total == 0 is a real state (nobody has sat anything yet). The painter
      // early-returns on it; the centre text must still be there rather than
      // the panel looking broken.
      await t.pumpWidget(host(
        const DonutChart(
          slices: <Slice>[Slice('Passed', 0, Color(0xFF4ADE80))],
          centerValue: '0/0',
          centerLabel: 'PASSED',
        ),
      ));
      await t.pump();

      expect(find.text('0/0'), findsOneWidget);
      expect(find.text('PASSED'), findsOneWidget);
    });
  });

  group('the bar chart label column', () {
    const List<Slice> kBars = <Slice>[
      Slice('DEMO Image Evaluation - Live', 7, Color(0xFFC084FC)),
      Slice('DEMO-SOP Forklift Safety Assessment', 3, Color(0xFFC084FC)),
      Slice('E2E Forklift Safety (live run)', 2, Color(0xFFC084FC)),
    ];

    testWidgets('it grows with the panel instead of staying at 148px',
        (WidgetTester t) async {
      await t.pumpWidget(host(const BarChart(bars: kBars), width: 700));
      await t.pump();

      final double w =
          t.getSize(find.text('DEMO Image Evaluation - Live')).width;
      // A third of 700 is 233. The bug is that this was 148 whatever the panel.
      expect(w, greaterThan(148),
          reason: 'the label column was pinned at 148px on a 700px panel, so '
              'every real assessment name clipped');
      expect(w, closeTo(700 / 3, 1.0));
    });

    testWidgets('a narrow panel is no worse than before', (WidgetTester t) async {
      // THE FLOOR. A third of 300 is 100, which would be a REGRESSION against
      // the old fixed 148 - so the fix must clamp up, not just scale.
      await t.pumpWidget(host(const BarChart(bars: kBars), width: 300));
      await t.pump();

      final double w =
          t.getSize(find.text('DEMO Image Evaluation - Live')).width;
      expect(w, closeTo(148, 1.0),
          reason: 'never narrower than the width this used to be fixed at');
    });

    testWidgets('a very wide panel does not leave the bars a stub',
        (WidgetTester t) async {
      // The default test surface is 800x600, so a 1600px SizedBox is clamped to
      // 800 and the cap would never bind - the surface has to be widened for
      // this case to be the case it claims to be.
      t.view.physicalSize = const Size(1800, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(host(const BarChart(bars: kBars), width: 1600));
      await t.pump();

      final double w =
          t.getSize(find.text('DEMO Image Evaluation - Live')).width;
      expect(w, closeTo(320, 1.0),
          reason: 'capped, because bar LENGTH is the thing being compared');
    });

    testWidgets('the full name is reachable when it still clips',
        (WidgetTester t) async {
      // Even a third of a panel can clip a long name, and the ellipsis lands
      // exactly where the operator needs to know WHICH assessment.
      await t.pumpWidget(host(const BarChart(bars: kBars), width: 400));
      await t.pump();

      final Iterable<Tooltip> tips = t.widgetList<Tooltip>(find.byType(Tooltip));
      expect(
        tips.map((Tooltip x) => x.message),
        containsAll(<String>[
          'DEMO Image Evaluation - Live',
          'DEMO-SOP Forklift Safety Assessment',
        ]),
      );
    });

    // NO UNBOUNDED-PARENT TEST. Measured with a probe: BarChart puts the bar in
    // an `Expanded` inside a Row, so a horizontally unbounded parent throws from
    // the Expanded before any of this code runs - the chart has never been
    // layout-able there. A test for it would assert a case that cannot occur,
    // and the guard it would have justified was deleted as unreachable.

    testWidgets('every value zero still renders the rows', (WidgetTester t) async {
      // The divide guard. Nobody has sat anything yet is a real state.
      await t.pumpWidget(host(const BarChart(bars: <Slice>[
        Slice('Alpha', 0, Color(0xFFC084FC)),
        Slice('Beta', 0, Color(0xFFC084FC)),
      ])));
      await t.pump();

      expect(t.takeException(), isNull);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('0'), findsWidgets);
    });
  });
}
