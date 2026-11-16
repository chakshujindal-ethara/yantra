// Walking from one assessment's Candidates tab to another's (15 Oct, R1).
//
// The router reuses the same tab State across that walk, so a tile pressed on
// the first assessment would otherwise filter the second one's roster: the
// operator lands on "Failed" for a cohort they never filtered. Pinned here:
// the second assessment is fetched with no state and no result, and All is
// the lit tile.
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

http.Response _json(Object data, {Map<String, dynamic>? meta}) => http.Response(
  jsonEncode(<String, dynamic>{
    'ok': true,
    'data': data,
    if (data is List) 'meta': meta ?? <String, dynamic>{'total': data.length},
  }),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

Map<String, dynamic> _asm(String id) => <String, dynamic>{
  'id': id,
  'name': 'Paper $id',
  'state': 'in_progress',
  'active': true,
};

void main() {
  testWidgets('a tile pressed on one assessment does not filter the next', (
    WidgetTester t,
  ) async {
    /// Every `/candidates` request: its path and its body, in order.
    final List<(String, Map<String, dynamic>)> asked =
        <(String, Map<String, dynamic>)>[];
    final AppStore store = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String p = req.url.path;
          if (p.endsWith('/candidates')) {
            final String id = p.split('/').reversed.elementAt(1);
            asked.add((p, jsonDecode(req.body) as Map<String, dynamic>));
            return _json(
              <dynamic>[
                <String, dynamic>{
                  'id': '1$id',
                  'assessment_id': id,
                  'candidate': <String, dynamic>{'id': 'p$id', 'name': 'C$id'},
                  'state': 'submitted',
                  'result': 'fail',
                },
              ],
              meta: <String, dynamic>{
                'total': 1,
                'counts': <String, int>{
                  'all': 5,
                  'submitted': 5,
                  'pass': 3,
                  'fail': 2,
                },
              },
            );
          }
          if (p.endsWith('/assessments')) {
            return _json(<dynamic>[_asm('58'), _asm('59')]);
          }
          final RegExpMatch? one = RegExp(
            r'/assessments/([^/]+)$',
          ).firstMatch(p);
          if (one != null) return _json(_asm(one.group(1)!));
          return _json(<String, dynamic>{});
        }),
      ),
    );
    addTearDown(store.dispose);
    await store.refresh();

    final AssessmentNav nav = AssessmentNav();
    Widget screen(String id) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: nav,
          child: SingleChildScrollView(
            child: AssessmentDetailScreen(
              store: store,
              portal: Portal.admin,
              asmId: id,
              tab: 'candidates',
            ),
          ),
        ),
      ),
    );
    bool lit(String label) =>
        t.widget<Btn>(find.widgetWithText(Btn, label)).pressed == true;

    t.view.physicalSize = const Size(1600, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(screen('58'));
    await t.pumpAndSettle();

    await t.tap(find.widgetWithText(Btn, 'Failed  2'));
    await t.pumpAndSettle();
    expect(asked.last.$1, endsWith('/assessments/58/candidates'));
    expect(asked.last.$2['result'], 'fail');

    // The same State, a different assessment: what the router does on a walk.
    await t.pumpWidget(screen('59'));
    await t.pumpAndSettle();

    expect(asked.last.$1, endsWith('/assessments/59/candidates'));
    expect(asked.last.$2.containsKey('result'), isFalse);
    expect(asked.last.$2.containsKey('state'), isFalse);
    expect(lit('All  5'), isTrue);
    expect(lit('Failed  2'), isFalse);
  });
}
