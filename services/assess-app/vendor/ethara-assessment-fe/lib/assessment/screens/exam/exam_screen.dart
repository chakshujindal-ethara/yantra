// The exam runtime - HANDOVER §4.1 (routes 28-32), §4.3, §6.8, §6.10.
//
// Five routes resolve into this one screen, and the ORDER of resolution is
// what makes them overlap correctly:
//   1. `answers` first, so a locked attempt can still open its answer review -
//      and it resolves BEFORE the assessment lookup, because the review is the
//      one surface a candidate reaches and a candidate cannot load assessment
//      records at all.
//   2. then locked/submitted -> the completion screen.
//   3. then the assessment-state check -> the "closed" gate.
//   4. then `review`.
//   5. then "not started" -> instructions.
//   6. and only then the question page.
//
// The countdown touches two nodes and never rebuilds the surface, because a
// per-second rebuild would destroy the caret in a free-text answer.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
// For the global Escape handler: `HardwareKeyboard` sees the key without the
// exam having to own focus, which it does not while a preview is up.
// `SemanticsService.announce` and `Assertiveness` - the clock speaks its
// milestones, replacing the QWeb runner's `aria-live` time announcer.
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

// The web build gets real browser detection; every other platform gets the
// no-op stub. Same conditional-import shape as the file picker.
import '../../../services/proctor_stub.dart'
    if (dart.library.js_interop) '../../../services/proctor_web.dart';
import '../../../services/seb_stub.dart'
    if (dart.library.js_interop) '../../../services/seb_web.dart';
import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../domain/category_scores.dart';
import '../../domain/transcription.dart' show ClipAnswers, clipCategoryLabel;
import '../../state/app_store.dart';
import '../../widgets/buttons.dart';
import '../../widgets/category_card.dart';
import '../../widgets/controls.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import 'answer_layouts.dart';
import 'gate_screen.dart';
import '../../../yantra_launch.dart' show yantraReturnUrl;
import 'video_plate.dart' show MediaInert, VideoPlate, publicVideoEmbedRef;
import '../../theme.dart';
import '../../nav.dart';
import 'transcription_box.dart' show TranscriptionBox;

enum ExamSub { instructions, question, review, complete, answers }

class ExamScreen extends StatefulWidget {
  final AppStore store;
  final String token;
  final ExamSub sub;
  final int questionNumber;

  /// Set by the section only while the rail is hidden (a sitting), so the
  /// candidate keeps a theme toggle. Null elsewhere: the rail has it.
  final VoidCallback? onToggleTheme;
  final bool isDark;

  /// A stand-in watcher for tests. Null everywhere else: the VM stub never
  /// fires, so without this nothing can prove when the listeners stop.
  @visibleForTesting
  final ProctorWatch? proctor;

  /// [preloadAi], [releaseAi] and [probeCamera], swapped in tests.
  @visibleForTesting
  final Future<void> Function() warmAi;
  @visibleForTesting
  final void Function() releaseWarmAi;
  @visibleForTesting
  final Future<String?> Function() askCamera;

  const ExamScreen({
    super.key,
    required this.store,
    required this.token,
    this.sub = ExamSub.instructions,
    this.questionNumber = 1,
    this.onToggleTheme,
    this.isDark = true,
    this.proctor,
    this.warmAi = preloadAi,
    this.releaseWarmAi = releaseAi,
    this.askCamera = probeCamera,
  });

  @override
  State<ExamScreen> createState() => _ExamScreenState();
}

class _ExamScreenState extends State<ExamScreen> {
  /// When the clock runs out. Derived from the moment the exam begins rather
  /// than stored in the seed - time is the one thing that is not deterministic.
  DateTime? _deadline;

  /// A blocking overlay: `webcam` or `deadline`. These are the strictest
  /// surfaces in the system - no backdrop dismissal, no Escape, only the
  /// single named action.
  String? _block;

  /// The proctoring violation toast, on its own channel with a 4s life.
  String? _vToast;
  Timer? _vTimer;

  /// The simulator panel is collapsed by default.
  bool _rigMin = true;

  /// True while the sitting named by this token is still being fetched.
  ///
  /// Without this the screen renders the "link does not work" gate during the
  /// round trip, which is a lie shown to every candidate who follows an
  /// invitation - the link is fine, the answer has just not arrived yet.
  bool _resolving = false;

  /// Watches the real browser for proctoring violations.
  ///
  /// The simulator below fires the same `_violate` path by hand; this fires it
  /// from actual events. Both exist on purpose: the simulator is how an
  /// operator demonstrates the rules without cheating, and it is the only way
  /// to exercise this on a platform with no browser.
  late final ProctorWatch _proctor = widget.proctor ?? createProctorWatch();
  bool _proctorStarted = false;

  /// Top-left of the camera preview once the candidate has dragged it; null =
  /// the default bottom-left corner. Kept for the sitting, not persisted.
  Offset? _camPos;
  bool _camDragging = false;

  @override
  void didUpdateWidget(ExamScreen old) {
    super.didUpdateWidget(old);
    // A new sitting starts with the preview back in its corner.
    if (old.token != widget.token) _camPos = null;
  }

  /// The last `evidence_upload` handed to the watcher. Compared by identity:
  /// a new one only exists when a `/begin`, `/state` or `/answer` (its `next`)
  /// was parsed.
  EvidenceUploadPolicy? _pushedPolicy;

  /// The heading of whichever blocking overlay is up. See [_followOverlay].
  final FocusNode _overlayHeading = FocusNode(
    debugLabel: 'overlay heading',
    // Here, not on the `Focus`: a widget does not set it on a node it was
    // handed.
    skipTraversal: true,
  );

  /// Where the focus was when an overlay went up, to hand it back.
  FocusNode? _focusBeforeOverlay;
  bool _overlayUp = false;

  /// The page was hidden - tab closed or switched, reload, browser Back - so
  /// the pending autosaves go now rather than after their debounce. Flutter
  /// web reports the page's `visibilitychange` as `hidden`, which browsers
  /// fire before `pagehide` on every unload. Not a violation: the proctor
  /// watch judges a tab-hide on its own.
  late final AppLifecycleListener _pageHide;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _pageHide = AppLifecycleListener(
      onHide: () => unawaited(widget.store.flushAnswers()),
    );

    // Hydrate the sitting this token names whenever the RUNNER's own envelope
    // is missing - not merely when the attempt is missing.
    //
    // The old condition was `attemptByToken(token) == null`, which is true for
    // a candidate arriving from an invitation link and FALSE for one arriving
    // from their own list: `/api/v1/me/assessments` already loaded the attempt.
    // That row carries no assessment record and no question, because a
    // candidate cannot read `/api/v1/assessments` at all - it is a manager
    // route - so the fetch was skipped, `asmById` stayed null, and the build
    // below rendered "This link does not work" over a perfectly valid sitting.
    // Every candidate pressing "Start assessment" hit that; only the emailed
    // link worked.
    //
    // `/exam/<token>/state` is the one route that carries the assessment for a
    // candidate, and it is the navigation authority besides, so ask it unless
    // both the record and the envelope are already here.
    final Attempt? known = widget.store.attemptByToken(widget.token);
    if (known == null ||
        widget.store.asmById(known.assessmentId) == null ||
        widget.store.examView(widget.token) == null) {
      _resolving = true;
      widget.store.loadExamByToken(widget.token).whenComplete(() {
        if (mounted) setState(() => _resolving = false);
      });
    }

    final Attempt? ev = widget.store.attemptByToken(widget.token);
    final Assessment? asm = ev == null
        ? null
        : widget.store.asmById(ev.assessmentId);
    if (ev?.startedAt != null && asm != null && asm.durationMinutes > 0) {
      _deadline = ev!.startedAt!.add(Duration(minutes: asm.durationMinutes));
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _pageHide.dispose();
    _vTimer?.cancel();
    // Always, even if the exam never started: a watcher left attached outlives
    // the screen and reports violations against a sitting nobody is taking.
    _proctor.stop();
    // The models warmed on the instructions page, which only a bridge that
    // started released: "Not Now" kept about 30 MB resident.
    if (_warmed) widget.releaseWarmAi();
    // Only our own: a newer screen may already have set its sink. Tear-offs
    // of one method on one object are equal.
    if (aiStatusSink == _reportAiStatus) aiStatusSink = null;
    _overlayHeading.dispose();
    super.dispose();
  }

  /// Reports how AI proctoring stands (`running`, `failed`) for this
  /// sitting; [aiStatusSink] while this screen watches.
  void _reportAiStatus(String status) =>
      widget.store.reportAiStatus(widget.token, status);

  /// The AI models were asked to load on the instructions page (R9b).
  bool _warmed = false;

  /// Load the AI models while the candidate reads the instructions, so
  /// detection is ready at Begin. Once per screen; never in a preview.
  void _warmAi(Assessment asm) {
    if (_warmed || !asm.rules[ProctorRule.aiProctor]) return;
    if (widget.store.examView(widget.token)?.preview ?? false) return;
    _warmed = true;
    // Out of build: the load touches the DOM.
    scheduleMicrotask(() => unawaited(widget.warmAi()));
  }

  /// Escape, while the exam holds the key.
  ///
  /// THE BUG: pressing Escape to shut the stimulus zoom preview also dropped
  /// the exam out of fullscreen, because Escape is the browser's own way out
  /// and that keypress cannot be cancelled. The candidate closed a preview and
  /// was handed a fullscreen violation for it.
  ///
  /// The proctor now claims Escape via the Keyboard Lock API while fullscreen,
  /// so the key arrives here instead. Two meanings, in order:
  ///
  ///   * a preview is open - let it fall through, and Flutter's own barrier
  ///     dismissal closes it. Fullscreen is untouched, no violation.
  ///   * nothing is open - the candidate means to leave fullscreen, so do it
  ///     deliberately. That still counts, as leaving fullscreen always has.
  ///
  /// Returns false whenever the lock is not in force (Firefox, Safari, an
  /// insecure origin, or simply not fullscreen), so where the browser still
  /// owns Escape this handler stays entirely out of the way rather than
  /// swallowing the only way out of a chromeless window.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent ||
        e.logicalKey != LogicalKeyboardKey.escape ||
        !_proctor.escapeCaptured) {
      return false;
    }
    final NavigatorState? nav = Navigator.maybeOf(context);
    if (nav != null && nav.canPop()) return false;
    // Inside a transcription box Escape is the box's own key (keep the
    // English letters, or play / pause the clip, as in the Strix workbench).
    // Leaving fullscreen there would record a violation for using the tool.
    final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorWidgetOfExactType<TranscriptionBox>() != null) {
      return false;
    }
    _proctor.exitFullscreen();
    return true;
  }

  /// Attach the browser listeners once the exam is genuinely in progress.
  ///
  /// Called from `build` rather than `initState` because the rules arrive with
  /// the attempt, which on a deep link is still being fetched when the screen
  /// first mounts. Guarded by `_proctorStarted` so the rebuild on every
  /// keystroke does not re-attach - that would multiply each violation, and at
  /// cap 1 it would end the sitting on the first one.
  void _ensureProctoring(Assessment asm, Attempt ev) {
    // Another tab holds the sitting: watch nothing until this one takes it
    // back ("Continue Here" clears the flag and the next build re-attaches).
    if (widget.store.sessionReplaced.contains(widget.token)) {
      if (_proctorStarted) {
        _proctorStarted = false;
        _proctor.stop();
      }
      return;
    }
    if (_proctorStarted) {
      _pushEvidencePolicy(asm);
      return;
    }
    // Nothing to watch once the paper is in: a candidate reading their own
    // submitted answers is not sitting an exam.
    if (ev.isLocked || ev.state == AttemptState.submitted) return;
    final ProctorRules rules = ProctorRules(
      tabSwitch: asm.rules[ProctorRule.tabSwitch],
      copyPaste: asm.rules[ProctorRule.copyPaste],
      rightClick: asm.rules[ProctorRule.rightClick],
      devtools: asm.rules[ProctorRule.devtools],
      // MET INSIDE SAFE EXAM BROWSER, which is a full-screen kiosk already and
      // whose web view may have no Fullscreen API: asking would put up a wall
      // nobody can pass, and "leaving" it would fire a violation.
      fullscreen: asm.rules[ProctorRule.fullscreen] && !insideSeb(),
      webcam: asm.rules[ProctorRule.webcam],
      aiProctor: asm.rules[ProctorRule.aiProctor],
    );
    if (!rules.any) return;
    _proctorStarted = true;
    // Before start: the AI's first status can arrive as soon as it runs.
    if (rules.aiProctor) aiStatusSink = _reportAiStatus;
    _proctor.start(
      rules: rules,
      onViolation: (String reason) {
        if (mounted) _violate(reason);
      },
      // The camera and fullscreen states are read during build, so the screen
      // has to be told when they move. Without this the blocking overlay only
      // appeared on the next unrelated rebuild - which on a question the
      // candidate is not typing into is never.
      onCameraChanged: () {
        if (mounted) setState(() {});
      },
    );
    _pushEvidencePolicy(asm);
  }

  /// Hand the watcher the newest snapshot upload policy, once per payload.
  ///
  /// `/begin` usually lands AFTER `start()` (the attempt goes in-progress
  /// locally first), and a reload gets its policy from `/state`, so this runs
  /// on every build that reaches the watcher, not only at start. Never on a
  /// paper without AI proctoring: nothing there takes snapshots.
  void _pushEvidencePolicy(Assessment asm) {
    if (!asm.rules[ProctorRule.aiProctor]) return;
    final EvidenceUploadPolicy? p = widget.store
        .examView(widget.token)
        ?.evidenceUpload;
    if (p == null || identical(p, _pushedPolicy)) return;
    _pushedPolicy = p;
    _proctor.setEvidencePolicy(<String, Object?>{
      ...p.toJson(),
      'landed': _snapshotLanded,
    });
  }

  /// Whether S3 holds one of this sitting's snapshots (`/evidence/landed`).
  /// The bridge asks after an upload whose S3 reply it could not read (a
  /// bucket with no CORS rule for POST stores the file but withholds the
  /// answer). False when it cannot tell, so the snapshot is sent again.
  Future<bool> _snapshotLanded(String key) async =>
      await widget.store.api?.examEvidenceLanded(widget.token, key) ?? false;

  /// True when the camera is required and the browser is not giving us one.
  ///
  /// `_block == 'webcam'` is the SIMULATOR's way in and is kept so a demo can
  /// still raise this overlay on a machine whose camera is working.
  bool _cameraBlocked(Assessment asm, Attempt ev) {
    if (_block == 'webcam') return true;
    // The same two guards its siblings carry. Without them this leant on
    // `stop()` having zeroed `cameraState` - true today, but `cameraState` is
    // a bare field read with no `_running` check of its own, unlike
    // `needsFullscreenPrompt` / `shouldOfferReturnToFullscreen`.
    if (!_proctorStarted) return false;
    if (ev.isLocked || ev.state == AttemptState.submitted) return false;
    if (!asm.rules[ProctorRule.webcam]) return false;
    return _proctor.cameraState == CameraState.off ||
        _proctor.cameraState == CameraState.unavailable;
  }

  /// True when this sitting should be asked into fullscreen.
  ///
  /// The rule check itself lives on the watcher, which knows both whether
  /// fullscreen has been entered and whether this document is allowed to
  /// enter it at all. Only the exam's own lifecycle is decided here.
  bool _needsFullscreen(Attempt ev) {
    if (!_proctorStarted) return false;
    if (ev.isLocked || ev.state == AttemptState.submitted) return false;
    return _proctor.needsFullscreenPrompt;
  }

  /// True when the candidate left fullscreen and can be offered a way back.
  ///
  /// NOT a blocking overlay. The exit is already recorded as a violation, and
  /// blocking on it made Escape a loop with no way out - the only action put
  /// them back into fullscreen, and Escape brought the wall straight back.
  bool _offerFullscreen(Attempt ev) {
    if (!_proctorStarted) return false;
    if (ev.isLocked || ev.state == AttemptState.submitted) return false;
    return _proctor.shouldOfferReturnToFullscreen;
  }

  /// The single blocking surface this sitting is entitled to, or null.
  ///
  /// See the call site: these are mutually exclusive by construction, because
  /// two stacked full-viewport overlays leave the lower one unreadable and its
  /// only button unpressable.
  Widget? _blockingOverlay(Assessment asm, Attempt ev) {
    if (_block == 'deadline') {
      return BlockOverlay(
        headingFocus: _overlayHeading,
        tone: Tone.warn,
        icon: Icons.schedule,
        title: 'Time is up',
        // Nothing is submitted yet: the button below does that (Q12).
        body: widget.store.sessionReplaced.contains(widget.token)
            ? AppStore.timeUpElsewhereMessage
            : '${AppStore.timeUpMessage} Questions you did not reach are '
                  'recorded as unanswered.',
        action: 'See my submission',
        onAction: () async {
          // The deadline overlay, so the cause is the clock - never the
          // proctor. The completion screen prints one or the other.
          //
          // UP UNTIL THE SERVER TAKES IT (BR-D1): a refused submit leaves this
          // overlay and its button, not a paper the clock has closed.
          if (await _finish(auto: true, autoReason: 'expired') && mounted) {
            setState(() => _block = null);
          }
        },
      );
    }

    // ANOTHER TAB OR DEVICE HOLDS THE SITTING (409 `session_replaced`). Under
    // the deadline, which keeps its own ending; over the camera and
    // fullscreen gates, whose watcher is stopped while this is up.
    if (widget.store.sessionReplaced.contains(widget.token)) {
      return BlockOverlay(
        headingFocus: _overlayHeading,
        tone: Tone.warn,
        icon: Icons.devices_outlined,
        title: 'Exam open elsewhere',
        body:
            'This exam is open in another tab or device. You can continue '
            'there, or continue here instead.',
        action: 'Continue Here',
        onAction: () => widget.store.continueExamHere(widget.token),
      );
    }

    // AT THE VIOLATION LIMIT, BEFORE THE SERVER HAS ANSWERED (BR-D15). The
    // report that reached it is on its way or waiting for a connection, so
    // the paper is out of reach and nothing is said of a submission: there
    // has not been one. The server's answer ends the sitting (the completion
    // screen) or, when it counted less, takes this away.
    if (widget.store.violationLocked(widget.token)) {
      return BlockOverlay(
        headingFocus: _overlayHeading,
        tone: Tone.warn,
        icon: Icons.block,
        title: 'Violation limit reached',
        body: widget.store.violationReportsWaiting(widget.token)
            ? 'Your exam has reached its violation limit. Reconnecting to '
                  'finish it.'
            : 'Your exam has reached its violation limit. Finishing it now.',
        action: 'Try again',
        onAction: () => widget.store.retryViolationReports(widget.token),
      );
    }

    // THE CAMERA GATE, driven by the browser rather than by a bool.
    //
    // This used to render off `_block == 'webcam'`, which only the simulator
    // ever set, and its action closed the overlay and toasted "Camera on."
    // without asking the browser for anything. It read as working camera
    // enforcement and was theatre. The state below comes from the actual
    // getUserMedia result, and the action re-requests it.
    if (_cameraBlocked(asm, ev)) {
      final bool unavailable = _proctor.cameraState == CameraState.unavailable;
      // What the camera is used for. With AI proctoring it is more than
      // on-off, and saying "no video is stored" there would be untrue.
      // The snapshot sentence only when one will be kept (BR-D8): with no
      // upload policy from the server there is nowhere to keep it.
      final String snapshot =
          widget.store.examView(widget.token)?.evidenceUpload == null
          ? ''
          : ' Camera snapshots are saved at the start, every 2 minutes and '
                'when a rule is tripped.';
      final String watched = asm.rules[ProctorRule.aiProctor]
          ? 'Your camera is watched for a second person, a phone, or an '
                'empty seat.$snapshot'
          : 'Only the on-off state is monitored. No video is recorded or '
                'stored.';
      return BlockOverlay(
        headingFocus: _overlayHeading,
        tone: Tone.bad,
        icon: Icons.videocam_off_outlined,
        title: unavailable ? 'No camera available' : 'Your camera is off',
        body:
            '${_proctor.cameraMessage}\n\n$watched The clock keeps running '
            'while the camera is off.',
        action: unavailable ? 'Try again' : 'Enable camera',
        onAction: () {
          // From inside a click, which is the only place a browser will
          // re-prompt after a refusal.
          _proctor.requestCamera();
          // The simulator's way in has to be cleared by hand: the real state
          // never set it and so can never clear it.
          setState(() => _block = null);
        },
      );
    }

    // THE FULLSCREEN GATE.
    //
    // `_begin()` requests fullscreen, but it is reachable only from the
    // instructions page - so a candidate who reloads mid-exam, or who opens
    // their sitting from their own list, never passed through it. That left
    // the exam windowed, which disarmed BOTH the fullscreen-exit violation and
    // the tab-switch check that trusts it. Prompting here is what re-arms
    // them, on the way in and after every exit.
    if (_needsFullscreen(ev)) {
      return BlockOverlay(
        headingFocus: _overlayHeading,
        tone: Tone.warn,
        icon: Icons.fullscreen,
        title: 'This exam runs in fullscreen',
        body:
            'Press the button below, or click anywhere on this page, to '
            'switch to fullscreen. Leaving fullscreen after this point is '
            'recorded as a proctoring violation. The clock keeps running.',
        action: 'Enter fullscreen',
        // A REAL DOM BUTTON OVER THE PAINTED ONE. `onAction` below is a Flutter
        // tap callback, dispatched from the gesture arena after the browser's
        // user-activation window for that click has shut - so the request it
        // makes is refused, and the candidate presses the only control the exam
        // offers while nothing happens. See ProctorWatch.fullscreenButtonView.
        actionViewType: _proctor.fullscreenButtonView(),
        onAction: () {
          _proctor.requestFullscreen();
          setState(() {});
        },
      );
    }
    return null;
  }

  /// The clock ran out on this screen.
  ///
  /// STOP PROCTORING FIRST (MT3-01). The watcher kept running under the
  /// time-up overlay, so an Escape or a tab switch there still counted as a
  /// violation - at the cap it auto-submitted the paper as a proctoring
  /// ending instead of one on the clock. `_proctorStarted` stays true so
  /// `_ensureProctoring` does not re-attach it on the next build.
  ///
  /// THEN FLUSH THE AUTOSAVE (MT3-02): the last sentence typed in time goes
  /// now, and nothing typed behind the overlay is queued after it.
  void _timeUp() {
    _proctor.stop();
    widget.store.flushAnswers();
    setState(() => _block = 'deadline');
  }

  /// The keyboard follows a blocking overlay (L6): onto its heading when one
  /// goes up, and back where it was when it clears.
  ///
  /// ON THE HEADING, EXPLICITLY. With the paper `ExcludeFocus`ed the answer
  /// box lets go of the focus, and it fell to the page itself: a browser put
  /// it on the page container, not on the "Time is up" heading the fullscreen
  /// gate still got. A node the framework marks focused is the one the engine
  /// focuses, whatever else moved. Called from build, so both moves wait for
  /// the frame that mounts (or unmounts) the overlay.
  void _followOverlay(bool up) {
    if (up == _overlayUp) return;
    _overlayUp = up;
    if (up) {
      final FocusNode? had = FocusManager.instance.primaryFocus;
      // A scope is "nothing focused": the heading's own exit hands focus back
      // to the page's scope already.
      _focusBeforeOverlay = had is FocusScopeNode ? null : had;
    }
    final FocusNode? to = up ? _overlayHeading : _focusBeforeOverlay;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // `mounted`, not a null context: a node keeps its context after the
      // widget holding it is gone.
      if (mounted && (to?.context?.mounted ?? false) && to!.canRequestFocus) {
        to.requestFocus();
      }
    });
  }

  void _toast(String reason) {
    _vTimer?.cancel();
    // "Noted", not "recorded" (RT-2): the report has only just been queued
    // on this device, and may wait for a connection.
    setState(() => _vToast = 'Proctoring: $reason - this has been noted.');
    _vTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _vToast = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppStore s = widget.store;

    // The fetch is still in flight: a spinner, never a gate. Checked BEFORE
    // the attempt lookup, because a candidate opening this from their own list
    // ALREADY has the attempt while the assessment is still arriving - the old
    // placement guarded only the `ev == null` arm, so that candidate fell
    // straight through to the dead-end gate below.
    if (_resolving) {
      return const Center(child: CircularProgressIndicator());
    }

    final Attempt? ev = s.attemptByToken(widget.token);

    // The SERVER's outcome is the navigation authority, so a dead end names
    // the reason it actually gave (`login_required`, `wrong_candidate`,
    // `closed`) rather than reporting every one of them as a broken link. An
    // outcome the client cannot place, or none at all, still falls to
    // `invalid` - GateKind.parse's own default.
    final ExamView? view = s.examView(widget.token);
    // `invalid` WINS over anything cached. A draft paper's link answers it
    // (owner rule: a draft is never shown to a candidate), and an attempt or
    // assessment left over from `/me` or an earlier `/state` must not turn
    // that into a "closed" page - or an exam.
    //
    // `seb_required` wins the same way: a write refused outside Safe Exam
    // Browser re-reads `/state` mid-sitting, over an attempt already held.
    if (ev == null ||
        view?.outcome == GateKind.invalid.wire ||
        view?.outcome == GateKind.sebRequired.wire) {
      // Nothing is being sat behind a gate. Idempotent, like the Complete arm.
      if (_proctorStarted) {
        _proctorStarted = false;
        _proctor.stop();
      }
      // `onSignOut` because two of these outcomes - not signed in, signed in
      // as somebody else - are recoverable only by changing account, and the
      // gate's own buttons say so.
      return GateScreen(
        kind: GateKind.parse(view?.outcome),
        onSignOut: s.signOut,
        seb: view?.seb ?? const SebLinks(),
      );
    }

    final Assessment? asm = s.asmById(ev.assessmentId);

    // The answer review is resolved FIRST and without an assessment.
    //
    // A candidate never loads assessment records (`/api/v1/assessments` is a
    // manager route), so `asm` is null on the one surface a candidate opens.
    // Requiring it here declared every valid candidate link dead. The review
    // hydrates itself from `/exam/<token>/answers`, which is scoped to the
    // token and carries the name, the marks and the rows.
    if (widget.sub == ExamSub.answers) {
      return _AnswerReview(store: s, token: widget.token);
    }

    // Every screen below runs the exam itself, which needs the questions - and
    // those only exist on an assessment record. Reaching here now means the
    // state call did not carry one, so the server's own outcome is the honest
    // answer; a flat `invalid` reported a broken link for a token the server
    // had just resolved.
    if (asm == null) {
      return GateScreen(
        kind: GateKind.parse(view?.outcome),
        onSignOut: s.signOut,
      );
    }

    return ListenableBuilder(
      listenable: s,
      builder: (BuildContext context, _) {
        final Attempt cur = s.attemptByToken(widget.token) ?? ev;

        // 2. Locked or submitted wins over the assessment state.
        if (cur.isDone) {
          // TEAR THE WATCHER DOWN HERE, not only in dispose().
          //
          // The completion surface is a rebuild inside this same State - the
          // router builds a keyless ExamScreen at the same slot for every exam
          // stage, so Flutter reuses the element and dispose() never runs. The
          // listeners therefore survived onto the completion screen: a
          // right-click on one's own submitted paper reached `_violate`, which
          // had no isDone guard, re-entered `finishExam`, and re-POSTed the
          // whole submission. The camera survived too, capture light and all,
          // with no preview left on screen to explain why it was on.
          //
          // Safe during build: `stop()` clears `_running` and both callbacks
          // up front, and the one DOM call it makes (`exitFullscreen`) raises
          // `fullscreenchange` on a later animation-frame task, never
          // synchronously - so nothing here can setState mid-frame. dispose()
          // still calls it and is idempotent.
          if (_proctorStarted) {
            _proctorStarted = false;
            _proctor.stop();
          }
          return _Complete(store: s, ev: cur, asm: asm);
        }

        // 3. The token is valid but the assessment is not in progress. A
        // draft reads as an unknown link, never "closed" or "not open yet":
        // until launch there is nothing to show a candidate.
        if (asm.state != AsmState.inProgress) {
          return GateScreen(
            kind: asm.state.isDraft ? GateKind.invalid : GateKind.closed,
          );
        }

        // 4. The pre-submit review.
        if (widget.sub == ExamSub.review) {
          // THE REVIEW STAGE PASSES ITS OWN TOTAL, because `_buildChrome`
          // falls back to `asm.questions.length` and that is EMPTY on a live
          // exam - the payload has never carried a question list. Omitting it
          // here printed "0 of 0 questions answered" across the top bar, and
          // an empty progress bar, while the panel three lines below correctly
          // read "0 of 9 answered" off the same data. Two denominators for one
          // fact, on the last screen a candidate sees before submitting.
          //
          // Read from the SAME source `_Review` builds its rows from, so the
          // two cannot drift apart again; the live envelope's own total is the
          // fallback for the moment before the review rows land.
          final int reviewTotal =
              s.examReviewByToken[cur.token]?.length ??
              s.examView(widget.token)?.total ??
              asm.questions.length;
          return _buildChrome(
            context,
            asm: asm,
            ev: cur,
            total: reviewTotal,
            // The same rows' count, so the bar and the panel agree.
            answered: s.examReviewByToken[cur.token]
                ?.where((ExamReviewRow r) => r.answered)
                .length,
            body: _Review(store: s, ev: cur, asm: asm, onFinish: _finish),
          );
        }

        // 5. Valid, not yet started - the candidate can begin.
        if (cur.startedAt == null) {
          _warmAi(asm);
          return _Instructions(
            store: s,
            ev: cur,
            asm: asm,
            onBegin: _begin,
            askCamera: widget.askCamera,
          );
        }

        // 6. The question page.
        //
        // Live, the question comes from the server's envelope - it sends one
        // at a time with its own index and total. In seed mode there is no
        // envelope, so the fixture list is indexed as before.
        //
        // Read again here rather than reusing the one above: this closure runs
        // on every store notification, and pressing Begin replaces the
        // envelope with the one `/exam/<token>/begin` answered.
        final ExamView? live = s.examView(widget.token);
        final Question? q =
            live?.question ??
            (asm.questions.isEmpty
                ? null
                : asm.questions[widget.questionNumber.clamp(
                        1,
                        asm.questions.length,
                      ) -
                      1]);
        if (q == null) {
          return _buildChrome(
            context,
            asm: asm,
            ev: cur,
            body: const EmptyLine('This assessment has no questions.'),
          );
        }
        final int total = live?.total ?? asm.questions.length;
        final int n =
            live?.index ??
            widget.questionNumber.clamp(1, total == 0 ? 1 : total);
        return _buildChrome(
          context,
          asm: asm,
          ev: cur,
          questionNumber: n,
          total: total,
          body: _QuestionPage(
            store: s,
            ev: cur,
            asm: asm,
            q: q,
            number: n,
            total: total,
            onNav: (String nav) => _navigate(cur, q, n, nav),
          ),
          footer: _QuestionNav(
            number: n,
            total: total,
            onNav: (String nav) => _navigate(cur, q, n, nav),
          ),
        );
      },
    );
  }

  /// Save the current answer if there is one, then move.
  ///
  /// SAVING AND MOVING ARE SEPARATE HERE, because on the server they are not.
  /// `/answer` does both in one call and refuses to do either when the answer
  /// is incomplete, so a blank question used to be a dead end: forward, back
  /// and Review all returned the same 422, and a candidate who wanted to skip
  /// a question - or who cleared a box to think again - was stuck on it.
  ///
  /// So: an answer with something in it is saved through `/answer`, which also
  /// hands back the next question. An empty one is not sent at all, and the
  /// move goes through `/state?q=`. Nothing the candidate typed is lost either
  /// way - it stays in the store, and the server still holds whatever the
  /// autosave already persisted.
  ///
  /// Seed mode keeps the old client-side index walk - there is no server to
  /// ask, and the fixture demo is the only thing that path serves.
  Future<void> _navigate(Attempt ev, Question q, int number, String nav) async {
    if (!widget.store.isLive) {
      if (nav == 'review') {
        context.nav.examReview(widget.token);
      } else {
        context.nav.examQuestion(
          widget.token,
          nav == 'prev' ? number - 1 : number + 1,
        );
      }
      return;
    }
    // RE-READ the sitting; do not trust the one this closure captured.
    //
    // `saveAnswerQuiet` deliberately does NOT notify - that is the whole
    // reason it exists, because a rebuild on every keystroke destroys the
    // caret in a free-text field. So nothing repaints while somebody types,
    // and `ev` here is still the Attempt as it stood when the question was
    // painted: its `resp` has no justification and no labels, however much
    // the candidate wrote. Posting that sent `justification: ""`, and
    // `_record_response` refuses an empty subjective answer
    // (candidate.py:660) - so the server answered 422 "This answer is
    // incomplete for its question type" over a box that was plainly filled,
    // and the attempt stayed on "0 answered".
    //
    // The store is the one place that DID see every keystroke.
    final Attempt current = widget.store.attemptByToken(widget.token) ?? ev;
    final Response r = current.resp[q.id] ?? const Response();

    // A REQUIRED JUSTIFICATION THAT IS STILL EMPTY IS NOT SAVEABLE EITHER.
    //
    // `_record_response` holds such an answer as a DRAFT and reports it
    // incomplete, so posting it would come back refused. `hasInput` does not
    // catch it - picking a verdict is enough to make that true - so the runner
    // has to ask the same question the server does.
    //
    // MOVE ANYWAY, exactly as a blank question moves. Blocking here is what
    // made a blank question a dead end before: forward, back and Review all
    // returned the same refusal and the candidate was stuck on it. They are
    // told why, once, and can still leave and come back - the verdicts they
    // picked stay in the store and in the draft the autosave already wrote.
    // MIRROR THE SERVER'S RULE, DO NOT APPROXIMATE IT.
    //
    // This used to read `q.requiresJustification && r.justification.isEmpty`,
    // which refused two kinds of fully answered question on EVERY Next press:
    //
    //   * image_label. Its answer lives in `labels`, never in `justification` -
    //     `_LabelRow.onChanged` only ever writes `labels`. The server does not
    //     disagree: `_record_response` PACKS the label map INTO `justification`
    //     before it applies this same test, so a labelled question passes there
    //     while the client was still looking at an empty string. A candidate saw
    //     "8 / 8 labelled" and a red "needs a justification before it counts".
    //
    //   * subjective_rubric answered on its axes. The server's `carried_by_axes`
    //     accepts a rubric whose dimensions are answered and whose optional
    //     prose box ("explain any FAILED check") is blank. The client had no
    //     equivalent, so answering all six axes still read as incomplete.
    //
    // The cost was not only the toast: `needsProse` also SKIPS the authoritative
    // save below, so the answer reached the server through the 1 s debounce
    // instead - which lands, so nothing was lost, but the candidate is told the
    // opposite of the truth and has no way to tell a false alarm from real data
    // loss. In an exam that is the same thing as losing it.
    //
    // The rule itself lives on `Response.satisfiesProse` so this screen and the
    // tests share ONE implementation - a second copy here is how the client and
    // the server drifted apart in the first place.
    final bool needsProse = q.requiresJustification && !r.satisfiesProse(q);
    if (needsProse) {
      widget.store.toaster.bad(
        'This question needs a justification before it counts as answered.',
      );
    }

    // Nothing to save: MOVE ONLY. `hasInput` is the grader's own test for an
    // absent answer, so the client and the server agree about what counts as
    // blank, and a question skipped here is scored exactly as one never
    // opened.
    if (!r.hasInput || needsProse) {
      if (nav == 'review') {
        await widget.store.loadExamReview(widget.token);
        if (mounted) context.nav.examReview(widget.token);
        return;
      }
      // No route change, exactly as the save path does it: the store now holds
      // the question and the ListenableBuilder repaints around it. Pushing a
      // route here would instead grow the back stack by one entry per skip.
      await widget.store.loadExamQuestion(
        widget.token,
        nav == 'prev' ? number - 1 : number + 1,
      );
      return;
    }

    final bool toReview = await widget.store.examAdvance(
      widget.token,
      q.id,
      r,
      nav: nav,
    );
    if (!mounted) return;
    if (toReview) {
      await widget.store.loadExamReview(widget.token);
      if (mounted) context.nav.examReview(widget.token);
    }
    // Otherwise the store already holds the next question and the
    // ListenableBuilder repaints - no route change, so the address bar and
    // the runner cannot disagree about which question is on screen.
  }

  Future<void> _begin() async {
    final Attempt? ev = widget.store.attemptByToken(widget.token);
    if (ev == null) return;
    final Assessment? asm = widget.store.asmById(ev.assessmentId);
    // NO FULLSCREEN REQUEST HERE, though there used to be one.
    //
    // This runs from the instructions page, which does not go through
    // `_buildChrome` - so the watcher has not been started, `_running` is
    // false, and `fullscreenchange` is not being listened for. A request made
    // here could therefore never set the `_everEnteredFullscreen` latch even
    // when it succeeded, and Flutter dispatches this callback after the
    // browser's activation window for the Begin click has closed, so it did
    // not succeed either. It spent the one gesture the exam gets on the way in
    // and left the gate up on the question page regardless.
    //
    // Worse with the webcam rule on: it raced `getUserMedia`, and a fullscreen
    // transition and a camera permission bubble cannot share a click. The gate
    // on the question page is what arms fullscreen now, on the Begin path and
    // the Resume path alike, and it waits for the camera first.
    // AWAITED: the call answers with the first question, and navigating before
    // it lands puts the runner on a question page with nothing to show.
    await widget.store.beginExam(ev.id);
    if (!mounted) return;
    if (asm != null && asm.durationMinutes > 0) {
      // On the server's clock, like every deadline the Clock is handed.
      _deadline = DateTime.now()
          .add(ev.clockOffset)
          .add(Duration(minutes: asm.durationMinutes));
    }
    context.nav.examQuestion(widget.token, 1);
  }

  /// True once the attempt is submitted. The completion screen is NOT routed
  /// to before that (BR-D1): a refused submit leaves the candidate on the
  /// screen they pressed it from, with Submit to press again.
  Future<bool> _finish({
    bool auto = false,
    String autoReason = '',
    bool force = false,
  }) async {
    final Attempt? ev = widget.store.attemptByToken(widget.token);
    if (ev == null) return false;
    final bool done = await widget.store.finishExam(
      ev.id,
      auto: auto,
      autoReason: autoReason,
      force: force,
    );
    if (done && mounted) context.nav.examComplete(widget.token);
    return done;
  }

  void _violate(String reason) {
    final Attempt? ev = widget.store.attemptByToken(widget.token);
    if (ev == null) return;
    // RECORD FIRST, THEN SAY SO.
    //
    // The toast used to fire before the store was even asked, so an event the
    // store then refused - a finished sitting, or a same-reason repeat inside
    // the 1.2s dedup window - still told the candidate "this has been
    // recorded" for something that was neither counted nor sent. A proctoring
    // notice that can be wrong is worse than none: it is the message a
    // candidate would quote in an appeal.
    // Both kinds summed: an AI reason moves the AI count only (R5).
    int counted(Attempt a) => a.violationCount + a.aiViolationCount;
    final int before = counted(ev);
    final bool ended = widget.store.recordViolation(ev.id, reason);
    final Attempt? after = widget.store.attemptById(ev.id);
    if (after != null && counted(after) > before) _toast(reason);
    if (ended && mounted) context.nav.examComplete(widget.token);
  }

  /// The exam chrome: sticky top bar, watermark, camera plate, simulator,
  /// toast and the blocking overlays.
  Widget _buildChrome(
    BuildContext context, {
    required Assessment asm,
    required Attempt ev,
    required Widget body,
    // PINNED BELOW THE SCROLL VIEW, not inside it.
    //
    // The question navigation used to be the last child of the scrolling
    // column, so its vertical position was a function of how tall the current
    // question happened to be: a short MCQ put Next near the top of the
    // screen, the next question's long prose pushed it down two hundred
    // pixels, and a candidate moving through a paper had to re-find the
    // primary action on every screen. It also left a large dead band under
    // short questions, because the column ended where the content did.
    Widget? footer,
    int? questionNumber,
    int? total,
    int? answered,
  }) {
    // The only place both live exam stages pass through, so the listeners are
    // attached exactly once regardless of which screen the candidate is on.
    _ensureProctoring(asm, ev);
    final AppTokens t = context.tokens;
    final Widget? overlay = _blockingOverlay(asm, ev);
    _followOverlay(overlay != null);
    return Scaffold(
      backgroundColor: t.bgSubtle,
      body: Stack(
        children: <Widget>[
          // The watermark is decoration and never intercepts a pointer.
          if (asm.rules[ProctorRule.watermark])
            Positioned.fill(
              child: IgnorePointer(
                child: Watermark(label: _watermarkLabel(asm, ev)),
              ),
            ),
          Column(
            children: <Widget>[
              // OUTSIDE the exclusion below (L6). Behind the camera and
              // fullscreen overlays - "The clock keeps running" - a screen
              // reader must still hear the time left. Its one control, the
              // theme toggle (BR-D9), is out of the keyboard's reach while
              // an overlay is up, as the paper is.
              ExcludeFocus(
                excluding: overlay != null,
                child: ExamTopBar(
                  title: asm.name,
                  questionNumber: questionNumber,
                  // The server's count. `asm.questions` is empty on a live
                  // exam - the payload has never carried a question list.
                  total: total ?? asm.questions.length,
                  answered: answered ?? ev.answeredCount,
                  // THE SERVER'S DEADLINE IS THE CLOCK (SNo 129).
                  //
                  // `evaluator.deadline_datetime` is on every exam payload and
                  // `Attempt.deadline` has parsed it all along - its own comment
                  // said it was "read by nothing", and that was true here. The
                  // runner counted down from `startedAt + duration`, and worse,
                  // `_begin()` set `_deadline` from the CLIENT's own
                  // `DateTime.now()`. Both drift from the server: a slow begin
                  // call, or a machine whose clock is a few minutes off, and the
                  // candidate is shown time they do not have - or loses time they
                  // do. The server expires the attempt on ITS deadline whatever
                  // the browser believes, so the browser should show that one.
                  //
                  // The two old sources stay as fallbacks, in order, for a
                  // payload that predates the field or an attempt the server has
                  // not stamped yet.
                  deadline:
                      ev.deadline ??
                      _deadline ??
                      (ev.startedAt != null && asm.durationMinutes > 0
                          ? ev.startedAt!.add(
                              Duration(minutes: asm.durationMinutes),
                            )
                          : null),
                  onExpire: _timeUp,
                  clockOffset: ev.clockOffset,
                  // The server's verdict, not a guess: it sets `preview` when the
                  // caller holds the token but is not the candidate.
                  preview:
                      widget.store.examView(widget.token)?.preview ?? false,
                  onToggleTheme: widget.onToggleTheme,
                  isDark: widget.isDark,
                ),
              ),
              // THE PAPER IS OUT OF REACH WHILE AN OVERLAY IS UP (MT3-02). The
              // overlay stopped the pointer but not the keyboard: Tab walked from
              // "See my submission" to Next and into the answer box behind it, and
              // the answer box kept the focus it had, so typing went on and the
              // autosave stored it. Toggling these keeps the subtree mounted, so
              // the clock's state survives.
              Expanded(
                // THE CAMERA PREVIEW MOVES IN HERE, under the top bar
                // (BR-D6). Over the whole screen it could be dropped on the
                // bar itself, over the title, the count and the clock.
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints below) => Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      ExcludeSemantics(
                        excluding: overlay != null,
                        child: ExcludeFocus(
                          excluding: overlay != null,
                          // And the pointer: an audio or video player under the
                          // overlay is a browser element and would take its clicks.
                          child: MediaInert(
                            inert: overlay != null,
                            child: Column(
                              children: <Widget>[
                                // UNDER the top bar, IN the Column - not over it in the Stack.
                                //
                                // Declared as a Stack child AFTER the Column, this bar painted
                                // on top of the very bar it belongs under, hiding the exam
                                // title, the question number, the answered count and the
                                // COUNTDOWN. The clock kept running and `onExpire` kept firing -
                                // it was hidden, not stopped - so a candidate who left
                                // fullscreen simply lost sight of how long they had left, for
                                // the rest of the sitting, as the direct consequence of a rule
                                // meant to protect the exam. Being an opaque `Material` it also
                                // swallowed every pointer across that strip.
                                //
                                // In the Column it takes its own height and pushes the paper
                                // down, so it can occlude neither the bar above nor the question
                                // below. An offset `Positioned` would not do: ExamTopBar's
                                // height is intrinsic, so any constant is wrong at a non-default
                                // text scale and drifts the moment anyone edits the bar.
                                if (_offerFullscreen(ev))
                                  FullscreenNudge(
                                    // NOT `fullscreenRefused`. A browser-driven exit - the tab
                                    // dropped out of fullscreen so a permission bubble could be
                                    // shown - reaches this bar with `_everEnteredFullscreen` set
                                    // and nothing on the record either.
                                    recorded: _proctor.fullscreenExitRecorded,
                                    queued: widget.store.violationReportsUnsent(
                                      widget.token,
                                    ),
                                    actionViewType: _proctor
                                        .fullscreenButtonView(),
                                    onEnter: () {
                                      _proctor.requestFullscreen();
                                      setState(() {});
                                    },
                                  ),
                                Expanded(
                                  child: SingleChildScrollView(
                                    // The 120 at the bottom existed to keep content clear of the
                                    // floating simulator and camera plate. With a real footer
                                    // the scroll area ends above it, so only the plate's own
                                    // clearance is still needed.
                                    padding: EdgeInsets.fromLTRB(
                                      20,
                                      22,
                                      20,
                                      footer == null ? 120 : 24,
                                    ),
                                    child: Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 1120,
                                        ),
                                        child: body,
                                      ),
                                    ),
                                  ),
                                ),
                                if (footer != null)
                                  Container(
                                    decoration: BoxDecoration(
                                      color: t.bgSubtle,
                                      border: Border(
                                        top: BorderSide(color: t.border),
                                      ),
                                    ),
                                    padding: const EdgeInsets.fromLTRB(
                                      20,
                                      12,
                                      20,
                                      12,
                                    ),
                                    child: Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 1120,
                                        ),
                                        child: footer,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // The live preview, so the candidate can see exactly
                      // what is on - the same reassurance the portal's own
                      // plate gave. Only mounted when there is a real
                      // stream behind it; `cameraViewType` is null on any
                      // platform without one, which is what keeps this
                      // compiling and inert under the VM test runner.
                      if (_proctor.cameraViewType != null)
                        _cameraPlate(below.biggest),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (_vToast != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 78,
              child: Center(child: ViolationToast(_vToast!)),
            ),
          // THE SIMULATOR IS A BUILD-TIME OPT-IN.
          //
          // ProctorRig is a control panel with a button per proctoring rule
          // that calls the REAL /exam/<token>/violation route. It is genuinely
          // useful for showing how proctoring behaves - and in front of an
          // actual candidate it is a way to fabricate violations against
          // yourself, or, at a violation cap of 1, to auto-submit your own
          // exam with one click. It was rendered unconditionally.
          //
          // Default OFF - see [kProctorSim]. Turn it on for a demo with
          // --dart-define=PROCTOR_SIM=true.
          if (kProctorSim)
            Positioned(
              right: 14,
              bottom: 72,
              child: ProctorRig(
                asm: asm,
                violations: ev.violationCount,
                aiViolations: ev.aiViolationCount,
                minimised: _rigMin,
                onToggle: () => setState(() => _rigMin = !_rigMin),
                onViolate: _violate,
                onBlockWebcam: () => setState(() => _block = 'webcam'),
                onBlockDeadline: () => setState(() => _block = 'deadline'),
              ),
            ),
          // EXACTLY ONE BLOCKING OVERLAY, EVER.
          //
          // These were three independent `if`s in the same Stack, and a
          // candidate who lost their camera while also not in fullscreen got
          // both painted on top of each other - two titles overlapping, and
          // the lower overlay's button unreachable underneath the upper one's.
          // A blocking surface names ONE thing to do; the moment two of them
          // stack, neither can be read or pressed.
          //
          // Ordered by what has to be true first: an ended exam beats a
          // missing camera, and a missing camera beats a windowed one - asking
          // for fullscreen while the camera is off would only have to be asked
          // again after the camera prompt.
          ?overlay,
        ],
      ),
    );
  }

  /// The draggable camera preview, positioned inside [area].
  ///
  /// The wrapper carries a stable key and only the `Positioned` above it
  /// changes on a move, so the `<video>` platform view is never remounted (a
  /// remount would restart the stream). Lowest allowed spot keeps the 72 px
  /// clear of the footer the plate has always had; the highest is the top of
  /// [area], which starts under the top bar.
  Widget _cameraPlate(Size area) {
    final double maxLeft = math.max(0, area.width - kCameraPlateSize.width);
    final double maxTop = math.max(
      0,
      area.height - kCameraPlateSize.height - 72,
    );
    final Offset pos = _camPos ?? Offset(14, maxTop);
    final double left = pos.dx.clamp(0, maxLeft).toDouble();
    final double top = pos.dy.clamp(0, maxTop).toDouble();
    return Positioned(
      left: left,
      top: top,
      child: Semantics(
        key: const ValueKey<String>('camera-plate'),
        container: true,
        excludeSemantics: true,
        label: 'Camera preview, drag to move',
        child: MouseRegion(
          cursor: _camDragging
              ? SystemMouseCursors.grabbing
              : SystemMouseCursors.grab,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => setState(() => _camDragging = true),
            onPanUpdate: (DragUpdateDetails d) => setState(() {
              _camPos = Offset(
                (left + d.delta.dx).clamp(0, maxLeft).toDouble(),
                (top + d.delta.dy).clamp(0, maxTop).toDouble(),
              );
            }),
            onPanEnd: (_) => setState(() => _camDragging = false),
            onPanCancel: () => setState(() => _camDragging = false),
            child: ProctorCameraPlate(viewType: _proctor.cameraViewType!),
          ),
        ),
      ),
    );
  }

  /// Who the watermark names.
  ///
  /// The SERVER's label first. Deriving it from the roster works only on admin
  /// surfaces - a candidate never loads a roster, so `personById` returned
  /// null on the one screen the watermark exists for and it painted nothing.
  /// The roster branch is kept for the seed fixtures and the admin preview,
  /// where the serializer has no candidate to name and sends an empty label.
  String _watermarkLabel(Assessment asm, Attempt ev) {
    if (asm.watermarkLabel.isNotEmpty) return asm.watermarkLabel;
    final Person? p = widget.store.personById(ev.employeeId);
    if (p != null) return '${p.name}  ${p.email}';
    // Last resort: this app knows who is signed in even when it holds no
    // roster row for them. A watermark with a name on it deters; an empty one
    // is the rule silently doing nothing.
    return widget.store.meName;
  }
}

/// The sticky exam top bar: title, position, progress, answered count and the
/// colour-changing clock.
class ExamTopBar extends StatelessWidget {
  final String title;
  final int? questionNumber;
  final int total;
  final int answered;
  final DateTime? deadline;
  final VoidCallback onExpire;

  /// See [Clock.offset].
  final Duration clockOffset;

  /// Staff reading a candidate's paper. Carried on EVERY question, not only on
  /// the instructions page: a preview that says so once and then looks identical
  /// to a live sitting for the next twelve screens is a preview somebody will
  /// forget they are in - and every control they try then refuses with
  /// `wrong_candidate`.
  final bool preview;

  /// The theme toggle, shown only where the nav rail (which carries it) is
  /// hidden - a sitting. Null leaves the bar as it was.
  final VoidCallback? onToggleTheme;
  final bool isDark;

  const ExamTopBar({
    super.key,
    required this.title,
    this.questionNumber,
    required this.total,
    required this.answered,
    this.deadline,
    required this.onExpire,
    this.clockOffset = Duration.zero,
    this.preview = false,
    this.onToggleTheme,
    this.isDark = true,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final double progress = total == 0 ? 0 : (questionNumber ?? 0) / total;
    final List<Widget> heading = <Widget>[
      if (preview) ...<Widget>[
        const Pill('Preview', Tone.info),
        const SizedBox(width: 10),
      ],
      Flexible(
        child: Text(
          title,
          style: context.type.body.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ];
    // ON A PHONE THE TITLE GETS A LINE OF ITS OWN (BR-D7). In the one row it
    // shared what the counts and the clock left with the progress bar, and at
    // 390 px that was a few pixels: the exam's name vanished. The row below
    // keeps its place in the tree either way, so the clock is never rebuilt.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: t.bgApp,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final bool narrow = box.maxWidth < Layout.sm;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (narrow)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(children: heading),
                )
              else
                const SizedBox.shrink(),
              Row(
                children: <Widget>[
                  if (!narrow) ...<Widget>[
                    ...heading,
                    const SizedBox(width: 14),
                  ],
                  if (questionNumber != null)
                    Text(
                      'Question $questionNumber of $total',
                      style: context.type.mono.copyWith(
                        fontSize: 12,
                        color: t.textSecondary,
                      ),
                    ),
                  const SizedBox(width: 14),
                  Expanded(
                    // PROGRESS WITH A VALUE, replacing the QWeb runner's
                    // `role="progressbar" aria-valuenow`. A bare
                    // `LinearProgressIndicator` announces "progress bar" and no number,
                    // so "how far through am I" was unanswerable without sight. The
                    // count is spoken rather than the fraction, because "3 of 12
                    // answered" is what a candidate is actually tracking.
                    child: Semantics(
                      label:
                          '$answered of $total '
                          '${total == 1 ? 'question' : 'questions'} answered',
                      value: '$answered of $total',
                      child: ExcludeSemantics(
                        child: ClipRRect(
                          borderRadius: const BorderRadius.all(
                            Radius.circular(3),
                          ),
                          child: LinearProgressIndicator(
                            value: progress.clamp(0, 1),
                            minHeight: 5,
                            backgroundColor: t.bgMuted,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              t.primary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  // Excluded, not relabelled: the progress bar beside it already says
                  // "N of M answered", and two readings of the same fact is noise.
                  ExcludeSemantics(
                    child: Text(
                      '$answered answered',
                      style: context.type.small,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Clock(
                    deadline: deadline,
                    onExpire: onExpire,
                    offset: clockOffset,
                  ),
                  if (onToggleTheme != null) ...<Widget>[
                    const SizedBox(width: 10),
                    IconBtn(
                      isDark
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                      tooltip: isDark ? 'Switch to light' : 'Switch to dark',
                      onPressed: onToggleTheme,
                    ),
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The countdown.
///
/// It owns a 1s timer and rebuilds ONLY itself, never the exam surface. With
/// no deadline it writes the literal "Not started"; otherwise `mm:ss`, turning
/// amber under five minutes and red under one.
class Clock extends StatefulWidget {
  final DateTime? deadline;
  final VoidCallback onExpire;

  /// Server clock minus device clock ([Attempt.clockOffset]). [deadline] is
  /// the SERVER's, so it is compared with device now + this: a device running
  /// slow otherwise showed time the server had already taken away, and its
  /// last answer landed past the 10s grace and was refused.
  final Duration offset;

  const Clock({
    super.key,
    this.deadline,
    required this.onExpire,
    this.offset = Duration.zero,
  });

  @override
  State<Clock> createState() => _ClockState();
}

class _ClockState extends State<Clock> {
  Timer? _tick;
  bool _fired = false;

  /// Now on the server's clock - see [Clock.offset].
  DateTime get _now => DateTime.now().add(widget.offset);

  /// Whole minutes at the last announcement, so the milestone check below fires
  /// once per crossing rather than once per tick. -1 = nothing announced yet.
  int _announcedMinute = -1;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  /// SPEAK THE TIME AT MILESTONES, not every second.
  ///
  /// The QWeb runner carried `role="timer"` plus an `aria-live="assertive"`
  /// announcer beside it; the Flutter exam had no equivalent, so a candidate
  /// using a screen reader had NO WAY to learn how long was left. They cannot
  /// see the badge, and nothing spoke.
  ///
  /// Announcing every tick is worse than silence - it talks over the question -
  /// so this speaks at the points a person actually acts on: 30, 20, 15, 10, 5,
  /// 2 and 1 minutes. `assertive` only under five minutes, because interrupting
  /// someone mid-answer is justified when the clock is nearly out and rude when
  /// it is not.
  void _announce(int minutesLeft) {
    if (minutesLeft == _announcedMinute) return;
    const Set<int> milestones = <int>{30, 20, 15, 10, 5, 2, 1};
    if (!milestones.contains(minutesLeft)) return;
    _announcedMinute = minutesLeft;
    // `sendAnnouncement`, not the deprecated `announce`: the latter resolves the
    // view through `PlatformDispatcher.implicitView` and asserts when there is
    // more than one. Passing this widget's own view is both current and correct.
    SemanticsService.sendAnnouncement(
      View.of(context),
      minutesLeft == 1
          ? '1 minute remaining'
          : '$minutesLeft minutes remaining',
      Directionality.of(context),
      assertiveness: minutesLeft <= 5
          ? Assertiveness.assertive
          : Assertiveness.polite,
    );
  }

  /// THE DEADLINE OFTEN ARRIVES AFTER THIS WIDGET IS FIRST BUILT.
  ///
  /// A candidate opening an invitation link has loaded nothing yet, so the
  /// attempt - and therefore the deadline - is null on the first frame and
  /// lands a moment later. The timer used to be created only in `initState`
  /// and only when the deadline was already non-null, so a RESUMING candidate
  /// got "Not started", no countdown, and an `onExpire` that never fired. They
  /// worked past the deadline until a server route settled them. Resume is
  /// the normal way in, so this was the common case, not the edge case.
  @override
  void didUpdateWidget(Clock old) {
    super.didUpdateWidget(old);
    if (old.deadline != widget.deadline) {
      _fired = false;
      _sync();
    }
  }

  void _sync() {
    _tick?.cancel();
    _tick = null;
    if (widget.deadline == null) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      final Duration left = widget.deadline!.difference(_now);
      if (!left.isNegative) {
        // Ceiling, so "1 minute remaining" is spoken while a minute is still
        // there to use rather than as it hits zero.
        _announce((left.inSeconds / 60).ceil());
      }
      if (left.isNegative && !_fired) {
        _fired = true;
        widget.onExpire();
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    if (widget.deadline == null) {
      // NOT "no limit" any more - every assessment is timed. A null deadline
      // now means only that the sitting has not started yet, so the clock has
      // nothing to count down from and says so rather than promising a paper
      // with no clock.
      return _shell(context, 'Not started', t.bgMuted, t.border, t.textPrimary);
    }
    final int ms = widget.deadline!
        .difference(_now)
        .inMilliseconds
        .clamp(0, 1 << 31);
    final int mm = ms ~/ 60000;
    final int ss = (ms % 60000) ~/ 1000;
    final String text =
        '${mm.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}';

    if (ms < 60000) {
      return _shell(context, text, t.destBg, t.destText.o(.4), t.destText);
    }
    if (ms < 300000) {
      return _shell(context, text, t.warnBg, t.warnText.o(.4), t.warnText);
    }
    return _shell(context, text, t.bgMuted, t.border, t.textPrimary);
  }

  Widget _shell(
    BuildContext context,
    String text,
    Color bg,
    Color border,
    Color fg,
  ) {
    // A SPOKEN LABEL, NOT THE GLYPH TEXT. "04:07" is read out as "four colon
    // zero seven" or as a bare number depending on the reader - neither of which
    // says it is a countdown. The replacement for the QWeb runner's
    // `role="timer"` is a label that states what the number MEANS; the visual
    // `mm:ss` is unchanged for everyone who can see it.
    final String spoken = widget.deadline == null
        ? 'Not started. The clock begins when you start the exam.'
        : () {
            final Duration left = widget.deadline!.difference(_now);
            if (left.isNegative) return 'Time is up.';
            final int m = left.inMinutes;
            final int s = left.inSeconds % 60;
            if (m == 0) return 'Time remaining: $s seconds.';
            return 'Time remaining: $m minute${m == 1 ? '' : 's'} $s seconds.';
          }();

    return Semantics(
      // LIVE, so a reader that polls regions picks the value up without the
      // candidate having to go looking for it. The milestone announcements in
      // `_announce` are the push half; this is the pull half.
      liveRegion: true,
      label: spoken,
      // The glyph would otherwise be read a second time, as digits.
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: Radii.button,
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.schedule, size: 14, color: fg),
            const SizedBox(width: 7),
            Text(text, style: context.type.clock.copyWith(color: fg)),
          ],
        ),
      ),
    );
  }
}

/// Tiled name-and-email spans at 6% ink, rotated -30 degrees, covering the
/// WHOLE surface. A visual deterrent only, and never announced to assistive
/// technology.
class Watermark extends StatelessWidget {
  final String label;

  const Watermark({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    final AppTokens t = context.tokens;

    // Laid out with a fixed-size Wrap, NOT a GridView.
    //
    // A GridView is a scrollable, and a scrollable inside an OverflowBox with
    // an infinite maxHeight has no viewport bound - Flutter throws "Vertical
    // viewport was given unbounded height" and the tile grid fails to lay out.
    // The watermark never scrolls and never changes size, so the scrollable
    // bought nothing and cost the whole subtree.
    const double tileW = 190;
    const double tileH = 60;

    // SIZED FROM THE VIEWPORT, NOT A HARDCODED 6x10 BLOCK.
    //
    // The counts used to be `cols = 6, rows = 10` - a 1140x600 slab centred in
    // whatever space it was given. On any display bigger than that the corners
    // were bare, and because the exam body is narrower than the window the
    // overhang landed on the SIDEBAR instead of the exam: a photograph of the
    // questions had no name on it, which is the one thing the watermark exists
    // to prevent. Seen in the browser at 1728x1049.
    //
    // `etp_assessment_pro` gets this for free - `.etp-watermark-layer` is
    // `position: fixed; inset: 0` on `document.body`, so it is the viewport by
    // construction. Flutter has no such anchor, so the count is computed.
    //
    // The DIAGONAL is why the span is multiplied rather than merely rounded up.
    // Rotating a w x h rectangle by 30 degrees needs
    // `w*cos30 + h*sin30` of width and `w*sin30 + h*cos30` of height to still
    // cover the original box, so the ~1.4x here is the rotation's cost plus one
    // tile of slack. Under-counting shows as clipped corners exactly at the
    // angle, which reads as a rendering bug rather than a missing deterrent.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // `maxWidth`/`maxHeight` are infinite if this is ever placed outside a
        // Positioned.fill; fall back to the window so it degrades to covering
        // the screen rather than throwing.
        final Size win = MediaQuery.sizeOf(context);
        final double w = c.maxWidth.isFinite ? c.maxWidth : win.width;
        final double h = c.maxHeight.isFinite ? c.maxHeight : win.height;
        final double span = (w > h ? w : h) * 1.45;
        final int cols = (span / tileW).ceil() + 1;
        final int rows = (span / tileH).ceil() + 1;

        return IgnorePointer(
          child: ClipRect(
            child: OverflowBox(
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: Transform.rotate(
                angle: -30 * 3.14159265 / 180,
                child: SizedBox(
                  width: tileW * cols,
                  height: tileH * rows,
                  child: Wrap(
                    children: <Widget>[
                      for (int i = 0; i < cols * rows; i++)
                        SizedBox(
                          width: tileW,
                          height: tileH,
                          child: Center(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              style: context.type.body.copyWith(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: t.textPrimary.o(.06),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The violation toast: its own channel, always destructive-toned, 4s life.
class ViolationToast extends StatelessWidget {
  final String message;

  const ViolationToast(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: (MediaQuery.of(context).size.width * .9).clamp(0.0, 512.0),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        decoration: BoxDecoration(
          color: t.destBg,
          borderRadius: const BorderRadius.all(Radius.circular(9)),
          border: Border.all(color: t.destText.o(.4)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: t.shadow.o(.2),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Text(
          message,
          style: context.type.body.copyWith(
            fontWeight: FontWeight.w600,
            color: t.destText,
          ),
        ),
      ),
    );
  }
}

/// Whether the proctoring SIMULATOR is built into the exam chrome.
///
/// It drives the REAL violation route, so it must not reach a live candidate:
/// at a violation cap of 1 a candidate can auto-submit their own exam from it.
///
/// DEFAULTS TO FALSE, and that is a change. It used to default to TRUE and rely
/// on every build passing `--dart-define=PROCTOR_SIM=false` to take it out
/// again - a fail-OPEN default on a control that can end somebody's exam. The
/// Dockerfile and the Makefile both pass it, so shipped bundles were safe; a
/// bundle built any other way was not, and a plain `flutter build web` put the
/// panel in front of candidates with nothing to warn anyone. A walkthrough on
/// 2026-09-09 hit exactly that.
///
/// The old default was justified as "every existing build and every test
/// expects it present". No test references it - checked, not assumed - and the
/// two real build paths pass the flag explicitly, so nothing depended on it.
///
/// Turn it on for a demo: `--dart-define=PROCTOR_SIM=true`, which is what
/// `make build PROCTOR_SIM=true` already does.
const bool kProctorSim = bool.fromEnvironment(
  'PROCTOR_SIM',
  defaultValue: false,
);

class ProctorRig extends StatelessWidget {
  final Assessment asm;
  final int violations;

  /// The AI count, against its own pair (R5): the rig's "AI: " button adds
  /// to this one, not to [violations].
  final int aiViolations;
  final bool minimised;
  final VoidCallback onToggle;
  final ValueChanged<String> onViolate;
  final VoidCallback onBlockWebcam;
  final VoidCallback onBlockDeadline;

  const ProctorRig({
    super.key,
    required this.asm,
    required this.violations,
    this.aiViolations = 0,
    required this.minimised,
    required this.onToggle,
    required this.onViolate,
    required this.onBlockWebcam,
    required this.onBlockDeadline,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    String count(String kind, int n, bool ai) {
      final ({ViolationAction action, int cap}) p = asm.policy(ai);
      final int cap = p.cap > 0 ? p.cap : 1;
      return p.action.isAuto
          ? '$kind $n of $cap - auto-submits at $cap'
          : '$kind $n - log only';
    }

    return Container(
      width: 246,
      decoration: BoxDecoration(
        color: t.bgApp,
        borderRadius: Radii.panel,
        border: Border.all(color: t.primary.o(.4)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: t.shadow.o(.2),
            blurRadius: 32,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onToggle,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 9,
                ),
                color: t.primarySubtle,
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'PROCTORING SIMULATOR',
                        style: context.type.tiny.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: .77,
                          color: t.primary,
                        ),
                      ),
                    ),
                    Icon(
                      minimised ? Icons.add : Icons.remove,
                      size: 15,
                      color: t.primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!minimised)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    count('Violation', violations, false),
                    style: context.type.tiny,
                  ),
                  if (asm.rules[ProctorRule.aiProctor])
                    Text(
                      count('AI violation', aiViolations, true),
                      style: context.type.tiny,
                    ),
                  const SizedBox(height: 6),
                  // Only the rules that are ON can be fired.
                  // WEBCAM EXCLUDED. It gained a `violationLabel` so the real
                  // watcher can name the reason it fires, which also put it in
                  // `firable` - and the rig already has a hand-written camera
                  // button below. Without this the panel shows two camera
                  // buttons that do different things.
                  for (final ProctorRule r in asm.rules.firable.where(
                    (ProctorRule r) => r != ProctorRule.webcam,
                  ))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Btn(
                        r.violationLabel,
                        size: BtnSize.sm,
                        expand: true,
                        onPressed: () => onViolate(r.violationLabel),
                      ),
                    ),
                  if (asm.rules[ProctorRule.webcam])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Btn(
                        'Camera Turned Off',
                        size: BtnSize.sm,
                        expand: true,
                        onPressed: onBlockWebcam,
                      ),
                    ),
                  Btn(
                    'Time Expires',
                    size: BtnSize.sm,
                    expand: true,
                    onPressed: onBlockDeadline,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The offer to go back into fullscreen after leaving it.
///
/// A BAR, not a blocking overlay. By the time this shows, the exit has already
/// been recorded as a violation - the rule has done its work. Walling the
/// paper off as well only trapped the candidate: the wall's one action put
/// them back into fullscreen and Escape brought the wall back, with no way to
/// keep answering. This states what happened, offers the way back, and leaves
/// the exam usable.
class FullscreenNudge extends StatelessWidget {
  const FullscreenNudge({
    super.key,
    required this.onEnter,
    this.recorded = true,
    this.queued = false,
    this.actionViewType,
  });

  final VoidCallback onEnter;

  /// The report of that exit has not reached the server yet: "noted", not
  /// "recorded", until it has (F4).
  final bool queued;

  /// Whether the exit that put this bar on screen was recorded as a violation.
  ///
  /// NOT ALWAYS TRUE ANY MORE, and the difference matters more than the copy
  /// does. Two routes here record nothing: a browser that refused the entry
  /// outright, so the requirement degraded from a wall to an offer rather than
  /// trapping the candidate behind a button that could not work; and an exit
  /// the browser performed itself in order to show a permission prompt. Saying
  /// "that has been recorded" to a candidate who has no violation is the exact
  /// sentence they would quote in an appeal.
  final bool recorded;

  /// See [ProctorWatch.fullscreenButtonView]. Null off the web.
  final String? actionViewType;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    // A recorded violation is a warning; a browser that will not co-operate is
    // information. The tone has to agree with the words.
    final ToneColors c = ToneColors.of(t, recorded ? Tone.warn : Tone.info);
    return Material(
      color: c.bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 9, 12, 9),
        child: Row(
          children: <Widget>[
            Icon(
              recorded ? Icons.fullscreen_exit : Icons.fullscreen,
              size: 15,
              color: c.fg,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                recorded
                    ? 'You left fullscreen. That has been '
                          '${queued ? 'noted' : 'recorded'} - returning to '
                          'fullscreen keeps the rest of this exam clean.'
                    // NO MENTION OF F11. It is browser-chrome fullscreen and
                    // does not set `document.fullscreenElement`, so no
                    // `fullscreenchange` fires, this bar does not clear, and
                    // the tab-switch rule stays disarmed. Telling a candidate
                    // to press it hands them an action that visibly does
                    // nothing, which is the failure this whole change exists
                    // to remove.
                    : 'This exam is meant to run in fullscreen and your '
                          'browser did not switch to it. Nothing has been '
                          'recorded against you - carry on answering, or try '
                          'again.',
                // Ink from the TONE, as every other tinted surface here does.
                // The default `small` is a neutral grey on the warn background:
                // 4.51:1 in light mode, one rounding error off the 4.5:1 floor.
                style: context.type.small.copyWith(color: c.fg),
              ),
            ),
            const SizedBox(width: 10),
            GestureButton(
              label: recorded ? 'Return to fullscreen' : 'Try fullscreen again',
              size: BtnSize.sm,
              viewType: actionViewType,
              onPressed: onEnter,
            ),
          ],
        ),
      ),
    );
  }
}

/// A button whose click reaches the browser as a REAL click.
///
/// Flutter paints the control and a transparent DOM element over it takes the
/// press, because the only thing on the other side of this button is
/// `requestFullscreen()` and the browser will not honour that from a Flutter
/// tap callback - by the time the gesture arena has resolved, the user
/// activation for that click is gone. [viewType] comes from
/// [ProctorWatch.fullscreenButtonView] and is null off the web, where this
/// degrades to the plain button and the DOM half simply does not exist.
///
/// [onPressed] is still wired, so a platform without the DOM half, or a press
/// that reaches Flutter anyway, behaves as it always did.
class GestureButton extends StatelessWidget {
  const GestureButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.viewType,
    this.size = BtnSize.md,
    this.primary = false,
  });

  final String label;
  final VoidCallback onPressed;
  final String? viewType;
  final BtnSize size;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final Widget painted = primary
        ? Btn.primary(label, size: size, onPressed: onPressed)
        : Btn(label, size: size, onPressed: onPressed);
    final String? type = viewType;
    if (type == null) return painted;
    // The unpositioned child sizes the Stack, so `Positioned.fill` lands
    // exactly on the painted button however the label wraps or the text scale
    // moves - no constant to drift.
    return Stack(
      children: <Widget>[
        painted,
        Positioned.fill(child: HtmlElementView(viewType: type)),
      ],
    );
  }
}

/// The live webcam preview, shown while the camera rule is satisfied.
///
/// Deliberately small and cornered: it is there so the candidate can SEE that
/// only their own framing is on screen, not to be watched. The stream never
/// leaves the browser - the server is told the camera's on-off state and
/// nothing else.
///
/// [viewType] is registered by the proctor watcher, which owns the stream's
/// lifetime; this widget only mounts what it is handed, so it can never
/// outlive a stopped stream.
/// Outer size of [ProctorCameraPlate]: the 132x99 video, a 5 px gap and the
/// caption row.
const Size kCameraPlateSize = Size(132, 120);

/// Builds the live video. Replaced only by tests: `HtmlElementView` throws off
/// the web.
@visibleForTesting
Widget Function(String viewType) cameraVideoBuilder = (String viewType) =>
    // Transparent so the browser's `<video>` lets the pointer through to the
    // drag handler instead of swallowing it.
    HtmlElementView(
      viewType: viewType,
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    );

class ProctorCameraPlate extends StatelessWidget {
  const ProctorCameraPlate({super.key, required this.viewType});

  final String viewType;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 132,
          height: 99,
          decoration: BoxDecoration(
            color: const Color(0xFF000000),
            borderRadius: Radii.card,
            border: Border.all(color: t.border),
          ),
          clipBehavior: Clip.antiAlias,
          // Transparent so the browser's `<video>` lets the pointer through to
          // the drag handler instead of swallowing it.
          child: cameraVideoBuilder(viewType),
        ),
        const SizedBox(height: 5),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.videocam_outlined, size: 12, color: t.textMuted),
            const SizedBox(width: 5),
            Text('Camera on', style: context.type.tiny),
            const SizedBox(width: 6),
            // The live dot: a steady green disc, the convention for "this is
            // on right now". It replaces the words "not recorded", which spent
            // a caption reassuring the candidate about something the blocking
            // overlay already tells them.
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: ToneColors.of(t, Tone.ok).dot,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A full-viewport blocking overlay.
///
/// The strictest surface in the system: no backdrop dismissal, no Escape, only
/// the single named action.
class BlockOverlay extends StatelessWidget {
  final Tone tone;
  final IconData icon;
  final String title;
  final String body;
  final String action;
  final VoidCallback onAction;

  /// See [ProctorWatch.fullscreenButtonView].
  ///
  /// Set only by the fullscreen gate, whose action a Flutter tap callback
  /// cannot carry out. The camera gate leaves it null: `getUserMedia` is
  /// happy to be called from a tap, so there is nothing to work around.
  final String? actionViewType;

  /// Put on the title, so the runner can move the focus there when the
  /// overlay goes up (L6).
  final FocusNode? headingFocus;

  const BlockOverlay({
    super.key,
    this.headingFocus,
    required this.tone,
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    required this.onAction,
    this.actionViewType,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final ToneColors c = ToneColors.of(t, tone);
    return Positioned.fill(
      // A SEMANTIC MODAL, and ANNOUNCED. This replaces the QWeb runner's
      // `role="alertdialog" aria-modal="true"` on the camera gate.
      //
      // Two separate problems it fixes. `scopesRoute` + `explicitChildNodes`
      // stop a reader walking THROUGH the overlay into the exam behind it -
      // without them the paper is still fully readable and navigable while the
      // screen says it is blocked, so a candidate could answer questions during
      // a camera refusal without ever being told. And `liveRegion` on the title
      // means the block ANNOUNCES ITSELF: these overlays appear in response to
      // the browser (camera revoked, fullscreen dropped, deadline passed), not
      // to a keypress, so nothing would otherwise draw attention to them.
      child: Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        namesRoute: true,
        label: title,
        child: Container(
          color: t.bgSubtle.o(.97),
          alignment: Alignment.center,
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ExcludeSemantics(
                  child: Container(
                    width: 54,
                    height: 54,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.bg,
                      borderRadius: const BorderRadius.all(Radius.circular(14)),
                    ),
                    child: Icon(icon, size: 26, color: c.fg),
                  ),
                ),
                const SizedBox(height: 13),
                // Takes the focus, but is never a Tab stop: Tab goes straight
                // to the one action.
                Focus(
                  focusNode: headingFocus,
                  skipTraversal: true,
                  child: Semantics(
                    // The overlay appears in response to the BROWSER - a
                    // revoked camera, a dropped fullscreen, a passed deadline -
                    // never to a keypress, so without this nothing tells a
                    // screen-reader user that the exam just stopped accepting
                    // answers.
                    liveRegion: true,
                    header: true,
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: context.type.body.copyWith(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 13),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: context.type.bodySecondary.copyWith(
                    fontSize: 13.5,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 13),
                GestureButton(
                  label: action,
                  size: BtnSize.lg,
                  primary: true,
                  viewType: actionViewType,
                  onPressed: onAction,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// The five exam sub-screens.

/// Instructions: the consent and rules page shown before the clock starts.
///
/// THE RULES ARE THE PAGE. An earlier version of this screen printed
/// `ProctorRule.hint` under a panel called "What Is Monitored" - seven
/// third-person sentences about what the system does, in grey, under a heading
/// that described the observer rather than the observed. Candidates read it and
/// then switched tabs. What replaced it is one imperative line per rule
/// (`ProctorRule.candidateRule`), a deny glyph on the six that can end the
/// exam, and a tick that has to be pressed before Start comes alive - so the
/// page is shorter than the prose it replaced AND harder to finish without
/// having read.
class _Instructions extends StatefulWidget {
  final AppStore store;
  final Attempt ev;
  final Assessment asm;
  final VoidCallback onBegin;

  /// [probeCamera]: asked once on the tick, so the camera prompt comes
  /// before Begin and fullscreen (R9b).
  final Future<String?> Function() askCamera;

  const _Instructions({
    required this.store,
    required this.ev,
    required this.asm,
    required this.onBegin,
    required this.askCamera,
  });

  @override
  State<_Instructions> createState() => _InstructionsState();
}

class _InstructionsState extends State<_Instructions> {
  /// The acknowledgement. Start is inert until this is true.
  bool _acked = false;

  /// The camera was asked for already, on an earlier tick.
  bool _cameraAsked = false;

  void _toggleAck() {
    setState(() => _acked = !_acked);
    if (_acked && !_cameraAsked && widget.asm.rules[ProctorRule.webcam]) {
      _cameraAsked = true;
      // The answer is read again at Begin: the camera gate handles a refusal.
      unawaited(widget.askCamera());
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Assessment asm = widget.asm;
    final Attempt ev = widget.ev;
    final int cap = asm.maxViolations > 0 ? asm.maxViolations : 1;
    // The `instructions` outcome carries the counts; `asm.questions` is empty
    // on a live exam, which had this page promising "0 questions".
    final ExamView? view = widget.store.examView(ev.token);
    final int fromServer =
        (view?.instructions['total_questions'] as int?) ?? view?.total ?? 0;
    final int questionCount = fromServer > 0
        ? fromServer
        : asm.questions.length;
    // STAFF LOOKING AT SOMEBODY ELSE'S PAPER. The server decides this, not the
    // client: `/exam/<token>/state` sets `preview` when the caller holds the
    // token but is not the candidate it belongs to.
    final bool isPreview = view?.preview ?? false;

    // SPLIT ON `firesViolation`, NOT ON A HANDWRITTEN LIST. Six of the seven
    // rules record a violation and can therefore end the sitting - right-click
    // and paste included, which surprises people: `proctor_web.dart` calls
    // `preventDefault()` AND `_fire()` on both. Only `watermark` fires nothing,
    // and it is the only one a candidate can do nothing about, so it leaves the
    // rule list and becomes a footnote.
    final List<ProctorRule> enforced = asm.rules.enabled
        .where((ProctorRule r) => r.firesViolation)
        .toList();
    final List<ProctorRule> passive = asm.rules.enabled
        .where((ProctorRule r) => !r.firesViolation)
        .toList();

    // ONE `ends` FOR THE WHOLE PAGE, so the sub-line, the consequence Notice
    // and the tick label cannot promise three different outcomes. See the
    // comment above `violationConsequence`: this page has shipped the wrong one
    // in both directions before.
    //
    // AND IT IS `isAuto` ALONE. This read `cap > 0 || isAuto`, three lines
    // under a `cap` normalised to a minimum of 1 - so it was unconditionally
    // true and the `Tone.inert` branch below was dead. That cost nothing while
    // it only picked a tone, but the sub-line and the tick label are sentences:
    // under Log only they would have promised an auto-submit that never comes,
    // which is the exact failure `violation_notice_test.dart` was written for.
    // Log only never ends a sitting, whatever the cap says (A-074).
    //
    // AI proctoring counts apart, against its own action (R5): either kind
    // under Auto-submit can end the exam.
    final bool aiEnds =
        asm.rules[ProctorRule.aiProctor] && asm.aiViolationAction.isAuto;
    final bool ends = asm.violationAction.isAuto || aiEnds;

    // WHO IS SITTING THIS, from the first source that has an answer.
    //
    // The roster first, for the admin preview and the seed fixtures. Then the
    // signed-in identity, which is the ONLY source a candidate has: `people` is
    // filled by the admin attempts load alone and `ev.employeeId` is empty on a
    // row that came from `/me/assessments`, so the `personById` this page used
    // to name the candidate with resolved to null for every real candidate and
    // the consent line read "the invited candidate" to all of them.
    //
    // `asm.watermarkLabel` already carries "name  email" and is deliberately
    // NOT used here: the server only builds it when `rule_watermark` is on, so
    // it is empty on most assessments.
    final Person? me = widget.store.personById(ev.employeeId);
    final String whoName = (me?.name ?? '').trim().isNotEmpty
        ? me!.name.trim()
        : widget.store.meName.trim();
    final String whoEmail = (me?.email ?? '').trim().isNotEmpty
        ? me!.email.trim()
        : widget.store.meEmail.trim();
    // Joined rather than concatenated, so one missing half cannot leave a
    // dangling separator on the page.
    final String identity = <String>[
      if (whoName.isNotEmpty) whoName,
      if (whoEmail.isNotEmpty) whoEmail,
    ].join('  -  ');

    return Scaffold(
      backgroundColor: t.bgSubtle,
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // SIZES ON THIS PAGE ARE LITERAL, NOT ZOOMED.
                //
                // This page was wrapped in a `_Zoom(scale: 1.10)`. The ack row,
                // the two buttons and the KPI strip were asked back to 100% and
                // three text elements were given their own multipliers, which a
                // single page-wide factor cannot express - so the wrapper is
                // gone and every size here is stated outright:
                //
                //   * elements nobody asked to change keep the size they
                //     RENDERED at under the zoom (title 24 -> 26, rule rows
                //     14 -> 15.5), so removing the wrapper is not a 9% shrink
                //     that was never requested;
                //   * the ack row, the `Btn`s and the `KpiStrip` take their own
                //     token sizes, which IS 100%;
                //   * the three named elements take rendered x their multiplier.
                Text(
                  asm.name,
                  style: context.type.pageTitle.copyWith(fontSize: 26),
                ),
                const SizedBox(height: 5),
                Text(
                  // A REQUEST TO READ BECAME A STATEMENT OF STAKE. "Read this
                  // before you begin." asks for attention without saying what
                  // it is worth.
                  ends
                      ? 'Follow these rules or your exam may end early.'
                      : 'Follow these rules. Violations are recorded for your '
                            'reviewer.',
                  // 17.1 = 18 x 0.95. The 18 was 13 x 1.10 rendered x 1.25;
                  // this trims 5% off that. Still the heaviest non-title line on
                  // the page, which is the point - it is the sentence saying
                  // what the rules below are worth.
                  //
                  // COLOURED THROUGH A TONE, NOT A LITERAL, so it resolves in
                  // BOTH modes off one line: `infoText` is #1D4ED8 on light
                  // (6.4:1 against `bgSubtle`) and #84AEF9 on dark (8.9:1) -
                  // both past WCAG AA. A hardcoded hex would have to be picked
                  // for one mode and would fail in the other.
                  //
                  // AND IT STAYS AMBER WHEN IT IS ACTUALLY A WARNING. Under
                  // auto-submit the exam really can end, so `warn` is the
                  // truthful tone there; under Log only it cannot, and amber
                  // would overstate it - so that branch takes `info`, which is
                  // what the sentence is. Not `dest`: the tone rule in
                  // `marks.dart` reserves red for failure or absence and
                  // nothing has failed. Not `primary` either - magenta is
                  // CTA-only, and the CTA is the Start button.
                  style: context.type.pageSub.copyWith(
                    fontSize: 17.1,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                    color: ToneColors.of(t, ends ? Tone.warn : Tone.info).fg,
                  ),
                ),
                // WHOSE SITTING THIS IS. Attribution, not instruction, so it
                // is quieter than the line above it and is not a sentence.
                //
                // The eyebrow STYLE, not the `Eyebrow` widget: that widget
                // uppercases, and an uppercased email reads as a different
                // address. Not a `Kpi` either - the strip is four fixed
                // 100px-tall tiles clipped to one line, and an email would
                // ellipsize.
                if (identity.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 7),
                  Text(
                    identity,
                    // +30%: 11 x 1.10 rendered = 12.1, x 1.30 = 15.5.
                    //
                    // `letterSpacing` drops from the eyebrow's 0.66 to 0.1.
                    // That tracking is sized for an 11px uppercase label;
                    // carried to 15.5px it spaces an email out until it reads
                    // as two words rather than one address.
                    //
                    // `ok`, THROUGH THE TONE, so one line covers both modes:
                    // `successText` is #047857 on light (5.2:1 against
                    // `bgSubtle`) and #4ADE80 on dark (11.4:1) - both past
                    // WCAG AA, which neither `textMuted` nor a hardcoded hex
                    // manages in both.
                    //
                    // GREEN BECAUSE THIS LINE IS A CONFIRMATION, not a warning.
                    // It names who the sitting is filed against, and the
                    // consent sentence further down asks the reader to confirm
                    // they are that person - so a verified-identity green is
                    // what it means. It also has to differ from the blue
                    // immediately above it, which was the ask; `warn` would
                    // read as a third alert and `dest` is reserved for failure.
                    style: context.type.eyebrow.copyWith(
                      fontSize: 15.5,
                      letterSpacing: 0.1,
                      fontWeight: FontWeight.w700,
                      color: ToneColors.of(t, Tone.ok).fg,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                KpiStrip(<Widget>[
                  // ONLY TIME IS TONED: it is the number that runs out. The
                  // pass mark is not shown to candidates at all (owner,
                  // 2026-09-29) - neither here nor in the invitation email.
                  Kpi(label: 'Questions', value: '$questionCount'),
                  Kpi(
                    label: 'Time',
                    value: '${asm.durationMinutes} min',
                    valueColor: ToneColors.of(t, Tone.warn).fg,
                  ),
                  const Kpi(label: 'Attempts', value: '1'),
                ]),
                Panel(
                  // "What Is Monitored" named the observer. "Rules" names what
                  // binds the reader.
                  title: 'Rules',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    // `spacing`, not `SizedBox`es: two children below are
                    // conditional, and manual spacers leave orphan gaps on a
                    // page that drops one.
                    spacing: 14,
                    children: <Widget>[
                      // ONE RULE PER LINE. This was an `AutoGrid(minWidth: 260)`
                      // - three across on a desktop, which is shorter but reads
                      // as a word cloud. Somebody skimming six prohibitions
                      // scans DOWN a column; across rows they lose their place.
                      // The height that costs is bought back by tightening the
                      // rows, not by a second column.
                      // 6 -> 12, and `_RuleLine` adds 3px of its own padding
                      // top and bottom, so the rows sit ~18px apart instead of
                      // 6. Six 15.5px lines 6px apart read as one paragraph of
                      // run-together text - the ask is for six separate rules,
                      // and the gap is what separates them.
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 12,
                        children: <Widget>[
                          for (final ProctorRule r in enforced) _RuleLine(r),
                        ],
                      ),
                      // ONLY UNDER AUTO-SUBMIT. The other branch printed
                      // `violationConsequence`'s "The exam is never ended
                      // automatically." - a THIRD statement of what the
                      // sub-line ("Violations are recorded for your reviewer.")
                      // and the tick label already say, and the sentence this
                      // surface was asked to stop showing. The function keeps
                      // it for the two admin surfaces that read it; see
                      // `config_tab_violation_policy_test.dart`.
                      if (asm.violationAction.isAuto)
                        Builder(
                          builder: (BuildContext context) {
                            final ({String strong, String text}) c =
                                violationConsequence(
                                  asm.violationAction,
                                  cap,
                                  candidate: true,
                                );
                            return Notice(
                              tone: Tone.warn,
                              strong: c.strong,
                              // The candidate reads the consequence, then what
                              // the record is for. The admin copy stops at the
                              // consequence.
                              text:
                                  '${c.text} Violations are recorded either '
                                  'way and passed to your reviewer.',
                            );
                          },
                        ),
                      // The AI count's own consequence, with its own cap.
                      if (aiEnds)
                        Builder(
                          builder: (BuildContext context) {
                            final ({String strong, String text}) c =
                                violationConsequence(
                                  asm.aiViolationAction,
                                  asm.aiMaxViolations > 0
                                      ? asm.aiMaxViolations
                                      : 1,
                                  candidate: true,
                                );
                            return Notice(
                              tone: Tone.warn,
                              strong: 'AI proctoring: ${c.strong}',
                              text:
                                  '${c.text} AI proctoring violations are '
                                  'counted apart from the others.',
                            );
                          },
                        ),
                      // The footnotes: true of the sitting, but nothing to
                      // obey. Kept out of the rule list so the deny marks all
                      // mean the same thing.
                      _Footnote(
                        <String>[
                          for (final ProctorRule r in passive)
                            r.candidateRule.text,
                          // Consent before the clock starts: the camera
                          // overlay that also says so only shows when the
                          // camera is OFF, which most candidates never see.
                          // Only when one WILL be kept (BR-D8): the server
                          // sends the upload policy only when storage is set
                          // up.
                          if (asm.rules[ProctorRule.aiProctor] &&
                              view?.evidenceUpload != null)
                            'Camera snapshots are saved at the start, every '
                                '2 minutes and when a rule is tripped.',
                          'Answers are saved as you move between questions.',
                        ].join(' '),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        // The name moved to the identity line under the title,
                        // where it is legible, so this points at it rather than
                        // interpolating a `personById` that was null for every
                        // candidate who ever read it.
                        identity.isEmpty
                            ? 'By starting you confirm you are the invited '
                                  'candidate and will work alone.'
                            : 'By starting you confirm you are the named '
                                  'candidate above and will work alone.',
                        // 13 x 1.10 rendered = 14.3. Not in the +% list, so it
                        // keeps the size it had rather than dropping to 13.
                        style: context.type.bodySecondary.copyWith(
                          fontSize: 14.3,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 14),
                      // PREVIEW MODE IS SAID OUT LOUD, AND START IS NOT OFFERED.
                      //
                      // The server has always sent `preview` on this payload and
                      // `ExamView.preview` has always parsed it - and nothing
                      // read it. So a staff member opening a candidate's token
                      // got the full consent page, a live-looking "Start
                      // Assessment" button, and a `wrong_candidate` refusal from
                      // `_write_guard` on pressing it. The QWeb runner showed a
                      // badge, said the timer would not start, and suppressed
                      // the form; this is that, in the app.
                      //
                      // The ack gate goes with it: there is nothing to consent
                      // to, because nothing will be recorded.
                      if (isPreview) ...<Widget>[
                        const Notice(
                          tone: Tone.info,
                          strong: 'Preview.',
                          text:
                              'You are looking at this exam as the candidate '
                              'will see it. The timer will not start, no '
                              'answers are saved, and nothing here reaches '
                              'their attempt.',
                        ),
                        const SizedBox(height: 14),
                        Btn(
                          'Back',
                          size: BtnSize.lg,
                          onPressed: () => context.nav.back(),
                        ),
                      ] else ...<Widget>[
                        // THE GATE. `AckBox` rather than a checkbox built here:
                        // it carries `Semantics(checked:)` and a
                        // `FocusableActionDetector`, so this is reachable by Tab
                        // and toggled by Space. A candidate who cannot use a
                        // mouse must still be able to start their exam.
                        //
                        // AT 100%, PER THE ASK: no `fontSize` override, so it
                        // takes `AckBox`'s own token size.
                        AckBox(
                          checked: _acked,
                          label: ends
                              ? 'I have read the rules and understand my exam '
                                    'can end if I break them.'
                              : 'I have read the rules and understand that '
                                    'violations are recorded.',
                          onToggle: _toggleAck,
                        ),
                        const SizedBox(height: 14),
                        // BOTH BUTTONS AT 100%, PER THE ASK - `BtnSize.lg` is
                        // `Btn`'s own 38px height and 14px label, unscaled.
                        Row(
                          children: <Widget>[
                            // A null callback is all the disabling needed:
                            // `Btn.enabled` is already `onPressed != null &&
                            // !busy`, and greys itself off it.
                            Btn.primary(
                              'Start Assessment',
                              size: BtnSize.lg,
                              onPressed: _acked ? widget.onBegin : null,
                              tooltip: _acked
                                  ? null
                                  : 'Tick the box above to start.',
                            ),
                            const SizedBox(width: 8),
                            Btn(
                              'Not Now',
                              size: BtnSize.lg,
                              onPressed: () =>
                                  context.nav.reset(const MyAssessments()),
                            ),
                          ],
                        ),
                      ],
                    ],
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

/// One rule, one line, on the instructions page.
///
/// The glyph is the grouping. This was a grey `check_circle_outline` in
/// `textMuted` - the mark a UI uses for "done" or "included", set over a list
/// of things not to do, so the panel scanned as reassurance. A deny mark in
/// `warn` scans as a prohibition set at a glance, which is the only reading a
/// candidate skimming before a timed exam will get.
///
/// `warn` and not `bad`: the tone rule in `marks.dart` reserves red for failure
/// or absence, and nothing has failed yet. Not `primary` either - that is the
/// CTA colour, and the CTA is the Start button. The TEXT stays `textPrimary`;
/// six coloured lines is a wall, and the icon already carries the tone.
///
/// TWO TONES, ON A SPLIT THAT ALREADY EXISTS. `candidateRule.prohibition` is
/// what picks the glyph, so it picks the colour with it: amber `block` for the
/// four things not to do, green `check_circle` for the states to hold (stay in
/// fullscreen, keep your camera on). Those two are not prohibitions and were
/// never violations of the same kind - marking them with the deny colour made
/// the page read as six identical warnings. The glyph sits in a tinted disc so
/// the column of marks is legible down the left edge without colouring text.
class _RuleLine extends StatelessWidget {
  final ProctorRule rule;

  const _RuleLine(this.rule);

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final ({String text, bool prohibition}) r = rule.candidateRule;
    final ToneColors c = ToneColors.of(t, r.prohibition ? Tone.warn : Tone.ok);
    return Padding(
      // The row's own breathing space, so the gap survives a rule that wraps to
      // two lines - a `spacing:` between siblings does not.
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // A 24px tinted disc, not a bare glyph. It gives the mark a
          // consistent optical width whichever icon it holds, and the tint is
          // what makes the left edge scannable at a glance.
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.bg,
              shape: BoxShape.circle,
              border: Border.all(color: c.fg.o(.32)),
            ),
            child: Icon(
              r.prohibition ? Icons.block : Icons.check_rounded,
              size: 14,
              color: c.fg,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Padding(
              // Optical centring against the 24px disc.
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                r.text,
                // 15.5 = the 14 these rows RENDERED at under the removed page
                // zoom (14 x 1.10). `height: 1.4` and not `body`'s 1.45: these
                // are one-line rows, and the gap between rows now does the work
                // the leading was doing.
                style: context.type.body.copyWith(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A muted line for what is true of the sitting but carries no instruction.
///
/// Set on an `info`-tinted strip. It is the one block on the page that is
/// neither a rule nor a consequence, and undifferentiated grey text directly
/// under six rule rows was being read as a seventh rule.
class _Footnote extends StatelessWidget {
  final String text;

  const _Footnote(this.text);

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final ToneColors c = ToneColors.of(t, Tone.info);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.bg.o(.5),
        borderRadius: Radii.card,
        border: Border.all(color: c.fg.o(.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.info_outline, size: 15, color: c.fg),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              // +20%: `tiny` is 12, x 1.10 rendered = 13.2, x 1.20 = 15.8. It
              // carries "Your name and email are shown on screen." - the one
              // fact here a candidate is surprised by, so it stops being fine
              // print. `textSecondary`, not `tiny`'s muted grey, which is
              // unreadable at any size on the tint.
              style: context.type.tiny.copyWith(
                fontSize: 15.8,
                height: 1.45,
                color: t.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A question's help/description text, with any public video link inside it
/// (YouTube, Vimeo, ...) made tappable.
///
/// Tapping opens the video in an in-app popup instead of `window.open`ing a
/// new tab, which would carry the candidate off the test screen mid-attempt -
/// answering the video is the point, not leaving to watch it elsewhere.
/// A non-video URL is left as plain text: this widget only ever changes what
/// happens for a link the app can actually embed.
class _HelpText extends StatefulWidget {
  const _HelpText(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_HelpText> createState() => _HelpTextState();
}

class _HelpTextState extends State<_HelpText> {
  static final RegExp _urlPattern = RegExp(r'https?://[^\s]+');
  static final RegExp _urlTrailingPunct = RegExp(r'[.,;:!?)\]}]+$');

  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final TapGestureRecognizer r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final TapGestureRecognizer r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final AppTokens t = context.tokens;
    final String text = widget.text;
    final Iterable<RegExpMatch> matches = _urlPattern.allMatches(text);
    if (matches.isEmpty) return Text(text, style: widget.style);

    final List<InlineSpan> spans = <InlineSpan>[];
    int cursor = 0;
    bool foundVideo = false;
    for (final RegExpMatch m in matches) {
      String url = m.group(0)!;
      // Trailing punctuation off the match reads as prose ("see
      // https://x.com."), not part of the address - strip it back onto the
      // plain-text side before resolving what the link even is.
      final RegExpMatch? trail = _urlTrailingPunct.firstMatch(url);
      final String tail = trail?.group(0) ?? '';
      if (tail.isNotEmpty) url = url.substring(0, url.length - tail.length);

      final ({String kind, String id})? embed = publicVideoEmbedRef(url);
      if (embed == null) {
        // Not a link this app can embed - leave it as plain, unclickable
        // text rather than opening ANY link in-app (a support/reference URL
        // is not the thing this popup exists for).
        continue;
      }
      foundVideo = true;

      if (m.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, m.start)));
      }
      final TapGestureRecognizer recognizer = TapGestureRecognizer()
        ..onTap = () => _openVideoPopup(context, url);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: url,
          style: widget.style.copyWith(
            color: t.primary,
            decoration: TextDecoration.underline,
          ),
          recognizer: recognizer,
        ),
      );
      if (tail.isNotEmpty) spans.add(TextSpan(text: tail));
      cursor = m.end;
    }
    if (!foundVideo) return Text(text, style: widget.style);
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}

void _openVideoPopup(BuildContext context, String url) {
  showDialog<void>(
    context: context,
    barrierColor: const Color(0xEB0F0B13),
    builder: (BuildContext ctx) => _HelpVideoPopup(url: url),
  );
}

class _HelpVideoPopup extends StatelessWidget {
  const _HelpVideoPopup({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Dialog.fullscreen(
      backgroundColor: const Color(0x00000000),
      child: Stack(
        children: <Widget>[
          // The backdrop closes; the player does not - a tap meant for the
          // player's own controls must not also dismiss it.
          Positioned.fill(
            child: GestureDetector(
              onTap: () => popIfCurrent(context),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * .86,
                maxHeight: MediaQuery.of(context).size.height * .78,
              ),
              child: GestureDetector(
                onTap: () {}, // absorb - see the backdrop comment above
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: Radii.card,
                    child: VideoPlate(
                      asset: Asset(
                        id: 'help-video',
                        label: 'Video',
                        url: url,
                        slot: 'main',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 16,
            right: 16,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => popIfCurrent(context),
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 11),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: t.bgApp,
                    borderRadius: Radii.button,
                    border: Border.all(color: t.border),
                  ),
                  child: Text('Close', style: context.type.button),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Text(
              'Esc to close',
              textAlign: TextAlign.center,
              style: context.type.small.copyWith(color: t.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// One question, with its answer layout.
///
/// Takes the QUESTION, not an index into a list. Against a live server the
/// runner is handed one question at a time by `/exam/<token>/state` and
/// `/exam/<token>/answer`; there has never been a list to index into, which is
/// why this screen used to render "This assessment has no questions" for every
/// real candidate. [number] and [total] are the server's own, so the footer
/// knows it is on the last question without counting anything itself.
class _QuestionPage extends StatelessWidget {
  final AppStore store;
  final Attempt ev;
  final Assessment asm;
  final Question q;
  final int number;
  final int total;

  /// Save the current answer and move. `next` | `prev` | `review`. Live, this
  /// is a server round trip whose response IS the next question.
  final Future<void> Function(String nav) onNav;

  const _QuestionPage({
    required this.store,
    required this.ev,
    required this.asm,
    required this.q,
    required this.number,
    required this.total,
    required this.onNav,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;

    // One notice per kind, each against its own pair (R5): "AI proctoring
    // violation 2 of 5" beside the regular count.
    List<Widget> violationNotice(bool ai) {
      final ({ViolationAction action, int cap}) p = asm.policy(ai);
      final int cap = p.cap > 0 ? p.cap : 1;
      final int n = ev.countOf(ai);
      final String kind = ai ? 'AI proctoring' : 'proctoring';
      // Log only past its cap (A-074): said once, plainly, and announced -
      // the exam goes on, so this replaces the per-violation line. Not
      // Auto-submit, which ends the exam there instead.
      if (!p.action.isAuto &&
          (ai ? ev.aiLimitBreached(asm) : ev.limitBreached(asm))) {
        return <Widget>[
          Semantics(
            liveRegion: true,
            child: Notice(
              tone: Tone.warn,
              strong: ai
                  ? 'You have reached the AI proctoring violation limit '
                        '(${p.cap}).'
                  : 'You have reached the violation limit (${p.cap}).',
              text:
                  'The exam continues, and your violations are reported to '
                  'the organiser.',
            ),
          ),
          const SizedBox(height: 16),
        ];
      }
      if (n == 0) return const <Widget>[];
      return <Widget>[
        Notice(
          tone: Tone.warn,
          // "Noted" until the server has the report (RT-2): offline, it is
          // only on this device.
          strong: p.action.isAuto
              ? 'Warning: $kind violation $n of $cap.'
              : store.violationReportsUnsent(ev.token)
              ? '${ai ? 'AI proctoring' : 'Proctoring'} violation noted ($n).'
              : '${ai ? 'AI proctoring' : 'Proctoring'} violation recorded '
                    '($n).',
          text: p.action.isAuto
              ? 'Your exam auto-submits at $cap.'
              : 'This assessment does not auto-submit - the record is passed '
                    'to your reviewer.',
        ),
        const SizedBox(height: 16),
      ];
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ...violationNotice(false),
        ...violationNotice(true),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
          decoration: BoxDecoration(
            color: t.bgApp,
            borderRadius: Radii.sheet,
            border: Border.all(color: t.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // THE SECTION THE EXAMINER AUTHORED THIS UNDER, when there is
              // one. Sections already decided the order questions arrive in
              // (`preserve_question_order`), but nothing ever told the
              // CANDIDATE a section existed - so a paper deliberately grouped
              // into "Before you start" / "On the floor" / "Escalation"
              // arrived as one flat run, and the grouping was invisible to the
              // only person it was for.
              //
              // Shown on EVERY question rather than only when it changes,
              // because the runner serves one question at a time: there is no
              // preceding question on screen to have carried the heading, so a
              // "changed" rule would leave most screens with no context at all.
              // A scrolling multi-question view would want the opposite.
              //
              // Empty for anything not authored in Form Studio, which renders
              // no heading rather than an invented one.
              if (q.sectionTitle.trim().isNotEmpty) ...<Widget>[
                Text(
                  q.sectionTitle.trim(),
                  style: context.type.tiny.copyWith(
                    fontWeight: FontWeight.w700,
                    color: t.textMuted,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Eyebrow('Question $number'),
              const SizedBox(height: 8),
              Text(q.prompt, style: context.type.questionPrompt),
              // `questionDesc`, not `q.desc`: a scale's "Scale: 1 = Unsure,
              // 5 = Certain" legend exists because the old boxed control had
              // nowhere to put the ends of the range. The scale draws them now,
              // so printing the line too would repeat both words directly above
              // themselves.
              if (questionDesc(q).isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                _HelpText(questionDesc(q), style: context.type.questionDesc),
              ],
              const SizedBox(height: 20),
              // KEYED BY QUESTION. Moving between questions rebuilds this same
              // widget type at this same position, so without a key Flutter
              // REUSES the State - and the answer editors own their text
              // controllers. Question 2 opened showing question 1's prose,
              // and because `_write` saves against the CURRENT question id,
              // typing one character then stored question 1's answer as
              // question 2's. Free navigation makes that reachable constantly,
              // so the key is not a tidy-up: it is what makes moving safe.
              AnswerArea(
                key: ValueKey<String>(q.id),
                store: store,
                ev: ev,
                q: q,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The question navigation, pinned under the scroll area by `_buildChrome`.
///
/// SPLIT OUT OF [_QuestionPage] so it can live OUTSIDE the scroll view. As the
/// last child of the scrolling column its position tracked the height of the
/// current question, so Next sat near the top of the screen on a short MCQ and
/// two hundred pixels lower on the next question's prose - the candidate had to
/// re-find the primary action on every screen of the paper.
class _QuestionNav extends StatelessWidget {
  final int number;
  final int total;
  final Future<void> Function(String nav) onNav;

  const _QuestionNav({
    required this.number,
    required this.total,
    required this.onNav,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      // Movement is unconditional. Both arrows save first WHEN there is
      // something to save and simply move when there is not, so a candidate is
      // never held on a question by the state of its answer - which is what
      // the old "Save & next" did whenever the box was empty.
      Btn(
        'Previous',
        icon: Icons.arrow_back,
        onPressed: number > 1 ? () => onNav('prev') : null,
      ),
      const Spacer(),
      // The jump-ahead, offered only while there is somewhere ahead to jump to
      // - on the last question the primary already says it.
      if (number < total) ...<Widget>[
        Btn('Review & Submit', onPressed: () => onNav('review')),
        const SizedBox(width: 8),
      ],
      Btn.primary(
        number >= total ? 'Review & Submit' : 'Next',
        trailingIcon: number >= total ? null : Icons.arrow_forward,
        onPressed: () => onNav(number >= total ? 'review' : 'next'),
      ),
    ],
  );
}

/// The height of the pinned question footer: 12 + a 32 px [Btn] + 12, and its
/// 1 px top border. Toasts are lifted clear of it ([ToastLayer.lift]).
const double kExamFooterHeight = 57;

/// The last look before submitting.
class _Review extends StatelessWidget {
  final AppStore store;
  final Attempt ev;
  final Assessment asm;

  /// [force] says the candidate was shown the gaps and chose to submit over
  /// them. Without it the request cannot be told apart from an accidental
  /// Submit, and the module refuses both.
  final void Function({bool auto, bool force}) onFinish;

  const _Review({
    required this.store,
    required this.ev,
    required this.asm,
    required this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    // Live, the checklist comes from `/exam/<token>/review`; `asm.questions` is
    // empty on a real exam. The server's rows carry no correctness - that is
    // deliberate, and it is what stops the answer key reaching a candidate who
    // has not submitted yet.
    final List<ExamReviewRow> rows =
        store.examReviewByToken[ev.token] ??
        <ExamReviewRow>[
          for (int i = 0; i < asm.questions.length; i++)
            ExamReviewRow(
              index: i + 1,
              questionId: asm.questions[i].id,
              name: asm.questions[i].name,
              answered: ev.resp[asm.questions[i].id]?.hasInput ?? false,
            ),
        ];
    final int total = rows.length;
    // The Submit in flight. The sitting stays open until the server takes it.
    final bool submitting = store.isBusy('submit:${ev.id}');
    // A grid ticked on one row of three is "answered" to the server; here it
    // is partly answered, and named before Submit. The server's own blank-row
    // count first, which survives a reload; else the rows of the questions
    // this session answered.
    String? partlyLine(ExamReviewRow r) {
      if (!r.answered) return null;
      final ({int missing, int rows}) local =
          (store.answeredQuestions[r.questionId] ??
                  asm.questionById(r.questionId))
              ?.blankRows(ev.resp[r.questionId]) ??
          (missing: 0, rows: 0);
      final int m = r.rowsUnanswered >= 0 ? r.rowsUnanswered : local.missing;
      if (m <= 0) return null;
      return local.rows > 0
          ? 'Q${r.index} - $m of ${local.rows} rows unanswered'
          : 'Q${r.index} - $m ${m == 1 ? 'row' : 'rows'} unanswered';
    }

    final Map<int, String> partly = <int, String>{
      for (final ExamReviewRow r in rows)
        if (partlyLine(r) case final String line) r.index: line,
    };
    // ONE RULE FOR "ANSWERED", shared with the top bar: a question holding
    // an answer, whole or partial. Partly answered is counted inside it.
    final int answered = rows.where((ExamReviewRow r) => r.answered).length;
    final int missing = total - answered;
    String qs(int n) => n == 1 ? '1 question is' : '$n questions are';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Notice(
          tone: missing + partly.length > 0 ? Tone.warn : Tone.ok,
          strong: switch ((missing, partly.length)) {
            (0, 0) => 'Every question has an answer.',
            (0, final int p) => '${qs(p)} partly answered.',
            (final int m, 0) => '${qs(m)} unanswered.',
            (final int m, final int p) =>
              '${qs(m)} unanswered and $p partly answered.',
          },
          text: missing + partly.length > 0
              ? 'You can still go back to them. An unanswered question scores '
                    'nothing - it is not penalised beyond that.'
              : 'Submit when you are ready. You cannot change an answer after '
                    'submitting.',
        ),
        const SizedBox(height: 16),
        Panel(
          title: 'Your Answers',
          note: partly.isEmpty
              ? '$answered of $total answered'
              : '$answered of $total answered, ${partly.length} partly',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // Out of reach while submitting, as Back to Questions is: on
              // main a later write wins, so an edit made now could be
              // overwritten by the submit's own re-send, or refused.
              IgnorePointer(
                ignoring: submitting,
                child: AutoGrid(
                  minWidth: 52,
                  gap: 7,
                  children: <Widget>[
                    for (final ExamReviewRow r in rows)
                      _MatrixCell(
                        number: r.index,
                        answered: r.answered,
                        partly: partly.containsKey(r.index),
                        // FETCH, then navigate. The route only says "a question
                        // screen"; WHICH question comes from the runner's
                        // envelope, so jumping by route alone landed on
                        // whichever question was already loaded - every cell in
                        // the matrix opened the same one.
                        onTap: () async {
                          await store.loadExamQuestion(ev.token, r.index);
                          if (context.mounted) {
                            context.nav.examQuestion(ev.token, r.index);
                          }
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              // A Wrap, so three entries still fit a phone.
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: <Widget>[
                  _Legend(
                    color: t.successBg,
                    border: t.successText.o(.4),
                    label: 'Answered',
                  ),
                  _Legend(
                    color: t.infoBg,
                    border: t.infoText.o(.45),
                    label: 'Partly answered',
                  ),
                  _Legend(
                    color: t.warnBg,
                    border: t.warnText.o(.45),
                    label: 'Not answered',
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Btn(
              'Back to Questions',
              // Not while submitting: the paper going out is the one on this
              // page, and an edit made now would be left behind (BR-D1).
              onPressed: submitting
                  ? null
                  : () async {
                      await store.loadExamQuestion(ev.token, 1);
                      if (context.mounted) {
                        context.nav.examQuestion(ev.token, 1);
                      }
                    },
            ),
            const Spacer(),
            Btn.primary(
              submitting ? 'Submitting...' : 'Submit Assessment',
              size: BtnSize.lg,
              // Inert while the submit is in flight (A-052); `finishExam`
              // refuses a second call either way.
              busy: submitting,
              // A last, NAMED warning: submitting is irreversible and the
              // matrix above may be scrolled past, so the blank questions are
              // listed by number in a dialog that cannot be missed.
              onPressed: () async {
                final List<int> gaps = rows
                    .where((ExamReviewRow r) => !r.answered)
                    .map((ExamReviewRow r) => r.index)
                    .toList();
                if (gaps.isNotEmpty || partly.isNotEmpty) {
                  final bool? go = await _confirmSubmit(
                    context,
                    gaps,
                    partly.values.toList(),
                  );
                  if (go != true) return;
                }
                // CARRY THE ANSWER, do not just act on it. This said
                // `onFinish()`, so the decision the dialog had just collected
                // died here and the request went out indistinguishable from an
                // accidental Submit - which the module refuses, by design.
                onFinish(force: gaps.isNotEmpty);
              },
            ),
          ],
        ),
      ],
    );
  }

  /// Names the gaps before the irreversible step: the unanswered questions by
  /// number, then each partly answered one with its blank rows.
  Future<bool?> _confirmSubmit(
    BuildContext context,
    List<int> gaps,
    List<String> partly,
  ) => showSheet<bool>(
    context,
    title: partly.isEmpty
        ? 'Submit with ${gaps.length} unanswered?'
        : 'Submit with ${gaps.length + partly.length} incomplete?',
    sub: 'You cannot change anything after this.',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (gaps.isNotEmpty)
          Text(
            gaps.length == 1
                ? 'Question ${gaps.single} has no answer.'
                : 'These questions have no answer: '
                      '${gaps.join(', ')}.',
            style: context.type.body.copyWith(height: 1.55),
          ),
        for (final String p in partly)
          Text('$p.', style: context.type.body.copyWith(height: 1.55)),
        const SizedBox(height: 10),
        Text(
          'An unanswered question scores nothing. It is not penalised beyond '
          'that, so submitting is a valid choice - but going back costs you '
          'only the time you have left.',
          style: context.type.bodySecondary.copyWith(height: 1.55),
        ),
      ],
    ),
    actions: <Widget>[
      Btn(
        'Go Back and Answer',
        size: BtnSize.lg,
        onPressed: () => Navigator.of(context).pop(false),
      ),
      Btn.primary(
        'Submit Anyway',
        size: BtnSize.lg,
        onPressed: () => Navigator.of(context).pop(true),
      ),
    ],
  );
}

/// `.mcell` - one cell in the answered/not-answered matrix. Skipped is AMBER,
/// never red, since skipping is not yet a failure; partly answered is BLUE.
class _MatrixCell extends StatefulWidget {
  final int number;
  final bool answered;
  final bool partly;
  final VoidCallback onTap;

  const _MatrixCell({
    required this.number,
    required this.answered,
    required this.onTap,
    this.partly = false,
  });

  @override
  State<_MatrixCell> createState() => _MatrixCellState();
}

class _MatrixCellState extends State<_MatrixCell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final (Color bg, Color fg, Color border) = widget.partly
        ? (t.infoBg, t.infoText, t.infoText.o(.45))
        : widget.answered
        ? (t.successBg, t.successText, t.successText.o(.4))
        : (t.warnBg, t.warnText, t.warnText.o(.45));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: const BorderRadius.all(Radius.circular(9)),
            border: Border.all(
              width: 1.5,
              color: _hover ? t.borderHover : border,
            ),
          ),
          child: Text(
            '${widget.number}',
            style: context.type.mono.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final Color border;
  final String label;

  const _Legend({
    required this.color,
    required this.border,
    required this.label,
  });

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          borderRadius: const BorderRadius.all(Radius.circular(3)),
          border: Border.all(color: border),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: context.type.small),
    ],
  );
}

/// Confirms submission, and shows the score ONLY if released.
class _Complete extends StatelessWidget {
  final AppStore store;
  final Attempt ev;
  final Assessment asm;

  const _Complete({required this.store, required this.ev, required this.asm});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    // The SERVER's verdict. `result(asm)` recomputes against
    // `asm.passThreshold`, and the assessment the exam gate sends a candidate
    // is a brief - so on this screen the recomputation was always judging a
    // released result against a default bar rather than the real one.
    final ResultState result = ev.verdict(asm);
    // The change flushed as proctoring ended the sitting was not kept.
    final String kept = store.unsavedAtEnd.contains(ev.id)
        ? 'Your last change may not count; your other answers were kept as '
              'they stood.'
        : 'Your answers were kept as they stood.';
    final String quitUrl = store.examView(ev.token)?.seb.quitUrl ?? '';
    // Which count ended it (R5): the AI one names AI proctoring and its cap.
    final bool aiEnded = ev.autoSubmitReason == 'ai_violation';
    final String endedKind = aiEnded ? 'AI proctoring' : 'proctoring';
    final int endedCount = ev.countOf(aiEnded);
    return Scaffold(
      backgroundColor: t.bgSubtle,
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 54,
                    height: 54,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: t.successBg,
                      borderRadius: const BorderRadius.all(Radius.circular(14)),
                    ),
                    child: Icon(Icons.check, size: 26, color: t.successText),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Assessment submitted',
                  textAlign: TextAlign.center,
                  style: context.type.pageTitle,
                ),
                const SizedBox(height: 6),
                Text(
                  'Your answers are recorded. There is nothing more to do.',
                  textAlign: TextAlign.center,
                  style: context.type.pageSub,
                ),
                if (timeUsed(ev, asm) case final String used) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    'Time used: $used',
                    textAlign: TextAlign.center,
                    style: context.type.bodyMuted,
                  ),
                ],
                const SizedBox(height: 20),
                // NAME THE CAUSE, never "proctoring or time": the module says
                // which, and a candidate whose exam was cut short by
                // proctoring is entitled to be told that plainly, because it
                // is the fact they would appeal.
                if (ev.autoSubmitted) ...<Widget>[
                  Notice(
                    tone: Tone.warn,
                    strong: switch (ev.autoSubmitReason) {
                      'violation' =>
                        'Auto-submitted: proctoring violation limit reached.',
                      'ai_violation' =>
                        'Auto-submitted: AI proctoring violation limit '
                            'reached.',
                      'expired' => 'Ended on the clock.',
                      _ => 'This attempt was submitted automatically.',
                    },
                    // The cap is the violation the exam ENDS at, as the
                    // runner says ("auto-submits at 2"), not an allowance:
                    // "allowed 2 and 2 were recorded" read as if the exam
                    // ended inside its limit. A cap of 0 ends on the first.
                    // Both counts are agreed with their verb: at a cap of 1
                    // this printed "1 were recorded".
                    text: switch ((
                      ev.autoSubmitReason,
                      asm.policy(aiEnded).cap,
                    )) {
                      ('violation' || 'ai_violation', 0) =>
                        'This sitting ended on the first $endedKind '
                            'violation. $kept',
                      ('violation' || 'ai_violation', final int cap) =>
                        'This sitting ends at $cap $endedKind '
                            '${cap == 1 ? 'violation' : 'violations'}, and '
                            '$endedCount '
                            '${endedCount == 1 ? 'was' : 'were'} '
                            'recorded, so the exam ended itself. $kept',
                      _ =>
                        'Your answers were kept as they stood. Questions you '
                            'did not reach are recorded as unanswered.',
                    },
                  ),
                  const SizedBox(height: 16),
                ],
                // The same fact the runner showed, kept on the record (A-074).
                // Under Auto-submit it is also why the exam ended.
                if (ev.limitBreached(asm)) ...<Widget>[
                  Notice(
                    tone: Tone.warn,
                    strong:
                        'You reached the violation limit '
                        '(${asm.violationLimit ?? asm.maxViolations}).',
                    text: asm.violationAction.isAuto
                        ? 'The exam ended there, and the attempt is marked '
                              'Violation Limit Breached for the organiser.'
                        : 'Your violations are reported to the organiser.',
                  ),
                  const SizedBox(height: 16),
                ],
                // The AI count, against its own limit (R5).
                if (ev.aiLimitBreached(asm)) ...<Widget>[
                  Notice(
                    tone: Tone.warn,
                    strong:
                        'You reached the AI proctoring violation limit '
                        '(${asm.aiViolationLimit ?? asm.aiMaxViolations}).',
                    text: asm.aiViolationAction.isAuto
                        ? 'The exam ended there, and the attempt is marked '
                              'Violation Limit Breached for the organiser.'
                        : 'Your violations are reported to the organiser.',
                  ),
                  const SizedBox(height: 16),
                ],
                // Invariant 3: no score is shown until a person releases it.
                if (!ev.resultsReleased)
                  const Notice(
                    tone: Tone.info,
                    strong: 'Awaiting results.',
                    text:
                        'Your marks are held until an administrator releases '
                        'them. You will see them here when they do.',
                  )
                else
                  Panel(
                    title: 'Your Result',
                    child: Builder(
                      builder: (BuildContext context) {
                        // PREFER the server's own marks.
                        //
                        // `earnedMarks(asm)` recounts from per-question
                        // responses, and `maxMarks(asm)` from the questions -
                        // neither of which a CANDIDATE ever loads, because
                        // both live on manager-only routes. Recounting
                        // therefore rendered "0 of 0" on the one screen a
                        // candidate actually reaches. `/exam/<token>/state`
                        // already sends the answer as `result.score_marks`.
                        //
                        // The fallback is `maxMarks`, not the question count:
                        // a question is worth its COMPONENT count now, so the
                        // count would put a candidate's own ring on a scale
                        // smaller than their score.
                        final int earned =
                            ev.serverEarned ?? ev.earnedMarks(asm);
                        final int total = ev.maxMarks(asm);
                        return Column(
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                ScoreRing(
                                  earned: earned,
                                  total: total,
                                  result: result,
                                ),
                                const SizedBox(width: 18),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Pill.state(result),
                                      const SizedBox(height: 8),
                                      Marks(earned, total, size: 17),
                                      const SizedBox(height: 8),
                                      ThresholdBar(
                                        earned: earned,
                                        total: total,
                                        threshold: ev.passMarkPercent(asm),
                                        result: result,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            // The grey "Pending" pill above says nothing about
                            // WHY. Written answers still in the grading queue
                            // mean the figure beside it is incomplete, and can
                            // only rise - which is not what a candidate reads
                            // into a pending mark on their own result.
                            if (ev.subjectivePending > 0) ...<Widget>[
                              const SizedBox(height: 12),
                              Text(
                                ev.pendingMarkingNote,
                                style: context.type.bodyMuted,
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    Btn(
                      'See My Answers',
                      onPressed: ev.resultsReleased
                          ? () => context.nav.examAnswers(ev.token)
                          : null,
                    ),
                    const Spacer(),
                    // Yantra: its worker goes back to Yantra, where the result
                    // and their next step are; this app's own list is not
                    // their home.
                    if (yantraReturnUrl() case final String yantra)
                      Btn.primary(
                        'Back to Yantra',
                        icon: Icons.arrow_back,
                        onPressed: () => navigateTo(yantra),
                      )
                    else
                      Btn.primary(
                        'Back to My Assessments',
                        onPressed: () =>
                            context.nav.reset(const MyAssessments()),
                      ),
                  ],
                ),
                // SEB locks the computer until it is told to quit: its quit
                // URL, from the envelope, closes it.
                if (insideSeb() && quitUrl.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Btn.primary(
                      'Exit Safe Exam Browser',
                      onPressed: () => navigateTo(quitUrl),
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

/// The candidate's own per-answer breakdown, after release.
///
/// It hydrates itself from `/exam/<token>/answers` rather than from the store's
/// entity tables. That route is scoped to the TOKEN, which is the only handle a
/// candidate has: they cannot load an Assessment record, so a review that
/// required one was unreachable for the only person it was written for.
class _AnswerReview extends StatefulWidget {
  final AppStore store;
  final String token;

  const _AnswerReview({required this.store, required this.token});

  @override
  State<_AnswerReview> createState() => _AnswerReviewState();
}

class _AnswerReviewState extends State<_AnswerReview> {
  /// Issued in initState, NOT in build. A future created inside build is a new
  /// future on every rebuild, so the screen would re-fetch on each frame and
  /// flash its loader between them.
  late final Future<AnswerSheet> _sheet = widget.store.answerSheet(
    widget.token,
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<AnswerSheet>(
    future: _sheet,
    builder: (BuildContext context, AsyncSnapshot<AnswerSheet> snap) {
      if (snap.connectionState != ConnectionState.done) {
        return _shell(context, const Center(child: Spinner(size: 22)));
      }

      if (snap.hasError) {
        // The attempt this screen was opened from already says whether the
        // result is out, so an unreleased sitting gets the gate that
        // explains it rather than an error about a refusal that was
        // correct. Anything else is reported in the server's own words:
        // claiming the link is dead would repeat the very bug this screen
        // exists to fix.
        final Attempt? ev = widget.store.attemptByToken(widget.token);
        if (ev != null && !ev.resultsReleased) {
          return const GateScreen(kind: GateKind.notReleased);
        }
        return _shell(
          context,
          EmptyState(
            icon: Icons.cloud_off_outlined,
            tone: Tone.bad,
            title: 'Your answers could not be loaded',
            body: '${snap.error}',
            compact: false,
            action: Btn.primary(
              'Back to My Assessments',
              onPressed: () => context.nav.reset(const MyAssessments()),
            ),
          ),
        );
      }

      final AnswerSheet sheet = snap.data ?? const AnswerSheet();

      // INVARIANT 3. An unreleased sheet gets the gate, not a page with
      // the numbers left out - the parser has already dropped every
      // scoring field, so there is nothing here to leak either way.
      if (!sheet.released) {
        return const GateScreen(kind: GateKind.notReleased);
      }

      return _shell(context, _body(context, sheet));
    },
  );

  /// The page frame, written once so the loading, failed and loaded states
  /// cannot drift apart.
  Widget _shell(BuildContext context, Widget child) => Scaffold(
    backgroundColor: context.tokens.bgSubtle,
    body: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: child,
        ),
      ),
    ),
  );

  Widget _body(BuildContext context, AnswerSheet sheet) {
    final AppTokens t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // A way back. This page had none: no breadcrumb, no back control, and
        // the browser's own button is not a route here - the only exit was the
        // sidebar, which reloads the section.
        Align(
          alignment: Alignment.centerLeft,
          child: Btn(
            'All My Assessments',
            size: BtnSize.sm,
            icon: Icons.arrow_back,
            onPressed: () => context.nav.reset(const MyAssessments()),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          sheet.assessmentName.isEmpty ? 'Assessment' : sheet.assessmentName,
          style: context.type.pageTitle,
        ),
        const SizedBox(height: 3),
        Text(
          'Your answers, question by question.',
          style: context.type.pageSub,
        ),
        const SizedBox(height: 16),
        KpiStrip(<Widget>[
          // Marks, never a percentage - and only from the server's own
          // figure, since a candidate cannot load the record to divide by.
          Kpi(
            label: 'Score',
            value: sheet.hasMarks ? '${sheet.earned} / ${sheet.total}' : '-',
          ),
          Kpi(
            label: 'Result',
            value: sheet.result.label,
            valueColor: switch (sheet.result) {
              ResultState.pass => t.successText,
              ResultState.fail => t.destText,
              ResultState.pending => null,
            },
          ),
          Kpi(
            label: 'Answered',
            value:
                '${sheet.rows.where((AnswerSheetRow r) => r.hasInput).length}',
            sub: 'of ${sheet.rows.length}',
          ),
          // The sheet carries no times; the attempt row does.
          if (widget.store.attemptByToken(widget.token) case final Attempt ev?)
            if (timeUsed(ev, widget.store.asmById(ev.assessmentId))
                case final String used)
              Kpi(
                label: 'Time used',
                value: used,
                word: true,
                sub: ev.endedOnClock ? 'Ended on the clock' : null,
              ),
          // WHERE THE MARKS CAME FROM, one KPI per section.
          //
          // The single "Score" figure above says a candidate got 6 of 10 and
          // nothing about which half they lost it on. The QWeb runner split this
          // out on its completion page and the API sent no equivalent, so this
          // was the one thing the server-rendered surface could tell a candidate
          // that the app could not. Structured from `candidate_result.breakdown`
          // rather than the server's HTML card - see [ResultSection].
          //
          // A section still being graded says so in its own sub-line, because
          // "2 of 3 passed" reads as final and is not while a judge is running.
          for (final ResultSection s in sheet.resultSections)
            Kpi(
              label: s.label,
              value: '${s.value} / ${s.total}',
              sub: s.pending > 0
                  ? '${s.unit}, ${s.pending} still grading'
                  : s.unit,
            ),
        ]),
        // PER-ASSESSMENT STRENGTHS AND WEAKNESSES, above the answers.
        //
        // The per-answer cards below carry the grader's feedback for each
        // question; this says what those answers add up to by SOP category, so
        // a candidate reads the shape first and the evidence for it underneath.
        //
        // Absent, not empty, when there is nothing to group: an unreleased sheet
        // has no grader scores (they are gated), and an untagged bank has no
        // categories. Either way a candidate cannot act on the reason, so the
        // panel simply is not drawn.
        if (categoryScores(answersOfSheet(sheet))
            case final List<CategoryScore> cats
            when cats.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          Panel(
            title: 'Strengths and Weaknesses',
            note: 'by SOP category, on this assessment',
            child: CategoryCard(
              scores: cats,
              // THE PASS MARK THIS ATTEMPT WAS ACTUALLY JUDGED AGAINST.
              //
              // This was a hardcoded 70 because the sheet did not carry the
              // figure - and the card PRINTS the number it colours against, so
              // a candidate sitting a 60% paper was told the bar was 70%. The
              // sheet carries it now; the literal only survives as the last
              // resort when an older server sends no threshold at all.
              threshold: sheet.passThreshold ?? 70,
              audience: CategoryAudience.candidate,
              showEnds: false,
            ),
          ),
          const SizedBox(height: 16),
        ],
        for (final AnswerSheetRow r in sheet.rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _AnswerCard(row: r),
          ),
        Row(
          children: <Widget>[
            Btn(
              'Back to My Assessments',
              onPressed: () => context.nav.reset(const MyAssessments()),
            ),
          ],
        ),
      ],
    );
  }
}

class _AnswerCard extends StatelessWidget {
  final AnswerSheetRow row;

  const _AnswerCard({required this.row});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool hasNotes =
        row.scoreVerdict.isNotEmpty ||
        row.feedback.isNotEmpty ||
        row.credit.isNotEmpty ||
        row.deductions.isNotEmpty;

    return Panel(
      title: 'Question ${row.number}',
      headActions: <Widget>[
        // The status is always a pill, and its wording and tone are both the
        // server's: a subjective answer awaiting a human reads "No Grade",
        // which is not a failure and must not be shown as one.
        if (!row.hasInput)
          const Pill('Not answered', Tone.inert)
        else
          Pill(
            row.verdict.isNotEmpty
                ? row.verdict
                // Released without the key (R6): the marks, not a verdict.
                : row.marksEarned != null
                ? '${_marks(row.marksEarned!)} / ${row.marksAvailable} marks'
                : 'Answered',
            row.tone,
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(row.prompt, style: context.type.body.copyWith(fontSize: 14)),
          const SizedBox(height: 12),
          // WHAT THE QUESTION WAS ASKING ABOUT, above the answer to it. The
          // same plates the exam rendered, off the same token-scoped URLs.
          // Without them an image_ab row read "Response A, Both Good" over
          // nothing, and a labelling row was a numbered list with no
          // screenshot - the answer sheet described a question it did not show.
          // A labelling row shows the MARKED plate, as the exam did: its
          // answers read "Box 3: ..." and need the numbered boxes to mean
          // anything. `question_media` withholds the marked plate for a
          // planted-defect question, so this cannot leak a key.
          if (row.hasMedia)
            ...mediaPlates(
              row.images,
              row.videos,
              showRegions: row.type == QType.imageLabel,
              sideFree: row.isSideFreeAb,
            ),
          if (!row.hasInput)
            Text(
              'You did not answer this question.',
              style: context.type.bodyMuted,
            )
          else ...<Widget>[
            const Eyebrow('Your answer'),
            const SizedBox(height: 5),
            Text(_answerText(), style: context.type.bodySecondary),
          ],
          // The key arrives for objective types only - a rubric's reference
          // answer stays inside the audit surface, so the server sends none.
          if (row.correct.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            const Eyebrow('Correct Answer'),
            const SizedBox(height: 5),
            Text(row.correct.join(', '), style: context.type.bodySecondary),
          ],
          if (hasNotes) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.bgMuted,
                borderRadius: Radii.option,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Eyebrow("The judge's verdict"),
                  const SizedBox(height: 5),
                  if (row.scoreVerdict.isNotEmpty) ...<Widget>[
                    Text(
                      row.scoreVerdict,
                      style: context.type.bodySecondary.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (row.feedback.isNotEmpty) const SizedBox(height: 6),
                  ],
                  if (row.feedback.isNotEmpty)
                    Text(row.feedback, style: context.type.bodySecondary),
                  for (final String c in row.credit) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      '+ $c',
                      style: context.type.small.copyWith(color: t.successText),
                    ),
                  ],
                  for (final String d in row.deductions) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      '- $d',
                      style: context.type.small.copyWith(color: t.destText),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 2.0 reads "2", 1.5 stays "1.5".
  static String _marks(double v) => '$v'.replaceFirst(RegExp(r'\.0$'), '');

  /// What the candidate put in. Options are already resolved to labels by the
  /// server, which is the only side that holds the option ids.
  ///
  /// A labelling answer arrives as a box->text map, not prose. It shares the
  /// `justification` column server-side, so before it was decoded this printed
  /// the candidate the raw JSON of their own answer. One line per box, in box
  /// order, numbered the way the boxes on the image are.
  String _answerText() {
    final List<MapEntry<int, String>> boxes = row.labelLines;
    if (boxes.isNotEmpty) {
      return boxes
          .map((MapEntry<int, String> e) => '${e.key}. ${e.value}')
          .join('\n');
    }
    if (row.chosen.isNotEmpty) return row.chosen.join(', ');
    final ClipAnswers? clip = row.clip;
    if (clip != null && !clip.transcribed) {
      return 'Not transcribed: ${clipCategoryLabel(clip.category)}';
    }
    return row.justification.isEmpty ? 'Left blank' : row.justification;
  }
}

/// `.ring` - the score ring. It draws the arc rather than printing a number in
/// a circle, so the proportion is readable at a glance.
class ScoreRing extends StatelessWidget {
  final int earned;
  final int total;
  final ResultState result;
  final double size;

  const ScoreRing({
    super.key,
    required this.earned,
    required this.total,
    required this.result,
    this.size = 92,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Color arc = switch (result) {
      ResultState.pass => t.successDot,
      ResultState.fail => t.destDot,
      ResultState.pending => t.textMuted,
    };
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: total == 0 ? 0 : earned / total,
              strokeWidth: 9,
              backgroundColor: t.bgMuted,
              valueColor: AlwaysStoppedAnimation<Color>(arc),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '$earned',
                style: context.type.mono.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                'of $total',
                style: context.type.tiny.copyWith(fontSize: 9.5),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `.scorebar` with a `.thr` marker - the score against the pass threshold.
class ThresholdBar extends StatelessWidget {
  final int earned;
  final int total;
  final double threshold;
  final ResultState result;

  const ThresholdBar({
    super.key,
    required this.earned,
    required this.total,
    required this.threshold,
    required this.result,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final double frac = total == 0 ? 0 : earned / total;
    final Color fill = switch (result) {
      ResultState.pass => t.successDot,
      ResultState.fail => t.destDot,
      // Pending is GREY, not red, because pending is not failure.
      ResultState.pending => t.textMuted,
    };
    // The fixed-height box wraps the LayoutBuilder, not the other way round:
    // a tight height short-circuits intrinsic-height queries, so this widget
    // can sit inside an IntrinsicHeight (the equal-height card grid) without
    // "LayoutBuilder does not support returning intrinsic dimensions".
    return SizedBox(
      height: 11,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) => Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              top: 2,
              left: 0,
              right: 0,
              child: Container(
                height: 7,
                decoration: BoxDecoration(
                  color: t.bgMuted,
                  borderRadius: Radii.bar,
                ),
              ),
            ),
            Positioned(
              top: 2,
              left: 0,
              child: Container(
                height: 7,
                width: c.maxWidth * frac.clamp(0, 1),
                decoration: BoxDecoration(color: fill, borderRadius: Radii.bar),
              ),
            ),
            Positioned(
              top: 0,
              bottom: 0,
              left: c.maxWidth * (threshold / 100).clamp(0, 1),
              child: Container(width: 2, color: t.textPrimary.o(.55)),
            ),
          ],
        ),
      ),
    );
  }
}
