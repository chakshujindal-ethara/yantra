// The generation poll must keep watching while ASSETS are still rendering.
//
// WHAT WAS BROKEN. `pollGeneration` stopped as soon as every generator's
// `sopGenState` and `tagExtractState` settled. Image and video rendering runs on
// a SEPARATE cron that finishes later, so generation reported `done`, the poll
// returned, and the Drafts list sat on "Pending" assets while the renders
// completed behind it. Clicking a draft fetched its detail and showed
// `Rendered`, which made the list look wrong rather than merely stale - reported
// as "the question says rendered only when I click on it".
//
// The payloads below are the module's own shapes: `S.generator_row` and
// `S.draft_row` in `controllers/api/serializers.py`.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// A generator that has FINISHED generating - the state the bug hid behind.
Map<String, dynamic> doneGenerator() => <String, dynamic>{
  'id': 172,
  'name': 'test T2I',
  'state': 'done',
  'sop_gen_state': 'done',
  'tag_extract_state': 'done',
  'question_count': 6,
};

/// One `draft_row`, with the asset state the list renders.
Map<String, dynamic> draftRow(int id, String imageState) => <String, dynamic>{
  'id': id,
  'name': 'Draft $id',
  'state': 'draft',
  'question_type': 'image_ab',
  'generator': <String, dynamic>{'id': 172, 'name': 'test T2I'},
  'image_state': imageState,
  'video_state': 'none',
  'has_images': true,
  'has_dimensions': true,
};

void main() {
  test('a draft still rendering keeps the poll alive after generation is done',
      () async {
    // Renders finish on the THIRD read: pending, rendering, then rendered.
    final List<String> states = <String>['pending', 'rendering', 'rendered'];
    int draftReads = 0;

    final MockClient client = MockClient((http.Request req) async {
      final String path = req.url.path;
      Object data = <dynamic>[];
      if (path.endsWith('/auth_token')) {
        data = <String, dynamic>{'access_token': 't', 'refresh_token': 'r'};
      } else if (path.endsWith('/generators')) {
        data = <dynamic>[doneGenerator()];
      } else if (path.endsWith('/drafts')) {
        final String s = states[draftReads.clamp(0, states.length - 1)];
        draftReads++;
        data = <dynamic>[draftRow(79, s)];
      }
      return http.Response(
        jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    final AppStore s = AppStore(
      api: ApiClient(client: client, baseUrl: 'http://x'),
    );
    await s.refresh();
    // The drafts are fetched OUTSIDE the blocking load now, so `refresh()`
    // returns before they land - see `_loadDraftsInBackground`. Waiting here is
    // what the poll itself does for the same reason: this loop reads the draft
    // asset states to decide whether to keep watching.
    await s.draftsSettled();

    expect(s.drafts.single.imageState, AssetState.pending,
        reason: 'the first read is mid-render');

    // Two ticks is enough to walk pending -> rendering -> rendered. Before the
    // fix this returned immediately on the first tick, because both generator
    // states already read `done`.
    await s.pollGeneration(
        every: const Duration(milliseconds: 1), maxTicks: 6);

    expect(s.drafts.single.imageState, AssetState.rendered,
        reason: 'the poll must follow the render to completion, so the list '
            'reaches Rendered without the operator opening a draft');
    expect(draftReads, greaterThan(1),
        reason: 'a poll that stopped at generation-done would read drafts once');
  });

  test('everything settled stops the poll rather than spinning', () async {
    int draftReads = 0;
    final MockClient client = MockClient((http.Request req) async {
      final String path = req.url.path;
      Object data = <dynamic>[];
      if (path.endsWith('/auth_token')) {
        data = <String, dynamic>{'access_token': 't', 'refresh_token': 'r'};
      } else if (path.endsWith('/generators')) {
        data = <dynamic>[doneGenerator()];
      } else if (path.endsWith('/drafts')) {
        draftReads++;
        data = <dynamic>[draftRow(79, 'rendered')];
      }
      return http.Response(
        jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    final AppStore s = AppStore(
      api: ApiClient(client: client, baseUrl: 'http://x'),
    );
    await s.refresh();
    // BASELINE IS TAKEN AFTER THE DEFERRED FETCH LANDS, not straight after
    // `refresh()`. The drafts call now runs outside the blocking load, so
    // `refresh()` returns with the read still outstanding - taking the baseline
    // at 0 and then counting that same single read would look like the poll had
    // started re-reading when it had not. Measured: one refresh plus one poll
    // issues exactly ONE /drafts read either way, so the work is unchanged and
    // only the moment it lands moved.
    await s.draftsSettled();
    final int afterFirstLoad = draftReads;

    await s.pollGeneration(
        every: const Duration(milliseconds: 1), maxTicks: 6);

    expect(draftReads, afterFirstLoad,
        reason: 'nothing is in flight, so the poll must not re-read at all - '
            'the fix must not turn an idle screen into a polling loop');
  });
}
