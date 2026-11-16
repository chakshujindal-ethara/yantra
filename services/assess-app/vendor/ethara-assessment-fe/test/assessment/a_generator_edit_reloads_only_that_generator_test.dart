// A generator edit must not reload the whole console, and a console refresh
// must not walk every attempt on the platform.
//
// PROD, 2026-09-29 11:41-11:43. The owner edited generator 108, and every
// save ended in `_act`'s full `refresh()`: bank x2, analytics, 25 x /attempts,
// drafts, settings, generators, tags, assessments, budget, responses, ledger
// x5, leaderboard, forms - about 45 requests per save, a save every ~5 s. That
// was 550 /attempts calls in two minutes, enough CPU for the autoscaler to add
// pods and part of the DB-connection outage that followed.
//
// The 25 was never one call per assessment. `/api/v1/attempts` is already the
// console-wide route; the server clamps a page at 200 (`common.py` MAX_LIMIT),
// and the client walked up to 25 pages (5,000 rows) on EVERY refresh.
//
// The rig below has prod's shape: 5,200 attempts (so the walk hits its cap),
// a two-page bank and a five-page ledger. Each test counts requests per route.
//
// Setting `_Server.now` turns the rig into a backend with `changed_since`: its
// `/attempts` pages carry `meta.server_time`, and the filter returns only rows
// written after it, newest change first. Left null it is the older backend,
// and the background reload must stay exactly the catch-up read.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

const int _attemptTotal = 5200;

/// The rig's clock on a backend that stamps its pages.
final DateTime _t0 = DateTime.utc(2026, 9, 29, 10);

class _Server extends http.BaseClient {
  final Map<String, int> calls = <String, int>{};

  /// Per-assessment `submitted_count`, so a test can move one counter.
  final Map<int, int> submitted = <int, int>{1: 10, 2: 10};

  /// Attempt ids the server no longer has (a roster removal, say).
  final Set<int> removed = <int>{};

  /// The server clock. Null = an older backend: no `server_time`, and the
  /// `changed_since` key is ignored.
  DateTime? now;

  /// Every `changed_since` the client sent, in order.
  final List<String> since = <String>[];

  /// Fields written onto one attempt, and when. Unwritten rows date from
  /// before the rig's clock starts.
  final Map<int, Map<String, dynamic>> patched = <int, Map<String, dynamic>>{};
  final Map<int, DateTime> written = <int, DateTime>{};

  /// Write [fields] onto attempt [id] at the current [now].
  void write(int id, Map<String, dynamic> fields) {
    patched[id] = <String, dynamic>{...?patched[id], ...fields};
    if (now != null) written[id] = now!;
  }

  /// Newest first, as the route orders them. Assessment 2 owns 150 sittings
  /// in the middle of the table: inside the capped walk, outside page one.
  List<Map<String, dynamic>> get _world => <Map<String, dynamic>>[
    for (int i = 0; i < _attemptTotal; i++)
      if (!removed.contains(i + 1))
        <String, dynamic>{
          ..._attempt(i + 1, i >= 4000 && i < 4150 ? 2 : 1),
          ...?patched[i + 1],
        },
  ];

  /// Holds every response until released, to overlap refreshes on purpose.
  Completer<void>? gate;

  void reset() => calls.clear();

  int n(String route) => calls[route] ?? 0;

  int get total => calls.values.fold(0, (int a, int b) => a + b);

  static Map<String, dynamic> _page(
    List<Object> rows,
    int total,
    int offset, {
    DateTime? serverTime,
  }) => <String, dynamic>{
    'ok': true,
    'data': rows,
    'meta': <String, dynamic>{
      'total': total,
      'limit': 200,
      'offset': offset,
      'has_more': offset + rows.length < total,
      // Whole seconds with a Z, the shape a Python strftime sends.
      if (serverTime != null)
        'server_time': '${serverTime.toIso8601String().substring(0, 19)}Z',
    },
  };

  static Map<String, dynamic> _attempt(int id, int asm) => <String, dynamic>{
    'id': id,
    'assessment_id': asm,
    'candidate': <String, dynamic>{'id': 'p$id', 'name': 'Candidate $id'},
    'state': 'submitted',
  };

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final String path = request.url.path.replaceFirst('/api/v1', '');
    calls[path] = (calls[path] ?? 0) + 1;
    if (gate != null) await gate!.future;

    Map<String, dynamic> params = <String, dynamic>{};
    if (request is http.Request && request.body.isNotEmpty) {
      final Object? d = jsonDecode(request.body);
      if (d is Map<String, dynamic>) params = d;
    }
    final int offset = params['offset'] is int ? params['offset'] as int : 0;

    Object body;
    if (path == '/attempts') {
      final Object? asm = params['assessment_id'];
      final Object? changed = params['changed_since'];
      List<Map<String, dynamic>> all = <Map<String, dynamic>>[
        for (final Map<String, dynamic> a in _world)
          if (asm == null || '${a['assessment_id']}' == '$asm') a,
      ];
      if (changed is String) since.add(changed);
      if (changed is String && now != null) {
        final DateTime after = DateTime.parse(changed);
        DateTime at(Map<String, dynamic> a) =>
            written[a['id']] ?? DateTime.utc(2026);
        all = all.where((Map<String, dynamic> a) => at(a).isAfter(after))
            .toList()
          ..sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
              at(b).compareTo(at(a)));
      }
      body = _page(
        all.skip(offset).take(200).toList(),
        all.length,
        offset,
        serverTime: now,
      );
    } else if (path == '/assessments') {
      body = _page(<Object>[
        for (final int id in <int>[1, 2])
          <String, dynamic>{
            'id': id,
            'name': 'Assessment $id',
            'state': 'in_progress',
            'assigned_count': 2600,
            'submitted_count': submitted[id],
          },
      ], 2, 0);
    } else if (path == '/generators') {
      body = _page(<Object>[
        <String, dynamic>{'id': 108, 'name': 'Gen 108', 'sop_gen_state': 'done'},
      ], 1, 0);
    } else if (path == '/generators/108') {
      body = <String, dynamic>{
        'ok': true,
        'data': <String, dynamic>{
          'id': 108,
          'name': 'Gen 108',
          'sop_gen_state': 'done',
          'sop_question_count': 10,
        },
      };
    } else if (path == '/bank') {
      body = _page(<Object>[
        for (int i = offset; i < offset + 200 && i < 300; i++)
          <String, dynamic>{'id': i + 1, 'name': 'Q$i', 'question_type': 'mcq'},
      ], 300, offset);
    } else if (path == '/ledger') {
      body = _page(<Object>[
        for (int i = offset; i < offset + 200; i++) <String, dynamic>{'id': i},
      ], 2000, offset);
    } else if (path == '/settings' ||
        path == '/budget' ||
        path == '/analytics' ||
        path.endsWith('/update') ||
        path == '/bank/delete') {
      body = <String, dynamic>{'ok': true, 'data': <String, dynamic>{}};
    } else {
      body = _page(<Object>[], 0, 0);
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
}

/// A console after its first (loud) load, with the deferred drafts landed.
/// [now] set = a backend that stamps its pages (see the header).
Future<({_Server server, AppStore store})> _console({DateTime? now}) async {
  final _Server server = _Server()..now = now;
  final AppStore store = AppStore(
    api: ApiClient(client: server, baseUrl: 'http://x'),
  );
  await store.refresh();
  await store.draftsSettled();
  server.reset();
  return (server: server, store: store);
}

void main() {
  test('the first load still walks the capped attempts table', () async {
    final _Server server = _Server();
    final AppStore store = AppStore(
      api: ApiClient(client: server, baseUrl: 'http://x'),
    );
    await store.refresh();
    expect(server.n('/attempts'), 25, reason: '${server.calls}');
    expect(store.attempts, hasLength(5000));
    store.dispose();
  });

  test('a generator edit re-reads that generator and nothing else', () async {
    final (:_Server server, :AppStore store) = await _console();

    await store.setQuestionCount('108', 12);
    await store.draftsSettled();

    expect(server.n('/generators/108/update'), 1, reason: '${server.calls}');
    expect(server.n('/generators/108'), 1, reason: '${server.calls}');
    for (final String route in <String>[
      '/attempts',
      '/analytics',
      '/leaderboard',
      '/budget',
      '/ledger',
      '/bank',
      '/assessments',
      '/generators',
      '/drafts',
    ]) {
      expect(server.n(route), 0, reason: '$route: ${server.calls}');
    }
    expect(server.total, 2, reason: '${server.calls}');
    expect(store.genById('108')!.sopQuestionCount, 10,
        reason: 'the server copy wins after the save');
    store.dispose();
  });

  test('every generator field save stays on its own generator', () async {
    final (:_Server server, :AppStore store) = await _console();

    await store.saveGeneratorName('108', 'Renamed');
    await store.setImageLabelCount('108', 5);
    await store.saveExtraInstructions('108', 'plain words');
    await store.setShapeQuotas('108', <String, int>{'mcq': 2});

    expect(server.n('/attempts'), 0, reason: '${server.calls}');
    expect(server.n('/assessments'), 0, reason: '${server.calls}');
    expect(server.n('/generators/108'), 4, reason: '${server.calls}');
    store.dispose();
  });

  test('a background console refresh reads ONE attempts page and keeps the '
      'rest of the cache', () async {
    final (:_Server server, :AppStore store) = await _console();
    final int held = store.attempts.length;

    await store.refresh(background: true);

    expect(server.n('/attempts'), 1, reason: '${server.calls}');
    expect(server.since, isEmpty,
        reason: 'no server_time, no changed_since: the older backend keeps '
            "today's catch-up read exactly");
    expect(store.attempts, hasLength(held),
        reason: 'nothing on screen may shrink: rows past the first page stay');
    expect(store.attemptsTotal, _attemptTotal);
    store.dispose();
  });

  test('an assessment whose counters moved has its own attempts re-read',
      () async {
    final (:_Server server, :AppStore store) = await _console();
    expect(store.attemptsFor('2'), hasLength(150));
    // One of assessment 2's sittings is taken off its roster, and the list
    // row's counters say so. The sitting is far below the newest page.
    server.removed.add(4001);
    server.submitted[2] = 11;

    await store.refresh(background: true);

    expect(server.n('/attempts'), 2,
        reason: 'the newest page plus assessment 2, not 25: ${server.calls}');
    expect(store.attemptsFor('2'), hasLength(149),
        reason: 'the re-read replaces that assessment\'s rows');
    expect(store.attempts.where((a) => a.id == '4001'), isEmpty);
    expect(store.attemptsFor('1'), hasLength(4850),
        reason: 'an unchanged assessment keeps what it held');
    store.dispose();
  });

  test('overlapping refreshes share one run plus one trailing run', () async {
    final (:_Server server, :AppStore store) = await _console();
    server.gate = Completer<void>();

    final List<Future<void>> all = <Future<void>>[
      for (int i = 0; i < 4; i++) store.refresh(background: true),
    ];
    await Future<void>.delayed(Duration.zero);
    server.gate!.complete();
    server.gate = null;
    await Future.wait(all);

    expect(server.n('/assessments'), 2,
        reason: 'four overlapping calls, two runs: ${server.calls}');
    store.dispose();
  });

  test('a bank delete reloads the console once, not twice', () async {
    final (:_Server server, :AppStore store) = await _console();

    await store.deleteQuestions(<String>['1']);

    expect(server.n('/assessments'), 1, reason: '${server.calls}');
    expect(store.loadState, LoadState.ready);
    store.dispose();
  });

  group('on a backend with changed_since', () {
    Attempt byId(AppStore store, String id) =>
        store.attempts.firstWhere((Attempt a) => a.id == id);

    test('the first load and a Retry still walk every page', () async {
      final _Server server = _Server()..now = _t0;
      final AppStore store = AppStore(
        api: ApiClient(client: server, baseUrl: 'http://x'),
      );
      await store.refresh();
      expect(server.n('/attempts'), 25, reason: '${server.calls}');

      server.reset();
      await store.refresh();
      expect(server.n('/attempts'), 25,
          reason: 'a loud reload is the full picture: ${server.calls}');
      expect(server.since, isEmpty);
      store.dispose();
    });

    test('a background reload asks only for what changed since the last '
        'server_time, less 5 s', () async {
      final (:_Server server, :AppStore store) = await _console(now: _t0);
      server.now = _t0.add(const Duration(minutes: 1));

      await store.refresh(background: true);
      expect(server.n('/attempts'), 1, reason: '${server.calls}');
      expect(server.since, <String>['2026-09-29T09:59:55Z']);

      // The stamp moves on to the clock of the read that just landed.
      await store.refresh(background: true);
      expect(server.n('/attempts'), 2, reason: '${server.calls}');
      expect(server.since.last, '2026-09-29T10:00:55Z');
      store.dispose();
    });

    test('the delta merges by id: changed rows update, the rest stay put',
        () async {
      final (:_Server server, :AppStore store) = await _console(now: _t0);
      final int held = store.attempts.length;
      final Attempt untouched = byId(store, '4000');
      server.now = _t0.add(const Duration(minutes: 1));
      server.write(3, <String, dynamic>{'violation_count': 2});
      // Past the capped walk, so not held yet.
      server.write(5100, <String, dynamic>{'violation_count': 1});
      // Gone from the server: a delta cannot say so, and must not guess.
      server.removed.add(10);

      await store.refresh(background: true);

      expect(server.n('/attempts'), 1, reason: '${server.calls}');
      expect(byId(store, '3').violationCount, 2, reason: 'server value wins');
      expect(identical(byId(store, '4000'), untouched), isTrue,
          reason: 'an unchanged row is left exactly as it was');
      expect(store.attempts.where((Attempt a) => a.id == '10'), hasLength(1),
          reason: 'nothing disappears on a background reload');
      expect(store.attempts.first.id, '5100',
          reason: 'a row not held yet joins at the top');
      expect(store.attempts, hasLength(held + 1));
      store.dispose();
    });

    test('the gap closed: an old attempt whose write changes shows after one '
        'background reload', () async {
      // Attempt 3000 is assessment 1's, far below the newest page, and the
      // write moves none of the list row's counters - so the catch-up read
      // (newest page + moved assessments) never re-reads it.
      for (final DateTime? clock in <DateTime?>[null, _t0]) {
        final (:_Server server, :AppStore store) = await _console(now: clock);
        server.now = clock?.add(const Duration(minutes: 1));
        server.write(3000, <String, dynamic>{'violation_count': 4});

        await store.refresh(background: true);

        expect(server.n('/attempts'), 1, reason: '${server.calls}');
        expect(byId(store, '3000').violationCount, clock == null ? 0 : 4,
            reason: clock == null
                ? 'the older backend still has the gap (this half proves the '
                    'check can fail)'
                : 'changed_since returns every written row');
        store.dispose();
      }
    });
  });
}
