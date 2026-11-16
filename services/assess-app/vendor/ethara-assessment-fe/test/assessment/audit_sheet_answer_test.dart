// The answer audit sheet shows the ANSWER, whatever type the answer is.
//
// THE BUG. The module keeps a candidate's answer in a different field per
// question type: prose lands in `justification`, a labelling answer in
// `label_answers`, an mcq's in the selected option ids, an image_ab's in its
// per-axis verdicts. `answerSummary` is the one read that knows all four, and
// the record and the scoring sheet both go through it.
//
// The attempt detail's own audit sheet did not - it printed `r.justification`
// raw. On every non-prose type that field is empty, so "The candidate answer"
// read "(erased or left blank)" over a fully answered question, on the one
// screen an admin opens to argue about a mark. The same answer rendered
// correctly one click away under "Open attempt", which is how it was found.
//
// Erasure is a SEPARATE fact and still has to survive: `redactFor` prints
// "[erased]" for an anonymised candidate, and a blank there would read as an
// unanswered question rather than a redacted one.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Widget mount(Widget child) => MaterialApp(
  theme: ThemeData.light(),
  home: Scaffold(
    body: AssessmentNavScope(nav: AssessmentNav(), child: child),
  ),
);

/// One graded `image_label` answer, in the shape `response_row` sends it: the
/// labels in `label_answers`, the justification empty, and a grader block that
/// makes the row show its "View" button at all.
Map<String, dynamic> _labelAnswer() => <String, dynamic>{
  'question_id': 'q1',
  'state': 'submitted',
  'needs_llm': true,
  'llm_state': 'scored',
  'llm_score': 0,
  'llm_max_score': 1,
  'llm_raw_100': 0.0,
  'justification': '',
  'label_answers': <String, dynamic>{
    // Out of order on purpose - `answerSummary` sorts by box number, and
    // this is the fixture that proved it had to.
    '46': 'it is cookies policy',
    '1': 'spotify icon',
  },
  'grading': <String, dynamic>{
    'verdict': 'Omitted the vast majority of required labels.',
    'profile': 'p3_dense_ui_labelling',
    'judge_model': 'gemini-3.1-pro-preview',
    'raw_100': 0.0,
    'attempts': 1,
  },
};

AppStore _seeded({bool anonymised = false}) {
  final AppStore s = AppStore();
  s.people = <Person>[
    const Person(id: 'p1', name: 'Utkarsh Jain E', email: 'u@example.com'),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 'a1',
      'name': 'High Res Dense Assessment',
      'state': 'done',
      'subjective_threshold': 60.0,
      'questions': <dynamic>[
        <String, dynamic>{
          'id': 'q1',
          'name': 'Task: Describe UI Elements',
          'question_type': 'image_label',
          'label_boxes': <int>[1, 46],
        },
      ],
    }),
  ];
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': '90',
      'assessment_id': 'a1',
      'candidate': <String, dynamic>{'id': 'p1', 'name': 'Utkarsh Jain E'},
      'state': 'submitted',
      'invite_state': 'sent',
      'answered_count': 1,
      'total_questions': 1,
      'result': 'fail',
      'pass_threshold': 60.0,
      'results_released': true,
      'pii_anonymized': anonymised,
      'answers': <dynamic>[_labelAnswer()],
    }),
  ];
  return s;
}

Future<void> _openAudit(WidgetTester t, {bool anonymised = false}) async {
  t.view.physicalSize = const Size(1800, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  await t.pumpWidget(
    mount(
      AttemptDetailScreen(
        store: _seeded(anonymised: anonymised),
        portal: Portal.admin,
        attemptId: '90',
      ),
    ),
  );
  await t.pumpAndSettle();

  await t.tap(find.text('View'));
  await t.pumpAndSettle();
  expect(find.text('Answer Audit'), findsOneWidget);
}

void main() {
  testWidgets('a labelling answer is the labels, not a blank', (
    WidgetTester t,
  ) async {
    await _openAudit(t);

    // The exact string the sheet printed instead of the answer.
    expect(
      find.text('(erased or left blank)'),
      findsNothing,
      reason: 'a fully answered question read as unanswered',
    );
    expect(find.textContaining('Box 1: spotify icon'), findsOneWidget);
    expect(find.textContaining('Box 46: it is cookies policy'), findsOneWidget);
  });

  testWidgets('and the boxes are in box order, not fill order', (
    WidgetTester t,
  ) async {
    await _openAudit(t);

    // The candidate filled 46 first. Read back against the image, an unsorted
    // list cannot be followed.
    final String shown = t
        .widgetList<Text>(find.textContaining('Box 1: spotify icon'))
        .first
        .data!;
    expect(shown.indexOf('Box 1:'), lessThan(shown.indexOf('Box 46:')));
  });

  testWidgets('an erased candidate reads as erased, not as unanswered', (
    WidgetTester t,
  ) async {
    await _openAudit(t, anonymised: true);

    expect(find.text('[erased]'), findsOneWidget);
    expect(find.textContaining('spotify icon'), findsNothing);
  });
}
