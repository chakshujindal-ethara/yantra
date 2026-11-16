// The dense table - HANDOVER §7.3. Rules enforced here, not at each call site:
//   - Headers are 10.5px uppercase .05em.
//   - Numerals are mono with tabular figures; numeric columns right-aligned.
//   - A status is a pill, never bare text.
//   - An empty result is a sentence saying what to change, never a blank body.
//   - Rows that navigate carry `.clickable`; the first cell takes the accent.
//   - Horizontal overflow is contained by `.gridwrap`, never the page body.
import 'package:flutter/material.dart';
import '../domain/enums.dart';
import '../theme.dart';
import 'empty_state.dart';
import 'marks.dart';

/// Where a column's content sits inside the width it was given.
///
/// A THIRD OPTION EXISTS BECAUSE TWO WERE NOT ENOUGH. Alignment used to be
/// derived from [Col.numeric] alone - right for numbers, left for everything
/// else - which is fine on a table whose columns are all one kind and visibly
/// wrong on one that mixes them. On the candidate roster it put a right-aligned
/// SCORE header hard against a left-aligned RESULT header with no gap at all,
/// while the columns either side of them carried 60px of dead space. The eye
/// reads that as columns of random width rather than as a table.
enum ColAlign { start, center, end }

class Col {
  final String label;

  /// Fixed width. When null the column shares the remaining space by [flex].
  final double? width;
  final int flex;

  /// Numeric columns use tabular figures and put the sort caret on the left.
  ///
  /// It NO LONGER decides alignment on its own - see [align]. It still decides
  /// the caret side, because a caret between a right-aligned header and the
  /// column beside it is the collision described above in miniature.
  final bool numeric;

  /// Where content sits in the column. Defaults to the old behaviour -
  /// [ColAlign.end] for numeric, [ColAlign.start] otherwise - so every grid in
  /// the app that does not ask for anything is pixel-identical to before.
  final ColAlign? align;

  ColAlign get alignment => align ?? (numeric ? ColAlign.end : ColAlign.start);

  Alignment get _a => switch (alignment) {
    ColAlign.start => Alignment.centerLeft,
    ColAlign.center => Alignment.center,
    ColAlign.end => Alignment.centerRight,
  };

  /// THE HEADER FOLLOWS THE CELLS, always. A header on a different axis from
  /// the data under it is the other half of what made the roster look shaky:
  /// the label and the value it names appeared to belong to different columns.
  TextAlign get textAlign => switch (alignment) {
    ColAlign.start => TextAlign.left,
    ColAlign.center => TextAlign.center,
    ColAlign.end => TextAlign.right,
  };

  /// Whether clicking this header orders the table by it. OPT-IN: a column with
  /// no data behind it (a checkbox gutter, a row action) must leave this false,
  /// or the header advertises an ordering that cannot exist.
  final bool sortable;

  const Col(
    this.label, {
    this.width,
    this.flex = 1,
    this.numeric = false,
    this.align,
    this.sortable = false,
  });
}

class GridRow {
  final List<Widget> cells;
  final VoidCallback? onTap;

  /// The record this row stands for, when the grid is selectable.
  ///
  /// SELECTION IS KEYED ON THIS, never on the row index. A grid re-sorts and
  /// re-filters underneath a selection - typing in the search box rebuilds
  /// every row - and an index-keyed selection would silently come to mean
  /// different records than the ones the operator ticked. On a control whose
  /// next step is a bulk delete, that is not a cosmetic bug.
  final String? id;

  const GridRow(this.cells, {this.onTap, this.id});
}

/// One bucket of rows in a grouped grid, holding sub-groups or rows or both.
/// Nesting expresses "Assessment, then candidate" without a re-filter.
class GridGroup {
  /// Stable identity for the open/closed state.
  ///
  /// MUST encode the axis as well as the value. Keyed on the label alone, a
  /// candidate and an assessment that happen to share a name are one key, and
  /// opening either opens both.
  final String key;
  final String label;

  /// Rows underneath, counted across every level below. Shown on the header so
  /// a closed group still says how much it is hiding.
  final int count;

  /// Aggregates, keyed by COLUMN INDEX, so a total sits under the column it
  /// totals. Only TRAILING fixed-width columns can carry one: everything before
  /// the first aggregated column is merged into the label region, so an
  /// aggregate on a flex column would not line up with the rows beneath it.
  final Map<int, Widget> aggregates;

  final List<GridRow> rows;
  final List<GridGroup> groups;

  const GridGroup({
    required this.key,
    required this.label,
    required this.count,
    this.aggregates = const <int, Widget>{},
    this.rows = const <GridRow>[],
    this.groups = const <GridGroup>[],
  });
}

/// One rendered line of a grouped grid: a group header, or a data row.
///
/// The tree is flattened before anything is built so zebra striping and the
/// last row's missing border can be decided across the WHOLE table. Deciding
/// them per group instead restarted the stripe inside every bucket and drew a
/// divider under the final row, which reads as a cut-off table.
class _Entry {
  final GridGroup? group;
  final GridRow? row;
  final int depth;
  final bool open;

  const _Entry.group(this.group, this.depth, this.open) : row = null;
  const _Entry.row(this.row, this.depth) : group = null, open = false;

  bool get isGroup => group != null;
}

/// `table.grid` inside a `.gridwrap`.
class DataGrid extends StatelessWidget {
  final List<Col> cols;
  final List<GridRow> rows;

  /// The sentence shown when there is nothing to list. It should say what to
  /// change, not merely that the list is empty.
  final String emptyMessage;

  /// The one thing to do about an empty list, when there is one - it turns the
  /// empty state into a route rather than a dead end.
  final Widget? emptyAction;

  /// The glyph for the empty state. Defaults to a generic tray; pass one that
  /// matches the domain so the state reads as designed rather than templated.
  final IconData emptyIcon;

  /// The natural width the table wants before it starts scrolling sideways.
  final double minWidth;

  /// Force every row to exactly this height instead of the usual 40 floor.
  ///
  /// For a table that has to line up with ANOTHER table. Row height is
  /// normally content-driven, so a grid whose cells carry a progress bar over
  /// a caption is taller per row than one carrying a single line - 42.5 against
  /// 40 on the dashboard, which is 25px of drift over a ten-row page and reads
  /// as two misaligned cards. Cells are clipped to the height rather than
  /// allowed to grow it.
  final double? rowHeight;

  /// Ids currently ticked. Non-null turns the checkbox column on. Deliberately
  /// CONTROLLED: the toolbar that acts on a selection lives outside the table
  /// and has to be able to read and clear it.
  final Set<String>? selected;

  /// Called with the new full selection whenever a box is ticked.
  final ValueChanged<Set<String>>? onSelectionChanged;

  /// Rows bucketed into groups. Non-null renders the grouped view and [rows] is
  /// ignored, so a screen can switch between the two by passing one or other.
  final List<GridGroup>? groups;

  /// Whether a group is open. CONTROLLED like the selection above: which levels
  /// default to open is a policy, and policy belongs to the screen.
  final bool Function(String key, int depth)? isGroupOpen;
  final void Function(String key, int depth)? onToggleGroup;

  /// The column index the table is ordered by, and which way. Null orders by
  /// nothing, which is the natural order the caller supplied.
  final int? sortCol;
  final bool sortAsc;

  /// Called with the column index a header was clicked on. The CALLER decides
  /// what that means, because only the caller knows what the column holds.
  final ValueChanged<int>? onSort;

  const DataGrid({
    super.key,
    required this.cols,
    this.rows = const <GridRow>[],
    this.emptyMessage = 'Nothing here yet.',
    this.emptyAction,
    this.emptyIcon = Icons.inbox_outlined,
    this.minWidth = 720,
    this.rowHeight,
    this.selected,
    this.onSelectionChanged,
    this.groups,
    this.isGroupOpen,
    this.onToggleGroup,
    this.sortCol,
    this.sortAsc = true,
    this.onSort,
  });

  /// The tree, in render order, with closed groups' contents left out.
  List<_Entry> _flatten(List<GridGroup> gs, int depth) {
    final List<_Entry> out = <_Entry>[];
    for (final GridGroup g in gs) {
      final bool open = isGroupOpen?.call(g.key, depth) ?? false;
      out.add(_Entry.group(g, depth, open));
      if (!open) continue;
      out.addAll(_flatten(g.groups, depth + 1));
      for (final GridRow r in g.rows) {
        out.add(_Entry.row(r, depth + 1));
      }
    }
    return out;
  }

  List<String> get _selectableIds => <String>[
    for (final GridRow r in rows)
      if (r.id != null) r.id!,
  ];

  bool get _selectable => selected != null && onSelectionChanged != null;

  void _toggle(String id) {
    final Set<String> next = <String>{...selected!};
    next.contains(id) ? next.remove(id) : next.add(id);
    onSelectionChanged!(next);
  }

  /// Select-all applies to the rows ON SCREEN - with a search active that is
  /// the filtered set, never rows the operator cannot see.
  void _toggleAll() {
    final List<String> ids = _selectableIds;
    final bool all = ids.isNotEmpty && ids.every(selected!.contains);
    final Set<String> next = <String>{...selected!};
    all ? next.removeAll(ids) : next.addAll(ids);
    onSelectionChanged!(next);
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final List<GridGroup>? gs = groups;

    if (gs == null ? rows.isEmpty : gs.isEmpty) {
      // No column headers on an empty table - headers over nothing make the
      // screen look broken rather than new; it gets the designed empty state.
      //
      // The message is authored as one sentence per screen, so it is split on
      // the first full stop: the first sentence is the headline (what is
      // true), the rest is the body (why, and what changes it).
      final int stop = emptyMessage.indexOf('. ');
      final String head = stop > 0
          ? emptyMessage.substring(0, stop)
          : emptyMessage;
      final String rest = stop > 0
          ? emptyMessage.substring(stop + 2).trim()
          : '';

      return EmptyState(
        icon: emptyIcon,
        title: head,
        body: rest,
        action: emptyAction,
      );
    }

    // Flat and grouped render through ONE loop. A second loop for the grouped
    // case would be a second place for the stripe, the borders and the
    // selection wiring to drift.
    final List<_Entry> entries = gs == null
        ? <_Entry>[for (final GridRow r in rows) _Entry.row(r, 0)]
        : _flatten(gs, 0);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double avail = c.maxWidth.isFinite ? c.maxWidth : minWidth;
        final bool scrolls = avail < minWidth;
        // Counts DATA rows only, so a group header does not consume a stripe
        // and leave two same-coloured rows touching across it.
        int striped = -1;
        final Widget table = SizedBox(
          width: scrolls ? minWidth : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _Head(
                cols: cols,
                selectable: _selectable,
                // `_selectable &&` FIRST, so `selected!` is only reached on a
                // grid that has a selection. Most grids in the app pass
                // neither callback, and dereferencing there crashed every one
                // of them inside LayoutBuilder.
                allSelected:
                    _selectable &&
                    _selectableIds.isNotEmpty &&
                    _selectableIds.every(selected!.contains),
                anySelected:
                    _selectable && _selectableIds.any(selected!.contains),
                onToggleAll: _toggleAll,
                sortCol: sortCol,
                sortAsc: sortAsc,
                onSort: onSort,
              ),
              for (int i = 0; i < entries.length; i++)
                if (entries[i].isGroup)
                  _GroupHead(
                    cols: cols,
                    group: entries[i].group!,
                    depth: entries[i].depth,
                    open: entries[i].open,
                    selectable: _selectable,
                    last: i == entries.length - 1,
                    onTap: onToggleGroup == null
                        ? null
                        : () => onToggleGroup!(
                            entries[i].group!.key,
                            entries[i].depth,
                          ),
                  )
                else
                  _Row(
                    cols: cols,
                    height: rowHeight,
                    row: entries[i].row!,
                    selectable: _selectable,
                    checked:
                        _selectable &&
                        entries[i].row!.id != null &&
                        selected!.contains(entries[i].row!.id),
                    onToggle: _selectable && entries[i].row!.id != null
                        ? () => _toggle(entries[i].row!.id!)
                        : null,
                    // Zebra on even rows, one step off the app surface. Row
                    // hover paints over it.
                    zebra: (striped += 1).isOdd ? t.zebra : t.bgApp,
                    last: i == entries.length - 1,
                  ),
            ],
          ),
        );
        // `.gridwrap` is the only element that scrolls horizontally, and the
        // fade is its scroll affordance - a bare scroller cuts the last column
        // clean at the edge and reads as a rendering fault. The right column
        // here was an Open button, so the row's primary action looked broken.
        // Drawn only when the table is wider than its box, and not
        // hit-testable, so it cannot eat a click on the cell beneath it.
        return scrolls
            ? Stack(
                children: <Widget>[
                  // AN ALWAYS-VISIBLE SCROLLBAR, not the platform default.
                  //
                  // macOS hides scrollbars until a scroll gesture starts, so a
                  // table wider than its pane looked complete: the fade at the
                  // right edge is a hint, and a hint is not an affordance. A
                  // reviewer looked for the Remarks and Flag columns, could not
                  // see them, and reported them missing - they were 700px to
                  // the right of the viewport.
                  _HScroll(child: table),
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: 28,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerRight,
                            end: Alignment.centerLeft,
                            colors: <Color>[t.bgApp, t.bgApp.o(0)],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : table;
      },
    );
  }
}

/// Width of the checkbox gutter - one constant so head and rows cannot drift.
const double _kCheckW = 34;

/// Horizontal scroll with a thumb that is always drawn.
///
/// ITS OWN WIDGET because `DataGrid` is stateless and a `ScrollController`
/// has to outlive a frame: one created inside `build` is a new object every
/// rebuild, which detaches the `Scrollbar` and resets the scroll offset
/// mid-drag.
class _HScroll extends StatefulWidget {
  const _HScroll({required this.child});

  final Widget child;

  @override
  State<_HScroll> createState() => _HScrollState();
}

class _HScrollState extends State<_HScroll> {
  final ScrollController _c = ScrollController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: _c,
    // ALWAYS VISIBLE, not the platform default. macOS hides scrollbars until
    // a gesture starts, so a table wider than its pane looked complete: the
    // fade at the right edge is a hint, and a hint is not an affordance. A
    // reviewer looked for the Remarks and Flag columns, could not find them,
    // and reported them missing - they were 700px right of the viewport.
    thumbVisibility: true,
    scrollbarOrientation: ScrollbarOrientation.bottom,
    child: SingleChildScrollView(
      controller: _c,
      scrollDirection: Axis.horizontal,
      // Room for the thumb, so it never sits over the last row.
      padding: const EdgeInsets.only(bottom: 10),
      child: widget.child,
    ),
  );
}

class _Head extends StatelessWidget {
  final List<Col> cols;
  final bool selectable;
  final bool allSelected;
  final bool anySelected;
  final VoidCallback onToggleAll;
  final int? sortCol;
  final bool sortAsc;
  final ValueChanged<int>? onSort;

  const _Head({
    required this.cols,
    this.selectable = false,
    this.allSelected = false,
    this.anySelected = false,
    required this.onToggleAll,
    this.sortCol,
    this.sortAsc = true,
    this.onSort,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
      decoration: BoxDecoration(
        color: t.bgApp,
        border: Border(bottom: BorderSide(color: t.borderSubtle)),
      ),
      child: Row(
        children: <Widget>[
          if (selectable)
            SizedBox(
              width: _kCheckW,
              // TRISTATE: an unticked box over a part-selected table reads as
              // "nothing is selected", the wrong belief before a bulk delete.
              child: Checkbox(
                value: allSelected ? true : (anySelected ? null : false),
                tristate: true,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (_) => onToggleAll(),
              ),
            ),
          for (int i = 0; i < cols.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 12),
            _cell(
              cols[i],
              _HeadCell(
                col: cols[i],
                active: sortCol == i,
                asc: sortAsc,
                onTap: onSort == null || !cols[i].sortable
                    ? null
                    : () => onSort!(i),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One header cell, and the sort affordance when the column carries one. The
/// caret is drawn ONLY on the ordering column; hover advertises the others,
/// which is why this is stateful.
class _HeadCell extends StatefulWidget {
  final Col col;
  final bool active;
  final bool asc;
  final VoidCallback? onTap;

  const _HeadCell({
    required this.col,
    required this.active,
    required this.asc,
    this.onTap,
  });

  @override
  State<_HeadCell> createState() => _HeadCellState();
}

class _HeadCellState extends State<_HeadCell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool on = widget.onTap != null;
    final bool numeric = widget.col.numeric;

    final Widget label = Text(
      widget.col.label.toUpperCase(),
      style: context.type.tableHead.copyWith(
        color: widget.active
            ? t.textPrimary
            : (_hover && on ? t.textSecondary : null),
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: widget.col.textAlign,
    );

    if (!on) return label;

    // Reserved whether or not it is drawn, so the label does not shift sideways
    // when the column becomes the sorted one.
    final Widget caret = SizedBox(
      width: 13,
      child: widget.active
          ? Icon(
              widget.asc ? Icons.arrow_upward : Icons.arrow_downward,
              size: 11,
              color: t.primary,
            )
          : (_hover
                ? Icon(Icons.unfold_more, size: 11, color: t.textMuted)
                : null),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        // Opaque so the whole cell is the target, not just the glyphs in it.
        behavior: HitTestBehavior.opaque,
        // The SORTABLE header follows its column's alignment too. A centred
        // column whose header row still packed to the start would put the
        // label and the data it names on different axes - the exact mismatch
        // `Col.textAlign` exists to remove, reintroduced one widget lower.
        child: Row(
          mainAxisAlignment: switch (widget.col.alignment) {
            ColAlign.start => MainAxisAlignment.start,
            ColAlign.center => MainAxisAlignment.center,
            ColAlign.end => MainAxisAlignment.end,
          },
          children: <Widget>[
            if (numeric) caret,
            Flexible(child: label),
            if (!numeric) caret,
          ],
        ),
      ),
    );
  }
}

/// A group header: the bucket's name, how many rows it holds, and its
/// aggregates lined up under the columns they aggregate.
class _GroupHead extends StatefulWidget {
  final List<Col> cols;
  final GridGroup group;
  final int depth;
  final bool open;
  final bool selectable;
  final bool last;
  final VoidCallback? onTap;

  const _GroupHead({
    required this.cols,
    required this.group,
    required this.depth,
    required this.open,
    required this.selectable,
    required this.last,
    this.onTap,
  });

  @override
  State<_GroupHead> createState() => _GroupHeadState();
}

class _GroupHeadState extends State<_GroupHead> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final GridGroup g = widget.group;

    // Everything before the first aggregated column merges into the label
    // region. Since the columns that follow keep their own fixed widths, the
    // merged region works out to exactly the space those leading columns
    // occupy in a data row, so the aggregates land under their own headers.
    int split = widget.cols.length;
    for (int i = 0; i < widget.cols.length; i++) {
      if (g.aggregates.containsKey(i)) {
        split = i;
        break;
      }
    }
    assert(
      !g.aggregates.keys.any(
        (int i) => i < widget.cols.length && widget.cols[i].width == null,
      ),
      'GridGroup aggregate on a flex column would not line up with the rows '
      'beneath it. Put aggregates on trailing fixed-width columns.',
    );

    final Widget body = Container(
      constraints: const BoxConstraints(minHeight: 38),
      padding: EdgeInsets.only(
        // The indent is the nesting - without it two levels read as one list.
        left: 15 + widget.depth * 18,
        right: 15,
        top: 7,
        bottom: 7,
      ),
      decoration: BoxDecoration(
        // Depth 0 sits on the panel's own subtle surface; deeper levels step
        // back towards the row surface so the hierarchy reads without rules.
        color: widget.depth == 0 ? t.bgSubtle : t.zebra,
        border: widget.last
            ? null
            : Border(bottom: BorderSide(color: t.borderSubtle)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Row(
              children: <Widget>[
                Icon(
                  widget.open ? Icons.expand_more : Icons.chevron_right,
                  size: 16,
                  color: t.textSecondary,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    g.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.tableCell.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text('(${g.count})', style: context.type.tiny),
              ],
            ),
          ),
          for (int i = split; i < widget.cols.length; i++) ...<Widget>[
            const SizedBox(width: 12),
            _cell(
              widget.cols[i],
              Align(
                alignment: widget.cols[i]._a,
                child: g.aggregates[i] ?? const SizedBox.shrink(),
              ),
            ),
          ],
        ],
      ),
    );

    return MouseRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Stack(
          children: <Widget>[
            body,
            if (_hover && widget.onTap != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(color: t.bgHover.o(t.hoverA)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatefulWidget {
  final List<Col> cols;
  final GridRow row;
  final Color zebra;
  final bool last;
  final bool selectable;
  final bool checked;
  final VoidCallback? onToggle;

  /// Exactly this tall when set; otherwise the usual 40 floor.
  final double? height;

  const _Row({
    required this.cols,
    required this.row,
    required this.zebra,
    required this.last,
    this.selectable = false,
    this.checked = false,
    this.onToggle,
    this.height,
  });

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool clickable = widget.row.onTap != null;

    // A row whose cell count does not match the header is a layout bug that
    // renders as a plausible-looking table: a short row leaves a blank gap and
    // a long row has its extra cells DROPPED, silently. Loud in debug, ignored
    // in release - a wrong column is not worth a white screen for an operator.
    assert(
      widget.row.cells.length == widget.cols.length,
      'DataGrid row has ${widget.row.cells.length} cells but there are '
      '${widget.cols.length} columns. Extra cells are dropped and missing ones '
      'render blank, so the table would look right and be wrong.',
    );

    final Widget body = Container(
      constraints: widget.height == null
          ? const BoxConstraints(minHeight: 40)
          : BoxConstraints.tightFor(height: widget.height),
      clipBehavior: widget.height == null ? Clip.none : Clip.hardEdge,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
      decoration: BoxDecoration(
        color: widget.zebra,
        border: widget.last
            ? null
            : Border(bottom: BorderSide(color: t.borderSubtle)),
      ),
      child: Row(
        children: <Widget>[
          if (widget.selectable)
            SizedBox(
              width: _kCheckW,
              // The checkbox swallows the tap so ticking a row does not also
              // OPEN it - every selectable grid here has a row-level onTap, and
              // navigating away mid-selection would lose the selection.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onToggle,
                child: Checkbox(
                  value: widget.checked,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: widget.onToggle == null
                      ? null
                      : (_) => widget.onToggle!(),
                ),
              ),
            ),
          for (int i = 0; i < widget.cols.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 12),
            _cell(
              widget.cols[i],
              // Deliberately NOT clipped. A cell whose contents exceed its
              // column is a column that is too narrow, and clipping would hide
              // that - along with whichever control got cut off. Letting it
              // report keeps the width honest; three real cases were found and
              // widened this way.
              Align(
                alignment: widget.cols[i]._a,
                child: i < widget.row.cells.length
                    ? widget.row.cells[i]
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ],
      ),
    );

    return MouseRegion(
      // Only rows that navigate get the pointer. A non-navigable row keeps the
      // hover tint but the default cursor, so the tint alone promises nothing.
      cursor: clickable ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.row.onTap,
        child: Stack(
          children: <Widget>[
            body,
            if (_hover)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(color: t.bgHover.o(t.hoverA)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Widget _cell(Col c, Widget child) => c.width != null
    ? SizedBox(width: c.width, child: child)
    : Expanded(flex: c.flex, child: child);

/// `.lnk` - the primary cell of a table row. The default takes the accent on
/// row hover, marking the row as a target; [GridLink.plain] is the same cell
/// without that promise, for a row with no detail route: four rows wore the
/// affordance over records that have none, advertising a click that led
/// nowhere.
class GridLink extends StatelessWidget {
  final String text;
  final bool strong;

  final bool navigable;

  /// How many lines the text may occupy before it is ellipsised.
  ///
  /// TWO, because this cell holds the name that identifies the record and one
  /// line cropped "DEMO-SOP Forklift Safety Assessment (co…" to exactly the
  /// part that told it apart from the next row. A cell is
  /// `BoxConstraints(minHeight: 40)` and grows, so a name that FITS still
  /// renders on one line at the same 40px row - only a name that would have
  /// been cropped changes anything.
  ///
  /// A PARAMETER rather than a hardcoded 2 so the opt-out is visible at the
  /// call site: a grid with a fixed `rowHeight` CLIPS instead of growing (see
  /// [DataGrid.rowHeight] and `panel.dart`'s note about fixed-height panels),
  /// so those callers pass 1 and keep the tooltip.
  final int maxLines;

  const GridLink(this.text, {super.key, this.strong = true, this.maxLines = 2})
    : navigable = true;

  const GridLink.plain(this.text, {super.key, this.maxLines = 2})
    : strong = true,
      navigable = false;

  @override
  Widget build(BuildContext context) {
    // The row paints the hover tint; this cell inherits the accent through the
    // enclosing hover state, which Flutter cannot express as a selector. The
    // pragmatic equivalent is to render the link in accent-adjacent weight so
    // it reads as the affordance whether or not the pointer is over it.
    final Widget label = Text(
      text,
      maxLines: maxLines,
      // Wrapping is the whole point at 2 lines; at 1 it must stay off, or a
      // fixed-height row would lay out a second line and clip it.
      softWrap: maxLines > 1,
      overflow: TextOverflow.ellipsis,
      style: context.type.tableCell.copyWith(
        fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
        color: navigable ? null : context.tokens.textPrimary,
      ),
    );
    // Nothing to reveal, and a tooltip with an empty message is an empty black
    // box that follows the pointer.
    if (text.trim().isEmpty) return label;
    return Tooltip(
      message: text,
      // The residual case: two lines still are not enough, or the caller opted
      // back to one. Hover is then the only way to read the rest, so nothing is
      // ever unrecoverable.
      //
      // EXCLUDED FROM SEMANTICS on purpose. `Text` reports its FULL string to
      // the accessibility tree whatever the visual overflow, so a tooltip
      // carrying the same words would have every grid cell in the app announced
      // twice. The tooltip is a fix for a visual crop, not a semantic one.
      excludeFromSemantics: true,
      child: label,
    );
  }
}

/// `.pfoot` pagination. Sizes are 20 / 50 / 100 / 200.
class Pagination extends StatelessWidget {
  final int page;
  final int pageSize;
  final int total;
  final ValueChanged<int> onPage;
  final ValueChanged<int> onPageSize;

  /// What is being counted, when it is not the obvious thing: a grouped table
  /// pages over GROUPS, so "1-3 of 3" over 46 answers reads as a wrong count.
  final String unit;

  /// 10 is here for the Assign-candidates picker, which pages a directory
  /// that can run to hundreds of people and is read a name at a time.
  static const List<int> sizes = <int>[10, 20, 50, 100, 200];

  const Pagination({
    super.key,
    required this.page,
    required this.pageSize,
    required this.total,
    required this.onPage,
    required this.onPageSize,
    this.unit = '',
  });

  int get pageCount => total <= 0 ? 1 : ((total - 1) ~/ pageSize) + 1;

  @override
  Widget build(BuildContext context) {
    final int from = total == 0 ? 0 : (page - 1) * pageSize + 1;
    final int to = (page * pageSize).clamp(0, total);
    // A Row, not a Wrap, for the same reason the toolbar is: the layout needs
    // a flexible gap, and `Spacer` extends `Expanded`, which throws outside a
    // Flex. Inside a Wrap it kills the enclosing subtree silently - no console
    // error, just a blank panel.
    return Row(
      children: <Widget>[
        // THE LEFT GROUP TAKES THE SLACK, so the page controls sit against the
        // right edge.
        //
        // This was `Flexible(count)` + `_SizeSelect` + `Spacer()`. Both the
        // Flexible and the Spacer carry flex 1, so the free space was SPLIT
        // between them - and because a `Flexible` is loose, the count text used
        // a little of its half and left the rest blank. The page controls came
        // to rest in the middle of the row, which is what was reported. One
        // `Expanded` around the left group takes all of it instead, and the
        // inner row still ellipsises a long count rather than overflowing.
        Expanded(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                child: Text(
                  unit.isEmpty
                      ? '$from-$to of $total'
                      : '$from-$to of $total $unit',
                  style: context.type.small,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              _SizeSelect(value: pageSize, onChanged: onPageSize, unit: unit),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _PageBtn(
          label: 'Previous',
          onPressed: page > 1 ? () => onPage(page - 1) : null,
        ),
        const SizedBox(width: 8),
        Text('Page $page of $pageCount', style: context.type.small),
        const SizedBox(width: 8),
        _PageBtn(
          label: 'Next',
          onPressed: page < pageCount ? () => onPage(page + 1) : null,
        ),
      ],
    );
  }
}

class _PageBtn extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const _PageBtn({required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool on = onPressed != null;
    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
      child: GestureDetector(
        onTap: onPressed,
        child: Opacity(
          opacity: on ? 1 : .42,
          child: Container(
            height: 27,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.bgApp,
              borderRadius: Radii.buttonSm,
              border: Border.all(color: t.border),
            ),
            child: Text(
              label,
              style: context.type.button.copyWith(fontSize: 11.5),
            ),
          ),
        ),
      ),
    );
  }
}

class _SizeSelect extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  final String unit;

  const _SizeSelect({
    required this.value,
    required this.onChanged,
    this.unit = '',
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      height: 27,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: t.bgApp,
        borderRadius: Radii.buttonSm,
        border: Border.all(color: t.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: value,
          isDense: true,
          dropdownColor: t.bgApp,
          style: context.type.small,
          icon: Icon(Icons.expand_more, size: 14, color: t.textMuted),
          items: Pagination.sizes
              .map(
                (int s) => DropdownMenuItem<int>(
                  value: s,
                  child: Text(
                    unit.isEmpty ? '$s per page' : '$s $unit per page',
                    style: context.type.small,
                  ),
                ),
              )
              .toList(),
          onChanged: (int? v) => v == null ? null : onChanged(v),
        ),
      ),
    );
  }
}

/// The assign -> submit -> release funnel, as one cell. Replaces four numeric
/// columns that cost ~360px and pushed the table past its container. A sitting
/// nobody has been assigned to shows a dash, not three zeros - three zeros read
/// as a fault rather than as "nothing has started".
class FunnelCell extends StatelessWidget {
  final int assigned;
  final int submitted;
  final int released;

  const FunnelCell({
    super.key,
    required this.assigned,
    required this.submitted,
    required this.released,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;

    if (assigned <= 0) {
      return Text('-', style: context.type.bodyMuted);
    }

    // Guarded against a server that reports more submissions than assignments
    // mid-refresh: a fraction over 1 would paint outside the track.
    double frac(int n) => (n / assigned).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // `released` is drawn over `submitted`, so the released portion reads
        // as a subset of what came in rather than a competing quantity.
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 5,
            child: Stack(
              children: <Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(color: t.border),
                  child: const SizedBox.expand(),
                ),
                // Tones come from ToneColors, the same source the pills use, so
                // the funnel cannot invent an unlicensed colour.
                FractionallySizedBox(
                  widthFactor: frac(submitted),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: ToneColors.of(t, Tone.info).fg.o(.55),
                    ),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: frac(released),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: ToneColors.of(t, Tone.ok).fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          '$submitted/$assigned in  -  $released released',
          style: context.type.tiny,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
