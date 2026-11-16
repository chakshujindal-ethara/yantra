// A shed or failed write is REPLAYED, not dropped.
//
// On 2026-09-03 the server answered 14,759 HTTP 500s on the answer route and
// this client re-issued none of them: `_syncAnswer` warned once and discarded
// the payload. Postgres-per-save is what made that incident lose zero answers,
// and that floor only protects answers that ARRIVE.
//
// The negative control for this file is `maxAttempts: 1` - it is what the client
// did before the ladder existed, so every "it retried" test below has a
// same-file twin proving the assertion fails without the fix.
import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Answers with [statuses] in order, then 200 forever. Records every hit.
class _Sequence {
  final List<int> statuses;
  final Map<String, String> headers;
  int hits = 0;
  final List<String> bodies = <String>[];

  _Sequence(this.statuses, {this.headers = const <String, String>{}});

  http.Client get client => MockClient((http.Request req) async {
    bodies.add(req.body);
    final int i = hits++;
    final int status = i < statuses.length ? statuses[i] : 200;
    if (status == 200) {
      return http.Response(
        jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
        200,
      );
    }
    return http.Response(
      jsonEncode(<String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{'code': 'server_error', 'message': 'boom'},
      }),
      status,
      headers: headers,
    );
  });
}

/// No real sleeping; records what the ladder asked to wait.
List<Duration> _waits = <Duration>[];

ApiClient _client(
  http.Client c, {
  int maxAttempts = 5,
  double jitter = 0.0,
  Duration retryBudget = const Duration(seconds: 60),
  void Function(RetryNotice)? onRetryWait,
}) {
  _waits = <Duration>[];
  return ApiClient(
    client: c,
    baseUrl: 'http://x',
    bearer: 'tok',
    maxAttempts: maxAttempts,
    retryBackoff: const Duration(milliseconds: 100),
    retryBudget: retryBudget,
    onRetryWait: onRetryWait,
    sleep: (Duration d) async => _waits.add(d),
    jitter: () => jitter,
  );
}

Duration get _totalWait =>
    _waits.fold(Duration.zero, (Duration a, Duration b) => a + b);


/// The ladder is scoped to the candidate WRITE path, so every "it retried" case
/// has to drive a write. `examBegin` is the smallest one.
Future<Map<String, dynamic>> _write(ApiClient c) => c.examBegin('tk');

void main() {
  group('retry ladder', () {
    test('a 500 is retried and the call ultimately succeeds', () async {
      final _Sequence s = _Sequence(<int>[500, 500]);
      await _write(_client(s.client));
      expect(s.hits, 3, reason: 'two failures then a success');
      expect(_waits.length, 2);
    });

    test('NEGATIVE CONTROL: with maxAttempts 1 the same 500 is not retried',
        () async {
      final _Sequence s = _Sequence(<int>[500, 500]);
      await expectLater(
        _write(_client(s.client, maxAttempts: 1)),
        throwsA(isA<ApiError>()),
      );
      expect(s.hits, 1, reason: 'this is the pre-fix behaviour');
      expect(_waits, isEmpty);
    });

    test('the payload is re-sent UNCHANGED on every attempt', () async {
      final _Sequence s = _Sequence(<int>[503, 500]);
      await _client(s.client).examAnswer(
        'tk',
        questionId: '7',
        optionIds: const <String>['1', '2'],
        justification: 'my answer',
        labels: const <int, String>{},
      );
      expect(s.hits, 3);
      expect(s.bodies.toSet().length, 1,
          reason: 'a replay that mutates the answer would corrupt it');
      expect(s.bodies.first, contains('my answer'));
    });

    test('gives up after maxAttempts and still reports the server error',
        () async {
      final _Sequence s = _Sequence(<int>[500, 500, 500, 500, 500, 500]);
      await expectLater(
        _write(_client(s.client)),
        throwsA(isA<ApiError>().having((ApiError e) => e.status, 'status', 500)),
      );
      expect(s.hits, 5, reason: 'maxAttempts, not maxAttempts + 1');
    });

    test('a 4xx verdict is NOT retried - replaying asks the same wrong question',
        () async {
      for (final int code in <int>[400, 403, 404, 422]) {
        final _Sequence s = _Sequence(<int>[code]);
        await expectLater(
          _write(_client(s.client)),
          throwsA(isA<ApiError>()),
        );
        expect(s.hits, 1, reason: '$code is a verdict, not a shed');
      }
    });

    test('409 attempt_locked is NOT retried - we lost a race we handle already',
        () async {
      final _Sequence s = _Sequence(<int>[409]);
      await expectLater(
        _write(_client(s.client)),
        throwsA(isA<ApiError>()),
      );
      expect(s.hits, 1);
    });

    test('429 IS retried', () async {
      final _Sequence s = _Sequence(<int>[429]);
      await _write(_client(s.client));
      expect(s.hits, 2);
    });

    test('backoff is exponential and carries at least 10% jitter', () async {
      final _Sequence s = _Sequence(<int>[500, 500, 500]);
      await _write(_client(s.client, jitter: 0.0));
      // base 100ms, doubling, x1.1 at zero jitter
      expect(_waits[0].inMilliseconds, 110);
      expect(_waits[1].inMilliseconds, 220);
      expect(_waits[2].inMilliseconds, 440);
    });

    test('jitter widens the delay, so a cohort does not retry in lockstep',
        () async {
      final _Sequence a = _Sequence(<int>[500]);
      await _write(_client(a.client, jitter: 0.0));
      final Duration low = _waits.first;

      final _Sequence b = _Sequence(<int>[500]);
      await _write(_client(b.client, jitter: 1.0));
      final Duration high = _waits.first;

      expect(high, greaterThan(low));
    });

    test("the server's Retry-After wins over our own backoff", () async {
      final _Sequence s = _Sequence(
        <int>[503],
        headers: const <String, String>{'retry-after': '7'},
      );
      await _write(_client(s.client));
      expect(_waits.first, const Duration(seconds: 7));
    });

    test('an untrustworthy Retry-After falls back to our backoff', () {
      expect(parseRetryAfter('0'), isNull, reason: '0 would be an instant herd');
      expect(parseRetryAfter('-5'), isNull);
      expect(parseRetryAfter('99999'), isNull, reason: 'absurd');
      expect(parseRetryAfter(''), isNull);
      expect(parseRetryAfter(null), isNull);
      expect(parseRetryAfter('  12 '), const Duration(seconds: 12));
      // The HTTP-date form needs dart:io and is unreachable on web, so it must
      // degrade to null rather than throw.
      expect(parseRetryAfter('Wed, 21 Oct 2026 07:28:00 GMT'), isNull);
    });

    test('a transport failure is retried', () async {
      int hits = 0;
      final http.Client c = MockClient((http.Request req) async {
        if (++hits < 3) throw http.ClientException('Failed to fetch');
        return http.Response(
          jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
          200,
        );
      });
      await _write(_client(c));
      expect(hits, 3);
    });

    test('sign-in is NEVER replayed, even on a 500', () async {
      // This holds STRUCTURALLY, not by classification: the ladder is opt-in
      // per route and `login` does not use it. Asserted anyway, because the
      // dangerous change is someone later making the ladder global - which is
      // what the first version of this fix did - and this is the test that
      // would catch a credential call being replayed.
      final _Sequence s = _Sequence(<int>[500, 500]);
      await expectLater(
        _client(s.client).login('a@b.c', 'pw'),
        throwsA(isA<ApiError>()),
      );
      expect(s.hits, 1,
          reason: 'replaying a credential call could lock an account');
    });

    test('READS are not retried - the runner re-reads on its next tick anyway',
        () async {
      // The other half of the scoping decision. A ladder on every call also
      // delays every ADMIN screen by the full backoff before it can show an
      // error, which is a worse console for a human watching it.
      final _Sequence s = _Sequence(<int>[500, 500]);
      await expectLater(
        _client(s.client).examState('tk'),
        throwsA(isA<ApiError>()),
      );
      expect(s.hits, 1);
      expect(_waits, isEmpty);
    });
  });

  // A LADDER THAT WAITS IN SILENCE IS INDISTINGUISHABLE FROM A HANG.
  //
  // `parseRetryAfter` accepts up to 300s and `maxAttempts` is 5, so four
  // honoured `Retry-After: 300` headers bought TWENTY MINUTES asleep behind
  // `toaster.busy('Submitting your exam...')` - a toast that by design never
  // expires and cannot be dismissed. A candidate reloads the page long before
  // that resolves, which is the one thing the ladder exists to prevent.
  //
  // None of this cuts the ladder back. Attempts are untouched; only the time
  // between them is bounded, and the last wait is CLIPPED to what the budget
  // has left rather than skipped.
  group('the ladder is bounded, legible and cancellable', () {
    /// A server shedding hard and asking for the parser's maximum every time.
    _Sequence shedding() => _Sequence(
          <int>[503, 503, 503, 503, 503],
          headers: const <String, String>{'retry-after': '300'},
        );

    test('Retry-After: 300 cannot buy twenty minutes of silence', () async {
      final _Sequence s = shedding();
      await expectLater(_write(_client(s.client)), throwsA(isA<ApiError>()));
      expect(_totalWait, lessThanOrEqualTo(const Duration(seconds: 60)),
          reason: 'the whole ladder, not one rung of it');
      expect(_waits.first, const Duration(seconds: 60),
          reason: 'CLIPPED, not skipped - the budget is spent trying');
      expect(s.hits, greaterThan(1), reason: 'it still retried');
    });

    test('NEGATIVE CONTROL: unbounded, the same server buys twenty minutes',
        () async {
      final _Sequence s = shedding();
      await expectLater(
        _write(_client(s.client, retryBudget: const Duration(days: 1))),
        throwsA(isA<ApiError>()),
      );
      expect(_totalWait, const Duration(minutes: 20),
          reason: 'this is the pre-fix behaviour');
    });

    test('an ordinary ladder is untouched by the budget', () async {
      // The 2026-09-03 case: four fast rungs well inside the budget, so the
      // bound must not cost a single attempt.
      final _Sequence s = _Sequence(<int>[500, 500, 500, 500, 500, 500]);
      await expectLater(_write(_client(s.client)), throwsA(isA<ApiError>()));
      expect(s.hits, 5);
      expect(_waits.length, 4);
    });

    test('each rung is announced before it is slept through', () async {
      final List<String> said = <String>[];
      final _Sequence s = _Sequence(<int>[500, 500]);
      await _write(_client(s.client,
          onRetryWait: (RetryNotice r) => said.add(
                'try ${r.attempt} of ${r.of}, waiting ${r.wait.inMilliseconds}'
                'ms, ${r.spent.inMilliseconds}ms spent',
              )));
      expect(
        said,
        <String>[
          'try 1 of 5, waiting 110ms, 110ms spent',
          'try 2 of 5, waiting 220ms, 330ms spent',
        ],
        reason: 'enough for a progress line that is not a lie',
      );
    });

    test('the announced wait is the CLIPPED one, not the one asked for',
        () async {
      // Showing "retrying in 300s" and then retrying in 60 would be a second
      // lie replacing the first.
      RetryNotice? first;
      final _Sequence s = shedding();
      await expectLater(
        _write(_client(s.client, onRetryWait: (RetryNotice r) => first ??= r)),
        throwsA(isA<ApiError>()),
      );
      expect(first!.wait, const Duration(seconds: 60));
    });

    test('cancelling stops the ladder and reports the server error', () async {
      final _Sequence s = shedding();
      await expectLater(
        _write(_client(s.client, onRetryWait: (RetryNotice r) => r.cancel())),
        throwsA(isA<ApiError>().having((ApiError e) => e.status, 'status', 503)),
      );
      expect(s.hits, 1, reason: 'the ladder stopped where it was stopped');
      expect(_waits, isEmpty, reason: 'and it did not sleep first');
    });

    test('NEGATIVE CONTROL: not cancelling runs the ladder out', () async {
      final _Sequence s = shedding();
      await expectLater(_write(_client(s.client)), throwsA(isA<ApiError>()));
      expect(s.hits, greaterThan(1));
      expect(_waits, isNotEmpty);
    });
  });

  group('ApiError.isRetryable', () {
    test('classifies by whether the server got to decide', () {
      expect(const ApiError('x', status: 500).isRetryable, isTrue);
      expect(const ApiError('x', status: 503).isRetryable, isTrue);
      expect(const ApiError('x', status: 429).isRetryable, isTrue);
      expect(const ApiError('x', isTransport: true).isRetryable, isTrue);

      expect(const ApiError('x', status: 409).isRetryable, isFalse);
      expect(const ApiError('x', status: 422).isRetryable, isFalse);
      expect(const ApiError('x', status: 401).isRetryable, isFalse);
      expect(const ApiError('x').isRetryable, isFalse);

      // THE ONE THAT MATTERS. The module's crash handler answers
      // fail("server_error", status=500), i.e. {"ok": false} at 500, so a
      // genuine server error arrives with isDomain SET. Gating retry on
      // !isDomain would refuse to replay precisely the 2026-09-03 case.
      expect(
        const ApiError('x', isDomain: true, status: 500).isRetryable,
        isTrue,
        reason: 'ok:false at 500 is the module CRASHING, not refusing',
      );
      // A domain refusal proper still carries a 4xx, so it stays out.
      expect(
        const ApiError('x', isDomain: true, status: 422).isRetryable,
        isFalse,
      );
    });
  });
}
