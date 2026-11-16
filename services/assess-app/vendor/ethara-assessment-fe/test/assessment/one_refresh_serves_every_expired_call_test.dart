// An expired token is renewed ONCE, however many calls find it expired.
//
// A dashboard load fires ~9 calls at once. When the bearer hits its 100-hour
// expiry each gets a 401, and the gateway ROTATES the access token on every
// refresh (`api.access_token.update_access_token`), killing the one the
// previous refresh handed out. Nine separate refreshes leave 1 of 9 tokens
// valid and 2-3 retries failing with "Your session has expired. Sign in
// again." on a perfectly renewable session.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';

/// The gateway's contract: one live access token per refresh token, and every
/// refresh replaces it.
class FakeGateway {
  FakeGateway({this.stagger = Duration.zero});

  /// Extra latency per request, in arrival order, so some 401s land after
  /// the refresh they could have waited for has already finished.
  final Duration stagger;
  String live = 'old';
  int refreshes = 0;
  int _seen = 0;

  http.Client get client => MockClient((http.Request req) async {
    final int n = _seen++;
    await Future<void>.delayed(const Duration(milliseconds: 5) + stagger * n);
    final String path = req.url.path;
    if (path.endsWith('/auth_token')) {
      return _json(<String, dynamic>{
        'data': <String, dynamic>{'access_token': live, 'refresh_token': 'r'},
      });
    }
    if (path.endsWith('/refresh_token')) {
      refreshes++;
      live = 'new$refreshes';
      return _json(<String, dynamic>{'access_token': live, 'refresh_token': 'r'});
    }
    if (req.headers['Authorization'] != 'Bearer $live') {
      return _json(<String, dynamic>{
        'ok': false,
        'code': 'session_expired',
        'message': 'Your session has expired. Sign in again.',
      }, 401);
    }
    return _json(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}});
  });

  static http.Response _json(Map<String, dynamic> body, [int status = 200]) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: <String, String>{'content-type': 'application/json'},
      );
}

void main() {
  test('nine calls on an expired token share one refresh', () async {
    final FakeGateway gateway = FakeGateway();
    final ApiClient api = ApiClient(client: gateway.client, baseUrl: 'http://x');
    await api.login('u', 'p');
    gateway.live = 'expired-by-the-server';

    final List<Object?> outcomes = await Future.wait(<Future<Object?>>[
      for (int i = 0; i < 9; i++)
        api.myDashboard().then<Object?>((_) => null, onError: (Object e) => e),
    ]);

    expect(outcomes.whereType<ApiError>(), isEmpty);
    expect(gateway.refreshes, 1);
  });

  test('a 401 that lands after the refresh retries instead of refreshing again',
      () async {
    final FakeGateway gateway = FakeGateway(
      stagger: const Duration(milliseconds: 15),
    );
    final ApiClient api = ApiClient(client: gateway.client, baseUrl: 'http://x');
    await api.login('u', 'p');
    gateway.live = 'expired-by-the-server';

    final List<Object?> outcomes = await Future.wait(<Future<Object?>>[
      for (int i = 0; i < 6; i++)
        api.myDashboard().then<Object?>((_) => null, onError: (Object e) => e),
    ]);

    expect(outcomes.whereType<ApiError>(), isEmpty);
    expect(gateway.refreshes, 1);
  });
}
