// The reported bug, pinned at the surface it was reported on.
//
// A draft msq with five options and three correct rendered in the review queue
// as an empty answer key under a blocking red "No correct option marked." -
// while the Odoo form for the same record showed all five chips with three
// ticked. Everything needed was on the wire; nothing displayed it, because
// every answer-key widget read the BANK spelling (`dimensions`) and a generated
// draft carries the flat one (`options` + `correct_answer`).
//
// `draft_key_shape_test.dart` pins the parse. This pins the PIXELS: the parse
// being right is not the same claim as the reviewer being able to see it, and
// it was the second half that was broken for the whole class of question.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/assessment_section.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/answer_key.dart';

/// Draft 7585 verbatim: the record in the bug report, as the server sends it
/// BEFORE the serializer learned to send its axis rows. Kept in the flat shape
/// deliberately - that is the payload the client has to survive, and the one
/// every fixture in this repo was missing.
Map<String, dynamic> _reportedDraft() => <String, dynamic>{
  'id': '7585',
  'name': 'Identify Interactive Elements',
  'question_type': 'msq',
  'state': 'draft',
  'medium': 'Text',
  'difficulty': 'medium',
  'prompt':
      'Which of the following UI components are considered interactive '
      'elements that require a bounding box because they trigger an action '
      'or navigation? (Select all that apply)',
  'options': <String>[
    'Upload buttons',
    'Navigation elements',
    'Static background images',
    'Tabs',
    'Plain text paragraphs',
  ],
  'correct_answer': <String>['Upload buttons', 'Navigation elements', 'Tabs'],
  'official_reasoning':
      'An interactive element is any UI component that a user can click, tap, '
      'scroll, or interact with to perform an action.',
  // The generator tied it to the SOP and no distractor gives the answer away,
  // so nothing else should be warning about this draft.
  'warnings': <String, dynamic>{
    'revealing_option': false,
    'source_reference': false,
  },
};

Future<AppStore> _pumpQueue(WidgetTester tester, Question draft) async {
  // The grids declare a minWidth past the 800x600 default; a narrower surface
  // overflows and the failure reads as a layout bug rather than a small window.
  tester.view.physicalSize = const Size(1600, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final AppStore store = AppStore();
  addTearDown(store.dispose);
  store.drafts = <Question>[draft];

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AssessmentSection(
          store: store,
          entry: AssessmentEntry.reviewQueue,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('every option is on the card, with the correct ones ticked', (
    WidgetTester tester,
  ) async {
    await _pumpQueue(tester, Question.fromJson(_reportedDraft()));

    // The distractors, shown plain.
    expect(find.text('Static background images'), findsOneWidget);
    expect(find.text('Plain text paragraphs'), findsOneWidget);

    // The key, ticked. The tick is the whole point: the reviewer is being
    // asked to sign off WHICH options are right, not merely that five exist.
    expect(find.text('✓  Upload buttons'), findsOneWidget);
    expect(find.text('✓  Navigation elements'), findsOneWidget);
    expect(find.text('✓  Tabs'), findsOneWidget);
  });

  testWidgets('the false "No answer key" notice is gone', (
    WidgetTester tester,
  ) async {
    await _pumpQueue(tester, Question.fromJson(_reportedDraft()));
    // findRichText, because `Notice` composes its lead sentence and body into
    // one `Text.rich`. Without it these finders match nothing whatever the UI
    // does, and a `findsNothing` assertion passes for the wrong reason - which
    // is how this test first went green while the notice was still on screen.
    expect(
      find.textContaining('No correct option marked', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining('No answer key', findRichText: true),
      findsNothing,
    );
  });

  // THE NEGATIVE CONTROL. Without it the test above proves only that the
  // notice can be absent, not that it still fires when it should - and a
  // warning that never fires is worse than the false one it replaced.
  testWidgets('a draft with nothing marked correct STILL warns', (
    WidgetTester tester,
  ) async {
    final Map<String, dynamic> j = _reportedDraft();
    j['correct_answer'] = <String>[];
    await _pumpQueue(tester, Question.fromJson(j));

    expect(
      find.textContaining('No correct option marked', findRichText: true),
      findsOneWidget,
    );
    // Twice, and both are right: the warning notice states it, and the
    // acknowledgement checkbox names it again - that checkbox is the gate a
    // reviewer must tick before this draft can be approved at all.
    expect(
      find.textContaining('No answer key', findRichText: true),
      findsNWidgets(2),
    );
  });

  testWidgets('the generator\'s rationale is shown with the key, unfolded', (
    WidgetTester tester,
  ) async {
    await _pumpQueue(tester, Question.fromJson(_reportedDraft()));

    // UNFOLDED, deliberately - this used to sit behind a "Show the answer
    // rationale" disclosure on the argument that a reviewer should judge the
    // key before reading its defence. The key and the argument for it are one
    // thing: on an image_ab draft this prose IS the standard the candidate's
    // written justification is marked against, so a reviewer signing the key
    // off while it was hidden was signing off half of what they approved.
    expect(find.text('Show the answer rationale'), findsNothing);
    expect(
      find.textContaining('any UI component that a user can click'),
      findsOneWidget,
    );
    expect(
      find.text('ANSWER RATIONALE (HIDDEN FROM CANDIDATE)'),
      findsOneWidget,
    );
  });

  testWidgets('the medium and time budget reach the card', (
    WidgetTester tester,
  ) async {
    final Map<String, dynamic> j = _reportedDraft();
    j['time_minutes'] = 4;
    await _pumpQueue(tester, Question.fromJson(j));
    expect(find.textContaining('Text'), findsWidgets);
    expect(find.textContaining('4 min'), findsOneWidget);
  });

  testWidgets('a DRAFT never offers the marking-guide sign-off', (
    WidgetTester tester,
  ) async {
    // `rubric_reviewed` is a column on `assessments.be.question` and on
    // nothing else. The review queue deals in `assessments.be.prompt.question`,
    // so this control sent a DRAFT id to a route that browses the BANK model
    // and every press answered `{"code": "not_found"}` - while the optimistic
    // local flip left the pill reading "Marking guide approved" over a server
    // that had recorded nothing. A subjective draft with a full rubric is the
    // exact shape that used to render it.
    final Map<String, dynamic> j = _reportedDraft();
    j['question_type'] = 'subjective_rubric';
    j['state'] = 'draft';
    j['subjective_rubric'] = <String>[
      'Names the deciding difference',
      'Cites evidence from the stimulus',
    ];
    await _pumpQueue(tester, Question.fromJson(j));

    expect(find.text('Approve marking guide'), findsNothing);
    expect(find.text('Marking guide not approved'), findsNothing);
    expect(find.text('Withdraw sign-off'), findsNothing);

    // ...and the warning that named that sign-off is gone with it. It read off
    // the same always-false flag, so it fired on every subjective draft
    // forever, pointing at a remedy no screen could give.
    expect(
      find.textContaining('Nobody has reviewed this rubric'),
      findsNothing,
    );
  });

  // THE SERVER'S RULE, `_check_answer_key`: every mcq / msq axis needs a key,
  // while an image_ab needs only ONE keyed axis - a 1-5 rating axis is left to
  // the grader by design. The notice demanded a key on every axis, so a draft
  // the server accepts (Approve enabled) sat under a red "No correct option
  // marked".
  group('the notice follows the server per type', () {
    QDimension axis(String name, {required bool keyed}) => QDimension(
      code: name,
      name: name,
      options: <QOption>[
        QOption(id: '$name-1', label: '$name 1', correct: keyed),
        QOption(id: '$name-2', label: '$name 2'),
      ],
    );

    Future<void> pumpKey(
      WidgetTester tester,
      QType type,
      List<QDimension> dims,
    ) async {
      final AppStore store = AppStore();
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnswerKeyView(
              store: store,
              question: Question(
                id: 'q',
                genId: 'g',
                type: type,
                name: 'n',
                prompt: 'p',
                dims: dims,
              ),
            ),
          ),
        ),
      );
    }

    final Finder notice = find.textContaining(
      'No correct option marked',
      findRichText: true,
    );

    testWidgets('image_ab: one keyed axis plus an unkeyed rating is a key', (
      WidgetTester tester,
    ) async {
      await pumpKey(tester, QType.imageAb, <QDimension>[
        axis('Overall', keyed: true),
        axis('Quality', keyed: false),
      ]);
      expect(find.text('✓  Overall 1'), findsOneWidget);
      expect(notice, findsNothing);
    });

    testWidgets('image_ab: no keyed axis still warns', (
      WidgetTester tester,
    ) async {
      await pumpKey(tester, QType.imageAb, <QDimension>[
        axis('Overall', keyed: false),
        axis('Quality', keyed: false),
      ]);
      expect(notice, findsOneWidget);
    });

    testWidgets('image_ab: no axis at all still warns', (
      WidgetTester tester,
    ) async {
      await pumpKey(tester, QType.imageAb, const <QDimension>[]);
      expect(notice, findsOneWidget);
    });

    testWidgets('mcq: an unkeyed axis still warns beside a keyed one', (
      WidgetTester tester,
    ) async {
      await pumpKey(tester, QType.mcq, <QDimension>[
        axis('First', keyed: true),
        axis('Second', keyed: false),
      ]);
      expect(notice, findsOneWidget);
    });

    testWidgets('mcq: no key at all still warns', (WidgetTester tester) async {
      await pumpKey(tester, QType.mcq, <QDimension>[
        axis('Answer', keyed: false),
      ]);
      expect(notice, findsOneWidget);
    });
  });
}
