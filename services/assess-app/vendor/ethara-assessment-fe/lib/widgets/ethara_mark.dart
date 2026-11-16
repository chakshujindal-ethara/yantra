import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/theme/portal_tokens.dart';

/// The Ethara brand mark, from the same `ethara-mark.svg` the host portal
/// ships, so both products show one identity.
///
/// Pass [color] to tint it; the asset's own near-white fill is only right on a
/// dark canvas, and this app supports both themes.
///
/// Pass [spin] to revolve it, which the host portal's sign-in page does. It is
/// deliberately opt-in: the mark also appears at 40px in the compact login
/// layout and would read as a spinner - an "I am loading" promise nothing here
/// keeps - rather than as a brand.
class EtharaMark extends StatefulWidget {
  const EtharaMark({
    super.key,
    this.size = 24,
    this.color,
    this.spin = false,
    this.period = const Duration(seconds: 10),
  });

  final double size;
  final Color? color;

  /// Revolve continuously. Ignored when the OS asks for reduced motion.
  final bool spin;

  /// One full revolution.
  ///
  /// MEASURED off the host portal rather than picked, so the two products turn
  /// at the same rate. Its sign-in page was sampled with a wall-clock stamp per
  /// frame and the mark's silhouette width extracted; the width traces |cos|,
  /// so it touches zero every quarter turn and the interval between those
  /// minima is half a revolution. Those intervals came out at 5024ms and
  /// 4967ms - a 10.0s revolution.
  ///
  /// Timestamps, not a frame count: screenshot overhead makes the real sampling
  /// interval drift well off its nominal value, and it differs between a local
  /// page and a remote one. Counting frames instead made this 7.4s, which is
  /// visibly faster than the portal.
  final Duration period;

  @override
  State<EtharaMark> createState() => _EtharaMarkState();
}

class _EtharaMarkState extends State<EtharaMark>
    with SingleTickerProviderStateMixin {
  AnimationController? _spin;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(EtharaMark old) {
    super.didUpdateWidget(old);
    if (old.spin != widget.spin || old.period != widget.period) _sync();
  }

  /// Create, retune or tear down the controller to match the current props and
  /// the OS motion preference.
  ///
  /// Built here rather than in `initState` because `Motion.reducedMotion` reads
  /// `MediaQuery`, which is not available that early - and because the setting
  /// can change while the page is open, which `didChangeDependencies` catches
  /// and `initState` would not.
  void _sync() {
    final bool wanted = widget.spin && !Motion.reducedMotion(context);
    if (!wanted) {
      _spin?.dispose();
      _spin = null;
      return;
    }
    _spin ??= AnimationController(vsync: this);
    _spin!.duration = widget.period;
    _spin!.repeat();
  }

  @override
  void dispose() {
    _spin?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget mark = SvgPicture.asset(
      'assets/ethara-mark.svg',
      width: widget.size,
      height: widget.size,
      colorFilter: widget.color == null
          ? null
          : ColorFilter.mode(widget.color!, BlendMode.srcIn),
    );
    final AnimationController? spin = _spin;
    if (spin == null) return mark;
    // Around the VERTICAL axis, the way a planet turns - NOT the in-plane spin
    // a RotationTransition gives, which reads as a clock hand or a loading
    // wheel. rotateY sweeps the mark edge-on and back twice per revolution.
    //
    // ORTHOGRAPHIC, deliberately: no perspective divisor. An earlier pass set
    // one (`..setEntry(3, 2, 0.0015)`), which grows the near edge as it comes
    // forward and reads as a card being tilted. The host portal does not do
    // that - sampling its mark frame by frame gives a silhouette whose width
    // is a clean, symmetric |cos| and whose height never moves, which is what
    // a flat rotation with no perspective looks like. Matching it means
    // leaving the projection alone.
    //
    // `child` is passed to AnimatedBuilder rather than built inside it, so the
    // 41 KB SVG is rasterised once instead of on every tick of an animation
    // that never stops.
    return AnimatedBuilder(
      animation: spin,
      child: mark,
      builder: (BuildContext context, Widget? child) => Transform(
        alignment: Alignment.center,
        transform: Matrix4.rotationY(spin.value * 2 * math.pi),
        child: child,
      ),
    );
  }
}
