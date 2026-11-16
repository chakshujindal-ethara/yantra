// The bank's Archive must archive, and only Delete may erase.
//
// 12 Oct 2026: both the row's Archive icon and the selection bar's "Archive"
// called `bank/delete`, which ERASES every selected question nothing points at.
// Archiving 146 questions on a local copy erased 44 of them for good. Archive
// now reaches `bank/archive` only; Delete keeps its own button and sheet, as
// the Assessments screens do - and is hidden for now (`showQuestionDelete`).
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/bank_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/question_editor.dart';

void main() {
  late List<String> paths;
  late Map<String, Map<String, dynamic>> bodies;

  Map<String, dynamic> row(
    String id,
    String name, {
    bool retired = false,
    bool deleted = false,
  }) => <String, dynamic>{
    'id': id,
    'name': name,
    'prompt': 'About $name',
    'question_type': 'subjective_rubric',
    'active': true,
    'retired': retired,
    'deleted': deleted,
  };

  AppStore store({List<Map<String, dynamic>>? rows}) {
    paths = <String>[];
    bodies = <String, Map<String, dynamic>>{};
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          paths.add(req.url.path);
          bodies[req.url.path] = req.body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(req.body) as Map<String, dynamic>;
          final Object data = req.url.path.endsWith('/bank')
              ? (rows ?? <Map<String, dynamic>>[row('1', 'Unused question')])
              : <String, dynamic>{};
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': data,
              if (data is List)
                'meta': <String, dynamic>{
                  'total': data.length,
                  'has_more': false,
                },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
    addTearDown(s.dispose);
    return s;
  }

  Future<void> pump(WidgetTester t, AppStore s) async {
    t.view.physicalSize = const Size(1600, 1400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await s.refresh();
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AssessmentNavScope(
          nav: AssessmentNav(),
          child: Scaffold(
            body: SingleChildScrollView(child: BankScreen(store: s)),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  /// Lets the toast the action raises time out, or the test ends with a timer
  /// still pending.
  Future<void> settleToasts(WidgetTester t) =>
      t.pump(const Duration(seconds: 30));

  Iterable<String> hits(String suffix) =>
      paths.where((String p) => p.endsWith(suffix));

  testWidgets('the row Archive icon archives and never deletes', (
    WidgetTester t,
  ) async {
    await pump(t, store());
    await t.tap(find.byTooltip('Archive'));
    await t.pumpAndSettle();
    expect(hits('/bank/archive'), hasLength(1));
    expect(bodies['/api/v1/bank/archive'], <String, dynamic>{
      'ids': <dynamic>['1'],
      'archive': true,
    });
    expect(hits('/bank/delete'), isEmpty);
    await settleToasts(t);
  });

  testWidgets('the selection bar archives, and Delete is not offered', (
    WidgetTester t,
  ) async {
    expect(showQuestionDelete, isFalse);
    await pump(t, store());
    await t.tap(find.byType(Checkbox).last);
    await t.pumpAndSettle();
    expect(find.text('1 question selected'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);

    await t.tap(find.text('Archive'));
    await t.pumpAndSettle();
    expect(hits('/bank/archive'), hasLength(1));
    expect(hits('/bank/delete'), isEmpty);
    await settleToasts(t);
  });

  // Delete is only hidden (`showQuestionDelete`): its flow is kept, so this
  // turns the button back on.
  group('with Delete shown', () {
    setUp(() => showQuestionDelete = true);
    tearDown(() => showQuestionDelete = false);

    testWidgets('the selection bar offers Archive and Delete separately', (
      WidgetTester t,
    ) async {
      await pump(t, store());
      await t.tap(find.byType(Checkbox).last);
      await t.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget);

      await t.tap(find.text('Archive'));
      await t.pumpAndSettle();
      expect(hits('/bank/archive'), hasLength(1));
      expect(hits('/bank/delete'), isEmpty);
      await settleToasts(t);
    });
  });

  testWidgets('a ticked row archived from its own icon leaves the selection', (
    WidgetTester t,
  ) async {
    await pump(t, store());
    await t.tap(find.byType(Checkbox).last);
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Archive'));
    await t.pumpAndSettle();
    expect(
      find.text('1 question selected'),
      findsNothing,
      reason: 'a bulk action pressed next would act on the row just archived',
    );
    await settleToasts(t);
  });

  testWidgets("the editor's Archived switch archives, never clears active", (
    WidgetTester t,
  ) async {
    final AppStore s = store();
    await s.refresh();
    t.view.physicalSize = const Size(1600, 1400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext c) => TextButton(
              onPressed: () => showBankEditor(c, s, s.bank.first),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.byType(Switcher));
    await t.pumpAndSettle();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(bodies['/api/v1/bank/1/update'], isNotNull);
    expect(
      bodies['/api/v1/bank/1/update']!.containsKey('active'),
      isFalse,
      reason: 'active=false is Odoo archive: it empties built papers',
    );
    expect(bodies['/api/v1/bank/archive'], <String, dynamic>{
      'ids': <dynamic>['1'],
      'archive': true,
    });
    await settleToasts(t);
  });

  testWidgets('a deleted question shows only under Show deleted, read-only', (
    WidgetTester t,
  ) async {
    await pump(
      t,
      store(
        rows: <Map<String, dynamic>>[
          row('1', 'Live one'),
          row('2', 'Archived one', retired: true),
          row('3', 'Deleted one', retired: true, deleted: true),
        ],
      ),
    );
    expect(find.text('Live one'), findsOneWidget);
    expect(find.text('Deleted one'), findsNothing);

    await t.tap(find.text('Show archived'));
    await t.pumpAndSettle();
    expect(find.text('Archived one'), findsOneWidget);
    expect(
      find.text('Deleted one'),
      findsNothing,
      reason: 'Deleted is out of Archived too, for good',
    );

    await t.tap(find.text('Show deleted'));
    await t.pumpAndSettle();
    expect(find.text('Deleted one'), findsOneWidget);
    expect(find.text('Archived one'), findsNothing);
    expect(find.text('Restore'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('a deleted question previews read-only, named as deleted', (
    WidgetTester t,
  ) async {
    await pump(
      t,
      store(
        rows: <Map<String, dynamic>>[
          row('3', 'Deleted one', retired: true, deleted: true),
        ],
      ),
    );
    await t.tap(find.text('Show deleted'));
    await t.pumpAndSettle();
    await t.tap(find.text('Deleted one'));
    await t.pumpAndSettle();
    expect(
      find.textContaining('Deleted from the bank', findRichText: true),
      findsOneWidget,
    );
    expect(find.byTooltip('Edit this question'), findsNothing);
  });
}
