// The Scoring Audit sheet judges a raw against the bar for THAT question's
// type (`Assessment.barFor`): a transcription clip against its own bar when
// one is set, a written answer against the subjective bar, and the badge
// under the meters says which side of it the raw fell. An image A/B prints
// the bar against its graded justification alone.
@TestOn('vm')
library;

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/response_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AppStore _seeded(String type, double raw) => AppStore()
  ..people = <Person>[const Person(id: 'p1', name: 'Asha', email: 'a@x.io')]
  ..assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 'a1',
      'name': 'Warehouse Safety',
      'state': 'done',
      'subjective_threshold': 70.0,
      'transcription_threshold': 85.0,
      'questions': <dynamic>[
        <String, dynamic>{
          'id': 'q1',
          'name': 'Explain the defect',
          'question_type': type,
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
      'answers': <dynamic>[
        <String, dynamic>{
          'question_id': 'q1',
          'justification': 'An answer.',
          'judge': <String, dynamic>{
            'profile': 'subjective',
            'gate': 'pass',
            'verdict': 'Reasoned.',
            'raw100': raw,
            'clarity': 'clear',
            'ai_confidence': 'unlikely',
            'verdict_consistency': 'consistent',
          },
        },
      ],
    }),
  ];

Future<void> _openAudit(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1800, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.light(),
      // The test font draws every glyph a full em wide; at real widths the
      // meter notes fit, here they would overflow the 880px sheet.
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(0.5)),
        child: child!,
      ),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: ResponseDetailScreen(
            store: s,
            attemptId: '90',
            questionId: 'q1',
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  await t.tap(find.widgetWithText(Btn, 'View'));
  await t.pumpAndSettle();
  expect(find.text('Scoring Audit'), findsOneWidget);
}

void main() {
  testWidgets('a clip is judged against its own bar, not the subjective one', (
    WidgetTester t,
  ) async {
    await _openAudit(t, _seeded('transcription', 80));
    expect(find.text('threshold 0.85'), findsOneWidget);
    expect(find.text('Below threshold'), findsOneWidget, reason: '80 < 85');
  });

  testWidgets('a written answer at the subjective bar clears it', (
    WidgetTester t,
  ) async {
    await _openAudit(t, _seeded('subjective_rubric', 70));
    expect(find.text('threshold 0.70'), findsOneWidget);
    expect(find.text('At or above threshold'), findsOneWidget);
  });

  testWidgets('an image A/B prints the bar against its justification', (
    WidgetTester t,
  ) async {
    await _openAudit(t, _seeded('image_ab', 80));
    expect(find.text('Graded raw'), findsOneWidget);
    expect(
      find.text('the justification alone; threshold 0.70'),
      findsOneWidget,
    );
  });
}
