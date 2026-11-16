// "Answered" is out of the paper the candidate sat, not the pool it was drawn
// from.
//
// THE BUG: `assessment_detail.questions` is every question the launch may draw
// from, and each candidate gets only `question_limit` of them. The Answered
// card and the roster CSV divided by `totalQuestions` - the pool - so a
// 10-question draw from 40 read "3 / 40".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// Pool 40, limit 10, three answered; [rowTotal] is the row's own count.
Future<void> _open(WidgetTester t, {int? rowTotal}) async {
  t.view.physicalSize = const Size(1440, 1800);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  final AppStore s = AppStore()
    ..people = <Person>[
      const Person(id: 'p1', name: 'Anita Rao', email: 'anita@example.com'),
    ]
    ..assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': 'a1',
        'name': 'Drawn Paper',
        'state': 'in_progress',
        'question_limit': 10,
        'questions': <dynamic>[
          for (int i = 1; i <= 40; i++)
            <String, dynamic>{
              'id': 'q$i',
              'name': 'Question $i',
              'question_type': 'mcq',
            },
        ],
      }),
    ]
    ..attempts = <Attempt>[
      Attempt.fromJson(<String, dynamic>{
        'id': '80',
        'assessment_id': 'a1',
        'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita Rao'},
        'state': 'in_progress',
        'answered_count': 3,
        'total_questions': ?rowTotal,
      }),
    ];

  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: AttemptDetailScreen(
            store: s,
            portal: Portal.admin,
            attemptId: '80',
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('pool 40, limit 10: Answered reads 3 / 10', (
    WidgetTester t,
  ) async {
    await _open(t);
    expect(find.text('3 / 10'), findsOneWidget);
    expect(find.text('3 / 40'), findsNothing);
  });

  testWidgets('the row says this paper holds 7: Answered reads 3 / 7 (L3)', (
    WidgetTester t,
  ) async {
    // `total_questions` is THIS candidate's paper, exact on an independent
    // draw where the assessment's size is not.
    await _open(t, rowTotal: 7);
    expect(find.text('3 / 7'), findsOneWidget);
    expect(find.text('3 / 10'), findsNothing);
  });

  test('the roster CSV reads the same denominator', () {
    final Assessment asm = Assessment.fromJson(<String, dynamic>{
      'id': 'a1',
      'question_limit': 10,
      'questions': <dynamic>[
        for (int i = 1; i <= 40; i++) <String, dynamic>{'id': 'q$i'},
      ],
    });
    Attempt row(int? total) => Attempt.fromJson(<String, dynamic>{
      'id': '80',
      'assessment_id': 'a1',
      'total_questions': ?total,
    });
    expect(row(7).paperSize(asm), 7);
    expect(row(null).paperSize(asm), 10);
  });

  test('pool 4, drawn 2, no server total: maxMarks is the 2 drawn', () {
    // Same bug in the marks denominator: with no `serverTotal` it summed
    // every question in the pool, not the ones this attempt drew.
    final Assessment asm = Assessment.fromJson(<String, dynamic>{
      'id': 'a1',
      'questions': <dynamic>[
        for (int i = 1; i <= 4; i++)
          <String, dynamic>{'id': 'q$i', 'question_type': 'subjective_rubric'},
      ],
    });
    const Attempt ev = Attempt(
      id: '80',
      assessmentId: 'a1',
      employeeId: 'p1',
      token: 't',
      questionOrder: <String>['q2', 'q4'],
    );

    expect(ev.serverTotal, isNull);
    expect(
      ev.maxMarks(asm),
      asm.questions[1].componentCount + asm.questions[3].componentCount,
    );
    expect(ev.maxMarks(asm), lessThan(asm.questions.length));
  });
}
