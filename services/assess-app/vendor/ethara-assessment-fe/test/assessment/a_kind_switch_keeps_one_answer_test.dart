// R8: switching a question to a one-pick kind keeps ONE correct answer.
//
// Checkboxes with two ticked, switched to Multiple choice, kept both: a key no
// candidate can earn on a one-pick question, which the server now refuses, so
// the template or form could no longer be saved. The same for a Checkbox grid
// row switched to a Multiple choice grid.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_item_editor.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';

typedef _KindPick = (FormItemKind, bool);

Future<void> _pump(WidgetTester t, FormItem item) async {
  t.view.physicalSize = const Size(1400, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) =>
                FormItemEditor(
                  store: AppStore(),
                  item: item,
                  index: 0,
                  onEdit: (VoidCallback mutate) => setState(mutate),
                  onDuplicate: () {},
                  onDelete: () {},
                ),
          ),
        ),
      ),
    ),
  );
  await t.pump();
}

Future<void> _choose(WidgetTester t, String label) async {
  await t.tap(find.byType(SelectField<_KindPick>));
  await t.pumpAndSettle();
  await t.tap(find.text(label).last);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('Checkboxes to Multiple choice keeps the first correct', (
    WidgetTester t,
  ) async {
    final FormItem it = FormItem(
      'q',
      FormItemKind.checkboxes,
      options: <FormOption>[
        FormOption('a', 'Alpha'),
        FormOption('b', 'Beta', correct: true),
        FormOption('c', 'Gamma', correct: true),
      ],
    );
    await _pump(t, it);
    await _choose(t, 'Multiple choice');

    expect(it.kind, FormItemKind.multipleChoice);
    expect(it.options.map((FormOption o) => o.correct).toList(), <bool>[
      false,
      true,
      false,
    ]);
  });

  testWidgets('Multiple choice to Checkboxes keeps what was keyed', (
    WidgetTester t,
  ) async {
    final FormItem it = FormItem(
      'q',
      FormItemKind.multipleChoice,
      options: <FormOption>[
        FormOption('a', 'Alpha', correct: true),
        FormOption('b', 'Beta'),
      ],
    );
    await _pump(t, it);
    await _choose(t, 'Checkboxes');

    expect(it.options.map((FormOption o) => o.correct).toList(), <bool>[
      true,
      false,
    ]);
  });

  testWidgets('a Checkbox grid row keeps one column as a choice grid', (
    WidgetTester t,
  ) async {
    final FormItem it = FormItem(
      'g',
      FormItemKind.checkboxGrid,
      rows: <String>['Row 1', 'Row 2'],
      columns: <String>['Column 1', 'Column 2'],
      gridKey: <int, Set<String>>{
        0: <String>{'Column 1', 'Column 2'},
        1: <String>{'Column 2'},
      },
    );
    await _pump(t, it);
    await _choose(t, 'Multiple choice grid');

    expect(it.kind, FormItemKind.choiceGrid);
    expect(it.gridKey, <int, Set<String>>{
      0: <String>{'Column 1'},
      1: <String>{'Column 2'},
    });
  });

  // The same rule for a picture or clip with options: switching "Allow
  // multiple selections" off kept two correct, and the publish was refused.
  for (final FormItemKind kind in <FormItemKind>[
    FormItemKind.imageBlock,
    FormItemKind.videoBlock,
  ]) {
    testWidgets('${kind.name}: multiple selections off keeps one correct', (
      WidgetTester t,
    ) async {
      final FormItem it = FormItem(
        'm',
        kind,
        multiSelect: true,
        options: <FormOption>[
          FormOption('a', 'Alpha'),
          FormOption('b', 'Beta', correct: true),
          FormOption('c', 'Gamma', correct: true),
        ],
      );
      await _pump(t, it);
      await t.tap(
        find.descendant(
          of: find
              .ancestor(
                of: find.text('Allow multiple selections'),
                matching: find.byType(Row),
              )
              .first,
          matching: find.byType(Switcher),
        ),
      );
      await t.pumpAndSettle();

      expect(it.multiSelect, isFalse);
      expect(it.options.map((FormOption o) => o.correct).toList(), <bool>[
        false,
        true,
        false,
      ]);
    });
  }
}
