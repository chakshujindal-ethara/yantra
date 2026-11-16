import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/screens/inbox_screen.dart';

import '../support/fake_backend.dart';

String iso(DateTime d) => d.toUtc().toIso8601String();

Map<String, Object?> item(
  String id, {
  required String kind,
  required String subject,
  String body = 'Body.',
  required DateTime at,
  DateTime? readAt,
}) => {'id': id, 'kind': kind, 'subject': subject, 'body': body, 'created_at': iso(at), 'read_at': readAt == null ? null : iso(readAt)};

List<Map<String, Object?>> threeItems() {
  final now = DateTime.now();
  return [
    item(
      'n1',
      kind: 'verdict_accepted',
      subject: 'Unit accepted',
      body: 'Row 17 was accepted.',
      at: now.subtract(const Duration(hours: 1)),
    ),
    item(
      'n2',
      kind: 'payout_paid',
      subject: 'Paid',
      body: 'INR 100 sent.',
      at: now.subtract(const Duration(days: 1)),
      readAt: now.subtract(const Duration(hours: 20)),
    ),
    item('n3', kind: 'window_closed', subject: 'Pay week closed', body: 'The week closed.', at: now.subtract(const Duration(days: 10))),
  ];
}

Future<FakeBackend> openInbox(WidgetTester tester, List<Map<String, Object?>> items, {Map<String, Handler>? routes}) async {
  final backend = FakeBackend({
    'GET /v1/claims/active': (_) => json({'claim': null, 'unit': null}),
    'GET /v1/batches': (_) => json([]),
    'GET /v1/notify/inbox': (_) => json(items),
    ...?routes,
  });
  await pumpApp(tester, backend);
  await tester.tap(find.text('Inbox'));
  await tester.pumpAndSettle();
  return backend;
}

FontWeight? weightOf(WidgetTester tester, String text) => tester.widget<Text>(find.text(text)).style?.fontWeight;

Finder bellBadge(String count) => find.descendant(of: find.byKey(const Key('bell')), matching: find.text(count));

void main() {
  testWidgets('items are grouped by day with icons by kind, unread bold with a dot', (tester) async {
    await openInbox(tester, threeItems());
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Unit accepted'), findsOneWidget);
    expect(find.text('Paid'), findsOneWidget);
    expect(find.text('Pay week closed'), findsOneWidget);
    expect(find.text('2 unread'), findsOneWidget);

    expect(weightOf(tester, 'Unit accepted'), FontWeight.w600);
    expect(weightOf(tester, 'Paid'), FontWeight.w400);
    expect(find.byKey(const Key('unread-dot-n1')), findsOneWidget);
    expect(find.byKey(const Key('unread-dot-n2')), findsNothing);

    Finder iconIn(String id, IconData icon) => find.descendant(of: find.byKey(Key('inbox-$id')), matching: find.byIcon(icon));
    expect(iconIn('n1', Icons.rule_outlined), findsOneWidget);
    expect(iconIn('n2', Icons.payments_outlined), findsOneWidget);
    expect(iconIn('n3', Icons.payments_outlined), findsOneWidget, reason: 'payout and window share the icon');
    expect(find.text('1 h ago'), findsOneWidget);
    await expectAccessible(tester);
  });

  testWidgets('tapping an unread item marks it read with an idempotency key and updates the bell', (tester) async {
    final backend = await openInbox(
      tester,
      threeItems(),
      routes: {
        'POST /v1/notify/inbox/n1/read': (_) => json({...threeItems()[0], 'read_at': iso(DateTime.now())}),
      },
    );
    expect(bellBadge('2'), findsOneWidget, reason: 'the bell badge shows two unread');
    await tester.tap(find.text('Unit accepted'));
    await tester.pumpAndSettle();

    final sent = backend.sent('POST', '/v1/notify/inbox/n1/read').single;
    expect(sent.headers['Idempotency-Key'], isNotNull);
    expect(weightOf(tester, 'Unit accepted'), FontWeight.w400);
    expect(find.byKey(const Key('unread-dot-n1')), findsNothing);
    expect(find.text('1 unread'), findsOneWidget);
    expect(bellBadge('1'), findsOneWidget, reason: 'the bell badge follows');
  });

  testWidgets('tapping a read item only expands it; no request is sent', (tester) async {
    final backend = await openInbox(tester, threeItems());
    await tester.tap(find.text('Paid'));
    await tester.pumpAndSettle();
    expect(backend.requests.where((r) => r.method == 'POST'), isEmpty);
    expect(tester.widget<Text>(find.text('INR 100 sent.')).maxLines, isNull, reason: 'expanded shows the full body');
  });

  testWidgets('the Unread filter hides read items', (tester) async {
    await openInbox(tester, threeItems());
    await tester.tap(find.descendant(of: find.byKey(const Key('inbox-filter')), matching: find.text('Unread')));
    await tester.pumpAndSettle();
    expect(find.text('Paid'), findsNothing);
    expect(find.text('Unit accepted'), findsOneWidget);
    expect(find.text('Pay week closed'), findsOneWidget);
    expect(find.text('Yesterday'), findsNothing);
  });

  testWidgets('mark all read posts one read per unread item, in order', (tester) async {
    final backend = await openInbox(
      tester,
      threeItems(),
      routes: {
        'POST /v1/notify/inbox/n1/read': (_) => json({...threeItems()[0], 'read_at': iso(DateTime.now())}),
        'POST /v1/notify/inbox/n3/read': (_) => json({...threeItems()[2], 'read_at': iso(DateTime.now())}),
      },
    );
    await tester.tap(find.byKey(const Key('mark-all-read')));
    await tester.pumpAndSettle();
    final posted = backend.requests.where((r) => r.method == 'POST').map((r) => r.url.path).toList();
    expect(posted, ['/v1/notify/inbox/n1/read', '/v1/notify/inbox/n3/read']);
    expect(find.text('All read'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const Key('mark-all-read'))).onPressed, isNull);
    expect(bellBadge('2'), findsNothing, reason: 'the bell badge is gone');
  });

  testWidgets('an empty inbox shows the empty state', (tester) async {
    await openInbox(tester, []);
    expect(find.text('No notifications yet. Verdicts and payouts land here.'), findsOneWidget);
    expect(find.byKey(const Key('mark-all-read')), findsNothing);
  });

  testWidgets('a failed load shows the error and Retry reloads', (tester) async {
    var down = true;
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json({'claim': null, 'unit': null}),
      'GET /v1/batches': (_) => json([]),
      'GET /v1/notify/inbox': (_) => down ? envelope(503, 'upstream_unavailable', headers: {'retry-after': '2'}) : json(threeItems()),
    });
    await pumpApp(tester, backend);
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    expect(find.text('Service is away. Retry in 2s.'), findsOneWidget);
    down = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Unit accepted'), findsOneWidget);
  });

  testWidgets('a failed mark-read keeps the item unread and shows the message', (tester) async {
    final backend = await openInbox(
      tester,
      threeItems(),
      routes: {
        'POST /v1/notify/inbox/n1/read': (_) => envelope(429, 'rate_limited', message: 'slow down', headers: {'retry-after': '7'}),
      },
    );
    await tester.tap(find.text('Unit accepted'));
    await tester.pumpAndSettle();
    expect(find.text('Too many requests. Wait 7s and try again.'), findsOneWidget);
    expect(weightOf(tester, 'Unit accepted'), FontWeight.w600);
    expect(find.byKey(const Key('unread-dot-n1')), findsOneWidget);
    expect(find.text('2 unread'), findsOneWidget);

    backend.routes['POST /v1/notify/inbox/n1/read'] = (_) => json({...threeItems()[0], 'read_at': iso(DateTime.now())});
    await tester.tap(find.text('Unit accepted'));
    await tester.pumpAndSettle();
    final keys = backend.sent('POST', '/v1/notify/inbox/n1/read').map((r) => r.headers['Idempotency-Key']).toList();
    expect(keys, hasLength(2));
    expect(keys[0], keys[1], reason: 'the retry reuses the key');
    expect(find.text('1 unread'), findsOneWidget);
  });

  testWidgets('an opened item links to the page it is about; news has no link', (tester) async {
    await openInbox(tester, threeItems());
    await tester.tap(find.text('Paid'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inbox-open-n1')), findsNothing, reason: 'only an opened item shows its link');
    await tester.tap(find.byKey(const Key('inbox-open-n2')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/work/earnings');
  });

  testWidgets('each kind leads where it belongs', (tester) async {
    expect(inboxTarget('verdict_rejected')?.path, '/work/my-work');
    expect(inboxTarget('payout_failed')?.path, '/work/earnings');
    expect(inboxTarget('adjustment_approved')?.path, '/work/earnings');
    expect(inboxTarget('application_offer')?.path, '/work/applications');
    expect(inboxTarget('bank_rejected')?.label, 'Fix bank account');
    expect(inboxTarget('bank_verified')?.path, '/work/home/onboarding');
    expect(inboxTarget('erasure_done'), isNull);
  });

  testWidgets('the inbox on a phone passes the checks and renders in dark mode', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json({'claim': null, 'unit': null}),
      'GET /v1/batches': (_) => json([]),
      'GET /v1/notify/inbox': (_) => json(threeItems()),
    });
    await pumpApp(tester, backend, size: const Size(390, 2400), at: '/inbox');
    await expectAccessible(tester);
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester, backend, dark: true, at: '/inbox');
    await expectRendersDark(tester);
  });
}
