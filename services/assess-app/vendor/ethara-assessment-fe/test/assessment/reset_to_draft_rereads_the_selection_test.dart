// After Reset to Draft the Selected Questions tab went on reading "2 of 10 in
// use" while the server had cleared the selection: `resetToDraft` only flipped
// the state, and `_act`'s list refresh keeps the held `pool` because no list
// row carries one. The detail is now re-read once the reset lands.
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
  testWidgets('Selected Questions shows the server selection after a reset', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1600, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    bool reset = false;
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
    // The list shape: no `pool`, exactly like `assessment_row`.
    Map<String, dynamic> row() => <String, dynamic>{
      'id': '58',
      'name': 'Paper',
      'state': reset ? 'draft' : 'cancelled',
      'active': true,
      'generator': <String, dynamic>{'id': 3, 'name': 'SOP alpha'},
    };
    // The detail shape. Before: 2 of 10 ticked. After: the selection is
    // cleared, which the server reports as every pool row in use.
    Map<String, dynamic> detail() => <String, dynamic>{
      ...row(),
      'pool': <Map<String, dynamic>>[
        for (int i = 1; i <= 10; i++)
          <String, dynamic>{
            'id': i,
            'name': 'Q$i',
            'question_type': 'mcq',
            'state': 'approved',
            'active': true,
            'in_use': reset || i <= 2,
          },
      ],
    };
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          if (path.endsWith('/reset_draft')) {
            reset = true;
            return json(detail());
          }
          if (path.endsWith('/assessments')) return json(<dynamic>[row()]);
          if (path.endsWith('/attempts')) return json(<dynamic>[]);
          if (RegExp(r'/assessments/58$').hasMatch(path)) {
            return json(detail());
          }
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
                tab: 'questions',
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('2 of 10 in use'), findsOneWidget);

    await s.resetToDraft(s.asmById('58')!);
    await t.pumpAndSettle();

    expect(s.asmById('58')!.state, AsmState.draft);
    expect(find.text('2 of 10 in use'), findsNothing);
    expect(find.text('10 of 10 in use'), findsOneWidget);

    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 4));
  });
}
