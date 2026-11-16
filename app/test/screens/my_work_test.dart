import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/core/widgets/cards.dart';

import '../support/fake_backend.dart';

String ago(Duration d) => DateTime.now().subtract(d).toUtc().toIso8601String();

Map<String, Object?> item({
  required String task,
  required String unit,
  String stage = 'decided',
  String? verdict,
  String? reason,
  bool billable = false,
  String note = '',
  Duration decided = const Duration(days: 1),
  Map<String, Object?>? dispute,
}) => {
  'task_id': task,
  'unit_id': unit,
  'batch_id': 'b1',
  'submission_id': 's-$task',
  'rubric_version': 'v2',
  'stage': stage,
  'canonical_verdict': verdict,
  'reason_code': reason,
  'billable': billable,
  'reviewer_note': note,
  'feedback': {},
  'created_at': ago(decided + const Duration(hours: 3)),
  'decided_at': stage == 'decided' ? ago(decided) : null,
  'dispute': dispute,
};

final fixture = [
  item(task: 't1', unit: 'aaaaaaaa-1111-accepted', verdict: 'accept'),
  item(task: 't2', unit: 'bbbbbbbb-2222-review', stage: 'in_review', decided: const Duration(hours: 2)),
  item(task: 't3', unit: 'cccccccc-3333-edits', verdict: 'needs_edits', reason: 'incomplete', note: 'Second field is blank.'),
  item(task: 't4', unit: 'dddddddd-4444-reject', verdict: 'reject', reason: 'client_glossary_change', billable: true),
  item(
    task: 't5',
    unit: 'eeeeeeee-5555-upheld',
    verdict: 'reject',
    reason: 'low_quality',
    decided: const Duration(days: 3),
    dispute: {
      'id': 'd5',
      'status': 'upheld',
      'reason': 'The rubric allowed this reading.',
      'answer': 'Agreed, record cleared.',
      'created_at': ago(const Duration(days: 2)),
      'resolved_at': ago(const Duration(days: 1)),
    },
  ),
];

Future<void> openMyWork(WidgetTester tester, FakeBackend backend) async {
  backend.routes['GET /v1/claims/active'] = (_) => json({'claim': null, 'unit': null});
  backend.routes['GET /v1/batches'] = (_) => json([]);
  await pumpApp(tester, backend);
  await tester.tap(find.text('My work'));
  await tester.pumpAndSettle();
}

Finder chip(String label) => find.widgetWithText(StatusChip, label);
Finder segment(String label) => find.descendant(of: find.byKey(const Key('mywork-filter')), matching: find.text(label));

void main() {
  testWidgets('counts, chips and reasons render from all four states', (tester) async {
    final backend = FakeBackend({'GET /v1/quality/my-work': (_) => json(fixture)});
    await openMyWork(tester, backend);

    expect(find.text('Every unit you submitted and how it was judged'), findsOneWidget);
    expect(chip('Accepted'), findsOneWidget);
    expect(chip('In review'), findsOneWidget);
    expect(chip('Needs edits'), findsOneWidget);
    expect(chip('Rejected'), findsNWidgets(2));
    expect(find.text('aaaaaaaa'), findsOneWidget);
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel('Unit aaaaaaaa-1111-accepted'), findsOneWidget, reason: 'the full id is reachable by assistive tech');
    semantics.dispose();
    expect(find.text('Rubric v2'), findsNWidgets(5));
    expect(find.text('Incomplete'), findsOneWidget);
    expect(find.text('Client changed the glossary'), findsOneWidget);
    expect(chip('Client-caused · billable rework'), findsOneWidget);
    expect(find.text('Second field is blank.'), findsOneWidget);
    expect(find.textContaining('Submitted '), findsNWidgets(5));
    expect(find.textContaining('Decided '), findsNWidgets(5), reason: '4 verdicts + the upheld dispute');
    await expectAccessible(tester);
  });

  testWidgets('the upheld dispute is excluded from the rejected count and the rate', (tester) async {
    final backend = FakeBackend({'GET /v1/quality/my-work': (_) => json(fixture)});
    await openMyWork(tester, backend);
    final rejectedTile = find.ancestor(of: find.text('Excludes upheld disputes'), matching: find.byType(KpiTile));
    expect(find.descendant(of: rejectedTile, matching: find.text('1')), findsOneWidget);
    // accepted 1 of decided 3 (accepted + needs edits + 1 rejected)
    expect(find.textContaining('33% of decided units'), findsOneWidget);
    expect(chip('Upheld'), findsOneWidget);
    expect(find.text('Agreed, record cleared.'), findsOneWidget);
    expect(find.byKey(const Key('dispute-t5')), findsNothing, reason: 'already disputed');
  });

  testWidgets('the filter narrows the list', (tester) async {
    final backend = FakeBackend({'GET /v1/quality/my-work': (_) => json(fixture)});
    await openMyWork(tester, backend);
    await tester.tap(segment('Rejected'));
    await tester.pumpAndSettle();
    expect(find.text('aaaaaaaa'), findsNothing);
    expect(find.text('dddddddd'), findsOneWidget);
    expect(find.text('eeeeeeee'), findsOneWidget);

    await tester.tap(segment('In review'));
    await tester.pumpAndSettle();
    expect(find.text('bbbbbbbb'), findsOneWidget);
    expect(find.text('dddddddd'), findsNothing);
  });

  testWidgets('needs edits points back to Home', (tester) async {
    final backend = FakeBackend({'GET /v1/quality/my-work': (_) => json(fixture)});
    await openMyWork(tester, backend);
    expect(find.text('This unit is back in your pools: claim it again from Home'), findsOneWidget);
    await tester.tap(find.byKey(const Key('go-home-cccccccc')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('page-title')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('page-title'))).data, 'Home');
  });

  testWidgets('a dispute is validated, posted with a key, then the list reloads', (tester) async {
    var loads = 0;
    final backend = FakeBackend({
      'GET /v1/quality/my-work': (_) => json(
        ++loads == 1
            ? fixture
            : [
                ...fixture.sublist(0, 3),
                item(
                  task: 't4',
                  unit: 'dddddddd-4444-reject',
                  verdict: 'reject',
                  reason: 'client_glossary_change',
                  billable: true,
                  dispute: {
                    'id': 'd4',
                    'status': 'open',
                    'reason': 'The glossary changed after I wrote it.',
                    'answer': '',
                    'created_at': ago(Duration.zero),
                    'resolved_at': null,
                  },
                ),
                fixture[4],
              ],
      ),
      'POST /v1/quality/tasks/t4/dispute': (_) => json({'id': 'd4', 'status': 'open', 'reason': 'x', 'answer': ''}, status: 201),
    });
    await openMyWork(tester, backend);
    await tester.tap(find.byKey(const Key('dispute-t4')));
    await tester.pumpAndSettle();
    expect(find.textContaining('One dispute per unit, within 14 days'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('dispute-reason')), 'too short');
    await tester.tap(find.byKey(const Key('dispute-send')));
    await tester.pumpAndSettle();
    expect(find.textContaining('at least 10 characters'), findsOneWidget);
    expect(backend.sent('POST', '/v1/quality/tasks/t4/dispute'), isEmpty);

    await tester.enterText(find.byKey(const Key('dispute-reason')), 'The glossary changed after I wrote it.');
    await tester.tap(find.byKey(const Key('dispute-send')));
    await tester.pumpAndSettle();
    final sent = backend.sent('POST', '/v1/quality/tasks/t4/dispute').single;
    expect(sent.body, '{"reason":"The glossary changed after I wrote it."}');
    expect(sent.headers['Idempotency-Key'], isNotNull);
    expect(loads, 2, reason: 'reloaded after the dispute');
    expect(find.text('Dispute sent'), findsOneWidget);
    expect(chip('Open'), findsOneWidget);
    expect(find.byKey(const Key('dispute-t4')), findsNothing);
  });

  testWidgets('a 409 dispute_exists is explained in the dialog', (tester) async {
    final backend = FakeBackend({
      'GET /v1/quality/my-work': (_) => json(fixture),
      'POST /v1/quality/tasks/t4/dispute': (_) => envelope(409, 'dispute_exists', message: 'already'),
    });
    await openMyWork(tester, backend);
    await tester.tap(find.byKey(const Key('dispute-t4')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('dispute-reason')), 'The glossary changed after I wrote it.');
    await tester.tap(find.byKey(const Key('dispute-send')));
    await tester.pumpAndSettle();
    expect(find.text('Already disputed'), findsOneWidget);
  });

  testWidgets('a verdict older than 14 days cannot be disputed', (tester) async {
    final backend = FakeBackend({
      'GET /v1/quality/my-work': (_) =>
          json([item(task: 't9', unit: 'ffffffff-old', verdict: 'reject', reason: 'low_quality', decided: const Duration(days: 20))]),
    });
    await openMyWork(tester, backend);
    expect(find.byKey(const Key('dispute-t9')), findsNothing);
    expect(find.text('The 14-day dispute window has closed'), findsOneWidget);
  });

  testWidgets('nothing submitted shows the empty state with a way to Home', (tester) async {
    final backend = FakeBackend({'GET /v1/quality/my-work': (_) => json([])});
    await openMyWork(tester, backend);
    expect(find.text('Nothing submitted yet. Claim a unit from Home.'), findsOneWidget);
    expect(find.byKey(const Key('mywork-filter')), findsNothing);
    await tester.tap(find.byKey(const Key('mywork-empty-home')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('page-title'))).data, 'Home');
  });

  testWidgets('the sidebar reaches My work at desktop width', (tester) async {
    final backend = FakeBackend({
      'GET /v1/quality/my-work': (_) => json(fixture),
      'GET /v1/claims/active': (_) => json({'claim': null, 'unit': null}),
      'GET /v1/batches': (_) => json([]),
    });
    await pumpApp(tester, backend, size: const Size(1280, 1000));
    await tester.tap(find.byKey(const Key('nav-myWork')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mywork-filter')), findsOneWidget);
    expect(chip('Accepted'), findsOneWidget);
  });

  testWidgets('renders at phone width without overflow', (tester) async {
    final backend = FakeBackend({
      'GET /v1/quality/my-work': (_) => json(fixture),
      'GET /v1/claims/active': (_) => json({'claim': null, 'unit': null}),
      'GET /v1/batches': (_) => json([]),
    });
    await pumpApp(tester, backend, size: const Size(390, 3000));
    await tester.tap(find.text('My work'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('mywork-filter')), findsOneWidget);
    expect(chip('Client-caused · billable rework'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dispute-t4')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('dispute-reason')), findsOneWidget);
  });

  testWidgets('my work on a phone passes the checks and renders in dark mode', (tester) async {
    final backend = FakeBackend({
      'GET /v1/quality/my-work': (_) => json(fixture),
      'GET /v1/claims/active': (_) => json({'claim': null, 'unit': null}),
      'GET /v1/batches': (_) => json([]),
    });
    await pumpApp(tester, backend, size: const Size(390, 2400), at: '/work/my-work');
    await expectAccessible(tester);
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester, backend, dark: true, at: '/work/my-work');
    await expectRendersDark(tester);
  });
}
