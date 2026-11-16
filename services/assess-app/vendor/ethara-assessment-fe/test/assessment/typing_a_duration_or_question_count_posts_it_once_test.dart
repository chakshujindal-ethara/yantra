// Typing the duration or the question count posts it ONCE, on Enter.
//
// Both committed on every keystroke, so typing "480" posted 4, then 48, then
// 480, and every post ended in a full console reload. They now commit on Enter
// (or on leaving the field), as the thresholds and the violation caps do.
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

/// A draft, so the question count is editable too.
Map<String, dynamic> get _draft => <String, dynamic>{
  'id': '7',
  'name': 'Warehouse Safety',
  'state': 'draft',
  'duration_minutes': 45,
  'question_limit': 6,
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
        // The list route answers with a list, so a refresh keeps the draft.
        final bool list = req.url.path.endsWith('/assessments');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'data': list ? <dynamic>[_draft] : _draft,
            if (list) 'meta': <String, dynamic>{'total': 1},
          }),
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
  for (final (String label, String key, String typed)
      in <(String, String, String)>[
        ('Duration (minutes)', 'duration_minutes', '480'),
        ('Questions', 'question_limit', '12'),
      ]) {
    testWidgets('typing $typed into "$label" posts $key once, with $typed', (
      WidgetTester t,
    ) async {
      final List<Map<String, dynamic>> writes = await _open(t);
      expect(_box(label), findsOneWidget);
      await t.ensureVisible(_box(label));
      await t.pump();

      // Keystroke by keystroke.
      for (int i = 1; i <= typed.length; i++) {
        await t.enterText(_box(label), typed.substring(0, i));
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(writes, isEmpty, reason: 'nothing posts before Enter');

      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      await t.pump(const Duration(milliseconds: 3300));

      expect(writes, hasLength(1));
      expect(writes.single[key], int.parse(typed));
    });
  }
}
