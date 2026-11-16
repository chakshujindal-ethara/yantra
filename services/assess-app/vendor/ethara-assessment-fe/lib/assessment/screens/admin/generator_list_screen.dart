// Generators list - HANDOVER 4.3.
//
// One generator per SOP, with its generation state and draft backlog. The
// screen's job is to make two things impossible to miss: how much work is
// waiting for a human at the approval gate, and whether the same SOP has been
// scoped twice.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../widgets/import_sheet.dart';
import '../../widgets/buttons.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/delete_sheet.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../../widgets/controls.dart';
import '../../theme.dart';
import '../../nav.dart';

/// Whether the generator list and the generator page offer Delete. OFF.
///
/// Delete erases a generator nothing uses with its drafts and SOP files, and
/// moves one an assessment uses to Deleted with no way back. Archive does what
/// an operator retiring a generator needs, and Restore undoes it. Hidden in
/// the UI only: the route, the store call and the sheet behind it are
/// untouched, and the tests of that flow turn this on.
///
/// Not `@visibleForTesting`, unlike `showQuestionDelete`: the generator page
/// reads it too, and one switch must govern both screens.
bool showGeneratorDelete = false;

/// The name a generator is created with, before anybody has chosen one.
///
/// It has to be SOMETHING: `/generators/create` answers 422 on a blank name,
/// and a nameless row cannot be picked out of the list. Named here rather than
/// inlined so the test that proves the title opens ready to type can assert
/// against the same string the screen writes.
const String kNewGeneratorName = 'Untitled generator';

class GeneratorListScreen extends StatefulWidget {
  final AppStore store;

  const GeneratorListScreen({super.key, required this.store});

  @override
  State<GeneratorListScreen> createState() => _GeneratorListScreenState();
}

class _GeneratorListScreenState extends State<GeneratorListScreen> {
  // Search and the archive toggle START from the address bar and `build`
  // writes them back.
  late String _search = context.navQuery['q'] ?? '';
  Timer? _debounce;

  /// A search restored from the address bar asks the server, as typing it
  /// would have. After the first frame: the store notifies, and the section
  /// above this screen is still building.
  @override
  void initState() {
    super.initState();
    if (_search.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.store.searchGenerators(_search);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// SERVER-BACKED, DEBOUNCED - the same shape as the other two list screens;
  /// see `assessment_list_screen.dart` for the reasoning. `/generators` accepted
  /// `search` all along and `api_client.generators()` was dropping it, so the
  /// parameter had to be added before this could be wired at all.
  void _onSearch(String v) {
    setState(() => _search = v);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      widget.store.searchGenerators(v);
    });
  }

  /// Ticked rows, by generator id. See [GridRow.id] for why not indices.
  Set<String> _picked = <String>{};
  bool _deleting = false;

  /// Show generators taken out of service. Off by default - an archived
  /// generator is one somebody removed on purpose. On, it is how an archive
  /// pressed by mistake gets undone from the product rather than the database.
  late bool _showArchived = context.navQuery['archived'] == '1';

  /// Show generators Delete could not erase because an assessment uses them.
  /// Out of every list and out of Archived for good; only this view lists
  /// them, read-only. Exclusive with [_showArchived].
  late bool _showDeleted = context.navQuery['deleted'] == '1';

  /// The side of the list a row belongs to under the current toggles.
  bool _onSide(Generator g) => _showDeleted
      ? g.deleted
      : !g.deleted && g.active != _showArchived;

  /// Delete generators, after showing exactly what it costs.
  ///
  /// The preview is the server's, not a guess: a generator takes its drafts and
  /// its SOP files with it, and the questions it authored leave the bank under
  /// the retire-or-erase rule - the ones an assessment already uses are kept,
  /// out of the bank, with their answers intact.
  Future<void> _delete(List<String> ids, {required String subject}) async {
    if (ids.isEmpty) return;
    setState(() => _deleting = true);
    try {
      final DeletePreview? preview = await widget.store.previewGeneratorDelete(
        ids,
      );
      if (!mounted || preview == null) return;
      final bool go = await confirmDelete(
        context,
        subject: subject,
        preview: preview,
        isGenerator: true,
      );
      if (!go) return;
      await widget.store.deleteGenerators(ids);
      // Only the rows just sent away: a row Delete must not wipe a selection
      // the operator was building elsewhere in the table.
      if (mounted) setState(() => _picked = _picked.difference(ids.toSet()));
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  /// Create a generator and go straight to it.
  ///
  /// NOTHING IS ASKED FOR FIRST: the sheet, and before it the whole page, that
  /// collected the name and the SOP asked for fields the generator's own screen
  /// already shows and can edit - a form in front of a form. It opens on the
  /// corpus tab with the placeholder name ready to type over.
  ///
  /// The trade: a mis-click leaves a real, empty generator, to be archived.
  Future<void> _create() async {
    final String? id = await widget.store.addGenerator(kNewGeneratorName);
    if (!mounted) return;
    // Only navigate on success. Landing on a generator page after a failed
    // create used to look like the step had worked.
    //
    // `tab: 'corpus'` EXPLICITLY though `_active` falls back to it: leaning on
    // a default makes the operator's only possible next action correct by
    // accident. `focusName` puts the caret in the title, because the name it
    // arrives with is a placeholder nobody chose.
    if (id != null) context.nav.generator(id, tab: 'corpus', focusName: true);
  }

  @override
  Widget build(BuildContext context) {
    final AppStore s = widget.store;
    final AppTokens t = context.tokens;
    context.setNavQuery(<String, Object?>{
      'q': _search,
      'archived': _showArchived ? 1 : null,
      'deleted': _showDeleted ? 1 : null,
    });

    return ListenableBuilder(
      listenable: s,
      builder: (BuildContext context, _) {
        // Every COUNT on this page reads `live`; only the grid reads `all`.
        // The store fetches with include_archived so the toggle below has rows
        // to reveal and Restore stays reachable, which puts archived rows in
        // `generators` - and a KPI counted straight off those reports work
        // against generators nobody can generate from any more.
        final List<Generator> all = s.generators;
        final List<Generator> live = s.liveGenerators();
        final String q = _search.trim().toLowerCase();
        // THE GRID'S POOL. Server matches under a term, the cache otherwise -
        // the counters below always read the cache, which is the population.
        final SearchSlice<Generator> hits = s.generatorSearch;
        final List<Generator> shown = (hits.active ? hits.rows : all).where((
          Generator g,
        ) {
          // ONLY the archived ones when the toggle is on - one side or the
          // other, never the union. Same rule as the question bank: a mixed
          // table hides the archived rows behind a pill on the one screen
          // somebody opens precisely to find them.
          if (!_onSide(g)) return false;
          if (q.isEmpty) return true;
          return g.name.toLowerCase().contains(q) ||
              g.tags.join(' ').toLowerCase().contains(q);
        }).toList();

        // The pool `shown` was filtered FROM by search - which the archived
        // toggle decides exclusively, so the denominator follows the toggle.
        final int pool = all
            .where(_onSide)
            .length;
        final int generated = live.fold<int>(
          0,
          (int n, Generator g) => n + g.questionCount,
        );
        final int pending = s.pendingDrafts().length;
        final int running = s.jobs
            .where((Job j) => j.state == JobState.running)
            .length;
        final List<Generator> dupes = live
            .where((Generator g) => g.possibleDuplicate)
            .toList();

        return PageBody(
          children: <Widget>[
            // No breadcrumb here: this IS a root destination, and the shell
            // already prints "Admin / <page>" in its top bar. Repeating it
            // put the same words on screen three times in 100px.
            PageHead(
              'Generators',
              sub:
                  'One generator per SOP. Creating one opens it, where you '
                  'name it, upload the document and extract its skills.',
              actions: <Widget>[
                Btn(
                  'Import',
                  tooltip:
                      'Load generators from a CSV. A row whose name already '
                      'exists updates that generator rather than adding a '
                      'second one; the SOP document is uploaded separately.',
                  onPressed: () => showImportSheet(
                    context,
                    widget.store,
                    entity: ImportEntity.generators,
                  ),
                ),
                Btn.primary(
                  'New Generator',
                  icon: Icons.add,
                  onPressed: _create,
                ),
              ],
            ),
            KpiStrip(<Widget>[
              Kpi(
                label: 'Generators',
                value: '${live.length}',
                sub: 'one per SOP',
              ),
              Kpi(
                label: 'Questions generated',
                value: '$generated',
                sub: 'across all banks',
              ),
              // Warn rather than celebrate: a backlog here is a queue of work
              // waiting on a person, which is the point of the gate.
              Kpi(
                label: 'Drafts awaiting review',
                value: '$pending',
                sub: 'human approval gate',
                valueColor: all.isEmpty
                    ? null
                    : (pending > 0 ? t.warnText : t.successText),
              ),
              Kpi(
                label: 'Jobs running',
                value: '$running',
                sub: 'generation and assets',
                valueColor: running > 0 ? t.infoText : null,
              ),
              Kpi(
                label: 'Possible duplicates',
                value: '${dupes.length}',
                sub: dupes.isEmpty ? 'none' : 'same SOP scoped twice',
                valueColor: all.isEmpty
                    ? null
                    : (dupes.isEmpty ? t.successText : t.warnText),
              ),
            ]),
            if (dupes.isNotEmpty) ...<Widget>[
              Notice(
                tone: Tone.warn,
                strong:
                    '${dupes.length} generators look like duplicates of each '
                    'other.',
                text:
                    'Building the same bank twice splits your question pool '
                    'and doubles review effort. Open either one to see the '
                    'comparison.',
              ),
              const SizedBox(height: 14),
            ],
            if (_picked.isNotEmpty)
              SelectionBar(
                count: _picked.length,
                noun: 'generator',
                busy: _deleting,
                onClear: () => setState(() => _picked = <String>{}),
                // Archive (Restore on the archived side) never erases; only
                // Delete may, after its own sheet says what it will do.
                secondary: Btn(
                  _showArchived ? 'Restore' : 'Archive',
                  size: BtnSize.sm,
                  icon: _showArchived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                  onPressed: _deleting
                      ? null
                      : () async {
                          await widget.store.archiveGenerators(
                            _picked.toList(),
                            archive: !_showArchived,
                          );
                          if (mounted) {
                            setState(() => _picked = <String>{});
                          }
                        },
                ),
                // HIDDEN - see [showGeneratorDelete]. Archive stays.
                onDelete: showGeneratorDelete
                    ? () => _delete(
                        _picked.toList(),
                        subject:
                            '${_picked.length} generator'
                            '${_picked.length == 1 ? '' : 's'}',
                      )
                    : null,
              ),
            Panel(
              flush: true,
              toolbar: Toolbar(<Widget>[
                SearchField(
                  value: _search,
                  hint: 'Search every generator',
                  onChanged: _onSearch,
                ),
                const Spacer(),
                // AFTER the Spacer, with the count: the toggle and the tally
                // it changes are one control.
                Btn(
                  _showArchived ? 'Hide archived' : 'Show archived',
                  size: BtnSize.sm,
                  pressed: _showArchived,
                  onPressed: () => setState(() {
                    _showArchived = !_showArchived;
                    _showDeleted = false;
                    // Selection is dropped with the filter. Rows leaving the
                    // screen while still ticked is how a bulk delete comes to
                    // act on things the operator can no longer see.
                    _picked = <String>{};
                  }),
                ),
                Btn(
                  _showDeleted ? 'Hide deleted' : 'Show deleted',
                  size: BtnSize.sm,
                  pressed: _showDeleted,
                  tooltip: 'Generators deleted while an assessment uses them. '
                      'Gone from every list for good; their assessments and '
                      'results are kept.',
                  onPressed: () => setState(() {
                    _showDeleted = !_showDeleted;
                    _showArchived = false;
                    _picked = <String>{};
                  }),
                ),
                // Under a search the denominator is the SERVER's match count,
                // and a matched set larger than the page says so.
                TagChip(
                  hits.active
                      ? '${shown.length} of ${hits.total} matching'
                      : '${shown.length} of $pool',
                ),
                if (hits.active && hits.partial)
                  TagChip('first ${hits.rows.length} shown'),
              ]),
              child: DataGrid(
                // 1150, not 1114: the Archive/Restore slot added 88px of
                // fixed width plus a gap, and Owner gave 20 of it back. The
                // table already ran past the ~996px content area, so the extra
                // 36 buys a row action that stays clickable rather than a
                // column clipped behind the scroll fade - which is exactly
                // what the bank's own width comment was written about.
                // NOT raised for the row Delete. 1198 was past the ~1170px pane
                // of a 1440px window, so the table scrolled and its fade sat
                // over the Delete icon at the right edge. The flex columns
                // give up the width the wider action slot below takes.
                minWidth: 1166,
                // No ticks on the Deleted side: nothing there can be acted on.
                selected: _showDeleted ? null : _picked,
                onSelectionChanged: _showDeleted
                    ? null
                    : (Set<String> next) => setState(() => _picked = next),
                emptyMessage: q.isEmpty
                    ? 'No generators yet. Create one and attach its SOP to '
                          'start generating questions.'
                    : 'No generator matches "$_search". Clear the search or '
                          'try a tag such as domain: or skill:.',
                // The empty state offers the way in rather than describing it -
                // unless a search emptied it, where the way out is the search.
                emptyIcon: Icons.auto_awesome_outlined,
                emptyAction: q.isEmpty
                    ? Btn.primary(
                        'New Generator',
                        icon: Icons.add,
                        size: BtnSize.sm,
                        onPressed: _create,
                      )
                    : Btn(
                        'Clear Search',
                        size: BtnSize.sm,
                        onPressed: () => setState(() => _search = ''),
                      ),
                cols: const <Col>[
                  Col('Generator', flex: 3),
                  Col('SOP', flex: 2),
                  Col('Generation', width: 112),
                  Col('Questions', width: 86, numeric: true),
                  Col('Drafts', width: 104, numeric: true),
                  Col('Tags', flex: 2),
                  // Owner and Updated were two 104-112px columns of metadata
                  // nobody scans a list by, and together they pushed the table
                  // to 1080 - past the 996px content area, so Updated was
                  // clipped and its timestamp wrapped mid-value. One column,
                  // stacked, and the full detail is on the generator page.
                  // 128, not 112: the created line under the owner is an IST
                  // timestamp on one clipped line, and 112 cut off its zone.
                  // minWidth above carries the extra 16.
                  Col('Owner', width: 128),
                  // Unlabelled row-action slot, the shape the bank uses. Left
                  // unsortable on purpose: there is no data behind it, so a
                  // sortable header would advertise an ordering that cannot
                  // exist. 136: Restore plus the Delete icon beside it, with
                  // room to spare for a wider font.
                  Col('', width: 136, numeric: true),
                ],
                rows: shown.map((Generator g) {
                  final int pend = s.pendingDrafts(g.id).length;
                  return GridRow(
                    <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(child: GridLink(g.name)),
                          if (g.possibleDuplicate) ...<Widget>[
                            const SizedBox(width: 7),
                            const StatusBadge('Possible duplicate', Tone.warn),
                          ],
                        ],
                      ),
                      // "Not attached" rather than a blank cell. `sop_title` is
                      // empty until skills are extracted, and a generator with
                      // no document is now the ORDINARY first state - creating
                      // one no longer collects the file - so the blank would be
                      // the common case rather than the edge one. `fileCount` is
                      // the truth here: `sop_title` is separately writable.
                      g.fileCount == 0
                          ? Text('Not attached', style: context.type.bodyMuted)
                          : Mono(
                              g.sopFile.isEmpty
                                  ? '${g.fileCount} file(s)'
                                  : g.sopFile,
                              size: 11.5,
                              color: t.textSecondary,
                            ),
                      Pill.state(g.sopGenState),
                      g.questionCount == 0
                          ? Text('-', style: context.type.bodyMuted)
                          : Mono('${g.questionCount}'),
                      pend == 0
                          ? Mono('0', color: t.textMuted)
                          : StatusBadge('$pend to review', Tone.warn),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: <Widget>[
                          for (final String tag in g.tags.take(3))
                            StatusBadge(tag, Tone.inert),
                          if (g.tags.length > 3)
                            Text(
                              '+${g.tags.length - 3}',
                              style: context.type.tiny,
                            ),
                        ],
                      ),
                      // Owner over timestamp: who to ask, then when it was made.
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            g.owner,
                            style: context.type.bodySecondary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            g.created,
                            style: context.type.tiny,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          // Only on the archived side. The toggle already says
                          // which side is on screen, but a row dragged into
                          // view by a search has to carry the fact itself.
                          // A generator's own lifecycle, beside the run state
                          // in the Generation column. `Ready` is the resting
                          // state and adding a pill for it would put one on
                          // every row, so only the unfinished ones say so -
                          // which is the whole point of showing it.
                          if (g.state != GeneratorState.done) ...<Widget>[
                            const SizedBox(height: 3),
                            Pill(g.state.label, g.state.tone),
                          ],
                          // Only on the archived side. The toggle already says
                          // which side is on screen, but a row dragged into
                          // view by a search has to carry the fact itself.
                          if (!g.active) ...<Widget>[
                            const SizedBox(height: 3),
                            Pill(g.deleted ? 'Deleted' : 'Archived', Tone.inert),
                          ],
                        ],
                      ),
                      // Restore for an archived row, Archive for a live one -
                      // same slot, only one applies. Archiving is not deleting:
                      // the generator keeps its drafts and its SOP files, and
                      // the questions it authored stay in the bank. Delete sits
                      // beside it on every row and runs the bulk bar's own
                      // `_delete`, so the server's preview decides erase or
                      // Deleted and the sheet says which before anything runs.
                      // A deleted row gets neither: Deleted is final.
                      if (g.deleted)
                        const SizedBox.shrink()
                      else
                        Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          g.active
                              ? IconBtn(
                                  Icons.archive_outlined,
                                  tooltip: 'Archive',
                                  onPressed: s.isBusy('archive:${g.id}')
                                      ? null
                                      : () => s.archiveGenerator(g.id),
                                )
                              : Btn(
                                  'Restore',
                                  tooltip:
                                      'Put this generator back in service so '
                                      'it can author questions and be chosen '
                                      'for a new assessment again.',
                                  size: BtnSize.sm,
                                  busy: s.isBusy('archive:${g.id}'),
                                  onPressed: () =>
                                      s.archiveGenerator(g.id, archive: false),
                                ),
                          // HIDDEN - see [showGeneratorDelete].
                          if (showGeneratorDelete) ...<Widget>[
                            const SizedBox(width: 4),
                            IconBtn(
                              Icons.delete_outline,
                              tooltip: 'Delete',
                              onPressed: _deleting
                                  ? null
                                  : () =>
                                        _delete(<String>[g.id], subject: g.name),
                            ),
                          ],
                        ],
                      ),
                    ],
                    id: g.id,
                    onTap: () => context.nav.generator(g.id),
                  );
                }).toList(),
              ),
            ),
          ],
        );
      },
    );
  }
}
