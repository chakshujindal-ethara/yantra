// Sign-in flow, against a stubbed transport.
//
// These exercise the real `ApiClient` request and envelope handling and the
// store's `adoptSession` role mapping; only the socket is faked. That is
// deliberate: the bugs worth catching here are in how the app reads the
// module's envelope and what it does with the role, not in whether `dart:io`
// can open a connection.
import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A client that answers the API's real envelope shapes.
///
/// By default it behaves like a deployment WITHOUT `api_auth_gateway`: the
/// bearer route 404s, so `login` falls through to the module's own cookie
/// endpoint. That is the standalone case, and it keeps these tests focused on
/// the module contract. `gateway: true` flips it to the shared-gateway case.
http.Client _stub({
  required Map<String, dynamic> Function(String path) handler,
  int status = 200,
  bool gateway = false,
}) {
  return MockClient((http.Request req) async {
    final String path = req.url.path;

    // The gateway addon is absent unless a test says otherwise. A 404 is what
    // makes `login` try the module route, so it has to be a real 404 here.
    if (path.endsWith('/auth_token') && !gateway) {
      return http.Response(
        jsonEncode(<String, dynamic>{'ok': false, 'message': 'Not Found'}),
        404,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }

    final Map<String, dynamic> body = handler(path);
    return http.Response(
      jsonEncode(body),
      body['ok'] == false ? status : 200,
      headers: <String, String>{
        'content-type': 'application/json',
        // Odoo sets the session cookie on the login response; the client has to
        // capture it or every later call is unauthenticated.
        'set-cookie': 'session_id=stub-session-abc; Path=/; HttpOnly',
      },
    );
  });
}

void main() {
  group('ApiClient envelope', () {
    test('unwraps data and captures the session cookie', () async {
      final ApiClient api = ApiClient(
        baseUrl: 'http://stub',
        client: _stub(
          handler: (_) => <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{
              'user': <String, dynamic>{
                'uid': 2,
                'name': 'Admin',
                'role': 'admin',
              },
            },
          },
        ),
      );

      expect(api.isAuthenticated, isFalse);
      final Map<String, dynamic> res = await api.login('admin', 'admin');

      expect(res['user'], isA<Map<String, dynamic>>());
      expect(
        api.isAuthenticated,
        isTrue,
        reason:
            'the Set-Cookie header must be captured, or every '
            'subsequent call is anonymous',
      );
    });

    test(
      'a refusal becomes a domain ApiError carrying the module text',
      () async {
        // The REAL shape the module answers with: the reason is nested under
        // `error`, not flat. Verified against a live /api/v1/scoring/queue,
        // which returns exactly this on an empty body.
        final ApiClient api = ApiClient(
          baseUrl: 'http://stub',
          client: _stub(
            status: 400,
            handler: (_) => <String, dynamic>{
              'ok': false,
              'error': <String, dynamic>{
                'code': 'missing_target',
                'message': 'Provide assessment_id or evaluator_ids',
              },
            },
          ),
        );

        await expectLater(
          api.login('admin', 'nope'),
          throwsA(
            isA<ApiError>()
                .having((ApiError e) => e.isDomain, 'isDomain', isTrue)
                .having((ApiError e) => e.code, 'code', 'missing_target')
                .having(
                  (ApiError e) => e.message,
                  'message',
                  'Provide assessment_id or evaluator_ids',
                ),
          ),
        );
      },
    );

    test('a flat refusal is still understood', () async {
      final ApiClient api = ApiClient(
        baseUrl: 'http://stub',
        client: _stub(
          status: 401,
          handler: (_) => <String, dynamic>{
            'ok': false,
            'code': 'invalid_credentials',
            'message': 'Wrong email or password.',
          },
        ),
      );

      await expectLater(
        api.login('admin', 'nope'),
        throwsA(
          isA<ApiError>()
              .having((ApiError e) => e.code, 'code', 'invalid_credentials')
              .having(
                (ApiError e) => e.message,
                'message',
                'Wrong email or password.',
              ),
        ),
      );
    });

    test(
      'a non-JSON body is a transport failure, not a domain refusal',
      () async {
        // Odoo answers an expired session on a NON-api route with an HTML
        // redirect; if that ever reaches the client it must not be reported to
        // the user as though the module had said something.
        final ApiClient api = ApiClient(
          baseUrl: 'http://stub',
          client: MockClient(
            (http.Request req) async =>
                http.Response('<!DOCTYPE html><title>Login</title>', 401),
          ),
        );

        await expectLater(
          api.login('admin', 'admin'),
          throwsA(
            isA<ApiError>().having(
              (ApiError e) => e.isDomain,
              'isDomain',
              isFalse,
            ),
          ),
        );
      },
    );
  });

  group('adoptSession', () {
    // The live sign-in is `Session.signIn` -> `/auth/me` -> `adoptSession`
    // (app_shell.dart). `/auth/me` sends `role` as exactly "admin" or
    // "member" (serializers.py `portal_role`).
    AppStore store() => AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        client: _stub(
          handler: (_) => <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{},
          },
        ),
      ),
    );

    test('takes the role from the SERVER and opens that portal', () {
      final AppStore s = store()
        ..adoptSession(orgRole: 'member', name: 'Sana Kapoor', uid: '41');
      expect(
        s.portal,
        Portal.member,
        reason:
            'a candidate must land in the candidate portal, and the '
            'client never gets to choose',
      );
      expect(s.meName, 'Sana Kapoor');
      expect(s.meId, '41');
      expect(s.source, DataSource.live);
    });

    test('an admin role opens the admin portal', () {
      expect((store()..adoptSession(orgRole: 'admin')).portal, Portal.admin);
    });

    test('an unknown role never opens the admin portal', () {
      expect((store()..adoptSession(orgRole: 'user')).portal, Portal.member);
    });

    // The live path's half of what `AppStore.signIn` used to pin: a refusal
    // leaves nothing for `adoptSession` to adopt.
    test('a failed sign-in leaves the session signed out', () async {
      final Session session = Session(
        api: ApiClient(
          baseUrl: 'http://stub',
          client: _stub(
            status: 401,
            handler: (_) => <String, dynamic>{
              'ok': false,
              'code': 'invalid_credentials',
              'message': 'Wrong email or password.',
            },
          ),
        ),
      );
      addTearDown(session.dispose);

      expect(await session.signIn('admin', 'wrong'), isFalse);
      expect(session.signedIn, isFalse);
      expect(
        session.name,
        isEmpty,
        reason: 'a rejected sign-in must not half-populate the session',
      );
      expect(session.role, isEmpty);
      expect(session.error, isNotNull);
    });
  });

  group('Gateway auth (api_auth_gateway)', () {
    // The shared org gateway is PREFERRED over the module's own login: it is
    // what the rest of the Ethara frontend already uses, so signing in here
    // joins the same session rather than opening a second one.

    http.Client gatewayStub({
      Map<String, dynamic>? user,
      int authTokenStatus = 200,
      Map<String, dynamic>? authTokenBody,
    }) {
      return MockClient((http.Request req) async {
        final String path = req.url.path;
        if (path.endsWith('/auth_token')) {
          return http.Response(
            jsonEncode(
              authTokenBody ??
                  <String, dynamic>{
                    'ok': true,
                    'data': <String, dynamic>{
                      'access_token': 'tok-abc',
                      'refresh_token': 'ref-xyz',
                      'uid': 9,
                      'name': 'Priya Nair',
                      ...?user,
                    },
                  },
            ),
            authTokenStatus,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
    }

    test('a bearer token is used, and no cookie is needed', () async {
      final ApiClient api = ApiClient(
        baseUrl: 'http://stub',
        client: gatewayStub(),
      );

      await api.login('priya', 'pw');
      expect(
        api.isAuthenticated,
        isTrue,
        reason:
            'the access_token alone must count as signed in - the '
            'gateway sets no session cookie',
      );
    });

    test('an org role maps onto a portal', () async {
      // pod_roles describes a JOB; the ETP groups describe what someone may do
      // inside an assessment. This is the bridge between them.
      expect(Portal.fromOrgRole('admin'), Portal.admin);
      expect(Portal.fromOrgRole('pm'), Portal.admin);
      expect(Portal.fromOrgRole('pl'), Portal.admin);
      expect(Portal.fromOrgRole('tasker'), Portal.member);
      expect(Portal.fromOrgRole('guest'), Portal.member);
      expect(
        Portal.fromOrgRole(''),
        Portal.member,
        reason:
            'an unknown role must fall to the SAFE side - a candidate '
            'surface only ever shows a person their own attempts',
      );
      expect(Portal.fromOrgRole(null), Portal.member);
    });

    test('a missing gateway falls through to the module login', () async {
      bool triedModule = false;
      final ApiClient api = ApiClient(
        baseUrl: 'http://stub',
        client: MockClient((http.Request req) async {
          if (req.url.path.endsWith('/auth_token')) {
            return http.Response(
              '{"ok":false}',
              404,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          triedModule = true;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{
                'user': <String, dynamic>{'uid': 2, 'role': 'admin'},
              },
            }),
            200,
            headers: <String, String>{
              'content-type': 'application/json',
              'set-cookie': 'session_id=fallback; Path=/',
            },
          );
        }),
      );

      await api.login('admin', 'admin');
      expect(
        triedModule,
        isTrue,
        reason: 'a 404 means the addon is absent, so try the module route',
      );
      expect(api.isAuthenticated, isTrue);
    });

    test(
      'a WRONG PASSWORD is not retried against the second endpoint',
      () async {
        // Retrying a real refusal would log two failed attempts for one typo,
        // and on a server with lockout that is twice the damage.
        int moduleCalls = 0;
        final ApiClient api = ApiClient(
          baseUrl: 'http://stub',
          client: MockClient((http.Request req) async {
            if (req.url.path.endsWith('/auth_token')) {
              return http.Response(
                jsonEncode(<String, dynamic>{
                  'ok': false,
                  'message': 'Wrong email or password.',
                }),
                401,
                headers: <String, String>{'content-type': 'application/json'},
              );
            }
            moduleCalls++;
            return http.Response(
              '{"ok":true,"data":{}}',
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
        );

        await expectLater(
          api.login('admin', 'wrong'),
          throwsA(isA<ApiError>()),
        );
        expect(moduleCalls, 0);
      },
    );

    test('an expired token is renewed without a new password', () async {
      final ApiClient api = ApiClient(
        baseUrl: 'http://stub',
        client: MockClient((http.Request req) async {
          if (req.url.path.endsWith('/auth_token')) {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': true,
                'data': <String, dynamic>{
                  'access_token': 'first',
                  'refresh_token': 'ref-1',
                  'uid': 2,
                },
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          if (req.url.path.endsWith('/refresh_token')) {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': true,
                'data': <String, dynamic>{
                  'access_token': 'second',
                  'refresh_token': 'ref-2',
                },
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response(
            '{"ok":true,"data":{}}',
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      await api.login('a', 'b');
      expect(await api.refreshSession(), isTrue);
      expect(api.isAuthenticated, isTrue);
    });

    test('a cookie session reports no refresh rather than throwing', () async {
      final ApiClient api = ApiClient(
        baseUrl: 'http://stub',
        client: _stub(
          handler: (_) => <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{
              'user': <String, dynamic>{'uid': 2},
            },
          },
        ),
      );

      await api.login('admin', 'admin');
      expect(
        await api.refreshSession(),
        isFalse,
        reason:
            'the cookie path has no refresh token; the caller should '
            'ask for a password rather than see an exception',
      );
    });
  });

  group('Wire format', () {
    // The module speaks snake_case; this app speaks camelCase. Before `jget`
    // existed every field silently fell back to its default, so a live payload
    // parsed "successfully" into a row of zeros.
    test(
      'an assessment row parses the API spelling, not just the fixtures',
      () {
        final Map<String, dynamic> wire = <String, dynamic>{
          'id': 12,
          'name': 'Warehouse Safety',
          'state': 'running',
          'generator': <String, dynamic>{'id': 3, 'name': 'SOP-14'},
          'question_limit': 20,
          'duration_minutes': 45,
          'assigned_count': 8,
          'submitted_count': 5,
          'releasable_count': 2,
          'response_count': 100,
        };

        final Assessment a = Assessment.fromJson(wire);

        expect(a.id, '12', reason: 'an integer id must survive as a String');
        expect(a.name, 'Warehouse Safety');
        expect(
          a.generatorName,
          'SOP-14',
          reason: 'the generator arrives nested',
        );
        expect(a.questionLimit, 20);
        expect(a.durationMinutes, 45);
        expect(a.assignedCount, 8);
        expect(a.submittedCount, 5);
        expect(a.releasableCount, 2);
      },
    );

    test('a fixture row still parses the camelCase spelling', () {
      final Assessment a = Assessment.fromJson(<String, dynamic>{
        'id': 'A-1',
        'name': 'Seeded',
        'questionLimit': 6,
        'durationMinutes': 30,
      });

      expect(a.id, 'A-1');
      expect(a.questionLimit, 6);
      expect(a.durationMinutes, 30);
      expect(
        a.assignedCount,
        -1,
        reason:
            'a counter the source did not send stays -1 so the screen '
            'knows to count for itself rather than showing a real 0',
      );
    });
  });
}
