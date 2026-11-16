// Pod Member: my assessments and my results.
//
// Two rules shape both screens:
//   - Invariant 3: no score is shown until a person releases it. An
//     unreleased attempt reads "Awaiting release", not a blank or a zero.
//   - Invariant 2: a released score is MARKS, never a percentage.
import 'package:flutter/material.dart';

import '../../domain/category_scores.dart' show timeUsed;
import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../widgets/buttons.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/marks.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/panel.dart';
import '../exam/exam_screen.dart';
import '../../theme.dart';
import '../../nav.dart';

class MyAssessmentsScreen extends StatefulWidget {
  final AppStore store;

  const MyAssessmentsScreen({super.key, required this.store});

  @override
  State<MyAssessmentsScreen> createState() => _MyAssessmentsScreenState();
}

/// One row: the candidate's attempt, the assessment when it is loaded, and
/// the bucket it falls in. `asm` is nullable because a candidate's own
/// endpoint does not send assessment records - only a manager's does.
typedef _Row = ({Attempt ev, Assessment? asm, Bucket bucket});

class _MyAssessmentsScreenState extends State<MyAssessmentsScreen> {
  // The bucket STARTS from the address bar (`/my-assessments?show=completed`);
  // `build` writes it back.
  late Bucket _bucket =
      Bucket.values
          .where((Bucket b) => b.wire == context.navQuery['show'])
          .firstOrNull ??
      Bucket.all;

  /// Which bucket an attempt falls into.
  ///
  /// `completed` is checked FIRST, so it wins over every assessment state - a
  /// submitted attempt on a closed assessment reads as completed, which is what
  /// the candidate did, rather than as closed, which is what happened to the
  /// assessment.
  Bucket _bucketOf(Attempt ev, Assessment? asm) {
    // THE SERVER'S ANSWER WINS. `attempt_bucket` reads the ASSESSMENT's state,
    // and a candidate never loads the assessment list - it is a manager route -
    // so `asm` below is null on the one screen this method exists for. The
    // fallback then had nothing to read and filed EVERY not-yet-started attempt
    // under "Available": an assessment the admin had marked done, and one still
    // sitting in draft, both drew a Start button whose only possible outcome
    // was the "This assessment is closed" page.
    //
    // Deriving it here at all was the mistake. The server already computes the
    // bucket, ships it, and is the authority on it; this reads it. Same shape
    // as `Attempt.verdict`, which prefers `serverResult` for the same reason.
    final Bucket? fromServer = ev.serverBucket;
    if (fromServer != null) return fromServer;
    if (ev.isDone) return Bucket.completed;
    // No bucket on the wire: the admin roster, and the seed fixtures. The
    // attempt's own state is all there is to go on.
    if (asm == null) {
      return ev.state == AttemptState.inProgress
          ? Bucket.inProgress
          : Bucket.available;
    }
    if (asm.state == AsmState.inProgress &&
        ev.state == AttemptState.inProgress) {
      return Bucket.inProgress;
    }
    if (asm.state == AsmState.inProgress) return Bucket.available;
    if (asm.state == AsmState.draft) return Bucket.upcoming;
    return Bucket.closed;
  }

  @override
  Widget build(BuildContext context) {
    final AppStore s = widget.store;
    context.setNavQuery(<String, Object?>{
      'show': _bucket == Bucket.all ? null : _bucket.wire,
    });
    return ListenableBuilder(
      listenable: s,
      builder: (BuildContext context, _) {
        final List<_Row> rows = <_Row>[];
        for (final Attempt ev in s.attemptsForPerson(s.meId)) {
          // Do NOT skip when the assessment is missing. The candidate's own
          // endpoint sends no assessment records, so skipping emptied this
          // screen entirely: it read 'All 0' while the API was returning a
          // completed sitting, and the card carries the name and marks.
          final Assessment? asm = s.asmById(ev.assessmentId);
          rows.add((ev: ev, asm: asm, bucket: _bucketOf(ev, asm)));
        }

        final Map<Bucket, int> counts = <Bucket, int>{};
        for (final _Row r in rows) {
          counts[r.bucket] = (counts[r.bucket] ?? 0) + 1;
        }

        final List<_Row> shown = _bucket == Bucket.all
            ? rows
            : rows.where((_Row r) => r.bucket == _bucket).toList();

        return PageBody(
          children: <Widget>[
            PageHead(
              'My Assessments',
              sub: 'Everything assigned to you, and where each one stands.',
            ),
            // `All` is always rendered; every other button appears ONLY when
            // its count is non-zero, so the filter row never offers an empty
            // result.
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: <Widget>[
                _BucketBtn(
                  label: 'All',
                  count: rows.length,
                  active: _bucket == Bucket.all,
                  onTap: () => setState(() => _bucket = Bucket.all),
                ),
                for (final Bucket b in Bucket.values)
                  if (b != Bucket.all && (counts[b] ?? 0) > 0)
                    _BucketBtn(
                      label: b.label,
                      count: counts[b]!,
                      active: _bucket == b,
                      onTap: () => setState(() => _bucket = b),
                    ),
              ],
            ),
            const SizedBox(height: 16),
            if (shown.isEmpty)
              Panel(
                // The candidate's own screen, so the copy is reassurance
                // rather than instruction: there is nothing for them to do
                // about an empty list, and a call to action they cannot
                // satisfy reads as a fault on their side.
                child: EmptyState(
                  icon: Icons.assignment_outlined,
                  title: rows.isEmpty
                      ? 'No assessments yet'
                      : 'Nothing in this bucket',
                  body: rows.isEmpty
                      ? 'When one is assigned to you it appears here, with '
                            'the date it opens.'
                      : 'Try All, or check back once an assessment opens.',
                  compact: false,
                ),
              )
            else
              AutoGrid(
                minWidth: 288,
                gap: 13,
                // Cards on one row share the tallest card's height, so a
                // sparse card (an unstarted Closed sitting) does not sit as
                // a stub next to a full released-result card. Safe here:
                // _AttemptCard holds no LayoutBuilder.
                equalRowHeight: true,
                children: shown
                    .map(
                      (_Row r) => _AttemptCard(
                        store: s,
                        ev: r.ev,
                        asm: r.asm,
                        bucket: r.bucket,
                      ),
                    )
                    .toList(),
              ),
          ],
        );
      },
    );
  }
}

class _BucketBtn extends StatelessWidget {
  final String label;
  final int count;
  final bool active;
  final VoidCallback onTap;

  const _BucketBtn({
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) =>
      Btn('$label  $count', pressed: active, onPressed: onTap);
}

/// `.acard` - one bucket card. Each carries the state pill, progress or
/// released marks, a violation line and ONE bucket-specific call to action.
class _AttemptCard extends StatefulWidget {
  final AppStore store;
  final Attempt ev;

  /// Null on a candidate's own list, which sends no assessment records.
  /// Everything the card needs is then read off the attempt itself.
  final Assessment? asm;
  final Bucket bucket;

  const _AttemptCard({
    required this.store,
    required this.ev,
    required this.asm,
    required this.bucket,
  });

  @override
  State<_AttemptCard> createState() => _AttemptCardState();
}

class _AttemptCardState extends State<_AttemptCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Attempt ev = widget.ev;
    final Assessment? asm = widget.asm;
    // TWO DIFFERENT NUMBERS, and they used to be one variable.
    //
    // A question is worth its COMPONENT count now - a three-sub-question mcq
    // is worth 3 - so the paper's mark total and its question count have
    // parted company. Sharing one `total` made this card print "12 questions"
    // over an eight-question paper and cap its progress bar at 8 of 12 on an
    // attempt the candidate had fully answered.
    //
    // Marks come from the SERVER when no assessment is loaded: it already
    // computed them, and this endpoint sends no per-question responses for the
    // client to recompute from.
    final int total = ev.serverTotal ?? (asm == null ? 0 : ev.maxMarks(asm));
    final int earned =
        ev.serverEarned ?? (asm == null ? 0 : ev.earnedMarks(asm));
    // The question count is a count of QUESTIONS: what the card says the paper
    // holds, and what the progress bar divides an answer count by. It reads
    // `serverQuestions`, which is parsed off `total_questions` / `progress`
    // alone - `serverTotal` is the MARK total and cannot stand in for it.
    //
    // THE ROW'S OWN COUNT WINS OVER THE CACHED ASSESSMENT. This used to be
    // `asm?.totalQuestions ?? ev.serverQuestions ?? 0`, and the bug was that
    // ZERO IS NOT NULL: opening the exam - or "See my submission" - caches an
    // assessment whose `totalQuestions` is 0, because no candidate route sends
    // it a question list. That 0 then satisfied the first `??` and won,
    // permanently, for the rest of the session. The card read "6 questions"
    // on a fresh login and "0 questions" the moment the candidate looked at
    // their own answers.
    //
    // `serverQuestions` is also the more correct source even when both are
    // present: it is THIS SITTING's paper size, which on an independent draw
    // is not the assessment's.
    final int rowQuestions = ev.serverQuestions ?? 0;
    final int asmQuestions = asm?.paperSize ?? 0;
    final int questions = rowQuestions > 0 ? rowQuestions : asmQuestions;
    final String title =
        asm?.name ??
        (ev.assessmentName.isEmpty ? 'Assessment' : ev.assessmentName);
    // The SERVER's verdict, whether or not an assessment is loaded. Branching
    // on `asm` made this card disagree with itself between refreshes: opening
    // the exam route caches an assessment that carries no pass threshold, and
    // the recomputation then judged a released result against the 70% default
    // instead of the bar the server had actually applied.
    final ResultState result = ev.verdict(asm);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: t.bgApp,
          borderRadius: Radii.panel,
          border: Border.all(color: _hover ? t.borderHover : t.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: context.type.body.copyWith(
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '$questions ${questions == 1 ? 'question' : 'questions'}'
              '  \u00b7  '
              '${asm?.durationMinutes ?? ev.durationMinutes} min',
              style: context.type.tiny,
            ),
            const SizedBox(height: 11),
            Row(
              children: <Widget>[
                _statePill(widget.bucket),
                const Spacer(),
                if (ev.isDone && ev.resultsReleased) Marks(earned, total),
              ],
            ),
            const SizedBox(height: 11),
            if (widget.bucket == Bucket.inProgress) ...<Widget>[
              ClipRRect(
                borderRadius: Radii.bar,
                child: LinearProgressIndicator(
                  value: questions == 0 ? 0 : ev.answeredCount / questions,
                  minHeight: 7,
                  backgroundColor: t.bgMuted,
                  valueColor: AlwaysStoppedAnimation<Color>(t.primary),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${ev.answeredCount} of $questions answered',
                style: context.type.tiny,
              ),
            ] else if (widget.bucket == Bucket.closed)
              // NOTHING ELSE ON A CLOSED CARD. The line below already says the
              // assessment closed without a submission, and that is the whole
              // story - "your answers are recorded and marked" beside it
              // claims work the candidate never did.
              //
              // It read that way because `isDone` is TRUE here: the wire sends
              // `state: "closed"`, `AttemptState.parse` maps that to
              // `submitted` on purpose so a released result still renders, and
              // `isDone` is `state == submitted || isLocked`. So the
              // awaiting-release branch fired on a sitting that never happened
              // - and RELEASING THE RESULTS COULD NOT CLEAR IT, because there
              // is no submission to release, so `resultsReleased` stays false
              // for good and the card was stuck on that sentence forever.
              //
              // The bucket is the safe thing to read: the server files an
              // attempt under `closed` only after `completed` has already
              // failed to match, so a candidate who DID sit it is never here.
              const SizedBox.shrink()
            else if (ev.isDone && !ev.resultsReleased)
              Text(
                // Not "and marked": an unreleased candidate row carries no
                // grading count, so written answers may still be ungraded.
                'Awaiting release. Your answers are recorded; your result is '
                'held until an administrator releases it.',
                style: context.type.tiny.copyWith(height: 1.45),
              )
            else if (ev.isDone && ev.resultsReleased)
              Row(
                children: <Widget>[
                  Pill.state(result),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ThresholdBar(
                      earned: earned,
                      total: total,
                      // The mark the server judged by, sent with the released
                      // result; the assessment is only a fallback, and the
                      // 70% default now only a last resort.
                      threshold: ev.passMarkPercent(asm),
                      result: result,
                    ),
                  ),
                ],
              ),
            // WHAT THE GREY "Pending" PILL BESIDE IT MEANS. A released result
            // whose written answers are still in the grading queue is an
            // incomplete figure, and a candidate reading "3 / 10 Pending" with
            // nothing else on the card concludes they failed.
            if (ev.isDone && ev.resultsReleased && ev.subjectivePending > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  ev.pendingMarkingNote,
                  style: context.type.tiny.copyWith(height: 1.45),
                ),
              ),
            if (timeUsed(ev, asm) case final String used
                when widget.bucket == Bucket.completed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${ev.endedOnClock ? 'Ended on the clock. ' : ''}'
                  'Time used: $used.',
                  style: context.type.tiny.copyWith(height: 1.45),
                ),
              ),
            // One line per kind: AI proctoring counts apart (R5).
            for (final (
                  int n,
                  List<({String reason, int count})> tally,
                  bool ai,
                )
                in <(int, List<({String reason, int count})>, bool)>[
                  (ev.violationCount, ev.violations, false),
                  (ev.aiViolationCount, ev.aiViolations, true),
                ])
              if (n > 0) ...<Widget>[
                const SizedBox(height: 8),
                // THE REASON, NOT ONLY THE COUNT, and the singular/plural filled
                // in. The QWeb runner carried `violation_reason` in the pill's
                // tooltip; this card printed "1 proctoring violation(s)
                // recorded." - a number, an unfinished template, and no way for
                // the candidate to know WHAT was recorded against them. Somebody
                // told they broke a rule is entitled to know which one.
                //
                // EVERY REASON, NOT JUST THE LAST ONE. `violation_reason` is only
                // the most recent event, so a candidate who breached three
                // different rules was shown one of them and told nothing about
                // the other two - on the only screen they can see. The tally now
                // arrives on `proctoring.violations` (see `attempt()` in
                // serializers.py) and is listed in full; "Last reason" stays as
                // the fallback for attempts recorded before the log existed,
                // which genuinely have no distribution to show.
                Text(
                  <String>[
                    '$n ${ai ? 'AI proctoring' : 'proctoring'} '
                        '${n == 1 ? 'violation' : 'violations'} recorded.',
                    if (tally.isNotEmpty)
                      '${tally.map((({String reason, int count}) v) => '${v.reason} (x${v.count})').join(', ')}.'
                    // The shared last reason, on the line of its own kind.
                    else if (ev.violationReason.isNotEmpty &&
                        isAiReason(ev.violationReason) == ai)
                      'Last reason: ${ev.violationReason}.',
                  ].join(' '),
                  style: context.type.tiny.copyWith(color: t.warnText),
                ),
              ],
            // The action pinned to the card FOOT: with rows equalised, the
            // spacer absorbs the height difference above the button, so
            // every card's call-to-action sits on one shared baseline.
            const SizedBox(height: 11),
            const Spacer(),
            _action(context),
          ],
        ),
      ),
    );
  }

  Widget _statePill(Bucket b) => switch (b) {
    Bucket.available => const Pill('Available', Tone.info),
    Bucket.inProgress => const Pill('In progress', Tone.info),
    Bucket.upcoming => const Pill('Upcoming', Tone.inert),
    Bucket.completed => const Pill('Completed', Tone.ok),
    Bucket.closed => const Pill('Closed', Tone.inert),
    Bucket.all => const Pill('Assigned', Tone.inert),
  };

  /// One call to action per card, chosen by bucket. A card that can do nothing
  /// says so rather than showing a disabled control with no explanation.
  Widget _action(BuildContext context) {
    final Attempt ev = widget.ev;
    return switch (widget.bucket) {
      Bucket.available => Btn.primary(
        'Start Assessment',
        expand: true,
        onPressed: () => context.nav.exam(ev.token),
      ),
      Bucket.inProgress => Btn.primary(
        'Resume',
        expand: true,
        onPressed: () => context.nav.examQuestion(
          ev.token,
          widget.asm == null ? 0 : firstUnanswered(ev, widget.asm!),
        ),
      ),
      Bucket.completed => Btn(
        ev.resultsReleased ? 'See my answers' : 'See my submission',
        expand: true,
        // A released result opens the answer sheet; an unreleased one can
        // only show that the attempt was submitted. Invariant 3: no score
        // before release.
        onPressed: () => ev.resultsReleased
            ? context.nav.examAnswers(ev.token)
            : context.nav.examComplete(ev.token),
      ),
      Bucket.upcoming => Text(
        'Opens ${_when(widget.asm?.startDate)}.',
        style: context.type.tiny,
      ),
      Bucket.closed => Text(
        'This assessment has been closed/expired without a submission '
        'from you.',
        style: context.type.tiny,
      ),
      Bucket.all => const SizedBox.shrink(),
    };
  }

  String _when(DateTime? d) =>
      d == null ? 'once it is scheduled' : istTimestamp(d);
}

/// My results: only RELEASED results, plus the candidate's own history.
class MyResultsScreen extends StatelessWidget {
  final AppStore store;

  const MyResultsScreen({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext context, _) {
        final List<Attempt> mine = store.attemptsForPerson(store.meId);
        final List<({Attempt ev, Assessment asm})> done =
            <({Attempt ev, Assessment asm})>[];
        for (final Attempt ev in mine) {
          final Assessment? asm = store.asmById(ev.assessmentId);
          if (asm != null && ev.isDone) done.add((ev: ev, asm: asm));
        }
        final List<({Attempt ev, Assessment asm})> released = done
            .where((({Attempt ev, Assessment asm}) r) => r.ev.resultsReleased)
            .toList();

        final int passed = released
            .where(
              (({Attempt ev, Assessment asm}) r) =>
                  r.ev.verdict(r.asm) == ResultState.pass,
            )
            .length;
        final int earned = released.fold<int>(
          0,
          (int a, ({Attempt ev, Assessment asm}) r) =>
              a + r.ev.earnedMarks(r.asm),
        );
        // `maxMarks`, not the question count: a paper of eight questions can
        // be a paper of fourteen marks, and summing counts against a numerator
        // of marks reported more earned than were available.
        final int outOf = released.fold<int>(
          0,
          (int a, ({Attempt ev, Assessment asm}) r) => a + r.ev.maxMarks(r.asm),
        );

        // "Best" points at ONE attempt, so marks are meaningful for it -
        // unlike an average across assessments, which would be comparing
        // different totals.
        ({Attempt ev, Assessment asm})? best;
        for (final ({Attempt ev, Assessment asm}) r in released) {
          if (best == null ||
              r.ev.internalPercent(r.asm) > best.ev.internalPercent(best.asm)) {
            best = r;
          }
        }

        return PageBody(
          children: <Widget>[
            PageHead(
              'My Results',
              sub: 'Only results an administrator has released appear here.',
            ),
            KpiStrip(<Widget>[
              Kpi(label: 'Taken', value: '${done.length}'),
              Kpi(label: 'Released', value: '${released.length}'),
              Kpi(
                label: 'Awaiting release',
                value: '${done.length - released.length}',
                valueColor: done.length > released.length ? t.warnText : null,
              ),
              Kpi(
                label: 'Passed',
                value: '$passed',
                valueColor: passed > 0 ? t.successText : null,
              ),
              Kpi(label: 'Marks earned', value: '$earned / $outOf'),
              Kpi(
                label: 'Best result',
                value: best == null
                    ? '-'
                    : '${best.ev.earnedMarks(best.asm)} / ${best.ev.maxMarks(best.asm)}',
              ),
            ]),
            Panel(
              title: 'Assessment History',
              flush: true,
              child: DataGrid(
                minWidth: 780,
                emptyMessage:
                    'You have not completed an assessment yet. Once you submit '
                    'one it appears here.',
                emptyIcon: Icons.assignment_turned_in_outlined,
                cols: const <Col>[
                  Col('Assessment', flex: 3),
                  Col('Submitted', flex: 2),
                  Col('Score', width: 110, numeric: true),
                  Col('Result', width: 110),
                ],
                rows: done
                    .map(
                      (({Attempt ev, Assessment asm}) r) => GridRow(<Widget>[
                        // .plain: this row has no destination.
                        GridLink.plain(r.asm.name),
                        Text(
                          r.ev.submittedAt == null
                              ? '-'
                              : istShortDate(r.ev.submittedAt!),
                          style: context.type.tableCell,
                        ),
                        // Invariant 3 at the row level: an unreleased row
                        // shows no number at all.
                        r.ev.resultsReleased
                            ? Marks(
                                r.ev.earnedMarks(r.asm),
                                r.ev.maxMarks(r.asm),
                              )
                            : Text(
                                'Not released',
                                style: context.type.bodyMuted,
                              ),
                        r.ev.resultsReleased
                            ? Pill.state(r.ev.verdict(r.asm))
                            : const Pill('Awaiting release', Tone.inert),
                      ]),
                    )
                    .toList(),
              ),
            ),
          ],
        );
      },
    );
  }
}
