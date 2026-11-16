// A BIG CSV IMPORT GOES IN BATCHES AND SAYS HOW FAR IT HAS GOT.
//
// Reported: a 1000+ row CSV showed nothing until it finished, and "sometimes it
// feels like there is error but it is slowly running in backend". It was ONE
// request: the server provisions a login per new candidate (~240 ms each, so
// ~4 minutes for 1000 rows), long past the idle timeout of the proxy in front
// of Odoo. `inviteMany` now sends `AppStore.inviteBatch` rows per request and
// moves `importProgress` after each one.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

typedef _Row = ({String name, String email});

List<_Row> _rows(int n) => <_Row>[
  for (int i = 0; i < n; i++) (name: 'Cand $i', email: 'c$i@example.com'),
];

class _Rig {
  /// The `candidates` list of every assign request, in order.
  final List<List<dynamic>> batches = <List<dynamic>>[];

  /// Progress as the store reported it after each notify.
  final List<({int done, int total})?> seen = <({int done, int total})?>[];

  /// 1-based batch number that answers 500, or 0 for none.
  final int failOn;

  /// Emails the server reports as already on the roster.
  final Set<String> already;

  late final AppStore store;

  _Rig({this.failOn = 0, this.already = const <String>{}}) {
    store = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        maxAttempts: 1,
        client: MockClient((http.Request req) async {
          if (req.url.path.endsWith('/assign')) {
            final List<dynamic> c =
                (jsonDecode(req.body) as Map<String, dynamic>)['candidates']
                    as List<dynamic>;
            batches.add(c);
            if (batches.length == failOn) {
              return _json(<String, dynamic>{
                'ok': false,
                'error': <String, dynamic>{
                  'code': 'server_error',
                  'message': 'The server failed.',
                },
              }, 500);
            }
            final int dup = c
                .where((dynamic r) => already.contains((r as Map)['email']))
                .length;
            return _json(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{
                'assigned_count': c.length - dup,
                'already_assigned': dup,
                'skipped': <dynamic>[],
              },
            });
          }
          return _json(<String, dynamic>{'ok': true, 'data': _detail});
        }),
      ),
    );
    store.addListener(() => seen.add(store.importProgress));
  }

  static http.Response _json(Map<String, dynamic> body, [int status = 200]) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: <String, String>{'content-type': 'application/json'},
      );

  Map<String, dynamic> get _detail => <String, dynamic>{
    'id': '7',
    'name': 'Sprint 3A',
    'state': 'draft',
    'duration_minutes': 45,
    'roster': <dynamic>[],
  };

  Future<Assessment> load() async {
    await store.loadAssessment('7');
    return store.asmById('7')!;
  }

  String get lastToast =>
      store.toaster.items.isEmpty ? '' : store.toaster.items.last.message;
}

void main() {
  test('1000 rows go in batches of inviteBatch, every row once', () async {
    final _Rig rig = _Rig();
    await rig.store.inviteMany(await rig.load(), _rows(1000));

    expect(rig.batches.length, (1000 / AppStore.inviteBatch).ceil());
    expect(
      rig.batches.every((List<dynamic> b) => b.length <= AppStore.inviteBatch),
      isTrue,
    );
    final List<dynamic> sent = rig.batches
        .expand((List<dynamic> b) => b)
        .toList();
    expect(sent.length, 1000);
    expect(
      sent.map((dynamic r) => (r as Map)['email']).toSet().length,
      1000,
      reason: 'no row may be sent twice or dropped',
    );
  });

  test('progress climbs to the total, then clears', () async {
    final _Rig rig = _Rig();
    await rig.store.inviteMany(await rig.load(), _rows(120));

    final List<int> done = <int>[
      for (final ({int done, int total})? p in rig.seen)
        if (p != null) p.done,
    ];
    expect(done, containsAllInOrder(<int>[0, 50, 100, 120]));
    expect(
      rig.seen.whereType<({int done, int total})>().every(
        (({int done, int total}) p) => p.total == 120,
      ),
      isTrue,
    );
    expect(rig.store.importProgress, isNull);
  });

  test('the summary adds up every batch', () async {
    final _Rig rig = _Rig(
      already: <String>{'c3@example.com', 'c77@example.com'},
    );
    await rig.store.inviteMany(await rig.load(), _rows(120));

    expect(rig.lastToast, '118 invited, 2 already assigned');
  });

  test('a small file is still one request', () async {
    final _Rig rig = _Rig();
    await rig.store.inviteMany(await rig.load(), _rows(12));

    expect(rig.batches.length, 1);
    expect(rig.lastToast, '12 invited');
  });

  test('a failed batch stops, and says how far it got', () async {
    final _Rig rig = _Rig(failOn: 3);
    await rig.store.inviteMany(await rig.load(), _rows(200));

    expect(rig.batches.length, 3, reason: 'nothing is sent after a failure');
    expect(rig.lastToast, contains('Imported 100 of 200, then stopped'));
    expect(rig.lastToast, contains('Import the same file again'));
    expect(rig.store.importProgress, isNull);
  });

  test('a first batch that fails reads exactly as before', () async {
    final _Rig rig = _Rig(failOn: 1);
    await rig.store.inviteMany(await rig.load(), _rows(200));

    expect(rig.batches.length, 1);
    expect(rig.lastToast, isNot(contains('Imported')));
    expect(rig.store.importProgress, isNull);
  });

  test('a second import while one runs is ignored', () async {
    final _Rig rig = _Rig();
    final Assessment asm = await rig.load();
    final Future<void> first = rig.store.inviteMany(asm, _rows(100));
    await rig.store.inviteMany(asm, _rows(100));
    await first;

    expect(rig.batches.length, 2, reason: 'only the first import was sent');
  });
}
