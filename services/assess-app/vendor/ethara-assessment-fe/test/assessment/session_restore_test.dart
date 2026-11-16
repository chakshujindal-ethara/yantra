// A refresh must not sign you out.
//
// THE BUG: sign-in returns a bearer token that lived only in an ApiClient
// field. A browser refresh restarts the Dart VM, so the token vanished and the
// app showed the login form while the server session was still open.
//
// These run on the VM: the token store is a conditional import whose web half
// needs a real `sessionStorage`. On the VM the stub answers "nothing stored", so
// the tests inject tokens through the constructor and drive `Session` directly -
// which is where the restore LOGIC lives. The storage half is covered by
// `token_store_web.dart` being the only other implementation of the same
// three-function contract.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/session.dart';

/// Records what the fake server was asked for, so a test can assert that a
/// stored token was VERIFIED rather than trusted.
class Calls {
  final List<String> paths = <String>[];
  final List<String?> auth = <String?>[];
}

http.Client fakeServer(
  Calls log, {
  required Map<String, dynamic> Function(String path, String? bearer) handler,
  int status = 200,
}) => MockClient((http.Request req) async {
  final String path = req.url.path;
  final String? bearer = req.headers['Authorization'];
  log.paths.add(path);
  log.auth.add(bearer);
  final Map<String, dynamic> body = handler(path, bearer);
  final int code = (body['__status'] as int?) ?? status;
  body.remove('__status');
  return http.Response(
    jsonEncode(body),
    code,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

Map<String, dynamic> okUser({String role = 'admin'}) => <String, dynamic>{
  'ok': true,
  'data': <String, dynamic>{
    'user': <String, dynamic>{
      'uid': '2',
      'name': 'Administrator',
      'role': role,
    },
  },
};

void main() {
  group('a stored token resumes the session', () {
    test('restore() adopts the role the SERVER reports', () async {
      final Calls log = Calls();
      final Session s = Session(
        api: ApiClient(
          client: fakeServer(
            log,
            handler: (String path, String? bearer) => okUser(role: 'admin'),
          ),
          baseUrl: 'http://x',
          bearer: 'stored-token',
        ),
      );

      expect(await s.restore(), isTrue);
      expect(s.signedIn, isTrue);
      expect(s.role, 'admin');
      expect(s.name, 'Administrator');
      // VERIFIED, not trusted: the stored bytes alone must never be enough.
      expect(log.paths, contains('/api/v1/auth/me'));
      expect(log.auth.last, 'Bearer stored-token');
    });

    test('restoring is false again once the answer lands', () async {
      final Calls log = Calls();
      final Session s = Session(
        api: ApiClient(
          client: fakeServer(
            log,
            handler: (String path, String? bearer) => okUser(),
          ),
          baseUrl: 'http://x',
          bearer: 't',
        ),
      );
      final List<bool> seen = <bool>[];
      s.addListener(() => seen.add(s.restoring));

      await s.restore();

      expect(seen.first, isTrue, reason: 'the gate must open before the call');
      expect(
        s.restoring,
        isFalse,
        reason: 'a stuck spinner is worse than a form',
      );
    });

    test('with NO stored token it does not call the server at all', () async {
      final Calls log = Calls();
      final Session s = Session(
        api: ApiClient(
          client: fakeServer(
            log,
            handler: (String path, String? bearer) => okUser(),
          ),
          baseUrl: 'http://x',
        ),
      );

      expect(await s.restore(), isFalse);
      expect(s.signedIn, isFalse);
      expect(
        log.paths,
        isEmpty,
        reason: 'a cold start must not make a doomed request',
      );
      expect(s.restoring, isFalse);
    });

    test('a REJECTED token falls back to the login form', () async {
      final Calls log = Calls();
      final Session s = Session(
        api: ApiClient(
          client: fakeServer(
            log,
            handler: (String path, String? bearer) => <String, dynamic>{
              '__status': 401,
              'ok': false,
              'error': <String, dynamic>{
                'code': 'unauthorized',
                'message': 'Session expired',
              },
            },
          ),
          baseUrl: 'http://x',
          bearer: 'expired',
        ),
      );

      expect(await s.restore(), isFalse);
      expect(
        s.signedIn,
        isFalse,
        reason: 'a dead token must not open the console',
      );
      expect(s.restoring, isFalse);
    });

    test('a token whose user has NO role is not a session', () async {
      // The module not recognising the user matters more than the token being
      // syntactically fine: an empty role would open a console with no
      // permissions behind it.
      final Calls log = Calls();
      final Session s = Session(
        api: ApiClient(
          client: fakeServer(
            log,
            handler: (String path, String? bearer) => okUser(role: ''),
          ),
          baseUrl: 'http://x',
          bearer: 'roleless',
        ),
      );

      expect(await s.restore(), isFalse);
      expect(s.signedIn, isFalse);
    });

    test(
      'an unreachable server keeps the spinner up, then resumes',
      () async {
        // Nor on the login form: it keeps the token and asks again. See
        // `a_network_error_keeps_the_saved_login_test.dart`.
        bool down = true;
        late final Session s;
        s = Session(
          api: ApiClient(
            client: MockClient((http.Request req) async {
              if (down) throw http.ClientException('down');
              return http.Response(
                jsonEncode(okUser()),
                200,
                headers: <String, String>{'content-type': 'application/json'},
              );
            }),
            baseUrl: 'http://x',
            bearer: 'whatever',
          ),
          sleep: (Duration d) async {
            expect(s.signedIn, isFalse);
            expect(s.restoring, isTrue);
            down = false;
          },
        );

        expect(await s.restore(), isTrue);
        expect(s.restoring, isFalse);
      },
    );
  });

  group('sign-in and restore agree', () {
    test('signIn refuses an account with no assessment role', () async {
      // Same rule as restore(): one path to the role, so the two cannot drift.
      final Calls log = Calls();
      final Session s = Session(
        api: ApiClient(
          client: fakeServer(
            log,
            handler: (String p, String? b) {
              if (p.contains('auth_token')) {
                return <String, dynamic>{
                  'ok': true,
                  'data': <String, dynamic>{'access_token': 'fresh'},
                };
              }
              return okUser(role: '');
            },
          ),
          baseUrl: 'http://x',
        ),
      );

      expect(await s.signIn('someone', 'pw'), isFalse);
      expect(s.signedIn, isFalse);
      expect(s.error, contains('no assessment role'));
    });

    test('signIn reports a refused session check as that, not as no role',
        () async {
      // `/auth/me` can answer 401 right after sign-in. That is an expired
      // session, not an account with no assessment role.
      final Calls log = Calls();
      final Session s = Session(
        api: ApiClient(
          client: fakeServer(
            log,
            handler: (String p, String? b) {
              if (p.contains('auth_token')) {
                return <String, dynamic>{
                  'ok': true,
                  'data': <String, dynamic>{'access_token': 'fresh'},
                };
              }
              return <String, dynamic>{
                '__status': 401,
                'ok': false,
                'code': 'session_expired',
                'message': 'Your session has expired. Sign in again.',
              };
            },
          ),
          baseUrl: 'http://x',
        ),
      );

      expect(await s.signIn('someone', 'pw'), isFalse);
      expect(s.error, isNot(contains('no assessment role')));
      expect(s.error, contains('Your session has expired'));
    });
  });
}
