// Form Studio lists BOTH kinds of question shape, in one place.
//
// THE GAP THIS CLOSES. A Form Studio task template was only ever visible inside
// a generator's type picker, so there was nowhere to see the full catalogue of
// shapes a run could author, compare two similarly-named templates, or tell
// which templates would actually generate anything. The built-in types were not
// listed anywhere at all. Both now appear on one searchable tab that copies the
// Forms tab's grid, toolbar and search rather than inventing a second layout.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_studio_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

TaskTemplate _tpl({
  required int id,
  required String name,
  int itemCount = 2,
  int usableCount = 2,
  String questionType = 'subjective_rubric',
}) => TaskTemplate(
  id: id,
  name: name,
  itemCount: itemCount,
  usableCount: usableCount,
  questionType: questionType,
  structure: <dynamic>[
    <String, dynamic>{
      'items': <dynamic>[
        <String, dynamic>{
          'title': 'Is the picture sharp?',
          'kind': 'multipleChoice',
        },
        <String, dynamic>{'title': 'Confidence', 'kind': 'linearScale'},
      ],
    },
  ],
);

Future<AppStore> _open(
  WidgetTester t, {
  List<TaskTemplate> templates = const <TaskTemplate>[],
  bool typesTab = true,
}) async {
  t.view.physicalSize = const Size(1600, 1400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  final AppStore store = AppStore();
  store.taskTemplates = templates;

  await t.pumpWidget(
    MaterialApp(home: Scaffold(body: FormStudioScreen(store: store))),
  );
  await t.pumpAndSettle();
  if (typesTab) {
    await t.tap(find.text('Question Types'));
    await t.pumpAndSettle();
  }
  return store;
}

void main() {
  group('Form Studio question-types tab', () {
    testWidgets('lists every built-in generatable type',
        (WidgetTester t) async {
      await _open(t);
      for (final QType q in QType.generatable) {
        expect(find.text(q.label), findsWidgets,
            reason: '${q.label} is generatable but absent from the catalogue');
      }
    });

    testWidgets('lists Form Studio templates beside the built-in types',
        (WidgetTester t) async {
      await _open(t, templates: <TaskTemplate>[
        _tpl(id: 1, name: 'IG Entity Sample Audit'),
      ]);
      expect(find.text('IG Entity Sample Audit'), findsOneWidget);
      expect(find.text('Form Studio'), findsWidgets,
          reason: 'a template must be labelled by where it came from');
      expect(find.text('Built-in'), findsWidgets);
    });

    testWidgets('an empty Items cell is a hyphen, never an em dash',
        (WidgetTester t) async {
      await _open(t);
      expect(find.text('\u2014'), findsNothing,
          reason: 'no em dash in UI text');
      expect(find.text('-'), findsWidgets);
    });

    testWidgets('flags a template that would generate nothing',
        (WidgetTester t) async {
      await _open(t, templates: <TaskTemplate>[
        _tpl(id: 2, name: 'Broken shape', itemCount: 4, usableCount: 0),
      ]);
      expect(find.text('Unusable'), findsOneWidget,
          reason: 'picking it spends money for zero questions');
    });

    testWidgets('flags a partly broken template with its usable count',
        (WidgetTester t) async {
      await _open(t, templates: <TaskTemplate>[
        _tpl(id: 3, name: 'Half shape', itemCount: 4, usableCount: 2),
      ]);
      expect(find.text('2/4 usable'), findsOneWidget);
    });

    testWidgets('search filters templates and built-in types together',
        (WidgetTester t) async {
      await _open(t, templates: <TaskTemplate>[
        _tpl(id: 4, name: 'Entity audit'),
        _tpl(id: 5, name: 'Defect critique'),
      ]);
      await t.enterText(find.byType(TextField).first, 'defect');
      await t.pumpAndSettle();
      expect(find.text('Defect critique'), findsOneWidget);
      expect(find.text('Entity audit'), findsNothing);
      expect(find.text(QType.mcq.label), findsNothing,
          reason: 'a built-in type that does not match must drop out too');
    });

    testWidgets('a built-in type previews what it asks a candidate to do',
        (WidgetTester t) async {
      await _open(t);
      await t.tap(find.text(QType.imageLabel.label).first);
      await t.pumpAndSettle();
      expect(find.textContaining('numbered region'), findsOneWidget);
    });

    testWidgets('a template previews its own questions',
        (WidgetTester t) async {
      await _open(t, templates: <TaskTemplate>[
        _tpl(id: 6, name: 'Sample audit'),
      ]);
      await t.tap(find.text('Sample audit'));
      await t.pumpAndSettle();
      expect(find.textContaining('Is the picture sharp?'), findsOneWidget);
      expect(find.textContaining('Confidence'), findsOneWidget);
    });

    testWidgets('New Form stays on the Forms tab only',
        (WidgetTester t) async {
      // The button creates a FORM, which is not what the types tab is about.
      await _open(t, typesTab: false);
      expect(find.text('New Form'), findsWidgets);
      await t.tap(find.text('Question Types'));
      await t.pumpAndSettle();
      expect(find.text('New Form'), findsNothing);
    });
  });
}
