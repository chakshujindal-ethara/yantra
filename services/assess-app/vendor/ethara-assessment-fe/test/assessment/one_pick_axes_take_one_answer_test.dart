// R8: an axis the candidate answers with one pick takes one correct answer,
// and an axis they tick several on keeps several - whatever the paper type.
//
// The server's `takes_one_answer`: msq, or a checkboxes / checkboxGrid axis,
// takes several; every other axis takes one. The editor used to decide by the
// paper type alone, so an A/B axis took several (a key nobody could earn,
// scoring being an exact-set match) and a checkboxes axis on an mcq paper
// could hold only one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/question_editor.dart';

Question _draft(String type, {String kind = ''}) =>
    Question.fromJson(<String, dynamic>{
      'id': 7,
      'name': 'Which apply?',
      'question_type': type,
      'state': 'draft',
      'dimensions': <dynamic>[
        <String, dynamic>{
          'id': 70,
          'label': 'Verdict',
          'input_kind': kind,
          'options': <dynamic>[
            <String, dynamic>{'id': 1, 'name': 'First', 'is_correct': true},
            <String, dynamic>{'id': 2, 'name': 'Second', 'is_correct': false},
            <String, dynamic>{'id': 3, 'name': 'Third', 'is_correct': false},
          ],
        },
      ],
    });

Finder get _correct =>
    find.byWidgetPredicate((Widget w) => w is SwitchRow && w.name == 'Correct');

List<bool> _key(WidgetTester tester) => tester
    .widgetList<SwitchRow>(_correct)
    .map((SwitchRow s) => s.value)
    .toList();

Future<void> _open(WidgetTester tester, Question q) async {
  tester.view.physicalSize = const Size(1600, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final AppStore store = AppStore();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => showDraftEditor(context, store, q),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _tick(WidgetTester tester, int i) async {
  await tester.tap(
    find.descendant(of: _correct.at(i), matching: find.byType(Switcher)),
  );
  await tester.pump();
}

void main() {
  testWidgets('an A/B axis takes one verdict', (WidgetTester tester) async {
    await _open(tester, _draft('image_ab'));
    await _tick(tester, 1);

    expect(_key(tester), <bool>[false, true, false]);
    expect(find.text('one correct'), findsOneWidget);
  });

  testWidgets('a checkboxes axis on an mcq paper keeps several', (
    WidgetTester tester,
  ) async {
    await _open(tester, _draft('mcq', kind: 'checkboxes'));
    await _tick(tester, 1);

    expect(_key(tester), <bool>[true, true, false]);
    expect(find.text('several may be correct'), findsOneWidget);
    expect(find.textContaining('only have one correct option'), findsNothing);
  });

  testWidgets('a plain mcq axis still takes one', (WidgetTester tester) async {
    await _open(tester, _draft('mcq'));
    await _tick(tester, 2);

    expect(_key(tester), <bool>[false, false, true]);
  });
}
