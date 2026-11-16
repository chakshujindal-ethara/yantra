// The grader's phase reaches the ASSESSMENTS LIST, and a stalled run ENDS the
// watch instead of arming one.
//
// TWO REPORTS, ONE FIELD. `scoring_phase` has ridden in on every list row
// since it shipped and this screen drew nothing with it, so "is anything being
// graded right now" was answerable only by opening papers one at a time -
// which on a 711-candidate cohort is the first question an operator asks. The
// module's own list has carried a Scoring column all along.
//
// And the phase that matters most is the one that must NOT be watched.
// `stalled` means work is queued and the cron that would drain it is dead, so
// nothing about it changes on its own: a poll armed there would run for the
// rest of the session waiting for an event that cannot arrive. That is why it
// is deliberately outside [ScoringPhase.isBusy] - and just as deliberately
// inside [ScoringPhase.isStoppable], because parking the queue is the one
// thing an operator can do about a dead cron from this console.
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
import 'package:ethara_assessment/assessment/screens/admin/assessment_list_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/data_grid.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:ethara_assessment/assessment/widgets/marks.dart';

/// Counts what each route was asked, so a watch can be proven to have stopped
/// rather than merely slowed down.
class _Spy {
  final List<String> paths = <String>[];

  /// Answers for `/scoring`, consumed in order so a test can walk a run from
  /// one phase to the next. The last entry repeats, because a poll that ran
  /// one tick more than expected must fail on the assertion rather than on a
  /// missing fixture.
  final List<Map<String, dynamic>> scoring;

  _Spy({List<Map<String, dynamic>>? scoring})
    : scoring = <Map<String, dynamic>>[...?scoring];

  int hits(String suffix) =>
      paths.where((String p) => p.endsWith(suffix)).length;

  http.Client get client => MockClient((http.Request req) async {
    paths.add(req.url.path);
    Map<String, dynamic> body = const <String, dynamic>{};
    if (req.url.path.endsWith('/scoring') && scoring.isNotEmpty) {
      body = scoring.length > 1 ? scoring.removeAt(0) : scoring.first;
    }
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': body}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
}

/// A list row built from a WIRE payload, on purpose.
///
/// `scoring_phase` / `scoring_summary` are what `assessment_row` actually
/// sends, so going through `fromJson` puts the snake_case keys under test
/// beside the cell that reads them. A rename on either side fails here rather
/// than quietly rendering a row with no mark and looking untouched.
///
/// [phase] null OMITS the key, which is the deployment that predates the
/// field - not the same thing as a server that answered `idle`.
Assessment _sent(String id, String name, {String? phase, String summary = ''}) =>
    Assessment.fromJson(<String, dynamic>{
      'id': id,
      'name': name,
      'state': 'done',
      'active': true,
      'scoring_phase': ?phase,
      'scoring_summary': summary,
    });

/// Every pill the grid drew, in the order it drew them.
///
/// The assertion is on the PILLS rather than on loose text: the toolbar's
/// state filter carries an option for each lifecycle label, so a bare
/// `find.text('Done')` would be answering a question about a dropdown.
List<String> _pills(WidgetTester t) => t
    .widgetList<Pill>(
      find.descendant(of: find.byType(DataGrid), matching: find.byType(Pill)),
    )
    .map((Pill p) => p.label)
    .toList();

Future<AppStore> _openList(
  WidgetTester t,
  List<Assessment> rows, {
  double width = 1600,
}) async {
  await t.binding.setSurfaceSize(Size(width, 1400));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final AppStore s = AppStore()..assessments = rows;
  // Explicit, so the width guard below measures the WIDEST the table ever
  // gets: the Archive/Restore slot collapses for a read-only Manager, and a
  // budget proven against the narrow version is not a budget.
  s.accessRole = AccessRole.admin;
  s.caps = Capability.values.toSet();
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: AssessmentNavScope(
        nav: AssessmentNav(),
        child: Scaffold(
          body: SingleChildScrollView(
            child: AssessmentListScreen(store: s, portal: Portal.admin),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return s;
}

/// The detail screen on `A-1`, pumped once rather than settled.
///
/// A settle waits out every animation, and the live readout's spinner is an
/// indeterminate `CircularProgressIndicator` that by design never ends. The
/// teardown is what runs `dispose` and cancels a poll the screen may have
/// armed; a test that just ends leaves the timer pending and fails the
/// binding's own invariant check.
Future<void> _openDetail(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1600, 2600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: AssessmentDetailScreen(
            store: s,
            portal: Portal.admin,
            asmId: 'A-1',
            tab: 'config',
          ),
        ),
      ),
    ),
  );
  await t.pump();
  addTearDown(() async => t.pumpWidget(const SizedBox.shrink()));
}

/// The detail record, carrying the server's phase on the wire keys.
Assessment _paper(String phase, {String summary = ''}) =>
    Assessment.fromJson(<String, dynamic>{
      'id': 'A-1',
      'name': 'Warehouse Safety',
      'state': 'in_progress',
      'scoring_phase': phase,
      'scoring_summary': summary,
    });

void main() {
  group('the list says what the grader is doing', () {
    testWidgets('a scoring row wears a Scoring pill UNDER its state', (
      WidgetTester t,
    ) async {
      await _openList(t, <Assessment>[
        _sent('1', 'Warehouse Safety', phase: 'scoring', summary: '238 queued'),
      ]);

      expect(
        _pills(t),
        <String>['Done', 'Scoring'],
        reason: 'the scoring mark STACKS under the lifecycle state, it does '
            'not replace it - the two answer different questions, and a row '
            'that dropped "Done" to say "Scoring" would have traded one '
            'missing fact for another',
      );
    });

    testWidgets('a stalled row says Not running', (WidgetTester t) async {
      await _openList(t, <Assessment>[
        _sent('1', 'Warehouse Safety', phase: 'stalled', summary: '1948 queued'),
      ]);

      expect(
        _pills(t),
        <String>['Done', 'Not running'],
        reason: 'a queue nobody is draining looks exactly like a large cohort '
            'from this list, and the only thing that tells them apart is this '
            'pill. The short label is what fits the column - the long form '
            'ellipsizes to "Grader Not..." and says nothing',
      );
    });

    testWidgets('an idle row wears NO scoring pill', (WidgetTester t) async {
      // Idle is the resting state of every finished paper, so a badge here is
      // a badge on every row - wallpaper, and it would dilute the two above.
      await _openList(t, <Assessment>[
        _sent('1', 'Warehouse Safety', phase: 'idle', summary: '464 scored'),
      ]);

      expect(
        _pills(t),
        <String>['Done'],
        reason: 'a finished paper must look exactly as it did before this '
            'shipped, and the state pill is still there - so this cannot be '
            'passing by rendering nothing at all',
      );
    });

    testWidgets('a row whose phase is ABSENT wears no scoring pill either', (
      WidgetTester t,
    ) async {
      // A deployment that predates the field sends nothing, and null is not
      // idle. Drawing a confident anything over a server that cannot say is
      // worse than silence, in either direction.
      await _openList(t, <Assessment>[_sent('1', 'Warehouse Safety')]);

      expect(_pills(t), <String>['Done']);
    });

    testWidgets('the table still fits a 996px content area', (
      WidgetTester t,
    ) async {
      // THE REASON THE MARK STACKS RATHER THAN TAKING A COLUMN OF ITS OWN.
      //
      // `DataGrid.minWidth` is 968 inside a ~996px content area (a 1280
      // viewport less the 240 rail and 44 page padding), and four funnel
      // columns were collapsed into one to get it there. A ~110px Scoring
      // column reintroduces exactly the sideways scroll that budget exists to
      // prevent - and because macOS hides scrollbars until you gesture, a
      // table past its pane does not look truncated. It looks like the last
      // columns were never built, which is how the Remarks and Flag columns
      // on the roster came to be reported missing.
      await _openList(t, <Assessment>[
        _sent('1', 'Warehouse Safety', phase: 'scoring', summary: '238 queued'),
        _sent('2', 'Forklift Handling', phase: 'stalled'),
        _sent('3', 'Cold Chain', phase: 'queued'),
      ], width: 996);

      expect(
        t.takeException(),
        isNull,
        reason: 'a row that overflows its flex is a layout fault, not a '
            'cosmetic one - the second pill must fit the cell it was added to',
      );

      // `DataGrid` wraps the table in a `Scrollbar` ONLY when it has decided
      // the table is wider than its box. Its absence is the direct proof, not
      // an inference from measured rectangles.
      expect(
        find.descendant(
          of: find.byType(DataGrid),
          matching: find.byType(Scrollbar),
        ),
        findsNothing,
        reason: 'the grid went into its horizontal-scrolling mode, which means '
            'the table no longer fits the content area a 1280 laptop gives it',
      );

      // And the same proof the roster's own budget test uses: every header is
      // reachable without scrolling.
      final Finder grid = find.byType(DataGrid);
      final List<String> offscreen = <String>[];
      for (final String h in const <String>[
        'ASSESSMENT', 'STATE', 'GENERATOR', 'QUESTIONS',
        'PROGRESS', 'CONDUCTED', 'DURATION',
      ]) {
        final Finder f = find.descendant(of: grid, matching: find.text(h));
        expect(f, findsOneWidget, reason: '$h is missing from the table');
        if (t.getRect(f.first).right > 996) offscreen.add(h);
      }
      expect(
        offscreen,
        isEmpty,
        reason: 'these columns need a horizontal scroll at 996px: '
            '${offscreen.join(", ")}',
      );
    });
  });

  group('a stalled run ends the watch', () {
    testWidgets('a screen opened on stalled never polls at the RUN\'s rate', (
      WidgetTester t,
    ) async {
      // THE FAILURE THIS TEST EXISTS FOR. Nothing an operator can wait for
      // settles a stalled queue - the cron that would drain it is dead - so a
      // watch armed here at the run's rate asks a question with one answer
      // twelve times a minute for as long as the tab is open. `stalled` is
      // outside `isBusy` precisely to make that impossible; what it gets
      // instead is the slow re-check below, one request a minute.
      final _Spy spy = _Spy();
      // An injected client is a live store on its own, with no `adoptSession` -
      // whose bootstrap `refresh()` would wipe the seeded record out from
      // under the widget before the first frame.
      final AppStore s = AppStore(
        api: ApiClient(baseUrl: 'http://stub', client: spy.client),
      )..assessments = <Assessment>[_paper('stalled', summary: '1948 queued')];
      await _openDetail(t, s);

      // Well past a dozen poll intervals at the run's rate, and past the
      // store's own notifies.
      await t.pump(const Duration(minutes: 5));
      await t.pump();
      s.notifyListeners();
      await t.pump(const Duration(minutes: 5));
      await t.pump();

      expect(
        spy.hits('/v1/scoring'),
        lessThanOrEqualTo(10),
        reason: 'ten minutes at the run\'s five seconds is 120 requests; the '
            'slow re-check spends one a minute, and a stalled queue must cost '
            'the second thing and not the first',
      );
    });

    testWidgets('and it is LOUD without a single tick', (WidgetTester t) async {
      // The banner rides in on the record rather than on the poll's answer,
      // which is what makes it free. Reading `_pipe` alone meant a deep link
      // to a stalled assessment showed nothing at all - and since no watch is
      // ever armed here, "nothing" would have lasted as long as the operator
      // stayed on the screen.
      final _Spy spy = _Spy();
      final AppStore s = AppStore(
        api: ApiClient(baseUrl: 'http://stub', client: spy.client),
      )..assessments = <Assessment>[_paper('stalled', summary: '1948 queued')];
      await _openDetail(t, s);

      expect(
        find.textContaining('Grading is not running.'),
        findsOneWidget,
        reason: 'silence over a dead grader reads as "the grader is fine"',
      );
      expect(
        spy.hits('/v1/scoring'),
        0,
        reason: 'and it said so on the first frame, before a tick could have '
            'run - the banner costs no request',
      );
    });

    testWidgets('a live run that goes stalled stops watching and re-reads', (
      WidgetTester t,
    ) async {
      // THE MID-RUN EDGE, and the reason `stalled` takes the busy -> not-busy
      // branch rather than a branch of its own: a run that will never end is
      // not a run that has ended, but everything the screen does about it is
      // the same. Cancel the watch, and spend one closing detail read putting
      // the warning and the settled roster on screen without the operator
      // touching anything.
      final _Spy spy = _Spy(
        scoring: <Map<String, dynamic>>[
          <String, dynamic>{'phase': 'stalled', 'summary': '1948 queued'},
        ],
      );
      final AppStore s = AppStore(
        api: ApiClient(baseUrl: 'http://stub', client: spy.client),
      )..assessments = <Assessment>[_paper('scoring', summary: '2 queued')];
      await _openDetail(t, s);

      final int detailReadsAtStart = spy.hits('/assessments/A-1');
      expect(spy.hits('/v1/scoring'), 0, reason: 'nothing polls before a tick');

      await t.pump(const Duration(seconds: 6));
      await t.pump();
      expect(spy.hits('/v1/scoring'), 1);
      // The closing read is spread over 0-5 s - see the backoff test.
      await t.pump(const Duration(seconds: 5));
      await t.pump();
      expect(
        spy.hits('/assessments/A-1'),
        detailReadsAtStart + 1,
        reason: 'the poll route answers counters, not rows, so without this '
            'one read the screen would announce that nothing is grading above '
            'the roster it held when grading began',
      );

      // And the RUN's watch is over, however long the screen stays open.
      await t.pump(const Duration(minutes: 10));
      await t.pump();
      expect(
        spy.hits('/v1/scoring'),
        lessThanOrEqualTo(11),
        reason: 'ten minutes at the run\'s rate is 120 requests - the phase '
            'left `isBusy`, so what is left is the once-a-minute re-check',
      );
      expect(
        spy.hits('/assessments/A-1'),
        detailReadsAtStart + 1,
        reason: 'and the closing read is worth exactly one - it is itself a '
            'notify, so an unguarded one fetches forever, and a re-check that '
            'keeps answering `stalled` is not a second run ending',
      );
    });

    testWidgets('a stalled queue is re-checked, and a run that resumes is '
        'watched again', (WidgetTester t) async {
      // THE OTHER HALF OF THAT EDGE, and the defect it closes. `stalled` is
      // not a terminal server state: `_scoring_drainer_health` recomputes
      // `blocked` from each cron's `active` and `nextcall` on every read, so
      // re-enabling the cron - exactly the remediation this screen's banner
      // asks for, performed in Odoo, on another tab - clears it. Cancelling
      // the last watch made the client's state terminal instead: no request of
      // any kind left this screen again, so a cohort that went on to grade to
      // completion sat under a red "Grading is not running." over the roster
      // it held at the stall, until somebody reloaded the browser.
      final _Spy spy = _Spy(
        scoring: <Map<String, dynamic>>[
          <String, dynamic>{'phase': 'scoring', 'summary': '2 queued'},
        ],
      );
      final AppStore s = AppStore(
        api: ApiClient(baseUrl: 'http://stub', client: spy.client),
      )..assessments = <Assessment>[_paper('stalled', summary: '1948 queued')];
      await _openDetail(t, s);

      await t.pump(const Duration(seconds: 30));
      await t.pump();
      expect(
        spy.hits('/v1/scoring'),
        0,
        reason: 'half a minute in, the run\'s rate would already have spent '
            'six requests',
      );

      await t.pump(const Duration(seconds: 40));
      await t.pump();
      expect(
        spy.hits('/v1/scoring'),
        greaterThan(0),
        reason: 'THE WAY BACK. A stalled phase can only change through a '
            'fetch, so a screen that stops fetching can never learn that the '
            'cron was restarted',
      );
      expect(
        s.asmById('A-1')!.scoringPhase,
        ScoringPhase.scoring,
        reason: 'and the re-check writes the resumed phase onto the record, '
            'which is what takes the red banner down',
      );

      final int atResume = spy.hits('/v1/scoring');
      await t.pump(const Duration(seconds: 12));
      await t.pump();
      expect(
        spy.hits('/v1/scoring'),
        greaterThan(atResume),
        reason: 'a resumed run is followed at the RUN\'s rate again - the '
            'slow re-check is for a queue nobody is draining, not for one '
            'that is moving',
      );
    });

    testWidgets('a busy paper under a stalled machine still shows ONE banner', (
      WidgetTester t,
    ) async {
      // THE TWO SIGNALS DO NOT EXCLUDE EACH OTHER, and read as an `||` they
      // stacked. `drainer.stalled` is cohort-wide (a higher shard disabled
      // under `scoring_shards = 1`, or any cron past its `nextcall`), while
      // `_compute_scoring_progress` checks `running` BEFORE it consults that
      // health - so a shard actively holding a row on THIS paper answers
      // `phase: scoring` beside `drainer.stalled: true`. On screen that was a
      // red "Grading is not running." directly above a blue "Scoring." with a
      // live spinner, and an operator acts on the red one: kills a healthy run,
      // or files an outage.
      final _Spy spy = _Spy(
        scoring: <Map<String, dynamic>>[
          <String, dynamic>{
            'phase': 'scoring',
            'summary': '238 queued  ·  1 scoring',
            'drainer': <String, dynamic>{
              'stalled': true,
              'reason': '3 of 4 grading cron(s) inactive and 238 answer(s) '
                  'queued',
            },
          },
        ],
      );
      final AppStore s = AppStore(
        api: ApiClient(baseUrl: 'http://stub', client: spy.client),
      )..assessments = <Assessment>[_paper('scoring', summary: '238 queued')];
      await _openDetail(t, s);

      await t.pump(const Duration(seconds: 6));
      await t.pump();
      expect(spy.hits('/v1/scoring'), greaterThan(0), reason: 'the tick ran');

      final Iterable<Notice> notices = t.widgetList<Notice>(
        find.byType(Notice),
      );
      expect(
        notices.where((Notice n) => n.strong == 'Grading is not running.'),
        isEmpty,
        reason: 'this paper IS being graded, so the cohort-wide verdict is the '
            'less specific answer and must not contradict the live readout - '
            'the per-assessment phase wins whenever the server named one',
      );
      expect(
        notices
            .where((Notice n) => n.strong == '${ScoringPhase.scoring.label}.')
            .length,
        1,
        reason: 'and it cannot be passing by rendering neither: the live '
            'readout is still there',
      );
    });

    testWidgets('the Kill button IS offered at stalled', (
      WidgetTester t,
    ) async {
      // `isStoppable`, not `isBusy`, and the two stopped agreeing when
      // `stalled` arrived. A stalled run has the largest queue behind it -
      // having one is what makes it stalled - and parking that queue is the
      // only thing an operator can do about a dead cron from this console.
      // Gating on `isBusy` would have hidden the button during exactly the
      // outage it exists for.
      final AppStore s = AppStore()
        ..assessments = <Assessment>[_paper('stalled', summary: '1948 queued')]
        ..attempts = <Attempt>[];
      await _openDetail(t, s);

      expect(
        find.text('Kill Scoring Process'),
        findsOneWidget,
        reason: 'the client cache is empty here, which is the production case: '
            'the attempts walk is capped console-wide, so on a large cohort '
            'the only thing that knows there is a queue is the phase',
      );
    });

    testWidgets('one banner, not two saying the same thing', (
      WidgetTester t,
    ) async {
      final AppStore s = AppStore()
        ..assessments = <Assessment>[_paper('stalled', summary: '1948 queued')];
      await _openDetail(t, s);

      // The live readout is gated on `isBusy` and renders the phase's own
      // label as its strong line, so at `stalled` it would read "Not running."
      // in an INFO tone with a spinner beside it - directly under a red
      // "Grading is not running." A spinner over a grader that is not running
      // is the meter-left-going reading the bad banner exists to correct.
      //
      // Asserted on the widget rather than on painted text: the two strong
      // lines differ only by a word and a capital, and a finder that leaned on
      // that would break the first time either sentence was reworded.
      final Iterable<Notice> notices = t.widgetList<Notice>(
        find.byType(Notice),
      );
      expect(
        notices
            .where((Notice n) => n.strong == '${ScoringPhase.stalled.label}.')
            .toList(),
        isEmpty,
        reason: 'the info-tone live readout must not stack a second banner '
            'under the warning, repeating it in a tone that contradicts it',
      );
      expect(
        notices
            .where((Notice n) => n.strong == 'Grading is not running.')
            .length,
        1,
        reason: 'the phase and the drainer both say "nothing is grading", so '
            'they share one Notice - and exactly one has to be drawn, or this '
            'is passing on a screen with no warning at all',
      );
      expect(
        find.textContaining('${ScoringPhase.stalled.label}.'),
        findsNothing,
        reason: 'and nothing paints the readout\'s strong line either',
      );
    });
  });
}
