@TestOn('vm')
/// Two rules about the fullscreen gate that no runner can reach at runtime.
///
/// The web watcher cannot be loaded on the VM, and under `--platform chrome`
/// the suite's own iframe carries no `allow="fullscreen"`, so
/// `document.fullscreenEnabled` is false and every predicate is trivially
/// false. Both rules below cost a candidate their sitting when broken and
/// neither is observable from a test that only pokes widgets, so they are
/// pinned by reading the source. VM only: `--platform chrome` has no
/// filesystem and this would fail with "Unsupported operation: _Namespace".
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('_begin() does not ask for fullscreen', () {
    // WHY IT MUST NOT. It runs from the instructions page, which never goes
    // through `_buildChrome` - so the watcher is not started, there is no
    // `fullscreenchange` listener, and the promise's own latch sits behind an
    // `if (!_running) return`. It also lands one beat before `start()` raises
    // the camera permission prompt, and a browser drops the tab OUT of
    // fullscreen to show that prompt, which the watcher then read as the
    // candidate leaving: a proctoring violation on the first frame of the
    // exam, and at a cap of 1 an exam that ends before the first question is
    // read. The watcher asks instead, from a capture-phase DOM handler.
    final String src = File(
      'lib/assessment/screens/exam/exam_screen.dart',
    ).readAsStringSync();
    final int start = src.indexOf('Future<void> _begin() async {');
    expect(start, isNot(-1), reason: '_begin moved or was renamed');
    final int end = src.indexOf('\n  }', start);
    expect(end, isNot(-1));

    final String body = src.substring(start, end);
    expect(
      body.contains('requestFullscreen'),
      isFalse,
      reason:
          'asking from Begin cannot latch, races the camera prompt, and '
          'fabricates an "Exited fullscreen" violation on the first frame',
    );
  });

  test('the gate predicate still waits for the camera', () {
    // The whole reported bug in one clause. Without `cameraReady` the
    // fullscreen wall goes up in the same frame as the browser's camera
    // bubble, a click aimed at the wall dismisses the bubble and denies the
    // camera, the camera overlay replaces the wall, its button re-prompts, the
    // wall comes back, and round again for as long as the candidate keeps
    // clicking.
    final String src = File(
      'lib/services/proctor_stub.dart',
    ).readAsStringSync();
    final int start = src.indexOf('bool get needsPrompt =>');
    expect(start, isNot(-1), reason: 'needsPrompt moved or was renamed');
    final String expr = src.substring(start, src.indexOf(';', start));

    expect(
      expr.contains('cameraReady'),
      isTrue,
      reason: 'the fullscreen wall must never share a frame with the camera '
          'permission prompt',
    );
  });
}
