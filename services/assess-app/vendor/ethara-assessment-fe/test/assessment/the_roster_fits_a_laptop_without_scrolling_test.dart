// The Candidates table fits a laptop screen, with no horizontal scrolling.
//
// WHY THIS IS A TEST AND NOT A STYLE NOTE. Columns are added one at a time by
// people who are looking at a wide external monitor, and each addition looks
// harmless. Two of them together pushed this grid to 1440px, which on a 14-inch
// MacBook put the last two columns roughly 700px off the right edge - and
// because macOS hides scrollbars until you gesture, the table did not look
// truncated. It looked like the columns had never been built. That is exactly
// what was reported.
//
// So the budget is pinned here instead: at the widths a reviewer actually uses,
// every header must be reachable without scrolling. A column added later either
// fits inside the budget or fails this test, which is the point.
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

/// Every header the Candidates table is expected to carry, in order.
///
/// `FLAGS` is deliberately absent: the advisory badges moved off this table
/// when the flag got a column of its own, and two columns both called some
/// variant of "flag" is what the reviewer objected to.
const List<String> kHeaders = <String>[
  'CANDIDATE', 'INVITE', 'STATE', 'ANSWERED',
  'SCORE', 'RESULT', 'RELEASED', 'REMARKS', 'FLAG',
];

Map<String, dynamic> _row(String id, String name, Map<String, dynamic>? flag) =>
    <String, dynamic>{
      'id': id,
      'assessment_id': '58',
      'candidate': <String, dynamic>{'id': 'p$id', 'name': name},
      'state': 'submitted',
      'answered_count': 13,
      'total_questions': 19,
      'results_released': true,
      'flags': <String, dynamic>{'manual_flagged': flag?['flagged'] ?? false},
      'candidate_flag': ?flag,
    };

http.Response _json(Object d, {int? total}) => http.Response(
    jsonEncode(<String, dynamic>{
      'ok': true,
      'data': d,
      if (d is List)
        'meta': <String, dynamic>{
          'total': total ?? d.length,
          'limit': 200,
          'offset': 0,
          'has_more': false,
        },
    }),
    200,
    headers: <String, String>{'content-type': 'application/json'});

AppStore _store() {
  final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
    _row('1', 'Aahan Trikha', null),
    _row('2', 'Jaahanvi', <String, dynamic>{
      'flagged': true,
      'remark': 'Left the room twice without telling the proctor.',
      'by': 'Akshay Kumar',
      'at': '2026-09-08T09:15:00',
    }),
  ];
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://x',
      client: MockClient((http.Request q) async {
        final String p = q.url.path;
        if (p.endsWith('/candidates')) return _json(rows, total: rows.length);
        if (p.endsWith('/attempts')) return _json(rows, total: rows.length);
        if (p.endsWith('/assessments')) {
          return _json(<dynamic>[
            <String, dynamic>{
              'id': '58', 'name': 'A', 'state': 'done', 'active': true,
            },
          ]);
        }
        if (RegExp(r'/assessments/[^/]+$').hasMatch(p)) {
          return _json(<String, dynamic>{
            'id': '58', 'name': 'A', 'state': 'done', 'active': true,
          });
        }
        return _json(<String, dynamic>{});
      }),
    ),
  );
  s.accessRole = AccessRole.admin;
  s.caps = Capability.values.toSet();
  return s;
}

void main() {
  // The content pane, not the screen: a 14-inch MacBook is 1512 logical points
  // wide and the nav rail takes ~260 of them. The Assessment History panel
  // takes another ~430 when it is OPEN, which no nine-column table can survive
  // - that case is left to the scrollbar, and it is why the scrollbar is drawn
  // even when the platform would hide it.
  for (final (String label, double width) in <(String, double)>[
    ('a 14-inch MacBook', 1250),
    ('a 13-inch Air', 1210),
    // THE CASE THAT WAS REPORTED: the Assessment History panel OPEN on a
    // 1728-point screen leaves the content pane around 1000, and the table was
    // scrolling there with the Flag column off the edge.
    ('a 16-inch with the history panel open', 1000),
    ('a narrow window', 980),
  ]) {
    testWidgets('every column is reachable on $label', (WidgetTester t) async {
      await t.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: AssessmentNavScope(
            nav: AssessmentNav(),
            child: SingleChildScrollView(
              child: AssessmentDetailScreen(
                store: _store(),
                portal: Portal.admin,
                asmId: '58',
                tab: 'candidates',
              ),
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();

      final Finder grid = find.byType(DataGrid);
      final List<String> offscreen = <String>[];
      for (final String h in kHeaders) {
        final Finder f = find.descendant(of: grid, matching: find.text(h));
        expect(f, findsOneWidget, reason: '$h is missing from the table');
        if (t.getRect(f.first).right > width) offscreen.add(h);
      }
      expect(offscreen, isEmpty,
          reason: 'these columns need a horizontal scroll on $label, which is '
              'how the Remarks and Flag columns came to be reported missing: '
              '${offscreen.join(", ")}');
    });
  }

  testWidgets('the pager sits against the right edge', (WidgetTester t) async {
    // IT USED TO LAND IN THE MIDDLE. The pagination row put the count text in
    // a `Flexible` and the page controls after a `Spacer`, both flex 1, so the
    // free width was SPLIT between them - and a loose `Flexible` leaves its
    // unused share blank. Previous/Page/Next drifted to the centre of the row,
    // which is what was reported.
    await t.binding.setSurfaceSize(const Size(1250, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: SingleChildScrollView(
            child: AssessmentDetailScreen(
              store: _store(), portal: Portal.admin, asmId: '58',
              tab: 'candidates'),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();

    final Finder next = find.text('Next');
    final Finder count = find.textContaining('of 2 candidates');
    expect(next, findsOneWidget);
    expect(count, findsOneWidget);

    // "Next" must sit in the far right of the row, not near its middle.
    final double nextRight = t.getRect(next).right;
    expect(t.getRect(count).left, lessThan(1250 * 0.3),
        reason: 'the count still anchors the left of the row');
    expect(nextRight, greaterThan(1250 * 0.80),
        reason: 'Previous/Page/Next belong against the right edge, not '
            'floating in the middle of the row');
  });

  testWidgets('the columns keep an even rhythm', (WidgetTester t) async {
    // THE "SHAKY" LOOK, pinned so it cannot come back.
    //
    // Alignment used to be binary - `numeric` right, everything else left - so
    // a right-aligned SCORE header sat flush against a left-aligned RESULT
    // header with no gap at all, while the columns either side carried 60px of
    // dead space. Every fixed column now centres its content, which makes each
    // one's gap to its neighbour exactly the grid's own 12px gutter regardless
    // of how wide the columns themselves are.
    await t.binding.setSurfaceSize(const Size(1250, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: SingleChildScrollView(
            child: AssessmentDetailScreen(
              store: _store(), portal: Portal.admin, asmId: '58',
              tab: 'candidates'),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();

    // MEASURED ON THE HEADER CELL, not on its label.
    //
    // It used to be the label's own `Text`, which worked only while every
    // header was a bare `Text` filling its column: the cell's rect and the
    // label's rect were the same rectangle. Every column on this table sorts
    // now, so a header is a `Row` of label + reserved caret and the `Text`
    // shrinks to the width of the word inside it - which reported the leftover
    // column space as the gutter (294px between CANDIDATE and INVITE) and said
    // the rhythm had broken when the columns had not moved at all. The cell is
    // what the rhythm is actually about, and the `GestureDetector` the sortable
    // header hangs its tap on spans exactly that cell.
    final Finder grid = find.byType(DataGrid);
    final List<double> gaps = <double>[];
    Rect? prev;
    for (final String h in kHeaders) {
      final Rect r = t.getRect(
        find
            .ancestor(
              of: find.descendant(of: grid, matching: find.text(h)).first,
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      if (prev != null) gaps.add(r.left - prev.right);
      prev = r;
    }
    expect(gaps, isNotEmpty);
    for (final double g in gaps) {
      expect(g, closeTo(12, 0.5),
          reason: 'every column should be one gutter from the next; uneven '
              'gaps are what read as columns of random width. Got: $gaps');
    }
  });

  testWidgets('the advisory Flags column is gone', (WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1250, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: SingleChildScrollView(
            child: AssessmentDetailScreen(
              store: _store(), portal: Portal.admin, asmId: '58',
              tab: 'candidates'),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(
      find.descendant(of: find.byType(DataGrid), matching: find.text('FLAGS')),
      findsNothing,
      reason: 'one column named FLAG is enough; two were confusing',
    );
  });
}
