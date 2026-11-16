// Attempt detail - HANDOVER §4.3.
//
// One candidate's attempt: result, session facts and per-answer marking.
//
// The notices stack rather than collapsing into one, because they mean
// different things and are cleared by different people. And every one of them
// is ADVISORY: invariant 6 says none of them touches a mark or a verdict, so
// the screen states what each one routes to rather than implying a penalty.
//
// THE OPERATOR'S FLAG IS NOT ONE OF THEM ANY MORE. It is an icon beside the
// candidate's name, and its remark is a panel below the notices: a person's
// concern about a candidate is not a machine signal about the sitting, and as
// a banner it displaced the three signals that are.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/api_client.dart' show ApiClient, ApiError;
import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../domain/category_scores.dart';
import '../../state/app_store.dart';
import '../../widgets/candidate_flag_sheet.dart';
import '../../widgets/buttons.dart';
import '../../widgets/category_card.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../../widgets/rescore_sheet.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/controls.dart';
import '../exam/exam_screen.dart';
import '../exam/image_plate.dart';
import 'zoomable_image.dart' show GalleryPage, showImageGallery;
import 'response_detail_screen.dart'
    show aiStatusLine, answerSummary, graderReasonNotice, redactFor;
import '../../theme.dart';
import '../../nav.dart';

/// [relative] as something that resolves where it is pasted.
///
/// `Assessment.candidateLink` is deliberately RELATIVE - `/exam/<token>` -
/// because `context.nav.exam` routes on it inside the app. Anything LEAVING the
/// app has to carry the origin, or an operator pastes `/exam/9f3c...` into an
/// email and the toast tells them it worked.
///
/// `Uri.base.origin` THROWS - `Bad state: Origin is only applicable schemes
/// http and https` - and off the web `Uri.base` is a `file://` path, so calling
/// it unguarded turns a copy button into a crash on every non-web build. The
/// relative link is a poor clipboard value; an exception is a worse one, and
/// this control has already shipped one silent-failure bug.
String absoluteLink(String relative) {
  if (relative.isEmpty) return '';
  final Uri base = Uri.base;
  if (base.scheme != 'http' && base.scheme != 'https') return relative;
  return '${base.origin}$relative';
}

/// Said wherever a candidate link would be, while the paper is a draft.
const String kLinkAfterLaunch =
    'The link works once the assessment is launched.';

class AttemptDetailScreen extends StatefulWidget {
  final AppStore store;
  final Portal portal;
  final String attemptId;

  const AttemptDetailScreen({
    super.key,
    required this.store,
    required this.portal,
    required this.attemptId,
  });

  @override
  State<AttemptDetailScreen> createState() => _AttemptDetailScreenState();
}

class _AttemptDetailScreenState extends State<AttemptDetailScreen> {
  /// Re-reads the attempt while any answer on it is waiting on a re-score.
  ///
  /// The route only QUEUES, so a page fetched once in `initState` would hold
  /// the old marks and states until a reload by hand - and an operator would
  /// press again, or read the stale marks as the re-grade's result.
  ///
  /// ponytail: re-reads the attempt on every tick rather than gating on the
  /// light `/scoring` counters the answer page watches. One call per ten
  /// seconds for a wait that is usually under a minute, and it stops the moment
  /// nothing is queued. Add the counter gate if candidate pages start being
  /// left open in bulk.
  Timer? _queuedWatch;
  bool _queuedTickInFlight = false;
  int _queuedTicks = 0;

  /// A queued re-score is usually graded within a minute.
  static const Duration _kQueuedWatchEvery = Duration(seconds: 10);

  /// An hour, for a request the grader never gets to (a stalled cron).
  static const int _kQueuedWatchMaxTicks = 360;

  @override
  void initState() {
    super.initState();
    // Before the load, so its notify can arm the watch.
    widget.store.addListener(_syncQueuedWatch);
    // Hydrate, like every sibling detail screen already did.
    //
    // This one was a StatelessWidget with no fetch at all: it relied entirely
    // on the attempts LIST having been loaded, so a deep link or a browser
    // refresh landed on "Attempt not found. It may have been removed." over a
    // live record. The route and the client method both already existed.
    widget.store.loadAttempt(widget.attemptId);
  }

  @override
  void dispose() {
    widget.store.removeListener(_syncQueuedWatch);
    _queuedWatch?.cancel();
    super.dispose();
  }

  /// Re-hydrate when the route points at a different attempt - the router
  /// reuses this State across records, so `initState` alone left the second
  /// attempt showing the first one's data (or "not found") until a refresh.
  @override
  void didUpdateWidget(AttemptDetailScreen old) {
    super.didUpdateWidget(old);
    if (old.attemptId != widget.attemptId) {
      _queuedWatch?.cancel();
      _queuedTicks = 0;
      widget.store.loadAttempt(widget.attemptId);
    }
  }

  void _syncQueuedWatch() {
    if (!mounted) return;
    final AppStore s = widget.store;
    final bool queued =
        s.isLive &&
        (s.attemptById(widget.attemptId)?.hasQueuedRescore ?? false);
    if (!queued) {
      _queuedWatch?.cancel();
      _queuedTicks = 0;
      return;
    }
    if (_queuedTickInFlight ||
        (_queuedWatch?.isActive ?? false) ||
        _queuedTicks >= _kQueuedWatchMaxTicks) {
      return;
    }
    _queuedWatch = Timer(_kQueuedWatchEvery, _tickQueuedWatch);
  }

  Future<void> _tickQueuedWatch() async {
    if (!mounted) return;
    _queuedTicks++;
    _queuedTickInFlight = true;
    try {
      await widget.store.loadAttempt(widget.attemptId);
    } finally {
      _queuedTickInFlight = false;
      _syncQueuedWatch();
    }
  }

  /// Edit the internal remark on THIS attempt.
  ///
  /// `remark:` ALONE, never `flagged:`. The flag and the remark are
  /// independent features sharing one endpoint, so sending the flag state back
  /// alongside the prose would turn a colleague's concurrent toggle into a
  /// silent revert - and would break the promise the sheet makes in so many
  /// words, that saving a remark does not raise or clear anything.
  Future<void> _editRemark(Attempt ev) async {
    final String name =
        widget.store.personById(ev.employeeId)?.name ?? 'this candidate';
    final String? out = await askForRemark(
      context,
      candidateName: name,
      existing: ev.candidateFlag.remark,
    );
    // null is CANCELLED, '' is "delete the remark". Collapsing the two here
    // would make an existing remark impossible to remove from this screen -
    // see the contract on [askForRemark].
    if (out == null || !mounted) return;
    await widget.store.flagAttempt(ev.id, remark: out);
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final AppStore store = widget.store;
    final String attemptId = widget.attemptId;

    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext context, _) {
        final Attempt? ev = store.attemptById(attemptId);
        if (ev == null) {
          if (store.isHydrating('attempt', attemptId)) {
            return const DetailScreenSkeleton();
          }
          return PageBody(
            children: <Widget>[
              PageHead('Attempt not found', sub: 'It may have been removed.'),
              Panel(child: const EmptyLine('Nothing to show.')),
            ],
          );
        }
        final Assessment? asm = store.asmById(ev.assessmentId);
        if (asm == null) {
          return PageBody(
            children: <Widget>[
              PageHead('Assessment not found'),
              Panel(child: const EmptyLine('Nothing to show.')),
            ],
          );
        }

        final Person? who = store.personById(ev.employeeId);
        // TIME TAKEN AND PACE, for the Session panel. The test's median is the
        // server's (over ALL its sittings) when it sent one; otherwise the same
        // local median the dashboard's Time Analysis takes, over the timed
        // sittings of this assessment held here.
        final Duration? took = attemptDuration(ev);
        final Duration? median = took == null
            ? null
            : ev.testMedian ??
                  medianDuration(<Duration>[
                    for (final Attempt a in store.attempts)
                      if (a.assessmentId == ev.assessmentId)
                        if (attemptDuration(a) case final Duration d) d,
                  ]);
        final Pace? pace = paceOf(took, median);
        final ResultState result = ev.verdict(asm);
        final List<String> unresolved = ev.unresolvedQuestionIds(asm);
        // WHAT IS LEFT TO ASK FOR, which is not the same as what is unresolved.
        // An answer already queued would only join the request it is in, so
        // counting it on the button would name work a press cannot affect. A
        // queued re-score of a SCORED answer is not in `unresolved` at all,
        // which is why the disabled fallback below reads
        // [Attempt.hasQueuedRescore] instead.
        final List<String> toQueue = <String>[
          for (final String id in unresolved)
            if (!(ev.resp[id]?.rescoreRequested ?? false)) id,
        ];
        // Refused with 409 `stopping` while a Kill settles (G1-08).
        final bool stopping = asm.scoringPhase == ScoringPhase.stopping;

        return PageBody(
          children: <Widget>[
            Crumbs(<Crumb>[
              Crumb('Assessments', () => context.nav.assessments()),
              Crumb(asm.name, () => context.nav.assessment(asm.id)),
              Crumb(who?.name ?? ev.employeeId),
            ]),
            PageHead(
              who?.name ?? ev.employeeId,
              // THE FLAG, BESIDE THE NAME IT IS ABOUT. It is read with the
              // person rather than as a red wall above the record, and it is
              // the only control there is: one click raises it, one withdraws
              // it, and there is no separate clear button to hunt for.
              titleChild: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // Flexible, so a long name ellipsises INSIDE the row instead
                  // of pushing the flag off the end of the header.
                  Flexible(
                    child: Text(
                      who?.name ?? ev.employeeId,
                      style: context.type.pageTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 10),
                  FlagToggle(
                    flag: ev.candidateFlag,
                    size: 22,
                    // Null below the Admin rung. The STATE is still shown - a
                    // read-only Manager is usually the person being asked why
                    // a candidate is held up - but the click is withheld
                    // rather than handed over to answer 403 and leave the
                    // record looking untouched.
                    onToggle: store.can(Capability.lifecycle)
                        ? () => store.flagAttempt(
                            ev.id,
                            flagged: !ev.candidateFlag.flagged,
                          )
                        : null,
                  ),
                ],
              ),
              // THE ADDRESS, WITH A WAY TO TAKE IT. `sub:` renders a bare
              // Text, so nothing could sit beside the email and chasing a
              // no-show meant retyping it off the screen a character at a
              // time. `subChild` is the head's own escape hatch, the twin of
              // the `titleChild` above, so the gap and the type ramp stay the
              // head's decision and only the CONTENT of the line moves here.
              // The address and its copy button get a line of their own, so the
              // button always sits right after the email instead of wherever a
              // long assessment name happens to end.
              subChild: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    asm.name,
                    style: context.type.pageSub,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // No button at all when there is no address - not a greyed
                  // one. An attempt with no person row is a data state, not a
                  // control an operator should be offered and refused.
                  if ((who?.email ?? '').isNotEmpty)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        // Flexible: a long address ellipsises inside the row
                        // rather than pushing the copy button off the end.
                        Flexible(
                          child: Text(
                            who!.email,
                            style: context.type.pageSub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        CopyBtn(
                          who.email,
                          toaster: store.toaster,
                          toast: 'Email copied',
                          semanticsLabel: 'Copy email address',
                        ),
                      ],
                    ),
                ],
              ),
              actions: <Widget>[
                Btn(
                  'Copy Candidate Link',
                  // A DRAFT'S LINK IS DEAD: the server answers it as unknown
                  // until launch, so there is nothing to hand a candidate yet.
                  tooltip: asm.state.isDraft
                      ? kLinkAfterLaunch
                      : 'Copy this candidate\'s exam link. It is a BEARER '
                            'credential, not an identifier: anyone holding it '
                            'can sit this paper as them, with no password. Send '
                            'it to the candidate and nobody else.',
                  icon: Icons.link,
                  // Actually copies. It reported success without touching the
                  // clipboard, so the operator pasted whatever was there
                  // before - the worst kind of failure, because the toast
                  // said it had worked.
                  onPressed: ev.token.isEmpty || asm.state.isDraft
                      ? null
                      : () async {
                          // ABSOLUTE, because this leaves the app. The getter
                          // is deliberately relative - `context.nav.exam`
                          // routes on it - so pasting it straight gave the
                          // operator `/exam/<token>`, which is not a link
                          // anywhere outside this tab. They mailed it to a
                          // candidate and the toast said it had worked.
                          await Clipboard.setData(
                            ClipboardData(text: absoluteLink(ev.candidateLink)),
                          );
                          store.toaster.ok('Candidate link copied');
                        },
                ),
                // THE ONLY WAY TO WRITE THE FIRST REMARK. The panel below
                // renders only once one EXISTS, so without this the feature is
                // unreachable on an attempt that has none. It disappears as
                // soon as there is one, because editing then belongs beside
                // the text being edited rather than up here.
                if (!ev.candidateFlag.hasRemark &&
                    store.can(Capability.lifecycle))
                  Btn(
                    'Add remark',
                    tooltip:
                        'Write an internal note about THIS sitting - what happened '
                        'and what a reviewer should know. Admins read it on this '
                        'attempt only, the candidate never does, and it neither '
                        'raises the flag nor moves a mark.',
                    // ONE GLYPH FOR THE REMARK, EVERYWHERE.
                    //
                    // `mode_comment_outlined` is what the Candidates roster and
                    // the candidate's own history page draw in their Remarks
                    // cells, so the icon an operator learns in a table is the
                    // icon they look for on the record. `note_add_outlined` was
                    // a fourth kind of "note" glyph in a console that already
                    // uses this one for exactly this field, and a control found
                    // by shape is not found when the shape changes per screen.
                    icon: Icons.mode_comment_outlined,
                    onPressed: () => _editRemark(ev),
                  ),
                // Re-scoring spends LLM calls and rewrites a mark, which is a
                // lifecycle action on an Admin-only route. A
                // read-only Manager still sees the count of held answers in the
                // marking table below and in the banner underneath; what they
                // do not get is a red button that answers 403 and leaves the
                // record looking untouched.
                if (toQueue.isNotEmpty && store.can(Capability.lifecycle))
                  Btn.danger(
                    'Re-score ${toQueue.length} answer(s)',
                    tooltip:
                        'Grade these unresolved answers again, together - one '
                        'LLM call grades up to 20 answers. A mark is replaced '
                        'only when its new grade succeeds.',
                    // The count on the label IS the request: these answers and
                    // no others, so what was promised is what gets graded.
                    onPressed: stopping
                        ? null
                        : () => rescoreConfirmed(
                            context,
                            store,
                            <String, List<String>?>{ev.id: toQueue},
                            attempts: <Attempt>[ev],
                          ),
                  )
                // NOTHING LEFT TO ASK FOR, BUT SOMETHING IS WAITING. A press
                // only queues, so an enabled button would say the act had not
                // happened - and a repeat press is at best a no-op.
                else if (ev.hasQueuedRescore && store.can(Capability.lifecycle))
                  Btn.danger(
                    'Re-score queued',
                    tooltip:
                        'The grader has been asked for these answers and has '
                        'not reached them yet. This page re-reads itself until '
                        'it does.',
                    onPressed: null,
                  ),
                if (ev.isDone)
                  Btn(
                    'Export Responses',
                    tooltip:
                        'Download this candidate\'s answers and their scoring as CSV, '
                        'as the module writes them.',
                    icon: Icons.table_view_outlined,
                    onPressed: () => store.exportAttemptResponses(ev.id),
                  ),
                if (ev.isDone &&
                    !ev.resultsReleased &&
                    store.can(Capability.release))
                  Btn.primary(
                    'Release This Result',
                    tooltip:
                        'Show this candidate their own result. Until you do, they see '
                        'that the attempt was submitted and nothing more. This is the '
                        'only action that reveals a mark, and it cannot be undone.',
                    onPressed: () => store.releaseOne(ev.id),
                  ),
                if (!ev.piiAnonymized && store.can(Capability.lifecycle))
                  Btn.danger(
                    'Erase Candidate Data',
                    tooltip:
                        'Delete the candidate\'s free text - their written answers and '
                        'the grader\'s notes on them. Scores, flags and the audit trail '
                        'are KEPT, so the result stays reviewable and no mark changes. '
                        'Irreversible.',
                    onPressed: () => _showEraseSheet(context, ev, who),
                  ),
              ],
            ),

            // Stacked notices about the RECORD. Order matters: what stops the
            // record being usable comes before what merely annotates it. The
            // operator's flag is no longer among them - it is the icon beside
            // the name above, and its remark is the panel below.
            if (ev.piiAnonymized) ...<Widget>[
              const Notice(
                tone: Tone.inert,
                strong: 'Candidate data was erased.',
                text:
                    'The free text is gone. Scores, flags and the audit trail '
                    'were kept, so the result stays reviewable.',
              ),
              const SizedBox(height: 12),
            ],
            if (ev.hasScoringError(asm)) ...<Widget>[
              Notice(
                tone: Tone.bad,
                strong: 'A grader error is holding this result.',
                text:
                    'Nothing clears a terminal error but a person. Until '
                    'then the result stays pending rather than finalising '
                    'as a zero.',
                actions: <Widget>[
                  // The BANNER is the point and it stays: a read-only Manager
                  // needs to know this candidate's result is held by a grader
                  // error rather than by the candidate, because they are often
                  // the one being asked why the mark has not arrived. Clearing
                  // the state is Admin-only, so they read the diagnosis without
                  // being handed a recovery that returns 403.
                  if (store.can(Capability.lifecycle))
                    Btn(
                      'Reset and Re-score',
                      tooltip:
                          'Clear the terminal grader error and grade the held answers '
                          'again. Nothing else clears that state - the automatic retry '
                          'excludes it, so an infrastructure failure is never recorded '
                          'as this candidate\'s failure. One LLM call grades up to '
                          '20 answers.',
                      size: BtnSize.sm,
                      // No ids when the answers have not loaded: the server
                      // then takes the unresolved set itself.
                      onPressed: stopping
                          ? null
                          : () => rescoreConfirmed(
                              context,
                              store,
                              <String, List<String>?>{
                                ev.id: unresolved.isEmpty ? null : unresolved,
                              },
                              attempts: <Attempt>[ev],
                            ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            // WHY THE GRADER LAST STOPPED, after the state that blocks the
            // record and before the advisory flags - which is what it is: a
            // reason, not a state. Without it a spend cap holding the queue and
            // a failed re-grade that kept the old mark both read as "Pending".
            if (graderReasonNotice(ev) case final Widget notice) ...<Widget>[
              notice,
              const SizedBox(height: 12),
            ],
            if (ev.scoreOutlier) ...<Widget>[
              const Notice(
                tone: Tone.warn,
                strong: 'This score is an outlier.',
                text:
                    'It sits far from the cohort. This is advisory only and has '
                    'not changed the mark.',
              ),
              const SizedBox(height: 12),
            ],
            if (ev.integrityAlert) ...<Widget>[
              const Notice(
                tone: Tone.warn,
                strong: 'An integrity signal was raised.',
                text:
                    'Advisory only. It routes a person to this record; it has '
                    'not changed the mark or the verdict.',
              ),
              const SizedBox(height: 12),
            ],
            // The regular count and the AI count, each against its own cap.
            if (ev.limitBreached(asm) || ev.aiLimitBreached(asm)) ...<Widget>[
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    if (ev.limitBreached(asm))
                      ViolationBreachBadge(ev, cap: asm.maxViolations),
                    if (ev.aiLimitBreached(asm))
                      ViolationBreachBadge(
                        ev,
                        cap: asm.aiMaxViolations,
                        ai: true,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            for (final bool ai in const <bool>[false, true])
              if (ev.countOf(ai) > 0) ...<Widget>[
                Builder(
                  builder: (BuildContext context) {
                    // Derived once by `proctoringViolationNotice` - the full
                    // tally with counts, the singular/plural fix, the empty-log
                    // fallback and the unchanged auto-submit clause all live
                    // there so this surface holds no copy of the rules.
                    final ({String strong, String text}) n =
                        proctoringViolationNotice(
                          count: ev.countOf(ai),
                          violations: ai ? ev.aiViolations : ev.violations,
                          violationReason: ev.violationReason,
                          autoSubmitReason: ev.autoSubmitReason,
                          maxViolations: asm.policy(ai).cap,
                          ai: ai,
                        );
                    return Notice(
                      tone: Tone.warn,
                      strong: n.strong,
                      text: n.text,
                    );
                  },
                ),
                const SizedBox(height: 12),
              ],
            if (aiStatusLine(ev.aiStatus) case final String line) ...<Widget>[
              Text(line, style: context.type.bodyMuted),
              const SizedBox(height: 12),
            ],

            // THE INTERNAL REMARK, under the notices and never above them.
            //
            // Prose a colleague typed is CONTEXT for the signals above, not a
            // signal itself - it holds no result and moves no mark - so it
            // must not sit where the violation, outlier and integrity notices
            // sit or it buries them.
            //
            // RENDERED ONLY WHEN THERE IS ONE. An empty panel on every attempt
            // promises content that is almost never there, which trains the
            // reader to skip it on the one record where somebody did write
            // something.
            //
            // UNGATED ON RUNG, like the notices: a read-only Manager has to be
            // able to read what a colleague recorded about a sitting they are
            // being asked about. Only the edit control is Admin-gated.
            //
            // No "raised by" line here: `by` and `at` describe the FLAG, and
            // are empty on the perfectly ordinary attempt that carries a
            // remark without one. That sentence lives on the toggle beside the
            // name, where the fact it describes lives.
            if (ev.candidateFlag.hasRemark) ...<Widget>[
              Panel(
                title: 'Internal Remark',
                note: 'Internal only - never shown to the candidate',
                headActions: <Widget>[
                  if (store.can(Capability.lifecycle))
                    Btn(
                      'Edit remark',
                      size: BtnSize.sm,
                      tooltip:
                          'Revise the note on this sitting. It belongs to this '
                          'attempt alone, so the same candidate\'s other '
                          'assessments keep theirs. Clearing the box and saving '
                          'removes it, and the flag is untouched either way.',
                      // THE SAME GLYPH AS "Add remark" ABOVE and as the tables'
                      // remark cells. The two buttons are one control at two
                      // moments in the field's life - before there is text and
                      // after - and a reader who has to re-identify it by label
                      // alone each time is a reader who stops looking for it.
                      icon: Icons.mode_comment_outlined,
                      onPressed: () => _editRemark(ev),
                    ),
                ],
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      ev.candidateFlag.remark,
                      style: context.type.bodySecondary.copyWith(height: 1.6),
                    ),
                    const SizedBox(height: 10),
                    // IN THE BODY, not only in the header note, which
                    // ellipsises on a narrow window - and the one sentence
                    // that must never be the one clipped is the one saying
                    // who does not get to read this. It carries the scope
                    // too: an operator who believes a remark follows the
                    // person will write it here once and expect to find it
                    // on their next assessment, where it does not exist.
                    Text(
                      'Internal only - never shown to the candidate, and never '
                      'part of a mark or a verdict. It belongs to THIS sitting: '
                      'the same candidate\'s other assessments carry their own.',
                      style: context.type.tiny.copyWith(height: 1.45),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // THE CAMERA SNAPSHOTS a tripped AI rule saved, under the notices
            // that count the violations they belong to. It owns its own load,
            // so it is mounted here only once the attempt and its assessment
            // are both in hand. Only an AI-proctored paper, or an attempt whose
            // AI reported (the rule may have been switched off since), can
            // have snapshots; any other attempt makes no request at all.
            ProctoringEvidencePanel(
              key: ValueKey<String>('evidence-${ev.id}'),
              api: store.api,
              attemptId: ev.id,
              aiProctored:
                  asm.rules[ProctorRule.aiProctor] || ev.aiStatus.isNotEmpty,
            ),

            const SizedBox(height: 4),
            Cols2(
              left: Panel(
                title: 'Result',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        // `maxMarks`, not `totalQuestions`: a question is
                        // worth its COMPONENT count now, so a five-question
                        // paper can be a fourteen-mark one and the ring read
                        // "9 / 5". Same argument for the two figures below -
                        // all three must divide by the same number the score
                        // was actually computed against.
                        ScoreRing(
                          earned: ev.earnedMarks(asm),
                          total: ev.maxMarks(asm),
                          result: result,
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Pill.state(result),
                                  const SizedBox(width: 8),
                                  if (ev.resultsReleased)
                                    const Pill('Released', Tone.ok)
                                  else
                                    const Pill('Held', Tone.inert),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Marks(
                                ev.earnedMarks(asm),
                                ev.maxMarks(asm),
                                size: 17,
                              ),
                              const SizedBox(height: 10),
                              ThresholdBar(
                                earned: ev.earnedMarks(asm),
                                total: ev.maxMarks(asm),
                                threshold: asm.passThreshold,
                                result: result,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                unresolved.isEmpty
                                    ? 'The marker line is the pass threshold, '
                                          '${asm.passThreshold.round()}%.'
                                    : '${unresolved.length} answer(s) are still '
                                          'unresolved, which holds the result on '
                                          'pending whatever the score.',
                                style: context.type.tiny.copyWith(height: 1.45),
                              ),
                              // THE UNGATED TOTAL, for the admin only.
                              //
                              // Every component is won whole or lost whole
                              // against a threshold, so a paper can read
                              // `0 / 5` while every answer was partly right -
                              // and from the marks alone that is
                              // indistinguishable from a blank paper. The raw
                              // total is the number that tells them apart, and
                              // `etp_assessment_pro` has always shown it to its
                              // admins. Only rendered when the route actually
                              // sent one; a candidate surface never does.
                              //
                              // BOTH FIGURES ARE THE GRADED HALF'S, not the
                              // paper's: the raw ungates the LLM-graded
                              // components only, so `rawOutOf` is its
                              // denominator and `gradedMarks` is the mark it
                              // has to be compared against. Handing it the
                              // paper's totals compared two different scales
                              // and called the difference partial credit.
                              if (ev.rawResult != null) ...<Widget>[
                                const SizedBox(height: 10),
                                _RawScoreLine(
                                  raw: ev.rawResult!,
                                  total: ev.rawOutOf ?? 0,
                                  marks: ev.gradedMarks,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // FOUR COUNTS (five with the AI watch), and nothing that
                    // is not one.
                    //
                    // `State` used to sit here as a fifth card, which was two
                    // problems at once. A KPI card is a numeral in a display
                    // size on a fixed 100px height, so the word "Submitted"
                    // rendered oversized and then ellipsised to "Subm..." - the
                    // one card on the row whose value could not be read. And
                    // five cards over a four-across grid left it orphaned on a
                    // second row of its own. It reads as what it is - a status,
                    // beside the rest of the sitting - in the Session panel.
                    AutoGrid(
                      minWidth: 120,
                      children: <Widget>[
                        Kpi(
                          label: 'Answered',
                          value: '${ev.answeredCount} / ${ev.paperSize(asm)}',
                        ),
                        Kpi(label: 'Violations', value: '${ev.violationCount}'),
                        // The AI watch's own count, on a paper that ran it
                        // (or a sitting that has one).
                        if (asm.rules[ProctorRule.aiProctor] ||
                            ev.aiViolationCount > 0)
                          Kpi(
                            label: 'AI violations',
                            value: '${ev.aiViolationCount}',
                          ),
                        Kpi(
                          label: 'Unresolved',
                          value: '${unresolved.length}',
                          valueColor: unresolved.isNotEmpty ? t.warnText : null,
                        ),
                        Kpi(
                          label: 'Auto-submitted',
                          // The one card on the row whose value is a word.
                          value: switch ((
                            ev.autoSubmitted,
                            ev.autoSubmitReason,
                          )) {
                            (false, _) => 'No',
                            (true, 'violation') => 'Violations',
                            (true, 'ai_violation') => 'AI proctor',
                            (true, 'expired') => 'Time out',
                            (true, _) => 'Yes',
                          },
                          word: true,
                          valueColor: ev.autoSubmitted ? t.warnText : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              right: Panel(
                title: 'Session',
                child: Column(
                  children: <Widget>[
                    // The two lifecycle states FIRST, and as pills: they decide
                    // how every row under them reads - "Not submitted" is
                    // expected on an attempt still running. Plain right-aligned
                    // text carried no tone, so a failure read like a success.
                    KvRow('State', Pill.state(ev.state)),
                    KvRow('Invitation', Pill.state(ev.inviteState)),
                    KvRow.text('Attempt id', ev.id),
                    KvRow.text(
                      'Started',
                      ev.startedAt == null ? 'Not started' : _dt(ev.startedAt!),
                    ),
                    KvRow.text(
                      'Submitted',
                      ev.submittedAt == null
                          ? 'Not submitted'
                          : _dt(ev.submittedAt!),
                    ),
                    // Each row only when it has something true to say: an
                    // unsubmitted paper has no duration, and a test with no
                    // median has nothing to judge the duration against.
                    // The SAME span the Pace row is judged on, and nothing
                    // else. `timeUsed` caps at the paper's CURRENT limit, which
                    // is not the limit this sitting ran under once a duration
                    // has been edited: it read "30 of 30 min" beside
                    // "median 1h" for a sitting that had an hour.
                    // TO THE SECOND, like the Pace tooltip beside it (BR-D12):
                    // "1 min" over a tooltip reading "1m 45s" was two answers
                    // to one question.
                    if (took != null)
                      KvRow.text('Time taken', preciseDuration(took)),
                    if (pace != null)
                      KvRow(
                        'Pace',
                        Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            // The dashboard's own pill and tooltip, so the tag
                            // reads and explains itself the same way here.
                            Tooltip(
                              message: paceExplanation(took, median),
                              child: Pill(pace.label, Tone.inert),
                            ),
                            Text(
                              'median ${preciseDuration(median!)}',
                              style: context.type.bodySecondary,
                            ),
                          ],
                        ),
                      ),
                    // Only while it can still decide anything. On a submitted
                    // attempt the deadline is spent history and would sit here
                    // reading like a warning about a paper that is already in.
                    if (ev.deadline != null && !ev.isDone)
                      KvRow.text('Deadline', _dt(ev.deadline!)),
                    KvRow.text('Locked', ev.isLocked ? 'Yes' : 'No'),
                    if (asm.state.isDraft)
                      KvRow.text('Candidate link', kLinkAfterLaunch, last: true)
                    else
                      KvRow(
                        'Candidate link',
                        LinkBtn(
                          '/exam/${ev.token}',
                          clip: true,
                          style: context.type.mono.copyWith(fontSize: 11.5),
                          onPressed: () => context.nav.exam(ev.token),
                        ),
                        last: true,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // PER-ASSESSMENT STRENGTHS AND WEAKNESSES, for THIS candidate.
            //
            // Here rather than as a tab on the assessment: the question an
            // operator is actually asking when they open a person's attempt is
            // "what is this candidate good and bad at on this paper", and the
            // grader's own reasoning is already on the same screen one click
            // away - so the categories and the evidence for them are read
            // together instead of on two surfaces.
            //
            // Cohort-level averages are NOT duplicated here. This is one
            // person's paper; the cohort's shape belongs on the dashboard.
            if (_categoriesOf(ev, asm) case final List<CategoryScore> cats
                when cats.isNotEmpty) ...<Widget>[
              Panel(
                title: 'Strengths and Weaknesses',
                note: 'SOP categories on this assessment - never a re-mark',
                child: CategoryCard(scores: cats, threshold: asm.passThreshold),
              ),
              const SizedBox(height: 16),
            ],
            Panel(
              title: 'Score Details',
              note: 'One row per answer',
              flush: true,
              child: DataGrid(
                minWidth: 900,
                emptyMessage: 'This candidate has not answered anything yet.',
                cols: const <Col>[
                  Col('Question', flex: 3),
                  Col('Type', width: 140),
                  Col('Scoring', width: 130),
                  Col('Raw', width: 80, numeric: true),
                  Col('Mark', width: 70, numeric: true),
                  Col('', width: 110),
                ],
                rows: asm.questions.where((Question q) => ev.resp.containsKey(q.id)).map((
                  Question q,
                ) {
                  final Response r = ev.resp[q.id]!;
                  return GridRow(<Widget>[
                    GridLink(q.name),
                    Text(q.taskLabelLong, style: context.type.bodySecondary),
                    // THE QUEUE WINS THE COLUMN. `llm_state` does not move
                    // while a re-score waits - the commonest re-score is of an
                    // already-SCORED answer, which sits at `scored` the whole
                    // time - so the state alone shows a queued answer as
                    // untouched. The answer page's own wording, so the two
                    // screens name one thing one way.
                    if (r.rescoreRequested)
                      const Pill('Re-score queued', Tone.info)
                    else
                      Pill.state(r.llmState),
                    // THE ANSWER'S OWN RAW, on the same scale as the total
                    // above this table - so the column adds up to it.
                    //
                    // It used to print the grader's 0-100 for a subjective row
                    // and a dash for everything else, which meant a column of
                    // "80, 60, -, -, -" sat under a total of "1.40 / 2" and
                    // nothing on screen connected the two. `rawScore` is per
                    // component, 0.0-1.0 each, so 80 reads as 0.80 and an
                    // exactly-right multiple-choice sub-question reads 1.00.
                    //
                    // The dash survives for a question with NO components at
                    // all ([Response.hasRaw]), which is a different fact from
                    // a raw of zero and must not be shown as one.
                    Mono(r.hasRaw ? (r.rawScore ?? 0).toStringAsFixed(2) : '-'),
                    Mono('${r.mark}'),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (r.judge != null)
                          Btn(
                            'View',
                            tooltip:
                                'View the grader\'s full reasoning for this answer - the '
                                'rubric it applied, its evidence, and the model that ran.',
                            size: BtnSize.sm,
                            // Stays: opens the scoring sheet, not the answer.
                            onPressed: () =>
                                showAuditSheet(context, store, ev, asm, q, r),
                          ),
                        // No "Open": the row itself opens the answer.
                      ],
                    ),
                  ], onTap: () => context.nav.response(ev.id, q.id));
                }).toList(),
              ),
            ),
            // No chatter panel, deliberately: `evaluator` does not inherit
            // mail.thread (posting 422s), and its only messages are the
            // outgoing invitation, which the read route filters as PII. That
            // leaves an empty panel promising a history that does not exist.
          ],
        );
      },
    );
  }

  static String _dt(DateTime d) => istTimestamp(d);

  /// The erase sheet separates what is REMOVED from what is KEPT, because the
  /// fear the action provokes is losing the record, and the record is exactly
  /// what survives.
  void _showEraseSheet(BuildContext context, Attempt ev, Person? who) {
    showSheet<void>(
      context,
      title: 'Erase Candidate Data',
      sub: who == null ? null : 'For ${who.name}.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Panel(
            title: 'Removed',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '\u2022  Every free-text answer',
                  style: context.type.body,
                ),
                const SizedBox(height: 5),
                Text(
                  '\u2022  Every image label the candidate typed',
                  style: context.type.body,
                ),
                const SizedBox(height: 5),
                Text(
                  '\u2022  The justification on every rated answer',
                  style: context.type.body,
                ),
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
                  '\u2022  Every score and the final result',
                  style: context.type.body,
                ),
                const SizedBox(height: 5),
                Text(
                  '\u2022  The launch gates and integrity flags',
                  style: context.type.body,
                ),
                const SizedBox(height: 5),
                Text(
                  '\u2022  The grader audit trail',
                  style: context.type.body,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Notice(
            tone: Tone.info,
            strong: 'Why the flags stay.',
            text: 'A result you cannot defend is worse than no result.',
          ),
          const SizedBox(height: 10),
          const Notice(
            tone: Tone.bad,
            strong: 'This cannot be undone.',
            text: 'The text is deleted, not hidden.',
          ),
        ],
      ),
      actions: <Widget>[
        Btn('Cancel', onPressed: () => Navigator.of(context).pop()),
        Btn.danger(
          'Erase and Keep the Scores',
          tooltip:
              'Confirm. The free text goes; every score, flag and audit '
              'line stays, so this result remains reviewable and no mark '
              'moves. There is no undo.',
          onPressed: () {
            Navigator.of(context).pop();
            widget.store.erasePii(ev.id);
          },
        ),
      ],
    );
  }

  /// This candidate's SOP-category scores on THIS assessment.
  ///
  /// The detail route carries the per-answer marks and each answer's tags, so
  /// this is computed from the same numbers the "Score details" grid below
  /// prints - the card and the table cannot disagree.
  ///
  /// Empty when the questions were never tagged. The caller omits the panel
  /// entirely in that case rather than drawing an empty chart: an operator
  /// looking at one person's paper cannot act on "your bank is untagged", and
  /// the assessment's own screens are where that belongs.
  List<CategoryScore> _categoriesOf(Attempt ev, Assessment asm) =>
      categoryScores(answersOf(ev, asm));
}

/// The audit sheet - everything the module knows about how one subjective
/// answer was scored, so the mark can be defended rather than merely asserted.
void showAuditSheet(
  BuildContext context,
  AppStore store,
  Attempt ev,
  Assessment asm,
  Question q,
  Response r,
) {
  final Judge? j = r.judge;
  if (j == null) return;
  final AppTokens t = context.tokens;

  showSheet<void>(
    context,
    wide: true,
    title: 'Answer Audit',
    sub: q.name,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        KpiStrip(<Widget>[
          Kpi(label: 'Mark', value: '${r.mark} / ${r.markOutOf}'),
          Kpi(label: 'Raw', value: rawFromHundred(j.raw100)),
          Kpi(
            label: 'Threshold',
            // ON THE SAME SCALE AS THE RAW BESIDE IT. Printing the bar as
            // `60` next to a raw of `0.93` gives two numbers that cannot be
            // compared by eye, which is the one thing this pair is for.
            value: rawFromHundred(asm.barFor(q.type)),
            sub: 'The bar to clear',
          ),
          Kpi(label: 'Attempts', value: '${j.attempts}'),
        ]),
        // THREE OUTCOMES, NOT TWO. A question is worth its component count
        // now, so `mark > 0` no longer means the question was earned - a 1 of
        // 3 printed an unqualified green "Mark earned." over two components
        // the candidate lost.
        Notice(
          tone: r.mark <= 0
              ? Tone.warn
              : (r.mark >= r.markOutOf ? Tone.ok : Tone.info),
          strong: r.mark <= 0
              ? 'No marks earned.'
              : (r.mark >= r.markOutOf
                    ? 'Full marks earned.'
                    : '${r.mark} of ${r.markOutOf} marks earned.'),
          text: j.verdict,
        ),
        const SizedBox(height: 14),
        FieldGrid(<Widget>[
          // `_orDash` for every one: these come from the grader's audit
          // record, and a field it did not populate must read as absent
          // rather than as a blank cell that looks like a broken render.
          Field.readonly('Profile', _orDash(j.profile)),
          Field.readonly('Gate', _orDash(j.gate)),
          Field.readonly('Rubric source', _orDash(j.rubricSource)),
          Field.readonly('Judge model', _orDash(j.judgeModel)),
        ]),
        const SizedBox(height: 16),
        const Eyebrow('How the raw score was reached'),
        const SizedBox(height: 8),
        _Meter(
          label: 'Key closeness',
          weight: '0.60',
          value: j.keyCloseness,
          color: t.c1,
        ),
        _Meter(
          label: 'SOP coverage',
          weight: '0.25',
          value: j.sopCoverage,
          color: t.c2,
        ),
        _Meter(label: 'Raw', weight: '', value: j.raw100 / 100, color: t.seq2),
        const SizedBox(height: 14),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            StatusBadge('Clarity: ${j.clarity}', Tone.inert),
            StatusBadge('AI-likeness: ${j.aiConfidence}', Tone.inert),
            StatusBadge('Consistency: ${j.verdictConsistency}', Tone.inert),
            StatusBadge('Threshold: ${asm.barFor(q.type).round()}', Tone.inert),
          ],
        ),
        const SizedBox(height: 16),
        Panel(
          title: 'The Candidate Answer',
          // `answerSummary`, not `r.justification`. The justification is the
          // answer on ONE type - the prose ones. An image_label answer lives
          // in `r.labels`, an mcq's in `r.lines`, an image_ab's in its
          // verdicts, and every one of those left the justification empty - so
          // this sheet printed "(erased or left blank)" over a fully answered
          // question, on the one screen opened to argue about its mark. Same
          // read as the record and the scoring sheet, so all three agree.
          child: Text(
            redactFor(ev, answerSummary(q, r)),
            style: context.type.bodySecondary.copyWith(height: 1.6),
          ),
        ),
        if (j.deductions.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          Panel(
            title: 'Deductions',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final JudgeNote n in j.deductions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Mono(
                              n.points.toStringAsFixed(1),
                              color: t.destText,
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(n.reason, style: context.type.body),
                            ),
                          ],
                        ),
                        if (n.evidence.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 3),
                          Text(n.evidence, style: context.type.tiny),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (j.credit.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          Panel(
            title: 'Credit',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final JudgeNote n in j.credit)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Mono(
                              '+${n.points.toStringAsFixed(1)}',
                              color: t.successText,
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(n.reason, style: context.type.body),
                            ),
                          ],
                        ),
                        if (n.evidence.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 3),
                          Text(n.evidence, style: context.type.tiny),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (j.claims.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          Panel(
            title: 'Golden Claims',
            note: 'What the reference answer required',
            child: Column(
              children: <Widget>[
                for (final JudgeNote n in j.claims)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Pill(n.verdict, switch (n.verdict) {
                          'hit' => Tone.ok,
                          'partial' => Tone.warn,
                          _ => Tone.bad,
                        }),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(n.reason, style: context.type.body),
                              if (n.evidence.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 3),
                                Text(n.evidence, style: context.type.tiny),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 9),
                        StatusBadge(n.kind, Tone.inert),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        // The reference answer and the full reasoning are folded away: they
        // are the evidence, needed when a mark is challenged rather than on
        // every read.
        Theme(
          data: Theme.of(context).copyWith(dividerColor: t.borderSubtle),
          // ITS OWN Material. An ExpansionTile is a ListTile, which paints its
          // background and its tap ink onto the nearest Material ancestor -
          // and the nearest one here is behind the sheet's own painted panel,
          // so both were drawn where nothing could see them. Flutter asserts
          // on exactly this in debug, which made the sheet impossible to pump
          // in a widget test at all. Transparent: the panel behind it already
          // carries the surface.
          child: Material(
            type: MaterialType.transparency,
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                'Reference answer and full reasoning',
                style: context.type.small.copyWith(fontWeight: FontWeight.w600),
              ),
              children: <Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Eyebrow('Reference answer'),
                      const SizedBox(height: 5),
                      Text(
                        j.referenceAnswer,
                        style: context.type.bodySecondary.copyWith(height: 1.6),
                      ),
                      const SizedBox(height: 12),
                      const Eyebrow('Scoring reasoning'),
                      const SizedBox(height: 5),
                      Text(
                        j.reasoning,
                        style: context.type.bodySecondary.copyWith(height: 1.6),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'scoredHash ${j.scoredHash}',
                        style: context.type.monoSmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
    actions: <Widget>[
      Btn('Close', onPressed: () => Navigator.of(context).pop()),
    ],
  );
}

/// The ungated raw total, and - when it disagrees with the marks - why.
///
/// ADMIN SURFACE ONLY. The marks decide the result; this explains it. Every
/// component is won or lost whole against a threshold, so a paper of
/// near-misses and a paper left blank both read `0 / n` in marks and are told
/// apart only here.
/// `etp_assessment_pro` shows the same number to the same audience and spells
/// the mismatch out in its field help; this is that sentence, on the screen
/// where the number is read rather than in a tooltip.
class _RawScoreLine extends StatelessWidget {
  final double raw;

  /// The paper's component count - the same denominator the mark above uses.
  /// 0 means the route could not say, in which case the raw prints bare rather
  /// than over a denominator guessed from the question count - see
  /// [Attempt.rawOutOf].
  final int total;

  /// The marks earned on those same components, or null when this route did
  /// not carry enough to work it out.
  final double? marks;

  const _RawScoreLine({
    required this.raw,
    required this.total,
    required this.marks,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    // "Disagrees" means the ungated total is materially ahead of the marks -
    // the case a reviewer must not miss. A 0.05 wobble is not worth a sentence,
    // so the note is earned rather than always printed.
    //
    // Both figures now span the WHOLE paper, so the comparison is like for
    // like. It was not always: the raw covered the graded components alone and
    // `marks` subtracted the objective half to match it. Comparing today's
    // whole-paper raw against that graded-only remainder would report every
    // multiple-choice paper as massively understated.
    final double? earned = marks;
    final bool understated = earned != null && raw - earned >= 0.5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              'Raw score',
              style: context.type.small.copyWith(color: t.textSecondary),
            ),
            const SizedBox(width: 8),
            Mono(
              total > 0
                  ? '${raw.toStringAsFixed(2)} / $total'
                  : raw.toStringAsFixed(2),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          understated
              ? 'Ungated quality on every answer, before the pass threshold is '
                    'applied. This paper earned partial credit that the marks '
                    'do not show: '
                    '${earned.toStringAsFixed(earned == earned.roundToDouble() ? 0 : 2)} '
                    'mark(s) against a raw ${raw.toStringAsFixed(2)}.'
              : 'Ungated quality on every answer, before the pass threshold is '
                    'applied. Same total as the mark above. Not the '
                    'candidate\'s grade, and never shown to them.',
          style: context.type.tiny.copyWith(height: 1.45),
        ),
      ],
    );
  }
}

class _Meter extends StatelessWidget {
  final String label;
  final String weight;
  final double value;
  final Color color;

  const _Meter({
    required this.label,
    required this.weight,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 130,
            child: Text(
              weight.isEmpty ? label : '$label  ($weight)',
              style: context.type.small,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(4),
                bottomRight: Radius.circular(4),
              ),
              child: LinearProgressIndicator(
                value: value.clamp(0, 1),
                minHeight: 14,
                backgroundColor: t.bgMuted,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
          const SizedBox(width: 11),
          SizedBox(
            width: 44,
            child: Text(
              value.toStringAsFixed(2),
              textAlign: TextAlign.right,
              style: context.type.mono.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A value the grader did not record, shown as absent rather than as an empty
/// cell. An audit surface must distinguish "not recorded" from "blank".
String _orDash(String v) => v.trim().isEmpty ? 'Not recorded' : v;

/// The camera snapshots AI proctoring saved for one attempt.
///
/// WHAT IT PROMISES. A failed read says so: the panel is an error, never an
/// empty box, because "no snapshots" and "could not look" lead a reviewer to
/// opposite conclusions about a candidate. Where there can be no snapshots
/// ([aiProctored] false) it never asks and draws nothing, so a storage fault
/// cannot paint a red box on every attempt of every paper.
///
/// WHY IT RE-READS. Each URL is a presigned GET that stops working after 15
/// minutes. A page left open past that would show broken thumbnails, so a tap
/// on a snapshot read more than 14 minutes ago re-reads first and opens the
/// fresh URL. The Refresh button is the same read, kept quiet: thumbnails stay
/// on screen while it runs.
class ProctoringEvidencePanel extends StatefulWidget {
  const ProctoringEvidencePanel({
    super.key,
    required this.api,
    required this.attemptId,
    required this.aiProctored,
    this.clock = DateTime.now,
  });

  /// Null in seed mode, where there is no server to hold snapshots: the panel
  /// then draws nothing and never loads.
  final ApiClient? api;
  final String attemptId;

  /// Whether this attempt can have snapshots: the paper's `ai_proctor` rule,
  /// or the attempt's AI reported a status. False: no request, nothing drawn.
  final bool aiProctored;

  /// Injected so a test can age the URLs without waiting 14 real minutes.
  final DateTime Function() clock;

  @override
  State<ProctoringEvidencePanel> createState() =>
      _ProctoringEvidencePanelState();
}

class _ProctoringEvidencePanelState extends State<ProctoringEvidencePanel> {
  static const Duration _kUrlMaxAge = Duration(minutes: 14);

  ({List<ProctoringEvidence> items, int count})? _page;
  String? _error;

  /// The server has no storage target: a calm note, not a failure.
  bool _notConfigured = false;
  bool _loading = false;

  /// The server does not have the route at all (an older backend): the
  /// feature is absent, so the panel is hidden rather than reporting an error
  /// on every attempt. See [_load] for how that is told from a real failure.
  bool _absent = false;

  /// When [_page] was read, i.e. when its URLs started their 15 minutes.
  DateTime? _readAt;

  @override
  void initState() {
    super.initState();
    // Post-frame: this setState-ing load must not run inside a build.
    if (widget.api != null && widget.aiProctored) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    final ApiClient? api = widget.api;
    if (api == null || !widget.aiProctored || _loading || !mounted) return;
    setState(() => _loading = true);
    ({List<ProctoringEvidence> items, int count})? page;
    Object? failure;
    bool notConfigured = false;
    try {
      final Map<String, dynamic> raw = await api.attemptEvidence(
        widget.attemptId,
      );
      page = ProctoringEvidence.parsePage(raw);
      // An older server sends no `storage` key and reads as configured.
      notConfigured = raw['storage'] == 'not_configured';
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _notConfigured = notConfigured;
      if (page != null) {
        _page = page;
        _error = null;
        _absent = false;
        _readAt = widget.clock();
      } else if (failure is ApiError &&
          failure.status == 404 &&
          !failure.isDomain) {
        // AN OLDER BACKEND, NOT A FAILED READ. Odoo answers a route it does
        // not know with an HTML 404, which the client turns into a 404 that
        // is not a domain refusal. A JSON 404 the API itself wrote
        // (`isDomain`, e.g. `not_found`) is a real answer and stays an error.
        _absent = true;
        _error = null;
      } else {
        // The old rows stay: they are older, not wrong, and the banner says
        // the refresh failed.
        _error = failure is ApiError
            ? failure.message
            : 'The server sent something this page could not read.';
      }
    });
  }

  Future<void> _open(ProctoringEvidence item) async {
    ProctoringEvidence shown = item;
    final DateTime? readAt = _readAt;
    if (!_loading &&
        readAt != null &&
        widget.clock().difference(readAt) > _kUrlMaxAge) {
      await _load();
      // A failed re-read is on screen as the banner; opening the old URL
      // would show a broken picture instead of saying why.
      if (!mounted || _error != null || _absent) return;
      shown =
          _page?.items.firstWhere(
            (ProctoringEvidence e) => e.key == item.key,
            orElse: () => item,
          ) ??
          item;
    }
    if (!mounted) return;
    // The whole page as a gallery, opened on this one, so a reviewer steps
    // through the sitting's snapshots without closing and re-tapping.
    final List<ProctoringEvidence> items =
        _page?.items ?? <ProctoringEvidence>[shown];
    final int at = items.indexWhere(
      (ProctoringEvidence e) => e.key == shown.key,
    );
    await showImageGallery(context, <GalleryPage>[
      for (final ProctoringEvidence e
          in at < 0 ? <ProctoringEvidence>[shown] : items)
        (url: e.url, title: e.ruleLabel, sub: _when(e)),
    ], at < 0 ? 0 : at);
  }

  static String _when(ProctoringEvidence e) =>
      e.at == null ? 'Time not recorded' : istDateTime(e.at!);

  @override
  Widget build(BuildContext context) {
    final ({List<ProctoringEvidence> items, int count})? page = _page;
    final bool show = widget.api != null && widget.aiProctored && !_absent;
    if (!show) return const SizedBox.shrink();

    final Widget body;
    if (_notConfigured) {
      body = Text(
        'Evidence storage is not set up on this server, so no snapshots are '
        'kept.',
        style: context.type.bodyMuted,
      );
    } else if (page == null && _error == null) {
      body = const EmptyLine('Loading snapshots...');
    } else if (page == null || page.items.isEmpty) {
      body = _error == null
          ? const EmptyLine('No snapshots for this attempt.')
          : const SizedBox.shrink();
    } else {
      body = Wrap(
        spacing: 12,
        runSpacing: 14,
        children: <Widget>[
          for (final ProctoringEvidence e in page.items)
            _EvidenceThumb(
              key: ValueKey<String>(e.key),
              item: e,
              caption: _when(e),
              onOpen: () => _open(e),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Panel(
          title: 'Proctoring evidence',
          note: page == null
              ? null
              : '${page.count} snapshot${page.count == 1 ? '' : 's'}',
          headActions: <Widget>[
            Btn(
              'Refresh',
              size: BtnSize.sm,
              icon: Icons.refresh,
              busy: _loading,
              tooltip:
                  'Read the snapshots again. Their links last 15 minutes, so '
                  'a page left open that long needs this to show them.',
              onPressed: _load,
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_error != null) ...<Widget>[
                Notice(
                  tone: Tone.bad,
                  strong: 'Could not read the snapshots.',
                  text: _error!,
                ),
                const SizedBox(height: 12),
              ],
              body,
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

/// One snapshot: a 160 px 4:3 thumbnail, the rule that tripped, and when.
class _EvidenceThumb extends StatelessWidget {
  const _EvidenceThumb({
    super.key,
    required this.item,
    required this.caption,
    required this.onOpen,
  });

  final ProctoringEvidence item;
  final String caption;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return SizedBox(
      width: 160,
      // Its own Material, for the focus ring: the nearest one is behind the
      // panel's painted body, where an InkWell's highlight is never seen.
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onOpen,
          borderRadius: Radii.card,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ClipRRect(
                borderRadius: Radii.card,
                child: ColoredBox(
                  color: t.bgMuted,
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: ImagePlate(
                      url: item.url,
                      onFailed: (BuildContext c) => Center(
                        child: Text('Image unavailable', style: c.type.tiny),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                item.ruleLabel,
                style: context.type.small.copyWith(fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(caption, style: context.type.tiny, maxLines: 2),
            ],
          ),
        ),
      ),
    );
  }
}
