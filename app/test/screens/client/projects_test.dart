import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/core/widgets/loader.dart';
import 'package:yantra_app/core/widgets/steps.dart';

import 'package:yantra_app/screens/client/downloads.dart';

import '../../support/fake_backend.dart';
import '../fixtures_console.dart';

Map<String, Handler> routes() => {
  'GET /v1/client/overview': (_) => json(clientOverview()),
  'GET /v1/client/projects': (_) => json([clientProject('p1'), clientProject('p2', name: 'Shop boards', status: 'closed')]),
  'GET /v1/client/projects/p1': (_) => json(clientProjectDetail('p1')),
  'GET /v1/client/batches/batch-aaaa-1111/manifest': (_) => json({
    'id': 'm1',
    'digest': 'sha256:9f8e',
    'units': [
      {'id': 'u1', 'verdict': 'accept'},
    ],
  }),
};

Future<void> openProjects(WidgetTester tester, FakeBackend backend, {bool wide = true, Size? size}) =>
    openClient(tester, backend, navKey: 'nav-clientProjects', label: 'Projects', wide: wide, size: size);

/// [openProjects] that hands back the harness, for the files the page saved.
Future<TestHarness> openProjectsH(WidgetTester tester, FakeBackend backend) async {
  final harness = await pumpApp(tester, backend, size: const Size(1280, 2400), roles: ['client']);
  await tester.tap(find.byKey(const Key('nav-clientProjects')));
  await tester.pumpAndSettle();
  return harness;
}

/// Taps the row at its left edge: on a phone the table scrolls sideways and the row's centre is off-screen.
Future<void> openRow(WidgetTester tester, String key) async {
  final row = find.byKey(Key(key));
  await tester.ensureVisible(row);
  await tester.tapAt(tester.getTopLeft(row) + const Offset(24, 20));
  await tester.pumpAndSettle();
}

Finder chip(String label) => find.widgetWithText(StatusChip, label);

void main() {
  testWidgets('the table lists name, status, units bar, acceptance and invoice per project', (tester) async {
    final backend = FakeBackend(routes());
    await openProjects(tester, backend);
    expect(find.text('CLIENT · PROJECTS'), findsOneWidget);
    expect(find.byKey(const Key('project-p1')), findsOneWidget);
    expect(find.text('Hindi street signs'), findsOneWidget);
    expect(find.text('Shop boards'), findsOneWidget);
    expect(chip('active'), findsOneWidget);
    expect(chip('closed'), findsOneWidget);
    expect(find.byType(StackedBar), findsNWidgets(2));
    expect(find.text('55/100'), findsNWidgets(2));
    expect(find.text('92%'), findsNWidgets(2));
    expect(find.text('₹12,500.00'), findsNWidgets(2));
    await expectAccessible(tester);
  });

  testWidgets('a row opens the project; Manifest saves the manifest as a JSON file', (tester) async {
    final backend = FakeBackend(routes());
    final harness = await openProjectsH(tester, backend);
    await openRow(tester, 'project-p1');
    expect(find.byKey(const Key('project-status')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('manifest-download-m1')));
    await tester.tap(find.byKey(const Key('manifest-download-m1')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/client/batches/batch-aaaa-1111/manifest'), hasLength(1));
    final file = harness.downloads.saved.single;
    expect(file.name, 'manifest-batch-aa.json');
    expect(file.mime, 'application/json');
    expect(utf8.decode(file.bytes), contains('"digest": "sha256:9f8e"'));
    expect(find.text('Manifest downloaded'), findsOneWidget);
  });

  testWidgets('Units saves the deliverable JSONL and its manifest from object storage', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/client/batches/batch-aaaa-1111/deliverable': (_) => json(deliverable()),
      'GET /deliv/units.jsonl': (_) => http.Response('{"unit_id":"u1"}\n{"unit_id":"u2"}\n', 200),
      'GET /deliv/manifest.json': (_) => http.Response('{"digest":"sha256:9f8e"}', 200),
    });
    final harness = await openProjectsH(tester, backend);
    await openRow(tester, 'project-p1');
    await tester.ensureVisible(find.byKey(const Key('units-download-m1')));
    await tester.tap(find.byKey(const Key('units-download-m1')));
    await tester.pumpAndSettle();
    await tester.pump(downloadGap); // the second file follows after a short gap
    await tester.pumpAndSettle();
    final saved = harness.downloads.saved;
    expect(saved.map((f) => f.name), ['units-batch-aa.jsonl', 'manifest-batch-aa-files.json']);
    expect(saved.first.mime, 'application/x-ndjson');
    expect(utf8.decode(saved.first.bytes), contains('"unit_id":"u2"'));
    expect(find.text('Deliverable downloaded: 2 units'), findsOneWidget);
  });

  testWidgets('a held batch shows why on the page; a storage failure is a toast', (tester) async {
    var held = true;
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/client/batches/batch-aaaa-1111/deliverable': (_) =>
          held ? envelope(409, 'batch_held', message: '3 units are not accepted yet') : json(deliverable()),
      'GET /deliv/units.jsonl': (_) => http.Response('denied', 403),
    });
    final harness = await openProjectsH(tester, backend);
    await openRow(tester, 'project-p1');
    await tester.ensureVisible(find.byKey(const Key('units-download-m1')));
    await tester.tap(find.byKey(const Key('units-download-m1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delivery-held')), findsOneWidget);
    expect(find.text('This batch is still held at the delivery gate.'), findsOneWidget);
    held = false;
    await tester.tap(find.byKey(const Key('units-download-m1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delivery-held')), findsNothing);
    expect(find.text('The file could not be fetched (403).'), findsOneWidget);
    expect(harness.downloads.saved, isEmpty);
  });

  testWidgets('the thread names authors and badges Yantra answers', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/client/projects/p1': (_) => json(
        clientProjectDetail(
          'p1',
          feedback: [
            {
              'id': 'f1',
              'author_id': 'client-9999-1',
              'author_kind': 'client',
              'author_name': 'Asha Rao',
              'body': 'Please prioritise the Delhi set.',
              'created_at': '2026-11-01T09:00:00Z',
            },
            {
              'id': 'f2',
              'author_id': 'ops-1',
              'author_kind': 'staff',
              'author_name': 'Ravi (Yantra)',
              'body': 'Done: the Delhi set is first in the queue.',
              'created_at': '2026-11-02T09:00:00Z',
            },
          ],
        ),
      ),
    });
    await openProjects(tester, backend, size: const Size(1280, 3000));
    await openRow(tester, 'project-p1');
    expect(find.text('Asha Rao'), findsOneWidget);
    expect(find.text('Ravi (Yantra)'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const Key('feedback-f2')), matching: find.byKey(const Key('feedback-staff-badge'))),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(const Key('feedback-f1')), matching: find.byKey(const Key('feedback-staff-badge'))),
      findsNothing,
    );
    await expectAccessible(tester);
  });

  testWidgets('the project page renders in dark mode', (tester) async {
    await pumpApp(tester, FakeBackend(routes()), size: const Size(1280, 2400), roles: ['client'], dark: true, at: '/client/projects/p1');
    expect(tester.takeException(), isNull);
    expect(find.text('Rubric v3 · INR'), findsOneWidget);
    // contrast is not asserted in dark: dark-mode primary text (#C552BC) is a pending design decision
  });

  testWidgets('feedback validates, POSTs the body with an idempotency key and reloads the thread', (tester) async {
    var sent = false;
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/client/projects/p1': (_) => json(
        clientProjectDetail(
          'p1',
          feedback: [
            {'id': 'f1', 'author_id': 'client-9999-1', 'body': 'Please prioritise the Delhi set.', 'created_at': '2026-11-01T09:00:00Z'},
            if (sent)
              {
                'id': 'f2',
                'author_id': 'client-9999-1',
                'body': 'Thanks, the Delhi set looks good now.',
                'created_at': '2026-11-03T09:00:00Z',
              },
          ],
        ),
      ),
      'POST /v1/client/projects/p1/feedback': (r) {
        sent = true;
        return json({
          'id': 'f2',
          'author_id': 'client-9999-1',
          'body': jsonDecode(r.body)['body'],
          'created_at': '2026-11-03T09:00:00Z',
        }, status: 201);
      },
    });
    await openProjects(tester, backend, size: const Size(1280, 3000));
    await openRow(tester, 'project-p1');
    await tester.ensureVisible(find.byKey(const Key('feedback-send')));
    await tester.tap(find.byKey(const Key('feedback-send')));
    await tester.pumpAndSettle();
    expect(find.text('Say a little more, at least 5 characters'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('feedback-body')), 'Thanks, the Delhi set looks good now.');
    await tester.tap(find.byKey(const Key('feedback-send')));
    await tester.pumpAndSettle();
    final req = backend.sent('POST', '/v1/client/projects/p1/feedback').single;
    expect(jsonDecode(req.body), {'body': 'Thanks, the Delhi set looks good now.'});
    expect(req.headers['Idempotency-Key'], isNotNull);
    expect(find.text('Feedback sent'), findsOneWidget);
    expect(find.byKey(const Key('feedback-f2')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('feedback-body'))).controller!.text, isEmpty);
  });

  testWidgets('an empty project list shows the table empty state; a failed load offers Retry', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/client/projects': (_) => fail ? envelope(503, 'upstream_unavailable', headers: {'retry-after': '3'}) : json([]),
    });
    await openProjects(tester, backend);
    expect(find.text('Service is away. Retry in 3s.'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No project yet.'), findsOneWidget);
  });

  testWidgets('the brand loader shows while the first load is in flight', (tester) async {
    await pumpApp(tester, FakeBackend(routes()), size: const Size(1280, 900), roles: ['client']);
    await tester.tap(find.byKey(const Key('nav-clientProjects')));
    await tester.pump();
    expect(find.byType(BrandLoader), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(BrandLoader), findsNothing);
  });

  testWidgets('renders at phone width without overflow; the project route too', (tester) async {
    final backend = FakeBackend(routes());
    await openProjects(tester, backend, wide: false, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    await openRow(tester, 'project-p1');
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('₹50.00 per accepted unit'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.text('₹50.00 per accepted unit'), findsOneWidget);
  });

  testWidgets('renders at desktop width without overflow', (tester) async {
    final backend = FakeBackend(routes());
    await openProjects(tester, backend, size: const Size(1280, 900));
    expect(tester.takeException(), isNull);
    await openRow(tester, 'project-p1');
    expect(tester.takeException(), isNull);
  });
}
