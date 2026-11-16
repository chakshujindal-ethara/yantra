/// Real proctoring detection for the browser.
///
/// PORTED FROM THE ODOO PORTAL (`views/portal_templates.xml`, the inline
/// script around line 1140). That implementation carries fixes for real
/// incidents, and they are reproduced here deliberately - re-deriving them
/// would mean repeating the incidents:
///
///   * a hidden tab only counts while fullscreen, because in windowed mode a
///     taskbar peek or an OS notification fires `visibilitychange` without the
///     candidate ever leaving the exam;
///   * devtools width is normalised by `devicePixelRatio`, because a low-vision
///     candidate at 150% zoom tripped the raw-pixel threshold and was
///     auto-submitted for cheating;
///   * leaving fullscreen only counts once it has been ENTERED, or declining
///     the initial prompt would itself be a violation and auto-submit the exam
///     on load at cap 0;
///   * a camera that is refused BLOCKS rather than violating, but one that is
///     turned off after having been granted is a violation - the first is a
///     candidate who has not consented yet, the second is one who withdrew
///     mid-exam.
library;

import 'dart:async';
import 'dart:js_interop';
// For `JSObject.has`. `navigator.mediaDevices` is typed non-nullable by
// package:web, but the browser simply does not define it on an insecure
// origin - so the only way to tell "no camera API" from "camera refused" is
// to ask whether the property is there before touching it.
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

import 'proctor_stub.dart'
    show
        CameraState,
        FullscreenGate,
        FullscreenRefusals,
        ProctorRules,
        ProctorWatch,
        aiStatusSink;

export 'proctor_stub.dart'
    show
        CameraState,
        FullscreenGate,
        FullscreenRefusals,
        ProctorRules,
        ProctorWatch,
        aiStatusSink;

class _WebProctorWatch implements ProctorWatch {
  void Function(String reason)? _report;
  void Function()? _onCameraChanged;
  bool _running = false;

  // Held so every listener can be removed again. A watcher left attached after
  // the exam screen rebuilds would report each violation twice, and at cap 1
  // that ends the sitting.
  final List<
    ({String type, web.EventListener fn, web.EventTarget on, bool capture})
  >
  _listeners =
      <
        ({String type, web.EventListener fn, web.EventTarget on, bool capture})
      >[];
  Timer? _devtoolsTimer;

  // Fullscreen.
  bool _everEnteredFullscreen = false;
  bool _wantFullscreen = false;

  /// Whether this document may enter fullscreen at all.
  ///
  /// False in an iframe without `allow="fullscreen"`, and in a browser where
  /// the API is disabled. Read once at [start]: every gate below has to treat
  /// "cannot" differently from "has not yet", or an unsatisfiable requirement
  /// becomes an unclearable overlay and a permanently disarmed tab-switch
  /// check.
  bool _fullscreenUsable = false;

  /// How often the browser has refused in a row, and why it last said no.
  ///
  /// Both used to be thrown away - `onError` was an empty block - which is the
  /// whole reason this took a bug report to find. A refusal is now written to
  /// the console, counted, and once the run reaches [FullscreenRefusals.limit]
  /// the gate stops blocking. The clock does not stop for a browser that will
  /// not co-operate, so a candidate must never be held on a dimmed paper by a
  /// control that cannot work.
  final FullscreenRefusals _refusals = FullscreenRefusals();

  /// Whether the last exit from fullscreen was recorded as a violation.
  ///
  /// Read by the screen to pick the offer bar's words - see
  /// [ProctorWatch.fullscreenExitRecorded].
  bool _lastExitRecorded = false;

  /// One request in flight at a time.
  ///
  /// A single press raises TWO calls: the capture-phase DOM handler, which is
  /// the one with the browser's transient activation behind it, and the
  /// overlay's own button a beat later. The second arrives after the first has
  /// spent that activation, so it is refused even when the first is about to
  /// succeed - and counting that would spend a strike on a click that WORKED.
  bool _fullscreenAsking = false;

  /// The platform view id of the transparent DOM button, registered on first
  /// ask. Held so a rebuild does not mint a second view type for the same
  /// control - `registerViewFactory` throws on a repeated id.
  String? _fsButtonViewType;

  // Devtools: the zoom level at the moment the exam loaded. Comparing against
  // this rather than assuming 100% means a candidate who was already zoomed in
  // is not flagged the instant the check first runs.
  double _baseDpr = 1;
  bool _devtoolsReported = false;

  // Camera.
  bool _wantCamera = false;
  bool _everGrantedCamera = false;
  web.MediaStream? _stream;

  // AI proctoring (`web/proctor_ai.js`), loaded only when the rule is on.
  bool _wantAi = false;

  /// The S3 upload policy in its wire shape, handed to the bridge at start
  /// and on every change. Survives [stop]: see [setEvidencePolicy].
  Map<String, Object?>? _evidencePolicy;

  /// This watcher started the page-wide bridge, so its [stop] may stop it.
  /// Without the check, stopping any OTHER watcher (an exam screen disposed
  /// after the next one mounted) would stop this one's detection.
  bool _aiStarted = false;

  /// Confirms a window blur before counting it.
  ///
  /// `blur` fires for things that are not a screen switch - a browser dialog
  /// taking focus, a print sheet, the fullscreen transition itself - so the
  /// event only ARMS the check; `document.hasFocus()` a beat later is what
  /// decides. Cancelled by the matching `focus`, which is what a same-screen
  /// blip looks like.
  Timer? _blurTimer;

  /// Bounds how long the camera may sit in [CameraState.pending].
  Timer? _cameraWaitTimer;

  /// Which acquisition attempt is current, so a late answer to a prompt the
  /// watchdog already gave up on cannot install itself over a newer one.
  int _acquireSeq = 0;
  CameraState _cameraState = CameraState.idle;
  String _cameraMessage = '';
  String? _cameraViewType;

  /// Whether [_lockEscape] has a lock in force.
  bool _escapeLocked = false;

  /// Distinguishes one registered preview from the next.
  ///
  /// `registerViewFactory` throws on a repeated type id, and a candidate who
  /// refuses the camera and then retries mints a second, different stream. The
  /// factory closes over the stream it was registered with, so reusing an id
  /// would leave the preview pointing at a stream whose tracks are stopped.
  static int _viewSeq = 0;

  @override
  bool get isFullscreen => web.document.fullscreenElement != null;

  @override
  bool get escapeCaptured => _escapeLocked && isFullscreen;

  /// Take Escape away from the browser while the exam is fullscreen.
  ///
  /// WHY THIS EXISTS. Escape is how the browser leaves fullscreen, and that
  /// keypress is not cancelable - `preventDefault` on it does nothing. So a
  /// candidate who opened the zoom preview of a stimulus and pressed Escape to
  /// shut it got the preview closed AND the exam dropped out of fullscreen,
  /// which the proctor then recorded as a violation. One dismissal, one
  /// violation, for using the control exactly as intended.
  ///
  /// The Keyboard Lock API is the sanctioned way out: a fullscreen document
  /// may claim Escape, after which the keydown is delivered to the page and
  /// fullscreen is left alone (holding Escape still exits, which is the
  /// browser's own guaranteed escape hatch and must stay that way). The app
  /// then decides what Escape means - close the preview if one is open, else
  /// leave fullscreen deliberately.
  ///
  /// Chrome-only and secure-context-only, so [escapeCaptured] reports whether
  /// the claim actually took. Where it did not, nothing changes and the old
  /// behaviour stands rather than the app swallowing the only way out.
  void _lockEscape(bool want) {
    if (want == _escapeLocked) return;
    final JSObject nav = web.window.navigator as JSObject;
    if (!nav.has('keyboard')) return;
    final JSObject? kb = nav.getProperty('keyboard'.toJS);
    if (kb == null) return;
    try {
      if (want) {
        if (!kb.has('lock')) return;
        final JSAny? res = kb.callMethod<JSAny?>(
          'lock'.toJS,
          <JSString>['Escape'.toJS].toJS,
        );
        // `lock()` REJECTS ASYNCHRONOUSLY, so the try/catch below cannot see
        // it. Left unhandled, a refused lock would leave the flag set and the
        // app would swallow an Escape the browser still owns - the one key
        // that gets a candidate out of a chromeless window.
        if (res.isA<JSPromise<JSAny?>>()) {
          unawaited(
            (res! as JSPromise<JSAny?>).toDart.then<void>(
              (JSAny? _) {},
              onError: (Object _) => _escapeLocked = false,
            ),
          );
        }
      } else {
        if (!kb.has('unlock')) return;
        kb.callMethod<JSAny?>('unlock'.toJS);
      }
      _escapeLocked = want;
    } catch (_) {
      // A refused lock is a supported outcome, not a failure: the exam runs
      // exactly as it did before, with the browser owning Escape.
      _escapeLocked = false;
    }
  }

  /// The live inputs to the fullscreen decision, in one place.
  ///
  /// The decision itself lives in [FullscreenGate] so it can be tested off the
  /// browser; everything here is a field read plus one DOM property.
  FullscreenGate get _gate => FullscreenGate(
    running: _running,
    wantFullscreen: _wantFullscreen,
    usable: _fullscreenUsable,
    wantCamera: _wantCamera,
    camera: _cameraState,
    everEntered: _everEnteredFullscreen,
    isFullscreen: isFullscreen,
    refused: _refusals.refused,
  );

  @override
  bool get fullscreenRefused => _refusals.refused;

  @override
  bool get fullscreenExitRecorded => _lastExitRecorded;

  /// True only BEFORE the first entry. Blocking on every later exit made
  /// Escape a loop: the overlay's one action re-entered fullscreen, and Escape
  /// brought it back, with no way to keep sitting the exam windowed.
  ///
  /// `!isFullscreen` IS LOAD-BEARING, and its absence is what put this gate
  /// back over a running exam. `_everEnteredFullscreen` is a latch meaning
  /// "this watcher instance saw an entry", not "the document is fullscreen",
  /// and the two come apart in three ordinary ways:
  ///
  ///  * `stop()` clears the latch and calls `exitFullscreen()`, so leaving the
  ///    runner and coming back starts a virgin watcher mid-sitting;
  ///  * `start()` samples `document.fullscreenElement` one frame after Begin
  ///    requested it, while the browser transition is still in flight, so the
  ///    latch is missed;
  ///  * `requestFullscreen()` on a document that is ALREADY the fullscreen
  ///    element resolves without firing `fullscreenchange`, so the overlay's
  ///    own button could not repair the latch either - the gate became a wall
  ///    with the exam visible and dimmed behind it and the clock running.
  ///
  /// Asking the browser closes all three at once, and it makes this agree with
  /// [shouldOfferReturnToFullscreen], which has always ended in `!isFullscreen`.
  @override
  bool get needsFullscreenPrompt => _gate.needsPrompt;

  /// Also the home for a browser that REFUSED, not only for one that was left.
  ///
  /// `needsFullscreenPrompt` blocks, and a block whose single action cannot
  /// succeed is a trap. Once the refusals are in, the requirement moves here:
  /// non-blocking, still offering the way back, with the paper readable and
  /// answerable behind it.
  @override
  bool get shouldOfferReturnToFullscreen => _gate.shouldOffer;

  /// When either half of "leave fullscreen and hide the tab" last fired.
  ///
  /// Alt-tab out of a fullscreen exam is ONE action that raises TWO events,
  /// and they carry different reason strings - so the server's dedup, which
  /// folds only a repeat of the same reason, cannot fold them. Counting both
  /// ends a sitting configured to allow one warning on the candidate's first
  /// slip. Whichever arrives first counts; the other is folded into it.
  int _lastExitMoveMs = 0;

  /// Folds a screenshot shortcut heard on both keydown and keyup into one.

  @override
  CameraState get cameraState => _cameraState;

  @override
  String get cameraMessage => _cameraMessage;

  @override
  String? get cameraViewType => _cameraViewType;

  void _on(web.EventTarget target, String type, void Function(web.Event) fn) {
    final web.EventListener listener = fn.toJS;
    target.addEventListener(type, listener);
    _listeners.add((type: type, fn: listener, on: target, capture: false));
  }

  /// As [_on], but in the CAPTURE phase, so the handler runs before Flutter's
  /// gesture pipeline gets the event. Removal has to pass the same flag or the
  /// listener outlives the sitting.
  void _onCapture(
    web.EventTarget target,
    String type,
    void Function(web.Event) fn,
  ) {
    final web.EventListener listener = fn.toJS;
    target.addEventListener(type, listener, true.toJS);
    _listeners.add((type: type, fn: listener, on: target, capture: true));
  }

  void _setCamera(CameraState state, String message) {
    if (_cameraState == state && _cameraMessage == message) return;
    _cameraState = state;
    _cameraMessage = message;
    _onCameraChanged?.call();
  }

  @override
  void start({
    required ProctorRules rules,
    required void Function(String reason) onViolation,
    void Function()? onCameraChanged,
  }) {
    // Idempotent: the exam screen rebuilds on every answer, and re-attaching
    // would multiply every violation.
    if (_running) return;
    _running = true;
    _report = onViolation;
    _onCameraChanged = onCameraChanged;
    _baseDpr = web.window.devicePixelRatio;
    _wantFullscreen = rules.fullscreen;
    _fullscreenUsable = web.document.fullscreenEnabled;

    // A sitting resumed from a reload can ALREADY be fullscreen, and the latch
    // is only otherwise set by the change event - which has long since fired.
    // Without this, leaving fullscreen on a resumed sitting was not a
    // violation and the tab-switch check stayed disarmed.
    if (isFullscreen) _everEnteredFullscreen = true;

    if (rules.rightClick) {
      _on(web.document, 'contextmenu', (web.Event e) {
        e.preventDefault();
        _fire('Right-click attempted');
      });
    }

    if (rules.copyPaste) {
      for (final String type in <String>['copy', 'cut', 'paste']) {
        _on(web.document, type, (web.Event e) {
          e.preventDefault();
          _fire('Clipboard action: $type');
        });
      }
    }

    if (rules.tabSwitch) {
      _on(web.document, 'visibilitychange', (web.Event _) {
        // Only a fullscreen exam can be genuinely hidden by alt-tab. Windowed,
        // this fires for a taskbar hover or a notification and produced false
        // "Tab switched" violations. When the fullscreen rule is off there is
        // no better signal, so fall back to the raw check.
        //
        // Gated on having ENTERED fullscreen rather than on being in it right
        // now: a candidate who alt-tabs away leaves fullscreen and hides the
        // tab in one motion, and browsers deliver those two events in an order
        // that is not guaranteed. Checking `isFullscreen` here meant the
        // fullscreen-exit landed first and the tab switch was then read as
        // "not fullscreen, ignore" - the exact move the rule exists to catch.
        // `_fullscreenUsable` guards the guard: where fullscreen cannot be
        // entered at all, gating on it would disarm this rule permanently, so
        // fall back to the raw hidden check exactly as the rule-off case does.
        if (rules.fullscreen && _fullscreenUsable && !_everEnteredFullscreen) {
          return;
        }
        if (!web.document.hidden) return;
        final int now = DateTime.now().millisecondsSinceEpoch;
        // Debounced: one switch can fire visibilitychange more than once, and
        // a fullscreen exit in the same motion has already counted.
        if (now - _lastExitMoveMs <= 1500) return;
        _lastExitMoveMs = now;
        _fire('Tab switched / window hidden');
      });

      // A SECOND SCREEN DEFEATS `visibilitychange` ENTIRELY.
      //
      // `document.hidden` means "this tab is not the one being rendered" - a
      // background tab, a minimised window. A candidate on a two-monitor desk
      // who clicks a window on the OTHER monitor leaves the exam tab fully
      // visible, so `hidden` stays false and nothing fired. The same is true
      // of alt-tab to a window that does not cover the exam, and of clicking
      // a phone-mirroring or screen-share panel beside it.
      //
      // Focus is the signal that survives all of those: the exam window stops
      // being the one receiving keystrokes the moment attention moves, whether
      // or not it is still on screen. Confirmed after a beat rather than on
      // the raw event - see [_blurTimer] - and folded into the same
      // `_lastExitMoveMs` window as the other two halves of an alt-tab, which
      // is one action that can raise all three.
      _on(web.window, 'blur', (web.Event _) {
        _blurTimer?.cancel();
        _blurTimer = Timer(const Duration(milliseconds: 400), () {
          _blurTimer = null;
          if (!_running || web.document.hasFocus()) return;
          // THE CAMERA PROMPT IS NOT A SCREEN SWITCH.
          //
          // `requestCamera` runs with the watcher already armed, and Chrome's
          // permission bubble takes keyboard focus - so `hasFocus()` is false
          // for as long as the candidate takes to find the Allow button, which
          // is always longer than the 400ms above. Every camera-rule sitting
          // would have opened with a violation against a candidate who did
          // exactly what the overlay asked. Nothing is lost by waiting: the
          // prompt resolves either way, and a real switch after it still fires.
          if (_cameraState == CameraState.pending) return;
          final int now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastExitMoveMs <= 1500) return;
          _lastExitMoveMs = now;
          _fire('Switched to another window or screen');
        });
      });
      _on(web.window, 'focus', (web.Event _) {
        _blurTimer?.cancel();
        _blurTimer = null;
      });
    }

    if (rules.devtools) {
      _devtoolsTimer = Timer.periodic(const Duration(seconds: 2), (Timer _) {
        if (_devtoolsReported) return;
        // innerWidth is in CSS pixels and SHRINKS as the candidate zooms in,
        // while outerWidth does not - so the raw delta grows with zoom.
        // devicePixelRatio moves with zoom, so scaling by it cancels that out.
        final double zoom = web.window.devicePixelRatio / _baseDpr;
        final double w = web.window.outerWidth - web.window.innerWidth * zoom;
        final double h = web.window.outerHeight - web.window.innerHeight * zoom;
        // 300, not 200: a docked panel is at least 250px, and guessing wrong
        // here ENDS someone's exam.
        if (w > 300 || h > 300) {
          _devtoolsReported = true;
          _fire('Developer tools detected');
        }
      });
    }

    if (rules.fullscreen) {
      // WHY NOT JUST THE BUTTON: a `requestFullscreen()` issued from Flutter's
      // own gesture pipeline is one the browser is free to refuse, and the
      // refusal is a rejected promise the candidate cannot see - so they are
      // left pressing a control that does nothing. Asking from a DOM listener
      // on the very same event is the request with the browser's own
      // activation behind it. Capture phase, so this runs before Flutter
      // consumes the event.
      //
      // THREE EVENTS, NOT ONE. `pointerdown` alone gave the ask a single
      // chance per gesture. These three are each activation-triggering in
      // their own right and arrive at different points of the same
      // interaction, so a window one misses is still open to the next - and a
      // candidate who reaches the gate by keyboard raises no pointer event at
      // all, which left them with a wall and no way through it. The portal's
      // own handler listens for pointer AND key for the same reason.
      for (final String type in <String>['pointerdown', 'click', 'keydown']) {
        _onCapture(web.document, type, _autoEnterFullscreen);
      }
      _on(web.document, 'fullscreenchange', (web.Event _) {
        _lockEscape(isFullscreen);
        if (isFullscreen) {
          // The screen watches this to drop its "return to fullscreen"
          // prompt the moment the candidate complies.
          _onFullscreenEntered();
          return;
        }
        _lastExitRecorded = false;
        // Declining the initial prompt is not a violation - only LEAVING
        // fullscreen after having been in it.
        //
        // AND THE CAMERA PROMPT IS NOT A LEAVING. A browser drops the tab out
        // of fullscreen in order to put a permission bubble on screen, and
        // this watcher raises the getUserMedia prompt itself from `start()`.
        // So a sitting that got into fullscreen and then met the camera prompt
        // recorded "Exited fullscreen" against a candidate who had done
        // exactly what was asked, on the first frame of the exam - and at a
        // violation cap of 1 that ends the paper before the first question is
        // read. The `blur` watchdog above carries the identical guard for the
        // identical cause; this one was missing it.
        if (_everEnteredFullscreen && _cameraState != CameraState.pending) {
          // Recorded one way or the other: either the report below fires, or
          // the other half of the same alt-tab already did inside the dedup
          // window. Both put a real violation on the record, so the offer
          // bar's "that has been recorded" is true either way.
          _lastExitRecorded = true;
          final int now = DateTime.now().millisecondsSinceEpoch;
          // The other half of the alt-tab pair may have counted already.
          if (now - _lastExitMoveMs > 1500) {
            _lastExitMoveMs = now;
            _fire('Exited fullscreen');
          }
        }
        // Re-raises the "enter fullscreen" prompt: the rule is still on, and
        // a candidate left windowed has the tab-switch check running against
        // a signal that no longer means what it means in fullscreen.
        _onCameraChanged?.call();
      });
    }

    if (rules.webcam) {
      _wantCamera = true;
      _wantAi = rules.aiProctor;
      // DEFERRED OUT OF THE FRAME. `start()` is called from the exam screen's
      // build, and requesting synchronously runs `_setCamera` - and therefore
      // the screen's `setState` - while that build is still on the stack,
      // which is "setState() called during build". A microtask drains after
      // the pipeline returns, so the notification lands on a clean frame.
      scheduleMicrotask(requestCamera);
    }
  }

  void _fire(String reason) {
    if (!_running) return;
    _report?.call(reason);
  }

  /// Enter fullscreen off a REAL browser event, which is where the activation
  /// is. Attached in the capture phase for `pointerdown`, `click` and
  /// `keydown`, so it runs before Flutter consumes the event.
  ///
  /// THREE EVENTS, NOT ONE. `pointerdown` alone gave the ask a single chance
  /// per gesture. Each of these is activation-triggering in its own right and
  /// arrives at a different point of the same interaction, so a window one
  /// misses is still open to the next - and a candidate who reaches the gate by
  /// keyboard raises no pointer event at all, which left them with a wall and
  /// no way through.
  void _autoEnterFullscreen(web.Event e) {
    // Cheap checks first: this runs on EVERY keystroke of every answer for the
    // whole sitting, and only past these does the DOM get asked anything.
    if (!_running || !_wantFullscreen || !_fullscreenUsable) return;
    // Never while a camera prompt is unresolved - see
    // [FullscreenGate.cameraReady].
    if (!_gate.cameraReady) return;

    // THE GATE: a blocking overlay is up and there is nothing else on screen to
    // interact with, so any event here means "get me in", whatever raised it.
    if (needsFullscreenPrompt) {
      requestFullscreen();
      return;
    }

    // THE OFFER BAR: the paper is visible and being answered, so pointer only.
    // On `keydown` this would take the window fullscreen under a candidate
    // mid-sentence, once per character - not a fix, a second surprise.
    if (e.type == 'pointerdown' && shouldOfferReturnToFullscreen) {
      requestFullscreen();
    }
  }

  @override
  void requestFullscreen() {
    // Nothing to ask for, and asking anyway would collect refusals from every
    // click of the offer bar in an iframe deployment and open the escape hatch
    // for a browser that was never going to be able to say yes.
    if (!_fullscreenUsable) return;
    // ALREADY THERE. `requestFullscreen()` on a document that IS the fullscreen
    // element resolves WITHOUT firing `fullscreenchange`, which is why the
    // latch was put on the promise in the first place. Do that repair here
    // rather than raising a second request whose refusal would then be counted
    // against the candidate.
    if (isFullscreen) {
      _onFullscreenEntered();
      return;
    }
    // One at a time - see [_fullscreenAsking].
    if (_fullscreenAsking) return;
    _fullscreenAsking = true;
    // Browsers only honour this inside a user gesture, so the caller must be a
    // real event handler. Wrapped because a refusal can throw rather than
    // returning a rejected promise.
    try {
      final JSPromise<JSAny?>? entered = web.document.documentElement
          ?.requestFullscreen();
      if (entered == null) {
        _fullscreenAsking = false;
        return;
      }
      entered.toDart.then<void>(
        (JSAny? _) {
          _fullscreenAsking = false;
          if (!_running) return;
          _onFullscreenEntered();
        },
        onError: (Object error) {
          _fullscreenAsking = false;
          if (!_running) return;
          _onFullscreenRefused(error.toString());
        },
      );
    } catch (e) {
      _fullscreenAsking = false;
      // A browser that refuses fullscreen must not break the exam. Older
      // engines throw here instead of rejecting; same outcome, same handling.
      if (_running) _onFullscreenRefused(e.toString());
    }
  }

  /// One place that means "we are in", however we got there.
  void _onFullscreenEntered() {
    _everEnteredFullscreen = true;
    _lastExitRecorded = false;
    _refusals.entered();
    // Repaint: this is what drops the overlay.
    _onCameraChanged?.call();
  }

  /// THE BROWSER SAID NO. COUNT IT, KEEP IT, AND SAY SO.
  ///
  /// This arm used to be `onError: (Object _) {}`, which made a refusal
  /// invisible in both directions at once: the candidate saw a button that did
  /// nothing, and a developer reading the console saw nothing at all. The
  /// surface it leaves behind is the strictest in this app - full viewport, one
  /// action, no dismissal, no Escape - so an unobservable failure there is a
  /// candidate walled in with the clock running.
  ///
  /// After [FullscreenRefusals.limit] in a row the requirement is downgraded:
  /// `needsFullscreenPrompt` goes false and `shouldOfferReturnToFullscreen`
  /// goes true, so the wall becomes a bar and the paper stays answerable. A
  /// requirement this browser will not satisfy must not cost somebody an exam.
  void _onFullscreenRefused(String error) {
    _refusals.refuse(error);
    web.console.warn(
      'proctor: fullscreen refused '
              '(${_refusals.consecutive}/${FullscreenRefusals.limit}): $error'
          .toJS,
    );
    // Repaint: this is what turns the wall into the offer bar.
    _onCameraChanged?.call();
  }

  /// See [ProctorWatch.fullscreenButtonView].
  @override
  String? fullscreenButtonView() {
    final String? existing = _fsButtonViewType;
    if (existing != null) return existing;
    final String type = 'etp-proctor-fs-btn-${_viewSeq++}';
    ui_web.platformViewRegistry.registerViewFactory(type, (int _) {
      final web.HTMLButtonElement el = web.HTMLButtonElement()
        ..type = 'button'
        // Invisible, not absent: the Flutter `Btn` underneath is what the
        // candidate sees, and two visible buttons would be two controls.
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.padding = '0'
        ..style.border = '0'
        ..style.background = 'transparent'
        // Matches `Radii.buttonLg`, so the hover wash below lands on the shape
        // the candidate can actually see rather than a rectangle around it.
        ..style.borderRadius = '9px'
        ..style.cursor = 'pointer';
      el.setAttribute('aria-label', 'Enter fullscreen');
      // The Flutter button underneath can no longer light up on hover - this
      // element is over it, so Flutter never sees the pointer - and a control
      // with no hover response is exactly what a dead one looks like. A neutral
      // grey wash reads on both the light and the dark theme without importing
      // a single token into this file.
      el.addEventListener(
        'mouseenter',
        ((web.Event _) => el.style.background = 'rgba(127, 127, 127, .16)')
            .toJS,
      );
      el.addEventListener(
        'mouseleave',
        ((web.Event _) => el.style.background = 'transparent').toJS,
      );
      el.addEventListener(
        'click',
        ((web.Event _) {
          // Inside the browser's own dispatch, so the activation for this very
          // click is still in force - the whole point of this element.
          requestFullscreen();
        }).toJS,
      );
      return el;
    });
    _fsButtonViewType = type;
    return type;
  }

  @override
  void exitFullscreen() {
    if (!isFullscreen) return;
    try {
      web.document.exitFullscreen();
    } catch (_) {
      // Nothing to do: the candidate can still leave with Escape.
    }
  }

  @override
  void requestCamera() {
    if (!_running || !_wantCamera) return;
    if (_cameraState == CameraState.pending) return;
    if (_stream != null) return;

    // No camera API at all - an insecure origin (plain http on anything but
    // localhost) hides `mediaDevices` entirely, and so does a browser without
    // one. Say so rather than sitting on a prompt that will never appear.
    final JSObject nav = web.window.navigator as JSObject;
    if (!nav.has('mediaDevices')) {
      _setCamera(
        CameraState.unavailable,
        'This exam requires a camera, but this browser exposes no camera '
        'access. Open the exam over https, or use a device with a camera.',
      );
      return;
    }

    _setCamera(CameraState.pending, 'Waiting for camera permission.');

    // PENDING MUST NOT BE FOREVER.
    //
    // `getUserMedia` has no timeout, and it does not always reject: a camera
    // held by another application behind a wedged driver, a virtual-camera
    // filter that hangs enumeration, or a prompt deferred in a backgrounded
    // tab all leave the promise unsettled with no prompt ever shown. Only
    // `off` and `unavailable` raise the blocking overlay, and `requestCamera`
    // returns early while pending - so the sitting would run to the end with
    // the camera rule silently unenforced and no way for the candidate to
    // retry. Falling into `off` is both honest and recoverable: the overlay
    // appears, and its button can genuinely re-request.
    final int gen = ++_acquireSeq;
    _cameraWaitTimer?.cancel();
    _cameraWaitTimer = Timer(const Duration(seconds: 20), () {
      if (!_running || _cameraState != CameraState.pending) return;
      _setCamera(
        CameraState.off,
        'Camera access was not granted. Allow the camera to continue the exam.',
      );
    });
    unawaited(_acquire(gen));
  }

  /// [gen] is the acquisition this call belongs to.
  ///
  /// After the watchdog above gives up, the original prompt can still be
  /// answered - so a late grant must not install itself over a newer attempt,
  /// and must release the device it just opened rather than leaving a second
  /// stream and a lit capture light behind.
  Future<void> _acquire(int gen) async {
    final web.MediaStream stream;
    try {
      stream = await web.window.navigator.mediaDevices
          .getUserMedia(web.MediaStreamConstraints(video: true.toJS))
          .toDart;
    } catch (_) {
      if (gen == _acquireSeq) _cameraWaitTimer?.cancel();
      if (!_running || gen != _acquireSeq) return;
      // Denied or unavailable. A FIRST denial is only a block - the candidate
      // has not consented yet and blocking is what asks them to. A loss after
      // a grant already recorded its violation in _onTrackEnded, so this arm
      // must not record a second one for the same event.
      _setCamera(
        CameraState.off,
        _everGrantedCamera
            ? 'Your camera was turned off. Re-enable it to continue the exam.'
            : 'Camera access is required to continue. Please allow the camera.',
      );
      return;
    }

    if (gen == _acquireSeq) _cameraWaitTimer?.cancel();
    if (!_running || gen != _acquireSeq) {
      // Stopped while the prompt was up, or superseded by a newer request.
      // Nothing will ever show this stream, so let go of the device rather
      // than leaving the capture light on.
      _stopStream(stream);
      return;
    }

    _everGrantedCamera = true;
    _stream = stream;
    for (final web.MediaStreamTrack track in stream.getVideoTracks().toDart) {
      track.addEventListener('ended', ((web.Event _) => _onTrackEnded()).toJS);
    }
    _cameraViewType = _registerPreview(stream);
    _setCamera(
      CameraState.on,
      'Camera on. Your session is monitored for exam integrity.',
    );
  }

  /// The camera went away mid-exam: record it and block until it is back.
  void _onTrackEnded() {
    if (!_running) return;
    _releaseStream();
    _fire('Webcam turned off / lost');
    _setCamera(
      CameraState.off,
      'Your camera was turned off. Re-enable it to continue the exam.',
    );
  }

  /// Register a `<video>` bound to [stream] and return its platform view id.
  ///
  /// Muted and `playsInline` deliberately: an unmuted autoplaying element is
  /// blocked outright by every browser's autoplay policy, and without
  /// `playsInline` iOS takes the preview fullscreen over the exam.
  String _registerPreview(web.MediaStream stream) {
    final String type = 'etp-proctor-cam-${_viewSeq++}';
    ui_web.platformViewRegistry.registerViewFactory(type, (int _) {
      final web.HTMLVideoElement el = web.HTMLVideoElement()
        ..autoplay = true
        ..muted = true
        ..srcObject = stream
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover'
        ..style.background = '#000'
        ..style.borderRadius = '8px'
        // Mirrored, because a candidate checking their own framing expects a
        // mirror. Every video-call client does the same.
        ..style.transform = 'scaleX(-1)';
      el.setAttribute('playsinline', 'true');
      // The preview is draggable by the Flutter plate around it, which only
      // hears pointers the browser lets through. `flt-platform-view` (the
      // element's parent, mounted just after this returns) takes them
      // otherwise, so switch it off once it exists.
      void passPointersThrough(web.Element e) => Timer.run(
        () =>
            (e.parentElement as web.HTMLElement?)?.style.pointerEvents = 'none',
      );
      if (!_wantAi) {
        passPointersThrough(el);
        return el;
      }
      // AI proctoring lays its face-box canvas over the video, so the view
      // is a wrapper the bridge can add that canvas to.
      final web.HTMLDivElement wrap = web.HTMLDivElement()
        ..style.position = 'relative'
        ..style.width = '100%'
        ..style.height = '100%';
      wrap.appendChild(el);
      passPointersThrough(wrap);
      unawaited(_startAi(el));
      return wrap;
    });
    return type;
  }

  /// Load `proctor_ai.js` (first time only) and point it at [video].
  ///
  /// Never throws into the exam: a browser that cannot run the detector (no
  /// WebAssembly, a blocked asset) sits the exam with the other rules intact,
  /// and [aiStatusSink] hears `failed`.
  Future<void> _startAi(web.HTMLVideoElement video) async {
    try {
      final JSObject? ai = await _importAi();
      if (!_running || !_wantAi) return;
      // A script that loaded but set no bridge is a failed start, not a
      // quiet one: the admin must not read it as "never reported".
      if (ai == null) throw StateError('proctor_ai.js set no __proctorAi');
      startAiBridge(
        ai,
        video,
        _evidencePolicy,
        _fire,
        onStatus: (String s) => aiStatusSink?.call(s),
      );
      _aiStarted = true;
    } catch (e) {
      web.console.warn('proctor: AI proctoring did not start: $e'.toJS);
      aiStatusSink?.call('failed');
    }
  }

  @override
  void setEvidencePolicy(Map<String, Object?> policy) {
    _evidencePolicy = policy;
    _aiBridge?.callMethod<JSAny?>('setPolicy'.toJS, evidencePolicyJs(policy));
  }

  void _stopStream(web.MediaStream stream) {
    for (final web.MediaStreamTrack track in stream.getTracks().toDart) {
      track.stop();
    }
  }

  void _releaseStream() {
    final web.MediaStream? held = _stream;
    _stream = null;
    _cameraViewType = null;
    // No stream, nothing to watch. A re-granted camera registers a new
    // preview, and that starts the bridge again.
    if (_aiStarted) {
      _aiStarted = false;
      _aiBridge?.callMethod<JSAny?>('stop'.toJS);
    }
    if (held != null) _stopStream(held);
  }

  @override
  void stop() {
    // `_running` drops FIRST, then the browser is handed back.
    //
    // An exam that put the browser INTO fullscreen has to take it back out
    // when the sitting ends, or the candidate is left on the completion screen
    // in a chromeless window - no tabs, no address bar, no obvious way out -
    // having just been told the exam is over. That exit raises a
    // `fullscreenchange` while the listener is still attached, and clearing
    // `_running` first is what stops it being recorded as the candidate
    // leaving: `_fire` checks `_running`, and nothing else would.
    //
    // The callbacks are dropped immediately after, so the handler's
    // `_onCameraChanged?.call()` cannot setState. That is belt AND braces:
    // `fullscreenchange` is dispatched from an animation-frame task, never
    // synchronously out of `exitFullscreen()`, so it could not land inside
    // this method in any case.
    _running = false;
    exitFullscreen();
    _report = null;
    _onCameraChanged = null;
    _devtoolsTimer?.cancel();
    _devtoolsTimer = null;
    _cameraWaitTimer?.cancel();
    _cameraWaitTimer = null;
    _blurTimer?.cancel();
    _blurTimer = null;
    // Escape belongs to the browser again the moment the exam is over.
    _lockEscape(false);
    // Invalidates any acquisition still in flight, so a grant that lands after
    // the sitting ended releases the device instead of installing itself.
    _acquireSeq++;
    for (final ({
          String type,
          web.EventListener fn,
          web.EventTarget on,
          bool capture,
        })
        l
        in _listeners) {
      // removeEventListener only matches a listener registered with the SAME
      // capture flag, so a capture-phase watcher left behind would keep firing
      // after the sitting ended.
      l.on.removeEventListener(l.type, l.fn, l.capture.toJS);
    }
    _listeners.clear();
    // The capture light stays on until every track is stopped, and a candidate
    // whose exam has ended is entitled to see it go out.
    _releaseStream();
    _wantCamera = false;
    _wantAi = false;
    _everGrantedCamera = false;
    _cameraState = CameraState.idle;
    _cameraMessage = '';
    // Latches are per-sitting, not per-instance: the screen keeps one watcher
    // for the whole exam, and a stop/start pair (submit, then a fresh sitting)
    // must not inherit the last one's fullscreen or devtools history.
    _everEnteredFullscreen = false;
    _wantFullscreen = false;
    _fullscreenUsable = false;
    _devtoolsReported = false;
    _lastExitMoveMs = 0;
    // Reset with the rest, or a fresh sitting in the same screen inherits the
    // last one's refusals and opens with the gate already given up on - the
    // fullscreen rule silently unenforced for a candidate whose browser was
    // perfectly willing. `_fullscreenAsking` too: a `stop()` while a request
    // was in flight would otherwise leave it stuck and block every later ask.
    // `_fsButtonViewType` deliberately survives - the factory closes over this
    // same watcher, and re-registering would only mint a second id for one
    // control.
    _refusals.entered();
    _lastExitRecorded = false;
    _fullscreenAsking = false;
  }
}

ProctorWatch createProctorWatch() => _WebProctorWatch();

JSObject? get _aiBridge =>
    (web.window as JSObject).getProperty<JSObject?>('__proctorAi'.toJS);

/// `window.__proctorAi`, importing `proctor_ai.js` the first time.
Future<JSObject?> _importAi() async {
  if (_aiBridge == null) {
    // Against `<base href>`, not the route, so a deep link resolves it.
    final String url = Uri.parse(
      web.document.baseURI,
    ).resolve('proctor_ai.js').toString();
    await importModule(url.toJS).toDart;
  }
  return _aiBridge;
}

/// Load the AI models before the exam starts (the instructions screen), so
/// detection is ready at Begin instead of a model download later. Never
/// throws: a failed preload only means the exam's own start loads them.
Future<void> preloadAi() async {
  _aiReleased = false;
  try {
    final JSObject? ai = await _importAi();
    // Left while `proctor_ai.js` was still importing: load nothing.
    if (ai == null || _aiReleased) return;
    await ai.callMethod<JSPromise<JSAny?>>('preload'.toJS).toDart;
  } catch (e) {
    web.console.warn('proctor: AI preload failed: $e'.toJS);
  }
}

/// Set by [releaseAi], cleared by the next [preloadAi]: a release that finds
/// no bridge yet (still importing) must stop the preload it raced.
bool _aiReleased = false;

/// Let go of the models [preloadAi] loaded (about 30 MB) when no run uses
/// them: the instructions page was left without starting. Nothing to do when
/// the bridge never loaded. Never throws.
void releaseAi() {
  _aiReleased = true;
  try {
    _aiBridge?.callMethod<JSAny?>('release'.toJS);
  } catch (e) {
    web.console.warn('proctor: AI release failed: $e'.toJS);
  }
}

/// Open the camera once and let it go, so the permission prompt is answered
/// before the exam (and before fullscreen). Null when the camera opened,
/// else the browser's reason, the DOMException name (`NotAllowedError`,
/// `NotFoundError`, `NotReadableError`, ...), or `NotSupportedError` where
/// the page has no camera API (plain http).
///
/// No timeout: the tracks are stopped whenever the prompt is answered, so a
/// late grant never leaves the camera light on.
Future<String?> probeCamera() {
  final JSObject nav = web.window.navigator as JSObject;
  if (!nav.has('mediaDevices')) {
    return Future<String?>.value('NotSupportedError');
  }
  final Completer<String?> done = Completer<String?>();
  // `then` in JS rather than `toDart`, so the rejection arrives as a JS value
  // whose `name` can be read.
  web.window.navigator.mediaDevices
      .getUserMedia(web.MediaStreamConstraints(video: true.toJS))
      .callMethod<JSAny?>(
        'then'.toJS,
        ((web.MediaStream stream) {
          for (final web.MediaStreamTrack track in stream.getTracks().toDart) {
            track.stop();
          }
          done.complete(null);
        }).toJS,
        ((JSAny? e) {
          final JSAny? name = e.isA<JSObject>()
              ? (e! as JSObject).getProperty<JSAny?>('name'.toJS)
              : null;
          done.complete(
            name.isA<JSString>() ? (name! as JSString).toDart : 'Error',
          );
        }).toJS,
      );
  return done.future;
}

/// [policy] as `proctor_ai.js` takes it: the wire shape, plus `landed` (the
/// screen's `Future<bool> Function(String key)`, `/evidence/landed`) as a JS
/// function returning a Promise. The bridge asks it after an upload whose S3
/// reply it could not read, instead of sending the snapshot again.
JSAny? evidencePolicyJs(Map<String, Object?>? policy) {
  if (policy == null) return null;
  final Object? landed = policy['landed'];
  final JSObject js =
      (Map<String, Object?>.of(policy)..remove('landed')).jsify()! as JSObject;
  if (landed is Future<bool> Function(String)) {
    js.setProperty(
      'landed'.toJS,
      ((JSString key) => landed(key.toDart).then((bool v) => v.toJS).toJS).toJS,
    );
  }
  return js;
}

/// `window.__proctorAi.start(video, policy, onEvent)`, with each trip's
/// `reason` handed to [onReason].
///
/// `callMethodVarArgs`, NOT `callMethod`: `callMethod` stops at the first null
/// argument (its own docs say so), and the policy IS null until `/begin`,
/// `/state` or `/answer` carries one, or for good where storage is not
/// configured. The
/// callback was silently dropped, so detection ran and every trip went
/// nowhere. Top-level so a browser test can drive it with a fake bridge.
///
/// A `rule: 'status'` event is how the AI stands (`running`, `failed`): its
/// `status` goes to [onStatus], checked FIRST,
/// so it can never be counted as a violation. The JS leaves its `reason`
/// empty so an older bridge (an app opened before a deploy, against the
/// no-cache `proctor_ai.js`) drops it rather than count it.
void startAiBridge(
  JSObject ai,
  JSObject video,
  Map<String, Object?>? policy,
  void Function(String reason) onReason, {
  void Function(String status)? onStatus,
}) {
  ai.callMethodVarArgs<JSAny?>('start'.toJS, <JSAny?>[
    video,
    evidencePolicyJs(policy),
    ((JSObject e) {
      final Object? rule = e.getProperty<JSAny?>('rule'.toJS).dartify();
      if (rule == 'status') {
        final Object? status = e.getProperty<JSAny?>('status'.toJS).dartify();
        if (status is String && status.isNotEmpty) onStatus?.call(status);
        return;
      }
      final Object? reason = e.getProperty<JSAny?>('reason'.toJS).dartify();
      if (reason is String && reason.isNotEmpty) onReason(reason);
    }).toJS,
  ]);
}
