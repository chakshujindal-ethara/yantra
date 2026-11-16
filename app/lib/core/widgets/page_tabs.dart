import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/portal_tokens.dart';
import 'tappable.dart';

/// Underline tabs for the sections of one page (System, Settings): the active tab is underlined in the
/// primary colour. For a value choice inside a card use a segmented control or filter chips instead.
/// Each tab is keyed `tab-<id>`.
class PageTabs<T> extends StatelessWidget {
  const PageTabs({super.key, required this.tabs, required this.selected, required this.onSelected});

  /// id → label, in display order.
  final Map<T, String> tabs;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: Space.x16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final e in tabs.entries)
              PortalTappable(
                key: Key('tab-${e.key is Enum ? (e.key as Enum).name : e.key}'),
                onTap: () => onSelected(e.key),
                semanticsLabel: e.value,
                selected: e.key == selected,
                child: Padding(
                  padding: const EdgeInsets.only(right: Space.x8),
                  // sized to its label, so the underline spans the tab (a Row gives no width to stretch into)
                  child: IntrinsicWidth(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Space.x12, vertical: Space.x12),
                          child: Text(
                            e.value,
                            style: theme.textTheme.labelLarge
                                ?.copyWith(color: e.key == selected ? t.textPrimary : t.textSecondary)
                                .merge(AppTheme.weight(e.key == selected ? FontWeight.w600 : FontWeight.w500)),
                          ),
                        ),
                        // the studio's tab underline: the brand gradient under the tab you are on
                        Container(
                          height: 2,
                          decoration: BoxDecoration(gradient: e.key == selected ? PortalTokens.brand : null, borderRadius: Radii.rFull),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
