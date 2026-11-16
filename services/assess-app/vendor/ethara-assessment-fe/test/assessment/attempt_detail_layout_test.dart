// Attempt detail fits, and every value on it is readable.
//
// THE BUG: `State` sat in the Result panel's KPI row as a fifth card. A KPI
// card is a numeral in a display size on a fixed 100px height, so the word
// "Submitted" rendered oversized and then ellipsised to "Subm..." - the one
// value on the row nobody could read - and five cards over a four-across grid
// orphaned it on a second row of its own.
//
// A status is not a count. It belongs beside the rest of the sitting, in the
// Session panel, as a pill. This pins that, and pins the layout it was
// breaking: four cards, one row, no overflow at a laptop width.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/marks.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';

Widget mount(Widget child, AssessmentNav nav) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: AssessmentNavScope(nav: nav, child: child),
  ),
);

/// A submitted, released, passing sitting - the shape in the screenshot this
/// was reported from: ten answers, ten marks, nothing unresolved.
AppStore seeded() {
  final AppStore s = AppStore();
  s.people = <Person>[
    const Person(id: 'p1', name: 'Anita Rao', email: 'anita@example.com'),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 'a1',
      'name': 'ETP Assessment Pro',
      'state': 'done',
      'subjective_threshold': 60.0,
      'questions': <dynamic>[
        for (int i = 1; i <= 10; i++)
          <String, dynamic>{
            'id': 'q$i',
            'name': 'Question $i',
            'question_type': 'mcq',
          },
      ],
    }),
  ];
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': '80',
      'assessment_id': 'a1',
      'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita Rao'},
      'state': 'submitted',
      'is_locked': true,
      'invite_state': 'sent',
      'started_at': '2026-08-13 11:34:00',
      'submitted_at': '2026-08-13 11:41:00',
      'answered_count': 10,
      'total_questions': 10,
      'score_marks': '10 / 10',
      'result': 'pass',
      'pass_threshold': 60.0,
      'results_released': true,
      'access_token': '6df2026a-4d70-42fd-b8c3-144b01ce97da',
    }),
  ];
  return s;
}

Future<void> open(WidgetTester t, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    mount(
      AttemptDetailScreen(
        store: seeded(),
        portal: Portal.admin,
        attemptId: '80',
      ),
      AssessmentNav(),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('the sitting state is a pill, not a truncated KPI', (
    WidgetTester t,
  ) async {
    await open(t, const Size(1800, 3000));

    // Spelled in full. The ellipsised card rendered the string "Subm…",
    // so asserting on the whole word is exactly the assertion that failed.
    expect(find.text('Submitted'), findsWidgets);
    expect(
      find.widgetWithText(Pill, 'Submitted'),
      findsOneWidget,
      reason: 'a lifecycle state reads as a status, not as a number',
    );

    // And it is NOT one of the counts any more.
    for (final Element e in find.byType(Kpi).evaluate()) {
      expect((e.widget as Kpi).label, isNot('State'));
    }
  });

  testWidgets('the invitation state is a pill too', (WidgetTester t) async {
    await open(t, const Size(1800, 3000));

    // Plain text carried no tone, so a FAILED invitation - the reason a
    // sitting never started - read exactly like a delivered one.
    expect(find.widgetWithText(Pill, 'Sent'), findsOneWidget);
  });

  testWidgets('four count cards, and they share one row', (
    WidgetTester t,
  ) async {
    await open(t, const Size(1800, 3000));

    final List<Kpi> cards = find
        .byType(Kpi)
        .evaluate()
        .map((Element e) => e.widget as Kpi)
        .toList();
    expect(cards.length, 4);
    expect(cards.map((Kpi k) => k.label).toList(), <String>[
      'Answered',
      'Violations',
      'Unresolved',
      'Auto-submitted',
    ]);

    // One row: every card on the same vertical offset. The fifth card was
    // below the other four, which is what made the panel look broken.
    final Set<double> tops = find
        .byType(Kpi)
        .evaluate()
        .map((Element e) => t.getTopLeft(find.byWidget(e.widget)).dy)
        .toSet();
    expect(tops.length, 1, reason: 'a card wrapped onto a row of its own');
  });

  // THE SECOND BUG on the same panel. The module keeps a mark in two places:
  // `_compute_score` short-circuits to 0 / 0 for anything that is not mcq or
  // msq, and a graded answer's mark lands in `llm_score` instead. "Score
  // details" printed `score` for every row, so a ten-question attempt with
  // five graded answers showed five rows of "0" directly underneath its own
  // ring reading 10 / 10.
  group('a mark is the mark, whichever half of the module scored it', () {
    /// One `response_audit` row in the module's own shape - the two score
    /// pairs kept apart exactly as `response_row` sends them.
    Map<String, dynamic> answer({
      required String qid,
      required bool objective,
      required int awarded,
    }) => <String, dynamic>{
      'question_id': qid,
      'state': 'submitted',
      'has_objective': objective,
      'needs_llm': !objective,
      'score': objective ? awarded : 0,
      'max_score': objective ? 1 : 0,
      'llm_score': objective ? 0 : awarded,
      'llm_max_score': objective ? 0 : 1,
      'llm_state': objective ? 'not_needed' : 'scored',
      'llm_raw_100': objective ? 0.0 : 100.0,
    };

    test('a graded answer reports the mark it earned, not zero', () {
      final Response graded = Response.fromJson(
        answer(qid: 'q1', objective: false, awarded: 1),
      );
      expect(graded.score, 0, reason: 'the objective half really is 0');
      expect(graded.mark, 1);
      expect(graded.markOutOf, 1);

      final Response objective = Response.fromJson(
        answer(qid: 'q2', objective: true, awarded: 1),
      );
      expect(objective.mark, 1);
      expect(objective.markOutOf, 1);
    });

    test('a seed fixture, which states neither half, still reads `score`', () {
      // The fixtures carry no `has_objective` and put the real mark in `score`
      // whatever the type, so the default has to be the objective branch.
      final Response seeded = Response.fromJson(<String, dynamic>{'score': 1});
      expect(seeded.mark, 1);
    });

    test('the local marks walk agrees with the server total', () {
      final Assessment asm = Assessment.fromJson(<String, dynamic>{
        'id': 'a1',
        'questions': <dynamic>[
          for (int i = 1; i <= 4; i++) <String, dynamic>{'id': 'q$i'},
        ],
      });
      // Two objective, two graded, all four earned. No `score_marks`, so
      // `earnedMarks` has to walk the answers itself - the path that summed
      // the objective half alone and reported 2 of 4 on a full paper.
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': '1',
        'assessment_id': 'a1',
        'state': 'submitted',
        'answers': <dynamic>[
          answer(qid: 'q1', objective: true, awarded: 1),
          answer(qid: 'q2', objective: true, awarded: 1),
          answer(qid: 'q3', objective: false, awarded: 1),
          answer(qid: 'q4', objective: false, awarded: 1),
        ],
      });

      expect(ev.earnedMarks(asm), 4);
    });
  });

  // THE SAME BUG AGAIN, on the card that stayed. "Auto-submitted" is the one
  // count on the row whose value is a WORD, and at the numeral's display size
  // "Time out" ellipsised to "Time ..." - a reviewer could not tell a paper
  // that ran out of time from one the proctor ended.
  //
  // NOT MEASURED IN A WIDGET TEST. `flutter test` paints in a test font whose
  // every glyph is a full em square, so a rendered-width assertion measures
  // the harness rather than the typeface and fails on strings that fit fine.
  // Same reason `kpi_sub_length_test` budgets characters from the source.
  group('the auto-submit reason is a word, and it is readable', () {
    testWidgets('so the card asks for the word size', (WidgetTester t) async {
      await open(t, const Size(1800, 3000));
      final Kpi card = find
          .byType(Kpi)
          .evaluate()
          .map((Element e) => e.widget as Kpi)
          .firstWhere((Kpi k) => k.label == 'Auto-submitted');
      expect(card.word, isTrue);

      // And the counts beside it are numerals, which keep the mono display
      // size - this is one card's fix, not a shrink of the whole row.
      for (final Element e in find.byType(Kpi).evaluate()) {
        final Kpi k = e.widget as Kpi;
        if (k.label != 'Auto-submitted') expect(k.word, isFalse);
      }
    });

    // VM ONLY, and tagged per-test rather than per-file. This one reads the
    // SOURCE TREE through dart:io; under `--platform chrome` there is no
    // filesystem, so it failed with "Unsupported operation: _Namespace" - a
    // harness limit, not a defect. Its siblings that scrape source carry a
    // file-level `@TestOn('vm')` (see kpi_sub_length_test), but that would
    // also pull the widget tests in this file off chrome, and those are
    // exactly the ones that catch web-only breakage: Flutter web paints to a
    // canvas, so an ellipsised value still reports its FULL text to the DOM.
    test('and no reason it can print is long enough to truncate', () {
      // A card is never narrower than the grid's 120px threshold, less 2*14
      // of internal padding = 92px of text. `kpiValueWord` renders at 17px,
      // averaging ~0.51em per character in this typeface, which is ~10. The
      // longest reason today is "Violations", exactly 10 - so this is a
      // tripwire on adding an eleventh character, not slack to spend.
      const int maxValueChars = 10;

      final List<String> arms = RegExp(r'\(true, .*?\) => ')
          .allMatches(
            File(
              'lib/assessment/screens/admin/attempt_detail_screen.dart',
            ).readAsStringSync(),
          )
          .map((RegExpMatch m) => m.input.substring(m.end))
          .map(
            (String rest) => RegExp(r"^'([^']*)'").firstMatch(rest)?.group(1),
          )
          .whereType<String>()
          .toList();

      expect(arms, isNotEmpty, reason: 'the auto-submit switch moved');
      expect(arms, contains('Time out'));
      for (final String value in arms) {
        expect(
          value.length,
          lessThanOrEqualTo(maxValueChars),
          reason:
              '"$value" will ellipsise in a 120px card, and a canvas-painted '
              'ellipsis is invisible to every DOM check',
        );
      }
    }, testOn: 'vm');
  });

  testWidgets('it fits a laptop without an overflow stripe', (
    WidgetTester t,
  ) async {
    // 1280 logical px with the console's own rail already taken out of it -
    // narrow enough that the Session panel's key/value rows are the tightest
    // thing on the page, and the exam token is 36 characters that cannot be
    // shortened by choosing better words.
    await open(t, const Size(1180, 2400));

    // An overflow is reported as an exception during layout, so a clean pump
    // IS the assertion.
    expect(t.takeException(), isNull);
    expect(find.widgetWithText(Pill, 'Submitted'), findsOneWidget);
  });
}
