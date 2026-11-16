// Changing your own password, against a stubbed transport.
//
// The bug worth pinning here is not "does the button post". It is that the
// server ENDS every credential this client holds as a side effect of the
// change - Odoo derives its session token from the password hash, and the auth
// gateway unlinks every bearer token for a user whose password is written - so
// a client that does not adopt the replacement in the reply is signed out one
// call later, having just told the user the change worked. That is invisible
// in a screenshot of the success message, which is exactly why it is a test.
import 'dart:convert';

import 'package:ethara_assessment/assessment/assessment_section.dart';
import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/nav_entries.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/account/account_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:ethara_assessment/password_reset.dart'
    show resetPasswordPolicyCache;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Records every request so a test can assert on the body that was actually
/// sent, not merely on what came back.
class _Recorder {
  final List<http.Request> requests = <http.Request>[];

  Map<String, dynamic> bodyOf(int i) =>
      jsonDecode(requests[i].body) as Map<String, dynamic>;

  String? authOf(int i) => requests[i].headers['Authorization'];
}

/// A signed-in client on the gateway (bearer) path.
///
/// `login` is driven through the real `/api/v1/auth_token` handler rather than
/// the constructor's `bearer:` shortcut, so the token the change has to replace
/// got there the same way a real one does.
Future<(ApiClient, _Recorder)> _signedIn({
  Map<String, dynamic>? changeReply,
  int changeStatus = 200,
}) async {
  final _Recorder rec = _Recorder();
  final ApiClient api = ApiClient(
    baseUrl: 'http://stub',
    client: MockClient((http.Request req) async {
      rec.requests.add(req);
      final String path = req.url.path;

      if (path.endsWith('/auth_token')) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{
              'access_token': 'first-token',
              'refresh_token': 'first-refresh',
              'uid': 7,
              'name': 'Sana Kapoor',
            },
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }

      if (path.endsWith('/auth/password')) {
        return http.Response(
          jsonEncode(
            changeReply ??
                <String, dynamic>{
                  'ok': true,
                  'data': <String, dynamic>{
                    'changed': true,
                    'reauthenticated': true,
                    'access_token': 'second-token',
                    'refresh_token': 'second-refresh',
                  },
                },
          ),
          changeStatus,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }

      return http.Response(
        jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }),
  );

  await api.login('sana', 'Ethara@123');
  return (api, rec);
}

void main() {
  group('ApiClient.changePassword', () {
    test('sends the new password to the module route', () async {
      final (ApiClient api, _Recorder rec) = await _signedIn();
      await api.changePassword('NewPassw0rd!', confirmPassword: 'NewPassw0rd!');

      final http.Request change = rec.requests.last;
      expect(change.url.path, '/api/v1/auth/password');
      expect(rec.bodyOf(1)['new_password'], 'NewPassw0rd!');
      expect(rec.bodyOf(1)['confirm_password'], 'NewPassw0rd!');
      expect(
        rec.bodyOf(1).containsKey('current_password'),
        isFalse,
        reason:
            'the key must be ABSENT, not empty - the server verifies it '
            'whenever it is sent, so an empty string would be checked and '
            'refused',
      );
    });

    test(
      'adopts the replacement token, so the next call is authorised',
      () async {
        final (ApiClient api, _Recorder rec) = await _signedIn();
        expect(rec.authOf(0), isNull, reason: 'sign-in carries no bearer yet');

        await api.changePassword('NewPassw0rd!');
        expect(
          rec.authOf(1),
          'Bearer first-token',
          reason: 'the change itself is signed with the OLD token',
        );

        await api.whoAmI();
        expect(
          rec.authOf(2),
          'Bearer second-token',
          reason:
              'the old token was revoked by the write; still presenting it '
              'would 401 the next call and dump the user on the login form',
        );
        expect(api.isAuthenticated, isTrue);
      },
    );

    test('reports a change the session did not survive', () async {
      // The password DID change. Only the credential renewal failed - an MFA
      // account on the cookie path, for instance. Reporting this as a failure
      // would send the user to retry with a password that already works.
      final (ApiClient api, _) = await _signedIn(
        changeReply: <String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{'changed': true, 'reauthenticated': false},
        },
      );

      expect(await api.changePassword('NewPassw0rd!'), isFalse);
    });

    test('keeps the old token when the server sent no replacement', () async {
      final (ApiClient api, _Recorder rec) = await _signedIn(
        changeReply: <String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{'changed': true, 'reauthenticated': false},
        },
      );

      await api.changePassword('NewPassw0rd!');
      await api.whoAmI();
      expect(
        rec.authOf(2),
        'Bearer first-token',
        reason:
            'a missing replacement must not blank the bearer - that would '
            'turn a recoverable "sign in again" into an anonymous client',
      );
    });

    test('a refusal arrives as the module worded it', () async {
      final (ApiClient api, _) = await _signedIn(
        changeStatus: 400,
        changeReply: <String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'weak_password',
            'message': 'Your new password must be at least 8 characters',
          },
        },
      );

      await expectLater(
        api.changePassword('short'),
        throwsA(
          isA<ApiError>()
              .having((ApiError e) => e.code, 'code', 'weak_password')
              .having(
                (ApiError e) => e.message,
                'message',
                'Your new password must be at least 8 characters',
              ),
        ),
      );
    });
  });

  group('AppStore.changePassword', () {
    test('refuses on fixtures rather than pretending', () async {
      // `hasBackend` is false in tests, so the store is on seed data. Answering
      // "password updated" there would be a lie the user acts on.
      final AppStore store = AppStore();
      await expectLater(
        store.changePassword('NewPassw0rd!'),
        throwsA(
          isA<ApiError>().having(
            (ApiError e) => e.isDomain,
            'isDomain',
            isTrue,
          ),
        ),
      );
    });
  });

  group('AccountScreen', () {
    Future<void> pump(WidgetTester tester, AppStore store) async {
      // TALL ENOUGH FOR THE WHOLE PAGE. Account leads with a Profile panel
      // now, which pushes the password form past an 800x600 fold - and a tap
      // outside the viewport hit-tests nothing, so the form simply never
      // submitted and the test read that as "no refusal was shown".
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AccountScreen(store: store)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('refuses a mismatch without asking the server', (
      WidgetTester tester,
    ) async {
      final _Recorder rec = _Recorder();
      final AppStore store = AppStore(
        api: ApiClient(
          baseUrl: 'http://stub',
          client: MockClient((http.Request req) async {
            rec.requests.add(req);
            return http.Response(
              '{"ok":true,"data":{}}',
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
        ),
      );
      await pump(tester, store);

      final Finder fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'NewPassw0rd!');
      await tester.enterText(fields.at(1), 'NewPassw0rdTypo');
      await tester.tap(find.widgetWithText(Btn, 'Update Password'));
      await tester.pumpAndSettle();

      expect(find.byType(Notice), findsOneWidget);
      expect(find.textContaining('do not match'), findsOneWidget);
      // The screen's one read is the password policy; the CHANGE is what a
      // mismatch must not send.
      expect(
        rec.requests.where(
          (http.Request r) => r.url.path.endsWith('/auth/password'),
        ),
        isEmpty,
        reason: 'a mismatch is knowable locally; it costs no round trip',
      );
    });

    testWidgets('refuses a password under the minimum length', (
      WidgetTester tester,
    ) async {
      final AppStore store = AppStore();
      await pump(tester, store);

      final Finder fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'short');
      await tester.enterText(fields.at(1), 'short');
      await tester.tap(find.widgetWithText(Btn, 'Update Password'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('at least $kMinPasswordLength'),
        findsOneWidget,
      );
    });

    testWidgets('the length refusal follows the server policy', (
      WidgetTester tester,
    ) async {
      resetPasswordPolicyCache();
      addTearDown(resetPasswordPolicyCache);
      final AppStore store = AppStore(
        api: ApiClient(
          baseUrl: 'http://stub',
          client: MockClient((http.Request req) async {
            final bool policy = req.url.path.endsWith('/auth/password_policy');
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': true,
                'data': policy
                    ? <String, dynamic>{
                        'min_length': 14,
                        'require': <String>['upper', 'digit'],
                      }
                    : <String, dynamic>{},
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
        ),
      );
      await pump(tester, store);
      expect(find.text('At least 14 characters'), findsOneWidget);
      expect(find.text('One lowercase letter'), findsNothing);

      // 13 characters: past the fallback's 12, short of the server's 14.
      final Finder fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Abcdefghij12!');
      await tester.enterText(fields.at(1), 'Abcdefghij12!');
      await tester.tap(find.widgetWithText(Btn, 'Update Password'));
      await tester.pumpAndSettle();

      expect(find.textContaining('at least 14'), findsOneWidget);
    });

    testWidgets('the form is the same one a candidate gets', (
      WidgetTester tester,
    ) async {
      // Not a cosmetic assertion. A candidate is the user who NEEDS this page -
      // their account is provisioned on a shared default password - and every
      // other screen in the section branches on `portal`. This one must not.
      final AppStore store = AppStore()..portal = Portal.member;
      await pump(tester, store);

      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.widgetWithText(Btn, 'Update Password'), findsOneWidget);
    });
  });

  group('Reaching Account from the sidebar name card', () {
    // The whole click path in one test: is the row GONE from the candidate's
    // rail, does the name card's key still route, does the screen render, and
    // does the card light up.
    //
    // Account moved out of the rail and under the signed-in person's name -
    // see `_Sidebar` in `app_shell.dart`. The guarantee that matters did not
    // move with it: a candidate signs in on the shared default password their
    // account was provisioned with, and this is the only screen in the app
    // that changes it. If the card ever stops calling `onOpen('account')`,
    // that screen becomes unreachable for the user who needs it most, and no
    // other test in the suite would notice.
    //
    // A widget test rather than browser automation for the reason
    // section_entry_test.dart gives: Flutter web renders to a canvas, so a
    // synthetic click never reaches the handler and a screenshot only proves
    // what was already painted. Driving the real widgets is the honest check.
    testWidgets('a candidate can open it from their name card', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final AppStore store = AppStore()..portal = Portal.member;
      addTearDown(store.dispose);

      List<NavEntry> entries = const <NavEntry>[];
      String activeKey = '';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AssessmentSection(
              store: store,
              entry: AssessmentEntry.mine,
              // Stands in for the shell's `_Sidebar`, which lives in
              // app_shell.dart. What matters is that the ENTRIES, the active
              // key and the open callback are the section's real ones - and
              // that the name card is wired the same way the real one is, with
              // a hardcoded `onOpen('account')` rather than an entry key,
              // because it no longer has an entry to read one from.
              sidebarBuilder:
                  (
                    BuildContext _,
                    List<NavEntry> e,
                    String active,
                    void Function(String) onOpen,
                  ) {
                    entries = e;
                    activeKey = active;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        ...e.map(
                          (NavEntry n) => TextButton(
                            key: ValueKey<String>('rail-${n.key}'),
                            onPressed: () => onOpen(n.key),
                            child: Text(n.label),
                          ),
                        ),
                        TextButton(
                          key: const ValueKey<String>('name-card'),
                          onPressed: () => onOpen('account'),
                          child: const Text('Sana Kapoor'),
                        ),
                      ],
                    );
                  },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        entries.map((NavEntry e) => e.key),
        isNot(contains('account')),
        reason:
            'Account moved to the name card; leaving the rail row as well '
            'would give one page two entry points and put a form about the '
            'PERSON back among the product sections',
      );

      await tester.tap(find.byKey(const ValueKey<String>('name-card')));
      await tester.pumpAndSettle();

      final AssessmentNavScope scope = tester.widget<AssessmentNavScope>(
        find.byType(AssessmentNavScope),
      );
      expect(
        scope.notifier!.current,
        isA<AccountSettings>(),
        reason:
            'an unrouted key falls through to the assessment list, which '
            'looks like a working click that opened the wrong page',
      );
      expect(find.byType(AccountScreen), findsOneWidget);
      expect(
        activeKey,
        'account',
        reason:
            'the section must still report the active key, because the name '
            'card lights itself from it exactly as a rail row does',
      );
    });
  });
}
