// A form's autosaves go to the server one at a time, in the order made.
//
// Each debounce fire started its own save, so a slow save and the next one ran
// side by side and could land out of order: the server kept the OLDER form.
// The newer save had already cleared the "unsaved" mark, so Publish then
// published that stale copy. Now each save waits for the one before it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _ok(Object data) => http.Response(
  jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

/// The first `/forms/save` waits on [slow]; later ones answer at once. The
/// server keeps the title of the save it finished last.
class _Rig {
  _Rig() {
    store = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String p = req.url.path;
          if (p.endsWith('/forms/save')) {
            final Map<String, dynamic> f =
                (jsonDecode(req.body) as Map<String, dynamic>)['form']
                    as Map<String, dynamic>;
            calls.add('save:${f['title']}');
            if (calls.length == 1) await slow.future;
            stored = f['title'] as String;
            return _ok(<String, dynamic>{'id': f['id']});
          }
          if (p.endsWith('/forms/publish')) {
            calls.add('publish');
            return _ok(<String, dynamic>{'assessment_id': 9});
          }
          return _ok(<dynamic>[]);
        }),
      ),
    );
    store.adoptSession(
      orgRole: 'admin',
      name: 'Aarav Mehta',
      uid: '2',
      accessRoleWire: AccessRole.admin.wire,
      capabilities: Capability.values.toSet(),
    );
  }

  late final AppStore store;
  final List<String> calls = <String>[];
  final Completer<void> slow = Completer<void>();
  String? stored;

  /// Retitle [f], then wait past the 900 ms debounce.
  Future<void> edit(FormDef f, String title) async {
    f.title = title;
    store.persistForm(f);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
  }
}

void main() {
  test('a slow save then a fast one: the server ends on the newer', () async {
    final _Rig rig = _Rig();
    final FormDef f = rig.store.createForm();
    await rig.edit(f, 'First draft');
    await rig.edit(f, 'Final wording');
    expect(rig.calls, <String>['save:First draft'], reason: 'it waits');

    final Future<(String, List<String>)?> published = rig.store.publishForm(
      f.id,
    );
    await pumpEventQueue();
    expect(rig.calls, isNot(contains('publish')), reason: 'both first');

    rig.slow.complete();
    expect(await published, isNotNull);
    expect(rig.calls, <String>[
      'save:First draft',
      'save:Final wording',
      'publish',
    ]);
    expect(rig.stored, 'Final wording');
  });

  test('a save waiting its turn is dropped when the form is deleted', () async {
    final _Rig rig = _Rig();
    final FormDef f = rig.store.createForm();
    await rig.edit(f, 'First draft');
    await rig.edit(f, 'Final wording');

    rig.store.deleteForm(f.id);
    rig.slow.complete();
    await pumpEventQueue();

    expect(rig.calls, <String>['save:First draft'], reason: 'not revived');
  });
}
