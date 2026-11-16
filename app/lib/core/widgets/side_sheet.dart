import 'package:flutter/material.dart';

import '../theme/portal_tokens.dart';
import 'portal_page.dart';

/// A detail panel: a drawer at the right edge on a wide screen, a bottom sheet on a phone. [builder]
/// gets a context whose Navigator pops the panel; the pop's result is returned.
Future<T?> showSideSheet<T>(BuildContext context, {required String title, required WidgetBuilder builder, double width = 440}) {
  final t = PortalTokens.of(context);
  final wide = MediaQuery.sizeOf(context).width >= Layout.wide;
  if (!wide) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.bgApp,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (ctx, controller) => _SheetBody(title: title, controller: controller, child: builder(ctx)),
      ),
    );
  }
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: t.scrim,
    transitionDuration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 180),
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
      child: child,
    ),
    pageBuilder: (ctx, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: t.bgApp,
        shape: RoundedRectangleBorder(side: BorderSide(color: t.border)),
        child: SizedBox(
          width: width,
          height: double.infinity,
          child: _SheetBody(title: title, child: builder(ctx)),
        ),
      ),
    ),
  );
}

class _SheetBody extends StatelessWidget {
  const _SheetBody({required this.title, required this.child, this.controller});
  final String title;
  final Widget child;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: Sizes.topBar,
          padding: const EdgeInsets.only(left: Space.x16, right: Space.x8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(title, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                key: const Key('sheet-close'),
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(controller: controller, padding: const EdgeInsets.all(Space.x16), child: child),
        ),
      ],
    );
  }
}
