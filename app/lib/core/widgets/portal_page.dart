import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../page_commands.dart';
import '../theme/portal_tokens.dart';

/// Layout constants shared by every page. A number a screen needs that is not here becomes a constant here.
abstract final class Layout {
  /// Below this width the shell paints a bottom bar instead of a sidebar.
  static const double wide = 960;

  /// Below this width two-column compositions stack.
  static const double twoColumn = 760;

  /// Below this width page padding drops from 24 to 16.
  static const double sm = 640;

  /// The policies page's table of contents.
  static const double tocWidth = 240;

  /// The side menu is a [rail] of icons at every wide width; it opens to [railOpen] over the page on hover or
  /// keyboard focus.
  static const double rail = 64;
  static const double railOpen = 252;

  /// The wide shell's top bar (the narrow one keeps [Sizes.topBar]).
  static const double topBarWide = 64;

  /// Pages fill the window, the way the studio's do; only very wide screens stop growing the line length.
  static const double pageMax = 1760;
  static const double pageMaxNarrow = 760;
  static const double pagePad = 24;
  static const double pagePadSm = 16;
  static const double gap = 16;
}

/// The canvas of every screen: page backdrop, capped width, responsive padding, an optional header,
/// then the children as a scrollable column. Pull-to-refresh when [onRefresh] is given.
class PortalPage extends StatelessWidget {
  const PortalPage({
    super.key,
    this.title,
    this.subtitle,
    this.kicker,
    this.actions = const [],
    required this.children,
    this.maxWidth = Layout.pageMax,
    this.onRefresh,
    this.controller,
    this.footer,
    this.commands = const [],
  });

  final String? title;
  final String? subtitle;
  final String? kicker;
  final List<Widget> actions;
  final List<Widget> children;
  final double maxWidth;
  final Future<void> Function()? onRefresh;
  final ScrollController? controller;

  /// Pinned under the scrolling content (a sticky action bar).
  final Widget? footer;

  /// The page's actions offered in the command palette while this page is on screen.
  final List<PageCommand> commands;

  @override
  Widget build(BuildContext context) {
    final page = _page(context);
    final framed = footer == null
        ? page
        : Column(
            children: [
              Expanded(child: page),
              footer!,
            ],
          );
    return commands.isEmpty ? framed : _RegisterCommands(commands: commands, child: framed);
  }

  Widget _page(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final pad = c.maxWidth < Layout.sm ? Layout.pagePadSm : Layout.pagePad;
        final list = ListView(
          controller: controller,
          padding: EdgeInsets.symmetric(horizontal: pad, vertical: pad),
          children: [
            if (title != null) PageHeader(title: title!, subtitle: subtitle, kicker: kicker, actions: actions),
            ...children,
          ],
        );
        // SelectionArea makes every Text copyable without turning it into a disabled text box for
        // assistive technology (which is what SelectableText does on the web). No fill of its own: the
        // shell's backdrop (the board and its blooms) shows behind the page.
        return Material(
          type: MaterialType.transparency,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: SelectionArea(
                child: onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Registers a page's palette commands under its location while it is mounted.
class _RegisterCommands extends StatefulWidget {
  const _RegisterCommands({required this.commands, required this.child});
  final List<PageCommand> commands;
  final Widget child;

  @override
  State<_RegisterCommands> createState() => _RegisterCommandsState();
}

class _RegisterCommandsState extends State<_RegisterCommands> {
  PageCommands? _registry;
  String? _location;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _register();
  }

  @override
  void didUpdateWidget(_RegisterCommands oldWidget) {
    super.didUpdateWidget(oldWidget);
    _register();
  }

  void _register() {
    _registry = PageCommandsScope.maybeOf(context);
    String? location;
    try {
      location = GoRouterState.of(context).uri.path;
    } on Object {
      location = null; // not under a route (a widget test of the page alone): nothing to register
    }
    _location = location;
    if (location != null) _registry?.set(location, widget.commands);
  }

  @override
  void dispose() {
    final location = _location;
    if (location != null) _registry?.clear(location, widget.commands);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Title, a one-line subtitle and the page's actions, wrapping on narrow widths.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.kicker, this.actions = const []});

  final String title;

  /// A small uppercase line above the title ("OPERATE · PROJECTS"), the way the studio's pages open.
  final String? kicker;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x20),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: Space.x12,
        spacing: Space.x12,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (kicker != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.x4),
                  child: Text(
                    kicker!.toUpperCase(),
                    // the studio's kicker: small, wide-tracked, in the accent
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: PortalTokens.of(context).primary,
                      fontSize: 10.5,
                      letterSpacing: 1.7,
                    ),
                  ),
                ),
              Text(title, style: theme.textTheme.headlineMedium),
              if (subtitle != null) ...[
                const SizedBox(height: Space.x4),
                Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(fontSize: 12.5, color: PortalTokens.of(context).textSecondary)),
              ],
            ],
          ),
          if (actions.isNotEmpty) Wrap(spacing: Space.x8, runSpacing: Space.x8, children: actions),
        ],
      ),
    );
  }
}

/// Two columns above [Layout.twoColumn], stacked below. [ratio] is the left share (1.15 = 1.15fr / 1fr).
class TwoColumn extends StatelessWidget {
  const TwoColumn({super.key, required this.left, required this.right, this.ratio = 1.0, this.gap = Layout.gap});

  final Widget left;
  final Widget right;
  final double ratio;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < Layout.twoColumn) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              left,
              SizedBox(height: gap),
              right,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: (ratio * 100).round(), child: left),
            SizedBox(width: gap),
            Expanded(flex: 100, child: right),
          ],
        );
      },
    );
  }
}
