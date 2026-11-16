// Each Form Studio row: an Admin edits, duplicates, exports and deletes it,
// and the row itself opens the designer; a Manager gets no actions and the row
// opens the read-only preview instead (the designer autosaves). A question
// type's Edit opens the template designer.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_studio_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/task_template_editor.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A live store at [role] holding one form, the Form Studio over it, and the
/// nav it moves.
Future<({AppStore s, AssessmentNav nav, FormDef form})> _open(
  WidgetTester t, {
  AccessRole role = AccessRole.admin,
}) async {
  t.view.physicalSize = const Size(1600, 1400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final FormDef form = formNewForm()..title = 'Site intake';
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      client: MockClient(
        (http.Request req) async => http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            // The server holds the form, so a refresh keeps it listed.
            'data': req.url.path.endsWith('/forms')
                ? <dynamic>[form.toJson()]
                : req.url.path.endsWith('/task_templates')
                ? <dynamic>[
                    <String, dynamic>{'id': 4, 'name': 'Caption check'},
                  ]
                : <dynamic>[],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      ),
    ),
  );
  addTearDown(s.dispose);
  s.adoptSession(
    orgRole: 'admin',
    name: 'Aarav Mehta',
    uid: '2',
    accessRoleWire: role.wire,
    capabilities: role == AccessRole.admin
        ? Capability.values.toSet()
        : const <Capability>{},
  );
  s.forms = <FormDef>[form];
  s.taskTemplates = <TaskTemplate>[
    const TaskTemplate(id: 4, name: 'Caption check'),
  ];
  final AssessmentNav nav = AssessmentNav();
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: AssessmentNavScope(
        nav: nav,
        child: Scaffold(body: FormStudioScreen(store: s)),
      ),
    ),
  );
  await t.pumpAndSettle();
  return (s: s, nav: nav, form: form);
}

Iterable<String> _toasts(AppStore s) =>
    s.toaster.items.map((ToastMsg m) => m.message);

void main() {
  testWidgets('Duplicate and Export', (WidgetTester t) async {
    final (:AppStore s, nav: _, form: _) = await _open(t);

    await t.tap(find.byTooltip('Duplicate'));
    await t.pumpAndSettle();
    expect(s.forms, hasLength(2));
    expect(_toasts(s), contains('Form duplicated'));

    await t.tap(
      find
          .byTooltip(
            'Export as JSON. The file imports back with '
            'the Import button, so a form can move between environments.',
          )
          .first,
    );
    await t.pump();
    expect(_toasts(s).any((String m) => m.contains('downloaded')), isTrue);
    await t.pump(const Duration(seconds: 30)); // past the toasts
  });

  testWidgets('Delete asks first, then removes the row', (
    WidgetTester t,
  ) async {
    final (:AppStore s, nav: _, form: _) = await _open(t);
    await t.tap(find.byTooltip('Delete'));
    await t.pumpAndSettle();
    expect(find.text('Delete this form?'), findsOneWidget);
    await t.tap(find.widgetWithText(Btn, 'Delete Form'));
    await t.pumpAndSettle();
    expect(s.forms, isEmpty);
    await t.pump(const Duration(seconds: 30));
  });

  testWidgets('the pencil and the row open the designer', (
    WidgetTester t,
  ) async {
    final (s: _, :AssessmentNav nav, :FormDef form) = await _open(t);
    await t.tap(find.byTooltip('Edit'));
    await t.pumpAndSettle();
    expect(nav.current, FormDesigner(form.id));

    nav.back();
    await t.pumpAndSettle();
    await t.tap(find.text('Site intake'));
    await t.pumpAndSettle();
    expect(nav.current, FormDesigner(form.id));
  });

  testWidgets('a Manager gets no actions; the row opens the preview', (
    WidgetTester t,
  ) async {
    final (s: _, :AssessmentNav nav, form: _) = await _open(
      t,
      role: AccessRole.manager,
    );
    expect(find.byTooltip('Duplicate'), findsNothing);
    expect(find.byTooltip('Delete'), findsNothing);

    await t.tap(find.text('Site intake'));
    await t.pumpAndSettle();
    expect(nav.current, isNot(isA<FormDesigner>()));
    expect(find.widgetWithText(Btn, 'Close'), findsOneWidget);
  });

  testWidgets('a question type opens in the template designer', (
    WidgetTester t,
  ) async {
    await _open(t);
    await t.tap(find.text('Question Types'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Edit this question type'));
    await t.pumpAndSettle();
    expect(find.byType(TaskTemplateEditor), findsOneWidget);
  });
}
