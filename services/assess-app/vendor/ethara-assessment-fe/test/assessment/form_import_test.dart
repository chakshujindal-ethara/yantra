// IMPORTING A WHOLE FORM FROM JSON.
//
// The document is the shape `FormDef.toJson` writes, so a form exported from
// Form Studio re-imports, and a bare `sections` array is accepted too because
// that is the half people actually paste.
//
// WHAT THESE TESTS ARE REALLY FOR:
//
//  * EVERY ID IS RE-MINTED. Item ids are not decoration - the designer keys its
//    text fields by item id, so two items sharing one make Flutter share their
//    edit state and typing in one shows up in the other. They also reach the
//    server, where publish stamps `source_ref = "form:<uid>#<item_id>"`, so
//    duplicates make a published question untraceable. Importing the same file
//    twice is the case that guarantees a collision, so it is the case tested.
//
//  * A REFUSAL SAYS WHY. An import that quietly produced an empty form is
//    indistinguishable from the feature being broken, so every rejection names
//    what was expected.
//
//  * `published` IS NEVER HONOURED. Publishing puts questions into the exam
//    pipeline; that is a decision, not a file attribute.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/services/json_export.dart';

Map<String, dynamic> _doc({
  String title = 'Onboarding',
  bool published = false,
}) => <String, dynamic>{
  'id': 'form-from-the-file',
  'title': title,
  'published': published,
  'sections': <dynamic>[
    <String, dynamic>{
      'id': 'sec-from-the-file',
      'title': 'S1',
      'items': <dynamic>[
        <String, dynamic>{
          'id': 'item-from-the-file',
          'kind': 'multipleChoice',
          'title': 'Pick one',
          'required': true,
          'options': <dynamic>[
            <String, dynamic>{
              'id': 'opt-from-the-file',
              'label': 'A',
              'correct': true,
            },
            <String, dynamic>{'id': 'opt-2-from-the-file', 'label': 'B'},
          ],
        },
      ],
    },
  ],
};

Iterable<String> _allIds(FormDef f) => <String>[
  f.id,
  for (final FormSection s in f.sections) ...<String>[
    s.id,
    for (final FormItem i in s.items) ...<String>[
      i.id,
      for (final FormOption o in i.options) o.id,
    ],
  ],
];

void main() {
  group('a well-formed document imports', () {
    test('the content survives', () {
      final FormDef f = formFromImportedJson(_doc());
      expect(f.title, 'Onboarding');
      expect(f.sections, hasLength(1));
      expect(f.sections.single.items, hasLength(1));

      final FormItem item = f.sections.single.items.single;
      expect(item.kind, FormItemKind.multipleChoice);
      expect(item.title, 'Pick one');
      expect(item.required, isTrue);
      expect(item.options.map((FormOption o) => o.label), <String>['A', 'B']);
      expect(
        item.options.where((FormOption o) => o.correct).single.label,
        'A',
        reason: 'the answer key is part of the form',
      );
    });

    test('a bare sections array is accepted', () {
      final FormDef f = formFromImportedJson(_doc()['sections']);
      expect(f.sections, hasLength(1));
      expect(f.sections.single.items, hasLength(1));
    });

    test('the filename titles a document that carries none', () {
      final Map<String, dynamic> d = _doc()..remove('title');
      final FormDef f =
          formFromImportedJson(d, fallbackTitle: 'onboarding-quiz');
      expect(f.title, 'onboarding-quiz');
    });

    test('a form studio export round-trips', () {
      final FormDef original = formFromImportedJson(_doc());
      final FormDef back = formFromImportedJson(original.toJson());
      expect(back.questionCount, original.questionCount);
      expect(back.sections.single.items.single.title, 'Pick one');
    });
  });

  group('ids are re-minted, so importing twice cannot collide', () {
    test('no id from the file survives', () {
      final FormDef f = formFromImportedJson(_doc());
      for (final String id in _allIds(f)) {
        expect(
          id,
          isNot(contains('from-the-file')),
          reason: 'a kept id could overwrite an existing form or share edit '
              'state with another item',
        );
      }
    });

    test('two imports of the same file share NO ids', () {
      final FormDef a = formFromImportedJson(_doc());
      final FormDef b = formFromImportedJson(_doc());
      final Set<String> overlap =
          _allIds(a).toSet().intersection(_allIds(b).toSet());
      expect(overlap, isEmpty, reason: 'the two forms must be independent');
    });
  });

  group('an import is always a draft', () {
    test('published: true in the file is ignored', () {
      final FormDef f = formFromImportedJson(_doc(published: true));
      expect(
        f.published,
        isFalse,
        reason: 'publishing reaches candidates; it is not a file attribute',
      );
    });
  });

  group('a bad document is refused, and says why', () {
    void refused(Object? input, String needle) {
      expect(
        () => formFromImportedJson(input),
        throwsA(
          isA<FormImportException>().having(
            (FormImportException e) => e.message,
            'message',
            contains(needle),
          ),
        ),
      );
    }

    test('not a form at all', () => refused('just a string', 'not a form'));
    test('a number', () => refused(42, 'not a form'));
    test('no sections key', () => refused(<String, dynamic>{'title': 'x'}, 'no "sections"'));
    test('sections is not a list',
        () => refused(<String, dynamic>{'sections': 'nope'}, 'no "sections"'));
    test('sections is empty',
        () => refused(<String, dynamic>{'sections': <dynamic>[]}, 'no sections'));
    test('sections holds no sections',
        () => refused(<String, dynamic>{'sections': <dynamic>[1, 2]},
            'does not contain any sections'));
  });

  group('the size cap mirrors the server', () {
    test('it matches studio_form.MAX_STRUCTURE_BYTES', () {
      expect(kMaxFormStructureBytes, 512 * 1024);
    });
  });

  // EXPORT IS THE OTHER HALF OF THE ROUND TRIP.
  //
  // Import could build a form from JSON, but nothing could produce that JSON -
  // so the only way to get a file was to write one by hand, and the feature
  // was half a loop. The Form Studio row now exports `FormDef.toJson()`, which
  // is exactly what this parser reads. These tests assert the loop closes on a
  // form using every shape a real one does, because an export that drops a
  // grid's rows or a scale's bounds still LOOKS like a valid file.
  group('an exported form imports back unchanged', () {
    FormDef built() {
      final FormDef f = formFromImportedJson(<String, dynamic>{
        'title': 'Every shape',
        'sections': <dynamic>[
          <String, dynamic>{
            'title': 'S1',
            'items': <dynamic>[
              <String, dynamic>{
                'kind': 'multipleChoice',
                'title': 'Pick one',
                'required': true,
                'options': <dynamic>[
                  <String, dynamic>{'label': 'A', 'correct': true},
                  <String, dynamic>{'label': 'B'},
                ],
              },
              <String, dynamic>{
                'kind': 'choiceGrid',
                'title': 'Rate each',
                'rows': <dynamic>['R1', 'R2'],
                'columns': <dynamic>['Pass', 'Fail'],
              },
              <String, dynamic>{
                'kind': 'linearScale',
                'title': 'How clear?',
                'scale_min': 1,
                'scale_max': 5,
                'scale_min_label': 'poor',
                'scale_max_label': 'great',
              },
              <String, dynamic>{
                'kind': 'paragraph',
                'title': 'Explain',
                'golden_answer': 'Mentions the tolerance.',
              },
            ],
          },
        ],
      });
      return f;
    }

    test('every shape survives export then import', () {
      final FormDef out = built();
      // The file the row writes, then read straight back by the Import button.
      final FormDef back =
          formFromImportedJson(jsonDecode(jsonEncode(out.toJson())));

      expect(back.title, out.title);
      expect(back.questionCount, out.questionCount);
      expect(back.sections.single.items, hasLength(4));

      final List<FormItem> a = out.sections.single.items;
      final List<FormItem> b = back.sections.single.items;
      for (int i = 0; i < a.length; i++) {
        expect(b[i].kind, a[i].kind, reason: 'kind of item $i');
        expect(b[i].title, a[i].title, reason: 'title of item $i');
        expect(b[i].options.map((FormOption o) => o.label),
            a[i].options.map((FormOption o) => o.label));
        expect(b[i].rows, a[i].rows, reason: 'grid rows of item $i');
        expect(b[i].columns, a[i].columns, reason: 'grid columns of item $i');
        expect(b[i].goldenAnswer, a[i].goldenAnswer);
      }
    });

    test('the answer key survives, because a form owns its key', () {
      final FormDef back =
          formFromImportedJson(jsonDecode(jsonEncode(built().toJson())));
      final FormItem mc = back.sections.single.items.first;
      expect(mc.options.where((FormOption o) => o.correct).single.label, 'A');
    });

    test('the scale keeps its bounds and labels', () {
      final FormDef back =
          formFromImportedJson(jsonDecode(jsonEncode(built().toJson())));
      final FormItem scale = back.sections.single.items[2];
      expect(scale.scaleMin, 1);
      expect(scale.scaleMax, 5);
      expect(scale.scaleMinLabel, 'poor');
      expect(scale.scaleMaxLabel, 'great');
    });

    test('the re-import is a NEW form, not the same one', () {
      final FormDef out = built();
      final FormDef back =
          formFromImportedJson(jsonDecode(jsonEncode(out.toJson())));
      expect(back.id, isNot(out.id),
          reason: 'importing an export must not overwrite the original');
      expect(back.published, isFalse);
    });

    test('the filename is derived from the title', () {
      expect(jsonFileName('Quality Assessment: IG Entity Image + Video'),
          'quality-assessment-ig-entity-image-video.json');
      expect(jsonFileName('', fallback: 'form'), 'form.json');
    });
  });
}
