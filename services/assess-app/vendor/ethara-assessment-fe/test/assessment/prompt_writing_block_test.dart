// THE PROMPT-WRITING BLOCK, in the designer and in the respondent view.
//
// `image_prompt` and `video_prompt` are two of the seven stored question
// types. The exam runner has always rendered them; the SERVER has always been
// able to store them (a task template routes `author_prompt` /
// `author_video_prompt` onto them). Form Studio could not express them at all
// - no `FormItemKind` produced either, so a designer's form could never carry
// one, and a generated one opened as a lossy paragraph that downgraded to
// plain free text if it was saved back.
//
// `FormItemKind.promptWriting` is the one kind that serves both, with the
// medium read from the attached media rather than asked of the author. These
// tests pin the client half of that: the editor collects what the type needs,
// and the preview asks for it in the same order the exam runner does.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_item_editor.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_preview.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Future<void> _pumpEditor(WidgetTester tester, FormItem item) async {
  tester.view.physicalSize = const Size(1600, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: FormItemEditor(
            store: AppStore(),
            item: item,
            index: 0,
            showDragHandle: false,
            onEdit: (VoidCallback mutate) => mutate(),
            onDuplicate: () {},
            onDelete: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpPreview(WidgetTester tester, FormDef form) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(child: FormPreview(form: form)),
      ),
    ),
  );
  await tester.pump();
}

FormDef _formWith(FormItem item) => FormDef(
  'form-1',
  title: 'Prompt set',
  sections: <FormSection>[
    FormSection('sec-1', items: <FormItem>[item]),
  ],
);

void main() {
  group('the kind exists and behaves like a question', () {
    test('it is answerable with NO options, unlike the media blocks', () {
      // A media block with no options is decoration. Prompt writing is not:
      // the written prompt is the answer whether or not axes were added, so
      // it must never fall into the options-gated branch of `isAnswerable`.
      final FormItem it = formNewItem(FormItemKind.promptWriting);
      expect(it.options, isEmpty, reason: 'axes are opt-in, not seeded');
      expect(it.isAnswerable, isTrue);
      expect(it.kind.isQuestion, isTrue);
    });

    test('it carries options for the OPTIONAL rating axes', () {
      expect(FormItemKind.promptWriting.hasOptions, isTrue);
    });

    // The "it never branches" case is gone with `canBranch`: NO kind branches
    // any more, so asserting it of this one says nothing specific to it.
    // `forms_are_linear_test.dart` pins the whole-model rule.

    test('it round-trips through JSON with both slots and the key', () {
      final FormItem it = formNewItem(FormItemKind.promptWriting)
        ..title = 'Write the prompt'
        ..mediaUrl = 'https://x/ref.png'
        ..mediaUrlB = 'https://x/out.png'
        ..goldenAnswer = 'A red barn at dusk.';
      final FormItem back = FormItem.fromJson(it.toJson());
      expect(back.kind, FormItemKind.promptWriting);
      expect(back.mediaUrl, 'https://x/ref.png');
      expect(back.mediaUrlB, 'https://x/out.png');
      expect(back.goldenAnswer, 'A red barn at dusk.');
    });
  });

  group('the designer collects what the type needs', () {
    testWidgets('it asks for the media and the golden prompt', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(tester, formNewItem(FormItemKind.promptWriting));
      expect(find.text('THE IMAGE OR CLIP'), findsOneWidget);
      expect(find.text('OUTPUT (OPTIONAL)'), findsOneWidget);
      expect(
        find.text('GOLDEN PROMPT (FOR THE LLM JUDGE)'),
        findsOneWidget,
      );
    });

    testWidgets('the second slot renames once it is a real pair', (
      WidgetTester tester,
    ) async {
      // Filling the output slot turns the question from "produce this" into
      // "turn the reference INTO this", and the labels have to say so.
      final FormItem it = formNewItem(FormItemKind.promptWriting)
        ..mediaUrl = 'https://x/ref.png'
        ..mediaUrlB = 'https://x/out.png';
      await _pumpEditor(tester, it);
      expect(find.text('REFERENCE'), findsOneWidget);
      expect(find.text('OUTPUT'), findsOneWidget);
      expect(find.text('OUTPUT (OPTIONAL)'), findsNothing);
    });

    testWidgets('axes are opt-in and say what adding one does', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(tester, formNewItem(FormItemKind.promptWriting));
      expect(find.textContaining('Rating axes (optional)'), findsOneWidget);
      expect(find.text('Add an axis'), findsOneWidget);
      // No option rows until the examiner asks for one.
      expect(find.text('Add option'), findsNothing);
    });

    testWidgets('adding an axis reveals the option editor', (
      WidgetTester tester,
    ) async {
      final FormItem it = formNewItem(FormItemKind.promptWriting);
      await _pumpEditor(tester, it);
      await tester.tap(find.text('Add an axis'));
      await tester.pump();
      expect(it.options, hasLength(1));
      expect(find.text('Add option'), findsOneWidget);
    });
  });

  group('the respondent view matches the exam runner', () {
    testWidgets('it asks for a prompt, and names the medium', (
      WidgetTester tester,
    ) async {
      final FormItem it = formNewItem(FormItemKind.promptWriting)
        ..title = 'Write the prompt'
        ..mediaUrl = 'https://x/ref.png';
      await _pumpPreview(tester, _formWith(it));

      expect(find.text('Your prompt'), findsOneWidget);
      // A still asks for an IMAGE prompt.
      expect(
        find.textContaining('image-generation prompt'),
        findsOneWidget,
      );
    });

    testWidgets('a clip asks for a VIDEO prompt instead', (
      WidgetTester tester,
    ) async {
      final FormItem it = formNewItem(FormItemKind.promptWriting)
        ..title = 'Write the prompt'
        ..mediaUrl = 'https://x/clip.mp4';
      await _pumpPreview(tester, _formWith(it));
      expect(
        find.textContaining('video-generation prompt'),
        findsOneWidget,
      );
    });

    testWidgets('a pair labels which plate is which', (
      WidgetTester tester,
    ) async {
      final FormItem it = formNewItem(FormItemKind.promptWriting)
        ..title = 'Write the transform prompt'
        ..mediaUrl = 'https://x/ref.png'
        ..mediaUrlB = 'https://x/out.png';
      await _pumpPreview(tester, _formWith(it));
      // On the pair form the label is the only thing telling them apart.
      expect(find.text('Reference'), findsOneWidget);
      expect(find.text('Output'), findsOneWidget);
    });

    testWidgets('the examiner preview opens with the golden prompt typed', (
      WidgetTester tester,
    ) async {
      // `showKeys` is the examiner's own preview: it opens as the PERFECT
      // submission, which for this kind means the golden prompt already in
      // the box - the same courtesy every other keyed kind gets.
      final FormItem it = formNewItem(FormItemKind.promptWriting)
        ..title = 'Write the prompt'
        ..mediaUrl = 'https://x/ref.png'
        ..goldenAnswer = 'A red barn at dusk, wide shot.';
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: FormPreview(form: _formWith(it), showKeys: true),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.text('A red barn at dusk, wide shot.'),
        findsOneWidget,
      );
    });
  });
}
