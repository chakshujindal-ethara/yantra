// A spent refresh token must cost ONE request, not a browser tab.
//
// FOUND BY OPENING THE APP, not by reading the code. A stale bearer left over
// from an earlier session produced 195 consecutive 401s on
// `/api/v1/refresh_token` in a few seconds and then the tab crashed. The Odoo log
// was clean throughout - every one of those was a correct refusal.
//
// THE LOOP. `_send`'s 401 hook renews the bearer and replays the request, and it
// exempts `<prefix>/auth*` so a wrong password is never retried. `refresh_token`
// is a SIBLING of those routes, not a child - the path is
// `/api/v1/refresh_token`, which starts with neither `/api/v1/auth` nor
// `<gateway>/auth` - so the exemption never covered it:
//
//     _send(/refresh_token) -> 401 -> refreshSession()
//       -> _call(/refresh_token) -> _send(/refresh_token) -> 401 -> ...
//
// with a real HTTP request per cycle and nothing counting them.
//
// WHY IT MATTERS ON A DEPLOYED BUILD. A spent refresh token is the ordinary
// resting state of a returning user, not an exotic one: a password change revokes
// every token the account holds, so does a logout in another tab, and plain
// expiry gets there on its own. Every such client did this to itself AND to the
// backend on page load.
//
// The fix is one argument - `refreshSession` passes `allowRetry: false` - and it
// is the kind of argument a later edit drops without noticing, which is why the
// request COUNT is asserted here rather than the behaviour around it.
//
// TOKENS ARE ESTABLISHED BY SIGNING IN, because `_refresh` is private and there
// is no setter for it. That is the honest setup anyway: it is the path a real
// client takes to get into this state.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';

/// A gateway that hands out tokens once, then refuses everything.
///
/// [refuseAfterLogin] is the whole fixture: the client ends up holding a bearer
/// and a refresh token the server will no longer accept, which is exactly what a
/// password change or a logout elsewhere leaves behind.
class _Gateway {
  final List<String> paths = <String>[];

  /// Answered for the second and subsequent non-login calls. 401 by default,
  /// which is what a revoked credential gets.
  final int refusalStatus;

  bool _loggedIn = false;

  _Gateway({this.refusalStatus = 401});

  int countOf(String needle) =>
      paths.where((String p) => p.contains(needle)).length;

  http.Response _json(Map<String, dynamic> body, int status) => http.Response(
    jsonEncode(body),
    status,
    headers: <String, String>{'content-type': 'application/json'},
  );

  http.Client get client => MockClient((http.Request req) async {
    final String path = req.url.path;
    paths.add(path);

    // A runaway loop would spin here until the test timed out with nothing
    // useful in the failure. Trip early and say what happened.
    if (paths.length > 40) {
      return _json(<String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{
          'code': 'test_tripwire',
          'message': 'runaway retry: ${paths.length} requests',
        },
      }, 500);
    }

    if (path.contains('auth_token') && !_loggedIn) {
      _loggedIn = true;
      return _json(<String, dynamic>{
        'ok': true,
        'access_token': 'bearer-1',
        'refresh_token': 'refresh-1',
      }, 200);
    }

    return _json(<String, dynamic>{
      'ok': false,
      'error': <String, dynamic>{
        'code': 'session_expired',
        'message': 'Your session has expired. Sign in again.',
      },
    }, refusalStatus);
  });
}

/// A client holding a bearer and a refresh token the server has since revoked.
Future<ApiClient> _signedInThenRevoked(_Gateway gateway) async {
  final ApiClient api = ApiClient(
    baseUrl: 'http://stub',
    client: gateway.client,
  );
  await api.login('cj@example.com', 'secret');
  gateway.paths.clear(); // the login itself is not what is being counted
  return api;
}

void main() {
  group('a refused renewal is asked once and believed', () {
    test('a rejected refresh token costs exactly one request', () async {
      final _Gateway gateway = _Gateway();
      final ApiClient api = await _signedInThenRevoked(gateway);

      final bool renewed = await api.refreshSession();

      expect(renewed, isFalse, reason: 'the gateway said no');
      expect(
        gateway.countOf('refresh_token'),
        1,
        reason: 'THE BUG: this was unbounded, and every cycle was a real HTTP '
            'request. 195 of them crashed a browser tab.',
      );
    });

    test('and it does not keep the credentials it was refused with', () async {
      final _Gateway gateway = _Gateway();
      final ApiClient api = await _signedInThenRevoked(gateway);

      await api.refreshSession();
      final bool second = await api.refreshSession();

      expect(
        second,
        isFalse,
        reason: 'with no refresh token left there is nothing to try',
      );
      expect(
        gateway.countOf('refresh_token'),
        1,
        reason: 'the second attempt must not reach the wire at all - keeping a '
            'token the server has rejected means every later reload repeats '
            'the same failure',
      );
    });

    test('a call that triggers a failed renewal is not replayed', () async {
      // The other half of the loop: the request that triggered the renewal must
      // surface its own 401 rather than be sent again on a token the gateway has
      // just refused.
      final _Gateway gateway = _Gateway();
      final ApiClient api = await _signedInThenRevoked(gateway);

      await expectLater(api.tags(), throwsA(isA<ApiError>()));

      expect(gateway.countOf('refresh_token'), 1, reason: 'one renewal');
      expect(
        gateway.countOf('/tags'),
        1,
        reason: 'and the original call is not replayed against a dead token',
      );
      expect(
        gateway.paths.length,
        lessThan(5),
        reason: 'the whole exchange is a handful of requests, not a storm',
      );
    });

    test('a 403 on the renewal does not loop either', () async {
      // The hook keys on 401, but a gateway that answers 403 to a revoked token
      // must not find some other way round the guard.
      final _Gateway gateway = _Gateway(refusalStatus: 403);
      final ApiClient api = await _signedInThenRevoked(gateway);

      await api.refreshSession();

      expect(gateway.countOf('refresh_token'), 1);
    });
  });

  group('the renewal still works, which is the point of having it', () {
    test('an expired bearer is renewed once and the call replayed once',
        () async {
      // THE GUARD MUST NOT HAVE BROKEN THE FEATURE. A token that expires
      // mid-exam has to be renewed transparently or a 45-minute sitting loses
      // its autosaves - which is the reason the 401 hook exists at all.
      final List<String> seen = <String>[];
      bool loggedIn = false;
      bool bearerRenewed = false;

      http.Response json(Map<String, dynamic> b, int s) => http.Response(
        jsonEncode(b),
        s,
        headers: <String, String>{'content-type': 'application/json'},
      );

      final ApiClient api = ApiClient(
        baseUrl: 'http://stub',
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          seen.add(path);
          if (path.contains('auth_token') && !loggedIn) {
            loggedIn = true;
            return json(<String, dynamic>{
              'ok': true,
              'access_token': 'bearer-1',
              'refresh_token': 'refresh-1',
            }, 200);
          }
          if (path.contains('refresh_token')) {
            bearerRenewed = true;
            return json(<String, dynamic>{
              'ok': true,
              'access_token': 'bearer-2',
              'refresh_token': 'refresh-2',
            }, 200);
          }
          // The first /tags 401s; the replay after the renewal succeeds.
          if (!bearerRenewed) {
            return json(<String, dynamic>{
              'ok': false,
              'error': <String, dynamic>{'code': 'session_expired'},
            }, 401);
          }
          return json(<String, dynamic>{'ok': true, 'data': <dynamic>[]}, 200);
        }),
      );

      await api.login('cj@example.com', 'secret');
      seen.clear();

      await api.tags();

      expect(
        seen.where((String p) => p.contains('refresh_token')).length,
        1,
        reason: 'exactly one renewal',
      );
      expect(
        seen.where((String p) => p.contains('/tags')).length,
        2,
        reason: 'the original call plus one replay - the whole point of the '
            'hook is that the caller never sees the expiry',
      );
    });
  });
}
