// R8: a Form Studio edit still inside its 900 ms save debounce, or a form the
// server has not been told about yet (just created or imported), survived
// nothing: every console refresh REPLACED `forms` with the server's list, so
// the edit snapped back, the new form vanished, and the designer was left
// holding an object the store no longer had. The refresh now merges: an
// unsaved or newer local copy wins, and once its save lands the server's
// copy is taken again.
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _ok(Object data) => http.Response(
  jsonEncode(<String, dynamic>{
    'ok': true,
    'data': data,
    if (data is List)
      'meta': <String, dynamic>{'total': data.length, 'has_more': false},
  }),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

/// The server's forms, by id: a save upserts the whole document.
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
            served[f['id'] as String] = f;
            return _ok(<String, dynamic>{'id': f['id']});
          }
          if (p.endsWith('/forms')) return _ok(served.values.toList());
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
  final Map<String, Map<String, dynamic>> served =
      <String, Map<String, dynamic>>{};

  FormDef? form(String id) => store.formById(id);

  /// Past the 900 ms debounce, so the save has landed.
  Future<void> saveLands() =>
      Future<void>.delayed(const Duration(milliseconds: 1100));
}

void main() {
  test('an edit inside the debounce survives a refresh', () async {
    final _Rig rig = _Rig();
    final FormDef made = rig.store.createForm()..title = 'Server copy';
    rig.store.persistForm(made);
    await rig.saveLands();
    await rig.store.refresh(background: true);
    final FormDef held = rig.form(made.id)!;
    expect(held.title, 'Server copy');

    held.title = 'Typed just now';
    rig.store.persistForm(held);
    await rig.store.refresh(background: true);
    expect(rig.form(made.id)?.title, 'Typed just now');
    expect(
      identical(rig.form(made.id), held),
      isTrue,
      reason: 'the designer holds this object; a refresh must not swap it',
    );
    await rig.saveLands();
  });

  test('a form the server has not been sent yet is not dropped', () async {
    final _Rig rig = _Rig();
    await rig.store.refresh();
    final FormDef made = rig.store.createForm();
    await rig.store.refresh(background: true);
    expect(rig.form(made.id), isNotNull);
    await rig.saveLands();
  });

  test('once its save lands, the server copy is taken again', () async {
    final _Rig rig = _Rig();
    final FormDef made = rig.store.createForm()..title = 'Mine';
    rig.store.persistForm(made);
    await rig.saveLands();
    // Another admin renames it on the server after the save.
    rig.served[made.id] = <String, dynamic>{
      ...rig.served[made.id]!,
      'title': 'Renamed elsewhere',
    };
    await rig.store.refresh(background: true);
    expect(rig.form(made.id)?.title, 'Renamed elsewhere');
  });

  test('a deleted form sends no pending save and is not kept', () async {
    final _Rig rig = _Rig();
    final FormDef made = rig.store.createForm()..title = 'Gone';
    rig.store.persistForm(made);
    rig.store.deleteForm(made.id);
    await rig.saveLands();
    expect(rig.served.containsKey(made.id), isFalse, reason: 'no save');
    await rig.store.refresh(background: true);
    expect(rig.form(made.id), isNull);
  });
}
