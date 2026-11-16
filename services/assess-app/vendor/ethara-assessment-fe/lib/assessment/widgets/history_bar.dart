// Back and Forward, over the pages the user actually visited.
//
// One control over the navigator's history, not a per-screen way out: a
// breadcrumb answers "up", where the page sits, not "back", where the user
// came from. Always drawn and disabled at the ends rather than hidden - a
// control that comes and goes is one nobody learns is there.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../nav.dart';
import 'buttons.dart';

/// True where the platform's own history shortcut is Cmd+[ / Cmd+].
bool get _isApple =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

String get backShortcutLabel => _isApple ? 'Cmd+[' : 'Alt+Left';

String get forwardShortcutLabel => _isApple ? 'Cmd+]' : 'Alt+Right';

/// Binds the platform's history keys to [nav] for everything under [child].
///
/// APPLE GETS CMD+BRACKET, AND NOT ALT+ARROW, and that is the whole reason the
/// bindings are platform-split rather than one list. On macOS Option+Left is
/// "move one word left" inside a text field, a binding Flutter installs in
/// `DefaultTextEditingShortcuts` up at the app root. Anything registered inside
/// the app sits CLOSER to the focused widget than that does, so claiming
/// Alt+Left here would quietly shadow word-navigation everywhere in a product
/// whose operators spend their day typing question text and prompts. Cmd+[ is
/// both the macOS convention for Back and bound to nothing in a text field.
///
/// Windows and Linux have the opposite arrangement: word-navigation there is
/// Ctrl+Arrow, so Alt+Arrow is free and is what those platforms already use.
///
/// NOT `Shortcuts` OR `CallbackShortcuts`, and that is not a style choice.
/// Both dispatch along the FOCUS chain, from the focused node UP through its
/// ancestors - and a widget mounted inside the section is a DESCENDANT of the
/// route's focus scope, not an ancestor of it. On a page the user has only
/// scrolled, nothing inside the section holds focus, the event never reaches
/// the binding, and the shortcut silently does nothing. Registering with the
/// keyboard itself is what makes it work before the first click as well as
/// after it. `false` is returned for everything else, so every other key
/// carries on to the focused widget untouched.
///
/// What that reach costs is a handler that goes on firing under whatever is
/// open on top of the section, so `_onKey` opens with a guard against it.
class HistoryShortcuts extends StatefulWidget {
  const HistoryShortcuts({super.key, required this.nav, required this.child});

  final AssessmentNav nav;
  final Widget child;

  @override
  State<HistoryShortcuts> createState() => _HistoryShortcutsState();
}

class _HistoryShortcutsState extends State<HistoryShortcuts> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    // NOT WHILE SOMETHING IS OPEN OVER THE PAGE.
    //
    // Registering with the keyboard itself is what makes the shortcut work
    // before the first click (see the class docstring) - but it also means the
    // handler keeps firing when the section is no longer what the user is
    // looking at. Every dialog, sheet and confirm in the app is a pushed route
    // ABOVE this one, so Cmd+[ inside a "delete this generator?" dialog moved
    // the page underneath it and left the dialog floating over a screen it was
    // never about.
    //
    // `isCurrent` is false for any route with something on top of it, which
    // also stops a second, backgrounded section from acting on the same press.
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;

    // NOT INSIDE THE EXAM RUNNER, for the same reason the visible pair is not
    // drawn there - and this half was missed, which briefly made the shortcut
    // an escape hatch out of a live sitting.
    //
    // The boundary used to be enforced by the NAVIGATOR: entering an exam
    // cleared the trail, so `canGoBack` was false and this handler could not
    // move anything even though it ran. Keeping one entry across the boundary
    // fixed three real bugs but made `canGoBack` true again, and the arrows
    // being hidden is not a guard - this handler registers with
    // `HardwareKeyboard` and never consults them. A candidate mid-paper could
    // press Alt+Left and land on their own results with the clock still going.
    //
    // The runner's own Previous/Next are unaffected: they move through the
    // server, not through page history.
    if (widget.nav.current is Exam) return false;

    final HardwareKeyboard kb = HardwareKeyboard.instance;

    // An EXACT modifier match. Cmd+Shift+[ is "previous tab" in every browser
    // this runs in, and Ctrl+Alt+Left is a workspace switch on Linux desktops;
    // treating those as Back would take a key the user meant for something
    // else.
    if (_isApple) {
      if (!kb.isMetaPressed ||
          kb.isAltPressed ||
          kb.isControlPressed ||
          kb.isShiftPressed) {
        return false;
      }
      if (event.logicalKey == LogicalKeyboardKey.bracketLeft) {
        widget.nav.back();
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.bracketRight) {
        widget.nav.forward();
        return true;
      }
      return false;
    }

    if (!kb.isAltPressed ||
        kb.isMetaPressed ||
        kb.isControlPressed ||
        kb.isShiftPressed) {
      return false;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      widget.nav.back();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      widget.nav.forward();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class HistoryBar extends StatelessWidget {
  const HistoryBar({super.key, required this.nav});

  final AssessmentNav nav;

  /// Names the destination, not the direction ("Back to Question bank"), and
  /// says so at the ends - a disabled control with no reason reads as broken.
  String _tip(AssessmentRoute? to, {required bool isBack}) {
    final String key = isBack ? backShortcutLabel : forwardShortcutLabel;
    if (to == null) {
      return isBack ? 'Nothing to go back to' : 'Nothing to go forward to';
    }
    return '${isBack ? 'Back to' : 'Forward to'} ${routeLabel(to)}  $key';
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      IconBtn(
        Icons.arrow_back,
        tooltip: _tip(nav.previous, isBack: true),
        onPressed: nav.canGoBack ? nav.back : null,
      ),
      const SizedBox(width: 2),
      IconBtn(
        Icons.arrow_forward,
        tooltip: _tip(nav.next, isBack: false),
        onPressed: nav.canGoForward ? nav.forward : null,
      ),
    ],
  );
}
