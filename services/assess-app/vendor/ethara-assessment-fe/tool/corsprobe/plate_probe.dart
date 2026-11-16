// DOES THE `<img>` PLATFORM VIEW ACTUALLY RENDER A NO-CORS IMAGE?
//
// This is the claim the media fix now rests on, and no test in `test/` can check
// it: `ImagePlate`'s web half needs `dart.library.js_interop`, so under the VM
// test runner the conditional export resolves to the stub and the element never
// exists. So this is a real browser probe, driven by `run.sh`.
//
// WHY IT IS NOT REDUNDANT WITH `cors_probe.dart`. That one measures Flutter's own
// `WebHtmlElementStrategy`, which reaches an `<img>` only AFTER an XHR has
// failed. This measures OUR element-first path - a different mechanism, and the
// one the app now uses for every foreign origin.
//
// Expects `plate=OK`, against a server that deliberately sends no
// `Access-Control-Allow-Origin`. A browser needs CORS to READ an image's pixels,
// not to SHOW it, so the element must display what `cors_probe`'s XHR cannot
// fetch.
//
// THE VERDICT IS WRITTEN FROM A POST-FRAME CALLBACK, NOT FROM `main`. Flutter's
// web bootstrap sets `document.title` from the app itself during startup, so a
// title written before the first frame is overwritten and the driver reads an
// empty string - which is exactly what a first version of this probe did.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:web/web.dart' as web;

import 'package:ethara_assessment/assessment/screens/exam/image_plate.dart';

const String kUrl = 'http://127.0.0.1:8201/plate.png';

void _report(String outcome) {
  web.document.title = 'PROBE plate=$outcome';
}

void main() => runApp(const _Probe());

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // WHY SUCCESS IS A TIMER AND NOT A CALLBACK. A platform view gives Dart no
    // "painted" event - the browser loads and draws the element itself, which is
    // the very property that makes it work cross-origin. So the honest signal is
    // the ABSENCE of an `error` once the image has had time to load, which is
    // also exactly what a user experiences.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _report('pending');
      Timer(const Duration(seconds: 3), () {
        if (!_failed) _report('OK');
      });
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 120,
          height: 120,
          child: ImagePlate(
            url: kUrl,
            // The element reporting `error` is a platform view's only failure
            // signal. If this fires, the mechanism is broken.
            onFailed: (BuildContext c) {
              _failed = true;
              _report('FAIL');
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    ),
  );
}
