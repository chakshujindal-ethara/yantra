// The template editor shows the answer-key fields the PRIMITIVE needs.
//
// WHY A WIDGET TEST AND NOT A BROWSER RUN. The editor opens from a
// virtualised generator table inside a CanvasKit canvas: there is no DOM to
// query, no deep-link route to the screen, and row text never reaches the
// accessibility tree. Mounting the screen exercises the SAME widget and lets
// the assertions read what a person actually reads.
//
// WHAT THIS PINS. A template used to carry axes and options only - exactly
// what an A/B item needs and almost nothing of what the other primitives
// need. So a written answer's rubric, an annotation task's target list and a
// generated stimulus's brief were all invented by the model, per item, with
// no examiner input. These fields are how the examiner states them, so they
// must appear for the right primitive and stay out of the way for the rest.
// NOTE: `Eyebrow` renders its label through `.toUpperCase()`, so these
// assertions match the SHOUTED form the widget actually paints.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/admin/task_template_editor.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

TaskTemplate _tpl({
  String response = 'single_choice',
  String rubricCriteria = '',
  String rubricPassCondition = '',
  String annotationTargets = '',
  int annotationExpectedCount = 0,
  String mediaBrief = '',
}) =>
    TaskTemplate(
      id: 1,
      name: 'A task',
      response: response,
      rubricCriteria: rubricCriteria,
      rubricPassCondition: rubricPassCondition,
      annotationTargets: annotationTargets,
      annotationExpectedCount: annotationExpectedCount,
      mediaBrief: mediaBrief,
      structure: const <dynamic>[],
    );

Future<void> _mount(WidgetTester tester, TaskTemplate tpl) async {
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

void main() {
  group('answer-key fields follow the primitive', () {
    testWidgets('a written answer asks for a rubric', (WidgetTester t) async {
      await _mount(t, _tpl(response: 'free_text'));

      expect(find.text('HOW THE ANSWER IS MARKED'), findsOneWidget);
      expect(find.text('A PASSING ANSWER MUST'), findsOneWidget);
      expect(find.text('WHAT THE CANDIDATE MUST MARK'), findsNothing,
          reason: 'a written answer is not an annotation task');
    });

    testWidgets('an annotation task asks what to mark', (WidgetTester t) async {
      await _mount(t, _tpl(response: 'annotate_image'));

      expect(find.text('WHAT THE CANDIDATE MUST MARK'), findsOneWidget);
      expect(find.text('MARKS IN A COMPLETE ANSWER'), findsOneWidget);
      expect(find.text('HOW THE ANSWER IS MARKED'), findsNothing,
          reason: 'an annotation task is not graded by rubric');
    });

    testWidgets('a video prompt asks what the clip shows',
        (WidgetTester t) async {
      await _mount(t, _tpl(response: 'author_video_prompt'));

      expect(find.text('WHAT THE CLIP MUST SHOW'), findsOneWidget);
      expect(find.text('WHAT THE IMAGE MUST SHOW'), findsNothing,
          reason: 'the wording follows the medium');
    });

    testWidgets('an image prompt asks what the image shows',
        (WidgetTester t) async {
      await _mount(t, _tpl(response: 'author_prompt'));

      expect(find.text('WHAT THE IMAGE MUST SHOW'), findsOneWidget);
    });

    testWidgets('a plain multiple-choice task asks for none of them',
        (WidgetTester t) async {
      await _mount(t, _tpl(response: 'single_choice'));

      expect(find.text('HOW THE ANSWER IS MARKED'), findsNothing);
      expect(find.text('WHAT THE CANDIDATE MUST MARK'), findsNothing);
      expect(find.text('WHAT THE IMAGE MUST SHOW'), findsNothing);
    });
  });

  group('what the examiner authored survives a round trip', () {
    testWidgets('rubric criteria render as typed', (WidgetTester t) async {
      await _mount(
          t,
          _tpl(
            response: 'free_text',
            rubricCriteria: 'Identifies the flaw\nProposes a fix',
            rubricPassCondition: 'Names the flaw AND proposes a fix',
          ));

      expect(find.text('Identifies the flaw\nProposes a fix'), findsOneWidget);
      expect(find.text('Names the flaw AND proposes a fix'), findsOneWidget);
    });

    testWidgets('the expected count derives from the target list',
        (WidgetTester t) async {
      await _mount(
          t,
          _tpl(
            response: 'annotate_image',
            annotationTargets: 'Extra finger\nMisspelled sign\nMelted edge',
          ));

      // 0 means "derive it", and the field says so rather than showing a bare 0.
      expect(find.text('3'), findsOneWidget);
      expect(find.textContaining('Every target above'), findsOneWidget);
    });

    testWidgets('an explicit count wins over the list length',
        (WidgetTester t) async {
      await _mount(
          t,
          _tpl(
            response: 'annotate_image',
            annotationTargets: 'A\nB\nC\nD\nE',
            annotationExpectedCount: 3,
          ));

      expect(find.textContaining('marks 3 of the targets'), findsOneWidget);
    });
  });

  testWidgets('the video primitive is offered at all', (WidgetTester t) async {
    // video_prompt was a stored question type NO primitive could reach, so an
    // examiner could never author a video task however they tried.
    expect(kResponsePrimitives.containsKey('author_video_prompt'), isTrue);
    expect(kResponsePrimitives['author_video_prompt'],
        'Write a prompt for a clip');
  });
}
