import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Charts, drawn with CustomPainter rather than a charting package.
///
/// WHY NOT fl_chart: every chart here is a bar, a donut or a sparkline, and a
/// library would add ~400KB to the bundle to draw rectangles while fighting
/// `context.tokens`. House rules: colour from `AppTokens` so both themes work,
/// the real number printed beside the geometry, an honest empty state.

/// One slice of a [DonutChart] or one bar of a [BarChart].
class Slice {
  const Slice(this.label, this.value, this.color);

  final String label;
  final double value;
  final Color color;
}

/// A donut with the headline figure in the middle. Used for pass/fail splits,
/// where the ratio is the story and the counts are the supporting detail.
class DonutChart extends StatelessWidget {
  const DonutChart({
    super.key,
    required this.slices,
    required this.centerValue,
    required this.centerLabel,
    this.size = 148,
  });

  final List<Slice> slices;
  final String centerValue;
  final String centerLabel;
  final double size;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final double total = slices.fold<double>(
      0,
      (double n, Slice s) => n + s.value,
    );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          CustomPaint(
            size: Size(size, size),
            painter: _DonutPainter(
              slices: slices,
              total: total,
              track: t.border,
            ),
          ),
          // SHRINK RATHER THAN WRAP - SNo 163.
          //
          // `kpiValue` is 30px mono, cut for two or three digits. The centre
          // figure here is a RATIO, so on a real cohort it reads "1466/2248" -
          // nine glyphs, about 162px, inside a 148px chart. It wrapped, and mono
          // wrapping mid-number renders "1466/224" above a lone "8", which is
          // not a wrong number so much as a different one.
          //
          // BOUNDED BY THE RING'S HOLE, which is a CORRECTION.
          //
          // This was bounded by the whole box on the reasoning that
          // constraining to the hole "would fix a bug nobody has". That was
          // wrong, and a walkthrough found it: the hole is `size - 2 * stroke`
          // and the painter's stroke is `0.16 * size`, so a 148px chart leaves
          // about 100px of clear space. "227/276" is seven glyphs of roughly
          // 126px - comfortably inside the 148px box, so it never scaled, and
          // it printed straight over the ring it sits in.
          //
          // The earlier note is right that this shrinks figures that used to
          // draw at 30px, "39/179" among them. That is the trade being taken
          // deliberately: those were overlapping the ring too, just by less. A
          // slightly smaller number that sits inside its own chart reads better
          // than a full-size one crossing the arc that gives it meaning.
          //
          // The 8px is breathing room, so a glyph does not touch the arc.
          SizedBox(
            width: (size * (1 - 2 * 0.16)) - 8,
            // D6 - ONE FittedBox PER CHILD, not one wrapped around both.
            //
            // A shared FittedBox scales to whichever child overflows MOST, and
            // past three digits that is always the ratio - so the label was
            // dragged down with it even though the label fits at every figure
            // this platform can produce. Measured in Chrome against the real
            // DM Mono / Plus Jakarta Sans faces, which is the only way to get
            // these numbers: flutter_test forces the Ahem face, whose full-em
            // advance reports a different scale entirely.
            //
            //   centre value   natural   scale   ratio px   LABEL px
            //   13/19            79.7    1.000     30.0       11.0
            //   396/572         113.4    0.817     24.5        9.0
            //   1466/2538       147.1    0.630     18.9        6.9
            //   12345/67890     180.8    0.512     15.4        5.6
            //
            // 'PASSED' at 5.6px is the reported defect. The ratio at 15.4px is
            // small but it is mono and it reads; the label at 5.6px is a
            // smudge. Splitting the box fixes the label outright - 'PASSED'
            // measures ~42px against this 92.6px bound, so its OWN scale is
            // 1.000 at every figure and it holds its authored 11px.
            //
            // THIS IS NOT THE RULED-OUT H2. H2 asked whether the label drives
            // the RATIO's scale - it does not, and the test that proves it
            // still passes unchanged. The defect is the converse, the ratio
            // driving the LABEL's, which the hypothesis table never listed.
            //
            // The ratio is deliberately NOT given a font floor. A floor can
            // only be honoured by letting the glyphs cross the arc, and the
            // 8px above is there precisely so they do not - a number sitting
            // inside its own chart reads better than a bigger one drawn over
            // the ring that gives it meaning.
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    centerValue,
                    // A ratio must never break across lines, whatever the
                    // scale ends up being.
                    maxLines: 1,
                    softWrap: false,
                    style: context.type.kpiValue,
                  ),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    centerLabel,
                    maxLines: 1,
                    softWrap: false,
                    style: context.type.kpiLabel,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.slices,
    required this.total,
    required this.track,
  });

  final List<Slice> slices;
  final double total;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final double stroke = size.width * 0.16;
    final Rect rect =
        Offset(stroke / 2, stroke / 2) &
        Size(size.width - stroke, size.height - stroke);
    final Paint base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(rect, 0, math.pi * 2, false, base);

    if (total <= 0) return;
    // Start at 12 o'clock: a ring that starts at 3 o'clock reads as rotated.
    double start = -math.pi / 2;
    for (final Slice s in slices) {
      if (s.value <= 0) continue;
      final double sweep = (s.value / total) * math.pi * 2;
      canvas.drawArc(
        rect,
        start,
        // A hair of separation so adjacent slices stay legible without a
        // border colour that would have to know the canvas behind it.
        math.max(0, sweep - 0.02),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.butt
          ..color = s.color,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.slices != slices || old.total != total || old.track != track;
}

/// A horizontal bar chart with the value printed at the end of each bar.
///
/// Horizontal, not vertical: the labels are assessment names and job titles,
/// which do not fit under a vertical column without rotating text.
class BarChart extends StatelessWidget {
  const BarChart({
    super.key,
    required this.bars,
    this.maxValue,
    this.valueSuffix = '',
    this.barHeight = 22,
  });

  final List<Slice> bars;
  final double? maxValue;
  final String valueSuffix;
  final double barHeight;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    if (bars.isEmpty) {
      return Text('Nothing to chart yet.', style: context.type.bodyMuted);
    }
    final double top =
        maxValue ??
        bars.fold<double>(0, (double n, Slice s) => math.max(n, s.value));
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints outer) {
        // A third of the row for the name, never below the 148 this used to be
        // fixed at, never above 320 - past that the bars are the stub instead.
        //
        // No unbounded-width guard here: the bar itself is an `Expanded` inside
        // a Row, so this chart has never been layout-able in a horizontally
        // unbounded parent and never will be. A guard for that case would be
        // unreachable code that only looked like safety (measured: an
        // IntrinsicWidth parent throws from the Expanded either way).
        final double labelWidth = math.min(
          320,
          math.max(148, outer.maxWidth / 3),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final Slice s in bars) ...<Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: <Widget>[
                    // THE LABEL COLUMN GROWS WITH THE PANEL - SNo 164.
                    //
                    // It was pinned at 148px whatever the width, so every real
                    // assessment name clipped: "DEMO Image Evaluatio…", "DEMO-SOP
                    // Forklift Saf…". A cohort chart whose rows cannot be told apart
                    // is not reporting anything. Seen live on the dashboard, where
                    // the panel is over 600px wide and 148 of them were being used.
                    //
                    // A THIRD of the row, floored at the old 148 so a narrow panel
                    // is no worse than before, and capped so a wide one does not
                    // leave the bars a stub. Proportional rather than intrinsic
                    // width: sizing to the longest label would make the bars jump
                    // in length whenever the cohort changes, and bar length is the
                    // thing being compared.
                    SizedBox(
                      width: labelWidth,
                      // The name in full on hover, because even a third of a
                      // narrow panel can clip a long one - and the ellipsis is
                      // exactly where an operator needs to know WHICH assessment.
                      child: Tooltip(
                        message: s.label,
                        waitDuration: const Duration(milliseconds: 400),
                        child: Text(
                          s.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.type.bodySecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints c) {
                          // Guard the divide: every value zero is a real state
                          // (nobody has sat anything yet), not a reason to crash.
                          final double frac = top <= 0 ? 0 : s.value / top;
                          return Stack(
                            children: <Widget>[
                              Container(
                                height: barHeight,
                                decoration: BoxDecoration(
                                  color: t.bgSubtle,
                                  borderRadius: Radii.bar,
                                ),
                              ),
                              // ZERO DRAWS NOTHING. A 2px stub reads as "a little
                              // bit", a different claim from "none". The floor
                              // keeps a SMALL non-zero value visible, not zero.
                              if (s.value > 0)
                                Container(
                                  height: barHeight,
                                  width: math.max(2, c.maxWidth * frac),
                                  decoration: BoxDecoration(
                                    color: s.color,
                                    borderRadius: Radii.bar,
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 54,
                      child: Text(
                        '${_trim(s.value)}$valueSuffix',
                        textAlign: TextAlign.right,
                        style: context.type.mono,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
}

/// A stacked single bar: one row, several segments, a legend underneath - the
/// right shape for passed / failed / awaiting, where the parts sum to a whole.
class StackedBar extends StatelessWidget {
  const StackedBar({super.key, required this.slices, this.height = 14});

  final List<Slice> slices;
  final double height;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final double total = slices.fold<double>(
      0,
      (double n, Slice s) => n + s.value,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ClipRRect(
          borderRadius: Radii.bar,
          child: SizedBox(
            height: height,
            // LayoutBuilder + explicit widths, NOT Expanded with a flex.
            //
            // `Expanded(flex: (v * 1000 / total).round())` rounds a small
            // share to a flex of 1 next to a flex of 999, which renders as a
            // sliver too thin to see - the bar looked empty while the legend
            // underneath said 1 of 5. Widths computed from the real fraction
            // keep a small segment visible.
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                if (total <= 0) return ColoredBox(color: t.bgSubtle);
                return Row(
                  children: <Widget>[
                    for (final Slice s in slices)
                      if (s.value > 0)
                        Container(
                          // A floor of 3px so a single candidate in a cohort
                          // of hundreds is still something the eye can find.
                          width: math.max(3, c.maxWidth * (s.value / total)),
                          // HEIGHT IS EXPLICIT. `SizedBox(width:)` wrapping a
                          // childless `ColoredBox` laid out at 0x0 - the bar
                          // rendered as nothing at all while the legend below
                          // it reported real counts. A ColoredBox has no
                          // intrinsic size, so something must give it one.
                          height: height,
                          color: s.color,
                        ),
                  ],
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: <Widget>[
            for (final Slice s in slices)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: s.color,
                      borderRadius: Radii.badge,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text('${s.label} ', style: context.type.bodySecondary),
                  Text('${s.value.round()}', style: context.type.mono),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// A compact trend line for a KPI tile.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    required this.color,
    this.height = 30,
  });

  final List<double> values;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (values.length < 2) return SizedBox(height: height);
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _SparkPainter(values: values, color: color),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double lo = values.reduce(math.min);
    final double hi = values.reduce(math.max);
    // A flat series is a real answer, not a divide-by-zero: draw it mid-height
    // rather than collapsing it onto the floor.
    final double span = (hi - lo).abs() < 1e-9 ? 1 : hi - lo;
    final Path line = Path();
    for (int i = 0; i < values.length; i++) {
      final double x = size.width * (i / (values.length - 1));
      final double norm = (hi - lo).abs() < 1e-9
          ? 0.5
          : (values[i] - lo) / span;
      final double y = size.height - (norm * size.height);
      i == 0 ? line.moveTo(x, y) : line.lineTo(x, y);
    }
    final Path fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.14));
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) =>
      old.values != values || old.color != color;
}
