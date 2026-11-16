// THE HEADERS RULE, measured: non-empty `headers` disables the <img> path.
//
// `_network_image_web.dart` routes to `loadViaDecode()` whenever headers are
// present, so `fallback` cannot save an image that also carries a bearer token.
// That is exactly why `stimulusImage` now attaches `mediaAuthHeaders` ONLY when
// the URL is our own origin - Preview used to send them to every host, which
// made it strictly worse off than the designer.
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

const String kUrl = 'http://127.0.0.1:8201/plate.png';
final Map<String, String> _r = <String, String>{};

void _report(String k, String v) {
  _r[k] = v;
  final List<String> ks = _r.keys.toList()..sort();
  web.document.title =
      'PROBE ${ks.map((String k) => '$k=${_r[k]}').join(' ')}';
}

void main() => runApp(const MaterialApp(
      home: Scaffold(
        body: Row(
          children: <Widget>[
            // fallback + NO headers: what a third-party plate does now.
            _One(label: 'noHeaders', headers: <String, String>{}),
            // fallback + headers: what Preview did to EVERY host before.
            _One(label: 'withHeaders',
                headers: <String, String>{'Authorization': 'Bearer x'}),
          ],
        ),
      ),
    ));

class _One extends StatelessWidget {
  const _One({required this.label, required this.headers});

  final String label;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 120,
        height: 120,
        child: Image.network(
          kUrl,
          headers: headers,
          webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
          frameBuilder: (BuildContext c, Widget w, int? f, bool s) {
            if (f != null) _report(label, 'OK');
            return w;
          },
          errorBuilder: (BuildContext c, Object e, StackTrace? s) {
            _report(label, 'FAIL');
            return const SizedBox.shrink();
          },
        ),
      );
}
