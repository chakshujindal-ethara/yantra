/// Real proctoring detection: the platform-neutral half.
///
/// The web implementation lives in `proctor_web.dart` and is selected by a
/// conditional import, exactly like `file_pick_stub` / `file_pick_web`. On any
/// non-web platform this stub is used and nothing is detected, which is honest:
/// there is no tab to switch away from and no devtools panel to spot.
library;

/// Which rules a deployment has switched on, as the server reports them.
///
/// Mirrors the `rules` object of `/api/v1/exam/<token>/state`. A field the
/// server did not send stays false, so a rule is only ever enforced because
/// somebody turned it on - never because the client guessed.
class ProctorRules {
  const ProctorRules({
    this.tabSwitch = false,
    this.copyPaste = false,
    this.rightClick = false,
    this.devtools = false,
    this.fullscreen = false,
    this.webcam = false,
    this.aiProctor = false,
  });

  final bool tabSwitch;
  final bool copyPaste;
  final bool rightClick;
  final bool devtools;
  final bool fullscreen;

  /// Ask for the camera and keep watching that it stays on.
  ///
  /// Was missing entirely: the server sent `webcam`, the operator could switch
  /// it on, and this class had nowhere to put it - so the one place server
  /// rules become browser behaviour dropped it. An assessment configured with
  /// only this rule also made [any] false, which meant the watcher never
  /// started at all.
  final bool webcam;

  /// Face and phone detection on the live camera (`web/proctor_ai.js`).
  /// Only acts alongside [webcam], which is what provides the stream.
  final bool aiProctor;

  /// True when at least one rule needs a browser listener.
  bool get any =>
      tabSwitch || copyPaste || rightClick || devtools || fullscreen || webcam;
}

/// How the camera currently stands, for the surface that has to say so.
enum CameraState {
  /// The rule is off, or nothing has been asked for yet.
  idle,

  /// Waiting on the permission prompt.
  pending,

  /// Granted and streaming.
  on,

  /// Refused, or lost after having been granted. [ProctorWatch.cameraMessage]
  /// says which, in the candidate's words.
  off,

  /// This browser exposes no camera API at all, so the requirement cannot be
  /// satisfied here however the candidate answers the prompt.
  unavailable,
}

/// The fullscreen gate's decision, with the browser taken out of it.
///
/// EXTRACTED SO IT CAN BE TESTED AT ALL. The web watcher is the only
/// implementation that answers anything but false, and it cannot be loaded on
/// the VM - `dart:js_interop`, `dart:ui_web` and `package:web` are not there -
/// so under `flutter test` the exam screen always meets the no-op stub below
/// and every fullscreen predicate is trivially false. Under
/// `flutter test --platform chrome` the suite runs inside the harness's own
/// iframe, which carries no `allow="fullscreen"`, so `fullscreenEnabled` is
/// false and the predicates are trivially false there too. Neither runner can
/// reach this reasoning through the watcher. A plain value class can be
/// reached from both.
class FullscreenGate {
  const FullscreenGate({
    required this.running,
    required this.wantFullscreen,
    required this.usable,
    required this.wantCamera,
    required this.camera,
    required this.everEntered,
    required this.isFullscreen,
    required this.refused,
  });

  /// The watcher is attached.
  final bool running;

  /// The deployment switched the rule on.
  final bool wantFullscreen;

  /// This document may enter fullscreen at all. False in an iframe without
  /// `allow="fullscreen"`, and where the API is disabled.
  final bool usable;

  final bool wantCamera;
  final CameraState camera;

  /// This watcher has seen an entry. A latch, not "is fullscreen right now".
  final bool everEntered;

  final bool isFullscreen;

  /// The browser has refused often enough in a row that the requirement has
  /// been downgraded from a wall to an offer.
  final bool refused;

  /// True when the camera rule is off, or on and already satisfied.
  ///
  /// FULLSCREEN AND A CAMERA PROMPT CANNOT BE ASKED FOR AT THE SAME TIME, and
  /// that is the whole bug. `start()` raises the getUserMedia prompt in the
  /// same frame the fullscreen gate goes up, so on a browser that has never
  /// been asked the candidate meets both at once. While that prompt is open
  /// the browser refuses `requestFullscreen()` - and worse, a click aimed at
  /// the fullscreen wall DISMISSES the prompt, which is a soft denial of the
  /// camera. So the attempt to clear the wall took the camera away instead:
  /// the camera overlay replaced the fullscreen one, its button re-prompted,
  /// the fullscreen wall came back on top, and round again for as long as they
  /// kept clicking. On the second visit the grant is remembered, no prompt
  /// appears, and the identical code works - which is why this only ever
  /// reproduced on a browser opened for the first time.
  ///
  /// Settle the camera FIRST, then ask for fullscreen. `_blockingOverlay`
  /// already orders its two overlays that way and says so in its own comment;
  /// this puts the same order somewhere the auto-enter handler can see it too.
  bool get cameraReady => !wantCamera || camera == CameraState.on;

  /// See [ProctorWatch.needsFullscreenPrompt].
  bool get needsPrompt =>
      running &&
      wantFullscreen &&
      usable &&
      cameraReady &&
      !refused &&
      !everEntered &&
      !isFullscreen;

  /// See [ProctorWatch.shouldOfferReturnToFullscreen].
  ///
  /// Deliberately NOT gated on [cameraReady]. This drives a non-blocking bar,
  /// which is harmless beside a camera prompt, and suppressing it would make
  /// the bar flicker every time the camera state moved. It is the REQUEST that
  /// must wait for the camera, not the offer.
  bool get shouldOffer =>
      running &&
      wantFullscreen &&
      usable &&
      (everEntered || refused) &&
      !isFullscreen;
}

/// The consecutive-refusal latch, kept out of the browser half for the same
/// reason [FullscreenGate] is.
class FullscreenRefusals {
  /// How many refusals in a row downgrade the wall to an offer.
  ///
  /// Two, not one: a single stray refusal is ordinary - a request that raced
  /// the browser's own transition, or one issued while a dialog held the
  /// surface - and opening the escape hatch on it would leave the rule
  /// unenforced for candidates whose browser was perfectly willing.
  static const int limit = 2;

  int _consecutive = 0;
  String _lastError = '';

  int get consecutive => _consecutive;

  /// The browser's own words for the last refusal, or empty.
  ///
  /// DEVELOPER DETAIL, never rendered to a candidate: a rejected
  /// `requestFullscreen()` stringifies to whatever the engine felt like.
  String get lastError => _lastError;

  bool get refused => _consecutive >= limit;

  void refuse(String error) {
    _lastError = error;
    _consecutive++;
  }

  /// Any entry clears the run. This counts a STREAK, not a lifetime tally: a
  /// candidate refused once who then gets in must not carry that forward.
  void entered() {
    _consecutive = 0;
    _lastError = '';
  }
}

/// Watches the browser for proctoring violations.
///
/// One instance per exam sitting. [start] attaches listeners, [stop] removes
/// them; both are safe to call more than once, because an exam screen rebuilds
/// often and a listener left behind would double-count every violation.
abstract class ProctorWatch {
  /// Begin watching. [onViolation] is called with the reason string that goes
  /// to `/api/v1/exam/<token>/violation` verbatim.
  ///
  /// [onCameraChanged] fires whenever [cameraState] moves, so the screen can
  /// raise or clear its blocking overlay without polling.
  void start({
    required ProctorRules rules,
    required void Function(String reason) onViolation,
    void Function()? onCameraChanged,
  });

  /// Detach every listener and release the camera.
  void stop();

  /// Where AI proctoring snapshots go: `ExamView.evidenceUpload` in its wire
  /// shape, plus `landed` (`Future<bool> Function(String key)`, see
  /// `evidencePolicyJs`). Called whenever a new `/begin`, `/state` or
  /// `/answer` brings one; kept across
  /// [stop], because the screen is per sitting and so is the policy.
  void setEvidencePolicy(Map<String, Object?> policy);

  /// Ask the browser to go fullscreen. Only works from inside a user gesture,
  /// so it must be called from a button handler, never on load.
  void requestFullscreen();

  bool get isFullscreen;

  /// True when fullscreen is required and has NEVER been entered.
  ///
  /// A blocking gate, and deliberately ONE-SHOT. The exam asks for fullscreen
  /// from the Begin button, but a candidate who reloads mid-exam or opens
  /// their sitting from their own list never passes through it - and a
  /// windowed exam has the fullscreen-exit violation and the tab-switch check
  /// both disarmed. Asking once is what arms them.
  ///
  /// It must NOT stay true after every later exit. Blocking on that turns
  /// Escape into a loop with no way out: the overlay's only action puts the
  /// candidate back into fullscreen, and Escape brings the overlay straight
  /// back. Leaving fullscreen later is a recorded violation plus an offer to
  /// return ([shouldOfferReturnToFullscreen]), never a wall.
  ///
  /// The decision lives here rather than on the screen because it depends on
  /// browser facts the screen cannot see: whether fullscreen has been entered,
  /// and whether this document is even permitted to enter it. A page embedded
  /// without `allow="fullscreen"` can never satisfy the prompt, and a screen
  /// that asked anyway would trap the candidate behind an overlay whose only
  /// button does nothing.
  bool get needsFullscreenPrompt;

  /// True when fullscreen was entered and has since been left.
  ///
  /// Drives a NON-blocking offer to go back. The violation is already
  /// recorded by then; the paper must stay readable and answerable.
  bool get shouldOfferReturnToFullscreen;

  /// Hand the document back out of fullscreen.
  ///
  /// An exam that put the browser into fullscreen owes the candidate taking it
  /// back out when the sitting ends, or they are left in a chromeless window
  /// with no tabs and no address bar and no obvious way to leave.
  void exitFullscreen();

  /// Ask for the camera. Safe to call repeatedly; a retry after a refusal is
  /// the normal path back.
  void requestCamera();

  CameraState get cameraState;

  /// What to tell the candidate about [cameraState]. Empty when there is
  /// nothing to say.
  String get cameraMessage;

  /// The platform view id of the live preview, or null when there is no
  /// stream to show.
  String? get cameraViewType;

  /// A real DOM button laid over the gate's own, or null off the web.
  ///
  /// WHY A SECOND, INVISIBLE BUTTON. The gate paints a Flutter `Btn`, which is
  /// a `GestureDetector`: its `onTap` is dispatched from the gesture arena on
  /// pointer-UP, after the browser's user-activation window for that click has
  /// closed. `requestFullscreen()` from there is refused for want of a gesture,
  /// the refusal is a rejected promise nobody sees, and the candidate is left
  /// pressing the one control the exam gave them while nothing happens. A
  /// reload was the only way on.
  ///
  /// A real element with a real `click` listener has no such gap: the handler
  /// runs inside the browser's own dispatch with the activation still in force.
  /// That is what the Odoo portal's `#etp-fs-btn` is, and that button has never
  /// shown this failure.
  ///
  /// Transparent and stretched over the painted control, so the design system
  /// still draws the button and only the click is taken from it.
  String? fullscreenButtonView();

  /// True once the browser has refused fullscreen enough times to give up on.
  ///
  /// The gate stops blocking at that point and the offer takes its place: a
  /// requirement this browser will not satisfy must not hold a candidate on a
  /// dimmed paper with the clock running.
  bool get fullscreenRefused;

  /// Whether the exit that raised [shouldOfferReturnToFullscreen] was actually
  /// recorded as a violation.
  ///
  /// The offer bar says "that has been recorded", and there are now two ways to
  /// reach that bar with nothing on the record: a browser that refused the
  /// entry outright, so the requirement degraded from a wall to an offer rather
  /// than trapping the candidate; and an exit the BROWSER performed itself in
  /// order to show a permission prompt. Telling a candidate they have a
  /// violation they do not have is the sentence they would quote in an appeal.
  bool get fullscreenExitRecorded;

  /// Whether Escape is currently being delivered to the PAGE rather than
  /// being eaten by the browser to leave fullscreen.
  ///
  /// False everywhere the Keyboard Lock API is unavailable (Firefox, Safari,
  /// any insecure origin) and whenever the document is not fullscreen. When it
  /// is false the app must not swallow Escape, because the browser's own
  /// handling is then the only way out of fullscreen.
  bool get escapeCaptured;
}

/// A watcher that does nothing, for platforms with no browser.
class _NoopProctorWatch implements ProctorWatch {
  @override
  void start({
    required ProctorRules rules,
    required void Function(String reason) onViolation,
    void Function()? onCameraChanged,
  }) {}

  @override
  void stop() {}

  @override
  void setEvidencePolicy(Map<String, Object?> policy) {}

  @override
  void requestFullscreen() {}

  @override
  bool get isFullscreen => false;

  @override
  bool get needsFullscreenPrompt => false;

  @override
  bool get shouldOfferReturnToFullscreen => false;

  @override
  void exitFullscreen() {}

  @override
  void requestCamera() {}

  @override
  CameraState get cameraState => CameraState.idle;

  @override
  String get cameraMessage => '';

  @override
  String? get cameraViewType => null;

  @override
  String? fullscreenButtonView() => null;

  @override
  bool get fullscreenRefused => false;

  @override
  bool get fullscreenExitRecorded => false;

  @override
  bool get escapeCaptured => false;
}

ProctorWatch createProctorWatch() => _NoopProctorWatch();

// Top-level rather than [ProctorWatch] members, so the test fakes that
// implement [ProctorWatch] need nothing new. `proctor_web.dart` has the real
// [preloadAi], [releaseAi] and [probeCamera] and re-exports [aiStatusSink]
// from here.

/// Load the AI models ahead of the exam. Nothing to load off the web.
Future<void> preloadAi() async {}

/// Let go of the models [preloadAi] loaded, unless a run uses them. Nothing
/// is held off the web.
void releaseAi() {}

/// Open the camera once and let it go. Null means it opened, else the
/// browser's reason. Off the web there is no camera to ask: always null.
Future<String?> probeCamera() async => null;

/// Hears how AI proctoring stands once it starts: `running` or `failed`. Set
/// by the exam screen; one variable for both halves.
void Function(String status)? aiStatusSink;
