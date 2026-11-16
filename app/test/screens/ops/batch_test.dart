import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:yantra_app/core/widgets/cards.dart';

import '../../support/fake_backend.dart';
import 'fixtures_ops.dart';

Finder tile(String label) => find.ancestor(of: find.text(label), matching: find.byType(KpiTile));

Map<String, Handler> batchRoutes({String status = 'open', String unitPay = '28.00', Map<String, Object?>? manifest}) => {
  ...overviewRoutes(),
  'GET /v1/batches/b1': (_) => json(batchSummary(status: status, unitPay: unitPay, manifest: manifest)),
  'GET /v1/batches/b1/units': (_) => json(unitsPage()),
  'GET /v1/projects/p1': (_) => json(projectDetail()),
};

Future<void> openBatch(WidgetTester tester, FakeBackend backend, {Size size = wide, double? floor = 0.3}) async {
  await pumpOps(tester, backend, size: size);
  await goTo(tester, '/ops/projects/p1/batches/b1', extra: floor);
}

void main() {
  testWidgets('the header carries the status, the pay against the bill and the counts', (tester) async {
    final backend = FakeBackend(batchRoutes());
    await openBatch(tester, backend);
    expect(find.text('OPERATE · BATCH'), findsOneWidget);
    expect(find.text('Label street signs'), findsOneWidget);
    expect(find.text('Hindi transcription · Open · claim TTL 4 h · rubric v2'), findsOneWidget);
    expect(chip('Open'), findsOneWidget);
    expect(find.text('₹28.00 pay'), findsOneWidget);
    expect(find.text('₹60.00 bill'), findsOneWidget);
    expect(find.text('47% margin'), findsOneWidget);
    expect(find.descendant(of: tile('Available'), matching: find.text('40')), findsOneWidget);
    expect(find.descendant(of: tile('Live claims'), matching: find.text('5')), findsOneWidget);
    expect(find.descendant(of: tile('In review'), matching: find.text('5')), findsOneWidget);
    expect(find.byKey(const Key('batch-pause')), findsOneWidget);
    expect(find.byKey(const Key('batch-cancel')), findsOneWidget);
    expect(find.byKey(const Key('batch-publish')), findsNothing);
    expect(find.byKey(const Key('batch-resume')), findsNothing);
    expect(
      backend.sent('GET', '/v1/projects/p1'),
      hasLength(1),
      reason: 'only the project page under it reads the project: the floor came with the route',
    );
    await expectAccessible(tester);
  });

  testWidgets('actions follow the status: draft publishes, paused resumes, closed has none', (tester) async {
    final backend = FakeBackend(batchRoutes(status: 'draft'));
    await openBatch(tester, backend);
    expect(find.byKey(const Key('batch-publish')), findsOneWidget);
    expect(find.byKey(const Key('batch-cancel')), findsOneWidget);
    expect(find.byKey(const Key('batch-pause')), findsNothing);
    await tester.pumpWidget(const SizedBox());

    final paused = FakeBackend(batchRoutes(status: 'paused'));
    await openBatch(tester, paused);
    expect(find.byKey(const Key('batch-resume')), findsOneWidget);
    expect(find.byKey(const Key('batch-cancel')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    final closed = FakeBackend(batchRoutes(status: 'closed'));
    await openBatch(tester, closed);
    expect(find.byKey(const Key('batch-publish')), findsNothing);
    expect(find.byKey(const Key('batch-pause')), findsNothing);
    expect(find.byKey(const Key('batch-resume')), findsNothing);
    expect(find.byKey(const Key('batch-cancel')), findsNothing);
  });

  testWidgets('pause posts with a key and reloads; a 409 on cancel shows the message', (tester) async {
    final backend = FakeBackend({
      ...batchRoutes(),
      'POST /v1/batches/b1/pause': (_) => json(batchSummary(status: 'paused')),
      'POST /v1/batches/b1/cancel': (_) => envelope(409, 'live_claims', message: '5 live claims; wait for them to end'),
    });
    await openBatch(tester, backend);
    await tester.tap(find.byKey(const Key('batch-pause')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/batches/b1/pause').single.headers['Idempotency-Key'], isNotEmpty);
    expect(find.text('Batch paused'), findsOneWidget);
    expect(backend.sent('GET', '/v1/batches/b1'), hasLength(2));
    expect(backend.sent('GET', '/v1/batches/b1/units'), hasLength(2), reason: 'the units table loads again too');

    await tester.tap(find.byKey(const Key('batch-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Cancel "Label street signs"?'), findsOneWidget);
    await tester.tap(find.text('Cancel batch'));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/batches/b1/cancel'), hasLength(1));
    expect(find.byKey(const Key('batch-error')), findsOneWidget);
    expect(find.textContaining('Details: 5 live claims; wait for them to end'), findsOneWidget);
  });

  testWidgets('publishing above the floor confirms and posts no approval', (tester) async {
    final backend = FakeBackend({
      ...batchRoutes(status: 'draft'),
      'POST /v1/batches/b1/publish': (_) => json(batchSummary(status: 'open')),
    });
    await openBatch(tester, backend);
    backend.routes['GET /v1/batches/b1'] = (_) => json(batchSummary(status: 'open'));
    await tester.tap(find.byKey(const Key('batch-publish')));
    await tester.pumpAndSettle();
    expect(find.text('Publish "Label street signs"?'), findsOneWidget);
    await tester.tap(find.text('Publish').last);
    await tester.pumpAndSettle();
    final post = backend.sent('POST', '/v1/batches/b1/publish').single;
    expect(jsonDecode(post.body), {'approved_by': null, 'approval_note': null});
    expect(find.text('Batch published'), findsOneWidget);
    expect(chip('Open'), findsOneWidget);
  });

  testWidgets('publishing under the floor asks who approved it and why, and sends both', (tester) async {
    final backend = FakeBackend({
      ...batchRoutes(status: 'draft', unitPay: '50.00'),
      'POST /v1/batches/b1/publish': (_) => json(batchSummary(status: 'open', unitPay: '50.00')),
    });
    await openBatch(tester, backend);
    expect(find.text('10% margin'), findsOneWidget);
    await tester.tap(find.byKey(const Key('batch-publish')));
    await tester.pumpAndSettle();
    expect(find.text('Publish under the floor'), findsOneWidget);
    await tester.tap(find.byKey(const Key('publish-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Both the approver and a note are required to publish under the floor'), findsOneWidget);
    expect(backend.sent('POST', '/v1/batches/b1/publish'), isEmpty);
    await tester.enterText(find.byKey(const Key('publish-approved-by')), 'Asha');
    await tester.enterText(find.byKey(const Key('publish-note')), 'Client agreed to the pilot rate');
    await tester.tap(find.byKey(const Key('publish-confirm')));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('POST', '/v1/batches/b1/publish').single.body), {
      'approved_by': 'Asha',
      'approval_note': 'Client agreed to the pilot rate',
    });
    expect(find.text('Batch published'), findsOneWidget);
  });

  testWidgets('import: a dry run reports every bad line; Import opens only after a clean dry run', (tester) async {
    var calls = 0;
    final backend = FakeBackend({
      ...batchRoutes(status: 'draft'),
      'POST /v1/batches/b1/units/import': (r) {
        calls++;
        final dry = r.url.queryParameters['dry_run'] == 'true';
        if (calls == 1) {
          return json(
            importReport(
              total: 3,
              accepted: 1,
              errors: [
                {'line': 2, 'external_ref': 'row-2', 'reason': 'payload: missing text'},
                {'line': 3, 'external_ref': '', 'reason': 'external_ref: required'},
              ],
            ),
          );
        }
        return json(importReport(total: 3, accepted: 3, dryRun: dry));
      },
    });
    await openBatch(tester, backend);
    await reveal(tester, find.byKey(const Key('import-dry-run')));
    await tester.tap(find.byKey(const Key('import-dry-run')));
    await tester.pumpAndSettle();
    expect(find.text('Paste the lines first'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('import-lines')), '[{"external_ref": "row-1"}, nope]');
    await tester.tap(find.byKey(const Key('import-dry-run')));
    await tester.pumpAndSettle();
    expect(find.textContaining('is not valid JSON'), findsOneWidget);
    expect(backend.sent('POST', '/v1/batches/b1/units/import'), isEmpty);

    const lines =
        '[{"external_ref": "row-1", "payload": {"text": "a"}}, {"external_ref": "row-2", "payload": {}}, {"payload": {"text": "c"}}]';
    await tester.enterText(find.byKey(const Key('import-lines')), lines);
    await tester.tap(find.byKey(const Key('import-dry-run')));
    await tester.pumpAndSettle();
    final dry = backend.sent('POST', '/v1/batches/b1/units/import').single;
    expect(dry.url.queryParameters['dry_run'], 'true');
    expect(dry.headers['Idempotency-Key'], isNotEmpty);
    expect((jsonDecode(dry.body) as Map)['lines'], hasLength(3));
    expect(find.text('Dry run: 1 of 3 lines accepted · 2 problems below. Fix the lines and run again.'), findsOneWidget);
    expect(find.byKey(const Key('import-errors')), findsOneWidget);
    expect(find.text('payload: missing text'), findsOneWidget);
    expect(find.text('external_ref: required'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('import-errors')), matching: find.text('row-2')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('import-commit'))).onPressed, isNull);

    await tester.tap(find.byKey(const Key('import-dry-run')));
    await tester.pumpAndSettle();
    expect(find.text('Dry run: all 3 lines accepted. Import to create the units.'), findsOneWidget);
    expect(find.text('Import 3 units'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('import-commit'))).onPressed, isNotNull);

    await tester.enterText(find.byKey(const Key('import-lines')), '$lines ');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const Key('import-commit'))).onPressed, isNull, reason: 'edited since the dry run');
    await tester.enterText(find.byKey(const Key('import-lines')), lines);
    await tester.pump();

    await tester.tap(find.byKey(const Key('import-commit')));
    await tester.pumpAndSettle();
    final commit = backend.sent('POST', '/v1/batches/b1/units/import')[2];
    expect(commit.url.queryParameters['dry_run'], 'false');
    expect(find.text('3 units imported'), findsWidgets);
    expect(tester.widget<TextField>(find.byKey(const Key('import-lines'))).controller!.text, isEmpty);
    expect(backend.sent('GET', '/v1/batches/b1'), hasLength(2));
  });

  testWidgets('import accepts one object per line', (tester) async {
    final backend = FakeBackend({
      ...batchRoutes(status: 'draft'),
      'POST /v1/batches/b1/units/import': (_) => json(importReport(total: 2, accepted: 2)),
    });
    await openBatch(tester, backend);
    await reveal(tester, find.byKey(const Key('import-dry-run')));
    await tester.enterText(
      find.byKey(const Key('import-lines')),
      '{"external_ref": "a", "payload": {}}\n{"external_ref": "b", "payload": {}}\n',
    );
    await tester.tap(find.byKey(const Key('import-dry-run')));
    await tester.pumpAndSettle();
    expect((jsonDecode(backend.sent('POST', '/v1/batches/b1/units/import').single.body) as Map)['lines'], [
      {'external_ref': 'a', 'payload': {}},
      {'external_ref': 'b', 'payload': {}},
    ]);
  });

  testWidgets('the units table filters by status and pages by fifty', (tester) async {
    final backend = FakeBackend({...batchRoutes(), 'GET /v1/batches/b1/units': (_) => json(unitsPage(total: 120, count: 50))});
    await openBatch(tester, backend);
    final first = backend.sent('GET', '/v1/batches/b1/units').single;
    expect(first.url.queryParameters, {'limit': '50', 'offset': '0'});
    await reveal(tester, find.text('row-1'));
    expect(find.text('row-50'), findsOneWidget);
    expect(find.text('001-ffff'), findsOneWidget);
    expect(find.text('120 units'), findsOneWidget);

    await reveal(tester, find.byKey(const Key('filter-accepted')));
    await tester.tap(find.byKey(const Key('filter-accepted')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/batches/b1/units')[1].url.queryParameters, {'status': 'accepted', 'limit': '50', 'offset': '0'});

    await reveal(tester, find.byKey(const Key('pager-next')));
    await tester.tap(find.byKey(const Key('pager-next')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/batches/b1/units')[2].url.queryParameters, {'status': 'accepted', 'limit': '50', 'offset': '50'});
    expect(find.text('51–100 of 120'), findsOneWidget);
  });

  testWidgets('the manifest card shows the delivery gate on a 409 and the manifest once built', (tester) async {
    var held = true;
    final backend = FakeBackend({
      ...batchRoutes(),
      'GET /v1/batches/b1/manifest': (_) => held ? envelope(409, 'batch_held', message: '3 units still open') : json(manifestJson),
    });
    await openBatch(tester, backend);
    expect(find.text('No manifest yet'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('manifest-build')));
    await tester.tap(find.byKey(const Key('manifest-build')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manifest-gate')), findsOneWidget);
    expect(find.textContaining('Details: 3 units still open'), findsOneWidget);
    held = false;
    backend.routes['GET /v1/batches/b1'] = (_) => json(batchSummary(manifest: manifestJson));
    await tester.tap(find.byKey(const Key('manifest-build')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manifest-gate')), findsNothing);
    expect(find.text('Manifest built'), findsOneWidget);
    expect(find.text('sha256:abcdef1234567890'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    expect(find.text('₹6,000.00'), findsOneWidget);
    expect(find.text('Rebuild manifest'), findsOneWidget);
  });

  testWidgets('without a floor from the route the screen reads the project', (tester) async {
    final backend = FakeBackend(batchRoutes(unitPay: '50.00'));
    await openBatch(tester, backend, floor: null);
    expect(backend.sent('GET', '/v1/projects/p1'), hasLength(2), reason: 'the project page under it, and the batch for its floor');
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget, reason: 'the under-floor mark');
  });

  testWidgets('when the project cannot be read the floor is unknown: Publish waits until Retry answers', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      ...batchRoutes(status: 'draft', unitPay: '50.00'),
      'GET /v1/projects/p1': (_) => fail ? envelope(503, 'unavailable', headers: {'retry-after': '2'}) : json(projectDetail()),
    });
    await openBatch(tester, backend, floor: null);
    expect(find.text('Label street signs'), findsOneWidget, reason: 'the batch itself still shows');
    expect(find.textContaining('Floor unknown, retry'), findsOneWidget);
    expect(find.textContaining('Service is away. Retry in 2s.'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('batch-publish'))).onPressed, isNull);
    fail = false;
    await tester.tap(find.byKey(const Key('floor-retry')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Floor unknown, retry'), findsNothing);
    expect(tester.widget<FilledButton>(find.byKey(const Key('batch-publish'))).onPressed, isNotNull);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget, reason: 'the under-floor mark once the floor is known');
  });

  testWidgets('a failed load offers retry', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      ...batchRoutes(),
      'GET /v1/batches/b1': (_) => fail ? envelope(500, 'boom', message: 'Market is away') : json(batchSummary()),
    });
    await openBatch(tester, backend);
    expect(find.textContaining('Details: Market is away'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Label street signs'), findsOneWidget);
  });

  testWidgets('renders on a phone without overflow', (tester) async {
    final backend = FakeBackend(batchRoutes(status: 'draft', unitPay: '50.00'));
    await openBatch(tester, backend, size: phone);
    expect(tester.takeException(), isNull);
    expect(find.text('Label street signs'), findsOneWidget);
    await tester.tap(find.byKey(const Key('batch-publish')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('publish-approved-by')), findsOneWidget);
  });

  testWidgets('a due date is picked, saved with PATCH and shown in the header', (tester) async {
    final backend = FakeBackend({
      ...batchRoutes(),
      'PATCH /v1/batches/b1': (r) => json({...batchSummary(), 'due_at': (jsonDecode(r.body) as Map)['due_at']}),
    });
    await openBatch(tester, backend);
    await tester.tap(find.byKey(const Key('batch-due')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('due-day')), '2026-13-40');
    await tester.tap(find.byKey(const Key('due-save')));
    await tester.pumpAndSettle();
    expect(find.text('Due date is not a real date'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('due-day')), '2026-11-30');
    backend.routes['GET /v1/batches/b1'] = (_) => json({...batchSummary(), 'due_at': '2026-11-30T00:00:00Z'});
    await tester.tap(find.byKey(const Key('due-save')));
    await tester.pumpAndSettle();
    final sent = backend.sent('PATCH', '/v1/batches/b1').single;
    expect(jsonDecode(sent.body), {'due_at': '2026-11-30T00:00:00.000Z'});
    expect(sent.headers['Idempotency-Key'], isNotEmpty);
    expect(find.textContaining('due 30 Nov'), findsOneWidget);
  });

  testWidgets('a CSV file becomes lines and is dry-run at once; a file without external_ref is refused', (tester) async {
    final backend = FakeBackend({
      ...batchRoutes(),
      'POST /v1/batches/b1/units/import': (r) {
        final lines = (jsonDecode(r.body) as Map)['lines'] as List;
        return json({'dry_run': true, 'total': lines.length, 'accepted': lines.length, 'errors': []});
      },
    });
    final h = await pumpOps(tester, backend);
    await goTo(tester, '/ops/projects/p1/batches/b1', extra: 0.3);
    h.files.next = (
      name: 'clips.csv',
      mime: 'text/csv',
      bytes: utf8.encode('external_ref,text\nrow-1,"Hello, world"\nrow-2,"He said ""hi"""\n'),
    );
    await reveal(tester, find.byKey(const Key('import-file')));
    await tester.tap(find.byKey(const Key('import-file')));
    await tester.pumpAndSettle();
    final lines = (jsonDecode(backend.sent('POST', '/v1/batches/b1/units/import').single.body) as Map)['lines'] as List;
    expect(lines, [
      {
        'external_ref': 'row-1',
        'payload': {'text': 'Hello, world'},
      },
      {
        'external_ref': 'row-2',
        'payload': {'text': 'He said "hi"'},
      },
    ]);
    expect(find.text('Dry run: all 2 lines accepted. Import to create the units.'), findsOneWidget);

    h.files.next = (name: 'bad.csv', mime: 'text/csv', bytes: utf8.encode('ref,text\nx,y\n'));
    await tester.tap(find.byKey(const Key('import-file')));
    await tester.pumpAndSettle();
    expect(find.text('bad.csv: the header needs an external_ref column'), findsOneWidget);
  });

  testWidgets('on a draft, media goes straight to storage and its line lands in the box', (tester) async {
    final backend = FakeBackend({
      ...batchRoutes(status: 'draft'),
      'POST /v1/batches/b1/payload-uploads': (r) {
        final f = ((jsonDecode(r.body) as Map)['files'] as List).single as Map;
        return json({
          'uploads': [
            {
              'name': f['name'],
              'key': 'projects/p1/units/u1/${f['name']}',
              'ref': 's3://yantra/projects/p1/units/u1/${f['name']}',
              'url': 'http://minio.test/put',
              'method': 'PUT',
              'headers': {'content-type': f['content_type']},
              'expires_at': '2026-11-04T10:05:00Z',
              'max_bytes': 1000,
            },
          ],
        });
      },
      'PUT /put': (_) => http.Response('', 200),
    });
    final h = await pumpOps(tester, backend);
    await goTo(tester, '/ops/projects/p1/batches/b1', extra: 0.3);
    h.files.next = (name: 'clip 01.wav', mime: 'audio/wav', bytes: [1, 2, 3]);
    await reveal(tester, find.byKey(const Key('media-upload')));
    await tester.tap(find.byKey(const Key('media-upload')));
    await tester.pumpAndSettle();
    final asked = (jsonDecode(backend.sent('POST', '/v1/batches/b1/payload-uploads').single.body) as Map)['files'] as List;
    expect(asked.single, {'name': 'clip-01.wav', 'content_type': 'audio/wav', 'size_bytes': 3});
    final put = backend.sent('PUT', '/put').single;
    expect(put.bodyBytes, [1, 2, 3]);
    expect(put.headers['content-type'], startsWith('audio/wav'));
    expect(
      tester.widget<TextField>(find.byKey(const Key('import-lines'))).controller!.text,
      '{"external_ref":"clip-01","payload":{"audio_ref":"s3://yantra/projects/p1/units/u1/clip-01.wav"}}',
    );
    expect(find.byKey(const Key('media-clip-01.wav')), findsOneWidget);
  });

  testWidgets('a delivered batch opens its JSONL and manifest; a held batch says why; Review queue opens quality for it', (tester) async {
    var held = true;
    final backend = FakeBackend({
      ...batchRoutes(
        manifest: {
          'id': 'm1',
          'digest': 'sha256:abcdef0123456789',
          'accepted_units': 50,
          'total_price': '3000.00',
          'created_at': '2026-11-01T10:00:00Z',
        },
      ),
      'GET /v1/batches/b1/deliverable': (_) => held
          ? envelope(409, 'batch_held', message: '3 units still open')
          : json({
              'manifest_id': 'm1',
              'batch_id': 'b1',
              'digest': 'sha256:abcdef',
              'jsonl': {
                'url': 'http://minio.test/units.jsonl?sig=1',
                'expires_at': '2026-11-04T10:05:00Z',
                'sha256': 'ffeeddccbbaa99887766',
                'bytes': 20480,
                'line_count': 50,
              },
              'manifest': {'url': 'http://minio.test/manifest.json?sig=1', 'expires_at': '2026-11-04T10:05:00Z'},
            }),
      'GET /v1/quality/stats': (_) => json(qualityStats()),
      'GET /v1/quality/tasks': (_) => json({'total': 0, 'items': []}),
      'GET /v1/quality/flags': (_) => json([]),
      'GET /v1/quality/disputes': (_) => json([]),
    });
    final h = await pumpOps(tester, backend);
    await goTo(tester, '/ops/projects/p1/batches/b1', extra: 0.3);
    await reveal(tester, find.byKey(const Key('deliverable-jsonl')));
    await tester.tap(find.byKey(const Key('deliverable-jsonl')));
    await tester.pumpAndSettle();
    expect(find.textContaining('The deliverable waits for the manifest.'), findsOneWidget);
    expect(find.textContaining('Details: 3 units still open'), findsOneWidget);
    held = false;
    await tester.tap(find.byKey(const Key('deliverable-jsonl')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('deliverable-manifest')));
    await tester.pumpAndSettle();
    expect(h.downloads.opened.map((u) => u.path), ['/units.jsonl', '/manifest.json']);
    expect(find.text('50 lines · 20 KB · sha256 ffeeddccbbaa'), findsOneWidget);
  });

  testWidgets('Review queue opens Quality filtered to the batch', (tester) async {
    final backend = FakeBackend({
      ...batchRoutes(),
      'GET /v1/quality/stats': (_) => json(qualityStats()),
      'GET /v1/quality/tasks': (_) => json({'total': 0, 'items': []}),
      'GET /v1/quality/flags': (_) => json([]),
      'GET /v1/quality/disputes': (_) => json([]),
    });
    await openBatch(tester, backend);
    await tester.tap(find.byKey(const Key('batch-review-queue')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/ops/quality?batch=b1');
  });

  testWidgets('renders in dark mode on a phone without overflow', (tester) async {
    final backend = FakeBackend(batchRoutes());
    await pumpApp(
      tester,
      backend,
      size: const Size(390, 2400),
      roles: const ['ops', 'finance'],
      dark: true,
      at: '/ops/projects/p1/batches/b1',
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Label street signs'), findsWidgets);
  });

  Map<String, Object?> assignedRow(String id, {String status = 'available', String? worker = 'worker-9999-1'}) => {
    ...unitRow(1, status: status),
    'id': id,
    'external_ref': 'ref-$id',
    'assigned_worker_id': worker,
  };

  testWidgets('an available unit held for one worker returns to the pool after a confirm', (tester) async {
    final backend = FakeBackend({
      ...batchRoutes(),
      'GET /v1/batches/b1/units': (_) => json({
        'total': 3,
        'items': [assignedRow('ua'), assignedRow('ub', worker: null), assignedRow('uc', status: 'claimed')],
      }),
      'POST /v1/units/ua/unassign': (_) => json({'id': 'ua', 'batch_id': 'b1', 'status': 'available', 'assigned_worker_id': null}),
    });
    await openBatch(tester, backend);
    await reveal(tester, find.byKey(const Key('unit-ua')));
    expect(find.byKey(const Key('unit-unassign-ua')), findsOneWidget);
    expect(find.byKey(const Key('unit-unassign-ub')), findsNothing, reason: 'not assigned to anyone');
    expect(find.byKey(const Key('unit-unassign-uc')), findsNothing, reason: 'someone is working on it');
    final before = backend.sent('GET', '/v1/batches/b1/units').length;
    await tester.tap(find.byKey(const Key('unit-unassign-ua')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Return to pool')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/units/ua/unassign').single.headers['Idempotency-Key'], isNotEmpty);
    expect(find.text('Unit back in the pool'), findsOneWidget);
    expect(backend.sent('GET', '/v1/batches/b1/units').length, before + 1, reason: 'the table loads again');
  });

  testWidgets('an assigned-mode batch has no pool, so no unit offers Return to pool', (tester) async {
    final backend = FakeBackend({
      ...batchRoutes(),
      'GET /v1/batches/b1': (_) => json({...batchSummary(), 'mode': 'assigned'}),
      'GET /v1/batches/b1/units': (_) => json({
        'total': 1,
        'items': [assignedRow('ua')],
      }),
    });
    await openBatch(tester, backend);
    await reveal(tester, find.byKey(const Key('unit-ua')));
    expect(find.byKey(const Key('unit-unassign-ua')), findsNothing);
  });

  testWidgets('a batch purged under retention says when, instead of a download', (tester) async {
    final backend = FakeBackend({
      ...batchRoutes(manifest: manifestJson),
      'GET /v1/batches/b1': (_) => json({...batchSummary(manifest: manifestJson), 'purged_at': '2026-11-03T10:00:00Z'}),
      'GET /v1/batches/b1/deliverable': (_) => envelope(410, 'batch_purged', context: {'batch_id': 'b1'}),
    });
    final h = await pumpOps(tester, backend);
    await goTo(tester, '/ops/projects/p1/batches/b1', extra: 0.3);
    await reveal(tester, find.byKey(const Key('deliverable-jsonl')));
    await tester.tap(find.byKey(const Key('deliverable-jsonl')));
    await tester.pumpAndSettle();
    expect(find.text("This delivery was purged under the project's retention policy on 3 Nov."), findsOneWidget);
    expect(h.downloads.opened, isEmpty);
  });
}
