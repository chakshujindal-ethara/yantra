// The Candidates tiles are ONE choice (15 Oct, R1).
//
// Every tile is counted over the same cohort, so a state chip AND-ed with a
// verdict showed rows no tile's number described. What each case pins:
//   - an old `?state=submitted&result=fail` link opens on the verdict alone;
//   - the rows of the last slice dim while another loads, so they are not read
//     as the answer to the new one - and a same-slice refetch does not dim;
//   - a page past the end (`?page=3` over one row) is clamped AND fetched, so
//     the rows, the pager and the URL agree.
@TestOn('vm')
library;

import 'dart:async';
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
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/data_grid.dart';

class _Rig {
  final AssessmentNav nav = AssessmentNav();

  /// The body of every `/candidates` request, in order.
  final List<Map<String, dynamic>> asked = <Map<String, dynamic>>[];

  /// When set, `/candidates` waits on it.
  Completer<void>? gate;

  late final AppStore store;

  _Rig() {
    store = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          if (path.endsWith('/candidates')) {
            asked.add(jsonDecode(req.body) as Map<String, dynamic>);
            if (gate != null) await gate!.future;
            return _json(
              <dynamic>[
                <String, dynamic>{
                  'id': '100',
                  'assessment_id': '58',
                  'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita'},
                  'state': 'submitted',
                  'result': 'fail',
                },
              ],
              meta: <String, dynamic>{
                'total': 1,
                'counts': <String, int>{
                  'all': 9,
                  'pending': 1,
                  'in_progress': 2,
                  'submitted': 6,
                  'scored': 4,
                  'score_pending': 2,
                  'pass': 3,
                  'fail': 2,
                },
              },
            );
          }
          if (path.endsWith('/assessments')) return _json(<dynamic>[_asm]);
          if (RegExp(r'/assessments/[^/]+$').hasMatch(path)) return _json(_asm);
          return _json(<String, dynamic>{});
        }),
      ),
    );
  }

  static const Map<String, dynamic> _asm = <String, dynamic>{
    'id': '58',
    'name': 'Q7r',
    'state': 'in_progress',
    'active': true,
  };

  static http.Response _json(Object data, {Map<String, dynamic>? meta}) =>
      http.Response(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'data': data,
          if (data is List)
            'meta': meta ?? <String, dynamic>{'total': data.length},
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );

  Widget app() => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: AssessmentNavScope(
        nav: nav,
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

Future<_Rig> _open(WidgetTester t, {Map<String, Object?>? query}) async {
  t.view.physicalSize = const Size(1600, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final _Rig r = _Rig();
  if (query != null) r.nav.setQuery(query);
  await r.store.refresh();
  await t.pumpWidget(r.app());
  await t.pumpAndSettle();
  return r;
}

Finder _chip(String label) => find.widgetWithText(Btn, label);

bool _pressed(WidgetTester t, String label) =>
    t.widget<Btn>(_chip(label)).pressed == true;

/// The dimmest Opacity above the roster table.
double _rowOpacity(WidgetTester t) => t
    .widgetList<Opacity>(
      find.ancestor(of: find.byType(DataGrid), matching: find.byType(Opacity)),
    )
    .fold<double>(1, (double m, Opacity o) => o.opacity < m ? o.opacity : m);

void main() {
  testWidgets('an old state-and-result link opens on the verdict alone', (
    WidgetTester t,
  ) async {
    final _Rig r = await _open(
      t,
      query: <String, Object?>{'state': 'submitted', 'result': 'fail'},
    );

    expect(r.asked.first['result'], 'fail');
    expect(r.asked.first.containsKey('state'), isFalse);
    expect(_pressed(t, 'Failed  2'), isTrue);
    expect(_pressed(t, 'Submitted  6'), isFalse);
    // Ported to main without stage's `Btn` semantics change (the lit tile
    // announced as selected): that wraps every button in the app, exam
    // included, and is left for a later release.
    expect(r.nav.query['state'] ?? '', isEmpty);
    expect(r.nav.query['result'], 'fail');
  });

  testWidgets('the rows dim while another tile loads', (WidgetTester t) async {
    final _Rig r = await _open(t);
    expect(_rowOpacity(t), 1);

    r.gate = Completer<void>();
    await t.tap(_chip('Failed  2'));
    await t.pump();

    expect(
      _rowOpacity(t),
      lessThan(1),
      reason: 'the rows on screen answer All, not Failed',
    );

    r.gate!.complete();
    await t.pumpAndSettle();
    expect(_rowOpacity(t), 1);
  });

  testWidgets('a refetch of the same slice does not dim', (
    WidgetTester t,
  ) async {
    final _Rig r = await _open(t);

    r.gate = Completer<void>();
    // What the tab sends after an action or a scoring run: the same slice.
    unawaited(r.store.loadRoster('58', pageSize: 100));
    await t.pump();

    expect(_rowOpacity(t), 1);

    r.gate!.complete();
    await t.pumpAndSettle();
  });

  testWidgets('a page past the end is clamped and fetched', (
    WidgetTester t,
  ) async {
    final _Rig r = await _open(t, query: <String, Object?>{'page': '3'});

    expect(r.asked.first['offset'], 200);
    expect(
      r.asked.last['offset'],
      0,
      reason: 'one row lives on page 1, so page 1 is what has to be asked for',
    );
    expect(r.nav.query.containsKey('page'), isFalse);
    expect(find.text('Anita'), findsOneWidget);
  });
}
