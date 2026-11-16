// Feedback surfaces - HANDOVER §2.8, §6.9, §7.6. Three channels, separated by
// how long the message must live: Banner stays while the condition does; Check
// list evaluates a set of gating conditions together; Toast acknowledges an
// event and comes down on a timer scaled to its own length.
//
// TWO DEVIATIONS FROM §6.9, BOTH EARNED. The spec's flat 3200ms and its
// `pointer-events: none` container were written for "Saved" and "Copied", and
// they silently broke the one message that most needed reading: a launch
// refusal naming four gates is 439 characters - about seventy words - and was
// given 3.2 seconds and no way to hold it open. See [toastDwell] and
// [ToastLayer].
import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/enums.dart';
import '../domain/gates.dart';
import 'marks.dart';
import '../theme.dart';

/// `.banner` - a persistent tinted strip. `bad` and `warn` take a warning
/// icon, everything else an info icon.
class Notice extends StatelessWidget {
  final Tone tone;

  /// The lead sentence, rendered bold.
  final String? strong;
  final String text;
  final List<Widget> actions;

  const Notice({
    super.key,
    required this.tone,
    this.strong,
    required this.text,
    this.actions = const <Widget>[],
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final ToneColors c = ToneColors.of(t, tone);
    final bool alarming = tone == Tone.bad || tone == Tone.warn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        border: Border.all(color: tone == Tone.inert ? t.border : c.fg.o(.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              alarming ? Icons.warning_amber_rounded : Icons.info_outline,
              size: 16,
              color: c.fg,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: <TextSpan>[
                  if (strong != null)
                    TextSpan(
                      text: '$strong ',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: c.fg,
                      ),
                    ),
                  TextSpan(text: text),
                ],
              ),
              style: context.type.banner.copyWith(color: c.fg),
            ),
          ),
          if (actions.isNotEmpty) ...<Widget>[
            const SizedBox(width: 10),
            Wrap(
              spacing: 7,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}

/// `.checks` - a bordered stack of evaluated conditions. §7.6: EVALUATE EVERY
/// CONDITION AND SHOW THEM TOGETHER - a failing one says what is wrong and
/// lists the offending records beneath it.
class CheckList extends StatelessWidget {
  final List<GateResult> checks;

  const CheckList(this.checks, {super.key});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      decoration: BoxDecoration(
        color: t.borderSubtle,
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        border: Border.all(color: t.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < checks.length; i++) ...<Widget>[
            if (i > 0) Container(height: 1, color: t.borderSubtle),
            _CheckRow(checks[i]),
          ],
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final GateResult c;

  const _CheckRow(this.c);

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final ToneColors tc = ToneColors.of(
      t,
      c.warning
          ? Tone.warn
          : c.ok
          ? Tone.ok
          : Tone.bad,
    );
    final Color mkBg = tc.bg;
    final Color mkFg = tc.fg;
    final bool clean = c.ok && !c.warning;
    return Container(
      color: t.bgApp,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 18,
            height: 18,
            margin: const EdgeInsets.only(top: 1),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: mkBg, shape: BoxShape.circle),
            child: Text(
              clean ? '\u2713' : '!',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: mkFg,
                height: 1,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  c.name,
                  style: context.type.body.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  c.why,
                  style: context.type.small.copyWith(
                    height: 1.5,
                    color: clean ? t.textSecondary : mkFg,
                  ),
                ),
                if (c.offenders.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 5),
                  for (final String o in c.offenders)
                    Padding(
                      padding: const EdgeInsets.only(left: 4, top: 2),
                      child: Text(
                        '\u2022  $o',
                        style: context.type.small.copyWith(color: mkFg),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ToastMsg {
  final int id;
  final String message;
  final Tone tone;

  /// An optional single action drawn inside the bubble - "Stop waiting" on a
  /// long retry, say. Null for the ordinary acknowledgement, which is the vast
  /// majority.
  final VoidCallback? onAction;
  final String actionLabel;

  const ToastMsg(
    this.id,
    this.message,
    this.tone, {
    this.onAction,
    this.actionLabel = 'Cancel',
  });
}

/// How long a toast stays up, scaled to how long it takes to read.
///
/// 3200ms was the flat lifetime, and it is kept as the FLOOR up to 140
/// characters - about two lines in the bubble, which covers every
/// acknowledgement this app writes ("Saved", "Launched - 12 invitation(s)
/// queued", "Keep at least one question. ..."). Nothing short starts lingering,
/// because nothing short changes at all.
///
/// Past that the message has stopped being an acknowledgement and become a
/// LIST, and it earns about 45ms a character - a shade over 200 words a minute,
/// a normal screen reading pace with some slack. The ceiling is 20s: beyond
/// there the message is read by scrolling it and taken down by tapping it,
/// which is what [ToastLayer] is now bounded and interactive for.
///
/// THE CASE THIS EXISTS FOR: an operator asked to be told WHICH launch gate
/// failed. The refusal that now names all four is 439 characters, and the flat
/// timer gave them seventy words in 3.2 seconds - the answer arrived and could
/// not be read.
Duration toastDwell(String message) {
  const int floorMs = 3200;
  const int freeChars = 140;
  const int msPerChar = 45;
  const int ceilingMs = 20000;
  final int over = message.length - freeChars;
  if (over <= 0) return const Duration(milliseconds: floorMs);
  final int ms = floorMs + over * msPerChar;
  return Duration(milliseconds: ms > ceilingMs ? ceilingMs : ms);
}

/// The global toast channel.
///
/// §6.9: dismissal is BY ID, never by index, so overlapping toasts cannot
/// remove the wrong one. Lifetime is [toastDwell], not a constant.
class Toaster extends ChangeNotifier {
  final List<ToastMsg> _items = <ToastMsg>[];
  int _seq = 0;

  List<ToastMsg> get items => List<ToastMsg>.unmodifiable(_items);

  /// Returns the toast's ID so a caller that finishes early can [dismiss] it
  /// rather than leave it sitting next to the message that replaced it.
  int show(String message, [Tone tone = Tone.info]) {
    final int id = ++_seq;
    _items.add(ToastMsg(id, message, tone));
    notifyListeners();
    Timer(toastDwell(message), () => dismiss(id));
    return id;
  }

  /// A toast for work IN PROGRESS: no expiry, because the work decides when it
  /// is over, not a stopwatch - a request slower than the read-time lifetime
  /// would drop its own progress message. The caller MUST [dismiss] it on
  /// every exit path, success and failure alike.
  int busy(
    String message, {
    VoidCallback? onAction,
    String actionLabel = 'Cancel',
  }) {
    final int id = ++_seq;
    _items.add(
      ToastMsg(
        id,
        message,
        Tone.info,
        onAction: onAction,
        actionLabel: actionLabel,
      ),
    );
    notifyListeners();
    return id;
  }

  /// Replace a live toast's words in place, keeping its ID and its position.
  ///
  /// For a [busy] toast that has something new to say - "the server is busy,
  /// next try in 47s" - where taking it down and putting a new one up would
  /// replay the entrance animation once a second. A no-op for an unknown or
  /// already-expired ID, so a caller may update unconditionally.
  void update(
    int id,
    String message, {
    VoidCallback? onAction,
    String actionLabel = 'Cancel',
  }) {
    final int i = _items.indexWhere((ToastMsg m) => m.id == id);
    if (i < 0) return;
    _items[i] = ToastMsg(
      id,
      message,
      _items[i].tone,
      onAction: onAction,
      actionLabel: actionLabel,
    );
    notifyListeners();
  }

  /// Removes a toast early, by ID. Unknown and already-expired IDs are a
  /// no-op, so a caller may dismiss unconditionally.
  void dismiss(int id) {
    final int before = _items.length;
    _items.removeWhere((ToastMsg m) => m.id == id);
    if (_items.length != before) notifyListeners();
  }

  void ok(String m) => show(m, Tone.ok);
  void bad(String m) => show(m, Tone.bad);
  void warn(String m) => show(m, Tone.warn);
  void info(String m) => show(m, Tone.info);

  /// The [ToastLayer.depth] of every mounted layer. Only the deepest paints:
  /// a sheet carries its own layer over the screen's, and the screen's copy
  /// would otherwise show through the scrim as a dimmed twin.
  final List<int> _layers = <int>[];

  bool _paints(int depth) => _layers.every((int d) => d <= depth);

  void _mount(int depth) {
    _layers.add(depth);
    _afterFrame();
  }

  void _unmount(int depth) {
    _layers.remove(depth);
    _afterFrame();
  }

  /// Layers mount mid-build and unmount mid-finalize, where rebuilding the
  /// other layers is an error, so they hear of it after the frame.
  void _afterFrame() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
}

/// `.toasts` - the fixed, bottom-centred live region.
///
/// BOUNDED, BECAUSE IT USED TO OVERFLOW UPWARDS IN SILENCE. This was a
/// `Positioned(left/right/bottom)`, which hands its child an UNBOUNDED height:
/// the column of toasts grew up out of the top of the Stack and was clipped
/// with no overflow exception to say so. Measured at 390x700, a six-gate
/// refusal lost 48px off its top and a twelve-gate one lost 768px - and what
/// went missing was the head of the message, `Launch blocked:` and the first
/// gate. At 1440x900 it fits, which is why it survived every laptop.
///
/// `Positioned.fill` + `Align` is the fix: the fill makes the available height
/// known, the align keeps the stack pinned to the bottom, and the scroll view
/// takes the child's height only up to what is actually there. Past that it
/// scrolls from the TOP of the message rather than clipping it, so the first
/// words are the ones you always see.
///
/// The `IgnorePointer` that used to wrap this is gone, and that is deliberate
/// rather than incidental: a message too tall to fit has to be scrollable to be
/// readable, and a message held open for twenty seconds has to be dismissable.
/// The scroll view shrink-wraps, so it only takes pointers over the bubbles
/// themselves - the rest of the screen is as clickable as it ever was, and with
/// no toasts up it occupies nothing at all.
class ToastLayer extends StatefulWidget {
  final Toaster toaster;

  /// Extra room kept clear at the bottom: the exam's pinned footer, whose
  /// Previous, Review & Submit and Next a toast must not cover (BR-D2).
  final double lift;

  /// How many sheets deep this layer sits: 0 for the screen's, 1 for a sheet
  /// over it, 2 for a sheet opened from that one. Only the deepest mounted
  /// layer paints - see `showSheet`, which is what puts one over each sheet.
  final int depth;

  const ToastLayer(this.toaster, {super.key, this.lift = 0, this.depth = 0});

  @override
  State<ToastLayer> createState() => _ToastLayerState();
}

class _ToastLayerState extends State<ToastLayer> {
  @override
  void initState() {
    super.initState();
    widget.toaster._mount(widget.depth);
  }

  @override
  void didUpdateWidget(ToastLayer old) {
    super.didUpdateWidget(old);
    if (old.toaster == widget.toaster && old.depth == widget.depth) return;
    old.toaster._unmount(old.depth);
    widget.toaster._mount(widget.depth);
  }

  @override
  void dispose() {
    widget.toaster._unmount(widget.depth);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Toaster toaster = widget.toaster;
    return Positioned.fill(
      child: Padding(
        padding: EdgeInsets.only(top: 18, bottom: 18 + widget.lift),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ListenableBuilder(
            listenable: toaster,
            builder: (BuildContext context, _) => SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: !toaster._paints(widget.depth)
                    ? const <Widget>[]
                    : toaster.items
                          .map(
                            (ToastMsg m) => Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: _Toast(
                                m,
                                onDismiss: () => toaster.dismiss(m.id),
                              ),
                            ),
                          )
                          .toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Toast extends StatefulWidget {
  final ToastMsg msg;

  /// Tapping the bubble takes it down. The counterweight to [toastDwell]'s
  /// ceiling: a long refusal is held open long enough to read, and anyone who
  /// has finished reading it does not have to wait it out.
  final VoidCallback onDismiss;

  const _Toast(this.msg, {required this.onDismiss});

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final ToneColors c = ToneColors.of(t, widget.msg.tone);
    // The `rise` keyframe: fade up 8px, .2s ease-out.
    final Animation<double> a = CurvedAnimation(
      parent: _c,
      curve: Curves.easeOut,
    );
    return FadeTransition(
      opacity: a,
      child: AnimatedBuilder(
        animation: a,
        builder: (BuildContext context, Widget? child) => Transform.translate(
          offset: Offset(0, 8 * (1 - a.value)),
          child: child,
        ),
        child: GestureDetector(
          onTap: widget.onDismiss,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: const BorderRadius.all(Radius.circular(9)),
              border: Border.all(color: c.fg.o(.4)),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: t.shadow.o(.16),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Flexible(
                  child: Text(
                    widget.msg.message,
                    style: context.type.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: c.fg,
                    ),
                  ),
                ),
                if (widget.msg.onAction != null) ...<Widget>[
                  const SizedBox(width: 12),
                  // Its own tap target, ahead of the bubble's dismiss: pressing
                  // "Stop waiting" must stop the waiting, not just hide the
                  // sentence that said it was happening.
                  GestureDetector(
                    onTap: widget.msg.onAction,
                    child: Text(
                      widget.msg.actionLabel,
                      style: context.type.button.copyWith(
                        color: c.fg,
                        decoration: TextDecoration.underline,
                        decorationColor: c.fg,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `.jobcard` - one card serves every background pipeline.
///
/// §7.7: any work that happens without a person watching gets one of these -
/// work with no visible state reads as work that is not happening.
class JobCard extends StatelessWidget {
  final String name;
  final JobState state;

  /// A mono ratio such as `9 / 24`.
  final String meta;
  final String detail;
  final int progress;
  final VoidCallback? onRetry;

  const JobCard({
    super.key,
    required this.name,
    required this.state,
    this.meta = '',
    this.detail = '',
    this.progress = 0,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: t.bgApp,
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (state == JobState.running) ...<Widget>[
                const Spinner(),
                const SizedBox(width: 9),
              ],
              Flexible(
                child: Text(
                  name,
                  style: context.type.body.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 9),
              Pill.state(state),
              const Spacer(),
              if (meta.isNotEmpty)
                Text(
                  meta,
                  style: context.type.monoSmall.copyWith(color: t.textMuted),
                ),
            ],
          ),
          if (state == JobState.running || progress > 0) ...<Widget>[
            const SizedBox(height: 9),
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(3)),
              child: LinearProgressIndicator(
                value: (progress / 100).clamp(0, 1),
                minHeight: 5,
                backgroundColor: t.bgMuted,
                valueColor: AlwaysStoppedAnimation<Color>(t.primary),
              ),
            ),
          ],
          if (detail.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(detail, style: context.type.tiny.copyWith(height: 1.45)),
          ],
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: 9),
            Align(alignment: Alignment.centerLeft, child: _RetryBtn(onRetry!)),
          ],
        ],
      ),
    );
  }
}

class _RetryBtn extends StatelessWidget {
  final VoidCallback onPressed;

  const _RetryBtn(this.onPressed);

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onPressed,
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
            'Retry',
            style: context.type.button.copyWith(fontSize: 11.5),
          ),
        ),
      ),
    );
  }
}

/// `.spin` - a 12px ring, .7s linear infinite. Used on in-flight pipeline jobs.
class Spinner extends StatefulWidget {
  final double size;

  const Spinner({super.key, this.size = 12});

  @override
  State<Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<Spinner> {
  // No AnimationController here on purpose.
  //
  // There used to be one, created with `..repeat()`, and nothing ever read it:
  // the indicator below drives itself and its colour is an
  // AlwaysStoppedAnimation. So the controller spun forever purely to be
  // disposed later - and in a widget test it outlived the tree, producing
  // "an animation is still running even after the widget tree was disposed"
  // against whatever test ran NEXT. One spinner failed fourteen unrelated
  // routes that way.

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        backgroundColor: t.primary.o(.25),
        valueColor: AlwaysStoppedAnimation<Color>(t.primary),
      ),
    );
  }
}
