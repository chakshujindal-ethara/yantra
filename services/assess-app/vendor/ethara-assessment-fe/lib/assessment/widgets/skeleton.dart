// Loading placeholders - HANDOVER §2.3 (panels), §7.1 (page envelope).
//
// WHY SKELETONS RATHER THAN A SPINNER: every admin screen fetches on entry, and
// a centred spinner throws the layout away and rebuilds it as content lands. A
// skeleton holds the shape it is about to become, so the layout never shifts.
//
// One controller per screen drives every block: a ticker each would put every
// block on its own phase, which reads as a fault rather than a wait.
import 'package:flutter/material.dart';

import '../theme.dart';
import 'panel.dart';

/// Drives the pulse for every [Skeleton] beneath it. Optional - a skeleton
/// outside a theme renders flat, so it stays usable in a sheet or a test.
class SkeletonTheme extends StatefulWidget {
  const SkeletonTheme({super.key, required this.child});

  final Widget child;

  @override
  State<SkeletonTheme> createState() => _SkeletonThemeState();
}

class _SkeletonThemeState extends State<SkeletonTheme>
    with SingleTickerProviderStateMixin {
  /// Created only when this theme is the OUTERMOST one.
  ///
  /// Nullable and lazily built, not `late final`: a nested theme reuses its
  /// ancestor's animation and never touches this, and a `late final` would then
  /// be initialised by `dispose()` itself - creating a ticker against an element
  /// that is already deactivated, which Flutter asserts on.
  AnimationController? _c;

  AnimationController get _controller => _c ??= AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reuse an ancestor's ticker when there is one.
    //
    // The file's own rule is one controller per screen, but the composites
    // nested a theme inside a theme: ListScreenSkeleton opened one and then
    // KpiStripSkeleton and TableSkeleton opened their own, so three controllers
    // ran where one was promised. They looked in phase only because all three
    // started at t=0; anything mounted later drifted permanently and read as a
    // fault rather than a wait.
    if (_SkeletonScope.of(context) != null) return widget.child;
    return _SkeletonScope(animation: _controller, child: widget.child);
  }
}

class _SkeletonScope extends InheritedWidget {
  const _SkeletonScope({required this.animation, required super.child});

  final Animation<double> animation;

  static Animation<double>? of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<_SkeletonScope>()?.animation;

  @override
  bool updateShouldNotify(_SkeletonScope old) => animation != old.animation;
}

/// One grey block that pulses. Stretches unless given a [width].
class Skeleton extends StatelessWidget {
  const Skeleton({super.key, this.width, this.height = 12, this.radius});

  final double? width;
  final double height;
  final BorderRadius? radius;

  @override
  Widget build(BuildContext context) {
    final Widget box = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: context.tokens.border,
        borderRadius: radius ?? BorderRadius.circular(4),
      ),
    );
    final Animation<double>? anim = _SkeletonScope.of(context);
    if (anim == null) return box;
    return AnimatedBuilder(
      animation: anim,
      // Opacity, not a travelling gradient: the gradient repaints the whole
      // block every frame, and a list screen carries a dozen of them.
      builder: (_, Widget? child) => Opacity(
        opacity: 0.45 + 0.35 * (1 - (anim.value - 0.5).abs() * 2),
        child: child,
      ),
      child: box,
    );
  }
}

/// The KPI strip, before the numbers land.
class KpiStripSkeleton extends StatelessWidget {
  const KpiStripSkeleton({super.key, this.count = 4});

  final int count;

  @override
  Widget build(BuildContext context) => SkeletonTheme(
    child: Row(
      children: <Widget>[
        for (int i = 0; i < count; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 12),
          const Expanded(
            child: Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Skeleton(width: 90, height: 10),
                  SizedBox(height: 12),
                  Skeleton(width: 56, height: 26),
                  SizedBox(height: 10),
                  Skeleton(width: 70, height: 10),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

/// A table, before its rows land. Mirrors the real grid's column weights so the
/// page does not reflow when the data arrives.
class TableSkeleton extends StatelessWidget {
  const TableSkeleton({super.key, this.rows = 5, this.columns = 5});

  final int rows;
  final int columns;

  @override
  Widget build(BuildContext context) => SkeletonTheme(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int r = 0; r < rows; r++) ...<Widget>[
          if (r > 0)
            Divider(height: 1, thickness: 1, color: context.tokens.border),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              children: <Widget>[
                for (int c = 0; c < columns; c++) ...<Widget>[
                  if (c > 0) const SizedBox(width: 16),
                  // Column 0 is the record name, sized like the real one.
                  Expanded(
                    flex: c == 0 ? 3 : 1,
                    child: Skeleton(width: c == 0 ? null : 60),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    ),
  );
}

/// The chatter timeline, before its entries land.
class ChatterSkeleton extends StatelessWidget {
  const ChatterSkeleton({super.key, this.lines = 3});

  final int lines;

  @override
  Widget build(BuildContext context) => SkeletonTheme(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < lines; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == lines - 1 ? 0 : 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // The rail dot, matching the real timeline's.
                const Padding(
                  padding: EdgeInsets.only(top: 5),
                  child: Skeleton(width: 9, height: 9, radius: Radii.pill),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Skeleton(width: 160, height: 10),
                      SizedBox(height: 7),
                      Skeleton(),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// A whole list screen - head, KPI strip, table - for first paint.
class ListScreenSkeleton extends StatelessWidget {
  const ListScreenSkeleton({super.key, this.kpis = 4, this.rows = 5});

  final int kpis;
  final int rows;

  @override
  Widget build(BuildContext context) => PageBody(
    children: <Widget>[
      // ONE theme over the whole page, so the nested themes inside
      // KpiStripSkeleton and TableSkeleton find it and reuse its ticker. These
      // three were SIBLINGS once: three controllers, drifting out of phase.
      SkeletonTheme(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Skeleton(width: 220, height: 26),
                  SizedBox(height: 8),
                  Skeleton(width: 380),
                ],
              ),
            ),
            KpiStripSkeleton(count: kpis),
            const SizedBox(height: 16),
            Panel(flush: true, child: TableSkeleton(rows: rows)),
          ],
        ),
      ),
    ],
  );
}

/// A whole DETAIL screen: crumbs, head, a couple of panels. Not
/// [ListScreenSkeleton]: no KPI strip or wide table, so that shape would
/// promise a layout this page never becomes. Shown while a record's fetch is in
/// flight, which used to render as "not found - it may have been removed".
class DetailScreenSkeleton extends StatelessWidget {
  const DetailScreenSkeleton({super.key});

  @override
  Widget build(BuildContext context) => PageBody(
    children: const <Widget>[
      SkeletonTheme(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Skeleton(width: 260, height: 10),
            SizedBox(height: 16),
            Skeleton(width: 340, height: 26),
            SizedBox(height: 8),
            Skeleton(width: 460),
            SizedBox(height: 20),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Skeleton(width: 120, height: 10),
                  SizedBox(height: 14),
                  Skeleton(height: 14),
                  SizedBox(height: 10),
                  Skeleton(width: 520, height: 14),
                ],
              ),
            ),
            SizedBox(height: 14),
            Panel(flush: true, child: TableSkeleton(rows: 3, columns: 4)),
          ],
        ),
      ),
    ],
  );
}
