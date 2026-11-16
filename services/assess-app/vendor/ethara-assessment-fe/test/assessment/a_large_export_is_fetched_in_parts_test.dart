// A LARGE EXPORT IS FETCHED IN PARTS, WITH PROGRESS, AND JOINED.
//
// Reported: Export Responses on a 691-candidate, 30-question assessment said
// "This export is 15.3 MB, over the 15.0 MB limit for a single download". The
// responses export is now fetched `AppStore.exportBatch` candidates at a time,
// `exportProgress` moves after each page, and the pages are joined into one
// CSV with a single header. The other exports ask for `zip: true`, so one too
// large for CSV arrives zipped and is saved as bytes, not decoded as text.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

const String _header = 'candidate,question,answer\r\n';

String _b64(String s) => base64Encode(utf8.encode(s));

class _Rig {
  final List<http.Request> requests = <http.Request>[];
  final List<({int done, int total})?> seen = <({int done, int total})?>[];
  late final AppStore store;

  /// Candidates on the paper; a paged request answers its slice of them.
  final int candidates;

  /// 1-based paged request that answers 500, or 0 for none.
  final int failOn;

  /// When set, the server ignores paging and answers this, as an old one did.
  final Map<String, dynamic>? whole;

  int _pages = 0;

  _Rig({this.candidates = 0, this.failOn = 0, this.whole}) {
    store = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        maxAttempts: 1,
        client: MockClient((http.Request req) async {
          requests.add(req);
          if (!req.url.path.contains('/export/')) return _ok(_detail);
          if (whole != null) return _ok(whole!);
          final Map<String, dynamic> b =
              jsonDecode(req.body) as Map<String, dynamic>;
          if (++_pages == failOn) {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': false,
                'error': <String, dynamic>{
                  'code': 'server_error',
                  'message': 'The server failed.',
                },
              }),
              500,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          final int offset = b['offset'] as int;
          final int limit = b['limit'] as int;
          final StringBuffer csv = StringBuffer('\u{FEFF}$_header');
          for (int i = offset; i < offset + limit && i < candidates; i++) {
            csv.write('Cand $i,Q1,yes\r\nCand $i,Q2,no\r\n');
          }
          return _ok(<String, dynamic>{
            'filename': 'paper_responses.csv',
            'mimetype': 'text/csv',
            'content': _b64(csv.toString()),
            'total': candidates,
            'offset': offset,
          });
        }),
      ),
    );
    store.addListener(() => seen.add(store.exportProgress));
  }

  static http.Response _ok(Map<String, dynamic> data) => http.Response(
    jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );

  static const Map<String, dynamic> _detail = <String, dynamic>{
    'id': '7',
    'name': 'Trinity',
    'state': 'in_progress',
    'duration_minutes': 45,
    'roster': <dynamic>[],
  };

  Future<Assessment> load() async {
    await store.loadAssessment('7');
    return store.asmById('7')!;
  }

  List<Map<String, dynamic>> get exportBodies => <Map<String, dynamic>>[
    for (final http.Request r in requests)
      if (r.url.path.contains('/export/'))
        jsonDecode(r.body) as Map<String, dynamic>,
  ];

  String get lastToast =>
      store.toaster.items.isEmpty ? '' : store.toaster.items.last.message;
}

void main() {
  test('691 candidates are fetched in pages of exportBatch', () async {
    final _Rig rig = _Rig(candidates: 691);
    await rig.store.exportResponses(await rig.load());

    final List<Map<String, dynamic>> bodies = rig.exportBodies;
    expect(bodies.length, (691 / AppStore.exportBatch).ceil());
    expect(
      <int>[for (final Map<String, dynamic> b in bodies) b['offset']],
      <int>[for (int o = 0; o < 691; o += AppStore.exportBatch) o],
    );
    expect(
      bodies.every(
        (Map<String, dynamic> b) => b['limit'] == AppStore.exportBatch,
      ),
      isTrue,
    );
    expect(rig.lastToast, 'paper_responses.csv downloaded');

    // The saved file: one header, then every candidate exactly once, in order.
    final String joined = rig.store.lastExportParts!
        .map((List<int> p) => utf8.decode(p))
        .join();
    final StringBuffer want = StringBuffer(_header);
    for (int i = 0; i < 691; i++) {
      want.write('Cand $i,Q1,yes\r\nCand $i,Q2,no\r\n');
    }
    expect(joined, want.toString());
  });

  test('progress climbs to the total, then clears', () async {
    final _Rig rig = _Rig(candidates: 120);
    await rig.store.exportResponses(await rig.load());

    final List<int> done = <int>[
      for (final ({int done, int total})? p in rig.seen)
        if (p != null && p.total > 0) p.done,
    ];
    expect(done, <int>[50, 100, 120]);
    expect(rig.store.exportProgress, isNull);
  });

  test('a failed page stops, says how far it got, and saves nothing', () async {
    final _Rig rig = _Rig(candidates: 200, failOn: 3);
    await rig.store.exportResponses(await rig.load());

    expect(rig.exportBodies.length, 3);
    expect(rig.lastToast, contains('stopped after 100 of 200 candidates'));
    expect(rig.lastToast, isNot(contains('downloaded')));
    expect(rig.store.exportProgress, isNull);
  });

  test('an old server that ignores paging still downloads once', () async {
    final _Rig rig = _Rig(
      whole: <String, dynamic>{
        'filename': 'paper_responses.csv',
        'mimetype': 'text/csv',
        'content': _b64(
          '$_header'
          'Asha,Q1,yes\r\n',
        ),
      },
    );
    await rig.store.exportResponses(await rig.load());

    expect(rig.exportBodies.length, 1);
    expect(rig.lastToast, 'paper_responses.csv downloaded');
    expect(rig.store.exportProgress, isNull);
  });

  test('a second press while exporting is ignored', () async {
    final _Rig rig = _Rig(candidates: 100);
    final Assessment asm = await rig.load();
    final Future<void> first = rig.store.exportResponses(asm);
    await rig.store.exportResponses(asm);
    await first;
    expect(rig.exportBodies.length, 2);
  });

  test('results and one-candidate exports ask for a zip', () async {
    final _Rig rig = _Rig(
      whole: <String, dynamic>{
        'filename': 'r.csv',
        'mimetype': 'text/csv',
        'content': _b64('a,b\n'),
      },
    );
    await rig.store.exportResults(await rig.load());
    expect(rig.requests.last.url.path, endsWith('/export/results'));
    expect(rig.exportBodies.last['zip'], isTrue);

    await rig.store.exportAttemptResponses('5');
    expect(
      rig.requests.last.url.path,
      endsWith('/attempts/5/export/responses'),
    );
    expect(rig.exportBodies.last['zip'], isTrue);
  });

  test('a zip is saved as bytes, not decoded as text', () async {
    final _Rig rig = _Rig(
      whole: <String, dynamic>{
        'filename': 'responses.zip',
        'mimetype': 'application/zip',
        // Not valid UTF-8: decoding it as text would throw.
        'content': base64Encode(<int>[0x50, 0x4b, 0x03, 0x04, 0xff, 0xfe]),
      },
    );
    await rig.store.exportAttemptResponses('5');
    expect(rig.lastToast, contains('responses.zip downloaded'));
  });
}
