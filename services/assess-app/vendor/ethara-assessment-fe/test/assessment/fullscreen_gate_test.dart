/// The fullscreen gate's decision, tested off the browser.
///
/// WHY THIS FILE EXISTS AT ALL. Neither test runner can reach this reasoning
/// through `ProctorWatch`. On the VM the conditional import resolves to the
/// no-op stub, so every fullscreen predicate is trivially false. Under
/// `--platform chrome` it resolves to the real watcher, but package:test loads
/// each suite in an iframe with no `allow="fullscreen"`, so
/// `document.fullscreenEnabled` is false and the predicates are trivially
/// false there too. The gate was therefore shipped with zero coverage, which
/// is how a candidate ended up behind a wall whose only button could not work.
library;

import 'package:ethara_assessment/services/proctor_stub.dart';
import 'package:flutter_test/flutter_test.dart';

FullscreenGate gate({
  bool running = true,
  bool wantFullscreen = true,
  bool usable = true,
  bool wantCamera = false,
  CameraState camera = CameraState.idle,
  bool everEntered = false,
  bool isFullscreen = false,
  bool refused = false,
}) => FullscreenGate(
  running: running,
  wantFullscreen: wantFullscreen,
  usable: usable,
  wantCamera: wantCamera,
  camera: camera,
  everEntered: everEntered,
  isFullscreen: isFullscreen,
  refused: refused,
);

void main() {
  group('The fullscreen wall waits for the camera', () {
    test('it does not go up while the camera prompt is still open', () {
      // THE BUG. A click aimed at the wall dismisses the browser's camera
      // bubble, which denies the camera - so the wall's own button took away
      // the permission that would have let it succeed.
      expect(
        gate(wantCamera: true, camera: CameraState.pending).needsPrompt,
        isFalse,
      );
    });

    test('it goes up once the camera is on', () {
      // Proves the line above is a suppression and not a permanent off.
      expect(
        gate(wantCamera: true, camera: CameraState.on).needsPrompt,
        isTrue,
      );
    });

    test('a refused or missing camera keeps it down', () {
      // The camera overlay outranks this one and names the one thing to do.
      for (final CameraState state in <CameraState>[
        CameraState.idle,
        CameraState.off,
        CameraState.unavailable,
      ]) {
        expect(
          gate(wantCamera: true, camera: state).needsPrompt,
          isFalse,
          reason: 'camera $state must not have a fullscreen wall over it',
        );
      }
    });

    test('the webcam rule being off changes nothing', () {
      // The regression guard: most assessments never turn the camera on, and
      // their gate must behave exactly as it did before any of this.
      expect(gate(camera: CameraState.idle).needsPrompt, isTrue);
    });
  });

  group('A browser that will not co-operate', () {
    test('stops blocking and starts offering', () {
      // The escape hatch, in one assertion. A wall whose single action cannot
      // succeed is a trap, and the clock does not stop for it.
      final FullscreenGate g = gate(refused: true);
      expect(g.needsPrompt, isFalse);
      expect(g.shouldOffer, isTrue);
    });

    test('neither wall nor offer survives an iframe that forbids fullscreen', () {
      // `usable` is read from `document.fullscreenEnabled`. An unsatisfiable
      // requirement must not raise any surface at all.
      final FullscreenGate g = gate(
        usable: false,
        refused: true,
        everEntered: true,
      );
      expect(g.needsPrompt, isFalse);
      expect(g.shouldOffer, isFalse);
    });

    test('nothing shows once the document really is fullscreen', () {
      // `!isFullscreen` is load-bearing on both predicates: the latch means
      // "this watcher saw an entry", not "we are in", and the two come apart.
      expect(gate(refused: true, isFullscreen: true).shouldOffer, isFalse);
      expect(gate(everEntered: true, isFullscreen: true).shouldOffer, isFalse);
    });
  });

  group('The plain cases still hold', () {
    test('entered and then left is the offer, never the wall', () {
      final FullscreenGate g = gate(everEntered: true);
      expect(g.needsPrompt, isFalse);
      expect(g.shouldOffer, isTrue);
    });

    test('a stopped watcher shows nothing', () {
      final FullscreenGate g = gate(running: false, everEntered: true);
      expect(g.needsPrompt, isFalse);
      expect(g.shouldOffer, isFalse);
    });

    test('a rule the operator never switched on shows nothing', () {
      final FullscreenGate g = gate(wantFullscreen: false, refused: true);
      expect(g.needsPrompt, isFalse);
      expect(g.shouldOffer, isFalse);
    });
  });

  group('Refusals are counted as a streak, not a tally', () {
    test('one refusal does not open the escape hatch', () {
      // Anti-flake: a single stray refusal is ordinary, and giving up on it
      // would leave the rule unenforced for a willing browser.
      final FullscreenRefusals r = FullscreenRefusals()..refuse('TypeError');
      expect(r.consecutive, 1);
      expect(r.refused, isFalse);
    });

    test('two in a row do', () {
      final FullscreenRefusals r = FullscreenRefusals()
        ..refuse('TypeError')
        ..refuse('TypeError');
      expect(r.refused, isTrue);
    });

    test('getting in clears the run', () {
      // A candidate refused once who then gets in must not carry that strike
      // forward into a later exit.
      final FullscreenRefusals r = FullscreenRefusals()..refuse('TypeError');
      r.entered();
      r.refuse('TypeError');
      expect(r.refused, isFalse, reason: 'a success resets the streak');
    });

    test('the browser reason survives to the latch, for the console', () {
      final FullscreenRefusals r = FullscreenRefusals()
        ..refuse('TypeError: API can only be initiated by a user gesture.');
      expect(r.lastError, contains('user gesture'));
    });
  });
}
