import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/app_router.dart';

import '../support/fake_backend.dart';
import 'fixtures.dart';
import 'fixtures_talent.dart';

/// "Continue with Yantra" from the exam app's sign-in page: Yantra mints a fresh signed-in link and the browser
/// goes straight back into the exam.
void main() {
  Map<String, Handler> routes() => {
    'GET /v1/claims/active': (_) => json(emptyActive),
    'GET /v1/batches': (_) => json([]),
    'POST /v1/assess/launch-by-exam': (_) => json(launchTicket(url: 'http://localhost:8096/yantra/launch#ticket=back-1')),
    'POST /v1/assess/admin-launch': (_) => json(launchTicket(url: 'http://localhost:8096/yantra/launch#ticket=staff-1')),
  };

  testWidgets('a worker coming back from the exam app is sent into their exam again', (tester) async {
    final backend = FakeBackend(routes());
    final harness = await pumpApp(tester, backend, at: '${Paths.assessContinue}?exam=tok-1');
    final sent = backend.sent('POST', '/v1/assess/launch-by-exam').single;
    expect(jsonDecode(sent.body), {'exam_token': 'tok-1'});
    expect(sent.headers['Idempotency-Key'], isNotEmpty);
    expect(harness.browser.navigations.single.fragment, 'ticket=back-1');
    // should the browser stay on this page, the link can be opened again by hand
    expect(find.byKey(const Key('assess-continue-opened')), findsOneWidget);
    await tester.tap(find.byKey(const Key('assess-continue-open')));
    expect(harness.browser.navigations, hasLength(2));
  });

  testWidgets('staff are sent into the Assessment admin page they asked for', (tester) async {
    final backend = FakeBackend({...routes(), 'GET /v1/projects': (_) => json([])});
    final harness = await pumpApp(tester, backend, roles: const ['ops'], at: '${Paths.assessContinue}?admin=1&next=/assessments/12');
    expect(jsonDecode(backend.sent('POST', '/v1/assess/admin-launch').single.body), {'next': '/assessments/12'});
    expect(harness.browser.navigations.single.fragment, 'ticket=staff-1');
  });

  testWidgets('a link that names no exam says so and asks for nothing', (tester) async {
    final backend = FakeBackend(routes());
    final harness = await pumpApp(tester, backend, at: Paths.assessContinue);
    expect(find.textContaining('does not say which exam to open'), findsOneWidget);
    expect(backend.sent('POST', '/v1/assess/launch-by-exam'), isEmpty);
    expect(harness.browser.navigations, isEmpty);
  });

  testWidgets('a refused link explains itself, Try again retries, and Back to Yantra goes home', (tester) async {
    var refuse = true;
    final backend = FakeBackend({
      ...routes(),
      'POST /v1/assess/launch-by-exam': (_) =>
          refuse ? envelope(409, 'result_pending') : json(launchTicket(url: 'http://localhost:8096/yantra/launch#ticket=again')),
    });
    final harness = await pumpApp(tester, backend, at: '${Paths.assessContinue}?exam=tok-1');
    expect(find.byKey(const Key('assess-continue-error')), findsOneWidget);
    expect(find.textContaining('still being marked'), findsOneWidget);
    await expectAccessible(tester);
    refuse = false;
    await tester.tap(find.byKey(const Key('assess-continue-retry')));
    await tester.pumpAndSettle();
    expect(harness.browser.navigations.single.fragment, 'ticket=again');
    refuse = true;
    await goTo(tester, '${Paths.assessContinue}?exam=tok-2');
    await tester.tap(find.byKey(const Key('assess-continue-home')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/work/home');
  });

  testWidgets('signed out, the worker signs in and carries on into the exam', (tester) async {
    final backend = FakeBackend({...routes(), 'POST $tokenPath': (_) => json(tokenResponse(access: fakeJwt()))});
    final harness = await pumpApp(tester, backend, signedOut: true, at: '${Paths.assessContinue}?exam=tok-1');
    expect(currentLocation(tester), Paths.login);
    await tester.enterText(find.byKey(const Key('login-username')), 'worker1');
    await tester.enterText(find.byKey(const Key('login-password')), 'yantra');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('POST', '/v1/assess/launch-by-exam').single.body), {'exam_token': 'tok-1'});
    expect(harness.browser.navigations.single.fragment, 'ticket=back-1');
  });
}
