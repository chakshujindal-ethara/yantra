// THE COUNT TYPED ON NEW ASSESSMENT IS THE PAPER (prod, 2026-09-29).
//
// The owner typed 15, the Selected Questions tab showed a handful ticked, and
// candidates sat 6. The form started at a literal 6, capped the stepper at the
// cached ready count, and drew from a bank cached before the latest approvals.
// This pins the create payload: the bank is re-read before the pick, a typed
// count the bank can fill goes out as typed, and one it cannot is said on
// screen and sent as what is actually ticked.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/new_assessment_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

/// One `/api/v1/bank` row in generator 3. [ready] false = the server says it
/// cannot be served because its media is missing.
Map<String, dynamic> _row(int id, {bool ready = true}) => <String, dynamic>{
  'id': id,
  'name': 'Q$id',
  'question_type': 'mcq',
  'difficulty': 'medium',
  'sequence': id,
  'active': true,
  'state': 'approved',
  'generator': <String, dynamic>{'id': 3, 'name': 'SOP alpha'},
  'has_valid_key': true,
  'missing_media_warning': ready ? '' : 'No image',
  'servable': ready,
};

/// Serves [bank] on `/bank`, one generator on `/generators`, records the
/// create body, and answers everything else with an empty envelope.
class _Server {
  final List<Map<String, dynamic>> bank;
  Map<String, dynamic>? created;

  _Server(this.bank);

  AppStore store() {
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        client: MockClient((http.Request req) async {
          final String p = req.url.path;
          Object data = <String, dynamic>{};
          if (p.endsWith('/bank')) data = bank;
          if (p.endsWith('/generators')) {
            data = <Map<String, dynamic>>[
              <String, dynamic>{'id': 3, 'name': 'SOP alpha', 'active': true},
            ];
          }
          if (p.endsWith('/assessments/create')) {
            created = jsonDecode(req.body) as Map<String, dynamic>;
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
    );
    s.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
    return s;
  }
}

Future<void> _open(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1600, 3200);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
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
  await t.enterText(find.byType(TextField).first, 'Warehouse Safety');
  await t.tap(find.text('Choose a generator'));
  await t.pumpAndSettle();
  await t.tap(find.text('SOP alpha').last);
  await t.pumpAndSettle();
}

Finder get _countBox => find.descendant(
  of: find.byType(NumberField).first,
  matching: find.byType(TextField),
);

Finder _notice(String strong) =>
    find.byWidgetPredicate((Widget w) => w is Notice && w.strong == strong);

void main() {
  testWidgets('15 typed, 15 ready: all 15 ticked and question_limit 15', (
    WidgetTester t,
  ) async {
    final _Server server = _Server(<Map<String, dynamic>>[
      for (int i = 1; i <= 15; i++) _row(i),
    ]);
    final AppStore s = server.store();
    await s.refresh();
    // A STALE CACHE: the console loaded when only 6 were approved. The pick
    // must come from a fresh read, not from this.
    s.bank = s.bank.take(6).toList();
    expect(s.poolFor('3'), hasLength(6));

    await _open(t, s);
    expect(
      s.poolFor('3'),
      hasLength(15),
      reason: 'picking the generator re-reads the bank',
    );

    await t.enterText(_countBox, '15');
    await t.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is Notice && (w.strong ?? '').startsWith('Only'),
      ),
      findsNothing,
    );

    await t.tap(find.widgetWithText(Btn, 'Create draft'));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 4));

    final Map<String, dynamic> body = server.created!;
    expect(body['question_ids'], hasLength(15));
    expect(body['question_limit'], 15);
  });

  testWidgets('15 typed, 4 ready: the notice says why and 4 is sent', (
    WidgetTester t,
  ) async {
    final _Server server = _Server(<Map<String, dynamic>>[
      for (int i = 1; i <= 4; i++) _row(i),
      for (int i = 5; i <= 7; i++) _row(i, ready: false),
    ]);
    final AppStore s = server.store();
    await s.refresh();

    await _open(t, s);
    await t.enterText(_countBox, '15');
    await t.pumpAndSettle();

    expect(
      t.widget<NumberField>(find.byType(NumberField).first).value,
      15,
      reason: 'the typed count is not silently capped at the ready pool',
    );
    expect(
      _notice('Only 4 of 15 questions are ready (3 missing media).'),
      findsOneWidget,
    );

    await t.tap(find.widgetWithText(Btn, 'Save as draft'));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 4));

    final Map<String, dynamic> body = server.created!;
    expect(body['question_ids'], hasLength(4));
    expect(
      body['question_limit'],
      4,
      reason: 'the paper never promises more than is ticked',
    );
  });
}
