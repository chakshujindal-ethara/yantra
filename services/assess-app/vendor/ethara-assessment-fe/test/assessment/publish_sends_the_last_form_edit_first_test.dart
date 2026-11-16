// Publish sends the designer's last edit first, or publishes nothing.
//
// `publishForm` flushed the form only while its 900 ms save timer was still
// pending. A save that had already FAILED (the edit still unsaved), or one
// still on the wire, was skipped: Publish published the server's stale copy
// and said "published". Now it waits for a save in flight, sends an unsaved
// edit again, and refuses to publish when that save fails.
library;

import 'dart:async';
import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _ok(Object data) => http.Response(
  jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

/// Records `/forms/save` (with the title it carried) and `/forms/publish`.
/// A save fails while [saveFails] is above 0, and waits on [holdSave].
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
            await holdSave?.future;
            if (saveFails > 0) {
              saveFails--;
              return http.Response(
                jsonEncode(<String, dynamic>{
                  'ok': false,
                  'error': <String, dynamic>{
                    'code': 'invalid',
                    'message': 'The form could not be saved.',
                  },
                }),
                422,
                headers: <String, String>{'content-type': 'application/json'},
              );
            }
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
  int saveFails = 0;
  Completer<void>? holdSave;

  /// A designer edit to [title], then past the 900 ms debounce.
  Future<FormDef> edit(String title) async {
    final FormDef f = store.createForm()..title = title;
    store.persistForm(f);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    return f;
  }

  Iterable<String> get toasts =>
      store.toaster.items.map((ToastMsg m) => m.message);
}

void main() {
  test('an edit still in its debounce is sent, then published', () async {
    final _Rig rig = _Rig();
    final FormDef f = rig.store.createForm()..title = 'Typed just now';
    rig.store.persistForm(f);

    expect(await rig.store.publishForm(f.id), isNotNull);
    expect(rig.calls, <String>['save:Typed just now', 'publish']);
    // The debounce was cancelled: nothing more goes out.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(rig.calls, <String>['save:Typed just now', 'publish']);
  });

  test('an edit whose save failed is sent again, then published', () async {
    final _Rig rig = _Rig()..saveFails = 1;
    final FormDef f = await rig.edit('Final wording');
    expect(rig.calls, <String>['save:Final wording'], reason: 'it failed');

    expect(await rig.store.publishForm(f.id), isNotNull);
    expect(rig.calls, <String>[
      'save:Final wording',
      'save:Final wording',
      'publish',
    ]);
  });

  test('a save still on the wire is waited for, then published', () async {
    final _Rig rig = _Rig()..holdSave = Completer<void>();
    final FormDef f = await rig.edit('Final wording');

    final Future<(String, List<String>)?> published = rig.store.publishForm(
      f.id,
    );
    await pumpEventQueue();
    expect(rig.calls, <String>['save:Final wording'], reason: 'it waits');

    rig.holdSave!.complete();
    expect(await published, isNotNull);
    expect(rig.calls, <String>['save:Final wording', 'publish']);
  });

  test('a save that fails again publishes nothing, and says so', () async {
    final _Rig rig = _Rig()..saveFails = 2;
    final FormDef f = await rig.edit('Final wording');

    expect(await rig.store.publishForm(f.id), isNull);
    expect(rig.calls, isNot(contains('publish')));
    expect(f.published, isFalse);
    expect(
      rig.toasts,
      contains(
        'Not published: the latest edits did not save. '
        'The form could not be saved.',
      ),
    );
  });
}
