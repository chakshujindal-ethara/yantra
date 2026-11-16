// A chip whose filter is applied never leaves the row, however small its count
// gets.
//
// Chips hide themselves at count 0, which is right for every chip nobody
// pressed - a filter with nobody in it is not worth a click. It is wrong for
// the one that IS pressed: the count drops, the chip vanishes, and the operator
// is left with an unexplained "No candidate matches these filters." over a row
// of chips where none is pressed. There is then nothing on screen saying what
// is being filtered, or anything to press to undo it.
//
// The natural trigger is the end of a re-score run watched from this tab - the
// workflow these chips were added for. "Score Pending 2" is pressed, the last
// two answers are graded, the tab refetches, `score_pending` is 0, and the chip
// the operator is standing on disappears out from under them.
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
  };

  late final AppStore store;

  _Rig() {
    store = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          if (path.endsWith('/candidates')) {
            return _json(
              <dynamic>[
                <String, dynamic>{
                  'id': '100',
                  'assessment_id': '58',
                  'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita'},
                  'state': 'submitted',
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

void main() {
  testWidgets('a pressed scoring chip survives its count reaching 0', (
    WidgetTester t,
  ) async {
    final _Rig r = await _open(t);

    await t.tap(find.text('Score Pending  2'));
    await t.pumpAndSettle();

    // The run ends: the last two answers are graded and the tab refetches.
    r.counts = <String, int>{...r.counts, 'scored': 6, 'score_pending': 0};
    await r.store.loadRoster('58', state: 'score_pending');
    await t.pumpAndSettle();

    final Finder chip = find.widgetWithText(Btn, 'Score Pending  0');
    expect(
      chip,
      findsOneWidget,
      reason:
          'the filter is still applied, so the row must keep saying so - an '
          'empty table under no pressed chip explains nothing',
    );
    expect(
      t.widget<Btn>(chip).pressed,
      isTrue,
      reason: 'and it must still read as the pressed one',
    );
  });

  testWidgets('a pressed state chip survives too', (WidgetTester t) async {
    final _Rig r = await _open(t);

    await t.tap(find.text('In progress  2'));
    await t.pumpAndSettle();

    // Both sittings are submitted while the tab is open.
    r.counts = <String, int>{...r.counts, 'in_progress': 0, 'submitted': 8};
    await r.store.loadRoster('58', state: 'in_progress');
    await t.pumpAndSettle();

    expect(find.widgetWithText(Btn, 'In progress  0'), findsOneWidget);
  });

  testWidgets('an UNPRESSED chip at 0 still steps aside', (
    WidgetTester t,
  ) async {
    final _Rig r = await _open(t);

    r.counts = <String, int>{...r.counts, 'score_pending': 0};
    await r.store.loadRoster('58');
    await t.pumpAndSettle();

    expect(
      find.textContaining('Score Pending'),
      findsNothing,
      reason: 'the exemption is for the pressed chip only',
    );
  });
}
