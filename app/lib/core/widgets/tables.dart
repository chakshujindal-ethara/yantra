import 'package:flutter/material.dart';

import '../theme/portal_tokens.dart';
import 'tappable.dart';

/// A column of a [PortalTable]. [numeric] right-aligns, with tabular digits; [flex] shares the width.
class PortalColumn {
  const PortalColumn(this.label, {this.flex = 1, this.numeric = false, this.width});
  final String label;
  final int flex;
  final bool numeric;

  /// A fixed width instead of a flex share (status chips, actions).
  final double? width;
}

/// A row of a [PortalTable]: one cell per column, built as widgets so a cell can be a chip or a button.
class PortalRow {
  const PortalRow(this.cells, {this.onTap, this.key, this.selected = false});
  final List<Widget> cells;
  final VoidCallback? onTap;
  final Key? key;
  final bool selected;
}

/// The data table every console page shares: a muted header row, zebra stripes, hover and focus on
/// tappable rows, numbers right-aligned with tabular digits, and a horizontal scroll below [minWidth] so phones
/// never squash the columns. Keep rows to a page; paginate with [Pager].
class PortalTable extends StatelessWidget {
  const PortalTable({
    super.key,
    required this.columns,
    required this.rows,
    this.minWidth = 640,
    this.emptyMessage = 'Nothing here yet',
    this.rowHeight = 44,
  });

  final List<PortalColumn> columns;
  final List<PortalRow> rows;
  final double minWidth;
  final String emptyMessage;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    // At large text sizes a cell may take a second line instead of clipping; the row grows to fit.
    final lines = MediaQuery.textScalerOf(context).scale(14) > 18 ? 2 : 1;
    Widget cell(PortalColumn c, Widget child, {bool header = false}) {
      final body = Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.x12),
        child: Align(
          alignment: c.numeric ? Alignment.centerRight : Alignment.centerLeft,
          child: DefaultTextStyle.merge(
            style: header
                // the studio's table heads: small and tracked (sentence case, so screen readers say the word); figures in the UI face, tabular
                ? theme.textTheme.labelSmall!.copyWith(color: t.textSecondary, fontSize: 10.5, letterSpacing: 0.8)
                : theme.textTheme.bodyMedium!,
            overflow: TextOverflow.ellipsis,
            maxLines: lines,
            child: header ? Semantics(header: true, child: child) : child,
          ),
        ),
      );
      return c.width != null ? SizedBox(width: c.width, child: body) : Expanded(flex: c.flex, child: body);
    }

    final table = ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 40),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.cardLine)),
            ),
            child: Row(children: [for (final c in columns) cell(c, Text(c.label), header: true)]),
          ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Space.x24),
              child: Text(emptyMessage, style: theme.textTheme.bodyMedium?.copyWith(color: t.textSecondary)),
            ),
          for (final (i, r) in rows.indexed)
            Material(
              key: r.key,
              color: r.selected ? t.selected : (i.isOdd ? t.zebra : Colors.transparent),
              child: () {
                final row = Container(
                  constraints: BoxConstraints(minHeight: rowHeight),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: t.cardLine)),
                  ),
                  child: Row(children: [for (final (j, c) in columns.indexed) cell(c, j < r.cells.length ? r.cells[j] : const SizedBox())]),
                );
                return r.onTap == null
                    ? row
                    : PortalTappable(onTap: r.onTap, borderRadius: BorderRadius.zero, selected: r.selected, child: row);
              }(),
            ),
        ],
      ),
    );
    return LayoutBuilder(
      // a table is a glass card on the board, like the studio's
      builder: (context, c) => DecoratedBox(
        decoration: BoxDecoration(borderRadius: Radii.rXl, boxShadow: t.isDark ? null : t.shadowCard),
        child: ClipRRect(
          borderRadius: Radii.rXl,
          child: Container(
            decoration: BoxDecoration(
              color: t.card,
              border: Border.all(color: t.cardLine),
              borderRadius: Radii.rXl,
            ),
            child: c.maxWidth < minWidth
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(width: minWidth, child: table),
                  )
                : table,
          ),
        ),
      ),
    );
  }
}

/// "1–50 of 312" with previous and next. [offset] and [limit] are the page; [total] the count.
class Pager extends StatelessWidget {
  const Pager({super.key, required this.offset, required this.limit, required this.total, required this.onPage});
  final int offset;
  final int limit;
  final int total;
  final void Function(int offset) onPage;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    if (total <= limit && offset == 0) return const SizedBox.shrink();
    final from = total == 0 ? 0 : offset + 1;
    final to = (offset + limit).clamp(0, total);
    return Padding(
      padding: const EdgeInsets.only(top: Space.x8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text('$from–$to of $total', style: theme.textTheme.labelMedium?.copyWith(color: t.textSecondary)),
          const SizedBox(width: Space.x8),
          IconButton(
            key: const Key('pager-prev'),
            tooltip: 'Previous page',
            onPressed: offset > 0 ? () => onPage((offset - limit).clamp(0, total)) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            key: const Key('pager-next'),
            tooltip: 'Next page',
            onPressed: to < total ? () => onPage(offset + limit) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

/// A row of filter chips with one selected ("All · Open · Closed"). [values] map label to the value
/// passed back; the null value means no filter.
class FilterChips<T> extends StatelessWidget {
  const FilterChips({super.key, required this.values, required this.selected, required this.onSelected});
  final Map<String, T?> values;
  final T? selected;
  final void Function(T?) onSelected;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Wrap(
      spacing: Space.x8,
      runSpacing: Space.x8,
      children: [
        for (final e in values.entries)
          ChoiceChip(
            key: Key('filter-${e.key.toLowerCase().replaceAll(' ', '-')}'),
            label: Text(e.key),
            selected: e.value == selected,
            onSelected: (_) => onSelected(e.value),
            selectedColor: t.primarySubtle,
            labelStyle: TextStyle(color: e.value == selected ? t.primary : t.textPrimary),
            side: BorderSide(color: e.value == selected ? t.borderHover : t.border),
          ),
      ],
    );
  }
}

/// The page's toolbar: a search field at the left, filters and actions at the right, wrapping on phones.
class Toolbar extends StatelessWidget {
  const Toolbar({super.key, this.search, this.children = const []});
  final Widget? search;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x12),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Space.x12,
        runSpacing: Space.x8,
        children: [
          if (search != null) ConstrainedBox(constraints: const BoxConstraints(maxWidth: 320, minWidth: 200), child: search!),
          Wrap(spacing: Space.x8, runSpacing: Space.x8, crossAxisAlignment: WrapCrossAlignment.center, children: children),
        ],
      ),
    );
  }
}
