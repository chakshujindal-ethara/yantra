import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/core/widgets/cards.dart';
import 'package:yantra_app/core/widgets/steps.dart';

import '../../support/fake_backend.dart';
import '../fixtures_console.dart';

Map<String, Handler> routes() => {
  'GET /v1/client/overview': (_) => json(clientOverview()),
  'GET /v1/client/projects': (_) => json([clientProject('p1'), clientProject('p2', name: 'Shop boards', status: 'closed')]),
  'GET /v1/client/projects/p1': (_) => json(clientProjectDetail('p1')),
};

Finder tile(String label) => find.ancestor(of: find.text(label), matching: find.byType(KpiTile));

void main() {
  testWidgets('the client lands on Overview with the numbers from GET /v1/client/overview and the projects', (tester) async {
    final backend = FakeBackend(routes());
    await openClient(tester, backend);
    expect(find.text('CLIENT · OVERVIEW'), findsOneWidget);
    expect(find.text('Acme Maps'), findsOneWidget, reason: 'the org names the page');
    expect(find.descendant(of: tile('Units delivered'), matching: find.text('55')), findsOneWidget);
    expect(find.text('Accepted of 100 in total'), findsOneWidget);
    expect(find.descendant(of: tile('In progress'), matching: find.text('20')), findsOneWidget);
    expect(find.text('10 in review · 20 not started'), findsOneWidget);
    expect(find.descendant(of: tile('Acceptance rate'), matching: find.text('92%')), findsOneWidget);
    expect(find.descendant(of: tile('Rework billed'), matching: find.text('4')), findsOneWidget);
    expect(find.descendant(of: tile('Deliveries'), matching: find.text('2')), findsOneWidget);
    expect(find.descendant(of: tile('Invoice to date'), matching: find.text('₹12,500.00')), findsOneWidget);
    expect(find.text('2 projects'), findsOneWidget);
    expect(find.byKey(const Key('project-p1')), findsOneWidget);
    expect(find.byKey(const Key('project-p2')), findsOneWidget);
    expect(find.byType(StackedBar), findsNWidgets(2));
    expect(find.textContaining('per unit'), findsNothing, reason: 'a client never sees pay');
    expect(find.textContaining('12.50'), findsNothing);
    await expectAccessible(tester);
  });

  testWidgets('a project card opens the project route with batches, reasons, deliveries and feedback', (tester) async {
    final backend = FakeBackend(routes());
    await openClient(tester, backend);
    await tester.tap(find.byKey(const Key('project-p1')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/client/projects/p1'), hasLength(1));
    expect(find.text('CLIENT · PROJECTS'), findsOneWidget);
    expect(find.text('Rubric v3 · INR'), findsOneWidget);
    expect(find.byKey(const Key('batch-batch-aaaa-1111')), findsOneWidget);
    expect(find.text('₹50.00 per accepted unit'), findsOneWidget);
    expect(find.text('₹45.00 per accepted unit'), findsOneWidget);
    expect(find.widgetWithText(StatusChip, 'Delivered'), findsOneWidget);
    expect(find.byKey(const Key('reason-client_glossary_change')), findsOneWidget);
    expect(find.text('Billable'), findsOneWidget);
    expect(find.text('Not billed'), findsOneWidget);
    expect(find.byKey(const Key('delivery-m1')), findsOneWidget);
    expect(find.text('Please prioritise the Delhi set.'), findsOneWidget);
    // the project lives under Projects: the link switches to that branch, and back returns to its list
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('crumb-current')), findsNothing);
    expect(find.text('CLIENT · PROJECTS'), findsOneWidget);
  });

  testWidgets('Next delivery names the open batch due first and how far along it is', (tester) async {
    final due = DateTime.now().add(const Duration(days: 3)).toUtc().toIso8601String();
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/client/overview': (_) => json(
        clientOverview(
          nextDelivery: {
            'batch_id': 'b1',
            'title': 'Week 46 clips',
            'project_id': 'p1',
            'project_name': 'Hindi street signs',
            'due_at': due,
            'accepted': 12,
            'total': 40,
          },
        ),
      ),
    });
    await openClient(tester, backend);
    final tile = find.byKey(const Key('next-delivery'));
    expect(find.descendant(of: tile, matching: find.text('Week 46 clips · Hindi street signs · 12 of 40 accepted')), findsOneWidget);
  });

  testWidgets('with nothing due the tile says so', (tester) async {
    await openClient(tester, FakeBackend(routes()));
    expect(
      find.descendant(of: find.byKey(const Key('next-delivery')), matching: find.text('No open batch has a due date')),
      findsOneWidget,
    );
  });

  testWidgets('a past-due batch is flagged', (tester) async {
    final past = DateTime.now().subtract(const Duration(days: 2)).toUtc().toIso8601String();
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/client/overview': (_) => json(
        clientOverview(
          nextDelivery: {
            'batch_id': 'b1',
            'title': '',
            'project_id': 'p1',
            'project_name': 'Signs',
            'due_at': past,
            'accepted': 1,
            'total': 2,
          },
        ),
      ),
    });
    await openClient(tester, backend);
    expect(
      find.descendant(
        of: find.byKey(const Key('next-delivery')),
        matching: find.textContaining('Batch · Signs · 1 of 2 accepted · past due'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the overview renders in dark mode and at phone width', (tester) async {
    await pumpApp(tester, FakeBackend(routes()), size: const Size(390, 2400), roles: ['client'], dark: true);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('next-delivery')), findsOneWidget);
    await expectAccessible(tester);
  });

  testWidgets('"All projects" moves to the Projects destination', (tester) async {
    final backend = FakeBackend(routes());
    await openClient(tester, backend);
    await tester.tap(find.byKey(const Key('overview-all-projects')));
    await tester.pumpAndSettle();
    expect(find.text('CLIENT · PROJECTS'), findsOneWidget);
  });

  testWidgets('a failed load offers Retry; no projects and no invoice say what comes next', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      'GET /v1/client/overview': (_) =>
          fail ? envelope(503, 'upstream_unavailable', headers: {'retry-after': '3'}) : json({...clientOverview(), 'invoice_total': {}}),
      'GET /v1/client/projects': (_) => json([]),
    });
    await openClient(tester, backend, size: const Size(1280, 900));
    expect(find.text('Service is away. Retry in 3s.'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No project yet.'), findsOneWidget);
    expect(find.descendant(of: tile('Invoice to date'), matching: find.text('—')), findsOneWidget);
  });

  testWidgets('renders at phone width without overflow, and the project route too', (tester) async {
    final backend = FakeBackend(routes());
    await openClient(tester, backend, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    final card = find.byKey(const Key('project-p1'));
    await tester.scrollUntilVisible(card, 300, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(card);
    // the card's top edge, not its centre: the bottom bar may still cover the centre on a phone
    await tester.tapAt(tester.getTopLeft(card) + const Offset(24, 20));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Rubric v3 · INR'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('batch-batch-aaaa-1111')), 300, scrollable: find.byType(Scrollable).last);
    expect(find.byKey(const Key('batch-batch-aaaa-1111')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders at desktop width without overflow', (tester) async {
    await openClient(tester, FakeBackend(routes()), size: const Size(1280, 900));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('project-p1')), findsOneWidget);
  });
}
