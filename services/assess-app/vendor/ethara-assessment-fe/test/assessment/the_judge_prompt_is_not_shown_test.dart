// The "Judge prompt" row is gone from the answer page and the attempt's audit
// sheet (ETP_PLANS_AND_STRATEGY.md §2.14, W12).
//
// The field is still recorded on every answer and still parsed - it is an
// audit value, shown on the Odoo answer form in developer mode - but it is an
// opaque hash like `bundled:34c42d2f` that an admin cannot act on, and after the
// text-only grading prompt ships every answer graded before it would show a
// different value for no reason a reviewer could see.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/response_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Map<String, dynamic> _graded() => <String, dynamic>{
  'question_id': 'q1',
  'state': 'submitted',
  'needs_llm': true,
  'llm_state': 'scored',
  'llm_raw_100': 72.0,
  'justification': 'The axes are mislabelled.',
  'grading': <String, dynamic>{
    'verdict': 'Named the defect and its cause.',
    'judge_model': 'gemini-3.1-pro-preview',
    'prompt_version': 'bundled:34c42d2f',
    'attempts': 1,
  },
};

/// A seed store, so neither screen's hydrate call replaces the answer.
AppStore _seeded() => AppStore()
  ..people = <Person>[const Person(id: 'p1', name: 'Asha', email: 'a@x.io')]
  ..assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 'a1',
      'name': 'Warehouse Safety',
      'state': 'done',
      'questions': <dynamic>[
        <String, dynamic>{
          'id': 'q1',
          'name': 'Explain the defect',
          'question_type': 'subjective_rubric',
        },
      ],
    }),
  ]
  ..attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': '90',
      'assessment_id': 'a1',
      'candidate': <String, dynamic>{'id': 'p1', 'name': 'Asha'},
      'state': 'submitted',
      'answers': <dynamic>[_graded()],
    }),
  ];

/// Either casing: the sheet prints field labels in capitals.
final RegExp _model = RegExp('^judge model\$', caseSensitive: false);
final RegExp _prompt = RegExp('judge prompt', caseSensitive: false);

Future<void> _mount(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1800, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.light(),
      home: Scaffold(
        body: AssessmentNavScope(nav: AssessmentNav(), child: child),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  test('the value is still parsed', () {
    expect(
      Response.fromJson(_graded()).judge?.promptVersion,
      'bundled:34c42d2f',
      reason: 'hidden from the page, not dropped from the record',
    );
  });

  testWidgets('the answer page shows the model and not the prompt', (
    WidgetTester t,
  ) async {
    await _mount(
      t,
      ResponseDetailScreen(store: _seeded(), attemptId: '90', questionId: 'q1'),
    );

    expect(
      find.textContaining(_model),
      findsOneWidget,
      reason: 'the audit panel rendered, so the row below is really absent',
    );
    expect(find.textContaining(_prompt), findsNothing);
    expect(find.textContaining('bundled:34c42d2f'), findsNothing);
  });

  testWidgets('the attempt\'s audit sheet shows the model and not the prompt', (
    WidgetTester t,
  ) async {
    await _mount(
      t,
      AttemptDetailScreen(
        store: _seeded(),
        portal: Portal.admin,
        attemptId: '90',
      ),
    );
    await t.tap(find.text('View'));
    await t.pumpAndSettle();

    expect(find.textContaining(_model), findsOneWidget);
    expect(find.textContaining(_prompt), findsNothing);
    expect(find.textContaining('bundled:34c42d2f'), findsNothing);
  });
}
