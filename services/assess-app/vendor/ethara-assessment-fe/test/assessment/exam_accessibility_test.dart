// A CANDIDATE WHO CANNOT SEE THE SCREEN MUST STILL BE ABLE TO SIT THE EXAM.
//
// The server-rendered runner this app replaced got most of this from the
// browser: real `<input type=radio|checkbox>` inside a `<fieldset>` with a
// `<legend>`, `role="timer"` beside an `aria-live` announcer, `role=progressbar`
// with `aria-valuenow`, `role=alertdialog aria-modal` on the camera gate. None of
// it survived the port. The Flutter exam tree had THREE `Semantics` sites in
// total, and the answer options - the primary control on every question - had
// none at all: they were painted boxes with a tap listener.
//
// Concretely, before this: a screen reader announced an option's label as static
// text with no state, so a chosen option and an unchosen one were
// indistinguishable and nothing said either could be picked. `GestureDetector`
// takes no focus, so options were unreachable by Tab and the exam could not be
// sat from a keyboard at all. Single-select and multi-select sounded identical.
// And the clock was silent, so "how long have I got" was unanswerable.
//
// ASSERTED ON THE SEMANTICS TREE, never on pixels. What matters is what a
// reader is told, and a golden test of the same widget would pass while saying
// nothing about it.
library;

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/exam/answer_layouts.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter/material.dart';
// `CheckedState` and `Tristate` - the tristate flag values that replaced the
// deprecated `SemanticsNode.hasFlag`.
import 'dart:ui' show CheckedState, Tristate;

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A question with one axis of `labels`, single- or multi-select.
Question _question(List<String> labels, {required bool multi}) => Question(
  id: 'q1',
  genId: 'g1',
  name: 'Pick',
  prompt: 'Which of these?',
  type: multi ? QType.msq : QType.mcq,
  dims: <QDimension>[
    QDimension(
      id: 'd1',
      code: 'D1',
      name: 'Failure mode',
      inputKind: multi ? 'checkboxes' : 'radio',
      options: <QOption>[
        for (int i = 0; i < labels.length; i++)
          QOption(id: 'o$i', label: labels[i], correct: i == 0),
      ],
    ),
  ],
);

void main() {
  void desktop(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// The answer area for one question, in a bare harness.
  ///
  /// The attempt is REGISTERED on the store and the tree rebuilds on
  /// `notifyListeners`. `AnswerArea` re-reads the response through
  /// `store.responseFor` on every build, so without both of these a pick writes
  /// through and nothing repaints - the assertion would then be about the
  /// harness rather than about the widget.
  Widget host(Question q, {bool readOnly = false}) {
    final AppStore store = AppStore();
    final Attempt ev = Attempt(
      id: 'a1',
      assessmentId: 'asm1',
      employeeId: 'p1',
      token: 'tok',
      resp: <String, Response>{q.id: Response.seed(q)},
    );
    store.attempts = <Attempt>[ev];
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: store,
          builder: (BuildContext _, Widget? _) => SingleChildScrollView(
            child: AnswerArea(
              store: store,
              ev: ev,
              q: q,
              readOnly: readOnly,
            ),
          ),
        ),
      ),
    );
  }

  group('an answer option is a control, not a painted box', () {
    testWidgets('single-select options announce as mutually exclusive', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(host(_question(<String>['Alpha', 'Bravo'],
          multi: false)));
      await tester.pump();

      // `inMutuallyExclusiveGroup` is what makes a reader say "radio button"
      // rather than "checkbox" - the difference between "pick one" and "pick
      // any", which was previously conveyed by the glyph alone.
      expect(
        tester.getSemantics(find.bySemanticsLabel('Alpha')),
        matchesSemantics(
          label: 'Alpha',
          hasEnabledState: true,
          isEnabled: true,
          hasCheckedState: true,
          isChecked: false,
          isInMutuallyExclusiveGroup: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('multi-select options do NOT claim exclusivity', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(host(_question(<String>['Alpha', 'Bravo'],
          multi: true)));
      await tester.pump();

      final SemanticsNode node =
          tester.getSemantics(find.bySemanticsLabel('Alpha'));
      expect(node.flagsCollection.isChecked != CheckedState.none, isTrue);
      expect(
        node.flagsCollection.isInMutuallyExclusiveGroup,
        isFalse,
        reason: 'a checkboxes axis must not be announced as a radio group - '
            '"pick one" and "pick any" sounded the same before',
      );
      handle.dispose();
    });

    testWidgets('picking an option flips its announced checked state', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(host(_question(<String>['Alpha', 'Bravo'],
          multi: false)));
      await tester.pump();

      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Alpha'))
            .flagsCollection.isChecked == CheckedState.isTrue,
        isFalse,
      );

      await tester.tap(find.text('Alpha'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Alpha'))
            .flagsCollection.isChecked == CheckedState.isTrue,
        isTrue,
        reason: 'without a checked state a reader cannot tell a chosen option '
            'from an unchosen one',
      );
      handle.dispose();
    });

    testWidgets('an option can be reached by Tab and picked with Space', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      final Question q = _question(<String>['Alpha', 'Bravo'], multi: false);
      await tester.pumpWidget(host(q));
      await tester.pump();

      // THE EXAM WAS UNSITTABLE FROM A KEYBOARD. `GestureDetector` takes no
      // focus, so no amount of tabbing reached an answer at all.
      //
      // The option is focused DIRECTLY rather than by counting Tab presses:
      // where it sits in the traversal ring depends on the whole page and is
      // not what this test is about. What is under test is that the option
      // takes focus and that Space activates it.
      // Reached through `Focus.of` from inside the option rather than by
      // pulling a `focusNode` off the widget: `FocusableActionDetector` creates
      // and owns its node internally, so `Focus.focusNode` is null there.
      final FocusNode node = Focus.of(tester.element(find.text('Alpha')));
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue,
          reason: 'an answer option must be able to hold keyboard focus - '
              'a GestureDetector takes none, so the exam could not be sat '
              'from a keyboard at all');

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.byWidgetPredicate(
          (Widget w) => w is Icon && w.icon == Icons.circle,
        ),
        findsOneWidget,
        reason: 'Space on a focused option must select it',
      );
    });

    testWidgets('a read-only option is announced as disabled', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(_question(<String>['Alpha'], multi: false), readOnly: true),
      );
      await tester.pump();

      final SemanticsNode node =
          tester.getSemantics(find.bySemanticsLabel('Alpha'));
      expect(node.flagsCollection.isEnabled == Tristate.isTrue, isFalse);
      handle.dispose();
    });
  });

  group('each axis is a named group', () {
    testWidgets('the axis name is spoken once, not per option', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      final SemanticsHandle handle = tester.ensureSemantics();
      // TWO axes, so the group labels are rendered - a single-axis question
      // does not repeat the name it already has in its prompt.
      final Question q = Question(
        id: 'q1',
        genId: 'g1',
        name: 'Judge',
        prompt: 'Rate both.',
        type: QType.mcq,
        dims: <QDimension>[
          QDimension(
            id: 'd1',
            code: 'D1',
            name: 'Sharpness',
            options: <QOption>[
              const QOption(id: 'a', label: 'Better', correct: true),
              const QOption(id: 'b', label: 'Worse'),
            ],
          ),
          QDimension(
            id: 'd2',
            code: 'D2',
            name: 'Colour',
            options: <QOption>[
              const QOption(id: 'c', label: 'Better', correct: true),
              const QOption(id: 'd', label: 'Worse'),
            ],
          ),
        ],
      );
      await tester.pumpWidget(host(q));
      await tester.pump();

      // THE BUG: two axes of "Better"/"Worse" in a flat run, with nothing
      // saying which axis either pair belongs to. An A/B evaluation has six.
      expect(find.bySemanticsLabel('Sharpness'), findsOneWidget);
      expect(find.bySemanticsLabel('Colour'), findsOneWidget);
      // Once each - the eyebrow text is excluded so the name is not read twice
      // on the way into the group.
      expect(find.bySemanticsLabel('SHARPNESS'), findsNothing);
      handle.dispose();
    });
  });

  group('the clock is legible without sight', () {
    Widget clockHost(DateTime? deadline) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Clock(deadline: deadline, onExpire: () {}),
      ),
    );

    testWidgets('it announces what the number MEANS, not just the digits', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        clockHost(DateTime.now().add(const Duration(minutes: 7, seconds: 5))),
      );
      await tester.pump();

      // "07:05" is read as "seven colon zero five" or as a bare number, neither
      // of which says it is a countdown. The QWeb runner used `role="timer"`.
      expect(
        find.bySemanticsLabel(RegExp('Time remaining: 7 minutes')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('an unstarted clock says so rather than reading 00:00', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(clockHost(null));
      await tester.pump();

      expect(
        find.bySemanticsLabel(RegExp('Not started')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('it is a live region so a reader can poll it', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        clockHost(DateTime.now().add(const Duration(minutes: 12))),
      );
      await tester.pump();

      expect(
        tester
            .getSemantics(find.bySemanticsLabel(RegExp('Time remaining')))
            .flagsCollection.isLiveRegion,
        isTrue,
      );
      handle.dispose();
    });
  });

  group('a blocking overlay is a modal, and announces itself', () {
    testWidgets('it scopes the route so a reader cannot walk behind it', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Stack(
              children: <Widget>[
                const Text('a question behind the overlay'),
                BlockOverlay(
                  tone: Tone.bad,
                  icon: Icons.videocam_off_outlined,
                  title: 'Your camera is off',
                  body: 'Turn it back on to continue.',
                  action: 'Enable camera',
                  onAction: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // Without `scopesRoute` the paper behind stays fully readable and
      // navigable while the screen says the exam is blocked - so a candidate
      // could answer questions during a camera refusal and never be told.
      // `.first` because the label matches both the scoping node and the
      // title Text inside it; the OUTER one carries the route flags.
      final SemanticsNode node = tester.getSemantics(
        find.bySemanticsLabel('Your camera is off').first,
      );
      expect(node.flagsCollection.scopesRoute, isTrue);
      expect(node.flagsCollection.namesRoute, isTrue);
      handle.dispose();
    });

    testWidgets('the title is a live region, because nothing else announces it',
        (WidgetTester tester) async {
      desktop(tester);
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Stack(
              children: <Widget>[
                BlockOverlay(
                  tone: Tone.warn,
                  icon: Icons.schedule,
                  title: 'Time is up',
                  body: AppStore.timeUpMessage,
                  action: 'See my submission',
                  onAction: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // These overlays appear in response to the BROWSER - a revoked camera, a
      // dropped fullscreen, a passed deadline - never to a keypress, so nothing
      // else would draw a screen-reader user's attention to one.
      expect(
        tester
            .getSemantics(find.text('Time is up'))
            .flagsCollection.isLiveRegion,
        isTrue,
      );
      handle.dispose();
    });
  });

  group('progress carries a value', () {
    testWidgets('the bar announces how many are answered, not just "progress"',
        (WidgetTester tester) async {
      desktop(tester);
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const Scaffold(
            body: ExamTopBar(
              title: 'Quality Assessment',
              questionNumber: 3,
              total: 12,
              answered: 2,
              onExpire: _noop,
            ),
          ),
        ),
      );
      await tester.pump();

      // A bare LinearProgressIndicator announces "progress bar" and no number,
      // so "how far through am I" was unanswerable. The QWeb runner carried
      // `role=progressbar aria-valuenow`.
      expect(
        find.bySemanticsLabel('2 of 12 questions answered'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}

void _noop() {}
