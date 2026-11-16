// All responses opens as a VIEW, not as a pile.
//
// The screen used to arrive as one flat list of every answer in the org, under
// four selects that between them offered mostly dead ends: every assessment
// whether or not it had answers, every question type whether or not one had
// been sat, and a "No flag filter" select whose four options included one that
// merely repeated the scoring-state select next to it. Nothing sorted, and the
// search box read two fields out of the fifteen on the row - so searching an
// assessment, a type, a state or the text of an answer all reported "no answers
// match those filters" over data that was on the screen.
//
// This pins the behaviour a reviewer actually needs: grouped on arrival the way
// the module's own Odoo list is, filters that only offer what exists, every
// column ordered both ways, and one search box that reads the whole row.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/screens/admin/responses_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// `flutter_test` pins the window to 800x600, which is narrower than this
/// table's own minimum - the grid then scrolls sideways and half the columns
/// are off-screen for every finder. Resized for real, as the other console
/// screen tests do.
Future<void> setSurface(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1800, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// One row of `GET /api/v1/responses`, which is the shape this screen reads.
Map<String, dynamic> row({
  required int id,
  required int evaluator,
  required String asmId,
  required String asmName,
  required String candidateId,
  required String candidate,
  required String question,
  required String type,
  required int score,
  String state = 'not_needed',
}) => <String, dynamic>{
  'id': id,
  'evaluator_id': evaluator,
  'assessment_id': asmId,
  'assessment_name': asmName,
  'question_id': 'q$id',
  'question_name': question,
  'question_type': type,
  'candidate': <String, dynamic>{'id': candidateId, 'name': candidate},
  'score': score,
  'max_score': 1,
  'llm_state': state,
  'needs_llm': state != 'not_needed',
  'state': 'submitted',
};

/// Two assessments, two candidates, three question types, two scoring states.
/// Small enough to assert on by name, wide enough that every control has
/// something to do.
AppStore seeded() {
  final AppStore s = AppStore();
  s.people = <Person>[
    const Person(id: 'p1', name: 'Anita Rao', email: 'anita@example.com'),
    const Person(id: 'p2', name: 'Zubin Mehta', email: 'zubin@example.com'),
  ];
  s.responseRows = <Map<String, dynamic>>[
    row(
      id: 1,
      evaluator: 11,
      asmId: 'a1',
      asmName: 'Text to Image Assessment',
      candidateId: 'p1',
      candidate: 'Anita Rao',
      question: 'Alpha artifact severity',
      type: 'mcq',
      score: 1,
    ),
    row(
      id: 2,
      evaluator: 11,
      asmId: 'a1',
      asmName: 'Text to Image Assessment',
      candidateId: 'p1',
      candidate: 'Anita Rao',
      question: 'Zulu justification writing',
      type: 'subjective_rubric',
      score: 0,
      state: 'error',
    ),
    row(
      id: 3,
      evaluator: 12,
      asmId: 'a1',
      asmName: 'Text to Image Assessment',
      candidateId: 'p2',
      candidate: 'Zubin Mehta',
      question: 'Mid prompt deconstruction',
      type: 'msq',
      score: 1,
    ),
    row(
      id: 4,
      evaluator: 13,
      asmId: 'a2',
      asmName: 'Warehouse Safety Induction',
      candidateId: 'p2',
      candidate: 'Zubin Mehta',
      question: 'Pedestrian near miss',
      type: 'mcq',
      score: 0,
    ),
  ];
  return s;
}

Future<void> open(WidgetTester t, AppStore s) async {
  await setSurface(t);
  await t.pumpWidget(host(ResponsesScreen(store: s)));
  await t.pumpAndSettle();
}

/// Pick the group-by / filter select carrying [current] and choose [option].
Future<void> choose(WidgetTester t, String current, String option) async {
  await t.tap(find.text(current).last);
  await t.pumpAndSettle();
  await t.tap(find.text(option).last);
  await t.pumpAndSettle();
}

Future<void> search(WidgetTester t, String q) async {
  await t.enterText(find.byType(SearchField), q);
  await t.pumpAndSettle();
}

/// Whether [text] is on screen, for readability at the call sites below.
bool shown(String text) => find.text(text).evaluate().isNotEmpty;

void main() {
  group('it opens grouped by assessment', () {
    testWidgets('both assessments are groups, and they carry their counts', (
      WidgetTester t,
    ) async {
      final AppStore s = seeded();
      await open(t, s);

      expect(t.takeException(), isNull);
      expect(shown('Text to Image Assessment'), isTrue);
      expect(shown('Warehouse Safety Induction'), isTrue);
      // Three answers in one, one in the other.
      expect(shown('(3)'), isTrue);
      expect(shown('(1)'), isTrue);
    });

    testWidgets('the footer pages over GROUPS, and says so', (
      WidgetTester t,
    ) async {
      await open(t, seeded());

      expect(find.textContaining('of 2 groups'), findsOneWidget);
    });

    testWidgets('it fits a laptop, with six cards and two toolbar rows', (
      WidgetTester t,
    ) async {
      // The controls grew: six KPI cards and a second toolbar row. A RenderFlex
      // overflow is a test failure here, which is the point - the previous
      // toolbar fitted five controls into one Row by squeezing each of them to
      // an unreadable stub, and nothing failed.
      t.view.physicalSize = const Size(1280, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(host(ResponsesScreen(store: seeded())));
      await t.pumpAndSettle();

      expect(t.takeException(), isNull);
      expect(shown('Text to Image Assessment'), isTrue);
    });

    testWidgets('the top level is open and the second level is not', (
      WidgetTester t,
    ) async {
      await open(t, seeded());

      // Exactly the reference view: assessments open, the candidates inside
      // them listed, and no answers until one is asked for. Opening every
      // level would put the flat list back with extra headers in it; opening
      // none would hide the candidates the screen is grouped by.
      expect(shown('Anita Rao'), isTrue);
      expect(shown('Zubin Mehta'), isTrue);
      expect(shown('Alpha artifact severity'), isFalse);
    });

    testWidgets('a candidate bucket opens to its answers', (
      WidgetTester t,
    ) async {
      await open(t, seeded());

      await t.tap(find.text('Anita Rao'));
      await t.pumpAndSettle();

      expect(shown('Alpha artifact severity'), isTrue);
      expect(shown('Zulu justification writing'), isTrue);
      // Somebody else's answers stay where they were.
      expect(shown('Mid prompt deconstruction'), isFalse);
    });

    testWidgets('a top-level group closes, and STAYS closed', (
      WidgetTester t,
    ) async {
      await open(t, seeded());

      await t.tap(find.text('Warehouse Safety Induction'));
      await t.pumpAndSettle();
      // Its only candidate goes with it; Zubin's row under the other
      // assessment does not.
      expect(find.text('Zubin Mehta'), findsOneWidget);

      await t.tap(find.text('Warehouse Safety Induction'));
      await t.pumpAndSettle();
      // The bug two sets of state exist to prevent: one set cannot tell "never
      // touched" from "deliberately closed", so a closed top-level group
      // snapped back open on the next rebuild.
      expect(find.text('Zubin Mehta'), findsNWidgets(2));
    });

    testWidgets('grouping can be turned off entirely', (WidgetTester t) async {
      await open(t, seeded());

      await choose(t, 'Assessment > Candidate', 'No grouping');

      // Every answer, no headers, no expanding.
      expect(shown('Alpha artifact severity'), isTrue);
      expect(shown('Pedestrian near miss'), isTrue);
      expect(find.textContaining('of 2 groups'), findsNothing);
    });
  });

  group('search reads the whole row', () {
    testWidgets('an assessment name narrows the list', (WidgetTester t) async {
      await open(t, seeded());
      await choose(t, 'Assessment > Candidate', 'No grouping');

      await search(t, 'warehouse');

      expect(shown('Pedestrian near miss'), isTrue);
      expect(shown('Alpha artifact severity'), isFalse);
      expect(shown('1 OF 4'), isTrue);
    });

    testWidgets('so does a question type and a scoring state', (
      WidgetTester t,
    ) async {
      await open(t, seeded());
      await choose(t, 'Assessment > Candidate', 'No grouping');

      // The TYPE label, which no field on the row spells out.
      await search(t, 'rubric');
      expect(shown('Zulu justification writing'), isTrue);
      expect(shown('Alpha artifact severity'), isFalse);

      // The scoring state, which is a pill rather than text.
      await search(t, 'scoring error');
      expect(shown('Zulu justification writing'), isTrue);
      expect(shown('1 OF 4'), isTrue);
    });

    testWidgets('every term has to land, in any field', (WidgetTester t) async {
      await open(t, seeded());
      await choose(t, 'Assessment > Candidate', 'No grouping');

      // Candidate AND type: two facets a person already knows, in one box.
      await search(t, 'zubin mcq');
      expect(shown('Pedestrian near miss'), isTrue);
      expect(shown('Mid prompt deconstruction'), isFalse);

      await search(t, 'zubin nonsense');
      expect(
        find.textContaining('No answers match those filters'),
        findsOneWidget,
      );
    });
  });

  group('the filters only offer what exists', () {
    testWidgets('question types absent from the data are not listed', (
      WidgetTester t,
    ) async {
      await open(t, seeded());

      await t.tap(find.text('All question types'));
      await t.pumpAndSettle();

      // Present, with its count.
      expect(find.textContaining('Objective · MCQ (2)'), findsWidgets);
      // Nothing has been sat with these, so offering them could only ever
      // produce an empty table.
      //
      // ASSERTED THROUGH THE ENUM, not against hand-typed display text. These
      // were literals ('Image · Labelling'), and a literal in an
      // absence assertion rots silently: renaming the label to
      // 'Image · Annotation' left this passing for the wrong reason - the
      // string it looked for no longer existed anywhere, so it would have kept
      // passing with the filter listing every type in the app.
      expect(find.textContaining(QType.videoPrompt.label), findsNothing);
      expect(find.textContaining(QType.imageLabel.label), findsNothing);
    });

    testWidgets('assessments are listed with their answer counts', (
      WidgetTester t,
    ) async {
      await open(t, seeded());

      expect(find.text('All assessments (4)'), findsOneWidget);
    });

    testWidgets('a KPI card is the filter for what it counts', (
      WidgetTester t,
    ) async {
      await open(t, seeded());
      await choose(t, 'Assessment > Candidate', 'No grouping');

      expect(shown('Alpha artifact severity'), isTrue);

      // "Scored zero" counts the one AWARDED zero; pressing it keeps it.
      // Zulu's 0 is an errored grade nobody awarded: it is Unresolved, not a
      // mark (stage, 2026-10-13: ungraded answers were counted as zeros).
      expect(
        t
            .widgetList<Kpi>(find.byType(Kpi))
            .singleWhere((Kpi k) => k.label == 'Scored zero')
            .value,
        '1',
      );
      await t.tap(find.text('SCORED ZERO'));
      await t.pumpAndSettle();

      expect(shown('Zulu justification writing'), isFalse);
      expect(shown('Pedestrian near miss'), isTrue);
      expect(shown('Alpha artifact severity'), isFalse);
      expect(shown('filtering this list - click to clear'), isTrue);

      // And pressing it again lets go.
      await t.tap(find.text('SCORED ZERO'));
      await t.pumpAndSettle();
      expect(shown('Alpha artifact severity'), isTrue);
    });

    testWidgets('clearing filters restores everything', (WidgetTester t) async {
      await open(t, seeded());
      await choose(t, 'Assessment > Candidate', 'No grouping');
      await search(t, 'warehouse');

      expect(shown('1 OF 4'), isTrue);

      await t.tap(find.text('Clear Filters'));
      await t.pumpAndSettle();

      expect(shown('4 OF 4'), isTrue);
      expect(find.text('Clear Filters'), findsNothing);
    });
  });

  group('every column with data behind it orders the table', () {
    /// Where a row sits vertically. Position is the honest assertion for an
    /// ordering: it is what the reader is actually comparing.
    double y(String text) => find.text(text).evaluate().isEmpty
        ? double.nan
        : (find.text(text).evaluate().first.renderObject as RenderBox)
              .localToGlobal(Offset.zero)
              .dy;

    testWidgets('question sorts A-Z, then Z-A, then back to arrival order', (
      WidgetTester t,
    ) async {
      await open(t, seeded());
      await choose(t, 'Assessment > Candidate', 'No grouping');

      // Arrival order: Alpha, Zulu, Mid, Pedestrian.
      expect(
        y('Zulu justification writing') < y('Mid prompt deconstruction'),
        isTrue,
      );

      await t.tap(find.text('QUESTION'));
      await t.pumpAndSettle();
      expect(
        y('Alpha artifact severity') < y('Mid prompt deconstruction'),
        isTrue,
      );
      expect(
        y('Mid prompt deconstruction') < y('Zulu justification writing'),
        isTrue,
      );

      await t.tap(find.text('QUESTION'));
      await t.pumpAndSettle();
      expect(
        y('Zulu justification writing') < y('Mid prompt deconstruction'),
        isTrue,
      );
      expect(
        y('Mid prompt deconstruction') < y('Alpha artifact severity'),
        isTrue,
      );

      // A third click is not a fourth direction: it hands the table back to
      // the order the answers arrived in.
      await t.tap(find.text('QUESTION'));
      await t.pumpAndSettle();
      expect(
        y('Alpha artifact severity') < y('Zulu justification writing'),
        isTrue,
      );
      expect(
        y('Zulu justification writing') < y('Mid prompt deconstruction'),
        isTrue,
      );
    });

    testWidgets('mark sorts by the score', (WidgetTester t) async {
      await open(t, seeded());
      await choose(t, 'Assessment > Candidate', 'No grouping');

      await t.tap(find.text('MARK'));
      await t.pumpAndSettle();

      // Ascending: the two zeros first, the two ones after.
      expect(
        y('Zulu justification writing') < y('Alpha artifact severity'),
        isTrue,
      );
      expect(
        y('Pedestrian near miss') < y('Mid prompt deconstruction'),
        isTrue,
      );
    });

    testWidgets('an ordering survives a filter, and applies inside groups', (
      WidgetTester t,
    ) async {
      await open(t, seeded());

      await t.tap(find.text('QUESTION'));
      await t.pumpAndSettle();
      await t.tap(find.text('Anita Rao'));
      await t.pumpAndSettle();

      // Inside one candidate's bucket, still A-Z. An ordering that only applied
      // to a flat list would leave the grouped view - the DEFAULT view - as the
      // one place a column header did nothing.
      expect(
        y('Alpha artifact severity') < y('Zulu justification writing'),
        isTrue,
      );
    });
  });

  // Zubin sat BOTH assessments - evaluator 12 on a1, evaluator 13 on a2 - so
  // he is the only row in the seed that can tell a person apart from a sitting.
  // The bucket key used to be `who:<employee>|<attempt>`, which made him two
  // groups; every existing test above picks 'Assessment > Candidate', where
  // the attempt id is redundant because a person sits an assessment once, so
  // the whole suite stayed green over it.
  group('grouping by candidate groups the PERSON, not the sitting', () {
    // A GROUP HEADING, not the same name in a row's Candidate cell. An open
    // one-level grouping renders both, so a bare `find.text` counts answers
    // rather than buckets and cannot see the duplicate-heading bug at all.
    Finder heading(String name) => find.byWidgetPredicate(
      (Widget w) =>
          w is Text && w.data == name && w.style?.fontWeight == FontWeight.w700,
    );

    testWidgets('a candidate who sat twice is ONE group', (
      WidgetTester t,
    ) async {
      await open(t, seeded());
      await choose(t, 'Assessment > Candidate', 'Candidate');

      // Two people, two groups - not three.
      expect(find.textContaining('of 2 groups'), findsOneWidget);
      expect(
        heading('Zubin Mehta'),
        findsOneWidget,
        reason: 'two headings with the same name is the bug',
      );
      expect(heading('Anita Rao'), findsOneWidget);
    });

    testWidgets('that group holds every answer the person gave', (
      WidgetTester t,
    ) async {
      await open(t, seeded());
      await choose(t, 'Assessment > Candidate', 'Candidate');

      // One answer from each of his two sittings, under the one heading.
      expect(shown('Mid prompt deconstruction'), isTrue);
      expect(shown('Pedestrian near miss'), isTrue);
    });

    testWidgets('Candidate > Assessment nests both of his sittings', (
      WidgetTester t,
    ) async {
      await open(t, seeded());
      await choose(t, 'Assessment > Candidate', 'Candidate > Assessment');

      // The top level opens on arrival, so his two assessments are the two
      // sub-headings sitting under the single "Zubin Mehta".
      expect(heading('Zubin Mehta'), findsOneWidget);
      // The second level is what this grouping exists for. Keyed per sitting,
      // every candidate bucket held exactly one assessment and the level was
      // dead weight on every row in the table.
      expect(shown('Text to Image Assessment'), isTrue);
      expect(shown('Warehouse Safety Induction'), isTrue);
    });
  });
}
