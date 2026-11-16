import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/portal_tokens.dart';

/// One step of a breadcrumb trail. A crumb with a [path] links back to that page.
class Crumb {
  const Crumb(this.label, {this.path});
  final String label;
  final String? path;
}

/// The frame of a detail page inside the shell: a slim bar with the back arrow and the breadcrumb trail
/// (`Operate › Projects › Hindi transcription`), the page's actions at its end, the [body] below it, and
/// an optional [footer] pinned under the body (a sticky submit bar on phones). The sidebar stays: the
/// detail is a page of its destination's branch.
class DetailFrame extends StatelessWidget {
  const DetailFrame({super.key, required this.crumbs, this.actions = const [], required this.body, this.footer});

  final List<Crumb> crumbs;
  final List<Widget> actions;
  final Widget body;
  final Widget? footer;

  /// Back: the page below in this branch when there is one (it keeps its scroll); otherwise, on a deep
  /// link, the nearest linked crumb. Both pass through the route's exit guard.
  static Future<void> back(BuildContext context, List<Crumb> crumbs) async {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      await navigator.maybePop();
      return;
    }
    final parent = crumbs.lastWhere((c) => c.path != null, orElse: () => const Crumb(''));
    if (parent.path != null && context.mounted) context.go(parent.path!);
  }

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    // no fill of its own: the shell's studio board shows behind a detail page as behind any other
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: Space.x16),
            decoration: BoxDecoration(
              color: t.card,
              border: Border(bottom: BorderSide(color: t.cardLine)),
            ),
            child: Row(
              children: [
                BackButton(key: const Key('back'), onPressed: () => back(context, crumbs)),
                const SizedBox(width: Space.x4),
                Expanded(child: Breadcrumbs(crumbs: crumbs)),
                ...actions,
              ],
            ),
          ),
          Expanded(child: body),
          ?footer,
        ],
      ),
    );
  }
}

/// The trail itself: linked crumbs go to their page, the last crumb is where you are.
class Breadcrumbs extends StatelessWidget {
  const Breadcrumbs({super.key, required this.crumbs});
  final List<Crumb> crumbs;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final small = theme.textTheme.labelMedium;
    return Semantics(
      container: true,
      label: 'Breadcrumb',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: Row(
          children: [
            for (final (i, c) in crumbs.indexed) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.x4),
                  child: Icon(Icons.chevron_right, size: Sizes.iconSm, color: t.textMuted),
                ),
              if (i == crumbs.length - 1)
                Text(c.label, key: const Key('crumb-current'), style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis)
              else if (c.path != null)
                TextButton(
                  key: Key('crumb-$i'),
                  onPressed: () => context.go(c.path!),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: Space.x6),
                    foregroundColor: t.textSecondary,
                    textStyle: small,
                  ),
                  child: Text(c.label),
                )
              else
                Text(c.label, style: small?.copyWith(color: t.textSecondary)),
            ],
          ],
        ),
      ),
    );
  }
}
