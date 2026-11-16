// Assessment controls that have no portal counterpart: the detail-page tab
// strip, the toolbar search and filter fields, the exam runtime's status bar,
// the toast host, the bounded-integer stepper. All paint with `PortalTokens`,
// so they match the rest of the app.
//
// The package's own `Shell` - rail, doc bar, portal switcher - is gone: the
// app shell provides all of that, and a second one beside it was duplication.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'buttons.dart';

import '../domain/enums.dart';
import '../theme.dart';
import 'feedback.dart';
import 'marks.dart' as marks;

class TabStrip extends StatelessWidget {
  final List<TabDef> tabs;
  final String active;
  final ValueChanged<String> onChanged;

  const TabStrip({
    super.key,
    required this.tabs,
    required this.active,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      decoration: BoxDecoration(
        color: t.bgApp,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 15),
        child: Row(
          children: tabs
              .map(
                (TabDef d) => _Tab(
                  def: d,
                  active: d.key == active,
                  onTap: d.disabled ? null : () => onChanged(d.key),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class TabDef {
  final String key;
  final String label;
  final int? count;
  final bool disabled;

  const TabDef(this.key, this.label, {this.count, this.disabled = false});
}

class _Tab extends StatefulWidget {
  final TabDef def;
  final bool active;
  final VoidCallback? onTap;

  const _Tab({required this.def, required this.active, this.onTap});

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool on = widget.onTap != null;
    final Color fg = widget.active
        ? t.primary
        : (_hover && on ? t.textPrimary : t.textSecondary);
    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Opacity(
          // A disabled tab is slightly dimmer than a disabled button.
          opacity: on ? 1 : .38,
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            margin: const EdgeInsets.only(right: 2),
            decoration: BoxDecoration(
              border: Border(
                // The 2px underline is present but transparent on every tab,
                // so selection changes colour, never layout.
                bottom: BorderSide(
                  width: 2,
                  color: widget.active ? t.primary : const Color(0x00000000),
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  widget.def.label,
                  style: context.type.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
                if (widget.def.count != null) ...<Widget>[
                  const SizedBox(width: 5),
                  Text('${widget.def.count}', style: context.type.countChip),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `.statusbar` - the segmented lifecycle bar. `cancelled` leaves the linear
/// run and is drawn as a single chip instead.
class StatusBar extends StatelessWidget {
  final AsmState state;

  const StatusBar(this.state, {super.key});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;

    if (state == AsmState.cancelled) {
      return marks.Pill.state(AsmState.cancelled);
    }

    final int idx = AsmState.linear.indexOf(state);
    return Container(
      decoration: BoxDecoration(
        color: t.bgApp,
        borderRadius: Radii.button,
        border: Border.all(color: t.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < AsmState.linear.length; i++)
            Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: i == idx ? t.primarySubtle : const Color(0x00000000),
                border: i < AsmState.linear.length - 1
                    ? Border(right: BorderSide(color: t.borderSubtle))
                    : null,
              ),
              child: Text(
                AsmState.linear[i].label,
                style: context.type.small.copyWith(
                  fontWeight: FontWeight.w600,
                  color: i == idx
                      ? t.primary
                      : i < idx
                      ? t.textSecondary
                      : t.textMuted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A search input for a panel toolbar.
///
/// Stateful because [value] is authoritative: a parent that clears its query
/// (a "Clear filters" button, a reset after navigating) must see the box empty
/// too. With a plain `initialValue` the text is read once at construction and
/// never again, so the parent's state and the visible text silently diverge.
class SearchField extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final String hint;

  const SearchField({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint = 'Search',
  });

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  late final TextEditingController _c = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(SearchField old) {
    super.didUpdateWidget(old);
    // Only when the parent's value genuinely differs from what is displayed.
    // Assigning on every rebuild would fight the user's cursor mid-typing.
    if (widget.value != _c.text) {
      _c.text = widget.value;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    // A MAXIMUM width, not a fixed one: a box pinned to 260px cannot shrink,
    // so a narrower toolbar overflows and clips whatever sits at the end -
    // usually the button the toolbar exists to offer.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260, minWidth: 96),
      child: SizedBox(
        height: 32,
        child: TextFormField(
          controller: _c,
          onChanged: widget.onChanged,
          style: context.type.body,
          cursorColor: t.primary,
          decoration: InputDecoration(
            isDense: true,
            hintText: widget.hint,
            hintStyle: context.type.bodyMuted,
            prefixIcon: Icon(Icons.search, size: 15, color: t.textMuted),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 30,
              minHeight: 30,
            ),
            filled: true,
            fillColor: t.bgApp,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10),
            border: OutlineInputBorder(
              borderRadius: Radii.input,
              borderSide: BorderSide(color: t.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: Radii.input,
              borderSide: BorderSide(color: t.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: Radii.input,
              borderSide: BorderSide(color: t.primary.o(.55)),
            ),
          ),
        ),
      ),
    );
  }
}

/// The default width of a filter dropdown, and the width every short filter
/// in the app should keep. See [SelectField.maxWidth] for when to exceed it.
const double kSelectFieldWidth = 200;

/// A filter whose options are operator-written names rather than our own short
/// labels. Wide enough for a realistic assessment title without turning the
/// toolbar into one control.
const double kSelectFieldWideWidth = 320;

/// A filter select for a panel toolbar.
class SelectField<T> extends StatelessWidget {
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  final String? label;

  /// How wide this control may grow. [kSelectFieldWidth] suits a filter whose
  /// options are written by us and therefore short ("All types", "Any date").
  ///
  /// A filter whose options are DATA needs more: an assessment picker lists
  /// names an operator typed, and "Q7r + Grade & Fix - Quality Assessment
  /// (Sprint 2) (copy)" ellipsises to uselessness at 200. Widening the default
  /// instead would swell every short filter in the app to match the one long
  /// one, which is the bug the cap was added to fix.
  final double maxWidth;

  const SelectField({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.label,
    this.maxWidth = kSelectFieldWidth,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    // A MAXIMUM width, for the same reason `SearchField` has one - and here it
    // is load-bearing rather than defensive. `isExpanded` below makes the
    // dropdown take the width it is GIVEN, so in a toolbar it grew to whatever
    // flex share the row handed it: "All types" rendered 278px wide next to a
    // 260px search box. The cap sizes it to a filter control; `minWidth` keeps
    // it legible when the toolbar is squeezed.
    // The label names the control for a screen reader: two selects that both
    // read "Unknown" (a speaker's gender and nativity) are otherwise the same.
    return Semantics(
      container: label != null,
      label: label,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, minWidth: 120),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: t.bgApp,
            borderRadius: Radii.input,
            border: Border.all(color: t.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              isDense: true,
              // Without this the button sizes to its WIDEST option label and
              // overflows its own container the moment an option is long ("All
              // scoring states", "Rubric unreviewed"). isExpanded makes it take the
              // width it is given and ellipsize instead, which is what a filter
              // control in a toolbar has to do.
              isExpanded: true,
              dropdownColor: t.bgApp,
              style: context.type.body,
              icon: Icon(Icons.expand_more, size: 15, color: t.textMuted),
              items: options
                  .map(
                    ((T, String) o) => DropdownMenuItem<T>(
                      value: o.$1,
                      // THE MENU TRUNCATES TOO, and it is the surface a reader is
                      // actually comparing names on. The menu takes the button's
                      // width, so a name that did not fit closed does not fit
                      // open either - and a picker whose rows all read
                      // "SCORING REVIEW 2026-08-25 - ..." is a picker you cannot
                      // choose from.
                      child: _ClippedLabel(o.$2),
                    ),
                  )
                  .toList(),
              // A TOOLTIP ONLY WHEN THE TEXT IS ACTUALLY CUT.
              //
              // `selectedItemBuilder` is what the CLOSED button shows; without it
              // the button re-renders the menu row, and a tooltip there would
              // follow the label into the open menu where nothing is truncated.
              // An always-on tooltip is worse than none: it trains the reader to
              // ignore it, so it is attached only when the name does not fit.
              selectedItemBuilder: (BuildContext context) => options
                  .map(
                    ((T, String) o) => Align(
                      alignment: Alignment.centerLeft,
                      child: _ClippedLabel(o.$2),
                    ),
                  )
                  .toList(),
              onChanged: (T? v) => v == null ? null : onChanged(v),
            ),
          ),
        ),
      ),
    );
  }
}

/// The scrim + sheet overlay - §7.5. Every confirmation, preview and audit is
/// the same object: actions in the footer with the affirmative last, Escape
/// closes. A sheet doing something irreversible says so in its body, naming
/// the people affected, before the button that does it.
Future<T?> showSheet<T>(
  BuildContext context, {
  required String title,
  String? sub,
  required Widget body,
  List<Widget> actions = const <Widget>[],
  bool wide = false,
}) => showToastedDialog<T>(
  context,
  barrierColor: const Color(0x8C030213),
  builder: (BuildContext ctx) {
    final AppTokens t = ctx.tokens;
    return Dialog(
      backgroundColor: const Color(0x00000000),
      insetPadding: const EdgeInsets.all(22),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: wide ? 880 : 640,
          maxHeight: MediaQuery.of(ctx).size.height * .88,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: t.bgApp,
            borderRadius: Radii.sheet,
            border: Border.all(color: t.border),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: t.shadow.o(.28),
                blurRadius: 50,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.fromLTRB(17, 15, 10, 15),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: t.borderSubtle)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(title, style: ctx.type.sheetTitle),
                          if (sub != null) ...<Widget>[
                            const SizedBox(height: 3),
                            Text(sub, style: ctx.type.sheetSub),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => popIfCurrent(ctx),
                      iconSize: 17,
                      tooltip: 'Close',
                      icon: Icon(Icons.close, color: t.textMuted),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
                  child: body,
                ),
              ),
              if (actions.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 17,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: t.bgSubtle,
                    border: Border(top: BorderSide(color: t.borderSubtle)),
                  ),
                  child: Row(
                    children: <Widget>[
                      const Spacer(),
                      for (final Widget a in actions) ...<Widget>[
                        a,
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  },
);

/// `showDialog`, with the caller's toasts carried over the dialog.
///
/// A dialog is a route on the root navigator, above the [ToastHost] the screen
/// sits in, so it painted over every toast: a save refused inside a sheet kept
/// the sheet open "while the toast explains why", and the toast only showed
/// after Cancel. The host is read from the CALLER, because the dialog's own
/// context is not under it; with no host there, nothing is added.
Future<T?> showToastedDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
}) {
  final _ToastScope? host = context
      .getInheritedWidgetOfExactType<_ToastScope>();
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    builder: host == null
        ? builder
        : (BuildContext ctx) => ToastHost(
            toaster: host.toaster,
            depth: host.depth + 1,
            child: builder(ctx),
          ),
  );
}

/// The toast host: one under the screen, and one over each dialog opened
/// through [showToastedDialog].
class ToastHost extends StatelessWidget {
  final Widget child;
  final Toaster toaster;

  /// See [ToastLayer.lift].
  final double lift;

  /// See [ToastLayer.depth]. A screen leaves it 0.
  final int depth;

  const ToastHost({
    super.key,
    required this.child,
    required this.toaster,
    this.lift = 0,
    this.depth = 0,
  });

  @override
  Widget build(BuildContext context) => _ToastScope(
    toaster: toaster,
    depth: depth,
    child: Stack(
      children: <Widget>[
        child,
        ToastLayer(toaster, lift: lift, depth: depth),
      ],
    ),
  );
}

/// What [showToastedDialog] reads off its caller.
class _ToastScope extends InheritedWidget {
  final Toaster toaster;
  final int depth;

  const _ToastScope({
    required this.toaster,
    required this.depth,
    required super.child,
  });

  @override
  bool updateShouldNotify(_ToastScope old) =>
      toaster != old.toaster || depth != old.depth;
}

/// A small stepper for a bounded integer, used wherever a percentage or a
/// count is edited. Shared rather than duplicated: the pass thresholds are set
/// at creation AND edited afterwards, and two copies would drift.
///
/// Clamping at the edit site rather than on save is what stops an out-of-range
/// value ever reaching the readiness checks.
class NumberField extends StatefulWidget {
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  /// Typed input commits only on Enter or leaving the field, and a number
  /// outside [min, max] is refused with a message instead of clamped. For a
  /// value whose every save re-decides results (the thresholds). The +/-
  /// buttons still commit at once.
  final bool commitOnSubmit;

  const NumberField({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.commitOnSubmit = false,
  });

  @override
  State<NumberField> createState() => _NumberFieldState();
}

/// Stepper AND direct entry. The number between the buttons is a real text
/// field: "15 annotations" must be typeable, not fifteen clicks. The steppers
/// still work, and typing commits per keystroke, clamped to [min, max].
class _NumberFieldState extends State<NumberField> {
  late final TextEditingController _ctl = TextEditingController(
    text: '${widget.value}',
  );
  final FocusNode _focus = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    // Leaving the field with it empty or out of range: show the value that
    // actually stuck, so the display can never disagree with the state.
    // Enter (TextInputAction.done) unfocuses too, so this is the one place a
    // typed value commits in [NumberField.commitOnSubmit] mode.
    _focus.addListener(() {
      if (_focus.hasFocus || !mounted) return;
      if (widget.commitOnSubmit && _commit()) return;
      if (_ctl.text != '${widget.value}') _ctl.text = '${widget.value}';
    });
  }

  /// Saves what was typed, or refuses it with a message. True when it saved.
  bool _commit() {
    final String raw = _ctl.text.trim();
    final int? n = int.tryParse(raw);
    if (n != null && n >= widget.min && n <= widget.max) {
      if (n != widget.value) widget.onChanged(n);
      _ctl.text = '$n';
      return true;
    }
    if (raw.isNotEmpty) {
      setState(
        () => _error =
            '$raw is not allowed: enter ${widget.min} to ${widget.max}.',
      );
    }
    return false;
  }

  @override
  void didUpdateWidget(covariant NumberField old) {
    super.didUpdateWidget(old);
    // A stepper press (or an outside reset) changed the value: reflect it -
    // but never while the change came from what is being typed right now.
    if (widget.value != old.value) _error = null;
    if (widget.value != old.value &&
        widget.value != int.tryParse(_ctl.text.trim())) {
      _ctl.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _typed(String raw) {
    final int? n = int.tryParse(raw.trim());
    if (n == null) return; // Mid-edit emptiness: keep the last valid value.
    // BELOW THE FLOOR IS A PREFIX, NOT AN ANSWER, so it commits nothing.
    //
    // "15" arrives as "1" first. Clamping that up to the minimum would commit
    // the minimum: on the assessment detail screen, which posts on every
    // change, typing 15 over 45 would briefly save a 2-minute exam before
    // settling on 15. Worse in the version this replaced, where the value
    // could be escaped DOWNWARD and typing the "1" of "15" over 45 silently
    // saved 0 - which then meant "no limit", so the server had no reason to
    // refuse it and there was not even a toast.
    //
    // Above the maximum still clamps, because there is no prefix reading of a
    // number that is already too big.
    if (n < widget.min) return;
    final int clamped = n.clamp(widget.min, widget.max);
    if (clamped != widget.value) widget.onChanged(clamped);
  }

  void _clearError(String _) {
    if (_error != null) setState(() => _error = null);
  }

  /// The next value below/above the current one, or null when the stepper has
  /// nowhere left to go - which is what greys the button out.
  int? _step({required bool up}) {
    final int v = widget.value + (up ? 1 : -1);
    return v < widget.min || v > widget.max ? null : v;
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final int? down = _step(up: false);
    final int? up = _step(up: true);
    final Widget row = Row(
      children: <Widget>[
        Btn(
          '-',
          size: BtnSize.sm,
          onPressed: down == null ? null : () => widget.onChanged(down),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 56,
          height: 30,
          child: TextField(
            controller: _ctl,
            focusNode: _focus,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            onChanged: widget.commitOnSubmit ? _clearError : _typed,
            style: context.type.mono.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
            cursorColor: t.primary,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: t.bgApp,
              contentPadding: const EdgeInsets.symmetric(vertical: 6),
              border: OutlineInputBorder(
                borderRadius: Radii.buttonSm,
                borderSide: BorderSide(color: t.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: Radii.buttonSm,
                borderSide: BorderSide(color: t.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: Radii.buttonSm,
                borderSide: BorderSide(color: t.primary.o(.55)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Btn(
          '+',
          size: BtnSize.sm,
          onPressed: up == null ? null : () => widget.onChanged(up),
        ),
      ],
    );
    if (!widget.commitOnSubmit) return row;
    // Always a Column in this mode: swapping Row for Column when the message
    // comes and goes would rebuild the text field and drop its focus.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        row,
        if (_error != null) ...<Widget>[
          const SizedBox(height: 4),
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: context.type.tiny.copyWith(color: t.destText),
            ),
          ),
        ],
      ],
    );
  }
}

/// The acknowledgement gate for a draft's blocking quality warnings.
///
/// SHARED, because there are two ways into the same decision: the review queue
/// works a card at a time, and the generator's Drafts tab ticks a row. That
/// second path used to open a preview with the warnings printed read-only and
/// no way to accept them, so a flagged draft could be seen and never approved -
/// the tick refused, the sheet explained why, and the sheet had only a Close
/// button. One widget, so both surfaces gate on the same act.
///
/// Focusable and operable from the keyboard. The queue around it is driven by
/// J/K/A/D, so a mouse-only checkbox in the middle of that flow was the one
/// step a reviewer had to leave the keyboard for.
class AckBox extends StatelessWidget {
  final bool checked;

  /// How many blocking warnings are being acknowledged - the label counts them
  /// so the reviewer cannot tick one box believing it covered one problem.
  ///
  /// Ignored when [label] is given.
  final int count;

  /// The whole sentence, for a gate that is not about acknowledging N
  /// warnings. The exam instructions page uses one: a candidate is confirming
  /// they have read the rules, and the count-derived wording above talks about
  /// serving a question, which is a reviewer's concern.
  ///
  /// An override rather than a second widget, because what is worth sharing
  /// here is the KEYBOARD path - `Semantics(checked:)` plus
  /// `FocusableActionDetector`, so Space toggles it and a screen reader
  /// announces the state. A hand-rolled checkbox on a new surface is how that
  /// gets lost.
  final String? label;

  final VoidCallback onToggle;

  const AckBox({
    required this.checked,
    required this.onToggle,
    this.count = 0,
    this.label,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final String label =
        this.label ??
        (count == 1
            ? 'I have looked at this warning and this question is still fair '
                  'to serve.'
            : 'I have looked at all $count warnings and this question is still '
                  'fair to serve.');

    return Semantics(
      container: true,
      checked: checked,
      label: label,
      onTap: onToggle,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onToggle();
              return null;
            },
          ),
        },
        child: Builder(
          builder: (BuildContext context) {
            final bool focused = Focus.of(context).hasFocus;
            return GestureDetector(
              // ONE NODE FOR A SCREEN READER (BR-D9). The Semantics above
              // already carries the tap; this one's own tap split the
              // focusable part off into a second node with no name, so Tab
              // landed on an unnamed button instead of the labelled checkbox.
              excludeFromSemantics: true,
              onTap: onToggle,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: checked ? t.primarySubtle : t.bgApp,
                  borderRadius: Radii.option,
                  border: Border.all(
                    color: checked || focused ? t.primary : t.border,
                    // The focus ring, stated in width rather than colour: the
                    // checked state already owns the accent colour, so colour
                    // alone could not tell "focused" from "ticked".
                    width: focused ? 2 : 1,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      width: 18,
                      height: 18,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: checked ? t.primary : t.bgApp,
                        borderRadius: Radii.bar,
                        border: Border.all(
                          color: checked ? t.primary : t.border,
                        ),
                      ),
                      child: checked
                          ? Icon(Icons.check, size: 13, color: t.bgApp)
                          : null,
                    ),
                    const SizedBox(width: 10),
                    // ExcludeSemantics: the label is already announced by the
                    // Semantics wrapper above, which is what carries the
                    // checked state. Without this the text is read twice.
                    Expanded(
                      child: ExcludeSemantics(
                        child: Text(label, style: context.type.body),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The app's text input, shaped like every other input here, for dynamic
/// designer rows.
///
/// SHARED, not screen-owned: `FormItemEditor` and `FormPreview` are meant to
/// be standalone blocks any screen can host (Form Studio today, a template
/// editor already, more to come) - one of them importing this from a
/// concrete screen file would be exactly the coupling that breaks that.
///
/// WHY THIS OWNS A CONTROLLER instead of handing `initialValue` to a
/// `TextFormField`, which is what it used to do and is the simpler code.
///
/// `initialValue` is read ONCE, in `initState`. `TextFormField.didUpdateWidget`
/// does not re-sync it, and the key here is the record id - stable across a
/// value change - so the element is UPDATED, never remounted. The field
/// therefore ignored any change to [value] that did not come from the user
/// typing it.
///
/// That is invisible for a field only ever written by its own keystrokes, and
/// it was wrong for the one field that is not: pasting a Google Drive share
/// link rewrites it into a url that displays (`_resolveShareLink`), and the box
/// went on showing the share page the examiner pasted while the model held the
/// rewritten url. The picture rendered and the field disagreed with it - which
/// reads as the rewrite having silently failed, and leaves the examiner looking
/// at a share link they have already been told is the wrong thing to paste.
///
/// THE SYNC IS GUARDED ON TEXT, NOT ON IDENTITY. Every host rebuilds this on
/// each keystroke with the value it just received, so an unconditional
/// assignment would reset the selection on every character typed. Comparing
/// against the controller's own text means a rebuild caused by the user's own
/// typing is a no-op, and only a value the field did not author moves the
/// caret - to the end, which is where it belongs after a programmatic rewrite.
class FormTextInput extends StatefulWidget {
  final String id;
  final String value;
  final String hint;
  final int maxLines;
  final ValueChanged<String> onChanged;

  /// Owned by the caller when set - lets an annotation marker focus its
  /// answer field from the image. Never disposed here.
  final FocusNode? focusNode;

  const FormTextInput({
    super.key,
    required this.id,
    required this.value,
    required this.hint,
    required this.onChanged,
    this.maxLines = 1,
    this.focusNode,
  });

  @override
  State<FormTextInput> createState() => _FormTextInputState();
}

class _FormTextInputState extends State<FormTextInput> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(FormTextInput old) {
    super.didUpdateWidget(old);
    // Only when the incoming value is not what the box already holds - see the
    // class doc for why comparing text rather than widget identity is what
    // keeps typing from resetting the caret.
    if (widget.value != _ctrl.text) {
      _ctrl.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return TextFormField(
      key: ValueKey<String>('fti-${widget.id}'),
      controller: _ctrl,
      maxLines: widget.maxLines,
      focusNode: widget.focusNode,
      onChanged: widget.onChanged,
      style: context.type.body,
      cursorColor: t.primary,
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        hintStyle: context.type.bodyMuted,
        filled: true,
        fillColor: t.bgApp,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: Radii.input,
          borderSide: BorderSide(color: t.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: Radii.input,
          borderSide: BorderSide(color: t.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: Radii.input,
          borderSide: BorderSide(color: t.primary.o(.55)),
        ),
      ),
    );
  }
}

/// The label a [SelectField] shows, with a tooltip iff it is really cut.
///
/// MEASURED AGAINST THE ROOM IT ACTUALLY HAS. This used to measure against the
/// control's `maxWidth` minus a hand-derived chrome constant, and that is wrong
/// twice over. `maxWidth` is only a CAP - a toolbar hands the control whatever
/// share it has, so a squeezed filter paints its label into far less than the
/// cap, ellipsises it, and was told it fitted: no tooltip in precisely the case
/// the tooltip exists for. And the open menu is not the button's width at all;
/// Flutter inflates it by `_kUnalignedMenuMargin` (16 + 24), so menu rows that
/// fitted got a tooltip anyway.
///
/// `LayoutBuilder` hands us the same box the `Text` below is given, so there is
/// no geometry left to derive and nothing to drift on the next SDK bump. It is
/// safe here because [SelectField] sets `isExpanded`, under which
/// `DropdownButton` lays its children out against real constraints rather than
/// asking them for intrinsics - which is what a `LayoutBuilder` cannot answer.
class _ClippedLabel extends StatelessWidget {
  const _ClippedLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = context.type.body;
    final Widget label = Text(
      text,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          // THE VIEWER'S OWN TEXT SIZE. A `Text` scales with it and a
          // `TextPainter` does not unless told, so at the browser's "Large"
          // setting every name ellipsised earlier and none of them carried a
          // tooltip - the accessibility setting removed the recovery path.
          // Reading it here also registers the dependency, so a live change
          // re-measures.
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
        )..layout(maxWidth: c.maxWidth);
        return painter.didExceedMaxLines
            ? Tooltip(message: text, child: label)
            : label;
      },
    );
  }
}
