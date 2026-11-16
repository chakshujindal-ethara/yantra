import 'dart:math' as math;

// Pod Member: my performance - a pass rate and a marks ring, four KPI cards,
// and a per-assessment breakdown.
//
// Invariant 3 governs the whole screen. `resultsReleased` is the only thing
// that admits a sitting to a figure: an unreleased attempt contributes to no
// ring, no total and no KPI, and appears in the breakdown wearing a status
// pill and nothing else. The gate is read as `ev.resultsReleased`, the same
// expression `my_assessments_screen.dart` uses, so there is one rule and one
// spelling of it.
//
// Invariant 2 holds too: every number a candidate sees here is MARKS. The
// internal percentage is used for ordering only ("best"), never rendered.
import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../domain/category_scores.dart';
import '../../nav.dart';
import '../../state/app_store.dart';
import '../../theme.dart';
import '../../widgets/buttons.dart';
import '../../widgets/category_card.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/charts.dart';
import '../../widgets/panel.dart';
import '../exam/exam_screen.dart';

/// One sitting: the candidate's attempt and the assessment it belongs to.
/// Spelled as a record to match the two neighbouring candidate screens.
typedef _Sitting = ({Attempt ev, Assessment? asm});

/// Marks earned on a sitting: the server's figure when it sent one, else the
/// per-response recomputation. Both are the same number by construction; only
/// their availability differs by endpoint.
int _earned(_Sitting r) =>
    r.ev.serverEarned ?? (r.asm == null ? 0 : r.ev.earnedMarks(r.asm!));

/// Marks available on a sitting, from whichever source knows.
///
/// `maxMarks` rather than the question count: a question is worth its
/// COMPONENT count now - one mark per keyed sub-question, one for a graded
/// write-up - so a paper of eight questions can be a paper of fourteen marks.
/// It reads the same `serverTotal` first, so the live path is unchanged; what
/// changes is the fallback a seeded or unreleased sitting lands on.
int _total(_Sitting r) =>
    r.ev.serverTotal ?? (r.asm == null ? 0 : r.ev.maxMarks(r.asm!));

/// Pass, fail or pending for a sitting, as the SERVER decided it.
///
/// `Attempt.verdict` recomputes only when no verdict was sent. Choosing the
/// source by whether `asm` is loaded - as this did - made the verdict flip
/// between refreshes, because a candidate acquires a threshold-less assessment
/// the moment they open the exam route.
ResultState _verdict(_Sitting r) => r.ev.verdict(r.asm);

/// Ratio used ONLY to rank sittings against each other, never displayed.
/// Assessments differ in length, so marks alone are not comparable.
double _ratio(_Sitting r) {
  final int t = _total(r);
  return t == 0 ? 0 : _earned(r) / t;
}

/// The assessment's name, from whichever source carries it.
String _asmName(_Sitting r) =>
    r.asm?.name ??
    (r.ev.assessmentName.isEmpty ? 'Assessment' : r.ev.assessmentName);

/// Everything this screen renders, derived once.
///
/// A value type rather than a pile of locals in `build` so the richer
/// `/api/v1/me/analytics` payload can land as a second factory here and reach
/// the widgets unchanged - they read fields, not a store. The release gate
/// then stays in ONE place for both sources.
class _Performance {
  /// Every submitted sitting, released or not. Only its COUNT and its status
  /// are safe to show.
  final List<_Sitting> completed;

  /// The released subset. Every figure on the screen is computed from this
  /// list alone.
  final List<_Sitting> released;

  final int passed;
  final int earnedMarks;
  final int availableMarks;
  final _Sitting? best;

  const _Performance({
    required this.completed,
    required this.released,
    required this.passed,
    required this.earnedMarks,
    required this.availableMarks,
    required this.best,
  });

  int get awaiting => completed.length - released.length;

  /// One aggregate verdict, colouring both rings.
  ///
  /// `pass` only when every released sitting passed, `fail` only when none
  /// did. The domain defines a pass threshold per assessment and none across a
  /// candidate's history, so a mixed record has no verdict to claim and stays
  /// neutral rather than inventing one. An empty record is neutral too: green
  /// would be claiming something is in good order when nothing has happened.
  ResultState get verdict {
    if (released.isEmpty) return ResultState.pending;
    if (passed == released.length) return ResultState.pass;
    if (passed == 0) return ResultState.fail;
    return ResultState.pending;
  }

  /// [personId] is whose page this is. A candidate passes their own id; an
  /// operator opening this from the leaderboard passes somebody else's.
  ///
  /// `attemptsByCandidate` and NOT `attemptsForPerson`: the latter also
  /// matches an attempt whose `employeeId` is empty, which is right only on a
  /// candidate's self-scoped store, where `/api/v1/me/assessments` omits the
  /// candidate object because the endpoint is already scoped to them. On an
  /// operator's store every attempt carries a real id, so that loose match
  /// would fold unrelated people into this person's totals.
  factory _Performance.fromStore(AppStore s, String personId) {
    final List<_Sitting> completed = <_Sitting>[];
    final bool isSelf = personId == s.meId;
    final List<Attempt> mine = isSelf
        ? s.attemptsForPerson(personId)
        : s.attemptsByCandidate(personId);
    for (final Attempt ev in mine) {
      if (!ev.isDone) continue;
      // A candidate never loads the assessment LIST (it is a manager route),
      // so `asm` is normally null on this screen. Skipping on null hid every
      // released result behind "nothing yet"; the marks come from the server
      // instead, via `_earned`/`_total` below.
      completed.add((ev: ev, asm: s.asmById(ev.assessmentId)));
    }
    // Newest first: the sitting a candidate just submitted is the one they
    // came to look for.
    completed.sort((_Sitting a, _Sitting b) {
      final DateTime? x = a.ev.submittedAt;
      final DateTime? y = b.ev.submittedAt;
      if (x == null && y == null) return 0;
      if (x == null) return 1;
      if (y == null) return -1;
      return y.compareTo(x);
    });

    // THE GATE. Every aggregate below reads `released`, never `completed`.
    final List<_Sitting> released = completed
        .where((_Sitting r) => r.ev.resultsReleased)
        .toList();

    int passed = 0;
    int earned = 0;
    int available = 0;
    _Sitting? best;
    for (final _Sitting r in released) {
      if (_verdict(r) == ResultState.pass) passed++;
      earned += _earned(r);
      available += _total(r);
      // Ranked on the internal percentage because assessments differ in
      // length; the winner is then SHOWN as its own marks.
      if (best == null || _ratio(r) > _ratio(best)) {
        best = r;
      }
    }

    return _Performance(
      completed: completed,
      released: released,
      passed: passed,
      earnedMarks: earned,
      availableMarks: available,
      best: best,
    );
  }
}

/// My performance: pass rate, marks and a per-assessment breakdown.
class MyPerformanceScreen extends StatefulWidget {
  final AppStore store;

  /// Whose performance. Null means the signed-in user, which is the candidate's
  /// own page and the behaviour this screen has always had. An operator reaches
  /// it with somebody else's id from the dashboard leaderboard.
  ///
  /// The RELEASE GATE IS KEPT on the totals either way: this is the
  /// candidate's own view, so an unreleased sitting is excluded from them for
  /// the operator too. Only the breakdown rows show an operator a held mark.
  final String? personId;

  const MyPerformanceScreen({super.key, required this.store, this.personId});

  @override
  State<MyPerformanceScreen> createState() => _MyPerformanceScreenState();
}

class _MyPerformanceScreenState extends State<MyPerformanceScreen> {
  /// Attempts already asked for, so a rebuild does not re-request them.
  final Set<String> _hydrated = <String>{};

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreChanged);
    // After the first frame, not during it - same reason as `_onStoreChanged`.
    WidgetsBinding.instance.addPostFrameCallback((_) => _hydrateReleased());
  }

  @override
  void didUpdateWidget(MyPerformanceScreen old) {
    super.didUpdateWidget(old);
    if (old.store != widget.store) {
      old.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
    }
    if (old.personId != widget.personId) {
      // A different person's sittings are a different set to fetch.
      _hydrated.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) => _hydrateReleased());
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    super.dispose();
  }

  /// Fetch the per-answer detail for each released sitting.
  ///
  /// WHY THIS IS NEEDED AT ALL. This screen is fed by a LIST route, and a list
  /// row carries no answers - so `attempt.resp` is empty and the category
  /// breakdown has nothing to group. Everything else here works off the server's
  /// pre-computed totals (`score_marks`), which is why the gap was invisible
  /// until categories needed per-answer marks.
  ///
  /// TWO ROUTES, BECAUSE THE TWO AUDIENCES ARE ALLOWED DIFFERENT THINGS:
  ///
  ///  - an OPERATOR (arrived from a leaderboard row) may call
  ///    `/api/v1/attempts/<id>`, so their sittings hydrate into `attempt.resp`
  ///    and the card is built from `answersOf`.
  ///  - a CANDIDATE may NOT - that route 403s for them by design. But their own
  ///    list carries a TOKEN per sitting, and `/api/v1/exam/<token>/answers` is
  ///    theirs, so their sittings are fetched as answer SHEETS and the card is
  ///    built from `answersOfSheet`. Same maths either way; only the source
  ///    differs.
  ///
  /// An earlier version called the manager route for everyone, which fired a
  /// forbidden request per sitting on the candidate's own page - caught by a
  /// pre-existing test as a pending timer after teardown.
  ///
  /// RELEASED ONLY: an unreleased sitting shows no marks on this screen anyway.
  ///
  /// NEVER CALLED FROM `build`. Both loaders end in `notifyListeners`, and a
  /// notify while the tree is building throws "setState() or markNeedsBuild()
  /// called during build".
  void _hydrateReleased() {
    if (!mounted) return;
    final AppStore store = widget.store;
    final String who = widget.personId ?? store.meId;
    final bool isSelf = who == store.meId;
    final _Performance p = _Performance.fromStore(store, who);

    for (final _Sitting r in p.released) {
      if (isSelf) {
        // The candidate's own path: by token, through the route they may call.
        final String token = r.ev.token;
        if (token.isEmpty || store.sheetByToken.containsKey(token)) continue;
        if (!_hydrated.add('sheet:$token')) continue;
        store.loadAnswerSheet(token);
      } else {
        // `resp` non-empty means the detail route already ran for this attempt.
        if (r.ev.resp.isNotEmpty || !_hydrated.add('attempt:${r.ev.id}')) {
          continue;
        }
        store.loadAttempt(r.ev.id);
      }
    }
  }

  /// Re-check after every store change, OUTSIDE the build phase.
  ///
  /// The attempts list usually resolves after this screen mounts, so the first
  /// pass in `initState` sees nothing to fetch. Deferring to the end of the
  /// frame keeps the fetch off the build phase.
  void _onStoreChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _hydrateReleased());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (BuildContext context, _) {
      final AppStore store = widget.store;
      final String? personId = widget.personId;
      final String who = personId ?? store.meId;
      final bool isSelf = who == store.meId;
      final String name = store.personById(who)?.name ?? '';
      final _Performance p = _Performance.fromStore(store, who);
      // "Marked" only when it is. An operator's roster carries each sitting's
      // ungraded count; a candidate's own unreleased rows carry none.
      final bool marked =
          !isSelf &&
          p.completed.every((_Sitting r) => r.ev.subjectivePending == 0);

      return PageBody(
        children: <Widget>[
          PageHead(
            isSelf
                ? 'My Performance'
                : (name.isEmpty ? 'Candidate Performance' : name),
            sub: isSelf
                ? 'How your released results add up. '
                      'Nothing appears here before an administrator '
                      'releases it.'
                : 'How this candidate\'s released results add up - the same '
                      'page they see. Unreleased sittings are not counted '
                      'here.',
          ),
          if (p.completed.isEmpty)
            Panel(child: _NothingYet(isSelf: isSelf))
          else ...<Widget>[
            _kpis(context, p, isSelf),
            if (p.awaiting > 0) ...<Widget>[
              _heldNotice(p, isSelf),
              const SizedBox(height: 16),
            ],
            Stack16(<Widget>[
              Panel(
                title: 'Pass Rate and Marks',
                note: 'Released results only.',
                child: p.released.isEmpty
                    ? EmptyState(
                        icon: Icons.schedule_outlined,
                        title: 'No results released yet',
                        body: isSelf
                            ? 'Your answers are recorded. These figures '
                                  'fill in the moment an administrator '
                                  'releases them.'
                            : 'This candidate\'s answers are recorded'
                                  '${marked ? ' and marked' : ''}. These '
                                  'figures fill in the moment an '
                                  'administrator releases them.',
                      )
                    : _Rings(p),
              ),
              Panel(
                title: 'Score Breakdown',
                note: isSelf
                    ? 'One row per assessment you have submitted.'
                    : 'One row per submitted assessment. Open one for the '
                          'full attempt.',
                flush: true,
                child: _breakdown(context, p, isSelf),
              ),
              // Marks over time. The table above answers "what did I get
              // on each one"; only a trend answers "am I improving",
              // which is the question a candidate actually has.
              if (p.released.length >= 2)
                Panel(
                  title: isSelf ? 'Your marks over time' : 'Marks over time',
                  note: 'released sittings, oldest first',
                  child: _Trend(p: p),
                ),
              // TIME, ON ITS OWN, WITH THE DISCLAIMER ATTACHED.
              //
              // Every other figure on this screen feeds a result, so a number
              // in the same visual language reads as one too. The spec asks for
              // "a clear note that time is not evaluated", and the honest place
              // for it is beside the number rather than in a legend somewhere
              // else. No cohort comparison here: Pace is admin-side, because
              // being told you were slower than your peers is not something a
              // candidate can act on.
              if (_timedSittings(p).isNotEmpty)
                Panel(
                  title: 'Time Taken',
                  note: isSelf
                      ? 'not evaluated - your time is never scored'
                      : 'not evaluated - time is never scored',
                  flush: true,
                  child: _TimeTaken(rows: _timedSittings(p), isSelf: isSelf),
                ),
              // Category breakdown, scoped to a single test - which is why it
              // is per-sitting rather than one all-up chart. The same four
              // categories the admin reads for the cohort, so a candidate and
              // their trainer are looking at the same words.
              ..._categoryPanels(context, p, isSelf),
            ]),
          ],
        ],
      );
    },
  );

  Widget _kpis(BuildContext context, _Performance p, bool isSelf) {
    final AppTokens t = context.tokens;
    // A local, so the null check promotes and the marks below cannot be read
    // off a null best.
    final _Sitting? best = p.best;
    final bool bestPassed = best != null && _verdict(best) == ResultState.pass;

    return KpiStrip(<Widget>[
      Kpi(
        label: 'Best result',
        // Marks, never a percentage - and only ever from a RELEASED sitting,
        // since `best` is chosen out of the released list.
        value: best == null ? '-' : '${_earned(best)} / ${_total(best)}',
        sub: best == null ? 'Nothing released yet' : _asmName(best),
        // Green states that something is in good order, so it needs a real
        // pass behind it - not merely a number in the slot.
        valueColor: bestPassed ? t.successText : null,
      ),
      Kpi(
        label: 'Passed',
        value: '${p.passed}',
        sub: 'of ${p.released.length} released',
        valueColor: p.passed > 0 ? t.successText : null,
      ),
      Kpi(
        label: 'Completed',
        value: '${p.completed.length}',
        sub: isSelf ? 'Sittings you submitted' : 'Sittings submitted',
      ),
      Kpi(
        label: 'Awaiting release',
        value: '${p.awaiting}',
        sub: 'Held until released',
        valueColor: p.awaiting > 0 ? t.warnText : null,
      ),
    ]);
  }

  /// Why a figure may look lower than the candidate expects. Inert, because a
  /// held result is the normal course of things and not a fault.
  Widget _heldNotice(_Performance p, bool isSelf) => Notice(
    tone: Tone.inert,
    strong: p.awaiting == 1
        ? (isSelf
              ? '1 of your results is still held.'
              : '1 of these results is still held.')
        : (isSelf
              ? '${p.awaiting} of your results are still held.'
              : '${p.awaiting} of these results are still held.'),
    text: isSelf
        ? 'Held sittings count towards nothing above. They join your pass '
              'rate and your marks as soon as an administrator releases them.'
        : 'Held sittings count towards nothing above. They join the figures '
              'above as soon as an administrator releases them.',
  );

  /// The sittings whose elapsed time is actually known.
  ///
  /// Both ends are required - see `attemptDuration`. A paper still open has no
  /// duration, and inventing one from the current clock would report a time
  /// that grows every time the screen is rebuilt.
  ///
  /// Read off COMPLETED, not released: how long somebody spent on their own
  /// paper is not a mark, so it is not gated on an administrator releasing it.
  List<({_Sitting r, String used})> _timedSittings(_Performance p) =>
      <({_Sitting r, String used})>[
        for (final _Sitting s in p.completed)
          if (timeUsed(s.ev, s.asm) case final String u) (r: s, used: u),
      ];

  /// One category panel per sitting that has categories to show.
  ///
  /// PER SITTING, NOT ONE COMBINED CHART. Categories are only comparable within
  /// a single test - a "prompt adherence" average pooled across two different
  /// papers mixes two different sets of questions and two different pass marks,
  /// so the number would describe neither.
  ///
  /// RELEASED ONLY. This is the one panel here that reports per-question marks
  /// back to the candidate, and a held sitting's marks have deliberately not
  /// been shown to them yet - the whole screen's release discipline would be
  /// undone by a chart that leaked them a category at a time.

  /// One sitting's category scores, from whichever source this audience has.
  ///
  /// An OPERATOR's sittings hydrate into `attempt.resp` off the manager route;
  /// a CANDIDATE's arrive as answer SHEETS off their token route. Both end in
  /// `categoryScores`, so the two audiences cannot be shown different numbers
  /// for the same paper - only the fetch differs.
  ///
  /// The attempt is tried first and the sheet second rather than branching on
  /// `isSelf`: whichever is present is the one that was allowed, and an operator
  /// who has also opened the sheet gets a consistent answer either way.
  List<CategoryScore> _scoresFor(_Sitting s) {
    final Assessment? asm = s.asm;
    if (asm != null && s.ev.resp.isNotEmpty) {
      final List<CategoryScore> fromAttempt = categoryScores(
        answersOf(s.ev, asm),
      );
      if (fromAttempt.isNotEmpty) return fromAttempt;
    }
    final AnswerSheet? sheet = widget.store.sheetByToken[s.ev.token];
    if (sheet == null) return const <CategoryScore>[];
    return categoryScores(answersOfSheet(sheet));
  }

  List<Widget> _categoryPanels(
    BuildContext context,
    _Performance p,
    bool isSelf,
  ) {
    final List<Widget> out = <Widget>[];
    // ALREADY NEWEST FIRST. `_Performance.fromStore` sorts `completed` by
    // `submittedAt` descending and `released` is a filtered view of it, so this
    // list is in the order the panels want.
    //
    // THIS WAS `.reversed` AND THAT INVERTED THE COMPARISON. Reversing made the
    // list oldest-first, so "the previous sitting of this test" found the NEWER
    // one - a candidate who improved was told they had declined, and a
    // candidate who declined got an improvement callout. Caught by two tests
    // that disagreed with each other, which is what a sign error looks like
    // from the outside.
    final List<_Sitting> ordered = p.released;

    for (int i = 0; i < ordered.length; i++) {
      final _Sitting s = ordered[i];
      final Assessment? asm = s.asm;
      final List<CategoryScore> scores = _scoresFor(s);
      if (scores.isEmpty) continue;
      // The previous sitting OF THE SAME TEST, for the improvement callout.
      // Comparing against a different assessment would be comparing two
      // different papers and calling the difference progress.
      //
      // Matched on the ASSESSMENT ID when both sides know it, and on the name
      // otherwise: a candidate's list does not always carry the Assessment
      // record (it is a manager route), so an id-only match would silently
      // never find a previous sitting on their own page - the one audience the
      // "most improved" line is written for.
      final String key = asm?.id ?? '';
      final _Sitting? earlier = ordered
          .skip(i + 1)
          .cast<_Sitting?>()
          .firstWhere(
            (_Sitting? o) =>
                o != null &&
                (key.isNotEmpty && o.asm != null
                    ? o.asm!.id == key
                    : _asmName(o) == _asmName(s)),
            orElse: () => null,
          );
      final List<CategoryScore> before = earlier == null
          ? const <CategoryScore>[]
          : _scoresFor(earlier);
      final ({String tag, double delta})? improved = mostImproved(
        scores,
        before,
      );

      // The pass mark the SERVER applied, which a released result carries -
      // the same expression the ThresholdBar in the breakdown below uses. A
      // candidate cannot load the Assessment, so reading it alone falls back
      // to 70 and files 60-69% categories as weaknesses on a 60% paper.
      final double threshold = s.ev.passMarkPercent(asm);

      out.add(
        Panel(
          title: ordered.length == 1
              ? 'Strengths and Weaknesses'
              : 'Strengths and Weaknesses - ${_asmName(s)}',
          note: 'marks earned over marks available, on this test',
          child: CategoryCard(
            scores: scores,
            threshold: threshold,
            improved: improved,
            audience: isSelf
                ? CategoryAudience.candidate
                : CategoryAudience.operator,
          ),
        ),
      );
    }
    return out;
  }

  Widget _breakdown(
    BuildContext context,
    _Performance p,
    bool isSelf,
  ) => DataGrid(
    minWidth: 840,
    emptyMessage: isSelf
        ? 'You have not completed an assessment yet. Once you '
              'submit one it appears here.'
        : 'This candidate has not completed an assessment yet.',
    emptyIcon: Icons.assignment_turned_in_outlined,
    cols: const <Col>[
      Col('Assessment', flex: 3),
      Col('Submitted', flex: 2),
      Col('Score', width: 96, numeric: true),
      Col('Against pass mark', width: 132),
      Col('Result', width: 132),
    ],
    rows: p.completed.map((_Sitting r) {
      final bool released = r.ev.resultsReleased;
      // An OPERATOR sees a held row's marks too: they decide the release, so
      // hiding the mark from them blinds the releaser. The pill still says
      // held, and the totals above stay the candidate's released-only view.
      final bool showMarks = released || !isSelf;
      return GridRow(
        <Widget>[
          // A LINK, to the same destination the matching row in My assessments
          // has had all along and by the same rule: a released sitting opens the
          // answer review, an unreleased one opens its completion card.
          //
          // It read as a dead end until now. A candidate looking at a failed
          // sitting is one click from the question they got wrong, and this
          // table is the obvious place to click.
          GridLink(_asmName(r)),
          Text(_date(r.ev.submittedAt), style: context.type.tableCell),
          // Invariant 3 at the row level. A candidate's unreleased row
          // carries a placeholder rather than a figure or a worded status:
          // the status is the pill at the end of the row, and it is the only
          // thing this row is allowed to say to them.
          showMarks
              ? Marks(_earned(r), _total(r))
              : Text('-', style: context.type.bodyMuted),
          // The threshold marker would disclose roughly where the score
          // landed, so a candidate's unreleased row gets no bar at all.
          showMarks
              ? SizedBox(
                  // A fixed width because a grid cell hands its child LOOSE
                  // constraints; the bar measures itself with a LayoutBuilder
                  // and would collapse to nothing on an unbounded width.
                  width: 116,
                  child: ThresholdBar(
                    earned: _earned(r),
                    total: _total(r),
                    // The pass mark the SERVER applied, which a released result
                    // now carries. A candidate's list holds no assessment, so
                    // the tick used to sit at the 70% default and contradict the
                    // very verdict beside it - green against a fill short of
                    // the bar.
                    threshold: r.ev.passMarkPercent(r.asm),
                    result: _verdict(r),
                  ),
                )
              : const SizedBox.shrink(),
          released
              ? Pill.state(_verdict(r))
              : const Pill('Awaiting release', Tone.inert),
        ],
        onTap: () {
          // WHOSE PAGE THIS IS decides the destination. A candidate goes to
          // their own exam surface - the answer review for a released sitting,
          // the completion card otherwise. An OPERATOR must not: those screens
          // are the candidate's, scoped to the signed-in user and gated on
          // release, so an admin clicking a released row landed on "Results not
          // released yet" - the gate answering about the ADMIN, who never sat
          // this exam. The operator's own view of one sitting is the attempt
          // detail, which carries the session, the violations and every
          // answer's mark.
          if (!isSelf) {
            context.nav.attempt(r.ev.id);
            return;
          }
          released
              ? context.nav.examAnswers(r.ev.token)
              : context.nav.examComplete(r.ev.token);
        },
      );
    }).toList(),
  );

  String _date(DateTime? d) => d == null ? '-' : istShortDate(d);
}

/// The two rings. Both are counts out of a total, so neither can express a
/// percentage even by accident.
class _Rings extends StatelessWidget {
  final _Performance p;

  const _Rings(this.p);

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 30,
    runSpacing: 18,
    children: <Widget>[
      _RingStat(
        earned: p.passed,
        total: p.released.length,
        result: p.verdict,
        label: 'Pass rate',
        caption: p.passed == p.released.length
            ? 'Every released result is a pass.'
            : '${p.passed} of ${p.released.length} released results '
                  'reached the pass mark.',
      ),
      _RingStat(
        earned: p.earnedMarks,
        total: p.availableMarks,
        result: p.verdict,
        label: 'Marks earned',
        // Pooled, not averaged. Averaging across assessments of different
        // lengths compares totals that are not comparable, which is the
        // same reason "best" points at a single sitting.
        // NOT "every question worth one mark" any more - that sentence is
        // false on any paper carrying a multi-part question, and it was
        // candidate-facing.
        caption:
            'Across ${p.released.length} released '
            '${p.released.length == 1 ? 'result' : 'results'}, pooled as '
            'marks.',
      ),
    ],
  );
}

class _RingStat extends StatelessWidget {
  final int earned;
  final int total;
  final ResultState result;
  final String label;
  final String caption;

  const _RingStat({
    required this.earned,
    required this.total,
    required this.result,
    required this.label,
    required this.caption,
  });

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: <Widget>[
      ScoreRing(earned: earned, total: total, result: result),
      const SizedBox(width: 14),
      // FLEXIBLE AS WELL AS CAPPED. The cap alone holds this pair at 316px
      // (92 of ring, 14 of gap, 210 of caption), which overflows a phone's
      // panel. Loose flex keeps the cap on a wide screen and lets the caption
      // wrap on a narrow one.
      Flexible(
        child: ConstrainedBox(
          // Capped so the caption wraps into a readable measure instead of
          // stretching across a wide panel.
          constraints: const BoxConstraints(maxWidth: 210),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Eyebrow(label),
              const SizedBox(height: 5),
              Text(caption, style: context.type.tiny.copyWith(height: 1.45)),
            ],
          ),
        ),
      ),
    ],
  );
}

/// The default state on a fresh account, and the one a reviewer sees first.
/// It is an absence, not a fault, so it explains what will fill it and offers
/// the one place worth going.
class _NothingYet extends StatelessWidget {
  /// False when an operator is reading somebody else's page: the copy is
  /// written to the person who sat the exam, and the action goes to the
  /// candidate's own list, which is not a place an operator can act.
  final bool isSelf;

  const _NothingYet({this.isSelf = true});

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: Icons.insights_outlined,
    title: 'No performance to show yet',
    body: isSelf
        ? 'Once you submit an assessment and an administrator releases the '
              'result, your pass rate, your marks and a breakdown per '
              'assessment appear here.'
        : 'This candidate has not submitted an assessment yet, or no result '
              'has been released. Their pass rate, marks and a breakdown per '
              'assessment appear here once one is.',
    compact: false,
    action: isSelf
        ? Btn.primary(
            'See My Assessments',
            onPressed: () => context.nav.reset(const MyAssessments()),
          )
        : null,
  );
}

/// Marks across released sittings, oldest first.
///
/// MARKS, never a percentage: the internal percentage decides pass and fail
/// but is never shown to a candidate, and a trend line is exactly the place
/// somebody would be tempted to leak it.
class _Trend extends StatelessWidget {
  const _Trend({required this.p});

  final _Performance p;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    // Oldest first so the line reads left to right as time passing. The store
    // hands them newest-first, which would draw progress backwards.
    final List<_Sitting> ordered = p.released.reversed.toList();
    final List<Slice> bars = <Slice>[
      for (final _Sitting r in ordered)
        Slice(
          _asmName(r),
          _earned(r).toDouble(),
          _verdict(r) == ResultState.pass ? t.successText : t.destText,
        ),
    ];
    final double top = ordered.fold<double>(
      0,
      (double n, _Sitting r) => math.max(n, _total(r).toDouble()),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Sparkline(
          values: <double>[for (final _Sitting r in ordered) _ratio(r)],
          color: t.primary,
        ),
        const SizedBox(height: 14),
        // The sparkline shows the shape; the bars carry the marks, so nothing
        // has to be read off the pixels.
        BarChart(bars: bars, maxValue: top <= 0 ? null : top),
      ],
    );
  }
}

/// How long each sitting took, with the disclaimer attached to the panel.
///
/// NO PACE TAG AND NO COHORT MEDIAN. Those are the admin's view. Telling a
/// candidate they were slower than their peers invites them to change something
/// that is not being measured - and on a paper with a fixed time limit, "slow"
/// mostly means "used the time they were given".
class _TimeTaken extends StatelessWidget {
  final List<({_Sitting r, String used})> rows;
  final bool isSelf;

  const _TimeTaken({required this.rows, required this.isSelf});

  @override
  Widget build(BuildContext context) {
    // Newest first, matching the breakdown table above it.
    final List<({_Sitting r, String used})> ordered =
        List<({_Sitting r, String used})>.from(rows.reversed);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DataGrid(
          minWidth: 420,
          cols: const <Col>[
            Col('Assessment', flex: 3),
            Col('Time used', width: 120, numeric: true),
          ],
          rows: <GridRow>[
            for (final ({_Sitting r, String used}) x in ordered)
              GridRow(<Widget>[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(_asmName(x.r), style: context.type.body),
                    if (x.r.ev.endedOnClock)
                      Text('Ended on the clock', style: context.type.tiny),
                  ],
                ),
                Mono(x.used),
              ]),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          isSelf
              ? 'Your time is recorded so an administrator can see how the '
                    'paper was used. It is not part of your score, and '
                    'finishing sooner or later does not change your marks or '
                    'your result.'
              : 'Recorded for context only. Time is not part of the score and '
                    'does not affect the result.',
          style: context.type.tiny.copyWith(
            height: 1.45,
            color: context.tokens.textMuted,
          ),
        ),
      ],
    );
  }
}
