// The Assessments list, the question Bank and the Generators list search the
// SERVER, not the rows the console happens to be holding.
//
// All three routes accepted `search` before this change and none of the three
// screens sent it; `api_client.generators()` did not even carry the parameter.
// Each box filtered a cache built by a boot-time walk, so anything past that
// walk was unfindable - the same class of defect as D7, one screen removed.
//
// THE THREE THINGS EACH TEST HAS TO SHOW, because a naive wiring gets two of
// them wrong:
//   * the term reaches the server at all;
//   * one search per pause, NOT one per keystroke;
//   * an empty box costs NOTHING, so the ordinary case is as cheap as it was.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_list_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/bank_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/generator_list_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// One request, with the search term it carried.
class Call {
  Call(this.path, this.body);
  final String path;
  final Map<String, dynamic> body;
  String get search => (body['search'] as String?) ?? '';
}

Map<String, dynamic> asm(String id, String name) => <String, dynamic>{
  'id': id,
  'name': name,
  'state': 'done',
  'active': true,
};

Map<String, dynamic> question(String id, String name) => <String, dynamic>{
  'id': id,
  'name': name,
  'prompt': name,
  'question_type': 'mcq_single',
  'active': true,
  'retired': false,
};

Map<String, dynamic> generator(String id, String name) => <String, dynamic>{
  'id': id,
  'name': name,
  'active': true,
};

/// A console whose caches hold ONE row and whose search route answers with a
/// DIFFERENT one.
///
/// That asymmetry is the test: a screen still filtering its cache can only ever
/// show the cached row, so finding the searched row is proof the predicate ran on
/// the server.
class _Rig {
  final List<Call> calls = <Call>[];
  late final AppStore store;

  /// How many rows the server claims match, so `partial` can be exercised.
  int matchTotal = 1;

  _Rig() {
    store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          final Map<String, dynamic> body =
              jsonDecode(req.body) as Map<String, dynamic>;
          calls.add(Call(path, body));
          final String term = (body['search'] as String?) ?? '';

          if (path.endsWith('/assessments')) {
            return _json(<dynamic>[
              if (term.isEmpty) asm('1', 'Cached assessment'),
              if (term.isNotEmpty) asm('2', 'Server assessment $term'),
            ], total: term.isEmpty ? 1 : matchTotal);
          }
          if (path.endsWith('/bank')) {
            return _json(<dynamic>[
              if (term.isEmpty) question('1', 'Cached question'),
              if (term.isNotEmpty) question('2', 'Server question $term'),
            ], total: term.isEmpty ? 1 : matchTotal);
          }
          if (path.endsWith('/generators')) {
            return _json(<dynamic>[
              if (term.isEmpty) generator('1', 'Cached generator'),
              if (term.isNotEmpty) generator('2', 'Server generator $term'),
            ], total: term.isEmpty ? 1 : matchTotal);
          }
          if (path.endsWith('/attempts') ||
              path.endsWith('/tags') ||
              path.endsWith('/drafts') ||
              path.endsWith('/responses') ||
              path.endsWith('/ledger') ||
              path.endsWith('/forms')) {
            return _json(<dynamic>[]);
          }
          return _json(<String, dynamic>{});
        }),
        baseUrl: 'http://x',
      ),
    );
  }

  static http.Response _json(Object data, {int? total}) => http.Response(
    jsonEncode(<String, dynamic>{
      'ok': true,
      'data': data,
      if (data is List)
        'meta': <String, dynamic>{
          'total': total ?? data.length,
          'limit': 200,
          'offset': 0,
          'has_more': false,
        },
    }),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );

  /// Requests to [path] that carried a search term.
  List<Call> searchesOn(String path) => calls
      .where((Call c) => c.path.endsWith(path) && c.search.isNotEmpty)
      .toList();
}

void main() {
  Future<void> pump(WidgetTester t, Widget child) async {
    t.view.physicalSize = const Size(1600, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AssessmentNavScope(
          nav: AssessmentNav(),
          child: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  /// Type [term] one character at a time, then wait past the debounce.
  Future<void> type(WidgetTester t, String term) async {
    for (int i = 1; i <= term.length; i++) {
      await t.enterText(find.byType(TextFormField).first, term.substring(0, i));
      await t.pump(const Duration(milliseconds: 40));
    }
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
  }

  group('the Assessments list', () {
    testWidgets('finds a row the client never held', (WidgetTester t) async {
      final _Rig rig = _Rig();
      await rig.store.refresh();
      await pump(
        t,
        AssessmentListScreen(store: rig.store, portal: Portal.admin),
      );

      await type(t, 'forklift');

      expect(rig.searchesOn('/assessments').length, 1);
      expect(rig.searchesOn('/assessments').single.search, 'forklift');
      expect(
        find.text('Server assessment forklift'),
        findsOneWidget,
        reason: 'the row came from the server; the cache holds a different one, '
            'so a local filter could not have produced it',
      );
    });

    testWidgets('eight keystrokes cost one request', (WidgetTester t) async {
      final _Rig rig = _Rig();
      await rig.store.refresh();
      await pump(
        t,
        AssessmentListScreen(store: rig.store, portal: Portal.admin),
      );

      await type(t, 'forklift');

      expect(
        rig.searchesOn('/assessments').length,
        1,
        reason: 'debounced at 250ms. Unthrottled this is eight round trips for '
            'one word',
      );
    });

    testWidgets('an empty box issues nothing and shows the cache', (
      WidgetTester t,
    ) async {
      final _Rig rig = _Rig();
      await rig.store.refresh();
      await pump(
        t,
        AssessmentListScreen(store: rig.store, portal: Portal.admin),
      );
      final int atRest = rig.calls.length;

      await type(t, 'forklift');
      await t.enterText(find.byType(TextFormField).first, '');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(
        find.text('Cached assessment'),
        findsOneWidget,
        reason: 'clearing the box returns the screen to its own cache',
      );
      expect(
        rig.calls.length,
        atRest + 1,
        reason: 'the one search, and NOTHING for clearing it - the empty term is '
            'not a query',
      );
    });

    testWidgets('a matched set larger than the page says so', (
      WidgetTester t,
    ) async {
      final _Rig rig = _Rig()..matchTotal = 4471;
      await rig.store.refresh();
      await pump(
        t,
        AssessmentListScreen(store: rig.store, portal: Portal.admin),
      );

      await type(t, 'a');

      // Property 3: a surface showing a bounded sample states the population.
      // TagChip upper-cases its label, so the assertion is on what is painted.
      expect(find.textContaining('OF 4471 MATCHING'), findsOneWidget);
      expect(find.textContaining('FIRST 1 SHOWN'), findsOneWidget);
    });
  });

  group('the question Bank', () {
    testWidgets('finds a question the client never held', (
      WidgetTester t,
    ) async {
      final _Rig rig = _Rig();
      await rig.store.refresh();
      await pump(t, BankScreen(store: rig.store));

      await type(t, 'forklift');

      expect(rig.searchesOn('/bank').length, 1);
      // The bank grid prints the name AND the prompt, which this fixture sets to
      // the same string.
      expect(find.text('Server question forklift'), findsWidgets);
    });

    testWidgets('an empty box issues nothing', (WidgetTester t) async {
      final _Rig rig = _Rig();
      await rig.store.refresh();
      await pump(t, BankScreen(store: rig.store));
      final int atRest = rig.calls.length;

      await t.enterText(find.byType(TextFormField).first, '');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(rig.calls.length, atRest);
      expect(find.text('Cached question'), findsWidgets);
    });
  });

  group('the Generators list', () {
    testWidgets('finds a generator the client never held', (
      WidgetTester t,
    ) async {
      final _Rig rig = _Rig();
      await rig.store.refresh();
      await pump(t, GeneratorListScreen(store: rig.store));

      await type(t, 'forklift');

      // This one needed `api_client.generators()` to carry the parameter at all.
      expect(rig.searchesOn('/generators').length, 1);
      expect(rig.searchesOn('/generators').single.search, 'forklift');
      expect(find.text('Server generator forklift'), findsOneWidget);
    });
  });

  group('the store, directly', () {
    test('a search never touches the console-wide caches', () async {
      // The hazard the roster cache exists to avoid, in its other form: the
      // KPIs, the pickers and both "show archived" toggles all read these
      // lists, so a search result written over the top would shrink every one
      // of them to whatever the operator last typed.
      final _Rig rig = _Rig();
      await rig.store.refresh();
      final int assessments = rig.store.assessments.length;
      final int bank = rig.store.bank.length;
      final int generators = rig.store.generators.length;

      await rig.store.searchAssessments('forklift');
      await rig.store.searchBank('forklift');
      await rig.store.searchGenerators('forklift');

      expect(rig.store.assessments.length, assessments);
      expect(rig.store.bank.length, bank);
      expect(rig.store.generators.length, generators);
      expect(rig.store.assessmentSearch.rows.length, 1);
      expect(rig.store.bankSearch.rows.length, 1);
      expect(rig.store.generatorSearch.rows.length, 1);
    });

    test('an abandoned term cannot overwrite a newer one', () async {
      final _Rig rig = _Rig();
      await rig.store.refresh();

      // Both in flight; the second is the one the operator is waiting for.
      final Future<void> first = rig.store.searchAssessments('a');
      final Future<void> second = rig.store.searchAssessments('aahan');
      await Future.wait<void>(<Future<void>>[first, second]);

      expect(
        rig.store.assessmentSearch.term,
        'aahan',
        reason: 'last write wins by sequence number, not by arrival order',
      );
    });

    test('a failed search reports the failure instead of an empty result',
        () async {
      final AppStore s = AppStore(
        api: ApiClient(
          client: MockClient((http.Request req) async {
            final Map<String, dynamic> body =
                jsonDecode(req.body) as Map<String, dynamic>;
            if (((body['search'] as String?) ?? '').isNotEmpty) {
              return http.Response(
                jsonEncode(<String, dynamic>{
                  'ok': false,
                  'error': <String, dynamic>{
                    'code': 'server_error',
                    'message': 'the search timed out',
                  },
                }),
                500,
                headers: <String, String>{'content-type': 'application/json'},
              );
            }
            return _Rig._json(<dynamic>[]);
          }),
          baseUrl: 'http://x',
        ),
      );

      await s.searchAssessments('forklift');

      expect(s.assessmentSearch.error, isNotEmpty);
      expect(s.assessmentSearch.rows, isEmpty);
      expect(
        s.assessmentSearch.total,
        0,
        reason: 'a failed search must not leave a stale count claiming matches',
      );
    });
  });
}
