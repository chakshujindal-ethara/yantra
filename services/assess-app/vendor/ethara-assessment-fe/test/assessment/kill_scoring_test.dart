// Kill Scoring Process - the button, its confirmation, and what a killed
// answer looks like afterwards.
//
// A kill is not free and not fully reversible, so the confirmation has to name
// the two facts an operator must know before pressing it: scores already
// stored are KEPT, and the one LLM call already in flight still completes and
// is BILLED. And the outcome is its own thing, not a failure: a cancelled
// answer must read as "Cancelled" in a neutral tone, never as a scoring error.
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
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:ethara_assessment/assessment/widgets/marks.dart';

class _Spy {
  final List<String> paths = <String>[];

  /// The envelope every route answers with. Overridden by a test that cares
  /// about the SHAPE of the payload rather than which path was hit.
  final Map<String, dynamic> data;

  /// Answers for `/scoring`, consumed in order so a test can walk a run from
  /// `scoring` through to `idle`. The last entry repeats, because a poll that
  /// ran one tick more than expected must fail on the assertion rather than on
  /// a missing fixture.
  final List<Map<String, dynamic>> scoring;

  _Spy({
    this.data = const <String, dynamic>{'settled': 2},
    List<Map<String, dynamic>>? scoring,
  }) : scoring = <Map<String, dynamic>>[...?scoring];

  int hits(String suffix) =>
      paths.where((String p) => p.endsWith(suffix)).length;

  http.Client get client => MockClient((http.Request req) async {
    paths.add(req.url.path);
    Map<String, dynamic> body = data;
    if (req.url.path.endsWith('/scoring') && scoring.isNotEmpty) {
      body = scoring.length > 1 ? scoring.removeAt(0) : scoring.first;
    }
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': body}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });

  bool hit(String fragment) => paths.any((String p) => p.contains(fragment));
}

Assessment _launched() => Assessment(
  id: 'A-1',
  name: 'Warehouse Safety',
  state: AsmState.inProgress,
);

/// The same assessment, built from a WIRE payload carrying the server's phase.
///
/// Through `fromJson` on purpose, so the key the module actually sends -
/// `scoring_phase`, snake_case - is under test beside the gate that reads it. A
/// rename on either side fails here rather than quietly falling back to the
/// client-side walk and looking like it still worked.
Assessment _sent(String phase, {String summary = ''}) =>
    Assessment.fromJson(<String, dynamic>{
      'id': 'A-1',
      'name': 'Warehouse Safety',
      'state': 'in_progress',
      'scoring_phase': phase,
      'scoring_summary': summary,
    });

Attempt _grading() => Attempt(
  id: '1',
  assessmentId: 'A-1',
  employeeId: 'P-1',
  token: 'tok',
  state: AttemptState.submitted,
  isLocked: true,
  // Actively being graded, which is the only state the Kill button appears in.
  subjectiveState: LlmState.scoring,
);

/// [settle] is false for a screen showing the live scoring banner: its spinner
/// is an indeterminate `CircularProgressIndicator`, so `pumpAndSettle` waits on
/// an animation that by design never ends.
Future<void> _open(WidgetTester t, AppStore s, {bool settle = true}) async {
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
  if (settle) {
    await t.pumpAndSettle();
    return;
  }
  await t.pump();
  // The screen watches a live phase with a periodic timer. Tearing the tree
  // down is what runs `dispose` and cancels it; a test that just ends leaves it
  // pending and fails the binding's own invariant check.
  addTearDown(() async => t.pumpWidget(const SizedBox.shrink()));
}

void main() {
  testWidgets('the Kill button only appears while something is grading', (
    WidgetTester t,
  ) async {
    final AppStore idle = AppStore()
      ..assessments = <Assessment>[_launched()]
      ..attempts = <Attempt>[
        Attempt(
          id: '1',
          assessmentId: 'A-1',
          employeeId: 'P-1',
          token: 'tok',
          state: AttemptState.submitted,
          isLocked: true,
          subjectiveState: LlmState.scored,
        ),
      ];
    await _open(t, idle);
    expect(
      find.text('Kill Scoring Process'),
      findsNothing,
      reason: 'a kill offered over an idle queue does nothing but alarm',
    );
  });

  testWidgets('no Kill button when answers merely AWAIT grading', (
    WidgetTester t,
  ) async {
    // THE REPORTED BUG. With "Grade subjective answers automatically" off,
    // nothing is ever queued - but the gate read the assessment's
    // `awaitingScoringCount`, which counts answers that still NEED grading, and
    // that stays positive forever. So the console offered to kill a scoring run
    // that did not exist, permanently.
    final AppStore waiting = AppStore()
      ..assessments = <Assessment>[
        Assessment(
          id: 'A-1',
          name: 'Warehouse Safety',
          state: AsmState.done,
          llmAutoScore: false,
          awaitingScoringCount: 2,
        ),
      ]
      ..attempts = <Attempt>[
        Attempt(
          id: '1',
          assessmentId: 'A-1',
          employeeId: 'P-1',
          token: 'tok',
          state: AttemptState.submitted,
          isLocked: true,
          // Ungraded, but nobody asked for it to be graded.
          subjectiveState: LlmState.pending,
          subjectivePending: 2,
        ),
      ];
    await _open(t, waiting);
    expect(
      find.text('Kill Scoring Process'),
      findsNothing,
      reason: 'answers waiting to be graded are not a run in flight - there is '
          'nothing to kill until the server has been asked to grade',
    );
  });

  testWidgets('the Kill button appears once grading has been REQUESTED', (
    WidgetTester t,
  ) async {
    // The other side of the same signal: `scoring_requested` is the flag the
    // server's own drainer selects on, so a candidate carrying it has work in
    // flight even before a worker picks them up.
    final AppStore queued = AppStore()
      ..assessments = <Assessment>[_launched()]
      ..attempts = <Attempt>[
        Attempt(
          id: '1',
          assessmentId: 'A-1',
          employeeId: 'P-1',
          token: 'tok',
          state: AttemptState.submitted,
          isLocked: true,
          subjectiveState: LlmState.pending,
          scoringRequested: true,
        ),
      ];
    await _open(t, queued);
    expect(find.text('Kill Scoring Process'), findsOneWidget);
  });

  // ── The server's own phase, and why it outranks the cache ────────────────
  //
  // `scoringEvs` is `store.attempts`, a console-wide walk capped at 25 pages x
  // 200 rows across EVERY assessment. Production is past that window, so the
  // client-side `any(...)` answered "is this being graded?" according to how
  // much of the roster had happened to load - which is how an operator came to
  // see a Kill button over a finished run and no Kill button over a live one.
  // `scoring_phase` is computed server-side from the predicate the scoring cron
  // selects on, so these two tests pin the only two cases where the cache and
  // the server can disagree.

  testWidgets('the server saying idle beats a cache that looks busy', (
    WidgetTester t,
  ) async {
    final AppStore s = AppStore()
      ..assessments = <Assessment>[_sent('idle')]
      // Mid-call as far as this client knows, and stale: the row was graded
      // after this page of the cache was fetched.
      ..attempts = <Attempt>[_grading()];
    await _open(t, s);
    expect(
      find.text('Kill Scoring Process'),
      findsNothing,
      reason: 'the server computes the phase from the cron\'s own selection, '
          'so a cached attempt that still reads `scoring` cannot conjure a run '
          'the grader has already finished',
    );
  });

  testWidgets('the server saying scoring beats an EMPTY cache', (
    WidgetTester t,
  ) async {
    // The reported case, and the one the cap makes inevitable: a 711-candidate
    // cohort whose rows fell outside the console-wide window entirely. Every
    // client-side signal reads idle because there is nothing to read.
    final AppStore s = AppStore()
      ..assessments = <Assessment>[_sent('scoring')]
      ..attempts = <Attempt>[];
    await _open(t, s, settle: false);
    expect(
      find.text('Kill Scoring Process'),
      findsOneWidget,
      reason: 'a run the client has no rows for is still a run, and an '
          'operator with no way to stop it is the whole report',
    );
  });

  // ── The live readout ─────────────────────────────────────────────────────

  testWidgets('a run in flight names its phase and its breakdown', (
    WidgetTester t,
  ) async {
    final AppStore s = AppStore()
      ..assessments = <Assessment>[
        _sent('scoring', summary: '238 queued  \u00b7  1 scoring  \u00b7  464 scored'),
      ];
    await _open(t, s, settle: false);

    expect(
      find.textContaining('238 queued'),
      findsOneWidget,
      reason: 'the summary is the server\'s, rendered verbatim - it is the '
          'only thing on this screen that moves while a cron grades a cohort',
    );
    expect(find.textContaining('Scoring.'), findsOneWidget);
  });

  testWidgets('an idle assessment carries no readout at all', (
    WidgetTester t,
  ) async {
    // The summary is DELIBERATELY still on the record. A banner that renders
    // whenever a payload happens to carry a sentence is a permanent banner, and
    // the phase is the only thing entitled to decide whether there is a run to
    // talk about.
    final AppStore s = AppStore()
      ..assessments = <Assessment>[
        _sent('idle', summary: '238 queued  \u00b7  1 scoring  \u00b7  464 scored'),
      ];
    await _open(t, s);

    expect(find.textContaining('238 queued'), findsNothing);
    expect(find.textContaining('Scoring.'), findsNothing);
  });

  testWidgets('the screen follows a live run and stops when it ends', (
    WidgetTester t,
  ) async {
    // THE DELIVERABLE, driven rather than described. The three assertions the
    // report turns on are that a tick actually reaches the light route, that
    // the run ending costs exactly one read of the heavy one, and that the
    // timer then stops - a watch that kept ticking would be a request every
    // five seconds for the rest of the session.
    final _Spy spy = _Spy(
      scoring: <Map<String, dynamic>>[
        <String, dynamic>{'phase': 'scoring', 'summary': '2 queued'},
        <String, dynamic>{'phase': 'idle', 'summary': ''},
      ],
    );
    // An injected client is a live store on its own, with no `adoptSession` -
    // whose bootstrap `refresh()` would wipe the seeded record out from under
    // the widget before the first frame.
    final AppStore s = AppStore(
      api: ApiClient(baseUrl: 'http://stub', client: spy.client),
    )..assessments = <Assessment>[_sent('scoring', summary: '2 queued')];
    await _open(t, s, settle: false);

    final int detailReadsAtStart = spy.hits('/assessments/A-1');
    expect(spy.hits('/v1/scoring'), 0, reason: 'nothing polls before a tick');

    // One tick: the server still says `scoring`, so the watch stays.
    await t.pump(const Duration(seconds: 6));
    await t.pump();
    expect(spy.hits('/v1/scoring'), 1);
    expect(
      spy.hits('/assessments/A-1'),
      detailReadsAtStart,
      reason: 'a tick must never put the heavy detail route on the timer - '
          'the lesson pollGeneration paid for with an unbounded /responses '
          'walk every two seconds',
    );

    // Second tick: the run has finished.
    await t.pump(const Duration(seconds: 6));
    await t.pump();
    expect(spy.hits('/v1/scoring'), 2);
    // The closing read is spread over 0-5 s so every open tab does not land
    // on the heavy route in the same second.
    await t.pump(const Duration(seconds: 5));
    await t.pump();
    expect(
      spy.hits('/assessments/A-1'),
      detailReadsAtStart + 1,
      reason: 'the run ending is worth exactly one full read, so the roster '
          'and the verdicts catch up without the operator reloading',
    );

    // And it is over: no further tick, however long the screen stays open.
    await t.pump(const Duration(seconds: 30));
    await t.pump();
    expect(
      spy.hits('/v1/scoring'),
      2,
      reason: 'an idle phase must stop the watch, not slow it down',
    );
  });

  testWidgets('a phase that never ends still stops the watch', (
    WidgetTester t,
  ) async {
    // A worker holding a row it will never finish leaves `scoring_phase` at
    // `scoring` forever, and the screen would otherwise poll for as long as it
    // stayed open.
    //
    // THE CAP BELONGS TO THE RUN, and the first version of it did not: the
    // count was reset each time the timer was armed, so the tick that gave up
    // left the phase still busy and the very next notify re-armed from zero.
    // The store notifies twice per call. Nothing in the suite saw it, because
    // giving up and re-arming are indistinguishable from never giving up
    // unless you count the requests.
    final _Spy spy = _Spy(
      scoring: <Map<String, dynamic>>[
        <String, dynamic>{'phase': 'scoring', 'summary': '2 queued'},
      ],
    );
    final AppStore s = AppStore(
      api: ApiClient(baseUrl: 'http://stub', client: spy.client),
    )..assessments = <Assessment>[_sent('scoring', summary: '2 queued')];
    await _open(t, s, settle: false);

    // Well past the budget for a single run: 720 ticks, which the backoff
    // spreads over about six hours of an unchanging answer.
    await t.pump(const Duration(hours: 7));
    await t.pump();
    final int afterGivingUp = spy.hits('/v1/scoring');
    expect(
      afterGivingUp,
      lessThanOrEqualTo(721),
      reason: 'the watch must give up, not merely slow down',
    );
    expect(afterGivingUp, greaterThan(700), reason: 'and it must have watched');

    // The phase is STILL busy, and the store keeps notifying. Neither may
    // re-arm it.
    s.notifyListeners();
    await t.pump(const Duration(hours: 1));
    await t.pump();
    expect(
      spy.hits('/v1/scoring'),
      afterGivingUp,
      reason: 'having given up, no notify may start it over',
    );
  });

  test('the kill toast reports the count the server sent', () async {
    // THE BUG THIS EXISTS FOR, and it is the release toast's bug again one
    // route over: the sentence read `settled` / `cancelled` against a route
    // that answers `settled_count`, so the number was never found and every
    // kill fell through to the bare "Stopped grading". An operator stopping a
    // 700-candidate run got no confirmation of what had been stopped.
    final _Spy spy = _Spy(data: const <String, dynamic>{'settled_count': 238});
    final AppStore s = AppStore(
      api: ApiClient(baseUrl: 'http://stub', client: spy.client),
    );
    s.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');

    await s.killScoring('A-1');

    expect(
      s.toaster.items.map((ToastMsg m) => m.message),
      contains('Stopped grading - 238 candidate(s) settled'),
      reason: 'the count must come from settled_count, not a bare fallback',
    );
  });

  testWidgets('Score All stays usable on a DONE assessment', (
    WidgetTester t,
  ) async {
    // The second reported bug. Automatic grading is off by default, so a paper
    // that has been closed is exactly where ungraded subjective answers pile
    // up - and the gate required `state.isLive`, so the only button that grades
    // them was greyed out. Closing an assessment does not grade its papers.
    final AppStore done = AppStore()
      ..assessments = <Assessment>[
        Assessment(
          id: 'A-1',
          name: 'Warehouse Safety',
          state: AsmState.done,
          llmAutoScore: false,
          awaitingScoringCount: 2,
        ),
      ]
      ..attempts = <Attempt>[
        Attempt(
          id: '1',
          assessmentId: 'A-1',
          employeeId: 'P-1',
          token: 'tok',
          state: AttemptState.submitted,
          isLocked: true,
          subjectiveState: LlmState.pending,
          subjectivePending: 2,
        ),
      ];
    await _open(t, done);

    final Finder scoreAll = find.widgetWithText(Btn, 'Score All');
    expect(scoreAll, findsOneWidget);
    expect(
      t.widget<Btn>(scoreAll).enabled,
      isTrue,
      reason: 'a done assessment with ungraded answers must still be gradable',
    );
  });

  testWidgets('the confirmation names what survives a kill', (
    WidgetTester t,
  ) async {
    final AppStore s = AppStore()
      ..assessments = <Assessment>[_launched()]
      ..attempts = <Attempt>[_grading()];
    await _open(t, s);

    await t.tap(find.text('Kill Scoring Process'));
    await t.pumpAndSettle();

    // The two facts the sheet must carry.
    expect(find.textContaining('Scores already stored are kept'), findsOneWidget);
    expect(
      find.textContaining('finishes and is billed'),
      findsOneWidget,
      reason: 'the operator must know the in-flight call is not clawed back',
    );
  });

  test('killing hits the kill_scoring route for the assessment', () async {
    // The request half, at the store rather than through the screen: a live
    // store's session bootstrap refreshes from the network and would wipe a
    // seeded launched assessment out from under the widget, so the button's
    // press path is proven here and its DIALOG copy in the widget test above.
    final _Spy spy = _Spy();
    final AppStore s = AppStore(
      api: ApiClient(baseUrl: 'http://stub', client: spy.client),
    );
    s.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');

    await s.killScoring('A-1');

    expect(
      spy.hit('/api/v1/assessments/A-1/kill_scoring'),
      isTrue,
      reason: 'the kill must reach the route that settles the queue',
    );
  });

  group('a cancelled answer is its own outcome, not an error', () {
    test('the state is terminal and neutral, and never auto-retried', () {
      expect(LlmState.cancelled.tone, Tone.inert);
      expect(LlmState.cancelled.tone, isNot(Tone.bad));
      expect(LlmState.cancelled.label, 'Cancelled');
      // A cron must never undo a deliberate stop, and Score Failed Responses
      // must not re-spend on somebody an admin just stopped.
      expect(LlmState.autoRetry.contains(LlmState.cancelled), isFalse);
      expect(LlmState.manualRescore.contains(LlmState.cancelled), isFalse);
      expect(LlmState.scoringFailed.contains(LlmState.cancelled), isFalse);
    });

    test('but it DOES hold the verdict at pending', () {
      // This assertion was inverted, and the inversion was the bug. A killed
      // answer carries no grade, so excluding it from `unresolved` let the
      // attempt compute a verdict over it - scoring the ungraded answer zero
      // and turning an admin pressing Kill into the candidate's FAIL. Nobody
      // decided anything about that candidate, which is precisely what
      // Invariant 4 exists to prevent.
      expect(
        LlmState.unresolved.contains(LlmState.cancelled),
        isTrue,
        reason: 'a killed answer was never graded, so the paper is not '
            'finished and must not be failed on its behalf',
      );
    });

    test('the wire value parses to cancelled', () {
      expect(LlmState.parse('cancelled'), LlmState.cancelled);
    });

    test('an attempt with a killed answer reads pending, not fail', () {
      // The consequence of the set membership above, asserted where a user
      // would see it: the verdict itself. Without `cancelled` in `unresolved`
      // this attempt scored the ungraded answer 0 and returned a definitive
      // FAIL - an admin pressing Kill deciding a candidate had failed.
      final Assessment asm = Assessment.fromJson(<String, dynamic>{
        'id': 21,
        'name': 'Killed mid-grade',
        'state': 'in_progress',
        'duration_minutes': 30,
        'pass_threshold': 60.0,
        'questions': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 900,
            'name': 'Written answer',
            'question_type': 'subjective_rubric',
            'prompt': 'Explain the defect',
          },
        ],
      });
      final Attempt killed = Attempt.fromJson(<String, dynamic>{
        'id': 79,
        'assessment_id': 21,
        'state': 'submitted',
        'submitted_at': '2026-09-03T06:12:00Z',
        'answers': <Map<String, dynamic>>[
          <String, dynamic>{
            'question_id': 900,
            'answer_text': 'a real answer the grader never reached',
            'llm_state': 'cancelled',
          },
        ],
      });

      expect(
        killed.result(asm),
        ResultState.pending,
        reason: 'an admin stopping the grader must not decide the candidate '
            'failed - the answer was never graded',
      );
    });

    testWidgets('it renders as its own pill, not an error pill', (
      WidgetTester t,
    ) async {
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: Pill.state(LlmState.cancelled)),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('Cancelled'), findsOneWidget);
      // The error label must NOT be what a killed answer shows.
      expect(find.text('Scoring error'), findsNothing);
    });
  });

  group('a kill that stopped nothing says so', () {
    // The route recounted `settled` as every evaluator on the assessment ever
    // parked by a kill, so a second kill over an empty queue answered the
    // FIRST kill's number. Odoo's own notification read "Nothing to stop / No
    // candidate was being graded on this assessment" at the same moment. The
    // route now returns what this kill actually settled, and zero is a real
    // answer the toast has to be able to give.
    Future<List<String>> toastFor(Map<String, dynamic> reply) async {
      final _Spy spy = _Spy(data: reply);
      final AppStore s = AppStore(
        api: ApiClient(baseUrl: 'http://stub', client: spy.client),
      );
      s.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
      await s.killScoring('A-1');
      return s.toaster.items.map((ToastMsg m) => m.message).toList();
    }

    test('zero settled and nothing dropped reads as nothing to stop', () async {
      expect(
        await toastFor(const <String, dynamic>{
          'settled_count': 0,
          'cleared_count': 0,
        }),
        contains('Nothing to stop - no candidate was being graded'),
      );
    });

    test('the dropped re-score requests are named', () async {
      // `action_kill_scoring` clears every queued `rescore_request_key` on the
      // assessment and says so in Odoo. The console said nothing at all - on
      // the surface where per-answer re-score is the headline control - so an
      // admin who queued re-scores and then stopped a cohort run waited for
      // grades that were never coming.
      expect(
        await toastFor(const <String, dynamic>{
          'settled_count': 4,
          'cleared_count': 3,
        }),
        contains(
          'Stopped grading - 4 candidate(s) settled; '
          '3 queued re-score(s) dropped',
        ),
      );
    });

    test('dropped re-scores count even when no candidate was queued', () async {
      expect(
        await toastFor(const <String, dynamic>{
          'settled_count': 0,
          'cleared_count': 2,
        }),
        contains('Stopped grading; 2 queued re-score(s) dropped'),
      );
    });
  });

  testWidgets('the confirmation warns that queued re-scores are dropped', (
    WidgetTester t,
  ) async {
    // Neither console warned beforehand, and the loss is silent: the keys are
    // cleared, the answers keep their old marks, and nothing is queued again.
    final AppStore s = AppStore()
      ..assessments = <Assessment>[_launched()]
      ..attempts = <Attempt>[_grading()];
    await _open(t, s);

    await t.tap(find.text('Kill Scoring Process'));
    await t.pumpAndSettle();

    expect(
      find.textContaining('are dropped too'),
      findsOneWidget,
      reason: 'an admin must learn about this before pressing, not after',
    );
  });
}
