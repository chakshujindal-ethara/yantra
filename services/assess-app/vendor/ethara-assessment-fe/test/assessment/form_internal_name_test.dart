// AN INTERNAL NAME THAT DOES NOT MOVE THE RESPONDENT'S HEADING.
//
// `FormDef.title` is candidate-facing copy - the heading above the first
// question, rendered by `form_preview._formHeader`. `FormDef.internalName` is
// what an operator calls the same form in a list of two hundred rows, and
// publishing names the assessment and the question pool from it
// (`studio_form.display_title`). One form, two audiences, two strings.
//
// WHAT THESE TESTS ARE REALLY FOR:
//
//  * THE FALLBACK IS ONE EXPRESSION. Ten admin call sites used to retype
//    `title.isEmpty ? 'Untitled form' : title`, in two different casings.
//    [FormDef.displayTitle] replaced all of them, so its three branches -
//    override, title, neither - are pinned here rather than at each screen.
//
//  * THE KEY SURVIVES BOTH DIRECTIONS. A key that `toJson` writes and
//    `fromJson` does not read (or the reverse) is lost silently, and the loss
//    only shows up where a form is duplicated or exported - both of which are
//    JSON round trips. So the round trip is asserted directly.
//
//  * AN OVERRIDE NEVER TOUCHES `title`. The whole point of the second field is
//    that the candidate's heading stays put, so that is asserted as its own
//    case: if it ever fails, this became a rename instead of an alias.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/form_models.dart';

FormDef _form({String title = 'Quality Assessment', String internal = ''}) =>
    FormDef(
      'form-1',
      title: title,
      internalName: internal,
      sections: <FormSection>[
        FormSection(
          'sec-1',
          title: 'S1',
          items: <FormItem>[
            FormItem(
              'item-1',
              FormItemKind.multipleChoice,
              title: 'Pick one',
              options: <FormOption>[
                FormOption('opt-1', 'A', correct: true),
                FormOption('opt-2', 'B'),
              ],
            ),
          ],
        ),
      ],
    );

void main() {
  group('displayTitle resolves the operator-facing name', () {
    test('with no override it is the respondent title', () {
      expect(_form().displayTitle, 'Quality Assessment');
    });

    test('an override wins', () {
      final FormDef f = _form(internal: 'Q7r cohort 3 - retake');
      expect(f.displayTitle, 'Q7r cohort 3 - retake');
    });

    test('an override does NOT move the respondent heading', () {
      final FormDef f = _form(internal: 'Q7r cohort 3 - retake');
      expect(
        f.title,
        'Quality Assessment',
        reason: 'the internal name is a second label, not a rename - a '
            'candidate must keep reading the heading that was authored for '
            'them',
      );
    });

    test('with neither, one fallback string in one casing', () {
      expect(
        _form(title: '').displayTitle,
        'Untitled form',
        reason: "'Untitled Form' was the designer's casing and 'Untitled "
            'form\' the list\'s; the same form read two ways in one session',
      );
    });

    test('a blank override falls through rather than showing empty', () {
      expect(_form(internal: '').displayTitle, 'Quality Assessment');
    });
  });

  group('the internal name survives a JSON round trip', () {
    test('toJson writes it and fromJson reads it back', () {
      final FormDef out = _form(internal: 'Q7r cohort 3 - retake');
      final FormDef back =
          FormDef.fromJson(jsonDecode(jsonEncode(out.toJson())));

      expect(back.internalName, 'Q7r cohort 3 - retake');
      expect(back.title, 'Quality Assessment');
      expect(back.displayTitle, out.displayTitle);
    });

    test('the key is emitted even when empty, so a clear can be saved', () {
      // `/forms/save` is an upsert on the whole form. If an empty override were
      // omitted, the server could not tell "never set" from "just cleared" and
      // the old name would outlive the operator deleting it.
      expect(_form().toJson().containsKey('internal_name'), isTrue);
      expect(_form().toJson()['internal_name'], '');
    });

    test('an exported form imports with its internal name intact', () {
      final FormDef out = _form(internal: 'Q7r cohort 3 - retake');
      final FormDef back =
          formFromImportedJson(jsonDecode(jsonEncode(out.toJson())));

      expect(back.internalName, 'Q7r cohort 3 - retake');
      expect(back.title, 'Quality Assessment');
      expect(back.id, isNot(out.id), reason: 'an import is still a new form');
    });

    test('a whitespace-only override imports as not overridden', () {
      final FormDef back = formFromImportedJson(<String, dynamic>{
        ...(_form().toJson()),
        'internal_name': '   ',
      });
      expect(back.internalName, isEmpty);
      expect(back.displayTitle, 'Quality Assessment');
    });
  });

  group('duplicating a form does not duplicate its operator-facing name', () {
    test('a re-mint that renames drops the override', () {
      // What `AppStore.duplicateForm` does. Carrying "Q7r cohort 3 - retake"
      // onto the copy would give two rows reading identically in every admin
      // list, and the copy is the row the operator went looking for.
      final FormDef src = _form(internal: 'Q7r cohort 3 - retake');
      final FormDef copy = formReminted(src, title: '${src.title} (copy)');

      expect(copy.internalName, isEmpty);
      expect(copy.displayTitle, 'Quality Assessment (copy)');
      expect(
        src.internalName,
        'Q7r cohort 3 - retake',
        reason: 'the source must be untouched by a copy',
      );
    });

    test('a re-mint that does not rename keeps the override', () {
      final FormDef src = _form(internal: 'Q7r cohort 3 - retake');
      final FormDef same = formReminted(src);
      expect(same.internalName, 'Q7r cohort 3 - retake');
    });

    test('an explicit internal name wins over the rename rule', () {
      final FormDef copy = formReminted(
        _form(internal: 'Q7r cohort 3'),
        title: 'Quality Assessment (copy)',
        internalName: 'Q7r cohort 4',
      );
      expect(copy.displayTitle, 'Q7r cohort 4');
    });
  });
}
