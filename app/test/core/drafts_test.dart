import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yantra_app/core/drafts.dart';

void main() {
  test('keys name the kind and the id', () {
    expect(DraftStore.unit('c1'), 'yantra.draft.unit.c1');
    expect(DraftStore.sitting('s1'), 'yantra.draft.sitting.s1');
  });

  test('the memory store keeps a copy, not the caller\'s map', () async {
    final store = MemoryDraftStore();
    final value = <String, Object?>{'a': 1};
    await store.write('k', value);
    value['a'] = 2;
    expect(await store.read('k'), {'a': 1});
    await store.remove('k');
    expect(await store.read('k'), isNull);
  });

  test('the preferences store round-trips, ignores a non-object and removes', () async {
    SharedPreferences.setMockInitialValues({'yantra.draft.unit.bad': '[1,2]', 'yantra.draft.unit.junk': 'not json'});
    final store = PreferencesDraftStore();
    await store.write('yantra.draft.unit.c1', {
      'rows': [
        ['k', 'v'],
      ],
    });
    expect(await store.read('yantra.draft.unit.c1'), {
      'rows': [
        ['k', 'v'],
      ],
    });
    expect(await store.read('yantra.draft.unit.bad'), isNull);
    expect(await store.read('yantra.draft.unit.junk'), isNull);
    expect(await store.read('yantra.draft.unit.none'), isNull);
    await store.remove('yantra.draft.unit.c1');
    expect(await store.read('yantra.draft.unit.c1'), isNull);
  });
}
