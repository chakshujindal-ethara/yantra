import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/stale_marks.dart';
import 'package:yantra_app/core/page_commands.dart';
import 'package:yantra_app/screens/ops/settings_screen.dart';
import 'package:yantra_app/screens/shell.dart';

import '../support/fake_backend.dart';
import 'fixtures.dart';

FakeBackend quiet() => FakeBackend({
  'GET /v1/claims/active': (_) => json(emptyActive),
  'GET /v1/batches': (_) => json([]),
  'GET /v1/notify/inbox': (_) => json([
    {'id': 'n1', 'kind': 'verdict_accepted', 'subject': 'Accepted', 'body': 'b', 'created_at': '2026-11-02T10:00:00Z'},
    {
      'id': 'n2',
      'kind': 'payout_paid',
      'subject': 'Paid',
      'body': 'b',
      'created_at': '2026-11-02T10:00:00Z',
      'read_at': '2026-11-02T11:00:00Z',
    },
  ]),
});

void main() {
  testWidgets('wide: sidebar groups, account footer, the active page follows the nav', (tester) async {
    await pumpApp(tester, quiet(), size: const Size(1280, 900));
    await openRail(tester);
    expect(find.text('WORK'), findsOneWidget);
    expect(find.text('MONEY'), findsOneWidget);
    expect(find.text('worker1'), findsWidgets);
    expect(find.byKey(const Key('nav-home')), findsOneWidget);
    await tester.tap(find.byKey(const Key('nav-earnings')));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Earnings');
    expect(find.byKey(const Key('studio-backdrop')), findsOneWidget, reason: 'pages sit on the studio board');
    await expectAccessible(tester);
  });

  testWidgets('narrow: a bottom bar with five items and the avatar opens Profile', (tester) async {
    await pumpApp(tester, quiet(), size: const Size(420, 900));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(const Key('nav-home')), findsNothing);
    await tester.tap(find.byKey(const Key('avatar-menu')));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Profile');
    // no bar item is painted as selected while Profile is active
    final theme = tester.widget<NavigationBarTheme>(find.byType(NavigationBarTheme));
    expect(theme.data.indicatorColor, Colors.transparent);
    await tester.tap(find.text('Earnings'));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Earnings');
    expect(tester.widget<NavigationBarTheme>(find.byType(NavigationBarTheme)).data.indicatorColor, isNot(Colors.transparent));
  });

  testWidgets('only the first page loads at sign-in; the bell counts once the inbox has been read', (tester) async {
    final backend = quiet();
    await pumpApp(tester, backend, size: const Size(1280, 900));
    expect(backend.sent('GET', '/v1/notify/inbox'), isEmpty);
    expect(backend.sent('GET', '/v1/payout/statement'), hasLength(1)); // Home's own call, no other page's
    await tester.tap(find.byKey(const Key('bell')));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Inbox');
    expect(backend.sent('GET', '/v1/notify/inbox'), hasLength(1));
    expect(find.descendant(of: find.byKey(const Key('bell')), matching: find.text('1')), findsOneWidget);
    // a page, once visited, is kept: going away and back does not load it again
    await tester.tap(find.byKey(const Key('nav-home')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-inbox')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/notify/inbox'), hasLength(1));
  });

  test('a kept page is rebuilt on re-entry only after 30 seconds, a stale mark or an explicit refresh', () {
    var now = DateTime(2026, 11, 3, 10);
    final policy = RevisitPolicy(clock: () => now);
    expect(policy.enter(Destination.inbox), 0, reason: 'first visit');
    expect(policy.visited(Destination.inbox), isTrue);
    expect(policy.visited(Destination.home), isFalse);
    now = now.add(const Duration(seconds: 10));
    expect(policy.enter(Destination.inbox), 0, reason: 'back within 30 seconds: kept as is');
    now = now.add(const Duration(seconds: 30));
    expect(policy.enter(Destination.inbox), 1, reason: '30 seconds since it was entered: rebuilt');
    expect(policy.enter(Destination.inbox, stale: true), 2, reason: 'a mutation elsewhere marked it');
    expect(policy.enter(Destination.inbox, refresh: true), 3, reason: 'asked for outright');
    expect(policy.enter(Destination.home, stale: true), 0, reason: 'a first visit builds once whatever the marks say');
    expect(policy.generation(Destination.inbox), 3);
  });

  test('a stale mark is consumed by the first take', () {
    final marks = StaleMarks();
    expect(marks.take(Destination.home), isFalse);
    marks.mark([Destination.home, Destination.applications]);
    expect(marks.take(Destination.home), isTrue);
    expect(marks.take(Destination.home), isFalse);
    expect(marks.take(Destination.applications), isTrue);
  });

  testWidgets('ShellActions.go with refresh rebuilds a kept page', (tester) async {
    final backend = quiet();
    await pumpApp(tester, backend, size: const Size(1280, 900));
    await tester.tap(find.byKey(const Key('bell')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/notify/inbox'), hasLength(1));
    ShellActions.of(tester.element(find.byKey(const Key('page-title')))).go(Destination.inbox, refresh: true);
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/notify/inbox'), hasLength(2));
  });

  testWidgets('the palette row under the cursor is selected for assistive tech', (tester) async {
    await pumpApp(tester, quiet(), size: const Size(1280, 900));
    await tester.tap(find.byKey(const Key('command-palette')));
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(find.byKey(const Key('palette-home'))).selected, isTrue);
    expect(tester.widget<ListTile>(find.byKey(const Key('palette-explore'))).selected, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(find.byKey(const Key('palette-home'))).selected, isFalse);
    expect(tester.widget<ListTile>(find.byKey(const Key('palette-explore'))).selected, isTrue);
  });

  testWidgets('the theme toggle flips brightness', (tester) async {
    await pumpApp(tester, quiet(), size: const Size(1280, 900));
    final before = Theme.of(tester.element(find.byKey(const Key('page-title')))).brightness;
    await tester.tap(find.byKey(const Key('theme-toggle')));
    await tester.pumpAndSettle();
    final after = Theme.of(tester.element(find.byKey(const Key('page-title')))).brightness;
    expect(after, isNot(before));
  });

  testWidgets('an operator opens on Overview with the operate groups; the bar carries five', (tester) async {
    final backend = quiet();
    await pumpApp(tester, backend, size: const Size(1280, 900), roles: ['ops', 'finance']);
    expect(pageTitle(tester), 'Overview');
    await openRail(tester);
    expect(find.text('OPERATE'), findsOneWidget);
    expect(find.text('WORK'), findsNothing);
    expect(find.text('Operator'), findsOneWidget);
    expect(backend.sent('GET', '/v1/claims/active'), isEmpty); // no worker page loaded
    await tester.tap(find.byKey(const Key('nav-finance')));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Finance');
  });

  testWidgets('a client sees only the client group and the profile', (tester) async {
    await pumpApp(tester, quiet(), size: const Size(1280, 900), roles: ['client']);
    await openRail(tester);
    expect(pageTitle(tester), 'Overview');
    expect(find.text('CLIENT'), findsOneWidget);
    expect(find.byKey(const Key('nav-home')), findsNothing);
    expect(find.byKey(const Key('bell')), findsNothing);
    expect(find.byKey(const Key('nav-profile')), findsOneWidget);
  });

  testWidgets('someone who is both ops and worker gets both groups', (tester) async {
    await pumpApp(tester, quiet(), size: const Size(1280, 900), roles: ['ops', 'worker']);
    await openRail(tester);
    expect(find.text('OPERATE'), findsOneWidget);
    expect(find.text('WORK'), findsOneWidget);
    expect(pageTitle(tester), 'Overview');
  });

  testWidgets('narrow: the drawer reaches every destination, including those off the bar', (tester) async {
    await pumpApp(tester, quiet(), size: const Size(420, 900));
    expect(find.text('Review'), findsNothing);
    await openFromDrawer(tester, 'nav-review');
    expect(pageTitle(tester), 'Review');
    // Review is not in the bar: nothing there looks selected
    expect(tester.widget<NavigationBarTheme>(find.byType(NavigationBarTheme)).data.indicatorColor, Colors.transparent);
  });

  testWidgets('the command palette filters destinations and goes there', (tester) async {
    await pumpApp(tester, quiet(), size: const Size(1280, 900));
    await tester.tap(find.byKey(const Key('command-palette')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('palette')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('palette-query')), 'earn');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('palette-earnings')), findsOneWidget);
    expect(find.byKey(const Key('palette-home')), findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Earnings');
  });

  testWidgets('Ctrl+K opens the palette', (tester) async {
    await pumpApp(tester, quiet(), size: const Size(1280, 900));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('palette')), findsOneWidget);
  });

  testWidgets('a worker without the reviewer role has no Review page', (tester) async {
    await pumpApp(tester, quiet(), size: const Size(1280, 900), roles: ['worker']);
    expect(find.byKey(const Key('nav-home')), findsOneWidget);
    expect(find.byKey(const Key('nav-review')), findsNothing);
  });

  testWidgets('finance alone opens on Finance under Money; no operate pages', (tester) async {
    await pumpApp(tester, quiet(), size: const Size(1280, 900), roles: ['finance']);
    await openRail(tester);
    expect(pageTitle(tester), 'Finance');
    expect(find.text('MONEY'), findsOneWidget);
    expect(find.text('OPERATE'), findsNothing);
    expect(find.text('Finance'), findsWidgets);
  });

  testWidgets('an operator without finance still reads Finance (moving money needs the role); the bar carries five', (tester) async {
    await pumpApp(tester, quiet(), size: const Size(420, 900), roles: ['ops']);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('Finance')), findsOneWidget);
    expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('Workers')), findsNothing);
  });

  testWidgets('an admin alone lands on System and gets Leadership and Profile, but no Inbox', (tester) async {
    await pumpApp(tester, quiet(), size: const Size(1280, 900), roles: ['admin']);
    await openRail(tester);
    expect(pageTitle(tester), 'System');
    expect(find.byKey(const Key('nav-leadership')), findsOneWidget);
    expect(find.byKey(const Key('nav-settings')), findsNothing);
    expect(find.byKey(const Key('nav-inbox')), findsNothing, reason: 'notify refuses admin tokens');
    expect(find.byKey(const Key('nav-home')), findsNothing);
    expect(find.text('Admin'), findsWidgets);
  });

  testWidgets('a token with no known role gets the no-access page and can sign out', (tester) async {
    final backend = quiet();
    await pumpApp(tester, backend, size: const Size(1280, 900), roles: ['offline_access', 'uma_authorization']);
    expect(find.byKey(const Key('no-access')), findsOneWidget);
    expect(find.byKey(const Key('page-title')), findsNothing);
    expect(backend.requests.where((r) => r.url.path.startsWith('/v1/')), isEmpty, reason: 'nothing is loaded for a role-less user');
    await tester.tap(find.byKey(const Key('no-access-sign-out')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
  });

  testWidgets('the offline banner follows the browser and the gateway', (tester) async {
    final harness = await pumpApp(tester, quiet(), size: const Size(1280, 900));
    expect(find.byKey(const Key('network-banner')), findsNothing);
    harness.network.setOnline(false);
    await tester.pump();
    expect(find.textContaining("You're offline"), findsOneWidget);
    harness.network.setOnline(true);
    harness.network.reportReachable(false);
    await tester.pump();
    expect(find.textContaining("Can't reach Yantra"), findsOneWidget);
    harness.network.reportReachable(true);
    await tester.pump();
    expect(find.byKey(const Key('network-banner')), findsNothing);
  });

  test('visibleTo has nothing for no known role, and firstFor is null', () {
    expect(Destination.visibleTo({'uma_authorization'}), isEmpty);
    expect(Destination.firstFor(const {}), isNull);
    expect(Destination.firstFor({'worker', 'reviewer'}), Destination.home);
    expect(Destination.firstFor({'reviewer'}), Destination.review);
    expect(Destination.firstFor({'client', 'worker'}), Destination.clientOverview);
    expect(Destination.visibleTo({'reviewer'}), [Destination.review, Destination.profile], reason: 'a reviewer alone has no inbox');
  });

  test('the bottom bar keeps Inbox for workers only; finance, reviewer and admin bars have none', () {
    expect(Destination.bottomBarFor({'worker'}), [
      Destination.home,
      Destination.explore,
      Destination.myWork,
      Destination.earnings,
      Destination.inbox,
    ]);
    expect(Destination.bottomBarFor({'finance'}), [Destination.finance, Destination.leadership, Destination.profile]);
    expect(Destination.bottomBarFor({'reviewer'}), [Destination.review, Destination.profile]);
    expect(Destination.bottomBarFor({'admin'}), [Destination.system, Destination.leadership, Destination.profile]);
    expect(Destination.bottomBarFor({'uma_authorization'}), isEmpty, reason: 'profile needs a known role');
  });

  testWidgets('the bell polls the unread count every minute without opening Inbox; a rise marks Inbox stale', (tester) async {
    var unread = 2;
    final backend = quiet()..routes['GET /v1/notify/inbox/unread-count'] = (_) => json({'unread': unread});
    await pumpApp(tester, backend, size: const Size(1280, 900));
    expect(find.byTooltip('Inbox, 2 unread'), findsOneWidget);
    unread = 5;
    await tester.pump(const Duration(seconds: 61));
    await tester.pump();
    expect(find.byTooltip('Inbox, 5 unread'), findsOneWidget);
    expect(backend.sent('GET', '/v1/notify/inbox/unread-count'), hasLength(2));
  });

  testWidgets('a failed poll changes nothing; a person who cannot see Inbox is not polled', (tester) async {
    final backend = quiet()..routes['GET /v1/notify/inbox/unread-count'] = (_) => envelope(503, 'upstream_unavailable');
    await pumpApp(tester, backend, size: const Size(1280, 900));
    expect(find.byTooltip('Inbox'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    final client = quiet()..routes['GET /v1/notify/inbox/unread-count'] = (_) => json({'unread': 9});
    await pumpApp(tester, client, size: const Size(1280, 900), roles: ['client']);
    expect(client.sent('GET', '/v1/notify/inbox/unread-count'), isEmpty);
  });

  testWidgets('the signed-in person is announced once, so operators see their name', (tester) async {
    final backend = quiet()..routes['PUT /v1/talent/people/me'] = (_) => json({'id': 'worker-1', 'name': 'worker1', 'kind': 'worker'});
    await pumpApp(tester, backend, size: const Size(1280, 900));
    await tester.tap(find.byKey(const Key('nav-explore')));
    await tester.pumpAndSettle();
    final puts = backend.sent('PUT', '/v1/talent/people/me');
    expect(puts, hasLength(1));
    expect(puts.single.headers['Idempotency-Key'], isNotEmpty);
  });

  testWidgets('the palette lists the page\'s own actions first and runs the one picked', (tester) async {
    var ran = 0;
    await pumpApp(tester, quiet(), size: const Size(1280, 900), roles: ['ops', 'finance'], at: '/ops/settings');
    final page = tester.element(find.byType(SettingsScreen));
    final registry = PageCommandsScope.maybeOf(page)!;
    final location = currentLocation(tester);
    registry.set(location, [PageCommand('Recount the numbers', Icons.refresh, () => ran++)]);
    await tester.tap(find.byKey(const Key('command-palette')));
    await tester.pumpAndSettle();
    expect(find.text('On this page'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('palette-query')), 'recount');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('palette-action-0')));
    await tester.pumpAndSettle();
    expect(ran, 1);
    expect(registry.at(location), hasLength(1));
    registry.clear(location, const []);
    expect(registry.at(location), hasLength(1), reason: 'only the list that was registered clears it');
  });
}
