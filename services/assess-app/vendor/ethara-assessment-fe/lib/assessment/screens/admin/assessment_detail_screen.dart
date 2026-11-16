// The assessment form - HANDOVER §4.3, §4.4.
//
// The single record surface for one assessment across its whole life. Five
// tabs, and the tab set itself encodes the lifecycle: a tab that does not
// apply is DISABLED AND LEFT VISIBLE so the shape of the record stays legible.
//
// Two sheets live here, and both exist because their action is irreversible:
// the launch checks (which evaluate all seven gates together and stay disabled
// while any fails) and the release confirmation (which names who is still
// being graded before it writes).
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/file_pick_stub.dart'
    if (dart.library.js_interop) '../../../services/file_pick_web.dart';

import '../../data/api_client.dart';
import '../../domain/enums.dart';
import '../../domain/gates.dart';
import '../../domain/generated_question_mapper.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../widgets/annotation_editor_sheet.dart';
import '../../widgets/answer_key.dart';
import '../../widgets/buttons.dart';
import '../../widgets/candidate_flag_sheet.dart';
import '../../widgets/disclosure.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/editable_title.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../../widgets/question_editor.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/controls.dart';
import '../exam/answer_layouts.dart';
import '../exam/exam_screen.dart';
import '../../widgets/violation_policy.dart';
import 'task_template_editor.dart';
import '../../theme.dart';
import '../../nav.dart';

/// Whether the assessment page offers Delete. OFF.
///
/// Delete destroys every attempt and answer, and once candidates have sat a
/// paper one mistaken click loses their work for good. Archive does what an
/// operator finishing with a paper needs, and it can be undone. Hidden in the
/// UI only: the route and the whole three-step flow behind it are untouched,
/// and the tests of that flow turn this on.
@visibleForTesting
bool showAssessmentDelete = false;

class AssessmentDetailScreen extends StatefulWidget {
  final AppStore store;
  final Portal portal;
  final String asmId;
  final String? tab;

  const AssessmentDetailScreen({
    super.key,
    required this.store,
    required this.portal,
    required this.asmId,
    this.tab,
  });

  /// Draws the 0-5 s spread on the run-end detail read. A seam so a test can
  /// fix the draw; production never sets it.
  @visibleForTesting
  static math.Random runEndJitter = math.Random();

  /// How the CSV import asks for a file. A seam so a test can answer the
  /// picker (`pickFile` is null off the web); production never sets it.
  @visibleForTesting
  static Future<PickedFile?> Function({String accept}) pick = pickFile;

  @override
  State<AssessmentDetailScreen> createState() => _AssessmentDetailScreenState();
}

class _AssessmentDetailScreenState extends State<AssessmentDetailScreen>
    with WidgetsBindingObserver {
  late String _tab = widget.tab ?? 'config';
  String _rosterSearch = '';

  /// Ticks while the server says this assessment is being graded.
  ///
  /// THE REPORT THIS CLOSES. Scoring runs in an Odoo cron - four shards, a
  /// one-minute tick, around twenty candidates a tick - so after the "Queued
  /// 711 candidate(s)" toast nothing on this screen moved again until the
  /// operator reloaded the page by hand. On a cohort that size that is half an
  /// hour with no way to tell a run in flight from a button that did nothing.
  ///
  /// NOT `pollGeneration`, and the choice is deliberate. That loop is
  /// store-owned and single-tenant - its `_polling` flag means one generation
  /// anywhere in the console would starve this watch, and this watch would
  /// starve it back - while its stop condition, its fingerprint and the two
  /// lists it re-reads are all generator-specific. It also ticks every two
  /// seconds, which against a cron that moves once a minute is thirty wasted
  /// requests a tick. What IS borrowed is everything it learned: stop on your
  /// own, cap the ticks, and never put the heavy route on the timer.
  Timer? _scoringPoll;
  int _scoringTicks = 0;

  /// Guards a tick against the tick before it, for a server slower than the
  /// interval. `pollGeneration` gets this free by awaiting inside its own loop;
  /// a periodic timer does not.
  bool _scoringInFlight = false;

  /// The grader's own health, as the poll last reported it.
  ///
  /// Held on the screen rather than in the store because `store.scoringPipeline`
  /// is the DASHBOARD's, scoped to whatever filter that screen last applied -
  /// writing an assessment-scoped read into it would leave the dashboard
  /// mounting with narrowed lane counts while `analyticsScope` still said
  /// all-up. This one is scoped by construction: it lives exactly as long as
  /// the screen looking at this assessment.
  ScoringPipeline? _pipe;

  /// Five seconds against a cron that moves once a minute: soon enough that a
  /// phase change feels immediate. [_kRunBackoff] stretches it while nothing
  /// moves.
  static const Duration _kScoringPollEvery = Duration(seconds: 5);

  /// The run's rate, backing off while the numbers hold still.
  ///
  /// The cron moves once a minute, so most 5 s ticks answer exactly what the
  /// last one did. After one unchanged answer the watch waits 15 s, after two
  /// 30 s, and the first change snaps it back to 5 s - about 4 requests a
  /// minute per open tab instead of 12.
  static const List<Duration> _kRunBackoff = <Duration>[
    _kScoringPollEvery,
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  /// How many ticks in a row answered the same numbers, and what they were.
  int _unchanged = 0;
  String? _lastNumbers;

  /// The browser tab is hidden. Nobody is reading the numbers, so the watch
  /// sleeps and catches up the moment the tab is shown again.
  bool _hidden = false;

  /// The pending run-end detail read. See [_reloadAfterRun].
  Timer? _runEndReload;

  /// A minute, for a queue nobody is draining.
  ///
  /// `stalled` IS NOT A TERMINAL SERVER STATE, and treating it as one is what
  /// this rate exists to undo. `_scoring_drainer_health` recomputes `blocked`
  /// from the cron's `active`/`nextcall` on every read, so re-enabling or
  /// catching up the cron - exactly the remediation the banner above asks for,
  /// performed in Odoo, on another tab - clears it. Watched at the busy rate
  /// that would be twelve requests a minute against a change only a human can
  /// make; not watched at all, an operator who performed that remediation kept
  /// a red "Grading is not running." over a cohort that had finished grading,
  /// for as long as the tab stayed open.
  static const Duration _kStalledRecheckEvery = Duration(minutes: 1);

  /// An hour at [_kScoringPollEvery], six once fully backed off. A cap, not a
  /// schedule: a phase that never leaves `scoring` - a worker holding a row it
  /// will never finish - must not leave a timer running for the rest of the
  /// session. 711 candidates at the cron's rate is about 36 minutes, so this
  /// outlasts the longest run this console has seen and still ends. The same
  /// budget bounds the slow re-check, where it is twelve hours rather than one.
  static const int _kScoringPollMaxTicks = 720;

  /// The interval [_scoringPoll] is running at, or null when nothing is armed.
  ///
  /// The RATE is what says which watch is up, and there are two: the run's and
  /// a stalled queue's. `_scoringPoll != null` no longer answers "is a run
  /// being watched", so the edge that spends the closing detail read reads
  /// this instead.
  Duration? _pollEvery;

  @override
  void initState() {
    super.initState();
    // Hydrate from the DETAIL route. The list row that got us here carries
    // `candidate_count` but no `roster`, so without this the Assign tab reads
    // "Nobody is assigned yet" while the server holds the invited people.
    widget.store.loadAssessment(widget.asmId);
    // THE STORE DRIVES THE WATCH, not `build`. Starting a timer from a build is
    // a side effect in the one method that must not have them, and the phase
    // arrives from three different places - this load, a poll tick, and a list
    // refresh landing underneath - so reacting to the notify covers all three
    // at once.
    widget.store.addListener(_syncScoringPoll);
    WidgetsBinding.instance.addObserver(this);
    _hidden = _isHidden(WidgetsBinding.instance.lifecycleState);
  }

  @override
  void dispose() {
    widget.store.removeListener(_syncScoringPoll);
    WidgetsBinding.instance.removeObserver(this);
    _scoringPoll?.cancel();
    _runEndReload?.cancel();
    super.dispose();
  }

  /// Flutter web reports the page's `visibilitychange` as `hidden` and
  /// `resumed`. `inactive` is only a blur - a tab on a second monitor is still
  /// being watched, so it keeps polling.
  static bool _isHidden(AppLifecycleState? s) =>
      s == AppLifecycleState.hidden || s == AppLifecycleState.paused;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool hidden = _isHidden(state);
    if (hidden == _hidden) return;
    _hidden = hidden;
    if (hidden) {
      _scoringPoll?.cancel();
      return;
    }
    // Shown again: read now rather than finishing a backed-off wait. A tick
    // still in flight re-arms itself when it lands.
    if (_pollEvery != null && !_scoringInFlight) {
      _scoringPoll?.cancel();
      _scoringPoll = Timer(Duration.zero, _tickScoring);
    }
  }

  /// Start, keep, or stop the watch to match what the server last said.
  ///
  /// The `busy -> not busy` EDGE is the part that matters: that is a run
  /// ending, and it is the moment everything else on the screen went stale.
  ///
  /// `stalled` TAKES THAT EDGE TOO, and deliberately. It is a run that will
  /// never end on its own rather than one that has, but it is not
  /// [ScoringPhase.isBusy] - so it leaves the run's rate and spends the one
  /// closing detail read, which is what puts the stalled banner and the
  /// settled roster on screen without the operator touching anything.
  ///
  /// IT DOES NOT STOP DEAD THERE, and that was the defect. `stalled` is the
  /// server's reading of a cron, not a terminal state, and the only thing that
  /// could ever change it is a fetch - so cancelling the last watch meant a run
  /// the operator restarted in Odoo was never seen again and the red banner
  /// stayed over a stale roster until the tab was reloaded. It drops to
  /// [_kStalledRecheckEvery] instead: slow enough to be free against a change
  /// only a human can make, and a way back.
  void _syncScoringPoll() {
    if (!mounted) return;
    final Assessment? asm = widget.store.asmById(widget.asmId);
    final ScoringPhase? phase = asm?.scoringPhase;
    // THE RATE IS THE PHASE'S, and null means no watch at all: `idle`, and a
    // deployment too old to name a phase, have nothing to wait for.
    final Duration? every = (phase?.isBusy ?? false)
        ? _kScoringPollEvery
        : phase == ScoringPhase.stalled
        ? _kStalledRecheckEvery
        : null;
    // The RUN's watch specifically, not any watch - the closing read below
    // belongs to a run ending, and a stalled queue re-checking itself is not
    // that.
    final bool wasWatchingRun = _pollEvery == _kScoringPollEvery;
    if (every != null) {
      // THE BUDGET BELONGS TO THE RUN, not to one arming of the timer, and
      // resetting the count here would have cancelled the cap outright. The
      // tick that gives up leaves `_scoringPoll` null while the phase is still
      // busy - giving up does not change what the server says - so the very
      // next notify would re-arm from zero. The store notifies twice per call
      // and `pollGeneration` notifies every two seconds, so "gave up after an
      // hour" would have meant polling for the rest of the session. The count
      // is cleared where a run actually ends, below, and on navigation.
      if (_pollEvery != every && _scoringTicks < _kScoringPollMaxTicks) {
        // RE-ARMED BEFORE THE FETCH BELOW, for the same reason the cancel used
        // to come first: `_withHydration` notifies SYNCHRONOUSLY before its
        // await, so `loadAssessment` re-enters this method on the same stack.
        // It terminates only because `_pollEvery` already holds the new rate by
        // then, so the re-entrant pass matches it and issues nothing.
        _stopScoringPoll();
        _pollEvery = every;
        _unchanged = 0;
        _lastNumbers = null;
        _scheduleScoringTick();
      }
      // ONE FULL DETAIL READ when the run stops, and only then. The poll route
      // answers counters, not rows, so without this the header would announce
      // that grading was over above the scores and verdicts it held when
      // grading began. Guarded on the edge because this method runs on every
      // notify and the read it makes is itself a notify - on a level it would
      // fetch forever.
      if (wasWatchingRun && every != _kScoringPollEvery) _reloadAfterRun();
      return;
    }
    // THE CANCEL MUST COME BEFORE THE FETCH BELOW, same rule as above.
    _stopScoringPoll();
    _scoringTicks = 0;
    if (wasWatchingRun) _reloadAfterRun();
  }

  void _stopScoringPoll() {
    _scoringPoll?.cancel();
    _scoringPoll = null;
    _pollEvery = null;
  }

  /// Arm the next tick: one-shot, because the wait depends on what the last
  /// tick saw. Nothing when a tick is already pending, the watch is off, or
  /// the tab is hidden - [didChangeAppLifecycleState] wakes it.
  void _scheduleScoringTick() {
    final Duration? every = _pollEvery;
    if (every == null || _hidden || (_scoringPoll?.isActive ?? false)) return;
    _scoringPoll = Timer(
      every == _kScoringPollEvery
          ? _kRunBackoff[math.min(_unchanged, _kRunBackoff.length - 1)]
          : every,
      _tickScoring,
    );
  }

  /// The one detail read a run ending earns, SPREAD over 0-5 s. Every tab open
  /// on this paper sees the run end on the same tick, and the detail route is
  /// the heavy one - read at once, they land on the server as one burst.
  void _reloadAfterRun() {
    _runEndReload?.cancel();
    final String asked = widget.asmId;
    _runEndReload = Timer(
      Duration(milliseconds: AssessmentDetailScreen.runEndJitter.nextInt(5001)),
      () {
        if (mounted && asked == widget.asmId) {
          widget.store.loadAssessment(asked);
        }
      },
    );
  }

  Future<void> _tickScoring() async {
    if (!mounted || ++_scoringTicks > _kScoringPollMaxTicks) {
      _stopScoringPoll();
      return;
    }
    // The tick in flight re-arms the watch when it lands.
    if (_scoringInFlight) return;
    _scoringInFlight = true;
    try {
      // THE LIGHT ROUTE, never `/assessments/<id>`. This is the lesson
      // `pollGeneration` paid for the hard way: it used to call the store-wide
      // `refresh()` on its tick and dragged an unbounded `/responses` walk
      // along with it. `/scoring` answers counters, which is everything a tick
      // needs to decide anything.
      final String asked = widget.asmId;
      final ScoringPipeline? pipe = await widget.store.loadScoring(
        assessmentId: asked,
      );
      // THE ID IS RE-CHECKED, the same rule `loadRoster`'s sequence guard
      // follows: the router reuses this State across a walk to another
      // assessment, so a tick already on the wire can land after the operator
      // has moved on and would file the old assessment's drainer under the new
      // one's name.
      if (!mounted || asked != widget.asmId) return;
      // THE NUMBERS, not the record: an unchanged answer is what backs the
      // watch off, and any change - a count, the phase - snaps it back.
      final String numbers =
          '${pipe?.phase}|${pipe?.summary}|${pipe?.queued}|'
          '${pipe?.needsManualRequeue}|${pipe?.stalled}';
      _unchanged = numbers == _lastNumbers ? _unchanged + 1 : 0;
      _lastNumbers = numbers;
      setState(() => _pipe = pipe);
    } finally {
      _scoringInFlight = false;
      if (mounted) _scheduleScoringTick();
    }
  }

  /// Re-hydrate when the route points at a different assessment.
  ///
  /// `initState` runs once per State, and the router builds this screen with
  /// no key at a fixed slot, so walking from one assessment to another reused
  /// the same State and never fetched the second. Everything the detail route
  /// adds over the list row - the roster, the selected questions, the rules -
  /// then rendered as the empty state until a browser refresh.
  @override
  void didUpdateWidget(AssessmentDetailScreen old) {
    super.didUpdateWidget(old);
    if (old.asmId != widget.asmId) {
      // The watch belongs to the assessment being looked at, not to this State,
      // which the router reuses across a walk from one assessment to another -
      // so a timer left running would go on polling the record the operator has
      // just navigated away from, and `_pipe` would report its drainer under
      // the new one's name.
      _stopScoringPoll();
      _runEndReload?.cancel();
      _scoringTicks = 0;
      _scoringInFlight = false;
      _pipe = null;
      widget.store.loadAssessment(widget.asmId);
    }
    // Back or Forward between two tabs of this page: the route moved, this
    // State stayed (`pageOf`), so the tab follows the route.
    if (old.tab != widget.tab) _tab = widget.tab ?? 'config';
  }

  /// Open tab [k], as a history entry: the address bar and Back follow it.
  void _showTab(String k) {
    setState(() => _tab = k);
    AssessmentNavScope.maybeRead(
      context,
    )?.go(AssessmentDetail(widget.asmId, tab: k));
  }

  @override
  Widget build(BuildContext context) {
    final AppStore s = widget.store;

    return ListenableBuilder(
      listenable: s,
      builder: (BuildContext context, _) {
        final Assessment? asm = s.asmById(widget.asmId);
        if (asm == null) {
          // Still arriving is NOT "removed". The fetch starts in initState, so
          // the first build always ran before any answer could land and stated
          // a deletion that had not happened.
          if (s.isHydrating('assessment', widget.asmId)) {
            return const DetailScreenSkeleton();
          }
          return PageBody(
            children: <Widget>[
              PageHead(
                'Assessment not found',
                sub: 'It may have been removed.',
              ),
              Panel(
                child: const EmptyLine(
                  'Nothing to show. Go back to the list and pick another.',
                ),
              ),
            ],
          );
        }

        final List<Attempt> evs = s.attemptsFor(asm.id);
        final bool isDraft = asm.state.isDraft;
        // Everyone Release writes, still-grading attempts included - see
        // [AppStore.toRelease]. The scored ones alone undercounted it.
        final int toRelease = s.toRelease(asm).length;
        // THE COUNT, not merely the fact. One held candidate and forty read
        // identically on a banner that only said "an answer", and the operator
        // chasing it needs to know how much of the paper is stuck. `hasError`
        // is derived from the same number so the two cannot disagree.
        final int heldCount = evs
            .where((Attempt e) => e.hasScoringError(asm))
            .length;
        final bool hasError = heldCount > 0;

        // A tab that resolves as disabled falls back to Configuration, so a
        // stale deep link never lands on a greyed surface.
        final List<TabDef> tabs = <TabDef>[
          const TabDef('config', 'Configuration'),
          // The ASSIGN tab counts the roster: before launch there are no
          // attempts, so `evs.length` was 0 beside a chip list showing two
          // people. The CANDIDATES tab keeps counting attempts, because that
          // is what it lists.
          TabDef(
            'assign',
            'Assign Candidates',
            count: evs.isNotEmpty ? evs.length : asm.roster.length,
            disabled: !isDraft,
          ),
          // THE SERVER'S COUNT, NOT THE CACHE'S. `evs` comes from
          // `attemptsFor`, which reads the console-wide attempts cache, and
          // that cache is CAPPED at `maxPages: 25` x 200 = 5,000 rows ordered
          // newest-first (`app_store.dart`). Production passed that: 7,373
          // attempts, so the oldest ~2,300 are simply not in it, and every
          // assessment old enough to fall outside the window rendered
          // "Candidates 0" beside a roster that plainly held people - measured
          // on prod, assessment 49 showing "Assign Candidates 7" and
          // "Candidates 0" at the same time, while a newer 711-candidate paper
          // counted correctly.
          //
          // `assignedCount` is `len(assessment.assessment_evaluator_ids)` from
          // `serializers.py`, computed per request over the real rows, so it
          // does not care how much of the cache the walk happened to reach.
          // It is -1 when the payload did not carry it (a list row rather than
          // a detail row), and only then is the cache the better answer.
          TabDef(
            'candidates',
            'Candidates',
            count: asm.assignedCount >= 0 ? asm.assignedCount : evs.length,
            disabled: isDraft,
          ),
          TabDef('leaderboard', 'Leaderboard', disabled: isDraft),
          // ENABLED ON A DRAFT. This was disabled until launch, so you could
          // not look at the questions you had just picked until the moment
          // they became unchangeable - exactly backwards. The tab is
          // read-only either way; seeing the selection is the point.
          // `effectiveQuestionCount`, not `totalQuestions`. The latter reads
          // `questions`, which the launch route fills only once a paper has been
          // DRAWN - so this badge read 0 on every draft, over a tab listing six
          // ticked rows. The two agree after launch, which is when the drawn
          // paper is the honest answer.
          TabDef(
            'questions',
            'Selected Questions',
            count: asm.effectiveQuestionCount,
          ),
        ];
        final TabDef active = tabs.firstWhere(
          (TabDef d) => d.key == _tab && !d.disabled,
          orElse: () => tabs.first,
        );
        // Null for a draft, which was never conducted. IST with the zone
        // named, so the header says the same thing to every reader.
        final DateTime? launchedAt = asm.launchedAt;
        final String conducted = launchedAt == null
            ? ''
            : '  ·  Conducted ${istDateTime(launchedAt)}';

        return PageBody(
          children: <Widget>[
            Crumbs(<Crumb>[
              Crumb('Assessments', () => context.nav.assessments()),
              Crumb(asm.name),
            ]),
            PageHead(
              asm.name,
              // The name is a FIELD of the record, edited where it is read -
              // the same control the generator title uses. Renaming is allowed
              // in every state: it does not change the exam anybody agreed to,
              // and an assessment whose name was wrong could otherwise never be
              // corrected once it had launched (`name` is in the server's
              // POST_DRAFT_FIELDS for exactly that reason).
              titleChild: EditableTitle(
                value: asm.name,
                enabled: s.isLive && s.can(Capability.configure),
                onCommit: (String next) => s.saveAssessmentName(asm.id, next),
              ),
              sub:
                  '${asm.generatorName}  \u00b7  '
                  '${asm.effectiveQuestionCount} questions$conducted',
              actions: _headerActions(context, s, asm, toRelease),
            ),
            Row(children: <Widget>[StatusBar(asm.state)]),
            const SizedBox(height: 16),
            if (!asm.active) ...<Widget>[
              Notice(
                tone: Tone.inert,
                strong: 'Archived.',
                text:
                    'Hidden from lists and figures. Scoring, invitations '
                    'and auto-submits are paused. Restore resumes them.',
                actions: <Widget>[
                  // The NOTICE is for every operator - being archived is why
                  // this assessment is absent from the list and from every
                  // dashboard figure, and a read-only Manager needs that
                  // explanation as much as an Admin does. Un-archiving is a
                  // lifecycle action behind an Admin-only route, so offering
                  // them Restore meant a 403 and a notice that did not budge,
                  // with nothing on screen to say why. The reading stays, the
                  // recovery goes.
                  if (s.can(Capability.lifecycle))
                    Btn(
                      'Restore',
                      tooltip:
                          'Un-archive this assessment so it appears in the '
                          'list and in the dashboard figures again.',
                      size: BtnSize.sm,
                      busy: s.isBusy('archive:${asm.id}'),
                      onPressed: s.isLive
                          ? () => s.archiveAssessment(asm.id, archive: false)
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            if (hasError) ...<Widget>[
              Notice(
                tone: Tone.bad,
                strong: heldCount == 1
                    ? '1 candidate held on a scoring error.'
                    : '$heldCount candidates held on a scoring error.',
                text:
                    'Results stay pending, not failed. Nothing retries on its '
                    'own. The reason is on the Responses screen - read it '
                    'before re-scoring.',
                actions: <Widget>[
                  // A held answer is worth telling a Manager about: it is why
                  // results on this paper read pending, and they may well be
                  // the person who has to chase it. Clearing it is not theirs
                  // to do - re-scoring spends LLM calls on an Admin-only route
                  // - so the sentence stays and the trigger goes rather than
                  // sitting there returning 403.
                  // Not on a cancelled paper: the reset would queue paid
                  // grading the queue route then refuses (R7-01).
                  if (s.can(Capability.lifecycle) &&
                      asm.state != AsmState.cancelled)
                    Btn(
                      'Re-score This Assessment',
                      tooltip:
                          'Reset the failed and errored answers on this paper, '
                          'then queue every unresolved answer for grading. One '
                          'LLM call grades up to 20 answers.',
                      size: BtnSize.sm,
                      onPressed: asm.scoringPhase == ScoringPhase.stopping
                          ? null
                          : () => s.rescore(asm),
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            // THE CRON IS DEAD - above the readout it invalidates, for the same
            // reason the dashboard puts its copy above the figures rather than
            // under them. A queue that will never drain is not a queue an
            // operator should be told to wait out, and "238 queued" under a
            // healthy-looking banner says exactly that.
            //
            // Read from the poll's own answer rather than `store.scoringPipeline`,
            // which only the dashboard ever fills: a deep link straight to this
            // screen would have found it null and rendered nothing, and silence
            // here reads as "the grader is fine".
            //
            // ONE BANNER OUT OF TWO SIGNALS. `scoring_phase == stalled` is this
            // paper's own verdict and rides in on the record, so it is on
            // screen at first paint and costs no request; `drainer.stalled` is
            // the machine's, and it is the wider fact - a dead cron stalls
            // every cohort at once, including papers with nothing queued, whose
            // phase the server resolves to `idle`. Both say "nothing is
            // grading", so they share one Notice rather than stacking two that
            // repeat each other. The phase decides whether it appears; the
            // poll's `reason` fills it in when a tick happened to run.
            //
            // AND IT MUST NOT WAIT FOR THAT TICK. `stalled` is deliberately not
            // `isBusy`, so the run's watch is never armed on it - reading
            // `_pipe` alone meant a deep link to a stalled assessment showed
            // nothing, for as long as the operator stayed on the screen.
            //
            // THIS PAPER'S OWN PHASE OUTRANKS THE MACHINE'S, which is what
            // keeps it to one banner. The two signals are computed
            // independently and do not exclude each other: `drainer.stalled` is
            // cohort-wide (a higher shard disabled, or a cron past its
            // `nextcall`) while `_compute_scoring_progress` checks `running`
            // BEFORE it ever consults that health, so a shard actively holding
            // a row on this paper answers `phase: scoring` beside
            // `drainer.stalled: true`. Read as an `||` that stacked a red
            // "Grading is not running." on top of a live blue "Scoring." with
            // its spinner - two banners contradicting each other over a paper
            // that was being graded normally. When the server has named a busy
            // phase for THIS paper it is the more specific answer and it wins;
            // the machine-wide verdict still speaks for every phase that is not
            // busy, including the `idle` papers with nothing queued that it
            // exists for.
            // THE LAST FINISHED RESULT, AND WHEN. While a run is live the
            // server sends the tally saved when that run started, so "400/650"
            // stays put under Score All and moves only when the run ends.
            if (asm.scoringScored > 0 &&
                asm.scoringFinishedAt != null) ...<Widget>[
              Notice(
                tone: asm.scoringScored >= asm.scoringCandidates
                    ? Tone.ok
                    : Tone.info,
                strong:
                    'Scored ${asm.scoringScored}/${asm.scoringCandidates} '
                    'candidates',
                text: 'on ${istDateAtTime(asm.scoringFinishedAt!)}',
              ),
              const SizedBox(height: 14),
            ],
            if (asm.scoringPhase == ScoringPhase.stalled ||
                (!(asm.scoringPhase?.isBusy ?? false) &&
                    (_pipe?.stalled ?? false))) ...<Widget>[
              Notice(
                tone: Tone.bad,
                strong: 'Grading is not running.',
                text: <String>[
                  // Prose joined by a space and the tally by a dot, not all of
                  // it by dots: `scoring_summary` separates its own lanes with
                  // the same dot, so one list would run the sentences and the
                  // counts together as peers.
                  <String>[
                    (_pipe?.reason ?? '').trim().isNotEmpty
                        ? _pipe!.reason.trim()
                        : 'The grading cron is stopped or overdue, so nothing '
                              'queued below will be scored until it runs '
                              'again.',
                    // The first thing an operator asks of a stopped grader,
                    // and the thing the module's own alert answers in its last
                    // sentence. Without it, "nothing is running" reads as a
                    // meter left going.
                    'Nothing is lost while it waits, and no model calls are '
                        'being made or billed.',
                  ].join(' '),
                  // ONLY THIS PAPER'S OWN, and the readout below is suppressed
                  // at this phase, so without it a stalled assessment carries
                  // no numbers at all - and the size of the stuck queue is the
                  // fact an operator acts on. The tally belongs to the phase
                  // beside it, the rule the readout follows too, so a
                  // machine-wide stall over an assessment with nothing queued
                  // does not borrow a sentence about work it does not have.
                  if (asm.scoringPhase == ScoringPhase.stalled &&
                      asm.scoringSummary.isNotEmpty)
                    asm.scoringSummary,
                ].join('  ·  '),
              ),
              const SizedBox(height: 14),
            ],
            // WHAT THE GRADER IS DOING, WHILE IT DOES IT.
            //
            // Scoring runs in a cron - four shards, a one-minute tick, around
            // twenty candidates a tick - so between the "Queued 711
            // candidate(s)" toast and a manual reload this screen had nothing
            // to say. That is the report: not that grading was slow, but that
            // an operator could not tell it apart from a button that had done
            // nothing at all.
            //
            // THE SERVER'S PHASE, never a count folded out of the attempts
            // cached here - that cache is capped console-wide, so on a large
            // cohort it answers according to how much of the roster happened to
            // load. Null is a deployment that predates the field and renders
            // nothing: a confident "Idle" over a server that cannot say is
            // worse than saying nothing.
            if (asm.scoringPhase?.isBusy ?? false) ...<Widget>[
              Notice(
                tone: Tone.info,
                strong: '${asm.scoringPhase!.label}.',
                text: asm.scoringSummary.isNotEmpty
                    ? asm.scoringSummary
                    : 'This page follows the run and refreshes itself when it '
                          'finishes.',
                // The spinner IS the live affordance. The numbers move every
                // five seconds, and for the other four and a half the banner
                // would read as a frozen page without it.
                actions: const <Widget>[Spinner()],
              ),
              const SizedBox(height: 14),
            ],
            // What is still missing, before the user goes looking. A fresh
            // draft opened on Configuration and showed only settings, so the
            // only route to "no generator, no questions, nobody assigned" was
            // to press Launch and read a sheet of failures.
            if (asm.state.isDraft && s.can(Capability.launch)) ...<Widget>[
              Builder(
                builder: (BuildContext context) {
                  final List<GateResult> failing = s
                      .launchGates(asm)
                      .where((GateResult g) => !g.ok)
                      .toList();
                  if (failing.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Notice(
                      tone: Tone.warn,
                      strong: failing.length == 1
                          ? 'One thing to settle before this can launch.'
                          : '${failing.length} things to settle before this '
                                'can launch.',
                      // The first two, not all seven: the point is to start the
                      // user moving, and the launch sheet lists every one.
                      text: failing
                          .take(2)
                          .map((GateResult g) => g.why)
                          .join('  \u00b7  '),
                      actions: <Widget>[
                        Btn(
                          'See All Checks',
                          size: BtnSize.sm,
                          onPressed: () => _showLaunchSheet(context, s, asm),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
            Panel(
              flush: true,
              toolbar: TabStrip(
                tabs: tabs,
                active: active.key,
                onChanged: _showTab,
              ),
              child: Padding(
                padding: const EdgeInsets.all(15),
                child: switch (active.key) {
                  'assign' => _AssignTab(
                    store: s,
                    asm: asm,
                    search: _rosterSearch,
                    onSearch: (String v) => setState(() => _rosterSearch = v),
                  ),
                  'candidates' => _CandidatesTab(
                    store: s,
                    asm: asm,
                    portal: widget.portal,
                  ),
                  'leaderboard' => _LeaderboardTab(
                    store: s,
                    asm: asm,
                    portal: widget.portal,
                  ),
                  'questions' => _QuestionsTab(store: s, asm: asm),
                  _ => _ConfigTab(store: s, asm: asm, portal: widget.portal),
                },
              ),
            ),
          ],
        );
      },
    );
  }

  /// How many candidates are mid-sitting RIGHT NOW, asked of the server.
  ///
  /// WHY NOT `attemptsFor`. That reads `AppStore.attempts`, a console-wide walk
  /// of `/api/v1/attempts` capped at 25 pages across EVERY assessment and
  /// filled once by `refresh()` - which this screen never calls on a timer. It
  /// reads zero two ways while people are sitting: staleness (every attempt is
  /// `pending` until its candidate presses Begin, and nothing here re-walks
  /// after that) and the cap (an older paper's rows fall out of the newest-
  /// first window). Zero skips the confirmation, so the one action in this set
  /// that cannot be undone had the weakest guard in it - `/archive` and
  /// `/delete` are both refused server-side over a live sitting, `/close` is
  /// not.
  ///
  /// ONE ROW, FOR THE COUNT ON THE ENVELOPE. `_attempt_page` answers
  /// `meta.total` from `search_count` over the whole filtered domain, so
  /// `limit: 1` costs a page of one row and still returns the cohort's true
  /// number - the same number the sheet quotes.
  ///
  /// AND EVERY UNKNOWN ANSWERS 1, never 0. A failed request, a shape this build
  /// cannot read, an envelope with no `meta`: none of them are evidence that
  /// the room is empty, and the fallback for "cannot tell" has to be the
  /// question rather than the irreversible act. The seed rig is the one case
  /// that legitimately answers from the cache - it has no server, and its
  /// fixtures ARE the whole population.
  Future<int> _liveSittingCount(AppStore s, String asmId) async {
    final ApiClient? api = s.api;
    if (api == null) {
      return s
          .attemptsFor(asmId)
          .where((Attempt a) => a.state == AttemptState.inProgress)
          .length;
    }
    try {
      final Map<String, dynamic> page = await api.candidates(
        asmId,
        state: AttemptState.inProgress.wire,
        limit: 1,
      );
      final Object? meta = page['meta'];
      final Object? total = meta is Map ? meta['total'] : null;
      return total is num ? total.toInt() : 1;
    } catch (_) {
      return 1;
    }
  }

  List<Widget> _headerActions(
    BuildContext context,
    AppStore s,
    Assessment asm,
    int toRelease,
  ) {
    final List<Widget> out = <Widget>[];
    final bool canLaunch = s.can(Capability.launch);
    final bool canRelease = s.can(Capability.release);
    final bool canLifecycle = s.can(Capability.lifecycle);

    // NOT ON AN ARCHIVED DRAFT: the route refuses to launch a suspended paper,
    // so the button could only end in a refusal. Restore comes first.
    if (asm.state.isDraft && asm.active && canLaunch) {
      // Say up front how many gates are failing. The button used to look fully
      // enabled on a draft that CANNOT launch, and the only way to find that
      // out was to press it and read a sheet of red.
      //
      // It stays PRESSABLE: the sheet is where the specific failures are
      // named, so disabling it outright would hide the diagnosis. The label
      // carries the count and the tone drops to secondary.
      final int blocking = s
          .launchGates(asm)
          .where((GateResult g) => !g.ok)
          .length;
      out.add(
        blocking == 0
            ? Btn.primary(
                'Launch & Invite',
                tooltip:
                    'Freeze the paper, create an attempt for every assigned '
                    'candidate and email each of them their exam link. Six gates '
                    'run first - a question with no correct answer marked, or '
                    'missing media, refuses the launch rather than shipping a '
                    'paper nobody can pass.',
                icon: Icons.rocket_launch_outlined,
                onPressed: () => _showLaunchSheet(context, s, asm),
              )
            : Btn(
                'Launch & invite ($blocking to fix)',
                tooltip:
                    'Open the launch sheet. $blocking gate(s) still fail, so '
                    'launching is blocked until they are fixed - the sheet '
                    'names each one.',
                icon: Icons.rocket_launch_outlined,
                onPressed: () => _showLaunchSheet(context, s, asm),
              ),
      );
    }
    if (toRelease > 0 && canRelease) {
      out.add(
        Btn.primary(
          'Release results ($toRelease)',
          tooltip:
              'Show these candidates their own marks. Until you do they see '
              'only that the attempt was submitted, and this cannot be undone.',
          onPressed: () => _showReleaseSheet(context, s, asm),
        ),
      );
    }
    // ── The scoring controls, all three of which only make sense once the
    // paper is out. They read the assessment's own attempts rather than the
    // Responses screen's org-wide view, because these buttons act on THIS
    // assessment and nothing else.
    if (!asm.state.isDraft && canLifecycle) {
      final List<Attempt> scoringEvs = s.attemptsFor(asm.id);
      // A Kill still settling would park anything queued now straight back to
      // cancelled, so the server refuses with 409 `stopping` (G1-08).
      final bool stopping = asm.scoringPhase == ScoringPhase.stopping;

      // Waiting on the judge: submitted attempts with a subjective answer
      // not yet scored. `awaitingScoringCount` is the server's own figure
      // (`needs_llm` and not `scored`) and wins whenever it was sent, 0
      // included; the walk is the fallback for a payload that did not.
      //
      // NOT `subjectiveState == pending`. That is the default on EVERY attempt,
      // an objective-only one included, so it offered a paid "Score All" on
      // papers with nothing to grade.
      final bool anyAwaiting = asm.awaitingScoringCount >= 0
          ? asm.awaitingScoringCount > 0
          : scoringEvs.any(
              (Attempt e) =>
                  e.subjectivePending > 0 ||
                  e.subjectiveState == LlmState.queued,
            );

      // Score All: queue everything still waiting. Offered whenever there is
      // genuinely something to grade, done included - not only `state.isLive`.
      // A DONE assessment is exactly where ungraded subjective answers pile
      // up: automatic grading is off by default, so nothing was queued while
      // it ran, and closing an assessment does not grade its papers. Never on
      // a cancelled or archived paper: that spends LLM calls on work somebody
      // called off or suspended.
      if (anyAwaiting && asm.state != AsmState.cancelled && asm.active) {
        out.add(
          Btn.accent(
            'Score All',
            tooltip:
                'Queue every submitted answer still waiting on the judge, on '
                'this assessment. Costs one LLM call per answer.',
            onPressed: stopping
                ? null
                : () => s.queueScoringFor(assessmentId: asm.id),
          ),
        );
      }

      // Score Failed Responses (n): only when n > 0. This codebase's own rule
      // (see responses_screen.dart) - an always-on danger button that reports
      // "nothing is errored" reads as a fault in the button, not an empty
      // queue. `n` is derived client-side from THIS assessment's attempts,
      // using the LlmState vocabulary rather than hard-coded state strings:
      // an attempt is failed if its subjective side is in `scoringFailed`, or
      // if `hasScoringError` (the server's own terminal-error flag) says so.
      final int failed = scoringEvs
          .where(
            (Attempt e) =>
                LlmState.scoringFailed.contains(e.subjectiveState) ||
                e.hasScoringError(asm),
          )
          .length;
      // NOT ON A CANCELLED ASSESSMENT. `!isDraft` admits `cancelled` as well as
      // in-progress and done, and this button spends LLM calls - paid
      // re-grading on a paper somebody has explicitly called off. `done` is
      // deliberately still allowed: re-scoring a finished assessment to clear a
      // grader error is legitimate.
      if (failed > 0 && asm.state != AsmState.cancelled) {
        out.add(
          Btn.danger(
            'Score Failed Candidates ($failed)',
            tooltip:
                'Requeue every failed or errored answer for these candidates. '
                'One LLM call per answer.',
            onPressed: stopping
                ? null
                : () => s.requeueFailedFor(assessmentId: asm.id),
          ),
        );
      }

      // Kill Scoring Process: shown ONLY while grading is genuinely under way -
      // the server has been ASKED to grade this candidate (`scoring_requested`,
      // the flag its cron selects on) or a worker is mid-call (`scoring`).
      //
      // It used to also fire on `asm.awaitingScoringCount > 0`, and that was
      // the reported bug. That count means "answers still NEED grading", not
      // "grading is running" - so with automatic grading off, where nothing is
      // ever queued, it stayed positive forever and offered a kill for a run
      // that did not exist. A kill over an idle queue is a button that cannot
      // do anything but alarm.
      //
      // THE SECOND REPORT, AND THE SAME FAULT ONE LAYER DOWN. The client-side
      // `any(...)` below walks `scoringEvs`, which is `store.attempts` - a
      // console-wide walk capped at 25 pages x 200 rows across EVERY
      // assessment. Production is past that window, so on a large cohort
      // whether this button appeared came down to how much of the roster had
      // happened to load: absent over a run that was plainly going, present
      // over one that had finished. `scoring_phase` is the server's own answer,
      // derived from the predicate its cron selects on, and it is true at any
      // cohort size.
      //
      // THE FALLBACK IS NOT OPTIONAL, and null is NOT idle. A deployment that
      // predates the field sends nothing, and reading nothing as "there is
      // nothing to stop" would take the Kill button away from every server this
      // has not reached yet. Only null goes back to the cache.
      // [ScoringPhase.isStoppable], NOT `isBusy`, and the two stopped agreeing
      // when `stalled` arrived. A stalled run is not busy - nothing is going to
      // change on its own - but it is the phase with the largest queue behind
      // it and the only one an operator can do anything about from here:
      // parking that queue is the act. Gating on `isBusy` would have hidden the
      // button precisely during the outage it exists for.
      final ScoringPhase? phase = asm.scoringPhase;
      final bool grading = phase != null
          ? phase.isStoppable
          : scoringEvs.any(
              (Attempt e) =>
                  e.scoringRequested || e.subjectiveState == LlmState.scoring,
            );
      if (grading) {
        out.add(
          Btn.dangerOutline(
            'Kill Scoring Process',
            tooltip:
                'Stop grading this assessment. Scores already stored are '
                'kept; the LLM call in flight still completes and is billed. '
                'You confirm before anything happens.',
            onPressed: () => _showKillScoringSheet(context, s, asm),
          ),
        );
      }
    }
    if (asm.state == AsmState.inProgress && canLifecycle) {
      out.add(
        Btn(
          'Resend Invitations',
          tooltip:
              'Send the invitation email again to every candidate whose '
              'invite failed or never arrived. It does not re-issue their '
              'exam link - the existing one keeps working.',
          onPressed: () => s.resendInvites(asm),
        ),
      );
      // CONFIRM WHEN SOMEONE IS MID-EXAM. Marking an assessment done puts every
      // in-progress sitting behind the "This assessment is closed" gate
      // immediately - the candidate's screen is replaced under their fingers.
      // With nobody sitting it, it is an ordinary tidy-up and asking would be
      // noise, so the confirmation is conditional on there being someone.
      //
      // AND THE SERVER ANSWERS THAT QUESTION, never the console's attempt
      // cache - see [_liveSittingCount]. This is the same fault the Kill
      // Scoring button above was moved off, one action later and with no way
      // back: a cache that reads zero skips the confirmation entirely, and an
      // irreversible close-out then fires with no warning at all, which is
      // worse than never having promised one.
      out.add(
        Btn(
          'Mark Done',
          // SAYS WHAT THE SERVER DOES, and the same thing the confirmation
          // below says. It used to promise that "attempts already in flight
          // keep their remaining time", which is the opposite: `action_done`
          // writes `state = "done"` and touches no per-candidate clock, and
          // `exam_begin` / `exam_answer` both refuse with `assessment_closed`
          // on `state != "in_progress"`, so the sitting is over on the
          // candidate's very next call. Nothing reopens it either -
          // `action_cancel` refuses a done paper and `action_reset_draft`
          // accepts only a cancelled one - and this is the sentence an operator
          // reads BEFORE deciding to press, so it is the one that has to be
          // true.
          tooltip:
              'Close the assessment. No further attempt can be started, and '
              'anyone mid-sitting is shown the closed screen on their next '
              'action. Cannot be undone.',
          onPressed: () async {
            final int live = await _liveSittingCount(s, asm.id);
            if (!context.mounted) return;
            if (live == 0) {
              s.markDone(asm);
              return;
            }
            showSheet<void>(
              context,
              title: 'Close this assessment?',
              sub: '$live candidate(s) are sitting it right now.',
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Notice(
                    tone: Tone.bad,
                    strong: 'Their exam ends immediately.',
                    text:
                        'Anyone mid-sitting is shown "This assessment is '
                        'closed" on their next action, and whatever they have '
                        'not answered stays unanswered.',
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      const Spacer(),
                      Btn(
                        'Leave It Open',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 8),
                      Btn.danger(
                        'Close It Anyway',
                        // SAYS THE SAME THING AS THE NOTICE ABOVE IT, on
                        // purpose. The notice explains the situation; this
                        // explains the button, and the two must not drift -
                        // both are descriptions of one server behaviour.
                        // `action_done` writes `state = "done"`, and
                        // `exam_state` answers the closed gate on
                        // `state != "in_progress"`, so anyone mid-question is
                        // closed out on their very next call. "Cannot be
                        // undone" is exact: `action_cancel` refuses a done
                        // paper and `action_reset_draft` accepts only a
                        // cancelled one, so there is no route back from here.
                        tooltip:
                            'Closes the assessment now. Anyone mid-sitting is '
                            'shown the closed screen on their next action and '
                            'whatever they have not answered stays '
                            'unanswered. Cannot be undone.',
                        onPressed: () {
                          Navigator.of(context).pop();
                          s.markDone(asm);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      );
    }
    if (asm.state == AsmState.cancelled && canLifecycle) {
      out.add(
        Btn(
          'Reset to Draft',
          tooltip:
              'Return this cancelled assessment to draft so its questions '
              'and roster can be edited, and it can be launched again.',
          onPressed: () => _resetToDraft(context, s, asm),
        ),
      );
    }
    // NOT OFFERED ON A FINISHED PAPER. `action_cancel` refuses `done` as well
    // as `cancelled` (models/assessment.py), so a Cancel on a Done paper only
    // earned a refusal reading "...or already cancelled" - and the operator
    // concluded it HAD been cancelled.
    if (asm.state != AsmState.cancelled &&
        asm.state != AsmState.done &&
        canLifecycle) {
      out.add(Btn.danger('Cancel', onPressed: () => _cancel(context, s, asm)));
    }
    // The module's own exports, which the client cannot rebuild: the response
    // sheet carries per-answer scoring, judge feedback and rubric columns that
    // never reach this app. Responses is only offered once there is something
    // to export.
    if (!asm.state.isDraft) {
      // Fetched in pages of candidates; the label counts them so a large
      // cohort visibly moves instead of looking stuck.
      final ({int done, int total})? ep = s.exportProgress;
      out.add(
        Btn(
          ep == null
              ? 'Export Responses'
              : ep.total == 0
              ? 'Exporting...'
              : 'Exporting ${ep.done} of ${ep.total}',
          busy: ep != null,
          tooltip:
              'Download every answer on this assessment, one row each, with '
              'its scoring. Large cohorts are fetched in parts and joined '
              'into one file.',
          icon: Icons.table_view_outlined,
          onPressed: asm.submittedCount == 0 || ep != null
              ? null
              : () => s.exportResponses(asm),
        ),
      );
    }
    // The roster's job as well, so offered in EVERY state, draft included: one
    // row per assigned candidate, people who have not started too. Enabled as
    // soon as anyone is assigned. The server's count when the detail carried
    // it, else the cache (see the Candidates tab).
    final bool resultsBusy = s.isBusy('exportResults:${asm.id}');
    out.add(
      Btn(
        resultsBusy ? 'Exporting...' : 'Export Results',
        busy: resultsBusy,
        tooltip:
            'Download one row per assigned candidate with invite, attempt '
            'state, answered, marks, verdict, release and time taken.',
        icon: Icons.emoji_events_outlined,
        onPressed:
            (asm.assignedCount >= 0
                        ? asm.assignedCount
                        : s.attemptsFor(asm.id).length) ==
                    0 ||
                resultsBusy
            ? null
            : () => s.exportResults(asm),
      ),
    );
    // LAST, and available in every state - including a sitting in progress.
    //
    // Archiving is not cancelling and not "Mark done": it moves nothing in the
    // lifecycle and ends nobody's exam. It takes the row out of the default
    // list and out of every dashboard figure, SUSPENDS the work queued against
    // it - the scoring lane, the invitation mailer, the expiry sweep all skip
    // an archived paper - and leaves the state, the sitting window and every
    // recorded result exactly where they were. Nothing is saved off to one
    // side because nothing needs to be: the untouched rows ARE the saved
    // state, and Restore resumes from them.
    //
    // That is why it needs no confirmation while "Mark done" above does - with
    // ONE exception, handled in `_archive`: a paper people are sitting right
    // now. Suspending under a live cohort is almost always a mistake, and the
    // route refuses it without an explicit yes.
    //
    // Gated on `lifecycle` rather than a capability of its own: deciding an
    // assessment is finished with is the same authority as closing it.
    if (canLifecycle) {
      out.add(
        Btn(
          asm.active ? 'Archive' : 'Restore',
          tooltip: asm.active
              ? 'Hide it and pause its queued work. Reversible.'
              : 'Show it again and resume its paused work.',
          busy: s.isBusy('archive:${asm.id}'),
          onPressed: s.isLive ? () => _archive(context, s, asm) : null,
        ),
      );
      // DELETE SITS BESIDE ARCHIVE because they are the same decision at two
      // depths, and an operator who reaches for the destructive one should be
      // looking straight at the reversible one. Same capability for the same
      // reason: this is "I am finished with this paper", taken further.
      //
      // HIDDEN - see [showAssessmentDelete]. Archive stays.
      if (showAssessmentDelete) {
        out.add(
          Btn.danger(
            'Delete',
            tooltip: 'Archives first, then destroys. Cannot be undone.',
            busy: s.isBusy('delete:${asm.id}'),
            onPressed: s.isLive ? () => _delete(context, s, asm) : null,
          ),
        );
      }
    }
    return out;
  }

  /// Cancel, asking first on a LIVE paper. One click used to cancel an
  /// in-progress assessment outright and lock out the candidate sitting it.
  /// A draft has nobody sitting it and Reset to Draft brings it back, so it
  /// does not ask.
  Future<void> _cancel(BuildContext context, AppStore s, Assessment asm) async {
    if (asm.state == AsmState.inProgress) {
      final bool? go = await showSheet<bool>(
        context,
        title: 'Cancel this assessment?',
        sub: 'It is live right now.',
        body: const Notice(
          tone: Tone.bad,
          strong: 'Candidates still sitting it are locked out.',
          text:
              'Their exam ends where it stands, nobody else can start, and no '
              'further grading runs on this paper.',
        ),
        actions: <Widget>[
          Btn(
            'Keep It Running',
            tooltip: 'Change nothing. The assessment stays live.',
            onPressed: () => Navigator.of(context).pop(false),
          ),
          Btn.danger(
            'Cancel Assessment',
            tooltip:
                'Cancel now. Anyone mid-sitting is locked out and no further '
                'grading runs.',
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      );
      if (go != true) return;
    }
    await s.cancel(asm);
  }

  /// Reset to draft. It deletes every attempt and answer, so it asks first
  /// whenever the paper has any - it used to ask only when results had been
  /// released, and one click erased submitted-but-unreleased work. When the
  /// server then says RELEASED results would go too, its own sentence is put
  /// to the admin and the reset retried only on a yes.
  Future<void> _resetToDraft(
    BuildContext context,
    AppStore s,
    Assessment asm,
  ) async {
    // The server's count when the detail carried it; see the Candidates tab.
    final int n = asm.assignedCount >= 0
        ? asm.assignedCount
        : s.attemptsFor(asm.id).length;
    if (n > 0) {
      final bool? go = await showSheet<bool>(
        context,
        title: 'Reset to Draft?',
        sub: 'The question selection and schedule are cleared too.',
        body: Notice(
          tone: Tone.bad,
          strong: n == 1
              ? 'Deletes 1 attempt and its answers.'
              : 'Deletes $n attempts and their answers.',
          text: 'The candidate list is kept. This cannot be undone.',
        ),
        actions: <Widget>[
          Btn(
            'Keep It Cancelled',
            tooltip: 'Change nothing. The assessment stays cancelled.',
            onPressed: () => Navigator.of(context).pop(false),
          ),
          Btn.danger(
            'Delete and Reset',
            tooltip:
                'Delete every attempt and answer and return this assessment '
                'to draft.',
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      );
      if (go != true || !context.mounted) return;
    }
    final String? released = await s.resetToDraft(asm);
    if (released == null || !context.mounted) return;
    final bool? go = await showSheet<bool>(
      context,
      title: 'Erase released results?',
      sub: 'Candidates have already been shown these results.',
      body: Notice(
        tone: Tone.bad,
        strong: 'This cannot be undone.',
        text: '$released The candidate list is kept.',
      ),
      actions: <Widget>[
        Btn(
          'Keep Results',
          tooltip: 'Change nothing. The assessment stays cancelled.',
          onPressed: () => Navigator.of(context).pop(false),
        ),
        Btn.danger(
          'Erase and Reset',
          tooltip:
              'Permanently erase the released results and return this '
              'assessment to draft.',
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (go != true) return;
    await s.resetToDraft(asm, confirmReleased: true);
  }

  /// Archive or restore, asking first when people are mid-sitting.
  ///
  /// THE COUNT IS READ LOCALLY AND THE ROUTE STILL DECIDES. This roster is
  /// already loaded, so asking first costs no round trip and - more to the
  /// point - a cancelled dialog sends nothing at all, which is what an
  /// operator who pressed the wrong button expects. The server refuses the
  /// same case on its own if this screen's roster is stale; the confirmation
  /// key only ever travels when somebody read the sheet and said yes.
  Future<void> _archive(
    BuildContext context,
    AppStore s,
    Assessment asm,
  ) async {
    // Restoring is never destructive and never asks.
    if (!asm.active) {
      await s.archiveAssessment(asm.id, archive: false);
      return;
    }
    final int live = s
        .attemptsFor(asm.id)
        .where((Attempt a) => a.state == AttemptState.inProgress)
        .length;
    if (live > 0 && !await confirmArchiveLiveSitting(context, live)) {
      return;
    }
    final int refused = await s.archiveAssessment(
      asm.id,
      confirmLiveAttempts: live > 0,
    );
    // THE SERVER COUNTED SOMEBODY THIS SCREEN DID NOT. The roster here is one
    // page of a cohort and can be minutes old, so "nobody is sitting it" is a
    // belief and not a fact - and a refusal an operator cannot answer is a
    // button that simply stops working. Ask again with the number the route
    // actually refused over.
    if (refused == 0) return;
    if (!context.mounted) return;
    if (!await confirmArchiveLiveSitting(context, refused)) return;
    await s.archiveAssessment(asm.id, confirmLiveAttempts: true);
  }

  /// The delete, which is two confirmations around the route's own two calls.
  ///
  ///   press Delete          -> a sheet that says what deleting does. Nothing
  ///                            is sent.
  ///   press Delete Permanently -> the route ARCHIVES the paper and answers with
  ///                            what destroying it would cost. Still nothing
  ///                            is destroyed, and backing out here leaves a
  ///                            suspended assessment that Restore brings back.
  ///   press Delete Forever  -> the only call that destroys anything.
  ///
  /// The archive-first order is the route's, and it is what makes an
  /// interrupted delete - a dropped connection, a closed tab, an operator who
  /// reads the numbers and changes their mind - leave a paper that is merely
  /// paused rather than half-destroyed.
  ///
  /// Live sittings are asked about SEPARATELY and first, because the archive
  /// is the step that stops their clock. It is the same question the Archive
  /// button asks, so it is the same sheet.
  Future<void> _delete(BuildContext context, AppStore s, Assessment asm) async {
    if (!await _confirmDeleteIntent(context, asm)) return;

    AssessmentDeletePlan? plan = await s.planAssessmentDelete(asm.id);
    if (plan != null && plan.needsLiveConfirm) {
      if (!context.mounted) return;
      final bool go = await confirmArchiveLiveSitting(
        context,
        plan.liveAttemptCount,
      );
      if (!go) return;
      plan = await s.planAssessmentDelete(asm.id, confirmLiveAttempts: true);
    }
    // Null is a refusal that has already been reported, and a plan that STILL
    // wants the live confirmation means the second call was refused too -
    // either way nothing was archived and there is nothing to confirm.
    if (plan == null || plan.needsLiveConfirm) return;
    if (!context.mounted) return;
    _showDestroySheet(context, s, asm, plan);
  }

  /// Step one, and it sends NOTHING.
  ///
  /// The point of asking before the first call is that the first call has an
  /// effect: it archives. That is reversible and it is the safer half of this
  /// action, but nobody should discover it by pressing a button labelled
  /// Delete - so the sheet says so, and offers the archive on its own as the
  /// thing most people who reach for Delete actually want.
  Future<bool> _confirmDeleteIntent(
    BuildContext context,
    Assessment asm,
  ) async {
    final bool? go = await showSheet<bool>(
      context,
      title: 'Delete ${asm.name}?',
      sub: 'This archives it first. Nothing is destroyed yet.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Notice(
            tone: Tone.warn,
            strong: 'Deleting cannot be undone.',
            text: 'To only hide it, use Archive.',
          ),
        ],
      ),
      actions: <Widget>[
        Btn(
          'Cancel',
          size: BtnSize.lg,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        // NOT THE DESTROY. It archives and asks the server what the damage
        // would be; the affirmative in THAT sheet is the only thing that
        // deletes.
        Btn.danger(
          'Delete Permanently',
          tooltip: 'Archives it and shows what would be destroyed.',
          size: BtnSize.lg,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    return go == true;
  }

  /// Step two of two: what is destroyed, what survives, and only then the call.
  ///
  /// SEPARATES LOST FROM KEPT for the reason the erase sheet on an attempt
  /// does: the fear the action provokes is losing the spend record along with
  /// the paper, and the spend record is exactly what survives. The LLM ledger
  /// keeps its rows against a null evaluator, so the money already spent on
  /// this assessment still counts against the daily cap - a delete that
  /// quietly refunded the budget would be a way to spend it twice.
  ///
  /// EVERY NUMBER HERE IS THE SERVER'S, from the plan the archive step came
  /// back with, and one it did not send is left out rather than printed as a
  /// guess. This is the sentence somebody is being asked to agree to.
  void _showDestroySheet(
    BuildContext context,
    AppStore s,
    Assessment asm,
    AssessmentDeletePlan plan,
  ) {
    showSheet<void>(
      context,
      title: 'Destroy ${asm.name} for good?',
      sub: 'Archived. This cannot be undone.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Panel(
            title: 'Destroyed',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (plan.candidateCount >= 0) ...<Widget>[
                  Text(
                    '•  ${plan.candidateCount} candidate(s)',
                    style: context.type.body,
                  ),
                  const SizedBox(height: 5),
                ],
                if (plan.responseCount >= 0) ...<Widget>[
                  Text(
                    '•  ${plan.responseCount} recorded response(s)',
                    style: context.type.body,
                  ),
                  const SizedBox(height: 5),
                ],
                Text('•  Every score and verdict', style: context.type.body),
                const SizedBox(height: 5),
                Text('•  The assessment itself', style: context.type.body),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Panel(
            title: 'Kept',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  plan.ledgerRowsKept >= 0
                      ? '•  LLM spend (${plan.ledgerRowsKept} row(s)) '
                            'stays on the budget'
                      : '•  The LLM budget contribution - the spend '
                            'already recorded against this assessment stays '
                            'in the budget and still counts against the daily '
                            'cap',
                  style: context.type.body,
                ),
                const SizedBox(height: 5),
                Text(
                  '•  The questions themselves, which live in the bank',
                  style: context.type.body,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Notice(
            tone: Tone.bad,
            strong: 'There is no undo.',
            text:
                'Stopping here leaves the assessment archived, which reverses '
                'cleanly - Restore puts it and its results back.',
          ),
        ],
      ),
      actions: <Widget>[
        Btn(
          'Keep It Archived',
          tooltip:
              'Stop here. The assessment stays archived - out of the list and '
              'suspended - and Restore brings it and its results back.',
          size: BtnSize.lg,
          onPressed: () => Navigator.of(context).pop(),
        ),
        Btn.danger(
          'Delete Forever',
          tooltip:
              'Destroy the assessment, its roster and every response and '
              'score on it. This cannot be undone. The LLM spend already '
              'recorded against it stays on the budget.',
          size: BtnSize.lg,
          onPressed: () async {
            final NavigatorState nav = Navigator.of(context);
            final AssessmentNav route = context.nav;
            nav.pop();
            // LEAVE THE SCREEN ONLY IF IT WORKED. The record is gone, so this
            // screen would otherwise sit on "Assessment not found" - and on a
            // REFUSED delete, walking away would contradict the toast that
            // just said why it did not happen.
            if (await s.destroyAssessment(asm.id)) route.assessments();
          },
        ),
      ],
    );
  }

  /// The launch sheet. All seven gates are evaluated and shown TOGETHER, and
  /// the action stays disabled while any one fails - reporting the first
  /// failure and stopping would turn fixing a record into a guessing game.
  void _showLaunchSheet(BuildContext context, AppStore s, Assessment asm) {
    final List<GateResult> gates = s.launchGates(asm);
    final bool ok = Gates.allPass(gates);
    final int n = s.attemptsFor(asm.id).length;
    // Started once, here, so a rebuild of the sheet does not re-ask. The
    // client's gates show at once; the server's warnings join the same list
    // when they arrive and never touch `ok`.
    final Future<List<GateResult>> warnings = s.launchWarnings(asm);

    showSheet<void>(
      context,
      title: 'Launch Checks',
      sub: 'Every condition is evaluated together.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FutureBuilder<List<GateResult>>(
            future: warnings,
            builder: (_, AsyncSnapshot<List<GateResult>> w) =>
                CheckList(<GateResult>[...gates, ...?w.data]),
          ),
          if (ok) ...<Widget>[
            const SizedBox(height: 12),
            Notice(
              tone: Tone.ok,
              strong: 'Ready to launch.',
              text:
                  '$n invitation(s) will be queued. Configuration is fixed once '
                  'an assessment is launched.',
            ),
          ],
        ],
      ),
      actions: <Widget>[
        Btn('Cancel', onPressed: () => Navigator.of(context).pop()),
        Btn.primary(
          'Launch & Invite',
          tooltip:
              'Freeze the paper, create an attempt for every assigned '
              'candidate and email each of them their exam link. This is '
              'the point of no return for the question list.',
          onPressed: ok
              ? () {
                  Navigator.of(context).pop();
                  s.launch(asm);
                  _showTab('candidates');
                }
              : null,
        ),
      ],
    );
  }

  /// The release sheet.
  ///
  /// It names the people who are still being graded rather than reporting a
  /// count, because "3 still grading" is not something anybody can act on.
  /// And it states that the action cannot be undone BEFORE the button that
  /// does it.
  void _showReleaseSheet(BuildContext context, AppStore s, Assessment asm) {
    final List<Attempt> targets = s.toRelease(asm);
    final List<Attempt> grading = s.stillGrading(asm);
    // Of those going out now, how many are still with the grader: they see
    // "pending" until it finishes, so the button says so.
    final int gradingNow = targets
        .where((Attempt e) => e.awaitingGrader(asm))
        .length;
    final int submitted = s
        .attemptsFor(asm.id)
        .where((Attempt e) => e.isDone)
        .length;

    showSheet<void>(
      context,
      title: 'Release Results',
      sub: 'Candidates see their marks the moment you do this.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          KpiStrip(<Widget>[
            Kpi(label: 'Submitted', value: '$submitted'),
            Kpi(label: 'Releasing now', value: '${targets.length}'),
            Kpi(label: 'Still grading', value: '${grading.length}'),
          ]),
          if (grading.isNotEmpty) ...<Widget>[
            Notice(
              tone: Tone.warn,
              strong: '${grading.length} attempt(s) are still being graded.',
              text: 'Releasing now shows them a result that is still pending.',
            ),
            const SizedBox(height: 10),
            for (final Attempt e in grading)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        s.personById(e.employeeId)?.name ?? e.employeeId,
                        style: context.type.body,
                      ),
                    ),
                    Text(
                      // The server's count on a roster row, which has no
                      // answers to walk.
                      '${math.max(e.subjectivePending, e.unresolvedQuestionIds(asm).length)}'
                      ' unresolved'
                      '${e.hasScoringError(asm) ? '  (scoring error)' : ''}',
                      style: context.type.small,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
          ],
          // Which review they get, from the Configuration switch.
          Text(
            asm.resultsShowAnswers
                ? 'Candidates will see the correct answers and feedback.'
                : 'Candidates will see their own answers and marks only - the '
                      'correct answers and feedback stay hidden.',
            style: context.type.body,
          ),
          const SizedBox(height: 10),
          const Notice(
            tone: Tone.bad,
            strong: 'This cannot be undone.',
            text:
                'There is no un-release. Once a candidate has seen a mark, you '
                'cannot take it back.',
          ),
        ],
      ),
      actions: <Widget>[
        Btn('Cancel', onPressed: () => Navigator.of(context).pop()),
        if (grading.isNotEmpty)
          Btn(
            'Wait for Scoring',
            tooltip:
                'Disabled until every answer is resolved. Releasing now would '
                'show a candidate a mark the grader has not finished, and '
                'invariant 4 holds the result at pending whatever the score.',
            onPressed: () {
              Navigator.of(context).pop();
              s.toaster.info('Left unreleased - nothing was written');
            },
          ),
        Btn.primary(
          gradingNow > 0
              ? 'Release ${targets.length} ($gradingNow still being graded)'
              : 'Release ${targets.length} result(s)',
          tooltip:
              'Show these candidates their own results. Until you do they '
              'see only that the attempt was submitted. This is the only '
              'path that reveals a mark, and it cannot be undone.',
          onPressed: targets.isEmpty
              ? null
              : () {
                  Navigator.of(context).pop();
                  s.releaseResults(asm);
                },
        ),
      ],
    );
  }

  /// Stop this assessment's subjective scoring, behind a confirmation.
  ///
  /// Worded like the generator's "Stop generating questions?" and for the same
  /// reason: a kill is not free and not fully reversible, so the sheet has to
  /// say precisely what survives it. TWO facts the operator must read before
  /// pressing it - scores already stored are kept, and the one LLM call
  /// already in flight still completes and is billed - because a kill that
  /// silently discarded either would be a nasty surprise on the ledger or the
  /// results.
  void _showKillScoringSheet(BuildContext context, AppStore s, Assessment asm) {
    showSheet<void>(
      context,
      title: 'Stop scoring this assessment?',
      sub: 'This assessment only. Any other assessment keeps grading.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Notice(
            tone: Tone.info,
            strong: 'Scores already stored are kept.',
            text:
                'Every answer graded so far keeps its mark. This settles the '
                'queue behind them; it does not undo a verdict already '
                'written.',
          ),
          const SizedBox(height: 12),
          Text(
            'The run stops at its next model call, so the one already in '
            'flight finishes and is billed. Everything queued after it is '
            'cancelled rather than graded, and each of those answers reads '
            'as Cancelled rather than as an error.',
            style: context.type.body,
          ),
          const SizedBox(height: 12),
          // NAMED BEFORE THE PRESS, not discovered afterwards. A kill clears
          // every queued individual re-score on the assessment as well as the
          // cohort run - the keys alone, so no mark or state moves. The toast
          // counts them afterwards; this sentence lets the choice be made
          // knowing it.
          Text(
            'Individual answers queued with "Re-score" are dropped too. They '
            'keep their current marks, and re-scoring them again is the way '
            'back.',
            style: context.type.body,
          ),
        ],
      ),
      actions: <Widget>[
        Btn(
          'Keep Grading',
          tooltip: 'Leave scoring running. Nothing changes.',
          onPressed: () => Navigator.of(context).pop(),
        ),
        Btn.danger(
          'Kill Scoring Process',
          tooltip:
              'Stop this assessment at its next model call. Scores already '
              'stored are kept; the call in flight still completes and is '
              'billed.',
          onPressed: () {
            Navigator.of(context).pop();
            s.killScoring(asm.id);
          },
        ),
      ],
    );
  }
}

/// Configuration, with THREE different locks on it, not one.
///
/// [_ro] is the capability gate alone - no state in it - and it decides
/// whether this surface can be edited at all. The other two add state on top
/// of it, and they differ from each other because THE SERVER DIFFERS: the
/// update route's `POST_DRAFT_FIELDS` accepts `llm_auto_score` after launch
/// and refuses the two draw settings (a changed `question_limit` as
/// `locked_after_launch`). The client mirrors that rather than inventing a
/// rule of its own.
///
/// * [_drawRo] gates "Shuffle Questions" and the "Questions" count: `_ro`
///   plus `!state.isDraft`. The draw happens at launch, so these two describe
///   the paper the candidate already agreed to.
/// * [_scoreRo] gates "Grade subjective answers automatically": `_ro` plus
///   done-or-cancelled only, matching the Odoo form's
///   `readonly="state in ('done','cancelled')"`. It is DELIBERATELY editable
///   while the assessment runs - turning it on is how an operator restarts a
///   grading queue that has starved, and freezing it at launch would take that
///   lever away exactly when somebody needs it.
/// * Everything else on the tab reads `_ro` alone and stays editable to the
///   end; the server accepts those fields post-draft.
///
/// THIS SPLIT IS A FIX, not a tightened rule. `_ro` alone has no state in it,
/// so a draw setting moved on a running assessment would flip on screen and
/// come back refused. `_apply_shuffle_alias` folds `shuffle_questions` into
/// `preserve_question_order` before the draft gate runs, so that one is
/// refused under its stored name.
///
/// What is locked is READ-ONLY rather than hidden: the settings are what the
/// candidate agreed to, so they stay legible forever.
class _ConfigTab extends StatelessWidget {
  final AppStore store;
  final Assessment asm;
  final Portal portal;

  const _ConfigTab({
    required this.store,
    required this.asm,
    required this.portal,
  });

  // THE BASE GATE: capability only, no state in it. Most of this tab is NOT
  // locked on launch (product decision, 2026-08-18) - the operator may correct
  // configuration, a missing time limit or a threshold, on a running
  // assessment, and the route's post-draft allow-list accepts those. The two
  // gates below add state on top of this one for the three fields where the
  // server does not.
  bool get _ro => !store.can(Capability.configure);

  // THE QUESTION DRAW HAPPENS AT LAUNCH, so these two describe the paper the
  // candidate agreed to and cannot move afterwards. The update route says the
  // same: `shuffle_questions` is folded into `preserve_question_order` BEFORE
  // the draft gate runs, so it is refused under that name, and a CHANGED
  // `question_limit` on a launched assessment is refused as
  // `locked_after_launch` (the unchanged value passes). Offering either on a
  // running assessment moved a control on screen and came back refused.
  bool get _drawRo => _ro || !asm.state.isDraft;

  // EDITABLE PAST LAUNCH, unlike its two neighbours above. Turning automatic
  // grading on is how an operator restarts a queue that has starved, and
  // freezing it at launch removes the only lever they have. The Odoo form
  // carries `readonly="state in ('done','cancelled')"` for this one field
  // while the draw settings carry `readonly="state != 'draft'"`, and
  // `llm_auto_score` is in the route's POST_DRAFT_FIELDS - so draft, running
  // and everything before Done accepts the write.
  bool get _scoreRo =>
      _ro || asm.state == AsmState.done || asm.state == AsmState.cancelled;

  @override
  Widget build(BuildContext context) {
    // What launch draws: `question_limit or len(available_questions)`. One
    // value for the stepper and its locked form, so launching does not change
    // the number on screen.
    final int questionCount = asm.questionLimit > 0
        ? asm.questionLimit
        : asm.effectiveQuestionCount;
    final List<ProctorRule> switches = asm.rules.switches;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_ro) ...<Widget>[
          const Notice(
            tone: Tone.inert,
            strong: 'Read-only.',
            text: 'Configuration is an authoring capability.',
          ),
          const SizedBox(height: 16),
        ],
        FieldGrid(<Widget>[
          Field.readonly('Name', asm.name),
          // An empty string renders as a blank cell, which reads as a
          // rendering fault rather than as "nothing is set". Its neighbour
          // already says 'Not tagged'; say the equivalent here.
          Field.readonly(
            'Generator',
            asm.generatorName.isEmpty ? 'Not set' : asm.generatorName,
          ),
          Field.readonly('Project', asm.projectId ?? 'Not tagged'),
          _ro
              ? Field.readonly('Duration', '${asm.durationMinutes} minutes')
              : Field(
                  label: 'Duration (minutes)',
                  help:
                      'At least 2. On a running assessment the new limit '
                      'applies from each candidate\'s start time.',
                  child: NumberField(
                    value: asm.durationMinutes,
                    // See the create screen: the server refuses 0 or 1.
                    min: 2,
                    max: 480,
                    // Every save reloads the console: typing commits on Enter
                    // or leaving the field, never per keystroke ("480" posted
                    // 4, then 48, then 480).
                    commitOnSubmit: true,
                    onChanged: (int v) =>
                        store.updateAsm(asm.copyWith(durationMinutes: v)),
                  ),
                ),
          // LOCKED AT LAUNCH (decided 2026-09-22), behind `_drawRo`. Launch
          // draws ONE shared set and late candidates copy it, so a count
          // changed afterwards reaches nobody - it would only make the screen
          // disagree with the paper. Form Studio publish fills this with the
          // form's question count and the creator may still want a shorter
          // paper, which is why it stays editable on a draft.
          _drawRo
              ? Field.readonly('Questions', '$questionCount')
              : Field(
                  label: 'Questions',
                  help:
                      'How many questions each candidate gets. Launch draws '
                      'this many from the selected pool.',
                  // The CEILING is the shortlist, and it has to be the effective
                  // one: against `totalQuestions` this stepper capped at 99 on
                  // an untouched draft (the `> 0 ? : 99` fallback) and let an
                  // operator ask for more questions than the generator holds,
                  // which `action_start` then refuses at launch.
                  child: NumberField(
                    value: questionCount,
                    min: 1,
                    max: asm.effectiveQuestionCount > 0
                        ? asm.effectiveQuestionCount
                        : 99,
                    commitOnSubmit: true,
                    onChanged: (int v) =>
                        store.updateAsm(asm.copyWith(questionLimit: v)),
                  ),
                ),
          // Editable like the subjective threshold: the server re-decides
          // pass and fail on write, without re-grading.
          Field(
            label: 'Pass threshold (%)',
            help:
                "Cut-off on the candidate's total marks for passing the whole "
                'assessment.',
            // Every save re-decides every candidate: typing commits on Enter
            // or leaving the field, never per keystroke.
            child: NumberField(
              value: asm.passThreshold.round(),
              min: 1,
              max: 100,
              commitOnSubmit: true,
              onChanged: (int v) =>
                  store.updateAsm(asm.copyWith(passThreshold: v.toDouble())),
            ),
          ),
          // EDITABLE even after the assessment is done. Raw scores are stored,
          // so moving this re-decides Pass and Fail with no re-grading: the
          // server recomputes every evaluator's result on write. While this
          // was read-only, a threshold set wrongly could never be corrected
          // once results existed - which is exactly when anybody notices.
          //
          // THE HELP NAMES THE LABELLING BOXES BECAUSE THIS ONE NUMBER IS
          // THREE BARS. A written answer clears it to earn its mark; every box
          // on a labelling question is thresholded against it individually;
          // and the share of boxes that cleared is then thresholded against it
          // AGAIN to decide the box set's single mark. The help used to name
          // the written answer alone, so an operator nudging it to loosen one
          // rubric had no way to know they were re-deciding every labelling
          // question on the paper at the same time.
          //
          // It also stopped saying "its single mark". That read as a claim
          // about the QUESTION, and under the component rule a question is
          // worth one mark per component - a four-axis image A/B with a
          // justification is worth five. The bar this control moves decides
          // ONE COMPONENT at a time, never a whole question, and the copy has
          // to say which.
          Field(
            label: 'Subjective threshold (%)',
            help:
                'The bar every graded component clears to earn its mark: a '
                'written answer, each box on a labelling question, then the '
                'share of those boxes that cleared. Raw scores are stored, so '
                'moving this re-decides pass and fail without re-grading.',
            child: NumberField(
              value: asm.subjectiveThreshold.round(),
              min: 0,
              max: 100,
              commitOnSubmit: true,
              onChanged: (int v) => store.updateAsm(
                asm.copyWith(subjectiveThreshold: v.toDouble()),
              ),
            ),
          ),
          // A transcription clip's own bar (`transcription_threshold`), shown
          // only where the paper can hold one. 0 follows the subjective bar,
          // so a paper nobody touched decides as it always did. The ticked
          // pool too: a draft's `questions` stays empty until launch. Never
          // the whole pool, which after launch still lists unticked rows.
          if (<Question>[
            ...asm.questions,
            ...asm.effectiveQuestions,
          ].any((Question q) => q.type == QType.transcription))
            Field(
              label: 'Transcription threshold (%)',
              help:
                  "A transcription clip's own bar; 0 follows the subjective "
                  'threshold. A clip loses 20 per critical mistake and 5 per '
                  'minor one, and 1 critical or 5 minor fail it whatever the '
                  'bar, so 80 or below adds nothing: 85 allows 3 minor '
                  'mistakes, 90 two, 95 one. Raw scores are stored, so moving '
                  'this re-decides pass and fail without re-grading.',
              child: NumberField(
                value: asm.transcriptionThreshold.round(),
                min: 0,
                max: 100,
                commitOnSubmit: true,
                onChanged: (int v) => store.updateAsm(
                  asm.copyWith(transcriptionThreshold: v.toDouble()),
                ),
              ),
            ),
        ]),
        // The server recomputes inline for a small assessment and defers to a
        // cron for a large one. Saying nothing here means an operator moves
        // the threshold, still sees the OLD pass/fail, and concludes it did
        // not work.
        if (asm.thresholdRecomputePending) ...<Widget>[
          const SizedBox(height: 12),
          const Notice(
            tone: Tone.info,
            strong: 'Results are being re-decided.',
            text:
                'This assessment has too many graded answers to redo on the '
                'spot, so pass and fail are being recomputed in the '
                'background. Nothing needs re-grading.',
          ),
        ],
        // The audit trail lives in the RIGHT-HAND DOCK now, not inline here,
        // so it stays beside the record on every tab. Rendering it in both
        // places would show it twice.
        const SizedBox(height: 20),
        // MIRRORED IN ODOO, WORD FOR WORD. The first two switches below - each
        // `name` and each `hint` - are copied verbatim into the "Scoring"
        // group of assessments_be_v2/views/assessment_views.xml, as the
        // `string=` and `help=` on `shuffle_questions` and `llm_auto_score`,
        // in this order. (No "Same questions for everybody" switch: everybody
        // always gets the same questions, decided 2026-09-22.) THIS FILE
        // IS THE SOURCE OF TRUTH. Reword anything below and change that view
        // in the same commit, or the two consoles describe one system in two
        // vocabularies again and an operator cannot match a setting here to
        // the setting there.
        //
        // `shuffle_questions` is NOT a column on the Odoo side either: it is a
        // computed, non-stored mirror of `preserve_question_order` with an
        // inverse setter - the same flip this client does at the wire.
        const Eyebrow('Scoring'),
        const SizedBox(height: 8),
        // ON BY DEFAULT: everybody gets the SAME questions, so a fixed order
        // lets two people sitting side by side read each other's screens
        // position-for-position. Shuffling per candidate closes that without
        // touching the paper. Read-only once the assessment leaves draft
        // (`_drawRo`, unlike the autograde switch below, which stays editable
        // while running) - the order candidates already agreed to must not
        // change under a sitting.
        SwitchRow(
          name: 'Shuffle Questions',
          hint:
              'Each candidate gets the questions in a random order fixed for '
              'their sitting. The numbers they read still count 1..N in the '
              'order they see.',
          value: asm.shuffleQuestions,
          onChanged: _drawRo
              ? null
              : (bool v) => store.updateAsm(asm.copyWith(shuffleQuestions: v)),
        ),
        // THE SWITCH THAT DECIDES WHETHER GRADING HAPPENS AT ALL.
        //
        // The module defaults it OFF and no screen showed it, so subjective
        // answers were queued by nothing: `evaluator.write()` only sets
        // `scoring_requested` on submit when this is on, and the scoring cron
        // only ever drains evaluators carrying that flag. The result is silent
        // starvation - answers sit `pending` with zero attempts and no error
        // recorded anywhere. One response had been waiting nine days.
        SwitchRow(
          name: 'Grade subjective answers automatically',
          hint:
              'On, a submit queues the candidate for the background grader. '
              'Off, nothing is graded until someone runs it by hand - and '
              'nothing tells you it is waiting.',
          value: asm.llmAutoScore,
          onChanged: _scoreRo
              ? null
              : (bool v) => store.updateAsm(asm.copyWith(llmAutoScore: v)),
        ),
        // IT ONLY BINDS ON THE NEXT SUBMIT. `evaluator.write()` sets
        // `scoring_requested` when a candidate moves to `submitted` and the
        // toggle is on at that moment; nothing re-reads it afterwards, and the
        // cron only ever drains rows already carrying the flag. So switching
        // this on mid-sitting picks up everybody still to submit and NOBODY
        // who already has - which is exactly the cohort the operator was
        // looking at when they reached for it. Say so, or the toggle reads as
        // broken. 'Re-score This Assessment' (`/scoring/queue`) is the button
        // that sweeps the ones already in, and it ignores this flag.
        if (!asm.state.isDraft && asm.llmAutoScore) ...<Widget>[
          const SizedBox(height: 8),
          const Notice(
            tone: Tone.info,
            strong: 'This applies from the next submission onwards.',
            text:
                'Candidates who already submitted are not queued by turning '
                'this on. Re-score the assessment to sweep those in.',
          ),
        ],
        // WHAT A RELEASE SHOWS. Editable in every state, released included:
        // the server reads it when a candidate opens the review, so a change
        // reaches results already out.
        // Only where the server can keep it: see
        // [AppStore.serverKnowsShowAnswers].
        if (store.serverKnowsShowAnswers)
          SwitchRow(
            name: 'Show correct answers and feedback',
            hint:
                "On, released candidates see the correct answers, each answer's "
                "verdict and the grader's feedback. Off, they see their own "
                'answers and marks only. Read when they open the review, so a '
                'change applies at once.',
            value: asm.resultsShowAnswers,
            onChanged: _ro
                ? null
                : (bool v) =>
                      store.updateAsm(asm.copyWith(resultsShowAnswers: v)),
          ),
        // No "Require a reviewed rubric" switch - see Gates.launchGates.
        // Approving a draft signs its marking guide, so the flag this set is
        // true for everything in the bank and the gate could never fail.
        //
        // No "Blend justification into image A/B" switch either. Blending the
        // verdict with the written justification is how image A/B is scored,
        // full stop - it is not a per-assessment choice, and offering it as
        // one meant an operator could put two assessments on two different
        // scoring mechanisms without knowing it.
        const SizedBox(height: 20),
        const Eyebrow('Rules and Proctoring'),
        const SizedBox(height: 8),
        for (final (int i, ProctorRule rule) in switches.indexed)
          SwitchRow(
            name: rule.label,
            hint: rule.hint,
            value: asm.rules[rule],
            last: i == switches.length - 1,
            onChanged: _ro
                ? null
                : (bool v) {
                    // A child switch with its parent off: say why, write
                    // nothing (the server would refuse it anyway).
                    final String? first = v ? asm.rules.needsFirst(rule) : null;
                    if (first != null) return store.toaster.warn(first);
                    store.updateAsm(
                      asm.copyWith(rules: asm.rules.set(rule, v)),
                    );
                  },
          ),
        // What invigilators type to close Safe Exam Browser early. Selectable,
        // so it can be copied into the room's briefing.
        if (asm.rules[ProctorRule.seb] &&
            asm.sebQuitPassword.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          SelectableText(
            'Quit password for invigilators: ${asm.sebQuitPassword}',
            style: context.type.bodySecondary,
          ),
        ],
        const SizedBox(height: 16),
        // THE VIOLATION POLICY, which the New assessment form has always
        // offered and this screen only ever described. The pair was set once
        // at creation and then frozen out of reach, so the setting operators
        // most often want back - "stop auto-submitting these people" on a
        // running assessment - could be read here and changed nowhere. Both
        // fields are in the update route's post-draft allow-list, so the
        // server has always accepted them.
        //
        // RAW cap, not `maxViolations > 0 ? maxViolations : 1`: 0 is a value
        // an operator can land on, and the normalised form fed 1 into
        // `violationConsequence`, whose "no cap" branch then never ran.
        ViolationPolicy(
          action: asm.violationAction,
          cap: asm.maxViolations,
          onAction: _ro
              ? null
              : (ViolationAction v) =>
                    store.updateAsm(asm.copyWith(violationAction: v)),
          onCap: (int v) => store.updateAsm(asm.copyWith(maxViolations: v)),
        ),
        // AI proctoring violations count apart, against their own pair.
        if (asm.rules[ProctorRule.aiProctor]) ...<Widget>[
          const SizedBox(height: 16),
          ViolationPolicy(
            ai: true,
            action: asm.aiViolationAction,
            cap: asm.aiMaxViolations,
            onAction: _ro
                ? null
                : (ViolationAction v) =>
                      store.updateAsm(asm.copyWith(aiViolationAction: v)),
            onCap: (int v) => store.updateAsm(asm.copyWith(aiMaxViolations: v)),
          ),
        ],
      ],
    );
  }
}

/// Assign candidates. Draft-only, because the roster is frozen at launch.
class _AssignTab extends StatefulWidget {
  final AppStore store;
  final Assessment asm;
  final String search;
  final ValueChanged<String> onSearch;

  const _AssignTab({
    required this.store,
    required this.asm,
    required this.search,
    required this.onSearch,
  });

  @override
  State<_AssignTab> createState() => _AssignTabState();
}

class _AssignTabState extends State<_AssignTab> {
  static const int _pageSizeDefault = 10;

  /// How many assigned chips are drawn before the strip offers to expand.
  static const int _kChipCap = 24;

  bool _showAllChips = false;
  int _page = 1;
  int _pageSize = _pageSizeDefault;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(_AssignTab old) {
    super.didUpdateWidget(old);
    if (old.search != widget.search) {
      // DEBOUNCED, because this now costs a request. `SearchField` fires on
      // every keystroke and the previous list was filtered in memory, so a
      // straight port would have put one round trip per character on the wire
      // and let a slow early response paint over a later one.
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 250), () {
        setState(() => _page = 1);
        _fetch();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _fetch() {
    widget.store.loadPickerUsers(
      search: widget.search,
      offset: (_page - 1) * _pageSize,
      limit: _pageSize,
    );
  }

  void _goto(int page) {
    setState(() => _page = page);
    _fetch();
  }

  /// The roster entry for a directory user, matched on the address.
  ///
  /// The picker's rows are `res.users` and the roster's are `hr.applicant`, so
  /// their ids are not comparable. The address is what links them - it is the
  /// same key the exam gate resolves identity on.
  Person? _rosterEntryFor(Person user) {
    final String email = user.email.trim().toLowerCase();
    if (email.isEmpty) return null;
    for (final Person p in widget.asm.roster) {
      if (p.email.trim().toLowerCase() == email) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final AppStore store = widget.store;
    final Assessment asm = widget.asm;
    final List<Attempt> assigned = store.attemptsFor(asm.id);

    // The assigned strip is a Wrap of one chip per person, and a full cohort
    // runs to a couple of hundred. Unbounded, that is a wall of chips the
    // operator has to scroll past to reach the search box on every visit. The
    // grid below is the place to work through a roster that size; this strip
    // is a reminder of who is already on it.
    final List<Person> rosterOnly = <Person>[
      for (final Person p in asm.roster)
        if (!assigned.any((Attempt a) => a.employeeId == p.id)) p,
    ];
    final int assignedTotal = assigned.length + rosterOnly.length;
    final int chipBudget = _showAllChips ? assignedTotal : _kChipCap;
    final List<Attempt> chipAttempts = assigned.take(chipBudget).toList();
    final List<Person> chipRoster = rosterOnly
        .take(chipBudget - chipAttempts.length)
        .toList();
    final int hiddenChips =
        assignedTotal - chipAttempts.length - chipRoster.length;

    final int total = store.pickerTotal;
    final int pageCount = total == 0 ? 1 : ((total - 1) ~/ _pageSize) + 1;
    final int page = _page.clamp(1, pageCount);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: <Widget>[
            for (final Attempt a in chipAttempts)
              _AssignedChip(
                name: store.personById(a.employeeId)?.name ?? a.employeeId,
                // The CHIP stays for a read-only Manager, only the X goes.
                // Who is assigned is roster information, and reading it is the
                // whole point of this strip; `toggleAssign` is an Admin-only
                // route, so for them the X answered 403 and the chip sat there
                // as though the click had been swallowed. Null is already the
                // no-affordance case here - see [_AssignedChip].
                onRemove: store.can(Capability.launch)
                    ? () => store.toggleAssign(asm, a.employeeId)
                    : null,
              ),
            // Invited but not yet launched. These have no attempt record, so
            // they appear in the roster and nowhere else - without this an
            // invitation to a draft is stored and then displayed nowhere, and
            // looks like it failed.
            for (final Person p in chipRoster)
              _AssignedChip(
                name: p.name,
                // REMOVABLE. This chip was the only record of somebody
                // invited to a draft and it carried no way to undo the
                // invitation, so a typo in an email address was permanent
                // for the life of the assessment. Removable BY SOMEBODY WHO
                // MAY ASSIGN: a read-only Manager still needs to see who was
                // invited, but the undo runs the same Admin-only route, so
                // they get the chip without the X instead of a 403.
                onRemove: store.can(Capability.launch)
                    ? () => store.toggleAssign(asm, p.id)
                    : null,
              ),
            if (hiddenChips > 0)
              Btn(
                'Show all $assignedTotal',
                size: BtnSize.sm,
                tooltip: '$hiddenChips more are assigned',
                onPressed: () => setState(() => _showAllChips = true),
              ),
            if (assignedTotal == 0)
              Text('Nobody is assigned yet.', style: context.type.bodyMuted),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            SearchField(
              value: widget.search,
              hint: 'Search people',
              onChanged: widget.onSearch,
            ),
            const Spacer(),
            // Everything that WRITES to the roster, gated as one group. Invite,
            // import and the importer's template all serve assigning, which is
            // Admin-only server-side, so a read-only Manager was handed three
            // buttons that end in 403 - and a template whose only use is an
            // import they cannot run. The search box and the grid below stay,
            // because reading who is on the roster is exactly what a Manager is
            // here for. Gated as a group rather than one at a time so the
            // spacers leave with the buttons they separate; individually gated,
            // an empty toolbar would still hold 14px of dead gap after the
            // search field.
            if (store.can(Capability.launch)) ...<Widget>[
              Btn(
                'Invite by Email',
                tooltip:
                    'For somebody with no account yet. Anyone who has one is '
                    'in the list below.',
                size: BtnSize.sm,
                onPressed: () => _showInviteSheet(context, store, asm),
              ),
              const SizedBox(width: 7),
              Btn(
                'Import from CSV',
                tooltip:
                    'Add candidates to the roster from a file. It assigns '
                    'them - nothing is emailed until the assessment is '
                    'launched.',
                size: BtnSize.sm,
                onPressed: () => _showRosterSheet(context),
              ),
              const SizedBox(width: 7),
              // The importer's own column headers, from the module. Offered
              // beside Import because "what columns does it want?" is the first
              // question anybody importing a roster has, and guessing wrong
              // costs a failed import.
              Btn(
                'Download Template',
                tooltip:
                    'A CSV with the columns the importer expects, so a roster '
                    'built in a spreadsheet loads without guesswork.',
                size: BtnSize.sm,
                icon: Icons.download_outlined,
                onPressed: store.downloadCandidateTemplate,
              ),
            ],
          ],
        ),
        // Here as well as in the import sheet: the sheet can be closed while
        // the import carries on, and this is where its rows will land.
        if (store.importProgress != null) ...<Widget>[
          const SizedBox(height: 12),
          _ImportProgress(store: store),
        ],
        const SizedBox(height: 12),
        DataGrid(
          minWidth: 560,
          emptyMessage: widget.search.trim().isEmpty
              ? 'No accounts to show.'
              : 'Nobody matches that search.',
          cols: const <Col>[
            Col('Name', flex: 2),
            Col('Email', flex: 3),
            // Wide enough for the widest label this column ever holds. The
            // button says "Assign" or "Remove", and at 110 the pair overflowed
            // by 82px and painted over the neighbouring cell.
            Col('', width: 200),
          ],
          rows: store.pickerUsers.map((Person u) {
            final Person? onRoster = _rosterEntryFor(u);
            return GridRow(<Widget>[
              Text(u.name, style: context.type.tableCell),
              Text(u.email, style: context.type.bodySecondary),
              // The directory itself is readable - a Manager may look up who
              // exists and who is already on this paper, which is what the
              // pressed state of this button reports. Both branches write,
              // though, on routes only an Admin may call, so for them the cell
              // empties instead of offering a button that 403s. The cell is
              // kept rather than dropped so the row still matches `cols`.
              if (!store.can(Capability.launch))
                const SizedBox.shrink()
              else
                Btn(
                  onRoster == null ? 'Assign' : 'Remove',
                  size: BtnSize.sm,
                  pressed: onRoster != null,
                  // Removing needs the APPLICANT id the roster carries; adding
                  // sends the directory id and lets the server make the
                  // applicant, which is what allows somebody who has never sat
                  // an assessment to be assigned at all.
                  onPressed: () => onRoster == null
                      ? store.assignPickedUser(asm, u)
                      : store.toggleAssign(asm, onRoster.id),
                ),
            ]);
          }).toList(),
        ),
        const SizedBox(height: 10),
        Pagination(
          page: page,
          pageSize: _pageSize,
          total: total,
          unit: 'people',
          onPage: _goto,
          onPageSize: (int n) {
            setState(() {
              _pageSize = n;
              _page = 1;
            });
            _fetch();
          },
        ),
      ],
    );
  }

  /// Invite one person by name and email.
  ///
  /// The roster grid can only offer people who already exist, because it is
  /// built from the candidates of past attempts. A first-time invitee is not
  /// there, so this is the only path that can add them: the server creates the
  /// applicant from name + email and queues the invitation.
  void _showInviteSheet(BuildContext context, AppStore store, Assessment asm) {
    final TextEditingController name = TextEditingController();
    final TextEditingController email = TextEditingController();
    showSheet<void>(
      context,
      title: 'Invite by Email',
      sub: 'Adds the person if they are new, then queues their invitation.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Field(
            label: 'FULL NAME',
            child: _SheetInput(controller: name, hint: 'e.g. Priya Sharma'),
          ),
          const SizedBox(height: 12),
          Field(
            label: 'EMAIL',
            child: _SheetInput(
              controller: email,
              hint: 'e.g. priya@example.com',
            ),
          ),
          const SizedBox(height: 12),
          const Notice(
            tone: Tone.info,
            strong: 'An existing person is reused, never duplicated.',
            text:
                'The server matches on email, so inviting somebody who is '
                'already here just assigns them.',
          ),
        ],
      ),
      actions: <Widget>[
        Btn('Cancel', onPressed: () => Navigator.of(context).pop()),
        Btn.primary(
          'Send Invitation',
          tooltip:
              'Email this candidate their exam link. The link is a bearer '
              'credential - whoever holds it can sit the paper as them.',
          onPressed: () {
            Navigator.of(context).pop();
            store.inviteByEmail(asm, name: name.text, email: email.text);
          },
        ),
      ],
    );
  }

  /// Import a roster from a real CSV file.
  ///
  /// WAS A MOCK: a hardcoded "roster-batch-07.csv" whose button assigned the
  /// first six people already in the store. It never read a file and could not
  /// add anybody new.
  void _showRosterSheet(BuildContext context) {
    showSheet<void>(
      context,
      title: 'Import Candidates',
      sub: 'A CSV with a name column and an email column.',
      body: _CsvImportBody(store: widget.store, asm: widget.asm),
      actions: <Widget>[
        Btn('Close', onPressed: () => Navigator.of(context).pop()),
      ],
    );
  }
}

/// The body of the CSV import sheet: pick, parse, show, send.
class _CsvImportBody extends StatefulWidget {
  const _CsvImportBody({required this.store, required this.asm});

  final AppStore store;
  final Assessment asm;

  @override
  State<_CsvImportBody> createState() => _CsvImportBodyState();
}

/// One plain address: no spaces, one `@`, a dot in the domain, and a
/// letters-only top-level domain of two or more.
final RegExp _plainEmail = RegExp(r'^[^\s@]+@[^\s@]+\.[A-Za-z]{2,}$');

/// A roster CSV, parsed - or refused.
///
/// ONE BAD ROW REFUSES THE WHOLE FILE (A-222, owner rule): [ok] is empty
/// whenever [bad] is not, so nothing can be sent. Each [bad] entry names the
/// file's row number, as a spreadsheet shows it, and why. This used to drop
/// the bad rows and import the rest, so a typo quietly left a candidate off.
({List<({String name, String email})> ok, List<String> bad}) parseCandidateCsv(
  List<int> bytes,
) {
  // latin1 rather than utf8: a roster exported from Excel is often cp1252,
  // and utf8.decode THROWS on a stray accented byte - which would look like
  // "the picker is broken" rather than "this file has an odd encoding".
  String text = String.fromCharCodes(bytes);
  // STRIP THE BYTE ORDER MARK.
  //
  // Excel and Google Sheets both write a UTF-8 BOM at the head of a CSV.
  // Read byte-for-byte as above it arrives as the three characters 'ï»¿'
  // glued to the first cell, so the header read as 'ï»¿name' rather than
  // 'name'. The header test below compared the first cell to 'name', missed,
  // and reported the header itself as a malformed row - "1 row(s) skipped"
  // on a file with nothing wrong with it. Both spellings are stripped: the
  // three-char form this decode produces, and the real U+FEFF in case the
  // decode ever becomes utf8.
  if (text.startsWith('ï»¿')) text = text.substring(3);
  if (text.startsWith('﻿')) text = text.substring(1);
  final List<({String name, String email})> ok =
      <({String name, String email})>[];
  final List<String> bad = <String>[];
  bool first = true;
  final List<String> lines = text.split(RegExp(r'\r?\n'));
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i].trim();
    if (line.isEmpty) continue;
    final int row = i + 1;
    final List<String> cells = line
        .split(',')
        .map((String c) => c.trim())
        .toList();
    final bool wasFirst = first;
    first = false;
    if (cells.length < 2) {
      bad.add('Row $row: needs a name and an email address, comma separated');
      continue;
    }
    final String n = cells[0];
    final String e = cells[1];
    // A HEADER IS THE FIRST ROW WHOSE EMAIL CELL IS NOT AN EMAIL.
    //
    // Matching the literal words 'name' and 'email' meant any other spelling
    // - "Full name,Email address", a translated export, or the BOM above -
    // was counted as a broken row and reported at the operator. Position plus
    // shape identifies it without knowing what it was called.
    if (wasFirst && !e.contains('@')) continue;
    if (!_plainEmail.hasMatch(e)) {
      bad.add('Row $row: "$e" is not a valid email address');
      continue;
    }
    // LOWER-CASED THROUGH THE ONE RULE, so a CSV import and a typed invite
    // cannot mint two applicants for one mailbox.
    ok.add((name: n, email: normalizeEmail(e)));
  }
  return (
    ok: bad.isEmpty ? ok : const <({String name, String email})>[],
    bad: bad,
  );
}

class _CsvImportBodyState extends State<_CsvImportBody> {
  String _fileName = '';
  List<({String name, String email})> _rows =
      const <({String name, String email})>[];
  List<String> _bad = const <String>[];

  /// The server's dry run of [_rows], null until it answers.
  ImportCheck? _check;
  bool _checking = false;

  /// Which file [_check] answers, so a slow check for a file the operator has
  /// already replaced cannot land on the new one.
  int _seq = 0;

  Future<void> _pick() async {
    final PickedFile? f = await AssessmentDetailScreen.pick(
      accept: '.csv,text/csv',
    );
    if (f == null) return;
    final ({List<({String name, String email})> ok, List<String> bad}) r =
        parseCandidateCsv(f.bytes);
    final int seq = ++_seq;
    setState(() {
      _fileName = f.name;
      _rows = r.ok;
      _bad = r.bad;
      _check = null;
      _checking = r.ok.isNotEmpty && widget.store.serverKnowsShowAnswers;
    });
    // A backend without the check would IMPORT the file for real here: it
    // ignores `dry_run` (see [AppStore.serverKnowsShowAnswers]). The batched
    // import below still runs, unchecked, as before.
    if (!_checking) return;
    // ASKED BEFORE ANYTHING IS WRITTEN. The real import of a large file takes
    // minutes, and an 874-row one once ended in a refusal nobody saw (stage,
    // 19 Oct 2026). The dry run answers in about a second with who would be
    // skipped and why, while the operator is still looking at the sheet.
    final ImportCheck c = await widget.store.checkImport(widget.asm, r.ok);
    if (!mounted || seq != _seq) return;
    setState(() {
      _check = c;
      _checking = false;
    });
  }

  /// The rows to send: the first per address (the parser lower-cased them)
  /// and none the server said it would skip. `seen` starts out holding the
  /// skipped addresses, so one set drops both.
  List<({String name, String email})> get _toSend {
    final Set<String> seen = <String>{
      for (final SkippedInvite s in _check?.skipped ?? const <SkippedInvite>[])
        normalizeEmail(s.email),
    };
    return _rows
        .where((({String name, String email}) r) => seen.add(r.email))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final List<({String name, String email})> send = _toSend;
    final List<SkippedInvite> skipped =
        _check?.skipped ?? const <SkippedInvite>[];
    final int already = _check?.already ?? 0;
    final String? error = _check?.error;
    final bool refused = _check?.refused ?? false;
    // THE SERVER COUNTS PEOPLE, the file counts rows: somebody already on the
    // roster is a row but not a new candidate. Its count wins whenever it
    // answered; offline, or when the check failed, the de-duplicated file is
    // all there is.
    final int count = _check != null && error == null && widget.store.isLive
        ? _check!.added
        : send.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Btn('Choose a CSV File', onPressed: _pick),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _fileName.isEmpty ? 'No file chosen' : _fileName,
                style: context.type.bodySecondary,
              ),
            ),
          ],
        ),
        if (_rows.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Panel(
            title: _fileName,
            note: _checking
                ? '${_rows.length} in the file'
                : '$count to import'
                      '${already > 0 ? ', $already already assigned' : ''}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final ({String name, String email}) r in _rows.take(8))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: <Widget>[
                        Expanded(child: Text(r.name, style: context.type.body)),
                        Expanded(
                          child: Text(
                            r.email,
                            style: context.type.bodySecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_rows.length > 8)
                  Text(
                    'and ${_rows.length - 8} more',
                    style: context.type.bodyMuted,
                  ),
              ],
            ),
          ),
        ],
        if (_checking) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            'Checking ${_rows.length} candidates...',
            style: context.type.bodyMuted,
          ),
        ],
        if (refused) ...<Widget>[
          const SizedBox(height: 12),
          Notice(
            tone: Tone.bad,
            strong: 'Nothing imported - the server refused this file.',
            text: '${error ?? ''} Fix the file and choose it again.',
          ),
        ] else if (error != null) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            'Could not check the file first: '
            '${error.replaceFirst(RegExp(r'\.$'), '')}. The import still '
            'skips anyone who cannot sit.',
            style: context.type.bodyMuted,
          ),
        ],
        if (skipped.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Notice(
            tone: Tone.warn,
            strong:
                '${skipped.length} will be skipped - they cannot sign in to '
                'sit.',
            text:
                '${skipped.take(8).map(skippedLine).join('; ')}'
                '${skipped.length > 8 ? '; and ${skipped.length - 8} more' : ''}',
          ),
        ],
        if (_bad.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Notice(
            tone: Tone.bad,
            strong: _bad.length == 1
                ? 'Nothing imported - 1 row needs fixing.'
                : 'Nothing imported - ${_bad.length} rows need fixing.',
            text:
                'One bad row refuses the whole file. Fix it and choose the '
                'file again: ${_bad.take(8).join('; ')}'
                '${_bad.length > 8 ? '; and ${_bad.length - 8} more' : ''}.',
          ),
        ],
        const SizedBox(height: 12),
        // THE SHEET STAYS OPEN WHILE IT IMPORTS. It used to close at the click
        // and leave nothing on screen until the summary toast - minutes later
        // for a 1000-row file, which read as a hang or an error.
        ListenableBuilder(
          listenable: widget.store,
          builder: (BuildContext context, Widget? _) {
            final bool busy = widget.store.importProgress != null;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (busy) ...<Widget>[
                  _ImportProgress(store: widget.store),
                  const SizedBox(height: 12),
                ],
                Btn.primary(
                  busy
                      ? 'Importing...'
                      : _rows.isEmpty
                      ? 'Import'
                      : 'Import $count candidate(s)',
                  // Held while the dry run is out, and when it says nobody
                  // new would be added. Only the people who can sit are sent.
                  onPressed: busy || _checking || refused || count == 0
                      ? null
                      : () async {
                          final NavigatorState nav = Navigator.of(context);
                          await widget.store.inviteMany(widget.asm, send);
                          if (mounted) nav.pop();
                        },
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// How far the CSV import in flight has got: a bar and "150 of 1000".
class _ImportProgress extends StatelessWidget {
  const _ImportProgress({required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final ({int done, int total})? p = store.importProgress;
    if (p == null) return const SizedBox.shrink();
    final AppTokens t = context.tokens;
    return Semantics(
      label: 'Importing candidates: ${p.done} of ${p.total}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                'Importing candidates - keep this page open',
                style: context.type.tiny,
              ),
              const Spacer(),
              Mono('${p.done} of ${p.total}', weight: FontWeight.w600),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: Radii.bar,
            child: LinearProgressIndicator(
              // Indeterminate until the first batch lands, so the bar moves
              // from the first second rather than sitting at zero.
              value: p.done == 0 ? null : p.done / p.total,
              minHeight: 7,
              backgroundColor: t.bgMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// A text input for the sheets, in the same shape the rest of the app uses.
class _SheetInput extends StatelessWidget {
  const _SheetInput({required this.controller, required this.hint});

  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return SizedBox(
      height: 32,
      child: TextField(
        controller: controller,
        style: context.type.body,
        cursorColor: t.primary,
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: context.type.bodyMuted,
          filled: true,
          fillColor: t.bgApp,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          border: OutlineInputBorder(
            borderRadius: Radii.input,
            borderSide: BorderSide(color: t.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: Radii.input,
            borderSide: BorderSide(color: t.border),
          ),
        ),
      ),
    );
  }
}

class _AssignedChip extends StatelessWidget {
  final String name;

  /// Null for somebody invited to a DRAFT: they have no attempt record yet, so
  /// there is nothing for `toggleAssign` to remove. Showing a dead X would
  /// offer an action that silently does nothing.
  final VoidCallback? onRemove;

  const _AssignedChip({required this.name, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      height: 26,
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: t.primarySubtle,
        borderRadius: Radii.pill,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            name,
            style: context.type.small.copyWith(
              fontWeight: FontWeight.w600,
              color: t.primary,
            ),
          ),
          if (onRemove != null) ...<Widget>[
            const SizedBox(width: 4),
            IconBtn(Icons.close, tooltip: 'Remove', onPressed: onRemove!),
          ] else
            const SizedBox(width: 6),
        ],
      ),
    );
  }
}

/// The roster's sortable columns, as the wire keys the route's allow-list
/// speaks, INDEX-ALIGNED with the `cols` the grid is built from below.
///
/// `DataGrid.onSort` reports the column INDEX and nothing else, deliberately -
/// only the screen knows what the column at that index holds. That makes this
/// list the join between the two, and a column inserted into the grid without
/// its key inserted here would silently sort by its neighbour: the table would
/// re-order, plausibly, by the wrong thing. Every entry has a matching `Col`
/// marked `sortable: true`, in the same order.
const List<String> _kRosterSortKeys = <String>[
  'candidate',
  'invite',
  'state',
  'answered',
  'score',
  'result',
  'released',
  'remarks',
  'flag',
];

/// Candidates. Post-draft only.
/// Where one candidate is in the grading queue, or null when there is nothing
/// worth saying.
///
/// ONLY WHEN IT IS NOT CLEAN. A badge on every row is wallpaper - the same rule
/// the Leaderboard's "n awaiting" already follows - so a fully scored roster
/// renders exactly as it did before this cell learned to speak, and a busy one
/// reads at a glance.
///
/// NOT THE REMOVED "Flags" COLUMN REBORN. That one carried the MACHINE badges
/// (integrity, outlier, auto-submitted, erased) in a cell of their own, one
/// letter away from the operator's "Flag" column, and operators asked which of
/// the two they were meant to act on. This says one thing about the score it
/// sits under and takes no column.
///
/// The labels and tones come off [LlmState] rather than being written here, so
/// a row and the attempt screen it opens cannot name the same state differently.
Widget? _scoringBadge(Attempt e) {
  final LlmState st = e.subjectiveState;
  if (st == LlmState.scored) return null;
  // `scoring_requested` is the flag the server's own cron selects on, so a
  // candidate carrying it is IN the queue while `llm_state` still reads
  // pending. Printing that as "Pending" would put an operator watching a
  // 700-row cohort in front of 700 rows that all look idle, which is the
  // report in miniature.
  if (e.scoringRequested && st != LlmState.scoring) {
    return const StatusBadge('Queued', Tone.info);
  }
  // Nothing has been asked for yet: the honest thing to report is the size of
  // what is outstanding, not a state nobody has entered.
  if (st == LlmState.notNeeded || st == LlmState.pending) {
    if (e.subjectivePending <= 0) return null;
    return StatusBadge('${e.subjectivePending} awaiting', Tone.warn);
  }
  return StatusBadge(st.label, st.tone);
}

class _CandidatesTab extends StatefulWidget {
  final AppStore store;
  final Assessment asm;
  final Portal portal;

  const _CandidatesTab({
    required this.store,
    required this.asm,
    required this.portal,
  });

  @override
  State<_CandidatesTab> createState() => _CandidatesTabState();
}

class _CandidatesTabState extends State<_CandidatesTab> {
  // Each filter STARTS from the address bar, so a reload of
  // `/assessments/<id>/candidates?state=...` reopens the same slice; `build`
  // writes them back.

  /// D1 - narrow the roster to operator-flagged candidates, server-side.
  late bool _flaggedOnly = context.navQuery['flagged'] == '1';

  /// The ONE pressed tile: '' (All), the wire of an [AttemptState] or
  /// [ScoringFilter] (sent as `state`), or `pass` / `fail` (sent as
  /// `result`). One choice, because every tile is counted over the same
  /// cohort: a state AND-ed with a verdict showed a total no tile carried. An
  /// old `?state=submitted&result=fail` link opens on the verdict.
  late String _tile = switch (context.navQuery['result']) {
    final String r when r == 'pass' || r == 'fail' => r,
    _ => context.navQuery['state'] ?? '',
  };

  bool get _isVerdict => _tile == 'pass' || _tile == 'fail';

  /// Matched against name or email, SERVER-side.
  late String _search = context.navQuery['q'] ?? '';

  late int _page = int.tryParse(context.navQuery['page'] ?? '') ?? 1;
  late int _pageSize = int.tryParse(context.navQuery['size'] ?? '') ?? 100;
  Timer? _debounce;

  /// The ordering, as an index into [_kRosterSortKeys]. Null is the route's own
  /// default - newest first - which is a real answer to "what is this cohort"
  /// and the only honest one before anybody has asked for another.
  int? _sortCol;
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    _seenRevision = widget.store.historyRevision;
    _fetch();
  }

  @override
  void didUpdateWidget(_CandidatesTab old) {
    super.didUpdateWidget(old);
    // ONLY on a different assessment. This tab lives inside a ListenableBuilder
    // on the store, so `didUpdateWidget` runs on every notify - and
    // `pollGeneration` notifies every two seconds while a generation is in
    // flight. Re-fetching here unconditionally would put the roster on that
    // loop, which is the traffic the console-wide walk was capped to escape.
    if (old.asm.id != widget.asm.id) {
      _debounce?.cancel();
      _tile = '';
      _search = '';
      _sortCol = null;
      _sortAsc = true;
      _page = 1;
      _fetch();
      return;
    }
    // AND WHEN A SCORING RUN ENDS. The roster is paged server-side, so the
    // marks in it are whatever the page held when it was fetched: a cohort
    // graded while this tab was open went on showing the scores it had before
    // grading started until the operator changed page. The detail read the
    // screen does at the same moment refreshes the header counts and the record
    // - it does not refill `rosterRows`, which only `loadRoster` writes.
    //
    // A TRANSITION, not a level, and that is what keeps it off the notify loop
    // the guard above exists to escape: `busy -> not busy` fires once per run.
    final bool wasScoring = old.asm.scoringPhase?.isBusy ?? false;
    final bool nowScoring = widget.asm.scoringPhase?.isBusy ?? false;
    // AND AFTER AN ACTION LANDS. Release changed the rows' Released column on
    // the server, and this page went on saying "Held" until the operator
    // switched tabs. `historyRevision` moves once per successful action, so
    // this too is a transition, not a level. Quiet: the rows stay on screen.
    final int revision = widget.store.historyRevision;
    if ((wasScoring && !nowScoring) || revision != _seenRevision) {
      _seenRevision = revision;
      _fetch();
    }
  }

  /// The store's action count this page was last fetched at.
  int _seenRevision = 0;

  @override
  void dispose() {
    // Nothing in flight can outlive the tab: the timer is cancelled here and
    // `loadRoster`'s sequence guard drops any response that lands afterwards.
    _debounce?.cancel();
    super.dispose();
  }

  void _fetch() => widget.store.loadRoster(
    widget.asm.id,
    page: _page,
    pageSize: _pageSize,
    search: _search,
    state: _isVerdict ? '' : _tile,
    result: _isVerdict ? _tile : '',
    manualFlaggedOnly: _flaggedOnly,
    sortCol: _sortCol == null ? '' : _kRosterSortKeys[_sortCol!],
    sortAsc: _sortAsc,
  );

  /// DEBOUNCED, because searching now costs a request.
  ///
  /// `SearchField` fires on every keystroke, and the old filter was in memory,
  /// so a straight port would have put one round trip per character on a backend
  /// that sheds load at capacity. 250ms is the same delay the Assign tab's
  /// directory picker uses.
  void _onSearch(String v) {
    setState(() => _search = v);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      // BACK TO PAGE 1. Page 4 of "aahan" is not page 4 of the unfiltered
      // cohort, and holding the offset across a new term shows an empty table
      // over rows that exist.
      setState(() => _page = 1);
      _fetch();
    });
  }

  void _goto(int page) {
    setState(() => _page = page);
    _fetch();
  }

  /// Press a tile. A lit one does nothing - All is the way back - and keeps
  /// its handler anyway: a `Btn` with none is DISABLED, which faded the
  /// selected tile below the unselected ones.
  void _pick(String wire) {
    if (_tile == wire) return;
    setState(() {
      _tile = wire;
      _page = 1;
    });
    _fetch();
  }

  /// A header click REFETCHES, and that is the whole design of this feature.
  ///
  /// `responses_screen.dart` sorts its rows in Dart and this deliberately does
  /// not. The roster is paged server-side at up to 200 rows and a live cohort
  /// is 711, so a comparator here would order 200 of 711 rows and label the
  /// result "sorted by score" while the top scorer sat on page 3 and never
  /// appeared. An operator cannot see that it happened, which is what makes it
  /// worse than having no sort at all: the ordering is the answer they came
  /// for, and it would be a confident wrong one.
  void _onSort(int col) {
    setState(() {
      if (_sortCol == col) {
        // Third click clears it rather than cycling back to ascending: the
        // route's default order is a state worth being able to get back to,
        // and there is no other control on this screen that returns to it.
        _sortAsc ? _sortAsc = false : _sortCol = null;
      } else {
        _sortCol = col;
        _sortAsc = true;
      }
      // BACK TO PAGE 1 on every change of order, for the same reason a new
      // search term goes back: page 4 of the cohort by score is not page 4 of
      // the cohort by name, so holding the offset lands the operator part-way
      // down a list they have not seen the start of.
      _page = 1;
    });
    _fetch();
  }

  /// D1 - write the internal remark from the ROSTER, without opening the
  /// sitting first.
  ///
  /// The sheet is the same one the attempt screen opens, deliberately: the
  /// remark is read months later by somebody arguing about a mark, and a box
  /// that explains what it is for on one surface but not the other would
  /// collect two different kinds of sentence.
  ///
  /// `remark:` ALONE, NEVER `flagged:`. The flag and the remark are independent
  /// facts sharing one endpoint, so echoing the flag state back alongside the
  /// prose would turn a colleague's concurrent toggle into a silent revert -
  /// and would break the promise the sheet makes in so many words, that saving
  /// a remark neither raises nor clears a flag.
  Future<void> _editRemark(Attempt e, String name) async {
    final String? out = await askForRemark(
      context,
      candidateName: name,
      existing: e.candidateFlag.remark,
    );
    // null is CANCELLED, '' is "delete the remark" - see the contract on
    // [askForRemark]. Collapsing the two here would make an existing remark
    // impossible to remove from the roster, and folding '' into null would
    // silently erase one every time an operator backed out of the sheet.
    if (out == null || !mounted) return;
    await widget.store.flagAttempt(e.id, remark: out);
  }

  @override
  Widget build(BuildContext context) {
    final AppStore store = widget.store;
    final Assessment asm = widget.asm;
    context.setNavQuery(<String, Object?>{
      'state': _isVerdict ? '' : _tile,
      'result': _isVerdict ? _tile : '',
      'q': _search,
      'flagged': _flaggedOnly ? 1 : null,
      'page': _page == 1 ? null : _page,
      'size': _pageSize == 100 ? null : _pageSize,
    });

    // THE ROSTER'S OWN ROUTE, not the console-wide attempts walk.
    //
    // `/api/v1/attempts` pages by `create_date desc` over a cohort invited in
    // one transaction, so every row shares a `create_date` and offset paging
    // over that unstable sort returned some rows twice and others never -
    // 2,538 collected, 2,077 distinct, measured on stage. Filtering that in
    // memory is how a candidate the server holds rendered as "No candidate
    // matches these filters", and how another rendered twice with the same
    // score. `/assessments/<id>/candidates` is scoped to the cohort, pages it
    // server-side and searches it server-side.
    final List<RosterRow> rows = store.rosterRowsFor(asm.id);

    // THE SERVER'S COUNT, never `rows.length`. One page of 100 out of 572 must
    // not be able to describe itself as the whole cohort - which is the failure
    // mode that hid this defect for months: `total` came from a correct
    // `search_count` while the rows underneath had drifted.
    final int total = store.rosterTotalFor(asm.id);
    final int pageCount = total == 0 ? 1 : ((total - 1) ~/ _pageSize) + 1;
    final int page = _page.clamp(1, pageCount);
    // THE CLAMPED PAGE IS FETCHED, after the frame. A `?page=9` link, or an
    // action that shrank the list, otherwise showed page 1's pager over the
    // empty page 9 the server answered, with page 9 still in the URL.
    if (page != _page && !store.rosterLoading && store.rosterError.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _page == page) return;
        setState(() => _page = page);
        _fetch();
      });
    }

    // EVERY CHIP'S COUNT FROM THE ROSTER RESPONSE (`meta.counts`), keyed by
    // the wire value the chip sends. Not the console-wide attempts cache: a
    // finished scoring run does not refresh it, and it cannot split Submitted
    // into Scored and Score Pending, since that split is made on answers the
    // roster rows do not carry. The tab refetches when a run ends (see
    // `didUpdateWidget`), so these move with it. A server that
    // sends no counts gets the chips without numbers rather than withheld - a
    // filter that cannot be reached is worse than one whose tally is missing.
    final Map<String, int> counts = store.rosterCountsFor(asm.id);
    final bool haveCounts = counts.isNotEmpty;

    final bool filtered =
        _tile.isNotEmpty || _search.trim().isNotEmpty || _flaggedOnly;
    final String emptyMessage = store.rosterError.isNotEmpty
        ? 'The roster could not be loaded: ${store.rosterError}'
        : store.rosterLoading
        ? 'Loading the roster...'
        : filtered
        ? 'No candidate matches these filters.'
        : 'Nobody was assigned to this assessment.';

    // Raising or clearing a flag and WRITING A REMARK are both LIFECYCLE
    // writes - the same capability the resend control in the Invite cell is
    // gated on, because all three are the same class of change to the same
    // sitting. Read once here rather than per row, because 200 rows would
    // otherwise ask the store the same question 200 times to reach the same
    // answer.
    final bool canWrite = store.can(Capability.lifecycle);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // A FAILED READ KEEPS ITS CONTROLS. `loadRoster`'s error path zeroes
        // `rosterTotal`, so a request that could not be answered - an expired
        // session, a dropped connection, a 500 - used to take the state chips
        // and the search box away with it and leave the operator an error
        // message, the column headers and no way to ask for anything else. The
        // message says what went wrong; the toolbar is how they try again.
        if (total > 0 || filtered || store.rosterError.isNotEmpty) ...<Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 7,
                  runSpacing: 7,
                  children: <Widget>[
                    const Eyebrow('State'),
                    Btn(
                      haveCounts ? 'All  ${counts['all'] ?? 0}' : 'All',
                      size: BtnSize.sm,
                      pressed: _tile.isEmpty,
                      tooltip: 'Show every candidate on this assessment',
                      onPressed: () => _pick(''),
                    ),
                    // `.wire`, NEVER `.name`. `_tile` is sent to the route as
                    // `state` and lands in `("state", "=", ...)` against the
                    // stored selection key, so it has to be the server's
                    // spelling. `.name` is the DART IDENTIFIER: it happens to
                    // equal `.wire` for `pending` and `submitted`, and does not
                    // for `inProgress` -> `in_progress`. So exactly one chip
                    // broke, and it broke SILENTLY - the count beside it is
                    // computed in the client from the cached rows, so it kept
                    // reading "In progress 8" while the route, asked for a
                    // state no row has ever held, answered with an empty page
                    // and the table said "No candidate matches these filters."
                    //
                    // Counting by `.wire` closes the other half: one
                    // vocabulary in this widget, so the chip's number and the
                    // chip's query cannot disagree again.
                    // `|| _tile == wire` ON EVERY GROUP. Hiding a chip at 0 is
                    // right for every chip nobody pressed and wrong for the one
                    // that IS pressed: the counts move when a run ends and the
                    // tab refetches, and a vanished chip would leave "No
                    // candidate matches these filters." with nothing pressed
                    // and nothing to press to undo it.
                    for (final AttemptState s in AttemptState.values)
                      if (!haveCounts ||
                          (counts[s.wire] ?? 0) > 0 ||
                          _tile == s.wire)
                        Btn(
                          haveCounts
                              ? '${s.label}  ${counts[s.wire]}'
                              : s.label,
                          size: BtnSize.sm,
                          pressed: _tile == s.wire,
                          tooltip:
                              'Show only candidates whose attempt is '
                              '${s.label.toLowerCase()}',
                          onPressed: () => _pick(s.wire),
                        ),
                    // AFTER SUBMITTED, which they split: Scored + Score Pending
                    // = Submitted. Same `state` parameter and same rules as the
                    // chips above.
                    for (final ScoringFilter f in ScoringFilter.values)
                      if (!haveCounts ||
                          (counts[f.wire] ?? 0) > 0 ||
                          _tile == f.wire)
                        Btn(
                          haveCounts
                              ? '${f.label}  ${counts[f.wire]}'
                              : f.label,
                          size: BtnSize.sm,
                          pressed: _tile == f.wire,
                          tooltip: f == ScoringFilter.scored
                              ? 'Show only submitted candidates with every '
                                    'answer scored'
                              : 'Show only submitted candidates with an answer '
                                    'still waiting on the grader',
                          onPressed: () => _pick(f.wire),
                        ),
                    // THE VERDICT: Passed and Failed are not values of `state`
                    // - a candidate is submitted AND passed - so they travel as
                    // `result`. Still one choice with the tiles before them:
                    // pressing one replaces a pressed state, and the lit one
                    // stays lit (All clears it). The counts are
                    // `meta.counts.pass` / `.fail`, and the same pressed-chip
                    // exemption as above applies.
                    for (final MapEntry<String, String> v
                        in const <String, String>{
                          'pass': 'Passed',
                          'fail': 'Failed',
                        }.entries)
                      if (!haveCounts ||
                          (counts[v.key] ?? 0) > 0 ||
                          _tile == v.key)
                        Btn(
                          haveCounts
                              ? '${v.value}  ${counts[v.key] ?? 0}'
                              : v.value,
                          size: BtnSize.sm,
                          pressed: _tile == v.key,
                          tooltip:
                              'Show only candidates who '
                              '${v.key == 'pass' ? 'passed' : 'failed'}',
                          onPressed: () => _pick(v.key),
                        ),
                    // D1. ITS OWN CHIP, not another value of the State group:
                    // a flag is not a state, and the server keeps the two
                    // separate too - `manual_flagged_only` is an AND-ed term
                    // beside `state`, so the two compose instead of replacing
                    // each other. Ticking it narrows whatever state is
                    // already selected.
                    //
                    // NO SPACER IN FRONT OF IT. A `SizedBox(width: 6)` used to
                    // sit here to set the flag chip apart from the state group,
                    // and it ADDED to the `Wrap`'s own 7px rather than
                    // replacing it: the gap before Flagged measured 13px
                    // against 7px everywhere else, which reads as a rendering
                    // fault rather than as a grouping. The `Wrap` owns the
                    // spacing for every chip in this row, this one included.
                    Btn(
                      'Flagged',
                      size: BtnSize.sm,
                      icon: Icons.outlined_flag,
                      pressed: _flaggedOnly,
                      tooltip:
                          'Show only candidates an operator has flagged. '
                          'Combines with the state filter rather than '
                          'replacing it.',
                      onPressed: () {
                        setState(() {
                          _flaggedOnly = !_flaggedOnly;
                          _page = 1;
                        });
                        _fetch();
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 220,
                child: SearchField(
                  value: _search,
                  hint: 'Find a candidate',
                  onChanged: _onSearch,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
        ],
        // DIMMED while another filter, page or sort loads, so the rows of the
        // last slice are not read as the answer to the new one. A refetch of
        // the same slice (after an action, a scoring run) leaves them alone.
        Opacity(
          opacity: store.rosterStale ? 0.4 : 1,
          child: DataGrid(
            // 1096, DOWN FROM 1440, and the drop is the whole point: `DataGrid`
            // scrolls sideways only once the width it is GIVEN falls below
            // `minWidth`, so 1440 guaranteed a horizontal scrollbar on the 14"
            // laptop this console is actually operated from - about 1250px of
            // content pane beside the 260px nav rail. Triaging a cohort meant
            // dragging the table right to read the verdict and left again to see
            // whose it was.
            //
            // THE ARITHMETIC, for the nine columns below:
            //     fixed    810 = Invite 116 + State 104 + Answered 76
            //                  + Score 96 + Result 84 + Released 88
            //                  + Remarks 194 + Flag 52
            //     gutters   96 = 8 gaps between 9 columns x 12px, fixed by
            //                    `data_grid.dart` and not negotiable here
            //     padding   30 = the row's own 15px on each side
            //     ---------------
            //              936 of structure, + 160 as the floor for the single
            //     flex column = 1096.
            //
            // 160 IS A FLOOR, NOT A TARGET. The flex column holds the NAME that
            // identifies the row, so it is the one cell worth giving slack to: at
            // the real 1250 it takes the entire surplus (~314px) instead of the
            // table taking a scrollbar, and 160 is only what it falls back to on
            // a narrower window before the grid finally starts scrolling. That
            // surplus is also what closed the gaps an operator reported as "a lot
            // of vacant space in between columns": the width had been parked in
            // eight fixed columns each sized for its own worst case, and every
            // row paid for all eight.
            minWidth: 976,
            emptyMessage: emptyMessage,
            sortCol: _sortCol,
            sortAsc: _sortAsc,
            onSort: _onSort,
            // EVERY COLUMN SORTS, and every one of them sorts on the SERVER - see
            // `_onSort`. The keys the header indices resolve to live in
            // `_kRosterSortKeys` above, in this same order.
            cols: const <Col>[
              // LEFT, and the only column that is. A name is read
              // left-to-right and a ragged left edge is genuinely harder to
              // scan; every column after it is CENTRED so that each one's
              // content sits in the middle of the width it was given. That is
              // what makes the rhythm even when the columns are deliberately
              // different widths - the alternative, packing everything to the
              // left, leaves a wide column looking like dead space and a narrow
              // one looking cramped.
              //
              // `flex: 2` is retained on purpose: this column absorbs and
              // releases the slack as the Assessment History panel opens and
              // closes, so the table reflows instead of scrolling.
              //
              // Sorts on the route's `candidate_name`, which is the name this
              // cell RENDERS. Ordering by the applicant relation instead would
              // sort by the comodel's own `_order` and ordering by the email
              // would diverge from the name as soon as an address is not
              // `first.last` - either way the column would re-order by something
              // the operator cannot see.
              Col('Candidate', flex: 2, sortable: true),
              // 116, down from 200. The 200 was sized for the RARE failed
              // invitation - pill, the server's reason, and a control to put the
              // mail back on the queue - and charged it to every row that just
              // says "Sent". The resend is an `IconBtn` now, so the worst case
              // measures: pill "Failed" ~58 + 5 + info glyph 14 + 5 + IconBtn 27
              // = 109. The pill is `Flexible` in the cell below, so a longer
              // label ellipsises rather than painting over State - which is the
              // failure the old 200 was really paying to avoid.
              Col('Invite', width: 116, align: ColAlign.center, sortable: true),
              // 104: the widest state pill is "Not started" / "In progress", ~84
              // including its dot and its 8px of padding each side.
              //
              // STATE ORDERS ON A SERVER-SIDE RANK, not on the stored selection
              // key: alphabetically `in_progress` sorts before `pending`, so the
              // lifecycle an operator is reading for - not started, in progress,
              // submitted - would come back starting in the middle. Nothing is
              // re-ordered here to correct it; the fix belongs where the ORDER BY
              // is, or the client is back to sorting one page of 711.
              Col('State', width: 96, align: ColAlign.center, sortable: true),
              // 82: the value is at most three mono digits, so the 11px uppercase
              // "ANSWERED" header (~68) is what sets this floor, not the data -
              // and a sortable header also reserves 13px for its caret whether or
              // not the caret is drawn (`data_grid.dart`, so the label cannot
              // shift sideways when the column becomes the sorted one). 68 left
              // the label 55px and cropped it to "ANSWERE...", on the column an
              // operator sorts most. The 14px comes out of the flex CANDIDATE
              // column's share rather than out of `minWidth`, which stays at 976
              // so the table still fits a 980px pane without scrolling.
              Col(
                'Answered',
                width: 82,
                numeric: true,
                align: ColAlign.center,
                sortable: true,
              ),
              // 96, the same width the candidate record gives the same column.
              // `Marks` paints the numerator at 32px mono and the denominator at
              // 18px, so "18 / 25" already measures ~92: 90 was short and the
              // 84 this re-fit started from would have clipped the total off
              // every two-digit score.
              Col(
                'Score',
                width: 96,
                numeric: true,
                align: ColAlign.center,
                sortable: true,
              ),
              // 84: "Pending" is the longest verdict, ~68 as a pill.
              Col('Result', width: 78, align: ColAlign.center, sortable: true),
              // 88: the "Released" pill measures ~73, and "RELEASED" ~62.
              Col(
                'Released',
                width: 80,
                align: ColAlign.center,
                sortable: true,
              ),
              // NO "Flags" COLUMN. It carried the MACHINE badges - scoring error,
              // integrity, outlier, auto-submitted, erased - one letter away from
              // the "Flag" column that carries the OPERATOR's own, and operators
              // asked which of the two they were meant to act on. Every one of
              // those badges is still rendered, unchanged, on the attempt detail
              // screen, which is where a machine signal is investigated anyway:
              // the roster gives up 120px of duplication and the product gives up
              // nothing.
              //
              // 194, up from 170, because this column now holds a CONTROL and not
              // only prose - the remark is written from here. Still not wide
              // enough for a whole sentence, deliberately: two ellipsised lines
              // plus the tooltip carry it, and the sitting shows it in full.
              Col(
                'Remarks',
                width: 136,
                align: ColAlign.center,
                sortable: true,
              ),
              // LAST, and narrow: one 17px glyph in a 52px cell that is all
              // target. NOT `numeric` - right-alignment would park the flag hard
              // against the table's edge, away from the header that names it, and
              // this column holds a control rather than a figure to line decimal
              // points up on. `sortable` IS on now that the route can order by
              // `manual_flagged`: the header gathers every flagged candidate in
              // the cohort into one block, which is the only question this column
              // is ever sorted to answer. It could not honestly be offered while
              // the ordering was the client's - a boolean over 711 rows is ~700
              // rows sharing one key, so a page of it is not a sample of
              // anything.
              Col('Flag', width: 52, align: ColAlign.center, sortable: true),
            ],
            rows: rows.map((RosterRow r) {
              final Attempt e = r.attempt;
              // THE SERVER'S VERDICT, not a local re-derivation. A roster row
              // carries no answers, so `result` could not see an answer held on a
              // terminal grader error and printed FAIL where the module said
              // pending. See `Attempt.result`.
              final ResultState result = e.verdict(asm);
              final Widget? scoring = _scoringBadge(e);
              // The name off the ROSTER ROW. `personById` reads the map the
              // console-wide walk builds, which does not necessarily hold a
              // candidate this page just introduced.
              //
              // HOISTED out of the cell because the remark sheet titles itself
              // with it too, and a sheet naming the candidate differently from
              // the row it was opened from reads as the wrong record being
              // edited - on a write that outlives the screen.
              final String name = r.name.isNotEmpty
                  ? r.name
                  : (store.personById(e.employeeId)?.name ?? e.employeeId);
              // Null for a rung that may READ the roster but not write to it.
              // Built once and handed to both the icon and the cell around it so
              // the two cannot drift into disagreeing about who may click.
              final VoidCallback? toggleFlag = canWrite
                  ? () => store.flagAttempt(
                      e.id,
                      flagged: !e.candidateFlag.flagged,
                    )
                  : null;
              // The remark rides the SAME gate as the flag, because it is the
              // same endpoint on the same sitting - a surface that let a Manager
              // type a remark and then refused the write would collect the
              // sentence and lose it to a 403.
              final VoidCallback? editRemark = canWrite
                  ? () => _editRemark(e, name)
                  : null;
              return GridRow(onTap: () => context.nav.attempt(e.id), <Widget>[
                GridLink(name),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    // FLEXIBLE, so the PILL is what gives way under pressure.
                    // This cell is 116px and its worst case (failed, with a
                    // reason and a resend) fills ~109 of them; a pill that
                    // refused to shrink would paint over the State column the
                    // first time a label or a font metric grew, which is the
                    // overflow the old 200px width was really buying off.
                    Flexible(child: Pill.state(e.inviteState)),
                    if (e.inviteState == InviteState.failed) ...<Widget>[
                      const SizedBox(width: 5),
                      // The server's own reason, on hover. "Failed" alone cannot
                      // tell a wrong address from a mail server that is down, so
                      // an operator would press Resend forever on something a
                      // resend can never fix.
                      if (e.inviteError.isNotEmpty)
                        Tooltip(
                          message: e.inviteError,
                          child: Icon(
                            Icons.info_outline,
                            size: 14,
                            color: context.tokens.textMuted,
                          ),
                        ),
                      // The failed pill and the server's reason stay for every
                      // operator: a Manager reading "failed - mailbox full" is
                      // the person most likely to go and fix the address. Putting
                      // the invitation back on the queue is a lifecycle action an
                      // Admin-only route owns, so the button leaves with its
                      // spacer and the cell ends on the reason instead of a 5px
                      // gap and a 403.
                      if (canWrite) ...<Widget>[
                        const SizedBox(width: 5),
                        // AN ICON, not the old "Resend" label. The label spent
                        // ~60px of a column that only exists at 116px now, and
                        // at that width it ran under State - the exact collision
                        // the 200px was there to prevent. The tooltip carries the
                        // whole sentence, so the action is still named for an
                        // operator who has not met it before, and the write it
                        // makes is unchanged.
                        IconBtn(
                          Icons.refresh,
                          tooltip: 'Resend this invitation',
                          onPressed: () => store.requeueInvite(e.id),
                        ),
                      ],
                    ],
                  ],
                ),
                Pill.state(e.state),
                Mono('${e.answeredCount}'),
                // Invariant 3 holds on the admin surface too, but for a different
                // reason: the admin CAN see the marks, so the column shows them.
                // What it must not do is imply the candidate can.
                //
                // THE BADGE UNDER THE NUMBER answers "where is candidate X", the
                // one question this roster could not answer at all while a cohort
                // was being graded. It belongs here rather than in a column of
                // its own because what it says is a fact ABOUT this number -
                // whether it is final - and because a column of its own is
                // exactly what was removed from this table and must not come
                // back. See the note where the Flags column used to be declared.
                scoring == null
                    ? Marks(e.earnedMarks(asm), e.maxMarks(asm))
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Marks(e.earnedMarks(asm), e.maxMarks(asm)),
                          const SizedBox(height: 3),
                          scoring,
                        ],
                      ),
                Pill.state(result),
                e.resultsReleased
                    ? const Pill('Released', Tone.ok)
                    : const Pill('Held', Tone.inert),
                // NO MACHINE-BADGE CELL HERE any more, and its `Col` went with
                // it in the same edit - a cell removed on its own shifts every
                // column to its right one place left, so header and data would
                // silently disagree from Remarks onwards. What it held (scoring
                // error, integrity, outlier, auto-submitted, erased) is still
                // rendered in full on the attempt detail screen.
                //
                // D1 - THE REMARK, and it is now WRITTEN from here as well as
                // read. Reading it in a column rather than behind a hover was the
                // original point: it is the sentence saying WHY a sitting was
                // held, and an operator scanning a cohort for the one they wrote
                // yesterday cannot hover a hundred rows to find it. What was
                // missing was the other half - typing one meant opening the
                // sitting first, which is the round trip that had operators not
                // writing remarks at all.
                _RemarkCell(flag: e.candidateFlag, onEdit: editRemark),
                // D1 - THE FLAG, and it WRITES from here.
                //
                // An operator triaging a cohort decides "this one needs looking
                // at" while READING the roster, not after opening each sitting
                // in turn; making them open the attempt to raise a flag is the
                // round trip that had them not flagging at all. Outline on every
                // row, not only flagged ones - a control that appears once the
                // state it sets is already set cannot be used to set it.
                //
                // The tap is SWALLOWED exactly as the grid's own checkbox gutter
                // swallows its own: this row navigates to the attempt, and a
                // near-miss on a 17px glyph must not carry the operator off the
                // page they are triaging. The outer detector runs the same
                // toggle as the icon, so the whole 52px cell is the target and
                // the gesture arena still resolves to exactly one of them.
                toggleFlag == null
                    // A read-only Manager still SEES the flag and its sentence -
                    // they are often the person asking why a candidate is held -
                    // and with no detector in the way the cell stays part of the
                    // row's own tap target rather than a dead strip down the
                    // right-hand edge.
                    ? FlagToggle(flag: e.candidateFlag)
                    : GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: toggleFlag,
                        child: FlagToggle(
                          flag: e.candidateFlag,
                          onToggle: toggleFlag,
                        ),
                      ),
                // No "Open": the row already navigates here.
              ]);
            }).toList(),
          ),
        ),
        if (total > 0) ...<Widget>[
          const SizedBox(height: 10),
          // SERVER-SIDE PAGING, so `total` is the cohort and not the page. The
          // sizes this control offers are 10/20/50/100/200, all inside the
          // route's own 200-row clamp.
          Pagination(
            page: page,
            pageSize: _pageSize,
            total: total,
            unit: 'candidates',
            onPage: _goto,
            onPageSize: (int n) {
              setState(() {
                _pageSize = n;
                _page = 1;
              });
              _fetch();
            },
          ),
        ],
      ],
    );
  }
}

/// Leaderboard. Released results only, because an unreleased mark has not been
/// shown to the person it belongs to.
/// STATEFUL, and it fetches. It used to rank `attemptsFor(asm.id)` - the
/// console-wide attempts cache, whose walk is capped across EVERY assessment -
/// so one large cohort could be ranked from whatever share of that cap was
/// left over, with nothing on screen saying the ranking was partial. A
/// leaderboard built from a sample is a guess with an ordinal beside it.
///
/// `store.loadCohort` reads this assessment's own roster route to the end and
/// keeps it in a cache scoped to this assessment, so neither the console-wide
/// attempts cache nor the dashboard's global leaderboard is disturbed.
class _LeaderboardTab extends StatefulWidget {
  final AppStore store;
  final Assessment asm;
  final Portal portal;

  const _LeaderboardTab({
    required this.store,
    required this.asm,
    required this.portal,
  });

  @override
  State<_LeaderboardTab> createState() => _LeaderboardTabState();
}

class _LeaderboardTabState extends State<_LeaderboardTab> {
  @override
  void initState() {
    super.initState();
    widget.store.loadCohort(widget.asm.id);
  }

  /// The router reuses this State across assessments, so without this the
  /// second assessment would be ranked from the first one's cohort.
  @override
  void didUpdateWidget(_LeaderboardTab old) {
    super.didUpdateWidget(old);
    if (old.asm.id != widget.asm.id) {
      widget.store.loadCohort(widget.asm.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStore store = widget.store;
    final Assessment asm = widget.asm;

    final List<Attempt> ranked =
        store.cohortFor(asm.id).where((Attempt e) => e.resultsReleased).toList()
          ..sort(
            (Attempt a, Attempt b) =>
                b.earnedMarks(asm).compareTo(a.earnedMarks(asm)),
          );

    if (ranked.isEmpty) {
      if (store.cohortLoading) {
        return const EmptyLine('Loading the cohort...');
      }
      if (store.cohortError.isNotEmpty) {
        // SAYS SO, rather than rendering as "nobody has been released yet".
        // A failed read and an empty leaderboard look identical otherwise, and
        // one of them is a reason to retry.
        return Notice(
          tone: Tone.bad,
          strong: 'The cohort could not be read.',
          text: store.cohortError,
          actions: <Widget>[
            Btn(
              'Try again',
              size: BtnSize.sm,
              tooltip:
                  'Re-read this assessment\'s cohort so the ranking can be '
                  'built. Nothing is changed by retrying.',
              onPressed: () => store.loadCohort(asm.id),
            ),
          ],
        );
      }
      return const EmptyLine(
        'Nothing to rank yet. A result appears here once it has been released.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (store.cohortTruncated) ...<Widget>[
          const Notice(
            tone: Tone.warn,
            strong: 'This ranking is partial.',
            text:
                'The cohort is larger than this screen reads in one pass, so '
                'the rows below are the part it holds rather than the whole '
                'cohort.',
          ),
          const SizedBox(height: 10),
        ],
        for (int i = 0; i < ranked.length; i++)
          _LeaderRow(
            store: store,
            asm: asm,
            attempt: ranked[i],
            rank: i + 1,
            last: i == ranked.length - 1,
          ),
      ],
    );
  }
}

/// D1 - the internal remark on one sitting, READ AND WRITTEN from a list row.
///
/// ONE WIDGET FOR BOTH LISTS, for the reason [FlagToggle] gives for itself: the
/// Candidates roster and the Leaderboard are two views of the same attempt, and
/// a remark that could be typed from one but only read from the other is the
/// kind of difference that gets reported as one of the two being broken.
///
/// A COMMENT GLYPH IS DRAWN ON EVERY UNREMARKED ROW, not a blank cell. Blank is
/// quieter, and it also hides the only control this feature has: nobody clicks
/// what is not there, and "click the empty space under Remarks" is not an
/// affordance. It is muted, so a cohort of them still reads as empty at a
/// glance and the handful carrying real text still stand out.
///
/// [onEdit] is null for a rung that may READ a sitting but not write to it. A
/// Manager still sees the sentence - they are frequently the person asking why a
/// candidate is held - and gets no glyph and no tap, rather than a control whose
/// only outcome is a 403 after they have typed a paragraph.
class _RemarkCell extends StatelessWidget {
  const _RemarkCell({required this.flag, this.onEdit, this.dense = false});

  final CandidateFlag flag;

  /// Opens the sheet. Null = read-only, see the class note.
  final VoidCallback? onEdit;

  /// GLYPH ONLY, no text, for a row that has no width to give a sentence.
  ///
  /// The roster has a 210px column whose whole purpose is that the remark can
  /// be READ while scanning. The leaderboard row has a name, a split, a
  /// threshold bar, a mark and a verdict on it already, and it is intrinsically
  /// laid out - two lines of prose in it would push the ranking apart and make
  /// the rows different heights. So there the glyph only DISCLOSES that a remark
  /// exists (filled when it does, exactly as the flag beside it fills when
  /// raised) and the tooltip carries the words.
  ///
  /// It also keeps the glyph's width CONSTANT down the board: a cell that
  /// collapsed on unremarked rows would move the flag after it sideways row by
  /// row, which is the alignment the flag was made a trailing column to get.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool has = flag.hasRemark;

    final Widget glyph = Tooltip(
      message: has
          ? flag.remark
          : (onEdit == null
                ? 'No remark on this sitting'
                : 'Write an internal remark on this sitting'),
      child: Icon(
        has ? Icons.mode_comment : Icons.mode_comment_outlined,
        size: 16,
        // Accent when there is something to read, muted when the glyph is only
        // an invitation to write. NOT the flag's red: a remark is a note, and
        // colouring it like an alert would have operators reading every remarked
        // row as a problem.
        color: has ? t.primary : t.textMuted,
      ),
    );

    final Widget body = dense
        ? glyph
        : has
        ? Tooltip(
            message: flag.remark,
            // EXCLUDED FROM SEMANTICS, same reason `GridLink` excludes its own:
            // `Text` already reports the FULL string to the accessibility tree
            // whatever the visual crop, so a tooltip repeating it would have
            // every remark announced twice. The tooltip fixes a visual
            // truncation, not a semantic one.
            excludeFromSemantics: true,
            child: Text(
              flag.remark,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.type.bodySecondary,
            ),
          )
        : onEdit == null
        // Nothing to read and nothing to do: no glyph, and with no detector in
        // the way the cell stays part of the row's own tap target instead of a
        // dead strip through the middle of it.
        ? const SizedBox.shrink()
        : glyph;

    // CENTRED IN THE COLUMN, not left-aligned with the prose columns.
    //
    // The glyph is the whole cell on most rows - a 16px mark in a 136px
    // column - and hard against the left edge it read as a stray artefact of
    // the column beside it rather than as this column's own control. Centring
    // is what makes the header and the affordance line up as one thing. The
    // TEXT case is centred too, so a row with a remark and a row without do
    // not sit on different axes down the table.
    final Widget aligned = Align(alignment: Alignment.center, child: body);

    if (onEdit == null) return aligned;

    // SWALLOWED, the same way the flag beside it swallows its own tap: both
    // rows navigate to the attempt, and a click meant to open the remark sheet
    // must not also carry the operator off the page they are triaging. Opaque,
    // so the whole cell is the target rather than 16px of glyph inside it.
    //
    // ANNOUNCED AS A BUTTON, because a `Text` reports as static prose: without
    // this a screen-reader user is read the remark and never told it can be
    // written from here, which is the whole change. The label carries the verb
    // and the child still carries the words, as [FlagToggle] does.
    return Semantics(
      button: true,
      label: has ? 'Edit this remark' : 'Add a remark',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onEdit,
        child: MouseRegion(cursor: SystemMouseCursors.click, child: aligned),
      ),
    );
  }
}

/// One leaderboard row, and it OPENS THE ATTEMPT.
///
/// A ranked name used to be inert `Text`, while the same person one tab left on
/// Candidates was a link - so the leaderboard read as a dead end.
///
/// The hover tint and pointer are the DataGrid's, deliberately: the two lists
/// sit in the same tab strip, and an affordance that differs between them reads
/// as one of the rows being broken.
class _LeaderRow extends StatefulWidget {
  final AppStore store;
  final Assessment asm;
  final Attempt attempt;
  final int rank;
  final bool last;

  const _LeaderRow({
    required this.store,
    required this.asm,
    required this.attempt,
    required this.rank,
    required this.last,
  });

  @override
  State<_LeaderRow> createState() => _LeaderRowState();
}

class _LeaderRowState extends State<_LeaderRow> {
  bool _hover = false;

  /// The same write the roster's remark cell makes, from the other list.
  ///
  /// `remark:` ALONE, NEVER `flagged:`: the two are independent facts sharing
  /// one endpoint, and sending the flag state back with the prose would turn a
  /// colleague's concurrent toggle into a silent revert.
  Future<void> _editRemark(String name) async {
    final Attempt e = widget.attempt;
    final String? out = await askForRemark(
      context,
      candidateName: name,
      existing: e.candidateFlag.remark,
    );
    // null is CANCELLED, '' is "delete the remark" - see [askForRemark]. Folding
    // '' into null would make a remark impossible to remove; folding null into
    // '' would erase one whenever an operator backed out.
    if (out == null || !mounted) return;
    await widget.store.flagAttempt(e.id, remark: out);
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Attempt e = widget.attempt;
    final Assessment asm = widget.asm;

    // ONE READ OF THE GATE for both writes on this row - the same lifecycle
    // capability the Candidates tab uses, because these are the same two writes
    // on the same attempt reached from a different list. Null callbacks below
    // for a rung that may read the board but not write to it.
    final bool canWrite = widget.store.can(Capability.lifecycle);
    final VoidCallback? toggleFlag = canWrite
        ? () =>
              widget.store.flagAttempt(e.id, flagged: !e.candidateFlag.flagged)
        : null;
    // HOISTED: the row shows this name and the remark sheet titles itself with
    // it, and a sheet naming a different candidate from the row it opened from
    // reads as the wrong record being edited.
    final String name =
        widget.store.personById(e.employeeId)?.name ?? e.employeeId;

    final Widget body = Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: widget.last
            ? null
            : Border(bottom: BorderSide(color: t.borderSubtle)),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 20,
            child: Text('${widget.rank}', style: context.type.monoSmall),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // GridLink, not Text: the same cell the Candidates tab uses
                // for the same name, so the two tabs promise the same thing.
                //
                // JUST THE NAME. A "Flagged" word-badge used to sit beside it,
                // spending the width that IDENTIFIES the row on a fact the
                // glyph at the end of the same row already carries - and on a
                // board this narrow it pushed longer names into a second line
                // to say something twice. The flag is a column now, at the
                // right-hand end, where it lines up down the board and can be
                // clicked instead of only read.
                GridLink(name),
                // The objective / subjective split, as Odoo's card
                // shows it. One total cannot distinguish a genuinely
                // low score from one still waiting on the judge, and
                // that is the single most consequential thing an
                // operator reads off this row.
                if (e.hasSplit) ...<Widget>[
                  const SizedBox(height: 5),
                  _SplitChips(attempt: e),
                ],
              ],
            ),
          ),
          SizedBox(
            width: 180,
            child: ThresholdBar(
              earned: e.earnedMarks(asm),
              total: e.maxMarks(asm),
              threshold: asm.passThreshold,
              result: e.verdict(asm),
            ),
          ),
          const SizedBox(width: 14),
          Marks(e.earnedMarks(asm), e.maxMarks(asm)),
          const SizedBox(width: 14),
          Pill.state(e.verdict(asm)),
          const SizedBox(width: 14),
          // D1 - THE REMARK, as a glyph rather than as prose. An operator
          // triaging the top of a board is the same operator who wants to
          // record why the third name is being looked at, and sending them to
          // the Candidates tab to type it is the round trip that had remarks
          // going unwritten. `dense` because this row has no width for a
          // sentence: filled when there is one, with the words on hover, and
          // the Candidates tab is still where a remark is READ at a glance.
          _RemarkCell(
            flag: e.candidateFlag,
            dense: true,
            onEdit: canWrite ? () => _editRemark(name) : null,
          ),
          const SizedBox(width: 14),
          // D1 - the flag, LAST, and last is what makes it a column. The marks
          // and the result pill are intrinsically sized, so anything placed
          // after them would sit at a different offset on every row; the final
          // child's right edge IS the row's right edge, so the glyphs line up
          // down the board without a fixed-width box pretending to be a cell.
          // The remark glyph before it is a constant 16px wide for the same
          // reason - see `dense` on [_RemarkCell].
          //
          // Same swallow as the roster's - the whole row opens the attempt,
          // and a miss on a 17px glyph must not navigate away from the board
          // being triaged.
          toggleFlag == null
              ? FlagToggle(flag: e.candidateFlag)
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: toggleFlag,
                  child: FlagToggle(
                    flag: e.candidateFlag,
                    onToggle: toggleFlag,
                  ),
                ),
        ],
      ),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        // Opaque: the whole row is the target, not only the glyphs. The gaps
        // between the bar, the marks and the pill are most of its width.
        behavior: HitTestBehavior.opaque,
        onTap: () => context.nav.attempt(e.id),
        child: Stack(
          children: <Widget>[
            body,
            if (_hover)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(color: t.bgHover.o(t.hoverA)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The objective / subjective breakdown chips under a leaderboard name.
class _SplitChips extends StatelessWidget {
  final Attempt attempt;

  const _SplitChips({required this.attempt});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final TextStyle label = context.type.bodyMuted.copyWith(fontSize: 11);
    final TextStyle value = context.type.monoSmall.copyWith(fontSize: 11);

    Widget chip(IconData icon, String name, String v) => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 12, color: t.textMuted),
        const SizedBox(width: 4),
        Text(name, style: label),
        const SizedBox(width: 5),
        Text(v, style: value),
      ],
    );

    return Wrap(
      spacing: 14,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        if (attempt.objectiveMax != null)
          chip(
            Icons.check_box_outlined,
            'Objective',
            '${attempt.objectiveScore ?? 0} / ${attempt.objectiveMax}',
          ),
        if (attempt.subjectiveMax != null)
          chip(
            Icons.edit_outlined,
            'Subjective',
            '${attempt.subjectiveScore ?? 0} / ${attempt.subjectiveMax}',
          ),
        // Only worth saying when there IS something outstanding: a badge on
        // every row is wallpaper.
        if (attempt.subjectivePending > 0)
          StatusBadge('${attempt.subjectivePending} awaiting', Tone.warn),
        if (attempt.subjectiveState == LlmState.error)
          const StatusBadge('Scoring error', Tone.bad),
      ],
    );
  }
}

/// Which of the generator's questions this assessment actually draws.
///
/// THE TAB SHOWS THE CHOICE, NOT ONLY THE PICK. It used to list `asm.questions`,
/// which the server does not write until launch - so on a draft it read "No
/// questions were selected" over a generator holding twenty, and an operator had
/// no way to narrow a paper short of editing the generator itself. It now lists
/// `asm.pool` with each row ticked or not, and the ticks ARE the selection.
///
/// A TICK, NOT A CHECKBOX. The state being expressed is "this question is part
/// of the instrument", which is a property of the row and reads as one; a
/// checkbox gutter reads as a transient selection waiting for a bulk action, and
/// there is no bulk action here.
///
/// EDITABLE IN DRAFT ONLY. The server refuses `question_ids` outside draft
/// (`POST_DRAFT_FIELDS`) because the paper is what the candidates agreed to. The
/// ticks stay VISIBLE and go inert, because a launched assessment still has to
/// show which questions it was launched against.
class _QuestionsTab extends StatelessWidget {
  final AppStore store;
  final Assessment asm;

  const _QuestionsTab({required this.store, required this.asm});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    // TWO SEPARATE LOCKS, and they say different things. State is about the
    // record - a launched paper is frozen for everybody, including an Admin.
    // Capability is about the person - a read-only Manager may look at a draft
    // and change nothing on it.
    final bool draft = asm.state == AsmState.draft;
    final bool permitted = store.can(Capability.configure);
    final bool editable = draft && permitted;

    final int inUse = asm.inUseCount;
    final int total = asm.pool.length;
    final bool allInUse = total > 0 && inUse == total;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (!draft)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Notice(
              tone: Tone.inert,
              strong: 'The paper is fixed.',
              text:
                  'Ticked questions are the ones this paper draws. Unticked '
                  'ones were excluded before launch.',
            ),
          )
        else if (!permitted)
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Notice(
              tone: Tone.inert,
              strong: 'Read-only.',
              text: 'Only an Admin can change the shortlist.',
            ),
          ),
        if (total > 0) ...<Widget>[
          Row(
            children: <Widget>[
              const Eyebrow('Shortlist'),
              const SizedBox(width: 10),
              // THE COUNT IS THE POINT of this header: it is the size of the
              // paper about to be drawn, and it is what "Number of Questions"
              // on the Configuration tab is checked against at launch.
              Text('$inUse of $total in use', style: context.type.bodyMuted),
              // SAY WHAT THE TICKS DO, once, next to the count. A person landing
              // here for the first time has six ticked rows and no reason to
              // suspect they are controls; a header on the column names them and
              // this names their consequence. Draft only - on a launched paper
              // the "The paper is fixed" notice above has already said it.
              if (editable) ...<Widget>[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Ticked questions are the ones this assessment will draw.',
                    style: context.type.tiny,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else
                const Spacer(),
              if (editable)
                Btn(
                  allInUse ? 'Clear all but one' : 'Use all $total',
                  size: BtnSize.sm,
                  tooltip: allInUse
                      // Named honestly. An empty shortlist means "the whole
                      // generator" server-side, so "Clear all" would do the
                      // opposite of what it says; one has to stay.
                      ? 'Leave only the first question in use, then tick the '
                            'ones you want'
                      : 'Put every question in this generator back in use',
                  onPressed: () => store.setQuestionsInUse(
                    asm.id,
                    allInUse
                        ? <String>{asm.pool.first.id}
                        : asm.pool.map((Question q) => q.id).toSet(),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
        ],
        DataGrid(
          minWidth: 880,
          emptyMessage: draft
              ? 'Pick a question generator on the Configuration tab and this '
                    'tab will list the questions it can draw.'
              : 'No questions were selected for this assessment.',
          cols: const <Col>[
            // THE GUTTER IS LABELLED NOW. It was deliberately blank - "the
            // gutter carries a control, not data, and a header over it would
            // advertise an ordering that does not exist" - and an unlabelled
            // column of already-ticked glyphs is how this control came to be
            // invisible. "Include" names what the box does, in the imperative,
            // so the header reads as the question the column is asking.
            Col('Include', width: 74),
            Col('Question', flex: 3),
            Col('Type', width: 150),
            Col('Difficulty', width: 110),
            Col('Key', width: 90),
          ],
          rows: asm.pool.map((Question q) {
            final bool on = asm.inUseIds.contains(q.id);
            return GridRow(<Widget>[
              _InUseTick(
                on: on,
                enabled: editable,
                name: q.name,
                onToggle: () => store.toggleQuestionInUse(asm.id, q.id),
              ),
              // An excluded question is DIMMED rather than hidden: the operator
              // has to be able to see what they took out to put it back. It
              // stays a link either way - the preview is how you decide.
              on
                  ? GridLink(q.name)
                  : Text(
                      q.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.tableCell.copyWith(
                        color: t.textMuted,
                      ),
                    ),
              Text(q.taskLabelLong, style: context.type.bodySecondary),
              Text(q.difficulty.label, style: context.type.bodySecondary),
              q.hasCompleteKey
                  ? const Pill('Complete', Tone.ok)
                  : const Pill('Missing', Tone.bad),
            ], onTap: () => showQuestionPreview(context, store, q));
          }).toList(),
        ),
      ],
    );
  }
}

/// The in-use tick: a CHECKBOX, with a faint gold aura behind a ticked one.
///
/// IT USED TO BE A CHECK-CIRCLE AND NOBODY COULD FIND IT. The argument for the
/// circle was that "this question is part of the instrument" is a property of the
/// row and reads as one, whereas a checkbox gutter reads as a transient selection
/// waiting for a bulk action. Sound in the abstract, and wrong in front of a
/// person: reported verbatim as "I cannot see the mechanism to select/deselect
/// questions in Selected Questions".
///
/// Three things made it invisible at once. Every row arrives TICKED, so there was
/// no contrast anywhere on screen to suggest a toggle; the column had no header,
/// so nothing named what it was; and the editable and the frozen states drew the
/// SAME glyph in the same colour, so a launched paper looked exactly as clickable
/// as a draft. A checkbox needs none of that explained - and it is already the
/// glyph the sibling screen uses for the identical job (`new_assessment_screen`
/// picks questions with `check_box` / `check_box_outline_blank`), so the two
/// screens now agree instead of teaching two idioms for one action.
///
/// THE GOLD AURA STAYS, MINIMAL. It is what says "deliberately marked" rather
/// than "a status this row happens to have", and losing it would flatten the
/// shortlist into an ordinary multi-select. Turned right down on request: opacity
/// .55 -> .18, blur 10 -> 4, spread 1 -> 0, so it is a warmth behind the box
/// rather than a glow around it. Still a `BoxShadow` under the glyph, so it
/// cannot be mistaken for a badge and costs no layout.
class _InUseTick extends StatelessWidget {
  final bool on;
  final bool enabled;

  /// The question's name, for the tooltip - "Put X in use" beats "Toggle".
  final String name;
  final VoidCallback onToggle;

  const _InUseTick({
    required this.on,
    required this.enabled,
    required this.name,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    // AN EMPTY BOX IS THE WHOLE POINT of the unticked state: it is the one thing
    // on the row that says a tick is something a person puts there. The old
    // outlined circle read as a dimmer version of the same status.
    final IconData icon = on ? Icons.check_box : Icons.check_box_outline_blank;
    // TICKED IS GREEN-GOLD WHETHER OR NOT IT CAN BE EDITED. The frozen state
    // used to draw every box in muted grey, so a launched paper's ticks read as
    // disabled chrome and an included row looked much like an excluded one. What
    // freezing changes is whether the tick RESPONDS - the tooltip says so and
    // the gesture is gone - not what the paper contains, and this column is the
    // record of what it contains.
    final Color ink = on
        ? t.successDot
        : (enabled ? t.textSecondary : t.textMuted);
    final Widget glyph = DecoratedBox(
      decoration: BoxDecoration(
        // A rounded square, matching the glyph it sits behind. A circular shadow
        // under a square box bled out at the corners.
        borderRadius: BorderRadius.circular(4),
        boxShadow: on
            ? <BoxShadow>[
                // Subtle by instruction: a warmth behind the box, not a glow
                // around it. See the note on the class.
                BoxShadow(color: t.warnDot.o(.18), blurRadius: 4),
              ]
            : const <BoxShadow>[],
      ),
      child: Icon(icon, size: 19, color: ink),
    );

    // SEMANTICS FIRST: this is a two-state control, and a screen reader needs
    // to hear the state and be able to change it. `Icon` alone announces
    // nothing, so the tick would have been invisible to anybody not looking at
    // it.
    //
    // ANNOUNCED AS A CHECKBOX, not as a button: `inMutuallyExclusiveGroup` is
    // false and `checked` is set, which is what makes a screen reader say
    // "checkbox, checked" rather than reading the label and stopping. It matches
    // what the glyph now draws, and it is the one description that tells a
    // non-sighted operator the row can be turned off.
    final Widget labelled = Semantics(
      // THE LABEL CARRIES THE STATE, and used to be the constant
      // '$name included in this paper'. That was survivable while a launched
      // paper listed only the rows it draws, because the sentence was then
      // always true. It is not any more: the pool now lists what the operator
      // EXCLUDED as well, so half these rows are not included - and because
      // the frozen branch below wraps this in a Tooltip saying the opposite,
      // a screen reader read out "X is not part of this paper" immediately
      // followed by "X included in this paper" on the same row.
      //
      // Same wording as the tooltip on purpose, so the two can never disagree
      // again. `checked` still carries it independently for anything that
      // announces the role rather than the label.
      label: on
          ? '$name is part of this paper'
          : '$name is not part of this paper',
      checked: on,
      enabled: enabled,
      // `onTap` as well as the GestureDetector below: assistive technology
      // activates the SEMANTICS node, not the gesture, so without this the
      // control could be heard and not operated.
      onTap: enabled ? onToggle : null,
      child: ExcludeSemantics(child: glyph),
    );

    // BOTH TOOLTIPS ARE EXCLUDED FROM SEMANTICS. A Tooltip contributes its
    // message to the tree, so every one of these rows was announced twice -
    // see the same fix on the remark cell above. The label, the checkbox role
    // and `onTap` already say what this control is, whether it is set and
    // whether it can be changed; the tooltip is there for the pointer.
    if (!enabled) {
      return Tooltip(
        excludeFromSemantics: true,
        message: on
            ? '$name is part of this paper'
            : '$name is not part of this paper',
        child: labelled,
      );
    }
    return Tooltip(
      excludeFromSemantics: true,
      message: on ? 'Take $name out of this paper' : 'Put $name in this paper',
      // Swallows the tap so ticking a row does not ALSO open its preview -
      // the same reason DataGrid's own checkbox gutter does.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: MouseRegion(cursor: SystemMouseCursors.click, child: labelled),
      ),
    );
  }
}

/// The question preview sheet.
///
/// It renders the candidate's view with every control inert, and says so, so
/// nobody mistakes a preview for a live answer surface.
void showQuestionPreview(BuildContext context, AppStore store, Question q) {
  // Fetch the full record, THEN open the sheet.
  //
  // The list row carries 21 of the question's 31 fields; the missing ten are
  // the media, the dimensions and the answer key - everything a preview is
  // for. The sheet below builds from a captured `q`, so it cannot repaint
  // itself when a later fetch lands; the fetch has to finish first.
  //
  // A DRAFT is not in the bank, so it needs `/drafts/<id>` and
  // `anyQuestionById`. Hydrating via the bank route missed every draft: the
  // fetch found nothing, the lookup returned null, and the sheet fell back to
  // the thin list row - which is why a draft read "No image yet".
  //
  // The SAME discriminator has to pick the id space the hydrated record is
  // read back from. Draft ids and bank ids are independent sequences, so
  // asking for "question 12" without saying which model can return the other
  // model's row 12 - a preview of a question nobody clicked.
  final bool isDraft = q.state == DraftState.draft;
  final Future<void> hydrated = isDraft
      ? store.loadDraft(q.id)
      : store.loadQuestion(q.id);
  unawaited(
    hydrated.then((_) {
      if (!context.mounted) return;
      _openQuestionPreview(
        context,
        store,
        store.anyQuestionById(q.id, preferDraft: isDraft) ?? q,
      );
    }),
  );
}

void _openQuestionPreview(BuildContext context, AppStore store, Question q) {
  // A throwaway attempt so the read-only layout has a response to read from
  // without touching any real record.
  final Attempt scratch = Attempt(
    id: 'preview',
    assessmentId: '',
    employeeId: '',
    token: 'preview',
    resp: <String, Response>{q.id: Response.seed(q)},
  );

  showSheet<void>(
    context,
    wide: true,
    title: q.name,
    // WHERE IT CAME FROM, on the one surface that shows a question in full -
    // a reviewer judging an answer key could not otherwise check it against
    // the document that justified it without leaving the sheet.
    //
    // `genName` is the server's own spelling and survives the generator being
    // deleted only as `sourceRef`, so both are tried before giving up.
    sub: <String>[
      // The TASK the examiner named when a template authored this, else the
      // engine type. "Image · A/B evaluation" describes the renderer, not the
      // job, and misleads outright when the task is not an A/B comparison.
      q.taskLabelLong,
      if (q.genName.isNotEmpty)
        q.genName
      else if (q.sourceRef.isNotEmpty)
        q.sourceRef,
      if (q.retired)
        q.deleted ? 'Deleted from the bank' : 'Archived from the bank',
    ].join('  \u00b7  '),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // EDIT FROM WHERE THE PROBLEM IS VISIBLE: seeing the question as the
        // candidate will is exactly when a clumsy option or a wrong
        // correct-flag becomes obvious.
        //
        // A pencil, not a sentence - the sheet is already titled with the
        // question and subtitled with its type.
        // AUTHORING, not viewing. Everything in this row EDITS the
        // question - a task template, the marker geometry, the draft or
        // bank record itself - so it belongs to the authoring capability
        // even though it hangs off a screen a read-only Manager can open.
        // The preview itself stays: seeing the question as the candidate
        // will is exactly what a Manager is here for.
        // None for a deleted question: Deleted is final, nothing changes it.
        if (store.isLive &&
            store.can(Capability.authoring) &&
            !q.deleted) ...<Widget>[
          Row(
            children: <Widget>[
              const Spacer(),
              // TURN A GOOD QUESTION INTO A REUSABLE SHAPE, from the one
              // surface where the examiner has just judged it good.
              //
              // A generated question they approve of is the clearest possible
              // description of the shape they want more of - which is exactly
              // what a task template is - and retyping it by hand was the only
              // way to get there. `taskTemplateFromQuestion` maps it onto the
              // designer's own blocks and drops the answer key, because a
              // template is a shape and the key belongs to each generated
              // instance.
              //
              // Needs a generator to belong to: `generator_id` is
              // ondelete="set null", so a question whose generator is gone has
              // nowhere to put a template and the action stands down rather
              // than opening an editor that cannot save.
              if (q.genId.isNotEmpty)
                IconBtn(
                  Icons.dashboard_customize_outlined,
                  tooltip: 'Make a task template from this question',
                  onPressed: () {
                    Navigator.of(context).pop();
                    showToastedDialog<void>(
                      context,
                      builder: (BuildContext _) => TaskTemplateEditor(
                        store: store,
                        generatorId: q.genId,
                        template: taskTemplateFromQuestion(q),
                      ),
                    );
                  },
                ),
              // MOVE A BOX AND FIX A GOLDEN ANSWER, from the surface where the
              // wrong one is visible - tracker SNo 168.
              //
              // The annotation editor has always existed and worked; nothing
              // could OPEN a generated question in it, because the Studio
              // translation only ran designer -> question. An examiner looking
              // at a plate whose box 4 sits in the wrong place could read the
              // key and not touch it.
              //
              // BANK ONLY. A draft is `assessments.be.prompt.question`, a
              // different model with its own geometry fields, and
              // `/bank/<id>/studio_item` is keyed on the approved question - so
              // offering this on a draft would open an editor whose save is a
              // 404. The draft's own editor covers the text and the key.
              //
              // The question TYPE gates the offer; whether it actually has
              // markers is the server's answer (404 `not_annotatable`), because
              // the admin payload reduces detected geometry to bare numbers and
              // a client-side test would refuse exactly the Studio-published
              // questions this exists for.
              // APPROVED ONLY, as an allow-list. `state != draft` was not
              // enough: DraftState also has `denied`, and a denied draft is
              // still an `assessments.be.prompt.question` - a DIFFERENT model
              // with its own id sequence - so its id sent to
              // /api/v1/bank/<id>/studio_item addresses whatever bank question
              // happens to hold that number. Best case a 404; worst case the
              // examiner opens and edits the markers of an unrelated question.
              if (q.type == QType.imageLabel && q.state == DraftState.approved)
                IconBtn(
                  Icons.pin_drop_outlined,
                  tooltip: 'Edit the markers and golden answers',
                  onPressed: () async {
                    final Map<String, dynamic>? item =
                        await fetchAnnotationItem(store, q.id);
                    if (!context.mounted) return;
                    if (item == null) {
                      store.toaster.info(
                        'This question has no markers to edit yet. Run '
                        'detection on its image first.',
                      );
                      return;
                    }
                    Navigator.of(context).pop();
                    await showAnnotationEditor(context, store, q.id, item);
                  },
                ),
              IconBtn(
                Icons.edit_outlined,
                tooltip: q.state == DraftState.draft
                    ? 'Edit this draft'
                    : 'Edit this question',
                onPressed: () {
                  Navigator.of(context).pop();
                  if (q.state == DraftState.draft) {
                    showDraftEditor(context, store, q);
                  } else {
                    showBankEditor(context, store, q);
                  }
                },
              ),
            ],
          ),
        ],
        // WHAT ODOO'S FORM HEADER SAYS. The sheet named the type and the
        // generator and stopped, so the medium, the difficulty and the time
        // budget - all on the wire, all on the Odoo form - were invisible here.
        // The `sub:` line above is one joined string with no room for them.
        if (_identityChips(q).isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          Wrap(spacing: 6, runSpacing: 6, children: _identityChips(q)),
        ],
        // The server's own sentence about which media slot is missing.
        if (q.missingMediaWarning.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Notice(tone: Tone.warn, text: q.missingMediaWarning),
        ],
        const SizedBox(height: 14),
        const Eyebrow('Question 1'),
        const SizedBox(height: 8),
        Text(q.prompt, style: context.type.questionPrompt),
        // `questionDesc`, matching the candidate's own screen: the `AnswerArea`
        // below draws a scale's end labels on the control, so its legend line
        // would otherwise print those two words directly above themselves. This
        // panel exists to show the examiner what the candidate will see.
        if (questionDesc(q).isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(questionDesc(q), style: context.type.questionDesc),
        ],
        // NO SEPARATE STIMULUS. `AnswerArea` draws it.
        //
        // This block existed because mcq, msq and subjective_rubric once
        // rendered options with no picture above them - `layoutDrawsMedia`
        // named exactly those three. All three have since learned to draw
        // their own media, each guarded on the question actually having some
        // (see the `q.images.isNotEmpty || q.videos.isNotEmpty` branches in
        // `AnswerArea`, and `_RubricLayout`'s early return), which is the same
        // condition this block tested. So the preview drew the clip and then
        // the layout drew it again: a reviewer opening a video question saw
        // TWO players, and before the admin URL was fixed, two copies of "No
        // video yet for this question."
        //
        // Reported from a walkthrough on 2026-09-09 with 1 video row on the
        // record and 2 plates on screen.
        const SizedBox(height: 18),
        AnswerArea(store: store, ev: scratch, q: q, readOnly: true),
        const SizedBox(height: 18),
        // One renderer, shared with the review queue - see AnswerKeyView. This
        // used to be a private copy that printed a comma-joined line and, when
        // `dims` was empty, printed nothing at all: a draft whose key the
        // server had sent in full showed an empty panel.
        Panel(
          title: 'Answer Key',
          child: AnswerKeyView(store: store, question: q),
        ),
        // The labelled marking guide, for a type whose key IS options - where
        // AnswerKeyView renders chips and would otherwise drop it.
        if (q.type.hasOptionKey && q.answerKey.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          Panel(
            title: 'Marking Guide',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final (String, List<String>) s in q.answerKey.sections)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 11),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Eyebrow(s.$1),
                        const SizedBox(height: 4),
                        for (final String line in s.$2)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              line,
                              style: context.type.body.copyWith(height: 1.5),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (q.coversElements.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          const Eyebrow('Covers'),
          const SizedBox(height: 5),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final String e in q.coversElements)
                StatusBadge(e, Tone.inert),
            ],
          ),
        ],
        // THE RATIONALE SITS WITH THE KEY, unfolded. On an image_ab question
        // this field IS the grading standard - the candidate's written
        // justification is marked against it - so a reviewer signing off the
        // key while it was hidden behind a disclosure was signing off half of
        // what they were approving. The verbose half (the golden answer and
        // how it is known) stays folded; that is reference, not the decision.
        if (q.officialReasoning.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          // Odoo's own label for this field, kept verbatim so the two screens
          // name the same thing the same way.
          const Eyebrow('Answer rationale (hidden from candidate)'),
          const SizedBox(height: 4),
          Text(
            q.officialReasoning,
            style: context.type.bodySecondary.copyWith(height: 1.6),
          ),
        ],
        if (q.solution.isNotEmpty ||
            q.solutionRationale.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          Disclosure(
            showLabel: 'Show the golden answer',
            builder: (BuildContext context) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (q.solution.isNotEmpty) ...<Widget>[
                  const Eyebrow('Golden answer'),
                  const SizedBox(height: 4),
                  for (final String line in q.solution)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        line,
                        style: context.type.bodySecondary.copyWith(height: 1.6),
                      ),
                    ),
                ],
                if (q.solutionRationale.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  const Eyebrow('How the golden answer is known'),
                  const SizedBox(height: 4),
                  Text(
                    q.solutionRationale,
                    style: context.type.bodySecondary.copyWith(height: 1.6),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (q.warnings.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          for (final QualityWarning w in q.warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Notice(
                tone: w.blocking ? Tone.bad : Tone.warn,
                strong: w.title,
                text: w.detail,
              ),
            ),
          // THE WAY OUT, on the surface that states the problem.
          //
          // The generator's Drafts tab sends a refused approval here, and until
          // now this sheet printed the warnings read-only and offered Close -
          // so a flagged draft could be inspected and never decided. The gate
          // and the decision both belong where the reviewer is already reading
          // why the draft was held.
          //
          // ListenableBuilder because the sheet is built once from a captured
          // `q`: `toggleAck` notifies the store, and without this the tick
          // would not paint and Approve would stay disabled.
          // The review-queue approval gate, embedded in this sheet.
          // Acknowledging a blocking warning is a decision about whether
          // a draft may enter the bank, which is authoring.
          if (q.state == DraftState.draft &&
              q.blockingWarnings.isNotEmpty &&
              store.can(Capability.authoring))
            ListenableBuilder(
              listenable: store,
              builder: (BuildContext context, _) => AckBox(
                checked: store.acknowledged.contains(q.id),
                count: q.blockingWarnings.length,
                onToggle: () => store.toggleAck(q.id),
              ),
            ),
        ],
        // Odoo's "Advanced (raw JSON)" tab. Folded, and last, because it is
        // diagnostic rather than decisive - but present, because until now the
        // only way to see any of it was to open the Odoo back office.
        // The generator's raw output. A Generators surface reached from an
        // Assessments screen, so it follows the authoring capability
        // rather than the screen it happens to be folded into.
        if (store.can(Capability.authoring) &&
            (q.advanced.isNotEmpty ||
                q.imageBriefs.isNotEmpty ||
                q.videoBriefs.isNotEmpty)) ...<Widget>[
          const SizedBox(height: 14),
          Disclosure(
            showLabel: 'Show advanced (raw generator output)',
            builder: (BuildContext context) => _AdvancedBlock(q: q),
          ),
        ],
      ],
    ),
    actions: <Widget>[
      // Media authoring, offered only where the module accepts it: detection
      // and DOM capture apply to a labelling stimulus, a clip to a video
      // question. Showing them everywhere would offer an operator a button
      // that can only ever refuse.
      // AUTHORING, ALL OF IT. Detect / Capture / Upload rewrite the
      // question's stimulus, and Deny / Approve into Bank are the review
      // queue's own decision - the one human gate in the pipeline. A
      // read-only Manager sees the sheet and none of these.
      if (q.type == QType.imageLabel &&
          store.can(Capability.authoring)) ...<Widget>[
        Btn(
          'Detect Now',
          tooltip:
              'Ask the model to find the elements in this image and place '
              'the numbered boxes a candidate will label. Costs an LLM '
              'call, and replaces the boxes currently on it.',
          icon: Icons.center_focus_strong_outlined,
          onPressed: () {
            Navigator.of(context).pop();
            store.detectNow(q.id);
          },
        ),
        Btn(
          'Capture URL',
          tooltip:
              'Render the page at this address and use the screenshot as '
              'the stimulus.',
          icon: Icons.travel_explore_outlined,
          onPressed: () {
            Navigator.of(context).pop();
            _showCaptureSheet(context, store, q);
          },
        ),
      ],
      if (q.type == QType.videoPrompt && store.can(Capability.authoring))
        Btn(
          'Upload Clip',
          tooltip:
              'Attach a video yourself instead of generating one. Use this '
              'when Veo is unconfigured, or when the clip has to be real '
              'footage.',
          icon: Icons.movie_outlined,
          onPressed: () {
            Navigator.of(context).pop();
            unawaited(_pickAndApplyVideo(store, q));
          },
        ),
      // DECIDE FROM HERE, for a DRAFT only - a bank question is already past
      // this gate and has no decision left to make.
      //
      // These two are what make the Drafts-tab tick completable: that tick
      // routes through `decideDraft`, which refuses a flagged draft and opens
      // this sheet, and the sheet had nothing to offer but Close.
      if (q.state == DraftState.draft &&
          store.can(Capability.authoring)) ...<Widget>[
        Btn.danger(
          'Deny',
          tooltip:
              'Reject this draft so it is never offered again. The generator '
              'keeps its record of having produced it.',
          onPressed: () {
            Navigator.of(context).pop();
            store.decideDraft(q.id, DraftState.denied);
          },
        ),
        ListenableBuilder(
          listenable: store,
          builder: (BuildContext context, _) {
            final bool canApprove =
                q.blockingWarnings.isEmpty || store.acknowledged.contains(q.id);
            return Btn.primary(
              'Approve into Bank',
              tooltip: canApprove
                  ? 'Move this draft into the bank, where an assessment can '
                        'draw it. Nothing reaches a candidate before this - it '
                        'is the one human gate in the pipeline.'
                  : 'Tick the acknowledgement above first. The server refuses '
                        'a draft with unacknowledged warnings, so this would '
                        'fail.',
              // Disabled here AND refused in the store, which is also what
              // sends the acknowledgement to the server.
              onPressed: canApprove
                  ? () {
                      // Pop only when the decision was ACCEPTED. `decideDraft`
                      // returns the id when it refuses, and closing the sheet
                      // on a refusal would hide the reason.
                      if (store.decideDraft(q.id, DraftState.approved) ==
                          null) {
                        Navigator.of(context).pop();
                      }
                    }
                  : null,
            );
          },
        ),
      ],
      Btn('Close', onPressed: () => Navigator.of(context).pop()),
    ],
  );
}

/// The taxonomy strip: what Odoo's form header states about this question.
///
/// Every chip is omitted when its value is empty, so a plain text mcq keeps the
/// sheet as short as it was and only a fully-populated draft grows.
List<Widget> _identityChips(Question q) => <Widget>[
  StatusBadge(q.taskLabelLong, Tone.inert),
  if (q.medium.isNotEmpty) StatusBadge(q.mediumLabel, Tone.inert),
  StatusBadge(q.difficulty.label, Tone.inert),
  if (q.timeMinutes > 0) StatusBadge('${q.timeMinutes} min', Tone.inert),
  if (q.generationStatus.isNotEmpty)
    StatusBadge(q.generationStatus, Tone.inert),
  if (q.genBatchLabel.isNotEmpty) StatusBadge(q.genBatchLabel, Tone.inert),
  if (q.detectionMode.isNotEmpty)
    StatusBadge('Detects ${q.detectionMode}', Tone.inert),
  if (q.usedIn > 0) StatusBadge('Used in ${q.usedIn}', Tone.inert),
  if (q.retired) StatusBadge(q.deleted ? 'Deleted' : 'Archived', Tone.warn),
  // THE SKILLS IT COVERS, in the accent the vocabulary uses everywhere else.
  //
  // `Question.tags` has been parsed all along and the server sent nothing to
  // put in it: the vocabulary stopped at the generator, so a bank of a
  // hundred questions inherited none of the skills its own SOP was read for.
  // "Backfill onto questions" is what fills these in.
  for (final String tag in q.tags) StatusBadge(tag, Tone.accent),
];

/// The generator's raw output, pretty-printed.
///
/// Deliberately not modelled field by field: these are pipeline artefacts whose
/// shape belongs to the generator, and this app only needs to DISPLAY them. The
/// whole record is dumped through `toJson`, which is also what keeps that
/// method honest - a field missing from it is now visibly missing here.
class _AdvancedBlock extends StatelessWidget {
  final Question q;

  const _AdvancedBlock({required this.q});

  @override
  Widget build(BuildContext context) {
    const JsonEncoder enc = JsonEncoder.withIndent('  ');
    String pretty(Object? v) {
      try {
        return enc.convert(v);
      } catch (_) {
        return '$v';
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final String brief in <String>[...q.imageBriefs, ...q.videoBriefs])
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              brief,
              style: context.type.bodySecondary.copyWith(height: 1.5),
            ),
          ),
        for (final MapEntry<String, dynamic> e in q.advanced.entries)
          if (e.value != null && '${e.value}'.isNotEmpty && e.value != '')
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Eyebrow(e.key.replaceAll('_', ' ')),
                  const SizedBox(height: 4),
                  SelectableText(
                    pretty(e.value),
                    style: context.type.monoSmall.copyWith(height: 1.5),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 10),
        const Eyebrow('The whole record'),
        const SizedBox(height: 4),
        SelectableText(
          pretty(q.toJson()),
          style: context.type.monoSmall.copyWith(height: 1.5),
        ),
      ],
    );
  }
}

/// Ask for the page to capture, then capture it.
///
/// The URL is asked for rather than assumed: the module refuses a capture
/// with no `source_url`, and the refusal is far more useful as a field than
/// as a toast after the fact.
void _showCaptureSheet(BuildContext context, AppStore store, Question q) {
  String url = '';
  showSheet<void>(
    context,
    title: 'Capture a Live Page',
    sub: 'The rendered DOM becomes this question\u2019s stimulus.',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Notice(
          tone: Tone.info,
          strong: 'The page is captured server-side.',
          text:
              'It replaces the current stimulus for this question. Detection '
              'runs separately, once the screenshot exists.',
        ),
        const SizedBox(height: 14),
        Field(
          label: 'Source URL',
          child: TextField(
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'https://example.com/app/screen',
            ),
            onChanged: (String v) => url = v,
          ),
        ),
      ],
    ),
    actions: <Widget>[
      Btn('Cancel', onPressed: () => Navigator.of(context).pop()),
      Btn.primary(
        'Capture',
        onPressed: () {
          Navigator.of(context).pop();
          store.captureUrl(q.id, sourceUrl: url.trim());
        },
      ),
    ],
  );
}

/// Pick a clip off disk and attach it to the question.
Future<void> _pickAndApplyVideo(AppStore store, Question q) async {
  final PickedFile? file = await pickFile(accept: 'video/*');
  if (file == null) return;
  await store.applyVideo(q.id, bytes: file.bytes, filename: file.name);
}

/// The sheet in front of archiving a paper people are SITTING.
///
/// TOP LEVEL, because two screens ask the same question: the detail header's
/// Archive button and the row control on the assessments list. The list has no
/// roster in hand at all, so the number it quotes can only be the one the route
/// refused over - which is why this takes a count rather than finding one.
///
/// It answers the two questions that decide whether this was a mistake: what
/// happens to their clock now, and what happens to it on the way back. The
/// answer is that archiving suspends only the closed-tab expiry sweep - it
/// neither ends nor pauses the exam itself,
/// and that restoring lets the attempts whose time ran out meanwhile
/// auto-submit exactly as they would have. No deadline is moved in either
/// direction - saying so is the point, because "suspend" invites the reader to
/// assume the time is given back.
Future<bool> confirmArchiveLiveSitting(BuildContext context, int live) async {
  final bool? go = await showSheet<bool>(
    context,
    title: 'Archive while $live candidate(s) are sitting?',
    sub: 'This is almost always a mistake. Nothing is destroyed either way.',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // ARCHIVING DOES NOT PAUSE A SITTING, and this is the sentence an
        // operator actually reads before deciding. It used to say the clock
        // stopped, which is how somebody came to read a warning as a pause and
        // confirm it. `deadline_datetime` is `started_at + duration_minutes`,
        // an absolute instant archiving never touches, and no candidate route
        // gates on `active` - so the paper stays sittable and
        // `/api/v1/exam/<token>/answer` still submits each candidate at their
        // ORIGINAL deadline. Kept word-for-word in step with
        // `_live_attempt_refusal` in controllers/api/write.py, which refuses
        // this same act on the server: two descriptions of one behaviour.
        Notice(
          tone: Tone.bad,
          strong: 'Their clock keeps running.',
          text:
              '$live candidate(s) are mid-sitting. Archiving does not pause '
              'an exam and gives nobody time back - the paper stays sittable, '
              'and each candidate is still submitted at their original '
              'deadline. The one thing it suspends is the sweep that submits '
              'for somebody who closed their tab.',
        ),
        const SizedBox(height: 12),
        const Notice(
          tone: Tone.info,
          strong: 'Restoring re-arms that sweep.',
          text:
              'When you restore it, every attempt whose deadline passed '
              'while it was archived auto-submits on the next sweep, with '
              'whatever was answered. No deadline is shifted forward.',
        ),
        const SizedBox(height: 12),
        const Notice(
          tone: Tone.ok,
          strong: 'Nothing is lost.',
          text:
              'Answers, scores and queued grading are left exactly as they '
              'are and carry on from there when the paper comes back.',
        ),
      ],
    ),
    actions: <Widget>[
      Btn(
        'Leave It Running',
        tooltip:
            'Change nothing. The paper stays live, every clock keeps '
            'running and nothing is sent to the server.',
        size: BtnSize.lg,
        onPressed: () => Navigator.of(context).pop(false),
      ),
      Btn.danger(
        'Archive Anyway',
        tooltip:
            'Suspend the paper now. Everyone mid-sitting stops where they '
            'are, and restoring it lets the overdue attempts auto-submit.',
        size: BtnSize.lg,
        onPressed: () => Navigator.of(context).pop(true),
      ),
    ],
  );
  return go == true;
}
