import 'package:flutter/material.dart';

import '../format.dart';
import '../money.dart';
import '../theme/app_theme.dart';
import '../theme/portal_tokens.dart';
import 'steps.dart';

/// Units of a batch or a project by stage as one stacked bar: available (neutral), in progress (info),
/// in review (warn), accepted (success), rejected (dest). Colours come from the tokens; the legend
/// carries the numbers so colour is never the only signal.
class StageBar extends StatelessWidget {
  const StageBar({
    super.key,
    required this.available,
    required this.inProgress,
    required this.inReview,
    required this.accepted,
    this.rejected = 0,
    this.needsEdits = 0,
    this.legend = true,
    this.height = 10,
  });

  final int available;
  final int inProgress;
  final int inReview;
  final int accepted;
  final int rejected;
  final int needsEdits;
  final bool legend;
  final double height;

  int get total => available + inProgress + inReview + accepted + rejected + needsEdits;

  /// The numbers in words, for the tooltip of a bar without a legend.
  String get breakdown => [
    '$available available',
    '$inProgress in progress',
    '$inReview in review',
    '$accepted accepted',
    if (needsEdits > 0) '$needsEdits need edits',
    if (rejected > 0) '$rejected rejected',
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final bar = StackedBar(
      legend: legend,
      height: height,
      segments: [
        ('Available', available.toDouble(), t.primary.withValues(alpha: 0.4)),
        ('In progress', inProgress.toDouble(), t.infoDot),
        ('In review', inReview.toDouble(), t.warnDot),
        ('Accepted', accepted.toDouble(), t.successDot),
        if (needsEdits > 0) ('Needs edits', needsEdits.toDouble(), t.warnText),
        if (rejected > 0) ('Rejected', rejected.toDouble(), t.destDot),
      ],
    );
    if (legend) return bar;
    // in a table the legend is off: the headline number sits beside the bar, the full breakdown rides on a
    // tooltip and a semantics label
    return Tooltip(
      message: breakdown,
      child: Semantics(
        label: '$accepted accepted of $total',
        container: true,
        child: ExcludeSemantics(
          child: CountedBar(bar: bar, accepted: accepted, total: total),
        ),
      ),
    );
  }
}

/// A table cell's bar with its headline number beside it ("2 of 12 accepted", or "No units yet"). A narrow cell
/// keeps the bar alone: the caller's tooltip still has the numbers.
class CountedBar extends StatelessWidget {
  const CountedBar({super.key, required this.bar, required this.accepted, required this.total});
  final Widget bar;
  final int accepted;
  final int total;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth < 160
          ? bar
          : Row(
              children: [
                Expanded(flex: 3, child: bar),
                const SizedBox(width: 12),
                Flexible(
                  flex: 2,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      total == 0 ? 'No units yet' : '$accepted of $total accepted',
                      style: AppTheme.figure(context, fontSize: 12.5, color: t.textMuted),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// The console's status words on top of [statusKindFor]: a live thing is success, a stopped one is
/// warn, an ended one is dest. Unknown words still read as info.
StatusKind consoleStatusKind(String status) => switch (status.toLowerCase()) {
  'active' || 'open' || 'published' || 'eligible' || 'live' => StatusKind.success,
  'paused' || 'suspended' || 'draft' || 'screening' || 'offered' || 'assessment' => StatusKind.warn,
  'cancelled' || 'canceled' || 'offboarded' || 'closed' || 'declined' || 'withdrawn' => StatusKind.dest,
  _ => statusKindFor(status),
};

/// A status chip for the console's own status words.
class ConsoleStatus extends StatelessWidget {
  const ConsoleStatus(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: StatusChip(status.isEmpty ? '—' : humanize(status), kind: consoleStatusKind(status)),
  );
}

/// Pay against bill on one line: `INR 28.00 pay · INR 60.00 bill · 53% margin`. Ops only; a worker
/// never sees a price.
class PayBill extends StatelessWidget {
  const PayBill({
    super.key,
    required this.pay,
    required this.bill,
    required this.currency,
    this.margin,
    this.underFloor = false,
    this.compact = false,
  });
  final String pay;
  final String bill;
  final String currency;
  final double? margin;
  final bool underFloor;

  /// One line that shrinks to fit (a table cell) instead of wrapping.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final marginText = margin == null ? '—' : '${(margin! * 100).round()}%';
    final parts = <Widget>[
      Text('${formatMoney(pay, currency: currency)} pay', style: AppTheme.figure(context, fontSize: 13)),
      Text('·', style: theme.textTheme.bodySmall),
      Text('${formatMoney(bill, currency: currency)} bill', style: AppTheme.figure(context, fontSize: 13)),
      Text('·', style: theme.textTheme.bodySmall),
      Text('$marginText margin', style: AppTheme.figure(context, fontSize: 13, color: underFloor ? t.destText : t.textSecondary)),
      if (underFloor) Icon(Icons.warning_amber_rounded, size: Sizes.iconSm, color: t.destDot, semanticLabel: 'Under the margin floor'),
    ];
    if (compact) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(mainAxisSize: MainAxisSize.min, spacing: Space.x6, children: parts),
      );
    }
    return Wrap(spacing: Space.x6, crossAxisAlignment: WrapCrossAlignment.center, children: parts);
  }
}

/// Small neutral chips for gates or tags; the first [max] shown, the rest counted.
class TagChips extends StatelessWidget {
  const TagChips(this.tags, {super.key, this.max = 3, this.onRemove});
  final List<String> tags;
  final int max;

  /// When given, every chip gets a remove button.
  final void Function(String)? onRemove;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    if (tags.isEmpty) return Text('—', style: theme.textTheme.bodySmall);
    final shown = onRemove == null ? tags.take(max).toList() : tags;
    return Wrap(
      spacing: Space.x6,
      runSpacing: Space.x4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final tag in shown)
          Container(
            padding: EdgeInsets.only(left: Space.x8, right: onRemove == null ? Space.x8 : Space.x2, top: Space.x2, bottom: Space.x2),
            decoration: BoxDecoration(
              color: t.bgMuted,
              borderRadius: Radii.rFull,
              border: Border.all(color: t.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tag, style: theme.textTheme.labelMedium?.copyWith(color: t.textPrimary)),
                if (onRemove != null)
                  IconButton(
                    key: Key('remove-tag-$tag'),
                    tooltip: 'Remove $tag',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    padding: EdgeInsets.zero,
                    iconSize: Sizes.iconSm,
                    onPressed: () => onRemove!(tag),
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
          ),
        if (shown.length < tags.length) Text('+${tags.length - shown.length}', style: theme.textTheme.labelMedium),
      ],
    );
  }
}
