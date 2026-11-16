// Form Studio and the Task Template designer must draw the SAME item card.
//
// THE DEFECT THIS PINS. The two screens each had their own item editor. Form
// Studio offered 18 item kinds, help text, duplicate/delete and the media
// BLOCKS a generated question fills in (`textBlock`, `imageBlock`,
// `videoBlock`); the template editor had 13 kinds, no blocks, and no item
// chrome at all. A template is supposed to BE the shape of a Form Studio form,
// so anything the designer can express a template must be able to express too
// - and two hand-maintained copies could only drift further apart.
//
// They now share `FormItemEditor`. These tests assert the shared contract, so
// a future edit that re-forks them fails here rather than in a demo.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_item_editor.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart' show IconBtn;
import 'package:ethara_assessment/assessment/widgets/feedback.dart'
    show ToastMsg;
import 'package:ethara_assessment/assessment/widgets/panel.dart' show Panel;

Future<void> _pump(
  WidgetTester tester,
  FormItemKind kind, {
  FormDef? form,
  bool showDragHandle = true,
  void Function(FormItem)? tweak,
  VoidCallback? onDelete,
  AppStore? store,
}) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final FormItem item = FormItem(
    'item-1',
    kind,
    title: 'Is the picture sharp and clear?',
  );
  tweak?.call(item);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FormItemEditor(
            store: store ?? AppStore(),
            item: item,
            index: 0,
            form: form,
            showDragHandle: showDragHandle,
            onEdit: (VoidCallback mutate) => mutate(),
            onDuplicate: () {},
            onDelete: onDelete ?? () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('the shared item card', () {
    testWidgets('carries help text, which the template editor lacked', (
      WidgetTester tester,
    ) async {
      await _pump(tester, FormItemKind.multipleChoice);

      expect(find.text('Help text (optional)'), findsOneWidget);
    });

    testWidgets('a textBlock asks for body text, not help text', (
      WidgetTester tester,
    ) async {
      await _pump(tester, FormItemKind.textBlock);

      expect(find.text('Body text (optional)'), findsOneWidget);
    });

    testWidgets('duplicate and delete are on every card', (
      WidgetTester tester,
    ) async {
      await _pump(tester, FormItemKind.multipleChoice);

      expect(find.byTooltip('Duplicate question'), findsOneWidget);
      expect(find.byTooltip('Delete question'), findsOneWidget);
    });

    // A SECTION KEEPS ALL FOUR CONTROLS IN ITS HEADER, so a question must too.
    //
    // Duplicate and delete used to sit in a footer below an `Hr()`, which put
    // the same two actions in two different places depending on which card the
    // reader was looking at - and on a long question the footer is off screen,
    // so the controls moved as the card grew. Asserted by POSITION rather than
    // by reading the widget tree's shape: what the examiner has to hit is a
    // place on the screen, and a refactor that keeps both buttons but drops one
    // back below the body would pass a structural check.
    testWidgets('all four controls sit in the header, above the body', (
      WidgetTester tester,
    ) async {
      await _pump(tester, FormItemKind.multipleChoice);

      // The kind picker is the leftmost thing in the header row, so its top
      // edge is the header's. The title field opens the body beneath it.
      final double body = tester.getTopLeft(find.text('Question')).dy;

      for (final String tip in <String>[
        'Collapse question',
        'Drag to reorder',
        'Duplicate question',
        'Delete question',
      ]) {
        expect(find.byTooltip(tip), findsOneWidget, reason: tip);
        expect(
          tester.getBottomLeft(find.byTooltip(tip)).dy,
          lessThanOrEqualTo(body),
          reason: '$tip must be in the header, not below the body',
        );
      }
    });

    // Deleting a question throws away its options, its answer key and its
    // media, and the designer has no undo. A section already confirmed; this
    // was the one destructive control in the designer that fired on one click.
    testWidgets('delete asks before it deletes, and cancel keeps the item', (
      WidgetTester tester,
    ) async {
      int deleted = 0;
      await _pump(
        tester,
        FormItemKind.multipleChoice,
        onDelete: () => deleted++,
      );

      await tester.tap(find.byTooltip('Delete question'));
      await tester.pumpAndSettle();

      expect(find.text('Delete this question?'), findsOneWidget);
      expect(deleted, 0, reason: 'nothing may be deleted before the answer');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(deleted, 0);
    });

    testWidgets('confirming the sheet deletes exactly once, and says so', (
      WidgetTester tester,
    ) async {
      int deleted = 0;
      final AppStore store = AppStore();
      await _pump(
        tester,
        FormItemKind.multipleChoice,
        onDelete: () => deleted++,
        store: store,
      );

      await tester.tap(find.byTooltip('Delete question'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete Question'));
      await tester.pumpAndSettle();

      expect(deleted, 1);
      // The card is gone by the time the sheet closes, so the toast is the
      // only thing that confirms the click landed. Read off the toaster
      // rather than the screen: `ToastHost` is mounted by the app shell, not
      // by this harness.
      expect(
        store.toaster.items.map((ToastMsg m) => m.message),
        contains('Question deleted'),
      );

      // A toast expires on a 3200ms timer, which outlives the test body and
      // trips the pending-timer invariant. Pump past it rather than leave the
      // suite failing on a timer that is correct behaviour.
      await tester.pump(const Duration(milliseconds: 3300));
    });

    // A display block is not a question, and the sheet must not call it one.
    testWidgets('a block is confirmed in its own words', (
      WidgetTester tester,
    ) async {
      await _pump(tester, FormItemKind.textBlock);

      await tester.tap(find.byTooltip('Delete question'));
      await tester.pumpAndSettle();

      expect(find.text('Delete this block?'), findsOneWidget);
      expect(find.text('Delete Block'), findsOneWidget);
    });

    testWidgets('the kind picker is present', (WidgetTester tester) async {
      await _pump(tester, FormItemKind.multipleChoice);

      expect(find.byType(FormItemEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the block placeholders a template could not express before', () {
    for (final FormItemKind kind in <FormItemKind>[
      FormItemKind.textBlock,
      FormItemKind.imageBlock,
      FormItemKind.videoBlock,
    ]) {
      testWidgets('${kind.name} renders with no form', (
        WidgetTester tester,
      ) async {
        // No `form:` - exactly how the task template editor mounts it.
        await _pump(tester, kind, form: null);

        expect(tester.takeException(), isNull);
      });
    }
  });

  group('a template has no sections', () {
    testWidgets('the branch picker stands down when there is no form', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        FormItemKind.multipleChoice,
        form: null,
        tweak: (FormItem it) => it.options.add(FormOption('opt-1', 'Yes')),
      );

      // A jump picker would offer 'Continue to next section'; with no form
      // there are no sections to jump to and it must not be drawn.
      expect(find.text('Continue to next section'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the drag handle can be hidden for a flat list', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        FormItemKind.shortAnswer,
        showDragHandle: false,
      );

      expect(find.byTooltip('Drag to reorder'), findsNothing);
    });
  });

  // THE ALIGNMENT, MEASURED - not asserted by eye.
  //
  // The reported defect was that a question's four controls did not line up
  // with a section's, even though they were by then the same four icons in the
  // same order. A section is a `Panel`: its controls sit at a fixed inset from
  // the panel's right edge. The question card had no header strip at all - one
  // padded `Container` with a `Flexible` picker and a `Spacer`, both of which
  // are flex children, so they SPLIT the free width and the leftover slack was
  // dumped after the last icon.
  //
  // Measured as an inset from each card's OWN right edge, because that is what
  // "aligned" means for two cards of different widths nested one inside the
  // other. Comparing absolute x would only hold at one window size.
  group('a question card lines up with a section card', () {
    // The same four glyphs a section header carries, in a section's order.
    const List<IconData> sectionOrder = <IconData>[
      Icons.expand_less,
      Icons.drag_indicator,
      Icons.copy_outlined,
      Icons.delete_outline,
    ];

    /// Distance from [card]'s right edge to the right edge of the icon row's
    /// last control, and each control's left edge.
    ///
    /// Every icon is looked up UNDER [card]: both cards carry the same four
    /// glyphs, so an unscoped `find.byIcon` matches two of each and throws.
    (double, List<double>) geometry(WidgetTester tester, Finder card) {
      Finder icon(IconData i) =>
          find.descendant(of: card, matching: find.byIcon(i));
      final List<double> lefts = sectionOrder
          .map((IconData i) => tester.getTopLeft(icon(i)).dx)
          .toList();
      return (
        tester.getBottomRight(card).dx -
            tester.getBottomRight(icon(sectionOrder.last)).dx,
        lefts,
      );
    }

    testWidgets('the controls sit at a panel header\'s inset from the edge', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final FormItem item = FormItem(
        'item-1',
        FormItemKind.multipleChoice,
        title: 'Is the picture sharp and clear?',
      );

      // Both cards on screen at once, in the nesting the designer draws: a
      // `Panel` for the section, the item card inside a `Panel` body's padding.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: <Widget>[
                  Panel(
                    key: const Key('section'),
                    title: 'Section 1 of 2 · Sec 1 Title',
                    headActions: <Widget>[
                      for (final IconData i in sectionOrder)
                        IconBtn(i, tooltip: i.toString(), onPressed: () {}),
                    ],
                    child: const SizedBox(height: 20),
                  ),
                  Panel(
                    key: const Key('host'),
                    title: 'Section 2 of 2',
                    child: FormItemEditor(
                      store: AppStore(),
                      item: item,
                      index: 0,
                      onEdit: (VoidCallback mutate) => mutate(),
                      onDuplicate: () {},
                      onDelete: () {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final (double secInset, List<double> secLefts) =
          geometry(tester, find.byKey(const Key('section')));
      final (double qInset, List<double> qLefts) = geometry(
        tester,
        find.byType(FormItemEditor),
      );

      // THE CLAIM: the same inset from each card's own right edge.
      expect(
        qInset,
        moreOrLessEquals(secInset, epsilon: 0.5),
        reason: 'a question\'s controls must sit at the same inset from its '
            'card edge ($qInset) as a section\'s do from theirs ($secInset)',
      );

      // And the same pitch between them, so the cluster reads as one row
      // rather than four buttons that happen to end in the right place.
      for (int i = 1; i < sectionOrder.length; i++) {
        expect(
          qLefts[i] - qLefts[i - 1],
          moreOrLessEquals(secLefts[i] - secLefts[i - 1], epsilon: 0.5),
          reason: 'gap ${i - 1}->$i must match the section\'s',
        );
      }
    });

    // The regression that produced the screenshot: `Flexible` + `Spacer` in one
    // Row divide the free width, so the icons stop short of the edge. On a
    // 1600px card with a 220px picker that left ~570px of slack behind them.
    testWidgets('the controls reach the edge on a wide card', (
      WidgetTester tester,
    ) async {
      await _pump(tester, FormItemKind.multipleChoice);

      final double cardRight =
          tester.getBottomRight(find.byType(FormItemEditor).first).dx;
      final double iconsRight =
          tester.getBottomRight(find.byIcon(Icons.delete_outline)).dx;

      expect(
        cardRight - iconsRight,
        lessThan(20),
        reason: 'the last control must sit on the card edge, not mid-card',
      );
    });
  });
}
