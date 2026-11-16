// A capped response load must not read as the whole table - SNo 105/106.
//
// THE DEFECT. `/api/v1/responses` grows with every answer every candidate
// gives, so the boot walk is capped at two pages (400 rows) - the right trade
// against a route that reached 158 sequential POSTs on stage. But EVERY count on
// the Responses screen is folded from the rows the client happens to hold
// (`s.allResponses()`), so a capped load published "Answers 400" over a table of
// 4,471 - measured on etp_local - with nothing on screen to say otherwise. An
// operator auditing a score was reading a subset as a population.
//
// `pagesTruncated` has recorded the shortfall since the cap was written and NO
// WIDGET READ IT. That is the whole bug: the fact was known and never said.
//
// WHY THESE TESTS ARE SHAPED THIS WAY:
//
//  * THE STORE MUST KEEP THE SERVER'S OWN TOTAL. `meta.total` was read to
//    decide when to stop paging and then discarded, so the client could not
//    name the population even in principle. `the store keeps the server's row
//    count` pins the plumbing; without it the screen has nothing true to print.
//
//  * THE POPULATION IS THE HEADLINE. `the answers tile leads with the
//    population` reads the `Kpi` widget's own `value` field rather than
//    searching for text: '4471' would also match a page number or another
//    tile, and a test that passes against the reverted code is not evidence.
//
//  * A COMPLETE LOAD MUST NOT BE QUALIFIED. `an uncapped load says nothing
//    about sampling` is the negative half - a banner on a screen that really
//    does hold every row is noise that teaches operators to ignore it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/screens/admin/responses_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';
import 'package:ethara_assessment/assessment/nav.dart';

/// The real population on this dev database, and the cap the walk stops at.
const int kTotal = 4471;
const int kHeld = 400;

/// A backend whose `/responses` reports [total] rows and serves full pages, so
/// the walk stops at its own cap rather than at the end of the list.
http.Client server({int total = kTotal}) =>
    MockClient((http.Request req) async {
      final String path = req.url.path;
      int offset = 0;
      if (req.body.isNotEmpty) {
        final Object? decoded = jsonDecode(req.body);
        if (decoded is Map && decoded['offset'] is int) {
          offset = decoded['offset'] as int;
        }
      }

      Object body;
      if (path.endsWith('/responses')) {
        final int remaining = (total - offset).clamp(0, 200);
        body = <String, dynamic>{
          'ok': true,
          'data': <Map<String, dynamic>>[
            for (int i = 0; i < remaining; i++)
              <String, dynamic>{
                'id': offset + i,
                'evaluator_id': 1,
                'assessment_id': 55,
                'question_id': 1,
                'question_type': 'mcq',
                'state': 'submitted',
                'mark': 1,
                'mark_out_of': 1,
                'candidate': <String, dynamic>{'id': 1, 'name': 'Priya Sharma'},
              },
          ],
          'meta': <String, dynamic>{
            'total': total,
            'limit': 200,
            'offset': offset,
            'has_more': offset + 200 < total,
          },
        };
      } else if (path.endsWith('/auth_token')) {
        body = <String, dynamic>{
          'data': <String, dynamic>{
            'access_token': 't',
            'user_type': 'admin',
            'name': 'Admin',
          },
        };
      } else {
        body = <String, dynamic>{
          'ok': true,
          'data': <Map<String, dynamic>>[],
          'meta': <String, dynamic>{
            'total': 0,
            'limit': 200,
            'offset': 0,
            'has_more': false,
          },
        };
      }
      return http.Response(
        jsonEncode(body),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

Future<AppStore> loaded({int total = kTotal}) async {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: server(total: total),
        bearer: 'stub'),
  )..portal = Portal.admin;
  await s.refresh();
  return s;
}

Widget mount(AppStore s) => MaterialApp(
  theme: ThemeData.dark(),
  home: AssessmentNavScope(
    nav: AssessmentNav(),
    child: Scaffold(body: ResponsesScreen(store: s)),
  ),
);

/// The value a named KPI is showing, read off the widget's own field.
///
/// NOT `find.text('4471')`. A bare number matches a page control or another
/// tile, so an assertion built on it can pass against the reverted code - the
/// exact vacuous test that had to be fixed once already on the candidates tile.
String kpiValue(WidgetTester t, String label) {
  final Finder f = find.byWidgetPredicate(
    (Widget w) => w is Kpi && w.label == label,
  );
  expect(f, findsOneWidget, reason: 'no KPI labelled "$label"');
  return t.widget<Kpi>(f).value;
}

void main() {
  test('the store keeps the server\'s row count, not just what it holds',
      () async {
    final AppStore s = await loaded();

    expect(s.pagesTruncated, isTrue, reason: 'the walk stopped at its cap');
    expect(s.responseRows, hasLength(kHeld));
    expect(s.responsesTotal, kTotal,
        reason: 'meta.total was read to stop paging and then discarded, so the '
            'client could not name the population at all');
  });

  test('a load that completes reports the real total and no shortfall',
      () async {
    final AppStore s = await loaded(total: 150);

    expect(s.pagesTruncated, isFalse);
    expect(s.responsesTotal, 150,
        reason: 'the total is reported on every page, so a completed walk '
            'overwrites a stale figure from a previous load');
  });

  testWidgets('the answers tile leads with the population, not the sample',
      (WidgetTester t) async {
    t.view.physicalSize = const Size(1700, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final AppStore s = await loaded();
    await t.pumpWidget(mount(s));
    await t.pump(const Duration(milliseconds: 300));

    expect(kpiValue(t, 'Answers'), '$kTotal',
        reason: 'the big figure is what gets read and quoted, so it has to be '
            'the number of answers that EXIST');
    expect(find.textContaining('$kHeld most recent loaded'), findsWidgets,
        reason: 'the sample is the qualifier');
  });

  testWidgets('the sample is named above the table', (WidgetTester t) async {
    t.view.physicalSize = const Size(1700, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final AppStore s = await loaded();
    await t.pumpWidget(mount(s));
    await t.pump(const Duration(milliseconds: 300));

    expect(
      find.textContaining('Showing the $kHeld most recent of $kTotal answers'),
      findsOneWidget,
    );
    // AND WHERE TO GO INSTEAD. Every filter on this screen narrows the rows
    // already held, so "filter to see the rest" would be false; a sitting
    // carries all of its own answers, which is where a row click already leads.
    expect(
      find.textContaining('Open a candidate or a sitting'),
      findsOneWidget,
    );
  });

  testWidgets('the folded counts say which rows they counted',
      (WidgetTester t) async {
    t.view.physicalSize = const Size(1700, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final AppStore s = await loaded();
    await t.pumpWidget(mount(s));
    await t.pump(const Duration(milliseconds: 300));

    // "none outstanding" beside Unresolved is a claim about the ORG that the
    // client cannot make from 400 of 4,471 rows - and it is the claim an
    // operator would stop looking after.
    expect(find.text('none outstanding'), findsNothing);
    expect(find.textContaining('in the $kHeld loaded'), findsWidgets);
  });

  testWidgets('an uncapped load says nothing about sampling',
      (WidgetTester t) async {
    t.view.physicalSize = const Size(1700, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    // THE NEGATIVE HALF. A banner on a screen that really does hold every row
    // is noise, and noise is what teaches an operator to skip the banner that
    // matters.
    final AppStore s = await loaded(total: 150);
    await t.pumpWidget(mount(s));
    await t.pump(const Duration(milliseconds: 300));

    expect(kpiValue(t, 'Answers'), '150');
    expect(find.textContaining('most recent of'), findsNothing);
    expect(find.textContaining('in the'), findsNothing);
    expect(find.text('submitted across the org'), findsOneWidget);
  });
}
