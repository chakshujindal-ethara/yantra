// Typing a violation cap posts it ONCE, on Enter.
//
// The cap committed on every keystroke, so typing "12" into a running
// Auto-submit paper's cap posted max_violations=1 first: any violation in that
// window ended a candidate's exam. Both caps, the regular one and the AI one,
// now commit on Enter (or on leaving the field), as the thresholds do.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> get _running => <String, dynamic>{
  'id': '7',
  'name': 'Warehouse Safety',
  'state': 'in_progress',
  'duration_minutes': 45,
  'question_limit': 6,
  'total_questions': 6,
  'violation_action': 'auto_submit',
  'max_violations': 3,
  'ai_violation_action': 'auto_submit',
  'ai_max_violations': 3,
  'rules': <String, dynamic>{'webcam': true, 'ai_proctor': true},
};

Future<List<Map<String, dynamic>>> _open(WidgetTester t) async {
  t.view.physicalSize = const Size(1600, 3600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final List<Map<String, dynamic>> writes = <Map<String, dynamic>>[];
  final AppStore store = AppStore(
    api: ApiClient(
      baseUrl: 'http://x',
      client: MockClient((http.Request req) async {
        if (req.url.path.endsWith('/update')) {
          writes.add(jsonDecode(req.body) as Map<String, dynamic>);
        }
        return http.Response(
          jsonEncode(<String, dynamic>{'ok': true, 'data': _running}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    ),
  )..adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: AssessmentDetailScreen(
            store: store,
            portal: Portal.admin,
            asmId: '7',
          ),
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  return writes;
}

Finder _box(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (Widget w) => w is Field && w.label == label,
    skipOffstage: false,
  ),
  matching: find.byType(TextField, skipOffstage: false),
);

void main() {
  for (final (String label, String key) in <(String, String)>[
    ('Threshold', 'max_violations'),
    ('AI threshold', 'ai_max_violations'),
  ]) {
    testWidgets('typing 12 into "$label" posts $key once, with 12', (
      WidgetTester t,
    ) async {
      final List<Map<String, dynamic>> writes = await _open(t);
      expect(_box(label), findsOneWidget);
      await t.ensureVisible(_box(label));
      await t.pump();

      // Keystroke by keystroke: "1", then "12".
      await t.enterText(_box(label), '1');
      await t.pump();
      expect(writes, isEmpty, reason: 'the "1" of "12" is no cap');
      await t.enterText(_box(label), '12');
      await t.pump(const Duration(milliseconds: 50));
      expect(writes, isEmpty, reason: 'nothing posts before Enter');

      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      await t.pump(const Duration(milliseconds: 3300));

      expect(writes, hasLength(1));
      expect(writes.single[key], 12);
    });
  }
}
