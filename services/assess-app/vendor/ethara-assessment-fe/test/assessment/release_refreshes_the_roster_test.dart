// After Release, the roster's Released column stayed "Held" until the operator
// switched tabs: the roster is a screen-owned page that only `loadRoster`
// fills, and a successful action never asked for it again. The tab now
// re-reads its page once each time an action lands.
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

void main() {
  testWidgets('a successful Release refreshes the roster rows', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1600, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    bool released = false;
    int rosterReads = 0;
    http.Response json(Object data) => http.Response(
      jsonEncode(<String, dynamic>{
        'ok': true,
        'data': data,
        if (data is List)
          'meta': <String, dynamic>{'total': data.length, 'limit': 200},
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
    final Map<String, dynamic> asm = <String, dynamic>{
      'id': '58',
      'name': 'Paper',
      'state': 'done',
      'active': true,
      'assigned_count': 1,
    };
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          if (path.endsWith('/release')) {
            released = true;
            return json(<String, dynamic>{'released_count': 1});
          }
          if (path.endsWith('/candidates')) {
            rosterReads++;
            return json(<dynamic>[
              <String, dynamic>{
                'id': '9',
                'assessment_id': '58',
                'candidate': <String, dynamic>{'id': 'p9', 'name': 'Anita'},
                'state': 'submitted',
                'results_released': released,
              },
            ]);
          }
          if (path.endsWith('/assessments')) return json(<dynamic>[asm]);
          if (path.endsWith('/attempts')) return json(<dynamic>[]);
          if (RegExp(r'/assessments/[^/]+$').hasMatch(path)) return json(asm);
          return json(<String, dynamic>{});
        }),
      ),
    );
    await s.refresh();
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: AssessmentNavScope(
            nav: AssessmentNav(),
            child: SingleChildScrollView(
              child: AssessmentDetailScreen(
                store: s,
                portal: Portal.admin,
                asmId: '58',
                tab: 'candidates',
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Held'), findsOneWidget);
    final int before = rosterReads;

    await s.releaseResults(s.asmById('58')!);
    await t.pumpAndSettle();

    expect(rosterReads, greaterThan(before));
    expect(find.text('Held'), findsNothing);
    expect(find.text('Released'), findsWidgets);

    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 4));
  });
}
