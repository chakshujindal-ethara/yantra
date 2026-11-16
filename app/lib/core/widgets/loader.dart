import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/portal_tokens.dart';

/// The brand mark with a turning ring: what a page shows while it waits for its first data. Still when
/// the person asks for reduced motion. Use [Skeleton] rows for a list inside a page that has loaded.
class BrandLoader extends StatefulWidget {
  const BrandLoader({super.key, this.size = 44, this.label = 'Loading'});
  final double size;
  final String label;

  @override
  State<BrandLoader> createState() => _BrandLoaderState();
}

class _BrandLoaderState extends State<BrandLoader> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void initState() {
    super.initState();
    _spin.repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    final ring = CustomPaint(
      size: Size.square(widget.size),
      painter: _ArcPainter(color: t.primary, track: t.border),
    );
    return Semantics(
      label: widget.label,
      liveRegion: true,
      child: Center(
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              reduce ? ring : RotationTransition(turns: _spin, child: ring),
              Container(
                width: widget.size * 0.5,
                height: widget.size * 0.5,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: t.primary, borderRadius: Radii.rSm),
                child: Text(
                  'Y',
                  style: TextStyle(color: Colors.white, fontSize: widget.size * 0.28).merge(AppTheme.weight(FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  const _ArcPainter({required this.color, required this.track});
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final stroke = size.width * 0.07;
    canvas.drawArc(
      rect.deflate(stroke),
      0,
      6.283,
      false,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    canvas.drawArc(
      rect.deflate(stroke),
      -1.2,
      1.9,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = stroke,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.color != color || old.track != track;
}

/// A toast at the bottom: the outcome of an action in one line, with an optional undo-style action.
void toast(BuildContext context, String message, {String? actionLabel, VoidCallback? onAction}) {
  final t = PortalTokens.of(context);
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: t.textPrimary,
        action: actionLabel == null || onAction == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction, textColor: t.bgApp),
      ),
    );
}
