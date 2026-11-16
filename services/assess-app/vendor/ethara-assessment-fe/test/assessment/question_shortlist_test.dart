// SHORTLISTING which of a generator's questions an assessment actually draws.
//
// Two bugs made the Selected Questions tab useless on the one state it matters
// in. The tab listed `asm.questions`, which the server does not write until
// `action_start` - so a DRAFT read "No questions were selected" over a generator
// holding twenty, and an operator who wanted eight of those twenty had to edit
// the generator itself. And `action_start` overwrote `question_ids` with the
// whole servable pool, so even a shortlist stored by hand was discarded at
// launch and the cohort sat all twenty.
//
// The server now sends `pool` (the choice) beside `questions` (the pick), each
// row flagged `in_use`, and narrows its draw to the shortlist. This pins the
// client half: what renders, what a tap writes, and the two states where a tap
// must do nothing.
//
// THE EMPTY-SHORTLIST TRAP is the subtle one and has its own test. Server-side
// an empty `question_ids` means "the whole generator", not "an empty paper" - so
// unticking the last question would silently do the OPPOSITE of what the
// operator just did. The last tick refuses to come off.
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// One pool row, as `assessment_pool` sends it.
Map<String, dynamic> _q(int id, {required bool inUse}) => <String, dynamic>{
  'id': id,
  'name': 'Q$id',
  'question_type': 'mcq',
  'difficulty': 'medium',
  'sequence': id,
  'active': true,
  'state': 'approved',
  'in_use': inUse,
};

/// Serves one assessment detail and records every update body.
class _Rig {
  final List<Map<String, dynamic>> writes = <Map<String, dynamic>>[];
  final String state;
  final int questionLimit;
  final int poolSize;

  /// Which pool ids arrive ticked. Null = every one of them, which is what an
  /// untouched draft looks like on the wire.
  final Set<int>? inUse;
  late final AppStore store;

  _Rig({
    this.state = 'draft',
    this.questionLimit = 0,
    this.poolSize = 4,
    this.inUse,
  }) {
    store = AppStore(
      api: ApiClient(
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
        baseUrl: 'http://x',
      ),
    );
  }

  Map<String, dynamic> get _detail => <String, dynamic>{
    'id': '7',
    'name': 'test_cj',
    'state': state,
    'duration_minutes': 45,
    'question_limit': questionLimit,
    'generator': <String, dynamic>{'id': 3, 'name': 'SOP alpha'},
    'pool': <Map<String, dynamic>>[
      for (int i = 1; i <= poolSize; i++)
        _q(i, inUse: inUse == null || inUse!.contains(i)),
    ],
  };

  Widget app({
    AccessRole role = AccessRole.admin,
    Set<Capability>? caps,
  }) {
    store.accessRole = role;
    if (caps != null) store.caps = caps;
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: AssessmentDetailScreen(
            store: store,
            portal: Portal.admin,
            asmId: '7',
            tab: 'questions',
          ),
        ),
      ),
    );
  }
}

/// The two tick states. `byIcon` matches the exact `IconData`, so these cannot
/// pick up each other.
///
/// CHECKBOXES, NOT CHECK-CIRCLES, since the control was reported as invisible:
/// every row arrives ticked, so with a circle there was no unticked glyph
/// anywhere on screen to suggest the column held controls at all. Defined once
/// here so the whole file follows the widget rather than 12 finders drifting
/// from it - which is exactly what happened when the glyph changed.
Finder get ticked => find.byIcon(Icons.check_box);
Finder get unticked => find.byIcon(Icons.check_box_outline_blank);

void main() {
  void desktop(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Past the 600ms save debounce AND the toast's 3.2s dismissal, either of
  /// which still pending at teardown fails the test on a live timer.
  ///
  /// ASSERT THE UI BEFORE THIS, THE WIRE AFTER IT. `_act` follows every write
  /// with a full console reload, and this rig answers one canned payload to
  /// every path - so past this point the store holds whatever that reload made
  /// of it, not the result of the tap. The tap's visible effect is the
  /// OPTIMISTIC update, which has already landed after a plain [settle].
  Future<void> settleSave(WidgetTester tester) async {
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 3300));
  }

  /// `Notice` paints through `Text.rich`, so `find.text` cannot see it.
  Finder noticeSaying(String strong) =>
      find.byWidgetPredicate((Widget w) => w is Notice && w.strong == strong);

  group('the shortlist renders the pool, not only the pick', () {
    testWidgets('a draft lists the generator pool with every row ticked', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      await tester.pumpWidget(_Rig().app());
      await settle(tester);

      // The bug this replaces: `questions` is EMPTY on a draft, so the tab used
      // to render its empty state over a generator holding four questions.
      expect(find.text('Q1'), findsOneWidget);
      expect(find.text('Q4'), findsOneWidget);
      expect(
        ticked,
        findsNWidgets(4),
        reason: 'an untouched draft has no shortlist, and no shortlist means '
            'the whole generator - not an empty paper',
      );
      expect(unticked, findsNothing);
    });

    testWidgets('the header counts the paper about to be drawn', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      await tester.pumpWidget(_Rig(inUse: <int>{1, 3}).app());
      await settle(tester);

      // This figure is what "Number of Questions" is checked against at launch,
      // so it is stated rather than left to be counted off the ticks.
      expect(find.text('2 of 4 in use'), findsOneWidget);
      expect(ticked, findsNWidgets(2));
      expect(unticked, findsNWidgets(2));
    });

    testWidgets('an excluded question is dimmed, never hidden', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      await tester.pumpWidget(_Rig(inUse: <int>{1}).app());
      await settle(tester);

      // Hiding it would leave no way to put it back.
      for (final String name in <String>['Q1', 'Q2', 'Q3', 'Q4']) {
        expect(find.text(name), findsOneWidget, reason: '$name must stay legible');
      }
    });
  });

  group('a tick writes the shortlist', () {
    testWidgets('unticking one sends the REMAINING ids', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      final _Rig rig = _Rig();
      await tester.pumpWidget(rig.app());
      await settle(tester);

      await tester.tap(ticked.at(1));
      await settleSave(tester);

      expect(rig.writes, hasLength(1));
      expect(
        (rig.writes.single['question_ids'] as List<dynamic>)
            .map((dynamic v) => v.toString())
            .toSet(),
        <String>{'1', '3', '4'},
        reason: 'the full set goes every time, so a dropped request costs '
            'nothing and the server never has to merge',
      );
    });

    testWidgets('a burst of ticks becomes ONE request', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      final _Rig rig = _Rig();
      await tester.pumpWidget(rig.app());
      await settle(tester);

      // Three taps inside the debounce window. Select-all over forty questions
      // is forty taps' worth of state but one instrument.
      await tester.tap(ticked.at(1));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(ticked.at(1));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(ticked.at(1));
      await settleSave(tester);

      expect(rig.writes, hasLength(1));
      expect(rig.writes.single['question_ids'], hasLength(1));
    });

    testWidgets('ticking does NOT also open the preview sheet', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      await tester.pumpWidget(_Rig().app());
      await settle(tester);

      await tester.tap(ticked.first);
      await settle(tester);

      // The row has its own onTap. If the tick did not swallow the gesture,
      // every shortlist change would navigate away and lose the next one.
      expect(find.text('Preview'), findsNothing);
      expect(unticked, findsNWidgets(1));
      await settleSave(tester);
    });

    testWidgets('the question limit comes down with the shortlist', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      // Four in the pool, the operator asked for four. Shortlisting to three
      // leaves a draft that cannot launch unless the limit follows.
      final _Rig rig = _Rig(questionLimit: 4);
      await tester.pumpWidget(rig.app());
      await settle(tester);

      await tester.tap(ticked.first);
      await settleSave(tester);

      expect(rig.writes.single['question_limit'], 3);
    });

    testWidgets('a limit of 0 becomes the tick count too', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      final _Rig rig = _Rig(questionLimit: 0);
      await tester.pumpWidget(rig.app());
      await settle(tester);

      await tester.tap(ticked.first);
      await settleSave(tester);

      expect(rig.writes.single['question_limit'], 3);
    });

    testWidgets('ticking 15 over a limit of 6 raises the limit to 15', (
      WidgetTester tester,
    ) async {
      // Prod 2026-09-29: 15 ticked, limit left at 6, and launch drew a random
      // 6 of the 15 as the one shared paper.
      desktop(tester);
      final _Rig rig = _Rig(
        questionLimit: 6,
        poolSize: 15,
        inUse: <int>{1, 2, 3, 4, 5, 6},
      );
      await tester.pumpWidget(rig.app());
      await settle(tester);

      await tester.tap(find.widgetWithText(Btn, 'Use all 15'));
      await settleSave(tester);

      expect(rig.writes.single['question_ids'], hasLength(15));
      expect(rig.writes.single['question_limit'], 15);
    });
  });

  group('select-all and its honest opposite', () {
    testWidgets('"Use all" puts every question back', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      final _Rig rig = _Rig(inUse: <int>{2});
      await tester.pumpWidget(rig.app());
      await settle(tester);

      await tester.tap(find.widgetWithText(Btn, 'Use all 4'));
      await settle(tester);
      expect(ticked, findsNWidgets(4));

      await settleSave(tester);
      expect(rig.writes.single['question_ids'], hasLength(4));
    });

    testWidgets('with everything in use the button offers to clear all BUT ONE',
        (WidgetTester tester) async {
      desktop(tester);
      final _Rig rig = _Rig();
      await tester.pumpWidget(rig.app());
      await settle(tester);

      // NOT "Clear all". An empty shortlist means the whole generator
      // server-side, so a button labelled "Clear all" would do the opposite of
      // what it says.
      expect(find.widgetWithText(Btn, 'Clear all but one'), findsOneWidget);
      await tester.tap(find.widgetWithText(Btn, 'Clear all but one'));
      await settle(tester);
      expect(ticked, findsNWidgets(1));

      await settleSave(tester);
      expect(rig.writes.single['question_ids'], hasLength(1));
    });

    testWidgets('the last tick refuses to come off', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      final _Rig rig = _Rig(inUse: <int>{3});
      await tester.pumpWidget(rig.app());
      await settle(tester);

      await tester.tap(ticked.first);
      await settle(tester);

      expect(
        ticked,
        findsNWidgets(1),
        reason: 'the server reads an empty question_ids as the WHOLE '
            'generator, so unticking the last one would enlarge the paper',
      );
      // Read off the Toaster rather than the tree: the toast host lives in the
      // app shell, and this rig mounts the screen alone.
      expect(
        rig.store.toaster.items.map((ToastMsg m) => m.message).join(),
        contains('Keep at least one question'),
      );
      await settleSave(tester);
      expect(rig.writes, isEmpty);
    });
  });

  group('two locks, and they say different things', () {
    testWidgets('a launched paper is fixed for everybody, Admin included', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      final _Rig rig = _Rig(state: 'in_progress', inUse: <int>{1, 2});
      await tester.pumpWidget(rig.app());
      await settle(tester);

      expect(noticeSaying('The paper is fixed.'), findsOneWidget);
      // The ticks STAY VISIBLE - a launched assessment still has to show which
      // questions it was launched against - and the select-all goes. Matched by
      // its label: the page header carries buttons of its own.
      expect(ticked, findsNWidgets(2));
      expect(find.widgetWithText(Btn, 'Use all 4'), findsNothing);
      expect(find.widgetWithText(Btn, 'Clear all but one'), findsNothing);

      await tester.tap(ticked.first);
      await settleSave(tester);
      expect(rig.writes, isEmpty, reason: 'the server would 409 the whole '
          'request, taking question_limit down with it');
    });

    testWidgets('a read-only Manager may review the shortlist, not change it', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      final _Rig rig = _Rig();
      await tester.pumpWidget(
        rig.app(
          role: AccessRole.manager,
          caps: <Capability>{Capability.launch},
        ),
      );
      await settle(tester);

      expect(noticeSaying('Read-only.'), findsOneWidget);
      expect(ticked, findsNWidgets(4));
      await tester.tap(ticked.first);
      await settleSave(tester);
      expect(rig.writes, isEmpty);
    });
  });

  group('the wire shape', () {
    test('pool and its ticks round-trip through toJson', () {
      final Assessment a = Assessment.fromJson(<String, dynamic>{
        'id': '7',
        'name': 'a',
        'state': 'draft',
        'pool': <Map<String, dynamic>>[
          _q(1, inUse: true),
          _q(2, inUse: false),
        ],
      });
      expect(a.inUseIds, <String>{'1'});
      expect(a.pool.map((Question q) => q.id), <String>['1', '2']);

      final Assessment back = Assessment.fromJson(a.toJson());
      expect(back.inUseIds, a.inUseIds);
      expect(back.pool.map((Question q) => q.id), a.pool.map((Question q) => q.id));
    });

    test('no pool key falls back to questions, all in use', () {
      // The seed fixtures and every list row send no `pool`. Falling back to an
      // empty one would have emptied this tab everywhere the app runs on seed
      // data - a fixture assessment has no separate choice to make.
      final Assessment a = Assessment.fromJson(<String, dynamic>{
        'id': '7',
        'name': 'a',
        'state': 'in_progress',
        'questions': <Map<String, dynamic>>[
          _q(5, inUse: true),
          _q(6, inUse: true),
        ],
      });
      expect(a.pool.map((Question q) => q.id), <String>['5', '6']);
      expect(a.inUseIds, <String>{'5', '6'});
      expect(a.inUseCount, 2);
    });

    test('inUseCount ignores an id whose question has gone', () {
      final Assessment a = Assessment.fromJson(<String, dynamic>{
        'id': '7',
        'name': 'a',
        'state': 'draft',
        'pool': <Map<String, dynamic>>[_q(1, inUse: true)],
      }).copyWith(inUseIds: <String>{'1', '99'});
      expect(
        a.inUseCount,
        1,
        reason: 'a question retired between two loads must not inflate the '
            'figure the operator sizes their question limit against',
      );
    });
  });
}
