/// The generator's date is a CREATION date, and now says so.
///
/// THE DEFECT. The header read "updated 9 days ago" over a value the server
/// never sent an update stamp for: `generator_row` (`serializers.py:1037`)
/// puts exactly one date on the wire, `create_date`, and the client read it
/// into a field called `updated`. So the one date a generator carried was
/// labelled as the opposite of what it was - a generator edited this morning
/// still reported the week-old day it was made, and nothing on screen said
/// which of the two it meant.
library;

import 'package:ethara_assessment/assessment/domain/models.dart';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('The date comes off create_date, whatever the wire spells it', () {
    test('snake_case `create_date`, which is what the API actually sends', () {
      final Generator g = Generator.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'High Res Dense Generator',
        'create_date': '2026-08-12T08:57:14Z',
      });
      // Humanised at parse time, not at the call site - the raw ISO string
      // was reaching the header verbatim.
      expect(g.created, isNot(contains('T08:57:14')));
      expect(g.created, isNotEmpty);
    });

    test('camelCase `createDate` reads the same', () {
      final Generator g = Generator.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'g',
        'createDate': '2026-08-12T08:57:14Z',
      });
      expect(g.created, isNotEmpty);
    });

    test('a fixture\'s pre-humanised string survives untouched', () {
      final Generator g = Generator.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'g',
        'created': '2 days ago',
      });
      expect(g.created, '2 days ago');
    });

    test('no date at all is empty, not the epoch', () {
      // The header hides the clause entirely when this is empty. A fallback
      // date would put a specific, wrong day on a record that has none.
      final Generator g =
          Generator.fromJson(<String, dynamic>{'id': 1, 'name': 'g'});
      expect(g.created, isEmpty);
    });

    test('round-trips through toJson under its own name', () {
      final Generator g = Generator.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'g',
        'created': '2 days ago',
      });
      expect(g.toJson()['created'], '2 days ago');
      expect(g.toJson().containsKey('updated'), isFalse);
    });
  });
}
