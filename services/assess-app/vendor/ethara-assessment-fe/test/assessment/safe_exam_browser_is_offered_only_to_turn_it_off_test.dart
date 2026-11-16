// Safe Exam Browser is offered only to turn it off.
//
// The owner removed locked mode from the admin UI ("remove safe browser mode;
// violations log to be kept independent and separate from it"). So the create
// form never shows "Require Safe Exam Browser" and a new paper goes out with
// it off, and the Configuration tab hides it too - except on a paper that
// already has it on, where it stays so an admin can switch it off. The
// candidate-side gate is untouched: it still runs for any paper with the rule
// on. The violation policy below the switches is not part of this: it renders
// and writes the same with or without the SEB row.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/new_assessment_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _seb = 'Require Safe Exam Browser';

Finder _row(String name) =>
    find.byWidgetPredicate((Widget w) => w is SwitchRow && w.name == name);

http.Response _ok(Object data) => http.Response(
  jsonEncode(<String, dynamic>{
    'ok': true,
    'data': data,
    if (data is List) 'meta': <String, dynamic>{'total': data.length},
  }),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

void _desktop(WidgetTester t) {
  t.view.physicalSize = const Size(1600, 5000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

Widget _app(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: AssessmentNavScope(nav: AssessmentNav(), child: child),
  ),
);

/// One draft paper on its Configuration tab, with [seb] as its stored rule.
/// Records every update body.
Future<List<Map<String, dynamic>>> _configTab(
  WidgetTester t, {
  required bool seb,
}) async {
  final List<Map<String, dynamic>> writes = <Map<String, dynamic>>[];
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://x',
      client: MockClient((http.Request req) async {
        if (req.url.path.endsWith('/update')) {
          writes.add(jsonDecode(req.body) as Map<String, dynamic>);
        }
        return _ok(<String, dynamic>{
          'id': '7',
          'name': 'Locked paper',
          'state': 'draft',
          'duration_minutes': 45,
          'question_limit': 6,
          'total_questions': 6,
          'violation_action': 'auto_submit',
          'max_violations': 3,
          'rules': <String, dynamic>{
            'tab_switch': true,
            'webcam': true,
            'watermark': true,
            'seb': seb,
          },
        });
      }),
    ),
  );
  addTearDown(s.dispose);
  await t.pumpWidget(
    _app(AssessmentDetailScreen(store: s, portal: Portal.admin, asmId: '7')),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  return writes;
}

void main() {
  testWidgets('the create form never offers it and sends it off', (
    WidgetTester t,
  ) async {
    _desktop(t);
    Map<String, dynamic>? created;
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String p = req.url.path;
          if (p.endsWith('/assessments/create')) {
            created = jsonDecode(req.body) as Map<String, dynamic>;
            return _ok(<String, dynamic>{'id': 9});
          }
          if (p.endsWith('/generators')) {
            return _ok(<Map<String, dynamic>>[
              <String, dynamic>{'id': 3, 'name': 'SOP alpha', 'active': true},
            ]);
          }
          // "Create draft" waits for questions to draw from.
          if (p.endsWith('/bank')) {
            return _ok(<Map<String, dynamic>>[
              for (int id = 1; id <= 2; id++)
                <String, dynamic>{
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
                },
            ]);
          }
          return _ok(<dynamic>[]);
        }),
      ),
    )..adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
    await s.refresh();
    await t.pumpWidget(_app(NewAssessmentScreen(store: s)));
    await t.pumpAndSettle();

    // The list is there, so its absence below is not a lazy build.
    expect(_row('Watermark the exam'), findsOneWidget);
    expect(_row(_seb), findsNothing);
    expect(find.text(_seb), findsNothing);
    // The violation policy still renders without it.
    expect(find.byType(SelectField<ViolationAction>), findsOneWidget);

    await t.enterText(find.byType(TextField).first, 'Plain paper');
    await t.tap(find.text('Choose a generator'));
    await t.pumpAndSettle();
    await t.tap(find.text('SOP alpha').last);
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(Btn, 'Create draft'));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 4));

    expect(created, isNotNull);
    expect(created!['rule_require_seb'], isFalse);
  });

  testWidgets('the Configuration tab hides it on a paper with it off', (
    WidgetTester t,
  ) async {
    _desktop(t);
    await _configTab(t, seb: false);

    expect(_row('Watermark the exam'), findsOneWidget);
    expect(_row(_seb), findsNothing);
    expect(find.text('ON VIOLATION'), findsOneWidget);
  });

  testWidgets('a paper with it on still shows it, so it can be turned off', (
    WidgetTester t,
  ) async {
    _desktop(t);
    final List<Map<String, dynamic>> writes = await _configTab(t, seb: true);

    expect(_row(_seb), findsOneWidget);
    await t.tap(
      find.descendant(of: _row(_seb), matching: find.byType(Switcher)),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 3300));

    expect(writes, isNotEmpty);
    expect(writes.last['rule_require_seb'], isFalse);
  });

  test('the AI proctoring hint no longer names Safe Exam Browser', () {
    expect(ProctorRule.aiProctor.hint, isNot(contains('Safe Exam Browser')));
    expect(ProctorRule.aiProctor.hint, endsWith('Made for Chrome.'));
  });
}
