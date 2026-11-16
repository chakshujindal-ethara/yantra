/// Importing a file, and the one thing that made the old path wrong.
///
/// THE DEFECT THIS REPLACES. This app used to parse CSV itself, in
/// `data/bank_payload.dart`, against a six-column spec - name, type,
/// difficulty, prompt, options, answer_key - and post the result as JSON. The
/// server's own template has thirty-three columns, including the indexed
/// dimension, rubric and image families. Feeding the template Odoo hands out to
/// this app therefore dropped the answer key, the rubric and the pictures, and
/// reported the import as a success.
///
/// The parser is gone. The bytes now go up untouched and the server reads them
/// with the same importer the back office uses, so the two cannot disagree.
/// What is left to test on this side is the routing and the reporting, which is
/// what this file covers - the column contract itself is pinned server-side in
/// `tests/test_import_parity.py`, where the parser actually lives.
library;

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Every importable entity routes to its own endpoint', () {
    test('the route segment matches the API path', () {
      // `/api/v1/<route>/import` and `/api/v1/<route>/template`. Questions are
      // served under `bank`, which is the one place the route and the name
      // differ - and exactly the kind of thing a rename would silently break.
      expect(ImportEntity.questions.route, 'bank');
      expect(ImportEntity.generators.route, 'generators');
      expect(ImportEntity.tags.route, 'tags');
    });

    test('no two entities share a route', () {
      final Set<String> routes = ImportEntity.values
          .map((ImportEntity e) => e.route)
          .toSet();
      expect(routes.length, ImportEntity.values.length);
    });

    test('every entity says what it is on the sheet', () {
      // The sheet takes all its wording from the enum, so an entity added
      // without copy would open a dialog with a blank title.
      for (final ImportEntity e in ImportEntity.values) {
        expect(e.title, isNotEmpty, reason: '${e.name} has no title');
        expect(e.sub, isNotEmpty, reason: '${e.name} has no sub');
      }
    });
  });

  group('The file picker offers what the importer accepts', () {
    test('questions take JSON as well as CSV', () {
      // The module has THREE question formats: its CSV, the authoring-harness
      // JSON and the native round-trip JSON. Offering only CSV would make two
      // of them unreachable from this app.
      expect(ImportEntity.questions.accept, contains('.json'));
      expect(ImportEntity.questions.accept, contains('.csv'));
    });

    test('tags and generators are CSV only', () {
      // There is no JSON importer for either, so offering JSON would let
      // somebody pick a file that can only be refused.
      expect(ImportEntity.tags.accept, isNot(contains('.json')));
      expect(ImportEntity.generators.accept, isNot(contains('.json')));
      expect(ImportEntity.tags.accept, contains('.csv'));
      expect(ImportEntity.generators.accept, contains('.csv'));
    });
  });
}
