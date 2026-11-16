// Response detail - HANDOVER 4.3, `#/admin/responses/:evId/:questionId`.
//
// A single answer as a linkable, citable route. It exists because a score has
// to be defensible to the person it was given to: the question, the answer and
// the grader's working all have to be reachable by one URL that can be pasted
// into a dispute.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../widgets/buttons.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../../widgets/rescore_sheet.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/controls.dart';
import '../../theme.dart';
import '../../nav.dart';
import '../exam/answer_layouts.dart' show mediaPlates;
import 'transcription_review.dart';

class ResponseDetailScreen extends StatefulWidget {
  final AppStore store;
  final String attemptId;
  final String questionId;

  const ResponseDetailScreen({
    super.key,
    required this.store,
    required this.attemptId,
    required this.questionId,
  });

  @override
  State<ResponseDetailScreen> createState() => _ResponseDetailScreenState();
}

class _ResponseDetailScreenState extends State<ResponseDetailScreen> {
  /// Watches for the new mark while this answer reads "Re-score queued".
  ///
  /// The label is the server's `rescore_requested`, read when the answer
  /// loads; the scoring watch that sees a run end lives on the assessment page
  /// and reloads only the ASSESSMENT. Armed only while the label shows, and it
  /// reads the light `/scoring` counters, re-reading the answer only when they
  /// move or the run is over.
  ///
  /// ponytail: no hidden-tab sleep, unlike the assessment page's watch; the
  /// tick cap bounds it. Add one if answer pages get left open in bulk.
  Timer? _rescoreWatch;
  bool _rescoreTickInFlight = false;
  int _rescoreTicks = 0;
  String? _lastNumbers;

  /// A single re-score is usually graded within a minute.
  static const Duration _kRescoreWatchEvery = Duration(seconds: 10);

  /// An hour, for a request the grader never gets to (a stalled cron).
  static const int _kRescoreWatchMaxTicks = 360;

  @override
  void initState() {
    super.initState();
    // Before the load, so its notify can arm the watch.
    widget.store.addListener(_syncRescoreWatch);
    // Hydrate from the DETAIL route. The cached answer came from the
    // `/responses` list, which omits the per-dimension marking - `lines`,
    // `subscores`, `justification` - so this screen showed a chosen option
    // and nothing about how it was scored.
    widget.store.loadResponse(widget.attemptId, widget.questionId);
  }

  @override
  void dispose() {
    widget.store.removeListener(_syncRescoreWatch);
    _rescoreWatch?.cancel();
    super.dispose();
  }

  void _syncRescoreWatch() {
    if (!mounted) return;
    final AppStore s = widget.store;
    final bool queued =
        s.isLive &&
        (s
                .attemptById(widget.attemptId)
                ?.resp[widget.questionId]
                ?.rescoreRequested ??
            false);
    if (!queued) {
      _rescoreWatch?.cancel();
      _rescoreTicks = 0;
      _lastNumbers = null;
      return;
    }
    if (_rescoreTickInFlight ||
        (_rescoreWatch?.isActive ?? false) ||
        _rescoreTicks >= _kRescoreWatchMaxTicks) {
      return;
    }
    _rescoreWatch = Timer(_kRescoreWatchEvery, _tickRescoreWatch);
  }

  Future<void> _tickRescoreWatch() async {
    final AppStore s = widget.store;
    final String? asmId = s.attemptById(widget.attemptId)?.assessmentId;
    if (!mounted || asmId == null) return;
    _rescoreTicks++;
    _rescoreTickInFlight = true;
    try {
      final ScoringPipeline? pipe = await s.loadScoring(assessmentId: asmId);
      if (!mounted) return;
      final String numbers = '${pipe?.phase}|${pipe?.summary}|${pipe?.queued}';
      // A server too old to name a phase counts as "not busy": re-reading the
      // one answer is the only way it can tell us the grade landed.
      final bool moved =
          numbers != _lastNumbers || !(pipe?.phase?.isBusy ?? false);
      _lastNumbers = numbers;
      if (moved) await s.loadResponse(widget.attemptId, widget.questionId);
    } finally {
      _rescoreTickInFlight = false;
      _syncRescoreWatch();
    }
  }

  /// Re-hydrate when the route points at a different answer. Walking between
  /// answers reuses this State, so without it the per-dimension marking stayed
  /// on the answer first opened.
  @override
  void didUpdateWidget(ResponseDetailScreen old) {
    super.didUpdateWidget(old);
    if (old.attemptId != widget.attemptId ||
        old.questionId != widget.questionId) {
      widget.store.loadResponse(widget.attemptId, widget.questionId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStore store = widget.store;
    final String attemptId = widget.attemptId;
    final String questionId = widget.questionId;
    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext context, _) {
        final Attempt? ev = store.attemptById(attemptId);
        final Assessment? asm = ev == null
            ? null
            : store.asmById(ev.assessmentId);
        final Question? q = asm?.questionById(questionId);
        final Response? r = ev?.resp[questionId];

        // A missing record is a sentence saying what to do next, never a
        // blank body - but only once the fetch has actually finished. Claiming
        // "no longer on this attempt" while still asking the server for it is a
        // statement about the data that the app has no basis for yet.
        if (ev == null || asm == null || q == null || r == null) {
          if (store.isHydrating('response', '$attemptId/$questionId')) {
            return const DetailScreenSkeleton();
          }
          return PageBody(
            children: <Widget>[
              // LIVE CRUMBS, even here. The sentence below tells the reader to
              // go back to All responses, and every crumb on this screen was a
              // dead `const Crumb` - so the one instruction the page gives was
              // the one thing it would not let them do.
              Crumbs(<Crumb>[
                Crumb('All responses', () => context.nav.responses()),
                const Crumb('Not found'),
              ]),
              const PageHead('Response not found'),
              Panel(
                child: const EmptyLine(
                  'That answer is no longer on this attempt. Go back to All '
                  'responses and pick a row from the list.',
                ),
              ),
            ],
          );
        }

        final Person? p = store.personById(ev.employeeId);
        final String who = p?.name ?? ev.employeeId;
        final Judge? j = r.judge;
        final bool canRescore =
            r.needsGrader &&
            ev.state == AttemptState.submitted &&
            store.can(Capability.lifecycle);

        return PageBody(
          children: <Widget>[
            // Three crumbs, all of them true. This was `Admin / All responses /
            // "$who  ${q.name}"` with every callback omitted, so the trail was
            // decoration - and the last crumb ran the candidate's name into the
            // question's with nothing between them ("Chakshu test Logical
            // Correctness Evaluation"), which reads as one long question title.
            //
            // The candidate goes to their HISTORY rather than to this sitting,
            // because that is the rule everywhere the console spans
            // assessments: from All responses a person's name means the person.
            // The sitting has its own button in the head.
            Crumbs(<Crumb>[
              Crumb('All responses', () => context.nav.responses()),
              if (ev.employeeId.isNotEmpty)
                Crumb(who, () => context.nav.candidate(ev.employeeId))
              else
                Crumb(who),
              Crumb(q.name),
            ]),
            PageHead(
              q.name,
              sub: '$who  \u00b7  ${asm.name}  \u00b7  ${q.taskLabelLong}',
              actions: <Widget>[
                Btn(
                  'Open Attempt',
                  onPressed: () => context.nav.attempt(ev.id),
                ),
                // Re-scoring is a lifecycle action, so a read-only Manager
                // reads the record and the failure reason without the button.
                //
                // SCORED ANSWERS TOO: a mark the admin doubts is the commonest
                // reason to re-grade. Never on an MCQ/MSQ - scored in code, so
                // there is nothing for the grader to do.
                if (canRescore) _rescoreBtn(context, store, ev, r, questionId),
              ],
            ),
            // WHY THE LAST RUN STOPPED, above the answer itself: this is the
            // page an admin opens to ask why a mark did not move.
            if (graderReasonNotice(ev) case final Widget notice) ...<Widget>[
              notice,
              const SizedBox(height: 16),
            ],
            // The one grader state that never clears itself, so it is stated
            // at the top of the record rather than left as a pill in a row.
            if (r.llmState == LlmState.error) ...<Widget>[
              Notice(
                tone: Tone.bad,
                strong: 'This answer hit a terminal grader error.',
                // NAMES THE FAILURE. This notice explained the retry POLICY and
                // never what actually went wrong, and `llm_error` - stored on
                // the model, sent by `evaluator_admin_row` - was rendered
                // nowhere in the app at all. So the one screen an operator opens
                // to diagnose a stuck attempt told them everything except the
                // reason, and "Re-score" was a guess: a bad credential and a
                // malformed rubric look identical here, and only one of them is
                // fixed by pressing it.
                text: (r.llmError ?? '').trim().isEmpty
                    ? 'It is deliberately excluded from the automatic retry '
                          'set, so it holds the whole attempt on pending until '
                          'a person clears it. The grader recorded no reason.'
                    : 'The grader reported: ${r.llmError!.trim()}\n\n'
                          'It is deliberately excluded from the automatic retry '
                          'set, so it holds the whole attempt on pending until '
                          'a person clears it.',
                actions: <Widget>[
                  if (canRescore)
                    _rescoreBtn(
                      context,
                      store,
                      ev,
                      r,
                      questionId,
                      size: BtnSize.sm,
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            Cols2(
              left: Stack16(<Widget>[
                _QuestionPanel(ev: ev, q: q, r: r),
                if (j != null)
                  _AuditPanel(ev: ev, asm: asm, q: q, r: r, judge: j),
              ]),
              right: _AttemptPanel(store: store, ev: ev, asm: asm, who: who),
            ),
          ],
        );
      },
    );
  }
}

/// "Re-score" for this one answer, or "Re-score queued" once it is asked for.
Widget _rescoreBtn(
  BuildContext context,
  AppStore store,
  Attempt ev,
  Response r,
  String questionId, {
  BtnSize size = BtnSize.md,
}) => Btn.danger(
  r.rescoreRequested ? 'Re-score queued' : 'Re-score',
  tooltip:
      'Grade this one answer again, on its own. One LLM call. The mark is '
      'replaced when the new grade succeeds; if it fails, the current mark '
      'stays.',
  size: size,
  // Disabled while queued: a second click would only join the same request.
  // And while a Kill settles, which refuses it with 409 `stopping`.
  onPressed:
      r.rescoreRequested ||
          store.asmById(ev.assessmentId)?.scoringPhase == ScoringPhase.stopping
      ? null
      // Asks first on a RELEASED result, where the call can move a mark the
      // candidate already holds. Unreleased, it goes straight through.
      : () => rescoreConfirmed(
          context,
          store,
          <String, List<String>?>{
            ev.id: <String>[questionId],
          },
          attempts: <Attempt>[ev],
        ),
);

/// What the grader last said about this CANDIDATE, when it said anything.
///
/// `subjective.error` is the reason behind two outcomes that otherwise leave no
/// trace at all on screen - a failed re-grade that kept the old mark, and a
/// call deferred for a spend cap or a 429 that spent no attempt. Both present
/// as an ordinary "Pending" without this.
///
/// THE SERVER'S OWN WORDS, verbatim. It writes a whole sentence ("Waiting to be
/// graded, no attempt used: ..." / "Re-score of Q205 failed, its previous mark
/// was kept: ..."), and sniffing that string to decide which of the two it is
/// would invent a state the payload does not carry - and get it wrong the first
/// time the module rewords one. Warn, not bad: nothing here is terminal and no
/// mark moved. [Attempt.hasScoringError] is the notice for the state that is.
Widget? graderReasonNotice(Attempt ev) {
  final String why = ev.subjectiveError.trim();
  if (why.isEmpty) return null;
  return Notice(
    tone: Tone.warn,
    strong: 'The grader left a reason on this candidate.',
    text: why,
  );
}

/// The question as the candidate met it, with what they put in and, where a
/// key exists, what it says. A subjective reference answer stays inside the
/// audit surface, next to the reasoning that used it.
class _QuestionPanel extends StatelessWidget {
  final Attempt ev;
  final Question q;
  final Response r;

  const _QuestionPanel({required this.ev, required this.q, required this.r});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Panel(
      title: 'Question',
      headActions: <Widget>[
        // `markOutOf`, not a literal 1: a question is worth its COMPONENT
        // count now - a three-sub-question mcq is out of 3 - so the hardcoded
        // denominator printed "2 / 1" and read as a broken render.
        Marks(r.mark, r.markOutOf),
        const SizedBox(width: 10),
        Pill.state(r.llmState),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            q.prompt,
            style: context.type.body.copyWith(fontSize: 14, height: 1.55),
          ),
          if (q.desc.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(q.desc, style: context.type.bodySecondary),
          ],
          // THE PICTURE THE QUESTION IS ABOUT.
          //
          // This card showed the prompt and the answer and nothing else, so a
          // labelling question read as a numbered list beside a wall of text
          // about a screenshot the reviewer could not see. A score cannot be
          // audited against a stimulus that is not on the page. The payload
          // has carried `images`/`videos` all along (`bank_question_detail`
          // emits admin proxy URLs) and `Question.fromJson` parses them - only
          // this screen never drew them. The candidate's own answer sheet got
          // this same fix; the reviewer's copy did not.
          if (q.images.isNotEmpty || q.videos.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            ...mediaPlates(
              q.images,
              q.videos,
              showRegions: q.type == QType.imageLabel,
              sideFree: q.isSideFreeAb,
            ),
          ],
          const SizedBox(height: 14),
          Eyebrow(
            q.type == QType.imageAb ? 'Candidate verdicts' : 'Candidate Answer',
          ),
          const SizedBox(height: 5),
          // PER DIMENSION, the way the module's own form does it: a multi-axis
          // question is answered per axis and a mark is defended per axis.
          // Joined into one line ("Response A, Both Good, Both Good, Response
          // A") a reader cannot tell which verdict was cast on which axis.
          //
          // The flat box stays for the shapes that have no breakdown to show:
          // a single-axis mcq, a written answer, and every seed fixture.
          if (r.details.isNotEmpty)
            _DimensionAnswers(ev: ev, q: q, lines: r.details)
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
              decoration: BoxDecoration(
                color: t.bgSubtle,
                borderRadius: Radii.buttonLg,
                border: Border.all(color: t.border),
              ),
              child: Text(
                redactFor(ev, answerSummary(q, r)),
                style: context.type.body.copyWith(height: 1.6),
              ),
            ),
          // A TRANSCRIPTION's review: the client rule, both texts, the word
          // differences, the clip answers against the correct ones, and each
          // mistake the judge weighed. Admin routes only send it.
          if (q.type == QType.transcription &&
              r.transcriptionReview != null) ...<Widget>[
            const SizedBox(height: 14),
            const Eyebrow('Transcription review'),
            const SizedBox(height: 6),
            TranscriptionReviewView(
              review: r.transcriptionReview!,
              deductions: r.judge?.deductions ?? const <JudgeNote>[],
              redact: (String text) => redactFor(ev, text),
            ),
          ],
          // The written justification, on the one type where it is a SECOND
          // answer rather than the whole of it. Everywhere else `answerSummary`
          // has already returned this prose and printing it twice would only
          // suggest there were two of them.
          if (q.type == QType.imageAb) ...<Widget>[
            const SizedBox(height: 14),
            const Eyebrow('Justification'),
            const SizedBox(height: 5),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
              decoration: BoxDecoration(
                color: t.bgSubtle,
                borderRadius: Radii.buttonLg,
                border: Border.all(color: t.border),
              ),
              child: Text(
                r.justification.trim().isEmpty
                    ? 'Left blank'
                    : redactFor(ev, r.justification),
                style: context.type.body.copyWith(height: 1.6),
              ),
            ),
          ],
          // image_ab has a real key - one correct option per dimension - and it
          // was hidden because this gate asked `isObjective`, which that type
          // is deliberately not. `hasOptionKey` is the axis that actually
          // answers "does a key exist to print".
          //
          // Suppressed once the table above is showing: it already prints the
          // key on the axis it belongs to, and a flat repeat of the same words
          // underneath reads as a second, different key.
          if (q.type.hasOptionKey && r.details.isEmpty) ...<Widget>[
            const SizedBox(height: 14),
            const Eyebrow('Correct Answer'),
            const SizedBox(height: 5),
            Text(
              correctSummary(q, r),
              style: context.type.body.copyWith(color: t.successText),
            ),
          ],
        ],
      ),
    );
  }
}

/// The answer, one row per dimension - Odoo's "Dimension Answers" list.
///
/// The key is printed ONLY beside a pick that missed it - a correct row already
/// says what the key was, and repeating it everywhere buries the misses.
///
/// `is_correct` comes off the response line rather than being recomputed
/// against the question. On an axis whose key was never set, "not correct" and
/// "no key" are different facts, and only the server can tell them apart.
class _DimensionAnswers extends StatelessWidget {
  final Attempt ev;
  final Question q;
  final List<ResponseLine> lines;

  const _DimensionAnswers({
    required this.ev,
    required this.q,
    required this.lines,
  });

  /// The correct option on one axis, named. Empty when the question record is
  /// not loaded or that axis has no key - both of which print nothing rather
  /// than a guess.
  String _keyFor(ResponseLine l) {
    for (final QDimension d in q.dims) {
      if (d.id != l.dimensionId && d.name != l.dimensionName) continue;
      for (final QOption o in d.options) {
        if (o.correct) return o.label;
      }
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 2),
      decoration: BoxDecoration(
        color: t.bgSubtle,
        borderRadius: Radii.buttonLg,
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < lines.length; i++)
            KvRow(
              // Unnamed axes still get a row: a missing label must not silently
              // drop a verdict the candidate actually cast.
              lines[i].dimensionName.isEmpty
                  ? 'Dimension ${i + 1}'
                  : lines[i].dimensionName,
              _Pick(line: lines[i], ev: ev, expected: _keyFor(lines[i])),
              last: i == lines.length - 1,
            ),
        ],
      ),
    );
  }
}

/// One pick: what they chose, whether it was right, and what was right when it
/// was not.
class _Pick extends StatelessWidget {
  final ResponseLine line;
  final Attempt ev;
  final String expected;

  const _Pick({required this.line, required this.ev, required this.expected});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final String picked = line.optionName.isEmpty
        ? 'Nothing selected'
        : redactFor(ev, line.optionName);

    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 7,
      runSpacing: 3,
      children: <Widget>[
        Text(
          picked,
          textAlign: TextAlign.right,
          style: context.type.body.copyWith(
            fontWeight: FontWeight.w600,
            color: line.isCorrect ? t.successText : null,
          ),
        ),
        Icon(
          line.isCorrect ? Icons.check_circle_outline : Icons.cancel_outlined,
          size: 14,
          color: line.isCorrect ? t.successText : t.destText,
        ),
        if (!line.isCorrect && expected.isNotEmpty)
          StatusBadge('Key: $expected', Tone.inert),
      ],
    );
  }
}

/// The grader's working, summarised. Everything here is also in the full audit
/// sheet; this panel is the part a reviewer reads before deciding whether the
/// full one is worth opening.
class _AuditPanel extends StatelessWidget {
  final Attempt ev;
  final Assessment asm;
  final Question q;
  final Response r;
  final Judge judge;

  const _AuditPanel({
    required this.ev,
    required this.asm,
    required this.q,
    required this.r,
    required this.judge,
  });

  @override
  Widget build(BuildContext context) => Panel(
    title: 'Grader Audit',
    headActions: <Widget>[
      Btn(
        'View',
        tooltip:
            'The grader\'s complete working: rubric, evidence, lane '
            'scores and the model that produced them.',
        size: BtnSize.sm,
        onPressed: () =>
            showAuditSheet(context, ev: ev, asm: asm, q: q, r: r, judge: judge),
      ),
    ],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Three outcomes, not two: with a question worth its component count,
        // `mark > 0` is no longer "the question was earned", so a partial must
        // not paint the same green as full marks.
        Notice(
          tone: r.mark <= 0
              ? Tone.warn
              : (r.mark >= r.markOutOf ? Tone.ok : Tone.info),
          strong: 'Verdict.',
          text: redactFor(ev, judge.verdict),
        ),
        if (ev.piiAnonymized) ...<Widget>[
          const SizedBox(height: 12),
          const Notice(
            tone: Tone.inert,
            strong: 'Grader prose is redacted for this candidate.',
            text:
                'The gate, the flags, the numeric scores and the pass or '
                'fail are deliberately kept, so integrity review still '
                'works after an erase.',
          ),
        ],
        const SizedBox(height: 12),
        KvRow.text('Profile', judge.profile),
        KvRow('Gate', gateBadge(judge)),
        KvRow('Key closeness', Mono(pct(judge.keyCloseness))),
        KvRow('SOP coverage', Mono(pct(judge.sopCoverage))),
        KvRow('Subjective raw', Mono(rawFromHundred(judge.raw100))),
        KvRow.text('Clarity', judge.clarity),
        KvRow.text('Rubric source', judge.rubricSource),
        KvRow('Judge model', Mono(judge.judgeModel)),
        KvRow('Grader attempts', Mono('${judge.attempts}'), last: true),
      ],
    ),
  );
}

/// The attempt this answer belongs to. It carries the result, which is the
/// figure the answer can change, and the release flag, which is the one it
/// cannot.
class _AttemptPanel extends StatelessWidget {
  final AppStore store;
  final Attempt ev;
  final Assessment asm;
  final String who;

  const _AttemptPanel({
    required this.store,
    required this.ev,
    required this.asm,
    required this.who,
  });

  @override
  Widget build(BuildContext context) {
    final int unresolved = ev.unresolvedQuestionIds(asm).length;
    return Panel(
      title: 'Attempt',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          KvRow.text('Candidate', who),
          KvRow.text('Assessment', asm.name),
          KvRow('Attempt state', Pill.state(ev.state)),
          KvRow('Result', Pill.state(ev.verdict(asm))),
          // `maxMarks`, not `totalQuestions`. Two bugs in one expression: the
          // question count is no longer the mark count, and reading it here
          // also threw away the server's own total on a route that sends it.
          KvRow('Marks so far', Marks(ev.earnedMarks(asm), ev.maxMarks(asm))),
          KvRow(
            'Released',
            ev.resultsReleased
                ? const Pill('Released', Tone.ok)
                : const Pill('Held', Tone.inert),
          ),
          KvRow('Unresolved answers', Mono('$unresolved')),
          KvRow(
            'Violations',
            ev.limitBreached(asm)
                ? ViolationBreachBadge(ev, cap: asm.maxViolations)
                : Mono('${ev.violationCount}'),
          ),
          // The AI watch's own count, where the paper ran it (or the sitting
          // has one) - the attempt page's rule for its card.
          if (asm.rules[ProctorRule.aiProctor] || ev.aiViolationCount > 0)
            KvRow(
              'AI violations',
              ev.aiLimitBreached(asm)
                  ? ViolationBreachBadge(ev, cap: asm.aiMaxViolations, ai: true)
                  : Mono('${ev.aiViolationCount}'),
            ),
          if (aiStatusLine(ev.aiStatus) case final String line)
            KvRow.text('AI proctoring', line),
          KvRow(
            'PII',
            ev.piiAnonymized
                ? const StatusBadge('Anonymized', Tone.inert)
                : Text('Retained', style: context.type.body),
            last: true,
          ),
          const SizedBox(height: 12),
          Btn(
            'Open the Full Attempt',
            expand: true,
            onPressed: () => context.nav.attempt(ev.id),
          ),
        ],
      ),
    );
  }
}

// ── The audit sheet, and the helpers every response surface shares ────────

/// Whether the AI watch ran on the candidate's device (`ai_status`), as one
/// grey line. Null when it never reported (an older app, or no AI rule).
///
/// The candidate's browser says this of itself, so the line says so: it is
/// not evidence the watch ran. `running_gaze` and `gaze_failed` come from
/// sittings before eye movement was removed (19 Oct); both had the AI running.
String? aiStatusLine(String status) {
  final String? line = switch (status) {
    'failed' => 'AI proctoring could not start',
    'running' || 'running_gaze' || 'gaze_failed' => 'AI proctoring: running',
    _ => null,
  };
  return line == null ? null : "$line (reported by the candidate's device)";
}

/// The wide audit sheet - HANDOVER 4.5. Opened from here and from the row
/// action in All responses, so both routes show one identical account of how
/// the mark was reached.
Future<void> showAuditSheet(
  BuildContext context, {
  required Attempt ev,
  required Assessment asm,
  required Question q,
  required Response r,
  required Judge judge,
}) => showSheet<void>(
  context,
  title: 'Scoring Audit',
  sub: '${q.name}  \u00b7  ${q.taskLabelLong}',
  wide: true,
  body: _AuditBody(ev: ev, asm: asm, q: q, r: r, judge: judge),
  actions: <Widget>[
    Builder(
      builder: (BuildContext ctx) =>
          Btn('Close', onPressed: () => Navigator.of(ctx).pop()),
    ),
  ],
);

class _AuditBody extends StatelessWidget {
  final Attempt ev;
  final Assessment asm;
  final Question q;
  final Response r;
  final Judge judge;

  const _AuditBody({
    required this.ev,
    required this.asm,
    required this.q,
    required this.r,
    required this.judge,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Marks(r.mark, r.markOutOf),
            Pill.state(r.llmState),
            StatusBadge(judge.profile, Tone.inert),
            gateBadge(judge),
            StatusBadge('Rubric: ${judge.rubricSource}', Tone.inert),
          ],
        ),
        const SizedBox(height: 12),
        Notice(
          tone: r.mark > 0 ? Tone.ok : Tone.warn,
          strong: 'Verdict.',
          text: redactFor(ev, judge.verdict),
        ),
        const SizedBox(height: 14),
        Eyebrow(
          q.type == QType.imageAb
              ? 'How each mark was decided'
              : 'How the raw score was reached',
        ),
        const SizedBox(height: 8),
        // Each meter names the rule that turned it into marks. THIS IS THE
        // DIALOG AN OPERATOR OPENS TO DEFEND A DISPUTED MARK, so a figure
        // whose rule is not printed beside it cannot be checked by the person
        // the mark was given to, and vague arithmetic here beats wrong
        // arithmetic by a distance.
        //
        // image_ab USED TO BLEND: 0.75 of the raw from the verdicts, 0.25 from
        // the written justification, one number out, and the mark taken as the
        // AND of the two halves. The blend, the two weights and the
        // conjunction are all gone. THE UNIT IS THE COMPONENT NOW - one mark
        // per keyed sub-question, one for the graded write-up - so every
        // verdict axis is decided on its own and the justification is decided
        // on its own beside them. Nothing here is weighted into anything else,
        // and there is no longer any way for a blank write-up to take an
        // already-earned verdict mark down with it.
        //
        // WHICH IS WHY THE HEADING SPLITS BY TYPE. The generic subjective
        // lanes below genuinely do build a raw and only a raw, so "How the raw
        // score was reached" is still exactly what they are. The verdict axes
        // are deterministic key matches that carry NO RAW AT ALL - they are
        // excluded from the raw score's numerator and from its denominator -
        // so the same heading over them would promise an arithmetic that does
        // not exist, and an operator reading it would go looking for the
        // number that turned three axes into three marks. There isn't one.
        //
        // The threshold is printed against the graded raw alone, because that
        // is now the only figure it is ever applied to. No verdict is waiting
        // on it.
        if (q.type == QType.imageAb) ...<Widget>[
          _Meter(
            label: 'Verdicts',
            value: (r.subscores?.abVerdictPct ?? 0) / 100,
            note: 'one mark per axis, each won or lost alone; no raw',
            fill: t.seq3,
          ),
          const SizedBox(height: 9),
          _Meter(
            label: 'Justification',
            value: (r.subscores?.abJustificationPct ?? 0) / 100,
            note:
                'one mark of its own, earned when its graded raw clears '
                'the threshold',
            fill: t.seq2,
          ),
          const SizedBox(height: 9),
          _Meter(
            label: 'Graded raw',
            value: (r.subscores?.abFinalPct ?? judge.raw100) / 100,
            note:
                'the justification alone; threshold '
                '${rawFromHundred(asm.barFor(q.type))}',
            fill: t.seq1,
            display: rawFromHundred(r.subscores?.abFinalPct ?? judge.raw100),
          ),
        ] else ...<Widget>[
          _Meter(
            label: 'Key closeness',
            value: judge.keyCloseness,
            note: 'weight 0.60',
            fill: t.seq3,
          ),
          const SizedBox(height: 9),
          _Meter(
            label: 'SOP coverage',
            value: judge.sopCoverage,
            note: 'weight 0.25',
            fill: t.seq2,
          ),
          const SizedBox(height: 9),
          _Meter(
            label: 'Subjective raw',
            value: judge.raw100 / 100,
            note: 'threshold ${rawFromHundred(asm.barFor(q.type))}',
            fill: t.seq1,
            display: rawFromHundred(judge.raw100),
          ),
        ],
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            StatusBadge('Clarity: ${judge.clarity}', Tone.inert),
            StatusBadge(
              'AI-likeness: ${judge.aiConfidence}',
              judge.aiConfidence == 'likely' ? Tone.warn : Tone.inert,
            ),
            StatusBadge(
              'Verdict: ${judge.verdictConsistency}',
              judge.verdictConsistency == 'consistent' ? Tone.inert : Tone.warn,
            ),
            StatusBadge(
              judge.raw100 >= asm.barFor(q.type)
                  ? 'At or above threshold'
                  : 'Below threshold',
              judge.raw100 >= asm.barFor(q.type) ? Tone.inert : Tone.warn,
            ),
          ],
        ),
        const Hr(),
        const SizedBox(height: 6),
        const Eyebrow('Candidate Answer'),
        const SizedBox(height: 5),
        // The same breakdown the record itself shows. The sheet is opened to
        // argue about a mark, and "Response A, Both Good, Both Good, Response
        // A" cannot be argued about: it does not say which axis lost.
        if (r.details.isNotEmpty)
          _DimensionAnswers(ev: ev, q: q, lines: r.details)
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            decoration: BoxDecoration(
              color: t.bgSubtle,
              borderRadius: Radii.buttonLg,
              border: Border.all(color: t.border),
            ),
            child: Text(
              redactFor(ev, answerSummary(q, r)),
              style: context.type.body.copyWith(height: 1.6),
            ),
          ),
        if (judge.deductions.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          const Eyebrow('Deductions'),
          const SizedBox(height: 5),
          for (final JudgeNote n in judge.deductions)
            _NoteRow(note: n, ev: ev, tone: Tone.bad),
        ],
        if (judge.credit.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          const Eyebrow('Credit'),
          const SizedBox(height: 5),
          for (final JudgeNote n in judge.credit)
            _NoteRow(note: n, ev: ev, tone: Tone.ok),
        ],
        if (judge.claims.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          const Eyebrow('Golden claims'),
          const SizedBox(height: 5),
          for (final JudgeNote n in judge.claims) _ClaimRow(note: n, ev: ev),
        ],
        const SizedBox(height: 14),
        _Disclosure(ev: ev, judge: judge),
      ],
    );
  }
}

/// A labelled proportion bar. The numeral is printed beside the bar because
/// the dark chart palette sits at deltaE 7.3, where colour alone is not
/// allowed to carry meaning.
class _Meter extends StatelessWidget {
  final String label;
  final double value;
  final String note;
  final Color fill;
  final String? display;

  const _Meter({
    required this.label,
    required this.value,
    required this.note,
    required this.fill,
    this.display,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(label, style: context.type.bodySecondary),
            const SizedBox(width: 8),
            Text(note, style: context.type.tiny),
            const Spacer(),
            Mono(display ?? pct(value), weight: FontWeight.w600),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: Radii.bar,
          child: LinearProgressIndicator(
            value: value.clamp(0, 1),
            minHeight: 7,
            backgroundColor: t.bgMuted,
            valueColor: AlwaysStoppedAnimation<Color>(fill),
          ),
        ),
      ],
    );
  }
}

class _NoteRow extends StatelessWidget {
  final JudgeNote note;
  final Attempt ev;
  final Tone tone;

  const _NoteRow({required this.note, required this.ev, required this.tone});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Color fg = tone == Tone.ok ? t.successText : t.destText;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.borderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 52,
            child: Mono(
              '${note.points > 0 ? '+' : ''}${note.points.round()}',
              color: fg,
              weight: FontWeight.w600,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(note.reason, style: context.type.body),
                if (note.evidence.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    redactFor(ev, note.evidence),
                    style: context.type.tiny.copyWith(height: 1.5),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ClaimRow extends StatelessWidget {
  final JudgeNote note;
  final Attempt ev;

  const _ClaimRow({required this.note, required this.ev});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Tone tone = switch (note.verdict) {
      'hit' => Tone.ok,
      'partial' => Tone.warn,
      _ => Tone.bad,
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.borderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Pill(note.verdict.isEmpty ? 'unknown' : note.verdict, tone),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(note.reason, style: context.type.body),
                if (note.evidence.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    redactFor(ev, note.evidence),
                    style: context.type.tiny.copyWith(height: 1.5),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 9),
          if (note.kind.isNotEmpty) StatusBadge(note.kind, Tone.inert),
        ],
      ),
    );
  }
}

/// The reference answer, the full reasoning and the scored hash. Folded away
/// by default because the reference answer is the one thing on this sheet a
/// reviewer must not read before forming their own view.
class _Disclosure extends StatefulWidget {
  final Attempt ev;
  final Judge judge;

  const _Disclosure({required this.ev, required this.judge});

  @override
  State<_Disclosure> createState() => _DisclosureState();
}

class _DisclosureState extends State<_Disclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Judge j = widget.judge;
    void toggle() => setState(() => _open = !_open);
    return Container(
      decoration: BoxDecoration(
        color: t.bgSubtle,
        borderRadius: Radii.option,
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // The whole strip toggles, matching the shared `Disclosure`. The tap
          // used to sit on the label alone, so the chevron - the part that
          // most looks like the control - did nothing.
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 11,
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: LinkBtn(
                        _open
                            ? 'Hide the reference answer and reasoning'
                            : 'Show the reference answer and reasoning',
                        onPressed: toggle,
                      ),
                    ),
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: t.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(13, 0, 13, 11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Eyebrow('Reference answer'),
                  const SizedBox(height: 4),
                  Text(
                    j.referenceAnswer.isEmpty
                        ? 'None recorded.'
                        : j.referenceAnswer,
                    style: context.type.bodySecondary.copyWith(height: 1.6),
                  ),
                  const SizedBox(height: 10),
                  const Eyebrow('Scoring reasoning'),
                  const SizedBox(height: 4),
                  Text(
                    redactFor(
                      widget.ev,
                      j.reasoning.isEmpty ? 'None recorded.' : j.reasoning,
                    ),
                    style: context.type.monoSmall.copyWith(height: 1.6),
                  ),
                  const SizedBox(height: 10),
                  const Eyebrow('Scored hash'),
                  const SizedBox(height: 4),
                  Mono(j.scoredHash.isEmpty ? '-' : j.scoredHash, size: 11),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── Shared formatting, used by All responses as well ──────────────────────

/// What the candidate put in, as one line a table cell or a panel can print.
///
/// THE SERVER'S OWN STRING WINS. Every branch below joins `r.lines` back to
/// `q.dims[].options[]` to name a pick - and most admin surfaces do not hold
/// those options. `/api/v1/responses` sends a question NAME and TYPE and no
/// options; an assessment's question list is the bank ROW shape, which carries
/// `dimension_count` rather than the dimensions. With nothing on either side of
/// the join, every objective answer on every admin screen printed "Nothing
/// selected" next to a mark of 1/1.
///
/// The module resolves the labels itself and has sent `answer_summary` on every
/// response row all along. The local join stays as the fallback: it is what the
/// seed fixtures and the exam runner need, neither of which has a server to ask.
String answerSummary(Question q, Response r) {
  if (r.serverAnswerSummary.trim().isNotEmpty) return r.serverAnswerSummary;
  if (q.type.isObjective) {
    final List<String> picked = <String>[
      for (final QDimension d in q.dims)
        for (final QOption o in d.options)
          if (r.lines.contains(o.id)) o.label,
    ];
    // `lines` non-empty with nothing resolved means the options simply are not
    // loaded on this row - say nothing rather than assert the candidate left
    // it blank, which is a different and much more damaging claim.
    if (picked.isEmpty && r.lines.isNotEmpty) return 'Answered';
    return picked.isEmpty ? 'Nothing selected' : picked.join(', ');
  }
  if (q.type == QType.imageLabel) {
    // SORTED BY BOX NUMBER. A map's iteration order is insertion order, which
    // here is whatever order the candidate happened to fill the boxes in - so
    // an unsorted read printed box 46 before box 1 and could not be read back
    // against the image. (The map itself was empty until the module started
    // sending `label_answers`; this branch printed "No boxes labelled" over a
    // fully answered question.)
    final Map<int, String> l = r.labels ?? const <int, String>{};
    final List<int> boxes =
        l.entries
            .where((MapEntry<int, String> e) => e.value.trim().isNotEmpty)
            .map((MapEntry<int, String> e) => e.key)
            .toList()
          ..sort();
    if (boxes.isEmpty) return 'No boxes labelled';
    return boxes.map((int k) => 'Box $k: ${l[k]!.trim()}').join('  \u00b7  ');
  }
  // image_ab's ANSWER is the verdicts, not the prose.
  //
  // It fell through to the justification below, so three quarters of the mark -
  // the four dimension verdicts the score is actually computed from - appeared
  // on no admin screen at all, and a reviewer reading "Candidate Answer" was
  // shown only the write-up. Named per axis rather than joined flat: four bare
  // "Response A"s in a row cannot be read back against a key.
  if (q.type == QType.imageAb) {
    final List<String> picked = <String>[
      for (final QDimension d in q.dims)
        for (final QOption o in d.options)
          if (r.lines.contains(o.id)) '${d.name}: ${o.label}',
    ];
    return picked.isEmpty ? 'Nothing selected' : picked.join('  \u00b7  ');
  }
  if (r.justification.trim().isNotEmpty) return r.justification;
  // A LIST ROW SENDS NO TEXT, only `justification_preview`, so this read
  // "Left blank" over every written answer on All Responses. A server too old
  // to send the preview cannot say whether it was blank: "-", not a claim.
  final String? preview = r.justificationPreview;
  if (preview == null) return '-';
  return preview.trim().isEmpty ? 'Left blank' : preview;
}

/// The answer key, for every type whose key IS its options - mcq, msq and
/// image_ab. Named per axis on the multi-dimension types so it lines up with
/// [answerSummary] and can be read back against it row by row.
///
/// Same rule as [answerSummary]: the module's `correct_summary` wins where it
/// sent one, because rebuilding the key needs the per-option `is_correct` flags
/// and the shapes that reach these screens do not carry them. That is why a
/// question with a full key printed "No key recorded" next to the mark it had
/// awarded.
String correctSummary(Question q, [Response? r]) {
  if ((r?.serverCorrectSummary ?? '').trim().isNotEmpty) {
    return r!.serverCorrectSummary;
  }
  final bool perAxis = q.dims.length > 1;
  final List<String> key = <String>[
    for (final QDimension d in q.dims)
      for (final QOption o in d.options)
        if (o.correct) perAxis ? '${d.name}: ${o.label}' : o.label,
  ];
  if (key.isEmpty) return 'No key recorded';
  return key.join(perAxis ? '  ·  ' : ', ');
}

/// An erased candidate keeps every score and flag but loses every word they or
/// the grader wrote, so free text is replaced rather than blanked - a blank
/// would read as an unanswered question.
String redactFor(Attempt ev, String text) =>
    ev.piiAnonymized ? '[erased]' : text;

/// The judge gate as a mark. `passed` is a state that carries no judgement, so
/// it stays inert; anything else is a caution a reviewer should see.
Widget gateBadge(Judge j) {
  final String g = j.gate.isEmpty ? 'none' : j.gate;
  return StatusBadge(g, isGated(j) ? Tone.warn : Tone.inert);
}

/// Whether the integrity gate flagged this answer. Advisory only: invariant 6
/// says a flag never changes a score.
bool isGated(Judge? j) =>
    j != null && j.gate.isNotEmpty && j.gate != 'none' && j.gate != 'passed';

/// A 0-1 proportion as a two-decimal figure. Never a candidate's score - this
/// is a grader diagnostic, and marks are the only score anybody is shown.
String pct(double v) => v.toStringAsFixed(2);
