import 'package:flutter/material.dart';

import '../theme/portal_tokens.dart';

/// The studio board behind every signed-in page and the sign-in screen: the page colour with a magenta
/// bloom at the top left and a teal one at the bottom right (the Social AI studio's `.dash-stage`).
/// Cards on it are translucent, so the blooms show through them.
class StudioBackdrop extends StatelessWidget {
  const StudioBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    RadialGradient bloom(Alignment at, Color c, double radius) =>
        RadialGradient(center: at, radius: radius, colors: [c, c.withValues(alpha: 0)], stops: const [0, 1]);
    return DecoratedBox(
      key: const Key('studio-backdrop'),
      decoration: BoxDecoration(color: t.bgSubtle),
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: bloom(const Alignment(-0.7, -1.1), t.bloomA, 1.0)),
        child: DecoratedBox(
          decoration: BoxDecoration(gradient: bloom(const Alignment(1.0, 1.0), t.bloomB, 0.9)),
          child: child,
        ),
      ),
    );
  }
}
