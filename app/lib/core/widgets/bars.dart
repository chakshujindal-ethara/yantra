import 'package:flutter/material.dart';

import '../format.dart';
import '../theme/app_theme.dart';
import '../theme/portal_tokens.dart';
import '../money.dart';

/// One bar per week. The tallest bar is the maximum; a zero week paints a hairline so the week is still
/// visibly there. Labels: the week's first day under each bar, the amount above the two largest bars.
class WeeklyBars extends StatelessWidget {
  const WeeklyBars({super.key, required this.values, required this.labels, this.currency = '', this.height = 140});

  final List<double> values;
  final List<String> labels;
  final String currency;
  final double height;

  /// From week rows: `(startsAt, amount)` pairs.
  factory WeeklyBars.fromWeeks(List<(DateTime?, double)> weeks, {String currency = '', double height = 140}) => WeeklyBars(
    values: [for (final w in weeks) w.$2],
    labels: [for (final w in weeks) w.$1 == null ? '' : shortDate(w.$1!)],
    currency: currency,
    height: height,
  );

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final max = values.fold<double>(0, (m, v) => v > m ? v : m);
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, c) {
          final n = values.length;
          if (n == 0) return const SizedBox.shrink();
          final slot = c.maxWidth / n;
          final barWidth = (slot * 0.6).clamp(6.0, 40.0);
          final labelEvery = slot < 44 ? (slot < 26 ? 4 : 2) : 1;
          final top = 22.0;
          final bottom = 18.0;
          final barArea = height - top - bottom;
          final sorted = [...values]..sort();
          // annotate the two largest bars only, so labels never collide on a dense chart
          final annotate = sorted.length >= 2 ? sorted[sorted.length - 2] : (sorted.isEmpty ? 0.0 : sorted.last);
          return Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: bottom,
                child: Container(height: 1, color: t.border),
              ),
              for (var i = 0; i < n; i++) ...[
                Positioned(
                  left: i * slot + (slot - barWidth) / 2,
                  bottom: bottom,
                  child: Semantics(
                    label: '${labels[i]}: ${formatAmount(values[i])} $currency',
                    child: Container(
                      width: barWidth,
                      height: max <= 0 ? 1 : (values[i] / max * barArea).clamp(values[i] == 0 ? 1 : 3, barArea),
                      decoration: BoxDecoration(
                        color: values[i] == 0 ? t.border : t.primary,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                      ),
                    ),
                  ),
                ),
                if (max > 0 && values[i] >= annotate && values[i] > 0)
                  Positioned(
                    left: i * slot,
                    width: slot,
                    bottom: bottom + (values[i] / max * barArea).clamp(3, barArea) + 4,
                    child: Text(
                      formatAmount(values[i]),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.visible,
                      softWrap: false,
                      style: AppTheme.figure(context, fontSize: 11, color: t.textSecondary),
                    ),
                  ),
                if (i % labelEvery == 0)
                  Positioned(
                    left: i * slot,
                    width: slot,
                    bottom: 0,
                    child: Text(
                      labels[i],
                      textAlign: TextAlign.center,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// `12,50,000` style amounts for chart labels (no decimals above 100, two below), Indian grouping.
String formatAmount(double v) => formatMoney(v.toStringAsFixed(2), decimals: v >= 100 || v == v.roundToDouble() ? 0 : 2);
