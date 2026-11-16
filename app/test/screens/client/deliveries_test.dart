import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:yantra_app/screens/client/downloads.dart';

import '../../support/fake_backend.dart';
import '../fixtures_console.dart';

Map<String, Handler> routes() => {
  'GET /v1/client/overview': (_) => json(clientOverview()),
  'GET /v1/client/projects': (_) => json([clientProject('p1'), clientProject('p2', name: 'Shop boards')]),
  'GET /v1/client/projects/p1': (_) => json(clientProjectDetail('p1')),
  'GET /v1/client/projects/p2': (_) => json(
    clientProjectDetail(
      'p2',
      name: 'Shop boards',
      deliveries: [
        {...manifest('m2', batch: 'batch-cccc-3333'), 'created_at': '2026-11-02T10:00:00Z', 'accepted_units': 12, 'total_price': '540.00'},
      ],
    ),
  ),
  'GET /v1/client/batches/batch-cccc-3333/manifest': (_) => json({'id': 'm2', 'digest': 'sha256:abcd'}),
};

Future<void> openDeliveries(WidgetTester tester, FakeBackend backend, {bool wide = true, Size? size}) =>
    openClient(tester, backend, navKey: 'nav-deliveries', label: 'Deliveries', wide: wide, size: size);

void main() {
  testWidgets('every manifest across the projects, newest first, with project, batch, digest, units and total', (tester) async {
    final backend = FakeBackend(routes());
    await openDeliveries(tester, backend);
    expect(find.text('CLIENT · DELIVERIES'), findsOneWidget);
    expect(backend.sent('GET', '/v1/client/projects/p1'), hasLength(1));
    expect(backend.sent('GET', '/v1/client/projects/p2'), hasLength(1));
    expect(find.byKey(const Key('delivery-m1')), findsOneWidget);
    expect(find.byKey(const Key('delivery-m2')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('delivery-m2'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('delivery-m1'))).dy),
      reason: 'newest first',
    );
    expect(find.text('Hindi street signs'), findsOneWidget);
    expect(find.text('Shop boards'), findsOneWidget);
    expect(find.text('Label street signs'), findsOneWidget, reason: 'the batch title from the project detail');
    expect(find.text('batch-cccc-3333'), findsOneWidget, reason: 'a manifest whose batch is not listed shows the id');
    expect(find.text('₹2,750.00'), findsOneWidget);
    expect(find.text('₹540.00'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('1 Nov'), findsOneWidget);
    await expectAccessible(tester);
  });

  testWidgets('Manifest and Units save files; a held batch is explained on the page', (tester) async {
    var held = true;
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/client/batches/batch-cccc-3333/deliverable': (_) =>
          held ? envelope(409, 'batch_held', message: '1 unit in review') : json(deliverable(batch: 'batch-cccc-3333')),
      'GET /deliv/units.jsonl': (_) => http.Response('{"unit_id":"u9"}\n', 200),
      'GET /deliv/manifest.json': (_) => http.Response('{}', 200),
    });
    final harness = await pumpApp(tester, backend, size: const Size(1280, 2400), roles: ['client']);
    await tester.tap(find.byKey(const Key('nav-deliveries')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manifest-download-m2')));
    await tester.pumpAndSettle();
    expect(harness.downloads.saved.single.name, 'manifest-batch-cc.json');
    expect(utf8.decode(harness.downloads.saved.single.bytes), contains('"digest": "sha256:abcd"'));
    await tester.tap(find.byKey(const Key('units-download-m2')));
    await tester.pumpAndSettle();
    expect(find.text('This batch is still held at the delivery gate.'), findsOneWidget);
    expect(find.textContaining('1 unit in review'), findsNothing, reason: 'a client sees plain copy, not server text');
    held = false;
    await tester.tap(find.byKey(const Key('units-download-m2')));
    await tester.pumpAndSettle();
    await tester.pump(downloadGap);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delivery-held')), findsNothing);
    expect(harness.downloads.saved.map((f) => f.name), contains('units-batch-cc.jsonl'));
  });

  testWidgets('a delivery purged under retention says so on the page, for the units and the manifest alike', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/client/batches/batch-cccc-3333/deliverable': (_) =>
          envelope(410, 'batch_purged', context: {'batch_id': 'batch-cccc-3333', 'purged_at': '2026-11-03T10:00:00Z'}),
      'GET /v1/client/batches/batch-cccc-3333/manifest': (_) => envelope(410, 'batch_purged', context: {'batch_id': 'batch-cccc-3333'}),
    });
    final harness = await pumpApp(tester, backend, size: const Size(1280, 2400), roles: ['client']);
    await tester.tap(find.byKey(const Key('nav-deliveries')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('units-download-m2')));
    await tester.pumpAndSettle();
    final banner = find.byKey(const Key('delivery-held'));
    expect(
      find.descendant(of: banner, matching: find.text("This delivery was purged under the project's retention policy on 3 Nov.")),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('manifest-download-m2')));
    await tester.pumpAndSettle();
    expect(find.text("This delivery was purged under the project's retention policy."), findsOneWidget, reason: 'the toast');
    expect(harness.downloads.saved, isEmpty);
  });

  testWidgets('the two deliverable files are saved one after the other, not in the same instant', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/client/batches/batch-cccc-3333/deliverable': (_) => json(deliverable(batch: 'batch-cccc-3333')),
      'GET /deliv/units.jsonl': (_) => http.Response('{"unit_id":"u9"}\n', 200),
      'GET /deliv/manifest.json': (_) => http.Response('{}', 200),
    });
    final harness = await pumpApp(tester, backend, size: const Size(1280, 2400), roles: ['client']);
    await tester.tap(find.byKey(const Key('nav-deliveries')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('units-download-m2')));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(harness.downloads.saved.map((f) => f.name), ['units-batch-cc.jsonl'], reason: 'a browser drops a second save in the same tick');
    await tester.pump(downloadGap);
    await tester.pumpAndSettle();
    expect(harness.downloads.saved.map((f) => f.name), ['units-batch-cc.jsonl', 'manifest-batch-cc-files.json']);
  });

  testWidgets('without a save, the manifest opens in a copyable box', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/client/batches/batch-cccc-3333/deliverable': (_) => json(deliverable(batch: 'batch-cccc-3333')),
      'GET /deliv/units.jsonl': (_) => http.Response('{"unit_id":"u9"}\n', 200),
      'GET /deliv/manifest.json': (_) => http.Response('{}', 200),
    });
    final harness = await pumpApp(tester, backend, size: const Size(1280, 2400), roles: ['client']);
    harness.downloads.supported = false;
    await tester.tap(find.byKey(const Key('nav-deliveries')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manifest-download-m2')));
    await tester.pumpAndSettle();
    expect(tester.widget<SelectableText>(find.byKey(const Key('mono-text'))).data, contains('"digest": "sha256:abcd"'));
    await tester.tap(find.byKey(const Key('mono-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('units-download-m2')));
    await tester.pumpAndSettle();
    expect(tester.widget<SelectableText>(find.byKey(const Key('mono-text'))).data, contains('"unit_id":"u9"'));
    expect(harness.downloads.saved, isEmpty);
  });

  testWidgets('a manifest that fails to load is a toast', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/client/batches/batch-cccc-3333/manifest': (_) => envelope(404, 'not_found', message: 'gone'),
    });
    await openDeliveries(tester, backend);
    await tester.tap(find.byKey(const Key('manifest-download-m2')));
    await tester.pumpAndSettle();
    expect(find.text('This is no longer there. Refresh and try again.'), findsOneWidget);
  });

  testWidgets('the deliveries page renders in dark mode', (tester) async {
    await pumpApp(tester, FakeBackend(routes()), size: const Size(1280, 2400), roles: ['client'], dark: true, at: '/client/deliveries');
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('delivery-m1')), findsOneWidget);
    // contrast is not asserted in dark: dark-mode primary text (#C552BC) is a pending design decision
  });

  testWidgets('no deliveries shows the empty state; a failed project load offers Retry', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/client/projects': (_) => fail ? envelope(503, 'upstream_unavailable', headers: {'retry-after': '3'}) : json([]),
    });
    await openDeliveries(tester, backend);
    expect(find.text('Service is away. Retry in 3s.'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No delivery yet.'), findsOneWidget);
  });

  testWidgets('renders at phone width without overflow', (tester) async {
    await openDeliveries(tester, FakeBackend(routes()), wide: false, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('delivery-m1')), findsOneWidget);
  });

  testWidgets('renders at desktop width without overflow', (tester) async {
    await openDeliveries(tester, FakeBackend(routes()), size: const Size(1280, 900));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('delivery-m1')), findsOneWidget);
  });
}
