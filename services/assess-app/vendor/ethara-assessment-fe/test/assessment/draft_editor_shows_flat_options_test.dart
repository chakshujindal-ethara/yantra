// Editing an MCQ/MSQ draft shows the options it actually carries.
//
// THE DEFECT, reproduced in a real browser before the fix. Edit Draft on an
// mcq rendered Title, Question, Description, Time, Answer rationale,
// Difficulty - and then Cancel/Save. NO options section at all, over a draft
// whose four options and answer key the review card behind the sheet was
// rendering correctly. Measured on live draft 197.
//
// TWO INDEPENDENT CAUSES, both needed fixing and either one alone still broke
// it:
//
//   1. CLIENT. The build draws one section per entry in `_axes` (the multi-axis
//      work moved it there), but the draft branch of `initState` only ever
//      filled `_options`. With `_axes` empty the loop ran zero times. Axis one
//      now shares the `_options` list by reference, exactly as the dimension
//      branch already arranged, so the flat save shape is unchanged.
//
//   2. SERVER. `showDraftEditor` is handed the CACHED LIST ROW - the review
//      queue, the generator's Drafts tab and the assessment preview all pass
//      the row they hold, never a detail fetch - and `options` /
//      `correct_answer` existed only in `draft_detail`. Pinned on that side by
//      `test_draft_row_carries_its_key.py`.
//
// Why it mattered: a reviewer could not fix the one thing this editor exists
// for ("fix it here rather than denying and regenerating"), and saving from
// that sheet posted an EMPTY option list over a good answer key.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/question_editor.dart';

const List<String> _options = <String>[
  'This is a verifiable AI tell of the Anatomy class.',
  'This is a verifiable AI tell of the Text / typography class.',
  'This is a verifiable AI tell of the Physics / lighting class.',
  'This is not a verifiable AI tell.',
];

/// Draft 197's real shape: the LIST-ROW payload, which is what the editor is
/// handed. Deliberately carries no `dimensions` - an mcq keys a flat list.
Question _mcqDraft() => Question.fromJson(<String, dynamic>{
  'id': 197,
  'name': 'Classifying a generated defect',
  'prompt': 'Which statement accurately describes this finding?',
  'question_type': 'mcq',
  'state': 'draft',
  'options': _options,
  'correct_answer': _options.first,
});

Question _msqDraft() => Question.fromJson(<String, dynamic>{
  'id': 198,
  'name': 'Which defects apply?',
  'question_type': 'msq',
  'state': 'draft',
  'options': <String>['Anatomy', 'Typography', 'Lighting'],
  'correct_answer': <String>['Anatomy', 'Lighting'],
});

/// The per-option "Correct" flags, in the order the options are drawn.
///
/// Read off the `SwitchRow` named "Correct" rather than off raw `Switch`
/// widgets: the toggle is a custom `Switcher`, so there is no material `Switch`
/// in the tree at all, and the sheet's OTHER switches (circulation, on a bank
/// question) must not be counted as answer-key state.
List<bool> _correctToggles(WidgetTester tester) => tester
    .widgetList<SwitchRow>(find.byType(SwitchRow))
    .where((SwitchRow s) => s.name == 'Correct')
    .map((SwitchRow s) => s.value)
    .toList();

Future<void> _open(WidgetTester tester, Question q) async {
  tester.view.physicalSize = const Size(1600, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final AppStore store = AppStore();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => showDraftEditor(context, store, q),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('an mcq draft shows every option it carries', (
    WidgetTester tester,
  ) async {
    await _open(tester, _mcqDraft());

    expect(
      find.text('OPTIONS'),
      findsOneWidget,
      reason: 'the options section rendered nowhere - the whole defect',
    );
    for (final String o in _options) {
      expect(
        find.widgetWithText(TextField, o),
        findsOneWidget,
        reason: 'option "$o" must be visible and editable',
      );
    }
  });

  testWidgets('the authored key is the one toggled on', (
    WidgetTester tester,
  ) async {
    // Not just "options appear": the RIGHT one has to be marked, or the sheet
    // would invite a reviewer to approve a key that is not the stored one.
    await _open(tester, _mcqDraft());

    final List<bool> keyed = _correctToggles(tester);
    expect(keyed.length, _options.length);
    expect(
      keyed,
      <bool>[true, false, false, false],
      reason: 'the key is option 1 (the Anatomy class), matching the row - and '
          'exactly one option is marked',
    );
  });

  testWidgets('an msq draft marks each of its several correct options', (
    WidgetTester tester,
  ) async {
    await _open(tester, _msqDraft());

    expect(find.text('OPTIONS'), findsOneWidget);
    expect(
      _correctToggles(tester),
      <bool>[true, false, true],
      reason: 'a multi-select key keeps every option it names',
    );
  });

  testWidgets('a draft with no options at all still opens', (
    WidgetTester tester,
  ) async {
    // A subjective_rubric keys nothing per-option, so the section is absent by
    // design. Guards against fixing the gap by always drawing an empty block.
    await _open(
      tester,
      Question.fromJson(<String, dynamic>{
        'id': 199,
        'name': 'Describe what is wrong',
        'question_type': 'subjective_rubric',
        'state': 'draft',
      }),
    );

    expect(find.text('OPTIONS'), findsNothing);
    expect(find.text('Save'), findsOneWidget);
  });
}
