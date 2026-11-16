// One candidate, across every assessment they have sat.
//
// A SEPARATE destination, not a mode of Attempt detail: that screen answers
// "how did this person do on THIS paper", this one answers "how have they
// done" across every sitting. Widening Attempt detail by how it was opened
// would leave one route rendering two different pages.
//
// NOTHING IS FETCHED HERE. `/api/v1/attempts` already returns every attempt the
// caller may see, in one paged call at refresh, with the candidate embedded on
// each row - so the whole history is in the store before this screen is built.
// The marks come off the server's own figures (`score_marks`, `result`), which
// list rows carry, so the grid is honest without the per-attempt detail route.
//
// TWO WRITES DO LIVE HERE, and both are PER-ATTEMPT: the operator's flag and
// the internal remark beside it. This is the one table that puts a single
// person's sittings next to each other, which makes it both the screen where
// those two are most useful and the screen where they are most easily taken for
// a note about the PERSON - so every handler below names the attempt it writes
// to, and the remark's own tooltip says so in words to the operator as well.
import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../widgets/candidate_flag_sheet.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../../widgets/skeleton.dart';
import '../../theme.dart';
import '../../nav.dart';

class CandidateDetailScreen extends StatelessWidget {
  final AppStore store;
  final String personId;

  const CandidateDetailScreen({
    super.key,
    required this.store,
    required this.personId,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (BuildContext context, _) {
      final AppTokens t = context.tokens;
      final List<Attempt> sat = store.attemptsByCandidate(personId);
      final Person? who = store.personById(personId);

      // The console-wide read has not landed yet. Distinct from "this person
      // has sat nothing", which is a real and permanent answer.
      if (who == null && sat.isEmpty) {
        if (store.loadState == LoadState.loading) {
          return const DetailScreenSkeleton();
        }
        return PageBody(
          children: <Widget>[
            Crumbs(<Crumb>[
              Crumb('All responses', () => context.nav.responses()),
              const Crumb('Candidate'),
            ]),
            PageHead(
              'Candidate not found',
              sub: 'No attempt in this console belongs to that person.',
            ),
            Panel(child: const EmptyLine('Nothing to show.')),
          ],
        );
      }

      final String name = who?.name ?? personId;

      // Counted off the RESULT, not the score, and only where the result has
      // been released: an unreleased mark is not yet a verdict, and rolling one
      // into "passed" would report an outcome nobody has been told.
      final List<Attempt> released = sat
          .where((Attempt a) => a.resultsReleased)
          .toList();
      // `verdict`, not `result`: it prefers the verdict the server already
      // reached and only re-derives when there is none. This screen spans
      // assessments, so some of them will not be cached in full, and
      // re-deriving against a default threshold would flip a released PASS to
      // a FAIL purely because its assessment happened not to be loaded.
      final int passed = released
          .where(
            (Attempt a) =>
                a.verdict(store.asmById(a.assessmentId)) == ResultState.pass,
          )
          .length;
      final int failed = released
          .where(
            (Attempt a) =>
                a.verdict(store.asmById(a.assessmentId)) == ResultState.fail,
          )
          .length;
      final int held = sat
          .where((Attempt a) => a.isDone && !a.resultsReleased)
          .length;
      final int open = sat.where((Attempt a) => !a.isDone).length;

      return PageBody(
        children: <Widget>[
          Crumbs(<Crumb>[
            Crumb('All responses', () => context.nav.responses()),
            Crumb(name),
          ]),
          PageHead(
            name,
            sub: <String>[
              if ((who?.email ?? '').isNotEmpty) who!.email,
              '${sat.length} assessment(s) sat',
            ].join('  ·  '),
          ),
          if (sat.any((Attempt a) => a.piiAnonymized)) ...<Widget>[
            const Notice(
              tone: Tone.inert,
              strong: 'Some of this candidate\'s data was erased.',
              text:
                  'The free text is gone on those attempts. Scores, flags and '
                  'the audit trail were kept, so the results stay reviewable.',
            ),
            const SizedBox(height: 12),
          ],
          KpiStrip(<Widget>[
            Kpi(
              label: 'Assessments',
              value: '${sat.length}',
              sub: 'sat in this console',
            ),
            Kpi(
              label: 'Passed',
              value: '$passed',
              sub: 'of ${released.length} released',
              valueColor: passed > 0 ? t.successText : null,
            ),
            Kpi(
              label: 'Failed',
              value: '$failed',
              sub: failed > 0 ? 'released as a fail' : 'none',
              valueColor: failed > 0 ? t.destText : null,
            ),
            Kpi(
              label: 'Awaiting release',
              value: '$held',
              sub: held > 0 ? 'submitted, marks held' : 'none held',
              valueColor: held > 0 ? t.warnText : null,
            ),
            Kpi(
              label: 'Still open',
              value: '$open',
              sub: open > 0 ? 'not submitted yet' : 'none outstanding',
            ),
          ]),
          Panel(
            title: 'Assessments Sat',
            note: 'One row per attempt, newest first',
            flush: true,
            child: DataGrid(
              // 1122 = the 940 this table has always wanted, plus the 170 the
              // Remarks column takes and the 12px gutter in front of it. Bumped
              // rather than left alone: `minWidth` is where the table starts
              // scrolling sideways, so a new fixed column at the old figure
              // would have come out of the Assessment cell instead - and the
              // paper's name over its "Submitted 4/9/2026 14:12" line is the one
              // thing here that cannot be shortened by choosing better words.
              minWidth: 1122,
              emptyMessage:
                  'This candidate has not been assigned an assessment yet.',
              emptyIcon: Icons.fact_check_outlined,
              cols: const <Col>[
                Col('Assessment', flex: 3),
                Col('State', width: 120),
                Col('Answered', width: 96, numeric: true),
                Col('Score', width: 92, numeric: true),
                Col('Result', width: 110),
                Col('Released', width: 100),
                // REMARKS THEN THE FLAG, the same pair in the same order as the
                // roster on the assessment - two tables that show one fact in
                // two places read as two different facts.
                //
                // A COLUMN OF ITS OWN, not a third thing inside the Flags cell.
                // A remark is a sentence written to be read months later, and in
                // the 120px that cell already shares with a toggle and four
                // badges it would ellipsise to about two words: enough to say a
                // remark exists, nothing about what it says. At 170 the cell
                // carries a readable opening, the tooltip carries the rest, and
                // the row opens the sitting where it is shown in full.
                Col('Remarks', width: 170),
                Col('Flags', width: 120),
              ],
              rows: sat.map((Attempt e) {
                // A stand-in rather than a SKIP when the assessment is not
                // cached: the attempt row carries its own name and its own
                // marks, so dropping it would hide a sitting that happened.
                final Assessment asm =
                    store.asmById(e.assessmentId) ??
                    Assessment.fromJson(<String, dynamic>{
                      'id': e.assessmentId,
                      'name': e.assessmentName.isEmpty
                          ? 'Assessment ${e.assessmentId}'
                          : e.assessmentName,
                    });
                // Built ONCE per row and handed to whichever shape the remark
                // cell takes: the text and the "write one" glyph are the same
                // control wearing two faces, and two closures would let them
                // drift into disagreeing about who is allowed to click.
                //
                // Null below the Admin rung, exactly like the flag beside it: a
                // read-only Manager READS what a colleague recorded - they are
                // usually the person being asked why a candidate is held up -
                // and is simply not handed a control the route answers 403 to.
                final VoidCallback? editRemark = store.can(Capability.lifecycle)
                    ? () => _editRemark(context, e, name)
                    : null;
                return GridRow(onTap: () => context.nav.attempt(e.id), <Widget>[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      GridLink(asm.name),
                      const SizedBox(height: 2),
                      Text(
                        _when(e),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.type.tiny,
                      ),
                    ],
                  ),
                  Pill.state(e.state),
                  Mono('${e.answeredCount}'),
                  Marks(e.earnedMarks(asm), e.maxMarks(asm)),
                  Pill.state(e.verdict(store.asmById(e.assessmentId))),
                  e.resultsReleased
                      ? const Pill('Released', Tone.ok)
                      : const Pill('Held', Tone.inert),
                  // D1 - THE REMARK, beside the flag and WRITEABLE from here.
                  //
                  // THIS IS THE SCREEN THAT NEEDS IT MOST. It is the only table
                  // that puts the SAME person's sittings next to each other, so
                  // it is where an operator asks "which of these did I leave a
                  // note on" - and, having found it, fixes the wording without
                  // opening three attempts in turn to look for it.
                  //
                  // PER ATTEMPT, like the flag: this row writes to THIS sitting
                  // and nothing else, so a note on the January paper never turns
                  // up on the March one two rows below. Neighbouring rows for one
                  // candidate are exactly where that is misread as "a note about
                  // the person", which is why the tooltip says so in words too.
                  //
                  // `remark:` alone reaches the store - see [_editRemark]; the
                  // flag is never sent from here, so editing prose cannot raise
                  // or clear one as a side effect.
                  e.candidateFlag.hasRemark
                      ? Tooltip(
                          // The clipped text IN FULL, and what a click does. Two
                          // lines of 170px is not a sentence written to justify a
                          // decision months later, so hover carries the rest.
                          message: editRemark == null
                              ? e.candidateFlag.remark
                              : '${e.candidateFlag.remark}\n\nClick to edit. It '
                                    'belongs to this sitting only.',
                          // WIDE, because this one carries prose. A default
                          // tooltip sizes to its content with no max, so a
                          // paragraph becomes one long strip off the edge of the
                          // window - the same reason `Btn` constrains its own.
                          constraints: const BoxConstraints(maxWidth: 340),
                          // EXCLUDED FROM SEMANTICS, as `GridLink` excludes its
                          // own: `Text` reports the WHOLE string to the
                          // accessibility tree whatever the visual crop, so a
                          // tooltip repeating it has every remark announced
                          // twice. This fixes a visual truncation, not a
                          // semantic one.
                          excludeFromSemantics: true,
                          child: _tappable(
                            editRemark,
                            Text(
                              e.candidateFlag.remark,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: context.type.bodySecondary,
                            ),
                          ),
                        )
                      // NO REMARK YET: a muted glyph, and only for a rung that
                      // can write one.
                      //
                      // The glyph rather than a dash or a placeholder sentence,
                      // because most sittings carry no remark and a line of prose
                      // on every one of those rows is noise the eye must filter
                      // before it can find the handful that do. And nothing at
                      // all for a read-only Manager: an affordance for something
                      // they cannot do is worse than a blank cell.
                      : editRemark == null
                      ? const SizedBox.shrink()
                      : _tappable(
                          editRemark,
                          Tooltip(
                            // SHORT, so it needs no width of its own. The long
                            // version of this explanation belongs on the sheet
                            // that opens, which already carries it.
                            message: 'Add an internal remark on this sitting',
                            child: Padding(
                              // A 24px target around a 16px glyph. The 170px
                              // cell is NOT the target: on most rows it is blank,
                              // and an invisible strip that wide would swallow
                              // clicks meant to open the sitting.
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                Icons.mode_comment_outlined,
                                size: 16,
                                // The SAME muted tone the clear flag wears, so
                                // the two empty affordances in one row read as
                                // one weight of invitation rather than two.
                                color: t.textMuted,
                              ),
                            ),
                          ),
                        ),
                  Wrap(
                    spacing: 4,
                    // Centred, because the toggle's 32px tap target is taller
                    // than the 20px badges beside it and a top-aligned row
                    // leaves the flag floating above them.
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      // ONE ROW, ONE SITTING. The flag belongs to the attempt,
                      // not to the person, so each row here toggles only its
                      // own: flagging the January paper leaves the March one
                      // clear, which is the whole point of a screen that lists
                      // the same candidate's assessments side by side.
                      //
                      // Drawn even when clear, unlike the badges after it - a
                      // cell that is blank until something is wrong gives the
                      // operator nothing to click, and this is the only place
                      // a flag is raised. The tap is caught by the toggle
                      // rather than the row, so clicking it does not also
                      // navigate into the attempt.
                      FlagToggle(
                        flag: e.candidateFlag,
                        // Null below the Admin rung: a read-only Manager still
                        // sees which sittings a colleague flagged, and is
                        // simply not handed a control that would answer 403.
                        onToggle: store.can(Capability.lifecycle)
                            ? () => store.flagAttempt(
                                e.id,
                                flagged: !e.candidateFlag.flagged,
                              )
                            : null,
                      ),
                      if (e.integrityAlert)
                        const StatusBadge('Integrity', Tone.warn),
                      if (e.scoreOutlier)
                        const StatusBadge('Outlier', Tone.warn),
                      if (e.autoSubmitted) const StatusBadge('Auto', Tone.warn),
                      // The paper's cap when it is loaded, else the flag.
                      if (e.limitBreached(store.asmById(e.assessmentId)))
                        ViolationBreachBadge(e),
                      if (e.aiLimitBreached(store.asmById(e.assessmentId)))
                        ViolationBreachBadge(e, ai: true),
                      if (e.piiAnonymized)
                        const StatusBadge('Erased', Tone.inert),
                    ],
                  ),
                ]);
              }).toList(),
            ),
          ),
        ],
      );
    },
  );

  /// Edit the internal remark on ONE of this candidate's sittings.
  ///
  /// `remark:` ALONE, never `flagged:`. The flag and the remark are independent
  /// fields behind one endpoint, and a key the server does not receive is a key
  /// it does not change - so echoing the flag state back alongside the prose
  /// would turn a colleague's concurrent toggle into a silent revert, and would
  /// break the promise the sheet makes in so many words: saving a remark
  /// neither raises nor clears a flag.
  ///
  /// [e] is the ATTEMPT that was clicked, not the person. Every row on this
  /// screen belongs to the same candidate, so a handler that took the person
  /// would have written one remark over all of their sittings - the exact bug
  /// the per-attempt store method was introduced to end.
  ///
  /// No `mounted` guard, and none is possible: this is a StatelessWidget. None
  /// is needed either, because nothing after the await touches the
  /// [BuildContext] - `store` is the widget's own field, so the write still
  /// lands if the operator navigates away while the sheet is open, which is the
  /// right outcome given they pressed Save.
  Future<void> _editRemark(BuildContext context, Attempt e, String name) async {
    final String? out = await askForRemark(
      context,
      candidateName: name,
      existing: e.candidateFlag.remark,
    );
    // null is CANCELLED, '' is "delete this remark". Collapsing the two would
    // make a remark impossible to remove from this screen, and reading null as
    // '' would erase one every time somebody backed out of the sheet - see the
    // contract on [askForRemark].
    if (out == null) return;
    await store.flagAttempt(e.id, remark: out);
  }

  /// The remark cell's tap target, or the bare child at a rung that may not
  /// edit.
  ///
  /// OPAQUE, so the gesture STOPS HERE. Every row on this screen navigates to
  /// its attempt and the arena resolves to exactly one detector, so without
  /// this a click on a remark would open the sitting instead of the sheet -
  /// which reads as the affordance being broken rather than as a mis-hit.
  static Widget _tappable(VoidCallback? onTap, Widget child) => onTap == null
      ? child
      : GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: child,
        );

  static String _when(Attempt e) {
    if (e.submittedAt != null) return 'Submitted ${_d(e.submittedAt!)}';
    if (e.startedAt != null) return 'Started ${_d(e.startedAt!)}';
    return 'Not started';
  }

  static String _d(DateTime d) => istTimestamp(d);
}
