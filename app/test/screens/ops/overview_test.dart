import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/core/widgets/cards.dart';
import 'package:yantra_app/core/widgets/stage_bar.dart';
import 'package:yantra_app/widgets/load_view.dart';

import '../../support/fake_backend.dart';
import '../fixtures.dart';
import 'fixtures_ops.dart';

Finder tile(String label) => find.ancestor(of: find.text(label), matching: find.byType(KpiTile));

/// Two projects; the second carries its batches, one of them under its 30% floor.
List<Object?> twoProjects() => [
  projectSummary(),
  projectSummary(
    id: 'p2',
    name: 'Street signs',
    createdAt: '2026-10-28T10:00:00Z',
    batches: [
      batchSummary(),
      batchSummary(id: 'b2', title: 'Cheap batch', unitPay: '50.00'),
    ],
  ),
];

void main() {
  testWidgets('KPIs come from the projects, the quality stats and the payout overview', (tester) async {
    final backend = FakeBackend(overviewRoutes(projects: twoProjects()));
    await pumpOps(tester, backend);
    expect(find.text('Operate · Overview'.toUpperCase()), findsOneWidget);
    expect(find.descendant(of: tile('Open units'), matching: find.text('80')), findsOneWidget);
    expect(find.descendant(of: tile('Live claims'), matching: find.text('10')), findsOneWidget);
    expect(find.descendant(of: tile('In review'), matching: find.text('10')), findsOneWidget);
    expect(find.text('oldest waiting 3 h'), findsOneWidget);
    expect(find.descendant(of: tile('Acceptance'), matching: find.text('90%')), findsOneWidget);
    expect(find.descendant(of: tile('Payable now'), matching: find.text('₹12,500.00')), findsOneWidget);
    expect(find.text(r'$40.00'), findsOneWidget, reason: 'every other currency goes in the note');
    expect(find.descendant(of: tile('Margin to date'), matching: find.text('₹32,000.00')), findsOneWidget);
    expect(find.descendant(of: tile('Window closes'), matching: find.text('in 3 days')), findsOneWidget);
    expect(find.descendant(of: tile('Bench'), matching: find.text('42')), findsOneWidget);
    expect(find.text('4 paused · 3 held · 46 in all'), findsOneWidget);
    expect(backend.sent('GET', '/v1/attention'), hasLength(1));
    expect(backend.sent('GET', '/v1/payout/attention'), hasLength(1));
    expect(backend.sent('GET', '/v1/quality/flags'), isEmpty, reason: 'two attention calls replace counting whole lists');
    await expectAccessible(tester);
  });

  testWidgets('the attention card counts and each button goes to its destination', (tester) async {
    final backend = FakeBackend({...overviewRoutes(projects: twoProjects()), 'GET /v1/projects/p2': (_) => json(projectDetail())});
    await pumpOps(tester, backend);
    expect(find.text('1 flag past its 2-day answer'), findsOneWidget);
    expect(find.text('2 open flags'), findsOneWidget);
    expect(find.text('1 open dispute'), findsOneWidget);
    expect(find.text('2 claims and reviews past their time'), findsOneWidget);
    expect(find.text('2 applicants waiting for screening'), findsOneWidget);
    expect(find.text('3 open tickets'), findsOneWidget);
    expect(find.text('1 window waiting for a second approval'), findsOneWidget);
    expect(find.text('2 payouts the bank refused'), findsOneWidget);
    expect(find.text('1 batch under its margin floor'), findsOneWidget);
    expect(find.text('Cheap batch · Street signs · 10% < 30%'), findsOneWidget);

    await reveal(tester, find.byKey(const Key('attention-support')));
    await tester.tap(find.byKey(const Key('attention-support')));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Support');
    await tester.tap(find.byKey(const Key('nav-opsOverview')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const Key('attention-quality')));
    await tester.tap(find.byKey(const Key('attention-quality')));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Quality');
    await tester.tap(find.byKey(const Key('nav-opsOverview')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const Key('attention-finance')));
    await tester.tap(find.byKey(const Key('attention-finance')));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Finance');
    await tester.tap(find.byKey(const Key('nav-opsOverview')));
    await tester.pumpAndSettle();

    await reveal(tester, find.byKey(const Key('attention-stuck')));
    await tester.tap(find.byKey(const Key('attention-stuck')));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'System');
    await tester.tap(find.byKey(const Key('nav-opsOverview')));
    await tester.pumpAndSettle();

    await reveal(tester, find.byKey(const Key('attention-floor-b2')));
    await tester.tap(find.byKey(const Key('attention-floor-b2')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/projects/p2'), hasLength(1), reason: 'an under-floor batch opens its project');
    expect(find.byKey(const Key('back')), findsOneWidget);
  });

  testWidgets('blocked payout lines, accounts to confirm, payout erasures and units waiting for one worker need attention', (tester) async {
    final backend = FakeBackend({
      ...overviewRoutes(),
      'GET /v1/attention': (_) => json({'stuck_assigned_units': 2}),
      'GET /v1/payout/attention': (_) => json({'lines_blocked': 3, 'erasures_pending': 1, 'accounts_awaiting_confirmation': 1}),
    });
    await pumpOps(tester, backend);
    expect(find.text('3 payout lines that cannot go out'), findsOneWidget);
    expect(find.text('1 bank account waiting for finance to confirm it'), findsOneWidget);
    expect(find.text('1 bank account to erase once what is owed is paid'), findsOneWidget);
    expect(find.text('2 units waiting days for one worker'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('attention-accounts-to-confirm')));
    await tester.tap(find.byKey(const Key('attention-accounts-to-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Finance'), findsWidgets);
  });

  testWidgets('a module that is empty (404) reads as a dash, never an error', (tester) async {
    final backend = FakeBackend({
      'GET /v1/projects': (_) => json([projectSummary()]),
    });
    await pumpOps(tester, backend);
    expect(find.byType(ErrorView), findsNothing);
    expect(find.descendant(of: tile('Acceptance'), matching: find.text('—')), findsOneWidget);
    expect(find.descendant(of: tile('Payable now'), matching: find.text('—')), findsOneWidget);
    expect(find.descendant(of: tile('Window closes'), matching: find.text('—')), findsOneWidget);
    expect(find.text('Nothing needs attention'), findsOneWidget);
    expect(find.text('— open flags'), findsNothing);
  });

  testWidgets('the units bar in a table carries its numbers as a tooltip and a semantics label, never colour alone', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpOps(tester, FakeBackend(overviewRoutes()));
    await reveal(tester, find.byType(StageBar));
    expect(find.bySemanticsLabel('50 accepted of 100'), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(find.descendant(of: find.byType(StageBar), matching: find.byType(Tooltip)));
    expect(tooltip.message, '40 available · 5 in progress · 5 in review · 50 accepted');
    handle.dispose();
  });

  testWidgets('the units bar in a table shows how many are accepted beside it, and says when there are none', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(
          body: Column(
            children: [
              StageBar(legend: false, available: 7, inProgress: 1, inReview: 1, accepted: 2, needsEdits: 1),
              StageBar(legend: false, available: 0, inProgress: 0, inReview: 0, accepted: 0),
            ],
          ),
        ),
      ),
    );
    expect(find.text('2 of 12 accepted'), findsOneWidget);
    expect(find.text('No units yet'), findsOneWidget);
  });

  testWidgets('the projects table lists the latest projects and opens one', (tester) async {
    final backend = FakeBackend({...overviewRoutes(projects: twoProjects()), 'GET /v1/projects/p1': (_) => json(projectDetail())});
    await pumpOps(tester, backend);
    await reveal(tester, find.text('Street signs'));
    expect(find.text('Hindi transcription'), findsOneWidget);
    expect(find.text('Street signs'), findsOneWidget);
    expect(chip('Active'), findsNWidgets(2));
    expect(find.byType(StageBar), findsNWidgets(2));
    final rows = tester.getTopLeft(find.text('Street signs')).dy < tester.getTopLeft(find.text('Hindi transcription')).dy;
    expect(rows, isTrue, reason: 'newest first');
    await reveal(tester, find.byKey(const Key('overview-project-p1')));
    await tester.tap(find.byKey(const Key('overview-project-p1')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/projects/p1'), hasLength(1));
    await reveal(tester, find.text('Transcribe the audio exactly as spoken.'));
    expect(find.text('Transcribe the audio exactly as spoken.'), findsOneWidget);
  });

  testWidgets('an error offers retry and recovers', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      ...overviewRoutes(),
      'GET /v1/projects': (_) => fail ? envelope(500, 'boom', message: 'Market is away') : json([projectSummary()]),
    });
    await pumpOps(tester, backend);
    expect(find.textContaining('Details: Market is away'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Details: Market is away'), findsNothing);
    expect(find.descendant(of: tile('Open units'), matching: find.text('40')), findsOneWidget);
  });

  testWidgets('renders on a phone without overflow', (tester) async {
    final backend = FakeBackend(overviewRoutes(projects: twoProjects()));
    await pumpOps(tester, backend, size: phone);
    expect(tester.takeException(), isNull);
    expect(find.descendant(of: tile('Open units'), matching: find.text('80')), findsOneWidget);
    await reveal(tester, find.text('Attention'));
    expect(find.text('2 open flags'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a KPI tile opens the page behind its figure', (tester) async {
    final backend = FakeBackend(overviewRoutes(projects: twoProjects()));
    await pumpOps(tester, backend);
    expect(find.descendant(of: tile('Bench'), matching: find.byIcon(Icons.arrow_forward)), findsOneWidget);
    await tester.tap(tile('Bench'));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Workers');
    await tester.tap(find.byKey(const Key('nav-opsOverview')));
    await tester.pumpAndSettle();
    await tester.tap(tile('Acceptance'));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Quality');
  });

  testWidgets('the overview re-reads itself quietly every minute', (tester) async {
    final backend = FakeBackend(overviewRoutes(projects: twoProjects()));
    await pumpOps(tester, backend);
    final first = backend.sent('GET', '/v1/attention').length;
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/attention').length, first + 1);
    expect(
      find.descendant(of: tile('Bench'), matching: find.text('42')),
      findsOneWidget,
      reason: 'the figures stay on screen',
    );
  });

  testWidgets('renders in dark mode without overflow and stays accessible', (tester) async {
    final backend = FakeBackend(overviewRoutes(projects: twoProjects()));
    await pumpApp(tester, backend, size: wide, roles: const ['ops', 'finance'], dark: true);
    expect(tester.takeException(), isNull);
    expect(find.text('1 flag past its 2-day answer'), findsOneWidget);
  });
}
