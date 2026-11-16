// Where the generator's uploaded files actually live in the payload.
//
// THE BUG: the DETAIL route sends BOTH an empty root `resources` and the real
// list under `tabs.resources`. The client read `root ?? tabs`, and an empty list
// is not null, so the root won and the corpus tab said "No files attached" over
// a stored document. Verified against the live route: generator 27 has one
// resource, root `resources` is `[]`, `tabs.resources` has the row.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';

/// One resource row, in the shape the server actually sends.
Map<String, dynamic> row(int id, String name) => <String, dynamic>{
  'id': id,
  'name': name,
  'category': 'sop',
  'status': 'ready',
  'char_count': 5369,
  'file_size': 5369,
  'extraction_error': '',
  'sequence': 10,
};

void main() {
  group('resources are found wherever the payload puts them', () {
    test('the live DETAIL shape: empty root, real list under tabs', () {
      final Generator g = Generator.fromJson(<String, dynamic>{
        'id': 27,
        'name': 'Forklift Safety - E2E',
        'resources': const <dynamic>[],
        'tabs': <String, dynamic>{
          'resources': <dynamic>[row(12, 'Warehouse Forklift Safety SOP.txt')],
        },
      });

      expect(
        g.resources.length,
        1,
        reason: 'an empty root list must not mask tabs.resources',
      );
      expect(g.resources.single.file, 'Warehouse Forklift Safety SOP.txt');
      expect(
        g.resources.single.size,
        isNotEmpty,
        reason: 'file_size now comes off ir.attachment, not the record',
      );
    });

    test('the fixture shape: rows at the root, no tabs', () {
      final Generator g = Generator.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'Seeded',
        'resources': <dynamic>[row(1, 'seed.txt')],
      });

      expect(g.resources.length, 1);
      expect(g.resources.single.file, 'seed.txt');
    });

    test('the root wins when BOTH carry rows', () {
      // Not a shape the server sends, but the rule has to be decidable: the
      // root is the explicit one, so it takes precedence when populated.
      final Generator g = Generator.fromJson(<String, dynamic>{
        'id': 2,
        'name': 'Both',
        'resources': <dynamic>[row(1, 'root.txt')],
        'tabs': <String, dynamic>{
          'resources': <dynamic>[row(2, 'nested.txt')],
        },
      });

      expect(g.resources.single.file, 'root.txt');
    });

    test('genuinely empty stays empty', () {
      final Generator g = Generator.fromJson(<String, dynamic>{
        'id': 3,
        'name': 'Bare',
        'resources': const <dynamic>[],
        'tabs': <String, dynamic>{'resources': const <dynamic>[]},
      });

      expect(g.resources, isEmpty);
    });

    test('a payload with neither key does not throw', () {
      final Generator g = Generator.fromJson(<String, dynamic>{
        'id': 4,
        'name': 'None',
      });
      expect(g.resources, isEmpty);
    });
  });
}
