// Extract skills and Draft from SOP each have a Stop (owner, 2026-09-29).
//
// Extract skills runs on the server's cron, so its Stop is a flag the screen
// shows as "Stopping..." until the server settles it. Draft from SOP is one web
// request the app is waiting on, so its Stop frees the button at once and drops
// the reply when it finally lands - without touching a newer press.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

const String kGen = '5';

Map<String, dynamic> _gen(String tagState, {bool stopping = false}) =>
    <String, dynamic>{
      'id': 5,
      'name': 'Video Caption Labeling',
      'tag_extract_state': tagState,
      'tag_extract_cancel_requested': stopping,
    };

/// Answers every route with `{}`, except the draft route, which waits on the
/// next completer in [drafts] so a test decides when the model "answers".
class _Server {
  final List<String> paths = <String>[];
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];
  final List<Completer<Map<String, dynamic>>> drafts =
      <Completer<Map<String, dynamic>>>[];

  http.Client get client => MockClient((http.Request req) async {
    paths.add(req.url.path);
    bodies.add(
      req.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(req.body) as Map<String, dynamic>,
    );
    Map<String, dynamic> data = <String, dynamic>{};
    if (req.url.path.endsWith('/task_templates/draft')) {
      final Completer<Map<String, dynamic>> c =
          Completer<Map<String, dynamic>>();
      drafts.add(c);
      data = await c.future;
    }
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
}

AppStore _store(_Server server) {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: server.client),
  );
  s.generators = <Generator>[Generator.fromJson(_gen('generating'))];
  addTearDown(s.dispose);
  return s;
}

Map<String, dynamic> _draft(String name) => <String, dynamic>{
  'name': name,
  'response': 'single_choice',
  'structure': <dynamic>[],
};

void main() {
  group('Extract skills', () {
    test('a running extraction can be stopped, once', () {
      final Generator running = Generator.fromJson(_gen('generating'));
      expect(running.canCancelTagExtract, isTrue);
      expect(running.isStoppingTagExtract, isFalse);

      final Generator stopping = Generator.fromJson(
        _gen('generating', stopping: true),
      );
      expect(stopping.canCancelTagExtract, isFalse, reason: 'no second press');
      expect(stopping.isStoppingTagExtract, isTrue);

      final Generator done = Generator.fromJson(_gen('done'));
      expect(done.canCancelTagExtract, isFalse);
      expect(done.isStoppingTagExtract, isFalse);
    });

    test('Stop calls the server and shows Stopping at once', () async {
      final _Server server = _Server();
      final AppStore s = _store(server);

      final Future<void> stop = s.cancelTagExtract(kGen);
      expect(s.genById(kGen)!.isStoppingTagExtract, isTrue);
      await stop;

      expect(
        server.paths,
        contains('/api/v1/generators/5/cancel_tag_extract'),
      );
    });
  });

  group('Draft from SOP', () {
    test('Stop frees the button and drops the late reply', () async {
      final _Server server = _Server();
      final AppStore s = _store(server);

      final Future<TaskTemplate?> first = s.draftTaskTemplate(kGen);
      await pumpEventQueue();
      expect(s.isBusy('draft:$kGen'), isTrue);

      await s.cancelTemplateDraft(kGen);
      expect(s.isBusy('draft:$kGen'), isFalse, reason: 'freed at once');
      final int i = server.paths.indexOf('/api/v1/task_templates/cancel_draft');
      expect(i, isNonNegative);
      expect(server.bodies[i]['generator_id'], 5);

      server.drafts.single.complete(_draft('late'));
      expect(await first, isNull, reason: 'a stopped draft never opens');
      expect(s.isBusy('draft:$kGen'), isFalse);
    });

    test('a stopped reply cannot clear a newer press', () async {
      final _Server server = _Server();
      final AppStore s = _store(server);

      final Future<TaskTemplate?> first = s.draftTaskTemplate(kGen);
      await pumpEventQueue();
      await s.cancelTemplateDraft(kGen);
      final Future<TaskTemplate?> second = s.draftTaskTemplate(kGen);
      await pumpEventQueue();

      server.drafts.first.complete(_draft('old'));
      expect(await first, isNull);
      expect(s.isBusy('draft:$kGen'), isTrue, reason: 'the new press waits on');

      server.drafts.last.complete(_draft('new'));
      expect((await second)?.name, 'new');
      expect(s.isBusy('draft:$kGen'), isFalse);
    });
  });
}
