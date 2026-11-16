// FORM-WIDE question shuffle.
//
// The designer's "Shuffle question order" toggle lives on the FORM, not a
// question. When on, each candidate is served the questions in a random order
// that is fixed for their sitting, but the NUMBER they read still counts
// 1..N in the order they actually see - "Question 3" is their third question,
// not the third one the author typed.
//
// These pin two things a demo cannot eyeball reliably (a shuffle might land on
// the authored order by chance): the flag survives a JSON round-trip, and the
// preview always numbers questions 1..N with no gaps or repeats regardless of
// the order they render in.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_preview.dart';

FormDef _formWith(int questions, {required bool shuffle}) => FormDef(
  'form-1',
  title: 'Ordering',
  shuffleQuestions: shuffle,
  sections: <FormSection>[
    FormSection(
      'sec-1',
      title: 'Only section',
      items: <FormItem>[
        for (int i = 0; i < questions; i++)
          FormItem('item-$i', FormItemKind.shortAnswer, title: 'Q$i'),
      ],
    ),
  ],
);

void main() {
  group('the shuffle_questions flag', () {
    test('survives a JSON round-trip', () {
      final FormDef on = _formWith(3, shuffle: true);
      final FormDef back = FormDef.fromJson(on.toJson());
      expect(back.shuffleQuestions, isTrue);

      // Off is the default and is written sparsely (absent key), which must
      // still read back as false.
      final FormDef off = _formWith(3, shuffle: false);
      expect(off.toJson().containsKey('shuffle_questions'), isFalse);
      expect(FormDef.fromJson(off.toJson()).shuffleQuestions, isFalse);
    });
  });

  group('the preview numbers questions in display order', () {
    Future<void> pump(WidgetTester tester, FormDef form) async {
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

    testWidgets('every question reads 1..N once, shuffle OFF', (
      WidgetTester tester,
    ) async {
      await pump(tester, _formWith(4, shuffle: false));
      // 1..4 present, no "Question 5".
      for (int n = 1; n <= 4; n++) {
        expect(
          find.textContaining('Question $n.'),
          findsOneWidget,
          reason: 'Question $n should appear exactly once',
        );
      }
      expect(find.textContaining('Question 5.'), findsNothing);
    });

    testWidgets('every question reads 1..N once, shuffle ON', (
      WidgetTester tester,
    ) async {
      // The point of the feature: whatever random order the four questions
      // land in, the visible numbers are still exactly 1, 2, 3, 4 - one each.
      await pump(tester, _formWith(4, shuffle: true));
      for (int n = 1; n <= 4; n++) {
        expect(
          find.textContaining('Question $n.'),
          findsOneWidget,
          reason: 'Question $n should appear exactly once even when shuffled',
        );
      }
      expect(find.textContaining('Question 5.'), findsNothing);
    });
  });

  // The ASSESSMENT-level shuffle, distinct from the FormDef one above. Same
  // idea, different model: it is the positive of the module's
  // `preserve_question_order`, and this app never holds the negative.
  group('Assessment.shuffleQuestions', () {
    Assessment asm() => Assessment(id: 'A-1', name: 'Warehouse Safety');

    test('defaults to true - a fresh assessment shuffles', () {
      expect(
        asm().shuffleQuestions,
        isTrue,
        reason: 'same questions in a fixed order is a side-by-side leak; the '
            'default closes it',
      );
    });

    test('the toggle flips through copyWith and holds', () {
      final Assessment off = asm().copyWith(shuffleQuestions: false);
      expect(off.shuffleQuestions, isFalse);
      // And back on.
      final Assessment on = off.copyWith(shuffleQuestions: true);
      expect(on.shuffleQuestions, isTrue);
    });

    test('survives a JSON round-trip in both positions', () {
      for (final bool v in <bool>[true, false]) {
        final Assessment back = Assessment.fromJson(
          asm().copyWith(shuffleQuestions: v).toJson(),
        );
        expect(back.shuffleQuestions, v);
      }
    });

    test('a payload that predates the field reads as true', () {
      // The one thing the shuffle exists to prevent is the authored order, so
      // an absent key must not silently mean "keep it".
      final Assessment back = Assessment.fromJson(<String, dynamic>{
        'id': 'A-9',
        'name': 'Legacy',
      });
      expect(back.shuffleQuestions, isTrue);
    });

    test('the wire spelling is snake_case, read via jget', () {
      // The server sends `shuffle_questions`; the parser must accept it.
      final Assessment back = Assessment.fromJson(<String, dynamic>{
        'id': 'A-2',
        'name': 'Snake',
        'shuffle_questions': false,
      });
      expect(back.shuffleQuestions, isFalse);
    });
  });
}
