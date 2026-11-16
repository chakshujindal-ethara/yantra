/// The candidate's own time and category panels.
///
/// THE STAKES ARE DIFFERENT ON THIS SCREEN. Everything here is shown to the
/// person it is about, so two rules are load-bearing rather than cosmetic:
/// an UNRELEASED sitting's marks must not leak (release is the only gate on a
/// candidate seeing their own score), and time must be visibly not-scored so a
/// number in the same layout as the marks is not read as one.
library;

import 'package:ethara_assessment/assessment/domain/category_scores.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/member/my_performance_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget mount(Widget child, AssessmentNav nav) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: AssessmentNavScope(nav: nav, child: child)),
);

const List<String> kTags = <String>[
  'domain:ai-image-evaluation',
  'modality:image',
  'output-format:ab-choice',
  'task:compare-ai-images',
];

/// A graded subjective answer, as image_ab really arrives: the mark is in the
/// llm pair and `maxScore` is 0.
Response answer({required bool right, List<String> tags = kTags}) => Response(
  hasObjective: false,
  score: 0,
  maxScore: 0,
  llmScore: right ? 1 : 0,
  llmMaxScore: 1,
  finalMark: right ? 1 : 0,
  llmState: LlmState.scored,
  state: 'submitted',
  tags: tags,
);

/// One sitting of one assessment.
({Assessment asm, Attempt ev}) sitting({
  required String asmId,
  required String attemptId,
  required List<bool> marks,
  required bool released,
  String name = 'Test 17/8',
  String started = '2026-08-17T13:00:00Z',
  String? submitted = '2026-08-17T13:31:00Z',
}) {
  final List<Question> qs = <Question>[
    for (int i = 0; i < marks.length; i++)
      Question(
        id: '$asmId-q$i',
        genId: 'g1',
        name: 'Comparing images $i',
        prompt: 'Which is better?',
        type: QType.imageAb,
      ),
  ];
  return (
    asm: Assessment(
      id: asmId,
      name: name,
      state: AsmState.done,
      questions: qs,
      passThreshold: 70,
      durationMinutes: 45,
    ),
    ev: Attempt(
      id: attemptId,
      assessmentId: asmId,
      employeeId: 'p1',
      token: attemptId,
      state: AttemptState.submitted,
      resultsReleased: released,
      startedAt: DateTime.parse(started),
      submittedAt: submitted == null ? null : DateTime.parse(submitted),
      resp: <String, Response>{
        for (int i = 0; i < marks.length; i++)
          '$asmId-q$i': answer(right: marks[i]),
      },
    ),
  );
}

AppStore storeOf(List<({Assessment asm, Attempt ev})> rows) {
  final AppStore s = AppStore();
  s.people = <Person>[
    const Person(id: 'p1', name: 'Priya Sharma', email: 'priya@example.com'),
  ];
  s.meId = 'p1';
  s.assessments = <Assessment>[
    for (final ({Assessment asm, Attempt ev}) r in rows) r.asm,
  ];
  s.attempts = <Attempt>[
    for (final ({Assessment asm, Attempt ev}) r in rows) r.ev,
  ];
  return s;
}

Future<void> open(WidgetTester tester, AppStore s) async {
  tester.view.physicalSize = const Size(1500, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    mount(MyPerformanceScreen(store: s), AssessmentNav()),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Time taken is shown, and shown NOT to be a score', () {
    testWidgets('the elapsed time appears for a submitted sitting', (
      WidgetTester tester,
    ) async {
      await open(
        tester,
        storeOf(<({Assessment asm, Attempt ev})>[
          sitting(
            asmId: 'a1',
            attemptId: 'e1',
            marks: <bool>[true, false],
            released: true,
          ),
        ]),
      );

      expect(find.text('Time Taken'), findsWidgets);
      expect(find.text('31 of 45 min'), findsOneWidget);
    });

    testWidgets('the panel says plainly that time is not evaluated', (
      WidgetTester tester,
    ) async {
      // THE SPEC ASKS FOR THIS IN WORDS. A duration in the same visual language
      // as the marks reads as part of the result unless something says it is
      // not.
      await open(
        tester,
        storeOf(<({Assessment asm, Attempt ev})>[
          sitting(
            asmId: 'a1',
            attemptId: 'e1',
            marks: <bool>[true],
            released: true,
          ),
        ]),
      );

      expect(find.textContaining('never scored'), findsWidgets);
      expect(find.textContaining('not part of your score'), findsOneWidget);
    });

    testWidgets('NO Pace tag on the candidate\'s own screen', (
      WidgetTester tester,
    ) async {
      // Pace is admin-side by design. Telling somebody they were slower than
      // their peers invites them to change something nobody is measuring - and
      // on a timed paper "slow" usually means "used the time they were given".
      await open(
        tester,
        storeOf(<({Assessment asm, Attempt ev})>[
          sitting(
            asmId: 'a1',
            attemptId: 'e1',
            marks: <bool>[true],
            released: true,
          ),
        ]),
      );

      // ENUMERATED, NOT TYPED OUT. This asserts no Pace label leaks to the
      // candidate, and three hand-written strings stop asserting that the
      // moment one is renamed - which is exactly what happened when
      // "Average" became "Normal".
      for (final Pace p in Pace.values) {
        expect(find.text(p.label), findsNothing, reason: '${p.name} leaked');
      }
    });

    testWidgets('an unfinished sitting contributes no time at all', (
      WidgetTester tester,
    ) async {
      // No `submittedAt`, so there is no elapsed span. Reporting "now minus
      // started" would grow every rebuild.
      await open(
        tester,
        storeOf(<({Assessment asm, Attempt ev})>[
          sitting(
            asmId: 'a1',
            attemptId: 'e1',
            marks: <bool>[true],
            released: true,
            submitted: null,
          ),
        ]),
      );
      expect(find.text('Time Taken'), findsNothing);
    });
  });

  group('Categories are per test, and gated on release', () {
    testWidgets('a released sitting shows its category breakdown', (
      WidgetTester tester,
    ) async {
      await open(
        tester,
        storeOf(<({Assessment asm, Attempt ev})>[
          sitting(
            asmId: 'a1',
            attemptId: 'e1',
            marks: <bool>[true, false, true, false, false],
            released: true,
          ),
        ]),
      );

      expect(find.textContaining('Strengths and Weaknesses'), findsWidgets);
      expect(find.textContaining('Compare AI Images'), findsWidgets);
    });

    testWidgets('a HELD sitting leaks no category at all', (
      WidgetTester tester,
    ) async {
      // THE IMPORTANT ONE. Release is the only gate on a candidate seeing their
      // own marks, and a category chart is per-question marks in aggregate - so
      // drawing it for a held sitting would undo the whole screen's release
      // discipline one category at a time.
      await open(
        tester,
        storeOf(<({Assessment asm, Attempt ev})>[
          sitting(
            asmId: 'a1',
            attemptId: 'e1',
            marks: <bool>[true, true, true],
            released: false,
          ),
        ]),
      );

      expect(find.textContaining('Strengths and Weaknesses'), findsNothing);
      expect(find.textContaining('Compare AI Images'), findsNothing);
      // The time panel is NOT gated - how long you spent on your own paper is
      // not a mark - so it must still be there. That contrast is the point.
      expect(find.text('Time Taken'), findsWidgets);
    });

    testWidgets('an untagged paper simply omits the panel', (
      WidgetTester tester,
    ) async {
      // On the candidate's screen the honest thing is silence: an admin can act
      // on "tag your generator", a candidate cannot, so telling them about a
      // tagging gap would be noise about somebody else's job.
      final AppStore s = storeOf(<({Assessment asm, Attempt ev})>[
        sitting(
          asmId: 'a1',
          attemptId: 'e1',
          marks: <bool>[true, false],
          released: true,
        ),
      ]);
      s.attempts = <Attempt>[
        s.attempts.first.copyWith(
          resp: <String, Response>{
            'a1-q0': answer(right: true, tags: const <String>[]),
            'a1-q1': answer(right: false, tags: const <String>[]),
          },
        ),
      ];
      await open(tester, s);

      expect(find.textContaining('Strengths and Weaknesses'), findsNothing);
      expect(find.textContaining('Backfill'), findsNothing);
    });
  });

  group('Most improved', () {
    testWidgets('two sittings of the SAME test produce the callout', (
      WidgetTester tester,
    ) async {
      // 1/3 then 3/3 on the same assessment: a real gain on the one category
      // those questions carry.
      final ({Assessment asm, Attempt ev}) older = sitting(
        asmId: 'a1',
        attemptId: 'e1',
        marks: <bool>[true, false, false],
        released: true,
        started: '2026-08-01T10:00:00Z',
        submitted: '2026-08-01T10:20:00Z',
      );
      final ({Assessment asm, Attempt ev}) newer = sitting(
        asmId: 'a1',
        attemptId: 'e2',
        marks: <bool>[true, true, true],
        released: true,
        started: '2026-08-17T10:00:00Z',
        submitted: '2026-08-17T10:25:00Z',
      );
      final AppStore s = storeOf(<({Assessment asm, Attempt ev})>[older]);
      s.attempts = <Attempt>[older.ev, newer.ev];
      await open(tester, s);

      expect(find.textContaining('Most improved'), findsOneWidget);
    });

    testWidgets('a FIRST sitting claims no improvement', (
      WidgetTester tester,
    ) async {
      // Nothing to have improved from. A "Most improved: 0%" line would be an
      // invented trend.
      await open(
        tester,
        storeOf(<({Assessment asm, Attempt ev})>[
          sitting(
            asmId: 'a1',
            attemptId: 'e1',
            marks: <bool>[true, true],
            released: true,
          ),
        ]),
      );
      expect(find.textContaining('Most improved'), findsNothing);
    });

    testWidgets('a DECLINE is never presented as improvement', (
      WidgetTester tester,
    ) async {
      final ({Assessment asm, Attempt ev}) older = sitting(
        asmId: 'a1',
        attemptId: 'e1',
        marks: <bool>[true, true, true],
        released: true,
        started: '2026-08-01T10:00:00Z',
        submitted: '2026-08-01T10:20:00Z',
      );
      final ({Assessment asm, Attempt ev}) newer = sitting(
        asmId: 'a1',
        attemptId: 'e2',
        marks: <bool>[false, false, false],
        released: true,
        started: '2026-08-17T10:00:00Z',
        submitted: '2026-08-17T10:25:00Z',
      );
      final AppStore s = storeOf(<({Assessment asm, Attempt ev})>[older]);
      s.attempts = <Attempt>[older.ev, newer.ev];
      await open(tester, s);

      expect(find.textContaining('Most improved'), findsNothing);
    });
  });
}
