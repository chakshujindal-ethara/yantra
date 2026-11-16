// Analytics dashboard - the admin's cohort view.
//
// WHERE THE NUMBERS COME FROM. `GET /api/v1/analytics` (totals / flags /
// by_assessment) is the source, via `ApiClient.analytics` ->
// `AppStore.analytics` -> `CohortAnalytics`. This comment used to say the route
// was unwired and that the screen derived everything locally; that stopped
// being true when the analytics fetch landed, and a stale comment about where
// figures come from is the kind a reader trusts.
//
// BOTH PATHS STILL EXIST, and deliberately. The server's counts win for
// anything RESULT-derived (decided / passed / failed / awaiting) because
// `_resultOf` needs an assessment's frozen question count to reach a verdict
// and a LIST row carries none - so the local arithmetic moved as the operator
// browsed. The local walk remains the fallback for seed mode, which never
// fetches, and for a payload predating a field.
//
// `people` is the one figure the client CANNOT compute: distinct humans across
// assessments. Summing per-assessment counts double-counts anyone sitting two
// papers, which is how "Passed 1466" came to exceed "Candidates 1330".
//
// THE ZERO CASE IS THE DESIGNED CASE. The database ships empty, so every
// figure here is 0 on first sight. A zero never takes a success colour: green
// is reserved for a real thing in good order, and "there is nothing" is not
// one. Zero-row surfaces render an EmptyState instead of a header over a void.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../domain/category_scores.dart';
import '../../widgets/category_card.dart';
import '../../state/app_store.dart';
import '../../widgets/buttons.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/charts.dart';
import '../../widgets/panel.dart';
import '../../widgets/controls.dart';
import '../exam/exam_screen.dart';
import '../../theme.dart';
import '../../nav.dart';

/// How far back the dashboard looks.
///
/// A FIXED SET OF WINDOWS, not a date picker. Every question this screen is
/// opened to answer is relative ("how did last week's cohort do?"), and a pair
/// of calendar fields costs two interactions plus a decision about what "to"
/// means at midnight. `all` is first because it is the honest default: a
/// narrowed dashboard that opens pre-narrowed hides work.
enum DateWindow {
  all('Any date'),
  last7('Last 7 days'),
  last30('Last 30 days'),
  last90('Last 90 days');

  const DateWindow(this.label);
  final String label;

  /// The earliest instant still inside this window, or null for [all].
  DateTime? cutoffFrom(DateTime now) => switch (this) {
    DateWindow.all => null,
    DateWindow.last7 => now.subtract(const Duration(days: 7)),
    DateWindow.last30 => now.subtract(const Duration(days: 30)),
    DateWindow.last90 => now.subtract(const Duration(days: 90)),
  };
}

class DashboardScreen extends StatefulWidget {
  final AppStore store;

  /// Scope. Admin sees every assessment; anything narrower is decided by
  /// `visibleAssessments`, the same gate the assessment list uses, so this
  /// screen cannot show a cohort the list would have hidden.
  final Portal portal;

  const DashboardScreen({
    super.key,
    required this.store,
    this.portal = Portal.admin,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  /// Empty means every assessment. An id that no longer resolves is treated the
  /// same way rather than emptying the screen - an assessment can be archived
  /// while this is open, and a dashboard that goes blank looks broken.
  String _assessmentId = '';
  DateWindow _window = DateWindow.all;

  /// Narrow the screen to one assessment, or to all of it.
  ///
  /// TWO HALVES, AND BOTH HAVE TO MOVE. The panels below split into figures
  /// this screen computes from the store's own attempt rows, and figures the
  /// server computes and sends whole. `setState` moves the first half; only a
  /// refetch moves the second. Until it did, choosing one assessment narrowed
  /// the flag counters and left Pass rate, Cohort outcome, Decided outcomes,
  /// Avg score and Strengths and weaknesses describing the entire cohort -
  /// under a heading and a scope note that both said otherwise.
  ///
  /// Not debounced: this is a select, so one change is one deliberate choice.
  void _scopeTo(String assessmentId) {
    setState(() => _assessmentId = assessmentId);
    unawaited(widget.store.loadAnalyticsScope(assessmentId));
  }

  @override
  void initState() {
    super.initState();
    // A previous visit may have left the store scoped to an assessment this
    // screen is not showing. Put it back rather than reading somebody else's
    // filter as though it were all-up.
    if (widget.store.analyticsScope.isNotEmpty) {
      unawaited(widget.store.loadAnalyticsScope(''));
    }
  }

  /// WHICH TIMESTAMP THE WINDOW FILTERS ON.
  ///
  /// `submittedAt` when there is one, `startedAt` otherwise. Filtering on
  /// submission alone would drop every in-progress sitting out of a windowed
  /// view - so "Last 7 days" would report a completion rate computed without
  /// the papers still being written, which is exactly the denominator that
  /// makes the rate mean anything.
  DateTime? _whenOf(Attempt e) => e.submittedAt ?? e.startedAt;

  bool _inWindow(Attempt e, DateTime? from) {
    if (from == null) return true;
    final DateTime? when = _whenOf(e);
    // An attempt with NO timestamp at all is assigned-but-never-opened. It is
    // kept: it is a real row of the cohort (it is what "not started" counts),
    // and dropping it would inflate the completion rate of every window.
    if (when == null) return true;
    return !when.isBefore(from);
  }

  /// What the numbers below are actually counting, in words.
  ///
  /// Printed whether or not a filter is on. A dashboard that only says
  /// "filtered" when narrowed leaves the unfiltered case implicit, and the
  /// reader has to remember that no news means all-up.
  String _scopeNote(int total, int attempts, {bool sampled = false}) {
    final String scope = _assessmentId.isEmpty
        ? '$total assessment${total == 1 ? '' : 's'}'
        : '1 of $total assessments';
    final String window = _window == DateWindow.all
        ? 'any date'
        : _window.label.toLowerCase();
    // SAYS WHEN THE COUNT IS A SAMPLE.
    //
    // The unwindowed figure comes from `analytics` and is complete whatever
    // the client holds. A DATE WINDOW is different: it is computed from the
    // attempts actually loaded, and that walk is capped at 5,000 sittings - so
    // on a programme past the cap a windowed count is a floor, not a total.
    // Reporting it bare would be the same overclaim the Leaderboard was making.
    final String suffix = sampled ? '+ (sampled)' : '';
    return '$scope  ·  $window  ·  $attempts$suffix '
        'sitting${attempts == 1 ? '' : 's'}';
  }

  @override
  Widget build(BuildContext context) {
    final AppStore s = widget.store;
    final Portal portal = widget.portal;
    final AppTokens t = context.tokens;

    return ListenableBuilder(
      listenable: s,
      builder: (BuildContext context, _) {
        final List<Assessment> visible = s.visibleAssessments(portal);

        // The assessment filter narrows the ASSESSMENT list, and the date
        // filter narrows the ATTEMPTS inside it. That covers every figure this
        // screen works out for itself.
        //
        // THE SERVER'S OWN FIGURES ARE SCOPED SEPARATELY, by `_scopeTo`
        // refetching them - they arrive aggregated and cannot be narrowed
        // here. The date window is the one filter the server does not honour:
        // `/api/v1/analytics` takes an assessment and nothing else, so a
        // windowed view narrows the local half only. `_scopeNote` says which
        // cohort is on screen for exactly this reason.
        final List<Assessment> all = _assessmentId.isEmpty
            ? visible
            : visible.where((Assessment a) => a.id == _assessmentId).toList();
        final DateTime? from = _window.cutoffFrom(DateTime.now());

        // ── Cohort totals ────────────────────────────────────────────────
        final List<({Assessment a, Attempt e})> everyone =
            <({Assessment a, Attempt e})>[
              for (final Assessment a in all)
                for (final Attempt e in s.attemptsFor(a.id))
                  if (_inWindow(e, from)) (a: a, e: e),
            ];

        final List<({Assessment a, Attempt e})> submitted = everyone
            .where((({Assessment a, Attempt e}) r) => r.e.isDone)
            .toList();
        final List<({Assessment a, Attempt e})> decided = submitted
            .where(
              (({Assessment a, Attempt e}) r) =>
                  _resultOf(r.a, r.e) != ResultState.pending,
            )
            .toList();
        final int passed = decided
            .where(
              (({Assessment a, Attempt e}) r) =>
                  _resultOf(r.a, r.e) == ResultState.pass,
            )
            .length;
        final int awaitingResult = submitted.length - decided.length;

        final double passRate = decided.isEmpty
            ? 0
            : 100.0 * passed / decided.length;
        final double completionRate = everyone.isEmpty
            ? 0
            : 100.0 * submitted.length / everyone.length;
        final double avgScore = decided.isEmpty
            ? 0
            : decided.fold<double>(
                    0,
                    (double n, ({Assessment a, Attempt e}) r) =>
                        n + r.e.internalPercent(r.a),
                  ) /
                  decided.length;

        // ONE BAR ONLY WHEN THERE IS ONE. This was the unweighted mean of the
        // visible thresholds - a bar no assessment was configured with - and
        // the ring was coloured against it. With mixed bars the row names the
        // range instead, and nothing is coloured against a made-up figure.
        final List<double> bars = <double>{
          for (final Assessment a in all) a.passThreshold,
        }.toList()..sort();
        final String thresholdText = bars.length > 1
            ? 'Mixed (${bars.first.round()}-${bars.last.round()}%)'
            : _pct(bars.firstOrNull ?? 0);

        // The cohort's own verdict, decided once and read by the KPI, the ring
        // and the ring's arc so the three cannot disagree.
        //
        // `passed > 0` is part of the test, not a nicety: a cohort where
        // nobody passed clears a threshold of zero on the arithmetic alone,
        // and painting that green would report an empty result as a good one.
        // ── Flags. Advisory only - invariant 6 says a flag never moves a
        // score - but each one is a person's attention, so they are counted
        // together and surfaced as one number.
        final int integrity = everyone
            .where((({Assessment a, Attempt e}) r) => r.e.integrityAlert)
            .length;
        final int outliers = everyone
            .where((({Assessment a, Attempt e}) r) => r.e.scoreOutlier)
            .length;
        // Both kinds: the regular count and the AI one, kept apart.
        final int violations = everyone
            .where(
              (({Assessment a, Attempt e}) r) =>
                  r.e.violationCount + r.e.aiViolationCount > 0,
            )
            .length;
        // DISTINCT SITTINGS, not a sum of the three counters.
        //
        // One attempt can trip more than one signal at once - an inflated
        // score is exactly what a prompt injection produces, so the same
        // sitting often lights both - and adding the counters reported more
        // work than existed. It is a count of people to go and read.
        //
        // Scoring errors are deliberately NOT in here; see the panel below.
        final int flagged = everyone
            .where(
              (({Assessment a, Attempt e}) r) =>
                  r.e.integrityAlert ||
                  r.e.scoreOutlier ||
                  r.e.violationCount + r.e.aiViolationCount > 0,
            )
            .length;

        final int assignedTotal = all.fold<int>(
          0,
          // Prefer the counter the list endpoint reported: a list row carries
          // no nested attempts, so counting what is in hand would render 0.
          (int n, Assessment a) =>
              n +
              (a.assignedCount >= 0
                  ? a.assignedCount
                  : s.attemptsFor(a.id).length),
        );

        // ── THE SERVER'S FIGURES WIN ─────────────────────────────────────
        //
        // Everything above is derived from the tables in hand, and the
        // result-derived half of it is NOT STABLE. `_resultOf` needs the
        // assessment's frozen question count to reach a verdict, and a row
        // from the LIST endpoint carries no questions - so every attempt of an
        // assessment the operator had not opened counted as undecided, and
        // opening one hydrated its questions and retroactively moved the
        // totals. The same dashboard reported "nothing decided yet", then 0 of
        // 1, then 3 of 6, purely as a function of where the operator had
        // browsed. `GET /api/v1/analytics` reads the stored `result` on each
        // evaluator, so its counts are complete and do not move.
        //
        // Only the RESULT-derived figures are taken from the server. The
        // others - submitted, assigned, and every flag - read fields that a
        // list row does carry, so they were never unstable.
        //
        // Null in seed mode, which never fetches: the local arithmetic is the
        // fallback so the fixtures keep rendering real numbers.
        final CohortAnalytics? srv = s.analytics;
        // DISTINCT PEOPLE, from the server, which is the only place that can
        // count them: a client holding two assessments cannot tell whether the
        // same person appears in both without walking every attempt of each,
        // and a list row carries no attempts at all.
        //
        // Falls back to the local distinct walk (not to `assignedTotal`) so
        // seed fixtures and a pre-`people` payload still render a figure that
        // agrees with its own label rather than a knowingly inflated one.
        //
        // NOT USED WHILE A DATE WINDOW IS OPEN. `/api/v1/analytics` takes an
        // assessment and nothing else, so its `people` counts the whole cohort -
        // printing it under "Last 7 days" beside a bar built from the windowed
        // rows would put two different cohorts side by side on one screen and
        // call them the same thing. Windowed, the local distinct walk IS the
        // answer: `everyone` is already filtered by `_inWindow`, and a walk over
        // it can undercount only if a person's attempts span two assessments
        // AND the client is holding one of them un-hydrated - which the
        // unwindowed server figure covers, and which is why it is preferred
        // whenever it can be trusted.
        final int peopleCount = (from == null && (srv?.people ?? 0) > 0)
            ? srv!.people
            : everyone
                  .map((({Assessment a, Attempt e}) r) => r.e.employeeId)
                  .toSet()
                  .length;
        // SITTINGS, from the server, counted over the same recordset as
        // `people` - which is what makes the two comparable. `assignedTotal`
        // is the client fold and is NOT interchangeable with it.
        //
        // Windowed, `everyone.length` is the sittings on screen: it is the exact
        // list the cohort bar draws a segment per, so the tile's subtitle and
        // that bar cannot disagree.
        final int sittingsCount = from != null
            ? everyone.length
            : ((srv?.assigned ?? 0) > 0 ? srv!.assigned : assignedTotal);
        final int decidedCount = srv?.decided ?? decided.length;
        final int passedCount = srv?.passed ?? passed;
        final int failedCount = srv?.failed ?? (decided.length - passed);
        final int awaitingCount = srv?.awaitingResult ?? awaitingResult;
        final double passRatePct = srv?.passRate ?? passRate;
        final double avgScorePct = srv?.avgScore ?? avgScore;
        // THE SERVER'S COUNT, like every other figure in this strip.
        //
        // Three numbers described one condition: this local walk over the
        // cached attempts, the Responses screen's count of errored ANSWERS,
        // and `flags.scoring_error` which nothing read. The walk also needs
        // each attempt's answers, which a list row does not carry - so it
        // undercounted until an assessment had been opened. The local
        // arithmetic stays as the fallback for seed fixtures and for a payload
        // that predates the flag, exactly as `decidedCount` and its
        // neighbours do above.
        final int scoringErrors =
            srv?.scoringError ??
            everyone
                .where(
                  (({Assessment a, Attempt e}) r) => r.e.hasScoringError(r.a),
                )
                .length;

        // ── WHOLE-COHORT COUNTS FROM THE SERVER, NOT THE CACHE ───────────
        //
        // Submitted, completion and every flag were counted off the cached
        // attempt rows, and that walk stops at 5,000 - past the cap each was a
        // floor printed as a total. The server counts the whole cohort. House
        // rule: read server totals, never `rows.length`.
        //
        // Null while a date window is open: the route takes no dates, so its
        // counts would describe a different cohort from the bar beside them.
        // The local walk is then the answer, as it is for a missing field.
        final CohortAnalytics? whole = from == null ? srv : null;
        final int submittedCount = whole?.submitted ?? submitted.length;
        final double completionPct = whole?.completionRate ?? completionRate;
        final int integrityCount = whole?.integrityAlert ?? integrity;
        final int outlierCount = whole?.scoreOutlier ?? outliers;
        final int violatedCount = whole?.violated ?? violations;
        final int flaggedCount = whole?.needsReview ?? flagged;
        // IN PROGRESS IS NOT "NOT STARTED". The bar used to call everything
        // unsubmitted "Not started", so a paper half written read as unopened.
        final int inProgressLocal = everyone
            .where(
              (({Assessment a, Attempt e}) r) =>
                  !r.e.isDone && r.e.state == AttemptState.inProgress,
            )
            .length;
        final int inProgressCount = whole?.inProgress ?? inProgressLocal;
        final int notStartedCount =
            whole?.notStarted ??
            everyone.length - submitted.length - inProgressLocal;

        // Recomputed from the effective figures, so the KPI, the ring and the
        // arc still cannot disagree. `passedCount > 0` remains part of the
        // test: a cohort nobody passed clears a zero threshold arithmetically,
        // and painting that green reports an empty result as a good one.
        // Mixed bars give no verdict colour at all: there is no one bar to
        // have cleared.
        final ResultState cohortVerdict = decidedCount == 0 || bars.length != 1
            ? ResultState.pending
            : (passedCount > 0 && passRatePct >= bars.first
                  ? ResultState.pass
                  : ResultState.fail);

        return PageBody(
          children: <Widget>[
            PageHead(
              'Dashboard - Assessment Analytics',
              sub: 'Cohort performance across every assessment.',
              // Stages sits to the LEFT of the primary action, and is the only
              // way in: it has no sidebar row, so this button is its front
              // door.
              actions: <Widget>[
                // HIDDEN FROM A READ-ONLY MANAGER, because Stages is a
                // DIRECTORY of the sections they cannot open - it links to
                // Generators, Review Queue and the Question Bank. Leaving this
                // button would put every hidden destination one click from the
                // landing screen, and the route guard would then bounce them
                // straight back here.
                if (s.accessRole != AccessRole.manager)
                  Btn('Go to Stages', onPressed: () => context.nav.startHere()),
                Btn(
                  'Open Assessments',
                  onPressed: () => context.nav.assessments(),
                ),
              ],
            ),
            // THE GRADER'S OWN STATE, ABOVE THE NUMBERS IT PRODUCES.
            //
            // SNo 112. `GET /api/v1/scoring` has always reported a stalled
            // drainer and an error lane that never retries itself
            // (INVARIANT 5: a terminal scoring error waits for a person), and
            // nothing in the client read it. So the one condition that makes
            // every figure below WRONG - grading stopped - was visible only as
            // candidates staying un-decided, which reads as slowness.
            //
            // Placed above the filters deliberately: it is not a property of
            // the narrowed cohort, it is a property of the machine, and a
            // warning under the numbers it invalidates is read too late.
            // Rendered only when there is something to DO, so a healthy
            // deployment carries no permanent banner.
            if (s.scoringPipeline?.needsAttention ?? false) ...<Widget>[
              Builder(
                builder: (BuildContext context) {
                  final ScoringPipeline p = s.scoringPipeline!;
                  final List<String> parts = <String>[
                    if (p.stalled)
                      p.reason.trim().isNotEmpty
                          ? p.reason.trim()
                          : 'The grading workers are not running'
                                '${p.cronsInactive > 0 ? " (${p.cronsInactive} of ${p.cronsTotal} inactive)" : ""}'
                                '${p.cronsOverdue > 0 ? " (${p.cronsOverdue} overdue)" : ""}.',
                    if (p.needsManualRequeue > 0)
                      '${p.needsManualRequeue} attempt'
                          '${p.needsManualRequeue == 1 ? "" : "s"} stopped on a '
                          'scoring error. These never retry on their own and stay '
                          'ungraded until somebody requeues them.',
                    if (p.queued > 0 && p.stalled)
                      '${p.queued} attempt${p.queued == 1 ? " is" : "s are"} '
                          'waiting to be graded behind it.',
                  ];
                  return Notice(
                    tone: p.stalled ? Tone.bad : Tone.warn,
                    strong: p.stalled
                        ? 'Grading is not running.'
                        : 'Some attempts need a person.',
                    text: parts.join(' '),
                  );
                },
              ),
              const SizedBox(height: 14),
            ],
            // FILTERS SIT ABOVE THE KPIs, because they govern them.
            //
            // Everything below this row is computed from the narrowed cohort,
            // so the controls have to be the first thing read - a strip of
            // numbers with the filter underneath invites reading the numbers as
            // all-up. The active scope is restated in words beside them for the
            // same reason: "Pass rate 50%" means nothing without knowing which
            // cohort and which window produced it.
            Toolbar(<Widget>[
              // ONE TOOLBAR CHILD EACH, NOT A NESTED ROW.
              //
              // `Toolbar` wraps every child before its `Spacer` in
              // `Flexible(flex: 1)`, and a LOOSE child that declines its share
              // does not hand the remainder back. Nesting both filters in one
              // child therefore made them split ONE share between them, so the
              // moment `Clear Filters` appeared - which is exactly when a long
              // assessment name is on screen - the wide filter dropped below the
              // 200px it was widened from. Flat, each filter holds its own share
              // and the wide cap binds instead of being halved.
              SelectField<String>(
                // WIDER THAN A STOCK FILTER, because these options are DATA.
                // Every other filter in the app picks from labels we wrote and
                // kept short; this one lists assessment names an operator typed,
                // and at the stock 200 a real title ellipsises before it says
                // anything that distinguishes it from its neighbour. Past this
                // width the name gets a tooltip instead - see
                // `SelectField.maxWidth`.
                maxWidth: kSelectFieldWideWidth,
                value: visible.any((Assessment a) => a.id == _assessmentId)
                    ? _assessmentId
                    : '',
                options: <(String, String)>[
                  ('', 'All assessments'),
                  for (final Assessment a in visible) (a.id, a.name),
                ],
                onChanged: _scopeTo,
              ),
              // These read as one control at the toolbar's stock 8px gap, and
              // they are not: one narrows WHICH cohort, the other WHEN. The
              // extra 6 rides on this filter's own padding because a bare
              // `SizedBox` between them would be a toolbar child in its own
              // right and burn a whole flex share to render 6px.
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: SelectField<DateWindow>(
                  value: _window,
                  options: <(DateWindow, String)>[
                    for (final DateWindow w in DateWindow.values) (w, w.label),
                  ],
                  onChanged: (DateWindow v) => setState(() => _window = v),
                ),
              ),
              if (_assessmentId.isNotEmpty || _window != DateWindow.all)
                Btn(
                  'Clear Filters',
                  onPressed: () {
                    setState(() => _window = DateWindow.all);
                    _scopeTo('');
                  },
                ),
              const Spacer(),
              Text(
                _scopeNote(
                  visible.length,
                  // The all-up count is the server's; only a date window falls
                  // back to what the client actually walked.
                  from == null ? sittingsCount : everyone.length,
                  sampled:
                      from != null &&
                      s.pagesTruncated &&
                      s.attemptsTotal > s.attempts.length,
                ),
                style: context.type.tiny.copyWith(color: t.textMuted),
              ),
            ]),
            KpiStrip(<Widget>[
              Kpi(
                label: 'Assessments',
                value: '${all.length}',
                onTap: () => context.nav.assessments(),
              ),
              // PEOPLE, not sittings - and the subtitle says which.
              //
              // This read `assignedTotal`, the sum of each assessment's own
              // `assignedCount`, while passed/failed/decided beside it came
              // from the server's per-sitting recordset. Two denominators on
              // one screen: a candidate on two papers counted twice here and
              // once there, so "Passed 1466" could exceed "CANDIDATES 1330".
              // Its own subtitle said "across every sitting" under a label
              // saying "Candidates", which is the bug written down.
              //
              // The sittings figure is not discarded - it is the honest
              // denominator for Submitted below, and it is what the subtitle
              // now reports when the two differ.
              Kpi(
                label: 'Candidates',
                value: '$peopleCount',
                // COMPARED AGAINST THE SERVER'S SITTINGS COUNT, not
                // `assignedTotal`. The client fold is the inflated figure this
                // whole fix exists to stop trusting; using it as the
                // comparison would decide whether to print "one sitting each"
                // from the number known to double-count. The server counts
                // both figures over the same recordset, so only it can say
                // whether they actually agree.
                sub: peopleCount == sittingsCount
                    ? 'one sitting each'
                    : '$sittingsCount sittings between them',
              ),
              Kpi(
                label: 'Submitted',
                value: '$submittedCount',
                // `sittingsCount`, not the cache: an empty cache over a server
                // reporting sittings is not "nobody assigned".
                sub: sittingsCount == 0
                    ? 'nobody assigned yet'
                    : '${_pct(completionPct)} of assigned',
                // Info, not success: work arriving is something happening, not
                // something finished.
                valueColor: submittedCount > 0 ? t.infoText : null,
              ),
              Kpi(
                label: 'Pass rate',
                // A dash, not "0.0%". Nothing has been decided, and a printed
                // zero reads as "everybody failed".
                value: decidedCount == 0 ? '-' : _pct(passRatePct),
                sub: decidedCount == 0
                    ? 'nothing decided yet'
                    : '$passedCount of $decidedCount decided',
                // Green only when a real cohort cleared a real bar.
                valueColor: switch (cohortVerdict) {
                  ResultState.pass => t.successText,
                  ResultState.fail => t.destText,
                  ResultState.pending => null,
                },
              ),
              Kpi(
                label: 'Awaiting result',
                value: '$awaitingCount',
                // Submitted minus released-and-decided, so a scored result
                // still held back counts here. "not scored" said otherwise.
                sub: 'submitted, not released',
                valueColor: awaitingCount > 0 ? t.warnText : null,
              ),
              Kpi(
                label: 'Needs review',
                value: '$flaggedCount',
                sub: 'never affects a score',
                // Amber, not red. Nothing here is broken and nothing is
                // blocked - somebody has reading to do. Red is kept for the
                // tile beside it, which IS stuck.
                valueColor: flaggedCount > 0 ? t.warnText : null,
              ),
              // ITS OWN TILE, not a row in the advisory panel. A terminal
              // grader error is a failed job, not a signal about a candidate,
              // and invariant 5 says nothing retries it automatically. Opens
              // Responses, where the failed answer itself is requeued - each
              // attempt row carries its own grading state and error.
              Kpi(
                label: 'Grader errors',
                value: '$scoringErrors',
                // Says WHICH UNIT. The Responses screen counts errored
                // answers and this counts the sittings holding them, so the
                // two figures differ legitimately and the labels have to
                // admit it. 26-character cap - see kpi_sub_length_test.
                sub: 'sittings, until requeued',
                valueColor: scoringErrors > 0 ? t.destText : null,
                onTap: () => context.nav.responses(),
              ),
            ]),
            // A VISUAL band before the tables. Six KPI tiles cannot show that
            // one assessment carries most of the cohort; the figures stay
            // printed beside every bar so nothing is estimated off the pixels.
            // ONE GAP RULE FOR THE PANEL STACK.
            //
            // `PageBody` is a bare Column, so every gap on this page was
            // hand-placed - and three of the five boundaries never got
            // one: the band ran straight into Cohort Outcome, the
            // Performance row into Strengths and Weaknesses, and that into
            // Time Analysis, while the two that had a `SizedBox` looked
            // right. `Stack16` spaces what it is given, so a section added
            // here cannot arrive flush against its neighbour.
            //
            // The head, toolbar and KPI strip stay outside it: `PageHead`
            // and `KpiStrip` carry their own `bottom: 16` already.
            Stack16(<Widget>[
              _AnalyticsBand(
                store: s,
                assessments: all,
                decidedCount: decidedCount,
                passed: passedCount,
                failed: failedCount,
                awaitingResult: awaitingCount,
                inProgress: inProgressCount,
                notStarted: notStartedCount,
                flagged: flaggedCount,
                sittings: sittingsCount,
              ),
              Cols2(
                left: Panel(
                  minHeight: Sizes.panelMin,
                  title: 'Cohort Outcome',
                  note: 'released and decided',
                  child: decidedCount == 0
                      ? EmptyState(
                          icon: Icons.donut_large_outlined,
                          title: 'No result has been decided yet',
                          body: 'Launch an assessment to start the cohort.',
                          action: Btn.primary(
                            'Go to Assessments',
                            onPressed: () => context.nav.assessments(),
                          ),
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: <Widget>[
                            ScoreRing(
                              earned: passedCount,
                              total: decidedCount,
                              result: cohortVerdict,
                              size: 104,
                            ),
                            const SizedBox(width: 18),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  KvRow(
                                    'Passed',
                                    Pill(
                                      '$passedCount passed',
                                      // Zero passes takes the inert tone for the
                                      // same reason zero failures does: green is
                                      // a real good outcome, not an empty set.
                                      passedCount > 0 ? Tone.ok : Tone.inert,
                                    ),
                                  ),
                                  KvRow(
                                    'Failed',
                                    Pill(
                                      '$failedCount failed',
                                      // Zero failures is an absence, and the
                                      // tone rule keeps red for a real one.
                                      failedCount > 0 ? Tone.bad : Tone.inert,
                                    ),
                                  ),
                                  KvRow.text(
                                    'Average score',
                                    _pct(avgScorePct),
                                  ),
                                  KvRow.text(
                                    'Pass threshold',
                                    thresholdText,
                                    last: true,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                ),
                // THREE REASONS FOR ONE ACTION, and the names say the reason.
                // This was "Integrity flags" over four pieces of internal
                // vocabulary, only three of which were the same KIND of thing -
                // the fourth was a failed job in a list of advisory signals,
                // under a footer promising none of them affected a score. That
                // one moved to its own tile above, because the answer to it is
                // not "read this" but "press requeue".
                right: Panel(
                  minHeight: Sizes.panelMin,
                  title: 'Needs Review',
                  note: 'what tripped it',
                  footer: Text(
                    'Advisory only. None of these changes a score.',
                    style: context.type.tiny,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      // The grader stopped on the answer itself: blank, an
                      // attempt to instruct it, an answer to a different
                      // question, or a key that changed after marking.
                      KvRow(
                        'Answers to review',
                        _FlagMark(integrityCount, Tone.warn),
                      ),
                      // Cohort statistics, not the grader. More than two standard
                      // deviations ABOVE the mean - the net for an injection that
                      // got past the gate and inflated a score. Above only: this
                      // is not looking for candidates who struggled.
                      KvRow(
                        'Unusually high scores',
                        _FlagMark(outlierCount, Tone.warn),
                      ),
                      KvRow(
                        'Exam rules broken',
                        _FlagMark(violatedCount, Tone.warn),
                        last: true,
                      ),
                    ],
                  ),
                ),
              ),
              // Side by side, each with its own search. They answer adjacent
              // questions - which assessment is performing, and who is - so
              // reading one used to mean scrolling past the other. `Cols2`
              // already collapses to a stacked Column under 980px, so the narrow
              // case needs nothing here.
              Cols2(
                left: _PerformancePanel(
                  store: s,
                  assessments: all,
                  byAssessment: <String, AssessmentAnalytics>{
                    for (final AssessmentAnalytics r
                        in srv?.byAssessment ?? const <AssessmentAnalytics>[])
                      r.id: r,
                  },
                ),
                // Takes the scope so its empty state can say WHICH cohort is
                // empty. The rows themselves are already scoped: the server
                // groups them by candidate, so the filtering has to happen
                // there and `_scopeTo` has refetched them.
                right: _LeaderboardPanel(
                  store: s,
                  scoped: _assessmentId.isNotEmpty,
                ),
              ),
              // WHERE THE COHORT IS STRONG AND WEAK.
              //
              // Above Time analysis because this one DOES bear on results:
              // category averages are what a coach acts on. Scoped to the
              // selected assessment, because `_scopeTo` refetches the analytics
              // payload these come in - not by the date window, which the
              // analytics route does not accept.
              _CohortCategoriesPanel(
                categories: srv?.cohortCategories ?? const <CohortCategory>[],
                threshold: _passThresholdOf(all),
              ),
              // TIME LAST, and full width.
              //
              // It is the least load-bearing panel on the screen - nothing here
              // affects a result - so it sits below the panels that do, where it
              // cannot be mistaken for part of the scoring story. Full width
              // because it is a four-column table of individual sittings; in a
              // half it would page four rows at a time.
              _TimeAnalysisPanel(store: s, rows: everyone),
            ]),
          ],
        );
      },
    );
  }
}

/// A flag count as a mark rather than a bare numeral.
///
/// Zero is `inert`, never `ok`: an absent problem is an absence, and a green
/// chip on every row of an empty database says "all good" about data nobody
/// has entered.
class _FlagMark extends StatelessWidget {
  final int count;
  final Tone tone;

  const _FlagMark(this.count, this.tone);

  @override
  Widget build(BuildContext context) =>
      StatusBadge('$count', count > 0 ? tone : Tone.inert);
}

/// The result an attempt may be reported with on an aggregate surface.
///
/// `Attempt.result` divides by the paper's mark total, which `maxMarks` falls
/// back to summing off the QUESTIONS - and a row loaded from the list endpoint
/// carries none, which would score every submitted attempt at zero and report
/// the whole cohort as failed. So the guard is "did the questions load at
/// all", and the question count is the cheapest statement of that. Pending is
/// the honest answer there: the marks are not in hand, so no verdict is.
ResultState _resultOf(Assessment a, Attempt e) =>
    a.totalQuestions == 0 ? ResultState.pending : e.result(a);

/// A cohort percentage. Never a candidate's score - see the panel note on the
/// performance breakdown.
String _pct(double v) => '${v.toStringAsFixed(1)}%';

/// The visual band under the KPI strip.
///
/// Three panels, each answering a question the numbers alone do not:
///   funnel  - where does the cohort drop off between assigned and decided?
///   outcome - what is the pass/fail split, as a ratio not a count?
///   load    - which assessments carry the cohort?
class _AnalyticsBand extends StatelessWidget {
  const _AnalyticsBand({
    required this.store,
    required this.assessments,
    required this.decidedCount,
    required this.passed,
    required this.failed,
    required this.awaitingResult,
    required this.inProgress,
    required this.notStarted,
    required this.flagged,
    required this.sittings,
  });

  final AppStore store;
  final List<Assessment> assessments;

  /// COUNTS, not the rows. The caller resolves these against the server's
  /// analytics, which the band cannot do for itself: deciding a verdict from
  /// the rows needs each assessment's question count, and a list row has none.
  final int decidedCount;
  final int passed;
  final int failed;
  final int awaitingResult;
  final int inProgress;
  final int notStarted;
  final int flagged;

  /// The screen's window-aware sitting count, for the sentence total and the
  /// empty check. NOT a sum of the slices: under a date window passed, failed
  /// and awaiting are still all-time server figures, so a sum added two
  /// cohorts together and an empty window drew the all-time bar.
  final int sittings;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;

    // Per-assessment cohort size, biggest first, capped so one panel cannot
    // grow without bound on a large tenancy.
    final List<Slice> load = <Slice>[
      for (final Assessment a in assessments)
        Slice(
          a.name,
          (a.assignedCount >= 0
                  ? a.assignedCount
                  : store.attemptsFor(a.id).length)
              .toDouble(),
          t.primary,
        ),
    ]..sort((Slice x, Slice y) => y.value.compareTo(x.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Cols2(
          // A StackedBar on the left builds through a LayoutBuilder, so this
          // row cannot use equalHeight. A shared floor is what keeps the two
          // cards the same size: the right one is a 148px donut when there is
          // data and two lines of text when there is not, and it used to
          // collapse to a third of its neighbour.
          left: Panel(
            minHeight: Sizes.panelMin,
            title: 'Where the Cohort Stands',
            // ONE SITTING PER SLICE, and the note says so.
            //
            // It read "every assigned candidate, once", which the bar has
            // never done: every slice counts SITTINGS, so a person on two
            // papers appears in two of them. That caption is what made the
            // total look impossible - it summed to 2342 under a heading of
            // 1330 - and the arithmetic was right while the sentence was
            // wrong. A candidate legitimately sitting several papers is the
            // whole point of a cohort view; claiming otherwise is what had to
            // go.
            note: 'one bar segment per sitting',
            child: sittings == 0
                ? Text('Nobody is assigned yet.', style: context.type.bodyMuted)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      StackedBar(
                        slices: <Slice>[
                          Slice('Passed', passed.toDouble(), t.successText),
                          Slice('Failed', failed.toDouble(), t.destText),
                          Slice(
                            'Awaiting result',
                            awaitingResult.toDouble(),
                            t.warnText,
                          ),
                          Slice(
                            'In progress',
                            inProgress.toDouble(),
                            t.infoText,
                          ),
                          Slice('Not started', notStarted.toDouble(), t.border),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        _funnelSentence(),
                        style: context.type.bodySecondary,
                      ),
                    ],
                  ),
          ),
          right: Panel(
            minHeight: Sizes.panelMin,
            title: 'Decided Outcomes',
            note: decidedCount == 0
                ? 'nothing decided yet'
                : 'released results',
            child: decidedCount == 0
                ? Text('Nothing decided yet.', style: context.type.bodyMuted)
                : Row(
                    children: <Widget>[
                      DonutChart(
                        slices: <Slice>[
                          Slice('Passed', passed.toDouble(), t.successText),
                          Slice('Failed', failed.toDouble(), t.destText),
                        ],
                        centerValue: '$passed/$decidedCount',
                        centerLabel: 'PASSED',
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            _Legend(
                              color: t.successText,
                              label: 'Passed',
                              value: '$passed',
                            ),
                            const SizedBox(height: 8),
                            _Legend(
                              color: t.destText,
                              label: 'Failed',
                              value: '$failed',
                            ),
                            if (flagged > 0) ...<Widget>[
                              const SizedBox(height: 12),
                              Text(
                                '$flagged to review - reviewing one never '
                                'changes its score.',
                                style: context.type.tiny,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        if (load.isNotEmpty && load.first.value > 0) ...<Widget>[
          const SizedBox(height: 16),
          Panel(
            title: 'Candidates per Assessment',
            note: 'who is carrying the cohort',
            child: BarChart(bars: load.take(8).toList()),
          ),
        ],
      ],
    );
  }

  /// One plain sentence naming the biggest gap, so the chart does not rely on
  /// the reader doing the subtraction.
  String _funnelSentence() {
    if (notStarted > 0 && notStarted >= awaitingResult) {
      // "sittings", not "assigned candidates": the count is over attempt
      // rows, so one person on two papers contributes two. Saying
      // "candidates" here is the same conflation the Candidates tile carried.
      return '$notStarted of $sittings sittings have not been started yet.';
    }
    if (awaitingResult > 0) {
      // Scoring OR release: a scored result still held back counts here too.
      return '$awaitingResult submitted attempt(s) are waiting on scoring '
          'or release before a result is out.';
    }
    if (decidedCount == 0) return 'Nothing has been decided yet.';
    return 'Every submitted attempt has been decided.';
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.color,
    required this.label,
    required this.value,
  });

  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(color: color, borderRadius: Radii.badge),
      ),
      const SizedBox(width: 7),
      Text(label, style: context.type.bodySecondary),
      const Spacer(),
      Text(value, style: context.type.mono),
    ],
  );
}

/// "Performance by assessment", searchable, sized to sit beside the
/// leaderboard.
///
/// Stateful only because of the search box. The screen itself stays
/// stateless - extracting the panel is cheaper than making the whole dashboard
/// rebuild on every keystroke, and follows `_AnalyticsBand` above.
///
/// COLUMNS WERE TRIMMED for the two-up layout. At a 996px content area the
/// halves are roughly 545/435, and the seven-column version wanted 870 on its
/// own, so Decided, Passed and Awaiting came out. Each row still opens the
/// assessment, where all of them are reported in full.
/// Time analysis: how long sittings take, and who is off the cohort's pace.
///
/// DESCRIPTIVE, NOT EVALUATIVE, and the panel says so in its own note. Time is
/// not part of any score here; a Slow tag is a prompt to look, not a penalty.
/// Kept admin-side per the spec - the candidate's own screen gets the plain
/// number without a cohort comparison, because ranking somebody's speed against
/// their peers is not information they can act on.
class _TimeAnalysisPanel extends StatefulWidget {
  const _TimeAnalysisPanel({required this.store, required this.rows});

  final AppStore store;

  /// The already-filtered cohort. The panel never reaches into the store for
  /// rows, so the dashboard's assessment and date filters govern it for free.
  final List<({Assessment a, Attempt e})> rows;

  @override
  State<_TimeAnalysisPanel> createState() => _TimeAnalysisPanelState();
}

class _TimeAnalysisPanelState extends State<_TimeAnalysisPanel> {
  String _search = '';
  int _page = 1;
  int _pageSize = 10;

  /// The same fallback the attempt screen uses: the person's name, or the raw
  /// id when the directory has not been loaded. Never blank - an unnamed row is
  /// unopenable in practice because there is nothing to search for.
  String _who(Attempt e) =>
      widget.store.personById(e.employeeId)?.name ?? e.employeeId;

  @override
  Widget build(BuildContext context) {
    // Only sittings with BOTH ends. Everything below is about elapsed time, and
    // a paper still being written has none - counting it would report a
    // duration that grows while nobody is looking at it.
    final List<({Assessment a, Attempt e, Duration d})> timed =
        <({Assessment a, Attempt e, Duration d})>[
          for (final ({Assessment a, Attempt e}) r in widget.rows)
            if (attemptDuration(r.e) case final Duration d)
              (a: r.a, e: r.e, d: d),
        ];

    // PER-TEST MEDIANS, not one cohort-wide median.
    //
    // The spec says Pace is "vs cohort median time FOR THAT TEST", and that is
    // the only comparison that means anything: a 9-question paper and a
    // 3-question paper have no shared notion of fast. A single global median
    // would label everybody on the short test Fast and everybody on the long
    // one Slow, which says nothing about the candidates at all.
    final Map<String, List<Duration>> byTest = <String, List<Duration>>{};
    for (final ({Assessment a, Attempt e, Duration d}) r in timed) {
      byTest.putIfAbsent(r.a.id, () => <Duration>[]).add(r.d);
    }
    final Map<String, Duration?> medianByTest = <String, Duration?>{
      for (final MapEntry<String, List<Duration>> e in byTest.entries)
        e.key: medianDuration(e.value),
    };

    final Duration? overall = medianDuration(
      timed.map((({Assessment a, Attempt e, Duration d}) r) => r.d),
    );

    final String q = _search.trim().toLowerCase();
    final List<({Assessment a, Attempt e, Duration d})> shown = q.isEmpty
        ? timed
        : timed
              .where(
                (({Assessment a, Attempt e, Duration d}) r) =>
                    _who(r.e).toLowerCase().contains(q) ||
                    r.a.name.toLowerCase().contains(q),
              )
              .toList();

    // Slowest first. The reason to open this panel is to find the sittings that
    // took unusually long; ordering by name would bury them.
    final List<({Assessment a, Attempt e, Duration d})> sorted =
        List<({Assessment a, Attempt e, Duration d})>.from(shown)..sort(
          (
            ({Assessment a, Attempt e, Duration d}) x,
            ({Assessment a, Attempt e, Duration d}) y,
          ) => y.d.compareTo(x.d),
        );

    final int total = sorted.length;
    final int pageCount = total == 0 ? 1 : ((total - 1) ~/ _pageSize) + 1;
    final int page = _page.clamp(1, pageCount);
    final List<({Assessment a, Attempt e, Duration d})> pageRows = sorted
        .skip((page - 1) * _pageSize)
        .take(_pageSize)
        .toList();

    return Panel(
      height: Sizes.panelTable,
      title: 'Time Analysis',
      // THE RULE, IN THE HEADER. A tag nobody can decode is a tag nobody
      // trusts, and "Pace" decoded to nothing at all: the thresholds lived
      // only in `paceOf`. Stated once here for the glance, and per row in the
      // tag's own tooltip for the check.
      note: 'descriptive only - time is never scored  ·  $paceLegend',
      flush: true,
      toolbar: Toolbar(<Widget>[
        SearchField(
          value: _search,
          hint: 'Search candidate or assessment',
          onChanged: (String v) => setState(() {
            _search = v;
            _page = 1;
          }),
        ),
        const Spacer(),
        // THE PER-TEST TYPICAL TIME, not one figure across every paper.
        //
        // The brief asks for "average time taken FOR THE TEST", and a single
        // all-up number is not that: a 9-question paper and a 3-question paper
        // pooled together produce a figure that describes neither, and it is
        // also the number every Pace tag would then look wrong against (Pace is
        // computed per test - see `medianByTest`). So when the cohort spans
        // several assessments this says so and the per-test figures appear on
        // their own rows below; narrowed to one assessment, it is that test's.
        if (medianByTest.length == 1 && overall != null)
          TagChip('median ${humanDuration(overall)}')
        else if (medianByTest.length > 1)
          TagChip('${medianByTest.length} tests · median per test'),
      ]),
      footer: Pagination(
        page: page,
        pageSize: _pageSize,
        total: total,
        onPage: (int p) => setState(() => _page = p),
        onPageSize: (int n) => setState(() {
          _pageSize = n;
          _page = 1;
        }),
      ),
      child: DataGrid(
        // Raised from 520 with the "Test median" column: two flex-3 names plus
        // 104 + 106 + 92 of fixed columns and their gaps no longer fit 520, and
        // an under-declared minWidth is what squeezes a numeric column into an
        // ellipsis.
        minWidth: 640,
        rowHeight: Sizes.tableRow,
        emptyIcon: Icons.timer_outlined,
        emptyMessage: q.isEmpty
            ? 'No finished sittings yet.'
            : 'No sitting matches "$_search".',
        cols: const <Col>[
          Col('Candidate', flex: 3),
          Col('Assessment', flex: 3),
          Col('Time taken', width: 104, numeric: true),
          // The TEST's own typical time, repeated on every row of that test.
          //
          // This is what makes the row self-explanatory: "38 min" means nothing
          // until you know the paper usually takes 26, and it is also the exact
          // number the Pace tag beside it was computed against - so the tag can
          // be checked by eye instead of taken on trust.
          Col('Test median', width: 106, numeric: true),
          Col('Pace', width: 92),
        ],
        rows: pageRows.map((({Assessment a, Attempt e, Duration d}) r) {
          final Duration? med = medianByTest[r.a.id];
          final Pace? pace = paceOf(r.d, med);
          return GridRow(<Widget>[
            // ONE LINE, EXPLICITLY. This grid passes `rowHeight`, which clips
            // its cells instead of letting them grow, and it sits in a
            // fixed-height Panel - so a wrapped name would be cut in half AND
            // push the panel body past its bounds. The tooltip still carries
            // the full name. Same at :1345 and :1529.
            GridLink(_who(r.e), maxLines: 1),
            Text(r.a.name, style: context.type.bodySecondary),
            Mono(humanDuration(r.d)),
            med == null
                ? Text('-', style: context.type.bodySecondary)
                : Text(humanDuration(med), style: context.type.bodySecondary),
            // THE ARITHMETIC ON HOVER, ON EVERY CELL INCLUDING THE EMPTY ONE.
            // The two columns to the left are rounded - `<1 min` against
            // `<1 min` cannot explain a Normal, let alone a Slow - so the only
            // place the tag can be checked is here, with the exact durations
            // and the ratio. A cell with no median to compare against says so
            // in words; a bare dash reads as a missing value, not as an absent
            // comparison.
            Tooltip(
              message: paceExplanation(r.d, med),
              // NEUTRAL TONE FOR EVERY PACE. Colouring Slow as a warning would
              // make a descriptive tag look like a finding, which is exactly
              // what the spec says it is not.
              child: pace == null
                  ? Text('-', style: context.type.bodySecondary)
                  : Pill(pace.label, Tone.inert),
            ),
          ], onTap: () => context.nav.attempt(r.e.id));
        }).toList(),
      ),
    );
  }
}

/// Cohort performance per assessment, searchable and paged.
///
/// Four columns, not seven: at the width this panel gets in a two-up band the
/// halves are roughly 545/435, and the seven-column version wanted 870 on its
/// own, so Decided, Passed and Awaiting came out. Each row still opens the
/// assessment, where all of them are reported in full.
class _PerformancePanel extends StatefulWidget {
  final AppStore store;
  final List<Assessment> assessments;

  /// The server's per-assessment figures, keyed by id. Empty in seed mode and
  /// before the first live refresh, and an assessment outside the server's own
  /// window is simply absent - both fall back to the local arithmetic.
  final Map<String, AssessmentAnalytics> byAssessment;

  const _PerformancePanel({
    required this.store,
    required this.assessments,
    this.byAssessment = const <String, AssessmentAnalytics>{},
  });

  @override
  State<_PerformancePanel> createState() => _PerformancePanelState();
}

class _PerformancePanelState extends State<_PerformancePanel> {
  String _search = '';
  int _page = 1;
  // TEN, matching the card's height floor. The two panels in this band are
  // read side by side, so a page that can outgrow the floor puts them back to
  // different heights - which is the complaint this pair of numbers answers.
  int _pageSize = 10;

  @override
  Widget build(BuildContext context) {
    final AppStore s = widget.store;
    final String q = _search.trim().toLowerCase();
    final List<Assessment> shown = q.isEmpty
        ? widget.assessments
        : widget.assessments
              .where((Assessment a) => a.name.toLowerCase().contains(q))
              .toList();

    // Clamp before slicing: a search can shorten the list under a page the
    // reader is already standing on. Same order as the Responses table.
    final int total = shown.length;
    final int pageCount = total == 0 ? 1 : ((total - 1) ~/ _pageSize) + 1;
    final int page = _page.clamp(1, pageCount);
    final List<Assessment> pageRows = shown
        .skip((page - 1) * _pageSize)
        .take(_pageSize)
        .toList();

    return Panel(
      height: Sizes.panelTable,
      title: 'Performance by Assessment',
      // Percentages are legitimate here and only here: these aggregate
      // ACROSS candidates, where one person's "X / N" is not comparable to
      // another's. Invariant 2 governs a candidate's own score on a
      // candidate-facing row, which is not this.
      note: 'cohort averages, not individual scores',
      flush: true,
      toolbar: Toolbar(<Widget>[
        SearchField(
          value: _search,
          hint: 'Search assessments',
          onChanged: (String v) => setState(() {
            _search = v;
            _page = 1;
          }),
        ),
        const Spacer(),
        // The FILTERED total, not the page: "3 shown" over a 20-row page
        // would read as a broken search.
        TagChip('$total shown'),
      ]),
      footer: Pagination(
        page: page,
        pageSize: _pageSize,
        total: total,
        onPage: (int p) => setState(() => _page = p),
        onPageSize: (int n) => setState(() {
          _pageSize = n;
          _page = 1;
        }),
      ),
      child: DataGrid(
        // Five columns: three fixed at 110, 110 and 156, one numeric at 92,
        // four 12px gaps and 30 of row padding, leaving the name column room
        // to flex. Starts is the date only: with the IST time it was 150 wide
        // and pushed Avg score off a 1440px screen (F1-03). Past this the grid
        // scrolls horizontally inside the ~545px half, which is what every
        // other table here already does when it outgrows its space -
        // preferable to dropping a column, since three were removed from this
        // one once already.
        minWidth: 630,
        rowHeight: Sizes.tableRow,
        emptyIcon: Icons.insights_outlined,
        emptyMessage: q.isEmpty
            ? 'No results yet.'
            : 'No assessment matches "$_search".',
        cols: const <Col>[
          Col('Assessment', flex: 3),
          Col('State', width: 110),
          // WHEN IT RAN. Scheduled start, not created: this table is about
          // cohorts that have sat something, and the date worth reading beside
          // a pass rate is the date the paper was open. Blank for an
          // assessment that was never scheduled, which renders as `-`.
          Col('Starts', width: 110),
          Col('Progress', width: 156),
          Col('Avg score', width: 92, numeric: true),
        ],
        rows: pageRows.map((Assessment a) {
          final List<Attempt> evs = s.attemptsFor(a.id);
          final int assigned = a.assignedCount >= 0
              ? a.assignedCount
              : evs.length;
          final int sent = a.submittedCount >= 0
              ? a.submittedCount
              : evs.where((Attempt e) => e.isDone).length;
          final int released = a.releasedCount >= 0
              ? a.releasedCount
              : evs.where((Attempt e) => e.resultsReleased).length;
          // AVG SCORE moved under navigation for the same reason the cohort
          // totals did: `_resultOf` cannot reach a verdict without the
          // assessment's questions, which a list row does not carry, so this
          // column read "-" until the operator opened that assessment and
          // then showed a figure. The server decided every row already.
          final AssessmentAnalytics? row = widget.byAssessment[a.id];
          final List<Attempt> ruled = evs
              .where((Attempt e) => _resultOf(a, e) != ResultState.pending)
              .toList();
          final int decidedHere = row?.decided ?? ruled.length;
          final double mean = row != null
              ? row.avgScore
              : (ruled.isEmpty
                    ? 0
                    : ruled.fold<double>(
                            0,
                            (double n, Attempt e) => n + e.internalPercent(a),
                          ) /
                          ruled.length);

          return GridRow(onTap: () => context.nav.assessment(a.id), <Widget>[
            // One line: fixed `rowHeight` in a fixed-height panel - see :1184.
            GridLink(a.name, maxLines: 1),
            (a.state == AsmState.inProgress && assigned > sent && assigned > 0)
                ? Tooltip(
                    message:
                        'Still open: ${assigned - sent} of $assigned have '
                        'not sat this yet.',
                    child: Pill.state(a.state),
                  )
                : Pill.state(a.state),
            Text(
              a.startDate == null ? '-' : istShortDate(a.startDate!),
              style: context.type.tableCell,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            FunnelCell(assigned: assigned, submitted: sent, released: released),
            Mono(decidedHere == 0 ? '-' : _pct(mean)),
          ]);
        }).toList(),
      ),
    );
  }
}

/// The cross-assessment leaderboard, searchable, with clickable candidates.
///
/// The SERVER's ranking, not a client recompute. Ranking from the cached
/// attempts dropped every unreleased one, so this panel read "Nobody can be
/// ranked yet" while nine candidates were ranked - and it contradicted the
/// score distribution above it. Release governs the CANDIDATE's own view, not
/// the admin's.
class _LeaderboardPanel extends StatefulWidget {
  final AppStore store;

  /// Whether the board has been narrowed to one assessment. Wording only -
  /// the rows arrive already scoped.
  final bool scoped;

  const _LeaderboardPanel({required this.store, this.scoped = false});

  @override
  State<_LeaderboardPanel> createState() => _LeaderboardPanelState();
}

class _LeaderboardPanelState extends State<_LeaderboardPanel> {
  String _search = '';
  int _page = 1;

  /// Ten, to match the panel height floor and its neighbour. See
  /// `_PerformancePanelState`.
  int _pageSize = 10;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final String q = _search.trim().toLowerCase();
    final List<Map<String, dynamic>> all = widget.store.leaderboard;
    final List<Map<String, dynamic>> top = q.isEmpty
        ? all
        : all
              .where(
                (Map<String, dynamic> r) => jval<String>(
                  r,
                  'applicantName',
                  '',
                ).toLowerCase().contains(q),
              )
              .toList();

    final int total = top.length;
    final int pageCount = total == 0 ? 1 : ((total - 1) ~/ _pageSize) + 1;
    final int page = _page.clamp(1, pageCount);
    // The offset is carried into the rows because RANK IS ABSOLUTE. The row
    // falls back to its index when the server sends no `rank`, and a
    // page-local index would restart the ranking at 1 on every page.
    final int from = (page - 1) * _pageSize;
    final List<Map<String, dynamic>> pageRows = top
        .skip(from)
        .take(_pageSize)
        .toList();

    return Panel(
      height: Sizes.panelTable,
      title: 'Leaderboard',
      // HONEST ABOUT ITS OWN CEILING (SNo 108).
      //
      // This said "every submitted attempt" unconditionally while the client
      // asked for 200 rows and the server caps at 2,000 - so on any cohort
      // past either number the board was partial and said it was complete. A
      // candidate missing from it then reads as unranked rather than unshown,
      // which is the wrong way round for the person checking whether their
      // result is in.
      //
      // The route has always answered `{total, returned, truncated}` beside
      // the rows for exactly this; nothing read it until now.
      //
      // One row per CANDIDATE: `total` counts distinct people, and on 6 Oct
      // the note read "of 822 submitted attempts" over 822 people holding
      // 2,101 of them.
      note: widget.store.leaderboardTruncated
          ? 'top ${widget.store.leaderboardReturned} of '
                '${widget.store.leaderboardTotal} candidates with a submitted '
                'attempt'
          : 'every candidate with a submitted attempt',
      flush: true,
      toolbar: Toolbar(<Widget>[
        SearchField(
          value: _search,
          hint: 'Search candidates',
          onChanged: (String v) => setState(() {
            _search = v;
            _page = 1;
          }),
        ),
        const Spacer(),
        TagChip('$total shown'),
      ]),
      footer: Pagination(
        page: page,
        pageSize: _pageSize,
        total: total,
        onPage: (int p) => setState(() => _page = p),
        onPageSize: (int n) => setState(() {
          _pageSize = n;
          _page = 1;
        }),
      ),
      child: DataGrid(
        // Sittings and Best came out for the two-up layout; both are on the
        // candidate's own performance page, which a row now opens.
        minWidth: 360,
        rowHeight: Sizes.tableRow,
        emptyIcon: Icons.emoji_events_outlined,
        emptyMessage: q.isNotEmpty
            ? 'No candidate matches "$_search".'
            // Naming the scope matters: an empty board under a filter is a
            // fact about that assessment, not about the cohort.
            : widget.scoped
            ? 'Nobody has submitted this assessment yet.'
            : 'No submitted attempts yet.',
        cols: const <Col>[
          Col('Rank', width: 74),
          Col('Candidate', flex: 3),
          Col('Avg score', width: 120, numeric: true),
        ],
        rows: <GridRow>[
          for (int i = 0; i < pageRows.length; i++)
            GridRow(
              // The server has always sent `applicant_id` on these rows; the
              // cell just threw it away behind a comment saying there was no
              // person route to open. There is.
              // THAT PERSON'S OWN PERFORMANCE PAGE (A-133, owner's call on
              // 18 Aug): the real My Performance layout, admin-only. A
              // 2026-09-08 change sent it to `CandidateDetailScreen` because
              // the page hid held marks from the releaser; the page now shows
              // an operator every row's marks instead
              // (my_performance_screen.dart `_breakdown`).
              onTap: () {
                final String who = jid(jget(pageRows[i], 'applicantId'));
                if (who.isNotEmpty) context.nav.candidatePerformance(who);
              },
              <Widget>[
                from + i < 3
                    ? StatusBadge(
                        '${jval(pageRows[i], 'rank', from + i + 1)}',
                        Tone.accent,
                        leading: Icon(
                          Icons.emoji_events_outlined,
                          size: 12,
                          color: t.primary,
                        ),
                      )
                    : Mono('${jval(pageRows[i], 'rank', from + i + 1)}'),
                // One line: fixed `rowHeight` in a fixed-height panel - see
                // :1184.
                //
                // NO FLAG HERE, and that is a fact about the DATA rather than
                // a want of room. This panel ranks a PERSON across every
                // assessment in the window, while a flag is raised on one
                // SITTING - so a row that aggregates three attempts has no
                // single flag to stand for, and the glyph that used to sit
                // here silently showed whichever attempt the leaderboard row
                // happened to carry. An operator reading it as "this candidate
                // is flagged" would have been wrong two thirds of the time.
                // The flag lives on the assessment's own Candidates and
                // Leaderboard tabs, where one row IS one attempt.
                GridLink(
                  jval<String>(pageRows[i], 'applicantName', ''),
                  maxLines: 1,
                ),
                // DOUBLE fallback, not `0`. `avg_score` arrives as 66.7, and
                // on the web there is one numeric type - `0 is double` is TRUE
                // in compiled JavaScript, so an int fallback sent the value
                // down jval's double branch and then cast it to int:
                // "66.7: type 'double' is not a subtype of type 'int'". That
                // threw during build and painted the whole dashboard grey.
                Mono('${jval(pageRows[i], 'avgScore', 0.0)}%'),
              ],
            ),
        ],
      ),
    );
  }
}

/// The pass mark to draw the category chart against.
///
/// One assessment selected: its own threshold. Filtered to "All": the mean of
/// the visible thresholds, because a single line has to stand for a mixed
/// cohort and picking the first assessment's would be arbitrary. Falls back to
/// the platform default when nothing is loaded.
double _passThresholdOf(List<Assessment> visible) {
  if (visible.isEmpty) return 70;
  if (visible.length == 1) return visible.first.passThreshold;
  final double sum = visible.fold<double>(
    0,
    (double acc, Assessment a) => acc + a.passThreshold,
  );
  return sum / visible.length;
}

/// Cohort strengths and weaknesses, by category.
///
/// The doc asks for "category-level averages, scoped per assessment (not
/// all-up), for targeted coaching" - so this reads the analytics route, which
/// already honours the screen's assessment filter, rather than averaging every
/// assessment together.
///
/// REUSES `CategoryCard`, the same widget the candidate page and the attempt
/// detail use. One chart, one set of wording rules, one definition of
/// strongest and weakest - a second implementation would drift.
class _CohortCategoriesPanel extends StatelessWidget {
  const _CohortCategoriesPanel({
    required this.categories,
    required this.threshold,
  });

  final List<CohortCategory> categories;
  final double threshold;

  @override
  Widget build(BuildContext context) => Panel(
    title: 'Strengths and Weaknesses',
    note: 'where the cohort is strong and weak',
    child: categories.isEmpty
        ? const EmptyLine('No tagged answers yet.')
        : Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: CategoryCard(
              // The server ranks these; `CategoryScore` carries the marks so
              // the card can show "13 of 16" rather than a bare percentage.
              scores: <CategoryScore>[
                for (final CohortCategory c in categories)
                  CategoryScore(
                    tag: c.tag,
                    earned: c.earned,
                    possible: c.possible,
                    answers: c.answers,
                    // The server's own readable name. It was being dropped
                    // here and re-derived from the machine key, which is how
                    // a tag pinned as "AI Image Editing" reached the screen
                    // as "Ai image editing".
                    serverLabel: c.label,
                  ),
              ],
              threshold: threshold,
              showEnds: true,
            ),
          ),
  );
}
