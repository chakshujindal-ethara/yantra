// "Export Results" does the roster's job, so the roster export is gone.
//
// OWNER DECISION: include the missing columns in Results rather than keep a
// second, near-identical export. The roster CSV was the only export usable
// before anyone had submitted, so Results takes that over: offered in every
// state (draft included) and enabled as soon as one candidate is assigned.
// Responses keeps its rule - not in draft, and it needs a submission.
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
import 'package:ethara_assessment/assessment/widgets/buttons.dart';

Assessment asm({
  AsmState state = AsmState.inProgress,
  int assigned = 1,
  int submitted = 0,
}) => Assessment(
  id: 'A-1',
  name: 'Warehouse Safety',
  state: state,
  assignedCount: assigned,
  submittedCount: submitted,
);

Attempt sitting() =>
    Attempt(id: '1', assessmentId: 'A-1', employeeId: 'P-1', token: 'tok');

Future<void> open(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1800, 2600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: AssessmentDetailScreen(
            store: s,
            portal: Portal.admin,
            asmId: 'A-1',
            tab: 'config',
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Finder button(String label) => find.widgetWithText(Btn, label);

/// Null when the button is shown but disabled.
VoidCallback? pressOf(WidgetTester t, String label) =>
    t.widget<Btn>(button(label)).onPressed;

void main() {
  group('The roster export is gone', () {
    for (final AsmState state in <AsmState>[
      AsmState.draft,
      AsmState.inProgress,
      AsmState.done,
    ]) {
      testWidgets('no Export Roster button on a ${state.name} assessment', (
        WidgetTester t,
      ) async {
        await open(
          t,
          AppStore()
            ..assessments = <Assessment>[asm(state: state, submitted: 1)]
            ..attempts = <Attempt>[sitting()],
        );
        expect(find.text('Export Roster'), findsNothing);
        expect(button('Export Results'), findsOneWidget);
      });
    }
  });

  group('Export Results is the pre-submission export', () {
    testWidgets('enabled with one assigned candidate and zero submissions', (
      WidgetTester t,
    ) async {
      await open(
        t,
        AppStore()
          ..assessments = <Assessment>[asm()]
          ..attempts = <Attempt>[sitting()],
      );
      expect(pressOf(t, 'Export Results'), isNotNull);
    });

    testWidgets('offered and enabled on a draft that has someone assigned', (
      WidgetTester t,
    ) async {
      await open(
        t,
        AppStore()
          ..assessments = <Assessment>[asm(state: AsmState.draft)]
          ..attempts = <Attempt>[sitting()],
      );
      expect(button('Export Results'), findsOneWidget);
      expect(pressOf(t, 'Export Results'), isNotNull);
    });

    testWidgets('with no server count it falls back to the held roster', (
      WidgetTester t,
    ) async {
      // `assignedCount` is -1 when the payload did not carry it.
      await open(
        t,
        AppStore()
          ..assessments = <Assessment>[asm(assigned: -1)]
          ..attempts = <Attempt>[sitting()],
      );
      expect(pressOf(t, 'Export Results'), isNotNull);
    });

    testWidgets('disabled with nobody assigned', (WidgetTester t) async {
      await open(t, AppStore()..assessments = <Assessment>[asm(assigned: 0)]);
      expect(button('Export Results'), findsOneWidget);
      expect(pressOf(t, 'Export Results'), isNull);
    });

    testWidgets('disabled on a draft with nobody assigned', (
      WidgetTester t,
    ) async {
      await open(
        t,
        AppStore()
          ..assessments = <Assessment>[asm(state: AsmState.draft, assigned: 0)],
      );
      expect(button('Export Results'), findsOneWidget);
      expect(pressOf(t, 'Export Results'), isNull);
    });

    testWidgets('the tooltip names what the file holds, in one sentence', (
      WidgetTester t,
    ) async {
      await open(
        t,
        AppStore()
          ..assessments = <Assessment>[asm()]
          ..attempts = <Attempt>[sitting()],
      );
      final String? tip = t.widget<Btn>(button('Export Results')).tooltip;
      expect(
        tip,
        'Download one row per assigned candidate with invite, attempt '
        'state, answered, marks, verdict, release and time taken.',
      );
      expect(tip, isNot(contains('\u2014')));
    });
  });

  group('Export Responses keeps its rule', () {
    testWidgets('still disabled with zero submissions', (WidgetTester t) async {
      await open(
        t,
        AppStore()
          ..assessments = <Assessment>[asm()]
          ..attempts = <Attempt>[sitting()],
      );
      expect(button('Export Responses'), findsOneWidget);
      expect(pressOf(t, 'Export Responses'), isNull);
    });

    testWidgets('enabled once there is a submission', (WidgetTester t) async {
      await open(
        t,
        AppStore()
          ..assessments = <Assessment>[asm(submitted: 1)]
          ..attempts = <Attempt>[sitting()],
      );
      expect(pressOf(t, 'Export Responses'), isNotNull);
    });

    testWidgets('not offered on a draft', (WidgetTester t) async {
      await open(
        t,
        AppStore()
          ..assessments = <Assessment>[asm(state: AsmState.draft)]
          ..attempts = <Attempt>[sitting()],
      );
      expect(button('Export Responses'), findsNothing);
    });
  });

  testWidgets('pressing Export Results asks the server for the results file', (
    WidgetTester t,
  ) async {
    final List<String> paths = <String>[];
    final AppStore s = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          paths.add(req.url.path);
          final Object body = req.url.path.endsWith('/export/results')
              ? <String, dynamic>{
                  'filename': 'results.csv',
                  'content': base64Encode(utf8.encode('Candidate,Invite\n')),
                }
              : req.url.path.endsWith('/assessments/A-1')
              ? <String, dynamic>{
                  'id': 'A-1',
                  'name': 'Warehouse Safety',
                  'state': 'in_progress',
                  'assigned_count': 1,
                  'submitted_count': 0,
                }
              : <String, dynamic>{};
          return http.Response(
            jsonEncode(<String, dynamic>{'ok': true, 'data': body}),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        baseUrl: 'http://x',
      ),
    )..assessments = <Assessment>[asm()];
    await open(t, s);

    await t.tap(button('Export Results'));
    await t.pumpAndSettle();
    // Let the "downloaded" toast's own dismiss timer run out.
    await t.pump(const Duration(seconds: 30));

    expect(
      paths.where((String p) => p.endsWith('/assessments/A-1/export/results')),
      hasLength(1),
      reason: 'the server builds the file; the client builds nothing',
    );
    expect(paths.where((String p) => p.contains('/export/responses')), isEmpty);
  });
}
