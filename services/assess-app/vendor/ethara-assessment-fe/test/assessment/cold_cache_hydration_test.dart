// Detail routes must hydrate into an EMPTY cache.
//
// THE BUG: every `loadX` used `list.map(replace)`, which drops the record when
// there is no match. A deep link or a browser refresh arrives with an empty
// cache, so the fetch succeeded and the result was thrown away - the screen sat
// on "not found" over a record the server had just returned. Session restore
// made this reachable on every refresh, not just a pasted link.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

http.Client serverFor(String kind, String id) => MockClient((
  http.Request req,
) async {
  final Map<String, dynamic> record = switch (kind) {
    'assessment' => <String, dynamic>{
      'id': id,
      'name': 'Deep-linked assessment',
      'state': 'draft',
    },
    'generator' => <String, dynamic>{'id': id, 'name': 'Deep-linked generator'},
    _ => <String, dynamic>{'id': id, 'name': 'Deep-linked question'},
  };
  return http.Response(
    jsonEncode(<String, dynamic>{'ok': true, 'data': record}),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

AppStore live(String kind, String id) => AppStore(
  api: ApiClient(client: serverFor(kind, id), baseUrl: 'http://x'),
);

void main() {
  group('hydrating into an empty cache keeps the record', () {
    test('loadAssessment on a cold cache', () async {
      final AppStore s = live('assessment', '77');
      expect(s.assessments, isEmpty, reason: 'a refresh starts cold');

      await s.loadAssessment('77');

      expect(
        s.asmById('77'),
        isNotNull,
        reason: 'the fetched record must survive, not be discarded',
      );
      expect(s.asmById('77')!.name, 'Deep-linked assessment');
    });

    test('loadGenerator on a cold cache', () async {
      final AppStore s = live('generator', '88');
      await s.loadGenerator('88');
      expect(s.generators.where((_) => true).length, 1);
      expect(s.generators.first.name, 'Deep-linked generator');
    });

    test('loadQuestion on a cold cache', () async {
      final AppStore s = live('question', '99');
      await s.loadQuestion('99');
      expect(s.bank.length, 1);
      expect(s.anyQuestionById('99'), isNotNull);
    });

    test('a second load REPLACES rather than duplicating', () async {
      // Upsert, not append-always: two loads of the same id must leave one row,
      // or every revisit grows the list.
      final AppStore s = live('assessment', '77');
      await s.loadAssessment('77');
      await s.loadAssessment('77');
      expect(s.assessments.length, 1);
    });
  });

  group('isEmpty tracks the candidate portal too', () {
    test('a store holding only attempts is NOT empty', () {
      // `_loadCandidate` fills only `attempts`. While isEmpty ignored it the
      // member portal stayed "empty" after a successful load, so the
      // first-paint skeleton fired on every refresh.
      // A LIVE store: a bare AppStore() has no injected client, so it falls
      // back to fixtures and is never empty.
      final AppStore s = live('assessment', '1');
      expect(s.isEmpty, isTrue, reason: 'nothing loaded yet');

      s.attempts = <Attempt>[
        Attempt.fromJson(<String, dynamic>{
          'id': '1',
          'assessment_id': '18',
          'employee_id': 'e1',
          'state': 'submitted',
        }),
      ];

      expect(
        s.isEmpty,
        isFalse,
        reason: 'the candidate portal has data; the skeleton must stop',
      );
    });
  });
}
