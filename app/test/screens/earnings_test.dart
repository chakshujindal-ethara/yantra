import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/screens/earnings_screen.dart';
import 'package:http/http.dart' as http;
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/core/widgets/cards.dart';
import 'package:yantra_app/core/widgets/bars.dart';

import '../support/fake_backend.dart';

Map<String, Object?> earning(String id, String amount, String status, {String kind = 'unit', String? window}) => {
  'id': id,
  'kind': kind,
  'unit_id': '$id$id$id$id-unit',
  'amount': amount,
  'currency': 'INR',
  'status': status,
  'window_id': window,
  'created_at': '2026-11-01T10:00:00Z',
};

Map<String, Object?> statement({String hold = '', List<Object?>? weeks}) => {
  'worker_id': 'worker-1',
  'totals': {'payable': '37.50', 'windowed': '20.00', 'paid': '100.00'},
  'hold': hold.isEmpty ? null : hold,
  'account': {'hold_until': hold.isEmpty ? null : '2026-11-10T00:00:00Z', 'first_paid_at': '2026-10-24T09:00:00Z'},
  'pending_next': {'currency': 'INR', 'amount': '37.50', 'count': 3},
  'next_window_closes_at': DateTime.now().add(const Duration(days: 2, hours: 1)).toUtc().toIso8601String(),
  'earnings': [
    earning('e1', '12.50', 'payable'),
    earning('e2', '12.50', 'payable'),
    earning('e3', '12.50', 'payable'),
    earning('e4', '20.00', 'windowed', kind: 'review', window: 'w2'),
    earning('e5', '100.00', 'paid', kind: 'audit', window: 'w1'),
  ],
  'windows': [
    {
      'window_id': 'w1',
      'starts_at': '2026-10-17T00:00:00Z',
      'ends_at': '2026-10-24T00:00:00Z',
      'currency': 'INR',
      'window_status': 'paid',
      'line_status': 'paid',
      'gross': '100.00',
      'earning_count': 8,
      'hold_reason': '',
      'paid_at': '2026-10-26T09:00:00Z',
      'rail_reference': 'razorpayx:w1abcdef',
      'utr': '508812345678',
      'closed_at': '2026-10-24T00:00:00Z',
    },
    {
      'window_id': 'w2',
      'starts_at': '2026-10-24T00:00:00Z',
      'ends_at': '2026-10-31T00:00:00Z',
      'currency': 'INR',
      'window_status': 'closed',
      'line_status': hold.isEmpty ? 'payable' : 'held',
      'gross': '20.00',
      'earning_count': 1,
      'hold_reason': hold,
      'paid_at': null,
      'rail_reference': '',
      'closed_at': '2026-10-31T00:00:00Z',
    },
  ],
  'weeks':
      weeks ??
      [
        for (var i = 0; i < 12; i++)
          {
            'starts_at': '2026-${(8 + i ~/ 4).toString().padLeft(2, '0')}-${(1 + 7 * (i % 4)).toString().padLeft(2, '0')}T00:00:00Z',
            'ends_at': null,
            'currency': 'INR',
            'amount': '${i * 10}.00',
            'count': i,
          },
      ],
};

Future<TestHarness> openEarnings(WidgetTester tester, FakeBackend backend, {Size size = const Size(900, 2400), bool dark = false}) async {
  backend.routes['GET /v1/claims/active'] = (_) => json({'claim': null, 'unit': null});
  backend.routes['GET /v1/batches'] = (_) => json([]);
  return pumpApp(tester, backend, size: size, dark: dark, at: '/work/earnings');
}

Finder chip(String label) => find.widgetWithText(StatusChip, label);
Finder tile(String label) => find.ancestor(of: find.text(label), matching: find.byType(KpiTile));

void main() {
  testWidgets('KPIs come from totals and the next window', (tester) async {
    final backend = FakeBackend({'GET /v1/payout/statement': (_) => json(statement())});
    await openEarnings(tester, backend);
    expect(find.descendant(of: tile('Paid to date'), matching: find.text('₹100.00')), findsOneWidget);
    expect(find.descendant(of: tile('In the next payout'), matching: find.text('₹37.50')), findsOneWidget);
    expect(find.text('3 units · closes in 2 days'), findsOneWidget);
    expect(find.descendant(of: tile('In a closed window'), matching: find.text('₹20.00')), findsOneWidget);
    expect(find.text('Being checked and approved'), findsOneWidget);
    expect(find.text('Held'), findsNothing, reason: 'no hold, no held tile');
    expect(find.textContaining('A hold is in force'), findsNothing);
    await expectAccessible(tester);
  });

  testWidgets('a hold shows the banner and the held tile', (tester) async {
    final backend = FakeBackend({'GET /v1/payout/statement': (_) => json(statement(hold: 'first_payout'))});
    await openEarnings(tester, backend);
    expect(find.text('A hold is in force: first payout. Held earnings roll into the next window; nothing is lost.'), findsOneWidget);
    expect(find.descendant(of: tile('Held'), matching: find.text('₹20.00')), findsOneWidget);
    expect(find.text('First payout until 10 Nov'), findsOneWidget);
    expect(chip('Held'), findsOneWidget);
  });

  testWidgets('withdrawn consent explains the hold and how to lift it; unconfirmed accounts and consent read plainly', (tester) async {
    final backend = FakeBackend({'GET /v1/payout/statement': (_) => json(statement(hold: 'consent_withdrawn'))});
    await openEarnings(tester, backend);
    expect(
      find.text(
        'Your payouts are held because you withdrew your data consent. Give consent again in Profile → Your data; held earnings then go out with the next window.',
      ),
      findsOneWidget,
    );
    expect(find.text('Held while your data consent is withdrawn'), findsOneWidget, reason: 'the held window row says why');
    expect(find.text('Until you give consent again'), findsOneWidget, reason: 'the Held tile has no end date to show');
    expect(holdLabel('account_unconfirmed'), 'Held until finance confirms your bank account; the bank returned no name for it');
  });

  testWidgets('the weekly chart is drawn from weeks and skipped when empty', (tester) async {
    final backend = FakeBackend({'GET /v1/payout/statement': (_) => json(statement())});
    await openEarnings(tester, backend);
    expect(find.byType(WeeklyBars), findsOneWidget);
    expect(find.text('Last 12 weeks'), findsOneWidget);
    expect(find.text('Pay week: Saturday 00:00 to Friday 23:59 IST'), findsOneWidget);
  });

  testWidgets('no weeks means no chart card', (tester) async {
    final backend = FakeBackend({'GET /v1/payout/statement': (_) => json(statement(weeks: []))});
    await openEarnings(tester, backend);
    expect(find.byType(WeeklyBars), findsNothing);
    expect(find.text('Last 12 weeks'), findsNothing);
    expect(find.text('Payouts'), findsOneWidget);
  });

  testWidgets('payout rows carry the stage chip, the reference and the paid date', (tester) async {
    final backend = FakeBackend({'GET /v1/payout/statement': (_) => json(statement())});
    await openEarnings(tester, backend);
    expect(chip('Paid'), findsNWidgets(2), reason: 'the paid window and the paid earning');
    expect(chip('Closed'), findsOneWidget);
    expect(find.text('UTR 508812345678'), findsOneWidget);
    expect(find.text('8 units'), findsOneWidget);
    expect(find.text('Paid 26 Oct'), findsOneWidget);
    expect(chip('Payable'), findsNWidgets(3));
    expect(chip('In window'), findsOneWidget);
    expect(tester.widget<StatusChip>(chip('In window')).kind, StatusKind.info, reason: 'in a window is a stage, not a warning');
    expect(chip('Unit'), findsNWidgets(3));
    expect(chip('Review'), findsOneWidget);
    expect(chip('Audit'), findsOneWidget);
    expect(find.text('e1e1e1e1'), findsOneWidget);
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel('Unit e1e1e1e1-unit'), findsOneWidget, reason: 'the full id is reachable by assistive tech');
    semantics.dispose();
    expect(find.text('Only an accepted unit creates an earning. Disputes never change pay; they clear your record.'), findsOneWidget);
  });

  testWidgets('Download all saves the statement CSV with the windows and the earnings', (tester) async {
    final backend = FakeBackend({'GET /v1/payout/statement': (_) => json(statement())});
    final harness = await openEarnings(tester, backend);
    expect(find.text('Download all (CSV)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('download-csv')));
    await tester.pumpAndSettle();
    final saved = harness.downloads.saved.single;
    expect(saved.name, 'yantra-earnings.csv');
    expect(saved.mime, 'text/csv');
    final csv = utf8.decode(saved.bytes);
    expect(
      csv,
      contains('window,w1,2026-10-17T00:00:00.000Z,2026-10-24T00:00:00.000Z,100.00,INR,8,Paid,508812345678,2026-10-26T09:00:00.000Z'),
    );
    expect(csv, contains('earning,e5,,,100.00,INR,1,paid,e5e5e5e5-unit,'));
    expect(find.text('Saved yantra-earnings.csv'), findsOneWidget);
  });

  testWidgets('more than 20 earnings paginate behind Show more', (tester) async {
    final backend = FakeBackend({
      'GET /v1/payout/statement': (_) => json({
        ...statement(),
        'earnings': [for (var i = 0; i < 25; i++) earning('x${i.toString().padLeft(2, '0')}', '1.00', 'payable')],
      }),
    });
    await openEarnings(tester, backend);
    expect(chip('Payable'), findsNWidgets(20));
    await tester.tap(find.byKey(const Key('earnings-more')));
    await tester.pumpAndSettle();
    expect(chip('Payable'), findsNWidgets(25));
    expect(find.byKey(const Key('earnings-more')), findsNothing);
  });

  testWidgets('an empty statement shows the empty state', (tester) async {
    final backend = FakeBackend({'GET /v1/payout/statement': (_) => json({})});
    await openEarnings(tester, backend);
    expect(find.text('No earnings yet. Your first accepted unit appears here.'), findsOneWidget);
    expect(find.byKey(const Key('download-csv')), findsNothing);
  });

  testWidgets('the sidebar reaches Earnings at desktop width', (tester) async {
    final backend = FakeBackend({
      'GET /v1/payout/statement': (_) => json(statement()),
      'GET /v1/claims/active': (_) => json({'claim': null, 'unit': null}),
      'GET /v1/batches': (_) => json([]),
    });
    await pumpApp(tester, backend, size: const Size(1280, 1000));
    await tester.tap(find.byKey(const Key('nav-earnings')));
    await tester.pumpAndSettle();
    expect(find.text('Accepted units, pay windows, payouts'), findsOneWidget);
    expect(find.byType(WeeklyBars), findsOneWidget);
  });

  testWidgets('renders at phone width without overflow', (tester) async {
    final backend = FakeBackend({
      'GET /v1/payout/statement': (_) => json(statement(hold: 'first_payout')),
      'GET /v1/claims/active': (_) => json({'claim': null, 'unit': null}),
      'GET /v1/batches': (_) => json([]),
    });
    final harness = await pumpApp(tester, backend, size: const Size(390, 3000));
    await tester.tap(find.text('Earnings'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(WeeklyBars), findsOneWidget);
    expect(find.text('UTR 508812345678'), findsOneWidget);
    await tester.tap(find.byKey(const Key('download-csv')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(harness.downloads.saved, hasLength(1));
  });

  Map<String, Object?> window(String id, {required String line, String window = 'paying', String utr = '', String reason = ''}) => {
    'window_id': id,
    'starts_at': '2026-10-24T18:30:00Z',
    'ends_at': '2026-10-31T18:29:59Z',
    'currency': 'INR',
    'window_status': window,
    'line_status': line,
    'gross': '150.00',
    'earning_count': 3,
    'hold_reason': null,
    'utr': utr.isEmpty ? null : utr,
    'failure_reason': reason.isEmpty ? null : reason,
    'paid_at': line == 'paid' ? '2026-11-01T06:00:00Z' : null,
    'rail_reference': 'razorpayx:$id',
    'closed_at': '2026-11-01T00:05:00Z',
  };

  testWidgets('a paid window offers its statement, saved as the server writes it', (tester) async {
    final backend = FakeBackend({
      'GET /v1/payout/statement': (_) => json({
        ...statement(),
        'windows': [window('w9abcdef12', line: 'paid', window: 'paid', utr: 'UTR793080536545')],
      }),
      'GET /v1/payout/statements/w9abcdef12/export': (r) {
        expect(r.url.queryParameters['format'], 'csv');
        expect(r.headers['Accept'], 'text/csv');
        return http.Response('kind,unit_id,amount\nunit,u1,150.00\n', 200, headers: {'content-type': 'text/csv'});
      },
    });
    final harness = await openEarnings(tester, backend);
    expect(find.text('UTR UTR793080536545'), findsOneWidget);
    await tester.tap(find.byKey(const Key('statement-w9abcdef12')));
    await tester.pumpAndSettle();
    final saved = harness.downloads.saved.single;
    expect(saved.name, 'statement-w9abcdef.csv');
    expect(utf8.decode(saved.bytes), contains('unit,u1,150.00'));
  });

  testWidgets('a statement before reconciliation says when it will be ready', (tester) async {
    final backend = FakeBackend({
      'GET /v1/payout/statement': (_) => json({
        ...statement(),
        'windows': [window('w9', line: 'paid', window: 'paid')],
      }),
      'GET /v1/payout/statements/w9/export': (_) => envelope(409, 'not_reconciled'),
    });
    final harness = await openEarnings(tester, backend);
    await tester.tap(find.byKey(const Key('statement-w9')));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('ready once this window is reconciled'), findsOneWidget);
    expect(harness.downloads.saved, isEmpty);
    await tester.pumpAndSettle();
  });

  testWidgets('lines being sent, failed or moved say so in plain words, with no statement yet', (tester) async {
    final backend = FakeBackend({
      'GET /v1/payout/statement': (_) => json({
        ...statement(),
        'windows': [
          window('wa', line: 'processing'),
          window('wb', line: 'failed', reason: 'insufficient_funds'),
          window('wc', line: 'returned', reason: 'beneficiary_account_closed'),
          window('wd', line: 'released', reason: 'insufficient_funds'),
        ],
      }),
    });
    await openEarnings(tester, backend);
    expect(chip('Sending'), findsOneWidget);
    expect(chip('Failed'), findsNWidgets(2));
    expect(chip('Moved'), findsOneWidget);
    expect(find.textContaining('It is retried; you do not need to do anything'), findsOneWidget);
    expect(find.textContaining('the account looks closed'), findsOneWidget);
    expect(find.textContaining('move to the next pay window'), findsOneWidget);
    expect(find.byKey(const Key('statement-wa')), findsNothing);
  });

  testWidgets('earnings filter by status and by pay window; nothing matching says so', (tester) async {
    final backend = FakeBackend({
      'GET /v1/payout/statement': (_) => json({
        ...statement(),
        'windows': [window('w1', line: 'paid', window: 'paid')],
        'earnings': [
          {...earning('p1', '11.11', 'payable'), 'window_id': null},
          {...earning('w1e', '22.22', 'paid'), 'window_id': 'w1'},
          {...earning('w2e', '33.33', 'windowed'), 'window_id': 'w2'},
        ],
      }),
    });
    await openEarnings(tester, backend);
    expect(find.text('₹11.11'), findsOneWidget);
    await tester.tap(find.byKey(const Key('filter-paid')));
    await tester.pumpAndSettle();
    expect(find.text('₹11.11'), findsNothing);
    expect(find.text('₹22.22'), findsOneWidget);
    await tester.tap(find.byKey(const Key('filter-in-window')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('earnings-window')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Oct').last);
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches these filters.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('filter-all')));
    await tester.pumpAndSettle();
    expect(find.text('₹22.22'), findsWidgets);
    expect(find.text('₹33.33'), findsNothing);
  });

  testWidgets('earnings on a phone pass the checks and render in dark mode', (tester) async {
    final backend = FakeBackend({'GET /v1/payout/statement': (_) => json(statement())});
    await openEarnings(tester, backend, size: const Size(390, 2400));
    await expectAccessible(tester);
    await tester.pumpWidget(const SizedBox());
    await openEarnings(tester, backend, dark: true);
    await expectRendersDark(tester);
  });

  testWidgets('where the browser cannot save a file, the CSV opens in a copyable box', (tester) async {
    final backend = FakeBackend({
      'GET /v1/payout/statement': (_) => json({
        ...statement(),
        'windows': [window('w9', line: 'paid', window: 'paid')],
      }),
      'GET /v1/payout/statements/w9/export': (_) => http.Response('kind,amount\nunit,1.00\n', 200),
    });
    final harness = await openEarnings(tester, backend);
    harness.downloads.supported = false;
    await tester.tap(find.byKey(const Key('download-csv')));
    await tester.pumpAndSettle();
    expect(tester.widget<SelectableText>(find.byKey(const Key('csv-text'))).data, contains('window,w9'));
    await tester.tap(find.byKey(const Key('csv-copy')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('statement-w9')));
    await tester.pumpAndSettle();
    expect(tester.widget<SelectableText>(find.byKey(const Key('csv-text'))).data, contains('unit,1.00'));
    expect(harness.downloads.saved, isEmpty);
  });

  testWidgets('a statement that fails for another reason says what happened', (tester) async {
    final backend = FakeBackend({
      'GET /v1/payout/statement': (_) => json({
        ...statement(),
        'windows': [window('w9', line: 'paid', window: 'paid')],
      }),
      'GET /v1/payout/statements/w9/export': (_) => envelope(403, 'forbidden', message: 'not yours'),
    });
    await openEarnings(tester, backend);
    await tester.tap(find.byKey(const Key('statement-w9')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.pumpAndSettle();
  });
}
