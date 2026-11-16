// A candidate name is a link, and WHERE it goes depends on where you are.
//
// THE GAP THIS EXISTS FOR. Every candidate name in the console led to one
// sitting, or to nothing at all:
//
//   - Leaderboard rendered the name as inert `Text`, so the tab that ranks a
//     cohort was the one tab you could not open a candidate from - while
//     Candidates, one tab to its left, linked the same person;
//   - All responses spans every assessment, but its rows only ever opened a
//     single answer, so "how has this person done overall" had no screen.
//
// The rule the two now follow: an assessment's own tabs stay scoped to that
// assessment and open the ATTEMPT. All responses already spans the console, so
// its name column opens the CANDIDATE and their whole history.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/candidate_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/responses_screen.dart';
import 'package:ethara_assessment/assessment/screens/member/my_performance_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Future<void> setSurface(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1800, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget mount(Widget child, AssessmentNav nav) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: AssessmentNavScope(nav: nav, child: child)),
);

/// All responses arrives GROUPED (Assessment > Candidate), and a depth-1 group
/// is closed - so the candidate's name on screen is a group HEADER and the row
/// underneath it is not built at all. Flatten first, or a tap on "the name"
/// only toggles a disclosure.
Future<void> ungroup(WidgetTester tester) async {
  await tester.tap(find.text('Assessment > Candidate').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('No grouping').last);
  await tester.pumpAndSettle();
}

/// One admin attempt row, in `evaluator_admin_row`'s own shape.
Map<String, dynamic> attemptRow({
  required String id,
  required String asmId,
  required String asmName,
  required String candidateId,
  required String candidate,
  required String submittedAt,
  String result = 'pass',
  bool released = true,
  String marks = '8 / 10',
}) => <String, dynamic>{
  'id': id,
  'assessment_id': asmId,
  'assessment_name': asmName,
  'candidate': <String, dynamic>{'id': candidateId, 'name': candidate},
  'state': 'submitted',
  'is_locked': true,
  'submitted_at': submittedAt,
  'answered_count': 10,
  'total_questions': 10,
  'score_marks': marks,
  'result': result,
  'results_released': released,
};

/// Two candidates, four sittings between them, across three assessments.
AppStore seeded() {
  final AppStore s = AppStore();
  s.people = <Person>[
    const Person(id: 'p1', name: 'Anita Rao', email: 'anita@example.com'),
    const Person(id: 'p2', name: 'Zubin Mehta', email: 'zubin@example.com'),
  ];
  // `done`, not the default draft: the Leaderboard tab is disabled on a draft,
  // which is correct - nothing has been sat - and would leave that test poking
  // at a tab the screen deliberately never builds.
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 'a1',
      'name': 'Text to Image',
      'state': 'done',
    }),
    Assessment.fromJson(<String, dynamic>{
      'id': 'a2',
      'name': 'Forklift',
      'state': 'done',
    }),
    Assessment.fromJson(<String, dynamic>{
      'id': 'a3',
      'name': 'SOP Induction',
      'state': 'done',
    }),
  ];
  s.attempts = <Attempt>[
    Attempt.fromJson(
      attemptRow(
        id: '11',
        asmId: 'a1',
        asmName: 'Text to Image',
        candidateId: 'p1',
        candidate: 'Anita Rao',
        submittedAt: '2026-07-14 09:00:00',
        marks: '3 / 10',
        result: 'fail',
      ),
    ),
    Attempt.fromJson(
      attemptRow(
        id: '12',
        asmId: 'a2',
        asmName: 'Forklift',
        candidateId: 'p1',
        candidate: 'Anita Rao',
        submittedAt: '2026-08-13 09:00:00',
      ),
    ),
    Attempt.fromJson(
      attemptRow(
        id: '13',
        asmId: 'a3',
        asmName: 'SOP Induction',
        candidateId: 'p1',
        candidate: 'Anita Rao',
        submittedAt: '2026-08-02 09:00:00',
        released: false,
      ),
    ),
    Attempt.fromJson(
      attemptRow(
        id: '21',
        asmId: 'a1',
        asmName: 'Text to Image',
        candidateId: 'p2',
        candidate: 'Zubin Mehta',
        submittedAt: '2026-08-13 09:00:00',
      ),
    ),
  ];
  return s;
}

void main() {
  group('attemptsByCandidate is strict and newest first', () {
    test('it returns only that candidate, newest sitting first', () {
      final AppStore s = seeded();
      final List<Attempt> mine = s.attemptsByCandidate('p1');

      expect(mine.map((Attempt a) => a.id).toList(), <String>['12', '13', '11']);
    });

    test('an UNOWNED attempt is not swept in', () {
      // `attemptsForPerson` deliberately matches an empty `employeeId`, because
      // a candidate's own `/me/assessments` rows carry no `candidate` object.
      // On an admin screen that same concession would put an attempt belonging
      // to nobody-known onto a named person's page.
      final AppStore s = seeded();
      s.attempts = <Attempt>[
        ...s.attempts,
        Attempt.fromJson(<String, dynamic>{
          'id': '99',
          'assessment_id': 'a1',
          'state': 'submitted',
        }),
      ];

      expect(
        s.attemptsByCandidate('p1').map((Attempt a) => a.id),
        isNot(contains('99')),
        reason: "an attempt with no candidate is not this candidate's",
      );
      expect(
        s.attemptsForPerson('p1').map((Attempt a) => a.id),
        contains('99'),
        reason: 'the candidate-portal helper keeps its own rule',
      );
    });
  });

  group('All responses opens the PERSON from the name', () {
    testWidgets('the name pushes the candidate, not the answer', (
      WidgetTester tester,
    ) async {
      await setSurface(tester);
      final AppStore s = seeded();
      s.responseRows = <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 1,
          'evaluator_id': '11',
          'assessment_id': 'a1',
          'assessment_name': 'Text to Image',
          'question_id': 'q1',
          'question_name': 'Alpha severity',
          'question_type': 'mcq',
          'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita Rao'},
          'score': 1,
          'max_score': 1,
          'llm_state': 'not_needed',
          'state': 'submitted',
        },
      ];
      final AssessmentNav nav = AssessmentNav();

      await tester.pumpWidget(mount(ResponsesScreen(store: s), nav));
      await tester.pumpAndSettle();
      await ungroup(tester);

      await tester.tap(find.text('Anita Rao').first);
      await tester.pumpAndSettle();

      expect(
        nav.current,
        isA<CandidateDetail>().having(
          (CandidateDetail r) => r.personId,
          'personId',
          'p1',
        ),
        reason:
            'this list already spans every assessment, so the name is where '
            'the whole history is asked for',
      );
    });

    testWidgets('the rest of the row still opens the answer', (
      WidgetTester tester,
    ) async {
      await setSurface(tester);
      final AppStore s = seeded();
      s.responseRows = <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 1,
          'evaluator_id': '11',
          'assessment_id': 'a1',
          'assessment_name': 'Text to Image',
          'question_id': 'q1',
          'question_name': 'Alpha severity',
          'question_type': 'mcq',
          'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita Rao'},
          'score': 1,
          'max_score': 1,
          'llm_state': 'not_needed',
          'state': 'submitted',
        },
      ];
      final AssessmentNav nav = AssessmentNav();

      await tester.pumpWidget(mount(ResponsesScreen(store: s), nav));
      await tester.pumpAndSettle();
      await ungroup(tester);

      // The question cell: same row, and it must keep the row's destination.
      await tester.tap(find.text('Alpha severity').first);
      await tester.pumpAndSettle();

      expect(
        nav.current,
        isA<ResponseDetail>()
            .having((ResponseDetail r) => r.attemptId, 'attemptId', '11')
            .having((ResponseDetail r) => r.questionId, 'questionId', 'q1'),
        reason: 'two targets in one cell must not cost the row its own',
      );
    });
  });

  group('The Leaderboard name opens that sitting', () {
    testWidgets('a ranked name pushes the attempt', (
      WidgetTester tester,
    ) async {
      await setSurface(tester);
      final AppStore s = seeded();
      final AssessmentNav nav = AssessmentNav();

      await tester.pumpWidget(
        mount(
          AssessmentDetailScreen(
            store: s,
            portal: Portal.admin,
            asmId: 'a1',
            tab: 'leaderboard',
          ),
          nav,
        ),
      );
      await tester.pumpAndSettle();

      // Released results only, so Anita's fail and Zubin's pass both rank.
      await tester.tap(find.text('Anita Rao').first);
      await tester.pumpAndSettle();

      expect(
        nav.current,
        isA<AttemptDetail>().having((AttemptDetail r) => r.id, 'id', '11'),
        reason:
            'inside an assessment the scope is that assessment: the name '
            'opens the sitting, exactly as the Candidates tab does',
      );
    });
  });

  group('The candidate screen shows every assessment they sat', () {
    testWidgets('and nobody else\'s', (WidgetTester tester) async {
      await setSurface(tester);
      final AppStore s = seeded();
      final AssessmentNav nav = AssessmentNav();

      await tester.pumpWidget(
        mount(CandidateDetailScreen(store: s, personId: 'p1'), nav),
      );
      await tester.pumpAndSettle();

      expect(find.text('Anita Rao'), findsWidgets);
      expect(find.text('Text to Image'), findsOneWidget);
      expect(find.text('Forklift'), findsOneWidget);
      expect(find.text('SOP Induction'), findsOneWidget);

      // Zubin also sat 'Text to Image'. His row must not be here, and the
      // count in the sub-line is what says so.
      expect(
        find.textContaining('3 assessment(s) sat'),
        findsOneWidget,
        reason: 'p1 sat three; p2 sat one, and it is not on this page',
      );
    });

    testWidgets('an unreleased sitting is not counted as passed', (
      WidgetTester tester,
    ) async {
      // A mark nobody has been shown is not yet a verdict. Rolling it into
      // "passed" would report an outcome the candidate has not been told.
      await setSurface(tester);
      final AppStore s = seeded();
      final AssessmentNav nav = AssessmentNav();

      await tester.pumpWidget(
        mount(CandidateDetailScreen(store: s, personId: 'p1'), nav),
      );
      await tester.pumpAndSettle();

      // p1: one released pass (Forklift), one released fail (Text to Image),
      // one held (SOP Induction).
      expect(find.text('of 2 released'), findsOneWidget);
      expect(find.text('submitted, marks held'), findsOneWidget);
    });

    testWidgets('a row opens that sitting', (WidgetTester tester) async {
      await setSurface(tester);
      final AppStore s = seeded();
      final AssessmentNav nav = AssessmentNav();

      await tester.pumpWidget(
        mount(CandidateDetailScreen(store: s, personId: 'p1'), nav),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Forklift'));
      await tester.pumpAndSettle();

      expect(
        nav.current,
        isA<AttemptDetail>().having((AttemptDetail r) => r.id, 'id', '12'),
      );
    });

    testWidgets('a person with no attempts says so rather than blanking', (
      WidgetTester tester,
    ) async {
      await setSurface(tester);
      final AppStore s = seeded();
      final AssessmentNav nav = AssessmentNav();

      await tester.pumpWidget(
        mount(CandidateDetailScreen(store: s, personId: 'p2-unknown'), nav),
      );
      await tester.pumpAndSettle();

      expect(find.text('Candidate not found'), findsOneWidget);
    });
  });

  group("An operator reading a candidate's performance page", () {
    // THE BUG THIS EXISTS FOR. The dashboard leaderboard now opens the
    // candidate's own performance page for whoever was clicked. Its score
    // breakdown sent every row to the candidate's EXAM surface - the answer
    // review, or the completion card - and those are scoped to the signed-in
    // user and gated on release. An admin clicking a row whose result was
    // plainly released therefore landed on "Results not released yet": the
    // gate answering about the ADMIN, who never sat the exam. It reads as the
    // page being broken.
    testWidgets('a breakdown row opens the attempt, not the exam', (
      WidgetTester tester,
    ) async {
      await setSurface(tester);
      final AppStore s = seeded();
      // Anybody but Anita: this is the operator case.
      s.meId = 'admin-1';
      final AssessmentNav nav = AssessmentNav();

      await tester.pumpWidget(
        mount(MyPerformanceScreen(store: s, personId: 'p1'), nav),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Text to Image').first);
      await tester.pumpAndSettle();

      expect(
        nav.current,
        isA<AttemptDetail>().having((AttemptDetail r) => r.id, 'id', '11'),
        reason:
            "an operator gets the operator's view of that sitting, never the "
            "candidate's release-gated exam screen",
      );
    });

    testWidgets('the candidate still goes to their own exam surface', (
      WidgetTester tester,
    ) async {
      await setSurface(tester);
      final AppStore s = seeded();
      // Anita reading her own page - personId omitted, exactly as the member
      // rail constructs it.
      s.meId = 'p1';
      final AssessmentNav nav = AssessmentNav();

      await tester.pumpWidget(mount(MyPerformanceScreen(store: s), nav));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Text to Image').first);
      await tester.pumpAndSettle();

      expect(
        nav.current,
        isA<Exam>(),
        reason: 'the candidate path is unchanged',
      );
    });

    testWidgets('the page is not written in the second person', (
      WidgetTester tester,
    ) async {
      await setSurface(tester);
      final AppStore s = seeded();
      s.meId = 'admin-1';

      await tester.pumpWidget(
        mount(MyPerformanceScreen(store: s, personId: 'p1'), AssessmentNav()),
      );
      await tester.pumpAndSettle();

      // The copy belongs to the person who sat the exam. An operator is not
      // that person, so "you"/"your" on this page is addressing the wrong one.
      expect(find.textContaining('you submitted'), findsNothing);
      expect(find.textContaining('you have submitted'), findsNothing);
      expect(find.textContaining('Your marks'), findsNothing);
      expect(find.text('Anita Rao'), findsWidgets);
    });
  });
}
