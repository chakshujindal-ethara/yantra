// Choosing a file must light up the button that imports it.
//
// THE BUG THIS EXISTS FOR, and it had shipped in four importers at once.
//
// `showSheet` puts `actions` in a footer `Container` that is a SIBLING of
// `body` (`widgets/controls.dart`). Both sheets wrapped their body in a
// `StatefulBuilder` and held the chosen file in a local that its setState
// mutated - which rebuilds the body subtree and NOTHING ELSE. The footer's
// `picked == null ? null : ...` was therefore evaluated exactly once, when the
// dialog was built and nothing was picked, and stayed disabled for the life of
// the sheet.
//
// Nothing forced a rebuild either: `_ModalScopeState` caches its page and only
// drops that cache from `Navigator.didUpdateWidget`, which nothing here
// triggers while a sheet is open. And the `Builder` in `actions` was the same
// widget INSTANCE every time, so even a forced rebuild would have
// short-circuited on identity.
//
// The failure looked like success. The dropzone lives inside the body, so it
// updated: choosing a file swapped it for a panel reading "myform.json ·
// 3.2 KB, ready to read" with a green "Selected" badge - above a primary
// button that could never be pressed. Every path into Form Studio import,
// question-bank import, generator import and tag import was dead.
//
// It survived because hot reload calls `reassemble`, which marks every element
// dirty - so it is invisible during `flutter run` and only real in a release
// build. That is exactly the shape of bug a widget test is for, and neither
// sheet had one.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/services/file_pick_stub.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/form_import_sheet.dart';
import 'package:ethara_assessment/assessment/widgets/import_sheet.dart';

/// A stub picker. `pickFile` is a conditional import that answers null off the
/// web, so without this seam the state where a file IS chosen - the only state
/// the bug lived in - is unreachable from a test.
Future<PickedFile?> Function({String accept}) picks(PickedFile f) =>
    ({String accept = ''}) async => f;

PickedFile file(String name, int bytes) =>
    PickedFile(name, List<int>.filled(bytes, 0x20));

/// The `Btn` whose label is [label], read as a widget so its `onPressed` can be
/// inspected. NOT `tap and see what happens`: a disabled button swallows a tap
/// silently, so the assertion has to be about the callback itself.
Btn button(WidgetTester t, String label) => t.widget<Btn>(
  find.byWidgetPredicate((Widget w) => w is Btn && w.label == label),
);

Widget host(void Function(BuildContext) open) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: Builder(
      builder: (BuildContext context) => ElevatedButton(
        onPressed: () => open(context),
        child: const Text('open'),
      ),
    ),
  ),
);

void main() {
  group('Form Studio import sheet', () {
    testWidgets('the Import button is dead until a file is chosen, and alive '
        'after', (WidgetTester t) async {
      final AppStore store = AppStore();
      await t.pumpWidget(
        host((BuildContext c) => showFormImportSheet(c, store,
            pick: picks(file('safety-induction.json', 3200)))),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      expect(find.text('Drop a JSON file here'), findsOneWidget);
      expect(button(t, 'Import').onPressed, isNull,
          reason: 'nothing is chosen yet, so there is nothing to import');

      await t.tap(find.text('Choose a File'));
      await t.pumpAndSettle();

      // THE REGRESSION GUARD. The dropzone updating is not enough - it did that
      // while the bug was live.
      expect(find.textContaining('safety-induction.json'), findsOneWidget);
      expect(button(t, 'Import').onPressed, isNotNull,
          reason: 'a chosen file must reach the footer, which is a SIBLING of '
              'the sheet body and so is not rebuilt by a setState inside it');
    });

    testWidgets('pressing Import answers the chosen file', (
      WidgetTester t,
    ) async {
      final AppStore store = AppStore();
      PickedFile? answered;
      await t.pumpWidget(
        host((BuildContext c) async {
          answered = await showFormImportSheet(c, store,
              pick: picks(file('two-sections.json', 900)));
        }),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Choose a File'));
      await t.pumpAndSettle();
      await t.tap(find.text('Import'));
      await t.pumpAndSettle();

      expect(answered, isNotNull);
      expect(answered!.name, 'two-sections.json');
      expect(find.text('Drop a JSON file here'), findsNothing,
          reason: 'the sheet should be gone');
    });

    testWidgets('an oversized file is refused in the sheet, not after it '
        'closes', (WidgetTester t) async {
      final AppStore store = AppStore();
      await t.pumpWidget(
        host((BuildContext c) => showFormImportSheet(c, store,
            pick: picks(file('huge.json', kMaxFormStructureBytes + 1)))),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Choose a File'));
      await t.pumpAndSettle();

      expect(find.text('Too large'), findsOneWidget);
      expect(button(t, 'Import').onPressed, isNull,
          reason: 'the sheet already knows the file is over the ceiling, so '
              'letting it close and toast the refusal afterwards just costs '
              'the operator the sheet');
    });

    testWidgets('the sheet states the ceiling the importer actually enforces', (
      WidgetTester t,
    ) async {
      final AppStore store = AppStore();
      await t.pumpWidget(host((BuildContext c) =>
          showFormImportSheet(c, store, pick: picks(file('x.json', 10)))));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      // A SECOND COPY OF THE LIMIT IS HOW THE SHEET COMES TO LIE. The number
      // shown has to be the one `AppStore.importForm` refuses on.
      expect(
        find.textContaining('Max ${kMaxFormStructureBytes ~/ 1024} KB'),
        findsOneWidget,
      );
    });
  });

  group('The CSV import sheet has the same footer, and the same fix', () {
    testWidgets('choosing a file enables Import for every entity', (
      WidgetTester t,
    ) async {
      for (final ImportEntity entity in ImportEntity.values) {
        final AppStore store = AppStore();
        await t.pumpWidget(
          host((BuildContext c) => showImportSheet(c, store,
              entity: entity, pick: picks(file('rows.csv', 512)))),
        );
        await t.tap(find.text('open'));
        await t.pumpAndSettle();

        expect(button(t, 'Import').onPressed, isNull, reason: entity.name);

        await t.tap(find.text('Choose a File'));
        await t.pumpAndSettle();

        // A question CSV names where it lands; the others keep "Import".
        final String label =
            entity == ImportEntity.questions ? 'Import as drafts' : 'Import';
        expect(button(t, label).onPressed, isNotNull,
            reason: '${entity.name}: a chosen file never reached the footer');

        await t.tap(find.text('Cancel'));
        await t.pumpAndSettle();
      }
    });
  });

  group('The question import button says where the file lands', () {
    Future<String> labelFor(WidgetTester t, PickedFile f) async {
      await t.pumpWidget(
        host((BuildContext c) => showImportSheet(c, AppStore(),
            entity: ImportEntity.questions, pick: picks(f))),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Choose a File'));
      await t.pumpAndSettle();
      final String label = t.widget<Btn>(find.byWidgetPredicate(
        (Widget w) => w is Btn && w.variant == BtnVariant.primary,
      )).label;
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      return label;
    }

    PickedFile json(String name, Object data, {bool bom = false}) =>
        PickedFile(name, <int>[
          if (bom) ...<int>[0xEF, 0xBB, 0xBF],
          ...utf8.encode(jsonEncode(data)),
        ]);

    const Map<String, dynamic> native = <String, dynamic>{
      'assessments_be_bank': '1',
      'questions': <dynamic>[],
    };

    testWidgets('a native bank export restores into the bank', (
      WidgetTester t,
    ) async {
      expect(await labelFor(t, json('bank.json', native)),
          'Restore into the bank');
    });

    testWidgets('a native export saved with a byte-order mark is still '
        'native', (WidgetTester t) async {
      // The server reads utf-8-sig. utf8.decode drops the BOM too; this pins
      // it, since jsonDecode alone refuses one.
      expect(await labelFor(t, json('bank.json', native, bom: true)),
          'Restore into the bank');
    });

    testWidgets('CSV and harness JSON land as drafts, as Odoo says', (
      WidgetTester t,
    ) async {
      expect(await labelFor(t, file('rows.csv', 512)), 'Import as drafts');
      final Map<String, dynamic> item = <String, dynamic>{
        'id': 'q1', 'instruction': 'x', 'fields': <String, dynamic>{},
      };
      expect(
        await labelFor(t, json('output.json', <String, dynamic>{
          'questions': <dynamic>[item],
        })),
        'Import as drafts',
      );
      expect(await labelFor(t, json('questions.json', <dynamic>[item])),
          'Import as drafts');
      expect(
        await labelFor(t, json('test.json', <String, dynamic>{
          'sections': <dynamic>[
            <String, dynamic>{'title': 'A', 'questions': <dynamic>[]},
          ],
        })),
        'Import as drafts',
      );
    });

    testWidgets('JSON the server cannot place keeps the plain label', (
      WidgetTester t,
    ) async {
      expect(await labelFor(t, json('x.json', <String, dynamic>{'a': 1})),
          'Import');
    });
  });
}
