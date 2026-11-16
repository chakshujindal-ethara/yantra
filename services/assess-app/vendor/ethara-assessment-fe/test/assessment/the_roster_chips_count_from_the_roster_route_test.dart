// "Scored" and "Score Pending" on the Candidates tab, and where EVERY chip's
// number comes from.
//
// THE COUNTS WERE STALE. The state chips counted the console-wide attempts
// cache, which a finished scoring run does not refresh, so "Submitted 12" sat
// beside a roster the server had moved on from. They now read `meta.counts`
// off the roster response itself - the response the tab refetches when a run
// ends - and the two new chips could not have come from that cache anyway:
// Scored / Score Pending split Submitted by ANSWERS, which roster rows do not
// carry.
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

class _Rig {
  /// What the roster route answers in `meta.counts` - mutable, so a test can
  /// move the numbers between two reads the way a scoring run does.
  Map<String, int> counts = <String, int>{
    'all': 9,
    'pending': 1,
    'in_progress': 2,
    'submitted': 6,
    'scored': 4,
    'score_pending': 2,
  };

  final List<String> rosterStates = <String>[];
  late final AppStore store;

  _Rig() {
    store = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          final Map<String, dynamic> body =
              jsonDecode(req.body) as Map<String, dynamic>;
          if (path.endsWith('/candidates')) {
            rosterStates.add((body['state'] as String?) ?? '');
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
          if (path.endsWith('/assessments')) {
            return _json(<dynamic>[_asm]);
          }
          // THE CONSOLE-WIDE CACHE DISAGREES ON PURPOSE: three submitted
          // attempts. A chip still counting it would read "Submitted 3" and
          // "All 3" where the roster route says 6 and 9.
          if (path.endsWith('/attempts')) {
            return _json(<dynamic>[
              for (int i = 0; i < 3; i++)
                <String, dynamic>{
                  'id': '${200 + i}',
                  'assessment_id': '58',
                  'candidate': <String, dynamic>{'id': 'q$i', 'name': 'C$i'},
                  'state': 'submitted',
                },
            ]);
          }
          if (RegExp(r'/assessments/[^/]+$').hasMatch(path)) {
            return _json(_asm);
          }
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

void main() {
  Future<_Rig> open(WidgetTester t) async {
    t.view.physicalSize = const Size(1600, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final _Rig r = _Rig();
    await r.store.refresh();
    await t.pumpWidget(r.app());
    await t.pumpAndSettle();
    return r;
  }

  test('the labels and wire names are exactly these', () {
    expect(ScoringFilter.scored.label, 'Scored');
    expect(ScoringFilter.scored.wire, 'scored');
    expect(ScoringFilter.scorePending.label, 'Score Pending');
    expect(ScoringFilter.scorePending.wire, 'score_pending');
  });

  testWidgets('every chip counts from meta.counts, not the attempts cache', (
    WidgetTester t,
  ) async {
    await open(t);

    expect(find.text('All  9'), findsOneWidget);
    expect(find.text('Not started  1'), findsOneWidget);
    expect(find.text('In progress  2'), findsOneWidget);
    expect(find.text('Submitted  6'), findsOneWidget);
    expect(find.text('Scored  4'), findsOneWidget);
    expect(find.text('Score Pending  2'), findsOneWidget);
  });

  testWidgets('Scored and Score Pending sit right after Submitted', (
    WidgetTester t,
  ) async {
    await open(t);

    final double submitted = t.getTopLeft(find.text('Submitted  6')).dx;
    final double scored = t.getTopLeft(find.text('Scored  4')).dx;
    final double pending = t.getTopLeft(find.text('Score Pending  2')).dx;
    final double flagged = t.getTopLeft(find.text('Flagged')).dx;
    expect(submitted < scored && scored < pending && pending < flagged, isTrue);
  });

  for (final ScoringFilter f in ScoringFilter.values) {
    testWidgets('the ${f.label} chip sends ${f.wire}', (WidgetTester t) async {
      final _Rig r = await open(t);
      final int before = r.rosterStates.length;

      await t.tap(find.text('${f.label}  ${r.counts[f.wire]}'));
      await t.pumpAndSettle();

      expect(r.rosterStates.length - before, 1);
      expect(r.rosterStates.last, f.wire);
    });
  }

  testWidgets('the next roster read moves the numbers', (WidgetTester t) async {
    final _Rig r = await open(t);

    // A scoring run finishes two more candidates.
    r.counts = <String, int>{...r.counts, 'scored': 6, 'score_pending': 0};
    await r.store.loadRoster('58');
    await t.pumpAndSettle();

    expect(find.text('Scored  6'), findsOneWidget);
    // Nothing left to filter to, so the chip steps aside like any other state
    // chip with nobody in it.
    expect(find.textContaining('Score Pending'), findsNothing);
  });
}
