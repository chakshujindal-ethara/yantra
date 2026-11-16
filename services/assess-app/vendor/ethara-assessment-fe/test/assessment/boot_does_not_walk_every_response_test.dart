// Loading the admin console must not walk the whole response table.
//
// THE BUG THIS EXISTS FOR. `/api/v1/responses` grows with every answer every
// candidate gives - one 30-question sitting adds 30 rows. `_allPages` followed
// `has_more` to the very end, so at 31,462 rows on stage a single load issued
// 158 sequential POSTs to that one route. `pollGeneration` then called a FULL
// `refresh()` on a 2-second tick, so stage served a sustained 813 requests a
// minute against a route the poll does not even read, and the whole console
// read as "the platform is slow".
//
// Both halves are asserted here by COUNTING REAL REQUESTS over a fake
// transport, not by inspecting store state: the defect was the request volume,
// so the request volume is what has to be pinned.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// Answers every admin route with a plausible envelope and tallies the calls.
///
/// `total` is deliberately huge on `/responses`: that is the condition the cap
/// exists for, and a fake that reports a small total would pass no matter what
/// the pager did.
class _CountingBackend extends http.BaseClient {
  final Map<String, int> calls = <String, int>{};
  static const int responseTotal = 31462;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final String path = request.url.path;
    calls[path] = (calls[path] ?? 0) + 1;

    int offset = 0;
    if (request is http.Request && request.body.isNotEmpty) {
      final Object? decoded = jsonDecode(request.body);
      if (decoded is Map && decoded['offset'] is int) {
        offset = decoded['offset'] as int;
      }
    }

    Object body;
    if (path.endsWith('/responses')) {
      // A full page every time, and `has_more` true well past any cap, so an
      // uncapped walk would run to 158 pages.
      body = <String, dynamic>{
        'ok': true,
        'data': <Map<String, dynamic>>[
          for (int i = 0; i < 200; i++)
            <String, dynamic>{
              'id': offset + i,
              'evaluator_id': 1,
              'assessment_id': 55,
              'question_id': 1,
              'question_type': 'mcq',
              'state': 'submitted',
              'candidate': <String, dynamic>{'id': 1, 'name': 'ZZCAPB 0001'},
            },
        ],
        'meta': <String, dynamic>{
          'total': responseTotal,
          'limit': 200,
          'offset': offset,
          'has_more': offset + 200 < responseTotal,
        },
      };
    } else if (path.endsWith('/auth_token')) {
      body = <String, dynamic>{
        'data': <String, dynamic>{
          'access_token': 't',
          'user_type': 'admin',
          'name': 'Admin',
        },
      };
    } else if (path.endsWith('/settings') ||
        path.endsWith('/budget') ||
        path.endsWith('/analytics')) {
      body = <String, dynamic>{'ok': true, 'data': <String, dynamic>{}};
    } else if (path.endsWith('/drafts')) {
      // STAGE'S ACTUAL STATE, and the condition that made the poll immortal:
      // a draft whose image render never completed. Stage has four sitting at
      // `pending` permanently, so `rendering` was true on every tick and the
      // loop ran its whole budget every time any action started it.
      body = <String, dynamic>{
        'ok': true,
        'data': <Map<String, dynamic>>[
          for (int i = 0; i < 4; i++)
            <String, dynamic>{
              'id': 26 + i,
              'name': 'Stuck draft ${26 + i}',
              'question_type': 'mcq',
              'image_state': 'pending',
              'video_state': 'rendered',
            },
        ],
        'meta': <String, dynamic>{
          'total': 4,
          'limit': 200,
          'offset': 0,
          'has_more': false,
        },
      };
    } else {
      // Every other list: one short page, so it terminates immediately and
      // cannot be confused with the route under test.
      body = <String, dynamic>{
        'ok': true,
        'data': <Map<String, dynamic>>[],
        'meta': <String, dynamic>{
          'total': 0,
          'limit': 200,
          'offset': 0,
          'has_more': false,
        },
      };
    }

    final List<int> bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      200,
      headers: <String, String>{'content-type': 'application/json'},
      request: request,
    );
  }
}

void main() {
  test('a full load reads a bounded number of response pages', () async {
    final _CountingBackend backend = _CountingBackend();
    final AppStore store = AppStore(
      api: ApiClient(
        client: backend,
        baseUrl: 'https://example.invalid',
        bearer: 't',
      ),
    );

    await store.refresh();

    final int hits = backend.calls['/api/v1/responses'] ?? 0;
    // The pre-fix walk was ceil(31462 / 200) = 158.
    expect(
      hits,
      lessThanOrEqualTo(2),
      reason:
          'boot walked $hits pages of /responses; the whole table is 158 pages '
          'and loading it is what made stage slow',
    );
    expect(hits, greaterThan(0), reason: 'the screen still needs rows to show');
    // Stopping short is deliberate, and must not read as "this is everything".
    expect(
      store.pagesTruncated,
      isTrue,
      reason: 'a capped walk has to record that it stopped short',
    );
  });

  test('polling a generation does not re-read responses at all', () async {
    final _CountingBackend backend = _CountingBackend();
    final AppStore store = AppStore(
      api: ApiClient(
        client: backend,
        baseUrl: 'https://example.invalid',
        bearer: 't',
      ),
    );

    await store.refresh();
    final int afterBoot = backend.calls['/api/v1/responses'] ?? 0;

    // Ticks fast, so the test does not sit for a minute. Nothing is generating
    // and nothing is rendering in this fixture, so the loop must return at
    // once - and even when it does tick, it must not touch `/responses`.
    await store.pollGeneration(
      every: const Duration(milliseconds: 1),
      maxTicks: 40,
    );

    expect(
      backend.calls['/api/v1/responses'] ?? 0,
      afterBoot,
      reason:
          'the generation poll re-read /responses, which it never displays - '
          'this is the 813 req/min that made stage slow',
    );
  });

  test('a render stuck at pending does not poll forever', () async {
    final _CountingBackend backend = _CountingBackend();
    final AppStore store = AppStore(
      api: ApiClient(
        client: backend,
        baseUrl: 'https://example.invalid',
        bearer: 't',
      ),
    );

    await store.refresh();
    // The fixture's four drafts stay at `pending` no matter how often they are
    // re-read - exactly like stage - so a loop that waits for them to settle
    // never returns on its own.
    final int afterBoot = backend.calls['/api/v1/drafts'] ?? 0;

    await store.pollGeneration(
      every: const Duration(milliseconds: 1),
      maxTicks: 500,
    );

    final int ticks = (backend.calls['/api/v1/drafts'] ?? 0) - afterBoot;
    expect(
      ticks,
      lessThan(40),
      reason:
          'polled $ticks times against drafts that never settle; with nothing '
          'generating, a stalled render must not hold the loop open',
    );
  });
}
