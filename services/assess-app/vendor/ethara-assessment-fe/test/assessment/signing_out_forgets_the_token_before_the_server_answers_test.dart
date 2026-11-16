// Sign-out is bounded: a stalled connection must not hold a candidate at a
// shared machine. So the logout request can still be on the wire after the app
// has moved on, and three things must hold while it is:
//
//  1. this client has already forgotten the credential, in memory and on the
//     device (a reload in that window must not sign the next person in as the
//     last one);
//  2. when the stalled request finally ends, it must not sign out whoever has
//     signed in on the same client in the meantime;
//  3. a token renewal that was racing the logout must not bring the session
//     back.
//
// The saved copy lives in the browser (`token_store_web.dart`); on the VM the
// store is a stub, so the device half of (1) is checked in a browser. The
// memory half, (2) and (3) are pinned here.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';

http.Response _json(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

void main() {
  test('a logout that ends late does not sign out the next person', () async {
    final Completer<void> stalled = Completer<void>();
    final List<String> seen = <String>[];
    String issue = 'first';
    final http.Client client = MockClient((http.Request req) async {
      final String path = req.url.path;
      if (path.endsWith('/auth_token')) {
        return _json(<String, dynamic>{
          'data': <String, dynamic>{
            'access_token': issue,
            'refresh_token': 'r-$issue',
          },
        });
      }
      if (path.endsWith('/auth/logout')) {
        seen.add('logout as ${req.headers['Authorization']}');
        await stalled.future;
        return _json(<String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{},
        });
      }
      seen.add('${path.split('/').last} as ${req.headers['Authorization']}');
      return _json(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}});
    });
    final ApiClient api = ApiClient(client: client, baseUrl: 'http://x');

    await api.login('a@example.com', 'pw');
    expect(api.isAuthenticated, isTrue);

    // The first person signs out; the server never answers in time.
    final Future<void> leaving = api.logout();
    expect(
      api.isAuthenticated,
      isFalse,
      reason: 'forgotten before the request has even gone out',
    );
    // The device copy goes in the same step (`_persistTokens`, which also
    // republishes the media credential): a reload while this stalls must not
    // sign the next person in as this one.
    expect(mediaAuthHeaders, isEmpty, reason: 'the saved copy goes too');
    await Future<void>.delayed(Duration.zero);
    expect(seen, <String>[
      'logout as Bearer first',
    ], reason: 'the request itself still carries the credential it is ending');

    // The next person signs in on the same client.
    issue = 'second';
    await api.login('b@example.com', 'pw');
    expect(api.isAuthenticated, isTrue);

    // Now the stalled logout ends.
    stalled.complete();
    await leaving;

    expect(
      api.isAuthenticated,
      isTrue,
      reason: 'the late logout ended the FIRST session, not this one',
    );
    await api.assessment('7');
    expect(
      seen.last,
      '7 as Bearer second',
      reason: 'the second person still sends their own token',
    );
  });

  test('a renewal racing the logout cannot bring the session back', () async {
    final Completer<void> renewal = Completer<void>();
    int refreshes = 0;
    final http.Client client = MockClient((http.Request req) async {
      final String path = req.url.path;
      if (path.endsWith('/auth_token')) {
        return _json(<String, dynamic>{
          'data': <String, dynamic>{
            'access_token': 'expired',
            'refresh_token': 'r',
          },
        });
      }
      if (path.endsWith('/refresh_token')) {
        refreshes++;
        await renewal.future;
        return _json(<String, dynamic>{
          'access_token': 'renewed',
          'refresh_token': 'r2',
        });
      }
      if (path.endsWith('/auth/logout')) {
        return _json(<String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{},
        });
      }
      // Everything else: this token has expired.
      return _json(<String, dynamic>{
        'ok': false,
        'code': 'session_expired',
        'message': 'Your session has expired. Sign in again.',
      }, 401);
    });
    final ApiClient api = ApiClient(client: client, baseUrl: 'http://x');
    await api.login('a@example.com', 'pw');

    // A call finds the token expired and starts a renewal, which hangs.
    final Future<Object?> call = api
        .assessment('7')
        .then<Object?>((Map<String, dynamic> v) => v)
        .catchError((Object e) => e);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(refreshes, 1);

    // The person signs out while it is out.
    await api.logout();
    expect(api.isAuthenticated, isFalse);

    // The renewal now succeeds, with a brand new pair.
    renewal.complete();
    expect(await call, isA<ApiError>());
    expect(
      api.isAuthenticated,
      isFalse,
      reason: 'the renewed pair belongs to a session that ended here',
    );
  });

  test('a logout that ends in time signs the person out', () async {
    final http.Client client = MockClient((http.Request req) async {
      if (req.url.path.endsWith('/auth_token')) {
        return _json(<String, dynamic>{
          'data': <String, dynamic>{'access_token': 't', 'refresh_token': 'r'},
        });
      }
      return _json(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}});
    });
    final ApiClient api = ApiClient(client: client, baseUrl: 'http://x');
    await api.login('a@example.com', 'pw');
    await api.logout();
    expect(api.isAuthenticated, isFalse);
  });

  test(
    'a refusal that lands after the next sign-in does not sign them out',
    () async {
      final Completer<void> renewal = Completer<void>();
      String issue = 'expired';
      final http.Client client = MockClient((http.Request req) async {
        final String path = req.url.path;
        if (path.endsWith('/auth_token')) {
          return _json(<String, dynamic>{
            'data': <String, dynamic>{
              'access_token': issue,
              'refresh_token': 'r-$issue',
            },
          });
        }
        if (path.endsWith('/refresh_token')) {
          await renewal.future;
          return _json(<String, dynamic>{
            'message': 'Invalid Refresh Token',
          }, 401);
        }
        if (path.endsWith('/auth/logout')) {
          return _json(<String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{},
          });
        }
        if (req.headers['Authorization'] == 'Bearer expired') {
          return _json(<String, dynamic>{
            'ok': false,
            'message': 'Your session has expired. Sign in again.',
          }, 401);
        }
        return _json(<String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{},
        });
      });
      final ApiClient api = ApiClient(client: client, baseUrl: 'http://x');
      await api.login('a@example.com', 'pw');

      // A's call finds the token expired; the renewal hangs.
      final Future<Object?> call = api
          .assessment('7')
          .then<Object?>((Map<String, dynamic> v) => v)
          .catchError((Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // A leaves, B signs in on the same client.
      await api.logout();
      issue = 'second';
      await api.login('b@example.com', 'pw');

      // Now A's renewal is refused.
      renewal.complete();
      await call;
      expect(
        api.isAuthenticated,
        isTrue,
        reason: "the refusal was of A's refresh token, not B's",
      );
    },
  );

  test('a renewal that meets no connection mid-call keeps both tokens and '
      'reports no connection, not an expired session', () async {
    bool down = false;
    final http.Client client = MockClient((http.Request req) async {
      final String path = req.url.path;
      if (path.endsWith('/auth_token')) {
        return _json(<String, dynamic>{
          'data': <String, dynamic>{
            'access_token': 'expired',
            'refresh_token': 'r',
          },
        });
      }
      if (path.endsWith('/refresh_token')) {
        if (down) throw http.ClientException('Failed to fetch');
        return _json(<String, dynamic>{
          'access_token': 'a2',
          'refresh_token': 'r2',
        });
      }
      if (req.headers['Authorization'] == 'Bearer expired') {
        down = true; // the connection drops as the renewal goes out
        return _json(<String, dynamic>{
          'ok': false,
          'message': 'Your session has expired. Sign in again.',
        }, 401);
      }
      return _json(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}});
    });
    final ApiClient api = ApiClient(client: client, baseUrl: 'http://x');
    await api.login('a@example.com', 'pw');

    await expectLater(
      api.assessment('7'),
      throwsA(
        isA<ApiError>().having(
          (ApiError e) => e.isTransport,
          'isTransport',
          isTrue,
        ),
      ),
    );
    expect(api.isAuthenticated, isTrue);
    expect(
      api.canRenew,
      isTrue,
      reason: 'the refresh token is kept to try again',
    );
  });
}
