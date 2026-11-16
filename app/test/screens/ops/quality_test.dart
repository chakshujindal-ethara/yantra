import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/core/widgets/cards.dart';
import 'package:yantra_app/core/widgets/loader.dart';

import '../../support/fake_backend.dart';
import '../fixtures_console.dart';

Map<String, Handler> routes() => {
  'GET /v1/quality/flags': (_) => json([flag('f1'), flag('f2', note: 'Is a faded sign still a sign?')]),
  'GET /v1/quality/disputes': (_) => json([disputeRow('d1'), disputeRow('d2', verdict: 'needs_edits', reason: 'client_glossary_change')]),
  'GET /v1/quality/stats': (_) => json(stats()),
  'GET /v1/quality/tasks': (_) => json(taskPage([taskRow('t1'), taskRow('t2', status: 'canonical', verdict: 'accept')])),
};

Future<void> openQuality(WidgetTester tester, FakeBackend backend, {bool wide = true, Size? size}) =>
    openOps(tester, backend, navKey: 'nav-quality', label: 'Quality', wide: wide, size: size);

Future<void> tab(WidgetTester tester, String label) async {
  final segment = find.descendant(of: find.byKey(const Key('quality-tab')), matching: find.text(label));
  await tester.ensureVisible(segment);
  await tester.tap(segment);
  await tester.pumpAndSettle();
}

Finder chip(String label) => find.widgetWithText(StatusChip, label);
Finder tile(String label) => find.ancestor(of: find.text(label), matching: find.byType(KpiTile));

void main() {
  testWidgets('flags list the note, the batch, the reviewer and the age; the kicker names the page', (tester) async {
    final backend = FakeBackend(routes());
    await openQuality(tester, backend);
    expect(find.text('OPERATE · QUALITY'), findsOneWidget);
    expect(find.text('Does "street sign" include shop boards?'), findsOneWidget);
    expect(find.text('Is a faded sign still a sign?'), findsOneWidget);
    expect(find.text('2 waiting for an answer'), findsOneWidget);
    expect(find.text('batch-aa'), findsNWidgets(2));
    expect(find.text('r-7777-1'), findsNWidgets(2));
    expect(find.text('Raised 3 h ago'), findsNWidgets(2));
    await expectAccessible(tester);
  });

  testWidgets('answering a flag POSTs the answer with an idempotency key and reloads', (tester) async {
    var answered = false;
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/quality/flags': (_) => json(
        answered ? [flag('f2', note: 'Is a faded sign still a sign?')] : [flag('f1'), flag('f2', note: 'Is a faded sign still a sign?')],
      ),
      'POST /v1/quality/flags/f1/answer': (r) {
        answered = true;
        return json({...flag('f1'), 'answer': jsonDecode(r.body)['answer'], 'answered_at': '2026-11-03T10:00:00Z'});
      },
    });
    await openQuality(tester, backend);
    await tester.tap(find.byKey(const Key('flag-answer-f1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('flag-answer-send')));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsOneWidget);
    expect(backend.sent('POST', '/v1/quality/flags/f1/answer'), isEmpty);

    await tester.enterText(find.byKey(const Key('flag-answer-text')), 'Yes: any board with a street name counts.');
    await tester.tap(find.byKey(const Key('flag-answer-send')));
    await tester.pumpAndSettle();
    final sent = backend.sent('POST', '/v1/quality/flags/f1/answer').single;
    expect(jsonDecode(sent.body), {'answer': 'Yes: any board with a street name counts.'});
    expect(sent.headers['Idempotency-Key'], isNotNull);
    expect(find.text('Answer sent'), findsOneWidget);
    expect(find.text('Does "street sign" include shop boards?'), findsNothing, reason: 'reloaded without the answered flag');
    expect(find.text('1 waiting for an answer'), findsOneWidget);
  });

  testWidgets('no flags shows "Nothing to answer"; a failed load offers Retry', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/quality/flags': (_) => fail ? envelope(503, 'upstream_unavailable', headers: {'retry-after': '3'}) : json([]),
    });
    await openQuality(tester, backend);
    expect(find.text('Service is away. Retry in 3s.'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing to answer'), findsOneWidget);
  });

  testWidgets('disputes show the reason, the verdict chip, the reason code and the billable chip', (tester) async {
    final backend = FakeBackend(routes());
    await openQuality(tester, backend);
    await tab(tester, 'Disputes');
    expect(find.text('2 open · the decision is final and never changes pay'), findsOneWidget);
    expect(find.text('The glossary changed after I submitted; my answer matched the old one.'), findsNWidgets(2));
    expect(chip('Rejected'), findsOneWidget);
    expect(tester.widget<StatusChip>(chip('Rejected')).kind, StatusKind.dest);
    expect(chip('Needs edits'), findsOneWidget);
    expect(find.text('Guideline miss'), findsOneWidget);
    expect(find.text('Client changed the glossary'), findsOneWidget);
    expect(chip('Billable rework'), findsOneWidget);
    expect(find.text('Raised 2 days ago'), findsNWidgets(2));
  });

  testWidgets('overturning a dispute POSTs outcome upheld with the note; upholding posts dismissed', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'POST /v1/quality/disputes/d1/resolve': (r) =>
          json({...disputeRow('d1'), 'status': jsonDecode(r.body)['outcome'], 'answer': jsonDecode(r.body)['answer']}),
      'POST /v1/quality/disputes/d2/resolve': (r) => json({...disputeRow('d2'), 'status': jsonDecode(r.body)['outcome']}),
    });
    await openQuality(tester, backend);
    await tab(tester, 'Disputes');
    final loads = backend.sent('GET', '/v1/quality/disputes').length;
    await tester.tap(find.byKey(const Key('dispute-overturn-d1')));
    await tester.pumpAndSettle();
    expect(find.text('Overturn the verdict'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('dispute-note')), 'You are right, the glossary moved.');
    await tester.tap(find.byKey(const Key('dispute-resolve-send')));
    await tester.pumpAndSettle();
    final sent = backend.sent('POST', '/v1/quality/disputes/d1/resolve').single;
    expect(jsonDecode(sent.body), {'outcome': 'upheld', 'answer': 'You are right, the glossary moved.'});
    expect(sent.headers['Idempotency-Key'], isNotNull);
    expect(find.text('Verdict overturned'), findsOneWidget);

    await tester.tap(find.byKey(const Key('dispute-uphold-d2')));
    await tester.pumpAndSettle();
    expect(find.text('Uphold the verdict'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('dispute-note')), 'The rubric is clear on this.');
    await tester.tap(find.byKey(const Key('dispute-resolve-send')));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('POST', '/v1/quality/disputes/d2/resolve').single.body)['outcome'], 'dismissed');
    expect(backend.sent('GET', '/v1/quality/disputes').length, loads + 2, reason: 'reloaded after each decision');
  });

  testWidgets('a dispute already decided elsewhere stays in the dialog with a plain reason', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'POST /v1/quality/disputes/d1/resolve': (_) => envelope(409, 'dispute_resolved', message: 'dispute already resolved'),
    });
    await openQuality(tester, backend);
    await tab(tester, 'Disputes');
    await tester.tap(find.byKey(const Key('dispute-uphold-d1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('dispute-note')), 'Stands.');
    await tester.tap(find.byKey(const Key('dispute-resolve-send')));
    await tester.pumpAndSettle();
    expect(find.text('Already decided by someone else'), findsOneWidget);
    expect(find.byKey(const Key('dispute-note')), findsOneWidget, reason: 'the dialog stays open');
  });

  testWidgets('no disputes shows "Nothing to decide"', (tester) async {
    final backend = FakeBackend({...routes(), 'GET /v1/quality/disputes': (_) => json([])});
    await openQuality(tester, backend);
    await tab(tester, 'Disputes');
    expect(find.textContaining('Nothing to decide'), findsOneWidget);
  });

  testWidgets('the queue shows the numbers, the reasons with billable chips and the tasks table', (tester) async {
    final backend = FakeBackend(routes());
    await openQuality(tester, backend);
    await tab(tester, 'Queue');
    expect(find.descendant(of: tile('Pending'), matching: find.text('12')), findsOneWidget);
    expect(find.descendant(of: tile('Claimed'), matching: find.text('3')), findsOneWidget);
    expect(find.descendant(of: tile('In audit'), matching: find.text('1')), findsOneWidget);
    expect(find.text('2 audit disagreements'), findsOneWidget);
    expect(find.descendant(of: tile('Accepted'), matching: find.text('33')), findsOneWidget);
    expect(find.text('of 40 decided'), findsOneWidget);
    expect(find.descendant(of: tile('Acceptance rate'), matching: find.text('83%')), findsOneWidget);
    expect(find.descendant(of: tile('Oldest waiting'), matching: find.text('30 h')), findsOneWidget);
    expect(find.byKey(const Key('reason-guideline_miss')), findsOneWidget);
    expect(find.byKey(const Key('reason-client_glossary_change')), findsOneWidget);
    expect(chip('Billable'), findsOneWidget);
    expect(chip('Worker'), findsOneWidget);
    expect(find.byKey(const Key('task-t1')), findsOneWidget);
    expect(find.byKey(const Key('task-t2')), findsOneWidget);
    expect(chip('Decided'), findsOneWidget);
    expect(chip('Accepted'), findsOneWidget);
    final first = backend.sent('GET', '/v1/quality/tasks').single;
    expect(first.url.queryParameters, {'limit': '50', 'offset': '0'});
  });

  testWidgets('a status filter and the pager change the tasks query', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/quality/tasks': (r) =>
          json(taskPage([for (var i = 0; i < 50; i++) taskRow('p${r.url.queryParameters['offset']}-$i')], total: 120)),
    });
    await openQuality(tester, backend, size: const Size(1280, 4000));
    await tab(tester, 'Queue');
    await tester.tap(find.byKey(const Key('filter-pending')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/quality/tasks').last.url.queryParameters['status'], 'pending');
    expect(find.text('1–50 of 120'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('pager-next')));
    await tester.tap(find.byKey(const Key('pager-next')));
    await tester.pumpAndSettle();
    final q = backend.sent('GET', '/v1/quality/tasks').last.url.queryParameters;
    expect(q['offset'], '50');
    expect(q['status'], 'pending');
    expect(find.text('51–100 of 120'), findsOneWidget);
    expect(find.byKey(const Key('task-p50-0')), findsOneWidget);
  });

  testWidgets('an acceptance rate sent as a percentage reads the same; an empty queue says so', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/quality/stats': (_) => json(stats(rate: '83')),
      'GET /v1/quality/tasks': (_) => json(taskPage([])),
    });
    await openQuality(tester, backend);
    await tab(tester, 'Queue');
    expect(find.descendant(of: tile('Acceptance rate'), matching: find.text('83%')), findsOneWidget);
    expect(find.text('No review tasks yet.'), findsOneWidget);
  });

  testWidgets('the brand loader shows while the first load is in flight', (tester) async {
    final backend = FakeBackend(routes());
    await pumpApp(tester, backend, size: const Size(1280, 900), roles: ['ops', 'finance']);
    await tester.tap(find.byKey(const Key('nav-quality')));
    await tester.pump();
    expect(find.byType(BrandLoader), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(BrandLoader), findsNothing);
  });

  testWidgets('renders at phone width without overflow and reaches the queue', (tester) async {
    final backend = FakeBackend(routes());
    await openQuality(tester, backend, wide: false, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(find.text('Does "street sign" include shop boards?'), findsOneWidget);
    await tab(tester, 'Queue');
    expect(tester.takeException(), isNull);
    expect(find.text('Pending'), findsWidgets);
  });

  testWidgets('renders at desktop width', (tester) async {
    final backend = FakeBackend(routes());
    await openQuality(tester, backend, size: const Size(1280, 900));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('flag-answer-f1')), findsOneWidget);
    expect(find.byKey(const Key('flag-answer-f2')), findsOneWidget);
  });

  testWidgets('an overdue flag comes first with its badge and the count says how many are late', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/quality/flags': (_) => json([
        flag('f1'),
        {...flag('f2', note: 'Is a faded sign still a sign?'), 'overdue': true},
      ]),
    });
    await openQuality(tester, backend);
    expect(find.text('2 waiting for an answer · 1 past the two-day answer'), findsOneWidget);
    expect(find.byKey(const Key('flag-overdue-f2')), findsOneWidget);
    final late = tester.getTopLeft(find.text('Is a faded sign still a sign?')).dy;
    final onTime = tester.getTopLeft(find.text('Does "street sign" include shop boards?')).dy;
    expect(late < onTime, isTrue, reason: 'overdue first');
  });

  testWidgets('a link with ?batch= opens the queue for that batch; typing another batch narrows it after a pause', (tester) async {
    final backend = FakeBackend(routes());
    await pumpApp(tester, backend, size: const Size(1280, 2400), roles: ['ops', 'finance'], at: '/ops/quality?batch=b1');
    expect(backend.sent('GET', '/v1/quality/stats').last.url.queryParameters['batch_id'], 'b1');
    expect(backend.sent('GET', '/v1/quality/tasks').last.url.queryParameters['batch_id'], 'b1');
    expect(tester.widget<TextField>(find.byKey(const Key('queue-batch'))).controller!.text, 'b1');
    await tester.enterText(find.byKey(const Key('queue-batch')), 'b2');
    await tester.pump(const Duration(milliseconds: 310));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/quality/tasks').last.url.queryParameters['batch_id'], 'b2');
    await tester.tap(find.byKey(const Key('queue-batch-clear')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/quality/tasks').last.url.queryParameters.containsKey('batch_id'), isFalse);
  });

  testWidgets('the integrity tab lists anomalies; upholding asks for a note, posts it and reloads', (tester) async {
    var upheld = false;
    Map<String, Object?> anomaly(String id, String kind, Map<String, Object?> detail, {String status = 'open'}) => {
      'id': id,
      'worker_id': 'worker-5555-1',
      'session_id': null,
      'kind': kind,
      'detail': detail,
      'week_start': null,
      'status': status,
      'note': null,
      'decided_by': null,
      'decided_at': null,
      'created_at': '2026-11-03T10:00:00Z',
    };
    final backend = FakeBackend({
      ...routes(),
      'GET /v1/tracker/anomalies': (r) => json([
        if (r.url.queryParameters['status'] == 'open' && !upheld) anomaly('a1', 'impossible_activity', {'active_seconds': 77400}),
        if (r.url.queryParameters['status'] == 'open')
          anomaly('a2', 'duplicate_device', {
            'worker_ids': ['w1', 'w2', 'w3'],
          }),
      ]),
      'GET /v1/workers': (_) => json({'total': 0, 'items': []}),
      'GET /v1/workers/worker-5555-1': (_) =>
          json({'id': 'worker-5555-1', 'status': 'eligible', 'cert_gates': [], 'updated_at': '2026-11-01T10:00:00Z'}),
      'POST /v1/tracker/anomalies/a1/uphold': (r) {
        upheld = true;
        return json({...anomaly('a1', 'impossible_activity', {}, status: 'upheld'), 'note': (jsonDecode(r.body) as Map)['note']});
      },
    });
    await openQuality(tester, backend);
    await tab(tester, 'Integrity');
    expect(backend.sent('GET', '/v1/tracker/anomalies').last.url.queryParameters['status'], 'open');
    expect(find.text('More than 20 h active in 24 h (21.5 h)'), findsOneWidget);
    expect(find.text('Same device as 2 other worker(s)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('anomaly-uphold-a1')));
    await tester.pumpAndSettle();
    expect(find.text('Uphold and hold payouts?'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('anomaly-note')), 'Two people on one account');
    await tester.tap(find.byKey(const Key('anomaly-send')));
    await tester.pumpAndSettle();
    final sent = backend.sent('POST', '/v1/tracker/anomalies/a1/uphold').single;
    expect(jsonDecode(sent.body), {'note': 'Two people on one account'});
    expect(sent.headers['Idempotency-Key'], isNotEmpty);
    expect(find.text('Upheld; payouts held'), findsOneWidget);
    expect(find.byKey(const Key('anomaly-a1')), findsNothing, reason: 'the open list reloaded without it');

    await tester.tap(find.byKey(const Key('anomaly-worker-a2')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/ops/workers/worker-5555-1');
  });

  testWidgets('the integrity tab is accessible in light and renders dark without overflow', (tester) async {
    final backend = FakeBackend({...routes(), 'GET /v1/tracker/anomalies': (_) => json([])});
    await openQuality(tester, backend);
    await tab(tester, 'Integrity');
    expect(find.textContaining('Nothing to look at'), findsOneWidget);
    await expectAccessible(tester);
  });

  testWidgets('the integrity tab renders dark on a phone without overflow', (tester) async {
    final backend = FakeBackend({...routes(), 'GET /v1/tracker/anomalies': (_) => json([])});
    await pumpApp(tester, backend, size: const Size(390, 2400), roles: ['ops', 'finance'], dark: true, at: '/ops/quality');
    await tab(tester, 'Integrity');
    expect(tester.takeException(), isNull);
  });
}
