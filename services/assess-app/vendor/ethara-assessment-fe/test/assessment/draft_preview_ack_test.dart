// THE DEAD END, as reported: "there is no option in Drafts (of Generator) to
// approve the question if it has any flags".
//
// The Drafts tab's approve tick routes through `store.decideDraft`, which
// refuses a draft carrying a blocking warning and hands back its id so the
// caller can open the preview. The preview printed the warnings read-only and
// its footer held one button: Close. So the reviewer was shown the reason and
// given no way to accept it - the row stayed Pending with a "1" in the Warnings
// column and nothing on any screen could move it.
//
// This pins the PIXELS of the way out. `draft_ack_test.dart` pins what the
// store then sends.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart'
    show showQuestionPreview;
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';

/// The hoodie draft from the report: flagged for citing the source document.
Question _flagged() => Question.fromJson(<String, dynamic>{
  'id': '9',
  'name': 'Task: Audit Main Image and Reference Match (Hoodie)',
  'question_type': 'subjective_rubric',
  'state': 'draft',
  'difficulty': 'medium',
  'prompt': 'Per Section 4.2 of the SOP, audit the image set.',
  'rubric': <String>['Names the failing phase.'],
  'official_reasoning': 'Both images carry deliberately planted flaws.',
  'warnings': <String, dynamic>{
    'revealing_option': false,
    'source_reference': true,
  },
});

/// A draft with nothing to acknowledge, for the contrast case.
Question _clean() => Question.fromJson(<String, dynamic>{
  'id': '11',
  'name': 'Defining Same Photoshoot',
  'question_type': 'subjective_rubric',
  'state': 'draft',
  'difficulty': 'easy',
  'prompt': 'Define what makes two photos the same photoshoot.',
  'rubric': <String>['Names lighting and background.'],
  'official_reasoning': 'Lighting and background decide it.',
  'warnings': <String, dynamic>{
    'revealing_option': false,
    'source_reference': false,
  },
});

/// Opens the preview the way the Drafts tab's refused tick does.
Future<AppStore> _openPreview(WidgetTester tester, Question draft) async {
  tester.view.physicalSize = const Size(1600, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final AppStore store = AppStore();
  addTearDown(store.dispose);
  store.drafts = <Question>[draft];

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showQuestionPreview(context, store, draft),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('a flagged draft states the warning and offers the way out', (
    WidgetTester tester,
  ) async {
    await _openPreview(tester, _flagged());

    expect(
      // `Notice` renders its strong lead and its body as one span, so this
      // matches inside rather than against a whole Text.
      find.textContaining('Cites the source document'),
      findsOneWidget,
      reason:
          'the warning must say what the server actually detected - it used '
          'to read "No source reference", the opposite problem',
    );
    expect(
      find.byType(AckBox),
      findsOneWidget,
      reason: 'THE DEAD END: the sheet had no acknowledgement control at all',
    );
    expect(
      find.text('Approve into Bank'),
      findsOneWidget,
      reason: 'and no decision either - the footer was Close alone',
    );
    expect(find.text('Deny'), findsOneWidget);
  });

  testWidgets('Approve is disabled until the warning is acknowledged', (
    WidgetTester tester,
  ) async {
    await _openPreview(tester, _flagged());

    expect(
      tester.widget<Btn>(_approveButton).onPressed,
      isNull,
      reason: 'approving a flagged draft unacknowledged would be refused',
    );

    await tester.tap(find.byType(AckBox));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Btn>(_approveButton).onPressed,
      isNotNull,
      reason:
          'ticking the box is what unlocks it - and the sheet has to repaint '
          'to show that, which is why the button sits in a ListenableBuilder',
    );
  });

  testWidgets('the tick is recorded against the draft, not the sheet', (
    WidgetTester tester,
  ) async {
    final AppStore store = await _openPreview(tester, _flagged());

    await tester.tap(find.byType(AckBox));
    await tester.pumpAndSettle();

    expect(
      store.acknowledged.contains('9'),
      isTrue,
      reason:
          'the store holds it, so the review queue and this sheet agree and '
          'the flag can travel with the request',
    );
  });

  testWidgets('the acknowledgement can be given from the keyboard', (
    WidgetTester tester,
  ) async {
    final AppStore store = await _openPreview(tester, _flagged());

    // Tab to it rather than reaching for the mouse: the review queue around
    // this control is driven by J/K/A/D, so a mouse-only gate is the one step
    // that breaks the flow. The old control was a bare GestureDetector.
    bool focused = false;
    for (int i = 0; i < 40 && !focused; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final FocusNode? node = FocusManager.instance.primaryFocus;
      focused =
          node != null &&
          node.context != null &&
          find
              .descendant(
                of: find.byType(AckBox),
                matching: find.byWidget(node.context!.widget),
              )
              .evaluate()
              .isNotEmpty;
    }
    expect(focused, isTrue, reason: 'the ack box must be reachable by Tab');

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();

    expect(
      store.acknowledged.contains('9'),
      isTrue,
      reason: 'Space on the focused box must tick it',
    );
  });

  testWidgets('a clean draft gets a decision but nothing to acknowledge', (
    WidgetTester tester,
  ) async {
    await _openPreview(tester, _clean());

    expect(find.byType(AckBox), findsNothing);
    expect(
      tester.widget<Btn>(_approveButton).onPressed,
      isNotNull,
      reason: 'there is no warning to hold it back',
    );
  });

  testWidgets('a BANK question is offered no decision at all', (
    WidgetTester tester,
  ) async {
    await _openPreview(
      tester,
      _clean().copyWith(state: DraftState.approved),
    );

    expect(
      find.text('Approve into Bank'),
      findsNothing,
      reason: 'it is already past this gate - the same sheet serves the bank',
    );
    expect(find.text('Deny'), findsNothing);
    expect(find.text('Close'), findsOneWidget);
  });
}

/// The Approve button itself. `Btn` paints a `GestureDetector`, not a
/// `TextButton`, so the enabled state has to be read off the `Btn`.
Finder get _approveButton => find.ancestor(
  of: find.text('Approve into Bank'),
  matching: find.byType(Btn),
);
