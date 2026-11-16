import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/screens/review_screen.dart';

import '../support/fake_backend.dart';

final task = {
  'id': 't1',
  'unit_id': 'u9u9u9u9-0000-4000-8000-000000000001',
  'batch_id': 'b1',
  'submission_id': 's9',
  'rubric_version': 'v3',
  'status': 'claimed',
  'claim_expires_at': DateTime.now().add(const Duration(minutes: 59)).toUtc().toIso8601String(),
  'canonical_verdict': null,
};

Map<String, Object?> detail({bool audit = false}) => {
  ...task,
  'payload': {
    'text': 'Stop sign at 5th',
    'meta': {'lang': 'en'},
  },
  'answer': {'label': 'stop', 'confidence': 'high'},
  'sampled_for_audit': audit,
};

Future<void> openReview(WidgetTester tester, FakeBackend backend) async {
  backend.routes.putIfAbsent(
    'GET /v1/claims/active',
    () =>
        (_) => json({'claim': null, 'unit': null}),
  );
  backend.routes.putIfAbsent(
    'GET /v1/batches',
    () =>
        (_) => json([]),
  );
  backend.routes.putIfAbsent(
    'GET /v1/quality/tasks/t1',
    () =>
        (_) => json(detail()),
  );
  await pumpApp(tester, backend);
  await openFromDrawer(tester, 'nav-review');
}

Future<void> getTask(WidgetTester tester, FakeBackend backend) async {
  await openReview(tester, backend);
  await tester.tap(find.byKey(const Key('get-review')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the idle card explains the queue and offers both entries', (tester) async {
    await openReview(tester, FakeBackend());
    expect(find.text('You never review your own work. Each task is held for 60 minutes.'), findsOneWidget);
    expect(find.text('Get next task'), findsOneWidget);
    expect(find.byKey(const Key('get-audit')), findsOneWidget);
    await expectAccessible(tester);
  });

  testWidgets('getting a task shows the payload, the answer, the unit, the rubric and the hold', (tester) async {
    final backend = FakeBackend({'POST /v1/quality/reviews/claim': (_) => json(task, status: 201)});
    await getTask(tester, backend);

    expect(backend.sent('POST', '/v1/quality/reviews/claim').single.url.queryParameters['kind'], 'review');
    expect(backend.sent('GET', '/v1/quality/tasks/t1'), hasLength(1));
    expect(find.text('What the worker was given'), findsOneWidget);
    expect(find.text('Stop sign at 5th'), findsOneWidget);
    expect(find.textContaining('"lang": "en"'), findsOneWidget);
    expect(find.text('Their answer'), findsOneWidget);
    expect(find.text('stop'), findsOneWidget);
    expect(find.text('high'), findsOneWidget);
    expect(find.text('Unit u9u9u9u9'), findsOneWidget, reason: 'shortened to 8 characters');
    expect(find.byTooltip('Unit u9u9u9u9-0000-4000-8000-000000000001'), findsOneWidget);
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(
      find.bySemanticsLabel('Unit u9u9u9u9-0000-4000-8000-000000000001'),
      findsOneWidget,
      reason: 'the full id is reachable by assistive tech',
    );
    semantics.dispose();
    expect(find.text('Rubric v3'), findsOneWidget);
    expect(find.text('Audit sample'), findsNothing);
    expect(find.textContaining('Held for 58:'), findsOneWidget);
    expect(find.byKey(const Key('review-countdown')), findsOneWidget);
    expect(find.byKey(const Key('verdict')), findsOneWidget);
    expect(find.byKey(const Key('reason')), findsNothing, reason: 'no reason list before a verdict');
  });

  testWidgets('an empty queue (404) is shown as nothing to review', (tester) async {
    final backend = FakeBackend({'POST /v1/quality/reviews/claim': (_) => envelope(404, 'not_found', message: 'queue is empty')});
    await getTask(tester, backend);
    expect(find.text('Nothing to review right now.'), findsOneWidget);
    expect(find.byKey(const Key('verdict')), findsNothing);
  });

  testWidgets('a task already held is shown on open, without claiming', (tester) async {
    final backend = FakeBackend({'GET /v1/quality/reviews/active': (_) => json(detail())});
    await openReview(tester, backend);
    expect(backend.sent('GET', '/v1/quality/reviews/active'), hasLength(1));
    expect(backend.sent('POST', '/v1/quality/reviews/claim'), isEmpty);
    expect(find.text('Stop sign at 5th'), findsOneWidget);
    expect(find.byKey(const Key('verdict')), findsOneWidget);
    expect(find.byKey(const Key('get-review')), findsNothing);
  });

  testWidgets('a 409 one_live_review fetches the held task and says so', (tester) async {
    var claimed = false;
    final backend = FakeBackend({
      'POST /v1/quality/reviews/claim': (_) {
        claimed = true;
        return envelope(409, 'one_live_review', message: 'you already hold a task');
      },
      'GET /v1/quality/reviews/active': (_) => claimed ? json(detail()) : envelope(404, 'not_found'),
    });
    await getTask(tester, backend);
    expect(backend.sent('GET', '/v1/quality/reviews/active'), hasLength(2), reason: 'once on open, once to recover the held task');
    expect(find.text('You still hold a task; finish it first'), findsOneWidget);
    expect(find.text('Stop sign at 5th'), findsOneWidget);
    expect(find.byKey(const Key('verdict')), findsOneWidget);
    expect(find.text('Nothing to review right now.'), findsNothing);
  });

  testWidgets('when the hold runs out the task is explained and can be dropped, and the ticker stops', (tester) async {
    var now = DateTime.now();
    final backend = FakeBackend({
      'POST /v1/quality/reviews/claim': (_) =>
          json({...task, 'claim_expires_at': now.add(const Duration(seconds: 90)).toUtc().toIso8601String()}, status: 201),
      'GET /v1/quality/tasks/t1': (_) =>
          json({...detail(), 'claim_expires_at': now.add(const Duration(seconds: 90)).toUtc().toIso8601String()}),
      'GET /v1/claims/active': (_) => json({'claim': null, 'unit': null}),
      'GET /v1/batches': (_) => json([]),
    });
    await pumpApp(tester, backend);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(body: ReviewScreen(clock: () => now)),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.tap(find.byKey(const Key('get-review')));
    await tester.pumpAndSettle();
    expect(find.text('Held for 01:30'), findsOneWidget);

    now = now.add(const Duration(minutes: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Hold expired'), findsOneWidget);
    expect(find.byKey(const Key('review-exit')), findsOneWidget);
    expect(find.textContaining('went back to the queue'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('record-verdict'))).onPressed, isNull, reason: 'nothing to record any more');

    await tester.tap(find.byKey(const Key('drop-task')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('verdict')), findsNothing);
    expect(find.text('Get next task'), findsOneWidget);
    expect(find.byKey(const Key('review-exit')), findsNothing);
  });

  testWidgets('the hold counts down on the server\'s clock, not a fast device\'s', (tester) async {
    final expires = DateTime.now().subtract(const Duration(seconds: 1)).toUtc().toIso8601String();
    final backend = FakeBackend({
      'POST /v1/quality/reviews/claim': (_) => json({...task, 'claim_expires_at': expires}, status: 201),
      'GET /v1/quality/tasks/t1': (_) => json({...detail(), 'claim_expires_at': expires}),
    })..serverSkew = const Duration(minutes: -5);
    await getTask(tester, backend);
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Held for 04:5'), findsOneWidget, reason: 'five minutes left on the server');
    expect(find.byKey(const Key('review-exit')), findsNothing);
    expect(find.text('Hold expired'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a 409 on record explains it and offers to drop the task', (tester) async {
    final backend = FakeBackend({
      'POST /v1/quality/reviews/claim': (_) => json(task, status: 201),
      'POST /v1/quality/tasks/t1/review': (_) => envelope(409, 'hold_expired', message: 'your hold on this task ended'),
    });
    await getTask(tester, backend);
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('record-verdict')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('review-exit')), findsOneWidget);
    expect(find.textContaining('This task cannot be recorded any more'), findsOneWidget);
    expect(find.textContaining('your hold on this task ended'), findsNothing, reason: 'server text is for logs');
    expect(tester.widget<FilledButton>(find.byKey(const Key('record-verdict'))).onPressed, isNull);

    await tester.tap(find.byKey(const Key('drop-task')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('verdict')), findsNothing);
    expect(find.byKey(const Key('get-review')), findsOneWidget);
  });

  testWidgets('a verdict is required, and a reason unless the verdict is accept', (tester) async {
    final backend = FakeBackend({'POST /v1/quality/reviews/claim': (_) => json(task, status: 201)});
    await getTask(tester, backend);

    await tester.tap(find.byKey(const Key('record-verdict')));
    await tester.pumpAndSettle();
    expect(find.text('Choose a verdict'), findsOneWidget);

    await tester.ensureVisible(find.text('Reject'));
    await tester.pump();
    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reason')), findsOneWidget);
    expect(find.text('Worker-caused'), findsOneWidget);
    expect(find.text('Client-caused (billable rework, the worker is not at fault)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('record-verdict')));
    await tester.pumpAndSettle();
    expect(find.text('Choose a reason code'), findsOneWidget);
    expect(backend.sent('POST', '/v1/quality/tasks/t1/review'), isEmpty);
  });

  testWidgets('needs edits with a client-caused reason posts the code and shows the billable grouping', (tester) async {
    final backend = FakeBackend({
      'POST /v1/quality/reviews/claim': (_) => json(task, status: 201),
      'POST /v1/quality/tasks/t1/review': (_) => json({...task, 'status': 'judged', 'canonical_verdict': 'needs_edits'}),
    });
    await getTask(tester, backend);

    await tester.tap(find.text('Needs edits'));
    await tester.pumpAndSettle();
    expect(find.text('Client-caused (billable rework, the worker is not at fault)'), findsOneWidget);
    expect(find.text('Client changed the glossary'), findsOneWidget);
    expect(find.text('Correct when written; the client moved the target.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reason-client_glossary_change')));
    await tester.enterText(find.byKey(const Key('note')), 'glossary moved after submit');
    await tester.tap(find.byKey(const Key('rubric-unclear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('record-verdict')));
    await tester.pumpAndSettle();

    final sent = backend.sent('POST', '/v1/quality/tasks/t1/review').single;
    expect(
      sent.body,
      '{"verdict":"needs_edits","reason_code":"client_glossary_change","rubric_unclear":true,"note":"glossary moved after submit","feedback":{}}',
    );
    expect(sent.headers['Idempotency-Key'], isNotNull);
    expect(find.byKey(const Key('review-done')), findsOneWidget);
    expect(find.text('Verdict Needs edits recorded · Client changed the glossary (billable rework)'), findsOneWidget);
    expect(find.text('Next task'), findsOneWidget);
    expect(find.byKey(const Key('get-review')), findsOneWidget, reason: 'ready for the next task');
    expect(find.byKey(const Key('verdict')), findsNothing);
  });

  testWidgets('a verdict changed after a 5xx goes out under a new key; the same verdict keeps its key', (tester) async {
    final backend = FakeBackend({
      'POST /v1/quality/reviews/claim': (_) => json(task, status: 201),
      'POST /v1/quality/tasks/t1/review': (_) => envelope(503, 'upstream_unavailable'),
    });
    await getTask(tester, backend);
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('record-verdict')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('record-verdict')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('note')), 'looked again');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('record-verdict')));
    await tester.pumpAndSettle();
    final keys = [for (final r in backend.sent('POST', '/v1/quality/tasks/t1/review')) r.headers['Idempotency-Key']];
    expect(keys, hasLength(3));
    expect(keys[1], keys[0], reason: 'a retry of the same verdict');
    expect(keys[2], isNot(keys[0]), reason: 'an edited verdict is a new action');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('accept needs no reason code and records a success banner', (tester) async {
    final backend = FakeBackend({
      'POST /v1/quality/reviews/claim': (_) => json(task, status: 201),
      'POST /v1/quality/tasks/t1/review': (_) => json({...task, 'status': 'judged', 'canonical_verdict': 'accept'}),
    });
    await getTask(tester, backend);
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reason')), findsNothing);
    await tester.tap(find.byKey(const Key('record-verdict')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/quality/tasks/t1/review').single.body, contains('"verdict":"accept","reason_code":null'));
    expect(find.text('Verdict Accept recorded'), findsOneWidget);

    await tester.tap(find.byKey(const Key('get-review')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/quality/reviews/claim'), hasLength(2), reason: 'Next task fetches again');
    expect(find.byKey(const Key('review-done')), findsNothing);
  });

  testWidgets('the audit button claims with kind=audit and the sample is flagged', (tester) async {
    final backend = FakeBackend({
      'POST /v1/quality/reviews/claim': (_) => json(task, status: 201),
      'GET /v1/quality/tasks/t1': (_) => json(detail(audit: true)),
    });
    await openReview(tester, backend);
    await tester.tap(find.byKey(const Key('get-audit')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/quality/reviews/claim').single.url.queryParameters['kind'], 'audit');
    expect(find.text('Audit sample'), findsOneWidget);
  });

  testWidgets('on a phone the task stacks and a verdict can still be recorded', (tester) async {
    final backend = FakeBackend({
      'POST /v1/quality/reviews/claim': (_) => json(task, status: 201),
      'POST /v1/quality/tasks/t1/review': (_) => json({...task, 'status': 'judged', 'canonical_verdict': 'reject'}),
      'GET /v1/claims/active': (_) => json({'claim': null, 'unit': null}),
      'GET /v1/batches': (_) => json([]),
      'GET /v1/quality/tasks/t1': (_) => json(detail()),
    });
    await pumpApp(tester, backend, size: const Size(390, 844));
    await openFromDrawer(tester, 'nav-review');
    await tester.tap(find.byKey(const Key('get-review')));
    await tester.pumpAndSettle();
    expect(find.text('Stop sign at 5th'), findsOneWidget);

    await tester.ensureVisible(find.text('Reject'));
    await tester.pump();
    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('reason-low_quality')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('reason-low_quality')));
    await tester.ensureVisible(find.byKey(const Key('record-verdict')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('record-verdict')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/quality/tasks/t1/review').single.body, contains('"verdict":"reject","reason_code":"low_quality"'));
    expect(find.text('Verdict Reject recorded · Low quality'), findsOneWidget);
  });

  testWidgets('on a desktop the sidebar opens Review and the columns sit side by side', (tester) async {
    final backend = FakeBackend({
      'POST /v1/quality/reviews/claim': (_) => json(task, status: 201),
      'GET /v1/claims/active': (_) => json({'claim': null, 'unit': null}),
      'GET /v1/batches': (_) => json([]),
      'GET /v1/quality/tasks/t1': (_) => json(detail()),
    });
    await pumpApp(tester, backend, size: const Size(1280, 1000));
    await tester.tap(find.byKey(const Key('nav-review')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('get-review')));
    await tester.pumpAndSettle();
    final left = tester.getRect(find.text('What the worker was given'));
    final right = tester.getRect(find.text('Your verdict'));
    expect(right.left, greaterThan(left.right), reason: 'two columns');
    expect((right.top - left.top).abs(), lessThan(8), reason: 'same row');
  });

  testWidgets('a rate limit on the review claim shows the wait and keeps the idle card', (tester) async {
    final backend = FakeBackend({
      'POST /v1/quality/reviews/claim': (_) => envelope(429, 'rate_limited', message: 'x', headers: {'retry-after': '30'}),
    });
    await getTask(tester, backend);
    expect(find.text('Too many requests. Wait 30s and try again.'), findsOneWidget);
    expect(find.byKey(const Key('get-review')), findsOneWidget);
  });

  testWidgets('an empty queue says how many tasks wait for a certification or a clearance the reviewer lacks', (tester) async {
    final backend = FakeBackend({
      'POST /v1/quality/reviews/claim': (_) =>
          envelope(404, 'not_found', message: 'nothing you can review', context: {'waiting_for_gate': 3, 'waiting_for_clearance': '1'}),
    });
    await getTask(tester, backend);
    expect(
      find.text(
        'Nothing you can review right now: 3 tasks wait for a certification you do not hold; 1 task needs sensitive-content clearance. '
        'Ask ops if you should have it.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the served reason catalogue replaces the shipped one and only offers reasons for the verdict', (tester) async {
    final backend = FakeBackend({
      'GET /v1/quality/reasons': (_) => json([
        {
          'code': 'off_topic',
          'label': 'Off topic',
          'billable': false,
          'applies_to': ['reject'],
        },
        {'code': 'client_scope_change', 'label': '', 'billable': true, 'applies_to': <String>[]},
        {'code': '', 'label': 'nameless'},
      ]),
      'POST /v1/quality/reviews/claim': (_) => json(task, status: 201),
    });
    await getTask(tester, backend);
    await tester.tap(find.text('Needs edits'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reason-off_topic')), findsNothing, reason: 'Off topic applies to Reject only');
    expect(find.byKey(const Key('reason-client_scope_change')), findsOneWidget);
    expect(find.text('Client scope change'), findsOneWidget, reason: 'a code without a label is named from the code');
    expect(find.byKey(const Key('reason-guideline_miss')), findsNothing, reason: 'the shipped list is replaced');
    await tester.ensureVisible(find.text('Reject'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reason-off_topic')), findsOneWidget);
  });

  testWidgets('the task payload renders by kind and the answer reads as prose where it is long', (tester) async {
    final backend = FakeBackend({
      'POST /v1/quality/reviews/claim': (_) => json(task, status: 201),
      'GET /v1/quality/tasks/t1': (_) => json({
        ...detail(),
        'payload': {'audio_ref': 's3://yantra/projects/p1/units/u/clip.wav', 'language': 'hi'},
        'answer': {'transcript': 'haan ji\nmain kal aaunga', 'speakers': 1},
      }),
    });
    await getTask(tester, backend);
    expect(find.byKey(const Key('payload-audio-audio_ref')), findsOneWidget);
    expect(find.byKey(const Key('answer-prose-transcript')), findsOneWidget);
  });

  testWidgets('a review recorded after the hold ran out says so in plain words', (tester) async {
    final backend = FakeBackend({
      'POST /v1/quality/reviews/claim': (_) => json(task, status: 201),
      'POST /v1/quality/tasks/t1/review': (_) => envelope(409, 'review_expired', message: 'review_expired'),
    });
    await getTask(tester, backend);
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('record-verdict')));
    await tester.pumpAndSettle();
    expect(find.textContaining('The hold on this task ran out, so it went back to the queue.'), findsOneWidget);
    expect(find.textContaining('review_expired'), findsNothing);
  });

  testWidgets('review on a phone passes the checks and renders in dark mode', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json({'claim': null, 'unit': null}),
      'GET /v1/batches': (_) => json([]),
    });
    await pumpApp(tester, backend, size: const Size(390, 2400), at: '/work/review');
    await expectAccessible(tester);
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester, backend, dark: true, at: '/work/review');
    await expectRendersDark(tester);
  });
}
