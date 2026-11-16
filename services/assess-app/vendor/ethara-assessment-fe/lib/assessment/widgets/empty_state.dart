// The designed "there is nothing here" state.
//
// The candidate gate screen's anatomy (`screens/exam/gate_screen.dart`),
// extracted so admin lists stop settling for one grey sentence in a void:
//
//     [icon badge]      tinted square, tone-coloured
//     Headline          what is true, in plain words
//     Body              why, and what changes it
//     [action]          the one thing to do about it
//
// The tone rule from `marks.dart` applies: `inert` for "nothing yet", warn and
// bad only when something is genuinely wrong. An empty list is never red.
import 'package:flutter/material.dart';

import '../domain/enums.dart';
import '../theme.dart';
import 'marks.dart';

class EmptyState extends StatelessWidget {
  /// What is true. One line, sentence case, no trailing period.
  final String title;

  /// Why it is true and what changes it. Two lines at most.
  final String body;

  /// The one thing to do about it. Optional: some empty states genuinely
  /// have no action (a filtered view whose only fix is the filter above it).
  final Widget? action;

  final IconData icon;

  /// `inert` by default - an empty list is an absence, not a fault.
  final Tone tone;

  /// Vertical breathing room: less of it inside a panel with its own toolbar.
  final bool compact;

  const EmptyState({
    super.key,
    required this.title,
    required this.body,
    this.action,
    this.icon = Icons.inbox_outlined,
    this.tone = Tone.inert,
    this.compact = true,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final ToneColors c = ToneColors.of(t, tone);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 24,
        vertical: compact ? 44 : 72,
      ),
      child: Center(
        // Capped so the body wraps to a readable measure, not a table's width.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.bg,
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                ),
                child: Icon(icon, size: 21, color: c.fg),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: context.type.body.copyWith(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                body,
                textAlign: TextAlign.center,
                style: context.type.bodyMuted.copyWith(height: 1.55),
              ),
              if (action != null) ...<Widget>[
                const SizedBox(height: 16),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
