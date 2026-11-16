// The Candidates tab reads ONE assessment's roster from the server, and pages
// and searches it there.
//
// WHAT WAS WRONG. The tab filtered `AppStore.attempts` - the console-wide walk
// of `/api/v1/attempts`. That route paged by `create_date desc` over a cohort
// invited in one transaction, so every row carried an identical `create_date`
// and offset paging over the unstable sort returned some rows twice and others
// never: 2,538 rows collected, 2,077 distinct, measured on stage. Searching that
// sample is why `aahan` on assessment 58 rendered one candidate TWICE and why
// the same query on assessment 60 said "No candidate matches these filters"
// while the server held two matches.
//
// WHAT THIS FILE ASSERTS. Not just that the right route is called - that would
// pass against an implementation that fetches on every rebuild, or one that
// fires a request per keystroke. A search box wired straight to `onChanged`
// against a pool that already sheds load at capacity is a self-inflicted
// outage, so the debounce, the page-1 reset and the last-write-wins guard are
// asserted as behaviour, and every test that can count requests does.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';

/// One request the client made, with the body it sent.
class Call {
  Call(this.path, this.body);
  final String path;
  final Map<String, dynamic> body;

  String get search => (body['search'] as String?) ?? '';
  String get state => (body['state'] as String?) ?? '';
  int get limit => (body['limit'] as num?)?.toInt() ?? -1;
  int get offset => (body['offset'] as num?)?.toInt() ?? -1;

  @override
  String toString() => '$path search=$search state=$state '
      'limit=$limit offset=$offset';
}

Map<String, dynamic> asmRow(String id) => <String, dynamic>{
  'id': id,
  'name': 'Q7r + Grade & Fix (copy)',
  'state': 'done',
  'active': true,
  'assigned_count': 572,
};

Map<String, dynamic> attemptRow(String id, String name, {String state = 'submitted'}) => <String, dynamic>{
  'id': id,
  'assessment_id': '58',
  'candidate': <String, dynamic>{'id': 'p$id', 'name': name},
  'state': state,
  'answered_count': 13,
  'total_questions': 19,
};

/// A cohort of 572, served a page at a time by the roster route.
///
/// The names are the two the stage reproduction turned on: `aahan` matches both
/// "Aahan Trikha" and "Jaahanvi", which is why a substring predicate rather than
/// a prefix one is the thing under test.
class _Rig {
  _Rig({this.slowTerm = '', this.slow = Duration.zero, this.rosterFails = false});

  /// The roster route answers a 500 instead of a page. An expired session, a
  /// dropped connection and a server error all land the same way: `loadRoster`
  /// catches the [ApiError], empties the rows and zeroes `rosterTotal`.
  final bool rosterFails;

  /// A term whose response is DELAYED, so a stale answer can be raced against a
  /// later one.
  final String slowTerm;
  final Duration slow;

  final List<Call> calls = <Call>[];
  late final AppStore store;

  static const int cohort = 572;

  List<Call> get roster =>
      calls.where((Call c) => c.path.endsWith('/candidates')).toList();

  void init() {
    store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          final Map<String, dynamic> body =
              jsonDecode(req.body) as Map<String, dynamic>;
          calls.add(Call(path, body));

          if (path.endsWith('/candidates')) {
            if (rosterFails) {
              return http.Response(
                jsonEncode(<String, dynamic>{
                  'ok': false,
                  'error': <String, dynamic>{
                    'code': 'server_error',
                    'message': 'Internal Server Error',
                  },
                }),
                500,
                headers: <String, String>{
                  'content-type': 'application/json',
                },
              );
            }
            final String term = (body['search'] as String?) ?? '';
            if (term.isNotEmpty && term == slowTerm) {
              await Future<void>.delayed(slow);
            }
            // A searched cohort is small; an unsearched one is 572 and pages.
            final List<Map<String, dynamic>> matches = term.isEmpty
                ? <Map<String, dynamic>>[
                    // THE COHORT SPANS EVERY STATE. It was uniformly
                    // `submitted`, which hid the other two chips entirely -
                    // so the state-chip test could only ever tap the one
                    // value whose Dart name equals its wire spelling, and
                    // the `inProgress` -> `in_progress` break was invisible
                    // to this file.
                    for (int i = 0; i < cohort; i++)
                      attemptRow(
                        '${1000 + i}',
                        'Candidate $i',
                        state: AttemptState.values[i % 3].wire,
                      ),
                  ]
                : <Map<String, dynamic>>[
                    // The term is BRACKETED so one response can be told from
                    // another: without the brackets 'Aahan Trikha aa' is a
                    // substring of 'Aahan Trikha aahan' and the stale-response
                    // test passes for the wrong reason.
                    attemptRow('1723', 'Aahan Trikha [$term]'),
                    attemptRow('1481', 'Jaahanvi [$term]'),
                  ];
            final int limit = (body['limit'] as num?)?.toInt() ?? 40;
            final int offset = (body['offset'] as num?)?.toInt() ?? 0;
            final List<Map<String, dynamic>> page = matches
                .skip(offset)
                .take(limit)
                .toList();
            return _json(page, total: matches.length);
          }
          if (path.endsWith('/assessments')) return _json(<dynamic>[asmRow('58')]);
          if (path.endsWith('/attempts')) return _json(<dynamic>[]);
          if (RegExp(r'/assessments/[^/]+$').hasMatch(path)) {
            return _json(asmRow('58'));
          }
          return _json(<String, dynamic>{});
        }),
        baseUrl: 'http://x',
      ),
    );
  }

  static http.Response _json(Object data, {int? total}) => http.Response(
    jsonEncode(<String, dynamic>{
      'ok': true,
      'data': data,
      if (data is List)
        'meta': <String, dynamic>{
          'total': total ?? data.length,
          'limit': 200,
          'offset': 0,
          'has_more': false,
        },
    }),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );

  /// SCROLLABLE, like the real shell (`assessment_section.dart:309`). A page of
  /// 100 rows is ~4,600px of table, so an unscrolled host throws a RenderFlex
  /// overflow during layout and masks every assertion below it.
  Widget app() => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: AssessmentNavScope(
        nav: AssessmentNav(),
        child: SingleChildScrollView(
          child: AssessmentDetailScreen(
            store: store,
            portal: Portal.admin,
            asmId: '58',
            tab: 'candidates',
          ),
        ),
      ),
    ),
  );
}

// ignore: library_private_types_in_public_api
_Rig rig({
  String slowTerm = '',
  Duration slow = Duration.zero,
  bool rosterFails = false,
}) {
  final _Rig r = _Rig(
    slowTerm: slowTerm,
    slow: slow,
    rosterFails: rosterFails,
  );
  r.init();
  return r;
}

void main() {
  void desktop(WidgetTester t) {
    t.view.physicalSize = const Size(1600, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  group('opening the tab', () {
    testWidgets('reads the roster route ONCE, and no more than one page', (
      WidgetTester t,
    ) async {
      desktop(t);
      final _Rig r = rig();
      await r.store.refresh();
      await t.pumpWidget(r.app());
      await t.pumpAndSettle();

      expect(r.roster.length, 1, reason: 'one request opens the tab');
      // THE CLAMP. The route refuses anything above 200 and quietly applies 40
      // when it gets nothing, so a page size outside that window would page a
      // different number of rows than the control displays.
      expect(r.roster.single.limit, lessThanOrEqualTo(200));
      expect(r.roster.single.limit, greaterThan(0));
      expect(r.roster.single.offset, 0);
    });

    testWidgets('the rows are the route\'s, and the count is the server\'s', (
      WidgetTester t,
    ) async {
      desktop(t);
      final _Rig r = rig();
      await r.store.refresh();
      await t.pumpWidget(r.app());
      await t.pumpAndSettle();

      // `/attempts` answered with NOTHING in this rig, so a tab still reading
      // the console-wide cache would render an empty table over a 572-person
      // cohort - which is the pre-fix failure in miniature.
      expect(find.text('Candidate 0'), findsOneWidget);
      expect(r.store.rosterTotalFor('58'), _Rig.cohort);
      expect(
        r.store.rosterRowsFor('58').length,
        lessThan(_Rig.cohort),
        reason: 'one page, not the cohort',
      );
      // `meta.total` drives what the operator reads, not the rows in hand.
      expect(find.textContaining('of 572'), findsOneWidget);
    });

    testWidgets('another assessment\'s rows are never served', (
      WidgetTester t,
    ) async {
      desktop(t);
      final _Rig r = rig();
      await r.store.refresh();
      await t.pumpWidget(r.app());
      await t.pumpAndSettle();

      expect(r.store.rosterRowsFor('58'), isNotEmpty);
      expect(
        r.store.rosterRowsFor('60'),
        isEmpty,
        reason: 'the cache is tagged with the assessment it holds, so it cannot '
            'hand assessment 58\'s cohort to assessment 60',
      );
      expect(r.store.rosterTotalFor('60'), 0);
    });
  });

  group('searching', () {
    testWidgets('five keystrokes cost ONE request, not five', (
      WidgetTester t,
    ) async {
      desktop(t);
      final _Rig r = rig();
      await r.store.refresh();
      await t.pumpWidget(r.app());
      await t.pumpAndSettle();
      final int afterOpen = r.roster.length;

      // Typed, not pasted: `SearchField.onChanged` fires per character.
      for (final String term in <String>['a', 'aa', 'aah', 'aaha', 'aahan']) {
        await t.enterText(find.byType(TextFormField).first, term);
        await t.pump(const Duration(milliseconds: 40));
      }
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(
        r.roster.length - afterOpen,
        1,
        reason: 'debounced at 250ms: five characters inside the window are one '
            'search. Unthrottled this is five round trips per word typed, on a '
            'route a 572-row cohort makes expensive',
      );
      expect(r.roster.last.search, 'aahan');
      expect(
        r.roster.last.offset,
        0,
        reason: 'a new term starts at page 1 - page 4 of "aahan" is not page 4 '
            'of the cohort',
      );
    });

    testWidgets('the term reaches the server, and both matches come back', (
      WidgetTester t,
    ) async {
      desktop(t);
      final _Rig r = rig();
      await r.store.refresh();
      await t.pumpWidget(r.app());
      await t.pumpAndSettle();

      await t.enterText(find.byType(TextFormField).first, 'aahan');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      // The stage reproduction, inverted: TWO DISTINCT rows for `aahan`, where
      // the local filter over a corrupted walk rendered one row twice.
      expect(find.textContaining('Aahan Trikha'), findsOneWidget);
      expect(find.textContaining('Jaahanvi'), findsOneWidget);
      expect(r.store.rosterTotalFor('58'), 2);
    });

    testWidgets('a slow early response cannot paint over a later one', (
      WidgetTester t,
    ) async {
      desktop(t);
      // 'aa' takes 600ms; 'aahan' answers immediately. Without a guard the
      // late-arriving 'aa' overwrites the rows for 'aahan' and the table
      // flickers back to results the operator has already typed past.
      final _Rig r = rig(slowTerm: 'aa', slow: const Duration(milliseconds: 600));
      await r.store.refresh();
      await t.pumpWidget(r.app());
      await t.pumpAndSettle();

      await t.enterText(find.byType(TextFormField).first, 'aa');
      await t.pump(const Duration(milliseconds: 300)); // debounce fires
      await t.enterText(find.byType(TextFormField).first, 'aahan');
      await t.pump(const Duration(milliseconds: 300)); // second search fires
      await t.pump(const Duration(milliseconds: 800)); // the slow one lands
      await t.pumpAndSettle();

      expect(
        r.store.rosterSearch,
        'aahan',
        reason: 'the newest term is the one the cache answers',
      );
      expect(find.textContaining('[aahan]'), findsWidgets);
      expect(
        find.textContaining('[aa]'),
        findsNothing,
        reason: 'the abandoned search must not be adopted when it finally '
            'arrives - last write wins is enforced by a sequence number, not '
            'by hoping responses come back in order',
      );
    });

    testWidgets('clearing the box goes back to the whole cohort', (
      WidgetTester t,
    ) async {
      desktop(t);
      final _Rig r = rig();
      await r.store.refresh();
      await t.pumpWidget(r.app());
      await t.pumpAndSettle();

      await t.enterText(find.byType(TextFormField).first, 'aahan');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(r.store.rosterTotalFor('58'), 2);

      await t.enterText(find.byType(TextFormField).first, '');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(r.store.rosterTotalFor('58'), _Rig.cohort);
      expect(r.roster.last.search, '', reason: 'no term is sent, not an empty '
          'one the server would have to interpret');
    });
  });

  group('paging', () {
    testWidgets('the next page is a request, not a slice', (
      WidgetTester t,
    ) async {
      desktop(t);
      final _Rig r = rig();
      await r.store.refresh();
      await t.pumpWidget(r.app());
      await t.pumpAndSettle();
      final int size = r.roster.single.limit;
      final int afterOpen = r.roster.length;

      // The footer sits below a 100-row table, so it has to be scrolled to
      // before it can be pressed - the same thing an operator does.
      await t.ensureVisible(find.text('Next'));
      await t.pumpAndSettle();
      await t.tap(find.text('Next'));
      await t.pumpAndSettle();

      expect(r.roster.length - afterOpen, 1, reason: 'one page, one request');
      expect(
        r.roster.last.offset,
        size,
        reason: 'server-side offset, so page 2 is the server\'s page 2 rather '
            'than a slice of whatever the client happened to hold',
      );
      expect(r.roster.last.limit, lessThanOrEqualTo(200));
    });

    testWidgets('no page can exceed the route\'s 200-row clamp', (
      WidgetTester t,
    ) async {
      desktop(t);
      final _Rig r = rig();
      await r.store.refresh();
      await t.pumpWidget(r.app());
      await t.pumpAndSettle();

      // Every size the control offers, straight through the store.
      for (final int n in <int>[10, 20, 50, 100, 200, 500]) {
        await r.store.loadRoster('58', pageSize: n);
      }
      for (final Call c in r.roster) {
        expect(c.limit, lessThanOrEqualTo(200), reason: '$c');
        expect(c.limit, greaterThan(0), reason: '$c');
      }
    });
  });

  group('the polling path', () {
    testWidgets('30 seconds of generation polling adds no roster requests', (
      WidgetTester t,
    ) async {
      desktop(t);
      final _Rig r = rig();
      await r.store.refresh();
      await t.pumpWidget(r.app());
      await t.pumpAndSettle();
      final int afterOpen = r.roster.length;

      // `pollGeneration` runs `refresh(background: true)` every two seconds.
      // Fifteen of those is thirty seconds of a generation in flight.
      for (int i = 0; i < 15; i++) {
        await r.store.refresh(background: true);
        await t.pump(const Duration(seconds: 2));
      }
      await t.pumpAndSettle();

      expect(
        r.roster.length,
        afterOpen,
        reason: 'the roster is screen-owned. Joining the poll loop would put '
            '15 extra requests on a 30-second generation, per open tab',
      );
    });
  });

  group('states', () {
    testWidgets('a state chip filters on the server', (WidgetTester t) async {
      desktop(t);
      final _Rig r = rig();
      await r.store.refresh();
      await t.pumpWidget(r.app());
      await t.pumpAndSettle();
      final int afterOpen = r.roster.length;

      await t.tap(find.textContaining('Submitted').first);
      await t.pumpAndSettle();

      expect(r.roster.length - afterOpen, 1);
      expect(r.roster.last.state, 'submitted');
      expect(
        r.roster.last.offset,
        0,
        reason: 'a new filter starts at page 1',
      );
    });

    // EVERY STATE, not a representative one. The test above taps 'Submitted',
    // and `AttemptState.submitted` is one of the two values whose Dart
    // identifier happens to equal its wire spelling - so it passed while the
    // chip beside it was sending `inProgress` for a column the route stores as
    // `in_progress`, and "In progress 8" answered "No candidate matches these
    // filters" on a live 711-candidate cohort. A parameterised loop is the only
    // shape that cannot be fooled by picking the lucky value, and it also means
    // a state added later is covered on the day it is added.
    for (final AttemptState s in AttemptState.values) {
      testWidgets('the ${s.label} chip sends ${s.wire}, not its Dart name', (
        WidgetTester t,
      ) async {
        desktop(t);
        final _Rig r = rig();
        await r.store.refresh();
        await t.pumpWidget(r.app());
        await t.pumpAndSettle();
        final int afterOpen = r.roster.length;

        // BY TOOLTIP, not by label. The page's own Draft / In progress /
        // Done switcher carries the text "In progress" too, and tapping that
        // is a silent no-op for the roster - which is exactly how this test
        // first reported a failure that was its own, not the product's.
        await t.tap(
          find.byTooltip(
            'Show only candidates whose attempt is '
            '${s.label.toLowerCase()}',
          ),
        );
        await t.pumpAndSettle();

        expect(
          r.roster.length - afterOpen,
          1,
          reason: 'tapping a state chip is one roster request',
        );
        expect(
          r.roster.last.state,
          s.wire,
          reason:
              'the route matches this against the stored selection key, so '
              'anything but ${s.wire} returns an empty page while the chip '
              'still shows a count',
        );
        expect(r.roster.last.offset, 0, reason: 'a new filter starts at page 1');
      });
    }

    testWidgets('a failed roster read says so instead of reading as empty', (
      WidgetTester t,
    ) async {
      desktop(t);
      final AppStore s = AppStore(
        api: ApiClient(
          client: MockClient((http.Request req) async {
            if (req.url.path.endsWith('/candidates')) {
              return http.Response(
                jsonEncode(<String, dynamic>{
                  'ok': false,
                  'error': <String, dynamic>{
                    'code': 'server_error',
                    'message': 'the roster query timed out',
                  },
                }),
                500,
                headers: <String, String>{'content-type': 'application/json'},
              );
            }
            return _Rig._json(
              req.url.path.endsWith('/assessments')
                  ? <dynamic>[asmRow('58')]
                  : (req.url.path.endsWith('/attempts')
                        ? <dynamic>[]
                        : asmRow('58')),
            );
          }),
          baseUrl: 'http://x',
        ),
      );
      await s.refresh();

      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: AssessmentNavScope(
              nav: AssessmentNav(),
              child: SingleChildScrollView(
                child: AssessmentDetailScreen(
                  store: s,
                  portal: Portal.admin,
                  asmId: '58',
                  tab: 'candidates',
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      // "Nobody was assigned" and "the server could not answer" are different
      // facts, and only one of them is the operator's problem to act on.
      expect(find.textContaining('could not be loaded'), findsOneWidget);
      expect(find.textContaining('Nobody was assigned'), findsNothing);
    });
  });

  group('a roster the server could not answer', () {
    testWidgets('keeps the search box and the state chips', (
      WidgetTester t,
    ) async {
      // THE TOOLBAR IS THE WAY OUT, and it used to leave with the rows.
      // `loadRoster`'s failure path zeroes `rosterTotal`, and the whole control
      // row was gated on `total > 0 || filtered` - so with no filter set, one
      // failed request took the search box and every state chip away and left
      // an error message over bare column headers. The operator who came to
      // find one candidate then had nothing on screen to ask with.
      desktop(t);
      final _Rig r = rig(rosterFails: true);
      await r.store.refresh();
      await t.pumpWidget(r.app());
      await t.pumpAndSettle();

      expect(
        find.textContaining('could not be loaded'),
        findsOneWidget,
        reason: 'the failure is still reported - this must not pass by '
            'hiding the error instead of the controls',
      );
      expect(
        find.byType(SearchField),
        findsOneWidget,
        reason: 'searching is a fresh request, which is the only retry this '
            'screen offers',
      );
      expect(find.widgetWithText(Btn, 'Flagged'), findsOneWidget);
      for (final AttemptState st in AttemptState.values) {
        expect(
          find.widgetWithText(Btn, st.label),
          findsOneWidget,
          reason: '${st.label} chip',
        );
      }
    });
  });
}
