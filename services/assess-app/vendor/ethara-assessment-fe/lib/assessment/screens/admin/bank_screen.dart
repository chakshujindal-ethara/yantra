// Question bank - HANDOVER 4.3.
//
// The approved, reusable pool - the ONLY source an assessment can draw from.
// That is why the invalid-key count is a KPI: a question with no correct option
// scores zero for everyone, and the sixth launch gate refuses it.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../widgets/buttons.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/delete_sheet.dart';
import '../../widgets/feedback.dart';
import '../../widgets/import_sheet.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../../widgets/controls.dart';
import 'assessment_detail_screen.dart' show showQuestionPreview;
import '../../nav.dart';
import '../../theme.dart';

/// Whether the bank offers Delete. OFF.
///
/// Delete erases every selected question nothing points at, for good, and
/// moves the rest to Deleted with no way back. Archive does what an operator
/// clearing out the bank needs, and Restore undoes it. Hidden in the UI only:
/// the route, the store call and the sheet behind it are untouched, and the
/// tests of that flow turn this on.
@visibleForTesting
bool showQuestionDelete = false;

class BankScreen extends StatefulWidget {
  final AppStore store;

  const BankScreen({super.key, required this.store});

  @override
  State<BankScreen> createState() => _BankScreenState();
}

class _BankScreenState extends State<BankScreen> {
  // Search, type and the archive toggle START from the address bar
  // (`/bank?q=...&type=mcq`) and `build` writes them back.
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
      if (mounted) widget.store.searchBank(_search);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// SERVER-BACKED, DEBOUNCED - see `assessment_list_screen.dart` for the whole
  /// reasoning; the shape is deliberately identical on all three list screens.
  /// `/bank` accepts `search`, and a bank runs to thousands of questions, so
  /// this is the screen where filtering only what the client holds is least
  /// defensible.
  void _onSearch(String v) {
    setState(() => _search = v);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      widget.store.searchBank(v);
    });
  }

  /// Ticked rows, by question id. See [GridRow.id] for why it is not indices.
  Set<String> _picked = <String>{};
  bool _deleting = false;

  /// Show questions taken out of the bank. Off by default - an archived
  /// question is one somebody removed on purpose. On, it is how an archive
  /// pressed by mistake gets undone from the product rather than from the
  /// database.
  ///
  /// The WIRE still calls this `retired`, and deliberately so: archiving a
  /// question in Odoo's sense (`active = false`) would empty it out of
  /// `assessment.question_ids` and silently shrink papers already sat. Only
  /// the label changed.
  late bool _showArchived = context.navQuery['archived'] == '1';

  /// Show questions Delete could not erase because they carry history. They
  /// are out of the bank AND out of Archived, for good; only this view lists
  /// them, read-only. Exclusive with [_showArchived].
  late bool _showDeleted = context.navQuery['deleted'] == '1';

  /// The side of the bank a row belongs to under the current toggles.
  bool _onSide(Question b) => _showDeleted
      ? b.deleted
      : !b.deleted && b.retired == _showArchived;

  Future<void> _delete(List<String> ids, {required String subject}) async {
    if (ids.isEmpty) return;
    setState(() => _deleting = true);
    try {
      final DeletePreview? preview = await widget.store.previewQuestionDelete(
        ids,
      );
      if (!mounted || preview == null) return;
      if (!await confirmDelete(context, subject: subject, preview: preview)) {
        return;
      }
      await widget.store.deleteQuestions(ids);
      if (mounted) setState(() => _picked = <String>{});
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  /// A row moved to the other side must not stay ticked: the bar would go on
  /// counting it, and a Delete pressed next would erase a hidden row.
  void _unpick(String id) =>
      setState(() => _picked = _picked.difference(<String>{id}));

  /// Null means every type. A sentinel rather than a magic QType, so the
  /// "all" case cannot be confused with a real selection.
  late QType? _type = QType.known
      .where((QType q) => q.wire == context.navQuery['type'])
      .firstOrNull;

  @override
  Widget build(BuildContext context) {
    final AppStore s = widget.store;
    final AppTokens t = context.tokens;
    context.setNavQuery(<String, Object?>{
      'q': _search,
      'type': _type?.wire,
      'archived': _showArchived ? 1 : null,
      'deleted': _showDeleted ? 1 : null,
    });

    return ListenableBuilder(
      listenable: s,
      builder: (BuildContext context, _) {
        final List<Question> all = s.bank;
        // Every COUNT on this page reads `live`; only the grid reads `all`.
        // The store fetches with include_retired so the "Show archived" toggle
        // has rows to reveal, and an archived question is still `active` on the
        // wire, so nothing else drops it from a tally. Counting `all` is what
        // made the "Bank questions" card read 40 above a grid listing 39.
        final List<Question> live = s.liveBank();
        final String q = _search.trim().toLowerCase();
        // THE GRID'S POOL. A term switches it to the server's matches so a
        // question past the boot-time walk is findable; an empty box leaves it
        // as the cache, which is what every count on this page reads.
        final SearchSlice<Question> hits = s.bankSearch;
        final List<Question> shown = (hits.active ? hits.rows : all).where((
          Question b,
        ) {
          // Archived questions are out of the bank. They are still ACTIVE
          // records on the wire - the assessments using them keep listing them
          // - so nothing else filters them out and this has to.
          // ONLY the archived ones when the toggle is on. It used to ADD them
          // to the live list, so "Show archived" produced a mixed table in
          // which the archived rows were findable only by spotting their pill -
          // on the one screen someone opens precisely because they want to see
          // what was taken out of the bank.
          if (!_onSide(b)) return false;
          if (_type != null && b.type != _type) return false;
          if (q.isEmpty) return true;
          return b.name.toLowerCase().contains(q) ||
              b.prompt.toLowerCase().contains(q);
        }).toList();

        // The pool `shown` was filtered FROM by search and type - which the
        // archived toggle now decides exclusively, so it is one side or the
        // other and never the union.
        final int pool = all.where(_onSide).length;
        final int active = live.where((Question b) => b.active).length;
        final int invalid = live
            .where((Question b) => !b.answerKeyValid)
            .length;
        final int typesInUse = live
            .map((Question b) => b.type)
            .where(QType.known.contains)
            .toSet()
            .length;

        return PageBody(
          children: <Widget>[
            // No breadcrumb here: this IS a root destination, and the shell
            // already prints "Admin / <page>" in its top bar. Repeating it
            // put the same words on screen three times in 100px.
            PageHead(
              'Question Bank',
              sub:
                  'Approved, reusable questions. Only items in here can be '
                  'served to a candidate.',
              actions: <Widget>[
                // The bank is one of the six surfaces a read-only Manager can
                // open, so every action on it needs the authoring capability.
                // Without this the screen offered an importer whose route is
                // Admin-only.
                if (s.can(Capability.authoring))
                  Btn(
                    'Import',
                    tooltip:
                        'Load questions from a CSV or JSON file. CSV and '
                        'harness JSON arrive as drafts in the review queue; a '
                        'native bank export restores straight into the live '
                        'bank.',
                    onPressed: () =>
                        showImportSheet(
                          context,
                          s,
                          entity: ImportEntity.questions,
                        ),
                  ),
              ],
            ),
            KpiStrip(<Widget>[
              Kpi(
                label: 'Bank questions',
                value: '${live.length}',
                sub: 'all approved',
              ),
              Kpi(label: 'Active', value: '$active', sub: 'servable today'),
              Kpi(
                label: 'Invalid answer key',
                value: '$invalid',
                sub: invalid == 0 ? 'none' : 'would score zero for everyone',
                // Green only when there is a bank to be clean. On an empty
                // install `invalid == 0` is trivially true, and a green 0
                // celebrates having no questions.
                valueColor: live.isEmpty
                    ? null
                    : (invalid == 0 ? t.successText : t.destText),
              ),
              Kpi(
                label: 'Types in use',
                // Counted, never hardcoded. The denominator was once a
                // literal, and it went stale the moment the module's type
                // table moved, so the card misreported the product. Deriving
                // it from the enum means the next type added or retired
                // server-side carries the card with it.
                value: '$typesInUse of ${QType.known.length}',
                sub: 'answer layouts',
              ),
            ]),
            if (invalid > 0) ...<Widget>[
              Notice(
                tone: Tone.bad,
                strong: '$invalid bank question has no correct answer marked.',
                text:
                    'Any assessment that selects it will refuse to launch - '
                    'this is the sixth launch gate, caught early.',
              ),
              const SizedBox(height: 14),
            ],
            if (_picked.isNotEmpty && s.can(Capability.authoring))
              SelectionBar(
                count: _picked.length,
                noun: 'question',
                busy: _deleting,
                onClear: () => setState(() => _picked = <String>{}),
                // Archive (Restore on the archived side) never erases; only
                // Delete may, after its own sheet says what it will erase.
                secondary: Btn(
                  _showArchived ? 'Restore' : 'Archive',
                  size: BtnSize.sm,
                  icon: _showArchived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                  onPressed: _deleting
                      ? null
                      : () async {
                          await s.archiveQuestions(
                            _picked.toList(),
                            archive: !_showArchived,
                          );
                          if (mounted) {
                            setState(() => _picked = <String>{});
                          }
                        },
                ),
                // HIDDEN - see [showQuestionDelete]. Archive stays.
                onDelete: showQuestionDelete
                    ? () => _delete(
                        _picked.toList(),
                        subject:
                            '${_picked.length} question'
                            '${_picked.length == 1 ? '' : 's'}',
                      )
                    : null,
              ),
            Panel(
              flush: true,
              toolbar: Toolbar(<Widget>[
                SearchField(
                  value: _search,
                  hint: 'Search the whole bank',
                  onChanged: _onSearch,
                ),
                SelectField<String>(
                  value: _type?.wire ?? 'all',
                  onChanged: (String v) => setState(
                    () => _type = v == 'all' ? null : QType.parse(v),
                  ),
                  options: <(String, String)>[
                    const ('all', 'All types'),
                    for (final QType x in QType.known) (x.wire, x.label),
                  ],
                ),
                const Spacer(),
                // AFTER the Spacer, with the count: the toggle and the tally it
                // changes are one control, and reading "Show archived" beside
                // "3 of 3" is what tells you the 3 is the archived side.
                Btn(
                  _showArchived ? 'Hide archived' : 'Show archived',
                  size: BtnSize.sm,
                  pressed: _showArchived,
                  onPressed: () => setState(() {
                    _showArchived = !_showArchived;
                    _showDeleted = false;
                    // Selection is dropped with the filter. Rows leaving the
                    // screen while still ticked is how a bulk archive comes to
                    // act on things the operator can no longer see.
                    _picked = <String>{};
                  }),
                ),
                Btn(
                  _showDeleted ? 'Hide deleted' : 'Show deleted',
                  size: BtnSize.sm,
                  pressed: _showDeleted,
                  tooltip: 'Questions deleted while in use. Gone from the '
                      'bank for good; their assessments, answers and scores '
                      'are kept.',
                  onPressed: () => setState(() {
                    _showDeleted = !_showDeleted;
                    _showArchived = false;
                    _picked = <String>{};
                  }),
                ),
                // The denominator is the pool `shown` was filtered FROM, which
                // is what the toggle decides. Hardcoding `all` printed
                // "39 of 40" with the toggle off and no way to reach the 40th.
                //
                // Under a search the denominator is the SERVER's match count -
                // the pool being filtered is no longer one the client holds -
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
                // Sized for the SEVEN columns this table has, not the nine it
                // used to. Leaving it at 1240 forced a horizontal scroll on a
                // table that now fits, which pushed the row action off-screen
                // behind a fade for no reason.
                // +18 for Approved, below.
                minWidth: 1058,
                // NO TICK GUTTER FOR A READ-ONLY MANAGER. `DataGrid` draws the
                // checkbox column only when BOTH of these are non-null
                // (`_selectable`), and the only thing a selection feeds here is
                // the bulk-archive bar above - which they do not get. Left in,
                // the gutter is a control that ticks, counts nothing and
                // produces no action: the reader ticks six rows looking for the
                // button that was supposed to appear.
                // Nor on the Deleted side: nothing there can be acted on.
                selected: s.can(Capability.authoring) && !_showDeleted
                    ? _picked
                    : null,
                onSelectionChanged: s.can(Capability.authoring) && !_showDeleted
                    ? (Set<String> next) => setState(() => _picked = next)
                    : null,
                emptyMessage: q.isEmpty && _type == null
                    ? 'The bank is empty. Approve a draft in the review queue '
                          'and it lands here.'
                    : 'Nothing matches those filters. Clear the search or set '
                          'the type back to All types.',
                // The action differs by CAUSE: an empty bank needs the review
                // queue, a filtered-to-nothing bank needs the filters cleared.
                emptyIcon: Icons.inventory_2_outlined,
                // The review queue is not on a Manager's rail, so pointing them
                // at it would be a button to a page they cannot open.
                emptyAction: q.isEmpty && _type == null
                    ? (s.can(Capability.authoring)
                          ? Btn(
                              'Go to Review Queue',
                              size: BtnSize.sm,
                              onPressed: () => context.nav.review(),
                            )
                          : null)
                    : Btn(
                        'Clear Filters',
                        size: BtnSize.sm,
                        onPressed: () => setState(() {
                          _search = '';
                          _type = null;
                        }),
                      ),
                cols: const <Col>[
                  Col('Question', flex: 3),
                  Col('Type', width: 112),
                  Col('Generator', flex: 2),
                  // Answer key + Rubric merged into READINESS, and
                  // Approved + Status merged into APPROVED.
                  //
                  // Nine columns wanted ~1090px of fixed width in a 996px
                  // content area, so the table ran to 1488px and the View
                  // button sat 208px off-screen - a row action nobody could
                  // click. Each pair answered one question anyway: "can this
                  // be served?" and "where did it come from, is it live?".
                  Col('Readiness', width: 168),
                  Col('Used in', width: 70, numeric: true),
                  // 150: an IST timestamp ("18 Sep, 10:03 AM IST") on one
                  // line of 11.5px mono.
                  Col('Approved', width: 150),
                  Col('', width: 96, numeric: true),
                ],
                rows: shown.map((Question b) {
                  return GridRow(
                    <Widget>[
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          GridLink(b.name),
                          const SizedBox(height: 2),
                          Text(
                            b.prompt,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.type.tiny,
                          ),
                        ],
                      ),
                      StatusBadge(b.taskLabel, Tone.inert),
                      Text(
                        // THE NAME THE SERVER SENT. `genById(...)?.name ?? genId`
                        // printed a raw database id whenever the generators were
                        // not loaded, and printed one permanently once the
                        // generator was deleted - `generator_id` is
                        // ondelete="set null". `sourceRef` is stamped at approval
                        // time and outlives the generator entirely, so it is the
                        // last honest fallback before "Unattributed".
                        b.genName.isNotEmpty
                            ? b.genName
                            : (s.genById(b.genId)?.name ??
                                  (b.sourceRef.isNotEmpty
                                      ? b.sourceRef
                                      : 'Unattributed')),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.type.bodySecondary,
                      ),
                      _Readiness(b),
                      Mono('${b.usedIn}'),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Mono(
                            _when(b.approvedOn),
                            size: 11.5,
                            color: t.textSecondary,
                          ),
                          const SizedBox(height: 3),
                          b.active
                              ? const Pill('Active', Tone.ok)
                              : Pill(
                                  b.deleted ? 'Deleted' : 'Archived',
                                  Tone.inert,
                                ),
                        ],
                      ),
                      // Restore for an archived row, Archive for a live one -
                      // same slot, only one applies. Archive only archives;
                      // Delete lives in the selection bar, behind its sheet.
                      // An icon, not a red button down every row of a browsing
                      // screen; Restore stays labelled as the rare way back.
                      if (!s.can(Capability.authoring) || b.deleted)
                        const SizedBox.shrink()
                      else if (b.retired)
                        Btn(
                              'Restore',
                              tooltip:
                                  'Put this question back in the bank so new '
                                  'assessments can draw it again. The '
                                  'assessments already built with it never '
                                  'lost it.',
                              size: BtnSize.sm,
                              onPressed: () {
                                _unpick(b.id);
                                s.restoreQuestion(b.id);
                              },
                            )
                      else
                        IconBtn(
                              // The ARCHIVE glyph, not a trash can, and the
                              // same one the generator and assessment lists
                              // use. A bin under the word "Archive" told two
                              // different stories about an action the server
                              // may well answer by keeping the row.
                              Icons.archive_outlined,
                              tooltip: 'Archive',
                              onPressed: () {
                                _unpick(b.id);
                                s.archiveQuestions(<String>[b.id]);
                              },
                            ),
                    ],
                    id: b.id,
                    onTap: () => showQuestionPreview(context, s, b),
                  );
                }).toList(),
              ),
            ),
          ],
        );
      },
    );
  }

  String _when(DateTime? d) =>
      d == null ? '-' : istTimestamp(d);
}

/// Can this question be served to a candidate?
///
/// One cell for what used to be two columns. The facts are not independent - a
/// broken answer key blocks serving whatever the rubric says - so the WORST one
/// leads.
class _Readiness extends StatelessWidget {
  const _Readiness(this.q);

  final Question q;

  @override
  Widget build(BuildContext context) {
    if (!q.answerKeyValid) {
      // The blocking fault, so nothing else competes with it.
      return const Pill('No correct option', Tone.bad);
    }
    // No rubric-review state. Approving the draft is what signs its marking
    // guide now, so anything that reached the bank is signed by construction
    // and a pill reporting otherwise could only ever be stale.
    return const Pill('Ready', Tone.ok);
  }
}
