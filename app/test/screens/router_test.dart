import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/screens/ops/leadership_screen.dart';
import 'package:yantra_app/app_router.dart';
import 'package:yantra_app/core/widgets/detail_frame.dart';
import 'package:yantra_app/screens/ops/project_screen.dart';
import 'package:yantra_app/screens/shell.dart';

import '../support/fake_backend.dart';
import 'fixtures.dart';
import 'ops/fixtures_ops.dart';

const wide = Size(1280, 900);

FakeBackend opsBackend() => FakeBackend({
  'GET /v1/projects': (_) => json([projectSummary()]),
  'GET /v1/projects/p1': (_) => json(projectDetail()),
});

void main() {
  testWidgets('a deep link opens the detail inside the shell; the crumb and the back arrow lead to the list', (tester) async {
    await pumpApp(tester, opsBackend(), size: wide, roles: ['ops', 'finance'], at: '/ops/projects/p1');
    expect(find.byType(ProjectScreen), findsOneWidget);
    expect(find.byKey(const Key('nav-projects')), findsOneWidget, reason: 'the sidebar stays');
    expect(find.byKey(const Key('page-title')), findsOneWidget);
    expect(find.byKey(const Key('crumb-current')), findsOneWidget);
    await tester.tap(find.byKey(const Key('back')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/ops/projects', reason: 'a cold link has no page below: back goes to the nearest linked crumb');
    expect(find.byType(ProjectScreen), findsNothing);

    await tester.tap(find.byKey(const Key('project-p1')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/ops/projects/p1');
    await tester.tap(find.byKey(const Key('crumb-1')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/ops/projects');
  });

  testWidgets('a page the roles do not allow sends the person to their first page; an unknown path too', (tester) async {
    final backend = FakeBackend({'GET /v1/claims/active': (_) => json(emptyActive), 'GET /v1/batches': (_) => json([])});
    await pumpApp(tester, backend, at: '/ops/overview');
    expect(currentLocation(tester), '/work/home');
    await goTo(tester, '/nowhere/at/all');
    expect(currentLocation(tester), '/work/home');
  });

  testWidgets('signed out, a deep link goes to sign-in and back to the page after it', (tester) async {
    final backend = opsBackend()
      ..routes['POST $tokenPath'] = (_) => json(
        tokenResponse(
          access: fakeJwt(username: 'ops1', roles: ['ops', 'finance']),
        ),
      );
    backend.routes['GET /v1/payout/windows'] = (_) => json([]);
    await pumpApp(tester, backend, signedOut: true, size: wide, at: '/ops/projects/p1');
    expect(currentLocation(tester), Paths.login);
    await tester.enterText(find.byKey(const Key('login-username')), 'ops1');
    await tester.enterText(find.byKey(const Key('login-password')), 'yantra');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/ops/projects/p1');
    expect(find.byType(ProjectScreen), findsOneWidget);
  });

  testWidgets('a remembered page the new roles do not allow lands on the first page instead', (tester) async {
    final backend = FakeBackend({
      'POST $tokenPath': (_) => json(tokenResponse(access: fakeJwt(username: 'worker1'))),
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([]),
    });
    await pumpApp(tester, backend, signedOut: true, at: '/ops/finance');
    await tester.enterText(find.byKey(const Key('login-username')), 'worker1');
    await tester.enterText(find.byKey(const Key('login-password')), 'yantra');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/work/home');
  });

  testWidgets('a token with no Yantra role sees the no-access page wherever it goes', (tester) async {
    await pumpApp(tester, FakeBackend(), roles: ['offline_access'], at: '/work/home');
    expect(currentLocation(tester), Paths.noAccess);
    expect(find.byKey(const Key('no-access')), findsOneWidget);
    await goTo(tester, '/ops/projects');
    expect(currentLocation(tester), Paths.noAccess);
  });

  testWidgets('the sign-in callback and the bare root both land a signed-in person on their first page', (tester) async {
    final backend = FakeBackend({'GET /v1/claims/active': (_) => json(emptyActive), 'GET /v1/batches': (_) => json([])});
    await pumpApp(tester, backend, at: '/auth/callback');
    expect(currentLocation(tester), '/work/home');
    await goTo(tester, '/');
    expect(currentLocation(tester), '/work/home');
    await goTo(tester, '/login');
    expect(currentLocation(tester), '/work/home');
  });

  testWidgets('a session that cannot be renewed ends on sign-in with the reason', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => envelope(401, 'unauthorized'),
      'GET /v1/batches': (_) => json([]),
      'POST $tokenPath': (_) => json({'error': 'invalid_grant'}, status: 400),
    });
    await pumpApp(tester, backend);
    expect(currentLocation(tester), Paths.login);
    expect(find.byKey(const Key('session-expired')), findsOneWidget);
  });

  testWidgets('signing out says nothing about expiry', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([]),
      'POST /realms/yantra/protocol/openid-connect/logout': (_) => json({}),
    });
    final harness = await pumpApp(tester, backend);
    await harness.session.logout();
    await tester.pumpAndSettle();
    expect(currentLocation(tester), Paths.login);
    expect(find.byKey(const Key('session-expired')), findsNothing);
  });

  testWidgets('leadership, settings and system have their own routes for the roles that use them', (tester) async {
    await pumpApp(tester, FakeBackend(), size: wide, roles: ['ops', 'finance'], at: '/ops/leadership');
    expect(find.byType(LeadershipScreen), findsOneWidget);
    expect(find.byKey(const Key('nav-system')), findsOneWidget);
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/ops/settings');
    expect(find.text('ADMIN · SETTINGS'), findsOneWidget);
    await tester.tap(find.byKey(const Key('nav-system')));
    await tester.pumpAndSettle();
    expect(find.text('ADMIN · SYSTEM'), findsOneWidget);
  });

  testWidgets('going to the page you are on closes a detail open in it', (tester) async {
    await pumpApp(tester, opsBackend(), size: wide, roles: ['ops', 'finance']);
    await tester.tap(find.byKey(const Key('nav-projects')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-p1')));
    await tester.pumpAndSettle();
    expect(find.byType(DetailFrame), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('nav-overview')).evaluate().isEmpty
          ? find.byKey(const Key('nav-opsOverview'))
          : find.byKey(const Key('nav-overview')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-projects')));
    await tester.pumpAndSettle();
    expect(find.byType(DetailFrame), findsOneWidget, reason: 'switching back keeps the branch where it was');
    await tester.tap(find.byKey(const Key('nav-projects')));
    await tester.pumpAndSettle();
    expect(find.byType(DetailFrame), findsNothing, reason: 'the destination you are on returns to its root');
    expect(currentLocation(tester), '/ops/projects');
  });

  test('every destination path maps back to itself; detail paths map to their branch', () {
    for (final d in Destination.values) {
      expect(Destination.byPath(d.path), d);
    }
    expect(Destination.byPath('/ops/projects/p1/batches/b1'), Destination.projects);
    expect(Destination.byPath('/ops/finance/windows/w1?x=1'), Destination.finance);
    expect(Destination.byPath('/login'), isNull);
    expect(Paths.unit('c1'), '/work/home/unit/c1');
    expect(Paths.assessment('pp1'), '/work/applications/assessment/pp1');
    expect(Paths.policy('pay-cycle'), '/profile/policies/pay-cycle');
    expect(Paths.opsListing('l1'), '/ops/listings/l1');
    expect(Paths.paper('pp1'), '/ops/papers/pp1');
    expect(Paths.worker('w1'), '/ops/workers/w1');
    expect(Paths.window('w1'), '/ops/finance/windows/w1');
    expect(Paths.clientProject('p1'), '/client/projects/p1');
    expect(Paths.onboarding(from: Destination.applications), '/work/applications/onboarding');
  });

  testWidgets('an exit guard is never asked once the person is signed out', (tester) async {
    var asked = 0;
    final guards = ExitGuards()
      ..set(GuardedRoute.assessment, (_) async {
        asked++;
        return false;
      });
    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    expect(await guards.allow(GuardedRoute.assessment, context), isFalse);
    expect(await guards.allow(GuardedRoute.assessment, context, signedIn: false), isTrue);
    expect(asked, 1, reason: 'a signed-out person is not asked');
  });
}
