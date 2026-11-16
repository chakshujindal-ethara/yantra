// THE DEFECT THIS PINS. Every objective item kind had a way to author its
// answer key EXCEPT `rating` and `linearScale`: multiple choice/checkboxes/
// dropdown mark a correct option, grids fill an "Answer Key" column, image
// annotation fills a golden label per marker, short answer/paragraph get a
// "Golden answer" text field - but the rating and linear-scale editors drew
// only the respondent-facing control (stars / a min-max slider row) with
// nowhere to say what a perfect answer IS. An examiner opening either kind
// in Form Studio could not fill in a golden answer at all.
//
// Fixed by giving both kinds their own key field on FormItem
// (`ratingGolden` / `scaleGolden`), a picker in their editors, and a seed
// case in the preview - the same three places every other kind already had.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_item_editor.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_preview.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

void main() {
  group('rating golden answer', () {
    test('is nullable, stored, and round-trips through JSON', () {
      final FormItem it = FormItem(
        'item-1',
        FormItemKind.rating,
        ratingMax: 5,
      );
      expect(it.ratingGolden, isNull, reason: 'no key authored yet');

      it.ratingGolden = 4;
      final FormItem back = FormItem.fromJson(it.toJson());
      expect(back.ratingGolden, 4);
    });

    test('an unset key is omitted from the wire payload', () {
      final FormItem it = FormItem('item-1', FormItemKind.rating);
      expect(it.toJson().containsKey('rating_golden'), isFalse);
    });

    testWidgets('the editor offers a control to set it', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final FormItem item = FormItem(
        'item-1',
        FormItemKind.rating,
        title: 'Rate the response',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: FormItemEditor(
                store: AppStore(),
                item: item,
                index: 0,
                showDragHandle: true,
                onEdit: (VoidCallback mutate) => mutate(),
                onDuplicate: () {},
                onDelete: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Before the fix, nothing on this card could set a golden answer and no
      // such message appeared at all.
      //
      // THE WORDING CHANGED WITH THE RULE. It used to read "No golden answer
      // set - this item cannot be auto-scored", which described an acceptable
      // resting state; publishing now REFUSES a rating with no key, so the line
      // says the key is required instead. What this test is really about - that
      // the card offers a way to set the key, and a star-tap sets it - is
      // unchanged and asserted below.
      // Matched on the golden-answer sentence, not the bare word "Required" -
      // the card's own footer carries a "Required" toggle for the QUESTION,
      // which is a different setting entirely.
      expect(
        find.textContaining('Tap a star to set the golden answer'),
        findsOneWidget,
        reason: 'an unkeyed rating must say the key is required',
      );

      // Tapping the 4th star sets the key to 4, same as clicking a rating
      // star anywhere else in the app.
      await tester.tap(find.byIcon(Icons.star_border).at(3));
      await tester.pump();

      expect(item.ratingGolden, 4);
      expect(find.textContaining('Golden answer: 4 stars'), findsOneWidget);
    });
  });

  group('linear scale golden answer', () {
    test('is nullable, stored, and round-trips through JSON', () {
      final FormItem it = FormItem(
        'item-1',
        FormItemKind.linearScale,
        scaleMin: 1,
        scaleMax: 5,
      );
      expect(it.scaleGolden, isNull);

      it.scaleGolden = 3;
      final FormItem back = FormItem.fromJson(it.toJson());
      expect(back.scaleGolden, 3);
    });

    testWidgets('the editor offers a picker to set it', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final FormItem item = FormItem(
        'item-1',
        FormItemKind.linearScale,
        title: 'How confident are you?',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: FormItemEditor(
                store: AppStore(),
                item: item,
                index: 0,
                showDragHandle: true,
                onEdit: (VoidCallback mutate) => mutate(),
                onDuplicate: () {},
                onDelete: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text('GOLDEN ANSWER (FOR AUTO-SCORING)'),
        findsOneWidget,
      );

      await tester.tap(find.byType(DropdownButton<int?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3').last);
      await tester.pumpAndSettle();

      expect(item.scaleGolden, 3);
    });
  });

  group('the preview seeds from the new keys', () {
    testWidgets('rating pre-fills to the golden star count', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final FormDef form = FormDef(
        'form-1',
        sections: <FormSection>[
          FormSection(
            'sec-1',
            items: <FormItem>[
              FormItem(
                'item-1',
                FormItemKind.rating,
                title: 'Rate it',
                ratingMax: 5,
                ratingGolden: 4,
              ),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: FormPreview(form: form, showKeys: true),
            ),
          ),
        ),
      );
      await tester.pump();

      // 4 of 5 stars filled - the preview opened as the perfect submission,
      // same guarantee every other kind already gets from showKeys.
      expect(find.byIcon(Icons.star), findsNWidgets(4));
      expect(find.byIcon(Icons.star_border), findsNWidgets(1));
    });
  });

  group('the key reaches the field the SERVER reads', () {
    // THE DEFECT THIS PINS. `studio_form._item_spec` reads every kind's key
    // from `golden_answer`, and for a scale or rating it demands a digit
    // string in range:
    //
    //     if not golden.isdigit() or not mn <= int(golden) <= mx:
    //         problems.append("set the correct value (%s-%s) ...")
    //
    // The typed keys are right for the editor, but a key that lived ONLY in
    // `rating_golden` was invisible to the server - so publishing a form with
    // a rating question was refused with "set the correct value as the golden
    // answer" no matter how carefully the examiner had set it.
    test('a rating key is published as a digit string', () {
      final FormItem it = FormItem('i', FormItemKind.rating, ratingMax: 5)
        ..ratingGolden = 4;
      final Map<String, dynamic> wire = it.toJson();
      expect(wire['golden_answer'], '4');
      // The typed key stays too, for the editor's own round trip.
      expect(wire['rating_golden'], 4);
    });

    test('a linear scale key is published as a digit string', () {
      final FormItem it = FormItem(
        'i',
        FormItemKind.linearScale,
        scaleMin: 1,
        scaleMax: 5,
      )..scaleGolden = 3;
      expect(it.toJson()['golden_answer'], '3');
    });

    test('no key means no golden_answer at all, not an empty one', () {
      // An empty string would fail the server's `isdigit()` check and read as
      // a key that was set to nothing.
      expect(
        FormItem('i', FormItemKind.rating)
            .toJson()
            .containsKey('golden_answer'),
        isFalse,
      );
    });

    test('a key the server sent back is read without the typed field', () {
      // The server only ever speaks `golden_answer`, so a form loaded from it
      // must still show its key in the picker.
      final FormItem back = FormItem.fromJson(<String, dynamic>{
        'id': 'i',
        'kind': 'rating',
        'rating_max': 5,
        'golden_answer': '4',
      });
      expect(back.ratingGolden, 4);
    });

    test('a text golden answer is untouched by any of this', () {
      final FormItem it = FormItem('i', FormItemKind.paragraph)
        ..goldenAnswer = 'What a perfect answer states.';
      expect(it.toJson()['golden_answer'], 'What a perfect answer states.');
    });
  });
}
