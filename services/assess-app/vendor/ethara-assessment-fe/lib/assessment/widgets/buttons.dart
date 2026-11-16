// Buttons and controls - HANDOVER §2.4, §3.2, §3.7.
//
// Every button is this one widget with a variant. The rules it carries:
//  - Hover moves the BORDER AND THE INK to the accent on secondary buttons;
//    only the primary moves its fill. `IconBtn` adds a muted chip on hover,
//    because a bare glyph has no resting border to strengthen.
//  - A disabled button never reacts to the pointer and takes `not-allowed`.
//  - One focus ring everywhere: accent, 2px, 2px offset - and the ring is a
//    promise, so Enter and Space press the button the ring is on.
//  - A press lands only while the button's route is the top one - see
//    [popIfCurrent].
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
// `show Toaster` deliberately: feedback.dart and loaders.dart both define
// a `Spinner`, and a bare import makes the one `Btn` already uses ambiguous.
import 'feedback.dart' show Toaster;
import 'loaders.dart';

/// Pops the route [context] is IN, unless that route has already left the top.
///
/// A double-click lands both clicks before the next frame, so a dialog button
/// ran `Navigator.pop` twice: the first closed the dialog, the second the page
/// under it - a white page with nothing in it ("Submit Anyway" did this over a
/// live exam). [Btn] and [IconBtn] make the same check before every press,
/// which covers the sheet actions built with the PAGE's context; this is for
/// the other widgets that pop, and for a pop after an `await`. Returns whether
/// it popped.
bool popIfCurrent<T extends Object?>(BuildContext context, [T? result]) {
  if (!_routeIsCurrent(context)) return false;
  Navigator.of(context).pop<T>(result);
  return true;
}

/// True outside any route, which is every button a test pumps bare.
bool _routeIsCurrent(BuildContext context) =>
    ModalRoute.isCurrentOf(context) ?? true;

enum BtnVariant {
  /// `.btn` - the default. Resting: app surface, hairline border, secondary
  /// ink. One per surface may be promoted to primary.
  normal,

  /// `.btn.primary` - the single commitment on a surface.
  primary,

  /// `.btn.danger` - destructive or corrective (erase, re-score errored).
  danger,

  /// The accent twin of [danger]: a tinted fill, accent ink, accent hairline.
  /// For an action that is significant and costs something - Score All spends
  /// paid LLM calls - but is NOT destructive, so red would overstate it
  /// and the plain [normal] treatment understates it.
  accent,

  /// [danger] with the fill removed: accent-free background, red ink, a slim
  /// red hairline. For a destructive action that must read as distinct from a
  /// neighbouring [danger] button rather than as a second copy of it - Kill
  /// Scoring Process sits beside Cancel, and two identical red buttons make an
  /// operator check which is which.
  dangerOutline,
}

enum BtnSize {
  /// `.btn.sm` - 27px. Dense contexts: toolbars, pagers, inline row actions.
  sm,

  /// `.btn` - 32px. The default.
  md,

  /// `.btn.lg` - 38px. A single primary commitment on a full-width surface.
  lg,
}

/// The one button.
class Btn extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final BtnVariant variant;
  final BtnSize size;
  final IconData? icon;

  /// `aria-pressed` - a toggle button. When true the button takes the accent
  /// tint, which is a different treatment from hover so the two never read as
  /// the same thing.
  final bool? pressed;

  /// A mono keyboard hint printed after the label, as the review queue does
  /// (`Approve into bank  A`).
  final String? keyHint;

  final bool expand;

  /// In flight. The icon slot becomes a spinner so the button keeps its width.
  /// Also NOT pressable - `enabled` folds this in, because the failure worth
  /// preventing is a second click on a slow, paid or irreversible action.
  final bool busy;

  /// An icon AFTER the label, for a control whose direction is forward. [icon]
  /// leads instead, which is right for "back" and wrong for "next".
  final IconData? trailingIcon;

  /// What this button DOES, for a reader who has not read the code.
  ///
  /// Not a restatement of the label: it carries what the action reaches, what
  /// it costs (an LLM call is real money) and whether it can be undone - a
  /// verb alone is not informed consent. It lives on the button rather than a
  /// `Tooltip` at each call site so wrapping, width and delay are decided once.
  final String? tooltip;

  const Btn(
    this.label, {
    super.key,
    this.busy = false,
    this.onPressed,
    this.variant = BtnVariant.normal,
    this.size = BtnSize.md,
    this.icon,
    this.trailingIcon,
    this.pressed,
    this.keyHint,
    this.expand = false,
    this.tooltip,
  });

  const Btn.primary(
    this.label, {
    super.key,
    this.busy = false,
    this.onPressed,
    this.size = BtnSize.md,
    this.icon,
    this.trailingIcon,
    this.keyHint,
    this.expand = false,
    this.tooltip,
  }) : variant = BtnVariant.primary,
       pressed = null;

  const Btn.danger(
    this.label, {
    super.key,
    this.busy = false,
    this.onPressed,
    this.size = BtnSize.md,
    this.icon,
    this.trailingIcon,
    this.keyHint,
    this.expand = false,
    this.tooltip,
  }) : variant = BtnVariant.danger,
       pressed = null;

  const Btn.accent(
    this.label, {
    super.key,
    this.busy = false,
    this.onPressed,
    this.size = BtnSize.md,
    this.icon,
    this.trailingIcon,
    this.keyHint,
    this.expand = false,
    this.tooltip,
  }) : variant = BtnVariant.accent,
       pressed = null;

  const Btn.dangerOutline(
    this.label, {
    super.key,
    this.busy = false,
    this.onPressed,
    this.size = BtnSize.md,
    this.icon,
    this.trailingIcon,
    this.keyHint,
    this.expand = false,
    this.tooltip,
  }) : variant = BtnVariant.dangerOutline,
       pressed = null;

  bool get enabled => onPressed != null && !busy;

  @override
  State<Btn> createState() => _BtnState();
}

class _BtnState extends State<Btn> {
  bool _hover = false;

  /// Whether the focus this button currently holds arrived from a POINTER.
  ///
  /// The ring is a keyboard affordance - it answers "where am I in the
  /// traversal" - but a tap also focuses the node, so every clicked button kept
  /// a 2px accent ring around it afterwards. On a toolbar that reads as the
  /// button being stuck in some state, which is what was reported about Score
  /// All. Flutter's own `FocusManager.highlightMode` distinguishes touch from
  /// mouse, not keyboard from mouse, so the pointer press is recorded here
  /// instead and cleared the moment focus moves on.
  bool _focusFromPointer = false;

  /// See [popIfCurrent]: a second click on a dialog button that already
  /// closed the dialog must not act on whatever is under it.
  void _press() {
    if (_routeIsCurrent(context)) widget.onPressed?.call();
  }

  double get _height => switch (widget.size) {
    BtnSize.sm => 27,
    BtnSize.md => 32,
    BtnSize.lg => 38,
  };

  double get _padH => switch (widget.size) {
    BtnSize.sm => 9,
    BtnSize.md => 11,
    BtnSize.lg => 18,
  };

  double get _fontSize => switch (widget.size) {
    BtnSize.sm => 11.5,
    BtnSize.md => 12.5,
    BtnSize.lg => 13.5,
  };

  // Yantra (studio look): every Btn is a pill.
  BorderRadius get _radius => switch (widget.size) {
    BtnSize.sm => Radii.btnPill,
    BtnSize.md => Radii.btnPill,
    BtnSize.lg => Radii.btnPill,
  };

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool on = widget.enabled;

    // Hover only applies when the button is enabled - `:hover:not(:disabled)`.
    final bool hovering = _hover && on;
    final bool studioPrimary =
        widget.pressed != true && widget.variant == BtnVariant.primary;

    Color bg;
    Color fg;
    Color border;

    if (widget.pressed == true) {
      // `.btn[aria-pressed="true"]` - an active toggle.
      bg = t.primarySubtle;
      fg = t.primary;
      border = t.primary.o(.45);
    } else {
      switch (widget.variant) {
        case BtnVariant.primary:
          bg = hovering ? t.primaryHover : t.primary;
          fg = const Color(0xFFFFFFFF);
          border = hovering ? t.primaryHover : t.primary;
        case BtnVariant.danger:
          bg = t.destBg;
          fg = t.destText;
          border = t.destText.o(hovering ? .7 : .4);
        case BtnVariant.accent:
          // The tinted-fill treatment `pressed` uses, as a variant a caller can
          // ask for. The fill deliberately does NOT move on hover - that stays
          // the primary button's one distinction - so hover strengthens the
          // border, exactly as `normal` does.
          bg = t.primarySubtle;
          fg = t.primary;
          border = t.primary.o(hovering ? .7 : .4);
        case BtnVariant.dangerOutline:
          // NO FILL. `bgApp` rather than transparent so it reads the same on
          // every surface this sits on, and matches how `normal` rests.
          bg = t.bgApp;
          fg = t.destText;
          border = t.destText.o(hovering ? .8 : .55);
        case BtnVariant.normal:
          bg = t.bgApp;
          // The INK takes the accent on hover, not merely more contrast: the
          // border was already accent-tinted, so a label answering one step
          // darker in grey read as nothing happening. The fill deliberately
          // does not move - that stays the primary button's one distinction.
          fg = hovering ? t.primary : t.textSecondary;
          border = hovering ? t.borderHover : t.border;
      }
    }

    final Widget content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (widget.busy) ...<Widget>[
          Spinner(size: _fontSize + 2, color: fg),
          const SizedBox(width: 6),
        ] else if (widget.icon != null) ...<Widget>[
          Icon(widget.icon, size: _fontSize + 2, color: fg),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.type.button.copyWith(fontSize: _fontSize, color: fg),
          ),
        ),
        // Never while busy: the spinner already holds the leading slot, and two
        // moving marks on one control read as two things happening.
        if (widget.trailingIcon != null && !widget.busy) ...<Widget>[
          const SizedBox(width: 6),
          Icon(widget.trailingIcon, size: _fontSize + 2, color: fg),
        ],
        if (widget.keyHint != null) ...<Widget>[
          const SizedBox(width: 8),
          Text(
            widget.keyHint!,
            style: context.type.monoSmall.copyWith(color: fg.o(.7)),
          ),
        ],
      ],
    );

    final Widget hit = MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Opacity(
        opacity: on ? 1 : .42,
        child: GestureDetector(
          // Recorded BEFORE the tap fires, so the ring is already suppressed by
          // the time focus lands on this node.
          onTapDown: on ? (_) => _focusFromPointer = true : null,
          // `on`, not `onPressed`: a BUSY button is disabled too (see the
          // header), and it still fired - "Submit Assessment" in flight
          // (A-052) took a second tap.
          onTap: on ? _press : null,
          child: Focus(
            canRequestFocus: on,
            // ENTER AND SPACE PRESS IT, exactly as a click does.
            //
            // A `GestureDetector` hears pointers and nothing else, and a bare
            // `Focus` supplies a node and the ring below but binds no
            // `ActivateIntent` - only `FocusableActionDetector`, `InkWell` and
            // the Material buttons do, and nothing above these screens
            // registers one either. So every button in the console could be
            // tabbed to, drew a ring saying it was ready, and then did nothing
            // at all when pressed: a ring advertising an interaction that did
            // not exist is worse than a control that never took focus. The
            // confirmation sheets are where it bit - their only affirmative
            // action is a `Btn`, so "Close It Anyway" and "Archive Anyway"
            // could be read by a keyboard operator and not answered.
            //
            // A KEY HANDLER RATHER THAN THE `Actions` STACK, because the node
            // is already here: the handler runs before the app-level
            // `Shortcuts` that would map these two keys to `ActivateIntent`,
            // and returning `handled` is what stops the press being counted
            // twice. `KeyDownEvent` only - a held Enter must not fire a
            // destructive button once per repeat.
            onKeyEvent: (FocusNode node, KeyEvent e) {
              if (!on || e is! KeyDownEvent) return KeyEventResult.ignored;
              if (e.logicalKey != LogicalKeyboardKey.enter &&
                  e.logicalKey != LogicalKeyboardKey.numpadEnter &&
                  e.logicalKey != LogicalKeyboardKey.space) {
                return KeyEventResult.ignored;
              }
              _press();
              return KeyEventResult.handled;
            },
            // Losing focus clears the flag, so the next arrival - which may be
            // a Tab press - is treated as the keyboard focus it is.
            onFocusChange: (bool hasFocus) {
              if (!hasFocus && _focusFromPointer) {
                setState(() => _focusFromPointer = false);
              }
            },
            child: Builder(
              builder: (BuildContext ctx) {
                final bool focused =
                    Focus.of(ctx).hasFocus && !_focusFromPointer;
                return Container(
                  height: _height,
                  padding: EdgeInsets.symmetric(horizontal: _padH),
                  decoration: BoxDecoration(
                    color: bg,
                    // Yantra (studio look): an enabled primary is the brand
                    // gradient pill, with a magenta glow under it on hover.
                    gradient: studioPrimary ? PortalTokens.brand : null,
                    borderRadius: _radius,
                    border: Border.all(
                      color: studioPrimary ? Colors.transparent : border,
                    ),
                    // The one global focus ring: 2px accent, 2px offset.
                    boxShadow: focused
                        ? <BoxShadow>[
                            BoxShadow(color: t.bgApp, spreadRadius: 2),
                            BoxShadow(color: t.ring, spreadRadius: 4),
                          ]
                        : (studioPrimary && hovering
                              ? const <BoxShadow>[
                                  BoxShadow(
                                    color: Color(0x73E11FE0),
                                    offset: Offset(0, 8),
                                    blurRadius: 24,
                                    spreadRadius: -8,
                                  ),
                                ]
                              : null),
                  ),
                  // Only an expanding button centres its content, and that is
                  // the ONLY reason to set `alignment` here. A Container with an
                  // alignment expands to fill whatever width it is offered, so
                  // setting it unconditionally makes every button in a Wrap or a
                  // wide Row stretch edge to edge. A default button must size to
                  // its label; the Row inside already centres it.
                  alignment: widget.expand ? Alignment.center : null,
                  child: content,
                );
              },
            ),
          ),
        ),
      ),
    );

    // What the tint and the opacity draw, said to a screen reader: the role,
    // whether it can be pressed, and `aria-pressed` as selected - so the lit
    // candidates tile is announced as the slice on screen. Null [Btn.pressed]
    // is not a toggle and announces no selected state. Layout is untouched.
    final Widget button = Semantics(
      button: true,
      enabled: on,
      selected: widget.pressed,
      child: hit,
    );

    final String? help = widget.tooltip;
    if (help == null || help.isEmpty) return button;
    return Tooltip(
      message: help,
      // WIDE, and it has to be. The default tooltip sizes to its content with
      // no max, so a sentence becomes one long strip off the edge of the
      // window, and constraining it without this width wraps a paragraph into
      // a column two words across.
      constraints: const BoxConstraints(maxWidth: 340),
      // Long enough not to fire while a pointer merely crosses a toolbar,
      // short enough to answer a question the reader is already asking.
      waitDuration: const Duration(milliseconds: 400),
      // A DISABLED button is exactly when the explanation is most wanted -
      // "why can I not press this" - and the tooltip sits outside the
      // Opacity/GestureDetector for that reason.
      child: button,
    );
  }
}

/// `.iconbtn` - a 27x27 square that rests as invisible chrome. Structure
/// appears only on hover, so a row of them does not read as a toolbar.
class IconBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;

  /// `.iconbtn.yes` / `.iconbtn.no` - approve and deny, pre-tinted at rest
  /// unlike the plain variant so a decision control is findable at a glance.
  final IconTone? tinted;

  const IconBtn(
    this.icon, {
    super.key,
    this.onPressed,
    this.tooltip = '',
    this.tinted,
  });

  @override
  State<IconBtn> createState() => _IconBtnState();
}

enum IconTone { yes, no }

class _IconBtnState extends State<IconBtn> {
  bool _hover = false;

  /// See [_BtnState._focusFromPointer]: no ring after a click.
  bool _focusFromPointer = false;

  void _press() {
    if (_routeIsCurrent(context)) widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool on = widget.onPressed != null;
    final bool hovering = _hover && on;

    Color fg = t.textMuted;
    Color bg = const Color(0x00000000);
    Color border = const Color(0x00000000);

    switch (widget.tinted) {
      case IconTone.yes:
        fg = t.successText;
        bg = t.successBg;
        border = t.successText.o(hovering ? .7 : .35);
      case IconTone.no:
        fg = t.destText;
        bg = t.destBg;
        border = t.destText.o(hovering ? .7 : .35);
      case null:
        // The same answer a secondary `Btn` gives: accent ink, accent-tinted
        // border. The muted FILL stays too - a bare glyph has no resting
        // border, so the chip appearing IS its affordance, not decoration.
        // Untinted only: approve and deny are green and red because the
        // DECISION is, and tinting them accent would say hover changed it.
        if (hovering) {
          fg = t.primary;
          bg = t.bgMuted;
          border = t.borderHover;
        }
    }

    final Widget btn = MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: on ? (_) => _focusFromPointer = true : null,
        // See [popIfCurrent].
        onTap: on ? _press : null,
        // REACHED BY TAB AND PRESSED BY ENTER OR SPACE (BR-D9), as [Btn] is and
        // for the same reasons. Without a focus node the theme toggle - on the
        // rail and on the exam's top bar - could not be reached from the
        // keyboard at all.
        child: Focus(
          canRequestFocus: on,
          onKeyEvent: (FocusNode node, KeyEvent e) {
            if (!on || e is! KeyDownEvent) return KeyEventResult.ignored;
            if (e.logicalKey != LogicalKeyboardKey.enter &&
                e.logicalKey != LogicalKeyboardKey.numpadEnter &&
                e.logicalKey != LogicalKeyboardKey.space) {
              return KeyEventResult.ignored;
            }
            _press();
            return KeyEventResult.handled;
          },
          onFocusChange: (bool hasFocus) {
            if (!hasFocus && _focusFromPointer) {
              setState(() => _focusFromPointer = false);
            }
          },
          child: Builder(
            builder: (BuildContext ctx) {
              final bool focused = Focus.of(ctx).hasFocus && !_focusFromPointer;
              return Opacity(
                opacity: on ? 1 : .42,
                child: Container(
                  width: 27,
                  height: 27,
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: Radii.buttonSm,
                    border: Border.all(color: border),
                    // The one global focus ring, as on [Btn].
                    boxShadow: focused
                        ? <BoxShadow>[
                            BoxShadow(color: t.bgApp, spreadRadius: 2),
                            BoxShadow(color: t.ring, spreadRadius: 4),
                          ]
                        : null,
                  ),
                  child: Icon(widget.icon, size: 15, color: fg),
                ),
              );
            },
          ),
        ),
      ),
    );

    return widget.tooltip.isEmpty
        ? btn
        : Tooltip(message: widget.tooltip, child: btn);
  }
}

/// Put one value on the clipboard. The icon twin of the labelled
/// `Btn('Copy Candidate Link')` on attempt detail - the same clipboard call
/// and the same toast, so an operator learns one confirmation and not two.
///
/// Disabled when [text] is empty, for the reason written on that button: a
/// toast that says "copied" over an untouched clipboard is worse than no
/// control at all, because the operator then pastes whatever was there before.
class CopyBtn extends StatelessWidget {
  /// The EXACT value that lands on the clipboard. Empty disables the control.
  final String text;

  final Toaster toaster;

  /// What the toast says once it has been copied, e.g. 'Email copied'.
  final String toast;

  /// OPTIONAL, and deliberately unset on the candidate email: the icon sits
  /// directly beside the address it copies, so a hover card only repeats what
  /// the eye already has. `IconBtn` renders no Tooltip for an empty message
  /// (see its build), so passing nothing here costs nothing. Kept on the type
  /// because a copy control somewhere less self-evident still wants one.
  ///
  /// [semanticsLabel] is NOT optional - a screen reader has no "beside it".
  final String? tooltip;

  /// Announced to a screen reader, as a verb phrase: 'Copy email address'.
  /// Separate from [tooltip], which is prose written for the pointer.
  final String semanticsLabel;

  const CopyBtn(
    this.text, {
    super.key,
    required this.toaster,
    required this.toast,
    this.tooltip,
    required this.semanticsLabel,
  });

  /// WCAG 2.5.5, and a REAL box rather than an `OverflowBox` drawn around the
  /// 27px chip: `RenderBox.hitTest` rejects any position outside the box's own
  /// size before it ever reaches a child, so a target painted outside its
  /// parent's bounds is invisible to the pointer and only LOOKS fixed. The
  /// chip stays 27; the line it sits on pays 44. That padding is also the gap
  /// to whatever sits left of it, which is why call sites add no `SizedBox`.
  static const double _kTarget = 44;

  @override
  Widget build(BuildContext context) {
    final bool on = text.isNotEmpty;

    Future<void> copy() async {
      // THE CLIPBOARD CAN REFUSE, and this app runs on the web where it
      // routinely does: a browser denies the write when the page is not
      // focused, when the permission was declined, or over plain http. The
      // unguarded call let that exception reach the framework, and the success
      // toast below - written after the await - never ran, so the operator got
      // a red overlay in debug and, in release, a button that did nothing
      // silently. Report the failure as a failure instead.
      try {
        await Clipboard.setData(ClipboardData(text: text));
      } catch (_) {
        toaster.bad('Could not copy - your browser blocked clipboard access');
        return;
      }
      toaster.ok(toast);
    }

    final Widget hit = SizedBox(
      width: _kTarget,
      height: _kTarget,
      // Opaque, and OUTSIDE the chip: on a touch screen most of the target is
      // the space around a 15px glyph. `IconBtn` keeps its own gesture for the
      // hover chip and the cursor; nested taps resolve to a single winner in
      // the gesture arena, so this copies once - which the widget test pins by
      // asserting exactly ONE toast after one tap.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: on ? copy : null,
        // Center, not a bare child: a `SizedBox` hands down TIGHT constraints,
        // which would stretch the 27px chip to fill all 44 and turn the hover
        // state into a slab.
        child: Center(
          child: IconBtn(
            Icons.copy_outlined,
            tooltip: tooltip ?? '',
            onPressed: on ? copy : null,
          ),
        ),
      ),
    );

    // The Tooltip inside `IconBtn` contributes its message to the semantics
    // tree, so without `ExcludeSemantics` this control is announced twice -
    // the same fix the roster's include toggle already carries. `onTap` is
    // here too because assistive technology activates the SEMANTICS node and
    // not the gesture, so without it this could be heard and not operated.
    return Semantics(
      button: true,
      enabled: on,
      label: semanticsLabel,
      onTap: on ? copy : null,
      child: ExcludeSemantics(child: hit),
    );
  }
}

/// `.linkbtn` - a button that must read as body text until hovered.
class LinkBtn extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final TextStyle? style;

  /// Clip to one line rather than run past the edge. Off by default - a link
  /// is normally a short phrase that should wrap. Opt-in for labels that are
  /// opaque IDENTIFIERS, like a 36-character exam token no wording can
  /// shorten, which in a right-aligned key/value row ran under its own key
  /// column on anything narrower than a desktop.
  final bool clip;

  const LinkBtn(
    this.label, {
    super.key,
    this.onPressed,
    this.style,
    this.clip = false,
  });

  @override
  State<LinkBtn> createState() => _LinkBtnState();
}

class _LinkBtnState extends State<LinkBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final TextStyle base =
        widget.style ?? context.type.body.copyWith(fontWeight: FontWeight.w600);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Text(
          widget.label,
          maxLines: widget.clip ? 1 : null,
          overflow: widget.clip ? TextOverflow.ellipsis : null,
          style: base.copyWith(
            color: _hover ? t.primary : base.color,
            decoration: _hover ? TextDecoration.underline : null,
            decorationColor: t.primary,
          ),
        ),
      ),
    );
  }
}

/// `.sw` - a 36x21 switch. `role="switch"` with `aria-checked`; the attribute
/// IS the state, and the knob travels 15px on a .15s transition.
class Switcher extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  const Switcher({super.key, required this.value, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool on = onChanged != null;
    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
      child: GestureDetector(
        onTap: on ? () => onChanged!(!value) : null,
        child: Opacity(
          opacity: on ? 1 : .45,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 36,
            height: 21,
            decoration: BoxDecoration(
              color: value ? t.primary : t.bgMuted,
              borderRadius: Radii.pill,
              border: Border.all(color: value ? t.primary : t.border),
            ),
            child: Stack(
              children: <Widget>[
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  left: value ? 15 : 0,
                  top: 0,
                  child: Container(
                    width: 15,
                    height: 15,
                    margin: const EdgeInsets.all(1),
                    decoration: BoxDecoration(
                      color: t.bgApp,
                      shape: BoxShape.circle,
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: t.shadow.o(.25),
                          blurRadius: 2,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `.switchrow` - a labelled setting: name, hint, switch pushed right. The
/// hint is required - an unexplained boolean cannot be set confidently.
class SwitchRow extends StatelessWidget {
  final String name;
  final String hint;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool last;

  const SwitchRow({
    super.key,
    required this.name,
    required this.hint,
    required this.value,
    this.onChanged,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: t.borderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  name,
                  style: context.type.body.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (hint.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(hint, style: context.type.tiny.copyWith(height: 1.45)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Switcher(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
