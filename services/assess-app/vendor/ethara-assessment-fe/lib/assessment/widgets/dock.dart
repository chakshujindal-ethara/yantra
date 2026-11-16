// The right-hand dock, holding the record's history.
//
// WHY A DOCK. Rendered inline the chatter scrolled away while you worked, and
// on the assessment it was buried inside the Configuration tab. Odoo puts it
// beside the record permanently: history is context for the work you are
// doing, not a section of the page.
//
// WHERE IT LIVES. In the shell Row beside the nav rail, NOT inside a screen.
// That is what makes it survive navigation: the screen rebuilds on every route
// change, the dock's Element does not, so its open state and its width persist
// without being stored in the route or re-fetched.
import 'package:flutter/material.dart';

import '../../services/prefs_stub.dart'
    if (dart.library.js_interop) '../../services/prefs_web.dart';
import '../theme.dart';

const String _kOpenKey = 'etp.dock.open';
const String _kWidthKey = 'etp.dock.width';

const double kDockMin = 300;
const double kDockMax = 620;
const double kDockDefault = 380;

/// Below this the dock would leave too little for the record itself, so it
/// stops taking width and the toggle hides it entirely.
const double kDockCollapseBelow = 1080;

class ChatterDock extends StatefulWidget {
  /// The panel to show. Null means the current route has no record to discuss,
  /// in which case the dock takes no width at all.
  final Widget? child;

  final String title;

  const ChatterDock({super.key, required this.child, this.title = 'History'});

  @override
  State<ChatterDock> createState() => _ChatterDockState();
}

class _ChatterDockState extends State<ChatterDock> {
  late bool _open = readPref(_kOpenKey) != '0';
  late double _width =
      double.tryParse(readPref(_kWidthKey) ?? '')?.clamp(kDockMin, kDockMax) ??
      kDockDefault;
  bool _dragging = false;

  void _toggle() {
    setState(() => _open = !_open);
    writePref(_kOpenKey, _open ? '1' : '0');
  }

  void _resize(double dx) {
    setState(() {
      // Minus: dragging the handle LEFT widens a right-hand panel.
      _width = (_width - dx).clamp(kDockMin, kDockMax);
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    if (widget.child == null) return const SizedBox.shrink();

    final double available = MediaQuery.sizeOf(context).width;
    if (available < kDockCollapseBelow) return const SizedBox.shrink();

    if (!_open) {
      // A hairline rail: without it the toggle vanishes with the panel.
      return _ReopenRail(onTap: _toggle);
    }

    return Row(
      children: <Widget>[
        _Handle(
          active: _dragging,
          onStart: () => setState(() => _dragging = true),
          onUpdate: _resize,
          onEnd: () {
            setState(() => _dragging = false);
            writePref(_kWidthKey, _width.toStringAsFixed(0));
          },
        ),
        SizedBox(
          width: _width,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: t.bgSubtle,
              border: Border(left: BorderSide(color: t.border)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _DockHead(title: widget.title, onClose: _toggle),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
                    child: widget.child,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DockHead extends StatelessWidget {
  final String title;
  final VoidCallback onClose;

  const _DockHead({required this.title, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      height: 42,
      padding: const EdgeInsets.only(left: 14, right: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: <Widget>[
          Text(
            title.toUpperCase(),
            style: context.type.eyebrow.copyWith(color: t.textSecondary),
          ),
          const Spacer(),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onClose,
              child: Tooltip(
                message: 'Hide the history panel',
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    Icons.chevron_right,
                    size: 17,
                    color: t.textMuted,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The drag handle. 7px of hit area over a 1px line - a 1px target is unusable.
class _Handle extends StatelessWidget {
  final bool active;
  final VoidCallback onStart;
  final void Function(double dx) onUpdate;
  final VoidCallback onEnd;

  const _Handle({
    required this.active,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        // Opaque so the drag is caught over whatever is behind the handle.
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => onStart(),
        onHorizontalDragUpdate: (DragUpdateDetails d) => onUpdate(d.delta.dx),
        onHorizontalDragEnd: (_) => onEnd(),
        child: SizedBox(
          width: 7,
          child: Center(
            child: Container(
              width: 1,
              color: active ? t.primary : Colors.transparent,
            ),
          ),
        ),
      ),
    );
  }
}

class _ReopenRail extends StatelessWidget {
  final VoidCallback onTap;

  const _ReopenRail({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 28,
          decoration: BoxDecoration(
            color: t.bgSubtle,
            border: Border(left: BorderSide(color: t.border)),
          ),
          child: Tooltip(
            message: 'Show the history panel',
            child: Column(
              children: <Widget>[
                const SizedBox(height: 13),
                Icon(Icons.chevron_left, size: 16, color: t.textMuted),
                const SizedBox(height: 10),
                // Vertical label, so a 28px rail still says what it opens.
                RotatedBox(
                  quarterTurns: 3,
                  child: Text(
                    'HISTORY',
                    style: context.type.eyebrow.copyWith(color: t.textMuted),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
