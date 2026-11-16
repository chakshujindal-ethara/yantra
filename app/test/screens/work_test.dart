import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/api/models.dart';
import 'package:yantra_app/core/widgets/detail_frame.dart';
import 'package:yantra_app/screens/work_screen.dart';

import '../support/fake_backend.dart';

final schema = {
  'type': 'object',
  'required': ['label', 'sentiment', 'score'],
  'properties': {
    'label': {'type': 'string', 'title': 'Sign label', 'description': 'What the sign says', 'maxLength': 40},
    'notes': {'type': 'string', 'format': 'textarea'},
    'sentiment': {
      'type': 'string',
      'enum': ['positive', 'neutral', 'negative'],
    },
    'language': {
      'type': 'string',
      'enum': ['en', 'hi', 'ta', 'te', 'kn', 'ml'],
    },
    'score': {'type': 'number', 'title': 'Confidence'},
    'count': {'type': 'integer'},
    'legible': {'type': 'boolean', 'title': 'Legible'},
  },
};

Map<String, Object?> batch({bool withSchema = true}) => {
  'id': 'b1',
  'project_id': 'p1',
  'project_name': 'Street signs',
  'title': 'Label street signs',
  'mode': 'open',
  'unit_pay': '12.50',
  'review_pay': '2.00',
  'currency': 'INR',
  'claim_ttl_minutes': 240,
  'rubric_version': 'v2',
  'status': 'open',
  'available_units': 42,
  if (withSchema) 'answer_schema': schema,
};

Map<String, Object?> claim({String expires = ''}) => {
  'id': 'c1',
  'unit_id': 'u1',
  'worker_id': 'worker-1',
  'status': 'live',
  'expires_at': expires.isEmpty ? DateTime.now().add(const Duration(hours: 2)).toUtc().toIso8601String() : expires,
};

final unit = {
  'id': 'u1',
  'batch_id': 'b1',
  'external_ref': 'row-17',
  'payload': {
    'text': 'Stop sign at 5th',
    'meta': {'lang': 'en'},
  },
  'unit_pay': '12.50',
  'rubric_version': 'v1',
  'status': 'claimed',
  'current_claim_id': 'c1',
};

Map<String, Object?> submitted() => {
  'id': 's1',
  'claim_id': 'c1',
  'unit_id': 'u1',
  'rubric_version': 'v2',
  'submitted_at': '2026-11-03T10:00:00Z',
};

/// Pumps the app, then opens the Work route the way Home does (handing over the live claim it read).
Future<TestHarness> openWork(
  WidgetTester tester,
  FakeBackend backend, {
  Map<String, Object?>? claimJson,
  Map<String, Object?>? batchJson,
  Size size = const Size(900, 2400),
}) async {
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
  final harness = await pumpApp(tester, backend, size: size);
  final b = batchJson ?? batch();
  final c = Claim.fromJson(claimJson ?? claim());
  await goTo(
    tester,
    '/work/home/unit/${c.id}',
    extra: ActiveWork(claim: c, unit: Unit.fromJson(unit), batch: Batch.fromJson(b)),
  );
  return harness;
}

Map<String, dynamic> answerOf(FakeBackend backend) =>
    (jsonDecode(backend.sent('POST', '/v1/claims/c1/submission').single.body) as Map<String, dynamic>)['answer'] as Map<String, dynamic>;

void main() {
  testWidgets('the brief, the payload and a form built from the schema are shown', (tester) async {
    final backend = FakeBackend();
    await openWork(tester, backend);

    expect(find.text('Street signs'), findsOneWidget);
    expect(find.text('Label street signs'), findsWidgets, reason: 'app bar title and brief');
    expect(find.text('Unit row-17'), findsOneWidget);
    expect(find.text('Pays ₹12.50 per accepted unit'), findsOneWidget, reason: 'currency comes from the batch');
    expect(find.text('Rubric v2'), findsOneWidget, reason: 'the batch rubric wins over the unit copy');
    expect(find.text('Judged against rubric v2. Only an accepted unit creates an earning.'), findsOneWidget);
    expect(find.text('What you are given'), findsOneWidget);
    expect(find.text('Stop sign at 5th'), findsOneWidget);
    expect(find.textContaining('"lang": "en"'), findsOneWidget, reason: 'nested payload is pretty-printed');
    expect(find.textContaining('Expires in 1:59:'), findsOneWidget);

    expect(find.text('Sign label *'), findsOneWidget, reason: 'title used as label, required marked');
    expect(find.text('What the sign says'), findsOneWidget, reason: 'description used as helper');
    expect(find.byKey(const Key('field-label')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('field-notes'))).maxLines, 5, reason: 'textarea is multiline');
    expect(find.byKey(const Key('field-sentiment')), findsOneWidget);
    expect(tester.widget(find.byKey(const Key('field-sentiment'))), isA<SegmentedButton<String>>(), reason: '3 options');
    expect(find.text('Positive'), findsOneWidget);
    expect(tester.widget(find.byKey(const Key('field-language'))), isA<DropdownButtonFormField<String>>(), reason: '6 options');
    expect(find.byKey(const Key('field-score')), findsOneWidget);
    expect(find.byKey(const Key('field-count')), findsOneWidget);
    expect(tester.widget(find.byKey(const Key('field-legible'))), isA<SwitchListTile>());
    expect(find.text('Legible'), findsOneWidget);
    expect(find.byKey(const Key('raw-toggle')), findsNothing, reason: 'no raw JSON when a schema drives the form');
    await expectAccessible(tester);
  });

  testWidgets('missing required fields block the submit with inline messages', (tester) async {
    final backend = FakeBackend({'POST /v1/claims/c1/submission': (_) => json(submitted(), status: 201)});
    await openWork(tester, backend);
    await tester.enterText(find.byKey(const Key('field-score')), 'high');
    await tester.tap(find.byKey(const Key('submit')));
    await tester.pumpAndSettle();

    expect(find.text('Required'), findsNWidgets(2), reason: 'label and sentiment are empty');
    expect(find.text('Enter a number'), findsOneWidget);
    expect(find.text('Fix the 3 highlighted fields before you submit.'), findsOneWidget);
    expect(backend.sent('POST', '/v1/claims/c1/submission'), isEmpty);
  });

  testWidgets('a good submit posts the typed answer with one idempotency key and pops after the dialog', (tester) async {
    final backend = FakeBackend({'POST /v1/claims/c1/submission': (_) => json(submitted(), status: 201)});
    await openWork(tester, backend);

    await tester.enterText(find.byKey(const Key('field-label')), 'STOP');
    await tester.tap(find.text('Negative'));
    await tester.enterText(find.byKey(const Key('field-score')), '0.75');
    await tester.enterText(find.byKey(const Key('field-count')), '4');
    await tester.tap(find.byKey(const Key('field-legible')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('submit')));
    await tester.pumpAndSettle();

    final answer = answerOf(backend);
    expect(answer, {'label': 'STOP', 'sentiment': 'negative', 'score': 0.75, 'count': 4, 'legible': true});
    expect(answer['score'], isA<double>());
    expect(answer['count'], isA<int>());
    expect(answer.containsKey('notes'), isFalse, reason: 'an empty optional field is left out');
    expect(answer.containsKey('language'), isFalse);
    final keys = backend.sent('POST', '/v1/claims/c1/submission').map((r) => r.headers['Idempotency-Key']).toList();
    expect(keys.single, isNotNull);

    expect(find.text('Submitted · rubric v2'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(WorkScreen), findsNothing, reason: 'back where the worker came from');
  });

  testWidgets('a failed submit keeps the same key on retry', (tester) async {
    var calls = 0;
    final backend = FakeBackend({
      'POST /v1/claims/c1/submission': (_) => ++calls == 1
          ? envelope(503, 'upstream_unavailable', message: 'try again shortly', headers: {'retry-after': '2'})
          : json(submitted(), status: 201),
    });
    await openWork(tester, backend, batchJson: batch(withSchema: false));
    await tester.enterText(find.byKey(const Key('answer-key-0')), 'label');
    await tester.enterText(find.byKey(const Key('answer-value-0')), 'stop');
    await tester.tap(find.byKey(const Key('submit')));
    await tester.pumpAndSettle();
    expect(find.text('Service is away. Retry in 2s.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('submit')));
    await tester.pumpAndSettle();
    expect(find.text('Submitted · rubric v2'), findsOneWidget);
    final keys = backend.sent('POST', '/v1/claims/c1/submission').map((r) => r.headers['Idempotency-Key']).toList();
    expect(keys, hasLength(2));
    expect(keys[0], keys[1], reason: 'a retry of the same action reuses the key');
  });

  testWidgets('without a schema the key/value rows and the raw JSON toggle still work', (tester) async {
    final backend = FakeBackend({'POST /v1/claims/c1/submission': (_) => json(submitted(), status: 201)});
    await openWork(tester, backend, batchJson: batch(withSchema: false));
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(tester.getSemantics(find.byKey(const Key('raw-toggle'))).label, 'Raw JSON', reason: 'the switch is announced by its label');
    semantics.dispose();

    await tester.enterText(find.byKey(const Key('answer-key-0')), 'label');
    await tester.enterText(find.byKey(const Key('answer-value-0')), 'stop');
    await tester.tap(find.byKey(const Key('add-field')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('answer-key-1')), 'confidence');
    await tester.enterText(find.byKey(const Key('answer-value-1')), 'high');

    await tester.tap(find.byKey(const Key('raw-toggle')));
    await tester.pumpAndSettle();
    expect(find.textContaining('"confidence": "high"'), findsOneWidget, reason: 'rows carry over into raw JSON');
    await tester.enterText(find.byKey(const Key('raw-answer')), '{"n": 3, "tags": ["a"]');
    await tester.tap(find.byKey(const Key('submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('not valid JSON'), findsOneWidget);
    expect(backend.sent('POST', '/v1/claims/c1/submission'), isEmpty);

    await tester.enterText(find.byKey(const Key('raw-answer')), '{"n": 3, "tags": ["a"]}');
    await tester.tap(find.byKey(const Key('submit')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/claims/c1/submission').single.body, '{"answer":{"n":3,"tags":["a"]}}');
  });

  testWidgets('an expired claim disables Submit and says so', (tester) async {
    final backend = FakeBackend();
    await openWork(tester, backend, claimJson: claim(expires: '2020-01-01T00:00:00Z'));
    expect(find.text('Expired'), findsOneWidget);
    expect(find.text('Claim expired'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('submit'))).onPressed, isNull);
  });

  testWidgets('a 422 from the gateway shows its message; a 409 claim_expired is explained', (tester) async {
    var calls = 0;
    final backend = FakeBackend({
      'POST /v1/claims/c1/submission': (_) => ++calls == 1
          ? envelope(422, 'invalid', message: "answer: label: 'STOP' is too long")
          : envelope(409, 'claim_expired', message: 'claim is not live'),
    });
    await openWork(tester, backend);
    await tester.enterText(find.byKey(const Key('field-label')), 'STOP');
    await tester.tap(find.text('Neutral'));
    await tester.enterText(find.byKey(const Key('field-score')), '1');
    await tester.tap(find.byKey(const Key('submit')));
    await tester.pumpAndSettle();
    expect(find.text("Some answers don't match what this unit asks for: label"), findsOneWidget);
    expect(find.textContaining('is too long'), findsNothing, reason: 'validator text is for logs');

    await tester.tap(find.byKey(const Key('submit')));
    await tester.pumpAndSettle();
    expect(find.text('This claim expired before you submitted. Claim another unit.'), findsOneWidget);
    expect(find.byKey(const Key('claim-not-live')), findsOneWidget, reason: 'the worker reads the message before leaving');
    final keys = backend.sent('POST', '/v1/claims/c1/submission').map((r) => r.headers['Idempotency-Key']).toList();
    expect(keys, hasLength(2));
    expect(keys[0], isNot(keys[1]), reason: 'a corrected answer after a 422 is a new action, so a new key');
  });

  testWidgets('on a phone the countdown and Submit sit in a sticky bottom bar', (tester) async {
    final backend = FakeBackend({'POST /v1/claims/c1/submission': (_) => json(submitted(), status: 201)});
    await openWork(tester, backend, size: const Size(390, 844));
    expect(find.byKey(const Key('countdown')), findsOneWidget);
    expect(find.byKey(const Key('submit')), findsOneWidget);
    final bar = tester.getRect(find.byKey(const Key('submit')));
    expect(bar.bottom, lessThanOrEqualTo(844));
    expect(bar.top, greaterThan(700), reason: 'pinned at the bottom of the viewport');
    expect(find.byKey(const Key('back')), findsOneWidget);
  });

  testWidgets('leaving with a typed answer asks; Stay keeps the page, Leave keeps the draft on the device', (tester) async {
    final backend = FakeBackend();
    final harness = await openWork(tester, backend, batchJson: batch(withSchema: false));
    await tester.tap(find.byKey(const Key('back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('leave-confirm')), findsNothing, reason: 'nothing typed: back needs no question');
    expect(find.byType(WorkScreen), findsNothing);

    await goTo(
      tester,
      '/work/home/unit/c1',
      extra: ActiveWork(claim: Claim.fromJson(claim()), unit: Unit.fromJson(unit), batch: Batch.fromJson(batch(withSchema: false))),
    );
    await tester.enterText(find.byKey(const Key('answer-key-0')), 'label');
    await tester.enterText(find.byKey(const Key('answer-value-0')), 'stop');
    await tester.pump(const Duration(seconds: 1));
    expect(harness.drafts.drafts['yantra.draft.unit.c1'], {
      'rows': [
        ['label', 'stop'],
      ],
    });
    await tester.tap(find.byKey(const Key('back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('leave-stay')));
    await tester.pumpAndSettle();
    expect(find.byType(WorkScreen), findsOneWidget);
    await goTo(tester, '/work/my-work');
    expect(find.byKey(const Key('leave-confirm')), findsOneWidget, reason: 'a link away asks the same question');
    await tester.tap(find.byKey(const Key('leave-confirm')));
    await tester.pumpAndSettle();
    expect(find.byType(WorkScreen), findsNothing);
    expect(harness.drafts.drafts.containsKey('yantra.draft.unit.c1'), isTrue);

    await goTo(
      tester,
      '/work/home/unit/c1',
      extra: ActiveWork(claim: Claim.fromJson(claim()), unit: Unit.fromJson(unit), batch: Batch.fromJson(batch(withSchema: false))),
    );
    // the Home branch kept the page alive under My work: it comes back as it was
    expect(tester.widget<TextField>(find.byKey(const Key('answer-value-0'))).controller!.text, 'stop');
  });

  testWidgets('a schema draft and a raw draft come back too', (tester) async {
    final backend = FakeBackend();
    final harness = TestHarness(backend, tokens: liveTokens());
    await harness.drafts.write('yantra.draft.unit.c1', {
      'schema': {
        'label': {'text': 'STOP', 'choice': null, 'flag': false},
        'sentiment': {'text': '', 'choice': 'neutral', 'flag': false},
        'legible': {'text': '', 'choice': null, 'flag': true},
        'ghost': {'text': 'x'},
      },
    });
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    backend.routes['GET /v1/claims/active'] = (_) => json({'claim': claim(), 'unit': unit, 'batch': batch()});
    backend.routes['GET /v1/batches'] = (_) => json([]);
    await tester.pumpWidget(harness.app);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpAndSettle();
    await goTo(tester, '/work/home/unit/c1');
    expect(find.text('Your draft from this device is back'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('field-label'))).controller!.text, 'STOP');

    await goTo(tester, '/work/home');
    await tester.tap(find.byKey(const Key('leave-confirm')));
    await tester.pumpAndSettle();
    await harness.drafts.write('yantra.draft.unit.c1', {'raw': '{"a": 1}'});
    backend.routes['GET /v1/claims/active'] = (_) => json({'claim': claim(), 'unit': unit, 'batch': batch(withSchema: false)});
    await goTo(tester, '/work/home/unit/c1');
    expect(find.byKey(const Key('raw-answer')), findsOneWidget);
  });

  testWidgets('Release claim confirms, posts with a key, drops the draft and leaves', (tester) async {
    final backend = FakeBackend({'POST /v1/claims/c1/release': (_) => json(claim())});
    final harness = await openWork(tester, backend, batchJson: batch(withSchema: false));
    await tester.enterText(find.byKey(const Key('answer-key-0')), 'label');
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('release-claim')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Release claim').last);
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/claims/c1/release').single.headers['Idempotency-Key'], isNotEmpty);
    expect(harness.drafts.drafts.keys.where((k) => k.startsWith('yantra.draft.')), isEmpty);
    expect(find.byType(WorkScreen), findsNothing);
    expect(find.text('Claim released'), findsOneWidget);
  });

  testWidgets('a refused release shows why and keeps the page; Release from the leave question leaves', (tester) async {
    var refuse = true;
    final backend = FakeBackend({
      'POST /v1/claims/c1/release': (_) => refuse ? envelope(409, 'claim_not_live', message: 'The claim is no longer live') : json(claim()),
    });
    await openWork(tester, backend, batchJson: batch(withSchema: false));
    await tester.tap(find.byKey(const Key('release-claim')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Release claim').last);
    await tester.pumpAndSettle();
    expect(find.text('This claim is no longer live: it was submitted, released or it expired.'), findsOneWidget);
    expect(find.byType(WorkScreen), findsOneWidget);

    refuse = false;
    await tester.enterText(find.byKey(const Key('answer-key-0')), 'label');
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('leave-release')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/claims/c1/release'), hasLength(2));
    expect(find.byType(WorkScreen), findsNothing);
  });

  testWidgets('a link to a claim that is no longer live says so and offers Home; a live one opens', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json({'claim': null, 'unit': null}),
      'GET /v1/batches': (_) => json([]),
    });
    await pumpApp(tester, backend, at: '/work/home/unit/gone');
    expect(find.byKey(const Key('claim-not-live')), findsOneWidget);
    await tester.tap(find.byKey(const Key('claim-not-live-home')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/work/home');

    backend.routes['GET /v1/claims/active'] = (_) => json({'claim': claim(), 'unit': unit, 'batch': batch()});
    await goTo(tester, '/work/home/unit/c1');
    expect(find.byType(WorkScreen), findsOneWidget);
  });

  testWidgets('a failed read of the live claim offers Retry', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) =>
          fail ? envelope(503, 'upstream_unavailable') : json({'claim': claim(), 'unit': unit, 'batch': batch()}),
      'GET /v1/batches': (_) => json([]),
    });
    await pumpApp(tester, backend, at: '/work/home/unit/c1');
    final retry = find.descendant(of: find.byType(DetailFrame), matching: find.text('Retry'));
    expect(retry, findsOneWidget);
    fail = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(find.byType(WorkScreen), findsOneWidget);
  });

  testWidgets('an open claim starts a tracking session, records samples, and ends it on submit', (tester) async {
    final backend = FakeBackend({
      'POST /v1/tracker/sessions': (_) => json({'id': 'ts1'}, status: 201),
      'POST /v1/tracker/sessions/ts1/samples': (_) => json({
        'week': {'active_seconds': 30, 'idle_seconds': 0, 'cap_hours': '40', 'cap_source': 'default', 'over_cap': false},
      }),
      'POST /v1/tracker/sessions/ts1/end': (_) => json({'id': 'ts1'}),
      'POST /v1/claims/c1/submission': (_) => json(submitted(), status: 201),
    });
    await openWork(tester, backend, batchJson: batch(withSchema: false));
    await tester.pump();
    final start = jsonDecode(backend.sent('POST', '/v1/tracker/sessions').single.body);
    expect(start['claim_id'], 'c1');
    expect(start['source'], 'web');
    expect(find.byKey(const Key('tracking-note')), findsOneWidget);
    await tester.tap(find.byKey(const Key('answer-key-0')));
    await tester.pump(const Duration(seconds: 30));
    final sample = jsonDecode(backend.sent('POST', '/v1/tracker/sessions/ts1/samples').single.body);
    expect((sample['samples'] as List).single['kind'], 'active');
    await tester.enterText(find.byKey(const Key('answer-key-0')), 'label');
    await tester.enterText(find.byKey(const Key('answer-value-0')), 'stop');
    await tester.tap(find.byKey(const Key('submit')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/tracker/sessions/ts1/end'), hasLength(1));
  });

  testWidgets('a tracker that refuses for withdrawn consent turns the note to "tracking is off"; the work goes on', (tester) async {
    final backend = FakeBackend({'POST /v1/tracker/sessions': (_) => envelope(403, 'consent_withdrawn')});
    await openWork(tester, backend, batchJson: batch(withSchema: false));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('tracking-off')), findsOneWidget);
    expect(find.text('Tracking is off: you withdrew your data consent.'), findsOneWidget);
    expect(find.text('Activity is recorded while you work.'), findsNothing);
    await tester.pump(const Duration(seconds: 61));
    expect(backend.sent('POST', '/v1/tracker/sessions'), hasLength(1));
    expect(find.byKey(const Key('submit')), findsOneWidget);
  });

  testWidgets('a hidden tab is recorded as away; the tracker being down never blocks the work', (tester) async {
    final backend = FakeBackend({
      'POST /v1/tracker/sessions': (_) => json({'id': 'ts1'}, status: 201),
      'POST /v1/tracker/sessions/ts1/samples': (_) => envelope(503, 'unavailable'),
    });
    await openWork(tester, backend, batchJson: batch(withSchema: false));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump(const Duration(seconds: 30));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final sent = backend.sent('POST', '/v1/tracker/sessions/ts1/samples');
    expect(sent, isNotEmpty);
    expect((jsonDecode(sent.first.body)['samples'] as List).first['kind'], 'focus_lost');
    expect(find.byKey(const Key('submit')), findsOneWidget);
  });

  testWidgets('What we track opens the tracking policy beside the work, served copy first', (tester) async {
    final backend = FakeBackend({
      'GET /v1/tracker/policy': (_) => json({
        'slug': 'tracking',
        'title': 'What we track while you work',
        'summary': 'Only while a claim is open on your screen.',
        'version': '1',
        'sections': [
          {
            'title': 'What is collected',
            'bullets': ['Active, idle or away every 30 seconds.'],
          },
        ],
      }),
    });
    await openWork(tester, backend, batchJson: batch(withSchema: false));
    await tester.tap(find.byKey(const Key('tracking-policy')));
    await tester.pumpAndSettle();
    expect(find.text('What we track while you work'), findsOneWidget);
    expect(find.text('Active, idle or away every 30 seconds.'), findsOneWidget);
  });

  testWidgets('releasing the claim ends the tracking session', (tester) async {
    final backend = FakeBackend({
      'POST /v1/tracker/sessions': (_) => json({'id': 'ts1'}, status: 201),
      'POST /v1/tracker/sessions/ts1/end': (_) => json({'id': 'ts1'}),
      'POST /v1/claims/c1/release': (_) => json(claim()),
    });
    await openWork(tester, backend, batchJson: batch(withSchema: false));
    await tester.pump();
    await tester.tap(find.byKey(const Key('release-claim')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Release claim').last);
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/tracker/sessions/ts1/end'), hasLength(1));
  });

  testWidgets('the work screen passes the checks on a phone and renders in dark mode', (tester) async {
    final backend = FakeBackend();
    await openWork(tester, backend, batchJson: batch(withSchema: false), size: const Size(390, 2400));
    await expectAccessible(tester);
    await tester.pumpWidget(const SizedBox());
    backend.routes['GET /v1/claims/active'] = (_) => json({'claim': null, 'unit': null});
    await pumpApp(tester, backend, dark: true);
    await goTo(
      tester,
      '/work/home/unit/c1',
      extra: ActiveWork(claim: Claim.fromJson(claim()), unit: Unit.fromJson(unit), batch: Batch.fromJson(batch(withSchema: false))),
    );
    await expectRendersDark(tester);
  });

  group('leaving because the session ended', () {
    for (final (how, end) in [
      ('signing out', (TestHarness h) => h.session.logout()),
      ('the session expiring', (TestHarness h) => h.session.authLost()),
    ]) {
      testWidgets('$how with a typed answer lands on sign-in with no question, and the draft stays', (tester) async {
        final backend = FakeBackend();
        final harness = await openWork(tester, backend, batchJson: batch(withSchema: false));
        await tester.enterText(find.byKey(const Key('answer-key-0')), 'label');
        await tester.enterText(find.byKey(const Key('answer-value-0')), 'sto');
        await tester.pump(const Duration(seconds: 1));
        await tester.enterText(find.byKey(const Key('answer-value-0')), 'stop');
        await end(harness);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('leave-confirm')), findsNothing, reason: 'no question for a signed-out person');
        expect(currentLocation(tester), '/login');
        expect(harness.drafts.drafts['yantra.draft.unit.c1'], {
          'rows': [
            ['label', 'stop'],
          ],
        }, reason: 'the last keystrokes are kept too');
      });
    }
  });

  group('the claim\'s clock is the server\'s', () {
    testWidgets('a device five minutes fast keeps Submit open while the server says time is left', (tester) async {
      final backend = FakeBackend()..serverSkew = const Duration(minutes: -5);
      final expires = DateTime.now().subtract(const Duration(seconds: 1)).toUtc().toIso8601String();
      await openWork(tester, backend, claimJson: claim(expires: expires));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Expires in 04:5'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('submit'))).onPressed, isNotNull);
    });

    testWidgets('a device five minutes slow closes Submit and stops tracking at the server\'s expiry', (tester) async {
      final backend = FakeBackend({
        'POST /v1/tracker/sessions': (_) => json({'id': 'ts1'}, status: 201),
        'POST /v1/tracker/sessions/ts1/end': (_) => json({'id': 'ts1'}),
      })..serverSkew = const Duration(minutes: 5);
      final expires = DateTime.now().add(const Duration(minutes: 4, seconds: 59)).toUtc().toIso8601String();
      await openWork(tester, backend, claimJson: claim(expires: expires));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Claim expired'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('submit'))).onPressed, isNull);
      expect(backend.sent('POST', '/v1/tracker/sessions'), isEmpty, reason: 'an expired claim is not tracked');
    });
  });

  testWidgets('an answer edited after a 5xx goes out under a new key', (tester) async {
    final backend = FakeBackend({'POST /v1/claims/c1/submission': (_) => envelope(503, 'upstream_unavailable')});
    await openWork(tester, backend, batchJson: batch(withSchema: false));
    await tester.enterText(find.byKey(const Key('answer-key-0')), 'label');
    await tester.enterText(find.byKey(const Key('answer-value-0')), 'stop');
    await tester.tap(find.byKey(const Key('submit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('answer-value-0')), 'STOP');
    await tester.tap(find.byKey(const Key('submit')));
    await tester.pumpAndSettle();
    final keys = backend.sent('POST', '/v1/claims/c1/submission').map((r) => r.headers['Idempotency-Key']).toList();
    expect(keys, hasLength(2));
    expect(keys[1], isNot(keys[0]), reason: 'a different body under the old key would be refused as a mismatch');
  });

  for (final (code, status) in [('claim_not_live', 409), ('conflict', 409), ('not_found', 404)]) {
    testWidgets('a submit refused with $status $code shows that the claim is no longer live, drops the draft and stops tracking', (
      tester,
    ) async {
      final backend = FakeBackend({
        'POST /v1/tracker/sessions': (_) => json({'id': 'ts1'}, status: 201),
        'POST /v1/tracker/sessions/ts1/end': (_) => json({'id': 'ts1'}),
        'POST /v1/claims/c1/submission': (_) => envelope(status, code, message: 'claim is not live'),
      });
      final harness = await openWork(tester, backend, batchJson: batch(withSchema: false));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('answer-key-0')), 'label');
      await tester.enterText(find.byKey(const Key('answer-value-0')), 'stop');
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('claim-not-live')), findsOneWidget);
      expect(backend.sent('GET', '/v1/claims/active'), isNotEmpty, reason: 'the server confirms the claim is gone first');
      expect(harness.drafts.drafts.containsKey('yantra.draft.unit.c1'), isFalse);
      expect(backend.sent('POST', '/v1/tracker/sessions/ts1/end'), hasLength(1));
      await tester.tap(find.byKey(const Key('claim-not-live-home')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('leave-confirm')), findsNothing, reason: 'nothing left to lose');
    });
  }

  testWidgets('a 409 while the claim is still live (or a request still in flight) keeps the form and the draft', (tester) async {
    var code = 'request_in_flight';
    final backend = FakeBackend({'POST /v1/claims/c1/submission': (_) => envelope(409, code)});
    final harness = await openWork(tester, backend, batchJson: batch(withSchema: false));
    backend.routes['GET /v1/claims/active'] = (_) => json({'claim': claim(), 'unit': unit, 'batch': batch(withSchema: false)});
    await tester.enterText(find.byKey(const Key('answer-key-0')), 'label');
    await tester.enterText(find.byKey(const Key('answer-value-0')), 'stop');
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('still being processed'), findsOneWidget);
    expect(find.byKey(const Key('claim-not-live')), findsNothing);
    code = 'conflict';
    await tester.tap(find.byKey(const Key('submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('claim-not-live')), findsNothing, reason: 'the server still lists the claim as live');
    expect(harness.drafts.drafts.containsKey('yantra.draft.unit.c1'), isTrue);
    expect(find.byKey(const Key('submit')), findsOneWidget);
  });

  testWidgets('a moment of inactive (a dialog, the tab strip) is not away; hidden is', (tester) async {
    final backend = FakeBackend({
      'POST /v1/tracker/sessions': (_) => json({'id': 'ts1'}, status: 201),
      'POST /v1/tracker/sessions/ts1/samples': (_) => json({
        'week': {'active_seconds': 30, 'idle_seconds': 0, 'cap_hours': '40', 'cap_source': 'default', 'over_cap': false},
      }),
    });
    await openWork(tester, backend, batchJson: batch(withSchema: false));
    await tester.pump();
    await tester.tap(find.byKey(const Key('answer-key-0')));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 30));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final sent = backend.sent('POST', '/v1/tracker/sessions/ts1/samples');
    expect((jsonDecode(sent.single.body)['samples'] as List).single['kind'], 'active');
  });

  testWidgets('the Submitted dialog names the unit, not the submission id', (tester) async {
    final backend = FakeBackend({
      'POST /v1/claims/c1/submission': (_) => json({...submitted(), 'id': '5b1c0e7a-0000-4000-8000-00000000abcd'}, status: 201),
    });
    await openWork(tester, backend, batchJson: batch(withSchema: false));
    await tester.enterText(find.byKey(const Key('answer-key-0')), 'label');
    await tester.enterText(find.byKey(const Key('answer-value-0')), 'stop');
    await tester.tap(find.byKey(const Key('submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('5b1c0e7a'), findsNothing);
    expect(find.textContaining('Unit row-17 is in the review queue'), findsOneWidget);
  });
}
