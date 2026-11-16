// A grid cell and a rating star carry no visible text of their own, so a
// screen reader had nothing to read: the cells announced as bare radios and
// the stars as unlabelled buttons. Each now names itself - "row, column" for a
// cell, "N of M stars" for a star - with its checked state.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/exam/answer_layouts.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Question _question(List<Map<String, dynamic>> dims) =>
    Question.fromJson(<String, dynamic>{
      'id': '10',
      'name': 'Q',
      'prompt': 'Q',
      'question_type': 'mcq',
      'dimensions': dims,
      'images': <dynamic>[],
      'videos': <dynamic>[],
      'label_boxes': <dynamic>[],
    });

Map<String, dynamic> _dim(
  int id,
  String name,
  String kind,
  List<String> cols,
) => <String, dynamic>{
  'id': id,
  'name': name,
  'input_kind': kind,
  'options': <Map<String, dynamic>>[
    for (int k = 0; k < cols.length; k++)
      <String, dynamic>{'id': id * 10 + k, 'label': cols[k]},
  ],
};

Future<void> _pump(WidgetTester t, Question q) async {
  t.view.physicalSize = const Size(1400, 1600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AnswerArea(
          store: AppStore(),
          ev: Attempt.fromJson(<String, dynamic>{'id': 7, 'assessment_id': 21}),
          q: q,
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('each grid cell reads its row and column', (
    WidgetTester t,
  ) async {
    final SemanticsHandle h = t.ensureSemantics();
    await _pump(
      t,
      _question(<Map<String, dynamic>>[
        _dim(1, 'Refund', 'choiceGrid', <String>['Yes', 'No']),
        _dim(2, 'Replace', 'choiceGrid', <String>['Yes', 'No']),
      ]),
    );
    expect(find.byKey(const Key('axis-grid')), findsOneWidget);
    for (final String label in <String>[
      'Refund, Yes',
      'Refund, No',
      'Replace, Yes',
      'Replace, No',
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }
    expect(
      t.getSemantics(find.bySemanticsLabel('Refund, Yes')),
      matchesSemantics(
        label: 'Refund, Yes',
        hasCheckedState: true,
        isInMutuallyExclusiveGroup: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    h.dispose();
  });

  testWidgets('each star reads "N of M stars"', (WidgetTester t) async {
    final SemanticsHandle h = t.ensureSemantics();
    await _pump(
      t,
      _question(<Map<String, dynamic>>[
        _dim(1, 'Answer', 'rating', <String>['1', '2', '3', '4', '5']),
      ]),
    );
    expect(find.byKey(const Key('axis-rating')), findsOneWidget);
    for (int i = 1; i <= 5; i++) {
      expect(find.bySemanticsLabel('$i of 5 stars'), findsOneWidget);
    }
    h.dispose();
  });
}
