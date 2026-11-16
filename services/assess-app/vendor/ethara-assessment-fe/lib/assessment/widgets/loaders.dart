// Loading affordances.
//
// The app had exactly two states: a full-page skeleton while `loadState` was
// `loading`, and nothing at all for everything else. So an operator who pressed
// "Generate questions" - a call that takes seconds and costs money - got no
// feedback until the toast arrived, and pressed it again. Same for uploads,
// approvals, and every tab that fetches its own data.
//
// The button's own busy state lives on `Btn`, not here: only the button can
// stop a disabled-looking button from still accepting taps.
import 'package:flutter/material.dart';

import '../theme.dart';

/// The one spinner. Sized to sit inside a line of text by default.
class Spinner extends StatelessWidget {
  final double size;
  final Color? color;

  const Spinner({super.key, this.size = 14, this.color});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CircularProgressIndicator(
      // Scaled to the diameter: a fixed stroke looks heavy at 12px and thin at
      // 28px, so spinners of different sizes still read as one component.
      strokeWidth: (size / 9).clamp(1.5, 3.0),
      valueColor: AlwaysStoppedAnimation<Color>(
        color ?? context.tokens.primary,
      ),
    ),
  );
}

/// Dims its child and swallows input while [busy].
///
/// AbsorbPointer, not IgnorePointer: a click during a save must be consumed,
/// not passed through to whatever sits underneath.
class BusyOverlay extends StatelessWidget {
  final bool busy;
  final Widget child;

  /// Shown beside the spinner. Set it for anything slow enough to look stuck.
  final String? label;

  const BusyOverlay({
    super.key,
    required this.busy,
    required this.child,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    if (!busy) return child;
    final AppTokens t = context.tokens;
    return Stack(
      children: <Widget>[
        // Dimmed rather than hidden: keeping the content in place stops the
        // page reflowing, and the operator can still read what they submitted.
        Opacity(opacity: 0.45, child: AbsorbPointer(child: child)),
        Positioned.fill(
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: t.bgApp,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: t.border),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Spinner(),
                    if (label != null) ...<Widget>[
                      const SizedBox(width: 9),
                      Text(label!, style: context.type.small),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A spinner and a line of text, for a region that has nothing to show yet.
/// Use where a skeleton would be dishonest - it implies "rows are coming",
/// which is wrong for a single record or an action's result.
class InlineBusy extends StatelessWidget {
  final String label;
  final EdgeInsets padding;

  const InlineBusy(
    this.label, {
    super.key,
    this.padding = const EdgeInsets.symmetric(vertical: 22),
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        const Spinner(size: 13),
        const SizedBox(width: 9),
        Text(
          label,
          style: context.type.small.copyWith(color: context.tokens.textMuted),
        ),
      ],
    ),
  );
}
