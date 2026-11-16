// A server that does not answer is not a server that said no.
//
// THE BUG (SEB review #7). A pod restart, or an ingress 502/503 page with no
// CORS headers, reaches the client as a transport failure. The refresh call
// cleared both tokens on ANY failure, the session check swallowed the error,
// and `restore()` then signed out. So one restart sent every candidate in the
// room back to the login form at once, on sessions the server still held.
//
// THE RULE. Only the gateway's own 401 on `/refresh_token` retires the
// tokens: its 400 is its crash page (`api_auth_gateway/controllers/main.py`
// turns any exception into one). No answer, a 5xx, a 429, or the 404 Odoo
// serves while its database is down keeps them, and the session check waits
// and asks again behind the resume spinner, never the login form. The
// spinner says so, and offers the sign-in form for whoever would rather not
// wait.
@TestOn('vm')
library;

import 'dart:convert';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/main.dart';
import 'package:ethara_assessment/session.dart';

/// A gateway whose host can go away and come back.
class _Gateway {
  /// Every request fails in transport, as a dead pod or a CORS-less 502 does.
  bool down = false;

  /// The next this many `/refresh_token` calls fail in transport.
  int refreshDrops = 0;

  /// The next this many `/auth/me` calls get the ingress's HTML 503 page.
  int meShed = 0;

  /// The next this many `/auth/me` calls get Odoo's HTML 404, as every route
  /// does while its database is unusable.
  int meNoDb = 0;

  /// What `/refresh_token` answers when it does answer: 200, or a refusal.
  int refreshStatus = 200;

  /// The access token `/auth/me` accepts.
  String live = 'a1';

  final List<String> paths = <String>[];
  final List<Object?> refreshSent = <Object?>[];

  http.Response _json(Map<String, dynamic> body, [int status = 200]) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: <String, String>{'content-type': 'application/json'},
      );

  http.Client get client => MockClient((http.Request req) async {
    final String path = req.url.path;
    paths.add(path);
    if (down) throw http.ClientException('Failed to fetch');
    if (path.endsWith('/auth_token')) {
      return _json(<String, dynamic>{
        'access_token': 'a1',
        'refresh_token': 'r1',
      });
    }
    if (path.endsWith('/refresh_token')) {
      refreshSent.add(
        (jsonDecode(req.body) as Map<String, dynamic>)['refresh_token'],
      );
      if (refreshDrops > 0) {
        refreshDrops--;
        throw http.ClientException('Failed to fetch');
      }
      if (refreshStatus != 200) {
        return _json(<String, dynamic>{
          'message': 'Invalid Refresh Token',
        }, refreshStatus);
      }
      live = 'a2';
      return _json(<String, dynamic>{
        'access_token': 'a2',
        'refresh_token': 'r2',
      });
    }
    if (path.endsWith('/auth/me')) {
      if (meShed > 0) {
        meShed--;
        return http.Response('<html>503 Service Unavailable</html>', 503);
      }
      if (meNoDb > 0) {
        meNoDb--;
        return http.Response('<html>404 Not Found</html>', 404);
      }
      if (req.headers['Authorization'] != 'Bearer $live') {
        return _json(<String, dynamic>{
          'ok': false,
          'code': 'session_expired',
          'message': 'Your session has expired. Sign in again.',
        }, 401);
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
    }
    return _json(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}});
  });
}

/// A client already signed in (bearer `a1`, refresh `r1`), as a reload
/// leaves it.
Future<ApiClient> _signedIn(_Gateway g) async {
  final ApiClient api = ApiClient(client: g.client, baseUrl: 'http://x');
  await api.login('asha@x', 'pw');
  return api;
}

/// Every (signedIn, restoring) pair the app was shown. `(false, false)` is
/// the login form (`main.dart`).
List<(bool, bool)> _screens(Session s) {
  final List<(bool, bool)> seen = <(bool, bool)>[];
  s.addListener(() => seen.add((s.signedIn, s.restoring)));
  return seen;
}

void main() {
  group('the refresh call', () {
    test(
      'a network error keeps both tokens and throws so the caller retries',
      () async {
        final _Gateway g = _Gateway();
        final ApiClient api = await _signedIn(g);

        g.refreshDrops = 1;
        await expectLater(
          api.refreshSession(),
          throwsA(
            isA<ApiError>().having(
              (ApiError e) => e.isTransport,
              'isTransport',
              isTrue,
            ),
          ),
        );
        expect(api.isAuthenticated, isTrue, reason: 'no answer is not a no');

        // The host is back: the SAME refresh token renews.
        expect(await api.refreshSession(), isTrue);
        expect(g.refreshSent, <Object?>['r1', 'r1']);
      },
    );

    test('a 401 still retires both tokens', () async {
      final _Gateway g = _Gateway()..refreshStatus = 401;
      final ApiClient api = await _signedIn(g);

      expect(await api.refreshSession(), isFalse);
      expect(api.isAuthenticated, isFalse);
    });

    test("a 400 is the gateway's crash page and keeps both tokens", () async {
      final _Gateway g = _Gateway()..refreshStatus = 400;
      final ApiClient api = await _signedIn(g);

      expect(await api.refreshSession(), isFalse);
      expect(api.isAuthenticated, isTrue);
    });

    test('any other refusal keeps the tokens and says no', () async {
      final _Gateway g = _Gateway()..refreshStatus = 403;
      final ApiClient api = await _signedIn(g);

      expect(await api.refreshSession(), isFalse);
      expect(api.isAuthenticated, isTrue);
    });
  });

  group('resuming a session', () {
    test('a pod restart keeps the login and shows no login form', () async {
      final _Gateway g = _Gateway();
      final List<Duration> waits = <Duration>[];
      final Session s = Session(
        api: await _signedIn(g),
        sleep: (Duration d) async {
          waits.add(d);
          g.down = false;
        },
      );
      final List<(bool, bool)> seen = _screens(s);

      g.down = true;
      expect(await s.restore(), isTrue);

      expect(s.signedIn, isTrue);
      expect(s.name, 'Asha');
      expect(waits, hasLength(1));
      expect(waits.single.inMilliseconds, inInclusiveRange(1500, 2500));
      expect(
        seen,
        isNot(contains((false, false))),
        reason: 'the login form must never be shown while the host is away',
      );
    });

    test('the waits back off 2, 4, 8, 16, then 30 s, each +-25%', () async {
      final _Gateway g = _Gateway();
      final List<Duration> waits = <Duration>[];
      final Session s = Session(
        api: await _signedIn(g),
        sleep: (Duration d) async {
          waits.add(d);
          if (waits.length == 6) g.down = false;
        },
      );
      g.down = true;
      expect(await s.restore(), isTrue);

      const List<int> steps = <int>[2, 4, 8, 16, 30, 30];
      expect(waits, hasLength(steps.length));
      for (int i = 0; i < steps.length; i++) {
        expect(
          waits[i].inMilliseconds,
          inInclusiveRange(steps[i] * 750, steps[i] * 1250),
          reason: 'wait ${i + 1}: a whole room must not come back every 2 s',
        );
      }
    });

    test('an ingress 503 page keeps the login too', () async {
      final _Gateway g = _Gateway()..meShed = 2;
      int waited = 0;
      final Session s = Session(
        api: await _signedIn(g),
        sleep: (Duration d) async => waited++,
      );

      expect(await s.restore(), isTrue);
      expect(waited, 2);
      expect(s.signedIn, isTrue);
    });

    test('the 404 of a database that is down keeps the login too', () async {
      final _Gateway g = _Gateway()..meNoDb = 2;
      int waited = 0;
      final Session s = Session(
        api: await _signedIn(g),
        sleep: (Duration d) async => waited++,
      );

      expect(await s.restore(), isTrue);
      expect(waited, 2);
    });

    test(
      'while it waits it says so, and the person may stop waiting',
      () async {
        final _Gateway g = _Gateway();
        final Completer<void> never = Completer<void>();
        final Session s = Session(
          api: await _signedIn(g),
          sleep: (Duration d) => never.future,
        );
        g.down = true;

        final Future<bool> resumed = s.restore();
        await Future<void>.delayed(Duration.zero);
        expect(s.reconnecting, isTrue);
        expect(s.restoring, isTrue);

        s.stopReconnecting();
        expect(await resumed, isFalse);
        expect(s.reconnecting, isFalse);
        expect(s.restoring, isFalse, reason: 'the sign-in form is shown');
        expect(
          s.api.isAuthenticated,
          isTrue,
          reason: 'the saved login stays, so a reload tries it again',
        );
      },
    );

    testWidgets('the spinner names the wait and offers the sign-in form', (
      WidgetTester t,
    ) async {
      final _Gateway g = _Gateway();
      final Completer<void> never = Completer<void>();
      final Session s = Session(
        api: await _signedIn(g),
        sleep: (Duration d) => never.future,
      );
      g.down = true;
      await t.pumpWidget(MaterialApp(home: Resuming(session: s)));
      expect(find.text('Sign in again'), findsNothing, reason: 'first try');

      final Future<bool> resumed = s.restore();
      await t.pump();
      expect(
        find.text('No connection to the server. Trying again automatically.'),
        findsOne,
      );

      await t.tap(find.text('Sign in again'));
      expect(await resumed, isFalse);
    });

    test(
      'a network error while renewing an expired token keeps both tokens',
      () async {
        final _Gateway g = _Gateway();
        final Session s = Session(
          api: await _signedIn(g),
          sleep: (Duration d) async {},
        );
        final List<(bool, bool)> seen = _screens(s);

        // The bearer expired overnight and the renewal meets the restart.
        g
          ..live = 'expired'
          ..refreshDrops = 1;
        expect(await s.restore(), isTrue);

        expect(g.refreshSent, <Object?>[
          'r1',
          'r1',
        ], reason: 'the refresh token survived the failed renewal');
        expect(s.signedIn, isTrue);
        expect(seen, isNot(contains((false, false))));
      },
    );

    // The gateway's 400 is its crash page (a database that flaps), a 403 is
    // no verdict on the token, and the 404 is Odoo with no database: none of
    // them retires the refresh token, so none of them may sign out.
    for (final int code in <int>[400, 403, 404]) {
      test(
        'a $code from the refresh call keeps the login and asks again',
        () async {
          final _Gateway g = _Gateway()..refreshStatus = code;
          final List<bool> reconnecting = <bool>[];
          late final Session s;
          s = Session(
            api: await _signedIn(g),
            sleep: (Duration d) async {
              reconnecting.add(s.reconnecting);
              g.refreshStatus = 200;
            },
          );
          final List<(bool, bool)> seen = _screens(s);

          g.live = 'expired';
          expect(await s.restore(), isTrue);

          expect(
            reconnecting,
            <bool>[true],
            reason: '"No connection to the server", with its Sign in again',
          );
          expect(g.refreshSent, <Object?>[
            'r1',
            'r1',
          ], reason: 'the refresh token survived the refusal');
          expect(s.signedIn, isTrue);
          expect(seen, isNot(contains((false, false))));
        },
      );
    }

    test(
      'a 401 from the refresh call still sends the user to sign in',
      () async {
        final _Gateway g = _Gateway()..refreshStatus = 401;
        int waited = 0;
        final Session s = Session(
          api: await _signedIn(g),
          sleep: (Duration d) async => waited++,
        );

        g.live = 'expired';
        expect(await s.restore(), isFalse);

        expect(s.signedIn, isFalse);
        expect(s.restoring, isFalse);
        expect(s.api.isAuthenticated, isFalse);
        expect(waited, 0, reason: 'a refusal is final, nothing is retried');
      },
    );
  });
}
