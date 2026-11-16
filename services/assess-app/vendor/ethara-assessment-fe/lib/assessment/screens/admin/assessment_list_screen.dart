// Assessment list - HANDOVER §4.3.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../widgets/buttons.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../../widgets/controls.dart';
import '../../theme.dart';
import '../../nav.dart';
import 'assessment_detail_screen.dart' show confirmArchiveLiveSitting;

class AssessmentListScreen extends StatefulWidget {
  final AppStore store;
  final Portal portal;

  const AssessmentListScreen({
    super.key,
    required this.store,
    required this.portal,
  });

  @override
  State<AssessmentListScreen> createState() => _AssessmentListScreenState();
}

class _AssessmentListScreenState extends State<AssessmentListScreen> {
  // Search, state filter and the archive toggle START from the address bar
  // (`/assessments?state=done`) and `build` writes them back.
  late String _search = context.navQuery['q'] ?? '';
  late String _stateFilter =
      AsmState.values
          .where((AsmState st) => st.wire == context.navQuery['state'])
          .firstOrNull
          ?.wire ??
      'all';
  Timer? _debounce;

  /// A search restored from the address bar asks the server, as typing it
  /// would have. After the first frame: the store notifies, and the section
  /// above this screen is still building.
  @override
  void initState() {
    super.initState();
    if (_search.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.store.searchAssessments(_search);
    });
  }

  /// Archive one row, answering the route's live-sitting refusal.
  ///
  /// THE COUNT CAN ONLY COME FROM THE SERVER HERE. This screen holds no
  /// roster, so it cannot know whether anybody is mid-exam - and archiving is
  /// a suspend now, which stops their clock. Without this the route's refusal
  /// arrived as a toast the operator had no way to answer, and the button on a
  /// live paper simply stopped working. Same sheet as the detail header's, so
  /// the two cannot describe the same act differently.
  Future<void> _archiveRow(
    BuildContext context,
    AppStore s,
    Assessment a,
  ) async {
    final int live = await s.archiveAssessment(a.id);
    if (live == 0 || !context.mounted) return;
    if (!await confirmArchiveLiveSitting(context, live)) return;
    await s.archiveAssessment(a.id, confirmLiveAttempts: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// SERVER-BACKED, DEBOUNCED.
  ///
  /// `/assessments` accepts `search` and this screen was filtering the rows the
  /// console had already walked, so anything past that walk was unfindable.
  /// Searching now costs a request, and `SearchField` fires on every keystroke -
  /// so a straight `onChanged` wiring would be one round trip per character
  /// against a backend that sheds load at capacity. 250ms is the same window the
  /// Assign-candidates picker uses.
  ///
  /// The local predicate still runs over whatever is on screen, which is what
  /// keeps the table narrowing while the debounce is open instead of freezing on
  /// the previous term's rows.
  void _onSearch(String v) {
    setState(() => _search = v);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      widget.store.searchAssessments(v);
    });
  }

  /// Show assessments taken out of the list. Off by default - an archived
  /// assessment is one somebody filed away on purpose. On, it is how an
  /// archive pressed by mistake gets undone from the product rather than the
  /// database.
  late bool _showArchived = context.navQuery['archived'] == '1';

  @override
  Widget build(BuildContext context) {
    final AppStore s = widget.store;
    final AppTokens t = context.tokens;
    context.setNavQuery(<String, Object?>{
      'q': _search,
      'state': _stateFilter == 'all' ? null : _stateFilter,
      'archived': _showArchived ? 1 : null,
    });

    return ListenableBuilder(
      listenable: s,
      builder: (BuildContext context, _) {
        // Every COUNT below reads `live`; only the grid reads `all`. The
        // store fetches archived rows so the toggle has something to reveal
        // and Restore stays reachable, and `visibleAssessments` drops them for
        // everybody else - this screen is the one caller that asks for them
        // back, because showing them is what its toggle is for.
        final List<Assessment> live = s.visibleAssessments(widget.portal);
        final List<Assessment> all = s.visibleAssessments(
          widget.portal,
          includeArchived: true,
        );

        // THE GRID'S POOL, and the only thing a search changes. Once the server
        // has answered a term, the rows come from it - so an assessment past the
        // console-wide walk is findable. Until then, and whenever the box is
        // empty, this is the cache exactly as before: no request, no moved
        // counter.
        final SearchSlice<Assessment> hits = s.assessmentSearch;
        final List<Assessment> pool = hits.active ? hits.rows : all;
        final List<Assessment> shown = pool.where((Assessment a) {
          // ONLY the archived ones when the toggle is on - one side or the
          // other, never the union. Same rule as the question bank and the
          // generator list.
          if (a.active == _showArchived) return false;
          if (_stateFilter != 'all' && a.state.wire != _stateFilter) {
            return false;
          }
          if (_search.isEmpty) return true;
          return a.name.toLowerCase().contains(_search.toLowerCase());
        }).toList();

        // Counters. Each is a fact a person acts on, not a decoration:
        // "awaiting release" is work queued for a human, and "blocked by
        // scoring" is work queued for a human that nobody asked for.
        final int inProgress = live
            .where((Assessment a) => a.state == AsmState.inProgress)
            .length;
        final int assigned = live.fold<int>(
          0,
          (int n, Assessment a) => n + s.attemptsFor(a.id).length,
        );
        final int awaitingRelease = live.fold<int>(
          0,
          (int n, Assessment a) => n + s.releasable(a).length,
        );
        final List<Assessment> blocked = live
            .where(
              (Assessment a) =>
                  s.attemptsFor(a.id).any((Attempt e) => e.hasScoringError(a)),
            )
            .toList();

        return PageBody(
          children: <Widget>[
            PageHead(
              'Assessments',
              sub: 'Every assessment, with its sitting and release position.',
              actions: <Widget>[
                // TWO CONDITIONS, AND THEY ANSWER DIFFERENT QUESTIONS.
                // `portal` is "am I drawing the operator console"; `can` is
                // "may this operator change anything". A read-only Manager is
                // Portal.admin, so the portal check alone offered them a button
                // whose route is Admin-only and answers 403 - a dead end with
                // no explanation on screen.
                if (widget.portal == Portal.admin &&
                    s.can(Capability.configure))
                  Btn.primary(
                    'New Assessment',
                    icon: Icons.add,
                    onPressed: () => context.nav.go(const NewAssessment()),
                  ),
              ],
            ),
            KpiStrip(<Widget>[
              Kpi(label: 'Assessments', value: '${live.length}'),
              Kpi(
                label: 'Live now',
                value: '$inProgress',
                valueColor: inProgress > 0 ? t.infoText : null,
              ),
              Kpi(label: 'Candidates assigned', value: '$assigned'),
              Kpi(
                label: 'Awaiting release',
                value: '$awaitingRelease',
                sub: 'Until someone releases',
                valueColor: awaitingRelease > 0 ? t.warnText : null,
              ),
              Kpi(
                label: 'Blocked by scoring',
                value: '${blocked.length}',
                valueColor: blocked.isNotEmpty ? t.destText : null,
              ),
            ]),
            // A terminal scoring error is surfaced HERE rather than left as a
            // marker on a detail page, because the whole point of the state is
            // that somebody has to notice it.
            if (blocked.isNotEmpty) ...<Widget>[
              Notice(
                tone: Tone.bad,
                strong: '${blocked.length} assessment(s) are held on pending.',
                // NO BUTTON HERE: the queue route refuses an org-wide call
                // (`missing_target`). Recovery is per paper: "Re-score This
                // Assessment" on the assessment resets and queues its errors.
                text:
                    'An answer hit a terminal grader error. It is never retried '
                    'automatically, so the result stays pending until a person '
                    'clears it. Open the assessment to re-score it.',
              ),
              const SizedBox(height: 16),
            ],
            Panel(
              flush: true,
              toolbar: Toolbar(<Widget>[
                SearchField(
                  value: _search,
                  hint: 'Search every assessment',
                  onChanged: _onSearch,
                ),
                SelectField<String>(
                  value: _stateFilter,
                  onChanged: (String v) => setState(() => _stateFilter = v),
                  options: <(String, String)>[
                    ('all', 'Every state'),
                    for (final AsmState st in AsmState.values)
                      (st.wire, st.label),
                  ],
                ),
                const Spacer(),
                // AFTER the Spacer, with the count: the toggle and the tally
                // it changes are one control.
                Btn(
                  _showArchived ? 'Hide archived' : 'Show archived',
                  size: BtnSize.sm,
                  pressed: _showArchived,
                  onPressed: () =>
                      setState(() => _showArchived = !_showArchived),
                ),
                // WHAT THE SEARCH MATCHED, from the server, not the length of
                // the list on screen. `hits.total` is `meta.total`; when the
                // page holds fewer than that, the view is partial and says so
                // rather than reading as the whole answer.
                TagChip(
                  hits.active
                      ? '${shown.length} of ${hits.total} matching'
                      : '${shown.length} shown',
                ),
                if (hits.active && hits.partial)
                  TagChip('first ${hits.rows.length} shown'),
              ]),
              child: DataGrid(
                // 880, not 1100: the four funnel columns became one, and
                // the table now fits a 996px content area (1280 viewport
                // less the 240 rail and 44 page padding) without
                // scrolling sideways at all.
                //
                // 968, not 880, once the Archive/Restore slot arrived: 880 was
                // the width of the table WITHOUT it, and leaving it there does
                // not make the column free - `DataGrid` treats minWidth as the
                // scroll threshold, so the 88px came out of the flex columns
                // and the name silently lost that much. Still inside 996.
                minWidth: 968,
                emptyMessage: _search.isEmpty && _stateFilter == 'all'
                    ? 'No assessments yet. Create one to draw questions from an '
                          'approved bank.'
                    : 'Nothing matches that search. Clear the filters to see '
                          'every assessment.',
                emptyIcon: Icons.assignment_outlined,
                // The action differs by cause: an empty list needs an
                // assessment created, a filtered-to-nothing list needs the
                // filters cleared. One action would be wrong for one of them.
                // `emptyAction` is nullable, and null is the right answer for a
                // read-only Manager looking at a genuinely empty list: there is
                // no action they can take, and offering "Clear Filters" when no
                // filter is set would be a button that does nothing.
                emptyAction: _search.isEmpty && _stateFilter == 'all'
                    ? (s.can(Capability.configure)
                          ? Btn.primary(
                              'New Assessment',
                              size: BtnSize.sm,
                              icon: Icons.add,
                              onPressed: () =>
                                  context.nav.go(const NewAssessment()),
                            )
                          : null)
                    : Btn(
                        'Clear Filters',
                        size: BtnSize.sm,
                        onPressed: () => setState(() {
                          _search = '';
                          _stateFilter = 'all';
                        }),
                      ),
                cols: const <Col>[
                  Col('Assessment', flex: 3),
                  Col('State', width: 120),
                  Col('Generator', flex: 2),
                  Col('Questions', width: 84, numeric: true),
                  // ONE column, not four.
                  //
                  // Assigned / Submitted / Released / Awaiting were four 90px
                  // numeric columns telling one story - how far a sitting has
                  // got. Four columns of mostly-zero forced the table 1100px
                  // wide, past the 996px content area, so the last column was
                  // clipped and the reader had to compare four numerals to
                  // learn one thing. The funnel reads as a single progression.
                  Col('Progress', width: 156),
                  // WHEN IT WENT LIVE, in India time, in the slot Awaiting held:
                  // "awaiting release" still reads on the detail header and
                  // Start Here, and which run is which is the question this
                  // list could not answer. 128 fits the date on one line and
                  // lets the clock wrap under it - 36px more than Awaiting,
                  // taken from the flex columns, so `minWidth` still holds.
                  Col('Conducted', width: 128),
                  Col('Duration', width: 88, numeric: true),
                  // Unlabelled row-action slot, the shape the bank and the
                  // generator list use. Unsortable: there is no data behind
                  // it, so a sortable header would advertise an ordering that
                  // cannot exist. 880 + 88 + a gap still fits the ~996px
                  // content area without scrolling sideways.
                  Col('', width: 88, numeric: true),
                ],
                rows: shown.map((Assessment a) {
                  // Prefer the counters the API reported; fall back to counting
                  // the attempts in hand. A row loaded from /assessments has no
                  // nested attempts, so counting there would render 0 for
                  // every column. -1 is the "not sent" sentinel.
                  final List<Attempt> evs = s.attemptsFor(a.id);
                  final int assigned = a.assignedCount >= 0
                      ? a.assignedCount
                      : evs.length;
                  final int submitted = a.submittedCount >= 0
                      ? a.submittedCount
                      : evs.where((Attempt e) => e.isDone).length;
                  // Same sentinel rule as its neighbours. This was the one
                  // counter with no server fallback, so a row loaded from
                  // /assessments - which carries no nested attempts, exactly as
                  // the comment above says - rendered "0 released" beside a
                  // submitted count that came from the API.
                  final int released = a.releasedCount >= 0
                      ? a.releasedCount
                      : evs.where((Attempt e) => e.resultsReleased).length;
                  // The list route sends no question RECORDS (they belong to
                  // the detail payload), so fall back to the counts it does
                  // send. `questionLimit` is a CAP, and 0 means "no cap" - not
                  // "no questions", which is how this column came to read 0
                  // for an assessment with 11 available and 3 already served.
                  final int questionCount = a.questions.isNotEmpty
                      ? a.paperSize
                      : (a.questionLimit > 0
                            ? a.questionLimit
                            : a.questionsAvailable);
                  return GridRow(onTap: () => context.nav.assessment(a.id), <
                    Widget
                  >[
                    GridLink(a.name),
                    // "In progress" names the SITTING window - can a candidate
                    // still sit this? - not the release workflow, which is the
                    // per-attempt `resultsReleased` flag. Read beside
                    // "2 released" with nothing left awaiting, the bare chip
                    // looks like it contradicts the row, so name who is still
                    // outstanding. Marking such an assessment done would revoke
                    // the live links those candidates are holding.
                    //
                    // ARCHIVED STACKS UNDER THE STATE, it does not replace it.
                    // The two answer different questions - where is this in
                    // its lifecycle, and is it filed away - and an archived
                    // in-progress sitting is a real combination.
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        (a.state == AsmState.inProgress &&
                                assigned > submitted &&
                                assigned > 0)
                            ? Tooltip(
                                message:
                                    'Sitting window is open: '
                                    '${assigned - submitted} of $assigned '
                                    'candidates have not sat this yet. '
                                    'Releasing results does not close it.',
                                child: Pill.state(a.state),
                              )
                            : Pill.state(a.state),
                        // Only on the archived side. The toggle already says
                        // which side is on screen, but a row dragged into view
                        // by a search has to carry the fact itself.
                        if (!a.active) ...<Widget>[
                          const SizedBox(height: 3),
                          const Pill('Archived', Tone.inert),
                        ],
                        // AND SO DOES THE GRADER'S PHASE, for the same reason:
                        // "is anything scoring right now" was legible only by
                        // opening papers one at a time. The module's list has
                        // carried a Scoring column since this shipped and this
                        // screen said nothing at all, which is the reported
                        // gap.
                        //
                        // STACKED, NOT A COLUMN. The note on `minWidth` above
                        // records what a column costs here: the table sits at
                        // 968 inside a ~996px content area and four funnel
                        // columns were collapsed into one to get it there, so
                        // a ~110px addition reintroduces the sideways scroll
                        // that note exists to remember. A pill under the state
                        // is free.
                        //
                        // ONLY WHEN THERE IS SOMETHING TO SAY. Idle is the
                        // resting state of every finished paper, and a badge
                        // on every row is wallpaper - the rule `_scoringBadge`
                        // already follows on the roster. Null is a deployment
                        // that predates the field, and a confident "Idle" over
                        // a server that cannot say is worse than silence.
                        //
                        // It cannot pile up with the archived marker: the
                        // server resolves an archived assessment to `idle`
                        // ahead of every other branch, so a row carries at
                        // most two pills either way and the row height is
                        // exactly what it was.
                        if (a.scoringPhase != null &&
                            a.scoringPhase != ScoringPhase.idle) ...<Widget>[
                          const SizedBox(height: 3),
                          Pill.state(a.scoringPhase!),
                        ],
                      ],
                    ),
                    Text(
                      a.generatorName,
                      style: context.type.tableCell,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Mono('$questionCount'),
                    FunnelCell(
                      assigned: assigned,
                      submitted: submitted,
                      released: released,
                    ),
                    // "-" for a draft: it has not been conducted. The zone is
                    // printed (no screen shows an IST time without saying
                    // IST); the 128px cell wraps it under the date.
                    Text(
                      a.launchedAt == null
                          ? '-'
                          : istDateTime(a.launchedAt!),
                      style: context.type.tableCell,
                    ),
                    Mono('${a.durationMinutes}m'),
                    // Restore for an archived row, Archive for a live one -
                    // same slot, only one applies. Still no "Open" button: the
                    // whole row already navigates, and a button repeating the
                    // row's own click cost 70px and was the column being
                    // clipped. This slot earns its width because there is no
                    // other way to reach the action.
                    //
                    // Archiving is not cancelling. It files the row away and
                    // leaves the sitting window, the state and every recorded
                    // result exactly where they were.
                    //
                    // Archive/Restore is a lifecycle change, so a read-only
                    // Manager gets neither. The slot collapses rather than
                    // showing a disabled control: a greyed button invites the
                    // reader to work out what would enable it, and nothing
                    // will.
                    if (!s.can(Capability.lifecycle))
                      const SizedBox.shrink()
                    else if (a.active)
                      IconBtn(
                        Icons.archive_outlined,
                        tooltip: 'Archive',
                        onPressed: s.isBusy('archive:${a.id}')
                            ? null
                            : () => _archiveRow(context, s, a),
                      )
                    else
                      Btn(
                        'Restore',
                        tooltip:
                            'Put this assessment back in the list and back '
                            'into every figure on the dashboard. Nothing '
                            'about it changed while it was archived.',
                        size: BtnSize.sm,
                        busy: s.isBusy('archive:${a.id}'),
                        onPressed: () =>
                            s.archiveAssessment(a.id, archive: false),
                      ),
                  ]);
                }).toList(),
              ),
            ),
          ],
        );
      },
    );
  }
}
