// All responses - HANDOVER 4.3, `#/admin/responses`.
//
// Every answer across every assessment, in one list. This is where a score is
// audited and defended, so the row carries the mark, the raw subjective
// figure, the scoring state and the integrity gate together: a person deciding
// whether a mark is safe should not have to open three screens to find out.
//
// GROUPED BY ASSESSMENT, THEN CANDIDATE, on arrival. A flat list of every
// answer in the org is a pile: the first thing anybody asks of this screen is
// "how did this assessment go", the second is "how did this person do on it",
// and the module's own Odoo list opens on exactly that pair.
//
// `PageBody`, `StatusBadge` and `TagChip` are hidden from Material because the design system
// defines its own; Flutter's would silently change the mark vocabulary.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/csv_export.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../widgets/buttons.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../../widgets/rescore_sheet.dart';
import '../../widgets/controls.dart';
import 'response_detail_screen.dart';
import '../../theme.dart';
import '../../nav.dart';

/// One bucketing axis.
enum _By {
  assessment('Assessment'),
  candidate('Candidate'),
  type('Question type'),
  scoring('Scoring state');

  final String label;

  const _By(this.label);
}

/// The group-by choices, spelled the way the reader will read them.
///
/// Composite options rather than two dropdowns. "Assessment > Candidate" is one
/// decision an auditor makes, and splitting it into a primary and a secondary
/// select would put four working combinations and eight useless ones in front
/// of somebody who only ever wanted this list.
enum _Grouping {
  asmWho('Assessment > Candidate', <_By>[_By.assessment, _By.candidate]),
  asm('Assessment', <_By>[_By.assessment]),
  who('Candidate', <_By>[_By.candidate]),
  whoAsm('Candidate > Assessment', <_By>[_By.candidate, _By.assessment]),
  qtype('Question type', <_By>[_By.type]),
  scoring('Scoring state', <_By>[_By.scoring]),
  flat('No grouping', <_By>[]);

  final String label;
  final List<_By> levels;

  const _Grouping(this.label, this.levels);
}

/// The cross-cutting filters, driven from the KPI cards rather than a dropdown.
///
/// Each one is a UNION that no single-value select can express: "unresolved" is
/// five scoring states at once, "gated" is a judge verdict rather than a state,
/// and "scored zero" is a mark. The counts are already on the cards, so the
/// cards are the control.
enum _Attn {
  none,
  unresolved,
  errored,
  gated,
  zero;

  /// Whether [a] belongs to this cut. `none` admits everything, so the caller
  /// never needs a special case for "no filter".
  bool admits(AnswerRef a) => switch (this) {
    _Attn.none => true,
    _Attn.unresolved => a.r.llmState.isUnresolved,
    _Attn.errored => a.isRescorableError,
    _Attn.gated => isGated(a.r.judge),
    _Attn.zero => a.r.mark == 0 && !a.r.llmState.isUnresolved,
  };
}

/// Column indices, named once.
///
/// The sort comparators, the group aggregates and the header all address
/// columns by position, and three separate literal `4`s meaning "the mark
/// column" is one insertion away from silently sorting by the wrong thing.
const int _cCandidate = 1;
const int _cQuestion = 2;
const int _cAnswer = 3;
const int _cMark = 4;
const int _cScoring = 5;

class ResponsesScreen extends StatefulWidget {
  final AppStore store;

  const ResponsesScreen({super.key, required this.store});

  @override
  State<ResponsesScreen> createState() => _ResponsesScreenState();
}

class _ResponsesScreenState extends State<ResponsesScreen> {
  // Search, the three filters, the attention cut, the grouping and the page
  // all START from the address bar (`/responses?state=...&page=2`) and `build`
  // writes them back. The selects already fall back to "all" for a value they
  // have no row for, so a stale or hand-edited URL cannot trip them.
  late final Map<String, String> _asked = context.navQuery;
  late String _search = _asked['q'] ?? '';

  /// A search restored from the address bar asks the server, as typing it
  /// would have. After the first frame: the store notifies, and the section
  /// above this screen is still building.
  @override
  void initState() {
    super.initState();
    if (_search.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.store.searchResponses(_search);
    });
  }

  @override
  void dispose() {
    // The debounce outlives the widget otherwise, and fires a store
    // call against a disposed screen.
    _searchDebounce?.cancel();
    super.dispose();
  }

  /// D2 - the term also goes to the SERVER, so it must not go per keystroke.
  ///
  /// 250ms, the same delay every other server-backed box in this console uses.
  /// The LOCAL pass still runs immediately on every keystroke: the rows in
  /// hand narrow as you type, and the server's supplement arrives a moment
  /// later. Typing therefore never feels gated on a request.
  Timer? _searchDebounce;

  void _onSearch(String v) {
    setState(() {
      _search = v;
      _page = 1;
    });
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 250),
      () => widget.store.searchResponses(v),
    );
  }

  late String _asmFilter = _asked['asm'] ?? 'all';
  late String _typeFilter = _asked['type'] ?? 'all';
  late String _stateFilter = _asked['state'] ?? 'all';
  late _Attn _attn = _Attn.values.asNameMap()[_asked['attn']] ?? _Attn.none;
  late _Grouping _group =
      _Grouping.values.asNameMap()[_asked['group']] ?? _Grouping.asmWho;

  /// The ordering. Null is the order the store handed over, which is the order
  /// answers were recorded in - a real answer to "what came in", and the only
  /// honest default before anybody has asked for another one.
  int? _sortCol;
  bool _sortAsc = true;

  late int _page = int.tryParse(_asked['page'] ?? '') ?? 1;
  late int _pageSize = int.tryParse(_asked['size'] ?? '') ?? 20;

  /// Selected rows, keyed `attemptId|questionId`. Selection is by key rather
  /// than by index so a filter change cannot re-point it at a different answer.
  final Set<String> _selected = <String>{};

  /// Groups explicitly opened, and explicitly closed.
  ///
  /// TWO sets, because the default is neither "all open" nor "all shut": the
  /// top level opens and deeper levels stay closed, which is what makes a
  /// two-level grouping readable on arrival. One set could not tell "never
  /// touched" from "deliberately closed", so collapsing a top-level group would
  /// have re-opened it on the next rebuild.
  final Set<String> _open = <String>{};
  final Set<String> _shut = <String>{};

  bool _isOpen(String key, int depth) =>
      _open.contains(key) ? true : (_shut.contains(key) ? false : depth == 0);

  void _toggleGroup(String key, int depth) => setState(() {
    if (_isOpen(key, depth)) {
      _open.remove(key);
      _shut.add(key);
    } else {
      _shut.remove(key);
      _open.add(key);
    }
  });

  String _key(AnswerRef a) => '${a.ev.id}|${a.q.id}';

  String _who(AppStore s, AnswerRef a) =>
      s.personById(a.ev.employeeId)?.name ?? a.ev.employeeId;

  /// Everything about an answer that a person could reasonably type.
  ///
  /// Search used to cover the candidate and the question NAME and nothing else,
  /// so the obvious searches over this table - an assessment, a question type,
  /// the text of an answer, `error`, a gate - all returned "no answers match
  /// those filters" over data that was sitting right there.
  ///
  /// Built only when there is a query: it is one string per row per keystroke,
  /// and over a few hundred answers that is worth not doing for nothing.
  String _hay(AppStore s, AnswerRef a) {
    final Person? p = s.personById(a.ev.employeeId);
    final Judge? j = a.r.judge;
    return <String?>[
      p?.name,
      p?.email,
      p?.pod,
      a.ev.employeeId,
      a.asm.name,
      a.q.name,
      a.q.prompt,
      // BOTH NAMES ARE SEARCHABLE. A haystack is not a label: an operator may
      // remember the examiner's task name ("Verify a single photo edit") or the
      // engine type ("Image A/B"), and matching only what is DISPLAYED would
      // silently stop the other query working.
      a.q.type.label,
      a.q.type.short,
      a.q.taskLabelLong,
      // THE SAME REDACTION THE CELL USES. Searching the raw text of an
      // anonymised attempt would let anyone confirm its contents by guessing at
      // them, which is the erasure undone by a search box.
      redactFor(a.ev, answerSummary(a.q, a.r)),
      redactFor(a.ev, a.r.justification),
      a.r.llmState.label,
      '${a.r.mark} / ${a.r.markOutOf}',
      a.r.llmRaw100 == null ? null : rawFromHundred(a.r.llmRaw100),
      a.r.llmError,
      j?.gate,
      j?.profile,
      redactFor(a.ev, j?.verdict ?? ''),
    ].whereType<String>().join(' ').toLowerCase();
  }

  bool _matches(AppStore s, AnswerRef a) {
    if (_asmFilter != 'all' && a.asm.id != _asmFilter) return false;
    if (_typeFilter != 'all' && a.q.type.wire != _typeFilter) return false;
    if (_stateFilter != 'all' && a.r.llmState.wire != _stateFilter) {
      return false;
    }
    if (!_attn.admits(a)) return false;
    if (_search.trim().isEmpty) return true;

    // EVERY term has to land, in any field. One box that narrows as you type
    // beats one that only ever matches a single word: "sumit rubric error" is
    // three facets a person already knows how to express.
    final String hay = _hay(s, a);
    return _search
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((String w) => w.isNotEmpty)
        .every(hay.contains);
  }

  /// The comparator for the active column, ascending. Direction is applied by
  /// the caller, so the tie-break below cannot be reversed with it: a stable
  /// final key is what stops equal rows swapping places on every rebuild.
  int _cmp(AppStore s, AnswerRef a, AnswerRef b) {
    int by(int c) => switch (c) {
      _cCandidate => _who(
        s,
        a,
      ).toLowerCase().compareTo(_who(s, b).toLowerCase()),
      _cQuestion => a.q.name.toLowerCase().compareTo(b.q.name.toLowerCase()),
      _cAnswer => answerSummary(
        a.q,
        a.r,
      ).toLowerCase().compareTo(answerSummary(b.q, b.r).toLowerCase()),
      // Marks first, then the raw grader figure underneath it: two answers on
      // one mark are not equally close to the next one.
      _cMark =>
        a.r.mark != b.r.mark
            ? a.r.mark.compareTo(b.r.mark)
            : (a.r.llmRaw100 ?? -1).compareTo(b.r.llmRaw100 ?? -1),
      // The ENUM order, which is the lifecycle: not needed, pending, queued,
      // scoring, scored, failed, error. Alphabetical would file "error" between
      // "queued" and "scored" and lose the only ordering the column has.
      _cScoring => a.r.llmState.index.compareTo(b.r.llmState.index),
      _ => 0,
    };
    final int primary = by(_sortCol ?? -1);
    return primary != 0 ? primary : _key(a).compareTo(_key(b));
  }

  List<AnswerRef> _sorted(AppStore s, List<AnswerRef> rows) {
    if (_sortCol == null) return rows;
    final List<AnswerRef> out = <AnswerRef>[...rows];
    out.sort(
      (AnswerRef a, AnswerRef b) => _sortAsc ? _cmp(s, a, b) : _cmp(s, b, a),
    );
    return out;
  }

  void _onSort(int col) => setState(() {
    if (_sortCol == col) {
      // Third click clears it rather than cycling back to ascending: "the order
      // it arrived in" is a state worth being able to get back to.
      _sortAsc ? _sortAsc = false : _sortCol = null;
    } else {
      _sortCol = col;
      _sortAsc = true;
    }
    _page = 1;
  });

  /// Which axis a sorted column corresponds to, if any.
  ///
  /// Sorting by Candidate while grouped BY candidate should order the groups -
  /// the rows inside each one are all the same candidate, so ordering them by
  /// that column does nothing a reader can see.
  _By? get _sortedAxis => switch (_sortCol) {
    _cCandidate => _By.candidate,
    _cScoring => _By.scoring,
    _ => null,
  };

  String _bucketKey(_By by, AnswerRef a) => switch (by) {
    _By.assessment => 'asm:${a.asm.id}',
    // THE PERSON, not the sitting. The attempt id used to ride along here,
    // which split a candidate who had sat two assessments into two top-level
    // buckets both labelled with their name (`_bucketLabel` renders `_who`,
    // which knows nothing about the attempt), and degenerated
    // 'Candidate > Assessment' into one child per parent. Uniqueness down the
    // tree is `prefix`'s job - see [_buildGroups] - not this key's.
    _By.candidate => 'who:${a.ev.employeeId}',
    _By.type => 'type:${a.q.type.wire}',
    _By.scoring => 'state:${a.r.llmState.wire}',
  };

  String _bucketLabel(AppStore s, _By by, AnswerRef a) => switch (by) {
    _By.assessment => a.asm.name.isEmpty ? 'Unnamed assessment' : a.asm.name,
    _By.candidate => _who(s, a),
    _By.type => a.q.taskLabelLong,
    _By.scoring => a.r.llmState.label,
  };

  /// The group tree for [rows], one level per entry in [levels].
  ///
  /// `prefix` makes every key unique down the tree, so opening "Priya" under
  /// one assessment does not open every other "Priya" as well.
  List<GridGroup> _buildGroups(
    BuildContext context,
    AppStore s,
    List<_By> levels,
    List<AnswerRef> rows,
    String prefix,
  ) {
    if (levels.isEmpty) return const <GridGroup>[];
    final _By by = levels.first;
    final List<_By> rest = levels.sublist(1);

    // Insertion-ordered, so a bucket's position is decided below rather than by
    // the hash of its key.
    final Map<String, List<AnswerRef>> buckets = <String, List<AnswerRef>>{};
    final Map<String, String> labels = <String, String>{};
    for (final AnswerRef a in rows) {
      final String k = _bucketKey(by, a);
      labels[k] = _bucketLabel(s, by, a);
      buckets.putIfAbsent(k, () => <AnswerRef>[]).add(a);
    }

    final List<String> keys = buckets.keys.toList()
      ..sort(
        (String x, String y) =>
            labels[x]!.toLowerCase().compareTo(labels[y]!.toLowerCase()),
      );
    // Groups read alphabetically unless the reader has asked for this very axis
    // in reverse, in which case the buckets are what they were reversing.
    if (_sortedAxis == by && !_sortAsc) {
      keys.setAll(0, keys.reversed.toList());
    }

    return <GridGroup>[
      for (final String k in keys)
        GridGroup(
          key: '$prefix$k/',
          label: labels[k]!,
          count: buckets[k]!.length,
          aggregates: _aggregates(context, buckets[k]!),
          groups: rest.isEmpty
              ? const <GridGroup>[]
              : _buildGroups(context, s, rest, buckets[k]!, '$prefix$k/'),
          rows: rest.isEmpty
              ? _rows(context, s, buckets[k]!)
              : const <GridRow>[],
        ),
    ];
  }

  /// What a closed group still tells you: the marks it earned, and whether
  /// anything inside it is unresolved.
  ///
  /// Marks out of the group's own MARK TOTAL, summed from the rows.
  ///
  /// The answer count used to be the denominator, because every question was
  /// worth exactly one mark. A question is worth its COMPONENT count now - a
  /// three-sub-question mcq is out of 3 - so a group of four such answers read
  /// "9 / 4". Summing `markOutOf` keeps the total on the same scale the rows
  /// themselves print, which is the part of invariant 2 that still holds: no
  /// group total may invent a scale its rows do not use.
  Map<int, Widget> _aggregates(BuildContext context, List<AnswerRef> rows) {
    final int earned = rows.fold<int>(0, (int n, AnswerRef a) => n + a.r.mark);
    final int outOf = rows.fold<int>(
      0,
      (int n, AnswerRef a) => n + a.r.markOutOf,
    );
    final int unresolved = rows
        .where((AnswerRef a) => a.r.llmState.isUnresolved)
        .length;
    return <int, Widget>{
      _cMark: Marks(earned, outOf),
      _cScoring: unresolved == 0
          ? const SizedBox.shrink()
          : StatusBadge('$unresolved unresolved', Tone.warn),
    };
  }

  /// Re-score exactly the ticked answers: one request per candidate, naming
  /// only that candidate's ticked answers. The bare attempt would re-score each
  /// candidate's UNRESOLVED answers instead.
  ///
  /// A ticked MCQ/MSQ is left out: it is scored in code, nothing to grade.
  /// The store sends them in turn and answers the press with one toast.
  Future<void> _rescoreSelected() async {
    final Map<String, List<String>> byAttempt = <String, List<String>>{};
    final Map<String, Attempt> chosen = <String, Attempt>{};
    for (final AnswerRef a in widget.store.allResponses()) {
      if (!_selected.contains(_key(a)) || !a.r.needsGrader) continue;
      (byAttempt[a.ev.id] ??= <String>[]).add(a.q.id);
      chosen[a.ev.id] = a.ev;
    }
    setState(_selected.clear);
    if (byAttempt.isEmpty) {
      widget.store.toaster.info('None of the ticked answers is LLM-graded');
      return;
    }
    // A bulk tick is the easiest way to sweep up a released candidate without
    // noticing, so this path asks the same question the single-answer one does.
    await rescoreConfirmed(
      context,
      widget.store,
      byAttempt,
      attempts: chosen.values,
    );
  }

  void _clearFilters() => setState(() {
    _search = '';
    _searchDebounce?.cancel();
    widget.store.searchResponses('');
    _asmFilter = 'all';
    _typeFilter = 'all';
    _stateFilter = 'all';
    _attn = _Attn.none;
    _page = 1;
  });

  @override
  Widget build(BuildContext context) {
    final AppStore s = widget.store;
    final AppTokens t = context.tokens;
    String? unlessAll(String v) => v == 'all' ? null : v;
    context.setNavQuery(<String, Object?>{
      'q': _search,
      'asm': unlessAll(_asmFilter),
      'type': unlessAll(_typeFilter),
      'state': unlessAll(_stateFilter),
      'attn': _attn == _Attn.none ? null : _attn.name,
      'group': _group == _Grouping.asmWho ? null : _group.name,
      'page': _page == 1 ? null : _page,
      'size': _pageSize == 20 ? null : _pageSize,
    });

    return ListenableBuilder(
      listenable: s,
      builder: (BuildContext context, _) {
        final List<AnswerRef> all = s.allResponses();

        final List<AnswerRef> rows = _sorted(
          s,
          all.where((AnswerRef a) => _matches(s, a)).toList(),
        );

        final int subjective = all
            .where((AnswerRef a) => a.q.type.isSubjective)
            .length;
        final int unresolved = all
            .where((AnswerRef a) => a.r.llmState.isUnresolved)
            .length;
        final int errored = s.scoringErrorCount;
        final int gated = all.where((AnswerRef a) => isGated(a.r.judge)).length;
        // An answer still with the grader (or errored) holds 0 that nobody
        // awarded: it is counted under Unresolved, not here.
        final int zero = all.where(_Attn.zero.admits).length;

        final bool grouped = _group.levels.isNotEmpty;

        // A SAMPLE, SAID OUT LOUD - SNo 105/106.
        //
        // The responses walk stops at two pages (400 rows) on purpose: this
        // list grows with every answer every candidate gives, and following it
        // to the end was 158 sequential POSTs per load. But every count on this
        // screen is folded from the rows the client HOLDS, so a capped load
        // published "Answers 400" over a table of 4,471 - measured on
        // etp_local - and nothing on screen said otherwise. The operator was
        // auditing a subset while reading a total.
        //
        // `pagesTruncated` has recorded the shortfall since the cap was added
        // and NO WIDGET READ IT. `responsesTotal` is the server's own
        // `meta.total`, so the sample can name its own denominator.
        final bool sampled = s.pagesTruncated && s.responsesTotal > all.length;
        final int held = all.length;

        // Pages over GROUPS when grouped and over answers when not: the thing
        // being paged is the thing the reader is scrolling.
        final List<GridGroup> tree = grouped
            ? _buildGroups(context, s, _group.levels, rows, '')
            : const <GridGroup>[];
        final int total = grouped ? tree.length : rows.length;

        // Clamp before slicing: a filter change can shorten the list under a
        // page the reader is already standing on.
        final int pageCount = total == 0 ? 1 : ((total - 1) ~/ _pageSize) + 1;
        final int page = _page.clamp(1, pageCount);
        final int from = (page - 1) * _pageSize;
        final List<GridGroup> groupSlice = grouped
            ? tree.skip(from).take(_pageSize).toList()
            : const <GridGroup>[];
        final List<AnswerRef> rowSlice = grouped
            ? const <AnswerRef>[]
            : rows.skip(from).take(_pageSize).toList();

        final int selCount = _selected.length;

        return PageBody(
          children: <Widget>[
            // No breadcrumb here: this IS a root destination, and the shell
            // already prints "Admin / <page>" in its top bar. Repeating it
            // put the same words on screen three times in 100px.
            PageHead(
              'All Responses',
              sub:
                  'Every answer, across every assessment. This is where a '
                  'score is audited and defended.',
              actions: <Widget>[
                // Only when there is something to retry: an always-on button
                // invites a click that reports "nothing is errored", which
                // reads as a fault in the button rather than an empty queue.
                //
                // And only for someone who can actually run it. The sweep
                // resets each errored answer and re-queues it - a lifecycle
                // action behind an Admin-only route, so a read-only Manager who
                // pressed this spent a click to earn a 403 and nothing else.
                // The COUNT is deliberately not gated with the button: the
                // "Terminal errors" KPI and the notice below both still say how
                // many answers are stuck, which is the half a Manager needs in
                // order to hand it on.
                if (errored > 0 && s.can(Capability.lifecycle))
                  Btn(
                    'Reset & re-score errored ($errored)',
                    variant: BtnVariant.danger,
                    onPressed: () => s.requeueErrored(),
                  ),
                Btn(
                  'Export CSV',
                  // WHAT THE FILE WILL ACTUALLY CONTAIN. The export writes the
                  // rows on screen, so on a sampled load it is a sample too -
                  // and a CSV is the artefact most likely to be mailed on and
                  // read as the whole table by somebody who never saw this
                  // screen. Said in the tooltip, before the download.
                  tooltip: sampled
                      ? 'Downloads the ${rows.length} row(s) shown - the '
                            '$held most recent answers, filtered - not all '
                            '${s.responsesTotal}. An erased attempt exports as '
                            '[erased], the same as it reads on screen.'
                      : 'Download the filtered rows, not the whole table. An '
                            'erased attempt exports as [erased], the same as '
                            'it reads on screen.',
                  onPressed: rows.isEmpty ? null : () => _exportCsv(rows),
                ),
              ],
            ),
            // The three cards that count something a person might want to LOOK
            // at are the filters for it, which is what the KPI's own `pressed`
            // state was built for. A card whose count is zero is not offered:
            // pressing it could only produce an empty table.
            KpiStrip(<Widget>[
              // THE POPULATION IS THE HEADLINE FIGURE, the sample is the
              // qualifier - not the other way round. "Answers 400 / of 4,471
              // loaded" would still put the wrong number in the big type, and
              // the big type is what gets read and quoted.
              Kpi(
                label: 'Answers',
                value: '${sampled ? s.responsesTotal : held}',
                sub: sampled
                    ? '$held most recent loaded'
                    : 'submitted across the org',
              ),
              // EVERY ONE OF THESE IS FOLDED FROM THE ROWS HELD, so on a
              // sampled load each is a count within the sample and not a fact
              // about the org. "in the 400 loaded" is what makes an Unresolved
              // count of 0 readable as "none in this sample" rather than "none
              // outstanding" - which is a claim the client cannot make, and the
              // one an operator would stop looking after.
              Kpi(
                label: 'Subjective',
                value: '$subjective',
                sub: sampled ? 'in the $held loaded' : 'graded by the judge',
              ),
              _attnKpi(
                label: 'Unresolved',
                count: unresolved,
                cut: _Attn.unresolved,
                sub: sampled
                    ? 'in the $held loaded'
                    : (unresolved > 0
                          ? 'holding a result on pending'
                          : 'none outstanding'),
                color: unresolved > 0 ? t.warnText : t.successText,
              ),
              // NOT QUALIFIED, and this is the exception that proves the rule:
              // `scoringErrorCount` folds the same held rows, so it is a sample
              // count like the others - but "Reset & re-score errored" acts on
              // it, and the count beside that button must not read as a sample
              // of something bigger. Said in the notice instead, where there is
              // room for the whole sentence.
              _attnKpi(
                label: 'Terminal errors',
                count: errored,
                cut: _Attn.errored,
                sub: sampled
                    ? 'in the $held loaded'
                    : (errored > 0 ? 'never retried automatically' : 'none'),
                color: errored > 0 ? t.destText : t.successText,
              ),
              _attnKpi(
                label: 'Gated by integrity',
                count: gated,
                cut: _Attn.gated,
                sub: sampled ? 'in the $held loaded' : 'advisory only',
                color: t.infoText,
              ),
              _attnKpi(
                label: 'Scored zero',
                count: zero,
                cut: _Attn.zero,
                sub: sampled ? 'in the $held loaded' : 'no mark earned',
                color: null,
              ),
            ]),
            // THE SAMPLE, NAMED, above the table it describes.
            //
            // The cap is the right trade against a route that grows with every
            // answer; showing a subset while reading like the whole set is not.
            //
            // WHAT IT DOES NOT SAY: "filter to see the rest". Every control on
            // this screen - the search box, all four selects, the attention
            // cuts - filters the rows already HELD (`_matches`, over
            // `s.allResponses()`); `/api/v1/responses` is called once at boot
            // with no filter argument. So filtering narrows the sample, it does
            // not re-query past it, and telling an operator otherwise would
            // send them to audit an assessment through a view that silently
            // cannot see most of it. The honest route out is the SITTING: a
            // candidate's attempt carries every one of its answers
            // (`/api/v1/attempts/<id>` sends `answers` in full), which is
            // exactly where a row click already goes.
            if (sampled) ...<Widget>[
              Notice(
                tone: Tone.info,
                strong:
                    'Showing the $held most recent of '
                    '${s.responsesTotal} answers.',
                text:
                    'The list loads in pages to keep the console responsive, '
                    'and every count above is counted from these $held rows. '
                    'Open a candidate or a sitting to see all of their answers, '
                    'however old.',
              ),
              const SizedBox(height: 16),
            ],
            // Invariant 5, stated where it can be acted on. The retry set
            // excludes the terminal error, so these answers wait here until a
            // person sweeps them.
            if (errored > 0) ...<Widget>[
              Notice(
                tone: Tone.bad,
                strong: '$errored answer(s) hit a terminal grader error.',
                text:
                    'These never retry on their own - that is what stops an '
                    'outage becoming a wrong fail. Recovery is manual.',
              ),
              const SizedBox(height: 16),
            ],
            Panel(
              flush: true,
              // TWO rows, not one. Search, four selects and a group-by in a
              // single Row shrank every control to an unreadable stub; split by
              // what they do, the first row finds an answer and the second
              // shapes the table.
              toolbar: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Toolbar(<Widget>[
                    // THIS BOX STAYS LOCAL, and the label says so.
                    //
                    // Every other admin search became server-backed. This one
                    // cannot: it searches the RENDERED, REDACTED answer text,
                    // using the redaction the cell itself applies (:185). That
                    // is a client-side presentation transform, and the server
                    // could only reproduce it by carrying a second copy of the
                    // redaction rules - which is the exact duplication that
                    // produced the defect this whole change is fixing.
                    //
                    // So it is labelled instead of moved: the box names the rows
                    // it can see, and the chip beside it names the population it
                    // cannot. `/responses` is walked at `maxPages: 2`, so on a
                    // real cohort those two numbers differ by thousands.
                    SearchField(
                      value: _search,
                      hint: 'Search answers, or a candidate anywhere',
                      onChanged: _onSearch,
                    ),
                    // WHAT THE BOX REACHES, in the two halves it actually has.
                    // The chip named only the cache, which was honest but no
                    // longer complete: a term now also goes to the server for
                    // the axes it can answer, so a candidate past the cached
                    // rows IS reachable and saying otherwise would send an
                    // operator away from a search that would have worked.
                    if (s.responsesTotal > held)
                      TagChip(
                        _search.trim().isEmpty
                            ? '${s.responsesTotal} answers, $held loaded'
                            : 'answer text searched in $held loaded; '
                                  'people and assessments searched in all '
                                  '${s.responsesTotal}',
                      ),
                    if (s.responseSearchPartial)
                      const TagChip('first 200 server matches'),
                    const Spacer(),
                    // The bulk action appears only when a selection exists, so
                    // the toolbar never offers a control that would do nothing.
                    if (selCount > 0 && s.can(Capability.lifecycle))
                      Btn.primary(
                        'Re-score $selCount selected',
                        tooltip: 'Grades exactly the ticked answers.',
                        size: BtnSize.sm,
                        onPressed: _rescoreSelected,
                      ),
                    if (_isFiltered)
                      Btn(
                        'Clear Filters',
                        size: BtnSize.sm,
                        onPressed: _clearFilters,
                      ),
                    TagChip('${rows.length} of ${all.length}'),
                  ]),
                  Toolbar(<Widget>[
                    _select(
                      value: _asmFilter,
                      options: _asmOptions(all),
                      onChanged: (String v) => setState(() {
                        _asmFilter = v;
                        _page = 1;
                      }),
                    ),
                    _select(
                      value: _typeFilter,
                      options: _typeOptions(all),
                      onChanged: (String v) => setState(() {
                        _typeFilter = v;
                        _page = 1;
                      }),
                    ),
                    _select(
                      value: _stateFilter,
                      options: _stateOptions(all),
                      onChanged: (String v) => setState(() {
                        _stateFilter = v;
                        _page = 1;
                      }),
                    ),
                    const Spacer(),
                    Text('Group by', style: context.type.small),
                    SelectField<_Grouping>(
                      value: _group,
                      onChanged: (_Grouping v) => setState(() {
                        _group = v;
                        _page = 1;
                      }),
                      options: <(_Grouping, String)>[
                        for (final _Grouping g in _Grouping.values)
                          (g, g.label),
                      ],
                    ),
                  ]),
                ],
              ),
              footer: Pagination(
                page: page,
                pageSize: _pageSize,
                total: total,
                unit: grouped ? 'groups' : '',
                onPage: (int p) => setState(() => _page = p),
                onPageSize: (int n) => setState(() {
                  _pageSize = n;
                  _page = 1;
                }),
              ),
              child: DataGrid(
                // Sized for the EIGHT columns this table has now. Fixed
                // width is 322px, leaving ~600px for the three flex columns
                // inside a 996px content area, so it fits without scrolling.
                minWidth: 940,
                emptyMessage: _isFiltered
                    ? 'No answers match those filters. Clear one of them, or '
                          'search for a different candidate.'
                    : 'No answers yet. They appear here as candidates submit '
                          'their assessments.',
                emptyIcon: Icons.fact_check_outlined,
                sortCol: _sortCol,
                sortAsc: _sortAsc,
                onSort: _onSort,
                isGroupOpen: _isOpen,
                onToggleGroup: _toggleGroup,
                cols: const <Col>[
                  Col('', width: 34),
                  // ELEVEN columns became EIGHT, and three pairs became one
                  // cell each. The table wanted 1320px in a 996px area, so it
                  // scrolled sideways and the row's own action sat off-screen
                  // behind the fade. Each merged pair answered one question -
                  // who sat it, what it got, where it is.
                  //
                  // Every column with data behind it sorts. The gutter and the
                  // Audit button do not: there is nothing to order them by.
                  Col('Candidate', flex: 3, sortable: true),
                  Col('Question', flex: 3, sortable: true),
                  Col('Answer', flex: 3, sortable: true),
                  Col('Mark', width: 92, numeric: true, sortable: true),
                  Col('Scoring', width: 132, sortable: true),
                  Col('', width: 64),
                ],
                groups: grouped ? groupSlice : null,
                rows: grouped ? const <GridRow>[] : _rows(context, s, rowSlice),
              ),
            ),
          ],
        );
      },
    );
  }

  /// A KPI card that is also the filter for what it counts.
  Widget _attnKpi({
    required String label,
    required int count,
    required _Attn cut,
    required String sub,
    required Color? color,
  }) {
    final bool active = _attn == cut;
    return Kpi(
      label: label,
      value: '$count',
      // Says so in words, not only in tint: a reader who has forgotten why the
      // table is short should be able to see the reason on the card.
      sub: active ? 'filtering this list - click to clear' : sub,
      valueColor: color,
      pressed: active,
      onTap: count == 0 && !active
          ? null
          : () => setState(() {
              _attn = active ? _Attn.none : cut;
              _page = 1;
            }),
    );
  }

  /// A filter select whose value is guaranteed to be one of its options.
  ///
  /// The options are DATA-DRIVEN, and a reload can drop the one that is
  /// selected - an assessment whose last answer was deleted, a state nothing is
  /// in any more. `DropdownButton` asserts on a value it cannot find and takes
  /// the whole screen down with it, so a stale selection reads as "all" here
  /// rather than as a crash.
  Widget _select({
    required String value,
    required List<(String, String)> options,
    required ValueChanged<String> onChanged,
  }) => SelectField<String>(
    value: options.any(((String, String) o) => o.$1 == value)
        ? value
        : options.first.$1,
    options: options,
    onChanged: onChanged,
  );

  /// Options for the assessment filter, WITH counts, and only for assessments
  /// that actually have answers.
  ///
  /// The list used to be every assessment in the org, most of which have no
  /// answers at all, so most choices could only ever produce an empty table.
  /// The count also answers the question people opened the filter to ask.
  List<(String, String)> _asmOptions(List<AnswerRef> all) {
    final Map<String, int> counts = <String, int>{};
    final Map<String, String> names = <String, String>{};
    for (final AnswerRef a in all) {
      counts[a.asm.id] = (counts[a.asm.id] ?? 0) + 1;
      names[a.asm.id] = a.asm.name.isEmpty ? 'Unnamed assessment' : a.asm.name;
    }
    final List<String> ids = counts.keys.toList()
      ..sort(
        (String x, String y) =>
            names[x]!.toLowerCase().compareTo(names[y]!.toLowerCase()),
      );
    return <(String, String)>[
      ('all', 'All assessments (${all.length})'),
      for (final String id in ids) (id, '${names[id]} (${counts[id]})'),
    ];
  }

  /// The types present, in the enum's own order so objective types stay
  /// together and ahead of the graded ones.
  List<(String, String)> _typeOptions(List<AnswerRef> all) {
    final Map<QType, int> counts = <QType, int>{};
    for (final AnswerRef a in all) {
      counts[a.q.type] = (counts[a.q.type] ?? 0) + 1;
    }
    return <(String, String)>[
      ('all', 'All question types'),
      for (final QType q in QType.values)
        if (counts[q] != null) (q.wire, '${q.label} (${counts[q]})'),
    ];
  }

  /// The scoring states present, in lifecycle order.
  List<(String, String)> _stateOptions(List<AnswerRef> all) {
    final Map<LlmState, int> counts = <LlmState, int>{};
    for (final AnswerRef a in all) {
      counts[a.r.llmState] = (counts[a.r.llmState] ?? 0) + 1;
    }
    return <(String, String)>[
      ('all', 'All scoring states'),
      for (final LlmState l in LlmState.values)
        if (counts[l] != null) (l.wire, '${l.label} (${counts[l]})'),
    ];
  }

  bool get _isFiltered =>
      _search.isNotEmpty ||
      _asmFilter != 'all' ||
      _typeFilter != 'all' ||
      _stateFilter != 'all' ||
      _attn != _Attn.none;

  /// The rows themselves. One builder for the flat table and for a group's
  /// contents, so a grouped row and an ungrouped one cannot drift apart.
  List<GridRow> _rows(BuildContext context, AppStore s, List<AnswerRef> slice) {
    final AppTokens t = context.tokens;
    return slice.map((AnswerRef a) {
      final String key = _key(a);
      final String who = _who(s, a);
      return GridRow(onTap: () => context.nav.response(a.ev.id, a.q.id), <
        Widget
      >[
        _RowCheck(
          on: _selected.contains(key),
          onChanged: (bool on) => setState(() {
            on ? _selected.add(key) : _selected.remove(key);
          }),
        ),
        // Who sat it, and which assessment.
        //
        // THE NAME GOES SOMEWHERE DIFFERENT FROM THE ROW: the row opens this
        // one answer, the name opens the PERSON. Two targets in one cell is
        // confined to here - reached from an assessment the scope is that
        // paper and the name opens the attempt, but this list already spans
        // every assessment, so widening the scope is what the reader wants.
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Flexible(
                  child: _CandidateLink(name: who, personId: a.ev.employeeId),
                ),
                if (a.ev.piiAnonymized) ...<Widget>[
                  const SizedBox(width: 6),
                  const StatusBadge('Anonymized', Tone.inert),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Text(
              a.asm.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.tiny,
            ),
          ],
        ),
        // The question, with its type under it.
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              a.q.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.tableCell.copyWith(color: t.textSecondary),
            ),
            const SizedBox(height: 3),
            StatusBadge(a.q.taskLabel, Tone.inert),
          ],
        ),
        Text(
          redactFor(a.ev, answerSummary(a.q, a.r)),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: context.type.tableCell.copyWith(color: t.textSecondary),
        ),
        // Invariant 2: a score is always marks out of a total.
        // The total is the question's COMPONENT count, not a
        // literal 1 - a three-sub-question mcq printed "2 / 1"
        // here while the same screen's export said "2 / 3". The
        // raw subjective score sits under it - same fact at a
        // finer grain, not a separate column.
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Marks(a.r.mark, a.r.markOutOf),
            if (a.r.llmRaw100 != null) ...<Widget>[
              const SizedBox(height: 2),
              Mono(
                'raw ${rawFromHundred(a.r.llmRaw100)}',
                size: 11,
                color: t.textMuted,
              ),
            ],
          ],
        ),
        // Where it stands, and anything holding it back.
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // THE QUEUE WINS THE CELL, as it does on the candidate page: a
            // re-score of an already-SCORED answer leaves `llm_state` at
            // `scored` the whole time it waits, so the state alone would make a
            // bulk press look like it did nothing.
            if (a.r.rescoreRequested)
              const Pill('Re-score queued', Tone.info)
            else
              Pill.state(a.r.llmState),
            // WHY IT FAILED, not just that it did.
            //
            // `llm_error` is stored on the model and sent by
            // `evaluator_admin_row`, and the ONLY thing this app did with it was
            // put it in the search haystack (see `_haystack`) - no column, no
            // cell, no detail field rendered it anywhere. So an operator read
            // "42 answers hit a terminal grader error ... Recovery is manual"
            // and had no way to find out WHAT went wrong before deciding
            // whether re-scoring would help: a bad API key and a malformed
            // rubric both present as the same red pill, and only one of them is
            // fixed by pressing the button. Measured on stage: 42 errored
            // answers, reason invisible on every one.
            //
            // Shown only for the states where a reason exists, and clipped to
            // two lines with the full text on hover - the message is a raw
            // exception string (240 chars on the model) and this is a table row.
            if ((a.r.llmError ?? '').trim().isNotEmpty &&
                (a.r.llmState == LlmState.error ||
                    a.r.llmState == LlmState.failed)) ...<Widget>[
              const SizedBox(height: 3),
              Tooltip(
                message: a.r.llmError!,
                child: Text(
                  a.r.llmError!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.tiny.copyWith(color: t.destText),
                ),
              ),
            ],
            if (a.r.judge != null && isGated(a.r.judge)) ...<Widget>[
              const SizedBox(height: 3),
              gateBadge(a.r.judge!),
            ],
          ],
        ),
        a.r.judge == null
            ? const SizedBox.shrink()
            : Btn(
                'View',
                tooltip:
                    'View the grader\'s full reasoning for this answer, without '
                    'leaving the table.',
                size: BtnSize.sm,
                onPressed: () => showAuditSheet(
                  context,
                  ev: a.ev,
                  asm: a.asm,
                  q: a.q,
                  r: a.r,
                  judge: a.r.judge!,
                ),
              ),
      ]);
    }).toList();
  }

  /// Download the filtered rows as CSV.
  ///
  /// Reuses the host app's `buildCsv`/`downloadCsv`, so escaping is RFC 4180 in
  /// one place. Exports what is ON SCREEN, in the ORDER it is on screen, so the
  /// filters and the sort the user set are the ones they get.
  void _exportCsv(List<AnswerRef> rows) {
    final AppStore s = widget.store;
    final String csv = buildCsv(
      <String>[
        'Attempt',
        'Candidate',
        'Assessment',
        'Question',
        'Type',
        'Answer',
        'Correct Answer',
        'Score',
        'Max',
        'Scoring state',
      ],
      rows
          .map(
            (AnswerRef a) => <Object?>[
              a.ev.id,
              s.personById(a.ev.employeeId)?.name ?? a.ev.employeeId,
              a.asm.name,
              a.q.prompt,
              a.q.taskLabelLong,
              // THE SAME STRING THE TABLE PRINTS, not `lines.join(' | ')`.
              //
              // That spelling exported nothing at all, on every row. `lines` is
              // absent from `/api/v1/responses` entirely - it arrives only on
              // the per-answer audit route - so the column was empty for
              // objective answers; and a subjective answer's prose lives in
              // `justification`, never in `lines`, so it was empty for those
              // too. An export whose Answer column is blank is the one column
              // the export exists for.
              //
              // REDACTED, like the cell at [_rows] and the search haystack at
              // [_hay]. Making the column non-empty is what first gave the
              // export something to leak: a table reading "[erased]" on screen
              // would have written the underlying text - and the answer key
              // beside it - into a file that leaves the app.
              redactFor(a.ev, answerSummary(a.q, a.r)),
              // Worth a column of its own: an export is read away from the app,
              // where a mark cannot be checked against anything unless the key
              // travels with it.
              a.q.type.hasOptionKey
                  ? redactFor(a.ev, correctSummary(a.q, a.r))
                  : '',
              a.r.mark,
              a.r.markOutOf,
              a.r.llmState.label,
            ],
          )
          .toList(),
    );
    downloadCsv('assessment-responses.csv', csv);
    s.toaster.ok('Exported ${rows.length} row(s)');
  }
}

/// The candidate's name, as its own target: it opens the PERSON, not the row's
/// answer.
///
/// Like [_RowCheck], the inner tap wins the gesture arena, so the row's own
/// `onTap` never fires for a click that landed on the name. That is the point -
/// the two destinations answer different questions, and an operator who clicks
/// a person's name is asking about the person.
///
/// WITHOUT AN ID IT STAYS A PLAIN CELL. `/api/v1/responses` carries the
/// candidate object on every row, but an attempt reconstructed from a row that
/// somehow lacks one has an empty `employeeId`, and a link there would open a
/// page that can only say "Candidate not found". A dead link is worse than no
/// link: it reads as the record being broken rather than absent.
class _CandidateLink extends StatelessWidget {
  final String name;
  final String personId;

  const _CandidateLink({required this.name, required this.personId});

  @override
  Widget build(BuildContext context) {
    if (personId.isEmpty) return GridLink.plain(name);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => context.nav.candidate(personId),
        // Opaque so the whole cell is the target, not just the glyphs.
        behavior: HitTestBehavior.opaque,
        child: GridLink(name),
      ),
    );
  }
}

/// The row selection box. It stops the tap from reaching the row, because
/// selecting a row and navigating away from it are opposite intentions.
class _RowCheck extends StatelessWidget {
  final bool on;
  final ValueChanged<bool> onChanged;

  const _RowCheck({required this.on, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(!on),
        child: Container(
          width: 17,
          height: 17,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? t.primary : Colors.transparent,
            borderRadius: Radii.badge,
            border: Border.all(color: on ? t.primary : t.border, width: 1.5),
          ),
          child: on
              ? const Icon(Icons.check, size: 11, color: Color(0xFFFFFFFF))
              : null,
        ),
      ),
    );
  }
}
