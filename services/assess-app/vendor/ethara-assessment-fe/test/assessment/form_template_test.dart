@TestOn('vm')
// Reads the captured fixture through dart:io, so it can only run on the VM.
// Under `--platform chrome` there is no filesystem. Same limit, same tag, as
// live_payload_test.dart beside it.
//
// THE CROSS-REPO GUARD FOR THE IMPORT TEMPLATE.
//
// The template is rendered by the MODULE, from `constants.FORM_ITEM_KINDS` -
// the same catalogue publish branches on. This client has its own closed
// `FormItemKind` enum. Those two lists agreeing is not something either repo
// can check alone, and the failure is silent by construction: an unknown
// `kind` is not refused at import, it becomes a `shortAnswer`
// (`FormItemKindX.parse`), with no warning to the operator and no error to
// anyone. So a module that learns a new kind would hand out a template with an
// element this app quietly turns into a text box.
//
// This file is where that stops being invisible.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/form_models.dart';

/// The template exactly as `/api/v1/forms/template/json` served it, decoded out
/// of its envelope by `tool/capture_payloads.py`.
///
/// FAILS LOUDLY WHEN ABSENT, unlike `rowsOf`/`objectOf` in live_payload_test,
/// which answer empty so an un-captured fixture cannot redden an unrelated
/// suite. Here the fixture IS the subject: a missing one must not read as a
/// template with no problems.
Map<String, dynamic> _template() {
  final File f = File('test/assessment/payloads/form_template.json');
  if (!f.existsSync()) {
    fail(
      'test/assessment/payloads/form_template.json is missing. It is the '
      'import template the module serves - re-capture it with '
      '`make fixtures` against a live backend.',
    );
  }
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

/// Every `kind` string in the raw document, in document order.
List<String> _rawKinds(Map<String, dynamic> doc) => <String>[
  for (final Object? s in doc['sections'] as List)
    for (final Object? i in (s as Map<String, dynamic>)['items'] as List)
      ((i as Map<String, dynamic>)['kind'] ?? '').toString(),
];

void main() {
  group('The import template the module serves', () {
    test('parses into a form, and keeps every section and item', () {
      final Map<String, dynamic> doc = _template();
      final FormDef form = formFromImportedJson(doc);

      expect(form.sections, hasLength((doc['sections'] as List).length));
      expect(
        form.sections.expand((FormSection s) => s.items).length,
        _rawKinds(doc).length,
      );
      for (final FormSection s in form.sections) {
        expect(s.items, isNotEmpty, reason: 'an empty section teaches nothing');
        expect(s.title, isNotEmpty);
      }
    });

    test('no kind is silently degraded on the way in', () {
      // THE POINT OF THIS FILE. `FormItemKindX.parse` falls back to
      // `shortAnswer` for anything it does not know, without a warning - so
      // comparing what was parsed against what was WRITTEN is the only way a
      // new module-side kind shows up as a failure rather than as a text box.
      final Map<String, dynamic> doc = _template();
      final List<String> written = _rawKinds(doc);
      final List<String> parsed = formFromImportedJson(doc).sections
          .expand((FormSection s) => s.items)
          .map((FormItem i) => i.kind.name)
          .toList();

      expect(
        parsed,
        written,
        reason:
            'the template carries a kind this app does not have, so the '
            'importer degraded it. Either add it to FormItemKind, or name it '
            'in services/form_json_template.SKIPPED_KINDS on the module side.',
      );
    });

    test('covers every kind this app can draw, exactly once', () {
      final List<String> written = _rawKinds(_template());
      expect(written.toSet(), hasLength(written.length),
          reason: 'a kind appears twice - the template is a catalogue');
      expect(
        written.toSet(),
        FormItemKind.values.map((FormItemKind k) => k.name).toSet(),
        reason:
            'the template and this app disagree about which kinds exist. A '
            'kind missing here is one an author cannot discover from the file '
            'the product hands out.',
      );
    });

    test('names the slots each kind needs, rather than leaving them out', () {
      // A STRUCTURE TEMPLATE IS ITS SLOTS. An item that arrived with none of
      // them would import and read as a finished question, which is exactly the
      // confusion the template exists to prevent - so the presence of the key
      // is asserted per kind, not its value (every value is deliberately blank).
      final Map<String, dynamic> raw = _template();
      final Map<String, Map<String, dynamic>> byKind =
          <String, Map<String, dynamic>>{
            for (final Object? s in raw['sections'] as List)
              for (final Object? i in (s as Map<String, dynamic>)['items']
                  as List)
                ((i as Map<String, dynamic>)['kind']).toString(): i,
          };

      const Map<String, List<String>> expected = <String, List<String>>{
        'shortAnswer': <String>['golden_answer'],
        'paragraph': <String>['golden_answer'],
        'multipleChoice': <String>['options'],
        'dropdown': <String>['options'],
        'checkboxes': <String>['options'],
        'choiceGrid': <String>['rows', 'columns', 'grid_key'],
        'checkboxGrid': <String>['rows', 'columns', 'grid_key'],
        'linearScale': <String>[
          'scale_min',
          'scale_max',
          'scale_min_label',
          'scale_max_label',
          'golden_answer',
        ],
        'rating': <String>['rating_max', 'golden_answer'],
        'imageBlock': <String>['media_url', 'media_kind', 'options'],
        'videoBlock': <String>['media_url', 'media_kind', 'options'],
        'comparePair': <String>[
          'media_url',
          'media_url_b',
          'options',
          'golden_answer',
          'require_justification',
        ],
        'imageAnnotation': <String>[
          'media_url',
          'annotation_count',
          'regions',
          'golden_labels',
        ],
        'promptWriting': <String>[
          'media_url',
          'media_url_b',
          'golden_answer',
          'options',
        ],
        'transcription': <String>['media_url', 'golden_answer'],
      };

      expected.forEach((String kind, List<String> keys) {
        final Map<String, dynamic>? item = byKind[kind];
        expect(item, isNotNull, reason: '$kind is not in the template');
        for (final String key in keys) {
          expect(
            item,
            contains(key),
            reason: '$kind should name $key so an author knows to fill it in',
          );
        }
      });
    });

    test('spells the scale key the way publish reads it', () {
      // `scale_golden` / `rating_golden` are THIS app's typed fields, written
      // by `toJson` and mapped back onto `golden_answer` by `_wireGoldenAnswer`.
      // `studio_form` reads only `golden_answer`, so a template using the typed
      // spelling would be refused with the value plainly in it - and only for
      // authors who never opened this app.
      final Map<String, dynamic> raw = _template();
      final String text = jsonEncode(raw);
      expect(text, isNot(contains('scale_golden')));
      expect(text, isNot(contains('rating_golden')));
      expect(text, contains('golden_answer'));
    });

    test('carries no answer key: it is a structure, not a form', () {
      final FormDef form = formFromImportedJson(_template());
      for (final FormItem i
          in form.sections.expand((FormSection s) => s.items)) {
        expect(i.goldenAnswer, isEmpty, reason: '${i.kind.name} has a key');
        expect(i.gridKey, isEmpty, reason: '${i.kind.name} has a grid key');
        expect(i.goldenLabels, isEmpty, reason: '${i.kind.name} has labels');
        for (final FormOption o in i.options) {
          expect(o.correct, isFalse, reason: '${i.kind.name} marks an option');
          expect(o.label, isEmpty);
        }
      }
      // AND YET `questionCount` IS NOT ZERO, which is the distinction worth
      // pinning rather than papering over. This app counts ANSWER SLOTS -
      // `isAnswerable` is kind-level for everything but the comparison and the
      // media blocks, and those three count as soon as an `options` list
      // exists at all, blank labels included. The server counts PUBLISHABLE
      // questions: `_media_item_has_options` wants a non-blank label, and every
      // other kind needs its key. So an unfilled template reads as 14 slots
      // here and 0 deliverable questions there, and both are right.
      expect(
        form.questionCount,
        form.sections
                .expand((FormSection s) => s.items)
                .where((FormItem i) => i.kind != FormItemKind.textBlock)
                .length,
        reason: 'every kind but the text block offers a slot to answer',
      );
    });

    test('carries no candidate-facing text, and the guidance never survives '
        'the import', () {
      // `help` BECOMES THE QUESTION'S DESCRIPTION, which a candidate reads
      // (`studio_form._item_spec`), and for a `textBlock` it is folded into the
      // next question's lead text. So the template's per-kind guidance cannot
      // live there: an author who fills in only what Publish forces would ship
      // "Write the model answer. The judge marks each candidate against it..."
      // to candidates, and Publish never looks at `help`, so nothing would say
      // so.
      //
      // It lives in `_note` instead - visible in the file the author edits, and
      // dropped by BOTH parsers. This is the client half of that: `FormItem`
      // reads named keys only, so `_note` cannot reach `/forms/save`, and
      // therefore cannot reach a candidate.
      final Map<String, dynamic> raw = _template();
      final List<Map<String, dynamic>> items = <Map<String, dynamic>>[
        for (final Object? s in raw['sections'] as List)
          for (final Object? i in (s as Map<String, dynamic>)['items'] as List)
            i as Map<String, dynamic>,
      ];
      for (final Map<String, dynamic> i in items) {
        expect(i['help'], '', reason: '${i['kind']} carries help text');
        expect(i['_note'], isNotEmpty,
            reason: '${i['kind']} has no authoring note to guide the author');
      }

      final FormDef form = formFromImportedJson(raw);
      for (final FormItem i
          in form.sections.expand((FormSection s) => s.items)) {
        expect(i.help, isEmpty, reason: '${i.kind.name} imported help text');
      }
      expect(
        jsonEncode(form.toJson()),
        isNot(contains('_note')),
        reason: 'the authoring note reached the wire, so it can reach a '
            'candidate as a question description',
      );
    });

    test('carries no media, so importing it fetches nothing', () {
      final FormDef form = formFromImportedJson(_template());
      for (final FormItem i
          in form.sections.expand((FormSection s) => s.items)) {
        expect(i.mediaUrl, isEmpty);
        expect(i.mediaUrlB, isEmpty);
      }
    });

    test('arrives as a draft with fresh ids, however it was written', () {
      final FormDef form = formFromImportedJson(_template());
      expect(form.published, isFalse);
      expect(form.title, isNotEmpty);
      final List<String> ids = <String>[
        for (final FormSection s in form.sections) ...<String>[
          s.id,
          for (final FormItem i in s.items) i.id,
        ],
      ];
      expect(ids.where((String id) => id.isEmpty), isEmpty);
      expect(ids.toSet(), hasLength(ids.length), reason: 'ids collide');
    });

    test('is far below the ceiling the importer enforces', () {
      // 512 KB is checked before the file is even decoded
      // (`AppStore.importForm`). A template near it would be unreadable long
      // before it was refused, so this asserts headroom, not the limit.
      final int bytes = File(
        'test/assessment/payloads/form_template.json',
      ).lengthSync();
      expect(bytes, lessThan(512 * 1024 ~/ 10));
    });

    test('re-exports to something the importer takes back', () {
      // The template is a starting point an author edits and re-imports, often
      // after a round trip through this designer. That round trip is already
      // pinned for authored forms; this asserts it for the template itself.
      final FormDef once = formFromImportedJson(_template());
      final FormDef twice = formFromImportedJson(once.toJson());
      expect(
        twice.sections.expand((FormSection s) => s.items)
            .map((FormItem i) => i.kind.name),
        once.sections.expand((FormSection s) => s.items)
            .map((FormItem i) => i.kind.name),
      );
    });
  });
}
