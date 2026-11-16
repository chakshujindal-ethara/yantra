import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_backend.dart';

const modules = ['market', 'talent', 'assess', 'quality', 'notify', 'tracker', 'analytics', 'payout'];

Map<String, Object?> expiredClaim(String id) => {
  'claim_id': id,
  'unit_id': 'unit-$id',
  'external_ref': 'clip-07',
  'batch_id': 'b1',
  'batch_title': 'Week 45 clips',
  'project_id': 'p1',
  'project_name': 'Hindi transcription',
  'worker_id': 'w-2',
  'worker_name': 'Ravi Kumar',
  'expires_at': '2026-11-04T09:00:00Z',
  'minutes_overdue': 75,
};

Map<String, Handler> routes({List<Object?>? claims, List<Object?>? reviews, Map<String, Handler> extra = const {}}) => {
  'GET /v1/claims/expired': (_) => json(claims ?? [expiredClaim('c1')]),
  'GET /v1/quality/reviews/expired': (_) => json(
    reviews ??
        [
          {
            'task_id': 't1',
            'unit_id': 'u9',
            'batch_id': 'b1000000-0000-0000-0000-000000000000',
            'kind': 'audit',
            'holder_id': 'w-3',
            'claim_expires_at': '2026-11-04T09:30:00Z',
            'minutes_overdue': 5,
          },
        ],
  ),
  'GET /v1/claims/released': (_) => json([
    {
      'claim_id': 'c0',
      'unit_id': 'u0',
      'batch_id': 'b1',
      'worker_id': 'w-4',
      'worker_name': 'Meena',
      'status': 'expired',
      'expires_at': '2026-11-03T09:00:00Z',
      'released_at': '2026-11-03T09:01:00Z',
      'released_by': null,
      'released_by_name': null,
    },
    {
      'claim_id': 'c9',
      'unit_id': 'u9',
      'batch_id': 'b1',
      'worker_id': 'w-5',
      'worker_name': 'Kiran',
      'status': 'expired',
      'expires_at': '2026-11-03T08:00:00Z',
      'released_at': '2026-11-03T10:00:00Z',
      'released_by': 'admin-1',
      'released_by_name': 'Admin One',
    },
  ]),
  'GET /v1/quality/reviews/released': (_) => json([
    {
      'task_id': 't0',
      'kind': 'review',
      'holder_id': 'w-6',
      'reason': 'holder',
      'released_by': null,
      'expires_at': null,
      'released_at': '2026-11-02T09:00:00Z',
    },
  ]),
  'GET /v1/people': (_) => json({
    'w-3': {'name': 'Sita', 'kind': 'worker'},
    'w-6': {'name': 'Gopal', 'kind': 'worker'},
  }),
  'GET /v1/units/stuck-assigned': (_) => json(<Object>[]),
  for (final m in modules) 'GET /v1/$m/dead-letters': (_) => json(<Object>[]),
  for (final m in modules)
    'GET /v1/$m/jobs': (_) => json([
      {
        'name': '${m}_prune',
        'next_run_at': DateTime.now().add(const Duration(hours: 3)).toUtc().toIso8601String(),
        'last_run_at': null,
        'last_finished_at': null,
        'last_result': null,
        'last_error': null,
        'locked_until': null,
      },
    ]),
  ...extra,
};

Future<TestHarness> open(WidgetTester tester, FakeBackend backend, {List<String> roles = const ['admin'], Size? size, bool dark = false}) =>
    pumpApp(tester, backend, size: size ?? const Size(1280, 2400), roles: roles, at: '/ops/system', dark: dark);

Future<void> tab(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(Key('tab-$name')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('stuck work lists expired claims and review claims with names, and the last 7 days', (tester) async {
    final backend = FakeBackend(routes());
    await open(tester, backend);
    expect(find.text('ADMIN · SYSTEM'), findsOneWidget);
    expect(find.text('2 stuck: 1 work, 1 review'), findsOneWidget);
    final claim = find.byKey(const Key('stuck-claim-c1'));
    expect(find.descendant(of: claim, matching: find.text('clip-07')), findsOneWidget);
    expect(find.descendant(of: claim, matching: find.text('Hindi transcription · Week 45 clips')), findsOneWidget);
    expect(find.descendant(of: claim, matching: find.text('Ravi Kumar')), findsOneWidget);
    expect(find.descendant(of: claim, matching: find.text('1 h 15 min')), findsOneWidget);
    final review = find.byKey(const Key('stuck-review-t1'));
    expect(find.descendant(of: review, matching: find.text('Audit')), findsOneWidget);
    expect(find.descendant(of: review, matching: find.text('Sita')), findsOneWidget);
    expect(find.descendant(of: review, matching: find.text('5 min')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('released-c0')), matching: find.text('Scheduler')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('released-c9')), matching: find.text('Admin One')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('released-t0')), matching: find.text('Given back')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('released-c9'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('released-c0'))).dy),
      reason: 'newest first',
    );
    await expectAccessible(tester);
  });

  testWidgets('Release on a row releases that claim and reloads; a 409 is a toast', (tester) async {
    var released = false;
    final backend = FakeBackend(
      routes(
        extra: {
          'POST /v1/claims/c1/release-expired': (_) {
            released = true;
            return json({'id': 'c1', 'status': 'expired'});
          },
          'POST /v1/quality/reviews/t1/release-expired': (_) => envelope(409, 'review_not_expired', message: 'Not expired any more'),
        },
      ),
    );
    await open(tester, backend);
    await tester.tap(find.byKey(const Key('release-claim-c1')));
    await tester.pumpAndSettle();
    expect(released, isTrue);
    expect(backend.sent('POST', '/v1/claims/c1/release-expired').single.headers['Idempotency-Key'], isNotEmpty);
    expect(find.text('Claim released'), findsOneWidget);
    expect(backend.sent('GET', '/v1/claims/expired'), hasLength(2));
    await tester.tap(find.byKey(const Key('release-review-t1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Details: Not expired any more'), findsOneWidget, reason: 'staff see the server text as details');
  });

  testWidgets('a release in flight disables its row and Release all until it answers', (tester) async {
    final answer = Completer<http.Response>();
    final backend = FakeBackend(routes());
    backend.slow['POST /v1/claims/c1/release-expired'] = (_) => answer.future;
    await open(tester, backend);
    await tester.tap(find.byKey(const Key('release-claim-c1')));
    await tester.pump();
    expect(tester.widget<TextButton>(find.byKey(const Key('release-claim-c1'))).onPressed, isNull);
    expect(tester.widget<FilledButton>(find.byKey(const Key('release-all'))).onPressed, isNull);
    expect(tester.widget<TextButton>(find.byKey(const Key('release-review-t1'))).onPressed, isNotNull, reason: 'other rows stay usable');
    answer.complete(json({'id': 'c1', 'status': 'expired'}));
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(find.byKey(const Key('release-claim-c1'))).onPressed, isNotNull);
    expect(tester.widget<FilledButton>(find.byKey(const Key('release-all'))).onPressed, isNotNull);
  });

  testWidgets('Release all in flight disables itself and every row', (tester) async {
    final answer = Completer<http.Response>();
    final backend = FakeBackend(
      routes(
        extra: {
          'POST /v1/quality/reviews/release-expired': (_) => json({'released': 0}),
        },
      ),
    );
    backend.slow['POST /v1/claims/release-expired'] = (_) => answer.future;
    await open(tester, backend);
    await tester.tap(find.byKey(const Key('release-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Release all').last);
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const Key('release-all'))).onPressed, isNull);
    expect(tester.widget<TextButton>(find.byKey(const Key('release-claim-c1'))).onPressed, isNull);
    answer.complete(json({'released': 1, 'more': false}));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('release-all'))).onPressed, isNotNull);
  });

  testWidgets('Release all keeps going while the server says there is more, and counts every pass', (tester) async {
    var pass = 0;
    final backend = FakeBackend(
      routes(
        extra: {
          'POST /v1/claims/release-expired': (_) =>
              ++pass < 3 ? json({'released': 100, 'more': true}) : json({'released': 3, 'more': false}),
          'POST /v1/quality/reviews/release-expired': (_) => json({'released': 2}),
        },
      ),
    );
    await open(tester, backend);
    await tester.tap(find.byKey(const Key('release-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Release all').last);
    await tester.pumpAndSettle();
    final keys = [for (final r in backend.sent('POST', '/v1/claims/release-expired')) r.headers['Idempotency-Key']];
    expect(keys, hasLength(3));
    expect(keys.toSet(), hasLength(3), reason: 'each pass is its own request');
    expect(find.text('205 claims released'), findsOneWidget);
  });

  testWidgets('Release all stops after 20 passes and says more remain', (tester) async {
    final backend = FakeBackend(
      routes(
        extra: {
          'POST /v1/claims/release-expired': (_) => json({'released': 10, 'more': true}),
          'POST /v1/quality/reviews/release-expired': (_) => json({'released': 0}),
        },
      ),
    );
    await open(tester, backend);
    await tester.tap(find.byKey(const Key('release-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Release all').last);
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/claims/release-expired'), hasLength(20));
    expect(find.text('200 claims released; more remain, run it again'), findsOneWidget);
  });

  testWidgets('row buttons name the person and the work they act on', (tester) async {
    final backend = FakeBackend(routes());
    await open(tester, backend);
    final handle = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel('Release the claim of Ravi Kumar on Week 45 clips'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Release the audit claim of (Sita|w-3) on batch ')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('Release all asks first, then releases claims and review claims and counts them', (tester) async {
    final backend = FakeBackend(
      routes(
        extra: {
          'POST /v1/claims/release-expired': (_) => json({'released': 1, 'more': false}),
          'POST /v1/quality/reviews/release-expired': (_) => json({'released': 1}),
        },
      ),
    );
    await open(tester, backend);
    await tester.tap(find.byKey(const Key('release-all')));
    await tester.pumpAndSettle();
    expect(find.text('Release all stuck work?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/claims/release-expired'), isEmpty);
    await tester.tap(find.byKey(const Key('release-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Release all').last);
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/claims/release-expired'), hasLength(1));
    expect(backend.sent('POST', '/v1/quality/reviews/release-expired'), hasLength(1));
    expect(find.text('2 claims released'), findsOneWidget);
  });

  testWidgets('a single release says so; a failed release-all is a toast; nothing stuck disables the button', (tester) async {
    var calls = 0;
    final backend = FakeBackend(
      routes(
        claims: [],
        reviews: [],
        extra: {
          'POST /v1/claims/release-expired': (_) =>
              ++calls == 1 ? json({'released': 1, 'more': false}) : envelope(503, 'upstream_unavailable'),
          'POST /v1/quality/reviews/release-expired': (_) => json({'released': 0}),
        },
      ),
    );
    await open(tester, backend);
    expect(find.text('Nothing is stuck'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('release-all'))).onPressed, isNull);
    expect(find.text('No work claim is past its time.'), findsOneWidget);
    // the palette command still reaches it
    await tester.tap(find.byKey(const Key('command-palette')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cmd-release-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Release all').last);
    await tester.pumpAndSettle();
    expect(find.text('1 claim released'), findsOneWidget);
    await tester.tap(find.byKey(const Key('command-palette')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cmd-release-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Release all').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('away'), findsWidgets);
  });

  testWidgets('dead letters list per module with Replay; a module that cannot answer says why', (tester) async {
    var replayed = false;
    final backend = FakeBackend(
      routes(
        extra: {
          'GET /v1/quality/dead-letters': (_) => json(
            replayed
                ? <Object>[]
                : [
                    {
                      'id': 'd1',
                      'consumer': 'quality-work-unit-submitted-v1',
                      'type': 'work.unit.submitted.v1',
                      'subject': 'work.unit.submitted',
                      'deliveries': 20,
                      'reason': 'IntegrityError: duplicate key',
                      'dead_at': '2026-11-04T08:00:00Z',
                    },
                  ],
          ),
          'GET /v1/payout/dead-letters': (_) => envelope(403, 'forbidden', message: 'admin or ops role required'),
          'POST /v1/quality/dead-letters/d1/replay': (_) {
            replayed = true;
            return json({'replayed': true, 'fresh': true});
          },
        },
      ),
    );
    await open(tester, backend);
    await tab(tester, 'dead');
    expect(find.text('1 dead letter. Fix the cause, then replay; a replay that fails again stays here.'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('dead-d1')), matching: find.text('work.unit.submitted.v1')), findsOneWidget);
    expect(find.textContaining('admin or ops role required'), findsOneWidget, reason: 'staff see the server text as details');
    await expectAccessible(tester);
    await tester.tap(find.byKey(const Key('replay-d1')));
    await tester.pumpAndSettle();
    expect(find.text('Replayed'), findsOneWidget);
    expect(find.text('No dead letters. Every event was handled.'), findsOneWidget);
  });

  testWidgets('jobs show next and last run and flag the ones behind or failing', (tester) async {
    final past = DateTime.now().subtract(const Duration(hours: 1)).toUtc().toIso8601String();
    final soon = DateTime.now().add(const Duration(seconds: 30)).toUtc().toIso8601String();
    final backend = FakeBackend(
      routes(
        extra: {
          'GET /v1/market/jobs': (_) => json([
            {
              'name': 'market_claim_expiry',
              'next_run_at': past,
              'last_run_at': past,
              'last_result': 3,
              'last_error': null,
              'locked_until': null,
            },
            {
              'name': 'market_prune',
              'next_run_at': soon,
              'last_run_at': past,
              'last_result': 0,
              'last_error': 'boom',
              'locked_until': null,
            },
            {
              'name': 'market_retention_purge',
              'next_run_at': past,
              'last_run_at': past,
              'last_result': null,
              'last_error': null,
              'locked_until': soon,
            },
          ]),
          'GET /v1/tracker/jobs': (_) => envelope(503, 'upstream_unavailable'),
        },
      ),
    );
    await open(tester, backend);
    await tab(tester, 'jobs');
    expect(find.textContaining('1 behind schedule, 1 whose last run failed'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('job-market_claim_expiry')), matching: find.text('Behind')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('job-market_prune')), matching: find.text('Last run failed')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('job-market_retention_purge')), matching: find.text('Running')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('job-talent_prune')), matching: find.text('On schedule')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('job-talent_prune')), matching: find.text('never')), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const Key('job-talent_prune')), matching: find.textContaining('in ')),
      findsOneWidget,
      reason: 'a future run reads ahead',
    );
    expect(find.descendant(of: find.byKey(const Key('job-market_claim_expiry')), matching: find.textContaining('due ')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('job-market_prune')), matching: find.text('within a minute')), findsOneWidget);
    expect(find.textContaining('away'), findsWidgets, reason: 'the tracker module says why it cannot answer');
    await tester.tap(find.byKey(const Key('system-refresh')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/market/jobs'), hasLength(2));
  });

  testWidgets('every job on schedule says so', (tester) async {
    await open(tester, FakeBackend(routes()));
    await tab(tester, 'jobs');
    expect(find.text('All 8 jobs are on schedule.'), findsOneWidget);
  });

  testWidgets('ops can open it; a worker cannot', (tester) async {
    await open(tester, FakeBackend(routes()), roles: ['ops', 'finance']);
    expect(find.text('ADMIN · SYSTEM'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await open(tester, FakeBackend(routes()), roles: ['worker']);
    expect(find.text('ADMIN · SYSTEM'), findsNothing);
  });

  testWidgets('renders at phone width and in dark mode without overflow', (tester) async {
    await open(tester, FakeBackend(routes()), size: const Size(390, 3000));
    expect(tester.takeException(), isNull);
    await tab(tester, 'jobs');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await open(tester, FakeBackend(routes()), dark: true);
    expect(tester.takeException(), isNull);
  });

  Map<String, Object?> stuckUnit(String id, {String batch = 'b1'}) => {
    'unit_id': id,
    'external_ref': 'clip-$id',
    'batch_id': batch,
    'batch_title': 'Week 45 clips',
    'project_id': 'p1',
    'project_name': 'Hindi transcription',
    'worker_id': 'w-2',
    'worker_name': 'Ravi Kumar',
    'assigned_at': '2026-10-29T09:00:00Z',
    'days_waiting': 6,
  };

  testWidgets('units waiting days for one worker go back to the pool after a confirm; an assigned batch says why not', (tester) async {
    var waiting = [stuckUnit('u1'), stuckUnit('u2', batch: 'b2')];
    final backend = FakeBackend(
      routes(
        extra: {
          'GET /v1/units/stuck-assigned': (_) => json(waiting),
          'POST /v1/units/u1/unassign': (_) {
            waiting = [stuckUnit('u2', batch: 'b2')];
            return json({'id': 'u1', 'batch_id': 'b1', 'status': 'available', 'assigned_worker_id': null});
          },
          'POST /v1/units/u2/unassign': (_) => envelope(409, 'assignment_required'),
        },
      ),
    );
    await open(tester, backend);
    final row = find.byKey(const Key('stuck-assigned-u1'));
    await tester.ensureVisible(row);
    expect(find.descendant(of: row, matching: find.text('clip-u1')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('Ravi Kumar')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('6 days')), findsOneWidget);

    await tester.tap(find.byKey(const Key('unassign-u1')));
    await tester.pumpAndSettle();
    expect(find.text('Return this unit to the pool?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/units/u1/unassign'), isEmpty);

    await tester.tap(find.byKey(const Key('unassign-u1')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Return to pool')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/units/u1/unassign').single.headers['Idempotency-Key'], isNotEmpty);
    expect(find.text('Unit back in the pool'), findsOneWidget);
    expect(find.byKey(const Key('stuck-assigned-u1')), findsNothing, reason: 'the list was read again');

    await tester.tap(find.byKey(const Key('unassign-u2')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Return to pool')));
    await tester.pumpAndSettle();
    expect(find.textContaining('has no pool to return the unit to'), findsOneWidget);
    await expectAccessible(tester);
  });

  testWidgets('a market that cannot list waiting units says so in that section; the rest of stuck work stays', (tester) async {
    final backend = FakeBackend(routes(extra: {'GET /v1/units/stuck-assigned': (_) => envelope(503, 'unavailable')}));
    await open(tester, backend);
    expect(find.byKey(const Key('stuck-claim-c1')), findsOneWidget);
    expect(find.byKey(const Key('stuck-assigned-error')), findsOneWidget);
  });
}
