// Panels, KPI cards and page furniture - HANDOVER §2.3, §2.6, §7.1, §7.2.
// §7.1 page envelope: crumbs, head, optional KPI strip, then one or more
// panels - no hero, no banner image, no coloured page header anywhere.
import 'package:flutter/material.dart';

import 'buttons.dart';
import '../theme.dart';

/// `.page` - a wide, left-aligned working area. `narrow` drops to a centred
/// 900px reading measure. NOT centred at 1320: on a wide display that leaves a
/// dead right-hand gutter and head actions land mid-window instead of at the
/// edge where a toolbar belongs.
class PageBody extends StatelessWidget {
  final List<Widget> children;
  final bool narrow;

  const PageBody({super.key, required this.children, this.narrow = false});

  /// Past this a grid's columns stretch so far apart a row is hard to track.
  static const double _kWide = 1720;

  @override
  Widget build(BuildContext context) {
    final Widget column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    return Align(
      alignment: narrow ? Alignment.topCenter : Alignment.topLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: narrow ? 900 : _kWide),
        child: column,
      ),
    );
  }
}

/// One segment of the breadcrumb trail. The last item is never a link.
class Crumb {
  final String label;

  /// What to do when this crumb is tapped. Null means it is the current page,
  /// which is not a link. A callback rather than a URL because the app pushes
  /// route objects onto `AssessmentNav`'s stack; `nav.dart` has the limits.
  final VoidCallback? onTap;

  const Crumb(this.label, [this.onTap]);
}

/// `.crumbs` - the trail above the page heading.
class Crumbs extends StatelessWidget {
  final List<Crumb> items;

  const Crumbs(this.items, {super.key});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final List<Widget> out = <Widget>[];
    for (int i = 0; i < items.length; i++) {
      final Crumb c = items[i];
      out.add(
        c.onTap == null
            ? Text(c.label, style: context.type.crumb)
            : LinkBtn(c.label, style: context.type.crumb, onPressed: c.onTap),
      );
      if (i < items.length - 1) {
        out.add(
          Text('  ›  ', style: context.type.crumb.copyWith(color: t.textMuted)),
        );
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: out),
    );
  }
}

/// `.phead` - the page heading: title, secondary line, actions pushed right and
/// sitting on the same baseline.
class PageHead extends StatelessWidget {
  final String title;
  final String? sub;
  final List<Widget> actions;

  /// Replaces the title TEXT, keeping the rest of the head. For a title that
  /// is also a control - the generator name is edited in place - so the type
  /// ramp, spacing and actions row stay identical wherever that is done.
  final Widget? titleChild;

  /// The same escape hatch for the SECOND line. For a subtitle that has to
  /// carry a CONTROL - the candidate's email carries a copy button, because
  /// chasing a no-show meant retyping the address off the screen - so the 3px
  /// gap and the type ramp stay decided here rather than at each call site.
  final Widget? subChild;

  const PageHead(
    this.title, {
    super.key,
    this.sub,
    this.actions = const <Widget>[],
    this.titleChild,
    this.subChild,
  });

  @override
  Widget build(BuildContext context) {
    final Widget heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        titleChild ?? Text(title, style: context.type.pageTitle),
        if (sub != null || subChild != null) ...<Widget>[
          const SizedBox(height: 3),
          subChild ?? Text(sub!, style: context.type.pageSub),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: actions.isEmpty
          ? heading
          // A Row + Wrap, deliberately WITHOUT a LayoutBuilder. A page head can
          // land inside an IntrinsicHeight (FieldGrid builds its rows that
          // way), and IntrinsicHeight cannot measure a LayoutBuilder - it
          // throws "LayoutBuilder does not support returning intrinsic
          // dimensions" and takes the whole subtree down with it. Flex layout
          // alone gives the same result and stays measurable.
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: heading),
                const SizedBox(width: 12),
                // Expanded, NOT Flexible: Flexible's loose fit lets the Wrap
                // shrink to its content, so `WrapAlignment.end` aligns inside
                // that shrunken box and the button lands mid-page. Expanded
                // forces the Wrap to fill its half, so `end` reaches the row's
                // real right edge. Guarded by ui_report_fixes_test.
                Expanded(
                  child: Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: actions,
                  ),
                ),
              ],
            ),
    );
  }
}

/// `.eyebrow` - a 10px uppercase caption above a block.
class Eyebrow extends StatelessWidget {
  final String text;

  const Eyebrow(this.text, {super.key});

  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: context.type.eyebrow);
}

/// `.panel` - the container everything lives in: app surface, hairline border,
/// 12px radius, clipped so a flush table meets the edge cleanly.
class Panel extends StatelessWidget {
  /// `.ph` - the header strip: title, note, actions.
  final String? title;
  final String? note;
  final List<Widget> headActions;

  /// `.pb` - the body. [flush] drops the padding so a table meets the edge.
  final Widget? child;
  final bool flush;

  /// `.pfoot` - pagination, or a single explanatory line.
  final Widget? footer;

  final Widget? toolbar;

  /// A floor for the card's height, so two cards side by side stay the same
  /// size when their content does not.
  ///
  /// A FLOOR, not a fixed height: a panel still grows past it. This is the
  /// only equalising mechanism that is safe here - see the comment in [Cols2]
  /// for the two ways `IntrinsicHeight` fails on these cards.
  final double? minHeight;

  /// An exact height, for a card that must match another card.
  ///
  /// [minHeight] only stops a card COLLAPSING; it cannot make two cards equal
  /// when their content differs. Ten rows beside seven is still ten rows
  /// beside seven. A fixed height is the only thing that holds regardless of
  /// row count, and with the footer pinned to the bottom a short list simply
  /// leaves space above the pager rather than dragging it up the card.
  ///
  /// Only safe when the content cannot outgrow it - pair it with a paged grid
  /// and a fixed `DataGrid.rowHeight`, or the body will overflow.
  final double? height;

  const Panel({
    super.key,
    this.title,
    this.note,
    this.headActions = const <Widget>[],
    this.child,
    this.flush = false,
    this.footer,
    this.toolbar,
    this.minHeight,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;

    final Widget? head = (title != null || headActions.isNotEmpty)
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.borderSubtle)),
            ),
            // THE TITLE OWNS THE GAP; THE ACTIONS SIT ON THE RIGHT EDGE.
            //
            // This was `Flexible(title) + Flexible(note) + Spacer() + actions`,
            // and Flexible and Spacer are BOTH flex children - so they divided
            // the free width between them rather than the Spacer taking all of
            // it. On a wide panel with a short title the actions landed in the
            // MIDDLE of the header.
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Row(
                    children: <Widget>[
                      if (title != null)
                        Flexible(
                          child: Text(title!, style: context.type.panelTitle),
                        ),
                      if (note != null) ...<Widget>[
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            note!,
                            style: context.type.panelNote,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                ...headActions,
              ],
            ),
          )
        : null;

    final Widget? body = child == null
        ? null
        : Padding(
            padding: flush
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
            child: child,
          );

    // UNDER A DEFINITE HEIGHT THE BODY IS WHAT GIVES.
    //
    // Anything else overflows the moment the chrome grows: the toolbar wraps
    // to two lines on a narrow card, and that is 7px a fixed height does not
    // have. Legal here precisely BECAUSE the height is definite - without one
    // the column is unbounded and a flex child throws. Clipped rather than
    // scrolled: these tables are paged to a fixed row count, so a body that
    // needs more room is a layout bug worth seeing, not one to hide behind a
    // scrollbar.
    final Widget group = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ?head,
        ?toolbar,
        if (body != null)
          if (height == null) body else Expanded(child: ClipRect(child: body)),
      ],
    );

    return Container(
      constraints: height != null
          ? BoxConstraints.tightFor(height: height)
          : (minHeight == null ? null : BoxConstraints(minHeight: minHeight!)),
      decoration: BoxDecoration(
        color: t.bgApp,
        borderRadius: Radii.panel,
        border: Border.all(color: t.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        // A DEFINITE HEIGHT CHANGES WHICH TOOL IS LEGAL. With one, `max` plus a
        // flexible body is safe and correct. Without one the column is
        // unbounded, `Expanded` throws, and the slack is distributed instead.
        mainAxisSize: height == null ? MainAxisSize.min : MainAxisSize.max,
        // THE FOOTER SITS ON THE CARD'S BOTTOM EDGE, NOT UNDER THE CONTENT.
        //
        // With only a [minHeight] the Column's BOX is the floor while its
        // CONTENT is whatever the rows add up to, and `start` alignment drops
        // all the slack after the last child - so a short table's pager sat
        // well above a full one's and the pair read as ragged.
        //
        // `spaceBetween` over exactly TWO children puts that slack between
        // them, with no flex child, so it works in the unbounded case too.
        // `MainAxisSize.max` alone is inert under an infinite maxHeight, and
        // the IntrinsicHeight that would bound it cannot measure the
        // LayoutBuilder inside a DataGrid - see [Cols2].
        //
        // Neutral everywhere else: with no floor the free space is zero, and
        // with no footer there is ONE child, which Flutter's own
        // `spaceBetween` degrades to `start`.
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          if (height == null) group else Expanded(child: group),
          if (footer != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: t.border)),
              ),
              child: footer!,
            ),
        ],
      ),
    );
  }
}

/// `.tbar` - the panel toolbar. Search grows, then selects, actions right,
/// count tag last.
///
/// A Row, not a Wrap: "actions right" needs a `Spacer`, and `Spacer` extends
/// `Expanded`, which THROWS outside a Flex - inside a Wrap it takes down the
/// whole panel subtree and the body renders blank with no console error.
/// Children before the `Spacer` are loosely flexible so a narrow toolbar
/// shrinks, not overflows.
class Toolbar extends StatelessWidget {
  final List<Widget> children;

  const Toolbar(this.children, {super.key});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    // THE SPACER OWNS THE GAP; WHATEVER FOLLOWS IT SITS ON THE RIGHT EDGE.
    //
    // EXACTLY THE BUG `Panel`'s header carries a comment about, on the class
    // below it. This was one flat Row of `Flexible(loose)` children plus a
    // `Spacer`, and Flexible and Spacer are BOTH flex children - so they
    // divided the free width EQUALLY rather than the Spacer taking all of it.
    // A five-child toolbar gave the Spacer a fifth of the slack, and because
    // the Row aligns to `start` the width the loose children declined to use
    // piled up AFTER the last one: the count chip floated ~200px short of the
    // panel's right edge on every list screen, and `SelectField` - which is
    // `isExpanded` and had no cap - swelled to fill its own share.
    //
    // Same fix as the header: everything up to the Spacer goes in ONE
    // `Expanded`, which is then the only flex child of the outer Row and
    // absorbs all the slack, and everything after it is laid out at its
    // intrinsic width hard against the edge.
    final int split = children.indexWhere((Widget w) => w is Spacer);
    final List<Widget> left = split < 0 ? children : children.sublist(0, split);
    final List<Widget> right = split < 0
        ? const <Widget>[]
        : children.sublist(split + 1);
    final Widget leftGroup = Row(
      children: <Widget>[
        for (int i = 0; i < left.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 8),
          // Loose, so a narrow toolbar shrinks the search box rather than
          // overflowing the row.
          Flexible(fit: FlexFit.loose, child: left[i]),
        ],
      ],
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      decoration: BoxDecoration(
        color: t.bgSubtle,
        border: Border(bottom: BorderSide(color: t.borderSubtle)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(child: leftGroup),
          for (final Widget w in right) ...<Widget>[
            const SizedBox(width: 8),
            w,
          ],
        ],
      ),
    );
  }
}

/// `.kpi` - a flat stat card. §7.2: the value carries the only colour, and
/// only when the number means something. A stat that navigates renders as a
/// button so it is focusable; a merely informative one does not.
class Kpi extends StatefulWidget {
  final String label;
  final String value;
  final String? sub;

  /// `.kpi.t-*` - tones the numeral only, never the label or sub-line.
  final Color? valueColor;

  final VoidCallback? onTap;

  /// `button.kpi[aria-pressed="true"]` - a KPI acting as an active filter.
  /// A 45% tint, lighter than a pressed button, because the card is large.
  final bool? pressed;

  /// The value is a WORD, not a numeral - "Time out", "Violations", "No".
  /// The display-size mono numeral is cut for two or three digits, so a word
  /// set in it is the one value on the row that cannot be read: it truncates
  /// to "Time ...". See [AppType.kpiValueWord].
  final bool word;

  const Kpi({
    super.key,
    required this.label,
    required this.value,
    this.sub,
    this.valueColor,
    this.onTap,
    this.pressed,
    this.word = false,
  });

  @override
  State<Kpi> createState() => _KpiState();
}

class _KpiState extends State<Kpi> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool interactive = widget.onTap != null;
    final bool on = widget.pressed == true;

    // A KPI card has a DEFINED height: only some carry a sub-line, so sizing
    // to content gave a ragged row. Cross-axis stretch cannot fix it (the grid
    // sits in a scroll view, so the Row has unbounded height and stretch
    // throws), and IntrinsicHeight cannot measure a LayoutBuilder cell.
    //
    // 100px is MEASURED, not computed. Deriving it from the nominal type scale
    // gave 92 and overflowed by 5: real font ascent and descent exceed the
    // nominal line box. `kpi_height_test.dart` pumps the tallest card and
    // fails if this number stops covering it.
    final Widget card = Container(
      height: 100,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: on ? t.primarySubtle.o(.45) : t.bgApp,
        borderRadius: Radii.card,
        border: Border.all(
          color: on
              ? t.primary.o(.5)
              : (_hover && interactive ? t.borderHover : t.border),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            widget.label.toUpperCase(),
            style: context.type.kpiLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 3),
          Text(
            widget.value,
            style:
                (widget.word
                        ? context.type.kpiValueWord
                        : context.type.kpiValue)
                    .copyWith(color: widget.valueColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (widget.sub != null) ...<Widget>[
            const SizedBox(height: 2),
            // ONE line, clipped: the card height is fixed, so an unbounded
            // sub-line overflows rather than wraps.
            Text(
              widget.sub!,
              style: context.type.kpiSub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );

    if (!interactive) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(onTap: widget.onTap, child: card),
    );
  }
}

/// `.kpis` - an auto-fitting grid with a 152px minimum, so it reflows from six
/// across to two without a breakpoint.
class KpiStrip extends StatelessWidget {
  final List<Widget> children;
  final double minWidth;

  const KpiStrip(this.children, {super.key, this.minWidth = 152});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: AutoGrid(minWidth: minWidth, gap: 11, children: children),
  );
}

/// The `repeat(auto-fit, minmax(N, 1fr))` behaviour CSS grid gives for free:
/// fit as many equal columns as will hold [minWidth], then share the remainder.
class AutoGrid extends StatelessWidget {
  final List<Widget> children;
  final double minWidth;
  final double gap;

  /// Retained for call-site compatibility, but no longer read: cells are
  /// always top-aligned. Equalising row height needed an IntrinsicHeight,
  /// which cannot measure a cell holding a LayoutBuilder - it rendered blank.
  @Deprecated('No longer has any effect; cells are always top-aligned.')
  final bool intrinsicHeight;

  /// OPT-IN equal-height rows: every cell in a row is stretched to the
  /// tallest cell's height, via IntrinsicHeight. Only safe when the caller
  /// KNOWS its cells contain no LayoutBuilder (a nested grid, a table, a
  /// page head) - IntrinsicHeight cannot measure those and fails the whole
  /// subtree. That is why this is per-call-site and default OFF, unlike the
  /// old always-on `intrinsicHeight` this widget once had.
  final bool equalRowHeight;

  const AutoGrid({
    super.key,
    required this.children,
    required this.minWidth,
    this.gap = 11,
    this.equalRowHeight = false,
    @Deprecated('No longer has any effect; cells are always top-aligned.')
    this.intrinsicHeight = true,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) {
      if (children.isEmpty) return const SizedBox.shrink();
      final double avail = c.maxWidth.isFinite ? c.maxWidth : minWidth;
      int cols = ((avail + gap) / (minWidth + gap)).floor();
      cols = cols.clamp(1, children.length);
      final double w = (avail - gap * (cols - 1)) / cols;

      final List<Widget> rows = <Widget>[];
      for (int i = 0; i < children.length; i += cols) {
        final List<Widget> row = <Widget>[];
        for (int j = i; j < i + cols && j < children.length; j++) {
          if (j > i) row.add(SizedBox(width: gap));
          row.add(SizedBox(width: w, child: children[j]));
        }
        // Default: `start`, and never an IntrinsicHeight.
        //
        // `stretch` requires the Row to have a definite height, so inside
        // an unbounded parent (a scroll view, which is where these grids
        // live) it throws "BoxConstraints forces an infinite height".
        // IntrinsicHeight would give it one, but it cannot measure a cell
        // containing a LayoutBuilder - a nested grid, a table, a page head
        // - and fails the whole subtree with "LayoutBuilder does not
        // support returning intrinsic dimensions", rendering blank.
        //
        // [equalRowHeight] opts back in for grids whose cells are known
        // LayoutBuilder-free (the candidate's attempt cards).
        final Widget rowWidget = equalRowHeight
            ? IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: row,
                ),
              )
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: row);
        rows.add(rowWidget);
        if (i + cols < children.length) rows.add(SizedBox(height: gap));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      );
    },
  );
}

/// `.stack` - the vertical rhythm between panels. A lone panel carries no
/// margin; `.panel + .panel` is 16px.
class Stack16 extends StatelessWidget {
  final List<Widget> children;
  final double gap;

  const Stack16(this.children, {super.key, this.gap = 16});

  @override
  Widget build(BuildContext context) {
    final List<Widget> out = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      if (i > 0) out.add(SizedBox(height: gap));
      out.add(children[i]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: out,
    );
  }
}

/// `.cols2` - the 1.25fr / 1fr content split, collapsing to one column under
/// 980px.
class Cols2 extends StatelessWidget {
  final Widget left;
  final Widget right;

  const Cols2({super.key, required this.left, required this.right});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) {
      if (c.maxWidth < Layout.twoColumn) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            left,
            const SizedBox(height: Layout.gridGap),
            right,
          ],
        );
      }
      return Row(
        // `start`, and NEVER an IntrinsicHeight - use `Panel.minHeight` to
        // make a pair of cards match.
        //
        // `stretch` needs a definite height, and these rows sit in a scroll
        // view, so the height would have to come from an `IntrinsicHeight`.
        // That was tried. It fails two ways here: it cannot measure a
        // `LayoutBuilder`, so any card holding a chart or a `DataGrid` renders
        // blank; and it measures text at UNBOUNDED width, so a card whose body
        // wraps onto three lines is measured as one and the card then
        // overflows the height it was given - 81px, in the panel that made
        // this comment necessary. A height FLOOR has neither failure mode: it
        // only ever grows the box, and the content still lays out naturally.
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(flex: 125, child: left),
          const SizedBox(width: Layout.gridGap),
          Expanded(flex: 100, child: right),
        ],
      );
    },
  );
}

/// `.kv` - a key/value row: label left, value right, hairline under.
class KvRow extends StatelessWidget {
  final String k;
  final Widget v;
  final bool last;

  const KvRow(this.k, this.v, {super.key, this.last = false});

  KvRow.text(String k, String v, {Key? key, bool last = false})
    : this(k, _KvText(v), key: key, last: last);

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: t.borderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 150,
            child: Text(k, style: context.type.bodySecondary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: v),
          ),
        ],
      ),
    );
  }
}

class _KvText extends StatelessWidget {
  final String text;

  const _KvText(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.right,
    style: context.type.body.copyWith(fontWeight: FontWeight.w600),
  );
}

/// `.field` - a labelled form field or read-only value.
class Field extends StatelessWidget {
  final String label;
  final Widget child;
  final String? help;

  const Field({super.key, required this.label, required this.child, this.help});

  /// `.field .ro` - a read-only value, which is how the whole configuration
  /// surface renders once an assessment has launched.
  factory Field.readonly(String label, String value, {String? help}) =>
      Field(label: label, help: help, child: _RoValue(value));

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Text(label.toUpperCase(), style: context.type.fieldLabel),
      const SizedBox(height: 4),
      child,
      if (help != null) ...<Widget>[
        const SizedBox(height: 4),
        Text(help!, style: context.type.tiny.copyWith(height: 1.45)),
      ],
    ],
  );
}

class _RoValue extends StatelessWidget {
  final String value;

  const _RoValue(this.value);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(
      value,
      style: context.type.body.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// `.fgrid` - the field grid: auto-fit, 258px minimum.
class FieldGrid extends StatelessWidget {
  final List<Widget> children;

  const FieldGrid(this.children, {super.key});

  @override
  Widget build(BuildContext context) => AutoGrid(
    minWidth: 258,
    gap: 20,
    intrinsicHeight: false,
    children: children,
  );
}

/// `.emptyline` - an empty result is a sentence explaining what to change,
/// never a blank body.
class EmptyLine extends StatelessWidget {
  final String message;

  const EmptyLine(this.message, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 34),
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: context.type.bodyMuted,
    ),
  );
}

/// `.hr` - a hairline rule inside a body.
class Hr extends StatelessWidget {
  const Hr({super.key});

  @override
  Widget build(BuildContext context) => Container(
    height: 1,
    margin: const EdgeInsets.symmetric(vertical: 4),
    color: context.tokens.borderSubtle,
  );
}
