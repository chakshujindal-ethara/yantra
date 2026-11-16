// Opening ONE assessment's Candidates tab must not disturb the console-wide
// attempts cache.
//
// THE HAZARD THIS EXISTS FOR. The roster is being re-pointed at
// `/api/v1/assessments/<id>/candidates`, which returns ONE assessment's rows.
// `_mergeAttempts` rebuilds `AppStore.attempts` from the rows it is handed and
// cannot retain a row that is absent from the incoming page - so folding a
// per-assessment page through it would drop every OTHER assessment's attempts,
// and the dashboard KPIs read that same list. Correct roster, wrong dashboard.
//
// The defence is structural: the roster gets its own store slot and never
// touches `attempts`. This test is what makes that structural claim checkable
// rather than a comment, and it PASSES BEFORE THE FIX - which is the point. A
// preservation baseline that only exists after the change it guards cannot tell
// you the change was safe.
//
// The three request-count assertions are the second half of the same argument.
// `/attempts` is walked on a `refresh()` that `pollGeneration` runs every two
// seconds, so a roster fetch that joined a rebuild or that poll would multiply
// console traffic against a backend that already sheds load at capacity.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// `assessment_row` for a LAUNCHED assessment - the Candidates tab is disabled
/// on a draft, so a draft would test nothing.
Map<String, dynamic> asmRow(String id, String name) => <String, dynamic>{
  'id': id,
  'name': name,
  'state': 'done',
  'active': true,
  'assigned_count': 1,
};

/// `evaluator_admin_row`, the shape both `/attempts` and the roster route send.
Map<String, dynamic> attemptRow(
  String id,
  String asmId,
  String personId,
  String personName,
) => <String, dynamic>{
  'id': id,
  'assessment_id': asmId,
  'candidate': <String, dynamic>{'id': personId, 'name': personName},
  'state': 'submitted',
  'answered_count': 1,
  'total_questions': 1,
};

/// A console holding two assessments, one attempt each.
///
/// The roster route answers with assessment 18's row ONLY. That asymmetry is
/// deliberate: it is the payload that would evict attempt 91 from the global
/// cache if the roster were folded into it.
class _Rig {
  final List<String> calls = <String>[];
  late final AppStore store;

  _Rig() {
    store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          calls.add(path);
          Object body = <String, dynamic>{};
          if (path.endsWith('/assessments')) {
            body = <dynamic>[
              asmRow('18', 'Forklift Safety'),
              asmRow('19', 'Warehouse Induction'),
            ];
          } else if (path.endsWith('/candidates')) {
            // ONE assessment's rows, which is the whole point of the route.
            body = <dynamic>[attemptRow('90', '18', '2', 'Anita Rao')];
          } else if (path.endsWith('/attempts')) {
            body = <dynamic>[
              attemptRow('90', '18', '2', 'Anita Rao'),
              attemptRow('91', '19', '3', 'Bharat Nair'),
            ];
          } else if (RegExp(r'/assessments/[^/]+$').hasMatch(path)) {
            body = asmRow(path.split('/').last, 'Forklift Safety');
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': body,
              if (body is List)
                'meta': <String, dynamic>{
                  'total': body.length,
                  'limit': 200,
                  'offset': 0,
                  'has_more': false,
                },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        baseUrl: 'http://x',
      ),
    );
  }

  int get rosterCalls =>
      calls.where((String p) => p.endsWith('/candidates')).length;

  Widget app({String tab = 'candidates'}) => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: AssessmentNavScope(
        nav: AssessmentNav(),
        child: AssessmentDetailScreen(
          store: store,
          portal: Portal.admin,
          asmId: '18',
          tab: tab,
        ),
      ),
    ),
  );
}

/// Everything the dashboard derives from the console-wide attempts cache.
///
/// Snapshotted as one value so the assertion names the whole surface rather
/// than whichever field happened to be checked.
/// `ids` is JOINED rather than kept as a list: a record holding a List compares
/// its fields with `==`, and two equal lists are not identical, so the snapshot
/// would never match itself.
({String ids, int on18, int on19, int total, int people}) kpis(AppStore s) => (
  ids: (s.attempts.map((Attempt a) => a.id).toList()..sort()).join(','),
  on18: s.attemptsFor('18').length,
  on19: s.attemptsFor('19').length,
  total: s.attemptsTotal,
  people: s.people.length,
);

void main() {
  // An admin page overflows the 800x600 test default, and a layout throw would
  // mask the assertion.
  void desktop(WidgetTester t) {
    t.view.physicalSize = const Size(1600, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  testWidgets('opening one assessment roster leaves every other assessment '
      'in the global cache', (WidgetTester t) async {
    desktop(t);
    final _Rig rig = _Rig();

    await rig.store.refresh();
    final ({String ids, int on18, int on19, int total, int people}) before =
        kpis(rig.store);
    expect(
      before.ids,
      '90,91',
      reason: 'the console-wide walk holds both assessments',
    );
    expect(before.on19, 1, reason: 'assessment 19 has its attempt');

    await t.pumpWidget(rig.app());
    await t.pumpAndSettle();

    expect(
      kpis(rig.store),
      before,
      reason: 'the roster page carries assessment 18 ONLY, so folding it into '
          '`attempts` would silently drop attempt 91 and every dashboard KPI '
          'reading that list would shrink with it',
    );
  });

  testWidgets('an ordinary rebuild does not re-fetch the roster', (
    WidgetTester t,
  ) async {
    desktop(t);
    final _Rig rig = _Rig();
    await rig.store.refresh();

    await t.pumpWidget(rig.app());
    await t.pumpAndSettle();
    final int afterOpen = rig.rosterCalls;

    // The tab lives inside a ListenableBuilder on the store, so EVERY notify
    // rebuilds it - and `pollGeneration` notifies every two seconds during a
    // generation. A fetch in `build` would put the roster on that loop.
    rig.store.notifyListeners();
    await t.pumpAndSettle();
    rig.store.notifyListeners();
    await t.pumpAndSettle();

    expect(
      rig.rosterCalls,
      afterOpen,
      reason: 'a rebuild is not a reason to re-read the server',
    );
  });

  testWidgets('a background refresh does not add roster requests', (
    WidgetTester t,
  ) async {
    desktop(t);
    final _Rig rig = _Rig();
    await rig.store.refresh();

    await t.pumpWidget(rig.app());
    await t.pumpAndSettle();
    final int afterOpen = rig.rosterCalls;

    // Exactly what `pollGeneration` runs every 2s while a generation is in
    // flight, and what `_act` runs after every mutation.
    await rig.store.refresh(background: true);
    await t.pumpAndSettle();

    expect(
      rig.rosterCalls,
      afterOpen,
      reason: 'the roster is screen-owned: it refreshes when the screen asks, '
          'not on the console-wide poll',
    );
  });

  testWidgets('leaving the tab stops it fetching', (WidgetTester t) async {
    desktop(t);
    final _Rig rig = _Rig();
    await rig.store.refresh();

    await t.pumpWidget(rig.app());
    await t.pumpAndSettle();
    final int afterOpen = rig.rosterCalls;

    // Switching tab disposes _CandidatesTab. Anything still in flight must be
    // dropped rather than adopted, and nothing new may be started.
    await t.pumpWidget(rig.app(tab: 'config'));
    await t.pumpAndSettle();
    rig.store.notifyListeners();
    await t.pumpAndSettle();

    expect(rig.rosterCalls, afterOpen);
    expect(t.takeException(), isNull);
  });
}
