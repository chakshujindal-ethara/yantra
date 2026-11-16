import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/theme/app_theme.dart';

import '../../support/fake_backend.dart';
import '../fixtures_console.dart';

Map<String, Handler> routes({List<Object?>? tickets}) => {
  'GET /v1/notify/tickets': (_) => json(
    tickets ??
        [
          ticket('t1'),
          ticket('t2', status: 'in_progress', category: 'payment', title: 'Payout reference missing'),
          ticket('t3', status: 'resolved', category: 'work', title: 'Unit payload empty', note: 'Re-imported the batch'),
        ],
  ),
};

Future<void> openSupport(WidgetTester tester, FakeBackend backend, {bool wide = true, Size? size}) =>
    openOps(tester, backend, navKey: 'nav-support', label: 'Support', wide: wide, size: size);

Finder chip(String label) => find.widgetWithText(StatusChip, label);

void main() {
  testWidgets('wide: three columns, each ticket card with its category chip, title, author, age and screen', (tester) async {
    final backend = FakeBackend(routes());
    await openSupport(tester, backend);
    expect(find.text('OPERATE · SUPPORT'), findsOneWidget);
    expect(find.byKey(const Key('column-open')), findsOneWidget);
    expect(find.byKey(const Key('column-in_progress')), findsOneWidget);
    expect(find.byKey(const Key('column-resolved')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('column-open')), matching: find.byKey(const Key('ticket-t1'))), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('column-in_progress')), matching: find.byKey(const Key('ticket-t2'))), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('column-resolved')), matching: find.byKey(const Key('ticket-t3'))), findsOneWidget);
    expect(chip('Bug'), findsOneWidget);
    expect(chip('Payment'), findsOneWidget);
    expect(chip('Work'), findsOneWidget);
    expect(find.text('Submit button does nothing'), findsOneWidget);
    expect(find.text('r-5555-1'), findsNWidgets(3));
    expect(find.text('5 h ago'), findsNWidgets(3));
    expect(find.text('Work'), findsWidgets, reason: 'the screen the person was on');
    await expectAccessible(tester);
  });

  testWidgets('opening a ticket shows the drawer with body, context and Start; starting posts in_progress', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'POST /v1/notify/tickets/t1/status': (r) =>
          json({...ticket('t1'), 'status': jsonDecode(r.body)['status'], 'note': jsonDecode(r.body)['note']}),
    });
    await openSupport(tester, backend);
    final loads = backend.sent('GET', '/v1/notify/tickets').length;
    await tester.tap(find.byKey(const Key('ticket-t1')));
    await tester.pumpAndSettle();
    expect(find.text('I filled the form and nothing happened after Submit.'), findsOneWidget);
    expect(find.text('app: web'), findsOneWidget);
    expect(find.text('width: 1280'), findsOneWidget);
    expect(find.byKey(const Key('ticket-start')), findsOneWidget);
    expect(find.byKey(const Key('ticket-resolve')), findsNothing);
    await tester.enterText(find.byKey(const Key('ticket-note')), 'On it');
    await tester.tap(find.byKey(const Key('ticket-start')));
    await tester.pumpAndSettle();
    final sent = backend.sent('POST', '/v1/notify/tickets/t1/status').single;
    expect(jsonDecode(sent.body), {'status': 'in_progress', 'note': 'On it'});
    expect(sent.headers['Idempotency-Key'], isNotNull);
    expect(tester.widget<StatusChip>(find.byKey(const Key('ticket-status'))).label, 'In progress');
    expect(find.byKey(const Key('ticket-resolve')), findsOneWidget, reason: 'the sheet moved on with the ticket');
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/notify/tickets').length, loads + 1, reason: 'the board reloads after a move');
  });

  testWidgets('resolving requires nothing but posts the note; a resolved ticket offers Reopen', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'POST /v1/notify/tickets/t2/status': (r) =>
          json({...ticket('t2', status: 'in_progress'), 'status': jsonDecode(r.body)['status'], 'note': jsonDecode(r.body)['note']}),
      'POST /v1/notify/tickets/t3/status': (r) => json({...ticket('t3', status: 'resolved'), 'status': jsonDecode(r.body)['status']}),
    });
    await openSupport(tester, backend);
    await tester.tap(find.byKey(const Key('ticket-t2')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ticket-note')), 'Reference was on the next line');
    await tester.tap(find.byKey(const Key('ticket-resolve')));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('POST', '/v1/notify/tickets/t2/status').single.body), {
      'status': 'resolved',
      'note': 'Reference was on the next line',
    });
    expect(find.text('Resolved'), findsWidgets);
    expect(find.byKey(const Key('ticket-note-shown')), findsOneWidget);
    expect(find.byKey(const Key('ticket-reopen')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ticket-t3')));
    await tester.pumpAndSettle();
    expect(find.text('Re-imported the batch'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ticket-reopen')));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('POST', '/v1/notify/tickets/t3/status').single.body)['status'], 'open');
    expect(find.byKey(const Key('ticket-start')), findsOneWidget);
  });

  testWidgets('a failed move stays in the drawer with the reason', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'POST /v1/notify/tickets/t1/status': (_) => envelope(429, 'rate_limited', headers: {'retry-after': '7'}),
    });
    await openSupport(tester, backend);
    await tester.tap(find.byKey(const Key('ticket-t1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ticket-start')));
    await tester.pumpAndSettle();
    expect(find.text('Too many requests. Wait 7s and try again.'), findsOneWidget);
    expect(find.byKey(const Key('ticket-start')), findsOneWidget);
  });

  testWidgets('no tickets shows the empty state; a failed load offers Retry', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      'GET /v1/notify/tickets': (_) => fail ? envelope(503, 'upstream_unavailable', headers: {'retry-after': '3'}) : json([]),
    });
    await openSupport(tester, backend);
    expect(find.text('Service is away. Retry in 3s.'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No tickets.'), findsOneWidget);
  });

  testWidgets('narrow: filter chips over one list, and a bottom sheet per ticket', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'POST /v1/notify/tickets/t1/status': (r) => json({...ticket('t1'), 'status': jsonDecode(r.body)['status']}),
    });
    await openSupport(tester, backend, wide: false, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('column-open')), findsNothing);
    expect(find.byKey(const Key('filter-all')), findsOneWidget);
    expect(find.byKey(const Key('ticket-t1')), findsOneWidget);
    expect(find.byKey(const Key('ticket-t2')), findsOneWidget);
    await tester.tap(find.byKey(const Key('filter-resolved')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ticket-t1')), findsNothing);
    expect(find.byKey(const Key('ticket-t3')), findsOneWidget);
    await tester.tap(find.byKey(const Key('filter-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ticket-t1')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byKey(const Key('ticket-start')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ticket-start')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/notify/tickets/t1/status'), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty column says so at desktop width', (tester) async {
    final backend = FakeBackend(routes(tickets: [ticket('t1')]));
    await openSupport(tester, backend, size: const Size(1280, 900));
    expect(find.text('Nothing in progress'), findsOneWidget);
    expect(find.text('Nothing resolved'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tickets show the author by name and the search narrows the board', (tester) async {
    final backend = FakeBackend(
      routes(
        tickets: [
          {...ticket('t1'), 'author_name': 'Asha Verma'},
          ticket('t2', status: 'in_progress', category: 'payment', title: 'Payout reference missing'),
        ],
      ),
    );
    await openSupport(tester, backend);
    expect(find.text('Asha Verma'), findsNWidgets(2), reason: 'both tickets are hers; the second is named from the people cache');
    await tester.enterText(find.byKey(const Key('support-search')), 'payout');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ticket-t2')), findsOneWidget);
    expect(find.byKey(const Key('ticket-t1')), findsNothing);
    await tester.enterText(find.byKey(const Key('support-search')), 'asha');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ticket-t1')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('support-search')), 'nothing like this');
    await tester.pumpAndSettle();
    expect(find.text('No ticket matches "nothing like this"'), findsOneWidget);
  });

  testWidgets('renders in dark mode on a phone without overflow', (tester) async {
    final backend = FakeBackend(routes());
    await pumpApp(tester, backend, size: const Size(390, 2400), roles: const ['ops', 'finance'], dark: true, at: '/ops/support');
    expect(tester.takeException(), isNull);
    expect(find.text('Submit button does nothing'), findsWidgets);
  });
}
