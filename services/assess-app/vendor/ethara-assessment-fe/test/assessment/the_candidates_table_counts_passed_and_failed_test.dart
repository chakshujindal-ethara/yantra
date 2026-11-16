// The Candidates tab filters by VERDICT, not only by state.
//
// "Who passed?" and "who failed?" were answerable only by reading the Result
// column of one page at a time. The roster route now takes `result` (`pass` |
// `fail`) beside `state` and counts both in `meta.counts.pass` / `.fail`, so
// the tab gets two more chips after Scored / Score Pending.
//
// THE THREE THINGS THAT CAN GO WRONG, and what each case below pins:
//   - the chip is drawn but asks for the wrong thing (a key spelled `verdict`,
//     a verdict sent as `state`, which no row has ever held);
//   - the verdict is AND-ed with a pressed state chip: every tile is counted
//     over the same cohort, so the tiles are ONE choice and "Failed" after
//     "Submitted" sends the verdict alone (15 Oct, R1);
//   - a chip at 0 is hidden, which is right until it is the pressed one.
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
import 'package:ethara_assessment/assessment/widgets/buttons.dart';

class _Rig {
  Map<String, int> counts = <String, int>{
    'all': 9,
    'pending': 1,
    'in_progress': 2,
    'submitted': 6,
    'scored': 4,
    'score_pending': 2,
    'pass': 3,
    'fail': 2,
  };

  /// The body of every `/candidates` request, in order.
  final List<Map<String, dynamic>> asked = <Map<String, dynamic>>[];

  late final AppStore store;

  _Rig() {
    store = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          if (path.endsWith('/candidates')) {
            asked.add(jsonDecode(req.body) as Map<String, dynamic>);
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
              meta: <String, dynamic>{'total': 1, 'counts': counts},
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

Future<_Rig> _open(WidgetTester t) async {
  t.view.physicalSize = const Size(1600, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final _Rig r = _Rig();
  await r.store.refresh();
  await t.pumpWidget(r.app());
  await t.pumpAndSettle();
  return r;
}

Finder _chip(String label) => find.widgetWithText(Btn, label);

bool _pressed(WidgetTester t, String label) =>
    t.widget<Btn>(_chip(label)).pressed == true;

void main() {
  testWidgets('Passed and Failed show the server counts, after Score Pending', (
    WidgetTester t,
  ) async {
    await _open(t);

    expect(_chip('Passed  3'), findsOneWidget);
    expect(_chip('Failed  2'), findsOneWidget);
    expect(
      t.getTopLeft(_chip('Passed  3')).dx,
      greaterThan(t.getTopLeft(_chip('Score Pending  2')).dx),
      reason: 'the verdict chips follow the Scored / Score Pending pair',
    );
    expect(_chip('Flagged'), findsOneWidget, reason: 'Flagged is untouched');
  });

  testWidgets('an unfiltered read sends no result term', (
    WidgetTester t,
  ) async {
    final _Rig r = await _open(t);

    expect(r.asked, isNotEmpty);
    expect(
      r.asked.every((Map<String, dynamic> b) => !b.containsKey('result')),
      isTrue,
      reason: 'the default read must be the request it always was',
    );
  });

  testWidgets('selecting Failed asks the route for result: fail', (
    WidgetTester t,
  ) async {
    final _Rig r = await _open(t);

    await t.tap(_chip('Failed  2'));
    await t.pumpAndSettle();

    expect(r.asked.last['result'], 'fail');
    expect(
      r.asked.last.containsKey('state'),
      isFalse,
      reason: 'a verdict is not a state - sending it as one asks for a state '
          'no row has ever held',
    );
    expect(_pressed(t, 'Failed  2'), isTrue);
    expect(_pressed(t, 'Passed  3'), isFalse);
  });

  testWidgets('a verdict replaces the pressed state', (WidgetTester t) async {
    final _Rig r = await _open(t);

    await t.tap(_chip('Submitted  6'));
    await t.pumpAndSettle();
    await t.tap(_chip('Failed  2'));
    await t.pumpAndSettle();

    expect(r.asked.last['result'], 'fail');
    expect(
      r.asked.last.containsKey('state'),
      isFalse,
      reason: 'one tile at a time: Failed counts every failed candidate, so '
          'the rows under it must be every failed candidate too',
    );
    expect(_pressed(t, 'Submitted  6'), isFalse);
    expect(_pressed(t, 'Failed  2'), isTrue);
  });

  testWidgets('Passed and Failed exclude each other; pressing the lit tile '
      'sends nothing', (WidgetTester t) async {
    final _Rig r = await _open(t);

    await t.tap(_chip('Failed  2'));
    await t.pumpAndSettle();
    await t.tap(_chip('Passed  3'));
    await t.pumpAndSettle();

    expect(r.asked.last['result'], 'pass');
    expect(_pressed(t, 'Passed  3'), isTrue);
    expect(_pressed(t, 'Failed  2'), isFalse, reason: 'one verdict at a time');

    final int before = r.asked.length;
    await t.tap(_chip('Passed  3'));
    await t.pumpAndSettle();

    expect(r.asked.length, before, reason: 'a lit tile is not a toggle');
    expect(_pressed(t, 'Passed  3'), isTrue, reason: 'All is the way back');
  });

  testWidgets('All clears a pressed verdict too', (WidgetTester t) async {
    final _Rig r = await _open(t);

    await t.tap(_chip('Failed  2'));
    await t.pumpAndSettle();
    expect(_pressed(t, 'All  9'), isFalse);

    await t.tap(_chip('All  9'));
    await t.pumpAndSettle();

    expect(r.asked.last.containsKey('result'), isFalse);
    expect(_pressed(t, 'All  9'), isTrue);
  });

  testWidgets('a verdict nobody holds is hidden, unless it is pressed', (
    WidgetTester t,
  ) async {
    final _Rig r = await _open(t);

    r.counts = <String, int>{...r.counts, 'pass': 0};
    await r.store.loadRoster('58');
    await t.pumpAndSettle();

    expect(find.textContaining('Passed'), findsNothing);
    expect(_chip('Failed  2'), findsOneWidget);

    // Pressed, then the last failure is re-scored to a pass: the chip the
    // operator is standing on must not vanish from under them.
    await t.tap(_chip('Failed  2'));
    await t.pumpAndSettle();
    r.counts = <String, int>{...r.counts, 'pass': 5, 'fail': 0};
    await r.store.loadRoster('58', result: 'fail');
    await t.pumpAndSettle();

    expect(_chip('Failed  0'), findsOneWidget);
    expect(_pressed(t, 'Failed  0'), isTrue);
  });

  testWidgets('a server that sends no verdict counts shows no verdict chips', (
    WidgetTester t,
  ) async {
    final _Rig r = _Rig();
    r.counts = <String, int>{'all': 9, 'submitted': 6};
    t.view.physicalSize = const Size(1600, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await r.store.refresh();
    await t.pumpWidget(r.app());
    await t.pumpAndSettle();

    expect(find.textContaining('Passed'), findsNothing);
    expect(find.textContaining('Failed'), findsNothing);
  });

  // The lit tile was drawn with `onPressed: null`, and a `Btn` with no handler
  // is a DISABLED one: faded to .42, fainter than the unlit tiles beside it.
  testWidgets('the lit tile reads as selected, not disabled', (
    WidgetTester t,
  ) async {
    await _open(t);
    double ink(String label) => t
        .widget<Opacity>(
          find.descendant(of: _chip(label), matching: find.byType(Opacity)),
        )
        .opacity;

    expect(_pressed(t, 'All  9'), isTrue);
    expect(ink('All  9'), 1.0);

    await t.tap(_chip('Failed  2'));
    await t.pumpAndSettle();
    expect(_pressed(t, 'Failed  2'), isTrue);
    expect(ink('Failed  2'), 1.0);
  });
}
