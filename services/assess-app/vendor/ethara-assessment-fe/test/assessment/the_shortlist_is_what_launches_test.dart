// THE SHORTLIST IS WHAT LAUNCHES, and for a while the client could neither
// count it nor let anybody change it.
//
// TWO FAULTS, ONE TAB, and they compounded. An operator who created an
// assessment could not launch it, and the control that would have let them work
// around that was on screen and invisible.
//
// COULD NOT LAUNCH. `Gates.launch` sized the paper off `asm.questions`, which
// the server writes only once `action_start` has DRAWN one. So on a brand-new
// assessment - which is every assessment at the moment it is created - that list
// was empty, `question_limit` was 0, and the gate reported "Asked for 0 but only
// 0 are selected." beside a generator holding six. The module would have
// launched it without complaint: `shortlist = set(rec.question_ids.ids); if
// shortlist: narrow...` then `limit = rec.question_limit or
// len(available_questions)` - an empty shortlist means THE WHOLE GENERATOR
// there. The client was the only thing refusing, and the only way past it was to
// toggle a tick, any tick, to make the count real. `effectiveQuestions` resolves
// the selection the way the server resolves it, and the gate reads that.
//
// COULD NOT SEE THE TICK. The one control that made the count real was drawn as
// `check_circle` / `check_circle_outline` in a column with no header, in the same
// ink whether the paper was editable or frozen. Every row arrives TICKED, so
// there was no unticked box anywhere on screen to suggest the glyphs were
// controls at all. Reported verbatim as "I cannot see the mechanism to
// select/deselect questions". It is a checkbox now, the column says 'Include',
// and a frozen paper draws in muted ink so it stops looking clickable.
//
// WHAT THE THIRD GROUP HERE PINS THAT THE OTHERS CANNOT: gate 6 - every
// objective question has an answer key - was VACUOUS on every draft for exactly
// the same reason the count was wrong. It walked `asm.questions`, always empty
// pre-launch, so an unkeyed question sailed through the one check that exists to
// catch it while it is still cheap to fix.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/gates.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

/// The two gates this file is about, named exactly as `Gates.launch` names them.
const String kCountGate = 'The requested question count is available';
const String kKeyGate = 'Every objective question has an answer key';

/// One approved, launch-ready question.
///
/// [keyed] false leaves the dimension with no correct option, which is the only
/// thing that makes [Question.hasCompleteKey] false - `servable` is set either
/// way so the question still counts towards the generator-pool gate and cannot
/// fail this file's assertions for an unrelated reason.
Question _q(String id, {bool keyed = true}) => Question(
  id: id,
  genId: 'GEN-1',
  type: QType.mcq,
  name: 'Q$id',
  prompt: 'Which one?',
  dims: <QDimension>[
    QDimension(
      code: 'D1',
      name: 'Answer',
      options: <QOption>[
        QOption(id: '$id-a', label: 'One', correct: keyed),
        const QOption(id: 'b', label: 'Two'),
      ],
    ),
  ],
  state: DraftState.approved,
  servable: true,
);

List<Question> _pool(int n) =>
    <Question>[for (int i = 1; i <= n; i++) _q('$i')];

/// A draft as the detail route hands one over: a [pool] of candidates, a
/// shortlist over it, and `questions` still EMPTY because nothing has been
/// drawn.
///
/// [inUse] defaults to every pool id, which is what an untouched draft looks
/// like on the wire - the serializer marks every row in use when the server-side
/// shortlist is empty.
Assessment _draft({
  List<Question> pool = const <Question>[],
  Set<String>? inUse,
  int limit = 0,
  List<Question> questions = const <Question>[],
}) => Assessment(
  id: 'A-1',
  name: 'Untouched draft',
  generatorId: 'GEN-1',
  questionLimit: limit,
  questions: questions,
  pool: pool,
  inUseIds: inUse ?? pool.map((Question q) => q.id).toSet(),
  roster: const <Person>[
    Person(id: '13', name: 'Ravi Kumar', email: 'ravi@example.com'),
  ],
);

const Generator _gen = Generator(id: 'GEN-1', name: 'VAL Generator');

List<GateResult> _gates(Assessment asm, {List<Question>? bank}) => Gates.launch(
  asm,
  attempts: const <Attempt>[],
  generator: _gen,
  bank: bank ?? asm.pool,
);

GateResult _gate(Assessment asm, String name, {List<Question>? bank}) =>
    _gates(asm, bank: bank).firstWhere((GateResult g) => g.name == name);

void main() {
  group('the launch gates size the paper the way the server does', () {
    test('an untouched draft can launch', () {
      // THE BUG, EXACTLY. Six in the pool, every one ticked, nothing drawn yet,
      // no explicit limit. This is the state every assessment is in one second
      // after it is created.
      final Assessment asm = _draft(pool: _pool(6));

      final GateResult count = _gate(asm, kCountGate);

      expect(
        count.ok,
        isTrue,
        reason:
            'this gate read `asm.questions`, which the launch route fills only '
            'AFTER launch - so it refused with "Asked for 0 but only 0 are '
            'selected." over a generator holding six, and the only workaround '
            'was to toggle a tick to make the count real',
      );
      expect(
        count.why,
        '6 question(s) selected.',
        reason: 'the gate states its evidence, and the evidence is the size of '
            'the paper `action_start` would draw',
      );
      expect(
        Gates.allPass(_gates(asm)),
        isTrue,
        reason: 'a draft with a roster, a generator, a servable pool and a '
            'complete key has nothing left to fix - if it still cannot launch, '
            'the client is refusing what the server would accept',
      );
    });

    test('a partial shortlist is what want falls back to', () {
      final Assessment asm = _draft(
        pool: _pool(6),
        inUse: <String>{'1', '3', '5'},
      );

      final GateResult count = _gate(asm, kCountGate);

      expect(count.ok, isTrue);
      expect(
        count.why,
        '3 question(s) selected.',
        reason: 'with no explicit limit the shortlist IS the limit, so the '
            'figure has to be the 3 ticked rather than the 6 available',
      );
    });

    test('an explicit limit the shortlist can meet passes', () {
      final Assessment asm = _draft(
        pool: _pool(6),
        inUse: <String>{'1', '2', '3'},
        limit: 3,
      );

      expect(_gate(asm, kCountGate).ok, isTrue);
      expect(_gate(asm, kCountGate).why, '3 question(s) selected.');
    });

    test('an explicit limit the shortlist cannot meet names both numbers', () {
      final Assessment asm = _draft(
        pool: _pool(6),
        inUse: <String>{'1', '2', '3'},
        limit: 5,
      );

      final GateResult count = _gate(asm, kCountGate);

      expect(
        count.ok,
        isFalse,
        reason: 'asking for 5 out of a shortlist of 3 is a real fault - the '
            'fix must not have made this gate unfailable',
      );
      expect(
        count.why,
        contains('5'),
        reason: 'the operator has to be told what they asked for, not just '
            'that something is wrong',
      );
      expect(count.why, contains('3'), reason: 'and what is actually there');
    });

    test('an empty server-side shortlist counts the whole pool', () {
      // ON THE WIRE an empty `question_ids` arrives as every row flagged in
      // use, because the server reads "nothing shortlisted" as "the whole
      // generator". Built through `fromJson` rather than the constructor, so
      // this pins the parse as well as the gate.
      final Assessment asm = Assessment.fromJson(<String, dynamic>{
        'id': '7',
        'name': 'Nothing shortlisted',
        'state': 'draft',
        'generator': <String, dynamic>{'id': 3, 'name': 'VAL Generator'},
        'roster': <Map<String, dynamic>>[
          <String, dynamic>{'id': 13, 'name': 'Ravi', 'email': 'r@x.io'},
        ],
        'pool': <Map<String, dynamic>>[
          for (int i = 1; i <= 6; i++)
            <String, dynamic>{
              'id': i,
              'name': 'Q$i',
              'question_type': 'mcq',
              'state': 'approved',
              'in_use': true,
            },
        ],
      });

      expect(
        asm.inUseIds,
        hasLength(6),
        reason: 'an empty shortlist is not an empty paper - reading it as one '
            'is what made the gate refuse a draft the server would launch',
      );
      expect(_gate(asm, kCountGate).ok, isTrue);
      expect(_gate(asm, kCountGate).why, '6 question(s) selected.');
    });

    test('an assessment with nothing to draw from still fails, and says so',
        () {
      // THE NEGATIVE HALF. No pool, no drawn questions, no shortlist: there is
      // genuinely nothing to launch, and the message has to point at the tab
      // where a person fixes it rather than quote two zeroes at them.
      final Assessment asm = _draft();

      final GateResult count = _gate(asm, kCountGate, bank: _pool(6));

      expect(
        count.ok,
        isFalse,
        reason: 'the fix must not have turned this gate into a row that can '
            'never fail - a checklist item that always passes teaches a reader '
            'to skim the ones that can',
      );
      expect(
        count.why,
        'Nothing is selected. Tick at least one question on the Selected '
        'Questions tab.',
        reason: 'naming the surface is the difference between a diagnosis and '
            'a complaint',
      );
    });

    test('an unkeyed question inside the shortlist is caught and named', () {
      // GATE 6 WAS VACUOUS ON EVERY DRAFT: it walked `asm.questions`, empty
      // until launch, so an objective question with no correct option marked
      // passed the one check that exists to catch it - and it could never be
      // scored.
      final Assessment asm = _draft(
        pool: <Question>[_q('1'), _q('2', keyed: false), _q('3')],
      );

      final GateResult key = _gate(asm, kKeyGate);

      expect(
        key.ok,
        isFalse,
        reason: 'an objective question with no correct option marked can never '
            'be scored, and a draft is the cheapest moment to fix it',
      );
      expect(
        key.offenders,
        contains('Q2'),
        reason: 'a count tells an operator to go hunting; a name tells them '
            'which row to open',
      );
    });

    test('the same question outside the shortlist is nobody\'s problem', () {
      // THE HALF THAT WAS VACUOUS, now meaningful in BOTH directions: taking
      // the unkeyed question out of the shortlist has to clear the gate,
      // because that question is not going out.
      final Assessment asm = _draft(
        pool: <Question>[_q('1'), _q('2', keyed: false), _q('3')],
        inUse: <String>{'1', '3'},
      );

      final GateResult key = _gate(asm, kKeyGate);

      expect(
        key.ok,
        isTrue,
        reason: 'the gate judges what would be DRAWN - blocking a launch over '
            'a question the operator has already excluded is a dead end with '
            'no way out of it',
      );
      expect(key.offenders, isEmpty);
    });
  });

  group('the effective selection is the one the server would draw', () {
    test('an empty shortlist means the whole pool', () {
      final Assessment asm = _draft(pool: _pool(6));

      expect(asm.effectiveQuestionCount, 6);
      expect(
        asm.effectiveQuestions.map((Question q) => q.id),
        <String>['1', '2', '3', '4', '5', '6'],
        reason: '`action_start` falls back to len(available_questions), so this '
            'is the paper that would actually go out',
      );
    });

    test('a partial shortlist means the ticked rows', () {
      final Assessment asm = _draft(
        pool: _pool(6),
        inUse: <String>{'2', '4', '6'},
      );

      expect(asm.effectiveQuestionCount, 3);
      expect(
        asm.effectiveQuestions.map((Question q) => q.id),
        <String>['2', '4', '6'],
        reason: 'the order is the pool order, so the tab and the gate agree on '
            'which rows they are talking about',
      );
    });

    test('a row carrying no pool falls back to what it was drawn against', () {
      // A LIST ROW, and the seed fixtures. Neither sends `pool`, and answering
      // 0 for those would have moved the bug rather than fixed it.
      final Assessment asm = Assessment(
        id: 'A-2',
        name: 'A list row',
        questions: _pool(4),
      );

      expect(asm.effectiveQuestionCount, 4);
      expect(asm.effectiveQuestions.map((Question q) => q.id), <String>[
        '1',
        '2',
        '3',
        '4',
      ]);
    });

    test('an id whose question has gone does not inflate the count', () {
      // RETIRED BETWEEN TWO LOADS. Counting `inUseIds` directly would report a
      // paper larger than the pool can serve, and the operator sizes their
      // question limit against this figure.
      final Assessment asm = _draft(
        pool: _pool(2),
        inUse: <String>{'1', '2', '99'},
      );

      expect(asm.effectiveQuestionCount, 2);
      expect(asm.effectiveQuestions.map((Question q) => q.id), <String>[
        '1',
        '2',
      ]);
      expect(
        asm.inUseCount,
        asm.effectiveQuestionCount,
        reason: 'the two counts are the same fact wherever a pool exists',
      );
    });

    test('totalQuestions is untouched by any of this', () {
      // THE DENOMINATOR MARKS ARE SCORED OUT OF. `effectiveQuestionCount` is
      // "what would go out if I launched now"; `totalQuestions` is the paper a
      // candidate actually sat. Folding the first into the second would move
      // every result's out-of figure.
      final Assessment untouched = _draft(pool: _pool(6));
      expect(
        untouched.totalQuestions,
        0,
        reason: 'nothing has been drawn yet, and claiming 6 here would score a '
            'candidate out of a paper that does not exist',
      );

      final Assessment shortlisted = _draft(
        pool: _pool(6),
        inUse: <String>{'1', '2'},
      );
      expect(shortlisted.totalQuestions, 0);
      expect(shortlisted.effectiveQuestionCount, 2);

      final Assessment launched = _draft(
        pool: _pool(6),
        inUse: <String>{'1', '2'},
        questions: _pool(4),
      );
      expect(
        launched.totalQuestions,
        4,
        reason: 'once a paper is drawn `questions` is the only honest '
            'denominator, whatever the shortlist says now',
      );
    });
  });

  group('the tick is visibly a control', () {
    testWidgets('a draft draws checkboxes, not status circles', (
      WidgetTester tester,
    ) async {
      final _Rig rig = _Rig(inUse: <int>{1, 2});
      await rig.mount(tester);

      expect(
        find.byIcon(Icons.check_box),
        findsNWidgets(2),
        reason: 'a filled box is the glyph the sibling New Assessment screen '
            'already uses for the identical job',
      );
      expect(
        find.byIcon(Icons.check_box_outline_blank),
        findsNWidgets(2),
        reason: 'AN EMPTY BOX IS THE WHOLE POINT: it is the only thing on '
            'screen that says a tick is something a person puts there',
      );
      expect(
        find.byIcon(Icons.check_circle),
        findsNothing,
        reason: 'the old glyph read as a status the row happened to have, and '
            'with every row arriving ticked there was no contrast anywhere to '
            'suggest otherwise',
      );
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);
    });

    testWidgets('the column says what the boxes are for', (
      WidgetTester tester,
    ) async {
      await _Rig().mount(tester);

      // Upper-cased by the grid's own header style. The column was deliberately
      // blank before - and an unlabelled gutter of already-ticked glyphs is
      // half of why nobody found the control.
      expect(
        find.text('INCLUDE'),
        findsOneWidget,
        reason: 'nothing named this column, so nothing said the glyphs in it '
            'were the mechanism for choosing questions',
      );
    });

    testWidgets('tapping an empty box puts that question in the paper', (
      WidgetTester tester,
    ) async {
      final _Rig rig = _Rig(inUse: <int>{1, 2});
      await rig.mount(tester);

      await tester.tap(find.byIcon(Icons.check_box_outline_blank).first);
      await rig.settle(tester);

      expect(
        rig.shortlist,
        <String>{'1', '2', '3'},
        reason: 'the box has to be the control it now looks like - drawing a '
            'checkbox that does not toggle would be a worse lie than the '
            'circle was',
      );
      expect(find.byIcon(Icons.check_box), findsNWidgets(3));

      await rig.settleSave(tester);
      expect(rig.writes, hasLength(1));
      expect(
        (rig.writes.single['question_ids'] as List<dynamic>)
            .map((dynamic v) => v.toString())
            .toSet(),
        <String>{'1', '2', '3'},
        reason: 'the tap has to reach the server too, or the shortlist is lost '
            'on the next load',
      );
    });

    testWidgets('a launched paper draws the boxes and refuses to move them', (
      WidgetTester tester,
    ) async {
      final _Rig rig = _Rig(state: 'in_progress', inUse: <int>{1, 2});
      await rig.mount(tester);

      expect(
        find.byWidgetPredicate(
          (Widget w) => w is Notice && w.strong == 'The paper is fixed.',
        ),
        findsOneWidget,
        reason: 'the boxes stay legible on a launched paper, so something has '
            'to say why they do not respond - `Notice` paints through '
            'Text.rich, which is why this is not a text finder',
      );
      expect(
        find.byIcon(Icons.check_box),
        findsNWidgets(2),
        reason: 'a launched assessment still has to show which questions it '
            'was launched against',
      );

      await tester.tap(find.byIcon(Icons.check_box).first);
      await rig.settle(tester);

      expect(
        rig.shortlist,
        <String>{'1', '2'},
        reason: 'changing the paper now would rewrite the exam under '
            'candidates who have already agreed to it, and the server would '
            '409 the whole request anyway',
      );
      await rig.settleSave(tester);
      expect(rig.writes, isEmpty);
    });
  });
}

/// Serves one assessment detail over four pool rows and records every write.
class _Rig {
  final List<Map<String, dynamic>> writes = <Map<String, dynamic>>[];
  final String state;

  /// Which pool ids arrive ticked. Null = all four, which is what an untouched
  /// draft looks like on the wire.
  final Set<int>? inUse;
  late final AppStore store;

  _Rig({this.state = 'draft', this.inUse}) {
    store = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        client: MockClient((http.Request req) async {
          if (req.url.path.endsWith('/update')) {
            writes.add(jsonDecode(req.body) as Map<String, dynamic>);
          }
          return http.Response(
            jsonEncode(<String, dynamic>{'ok': true, 'data': _detail}),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
  }

  /// The shortlist the store currently holds for this assessment.
  Set<String> get shortlist => store.asmById('7')!.inUseIds;

  Map<String, dynamic> get _detail => <String, dynamic>{
    'id': '7',
    'name': 'test_cj',
    'state': state,
    'duration_minutes': 45,
    'question_limit': 0,
    'generator': <String, dynamic>{'id': 3, 'name': 'VAL Generator'},
    'pool': <Map<String, dynamic>>[
      for (int i = 1; i <= 4; i++)
        <String, dynamic>{
          'id': i,
          'name': 'Q$i',
          'question_type': 'mcq',
          'difficulty': 'medium',
          'sequence': i,
          'active': true,
          'state': 'approved',
          'in_use': inUse == null || inUse!.contains(i),
        },
    ],
  };

  Future<void> mount(WidgetTester tester) async {
    // The grid declares a minWidth of 880 and the tab is long, so the default
    // 800x600 viewport would overflow and read as a layout bug.
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AssessmentNavScope(
          nav: AssessmentNav(),
          child: Scaffold(
            body: AssessmentDetailScreen(
              store: store,
              portal: Portal.admin,
              asmId: '7',
              tab: 'questions',
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Past the 600ms shortlist debounce AND the toast's own dismissal, either of
  /// which still pending at teardown fails the test on a live timer.
  ///
  /// ASSERT THE UI BEFORE THIS, THE WIRE AFTER IT: every write is followed by a
  /// full reload, and this rig answers one canned payload to every path, so
  /// past this point the store holds what that reload made of it rather than
  /// the result of the tap.
  Future<void> settleSave(WidgetTester tester) async {
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 3300));
  }
}
