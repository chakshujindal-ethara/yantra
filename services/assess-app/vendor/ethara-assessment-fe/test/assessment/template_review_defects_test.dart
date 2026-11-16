// Four defects found by driving the real screens, all in the reviewer's view of
// a TEMPLATE-authored question.
//
// NOTE: `Eyebrow` renders its label through `.toUpperCase()`, so assertions on
// section headings match the SHOUTED form the widget actually paints.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/admin/task_template_editor.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

TaskTemplate _tpl({String response = 'compare_two', List<dynamic>? structure}) =>
    TaskTemplate(
      id: 1,
      name: 'Verify a single photo edit',
      response: response,
      structure: structure ?? const <dynamic>[],
    );

/// A three-axis Yes/No task with NO correct option marked anywhere - which is
/// the correct state for a template.
List<dynamic> _threeAxesNoKey() => <dynamic>[
      <String, dynamic>{
        'id': 's1',
        'title': 'Checks',
        'items': <dynamic>[
          for (final String q in <String>[
            'Was the instruction applied?',
            'Is the subject preserved?',
            'Is the rest of the frame free of collateral damage?',
          ])
            <String, dynamic>{
              'id': q,
              'kind': 'multipleChoice',
              'title': q,
              'options': <dynamic>[
                <String, dynamic>{'label': 'Yes'},
                <String, dynamic>{'label': 'No'},
              ],
            },
        ],
      },
    ];

Future<void> _mount(WidgetTester tester, TaskTemplate tpl) async {
  tester.view.physicalSize = const Size(1600, 4000);
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

void main() {
  group('a template is not asked for answers it cannot have', () {
    testWidgets('no "no correct option" warning for an unkeyed template',
        (WidgetTester t) async {
      // The key belongs to each GENERATED instance, not to the shape. The
      // editor used to list one warning per question and the picker badged the
      // template "Generates nothing".
      await _mount(t, _tpl(structure: _threeAxesNoKey()));

      expect(find.textContaining('has no correct option marked'), findsNothing);
      expect(find.textContaining('Fix before generating'), findsNothing);
    });

    testWidgets('a genuinely broken shape is still reported',
        (WidgetTester t) async {
      // One option is not a choice - the generator cannot reproduce it.
      await _mount(
          t,
          _tpl(structure: <dynamic>[
            <String, dynamic>{
              'id': 's1',
              'title': 'S',
              'items': <dynamic>[
                <String, dynamic>{
                  'id': 'q1',
                  'kind': 'multipleChoice',
                  'title': 'Only one option',
                  'options': <dynamic>[
                    <String, dynamic>{'label': 'Yes'},
                  ],
                },
              ],
            },
          ]));

      expect(find.textContaining('needs at least two options'), findsOneWidget);
    });
  });

  group('the examiner can see the task carries media', () {
    testWidgets('compare-two shows both response slots', (WidgetTester t) async {
      await _mount(t, _tpl(structure: _threeAxesNoKey()));

      expect(find.text('THE IMAGE A CANDIDATE SEES'), findsOneWidget);
      expect(find.text('Response A'), findsOneWidget);
      expect(find.text('Response B'), findsOneWidget);
      expect(find.textContaining('planted flaw'), findsOneWidget);
    });

    testWidgets('a video task says clip, not image', (WidgetTester t) async {
      await _mount(t, _tpl(response: 'author_video_prompt'));

      expect(find.text('THE CLIP A CANDIDATE SEES'), findsOneWidget);
      expect(find.text('The target clip'), findsOneWidget);
    });

    testWidgets('an annotation task shows one slot', (WidgetTester t) async {
      await _mount(t, _tpl(response: 'annotate_image'));

      expect(find.text('The image to mark'), findsOneWidget);
    });

    testWidgets('a text-only task shows no media slots', (WidgetTester t) async {
      await _mount(t, _tpl(response: 'free_text'));

      expect(find.text('THE IMAGE A CANDIDATE SEES'), findsNothing);
      expect(find.text('THE CLIP A CANDIDATE SEES'), findsNothing);
    });
  });

  group('a draft is labelled with its task, not the engine', () {
    test('the template name wins over the question type', () {
      final Question q = Question.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'Task: Verify an object removal',
        'type': 'image_ab',
        'source_template': <String, dynamic>{
          'id': 16,
          'name': 'Verify a single photo edit',
        },
      });

      expect(q.sourceTemplateName, 'Verify a single photo edit');
      // The engine type is still there for anything that needs it.
      expect(q.type, QType.imageAb);
    });

    test('a model-authored draft falls back to the type', () {
      final Question q = Question.fromJson(<String, dynamic>{
        'id': 2,
        'name': 'Compare the two images',
        'type': 'image_ab',
      });

      expect(q.sourceTemplateName, '');
    });
  });
}
