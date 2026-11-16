/// SOP-category strengths and weaknesses, on all four surfaces that show them.
///
/// WHY ONE FILE FOR FOUR SCREENS. The whole point of `CategoryCard` +
/// `category_scores.dart` is that an operator and the candidate they are judging
/// read the SAME number for the same category. Testing the surfaces separately
/// would let them drift apart between files; testing them together means a
/// change that moves one and not the others fails here.
///
/// The placements, per the growth manager's brief as re-scoped:
///   admin     - a candidate's ATTEMPT (per assessment, beside grader feedback)
///   admin     - a candidate's PERFORMANCE page, from a leaderboard row
///   candidate - their own PERFORMANCE page
///   candidate - "See my answers" for one sitting, beside grader feedback
library;

import 'package:ethara_assessment/assessment/domain/category_scores.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/member/my_performance_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/category_card.dart';
import 'package:ethara_assessment/assessment/widgets/charts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget mount(Widget child, AssessmentNav nav) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: AssessmentNavScope(nav: nav, child: child)),
);

/// The four facets the live bank actually carries, extracted from its SOP.
const List<String> kSopTags = <String>[
  'domain:ai-image-evaluation',
  'modality:image',
  'output-format:ab-choice',
  'task:compare-ai-images',
];

/// A SECOND task, for the cases that need more than one category to rank.
///
/// `kSopTags` carries exactly one `task:` tag, and `categoryScores` ranks ONE
/// facet at a time - so a paper tagged only with `kSopTags` legitimately yields
/// a single category, and the Strongest/Weakest pair is suppressed by design (a
/// "strongest of one" is not a finding). Any test about those two KPIs has to
/// give the paper two tasks to choose between.
const List<String> kSopTagsAlt = <String>[
  'domain:ai-image-evaluation',
  'modality:image',
  'output-format:ab-choice',
  'task:spot-ai-artifacts',
];

/// A graded subjective answer, exactly as image_ab arrives: the mark lives in
/// the llm pair and `maxScore` is 0.
Response answer({required bool right, List<String> tags = kSopTags}) => Response(
  hasObjective: false,
  score: 0,
  maxScore: 0,
  llmScore: right ? 1 : 0,
  llmMaxScore: 1,
  finalMark: right ? 1 : 0,
  llmRaw100: right ? 90 : 20,
  llmState: LlmState.scored,
  state: 'submitted',
  tags: tags,
);

({Assessment asm, Attempt ev}) sitting({
  required String asmId,
  required String attemptId,
  required List<bool> marks,
  bool released = true,
  String name = 'Test 17/8',
  String started = '2026-08-17T13:00:00Z',
  String? submitted = '2026-08-17T13:31:00Z',
  List<String> tags = kSopTags,

  /// Per-answer tags, when a case needs more than one category. Falls back to
  /// [tags] for every answer.
  List<List<String>>? tagsPer,
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
  List<String> tagsFor(int i) =>
      tagsPer != null && i < tagsPer.length ? tagsPer[i] : tags;
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
          '$asmId-q$i': answer(right: marks[i], tags: tagsFor(i)),
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
  s.assessments = <Assessment>[for (final r in rows) r.asm];
  s.attempts = <Attempt>[for (final r in rows) r.ev];
  return s;
}

Future<void> openAttempt(WidgetTester tester, AppStore s) async {
  tester.view.physicalSize = const Size(1600, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    mount(
      AttemptDetailScreen(store: s, portal: Portal.admin, attemptId: 'e1'),
      AssessmentNav(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openPerformance(
  WidgetTester tester,
  AppStore s, {
  String? personId,
}) async {
  tester.view.physicalSize = const Size(1500, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    mount(
      MyPerformanceScreen(store: s, personId: personId),
      AssessmentNav(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('ADMIN - a candidate\'s attempt, per assessment', () {
    testWidgets('the card sits beside the per-answer grader detail', (
      WidgetTester tester,
    ) async {
      // THE RE-SCOPE. This used to be a tab on the ASSESSMENT; it belongs on the
      // person's paper, where the grader's own reasoning already is.
      await openAttempt(
        tester,
        storeOf(<({Assessment asm, Attempt ev})>[
          sitting(
            asmId: 'a1',
            attemptId: 'e1',
            marks: <bool>[true, false, true, false, false],
          ),
        ]),
      );

      expect(find.text('Strengths and Weaknesses'), findsOneWidget);
      expect(find.textContaining('Compare AI Images'), findsWidgets);
      // The grader evidence is on the same screen - that is why it is here.
      expect(find.text('Score Details'), findsOneWidget);
    });

    testWidgets('categories are named from the SOP, and say so', (
      WidgetTester tester,
    ) async {
      // The brief asks for SOP tags as the categories so an operator can judge
      // proficiency against what the SOP required. The card states where the
      // categories came from rather than leaving it implied.
      await openAttempt(
        tester,
        storeOf(<({Assessment asm, Attempt ev})>[
          sitting(asmId: 'a1', attemptId: 'e1', marks: <bool>[true, false]),
        ]),
      );
      expect(find.textContaining('by SOP category'), findsOneWidget);
    });

    testWidgets('an operator is told it never re-marks anybody', (
      WidgetTester tester,
    ) async {
      await openAttempt(
        tester,
        storeOf(<({Assessment asm, Attempt ev})>[
          sitting(asmId: 'a1', attemptId: 'e1', marks: <bool>[true, false]),
        ]),
      );
      expect(find.textContaining('Never changes a mark'), findsOneWidget);
    });

    testWidgets('an UNTAGGED paper omits the card entirely', (
      WidgetTester tester,
    ) async {
      // No chart drawn from nothing. An operator reading one person's paper
      // cannot act on "your bank is untagged".
      await openAttempt(
        tester,
        storeOf(<({Assessment asm, Attempt ev})>[
          sitting(
            asmId: 'a1',
            attemptId: 'e1',
            marks: <bool>[true, false],
            tags: const <String>[],
          ),
        ]),
      );
      expect(find.text('Strengths and Weaknesses'), findsNothing);
      // The rest of the screen is unaffected.
      expect(find.text('Score Details'), findsOneWidget);
    });

    testWidgets('SUBJECTIVE answers count - maxScore 0 must not zero them', (
      WidgetTester tester,
    ) async {
      // THE TRAP. image_ab carries `maxScore: 0` and puts the mark in
      // `llmScore`/`llmMaxScore`. A denominator read off `maxScore` drops every
      // one and the card vanishes over a fully graded paper.
      await openAttempt(
        tester,
        storeOf(<({Assessment asm, Attempt ev})>[
          sitting(asmId: 'a1', attemptId: 'e1', marks: <bool>[true]),
        ]),
      );
      expect(find.text('Strengths and Weaknesses'), findsOneWidget);
    });
  });

  group('ADMIN - a candidate\'s performance page, from a leaderboard row', () {
    testWidgets('the same card appears, worded for an operator', (
      WidgetTester tester,
    ) async {
      // A leaderboard row navigates to CandidatePerformance, which renders
      // MyPerformanceScreen with a personId - so this is the operator reading
      // the candidate's own view.
      //
      // `meId` MUST BE SOMEBODY ELSE. `isSelf` is `personId == store.meId`, so
      // passing the signed-in user's own id here would exercise the CANDIDATE
      // wording and quietly prove nothing about the operator's.
      final AppStore s = storeOf(<({Assessment asm, Attempt ev})>[
        sitting(
          asmId: 'a1',
          attemptId: 'e1',
          marks: <bool>[true, false],
          // Two categories, so there is a strongest and a weakest to name.
          tagsPer: <List<String>>[kSopTags, kSopTagsAlt],
        ),
      ]);
      s.meId = 'admin1';
      await openPerformance(tester, s, personId: 'p1');

      expect(find.textContaining('Strengths and Weaknesses'), findsWidgets);
      // UPPERCASE: `Kpi` renders its label through `.toUpperCase()`, so the
      // finder has to match what is painted, not what was passed in.
      expect(find.text('NEEDS COACHING'), findsWidgets);
      expect(find.text('STRENGTHS'), findsWidgets);
      expect(find.textContaining('Never changes a mark'), findsWidgets);
    });
  });

  group('CANDIDATE - their own performance page', () {
    testWidgets('the same card, worded for the person it is about', (
      WidgetTester tester,
    ) async {
      // NOTE ON SCOPE. In a widget test the store is handed answers directly, so
      // the card renders. Against a LIVE backend a candidate's own page does not
      // fetch per-answer detail - `/api/v1/attempts/<id>` is a manager route
      // that 403s for them - so their per-assessment breakdown is on "See my
      // answers" instead. What this test pins is the WORDING and the release
      // gate, both of which apply wherever the card is drawn.
      await openPerformance(
        tester,
        storeOf(<({Assessment asm, Attempt ev})>[
          sitting(
            asmId: 'a1',
            attemptId: 'e1',
            marks: <bool>[true, false],
            tagsPer: <List<String>>[kSopTags, kSopTagsAlt],
          ),
        ]),
      );

      expect(find.textContaining('Strengths and Weaknesses'), findsWidgets);
      expect(find.text('WEAKEST AREAS'), findsWidgets);
      expect(find.text('STRENGTHS'), findsWidgets);
      expect(
        find.text('NEEDS COACHING'),
        findsNothing,
        reason: 'operator wording must not reach the candidate',
      );
      // It must not read as a re-mark of work they have already been given.
      expect(find.textContaining('It does not change them'), findsWidgets);
    });

    testWidgets('a HELD sitting leaks no category', (
      WidgetTester tester,
    ) async {
      // Release is the only gate on a candidate seeing their own marks, and a
      // category chart is those marks in aggregate.
      await openPerformance(
        tester,
        storeOf(<({Assessment asm, Attempt ev})>[
          sitting(
            asmId: 'a1',
            attemptId: 'e1',
            marks: <bool>[true, true],
            released: false,
          ),
        ]),
      );
      expect(find.textContaining('Strengths and Weaknesses'), findsNothing);
      // But time is NOT gated - how long you spent is not a mark.
      expect(find.text('Time Taken'), findsWidgets);
    });
  });

  group('The two audiences never see different arithmetic', () {
    testWidgets('the same paper yields the same percentage on both screens', (
      WidgetTester tester,
    ) async {
      // 2 of 5 = 40%. If the operator's screen and the candidate's disagreed,
      // the candidate could not trust either - which is why the maths lives in
      // one function and the card in one widget.
      final List<({Assessment asm, Attempt ev})> rows =
          <({Assessment asm, Attempt ev})>[
            sitting(
              asmId: 'a1',
              attemptId: 'e1',
              marks: <bool>[true, true, false, false, false],
            ),
          ];

      await openPerformance(tester, storeOf(rows));
      expect(find.textContaining('40'), findsWidgets);

      await openAttempt(tester, storeOf(rows));
      expect(find.textContaining('40'), findsWidgets);
    });

    test('and the shared function is what both call', () {
      // Guards the contract directly, off the widgets: 2 of 5 marks is 40%,
      // computed by summing marks rather than averaging percentages.
      final List<CategoryScore> out = categoryScores(<
        ({List<String> tags, double earned, double possible})
      >[
        (tags: <String>['task:x'], earned: 1, possible: 1),
        (tags: <String>['task:x'], earned: 1, possible: 1),
        (tags: <String>['task:x'], earned: 0, possible: 1),
        (tags: <String>['task:x'], earned: 0, possible: 1),
        (tags: <String>['task:x'], earned: 0, possible: 1),
      ]);
      expect(out.single.percent, closeTo(40.0, 0.001));
    });
  });

  group('CANDIDATE - "See my answers" reads the answer sheet', () {
    test('a released sheet yields categories from its rows', () {
      // The sheet route carries no Attempt/Response, so `answersOfSheet` feeds
      // the same maths from the flat rows instead.
      final AnswerSheet sheet = AnswerSheet(
        assessmentName: 'Test 17/8',
        released: true,
        rows: <AnswerSheetRow>[
          const AnswerSheetRow(tags: kSopTags, scoreRaw: 0.9),
          const AnswerSheetRow(tags: kSopTags, scoreRaw: 0.1),
        ],
      );

      final List<CategoryScore> out = categoryScores(answersOfSheet(sheet));
      expect(out.single.tag, 'task:compare-ai-images');
      // 0.9 + 0.1 over 2 answers = 50%.
      expect(out.single.percent, closeTo(50.0, 0.001));
    });

    test('scoreRaw is read as a FRACTION, not a percentage', () {
      // THE 100x TRAP. `score_raw` is 0-1 on this route while `llm_raw_100` is
      // 0-100 elsewhere in the same API. Reading 0.75 as a percentage would
      // render a strong answer as "1%".
      final AnswerSheet sheet = AnswerSheet(
        released: true,
        rows: <AnswerSheetRow>[
          const AnswerSheetRow(tags: kSopTags, scoreRaw: 0.75),
        ],
      );
      expect(
        categoryScores(answersOfSheet(sheet)).single.percent,
        closeTo(75.0, 0.001),
      );
    });

    test('an UNGRADED row contributes nothing rather than a zero', () {
      // Objective answers have no grader score, and a subjective one has none
      // until the grader runs. Counting either as lost marks would show a
      // weakness that is really a queue.
      final AnswerSheet sheet = AnswerSheet(
        released: true,
        rows: <AnswerSheetRow>[
          const AnswerSheetRow(tags: kSopTags, scoreRaw: 1.0),
          const AnswerSheetRow(tags: kSopTags),
        ],
      );
      final List<CategoryScore> out = categoryScores(answersOfSheet(sheet));
      expect(out.single.answers, 1);
      expect(out.single.percent, closeTo(100.0, 0.001));
    });

    test('OBJECTIVE rows count off their TONE, not a grader score', () {
      // THE BUG THIS PINS. mcq/msq answers never carry `score_raw` - no grader
      // runs on them - so reading only that field produced an EMPTY breakdown
      // for an all-MCQ paper where every question had in fact been marked.
      // Found by seeding a 12-question MCQ demo and getting no categories.
      //
      // The server decides the outcome and sends it as `kind`; the parser turns
      // that into a Tone. `pass` -> ok is a mark, `fail` -> bad is not.
      final AnswerSheet sheet = AnswerSheet(
        released: true,
        rows: <AnswerSheetRow>[
          const AnswerSheetRow(tags: kSopTags, tone: Tone.ok),
          const AnswerSheetRow(tags: kSopTags, tone: Tone.ok),
          const AnswerSheetRow(tags: kSopTags, tone: Tone.bad),
          const AnswerSheetRow(tags: kSopTags, tone: Tone.bad),
        ],
      );

      final List<CategoryScore> out = categoryScores(answersOfSheet(sheet));
      expect(out, isNotEmpty, reason: 'an all-MCQ paper still has categories');
      expect(out.single.answers, 4);
      expect(out.single.percent, closeTo(50.0, 0.001));
    });

    test('an INERT objective row is not a zero', () {
      // `inert` is what "Not answered" and "Awaiting grading" arrive as. Scoring
      // them 0 would report a weakness for a question nobody has marked.
      final AnswerSheet sheet = AnswerSheet(
        released: true,
        rows: <AnswerSheetRow>[
          const AnswerSheetRow(tags: kSopTags, tone: Tone.ok),
          const AnswerSheetRow(tags: kSopTags, tone: Tone.inert),
        ],
      );
      final List<CategoryScore> out = categoryScores(answersOfSheet(sheet));
      expect(out.single.answers, 1);
      expect(out.single.percent, closeTo(100.0, 0.001));
    });

    test('a MIXED paper counts both kinds of row once each', () {
      // A real paper can carry both. One subjective at 0.5 plus one objective
      // pass = 1.5 of 2 = 75%.
      final AnswerSheet sheet = AnswerSheet(
        released: true,
        rows: <AnswerSheetRow>[
          const AnswerSheetRow(tags: kSopTags, scoreRaw: 0.5),
          const AnswerSheetRow(tags: kSopTags, tone: Tone.ok),
        ],
      );
      final List<CategoryScore> out = categoryScores(answersOfSheet(sheet));
      expect(out.single.answers, 2);
      expect(out.single.percent, closeTo(75.0, 0.001));
    });

    test('an UNRELEASED sheet has no scores to group, so no categories', () {
      // `AnswerSheetRow.fromJson` gates `scoreRaw` on release, so an unreleased
      // sheet parses with none - and the panel is simply not drawn.
      final AnswerSheet sheet = AnswerSheet(
        released: false,
        rows: <AnswerSheetRow>[
          const AnswerSheetRow(tags: kSopTags),
          const AnswerSheetRow(tags: kSopTags),
        ],
      );
      expect(categoryScores(answersOfSheet(sheet)), isEmpty);
    });

    test('the release gate is enforced by the PARSER, not just the caller', () {
      // Proves the gate lives in `fromJson`: the same payload with
      // `released: false` must drop the grader's number even though it is
      // present on the wire.
      final Map<String, dynamic> wire = <String, dynamic>{
        'index': 1,
        'name': 'Comparing images',
        'question_type': 'image_ab',
        'tags': kSopTags,
        'score_raw': 0.9,
        'verdict': 'Passed',
        'kind': 'pass',
      };

      final AnswerSheetRow open = AnswerSheetRow.fromJson(wire, released: true);
      final AnswerSheetRow held = AnswerSheetRow.fromJson(wire, released: false);

      expect(open.scoreRaw, 0.9);
      expect(held.scoreRaw, isNull, reason: 'a held mark must not reach them');
      expect(held.verdict, '', reason: 'nor the verdict');
      // Tags are NOT gated: a skill name is not a mark.
      expect(held.tags, isNotEmpty);
    });
  });

  group('CategoryCard - the summary tiles', () {
    /// Two categories at the SAME percentage, i.e. a candidate who was
    /// consistent (or perfect) across every category.
    List<CategoryScore> level(double pct) => <CategoryScore>[
      CategoryScore(
        tag: 'skill:pre-shift-inspection',
        earned: pct,
        possible: 100,
        answers: 2,
      ),
      CategoryScore(
        tag: 'skill:load-handling',
        earned: pct,
        possible: 100,
        answers: 3,
      ),
    ];

    testWidgets('a cohort at 100% has no weakness invented for it', (
      WidgetTester tester,
    ) async {
      // THE REGRESSION THIS GROUP EXISTS FOR, restated for the new rule.
      //
      // Ranking named `scores.first` the strongest and `scores.last` the
      // weakest, so an all-level set put ONE category under both headings at
      // once - seen on a real sitting where somebody scored 8/8, which is
      // exactly when the panel should be congratulating them. Splitting on the
      // pass mark cannot do that: a category is on one side of the bar or the
      // other.
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: CategoryCard(
            scores: level(100),
            threshold: 75,
            audience: CategoryAudience.candidate,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Both boxes are present - an empty side is a RESULT, not a missing
      // value, and hiding it would leave the reader to infer it.
      expect(find.text('STRENGTHS'), findsOneWidget);
      expect(find.text('WEAKEST AREAS'), findsOneWidget);
      expect(find.text('Nothing below the pass mark'), findsOneWidget);
      expect(find.byType(BarChart), findsOneWidget);
    });

    testWidgets('a cohort below the bar everywhere has no strength invented', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: CategoryCard(
            scores: level(40),
            threshold: 75,
            audience: CategoryAudience.operator,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // 40% against a 75% bar is a weakness however it ranks. The old rule
      // reported the least-bad of a poor set as the strongest.
      expect(find.text('NEEDS COACHING'), findsOneWidget);
      expect(find.text('Nothing at the pass mark yet'), findsOneWidget);
    });

    testWidgets('the split follows the pass mark, not the ranking', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: CategoryCard(
            scores: <CategoryScore>[
              const CategoryScore(
                tag: 'skill:load-handling',
                earned: 100,
                possible: 100,
                answers: 3,
              ),
              const CategoryScore(
                tag: 'skill:pedestrian-awareness',
                earned: 25,
                possible: 100,
                answers: 2,
              ),
            ],
            threshold: 75,
            audience: CategoryAudience.candidate,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('STRENGTHS'), findsOneWidget);
      expect(find.text('WEAKEST AREAS'), findsOneWidget);
      // One category each side, named rather than counted away.
      expect(find.textContaining('Load Handling'), findsWidgets);
      expect(find.textContaining('Pedestrian Awareness'), findsWidgets);
    });

    testWidgets('a box opens the full list of its side', (
      WidgetTester tester,
    ) async {
      // The point of the change: the tile it replaces named ONE category and
      // dropped the rest, so a cohort weak in three areas was reported as weak
      // in one.
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: CategoryCard(
            scores: <CategoryScore>[
              const CategoryScore(
                tag: 'skill:first',
                earned: 10,
                possible: 100,
                answers: 2,
              ),
              const CategoryScore(
                tag: 'skill:second',
                earned: 20,
                possible: 100,
                answers: 2,
              ),
              const CategoryScore(
                tag: 'skill:third',
                earned: 30,
                possible: 100,
                answers: 2,
              ),
            ],
            threshold: 75,
            audience: CategoryAudience.operator,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // The box names two and says how many more, rather than pretending the
      // third does not exist.
      expect(find.textContaining('+1 more'), findsOneWidget);

      await tester.tap(find.text('NEEDS COACHING'));
      await tester.pumpAndSettle();

      // Every one of the three is in the sheet, with its own percentage.
      expect(find.textContaining('First'), findsWidgets);
      expect(find.textContaining('Second'), findsWidgets);
      expect(find.textContaining('Third'), findsWidgets);
      expect(find.textContaining('30.0%'), findsWidgets);
    });
  });
}
