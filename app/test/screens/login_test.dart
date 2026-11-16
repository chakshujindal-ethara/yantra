import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/auth/browser.dart';
import 'package:yantra_app/config.dart';

import '../support/fake_backend.dart';
import 'fixtures.dart';

void main() {
  testWidgets('a good password signs in and lands on Home', (tester) async {
    final backend = FakeBackend({
      'POST $tokenPath': (_) => json(tokenResponse(access: fakeJwt(username: 'worker1'))),
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([]),
    });
    await pumpApp(tester, backend, signedOut: true);
    expect(find.text('Sign in to Yantra'), findsOneWidget);
    // off the web there is no redirect: the password form is shown directly
    expect(find.byKey(const Key('login-keycloak')), findsNothing);

    await tester.enterText(find.byKey(const Key('login-username')), 'worker1');
    await tester.enterText(find.byKey(const Key('login-password')), 'yantra');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('page-title')), findsOneWidget);
    expect(find.textContaining(', worker1'), findsOneWidget);
    await expectAccessible(tester);
  });

  testWidgets('a refused password shows the identity server message', (tester) async {
    final backend = FakeBackend({
      'POST $tokenPath': (_) => json({'error': 'invalid_grant', 'error_description': 'Invalid user credentials'}, status: 401),
    });
    await pumpApp(tester, backend, signedOut: true);
    await tester.enterText(find.byKey(const Key('login-username')), 'worker1');
    await tester.enterText(find.byKey(const Key('login-password')), 'nope');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Invalid user credentials'), findsOneWidget);
    expect(find.text('Sign in to Yantra'), findsOneWidget);
  });

  testWidgets('empty fields are refused before any request', (tester) async {
    final backend = FakeBackend();
    await pumpApp(tester, backend, signedOut: true);
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Enter your username and password'), findsOneWidget);
    expect(backend.requests, isEmpty);
  });

  testWidgets('in a browser the Keycloak redirect is primary and the password form is behind a link', (tester) async {
    final browser = MemoryBrowser(canRedirect: true);
    await pumpApp(tester, FakeBackend(), signedOut: true, browser: browser);
    expect(find.byKey(const Key('login-keycloak')), findsOneWidget);
    expect(find.byKey(const Key('login-username')), findsNothing);

    await tester.tap(find.byKey(const Key('login-use-password')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login-username')), findsOneWidget);

    await tester.tap(find.byKey(const Key('login-keycloak')));
    await tester.pump();
    expect(browser.navigations.single.path, '/realms/yantra/protocol/openid-connect/auth');
  });

  testWidgets('a production build without the password grant offers only Keycloak', (tester) async {
    const prod = AppConfig(gatewayUrl: 'http://gateway.test', keycloakUrl: 'http://keycloak.test', directLogin: false);
    await pumpApp(tester, FakeBackend(), signedOut: true, config: prod, browser: MemoryBrowser(canRedirect: true));
    expect(find.byKey(const Key('login-keycloak')), findsOneWidget);
    expect(find.byKey(const Key('login-use-password')), findsNothing);
    expect(find.byKey(const Key('login-username')), findsNothing);
  });

  testWidgets('a failed redirect sign-in is explained on the login screen', (tester) async {
    final browser = MemoryBrowser(current: Uri.parse('http://localhost:8095/?error=access_denied'), canRedirect: true);
    await pumpApp(tester, FakeBackend(), signedOut: true, browser: browser);
    expect(find.textContaining('cancelled'), findsOneWidget);
  });

  testWidgets('the wide layout shows the brand panel', (tester) async {
    await pumpApp(tester, FakeBackend(), signedOut: true, size: const Size(1280, 900));
    expect(find.text('Trusted human work for AI labs.'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'the wordmark scales down instead of overflowing');
  });

  testWidgets('the corner pill switches the sign-in page between light and dark', (tester) async {
    await pumpApp(tester, FakeBackend(), signedOut: true, size: const Size(1280, 900));
    Brightness now() => Theme.of(tester.element(find.text('Sign in to Yantra'))).brightness;
    final before = now();
    await tester.tap(find.byKey(const Key('login-theme')));
    await tester.pumpAndSettle();
    expect(now(), isNot(before));
  });

  testWidgets('the brand panel fits a narrow desktop', (tester) async {
    await pumpApp(tester, FakeBackend(), signedOut: true, size: const Size(960, 800));
    expect(find.text('Trusted human work for AI labs.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sign out from the sidebar returns to the login screen', (tester) async {
    final backend = FakeBackend({'GET /v1/claims/active': (_) => json(emptyActive), 'GET /v1/batches': (_) => json([])});
    final h = await pumpApp(tester, backend, size: const Size(1280, 900));
    await openRail(tester);
    await tester.tap(find.byKey(const Key('logout')));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to Yantra'), findsOneWidget);
    expect(await h.store.read(), isNull);
  });
}
