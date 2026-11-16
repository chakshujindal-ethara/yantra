// Sign-out is bounded: a stalled connection must not keep the shell up, with
// a candidate stuck at a shared machine they cannot leave. After 2 s the app
// is signed out here whatever the server is doing; the request itself may
// still end later (see `signing_out_forgets_the_token_before_the_server_
// answers_test.dart` for why that is safe).
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/session.dart';

http.Response _json(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

void main() {
  testWidgets('a logout the server never answers ends locally after 2 s', (
    WidgetTester t,
  ) async {
    final Completer<http.Response> stalled = Completer<http.Response>();
    final Session s = Session(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          if (path.endsWith('/auth/logout')) return stalled.future;
          if (path.endsWith('/auth_token')) {
            return _json(<String, dynamic>{
              'access_token': 'a1',
              'refresh_token': 'r1',
            });
          }
          return _json(<String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{
              'user': <String, dynamic>{
                'uid': '7',
                'name': 'Asha',
                'role': 'candidate',
              },
            },
          });
        }),
      ),
    );
    addTearDown(s.dispose);
    expect(await s.signIn('asha@x', 'pw'), isTrue);

    bool out = false;
    unawaited(s.signOut().then((_) => out = true));
    await t.pump(const Duration(milliseconds: 1900));
    expect(out, isFalse, reason: 'still giving the server its chance');
    expect(s.signedIn, isTrue);

    await t.pump(const Duration(milliseconds: 200));
    expect(out, isTrue, reason: 'given up at 2 s');
    expect(s.signedIn, isFalse);
    expect(s.api.isAuthenticated, isFalse);

    stalled.complete(_json(<String, dynamic>{'ok': true}));
    await t.pump();
  });

  test('a session with no client given builds its own', () {
    final Session s = Session();
    expect(s.api.isAuthenticated, isFalse);
    expect(s.reconnecting, isFalse);
    s.dispose();
  });

  testWidgets('the portal\'s own sign-out (Switch account, Sign In Again) is '
      'bounded too', (WidgetTester t) async {
    final Completer<http.Response> stalled = Completer<http.Response>();
    final AppStore store = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        bearer: 't',
        client: MockClient((http.Request req) async {
          if (req.url.path.endsWith('/auth/logout')) return stalled.future;
          return _json(<String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{},
          });
        }),
      ),
    );
    addTearDown(store.dispose);
    int signedOut = 0;
    store.onSignedOut = () => signedOut++;

    bool out = false;
    unawaited(store.signOut().then((_) => out = true));
    await t.pump(const Duration(milliseconds: 1900));
    expect(out, isFalse);
    expect(signedOut, 0);

    await t.pump(const Duration(milliseconds: 200));
    expect(out, isTrue, reason: 'given up at 2 s');
    expect(signedOut, 1, reason: 'the app is told, so it shows the login form');

    stalled.complete(_json(<String, dynamic>{'ok': true}));
    await t.pump();
  });
}
