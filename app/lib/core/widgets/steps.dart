import 'package:flutter/material.dart';

import '../format.dart';
import '../theme/app_theme.dart';
import '../theme/portal_tokens.dart';

/// Where one step of a checklist stands.
enum StepState { pending, active, done, failed }

/// One step: a numbered disc (a tick when done, a cross when failed), the title, a hint, an action.
class StepTile {
  const StepTile({required this.title, required this.state, this.hint, this.action, this.key});
  final String title;
  final StepState state;
  final String? hint;
  final Widget? action;
  final Key? key;
}

/// Mercor-style step checklist: numbered discs joined by a rail, "n of m" at the top, steps complete
/// once and stay ticked. Used by applications, onboarding and the paper's brief.
class StepList extends StatelessWidget {
  const StepList({super.key, required this.steps, this.title, this.showProgress = true});
  final List<StepTile> steps;
  final String? title;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final done = steps.where((s) => s.state == StepState.done).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null || showProgress)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.x12),
            child: Row(
              children: [
                if (title != null) Expanded(child: Text(title!, style: theme.textTheme.titleSmall)),
                if (showProgress)
                  Text(
                    '$done of ${steps.length}',
                    key: const Key('step-progress'),
                    style: theme.textTheme.labelMedium?.copyWith(color: t.textSecondary),
                  ),
              ],
            ),
          ),
        if (showProgress)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.x16),
            child: ProgressBar(value: done.toDouble(), total: steps.length.toDouble()),
          ),
        for (final (i, s) in steps.indexed)
          Padding(
            key: s.key,
            padding: const EdgeInsets.only(bottom: Space.x12),
            child: Semantics(
              container: true,
              label: 'Step ${i + 1} of ${steps.length}, ${_stateWord(s.state)}',
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StepDisc(number: i + 1, state: s.state),
                  const SizedBox(width: Space.x12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.title,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: s.state == StepState.pending ? t.textSecondary : t.textPrimary,
                            fontWeight: s.state == StepState.active ? FontWeight.w600 : null,
                          ),
                        ),
                        if (s.hint != null) Text(s.hint!, style: theme.textTheme.bodySmall?.copyWith(color: t.textMuted)),
                      ],
                    ),
                  ),
                  if (s.action != null) ...[const SizedBox(width: Space.x12), s.action!],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

String _stateWord(StepState s) => switch (s) {
  StepState.done => 'done',
  StepState.active => 'in progress',
  StepState.failed => 'failed',
  StepState.pending => 'to do',
};

/// The numbered disc of a step.
class StepDisc extends StatelessWidget {
  const StepDisc({super.key, required this.number, required this.state, this.size = 28});
  final int number;
  final StepState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final (bg, fg, border, child) = switch (state) {
      StepState.done => (t.successBg, t.successText, t.successDot, Icon(Icons.check, size: size * 0.55, color: t.successText)),
      StepState.failed => (t.destBg, t.destText, t.destDot, Icon(Icons.close, size: size * 0.55, color: t.destText)),
      StepState.active => (t.primarySubtle, t.primary, t.primary, null),
      StepState.pending => (t.bgMuted, t.textSecondary, t.border, null),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(color: border),
      ),
      child:
          child ??
          Text(
            '$number',
            style: TextStyle(fontFamily: PortalType.familyMono, fontSize: size * 0.45, fontWeight: FontWeight.w500, color: fg),
          ),
    );
  }
}

/// A thin determinate bar in a status family.
class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key, required this.value, required this.total, this.kind = StatusKind.success, this.height = 6});
  final double value;
  final double total;
  final StatusKind kind;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final fill = switch (kind) {
      StatusKind.success => t.successDot,
      StatusKind.info => t.infoDot,
      StatusKind.warn => t.warnDot,
      StatusKind.dest => t.destDot,
    };
    final fraction = total <= 0 ? 0.0 : (value / total).clamp(0.0, 1.0);
    return Semantics(
      value: '${(fraction * 100).round()}%',
      child: ClipRRect(
        borderRadius: Radii.rFull,
        child: SizedBox(
          height: height,
          child: Stack(
            children: [
              Container(color: t.bgMuted),
              FractionallySizedBox(
                widthFactor: fraction,
                child: Container(color: fill),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stacked segments of one total (available · in progress · in review · accepted) with a dot legend.
class StackedBar extends StatelessWidget {
  const StackedBar({super.key, required this.segments, this.height = 10, this.legend = true});

  /// label, value, colour.
  final List<(String, double, Color)> segments;
  final double height;
  final bool legend;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final total = segments.fold<double>(0, (a, s) => a + s.$2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: Radii.rFull,
          child: SizedBox(
            height: height,
            child: total <= 0
                ? Container(color: t.bgMuted)
                : Row(
                    children: [
                      for (final s in segments)
                        if (s.$2 > 0)
                          Expanded(
                            flex: (s.$2 * 1000 / total).round().clamp(1, 1000),
                            child: Container(color: s.$3),
                          ),
                    ],
                  ),
          ),
        ),
        if (legend) ...[
          const SizedBox(height: Space.x8),
          Wrap(
            spacing: Space.x12,
            runSpacing: Space.x4,
            children: [
              for (final s in segments)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: s.$3, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: Space.x6),
                    Text('${s.$1} ${s.$2.toInt()}', style: theme.textTheme.labelSmall?.copyWith(color: t.textSecondary)),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A countdown chip ("expires in 2d 4h"), warn when under a day, dest once past.
class Countdown extends StatelessWidget {
  const Countdown({super.key, required this.until, this.prefix = 'Expires', this.now});
  final DateTime until;
  final String prefix;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final at = now ?? DateTime.now();
    final left = until.difference(at);
    final (label, kind) = left.isNegative
        ? ('Expired', StatusKind.dest)
        : ('$prefix ${untilShort(until, now: at)}', left < const Duration(hours: 24) ? StatusKind.warn : StatusKind.info);
    return StatusChip(label, kind: kind);
  }
}
