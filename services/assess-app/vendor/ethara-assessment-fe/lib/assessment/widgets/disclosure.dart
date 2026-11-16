// A folded-away block.
//
// `showSheet` is one scrolling column with no tab strip, so a sheet reaches
// parity with a tabbed Odoo form by folding rather than paging. Two things
// earn a fold: content a reviewer must not read before forming their own view
// (a rationale, a golden answer), and content that is diagnostic not decisive.
import 'package:flutter/material.dart';

import '../theme.dart';
import 'buttons.dart';

class Disclosure extends StatefulWidget {
  /// Shown when folded, e.g. "Show the answer rationale".
  final String showLabel;

  /// Shown when open. Defaults to [showLabel] with "Show" swapped for "Hide".
  final String? hideLabel;

  /// Built only while open, so a heavy body costs nothing folded.
  final WidgetBuilder builder;

  const Disclosure({
    super.key,
    required this.showLabel,
    this.hideLabel,
    required this.builder,
  });

  @override
  State<Disclosure> createState() => _DisclosureState();
}

class _DisclosureState extends State<Disclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final String hide =
        widget.hideLabel ?? widget.showLabel.replaceFirst('Show', 'Hide');
    void toggle() => setState(() => _open = !_open);
    return Container(
      decoration: BoxDecoration(
        color: t.bgSubtle,
        borderRadius: Radii.option,
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // THE WHOLE STRIP IS THE CONTROL, not just the words.
          //
          // The tap used to live only on the LinkBtn, so the row read as one
          // control and behaved as two: clicking the label opened it, clicking
          // the empty space beside it or the chevron itself did nothing. The
          // padding sits INSIDE the gesture so the full height of the strip
          // is hit-testable, and `opaque` catches the gap between the label
          // and the chevron. The body is deliberately outside it - a click
          // inside an opened block must not fold it away again.
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 11,
                ),
                child: Row(
                  children: <Widget>[
                    // EXPANDED, not Flexible + Spacer. Those are both flex
                    // children, so they SHARED the free space: the label grew
                    // with its own text and carried the chevron rightward with
                    // it, leaving two stacked disclosures with their arrows at
                    // different x positions. Expanded takes the whole gap, so
                    // the chevron is pinned to the right edge whatever the
                    // label says.
                    Expanded(
                      child: LinkBtn(
                        _open ? hide : widget.showLabel,
                        onPressed: toggle,
                      ),
                    ),
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: t.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(13, 0, 13, 11),
              child: widget.builder(context),
            ),
        ],
      ),
    );
  }
}
