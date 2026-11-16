import 'package:flutter/material.dart';

import '../theme/portal_tokens.dart';

/// Everything clickable that is not a Material button goes through here: the click cursor, hover,
/// Enter/Space activation (from [InkWell]), a button node for assistive tech, and keyboard focus shown
/// as a 2px ring in the ring colour, never a fill alone.
class PortalTappable extends StatefulWidget {
  const PortalTappable({
    super.key,
    required this.onTap,
    required this.child,
    this.borderRadius = Radii.rMd,
    this.semanticsLabel,
    this.selected = false,
    this.hoverColor,
  });

  final VoidCallback? onTap;
  final Widget child;
  final BorderRadius borderRadius;
  final String? semanticsLabel;
  final bool selected;
  final Color? hoverColor;

  @override
  State<PortalTappable> createState() => _PortalTappableState();
}

class _PortalTappableState extends State<PortalTappable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Semantics(
      button: widget.onTap != null,
      selected: widget.selected ? true : null,
      label: widget.semanticsLabel,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: widget.borderRadius,
        hoverColor: widget.hoverColor ?? t.bgHover,
        focusColor: Colors.transparent,
        mouseCursor: widget.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onFocusChange: (f) => setState(() => _focused = f),
        child: DecoratedBox(
          key: const Key('tappable-ring'),
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            border: _focused ? Border.all(color: t.ring, width: 2) : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
