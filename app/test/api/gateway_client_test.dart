import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:yantra_app/api/gateway_client.dart';
import 'package:yantra_app/auth/session.dart';
import 'package:yantra_app/core/errors.dart';
import 'package:yantra_app/core/network_status.dart';

import '../support/fake_backend.dart';

class ScriptedTokens implements TokenProvider {
  ScriptedTokens({this.current = 'tok-1', this.refreshed = 'tok-2'});
  String? current;
  String? refreshed;
  int refreshes = 0;
  bool lost = false;

  @override
  Future<String?> accessToken() async => current;

  @override
  Future<String?> refreshedAccessToken() async {
    refreshes++;
    return refreshed;
  }

  @override
  Future<void> authLost() async => lost = true;
}

void main() {
  final waits = <Duration>[];
  GatewayClient make(FakeBackend backend, ScriptedTokens tokens) =>
      GatewayClient(client: backend.client, tokens: tokens, baseUrl: 'http://gateway.test/', sleep: (d) async => waits.add(d));

  setUp(waits.clear);

  test('GET carries the bearer token', () async {
    final backend = FakeBackend({'GET /v1/batches': (_) => json([])});
    final r = await make(backend, ScriptedTokens()).get('/v1/batches');
    expect(r.statusCode, 200);
    expect(backend.requests.single.headers['Authorization'], 'Bearer tok-1');
    expect(backend.requests.single.url.toString(), 'http://gateway.test/v1/batches');
  });

  test('POST carries the idempotency key and a JSON body', () async {
    final backend = FakeBackend({
      'POST /v1/x': (r) => json({'ok': true}, status: 201),
    });
    await make(backend, ScriptedTokens()).post('/v1/x', idempotencyKey: 'key-abc-123', body: {'a': 1});
    final sent = backend.requests.single;
    expect(sent.headers['Idempotency-Key'], 'key-abc-123');
    expect(sent.headers['Content-Type'], startsWith('application/json'));
    expect(sent.body, '{"a":1}');
  });

  test('a raw body goes out as is with its own content type', () async {
    final backend = FakeBackend({
      'POST /v1/x': (r) => json({'ok': true}),
    });
    await make(backend, ScriptedTokens()).post(
      '/v1/x',
      idempotencyKey: 'key-raw-1',
      body: const RawBody('a,b\n1,2\n', contentType: 'text/csv'),
    );
    final sent = backend.requests.single;
    expect(sent.headers['Content-Type'], startsWith('text/csv'));
    expect(sent.body, 'a,b\n1,2\n');
  });

  test('a 401 is repaired with one refresh and the request is retried', () async {
    final backend = FakeBackend({
      'GET /v1/batches': (r) => r.headers['Authorization'] == 'Bearer tok-2' ? json([]) : envelope(401, 'unauthorized'),
    });
    final tokens = ScriptedTokens();
    final r = await make(backend, tokens).get('/v1/batches');
    expect(r.statusCode, 200);
    expect(tokens.refreshes, 1);
    expect(backend.requests.map((r) => r.headers['Authorization']), ['Bearer tok-1', 'Bearer tok-2']);
  });

  test('a 401 that survives the refresh drops the session', () async {
    final backend = FakeBackend({'GET /v1/batches': (_) => envelope(401, 'unauthorized')});
    final tokens = ScriptedTokens();
    await expectLater(make(backend, tokens).get('/v1/batches'), throwsA(isA<AuthRequiredException>()));
    expect(tokens.lost, isTrue);
  });

  test('no refresh token means sign in again', () async {
    final backend = FakeBackend({'GET /v1/batches': (_) => envelope(401, 'unauthorized')});
    final tokens = ScriptedTokens(refreshed: null);
    await expectLater(make(backend, tokens).get('/v1/batches'), throwsA(isA<AuthRequiredException>()));
    expect(tokens.lost, isTrue);
  });

  test('429 surfaces Retry-After', () async {
    final backend = FakeBackend({
      'GET /v1/batches': (_) => envelope(429, 'rate_limited', message: 'too many requests', headers: {'retry-after': '17'}),
    });
    await expectLater(
      make(backend, ScriptedTokens()).get('/v1/batches'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.isRateLimited, 'rate limited', isTrue)
            .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 17))
            .having((e) => e.requestId, 'requestId', 'req-1'),
      ),
    );
  });

  test('503 surfaces Retry-After and the code', () async {
    final backend = FakeBackend({
      'POST /v1/x': (_) => envelope(503, 'upstream_unavailable', message: 'try again shortly', headers: {'retry-after': '2'}),
    });
    await expectLater(
      make(backend, ScriptedTokens()).post('/v1/x', idempotencyKey: 'key-abc-123'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.isUnavailable, 'unavailable', isTrue)
            .having((e) => e.code, 'code', 'upstream_unavailable')
            .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 2)),
      ),
    );
  });

  test('409 request_in_flight is retried after a second with the same key', () async {
    var calls = 0;
    final backend = FakeBackend({
      'POST /v1/x': (_) => ++calls < 3 ? envelope(409, 'request_in_flight') : json({'ok': true}, status: 201),
    });
    final r = await make(backend, ScriptedTokens()).post('/v1/x', idempotencyKey: 'key-abc-123');
    expect(r.statusCode, 201);
    expect(waits, [const Duration(seconds: 1), const Duration(seconds: 1)]);
    expect(backend.requests.map((r) => r.headers['Idempotency-Key']).toSet(), {'key-abc-123'});
  });

  test('409 request_in_flight gives up after the retry budget', () async {
    final backend = FakeBackend({'POST /v1/x': (_) => envelope(409, 'request_in_flight')});
    await expectLater(
      make(backend, ScriptedTokens()).post('/v1/x', idempotencyKey: 'key-abc-123'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'request_in_flight')),
    );
    expect(backend.requests, hasLength(1 + GatewayClient.inFlightRetries));
  });

  test('other 409s are not retried', () async {
    final backend = FakeBackend({'POST /v1/x': (_) => envelope(409, 'one_live_claim')});
    await expectLater(
      make(backend, ScriptedTokens()).post('/v1/x', idempotencyKey: 'key-abc-123'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'one_live_claim')),
    );
    expect(backend.requests, hasLength(1));
  });

  test('the error envelope context is kept; an empty map when absent', () async {
    final backend = FakeBackend({
      'POST /v1/assess/papers/pp1/sittings': (_) =>
          envelope(409, 'sitting_live', message: 'a sitting is live', context: {'sitting_id': 's1'}),
      'GET /v1/batches': (_) => envelope(503, 'unavailable'),
    });
    final client = make(backend, ScriptedTokens());
    await expectLater(
      client.post('/v1/assess/papers/pp1/sittings', idempotencyKey: 'k'),
      throwsA(isA<ApiException>().having((e) => e.context, 'context', {'sitting_id': 's1'})),
    );
    await expectLater(client.get('/v1/batches'), throwsA(isA<ApiException>().having((e) => e.context, 'context', isEmpty)));
  });

  test('a non-JSON error body still becomes an ApiException', () async {
    final backend = FakeBackend({'GET /v1/batches': (_) => http.Response('<html>bad gateway</html>', 502)});
    await expectLater(
      make(backend, ScriptedTokens()).get('/v1/batches'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'http_502')),
    );
  });

  test('signed out means AuthRequired before any request', () async {
    final backend = FakeBackend();
    await expectLater(make(backend, ScriptedTokens(current: null)).get('/v1/batches'), throwsA(isA<AuthRequiredException>()));
    expect(backend.requests, isEmpty);
  });

  test('a transport failure is a TransportException', () async {
    final backend = FakeBackend({'GET /v1/batches': (_) => throw http.ClientException('refused')});
    await expectLater(make(backend, ScriptedTokens()).get('/v1/batches'), throwsA(isA<TransportException>()));
  });

  test('a transport failure marks the gateway unreachable and says offline when the browser is', () async {
    final network = NetworkStatus();
    final backend = FakeBackend({'GET /v1/batches': (_) => throw http.ClientException('refused')});
    final gateway = GatewayClient(client: backend.client, tokens: ScriptedTokens(), baseUrl: 'http://gateway.test', network: network);
    await expectLater(gateway.get('/v1/batches'), throwsA(isA<TransportException>().having((e) => e.offline, 'offline', isFalse)));
    expect(network.reachable, isFalse);
    network.setOnline(false);
    await expectLater(gateway.get('/v1/batches'), throwsA(isA<TransportException>().having((e) => e.offline, 'offline', isTrue)));
    backend.routes['GET /v1/batches'] = (_) => json([]);
    network.setOnline(true);
    await gateway.get('/v1/batches');
    expect(network.reachable, isTrue, reason: 'one answer is enough to clear the banner');
  });

  test('an error envelope that is not JSON still becomes an ApiException', () async {
    final backend = FakeBackend({'GET /v1/batches': (_) => http.Response('<html>bad gateway</html>', 502)});
    await expectLater(
      make(backend, ScriptedTokens()).get('/v1/batches'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'http_502')),
    );
  });

  test('serverNow follows the Date header of the last answer; without one it is the device clock', () async {
    var device = DateTime.utc(2026, 11, 4, 10);
    final backend = FakeBackend({
      'GET /v1/batches': (_) => json([], headers: {'date': formatHttpDate(DateTime.utc(2026, 11, 4, 10, 5))}),
    });
    final gateway = GatewayClient(
      client: backend.client,
      tokens: ScriptedTokens(),
      baseUrl: 'http://gateway.test',
      deviceClock: () => device,
    );
    expect(gateway.serverNow(), device, reason: 'nothing heard yet: the device clock');
    await gateway.get('/v1/batches');
    expect(gateway.serverNow(), DateTime.utc(2026, 11, 4, 10, 5), reason: 'the device is five minutes behind');
    device = device.add(const Duration(seconds: 30));
    expect(gateway.serverNow(), DateTime.utc(2026, 11, 4, 10, 5, 30), reason: 'the offset keeps, the device clock ticks');
    backend.routes['GET /v1/batches'] = (_) => json([], headers: {'date': 'not a date'});
    await gateway.get('/v1/batches');
    expect(gateway.serverNow(), DateTime.utc(2026, 11, 4, 10, 5, 30), reason: 'an unreadable Date changes nothing');
    backend.routes['GET /v1/batches'] = (_) =>
        envelope(409, 'conflict', headers: {'date': formatHttpDate(DateTime.utc(2026, 11, 4, 9, 55, 30))});
    await expectLater(gateway.get('/v1/batches'), throwsA(isA<ApiException>()));
    expect(gateway.serverNow(), DateTime.utc(2026, 11, 4, 9, 55, 30), reason: 'an error answer carries the clock too');
  });
}
