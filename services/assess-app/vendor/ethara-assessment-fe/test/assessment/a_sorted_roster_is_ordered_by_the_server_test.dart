// The roster's column headers sort the COHORT, by asking the server for it.
//
// WHY THIS FILE IS ABOUT REQUESTS AND NOT ABOUT ROWS. The Candidates tab pages
// server-side at up to 200 rows and a live cohort on assessment 57 is 711, so a
// comparator in Dart would order 200 of 711 rows and label the result "sorted
// by score" - with the top scorer sitting on page 3, never shown, and nothing
// on screen saying the ordering was partial. That is the defect this feature
// exists to avoid, so the assertions below are deliberately the opposite of the
// ones a client-side sort would want: the fake server NEVER re-orders anything,
// and every test checks that the request carried the sort and that the rows on
// screen are still exactly what the server handed over.
//
// `responses_screen.dart` does sort in Dart, over a single unpaged fetch. The
// header affordance is shared with this screen; the comparator is not.
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
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/data_grid.dart';

/// One roster request, with the body it carried.
class Call {
  Call(this.body);
  final Map<String, dynamic> body;

  // `sort` / `sort_desc` are the route's own argument names - see
  // `_attempt_order()` in `controllers/api/admin.py`. Asserting on them here is
  // the only place the two halves of this feature are checked against each
  // other: the route treats an unknown key as "no sort" and degrades to
  // newest-first, so a rename on either side produces a roster that is simply
  // never ordered, under a header that draws a caret as if it were.
  bool get sorted => body.containsKey('sort');
  String get order => (body['sort'] as String?) ?? '';
  // Absent means ascending, which is the route's default.
  String get dir => (body['sort_desc'] == true) ? 'desc' : 'asc';
  int get offset => (body['offset'] as num?)?.toInt() ?? -1;

  @override
  String toString() => 'sort=$order dir=$dir offset=$offset';
}

/// The nine sortable columns, as the header renders them and as the route reads
/// them. The pairing is the thing under test: `DataGrid` reports a column INDEX
/// and the screen alone knows which key that index means, so a column inserted
/// without its key would re-order the table by its neighbour - plausibly, and
/// wrongly.
const Map<String, String> kHeaderKeys = <String, String>{
  'CANDIDATE': 'candidate',
  'INVITE': 'invite',
  'STATE': 'state',
  'ANSWERED': 'answered',
  'SCORE': 'score',
  'RESULT': 'result',
  'RELEASED': 'released',
  'REMARKS': 'remarks',
  'FLAG': 'flag',
};

Map<String, dynamic> asmRow(String id) => <String, dynamic>{
  'id': id,
  'name': 'Q7r + Grade & Fix (copy)',
  'state': 'done',
  'active': true,
  'assigned_count': _Rig.cohort,
};

Map<String, dynamic> attemptRow(String id, String name) => <String, dynamic>{
  'id': id,
  'assessment_id': '58',
  'candidate': <String, dynamic>{'id': 'p$id', 'name': name},
  'state': 'submitted',
  'answered_count': 13,
  'total_questions': 19,
};

class _Rig {
  final List<Call> roster = <Call>[];
  late final AppStore store;

  /// Bigger than one page, so "back to page 1" is a state that can be left.
  static const int cohort = 250;

  /// THE SERVER'S ORDER, and jumbled on purpose. The first three names are not
  /// alphabetical, so a client that sorted its page by CANDIDATE would put
  /// "Aahan Trikha" first and be caught by the assertions that expect "Zoe
  /// Adams" to still be there.
  static final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
    attemptRow('1001', 'Zoe Adams'),
    attemptRow('1002', 'Aahan Trikha'),
    attemptRow('1003', 'Mira Banerjee'),
    for (int i = 3; i < cohort; i++) attemptRow('${1000 + i}', 'Candidate $i'),
  ];

  void init() {
    store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          final Map<String, dynamic> body =
              jsonDecode(req.body) as Map<String, dynamic>;

          if (path.endsWith('/candidates')) {
            roster.add(Call(body));
            // DELIBERATELY IGNORES THE SORT. A fake that honoured it could not
            // tell a client that sorts locally from one that does not.
            final int limit = (body['limit'] as num?)?.toInt() ?? 40;
            final int offset = (body['offset'] as num?)?.toInt() ?? 0;
            return _json(
              rows.skip(offset).take(limit).toList(),
              total: rows.length,
            );
          }
          if (path.endsWith('/assessments')) {
            return _json(<dynamic>[asmRow('58')]);
          }
          if (path.endsWith('/attempts')) return _json(<dynamic>[]);
          if (RegExp(r'/assessments/[^/]+$').hasMatch(path)) {
            return _json(asmRow('58'));
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

  /// SCROLLABLE, like the real shell: a page of 100 rows is ~4,600px of table
  /// and an unscrolled host overflows during layout, masking every assertion
  /// under the exception.
  Widget app() => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: AssessmentNavScope(
        nav: AssessmentNav(),
        child: SingleChildScrollView(
          child: AssessmentDetailScreen(
            store: store,
            portal: Portal.admin,
            asmId: '58',
            tab: 'candidates',
          ),
        ),
      ),
    ),
  );
}

// ignore: library_private_types_in_public_api
Future<_Rig> open(WidgetTester t) async {
  t.view.physicalSize = const Size(1600, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);

  final _Rig r = _Rig();
  r.init();
  await r.store.refresh();
  await t.pumpWidget(r.app());
  await t.pumpAndSettle();
  return r;
}

/// A header, found inside the grid so a matching word elsewhere on the screen
/// cannot be tapped instead.
Finder header(String label) => find.descendant(
  of: find.byType(DataGrid),
  matching: find.text(label),
);

Future<void> tapHeader(WidgetTester t, String label) async {
  // SCROLLED TO FIRST. The page is 100 rows of table inside the shell's own
  // scroller, so an operator who has walked to the footer to page forward is
  // looking at row 90-odd - and a tap on a header that is off-screen silently
  // misses rather than failing, which would pass this file for the wrong
  // reason.
  await t.ensureVisible(header(label));
  await t.pumpAndSettle();
  await t.tap(header(label));
  await t.pumpAndSettle();
}

Finder caret(IconData icon) =>
    find.descendant(of: find.byType(DataGrid), matching: find.byIcon(icon));

void main() {
  group('the affordance', () {
    testWidgets('every sortable column offers a sort, and none is on yet', (
      WidgetTester t,
    ) async {
      final _Rig r = await open(t);

      for (final String label in kHeaderKeys.keys) {
        expect(header(label), findsOneWidget, reason: '$label is missing');
      }
      // The caret is drawn only on the ordering column, so an untouched roster
      // has none: the default is the route's own order, and a caret would claim
      // the operator had chosen it.
      expect(caret(Icons.arrow_upward), findsNothing);
      expect(caret(Icons.arrow_downward), findsNothing);
      expect(
        r.roster.single.sorted,
        isFalse,
        reason: 'an unsorted roster sends exactly the request it sent before '
            'this feature existed - no order term for the server to interpret',
      );
    });

    testWidgets('the header that was clicked is the one that carries a caret', (
      WidgetTester t,
    ) async {
      await open(t);
      await tapHeader(t, 'SCORE');

      expect(caret(Icons.arrow_upward), findsOneWidget);
      expect(caret(Icons.arrow_downward), findsNothing);
    });
  });

  group('a click is a request', () {
    testWidgets('each column asks the server for its own key', (
      WidgetTester t,
    ) async {
      final _Rig r = await open(t);

      // Every header in turn, so a column wired to its NEIGHBOUR's key - the
      // one failure of an index-keyed table that still looks right on screen -
      // is caught here rather than by an operator reading a table sorted by
      // something else.
      for (final MapEntry<String, String> e in kHeaderKeys.entries) {
        await tapHeader(t, e.key);
        expect(r.roster.last.order, e.value, reason: 'header ${e.key}');
        expect(r.roster.last.dir, 'asc');
        expect(r.roster.last.offset, 0);
      }
    });

    testWidgets('the rows are the server\'s, never re-ordered in the client', (
      WidgetTester t,
    ) async {
      final _Rig r = await open(t);
      final int before = r.roster.length;

      await tapHeader(t, 'CANDIDATE');

      expect(r.roster.length - before, 1, reason: 'one sort, one request');
      // The fake ignores the sort, so the rows come back in the jumbled order
      // it holds. A client-side comparator would put "Aahan Trikha" first here,
      // over a page that is 100 of 250 rows - the confident wrong answer.
      expect(r.store.rosterRowsFor('58').first.name, 'Zoe Adams');
      expect(find.text('Zoe Adams'), findsOneWidget);
    });

    testWidgets('a second click flips the direction, a third clears the sort', (
      WidgetTester t,
    ) async {
      final _Rig r = await open(t);

      await tapHeader(t, 'SCORE');
      expect(r.roster.last.dir, 'asc');

      await tapHeader(t, 'SCORE');
      expect(r.roster.last.order, 'score');
      expect(r.roster.last.dir, 'desc');
      expect(caret(Icons.arrow_downward), findsOneWidget);

      await tapHeader(t, 'SCORE');
      expect(
        r.roster.last.sorted,
        isFalse,
        reason: 'the third click returns to the route\'s own order, which is '
            'the only way back to it - so no order term is sent at all',
      );
      expect(caret(Icons.arrow_upward), findsNothing);
      expect(caret(Icons.arrow_downward), findsNothing);
    });
  });

  group('paging', () {
    testWidgets('changing the sort goes back to the first page', (
      WidgetTester t,
    ) async {
      final _Rig r = await open(t);

      // The footer sits under a 100-row table, so it is scrolled to first -
      // the same thing an operator does.
      await t.ensureVisible(find.text('Next'));
      await t.pumpAndSettle();
      await t.tap(find.text('Next'));
      await t.pumpAndSettle();
      expect(r.roster.last.offset, greaterThan(0), reason: 'now on page 2');

      await tapHeader(t, 'SCORE');

      expect(
        r.roster.last.offset,
        0,
        reason: 'page 2 by score is not page 2 by arrival order, so keeping '
            'the offset drops the operator part-way down a list they have not '
            'seen the start of',
      );
    });

    testWidgets('the next page of a sorted roster carries the same sort', (
      WidgetTester t,
    ) async {
      final _Rig r = await open(t);
      await tapHeader(t, 'SCORE');

      await t.ensureVisible(find.text('Next'));
      await t.pumpAndSettle();
      await t.tap(find.text('Next'));
      await t.pumpAndSettle();

      expect(r.roster.last.order, 'score');
      expect(r.roster.last.dir, 'asc');
      expect(
        r.roster.last.offset,
        greaterThan(0),
        reason: 'every page of a sorted cohort is a page of the SAME sort, or '
            'the pages are slices of different orderings stitched together',
      );
    });
  });
}
