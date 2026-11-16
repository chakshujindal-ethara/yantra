// EXPORTING A TASK TEMPLATE AS JSON.
//
// The file the Export button writes is a Form Studio import document: the
// template's `structure` already IS `sections`, so the export costs nothing and
// buys the ability to open a model draft as a real form with a real preview.
//
// WHAT THESE TESTS ARE REALLY FOR:
//
//  * THE ROUND TRIP HOLDS. Export then import must yield the same questions.
//    This is the whole claim of the feature, so it is asserted directly against
//    `formFromImportedJson` - the same parser the Import button uses - rather
//    than by eyeballing the shape.
//
//  * GENERATOR INSTRUCTIONS DO NOT BECOME A FORM DESCRIPTION. Instructions are
//    never shown to a candidate; a form description is. Mapping one onto the
//    other would leak examiner notes into an exam as soon as someone imported
//    the file and published it, and nothing in the exam runner would flag it.
//
//  * THE FILENAME IS SAFE. Real template names carry slashes and brackets
//    ("Verify Image Entities and References (Yes/No)"); a raw name would make
//    the browser read part of it as a path.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/admin/task_template_editor.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/services/json_export.dart';

/// The document `_exportDoc` builds, kept in one place so the assertions below
/// read as the file someone actually opens.
Map<String, dynamic> exportDoc({
  String name = 'Verify Image Entities',
  String instructions = 'Never shown to a candidate.',
  List<Map<String, dynamic>>? items,
}) => <String, dynamic>{
  'title': name,
  'sections': <dynamic>[
    <String, dynamic>{
      'id': 'sec-1',
      'title': 'Questions',
      'items': items ??
          <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'i1',
              'kind': 'multipleChoice',
              'title': 'Is the Picture Sharp and Clear?',
              'required': true,
              'options': <dynamic>[
                <String, dynamic>{'id': 'o1', 'label': 'Pass'},
                <String, dynamic>{'id': 'o2', 'label': 'Fail'},
              ],
            },
          ],
    },
  ],
  'published': false,
  'template': <String, dynamic>{
    'name': name,
    'response': 'single_choice',
    'instructions': instructions,
    'authored_by': 'llm_edited',
  },
  'exported_at': '2026-09-02T17:00:00.000',
};

void main() {
  group('the exported file imports back into form studio', () {
    test('the questions survive the round trip', () {
      final FormDef f = formFromImportedJson(jsonDecode(jsonEncode(exportDoc())));
      expect(f.title, 'Verify Image Entities');
      expect(f.questionCount, 1);
      final FormItem item = f.sections.single.items.single;
      expect(item.kind, FormItemKind.multipleChoice);
      expect(item.title, 'Is the Picture Sharp and Clear?');
      expect(item.options.map((FormOption o) => o.label), <String>['Pass', 'Fail']);
    });

    test('the template block does not confuse the form parser', () {
      // `template` and `exported_at` are keys a form knows nothing about.
      final FormDef f = formFromImportedJson(exportDoc());
      expect(f.sections, hasLength(1));
      expect(f.published, isFalse);
    });

    test('an import is a draft even though the export says so too', () {
      final Map<String, dynamic> doc = exportDoc()..['published'] = true;
      expect(formFromImportedJson(doc).published, isFalse);
    });
  });

  group('examiner-facing notes stay out of the candidate-facing form', () {
    test('instructions are not the form description', () {
      final Map<String, dynamic> doc =
          exportDoc(instructions: 'INTERNAL: mark harshly on colorway.');
      expect(
        doc.containsKey('description'),
        isFalse,
        reason: 'a form description IS shown to a candidate',
      );
      expect(doc['template']!['instructions'], contains('INTERNAL'));

      final FormDef f = formFromImportedJson(doc);
      expect(
        f.description,
        isEmpty,
        reason: 'importing must not surface generator instructions to '
            'candidates',
      );
    });
  });

  group('the filename is safe to hand to a browser', () {
    test('a real template name becomes a slug', () {
      expect(
        jsonFileName('Verify Image Entities and References (Yes/No)'),
        'verify-image-entities-and-references-yes-no.json',
      );
    });

    test('slashes cannot become a path', () {
      expect(jsonFileName('Image + Video / Yes-No'), isNot(contains('/')));
    });

    test('an unnamed template still gets a filename', () {
      expect(jsonFileName('', fallback: 'task-template'), 'task-template.json');
      expect(jsonFileName('///'), 'export.json');
    });

    test('it always ends in .json', () {
      for (final String n in <String>['A', 'a b c', '(Yes/No)', '']) {
        expect(jsonFileName(n), endsWith('.json'));
      }
    });
  });

  group('the file is meant to be read and edited by hand', () {
    test('it is pretty-printed, not one line', () {
      final String out =
          const JsonEncoder.withIndent('  ').convert(exportDoc());
      expect(out, contains('\n  "title"'));
      expect(out.split('\n').length, greaterThan(10));
    });
  });

  // THE BUTTON IS ACTUALLY ON SCREEN.
  //
  // Mounts the real dialog, because "the code is in the bundle" and "a person
  // can see it" are different claims - the first was true while the second was
  // being doubted, and only a render settles it.
  group('the dialog shows the export action', () {
    Future<void> mount(WidgetTester tester, TaskTemplate tpl) async {
      tester.view.physicalSize = const Size(1600, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: TaskTemplateEditor(
            store: AppStore(),
            generatorId: '177',
            template: tpl,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// A model draft, which is the state the button was asked for: id 0.
    TaskTemplate draft({bool withQuestion = true}) => TaskTemplate(
      id: 0,
      name: 'Audit Image Reference Sets (Pass/Fail)',
      response: 'single_choice',
      structure: <dynamic>[
        <String, dynamic>{
          'id': 'sec-1',
          'title': 'Questions',
          'items': withQuestion
              ? <dynamic>[
                  <String, dynamic>{
                    'id': 'i1',
                    'kind': 'multipleChoice',
                    'title': 'Is the Picture Sharp and Clear?',
                    'options': <dynamic>[
                      <String, dynamic>{'id': 'o1', 'label': 'Pass'},
                      <String, dynamic>{'id': 'o2', 'label': 'Fail'},
                    ],
                  },
                ]
              : <dynamic>[],
        },
      ],
    );

    testWidgets('it renders beside the save actions on a drafted template',
        (WidgetTester tester) async {
      await mount(tester, draft());
      expect(find.text('Review the drafted template'), findsOneWidget);
      expect(find.text('Export JSON'), findsOneWidget);
      expect(find.text('Save Template'), findsOneWidget);
    });

    testWidgets('it is enabled once there is a question',
        (WidgetTester tester) async {
      await mount(tester, draft());
      expect(
        tester.widget<Btn>(find.widgetWithText(Btn, 'Export JSON')).enabled,
        isTrue,
        reason: 'a titled question with two options is exportable',
      );
    });

    testWidgets('it is disabled when there is nothing to export',
        (WidgetTester tester) async {
      await mount(tester, draft(withQuestion: false));
      expect(
        tester.widget<Btn>(find.widgetWithText(Btn, 'Export JSON')).enabled,
        isFalse,
      );
    });
  });
}
