import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/widgets/tables.dart';

import '../../support/fake_backend.dart';
import 'fixtures_ops.dart';

const w1 = 'worker-1111-2222';

Map<String, Handler> workerRoutes({Map<String, Object?>? account}) => {
  ...overviewRoutes(),
  'GET /v1/workers': (_) => json(workersPage()),
  'GET /v1/workers/$w1': (_) => json(workerRow()),
  'PUT /v1/workers/$w1': (r) => json({...workerRow(), ...(jsonDecode(r.body) as Map)}),
  'GET /v1/payout/accounts/$w1': (_) => json(account ?? payoutAccount()),
  'GET /v1/talent/workers/$w1/documents': (_) => json([
    {
      'kind': 'identity_front',
      'sha256': 'ab' * 32,
      'size_bytes': 204800,
      'content_type': 'image/jpeg',
      'uploaded_at': '2026-11-01T10:00:00Z',
    },
  ]),
  'GET /v1/talent/workers/$w1/documents/identity_front/url': (_) =>
      json({'url': 'http://minio.test/doc?sig=1', 'expires_at': '2026-11-04T10:05:00Z'}),
  'GET /v1/quality/reviewers/$w1': (_) => json({
    'worker_id': w1,
    'sensitive_cleared': false,
    'gates': ['transcription'],
    'updated_at': null,
  }),
  'PUT /v1/quality/reviewers/$w1': (r) => json({
    'worker_id': w1,
    'sensitive_cleared': (jsonDecode(r.body) as Map)['sensitive_cleared'],
    'gates': ['transcription'],
    'updated_at': '2026-11-04T10:00:00Z',
  }),
  'GET /v1/tracker/sessions': (_) => json([
    {
      'id': 's1',
      'worker_id': w1,
      'claim_id': 'c1',
      'project_id': null,
      'source': 'web',
      'started_at': '2026-11-03T09:00:00Z',
      'ended_at': '2026-11-03T10:30:00Z',
      'last_sample_at': '2026-11-03T10:30:00Z',
      'active_seconds': 4500,
      'idle_seconds': 900,
      'over_cap_at': null,
      'end_reason': 'client',
    },
  ]),
  'PUT /v1/payout/accounts/$w1/hold': (r) {
    final body = jsonDecode(r.body) as Map;
    return json({'worker_id': w1, 'first_paid_at': '2026-10-20T10:00:00Z', 'hold_reason': body['reason'], 'hold_until': body['until']});
  },
};

Future<void> openWorker(WidgetTester tester, FakeBackend backend, {Size size = wide}) async {
  await pumpOps(tester, backend, size: size, navKey: 'nav-workers');
  final row = find.byKey(const Key('worker-$w1'));
  await tester.tapAt(tester.getTopLeft(row) + const Offset(24, 20));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the bench lists workers with status, gates and availability; search and filters hit the API', (tester) async {
    final backend = FakeBackend(workerRoutes());
    await pumpOps(tester, backend, navKey: 'nav-workers');
    expect(find.text('OPERATE · WORKERS'), findsOneWidget);
    expect(backend.sent('GET', '/v1/workers').single.url.queryParameters, {'limit': '50', 'offset': '0'});
    expect(find.text('333-4444'), findsOneWidget, reason: 'an unnamed worker shows the short id');
    expect(chip('Eligible'), findsOneWidget);
    expect(chip('Suspended'), findsOneWidget);
    expect(find.text('transcription'), findsOneWidget);
    expect(find.text('labelling'), findsNWidgets(2));
    expect(find.text('20 h/wk'), findsOneWidget);
    expect(find.textContaining('paused until'), findsOneWidget);
    expect(find.text('2 workers'), findsOneWidget);

    expect(find.text('Asha Verma'), findsOneWidget, reason: 'a named worker shows the name');
    expect(chip('Done'), findsOneWidget);
    expect(chip('In progress'), findsOneWidget);
    expect(find.byKey(const Key('worker-held-worker-3333-4444')), findsOneWidget);
    expect(find.text('Held to 20 Nov'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('workers-search')), 'a1b2');
    await tester.pump(const Duration(milliseconds: 310));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/workers')[1].url.queryParameters, {'q': 'a1b2', 'limit': '50', 'offset': '0'});
    await tester.tap(find.byKey(const Key('filter-suspended')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/workers')[2].url.queryParameters, {'status': 'suspended', 'q': 'a1b2', 'limit': '50', 'offset': '0'});
    await expectAccessible(tester);
  });

  testWidgets('more than fifty workers page', (tester) async {
    final backend = FakeBackend({
      ...workerRoutes(),
      'GET /v1/workers': (_) => json({
        'total': 130,
        'items': [for (var i = 0; i < 50; i++) workerRow(id: 'w$i-aaaa-bbbb')],
      }),
    });
    await pumpOps(tester, backend, navKey: 'nav-workers');
    expect(find.text('130 workers'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('pager-next')));
    await tester.tap(find.byKey(const Key('pager-next')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/workers')[1].url.queryParameters['offset'], '50');
    expect(find.text('51–100 of 130'), findsOneWidget);
  });

  testWidgets('the worker screen shows the profile and edits the gates through PUT', (tester) async {
    final backend = FakeBackend(workerRoutes());
    await openWorker(tester, backend);
    expect(backend.sent('GET', '/v1/workers/$w1'), hasLength(1));
    expect(find.text('OPERATE · WORKER'), findsOneWidget);
    expect(find.text('onboarded · 2 gates · 20 h/wk'), findsOneWidget);
    expect(find.text(w1), findsOneWidget);
    expect(find.text('7'), findsOneWidget, reason: 'the partner ref');
    expect(find.byKey(const Key('remove-tag-transcription')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('gate-input')), ' OCR ');
    await tester.tap(find.byKey(const Key('gate-add')));
    await tester.pumpAndSettle();
    final put = backend.sent('PUT', '/v1/workers/$w1').single;
    expect(put.headers['Idempotency-Key'], isNotEmpty);
    expect(jsonDecode(put.body), {
      'status': 'eligible',
      'cert_gates': ['transcription', 'labelling', 'ocr'],
      'partner_ref': 7,
    });
    expect(find.text('Gates saved'), findsOneWidget);
    expect(backend.sent('GET', '/v1/workers/$w1'), hasLength(2));

    await tester.tap(find.byKey(const Key('remove-tag-labelling')));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('PUT', '/v1/workers/$w1')[1].body)['cert_gates'], ['transcription']);
  });

  testWidgets('a status change confirms, then PUTs status with the gates', (tester) async {
    final backend = FakeBackend(workerRoutes());
    await openWorker(tester, backend);
    await tester.tap(find.byKey(const Key('worker-status')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suspended').last);
    await tester.pumpAndSettle();
    expect(find.text('Set 111-2222 to suspended?'), findsOneWidget, reason: 'the detail row carries no name');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.sent('PUT', '/v1/workers/$w1'), isEmpty);

    await tester.tap(find.byKey(const Key('worker-status')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Offboarded').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set status'));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('PUT', '/v1/workers/$w1').single.body), {
      'status': 'offboarded',
      'cert_gates': ['transcription', 'labelling'],
      'partner_ref': 7,
    });
    expect(find.text('Status set to offboarded'), findsOneWidget);
  });

  testWidgets('a PUT that fails shows the message and keeps the typed gate in the field', (tester) async {
    final backend = FakeBackend({
      ...workerRoutes(),
      'PUT /v1/workers/$w1': (_) => envelope(422, 'invalid', message: 'status: not a known status'),
    });
    await openWorker(tester, backend);
    await tester.enterText(find.byKey(const Key('gate-input')), 'ocr');
    await tester.tap(find.byKey(const Key('gate-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('worker-error')), findsOneWidget);
    expect(find.textContaining('Details: status: not a known status'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const Key('gate-input'))).controller!.text,
      'ocr',
      reason: 'nothing landed; the typed gate stays',
    );
  });

  testWidgets('a key kept after a 503 is never reused for a different status or a different gate set', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      ...workerRoutes(),
      'PUT /v1/workers/$w1': (r) =>
          fail ? envelope(503, 'unavailable', headers: {'retry-after': '1'}) : json({...workerRow(), ...(jsonDecode(r.body) as Map)}),
    });
    await openWorker(tester, backend);
    Future<void> setStatus(String label) async {
      await tester.tap(find.byKey(const Key('worker-status')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set status'));
      await tester.pumpAndSettle();
    }

    await setStatus('Suspended');
    expect(find.byKey(const Key('worker-error')), findsOneWidget);
    fail = false;
    await setStatus('Offboarded');
    final puts = backend.sent('PUT', '/v1/workers/$w1');
    expect(puts, hasLength(2));
    expect(
      puts[1].headers['Idempotency-Key'],
      isNot(puts[0].headers['Idempotency-Key']),
      reason: 'suspend and offboard are different actions',
    );

    fail = true;
    await tester.enterText(find.byKey(const Key('gate-input')), 'ocr');
    await tester.tap(find.byKey(const Key('gate-add')));
    await tester.pumpAndSettle();
    fail = false;
    await tester.tap(find.byKey(const Key('remove-tag-labelling')));
    await tester.pumpAndSettle();
    final gatePuts = backend.sent('PUT', '/v1/workers/$w1').sublist(2);
    expect(gatePuts, hasLength(2));
    expect(
      gatePuts[1].headers['Idempotency-Key'],
      isNot(gatePuts[0].headers['Idempotency-Key']),
      reason: 'adding ocr and removing labelling are different actions',
    );
  });

  testWidgets('the hold card reads the payout account, places a hold and lifts it', (tester) async {
    final backend = FakeBackend(workerRoutes());
    await openWorker(tester, backend);
    expect(backend.sent('GET', '/v1/payout/accounts/$w1'), hasLength(1));
    expect(find.text('250.00'), findsOneWidget);
    expect(find.text('1,000.00'), findsOneWidget);
    expect(find.byKey(const Key('hold-open')), findsOneWidget);
    expect(find.byKey(const Key('hold-lift')), findsNothing);

    await reveal(tester, find.byKey(const Key('hold-open')));
    await tester.tap(find.byKey(const Key('hold-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hold-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('A reason is required'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('hold-reason')), 'Quality review');
    await tester.enterText(find.byKey(const Key('hold-until')), '2026-11-20');
    backend.routes['GET /v1/payout/accounts/$w1'] = (_) =>
        json(payoutAccount(holdReason: 'quality_review', holdUntil: '2026-11-20T00:00:00Z'));
    await tester.tap(find.byKey(const Key('hold-confirm')));
    await tester.pumpAndSettle();
    final put = backend.sent('PUT', '/v1/payout/accounts/$w1/hold').single;
    expect(put.headers['Idempotency-Key'], isNotEmpty);
    expect(jsonDecode(put.body), {'reason': 'quality_review', 'until': '2026-11-20T00:00:00.000Z'});
    expect(find.text('Hold placed'), findsOneWidget);
    expect(backend.sent('GET', '/v1/payout/accounts/$w1'), hasLength(2), reason: 'the card reads the account again');
    expect(find.byKey(const Key('hold-banner')), findsOneWidget);
    expect(find.text('On hold: quality review until 20 Nov'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('hold-lift')));
    await tester.tap(find.byKey(const Key('hold-lift')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lift hold').last);
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('PUT', '/v1/payout/accounts/$w1/hold')[1].body), {'reason': null, 'until': null});
    expect(find.text('Hold lifted'), findsOneWidget);
  });

  testWidgets('a hold whose date changed after a 5xx goes out under a new key', (tester) async {
    final backend = FakeBackend({...workerRoutes(), 'PUT /v1/payout/accounts/$w1/hold': (_) => envelope(503, 'upstream_unavailable')});
    await openWorker(tester, backend);
    await reveal(tester, find.byKey(const Key('hold-open')));
    await tester.tap(find.byKey(const Key('hold-open')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('hold-reason')), 'Quality review');
    await tester.enterText(find.byKey(const Key('hold-until')), '2026-11-20');
    await tester.tap(find.byKey(const Key('hold-confirm')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const Key('hold-open')));
    await tester.tap(find.byKey(const Key('hold-open')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('hold-reason')), 'Quality review');
    await tester.enterText(find.byKey(const Key('hold-until')), '2026-11-27');
    await tester.tap(find.byKey(const Key('hold-confirm')));
    await tester.pumpAndSettle();
    final keys = [for (final r in backend.sent('PUT', '/v1/payout/accounts/$w1/hold')) r.headers['Idempotency-Key']];
    expect(keys, hasLength(2));
    expect(keys[1], isNot(keys[0]));
  });

  testWidgets('a worker market has not received yet (404) opens as unknown, ready to set, not as an error', (tester) async {
    final backend = FakeBackend({...workerRoutes(), 'GET /v1/workers/$w1': (_) => envelope(404, 'not_found')});
    await openWorker(tester, backend);
    expect(find.textContaining('no longer there'), findsNothing);
    expect(find.text('Unknown'), findsWidgets);
  });

  testWidgets('no payout account yet (404) reads as a note, not an error', (tester) async {
    final backend = FakeBackend({...workerRoutes(), 'GET /v1/payout/accounts/$w1': (_) => envelope(404, 'not_found')});
    await openWorker(tester, backend);
    expect(find.byKey(const Key('hold-none')), findsOneWidget);
    expect(find.byKey(const Key('hold-open')), findsNothing);
  });

  testWidgets('a failed bench load offers retry; an empty bench says so', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      ...workerRoutes(),
      'GET /v1/workers': (_) => fail ? envelope(500, 'boom', message: 'Market is away') : json({'total': 0, 'items': []}),
    });
    await pumpOps(tester, backend, navKey: 'nav-workers');
    expect(find.textContaining('Details: Market is away'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No workers yet. They appear here once onboarding marks them eligible.'), findsOneWidget);
  });

  testWidgets('renders on a phone: the table scrolls sideways and the worker screen stacks', (tester) async {
    final backend = FakeBackend(workerRoutes());
    await openWorker(tester, backend, size: phone);
    expect(tester.takeException(), isNull);
    expect(find.text('OPERATE · WORKER'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('hold-open')));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('back')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(PortalTable), matching: find.byType(SingleChildScrollView)), findsOneWidget);
  });

  testWidgets('typing fast sends one request after a pause; a name is not an id and says so; the gate filters', (tester) async {
    final backend = FakeBackend(workerRoutes());
    await pumpOps(tester, backend, navKey: 'nav-workers');
    final search = find.byKey(const Key('workers-search'));
    for (final text in ['a', 'ab', 'abc']) {
      await tester.enterText(search, text);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(backend.sent('GET', '/v1/workers'), hasLength(1), reason: 'nothing while typing');
    await tester.pump(const Duration(milliseconds: 310));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/workers'), hasLength(2));
    expect(backend.sent('GET', '/v1/workers').last.url.queryParameters['q'], 'abc');

    await tester.enterText(search, 'asha');
    await tester.pump(const Duration(milliseconds: 310));
    await tester.pumpAndSettle();
    expect(find.text('Search by the start of a worker id (0-9, a-f)'), findsOneWidget);
    expect(backend.sent('GET', '/v1/workers').last.url.queryParameters.containsKey('q'), isFalse);

    await tester.enterText(find.byKey(const Key('workers-gate')), 'transcription');
    await tester.pump(const Duration(milliseconds: 310));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/workers').last.url.queryParameters['gate'], 'transcription');
  });

  testWidgets('the worker screen shows documents, reviewer clearance, the bank account and tracked sessions', (tester) async {
    final backend = FakeBackend({...workerRoutes(account: payoutAccount(bank: bankStatus(nameMatch: false)))});
    final h = await pumpOps(tester, backend, navKey: 'nav-workers');
    await tester.tapAt(tester.getTopLeft(find.byKey(const Key('worker-$w1'))) + const Offset(24, 20));
    await tester.pumpAndSettle();
    expect(find.text('Identity front · 200 KB · 1 Nov'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('doc-view-identity_front')));
    await tester.tap(find.byKey(const Key('doc-view-identity_front')));
    await tester.pumpAndSettle();
    expect(h.downloads.opened.single.toString(), 'http://minio.test/doc?sig=1');

    expect(find.text('Review gates: transcription'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('reviewer-sensitive')));
    await tester.tap(find.byKey(const Key('reviewer-sensitive')));
    await tester.pumpAndSettle();
    final put = backend.sent('PUT', '/v1/quality/reviewers/$w1').single;
    expect(jsonDecode(put.body), {'sensitive_cleared': true});
    expect(put.headers['Idempotency-Key'], isNotEmpty);
    expect(find.text('Cleared for sensitive projects').last, findsOneWidget);

    expect(find.textContaining('Verified · Asha Verma · ••••4321 · HDFC0001234 · the bank holds a different name'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('session-s1')));
    expect(find.text('1.3 h'), findsOneWidget);
    expect(find.text('15 min'), findsOneWidget);
    expect(backend.sent('GET', '/v1/tracker/sessions').single.url.queryParameters['worker_id'], w1);
  });

  testWidgets('a worker with no bank account is told plainly; the worker screen renders dark and stays accessible', (tester) async {
    final backend = FakeBackend(workerRoutes());
    await pumpApp(tester, backend, size: wide, roles: const ['ops', 'finance'], dark: true, at: '/ops/workers/$w1');
    expect(find.byKey(const Key('bank-none')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a bank account waiting for confirmation says why; finance confirms it after a check', (tester) async {
    var awaiting = true;
    final backend = FakeBackend({
      ...workerRoutes(),
      'GET /v1/payout/accounts/$w1': (_) => json(
        payoutAccount(
          bank: {
            ...bankStatus(nameMatch: null),
            'awaiting_confirmation': awaiting,
            'confirmed_at': awaiting ? null : '2026-11-05T09:00:00Z',
          },
        ),
      ),
      'POST /v1/payout/accounts/$w1/confirm': (_) {
        awaiting = false;
        return json({...bankStatus(nameMatch: null), 'awaiting_confirmation': false});
      },
    });
    await openWorker(tester, backend);
    await reveal(tester, find.byKey(const Key('bank-awaiting')));
    expect(find.textContaining('the bank returned no name'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bank-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Confirm account')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/payout/accounts/$w1/confirm').single.headers['Idempotency-Key'], isNotEmpty);
    expect(find.text('Bank account confirmed'), findsOneWidget);
    expect(find.byKey(const Key('bank-awaiting')), findsNothing);
    expect(find.textContaining('confirmed by finance'), findsOneWidget);
  });

  testWidgets('confirming is refused plainly for one\'s own account; ops without finance only read it', (tester) async {
    final backend = FakeBackend({
      ...workerRoutes(account: payoutAccount(bank: {...bankStatus(nameMatch: null), 'awaiting_confirmation': true})),
      'POST /v1/payout/accounts/$w1/confirm': (_) => envelope(409, 'same_person'),
    });
    await openWorker(tester, backend);
    await reveal(tester, find.byKey(const Key('bank-confirm')));
    await tester.tap(find.byKey(const Key('bank-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Confirm account')));
    await tester.pumpAndSettle();
    expect(find.text('You cannot do this for yourself or approve your own proposal. Ask a colleague.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester, backend, size: wide, roles: const ['ops'], at: '/ops/workers/$w1');
    await reveal(tester, find.byKey(const Key('bank-awaiting')));
    expect(find.byKey(const Key('bank-confirm')), findsNothing);
  });
}
