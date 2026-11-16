// The exam screen lets go of the AI models it warmed on the instructions
// page (`releaseAi`, about 30 MB). The bridge's own `release()` keeps them
// while a run uses them; this side only asks, and never throws: there may be
// no bridge yet, or an older one with no `release`. Run it in a browser:
//
//   flutter test --platform chrome test/services/warmed_ai_models_are_let_go_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'package:ethara_assessment/services/proctor_web.dart';

JSObject get _window => web.window as JSObject;

void main() {
  tearDown(() => _window.delete('__proctorAi'.toJS));

  test('asks the loaded bridge to release', () {
    final JSObject ai = globalContext.callMethod<JSObject>(
      'eval'.toJS,
      '({ calls: 0, release() { this.calls++; return true; } })'.toJS,
    );
    _window.setProperty('__proctorAi'.toJS, ai);

    releaseAi();

    expect(ai.getProperty<JSNumber>('calls'.toJS).toDartInt, 1);
  });

  test('no bridge, or one without release: nothing, and no throw', () {
    expect(releaseAi, returnsNormally);
    _window.setProperty('__proctorAi'.toJS, JSObject());
    expect(releaseAi, returnsNormally);
  });

  // `proctor_ai.js` may still be importing when the page is left: the release
  // then finds no bridge, and the preload must not go on to load the models.
  test('a release while the bridge imports stops the preload', () async {
    final JSObject ai = globalContext.callMethod<JSObject>(
      'eval'.toJS,
      '({ preloads: 0, preload() { this.preloads++; return Promise.resolve(true); },'
              ' release() { return true; } })'
          .toJS,
    );
    _window.setProperty('__proctorAi'.toJS, ai);

    final Future<void> warming = preloadAi();
    releaseAi(); // before the import's await resumes
    await warming;

    expect(ai.getProperty<JSNumber>('preloads'.toJS).toDartInt, 0);
  });

  // Eye movement is gone: nothing may ask the bridge for the eye model.
  test(
    'a preload with nothing released goes ahead, asking for no eye model',
    () async {
      final JSObject ai = globalContext.callMethod<JSObject>(
        'eval'.toJS,
        '({ preloads: 0, args: -1, preload(...a) { this.preloads++; this.args = a.length; return Promise.resolve(true); } })'
            .toJS,
      );
      _window.setProperty('__proctorAi'.toJS, ai);
      await preloadAi();
      expect(ai.getProperty<JSNumber>('preloads'.toJS).toDartInt, 1);
      expect(ai.getProperty<JSNumber>('args'.toJS).toDartInt, 0);
    },
  );
}
