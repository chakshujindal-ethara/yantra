// The assessments cache MERGES a list page onto what a detail route hydrated,
// and the SHORTLIST was never on the list of things it keeps.
//
// THE BUG: `_mergeAssessments` returns `fresh.copyWith(...)`, so any field
// absent from that argument list takes the FRESH value - and `fresh` here is
// built from an `assessment_row`, which carries neither `pool` nor `questions`.
// Fourteen detail-only fields are listed and preserved behind
// `bool sent(String camel) => jget(row, camel) != null`. `pool` is not one of
// them, and neither is `inUseIds`, which has no wire key at all:
// `Assessment.fromJson` derives it from the pool rows' `in_use` flags, and its
// `poolRows.isEmpty ? questions : ...` fallback turns a list row into a
// legitimately-shaped EMPTY pool rather than an error. So every background list
// refresh takes both back to empty, silently.
//
// The Selected Questions tab renders `asm.pool`, and `total` is
// `asm.pool.length`. Tick a question on a draft: the toast reads "Shortlist
// saved", and about 600ms later the table collapses to "Pick a question
// generator on the Configuration tab" - the moment `_act`'s trailing
// `refresh(background: true)` lands. Nothing was lost server-side, which is
// what made it read as a save fault when it is a display one.
//
// WHY 1,489 PASSING TESTS MISSED IT, AND IT IS NOT THE TIMING. Both existing
// shortlist files DO land that refresh: `question_shortlist_test.dart` and
// `the_shortlist_is_what_launches_test.dart` each end a tap with a `settleSave`
// that pumps 700ms and then 3300ms, which is past the 600ms debounce and
// through `_act`'s refresh. Their blind spot is the PAYLOAD. Both rigs answer
// ONE canned detail body - `pool` included - to every path, so on the refresh
// `sent('pool')` is true and an identical pool replaces the held one. The
// erasure is invisible because the list route never behaves like the list
// route. SHAPE, not timing, is the gap.
//
// So the one thing this rig must get right is that the list and detail shapes
// DIFFER, exactly as `assessment_row` and `assessment_detail` differ in
// `controllers/api/serializers.py`. Modelled on
// `test/assessment/attempt_cache_merge_test.dart`, the precedent for this same
// hazard on the attempts cache.
//
// OBSERVED ON UNFIXED CODE. This file is a falsification rig: it is SUPPOSED to
// fail until the two `copyWith` entries land, and every assertion BEFORE the
// refresh passes, which is what says the failures are the merge rather than the
// fixtures. Verbatim:
//
//   1. the pool survives a background refresh
//        Expected: <4>
//          Actual: <0>
//      The detail fetch had just been asserted at 4. The list refresh takes it
//      to `[]`.
//   2. the ticks survive with it
//        Expected: Set:['1', '3']
//          Actual: Set:[]
//          Which: does not contain '1'
//      So a strip would read "0 of 4 in use", if it were still drawn at all.
//   3. ticking a question does not empty the tab
//        Expected: exactly one matching candidate
//          Actual: _TextWidgetFinder:<Found 0 widgets with text "Q1": []>
//      The tab had rendered "2 of 4 in use" over four rows, and "3 of 4 in use"
//      after the tap. Then `total == 0` hid the strip and the select-all, and
//      the grid fell to its draft empty state under an unchanged badge.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// One `assessment_pool` row, as the detail route sends it.
Map<String, dynamic> poolRow(int id, {required bool inUse}) =>
    <String, dynamic>{
      'id': id,
      'name': 'Q$id',
      'question_type': 'mcq',
      'difficulty': 'medium',
      'state': 'approved',
      'active': true,
      'in_use': inUse,
    };

/// One row of the FROZEN paper - `questions`, which is also detail-only and
/// carries no tick, because a paper that has been drawn is no longer a choice.
/// Named `P$id` and numbered from 101 so a `questions` row can never be
/// mistaken for a `pool` row in an assertion.
Map<String, dynamic> paperRow(int id) => <String, dynamic>{
  'id': id,
  'name': 'P$id',
  'question_type': 'mcq',
  'difficulty': 'medium',
  'state': 'approved',
  'active': true,
};

/// `assessment_row` - the LIST shape. NO `pool` and NO `questions`: the choice
/// and the pick both ride only on a detail route. This absence is the bug.
Map<String, dynamic> get listRow => <String, dynamic>{
  'id': '7',
  'name': 'test_cj',
  'state': 'draft',
  'active': true,
  'duration_minutes': 45,
  'question_limit': 0,
  'generator': <String, dynamic>{'id': 3, 'name': 'SOP alpha'},
  'assigned_count': 0,
  'submitted_count': 0,
  'response_count': 0,
};

/// `assessment_detail` - the same assessment plus the one thing only this route
/// carries. Rows 1 and 3 arrive ticked, so `inUseIds` is `{'1', '3'}` and the
/// tab reads "2 of 4 in use" before anybody touches it.
Map<String, dynamic> get detailRow => <String, dynamic>{
  ...listRow,
  'pool': <Map<String, dynamic>>[
    poolRow(1, inUse: true),
    poolRow(2, inUse: false),
    poolRow(3, inUse: true),
    poolRow(4, inUse: false),
  ],
};

/// What the server changed since the last call, per route.
///
/// The preservation cases below all need the two shapes to say DIFFERENT things
/// on the same key - a pool of three where four were held, a `state` the list
/// route has moved on and the detail route has not - and the only honest way to
/// get that is to let each route's answer be edited between two calls. Spread
/// LAST, so an overlay wins over the base fixture, including on `pool`.
///
/// Both default to empty and [buildStore] clears them, so with nothing set the
/// rig answers exactly what it answered before these existed: the three cases
/// above are untouched by this.
Map<String, dynamic> listOverlay = <String, dynamic>{};
Map<String, dynamic> detailOverlay = <String, dynamic>{};

Map<String, dynamic> get listPayload => <String, dynamic>{
  ...listRow,
  ...listOverlay,
};

Map<String, dynamic> get detailPayload => <String, dynamic>{
  ...detailRow,
  ...detailOverlay,
};

/// ORDER MATTERS, and it is the whole rig. `/assessments/7/update` also
/// CONTAINS `/assessments/`, so the write has to be matched before the detail
/// route or the store would parse a write response as a fresh record. And
/// `/assessments` has to be matched before `/assessments/` for the same reason
/// in reverse: the list is the one route that must answer with the thin shape.
Map<String, dynamic> envelopeFor(String path) {
  if (path.endsWith('/update')) {
    return <String, dynamic>{'ok': true, 'data': detailPayload};
  }
  if (path.endsWith('/assessments')) {
    return <String, dynamic>{
      'ok': true,
      'data': <dynamic>[listPayload],
      'meta': <String, dynamic>{'total': 1, 'has_more': false},
    };
  }
  if (path.contains('/assessments/')) {
    return <String, dynamic>{'ok': true, 'data': detailPayload};
  }
  // Every other slot `_loadAdmin` waits on - bank, tags, generators, settings,
  // responses, ledger, budget, leaderboard, analytics, forms. None of them is
  // the subject; they only have to resolve so the console load completes.
  return <String, dynamic>{
    'ok': true,
    'data': <dynamic>[],
    'meta': <String, dynamic>{'total': 0, 'has_more': false},
  };
}

/// Records the path of every request, so a fixture mistake reads as a fixture
/// mistake rather than as the bug.
List<String> paths = <String>[];

AppStore buildStore() {
  paths = <String>[];
  // Top-level state, so it has to be cleared per case or the order the cases
  // happen to run in becomes part of what they assert.
  listOverlay = <String, dynamic>{};
  detailOverlay = <String, dynamic>{};
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      client: MockClient((http.Request req) async {
        paths.add(req.url.path);
        return http.Response(
          jsonEncode(envelopeFor(req.url.path)),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    ),
  );
  addTearDown(s.dispose);
  s.adoptSession(
    orgRole: 'admin',
    name: 'Aarav Mehta',
    uid: '2',
    accessRoleWire: AccessRole.admin.wire,
    capabilities: Capability.values.toSet(),
  );
  return s;
}

Assessment held(AppStore s) =>
    s.assessments.firstWhere((Assessment a) => a.id == '7');

void main() {
  // `testWidgets` throughout, even where nothing is a widget: `adoptSession`
  // fires `refresh()` fire-and-forget, and that list load has to be DRAINED
  // before the detail fetch or the two race - a refresh landing after the
  // hydration would empty the pool early and the failure would read as a
  // fixture bug instead of the merge. `pumpAndSettle` drains it, and it also
  // keeps the load from notifying a store the tear-down has disposed.
  Future<void> drainFirstLoad(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets('the pool survives a background refresh', (
    WidgetTester tester,
  ) async {
    final AppStore s = buildStore();
    await drainFirstLoad(tester);

    // Guard the guard: the list route has to have been asked, with the thin
    // shape, or nothing below is testing a merge at all.
    expect(paths, contains('/api/v1/assessments'));
    expect(held(s).pool, isEmpty, reason: 'a list row carries no pool');

    await s.loadAssessment('7');
    expect(
      held(s).pool.length,
      4,
      reason: 'the detail route sends the whole choice under `pool`',
    );

    // Exactly what `_act` runs after EVERY mutation, the shortlist save
    // included - and what the failure-recovery retry and the violation
    // reconciliation run too.
    await s.refresh(background: true);

    expect(
      held(s).pool.length,
      4,
      reason: 'the list row carries no `pool` key, so it must not overwrite '
          'the four rows the detail route just hydrated',
    );
    expect(
      held(s).pool.map((Question q) => q.id).toList(),
      <String>['1', '2', '3', '4'],
      reason: 'and it must be the SAME four, in the same order',
    );
  });

  testWidgets('the ticks survive with it', (WidgetTester tester) async {
    final AppStore s = buildStore();
    await drainFirstLoad(tester);

    await s.loadAssessment('7');
    expect(
      held(s).inUseIds,
      <String>{'1', '3'},
      reason: 'rows 2 and 4 arrive `in_use: false`',
    );

    await s.refresh(background: true);

    // `inUseIds` has no key of its own on the wire - `Assessment.fromJson`
    // derives it from the pool rows' `in_use` flags - so it can only ride
    // `sent('pool')`. What THIS case pins is the ticks surviving a list
    // refresh, which is the half the operator sees.
    //
    // It does NOT catch splitting the signal, and that was measured: gate
    // `inUseIds` on `sent('inUseIds')` instead and all three cases here still
    // pass, because a signal that is always FALSE on a list row is
    // indistinguishable from "keep old" in THIS direction - and `old.inUseIds`
    // is already `{'1', '3'}` when the refresh lands. The split is caught by
    // the preservation group below: `a detail row still WINS on pool`
    // (expected `{'2', '4'}`, actual `{'1'}`) and `an operator who genuinely
    // empties a shortlist reaches empty` (expected empty, actual
    // `{'1', '3'}`). Only a split onto a key the list row DOES carry would
    // fail here.
    expect(
      held(s).inUseIds,
      <String>{'1', '3'},
      reason: 'the shortlist is derived from the pool rows, so it has to be '
          'preserved on the same signal as the pool',
    );
    expect(held(s).inUseCount, 2);
  });

  testWidgets('ticking a question does not empty the tab', (
    WidgetTester tester,
  ) async {
    // The grid declares minWidth 880 and the page adds a header, a tab bar and
    // the shortlist strip above four rows, so the default 800x600 viewport
    // would overflow and read as a layout bug rather than an assertion.
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final AppStore s = buildStore();
    await drainFirstLoad(tester);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        // The screen navigates through `context.nav`, so the scope has to be
        // present or a row tap throws instead of asserting.
        home: AssessmentNavScope(
          nav: AssessmentNav(),
          child: Scaffold(
            body: AssessmentDetailScreen(
              store: s,
              portal: Portal.admin,
              asmId: '7',
              tab: 'questions',
            ),
          ),
        ),
      ),
    );
    // `initState` starts the detail fetch; this lands it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('2 of 4 in use'), findsOneWidget);
    expect(find.byIcon(Icons.check_box), findsNWidgets(2));
    expect(find.byIcon(Icons.check_box_outline_blank), findsNWidgets(2));

    // PUT A THIRD QUESTION IN, rather than taking one out. Same code path
    // either way, and this direction is the operator's own report: an empty box
    // is the one thing on the row that says a tick is something a person puts
    // there, and adding one is what they were doing when the tab vanished.
    await tester.tap(find.byIcon(Icons.check_box_outline_blank).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.text('3 of 4 in use'),
      findsOneWidget,
      reason: 'the optimistic update lands under the cursor, before the wire',
    );

    // Past the 600ms `_shortlistSync` debounce, then past the toast's 3.2s
    // dismissal - which is also long enough for `_act`'s trailing
    // `refresh(background: true)` to land. This is where the tab emptied.
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 3300));

    for (final String name in <String>['Q1', 'Q2', 'Q3', 'Q4']) {
      expect(
        find.text(name),
        findsOneWidget,
        reason: '$name was on screen a moment ago and nothing removed it',
      );
    }
    expect(
      find.textContaining('3 of 4 in use'),
      findsOneWidget,
      reason: 'the badge, the strip and the table body have to agree with the '
          'save the operator just made',
    );
    expect(
      find.textContaining('Pick a question generator'),
      findsNothing,
      reason: 'the draft empty state over a populated shortlist is the report',
    );
  });

  // The fix is two `copyWith` entries under one `sent('pool')` test, and every
  // case in here is GREEN ON UNFIXED CODE and has to stay green after. That is
  // the whole point: the three cases above measure what changes, these measure
  // what must not, and a case that only passes on one side of the fix belongs
  // in the other group. Each one names the plausible wrong fix it rules out.
  group('what the fix must not break', () {
    testWidgets('a detail row still WINS on pool', (
      WidgetTester tester,
    ) async {
      // RULES OUT the over-correction: preserving `old.pool` unconditionally,
      // or on an emptiness test, which would pin the tab to whatever the first
      // detail fetch happened to return and make a retired question immortal.
      // Preservation is for the row that DIDN'T send the key. A row that did
      // still wins, whichever route carried it.
      final AppStore s = buildStore();
      await drainFirstLoad(tester);

      await s.loadAssessment('7');
      expect(held(s).pool.length, 4);
      expect(held(s).inUseIds, <String>{'1', '3'});

      // Q2 is retired from the generator and Q3 is unticked from another tab,
      // so the detail route now answers three rows with one tick.
      detailOverlay = <String, dynamic>{
        'pool': <Map<String, dynamic>>[
          poolRow(1, inUse: true),
          poolRow(3, inUse: false),
          poolRow(4, inUse: false),
        ],
      };
      await s.loadAssessment('7');

      expect(
        held(s).pool.map((Question q) => q.id).toList(),
        <String>['1', '3', '4'],
        reason: 'a second detail fetch replaces the record wholesale - it does '
            'not go through the merge at all, and must not start to',
      );
      expect(held(s).inUseIds, <String>{'1'});
      expect(held(s).inUseCount, 1);

      // And the same claim through the merge itself. `assessment_row` never
      // carries `pool` server-side, so this row is the fixture reaching past
      // the real shape on purpose: it is the only way to exercise the TRUE
      // branch of `sent('pool')`, which is the branch the fix leaves alone.
      listOverlay = <String, dynamic>{
        'pool': <Map<String, dynamic>>[
          poolRow(2, inUse: true),
          poolRow(4, inUse: true),
        ],
      };
      await s.refresh(background: true);

      expect(
        held(s).pool.map((Question q) => q.id).toList(),
        <String>['2', '4'],
        reason: 'the key is present, so the fresh value lands exactly as it '
            'does today',
      );
      expect(held(s).inUseIds, <String>{'2', '4'});
    });

    testWidgets('an operator who genuinely empties a shortlist reaches empty', (
      WidgetTester tester,
    ) async {
      // THIS IS THE CASE THAT STOPS AN EMPTINESS-BASED FIX, and it is the
      // reason the gate is `jget(row, 'pool') != null` rather than
      // `fresh.pool.isNotEmpty`. Write it the tempting way -
      // `fresh.pool.isEmpty ? old.pool : fresh.pool` - and the three cases
      // above still pass while this one fails, holding four dead rows on a
      // record the server says has none. An operator who empties something has
      // to be able to reach empty; the merge preserves absence, not emptiness.
      final AppStore s = buildStore();
      await drainFirstLoad(tester);

      await s.loadAssessment('7');
      expect(held(s).pool.length, 4, reason: 'four rows are held to begin with');

      // Both routes now SEND the key, with nothing in it. Both, rather than
      // just the list route, so that a stray detail fetch cannot repopulate
      // the pool and turn a real failure into a confusing one.
      detailOverlay = <String, dynamic>{'pool': <dynamic>[]};
      listOverlay = <String, dynamic>{'pool': <dynamic>[]};
      await s.refresh(background: true);

      expect(
        held(s).pool,
        isEmpty,
        reason: 'a sent-but-empty pool is a real state, not an absent one',
      );
      expect(
        held(s).inUseIds,
        isEmpty,
        reason: 'and the ticks go with it, on the same signal - '
            '`Assessment.fromJson` derives them from the pool rows it was '
            'given, and it was given none',
      );
      expect(held(s).inUseCount, 0);
    });

    testWidgets('the list row still owns state, active and the counters', (
      WidgetTester tester,
    ) async {
      // RULES OUT freezing the record. The merge exists to keep detail-only
      // fields, and the failure mode on the other side of it is preserving too
      // much: an assessment that has been launched, archived and answered
      // still reading "Draft / 0 assigned" because a detail fetch got there
      // first. `state`, `active`, `name`, `questionLimit` and the seven
      // roll-up counters are the LIST route's to report - a detail fetch does
      // not make them stale, it makes them old.
      final AppStore s = buildStore();
      await drainFirstLoad(tester);

      await s.loadAssessment('7');
      expect(held(s).state, AsmState.draft);
      expect(held(s).active, isTrue);
      expect(held(s).assignedCount, 0);
      expect(held(s).submittedCount, 0);
      expect(held(s).responseCount, 0);

      // Launched, renamed, sat by twelve people and then archived, all from
      // somewhere this store never looked. The detail row is deliberately left
      // on its original `state` and zeroed counters, so anything that took the
      // held values instead of the fresh ones fails here rather than passing
      // on a coincidence.
      listOverlay = <String, dynamic>{
        'state': 'in_progress',
        'active': false,
        'name': 'test_cj (renamed)',
        'question_limit': 8,
        'assigned_count': 12,
        'submitted_count': 5,
        'response_count': 41,
      };
      await s.refresh(background: true);

      expect(
        held(s).state,
        AsmState.inProgress,
        reason: 'the whole editability gate hangs off this - a frozen `draft` '
            'would leave the Configuration tab writable on a live sitting',
      );
      expect(held(s).active, isFalse, reason: 'an archive still takes effect');
      expect(held(s).name, 'test_cj (renamed)');
      expect(held(s).questionLimit, 8);
      expect(held(s).assignedCount, 12);
      expect(held(s).submittedCount, 5);
      expect(held(s).responseCount, 41);
    });

    testWidgets('the 14 already-preserved fields are untouched', (
      WidgetTester tester,
    ) async {
      // The change is ADDITIVE - two entries beside the fourteen - and this is
      // the case that says so. `questions` and `roster` are the two the merge
      // was written for in the first place (the "0 questions" launch gate and
      // the "Nobody is assigned yet" Assign tab), so if adding `pool` disturbed
      // the list at all, it shows up here first.
      final AppStore s = buildStore();
      await drainFirstLoad(tester);

      detailOverlay = <String, dynamic>{
        'questions': <Map<String, dynamic>>[paperRow(101), paperRow(102)],
        'roster': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': '31',
            'name': 'Priya Raman',
            'email': 'priya.raman@ethara.ai',
            'pod': 'Delta',
          },
          <String, dynamic>{
            'id': '32',
            'name': 'Omar Haddad',
            'email': 'omar.haddad@ethara.ai',
            'pod': 'Delta',
          },
        ],
      };
      await s.loadAssessment('7');
      expect(held(s).questions.length, 2);
      expect(held(s).roster.length, 2);

      await s.refresh(background: true);

      expect(
        held(s).questions.map((Question q) => q.id).toList(),
        <String>['101', '102'],
        reason: 'the frozen paper survives a list refresh, as it has since the '
            'merge was written',
      );
      expect(
        held(s).roster.map((Person p) => p.email).toList(),
        <String>['priya.raman@ethara.ai', 'omar.haddad@ethara.ai'],
        reason: 'and so do the invited people, who exist nowhere else before '
            'launch creates their attempts',
      );
    });

    testWidgets('effectiveQuestionCount and totalQuestions are unchanged', (
      WidgetTester tester,
    ) async {
      // TWO COUNTS OFF TWO DIFFERENT LISTS, and the merge must not blur them.
      // `totalQuestions` is `questions.length` - the paper a candidate sat and
      // the denominator their marks are scored out of. `effectiveQuestionCount`
      // is `pool.isEmpty ? questions.length : inUseCount` - what would go out
      // if the operator launched now. Preserving `pool` puts a second populated
      // list on the record, so the temptation is to route one of these through
      // it; neither may move.
      //
      // The fixture is deliberately INCOHERENT - a frozen paper of two over a
      // pool of four - because that is the only way to prove which list each
      // getter reads. On a real record the two agree from launch onwards, which
      // is exactly why a coherent fixture could not tell them apart.
      final AppStore s = buildStore();
      await drainFirstLoad(tester);

      detailOverlay = <String, dynamic>{
        'questions': <Map<String, dynamic>>[paperRow(101), paperRow(102)],
      };
      await s.loadAssessment('7');

      expect(
        held(s).totalQuestions,
        2,
        reason: 'reads `questions`, and the pool of four is not it',
      );
      expect(
        held(s).effectiveQuestionCount,
        2,
        reason: 'the pool is populated, so this is `inUseCount` - rows 1 and 3 '
            'are ticked. Equal to `totalQuestions` by coincidence of count, '
            'not by reading the same list, which the next two assertions show',
      );
      expect(
        held(s).effectiveQuestions.map((Question q) => q.id).toList(),
        <String>['1', '3'],
        reason: 'POOL ids, not paper ids - the two lists share no id at all',
      );
      expect(held(s).inUseCount, 2);

      // Now empty the pool the legitimate way - the key present, nothing in it
      // - and the documented fallback has to still be there. This is the one
      // shape `effectiveQuestionCount` was given a fallback FOR: a list row, or
      // seed data, that carries no pool at all.
      listOverlay = <String, dynamic>{'pool': <dynamic>[]};
      detailOverlay = <String, dynamic>{
        'questions': <Map<String, dynamic>>[paperRow(101), paperRow(102)],
        'pool': <dynamic>[],
      };
      await s.refresh(background: true);

      expect(
        held(s).totalQuestions,
        2,
        reason: 'unmoved: `questions` is preserved by the merge and the marks '
            'denominator has nothing to do with the shortlist',
      );
      expect(
        held(s).effectiveQuestionCount,
        2,
        reason: 'the pool is empty, so it falls back to `questions.length` - '
            'the same 2, now off the other list',
      );
      expect(
        held(s).effectiveQuestions.map((Question q) => q.id).toList(),
        <String>['101', '102'],
        reason: 'and THIS is where the two lists separate: the same count as '
            'before, out of the paper rather than the pool',
      );
    });
  });
}
