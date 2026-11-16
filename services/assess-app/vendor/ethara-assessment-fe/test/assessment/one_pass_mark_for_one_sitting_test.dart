// One sitting, one pass mark - on every card that names it.
//
// THE BUG. `_categoryPanels` built the Strengths-and-Weaknesses card with
// `asm?.passThreshold ?? 70`. A candidate never loads an Assessment record
// (`/api/v1/assessments` is a manager route), and the one they DO acquire from
// the exam route carries no threshold - so the card fell back to 70, printed
// "against the 70% pass mark", and filed every category scoring 60-69% under
// "Weakest areas". The ThresholdBar 76 lines below in the same file already
// read `ev.passMarkPercent(asm)` - the figure `_compute_result` actually
// applied, sent on every released candidate attempt as `result.pass_threshold`
// - so one screen stated two different bars for one sitting.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/member/my_performance_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/category_card.dart';

const List<String> kTags = <String>[
  'domain:ai-image-evaluation',
  'task:compare-ai-images',
];

Response _answer({required bool right}) => Response(
  hasObjective: false,
  score: 0,
  maxScore: 0,
  llmScore: right ? 1 : 0,
  llmMaxScore: 1,
  finalMark: right ? 1 : 0,
  llmRaw100: right ? 90 : 20,
  llmState: LlmState.scored,
  state: 'submitted',
  tags: kTags,
);

/// A candidate's own sitting of a 60% paper.
///
/// The Assessment is the threshold-less record the exam route leaves behind -
/// `passThreshold` sits at the platform default - while the ATTEMPT carries
/// `result.pass_threshold: 60`, the bar the server actually judged by.
AppStore _store() {
  final List<Question> qs = <Question>[
    for (int i = 0; i < 4; i++)
      Question(
        id: 'a1-q$i',
        genId: 'g1',
        name: 'Comparing images $i',
        prompt: 'Which is better?',
        type: QType.imageAb,
      ),
  ];
  final AppStore s = AppStore();
  s.people = <Person>[
    const Person(id: 'p1', name: 'Priya Sharma', email: 'priya@example.com'),
  ];
  s.meId = 'p1';
  s.assessments = <Assessment>[
    Assessment(
      id: 'a1',
      name: 'Image comparison',
      state: AsmState.done,
      questions: qs,
      passThreshold: 70,
      durationMinutes: 45,
    ),
  ];
  s.attempts = <Attempt>[
    Attempt(
      id: 'e1',
      assessmentId: 'a1',
      employeeId: 'p1',
      token: 'e1',
      state: AttemptState.submitted,
      resultsReleased: true,
      serverPassThreshold: 60,
      startedAt: DateTime.parse('2026-08-17T13:00:00Z'),
      submittedAt: DateTime.parse('2026-08-17T13:31:00Z'),
      resp: <String, Response>{
        for (int i = 0; i < qs.length; i++)
          'a1-q$i': _answer(right: i.isEven),
      },
    ),
  ];
  return s;
}

void main() {
  testWidgets('the strengths card uses the pass mark the server applied', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1500, 3400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: AssessmentNavScope(
            nav: AssessmentNav(),
            child: MyPerformanceScreen(store: _store()),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    final CategoryCard card = t.widget<CategoryCard>(
      find.byType(CategoryCard).first,
    );
    expect(
      card.threshold,
      60,
      reason:
          'the card and the ThresholdBar on the same screen must state the '
          'one bar the server judged this sitting by',
    );
  });
}
