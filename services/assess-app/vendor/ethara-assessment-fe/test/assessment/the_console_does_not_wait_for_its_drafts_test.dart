/// The console must not sit on its skeleton waiting for the draft list.
///
/// THE DEFECT, reported from a local run and reproduced against the
/// live-shaped database. `_loadAdmin` issued fourteen calls inside one
/// `Future.wait`, and `Future.wait` completes when its SLOWEST member does.
/// Timed with all fourteen in flight at once, exactly as the browser issues
/// them:
///
///     drafts       6.18s   <- set the wall clock for the entire load
///     forms        0.69s
///     assessments  0.61s
///     analytics    0.60s
///     ...          every other call under 0.5s
///
/// So thirteen replies sat parsed and waiting while one endpoint held the whole
/// console blank. In the browser's network panel `drafts` reads "(pending)" at
/// 0.0 kB with everything around it at 200 - which is what the report looked
/// like.
///
/// Drafts is the heaviest list (a draft row carries rendered image specs) and
/// the ONLY one on that list no landing screen reads: the dashboard shows none
/// of it, and its two real consumers - the review queue and a generator's
/// detail screen - are places an operator navigates to. So it is fetched after
/// the blocking load instead of inside it.
///
/// TWO WAYS THIS SILENTLY BREAKS, and there is a test for each:
///
///   1. The placeholder slot. Every assignment in `_loadAdmin` is POSITIONAL,
///      so the deferred call keeps its position in the array. If somebody
///      assigns that empty slot to `drafts`, `_mergeQuestions` - which maps
///      over the INCOMING rows - clears the list. The Review Queue badge then
///      blanks on every refresh, and `pollGeneration` refreshes every two
///      seconds during a run, so it blanks over and over while an operator
///      watches.
///   2. Re-entry. Same two-second poll: without a guard each tick starts
///      another six-second walk on top of the last.
library;

import 'dart:async';
import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// A backend that answers everything instantly EXCEPT `/drafts`, which it
/// holds until the test releases it.
///
/// That asymmetry IS the test: a fake where every route is fast could not tell
/// a load that waits for drafts from one that does not.
class _SlowDraftsClient extends http.BaseClient {
  _SlowDraftsClient();

  /// Released to let the held drafts call finish.
  final Completer<void> draftsGate = Completer<void>();

  /// How many times `/drafts` was asked for - the re-entry check.
  int draftCalls = 0;

  /// Paths seen, in order, so a test can prove the rest of the load ran.
  final List<String> seen = <String>[];

  /// One draft row, enough for the badge to be non-zero.
  static const String _draftRow = '''
{"ok": true, "data": [
  {"id": "9001", "name": "A draft awaiting review", "question_type": "mcq",
   "state": "draft", "difficulty": "easy", "prompt": "Pick one"}
], "meta": {"total": 1, "hasMore": false}}''';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final String path = request.url.path;
    seen.add(path);

    if (path.endsWith('/drafts')) {
      draftCalls++;
      await draftsGate.future;
      return _json(_draftRow);
    }
    // Everything else: a well-formed empty list, or an empty object for the
    // routes that return one. Shape matters more than content here - the store
    // parses each reply positionally and a wrong shape would fail the load for
    // a reason unrelated to what is under test.
    if (path.endsWith('/auth/me')) {
      return _json('{"ok": true, "data": {"uid": 2, "name": "Admin", '
          '"email": "admin", "role": "manager"}}');
    }
    if (path.endsWith('/settings') ||
        path.endsWith('/budget') ||
        path.endsWith('/analytics')) {
      return _json('{"ok": true, "data": {}}');
    }
    return _json(
      '{"ok": true, "data": [], "meta": {"total": 0, "hasMore": false}}',
    );
  }

  static http.StreamedResponse _json(String body) => http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
}

AppStore _liveStore(_SlowDraftsClient http_) {
  final ApiClient api = ApiClient(
    baseUrl: 'https://example.invalid',
    client: http_,
  );
  return AppStore(api: api)..source = DataSource.live;
}

void main() {
  test('the load finishes while the draft list is still in flight', () async {
    // THE HEADLINE. The drafts call is deliberately never released before the
    // assertion, so a load that still waits for it can only time out.
    final _SlowDraftsClient http_ = _SlowDraftsClient();
    final AppStore store = _liveStore(http_);
    addTearDown(store.dispose);

    bool loaded = false;
    final Future<void> load = store.refresh().then((_) => loaded = true);

    // Generous, and irrelevant to the outcome: this resolves as soon as the
    // load does. If drafts were still awaited it would hang here instead.
    await load.timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail(
        'refresh() did not finish while /drafts was outstanding - the draft '
        'fetch is back inside the blocking Future.wait',
      ),
    );

    expect(loaded, isTrue);
    expect(store.loadState, LoadState.ready,
        reason: 'the console must be usable before drafts arrive');

    // GUARD THE FAKE. If the request never went out, the assertion above would
    // pass for the wrong reason - a load that simply stopped fetching drafts
    // altogether would look identical.
    expect(http_.draftCalls, 1,
        reason: 'the drafts fetch must still be issued, just not awaited');
    expect(http_.seen.any((String p) => p.endsWith('/assessments')), isTrue,
        reason: 'the rest of the load did not run, so nothing here is proven');

    http_.draftsGate.complete();
  });

  test('the drafts arrive once the call comes back', () async {
    // Deferred is not dropped. The badge appears a moment late; it must appear.
    final _SlowDraftsClient http_ = _SlowDraftsClient();
    final AppStore store = _liveStore(http_);
    addTearDown(store.dispose);

    await store.refresh();
    expect(store.drafts, isEmpty, reason: 'not yet - the call is still held');

    http_.draftsGate.complete();
    // Let the fire-and-forget continuation run.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(store.drafts.length, 1,
        reason: 'the deferred fetch never landed its rows');
    expect(store.drafts.first.id, '9001');
  });

  test('a refresh does not blank the badge it already has', () async {
    // DEFECT 1. `_mergeQuestions` maps over the INCOMING rows, so assigning
    // the empty placeholder slot to `drafts` clears it. With pollGeneration
    // refreshing every two seconds, the Review Queue badge would blank
    // repeatedly in front of the operator.
    final _SlowDraftsClient http_ = _SlowDraftsClient();
    final AppStore store = _liveStore(http_);
    addTearDown(store.dispose);

    await store.refresh();
    http_.draftsGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(store.drafts.length, 1, reason: 'precondition: a draft is held');

    // A SECOND refresh, the one the poll issues.
    await store.refresh();

    expect(store.drafts.length, 1,
        reason: 'the refresh cleared the drafts it was holding - the empty '
            'placeholder slot has been assigned to `drafts`');
  });

  test('overlapping refreshes do not stack draft walks', () async {
    // DEFECT 2. The walk is the expensive part (6.18s measured), so a poll
    // firing every two seconds must not start a new one each tick.
    final _SlowDraftsClient http_ = _SlowDraftsClient();
    final AppStore store = _liveStore(http_);
    addTearDown(store.dispose);

    await store.refresh();
    expect(http_.draftCalls, 1);

    // Two more refreshes while the first walk is STILL held open.
    await store.refresh();
    await store.refresh();

    expect(http_.draftCalls, 1,
        reason: 'each refresh started another draft walk while one was '
            'already in flight');

    http_.draftsGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // And once it is done, a later refresh IS allowed to fetch again -
    // otherwise the guard would freeze the badge forever.
    await store.refresh();
    expect(http_.draftCalls, 2,
        reason: 'the re-entry guard never released, so the badge can never '
            'update again');
  });
}
