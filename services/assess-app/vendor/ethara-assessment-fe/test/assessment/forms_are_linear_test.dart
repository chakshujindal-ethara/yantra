// A SECTION HAS NO DESTINATION OF ITS OWN.
//
// The designer used to draw an "After section N" picker per section, offering
// "Continue to next section" / "Submit form". It was misleading in both
// directions:
//
//   * Nothing downstream read it. The module has no `go_to` anywhere, and the
//     real exam runner (exam_screen.dart) paginates per QUESTION and decides
//     the last page by counting - `number >= total ? 'Review & Submit' :
//     'Next'`. So the setting only ever steered the admin preview.
//   * Left on "Submit form", a NON-FINAL section ended the preview early, which
//     reads as the form being broken. That is the reported defect.
//
// The candidate's flow is: Next through every question, Submit at the end. So
// the field is gone from the model, not just hidden - a stored "@submit" would
// otherwise keep truncating a form with no control left anywhere to repair it.
//
// Per-ANSWER branching (an option with its own destination) is untouched and is
// asserted here too, since removing one and breaking the other would be a poor
// trade.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_preview.dart';

FormSection _sec(String id, String title, List<FormItem> items) =>
    FormSection(id, title: title, items: items);

FormItem _q(String id, String title) =>
    FormItem(id, FormItemKind.shortAnswer, title: title, required: false);

FormDef _threeSections() => FormDef(
  'form-1',
  title: 'Linear',
  sections: <FormSection>[
    _sec('sec-1', 'One', <FormItem>[_q('i1', 'Q one')]),
    _sec('sec-2', 'Two', <FormItem>[_q('i2', 'Q two')]),
    _sec('sec-3', 'Three', <FormItem>[_q('i3', 'Q three')]),
  ],
);

Future<void> _pump(WidgetTester tester, FormDef form) async {
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

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// A question's title is rendered inside a `Text.rich` that PREFIXES the
/// candidate-facing number ("Question 2. Q two"), so an exact-text finder never
/// matches it. Substring matching is what identifies which page is on screen.
Finder _question(String title) => find.textContaining(title);

void main() {
  group('a section carries no destination', () {
    test('the model has no goTo to set', () {
      // A compile-time guarantee really, but stated so a re-added field has to
      // pass through this file: the JSON a section writes carries exactly its
      // identity, prose and items - no routing key.
      final Map<String, dynamic> j = _sec('sec-1', 'One', <FormItem>[
        _q('i1', 'Q one'),
      ]).toJson();
      expect(j.keys.toSet(), <String>{'id', 'title', 'description', 'items'});
    });

    test('a stored go_to from the old picker is IGNORED, not honoured', () {
      // The migration decision. Forms saved while the picker existed may carry
      // `go_to: "@submit"` on a non-final section; reading it back would cut
      // those forms short with nothing in the UI to explain or fix it.
      final FormSection back = FormSection.fromJson(<String, dynamic>{
        'id': 'sec-1',
        'title': 'One',
        'go_to': '@submit',
        'items': <dynamic>[],
      });
      expect(back.toJson().containsKey('go_to'), isFalse);
    });
  });

  group('the preview walks every section in order', () {
    testWidgets('Next on a middle section, Submit only on the last', (
      WidgetTester tester,
    ) async {
      await _pump(tester, _threeSections());

      // Section 1 of 3: Next, not Submit.
      expect(_question('Q one'), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);
      expect(find.text('Submit'), findsNothing);

      await _tap(tester, 'Next');
      expect(_question('Q two'), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);
      expect(
        find.text('Submit'),
        findsNothing,
        reason: 'section 2 of 3 is not the end of the form',
      );

      await _tap(tester, 'Next');
      expect(_question('Q three'), findsOneWidget);
      expect(
        find.text('Submit'),
        findsOneWidget,
        reason: 'the last section is where the form ends',
      );
      expect(find.text('Next'), findsNothing);
    });

    testWidgets('a form whose sections carried "@submit" no longer ends early', (
      WidgetTester tester,
    ) async {
      // Round-tripped through JSON on purpose: this is exactly how a form saved
      // by the old designer arrives, and the bug was that it stopped at
      // section 1 of 3.
      final Map<String, dynamic> raw = _threeSections().toJson();
      for (final Object? s in raw['sections'] as List<dynamic>) {
        (s as Map<String, dynamic>)['go_to'] = '@submit';
      }
      await _pump(tester, FormDef.fromJson(raw));

      expect(find.text('Next'), findsOneWidget);
      expect(find.text('Submit'), findsNothing);
      await _tap(tester, 'Next');
      expect(
        _question('Q two'),
        findsOneWidget,
        reason: 'a stale "@submit" must not end the form on section 1',
      );
    });
  });

  group('per-ANSWER branching is gone too', () {
    // THIS FILE PREVIOUSLY ASSERTED THE OPPOSITE. When only the section-level
    // picker was removed, option-level branching was kept and pinned here as
    // "still works". It is now removed as well, for the reason that always
    // applied to both: NOTHING DOWNSTREAM READS IT. The module has no `go_to`,
    // and the candidate's exam runner paginates one question at a time with no
    // concept of a section - so a routed form was honoured in the examiner's
    // preview and nowhere else, which is worse than not offering it.
    test('an option cannot carry a destination at all', () {
      final Map<String, dynamic> j = FormOption('o1', 'Yes').toJson();
      expect(j.keys.toSet(), <String>{'id', 'label'});
    });

    test('a stored option go_to is IGNORED on read', () {
      final FormOption back = FormOption.fromJson(<String, dynamic>{
        'id': 'o1',
        'label': 'Yes, skip ahead',
        'go_to': 'sec-3',
        'correct': true,
      });
      // The key survives; the routing does not.
      expect(back.correct, isTrue);
      expect(back.toJson().containsKey('go_to'), isFalse);
    });

    testWidgets('a form authored with option jumps now runs straight through', (
      WidgetTester tester,
    ) async {
      // The exact fixture this file used to prove branching WITH: picking "Yes"
      // jumped from section 1 to section 3. It must now walk 1 → 2 → 3.
      final Map<String, dynamic> raw = <String, dynamic>{
        'id': 'form-2',
        'title': 'Was branching',
        'sections': <dynamic>[
          <String, dynamic>{
            'id': 'sec-1',
            'title': 'Triage',
            'items': <dynamic>[
              <String, dynamic>{
                'id': 'i1',
                'kind': 'multipleChoice',
                'title': 'All good?',
                'options': <dynamic>[
                  <String, dynamic>{
                    'id': 'o1',
                    'label': 'Yes, skip ahead',
                    'go_to': 'sec-3',
                  },
                  <String, dynamic>{'id': 'o2', 'label': 'No, tell me more'},
                ],
              },
            ],
          },
          <String, dynamic>{
            'id': 'sec-2',
            'title': 'Detail',
            'items': <dynamic>[
              <String, dynamic>{
                'id': 'i2',
                'kind': 'shortAnswer',
                'title': 'What went wrong?',
              },
            ],
          },
          <String, dynamic>{
            'id': 'sec-3',
            'title': 'Done',
            'items': <dynamic>[
              <String, dynamic>{
                'id': 'i3',
                'kind': 'shortAnswer',
                'title': 'Anything else?',
              },
            ],
          },
        ],
      };
      await _pump(tester, FormDef.fromJson(raw));

      await _tap(tester, 'Yes, skip ahead');
      await _tap(tester, 'Next');
      expect(
        _question('What went wrong?'),
        findsOneWidget,
        reason: 'the stale jump must not skip section 2 any more',
      );
      await _tap(tester, 'Next');
      expect(_question('Anything else?'), findsOneWidget);
      expect(find.text('Submit'), findsOneWidget);
    });
  });

  group('the retired kinds degrade to something markable', () {
    test('date, time and fileUpload read back as short answer', () {
      // None of the three was gradeable: an upload has no question-type mapping
      // at all, and a date or time is one literal with no key and no rubric - so
      // an examiner could publish one and the answer would count for nothing.
      // Reading them as shortAnswer keeps the question text, help, required flag
      // and position; only the unscoreable control goes.
      for (final String wire in <String>['date', 'time', 'fileUpload']) {
        expect(
          FormItemKindX.parse(wire),
          FormItemKind.shortAnswer,
          reason: '$wire must degrade, not vanish',
        );
      }
    });

    test('a live item using one keeps its wording', () {
      // Form 12's real shape - two of these were in use when the kinds went.
      final FormItem back = FormItem.fromJson(<String, dynamic>{
        'id': 'i9',
        'kind': 'date',
        'title': 'On what date did the refund policy change?',
        'required': true,
      });
      expect(back.kind, FormItemKind.shortAnswer);
      expect(back.title, 'On what date did the refund policy change?');
      expect(back.required, isTrue);
    });
  });

  group('a question carries no shuffle of its own', () {
    test('the per-question shuffle flag is gone from the wire', () {
      final Map<String, dynamic> j = FormItem(
        'i1',
        FormItemKind.multipleChoice,
        title: 'Pick one',
        options: <FormOption>[FormOption('o1', 'A'), FormOption('o2', 'B')],
      ).toJson();
      expect(j.containsKey('shuffle'), isFalse);
      // The FORM-wide flag is the survivor and is a different key.
      expect(
        FormDef('f', shuffleQuestions: true).toJson()['shuffle_questions'],
        isTrue,
      );
    });

    test('a stored per-question shuffle is ignored', () {
      final FormItem back = FormItem.fromJson(<String, dynamic>{
        'id': 'i1',
        'kind': 'multipleChoice',
        'title': 'Pick one',
        'shuffle': true,
        'options': <dynamic>[
          <String, dynamic>{'id': 'o1', 'label': 'A'},
        ],
      });
      expect(back.toJson().containsKey('shuffle'), isFalse);
    });
  });
}
