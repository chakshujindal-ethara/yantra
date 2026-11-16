// DOES `WebHtmlElementStrategy.fallback` ACTUALLY RENDER A NO-CORS IMAGE?
//
// The one claim in the Form Studio media fix that NO test in `test/` can check:
// the flag is inert off-web (`_network_image_io.dart` stores it and never reads
// it), and all 35+ test files are `@TestOn('vm')`. So this is a real browser
// probe, not a test - run it by hand with `tool/corsprobe/run.sh`.
//
// It mounts the SAME two configurations the app uses, against a local server
// that deliberately sends no `Access-Control-Allow-Origin`:
//
//   never    - the Flutter DEFAULT, and what every designer plate passed before
//              this change. Bytes are XHR-fetched, so a no-CORS host MUST fail.
//   fallback - what the plates pass now. Bytes first, then a plain `<img>`,
//              which a browser displays without needing CORS. MUST succeed.
//
// The verdict goes in `document.title` because that is the one channel a
// headless driver can read without accessibility mode: a CanvasKit frame is
// pixels inside a canvas and an `<img>` fallback is a platform view, so neither
// is findable as a DOM `<img>` by a selector.
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

const String kUrl = 'http://127.0.0.1:8201/plate.png';

final Map<String, String> _results = <String, String>{};

void _report(String label, String outcome) {
  _results[label] = outcome;
  final List<String> parts = _results.keys.toList()..sort();
  web.document.title =
      'PROBE ${parts.map((String k) => '$k=${_results[k]}').join(' ')}';
}

void main() => runApp(const _Probe());

class _Probe extends StatelessWidget {
  const _Probe();

  @override
  Widget build(BuildContext context) => const MaterialApp(
        home: Scaffold(
          body: Row(
            children: <Widget>[
              _One(label: 'never', strategy: WebHtmlElementStrategy.never),
              _One(label: 'fallback', strategy: WebHtmlElementStrategy.fallback),
            ],
          ),
        ),
      );
}

class _One extends StatelessWidget {
  const _One({required this.label, required this.strategy});

  final String label;
  final WebHtmlElementStrategy strategy;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 120,
        height: 120,
        child: Image.network(
          kUrl,
          webHtmlElementStrategy: strategy,
          // `frameBuilder` firing with a non-null frame IS the render - it is
          // the same signal a user seeing the picture depends on.
          frameBuilder: (BuildContext c, Widget child, int? frame, bool sync) {
            if (frame != null) _report(label, 'OK');
            return child;
          },
          errorBuilder: (BuildContext c, Object e, StackTrace? s) {
            _report(label, 'FAIL');
            return const SizedBox.shrink();
          },
        ),
      );
}
