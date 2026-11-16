// AI proctoring's JS bridge must receive the trip callback even when there is
// no snapshot upload policy.
//
// THE BUG: `startAiBridge` used `callMethod(start, video, policy, onEvent)`.
// `callMethod` stops at the first null argument, and the policy is null until
// `/begin` or `/state` carries one (and for good where storage is not
// configured). JS got `start(video)`: detection ran, the face box was drawn,
// and every trip was reported to nobody. No VM test can see this - it is
// `dart:js_interop` behaviour - so this runs in a browser:
//
//   flutter test --platform chrome test/assessment/the_ai_bridge_gets_its_callback_without_a_policy_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'package:ethara_assessment/services/proctor_web.dart';

/// A stand-in for `window.__proctorAi` that keeps every `start` call's
/// arguments exactly as JS received them.
JSObject _fakeBridge() => globalContext.callMethod<JSObject>(
  'eval'.toJS,
  '({ calls: [], start(...a) { this.calls.push(a); } })'.toJS,
);

JSArray<JSAny?> _call(JSObject ai, int i) =>
    ai.getProperty<JSArray<JSAny?>>('calls'.toJS).toDart[i] as JSArray<JSAny?>;

void main() {
  test('without a policy, start() still gets the callback, third', () {
    final JSObject ai = _fakeBridge();
    final List<String> reasons = <String>[];
    startAiBridge(ai, web.HTMLVideoElement(), null, reasons.add);

    final List<JSAny?> args = _call(ai, 0).toDart;
    expect(args, hasLength(3), reason: 'video, policy, onEvent');
    expect(args[1], isNull);
    expect(args[2].typeofEquals('function'), isTrue);

    // A trip, as the bridge reports it, reaches Dart.
    (args[2]! as JSFunction).callAsFunction(
      null,
      <String, Object?>{
        'rule': 'no_face',
        'reason': 'AI: no face for 5s',
      }.jsify(),
    );
    expect(reasons, <String>['AI: no face for 5s']);
  });

  // `proctor_ai.js` reports how it stands (`running`, `failed`) on the trip
  // callback as
  // `{rule: 'status', reason: '', status}`: the value is in `status`, and the
  // empty `reason` is what keeps an OLDER bridge from counting it (see the
  // deploy-skew guard in tool/proctor_ai_rules_test.mjs). Reaching the
  // violation callback would count "running" as a violation.
  test('a status event reaches onStatus, never the violation callback', () {
    final JSObject ai = _fakeBridge();
    final List<String> violations = <String>[];
    final List<String> statuses = <String>[];
    startAiBridge(
      ai,
      web.HTMLVideoElement(),
      null,
      violations.add,
      onStatus: statuses.add,
    );
    final JSFunction onEvent = _call(ai, 0).toDart[2]! as JSFunction;
    for (final String s in <String>['running', 'failed']) {
      onEvent.callAsFunction(
        null,
        <String, Object?>{'rule': 'status', 'reason': '', 'status': s}.jsify(),
      );
    }
    expect(statuses, <String>['running', 'failed']);
    expect(violations, isEmpty);

    // Without an onStatus it is dropped, still never a violation.
    final JSObject bare = _fakeBridge();
    startAiBridge(bare, web.HTMLVideoElement(), null, violations.add);
    (_call(bare, 0).toDart[2]! as JSFunction).callAsFunction(
      null,
      <String, Object?>{
        'rule': 'status',
        'reason': '',
        'status': 'running',
      }.jsify(),
    );
    expect(violations, isEmpty);
  });

  // The instructions screen asks for the camera once, before fullscreen.
  test('probeCamera names a refusal and lets go of a granted camera', () async {
    final JSObject media = (web.window.navigator as JSObject)
        .getProperty<JSObject>('mediaDevices'.toJS);
    globalContext.callMethod<JSAny?>(
      'eval'.toJS,
      '''window.__stopped = 0;
         navigator.mediaDevices.getUserMedia = () => window.__grant
           ? Promise.resolve({ getTracks: () => [{ stop() { window.__stopped++; } }] })
           : Promise.reject(new DOMException('no', 'NotAllowedError'));'''
          .toJS,
    );
    try {
      globalContext.setProperty('__grant'.toJS, false.toJS);
      expect(await probeCamera(), 'NotAllowedError');
      globalContext.setProperty('__grant'.toJS, true.toJS);
      expect(await probeCamera(), isNull);
      expect(
        globalContext.getProperty<JSNumber>('__stopped'.toJS).toDartInt,
        1,
      );
    } finally {
      media.delete('getUserMedia'.toJS);
    }
  });

  test('with a policy, the policy rides second', () {
    final JSObject ai = _fakeBridge();
    startAiBridge(ai, web.HTMLVideoElement(), <String, Object?>{
      'url': 'https://b/',
      'prefix': 'p/',
    }, (_) {});
    final List<JSAny?> args = _call(ai, 0).toDart;
    expect(args, hasLength(3));
    expect(
      (args[1]! as JSObject).getProperty<JSString>('prefix'.toJS).toDart,
      'p/',
    );
    expect(args[2].typeofEquals('function'), isTrue);
  });

  // `proctor_ai.js` asks `policy.landed(key)` after an upload whose S3 reply
  // it could not read (no CORS rule for POST), instead of sending it again.
  test(
    'the screen\'s landed check reaches the bridge as a JS function',
    () async {
      final JSObject ai = _fakeBridge();
      final List<String> asked = <String>[];
      Future<bool> landed(String key) async {
        asked.add(key);
        return true;
      }

      startAiBridge(ai, web.HTMLVideoElement(), <String, Object?>{
        'url': 'https://b/',
        'prefix': 'p/',
        'landed': landed,
      }, (_) {});
      final JSObject policy = _call(ai, 0).toDart[1]! as JSObject;
      expect(policy.getProperty<JSString>('prefix'.toJS).toDart, 'p/');
      final JSPromise<JSBoolean> found =
          policy
                  .getProperty<JSFunction>('landed'.toJS)
                  .callAsFunction(null, 'p/1_phone.jpg'.toJS)!
              as JSPromise<JSBoolean>;
      expect((await found.toDart).toDart, isTrue);
      expect(asked, <String>['p/1_phone.jpg']);
    },
  );
}
