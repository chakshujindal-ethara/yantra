// The New Assessment form sends the AI violation pair the operator set.
//
// The pair (`ai_violation_action`, `ai_max_violations`) is offered once AI
// proctoring is on, and both default to the server's own Log only / 5. A
// create that dropped them therefore looked right on every default paper;
// only values the operator CHANGED show whether they reach the wire.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/new_assessment_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _row(int id) => <String, dynamic>{
  'id': id,
  'name': 'Q$id',
  'question_type': 'mcq',
  'difficulty': 'medium',
  'sequence': id,
  'active': true,
  'state': 'approved',
  'generator': <String, dynamic>{'id': 3, 'name': 'SOP alpha'},
  'has_valid_key': true,
  'missing_media_warning': '',
  'servable': true,
};

Finder _switch(String name) => find.descendant(
  of: find.byWidgetPredicate((Widget w) => w is SwitchRow && w.name == name),
  matching: find.byType(Switcher),
);

void main() {
  testWidgets('a changed AI pair reaches the create body', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1600, 5000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    Map<String, dynamic>? created;
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String p = req.url.path;
          Object data = <dynamic>[];
          if (p.endsWith('/assessments/create')) {
            created = jsonDecode(req.body) as Map<String, dynamic>;
            data = <String, dynamic>{'id': 9};
          }
          if (p.endsWith('/bank')) data = <dynamic>[_row(1), _row(2)];
          if (p.endsWith('/generators')) {
            data = <Map<String, dynamic>>[
              <String, dynamic>{'id': 3, 'name': 'SOP alpha', 'active': true},
            ];
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': data,
              if (data is List) 'meta': <String, dynamic>{'total': data.length},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    )..adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
    await s.refresh();
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: AssessmentNavScope(
            nav: AssessmentNav(),
            child: NewAssessmentScreen(store: s),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, 'AI paper');
    await t.tap(find.text('Choose a generator'));
    await t.pumpAndSettle();
    await t.tap(find.text('SOP alpha').last);
    await t.pumpAndSettle();

    expect(find.text('ON AI VIOLATION'), findsNothing, reason: 'AI is off');
    // The webcam rule, its prerequisite, is on by default.
    await t.tap(_switch('AI proctoring'));
    await t.pumpAndSettle();

    await t.tap(find.byType(SelectField<ViolationAction>).last);
    await t.pumpAndSettle();
    await t.tap(find.text('Auto-submit the exam').last);
    await t.pumpAndSettle();
    final Finder plus = find.descendant(
      of: find.byWidgetPredicate(
        (Widget w) => w is Field && w.label == 'AI threshold',
      ),
      matching: find.widgetWithText(Btn, '+'),
    );
    await t.tap(plus);
    await t.pump();
    await t.tap(plus);
    await t.pumpAndSettle();

    // The regular pair, moved too, so neither can stand in for the other.
    await t.tap(find.byType(SelectField<ViolationAction>).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Auto-submit the exam').last);
    await t.pumpAndSettle();
    await t.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (Widget w) => w is Field && w.label == 'Threshold',
        ),
        matching: find.widgetWithText(Btn, '+'),
      ),
    );
    await t.pumpAndSettle();

    await t.tap(find.widgetWithText(Btn, 'Create draft'));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 4));

    expect(created, isNotNull);
    expect(created!['ai_violation_action'], 'auto_submit');
    expect(created!['ai_max_violations'], 7);
    expect(created!['violation_action'], 'auto_submit');
    expect(created!['max_violations'], 6);
  });
}
