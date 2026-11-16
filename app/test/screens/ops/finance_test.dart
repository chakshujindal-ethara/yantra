import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/core/widgets/cards.dart';

import '../../support/fake_backend.dart';
import '../fixtures_console.dart';

Map<String, Handler> routes() => {
  'GET /v1/payout/overview': (_) => json(payoutOverview()),
  'GET /v1/payout/windows': (_) =>
      json([window('w1', approvals: 1), window('w2', status: 'approved', approvals: 2), window('w3', status: 'paid')]),
  'GET /v1/payout/windows/w1': (_) => json(window('w1', approvals: 1)),
  'GET /v1/payout/windows/w2': (_) => json(window('w2', status: 'approved', approvals: 2)),
  'GET /v1/payout/windows/w3': (_) => json(window('w3', status: 'paid')),
  'GET /v1/payout/windows/w1/lines': (_) =>
      json([line('l1', 'worker-5555-1', '2100.00'), line('l2', 'worker-6666-2', '300.00', status: 'held', hold: 'first_payout')]),
  'GET /v1/payout/windows/w2/lines': (_) => json([line('l3', 'worker-5555-1', '4200.00')]),
  'GET /v1/payout/windows/w3/lines': (_) => json([line('l4', 'worker-5555-1', '4200.00', status: 'paid')]),
  'GET /v1/payout/adjustments': (_) => json([adjustment('a1'), adjustment('a2', status: 'approved', kind: 'correction', amount: '-40.00')]),
  'GET /v1/payout/margin': (_) => json([marginRow('batch-aaaa-1111')]),
  'GET /v1/payout/attention': (_) => json(<String, Object?>{}),
};

Future<void> openFinance(WidgetTester tester, FakeBackend backend, {bool wide = true, Size? size}) =>
    openOps(tester, backend, navKey: 'nav-finance', label: 'Finance', wide: wide, size: size);

Future<void> tab(WidgetTester tester, String label) async {
  final segment = find.descendant(of: find.byKey(const Key('finance-tab')), matching: find.text(label));
  await tester.ensureVisible(segment);
  await tester.tap(segment);
  await tester.pumpAndSettle();
}

Finder chip(String label) => find.widgetWithText(StatusChip, label);
Finder tile(String label) => find.ancestor(of: find.text(label), matching: find.byType(KpiTile));

/// Taps the row at its left edge: on a phone the table scrolls sideways and the row's centre is off-screen.
Future<void> openWindow(WidgetTester tester, String id) async {
  final row = find.byKey(Key('window-$id'));
  await tester.ensureVisible(row);
  await tester.tapAt(tester.getTopLeft(row) + const Offset(24, 20));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the overview tiles read GET /v1/payout/overview', (tester) async {
    final backend = FakeBackend(routes());
    await openFinance(tester, backend);
    expect(find.text('MONEY · FINANCE'), findsOneWidget);
    expect(find.descendant(of: tile('Payable now'), matching: find.text('₹1,250.00')), findsOneWidget);
    expect(find.descendant(of: tile('Paid total'), matching: find.text('₹98,000.00')), findsOneWidget);
    expect(find.text('4 windows paid'), findsOneWidget);
    expect(find.descendant(of: tile('Held'), matching: find.text('₹300.00')), findsOneWidget);
    expect(find.descendant(of: tile('Open window closes'), matching: find.text('in 2 days')), findsOneWidget);
    expect(find.descendant(of: tile('Pending adjustments'), matching: find.text('2')), findsOneWidget);
    expect(find.descendant(of: tile('Awaiting approval'), matching: find.text('1')), findsOneWidget);
    expect(find.descendant(of: tile('Margin to date'), matching: find.text('₹21,000.00')), findsOneWidget);
    await expectAccessible(tester);
  });

  testWidgets('pay windows list the period, lines, gross, held, status and approvals; closing posts the currency', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'POST /v1/payout/windows/close': (r) => json({...window('w4'), 'currency': jsonDecode(r.body)['currency']}, status: 201),
    });
    await openFinance(tester, backend);
    await tab(tester, 'Pay windows');
    expect(find.text('25 – 31 Oct IST'), findsNWidgets(3), reason: 'pay weeks are IST, and say so');
    expect(find.text('₹4,200.00'), findsNWidgets(3));
    expect(find.text('₹300.00'), findsNWidgets(3));
    expect(chip('Closed'), findsOneWidget);
    expect(chip('Approved'), findsOneWidget);
    expect(chip('Paid'), findsOneWidget);
    expect(find.text('1 of 2'), findsOneWidget);
    expect(find.text('2 of 2'), findsOneWidget);
    expect(find.text('—'), findsOneWidget, reason: 'a window without an approvals count shows a dash');

    final loads = backend.sent('GET', '/v1/payout/windows').length;
    await tester.tap(find.byKey(const Key('close-window')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('close-currency')), matching: find.text('INR')), findsOneWidget);
    await tester.tap(find.byKey(const Key('close-currency')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('USD').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('close-window-send')));
    await tester.pumpAndSettle();
    final sent = backend.sent('POST', '/v1/payout/windows/close').single;
    expect(jsonDecode(sent.body), {'currency': 'USD'});
    expect(sent.headers['Idempotency-Key'], isNotNull);
    expect(find.textContaining('Window closed'), findsOneWidget);
    expect(backend.sent('GET', '/v1/payout/windows').length, loads + 1);
  });

  testWidgets('a closed window shows its lines and the second-approval banner; approving posts and explains', (tester) async {
    var approvals = 1;
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/windows/w1': (_) => json(window('w1', status: approvals >= 2 ? 'approved' : 'closed', approvals: approvals)),
      'POST /v1/payout/windows/w1/approve': (_) {
        approvals++;
        return json(window('w1', status: approvals >= 2 ? 'approved' : 'closed', approvals: approvals));
      },
    });
    await openFinance(tester, backend);
    await tab(tester, 'Pay windows');
    await openWindow(tester, 'w1');
    expect(find.text('Pay window'), findsOneWidget);
    expect(find.byKey(const Key('window-second-approval')), findsOneWidget);
    expect(find.byKey(const Key('line-l1')), findsOneWidget);
    expect(find.text('₹2,100.00'), findsOneWidget);
    expect(find.text('First payout, 7-day hold'), findsOneWidget);
    expect(chip('Held'), findsOneWidget);
    expect(find.byKey(const Key('window-pay')), findsNothing, reason: 'not approved yet');

    await tester.tap(find.byKey(const Key('window-approve')));
    await tester.pumpAndSettle();
    final sent = backend.sent('POST', '/v1/payout/windows/w1/approve').single;
    expect(sent.headers['Idempotency-Key'], isNotNull);
    expect(find.text('Approval recorded'), findsOneWidget);
    expect(tester.widget<StatusChip>(find.byKey(const Key('window-status'))).label, 'Approved');
    expect(find.byKey(const Key('window-approve')), findsNothing);
    expect(find.byKey(const Key('window-pay')), findsOneWidget);
    expect(find.byKey(const Key('window-bank-file')), findsNothing, reason: 'only a window on the file rail has a bank file');
  });

  testWidgets('a first approval that leaves the window closed asks for a second person; a repeat is refused plainly', (tester) async {
    var calls = 0;
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/windows': (_) => json([window('w1', approvals: 0)]),
      'GET /v1/payout/windows/w1': (_) => json(window('w1', approvals: calls >= 1 ? 1 : 0)),
      'POST /v1/payout/windows/w1/approve': (_) => ++calls == 1
          ? json(window('w1', approvals: 1))
          : envelope(409, 'already_approved', message: 'this approver has already approved'),
    });
    await openFinance(tester, backend);
    await tab(tester, 'Pay windows');
    await openWindow(tester, 'w1');
    expect(find.byKey(const Key('window-second-approval')), findsNothing);
    await tester.tap(find.byKey(const Key('window-approve')));
    await tester.pumpAndSettle();
    expect(find.text('Your approval is recorded. A second person must approve before the window can be paid.'), findsOneWidget);
    expect(find.byKey(const Key('window-approve')), findsOneWidget, reason: 'still closed');
    await tester.tap(find.byKey(const Key('window-approve')));
    await tester.pumpAndSettle();
    expect(find.text('You already approved this window. A second person must approve it before it can be paid.'), findsOneWidget);
  });

  testWidgets('paying an approved window asks first, queues the lines and follows them on the rail', (tester) async {
    var status = 'approved';
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/windows/w2': (_) => json(window('w2', status: status, approvals: 2)),
      'POST /v1/payout/windows/w2/pay': (_) {
        status = 'paying';
        return json(window('w2', status: 'paying', approvals: 2));
      },
      'GET /v1/payout/windows/w2/lines': (_) => json([
        line(
          'l3',
          'worker-5555-1',
          '4200.00',
          status: status == 'paid' ? 'paid' : (status == 'paying' ? 'processing' : 'payable'),
          attempts: status == 'approved' ? 0 : 1,
          utr: status == 'paid' ? 'UTR7788' : null,
        ),
      ]),
    });
    await openFinance(tester, backend);
    await tab(tester, 'Pay windows');
    await openWindow(tester, 'w2');
    await tester.tap(find.byKey(const Key('window-pay')));
    await tester.pumpAndSettle();
    expect(find.text('Pay this window?'), findsOneWidget);
    await tester.tap(find.text('Pay window').last);
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/payout/windows/w2/pay').single.headers['Idempotency-Key'], isNotNull);
    expect(tester.widget<StatusChip>(find.byKey(const Key('window-status'))).label, 'Paying');
    expect(chip('Processing'), findsOneWidget);
    expect(find.text('Sent to the rail'), findsOneWidget);

    status = 'paid';
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(tester.widget<StatusChip>(find.byKey(const Key('window-status'))).label, 'Paid');
    expect(find.text('UTR7788'), findsOneWidget, reason: 'the poll re-read the lines while the window was paying');
    expect(find.textContaining('not reconciled yet, statements are held'), findsOneWidget);
  });

  testWidgets('a failed line can be retried or released; releasing asks first', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/windows': (_) => json([window('w5', status: 'paying', approvals: 2)]),
      'GET /v1/payout/windows/w5': (_) => json(window('w5', status: 'paying', approvals: 2)),
      'GET /v1/payout/windows/w5/lines': (_) => json([
        line('l7', 'worker-5555-1', '40.13', status: 'failed', attempts: 1, reason: 'insufficient_funds'),
        line('l8', 'worker-6666-2', '118.00', status: 'paid', attempts: 1, utr: 'UTR1'),
      ]),
      'POST /v1/payout/windows/w5/lines/l7/retry': (_) => json(line('l7', 'worker-5555-1', '40.13', status: 'queued', attempts: 2)),
      'POST /v1/payout/windows/w5/lines/l7/release': (_) => json(line('l7', 'worker-5555-1', '40.13', status: 'released', attempts: 2)),
    });
    await openFinance(tester, backend);
    await tab(tester, 'Pay windows');
    await openWindow(tester, 'w5');
    expect(find.text('Insufficient funds'), findsOneWidget);
    expect(find.text('UTR1'), findsOneWidget);
    expect(find.byKey(const Key('line-retry-l8')), findsNothing, reason: 'a paid line has nothing to do');
    await tester.tap(find.byKey(const Key('line-retry-l7')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/payout/windows/w5/lines/l7/retry'), hasLength(1));
    expect(find.text('Line sent again'), findsOneWidget);
    await tester.tap(find.byKey(const Key('line-release-l7')));
    await tester.pumpAndSettle();
    expect(find.text('Release this line?'), findsOneWidget);
    await tester.tap(find.text('Release line'));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/payout/windows/w5/lines/l7/release'), hasLength(1));
    expect(find.text('Line released'), findsOneWidget);
  });

  testWidgets('on the file rail finance downloads the bank file and uploads the return file', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/windows': (_) => json([window('w6', status: 'paying', approvals: 2, rail: 'file')]),
      'GET /v1/payout/windows/w6': (_) => json(window('w6', status: 'paying', approvals: 2, rail: 'file')),
      'GET /v1/payout/windows/w6/lines': (_) => json([line('l9', 'worker-5555-1', '4200.00', status: 'processing', attempts: 1)]),
      'GET /v1/payout/windows/w6/bank-file': (r) => http.Response('reference,beneficiary_name\nFILE-1,Asha\n', 200),
      'POST /v1/payout/windows/w6/bank-file/reconcile': (r) => json({
        'applied': ['l9'],
        'skipped': [
          {'row': 3, 'reference': 'FILE-X', 'reason': 'unknown_reference'},
        ],
      }),
    });
    final h = await pumpApp(tester, backend, size: const Size(1280, 2400), roles: ['ops', 'finance'], at: '/ops/finance');
    await tab(tester, 'Pay windows');
    await openWindow(tester, 'w6');
    await tester.tap(find.byKey(const Key('window-bank-file')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/payout/windows/w6/bank-file').single.headers['Accept'], 'text/csv');
    expect(h.downloads.saved.single.name, startsWith('bank-file-'));
    expect(utf8.decode(h.downloads.saved.single.bytes), contains('FILE-1,Asha'));

    h.files.next = (name: 'returns.csv', mime: 'text/csv', bytes: utf8.encode('reference,status,utr,reason\nFILE-1,paid,UTR5,\n'));
    await tester.tap(find.byKey(const Key('window-return-file')));
    await tester.pumpAndSettle();
    final sent = backend.sent('POST', '/v1/payout/windows/w6/bank-file/reconcile').single;
    expect(sent.headers['Content-Type'], startsWith('text/csv'));
    expect(sent.body, contains('FILE-1,paid,UTR5'));
    expect(find.textContaining('Return file: 1 lines settled, 1 skipped (row 3: Unknown reference)'), findsOneWidget);
  });

  testWidgets('reconcile checks live, records a run, lists runs and then releases the statement export', (tester) async {
    var balanced = true;
    var reconciled = false;
    Map<String, Object?> report() => {
      'window_id': 'w3',
      'status': 'paid',
      'earnings_total': '4200.00',
      'lines_total': balanced ? '4200.00' : '4100.00',
      'paid_total': '4200.00',
      'rail_total': '4200.00',
      'delta': balanced ? '0.00' : '100.00',
      'delta_rail': '0.00',
      'failed_lines': 0,
      'processing_lines': 0,
      'unpaid_earnings': balanced ? 0 : 1,
      'balanced': balanced,
    };
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/windows/w3': (_) => json(window('w3', status: 'paid', reconciledAt: reconciled ? '2026-11-03T02:00:00Z' : null)),
      'GET /v1/payout/windows/w3/reconcile': (_) => json(report()),
      'POST /v1/payout/windows/w3/reconcile': (_) {
        reconciled = true;
        return json(report());
      },
      'GET /v1/payout/reconciliation-runs': (_) => json([
        if (reconciled)
          {
            'id': 'run1',
            'window_id': 'w3',
            'ran_at': '2026-11-03T02:00:00Z',
            'earnings_total': '4200.00',
            'lines_total': '4200.00',
            'paid_total': '4200.00',
            'rail_total': '4200.00',
            'delta_lines': '0.00',
            'delta_rail': '0.00',
            'failed_lines': 0,
            'processing_lines': 0,
            'balanced': true,
          },
      ]),
      'GET /v1/payout/statements/w3/export': (_) => http.Response('line_id,worker_id,gross\nl4,worker-5555-1,4200.00\n', 200),
    });
    final h = await pumpApp(tester, backend, size: const Size(1280, 2400), roles: ['ops', 'finance'], at: '/ops/finance');
    await tab(tester, 'Pay windows');
    await openWindow(tester, 'w3');
    expect(find.textContaining('No recorded run yet'), findsOneWidget);
    expect(find.byKey(const Key('window-export')), findsNothing, reason: 'statements wait for a balanced run');
    balanced = false;
    await tester.tap(find.byKey(const Key('window-reconcile')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Not balanced: earnings ₹4,200.00 against lines ₹4,100.00; 1 earnings still unpaid'), findsOneWidget);
    expect(tester.widget<StatusBanner>(find.byKey(const Key('reconcile-result'))).kind, StatusKind.dest);
    expect(backend.sent('POST', '/v1/payout/windows/w3/reconcile'), isEmpty, reason: 'a check records nothing');

    balanced = true;
    await tester.tap(find.byKey(const Key('window-record')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Balanced: earnings ₹4,200.00 equal the lines'), findsOneWidget);
    expect(find.byKey(const Key('run-run1')), findsOneWidget);
    expect(find.textContaining('statements released'), findsOneWidget);
    await tester.tap(find.byKey(const Key('window-export')));
    await tester.pumpAndSettle();
    expect(h.downloads.saved.single.name, 'statement-w3.csv');
    expect(backend.sent('GET', '/v1/payout/statements/w3/export').single.url.queryParameters['format'], 'csv');
  });

  testWidgets('an operator without the finance role reads windows but cannot move money', (tester) async {
    final backend = FakeBackend({...routes(), 'GET /v1/payout/windows/w5/lines': (_) => json([])});
    await pumpApp(tester, backend, size: const Size(1280, 2400), roles: ['ops'], at: '/ops/finance');
    await tab(tester, 'Pay windows');
    expect(find.byKey(const Key('close-window')), findsNothing);
    await openWindow(tester, 'w1');
    expect(find.byKey(const Key('window-read-only')), findsOneWidget);
    expect(find.byKey(const Key('window-approve')), findsNothing);
    expect(find.byKey(const Key('window-reconcile')), findsOneWidget, reason: 'a live check is a read');
  });

  testWidgets('the overview shows the rail and what is stuck on it; holds list and lift', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/rail': (_) => json({
        'rail': 'razorpayx',
        'supports_penny_drop': true,
        'lines': {'queued': 0, 'processing': 2, 'failed': 1, 'returned': 0},
        'accounts_verifying': 1,
        'last_dispatch_at': '2026-11-04T10:00:00Z',
        'last_poll_at': null,
      }),
      'GET /v1/payout/accounts': (_) => json({
        'total': 1,
        'items': [
          {'worker_id': 'worker-7777-3', 'hold_reason': 'account_unverified', 'hold_until': null, 'first_paid_at': null},
        ],
      }),
      'PUT /v1/payout/accounts/worker-7777-3/hold': (r) => json({'worker_id': 'worker-7777-3', 'hold_reason': null, 'hold_until': null}),
    });
    await openFinance(tester, backend);
    expect(find.text('Rail: RazorpayX'), findsOneWidget);
    expect(find.text('1 need finance'), findsOneWidget);
    expect(find.text('Processing 2'), findsOneWidget);
    expect(find.textContaining('penny drop'), findsOneWidget);
    await tab(tester, 'Holds');
    expect(backend.sent('GET', '/v1/payout/accounts').single.url.queryParameters['held'], 'true');
    expect(find.text('No verified bank account'), findsOneWidget);
    expect(find.text('Until lifted'), findsOneWidget);
    await tester.tap(find.byKey(const Key('hold-lift-worker-7777-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lift hold'));
    await tester.pumpAndSettle();
    final sent = backend.sent('PUT', '/v1/payout/accounts/worker-7777-3/hold').single;
    expect(jsonDecode(sent.body), {'reason': null, 'until': null});
    expect(find.text('Hold lifted'), findsOneWidget);
    await expectAccessible(tester);
  });

  testWidgets('adjustments list with status chips; propose validates and POSTs the body', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'POST /v1/payout/adjustments': (r) => json({...adjustment('a3'), ...jsonDecode(r.body) as Map<String, Object?>}, status: 201),
    });
    await openFinance(tester, backend);
    await tab(tester, 'Adjustments');
    expect(find.byKey(const Key('adjust-a1')), findsOneWidget);
    expect(find.text('₹150.00'), findsOneWidget);
    expect(find.text('-₹40.00'), findsOneWidget);
    expect(chip('Pending'), findsOneWidget);
    expect(chip('Approved'), findsOneWidget);
    expect(find.byKey(const Key('adjust-approve-a1')), findsOneWidget);
    expect(find.byKey(const Key('adjust-approve-a2')), findsNothing, reason: 'decided rows have no buttons');
    expect(find.text('222-bbbb'), findsOneWidget, reason: 'the decider, short until the people cache names them');

    await tester.tap(find.byKey(const Key('filter-approved')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/payout/adjustments').last.url.queryParameters['status'], 'approved');

    await tester.tap(find.byKey(const Key('adjust-propose')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('adjust-send')));
    await tester.pumpAndSettle();
    expect(find.text('Worker id is required'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('adjust-worker')), 'worker-5555-1');
    await tester.enterText(find.byKey(const Key('adjust-amount')), '-20');
    await tester.enterText(find.byKey(const Key('adjust-reason')), 'Overpaid last week');
    await tester.tap(find.byKey(const Key('adjust-send')));
    await tester.pumpAndSettle();
    expect(find.text('A bonus is positive; use a correction to take money back'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byKey(const Key('adjust-kind')), matching: find.text('Correction')));
    await tester.tap(find.byKey(const Key('adjust-send')));
    await tester.pumpAndSettle();
    final sent = backend.sent('POST', '/v1/payout/adjustments').single;
    expect(jsonDecode(sent.body), {
      'worker_id': 'worker-5555-1',
      'amount': '-20',
      'currency': 'INR',
      'kind': 'correction',
      'reason': 'Overpaid last week',
    });
    expect(sent.headers['Idempotency-Key'], isNotNull);
    expect(find.text('Adjustment proposed'), findsOneWidget);
  });

  testWidgets('approving an adjustment posts the note; the same person is refused with the 409 message', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'POST /v1/payout/adjustments/a1/approve': (_) =>
          envelope(409, 'same_person', message: 'the proposer cannot approve their own adjustment'),
      'POST /v1/payout/adjustments/a1/reject': (r) => json({...adjustment('a1', status: 'rejected'), 'note': jsonDecode(r.body)['note']}),
    });
    await openFinance(tester, backend);
    await tab(tester, 'Adjustments');
    await tester.tap(find.byKey(const Key('adjust-approve-a1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('adjust-note')), 'Looks right');
    await tester.tap(find.byKey(const Key('adjust-note-send')));
    await tester.pumpAndSettle();
    expect(find.text('The person who proposed an adjustment cannot approve it. Ask a colleague.'), findsOneWidget);
    expect(jsonDecode(backend.sent('POST', '/v1/payout/adjustments/a1/approve').single.body), {'note': 'Looks right'});
    await tester.tap(find.byKey(const Key('action-cancel')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('adjust-reject-a1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('adjust-note-send')));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('POST', '/v1/payout/adjustments/a1/reject').single.body), {'note': ''}, reason: 'the note is optional');
    expect(find.text('Adjustment rejected'), findsOneWidget);
  });

  testWidgets('the margin table lists invoice, costs, margin and margin percent per batch', (tester) async {
    final backend = FakeBackend(routes());
    await openFinance(tester, backend);
    await tab(tester, 'Margin');
    expect(find.byKey(const Key('margin-batch-aaaa-1111')), findsOneWidget);
    expect(find.text('₹5,000.00'), findsOneWidget);
    expect(find.text('₹2,500.00'), findsOneWidget);
    expect(find.text('₹400.00'), findsOneWidget);
    expect(find.text('₹100.00'), findsOneWidget);
    expect(find.text('₹2,000.00'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('120'), findsOneWidget);
  });

  testWidgets('empty lists say what comes next; a failed overview offers Retry', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/overview': (_) =>
          fail ? envelope(503, 'upstream_unavailable', headers: {'retry-after': '2'}) : json(payoutOverview()),
      'GET /v1/payout/windows': (_) => json([]),
      'GET /v1/payout/adjustments': (_) => json([]),
      'GET /v1/payout/margin': (_) => json([]),
    });
    await openFinance(tester, backend);
    expect(find.text('Service is away. Retry in 2s.'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Payable now'), findsOneWidget);
    await tab(tester, 'Pay windows');
    expect(find.textContaining('No pay window yet'), findsOneWidget);
    await tab(tester, 'Adjustments');
    expect(find.textContaining('No adjustments yet'), findsOneWidget);
    await tab(tester, 'Margin');
    expect(find.textContaining('No margin yet'), findsOneWidget);
  });

  testWidgets('renders at phone width without overflow, including the window route', (tester) async {
    final backend = FakeBackend(routes());
    await openFinance(tester, backend, wide: false, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    await tab(tester, 'Pay windows');
    expect(tester.takeException(), isNull);
    await openWindow(tester, 'w1');
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.byKey(const Key('line-l1')), 200, scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const Key('line-l1')), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tab(tester, 'Adjustments');
    await tab(tester, 'Margin');
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders at desktop width without overflow', (tester) async {
    final backend = FakeBackend(routes());
    await openFinance(tester, backend, size: const Size(1280, 900));
    expect(tester.takeException(), isNull);
    await tab(tester, 'Pay windows');
    await tab(tester, 'Adjustments');
    await tab(tester, 'Margin');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a link to a window reads it by id; a failed read offers Retry', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/windows/w1': (_) => fail ? envelope(503, 'upstream_unavailable') : json(window('w1', approvals: 1)),
    });
    await pumpApp(tester, backend, size: const Size(1280, 900), roles: ['ops', 'finance'], at: '/ops/finance/windows/w1');
    expect(find.byKey(const Key('crumb-current')), findsOneWidget);
    final retry = find.text('Retry');
    expect(retry, findsOneWidget);
    fail = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('window-status')), findsOneWidget);
    expect(backend.sent('GET', '/v1/payout/windows/w1'), hasLength(2));
  });

  testWidgets('renders in dark mode on a phone without overflow', (tester) async {
    final backend = FakeBackend(routes());
    await pumpApp(tester, backend, size: const Size(390, 2400), roles: const ['ops', 'finance'], dark: true, at: '/ops/finance');
    expect(tester.takeException(), isNull);
    expect(find.text('Payable now'), findsWidgets);
  });

  testWidgets('a window opened from the list is read again, so a row that went stale is not acted on', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      // the list still says closed; meanwhile a second person approved it
      'GET /v1/payout/windows/w1': (_) => json(window('w1', status: 'approved', approvals: 2)),
    });
    await openFinance(tester, backend);
    await tab(tester, 'Pay windows');
    await openWindow(tester, 'w1');
    expect(backend.sent('GET', '/v1/payout/windows/w1'), hasLength(1));
    expect(tester.widget<StatusChip>(find.byKey(const Key('window-status'))).label, 'Approved');
    expect(find.byKey(const Key('window-approve')), findsNothing);
    expect(find.byKey(const Key('window-pay')), findsOneWidget);
  });

  testWidgets('a refresh that fails while paying says so quietly and offers Retry; the page stays', (tester) async {
    var fail = false;
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/windows': (_) => json([window('w5', status: 'paying', approvals: 2)]),
      'GET /v1/payout/windows/w5': (_) => fail ? envelope(503, 'upstream_unavailable') : json(window('w5', status: 'paying', approvals: 2)),
      'GET /v1/payout/windows/w5/lines': (_) => json([line('l8', 'worker-6666-2', '118.00', status: 'processing', attempts: 1)]),
    });
    await openFinance(tester, backend);
    await tab(tester, 'Pay windows');
    await openWindow(tester, 'w5');
    expect(find.byKey(const Key('window-refresh-failed')), findsNothing);
    fail = true;
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('window-refresh-failed')), findsOneWidget);
    expect(find.text("Couldn't refresh"), findsOneWidget);
    expect(find.byKey(const Key('line-l8')), findsOneWidget, reason: 'the lines stay on screen');
    expect(tester.takeException(), isNull);
    fail = false;
    await tester.tap(find.byKey(const Key('window-refresh-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('window-refresh-failed')), findsNothing);
  });

  testWidgets('a window without dates is titled by what dates it has, never its id', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/windows': (_) => json([
        {...window('w7abcdef99'), 'starts_at': null, 'ends_at': null},
        {...window('w8abcdef99'), 'ends_at': null},
      ]),
      'GET /v1/payout/windows/w7abcdef99': (_) => json({...window('w7abcdef99'), 'starts_at': null, 'ends_at': null}),
      'GET /v1/payout/windows/w7abcdef99/lines': (_) => json([]),
    });
    await openFinance(tester, backend);
    await tab(tester, 'Pay windows');
    expect(find.textContaining('w7abcdef'), findsNothing);
    expect(find.text('Pay window'), findsWidgets);
    expect(find.text('From 25 Oct IST'), findsOneWidget);
    await openWindow(tester, 'w7abcdef99');
    expect(find.textContaining('w7abcdef'), findsNothing);
  });

  testWidgets('line buttons tell a screen reader whose line they act on', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/windows': (_) => json([window('w5', status: 'paying', approvals: 2)]),
      'GET /v1/payout/windows/w5': (_) => json(window('w5', status: 'paying', approvals: 2)),
      'GET /v1/payout/windows/w5/lines': (_) =>
          json([line('l7', 'worker-5555-1', '40.13', status: 'failed', attempts: 1, reason: 'insufficient_funds')]),
      'GET /v1/people': (_) => json({
        'worker-5555-1': {'name': 'Asha Rao', 'kind': 'worker'},
      }),
    });
    await openFinance(tester, backend);
    await tab(tester, 'Pay windows');
    await openWindow(tester, 'w5');
    final handle = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp(r'^Retry the payout to (Asha Rao|r-5555-1)$')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Release the line of (Asha Rao|r-5555-1)$')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a proposal edited after a 5xx goes out under a new key', (tester) async {
    final backend = FakeBackend({...routes(), 'POST /v1/payout/adjustments': (_) => envelope(503, 'upstream_unavailable')});
    await openFinance(tester, backend);
    await tab(tester, 'Adjustments');
    await tester.tap(find.byKey(const Key('adjust-propose')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('adjust-worker')), 'worker-5555-1');
    await tester.enterText(find.byKey(const Key('adjust-amount')), '20');
    await tester.enterText(find.byKey(const Key('adjust-reason')), 'Bonus for the week');
    await tester.tap(find.byKey(const Key('adjust-send')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('adjust-reason')), 'Bonus for the hard week');
    await tester.tap(find.byKey(const Key('adjust-send')));
    await tester.pumpAndSettle();
    final keys = [for (final r in backend.sent('POST', '/v1/payout/adjustments')) r.headers['Idempotency-Key']];
    expect(keys, hasLength(2));
    expect(keys[1], isNot(keys[0]));
  });

  testWidgets('a window over the per-window cap is paid only with a reason, which the window then shows', (tester) async {
    var override = false;
    Map<String, Object?> paying() => {
      ...window('w2', status: 'paying', approvals: 2),
      'cap_override_by': 'ops-1111-aaaa',
      'cap_override_reason': 'Diwali bonus week',
      'cap_override_at': '2026-11-04T09:00:00Z',
    };
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/windows/w2': (_) => json(override ? paying() : window('w2', status: 'approved', approvals: 2)),
      'POST /v1/payout/windows/w2/pay': (r) {
        if (r.body.isEmpty) return envelope(409, 'window_over_cap', message: 'over the cap');
        expect(jsonDecode(r.body), {'override_cap': true, 'reason': 'Diwali bonus week'});
        override = true;
        return json(paying());
      },
    });
    await openFinance(tester, backend);
    await tab(tester, 'Pay windows');
    await openWindow(tester, 'w2');
    await tester.tap(find.byKey(const Key('window-pay')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pay window').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('This window is above the per-window payout cap.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('window-pay-over-cap')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('over-cap-send')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/payout/windows/w2/pay'), hasLength(1), reason: 'a reason is required');
    await tester.enterText(find.byKey(const Key('over-cap-reason')), 'Diwali bonus week');
    await tester.tap(find.byKey(const Key('over-cap-send')));
    await tester.pumpAndSettle();
    final sent = backend.sent('POST', '/v1/payout/windows/w2/pay');
    expect(sent, hasLength(2));
    expect(sent.last.headers['Idempotency-Key'], isNot(sent.first.headers['Idempotency-Key']));
    expect(tester.widget<StatusChip>(find.byKey(const Key('window-status'))).label, 'Paying');
    final banner = find.byKey(const Key('window-cap-override'));
    expect(find.descendant(of: banner, matching: find.textContaining('Diwali bonus week')), findsOneWidget);
    expect(find.byKey(const Key('window-pay-over-cap')), findsNothing);
  });

  testWidgets('a line that is held or not going out says why in plain words; retry refusals are explained', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/windows': (_) => json([window('w5', status: 'paying', approvals: 2)]),
      'GET /v1/payout/windows/w5': (_) => json(window('w5', status: 'paying', approvals: 2)),
      'GET /v1/payout/windows/w5/lines': (_) => json([
        {...line('l1', 'worker-5555-1', '40.00', status: 'queued', attempts: 1), 'rail_status': 'account_changed'},
        line('l2', 'worker-6666-2', '30.00', status: 'held', hold: 'account_unconfirmed'),
        line('l3', 'worker-7777-3', '20.00', status: 'failed', attempts: 999, reason: 'rail_error'),
      ]),
      'POST /v1/payout/windows/w5/lines/l3/retry': (_) => envelope(409, 'too_many_attempts'),
    });
    await openFinance(tester, backend);
    await tab(tester, 'Pay windows');
    await openWindow(tester, 'w5');
    expect(find.text('Not going out: bank account changed since dispatch'), findsOneWidget);
    expect(find.text('Bank account waits for finance to confirm'), findsOneWidget);
    await tester.tap(find.byKey(const Key('line-retry-l3')));
    await tester.pumpAndSettle();
    expect(find.text('This line was tried too many times. Release it so its earnings roll into the next window.'), findsOneWidget);
  });

  testWidgets('a bank file that left lines out says how many and why', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/windows': (_) => json([window('w6', status: 'paying', approvals: 2, rail: 'file')]),
      'GET /v1/payout/windows/w6': (_) => json(window('w6', status: 'paying', approvals: 2, rail: 'file')),
      'GET /v1/payout/windows/w6/lines': (_) => json([line('l9', 'worker-5555-1', '4200.00', status: 'processing', attempts: 1)]),
      'GET /v1/payout/windows/w6/bank-file': (_) =>
          http.Response('reference\n', 200, headers: {'content-type': 'text/csv', 'x-skipped-lines': 'lx:held,ly:account_missing'}),
    });
    final h = await pumpApp(tester, backend, size: const Size(1280, 2400), roles: ['ops', 'finance'], at: '/ops/finance');
    await tab(tester, 'Pay windows');
    await openWindow(tester, 'w6');
    await tester.tap(find.byKey(const Key('window-bank-file')));
    await tester.pumpAndSettle();
    expect(
      find.text('2 lines were left out: 1 worker on hold, 1 bank account gone. They are back in the queue and are not in this file.'),
      findsOneWidget,
    );
    expect(h.downloads.saved, hasLength(1));
  });

  testWidgets('Holds lists bank accounts waiting for confirmation; finance confirms one after a check', (tester) async {
    var waiting = 2;
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/attention': (_) => json({'accounts_awaiting_confirmation': waiting}),
      'GET /v1/payout/accounts': (_) => json({'total': 0, 'items': []}),
      'GET /v1/payout/windows/w1/lines': (_) => json([
        line('l1', 'worker-5555-1', '2100.00'),
        line('l2', 'worker-6666-2', '300.00', status: 'held', hold: waiting == 2 ? 'account_unconfirmed' : null),
      ]),
      'POST /v1/payout/accounts/worker-6666-2/confirm': (_) {
        waiting = 1;
        return json({'status': 'verified', 'awaiting_confirmation': false});
      },
    });
    await openFinance(tester, backend);
    await tab(tester, 'Holds');
    expect(find.byKey(const Key('awaiting-worker-6666-2')), findsOneWidget);
    expect(find.byKey(const Key('awaiting-worker-5555-1')), findsNothing);
    expect(backend.sent('GET', '/v1/payout/windows/w3/lines'), isEmpty, reason: 'a paid window has nothing held');
    expect(find.textContaining('1 more'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-account-worker-6666-2')));
    await tester.pumpAndSettle();
    expect(find.text('Confirm this bank account?'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Confirm account')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/payout/accounts/worker-6666-2/confirm').single.headers['Idempotency-Key'], isNotEmpty);
    expect(find.text('Bank account confirmed'), findsOneWidget);
    expect(find.byKey(const Key('awaiting-worker-6666-2')), findsNothing);
    await expectAccessible(tester);
  });

  testWidgets('nothing waiting for confirmation shows no section and reads no lines', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/payout/accounts': (_) => json({'total': 0, 'items': []}),
    });
    await openFinance(tester, backend);
    await tab(tester, 'Holds');
    expect(find.byKey(const Key('awaiting-confirmation')), findsNothing);
    expect(backend.sent('GET', '/v1/payout/windows'), isEmpty, reason: 'no lines are read when nothing waits');
  });
}
