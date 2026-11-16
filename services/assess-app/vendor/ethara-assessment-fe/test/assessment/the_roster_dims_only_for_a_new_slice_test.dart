// R1: while the roster loads ANOTHER tile, page or sort, the rows on screen
// answer the old one. `AppStore.rosterStale` says so, so the tab can dim them
// until the new page lands. A refetch of the SAME slice (after an action, a
// scoring run) leaves the rows alone: dimming those would flash the table on
// every save.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

void main() {
  late Completer<void> gate;
  late AppStore store;

  setUp(() {
    gate = Completer<void>()..complete();
    store = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          await gate.future;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <dynamic>[],
              'meta': <String, dynamic>{'total': 0},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
    addTearDown(store.dispose);
  });

  test('a new tile dims the rows until its page lands', () async {
    await store.loadRoster('58');
    expect(store.rosterStale, isFalse);

    gate = Completer<void>();
    final Future<void> pressed = store.loadRoster('58', result: 'fail');
    expect(store.rosterStale, isTrue, reason: 'the rows are All, not Failed');
    gate.complete();
    await pressed;
    expect(store.rosterStale, isFalse);
  });

  test('the same slice again does not dim', () async {
    await store.loadRoster('58', state: 'submitted');

    gate = Completer<void>();
    final Future<void> again = store.loadRoster('58', state: 'submitted');
    expect(store.rosterStale, isFalse);
    gate.complete();
    await again;
    expect(store.rosterStale, isFalse);
  });

  test('a later same-slice call cannot undim a pending new slice', () async {
    await store.loadRoster('58');

    gate = Completer<void>();
    final Future<void> a = store.loadRoster('58', page: 2);
    final Future<void> b = store.loadRoster('58', page: 2);
    expect(store.rosterStale, isTrue);
    gate.complete();
    await Future.wait(<Future<void>>[a, b]);
    expect(store.rosterStale, isFalse);
  });
}
