import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:yantra_app/api/gateway_client.dart';
import 'package:yantra_app/api/tracker_models.dart';
import 'package:yantra_app/api/tracker_repository.dart';
import 'package:yantra_app/core/activity_agent.dart';
import 'package:yantra_app/core/drafts.dart';

import '../api/gateway_client_test.dart' show ScriptedTokens;
import '../support/fake_backend.dart';

const week = {
  'starts_at': '2026-11-02T00:00:00+05:30',
  'ends_at': '2026-11-09T00:00:00+05:30',
  'active_seconds': 3600,
  'idle_seconds': 60,
  'cap_hours': '40.00',
  'cap_source': 'default',
  'over_cap': false,
};

class Clock {
  DateTime now = DateTime.utc(2026, 11, 4, 10);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  late FakeBackend backend;
  late Clock clock;
  late MemoryDraftStore store;
  var ids = 0;

  ActivityAgent agent({void Function(TrackerWeek)? onWeek}) => ActivityAgent(
    tracker: TrackerRepository(
      GatewayClient(client: backend.client, tokens: ScriptedTokens(), baseUrl: 'http://gateway.test/', sleep: (_) async {}),
    ),
    claimId: 'c1',
    devices: store,
    now: clock.call,
    newKey: () => 'key-${++ids}-abcdefgh',
    onWeek: onWeek,
  );

  List<Map<String, dynamic>> sampled() => [
    for (final r in backend.sent('POST', '/v1/tracker/sessions/s1/samples'))
      for (final s in (jsonDecode(r.body)['samples'] as List)) Map<String, dynamic>.from(s as Map),
  ];

  setUp(() {
    ids = 0;
    clock = Clock();
    store = MemoryDraftStore();
    backend = FakeBackend({
      'POST /v1/tracker/sessions': (_) => json({'id': 's1'}, status: 201),
      'POST /v1/tracker/sessions/s1/samples': (_) => json({'accepted': 1, 'duplicates': 0, 'over_cap': false, 'week': week}),
      'POST /v1/tracker/sessions/s1/end': (_) => json({'id': 's1'}),
    });
  });

  test('starts a session for the claim with a device id it keeps in the browser', () async {
    final a = agent();
    await a.start();
    a.dispose();
    final body = jsonDecode(backend.sent('POST', '/v1/tracker/sessions').single.body);
    expect(body, {'claim_id': 'c1', 'source': 'web', 'device_hash': 'key-1-abcdefgh'});
    expect((await store.read(ActivityAgent.deviceKey))?['id'], 'key-1-abcdefgh');
    // a second agent in the same browser reuses the id
    final b = agent();
    await b.start();
    b.dispose();
    expect(jsonDecode(backend.sent('POST', '/v1/tracker/sessions').last.body)['device_hash'], 'key-1-abcdefgh');
  });

  test('a session already open is reused instead of failing', () async {
    backend.routes['POST /v1/tracker/sessions'] = (_) => envelope(409, 'session_open', context: {'session_id': 's1'});
    final a = agent();
    await a.start();
    a.dispose();
    expect(a.session, 's1');
  });

  test('samples say active, idle or away, and the flush key is session plus the first sample time', () async {
    TrackerWeek? seen;
    final a = agent(onWeek: (w) => seen = w);
    await a.start();
    clock.advance(const Duration(seconds: 30));
    await a.tick(); // input at start, 30 s ago: active
    clock.advance(const Duration(seconds: 61));
    await a.tick(); // no input for 91 s: idle
    a.input();
    a.visible(false);
    clock.advance(const Duration(seconds: 30));
    await a.tick(); // hidden: away
    a.dispose();
    expect([for (final s in sampled()) s['kind']], ['active', 'idle', 'focus_lost']);
    expect(sampled().first['label'], 'yantra-web');
    final first = backend.sent('POST', '/v1/tracker/sessions/s1/samples').first;
    expect(first.headers['Idempotency-Key'], 's1:2026-11-04T10:00:30.000Z');
    expect(seen?.activeSeconds, 3600);
    expect(seen?.capHours, 40);
    expect(a.pending, 0);
  });

  test('a failed flush is retried with the exact same body and key; newer samples wait for their own flush', () async {
    var down = true;
    backend.routes['POST /v1/tracker/sessions/s1/samples'] = (_) =>
        down ? http.Response('{"code":"unavailable","message":"down"}', 503) : json({'week': week});
    final a = agent();
    await a.start();
    await a.tick();
    expect(a.pending, 1);
    down = false;
    clock.advance(const Duration(seconds: 30));
    await a.tick();
    a.dispose();
    expect(a.pending, 0);
    final sent = backend.sent('POST', '/v1/tracker/sessions/s1/samples');
    expect(sent, hasLength(3));
    expect(sent[1].body, sent[0].body, reason: 'the frozen batch did not grow');
    expect(sent[1].headers['Idempotency-Key'], sent[0].headers['Idempotency-Key']);
    expect((jsonDecode(sent[2].body)['samples'] as List).length, 1, reason: 'the newer sample went on its own');
    expect(sent[2].headers['Idempotency-Key'], isNot(sent[0].headers['Idempotency-Key']));
  });

  test('a sample out of range is dropped alone and the rest are sent again under a new key', () async {
    var up = false;
    backend.routes['POST /v1/tracker/sessions'] = (_) => up ? json({'id': 's1'}, status: 201) : http.Response('down', 503);
    var refused = false;
    backend.routes['POST /v1/tracker/sessions/s1/samples'] = (_) {
      if (refused) return json({'week': week});
      refused = true;
      return envelope(422, 'sample_out_of_range', context: {'index': 1});
    };
    final a = agent();
    await a.start();
    for (var i = 0; i < 3; i++) {
      clock.advance(const Duration(seconds: 30));
      await a.tick(); // no session yet: the samples wait
    }
    up = true;
    await a.flush();
    a.dispose();
    final sent = backend.sent('POST', '/v1/tracker/sessions/s1/samples');
    expect(sent, hasLength(2));
    final first = [for (final x in jsonDecode(sent[0].body)['samples'] as List) (x as Map)['at']];
    final second = [for (final x in jsonDecode(sent[1].body)['samples'] as List) (x as Map)['at']];
    expect(first, hasLength(3));
    expect(second, [first[0], first[2]], reason: 'only the sample at index 1 is dropped');
    expect(sent[1].headers['Idempotency-Key'], isNot(sent[0].headers['Idempotency-Key']), reason: 'a new body needs a new key');
    expect(a.pending, 0);
  });

  test('an idempotency mismatch re-keys the batch and never drops it', () async {
    var first = true;
    backend.routes['POST /v1/tracker/sessions/s1/samples'] = (_) {
      if (first) {
        first = false;
        return envelope(422, 'idempotency_mismatch');
      }
      return json({'week': week});
    };
    final a = agent();
    await a.start();
    await a.tick();
    a.dispose();
    final sent = backend.sent('POST', '/v1/tracker/sessions/s1/samples');
    expect(sent, hasLength(2));
    expect(sent[1].body, sent[0].body);
    expect(sent[1].headers['Idempotency-Key'], isNot(sent[0].headers['Idempotency-Key']));
    expect(a.pending, 0);
  });

  test('an ended session is replaced and only samples older than the new session are dropped', () async {
    backend.routes['POST /v1/tracker/sessions/s1/samples'] = (_) => envelope(409, 'session_ended');
    final a = agent();
    await a.start();
    await a.tick(); // 10:00:00, sent to s1 and refused: session ended
    expect(a.pending, 1);
    backend.routes['POST /v1/tracker/sessions'] = (_) => json({'id': 's2', 'started_at': '2026-11-04T10:00:45Z'}, status: 201);
    backend.routes['POST /v1/tracker/sessions/s2/samples'] = (_) => json({'week': week});
    clock.advance(const Duration(seconds: 30));
    a.visible(true);
    // 10:00:30 is recorded, then s2 starts at 10:00:45: both older samples go; a later one is kept
    backend.routes['POST /v1/tracker/sessions/s1/samples'] = (_) => envelope(409, 'session_ended');
    await a.tick();
    expect(a.session, 's2');
    clock.advance(const Duration(seconds: 30));
    await a.tick(); // 10:01:00
    a.dispose();
    final sent = [
      for (final r in backend.sent('POST', '/v1/tracker/sessions/s2/samples'))
        ...(jsonDecode(r.body)['samples'] as List).map((s) => (s as Map)['at']),
    ];
    expect(sent, ['2026-11-04T10:01:00.000Z']);
    expect(a.pending, 0);
  });

  test('ending while the session is still starting waits for it, ends it and stops the clock', () async {
    final gate = Completer<void>();
    var ticks = 0;
    backend = FakeBackend({
      'POST /v1/tracker/sessions/s1/end': (_) => json({'id': 's1'}),
      'POST /v1/tracker/sessions/s1/samples': (_) {
        ticks++;
        return json({'week': week});
      },
    });
    final slow = _SlowStart(backend, gate.future);
    final a = ActivityAgent(
      tracker: slow,
      claimId: 'c1',
      devices: store,
      now: clock.call,
      newKey: () => 'key-x-abcdefgh',
      every: const Duration(milliseconds: 10),
    );
    final started = a.start();
    final ended = a.end();
    gate.complete();
    await started;
    await ended;
    expect(backend.sent('POST', '/v1/tracker/sessions/s1/end'), hasLength(1), reason: 'the session the start opened is closed');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(ticks, 0, reason: 'no clock left running');
  });

  test('a tracker that cannot start a session never stops the work, and retries on the next tick', () async {
    var refuse = true;
    backend.routes['POST /v1/tracker/sessions'] = (_) =>
        refuse ? http.Response('{"code":"unavailable","message":"down"}', 503) : json({'id': 's1'}, status: 201);
    final a = agent();
    await a.start();
    expect(a.session, isNull);
    await a.tick();
    expect(a.pending, 1);
    refuse = false;
    await a.tick();
    a.dispose();
    expect(a.session, 's1');
    expect(a.pending, 0);
  });

  test('a worker who withdrew consent is refused a session: the agent stops quietly and says tracking is off', () async {
    backend.routes['POST /v1/tracker/sessions'] = (_) => envelope(403, 'consent_withdrawn');
    var told = 0;
    final a = ActivityAgent(
      tracker: TrackerRepository(
        GatewayClient(client: backend.client, tokens: ScriptedTokens(), baseUrl: 'http://gateway.test/', sleep: (_) async {}),
      ),
      claimId: 'c1',
      devices: store,
      now: clock.call,
      newKey: () => 'key-${++ids}-abcdefgh',
      onTrackingOff: () => told++,
    );
    await a.start();
    expect(a.trackingOff, isTrue);
    expect(told, 1);
    await a.tick();
    await a.tick();
    await a.end();
    expect(backend.sent('POST', '/v1/tracker/sessions'), hasLength(1), reason: 'no retry once consent is withdrawn');
    expect(a.pending, 0, reason: 'nothing is recorded');
  });

  test('samples refused for withdrawn consent stop the agent; the tracker already ended the session', () async {
    backend.routes['POST /v1/tracker/sessions/s1/samples'] = (_) => envelope(403, 'consent_withdrawn');
    final a = agent();
    await a.start();
    await a.tick();
    expect(a.trackingOff, isTrue);
    await a.tick();
    await a.end();
    expect(backend.sent('POST', '/v1/tracker/sessions/s1/samples'), hasLength(1));
    expect(backend.sent('POST', '/v1/tracker/sessions/s1/end'), isEmpty);
    expect(a.pending, 0);
  });

  test('an ended session is replaced; a refusal without an index drops that batch', () async {
    var ended = true;
    backend.routes['POST /v1/tracker/sessions/s1/samples'] = (_) =>
        ended ? envelope(409, 'session_ended') : envelope(422, 'sample_out_of_range');
    final a = agent();
    await a.start();
    await a.tick();
    expect(a.session, isNull, reason: 'a new session starts on the next tick');
    expect(a.pending, 1);
    ended = false;
    await a.tick();
    a.dispose();
    expect(a.pending, 0);
    expect(backend.sent('POST', '/v1/tracker/sessions').length, 2);
  });

  test('end flushes what is left, ends the session once, and stops the clock', () async {
    final a = agent();
    await a.start();
    a.input();
    clock.advance(const Duration(seconds: 10));
    await a.tick();
    await a.end();
    await a.end();
    await a.tick();
    expect(backend.sent('POST', '/v1/tracker/sessions/s1/end').length, 1);
    expect(sampled().length, 1);
  });

  test('ending without a session or with the tracker down is quiet', () async {
    backend.routes['POST /v1/tracker/sessions'] = (_) => http.Response('down', 503);
    final a = agent();
    await a.start();
    await a.end();
    expect(backend.sent('POST', '/v1/tracker/sessions/s1/end'), isEmpty);
    backend.routes['POST /v1/tracker/sessions'] = (_) => json({'id': 's1'}, status: 201);
    backend.routes['POST /v1/tracker/sessions/s1/end'] = (_) => http.Response('down', 503);
    final b = agent();
    await b.start();
    await b.end();
  });

  test('a long outage keeps at most four batches and sends them 500 at a time', () async {
    var down = true;
    backend.routes['POST /v1/tracker/sessions/s1/samples'] = (_) => down ? http.Response('down', 503) : json({'week': week});
    final a = agent();
    await a.start();
    for (var i = 0; i < ActivityAgent.maxBatch * 4 + 3; i++) {
      clock.advance(const Duration(seconds: 30));
      await a.tick();
    }
    expect(a.pending, ActivityAgent.maxBatch * 4 + 1, reason: 'four batches waiting plus the one in flight');
    down = false;
    await a.flush();
    a.dispose();
    expect(a.pending, 0);
    final sizes = [
      for (final r in backend.sent('POST', '/v1/tracker/sessions/s1/samples').skip(ActivityAgent.maxBatch * 4 + 3))
        (jsonDecode(r.body)['samples'] as List).length,
    ];
    expect(sizes, [1, 500, 500, 500, 500], reason: 'the frozen batch first, then the rest 500 at a time');
  });

  test('a stored device id that is not one is replaced', () async {
    await store.write(ActivityAgent.deviceKey, {'id': 'x'});
    expect(await ActivityAgent.device(store, () => 'fresh-device-1'), 'fresh-device-1');
  });

  test('the tracker repository reads the week and the policy', () async {
    backend.routes['GET /v1/tracker/sessions/me'] = (_) => json({
      'open_session_id': null,
      'week': week,
      'sessions': [
        {
          'id': 's1',
          'claim_id': 'c1',
          'started_at': '2026-11-04T10:00:00Z',
          'active_seconds': 120,
          'idle_seconds': 30,
          'end_reason': 'client',
        },
      ],
    });
    backend.routes['GET /v1/tracker/policy'] = (_) => json({
      'slug': 'tracking',
      'title': 'What we track while you work',
      'summary': 'Only while a claim is open.',
      'version': '1',
      'sections': [
        {
          'title': 'What is collected',
          'bullets': ['Active or idle every 30 seconds.'],
        },
      ],
    });
    final repo = TrackerRepository(
      GatewayClient(client: backend.client, tokens: ScriptedTokens(), baseUrl: 'http://gateway.test/', sleep: (_) async {}),
    );
    final mine = await repo.mine();
    expect(mine.openSessionId, '');
    expect(mine.sessions.single.activeSeconds, 120);
    expect(mine.week.activeHours, 1);
    final policy = await repo.policy();
    expect(policy.sections.single.bullets.single, contains('30 seconds'));
    // a cap sent as a number reads the same
    expect(TrackerWeek.fromJson({...week, 'cap_hours': 12}).capHours, 12);
  });
}

/// A tracker whose session start waits on [gate]: an end that arrives first must wait for it.
class _SlowStart extends TrackerRepository {
  _SlowStart(FakeBackend backend, this.gate)
    : super(GatewayClient(client: backend.client, tokens: ScriptedTokens(), baseUrl: 'http://gateway.test/', sleep: (_) async {}));
  final Future<void> gate;

  @override
  Future<TrackerStart> start({required String claimId, required String device, required String key}) async {
    await gate;
    return const TrackerStart('s1');
  }
}
