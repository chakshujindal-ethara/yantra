// Trading a Yantra launch ticket for a session: one redeem, then the same
// `/auth/me` every sign-in goes through. A spent or expired ticket says so in
// words a worker can act on, and points back to Yantra.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/session.dart';
import 'package:ethara_assessment/yantra_launch.dart';

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

const Map<String, Object?> _grant = <String, Object?>{
  'access_token': 'bearer-1',
  'refresh_token': '',
  'expires_at': '2026-11-12 12:00:00',
  'exam_token': 'exam-1',
  'next': null,
  'return_url': 'http://localhost:8095/work/applications',
};

void main() {
  setUp(() => rememberYantraReturn(null));

  test('a ticket buys a bearer that every later call carries', () async {
    final List<http.Request> seen = <http.Request>[];
    final Session s = Session(
      api: ApiClient(
        baseUrl: 'http://app',
        client: MockClient((http.Request r) async {
          seen.add(r);
          if (r.url.path == '/api/v1/yantra/launch/redeem') {
            return _json(200, <String, Object?>{'ok': true, 'data': _grant});
          }
          return _json(200, <String, Object?>{
            'ok': true,
            'data': <String, Object?>{
              'user': <String, Object?>{
                'name': 'Worker Four',
                'uid': 8,
                'role': 'candidate',
              },
            },
          });
        }),
      ),
    );
    LaunchGrant? granted;
    expect(await s.launch('t-1', onGrant: (LaunchGrant g) => granted = g),
        isTrue);
    expect(jsonDecode(seen.first.body), <String, Object?>{'ticket': 't-1'});
    expect(seen.first.headers['Authorization'], isNull);
    expect(seen.last.url.path, '/api/v1/auth/me');
    expect(seen.last.headers['Authorization'], 'Bearer bearer-1');
    expect(granted?.examToken, 'exam-1');
    expect(granted?.next, isNull);
    expect(s.signedIn, isTrue);
    expect(s.restoring, isFalse);
    expect(s.name, 'Worker Four');
    expect(s.api.canRenew, isFalse, reason: 'a launch has no refresh token');
    expect(yantraReturnUrl(yantraAppUrl: ''),
        'http://localhost:8095/work/applications');
  });

  test('a spent, expired or unknown ticket is named, and nobody is signed in',
      () async {
    for (final (int status, String code, String words) in <(int, String, String)>[
      (410, 'ticket_used', 'already been used'),
      (410, 'ticket_expired', 'expired'),
      (404, 'invalid_ticket', 'not valid'),
      (403, 'account_inactive', 'not active'),
    ]) {
      final Session s = Session(
        api: ApiClient(
          baseUrl: 'http://app',
          client: MockClient((http.Request r) async => _json(status, <String, Object?>{
            'ok': false,
            'error': <String, Object?>{'code': code, 'message': code},
          })),
        ),
      );
      expect(await s.launch('t'), isFalse, reason: code);
      expect(s.signedIn, isFalse);
      expect(s.restoring, isFalse);
      expect(s.error, contains(words), reason: code);
      expect(s.error, contains('Yantra'), reason: code);
    }
  });

  test('a bearer the module does not recognise is not a session', () async {
    final Session s = Session(
      api: ApiClient(
        baseUrl: 'http://app',
        client: MockClient((http.Request r) async {
          if (r.url.path == '/api/v1/yantra/launch/redeem') {
            return _json(200, <String, Object?>{'ok': true, 'data': _grant});
          }
          if (r.url.path == '/api/v1/auth/me') {
            return _json(200, <String, Object?>{
              'ok': true,
              'data': <String, Object?>{'user': <String, Object?>{}},
            });
          }
          return _json(200, <String, Object?>{'ok': true, 'data': {}});
        }),
      ),
    );
    expect(await s.launch('t'), isFalse);
    expect(s.signedIn, isFalse);
    expect(s.error, contains('no assessment role'));
  });

  test('a server that does not answer is said plainly', () async {
    final Session s = Session(
      api: ApiClient(
        baseUrl: 'http://app',
        client: MockClient((http.Request r) async => throw http.ClientException('down')),
      ),
    );
    expect(await s.launch('t'), isFalse);
    expect(s.error, contains('Could not reach'));
  });
}
