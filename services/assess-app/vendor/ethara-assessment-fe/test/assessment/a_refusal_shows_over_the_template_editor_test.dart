// A refusal shows OVER the task template editor, from every place that opens
// it (stage's `showToastedDialog` call sites).
//
// The editor is a dialog on the root navigator, above the screen's toast layer,
// so a refused template save stayed hidden under it until the editor closed.
// See `a_refusal_shows_over_the_sheet_test.dart` for the sheets themselves.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart'
    show showQuestionPreview;
import 'package:ethara_assessment/assessment/screens/admin/form_studio_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/generator_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/task_template_editor.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';

const String _refusal = 'Give the template at least one axis.';

/// The editor is open, and a toast fired now paints on top of it, once.
Future<void> _toastIsOnTop(WidgetTester t, AppStore s) async {
  expect(find.byType(TaskTemplateEditor), findsOneWidget);
  s.toaster.bad(_refusal);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  expect(
    find.text(_refusal).hitTestable(),
    findsOneWidget,
    reason: 'the toast must be on top of the editor, not under its scrim',
  );
  expect(find.text(_refusal), findsOneWidget);
  await t.pump(const Duration(seconds: 30));
}

/// The generator page's Skills & Templates tab, with one template of its own.
Future<AppStore> _generatorPage(WidgetTester t) async {
  t.view.physicalSize = const Size(1500, 4200);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final AppStore s = AppStore();
  addTearDown(s.dispose);
  s.generators = <Generator>[
    ...s.generators,
    // Tagged, so the tab shows its panels rather than "read the SOP first".
    Generator.fromJson(<String, dynamic>{
      'id': 5,
      'name': 'Ad review SOP',
      'tags': <String>['ads'],
    }),
  ];
  s.taskTemplates = <TaskTemplate>[
    const TaskTemplate(id: 77, name: 'Pick the better ad', originId: 5),
  ];
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: ToastHost(
            toaster: s.toaster,
            child: GeneratorDetailScreen(store: s, genId: '5', tab: 'skills'),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return s;
}

void main() {
  testWidgets('New Template on the generator page', (WidgetTester t) async {
    final AppStore s = await _generatorPage(t);
    await t.tap(find.text('New Template'));
    await t.pumpAndSettle();
    await _toastIsOnTop(t, s);
  });

  testWidgets("a template row's Edit", (WidgetTester t) async {
    final AppStore s = await _generatorPage(t);
    expect(find.text('Pick the better ad'), findsOneWidget);
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    await _toastIsOnTop(t, s);
  });

  testWidgets("a question preview's Make a task template", (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1600, 1600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final Map<String, dynamic> record = <String, dynamic>{
      'id': '9603',
      'name': 'Which action comes first?',
      'question_type': 'mcq',
      'state': 'approved',
      'difficulty': 'easy',
      'prompt': 'Which action comes first?',
      'generator': <String, dynamic>{'id': 5, 'name': 'Ad review SOP'},
    };
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient(
          (http.Request _) async => http.Response(
            jsonEncode(<String, dynamic>{'ok': true, 'data': record}),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          ),
        ),
      ),
    )..source = DataSource.live;
    addTearDown(s.dispose);
    final Question q = Question.fromJson(record);
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ToastHost(
            toaster: s.toaster,
            child: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => showQuestionPreview(context, s, q),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    await t.tap(find.byTooltip('Make a task template from this question'));
    await t.pumpAndSettle();
    await _toastIsOnTop(t, s);
  });

  testWidgets("Form Studio's Question Types Edit, which a stray click does "
      'not close', (WidgetTester t) async {
    t.view.physicalSize = const Size(1600, 1400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final AppStore s = AppStore();
    addTearDown(s.dispose);
    s.taskTemplates = <TaskTemplate>[
      const TaskTemplate(id: 77, name: 'Pick the better ad'),
    ];
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ToastHost(
            toaster: s.toaster,
            child: FormStudioScreen(store: s),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Question Types'));
    await t.pumpAndSettle();

    await t.tap(find.byTooltip('Edit this question type').first);
    await t.pumpAndSettle();
    // Unsaved edits live in the editor: the scrim must not dismiss it.
    await t.tapAt(const Offset(4, 4));
    await t.pumpAndSettle();
    await _toastIsOnTop(t, s);
  });
}
