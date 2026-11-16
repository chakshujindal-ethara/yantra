// LLM budget - HANDOVER 4.3, `#/admin/budget`.
//
// Token spend and estimated cost for every model call the module makes.
//
// The chart rule this screen is built around (HANDOVER 1.9): the dark
// categorical pair sits at deltaE 7.3, in the floor band, so COLOUR ALONE IS
// NOT PERMITTED TO CARRY MEANING. Every chart here therefore adds secondary
// encoding - a legend, a direct label on each value, and a 2px gap between
// adjacent stacked segments.
import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../widgets/buttons.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../../theme.dart';
import '../../nav.dart';

class BudgetScreen extends StatelessWidget {
  final AppStore store;

  const BudgetScreen({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;

    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext context, _) {
        final List<LedgerRow> rows = store.ledger;

        double sum(double Function(LedgerRow) f) =>
            rows.fold<double>(0, (double a, LedgerRow r) => a + f(r));
        int sumInt(int Function(LedgerRow) f) =>
            rows.fold<int>(0, (int a, LedgerRow r) => a + f(r));

        final double totalCost = sum((LedgerRow r) => r.cost);
        final int tokensIn = sumInt((LedgerRow r) => r.tokensIn);
        final int tokensOut = sumInt((LedgerRow r) => r.tokensOut);
        final int thoughts = sumInt((LedgerRow r) => r.thoughts);
        final int totalTokens = tokensIn + tokensOut + thoughts;

        // ── Grouping ─────────────────────────────────────────────────────
        final Map<String, double> costByOp = <String, double>{};
        final Map<String, int> reqByOp = <String, int>{};
        final Map<String, int> tokByModel = <String, int>{};
        final Map<String, _TokenSplit> tokensByOp = <String, _TokenSplit>{};

        for (final LedgerRow r in rows) {
          final String op = r.op.label;
          costByOp[op] = (costByOp[op] ?? 0) + r.cost;
          reqByOp[op] = (reqByOp[op] ?? 0) + 1;
          tokByModel[r.model] = (tokByModel[r.model] ?? 0) + r.totalTokens;
          final _TokenSplit s =
              tokensByOp[op] ?? (tokensByOp[op] = _TokenSplit(op));
          s.add(r);
        }

        final List<_Slice> costRows = _ranked(costByOp);
        final List<_Slice> modelRows = _ranked(
          tokByModel.map(
            (String k, int v) => MapEntry<String, double>(k, v.toDouble()),
          ),
        ).take(6).toList();
        final List<_Slice> reqRows = _ranked(
          reqByOp.map(
            (String k, int v) => MapEntry<String, double>(k, v.toDouble()),
          ),
        ).take(6).toList();
        final List<_TokenSplit> splitRows = tokensByOp.values.toList()
          ..sort((_TokenSplit a, _TokenSplit b) => b.total.compareTo(a.total));

        // ── Attribution ──────────────────────────────────────────────────
        //
        // Authoring rows carry a generator; evaluation rows carry an attempt,
        // which resolves back through its assessment to a generator. Anything
        // that resolves to neither is SHOWN, not quietly dropped - an
        // untraceable cost is exactly the one worth surfacing.
        final Map<String, _Project> byProject = <String, _Project>{};
        double unattributed = 0;
        int unattributedReq = 0;

        for (final LedgerRow r in rows) {
          String? gid = r.genId;
          if (gid == null && r.evId != null) {
            final Attempt? ev = store.attemptById(r.evId);
            gid = ev == null
                ? null
                : store.asmById(ev.assessmentId)?.generatorId;
          }
          if (gid == null || gid.isEmpty) {
            unattributed += r.cost;
            unattributedReq++;
            continue;
          }
          final _Project p = byProject[gid] ?? (byProject[gid] = _Project(gid));
          if (p.name.isEmpty && r.genName.isNotEmpty) p.name = r.genName;
          // The split is by operation, so a new authoring operation lands on
          // the right side of the ledger without this screen being touched.
          if (r.op.isAuthoring) {
            p.authoring += r.cost;
          } else {
            p.evaluation += r.cost;
          }
          p.tokens += r.totalTokens;
          p.requests++;
        }

        final List<_Project> projects = byProject.values.toList()
          ..sort((_Project a, _Project b) => b.total.compareTo(a.total));

        final double authoringSpend = projects.fold<double>(
          0,
          (double a, _Project p) => a + p.authoring,
        );
        final int authoringShare = totalCost <= 0
            ? 0
            : (authoringSpend / totalCost * 100).round();

        // Cost and calls come from the server's lifetime totals; everything
        // else is summed from the rows held, so it says when those are a
        // sample (F2-01).
        final ({double spend, int calls})? life = store.budgetLifetime;
        final double cost = life?.spend ?? totalCost;
        final int calls = life?.calls ?? rows.length;
        final String sample = 'last ${nf(rows.length)} calls';
        final bool partial = life == null || life.calls > rows.length;
        String held(String sub) => partial ? sample : sub;

        return PageBody(
          children: <Widget>[
            // No breadcrumb here: this IS a root destination, and the shell
            // already prints "Admin / <page>" in its top bar. Repeating it
            // put the same words on screen three times in 100px.
            PageHead(
              'LLM Budget',
              sub:
                  'Token spend and estimated cost across every model call '
                  'this module makes.',
              actions: <Widget>[
                Btn(
                  'Ledger',
                  onPressed: () => context.nav.go(const LedgerAdmin()),
                ),
              ],
            ),
            // TODAY AGAINST THE CAP, from the server's own aggregate.
            //
            // Everything below this is spend to date, which answers "what has
            // this cost" but not the question an operator actually has before
            // pressing Generate: is there budget left today. The cap lives in
            // settings and the day's spend is a filtered sum - neither is
            // derivable from the rows on screen, and without this a generation
            // refused on a cap looks like one that failed.
            _TodayPanel(store: store),
            // Three of these six navigate. A stat that navigates is a control;
            // one that is merely informative is not, so only these carry a tap.
            //
            // minWidth 240, not the 152 default: SIX cards across a 996px area
            // gives 155px each, and a real six-figure token count ("118,940")
            // does not fit - it rendered as "118,9...".
            //
            // 240 wraps to 3 + 3. At 190 it fitted 5 and orphaned the sixth on
            // a row of its own, which reads as a rendering fault.
            KpiStrip(minWidth: 240, <Widget>[
              Kpi(
                label: 'Total cost',
                value: usd(cost),
                sub: life == null ? sample : 'estimated, all time',
                valueColor: t.primary,
                onTap: () => context.nav.go(const LedgerAdmin()),
              ),
              Kpi(
                label: 'Requests',
                value: nf(calls),
                sub: life == null ? sample : 'model calls, all time',
                onTap: () => context.nav.go(const LedgerAdmin()),
              ),
              Kpi(
                label: 'Total tokens',
                value: nf(totalTokens),
                sub: held('in + out + thinking'),
                onTap: () => context.nav.go(const LedgerAdmin()),
              ),
              Kpi(
                label: 'Avg per request',
                value: usd(cost / (calls == 0 ? 1 : calls)),
                sub: life == null ? sample : 'cost',
              ),
              Kpi(
                label: 'Images',
                value: nf(sumInt((LedgerRow r) => r.images)),
                sub: held('rendered'),
              ),
              Kpi(
                label: 'Video seconds',
                value: nf(sumInt((LedgerRow r) => r.videoSeconds)),
                sub: held('generated'),
              ),
            ]),
            KpiStrip(<Widget>[
              Kpi(label: 'Tokens in', value: nf(tokensIn), sub: held('prompt')),
              Kpi(
                label: 'Tokens out',
                value: nf(tokensOut),
                sub: held('completion'),
              ),
              Kpi(
                label: 'Thinking tokens',
                value: nf(thoughts),
                sub: held('billed as output'),
              ),
              Kpi(
                label: 'Authoring share',
                value: '$authoringShare%',
                sub: held('of spend'),
              ),
            ]),
            const Notice(
              tone: Tone.inert,
              text: 'Every card above opens the underlying ledger.',
            ),
            const SizedBox(height: 16),
            Cols2(
              left: Panel(
                title: 'Cost by Operation',
                child: _HBarChart(
                  rows: costRows,
                  format: usd,
                  fill: t.seq3,
                  seriesLabel: 'Estimated cost',
                  emptyMessage:
                      'No calls recorded yet. Run a generator or grade an '
                      'answer and the spend appears here.',
                ),
              ),
              right: Panel(
                title: 'Tokens by Operation',
                note: 'Input \u00b7 output \u00b7 thinking',
                child: _StackedBarChart(
                  rows: splitRows.take(6).toList(),
                  emptyMessage:
                      'No token usage recorded yet. It appears as soon as a '
                      'model call lands.',
                ),
              ),
            ),
            const SizedBox(height: 16),
            Cols2(
              left: Panel(
                title: 'Tokens by Model',
                child: _HBarChart(
                  rows: modelRows,
                  format: (double v) => nf(v.round()),
                  fill: t.seq2,
                  seriesLabel: 'Total tokens',
                  emptyMessage:
                      'No model has been called yet. Usage appears here per '
                      'model once one has.',
                ),
              ),
              right: Panel(
                title: 'Requests by Operation',
                child: _VColChart(
                  rows: reqRows,
                  seriesLabel: 'Model calls',
                  emptyMessage:
                      'No requests recorded yet. Each model call adds one to '
                      'its operation.',
                ),
              ),
            ),
            const SizedBox(height: 16),
            Panel(
              title: 'Cost by Project',
              note:
                  'Authoring the bank versus evaluating candidates against '
                  'it',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (projects.isEmpty && unattributedReq == 0)
                    const EmptyLine(
                      'No spend is attributed yet. Run a generator to see its '
                      'authoring cost appear here.',
                    ),
                  for (int i = 0; i < projects.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(height: 11),
                    _ProjectCard(
                      project: projects[i],
                      generator: store.genById(projects[i].gid),
                    ),
                  ],
                  // On the recessed surface, so it does not read as one more
                  // project.
                  if (unattributedReq > 0) ...<Widget>[
                    if (projects.isNotEmpty) const SizedBox(height: 11),
                    _UnattributedCard(
                      cost: unattributed,
                      requests: unattributedReq,
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One labelled magnitude in a chart.
class _Slice {
  final String label;
  final double value;

  const _Slice(this.label, this.value);
}

List<_Slice> _ranked(Map<String, double> m) {
  final List<_Slice> out = <_Slice>[
    for (final MapEntry<String, double> e in m.entries) _Slice(e.key, e.value),
  ]..sort((_Slice a, _Slice b) => b.value.compareTo(a.value));
  return out;
}

/// Input, output and thinking tokens for one operation. These are three
/// magnitudes of a single measure, so they take the sequential ramp rather
/// than three categorical hues.
class _TokenSplit {
  final String label;
  int tin = 0;
  int tout = 0;
  int th = 0;

  _TokenSplit(this.label);

  void add(LedgerRow r) {
    tin += r.tokensIn;
    tout += r.tokensOut;
    th += r.thoughts;
  }

  int get total => tin + tout + th;
}

/// One generator's spend, split by what the calls were for.
class _Project {
  final String gid;

  /// The name off the ledger row, when one came with it. The generator list is
  /// paged, so `store.genById` can miss on precisely the historic runs a spend
  /// audit is looking at - and the card then had nothing to print but the bare
  /// id.
  ///
  /// It used to miss on archived generators too; the store now fetches those
  /// (`include_archived`, for the list's Show archived toggle) so that half no
  /// longer applies. The paging half still does, and a ledger row that names
  /// its own generator is cheaper than resolving one either way.
  String name = '';
  double authoring = 0;
  double evaluation = 0;
  int tokens = 0;
  int requests = 0;

  _Project(this.gid);

  double get total => authoring + evaluation;
}

// ── Charts ────────────────────────────────────────────────────────────────

/// `.chart` with `.hrow` - label, track, value. The track is a proportion of
/// the largest row, so the longest bar always fills the width and the rest are
/// read against it.
class _HBarChart extends StatelessWidget {
  final List<_Slice> rows;
  final String Function(double) format;
  final Color fill;
  final String seriesLabel;
  final String emptyMessage;

  const _HBarChart({
    required this.rows,
    required this.format,
    required this.fill,
    required this.seriesLabel,
    required this.emptyMessage,
  });

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return EmptyLine(emptyMessage);

    final double max = rows.first.value <= 0 ? 1 : rows.first.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < rows.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 10),
          Row(
            children: <Widget>[
              SizedBox(
                width: 132,
                child: Text(
                  rows[i].label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.small.copyWith(fontSize: 12),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: _Track(
                  segments: <_Segment>[_Segment(rows[i].value / max, fill)],
                ),
              ),
              const SizedBox(width: 11),
              // The direct label. Without it the bar length alone would have
              // to carry the value, which the palette is not allowed to do.
              Mono(format(rows[i].value), size: 12, weight: FontWeight.w600),
            ],
          ),
        ],
        const SizedBox(height: 10),
        _Legend(items: <_LegendItem>[_LegendItem(seriesLabel, fill)]),
        const SizedBox(height: 3),
        Text(
          'Bars are drawn against the largest row, ${format(max)}.',
          style: context.type.tiny,
        ),
      ],
    );
  }
}

/// The stacked input / output / thinking bar. Adjacent segments carry a 2px
/// gap so the boundary is visible without relying on the hue change.
class _StackedBarChart extends StatelessWidget {
  final List<_TokenSplit> rows;
  final String emptyMessage;

  const _StackedBarChart({required this.rows, required this.emptyMessage});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    if (rows.isEmpty) return EmptyLine(emptyMessage);

    final int max = rows.first.total <= 0 ? 1 : rows.first.total;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < rows.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 10),
          Row(
            children: <Widget>[
              SizedBox(
                width: 132,
                child: Text(
                  rows[i].label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.small.copyWith(fontSize: 12),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: _Track(
                  segments: <_Segment>[
                    _Segment(rows[i].tin / max, t.seq3),
                    _Segment(rows[i].tout / max, t.seq2),
                    _Segment(rows[i].th / max, t.seq1),
                  ],
                ),
              ),
              const SizedBox(width: 11),
              Mono(nf(rows[i].total), size: 12, weight: FontWeight.w600),
            ],
          ),
          // Each segment names its own number, because three shades of one
          // ramp are the hardest case for a reader to separate by eye.
          Padding(
            padding: const EdgeInsets.only(left: 143, top: 3),
            child: Text(
              'in ${nf(rows[i].tin)}  \u00b7  out ${nf(rows[i].tout)}  '
              '\u00b7  thinking ${nf(rows[i].th)}',
              style: context.type.tiny,
            ),
          ),
        ],
        const SizedBox(height: 10),
        _Legend(
          items: <_LegendItem>[
            _LegendItem('Input', t.seq3),
            _LegendItem('Output', t.seq2),
            _LegendItem('Thinking', t.seq1),
          ],
        ),
      ],
    );
  }
}

/// `.cols` - a column chart. Every column prints its value above it and its
/// label below, so the chart survives being read in greyscale.
class _VColChart extends StatelessWidget {
  final List<_Slice> rows;
  final String seriesLabel;
  final String emptyMessage;

  const _VColChart({
    required this.rows,
    required this.seriesLabel,
    required this.emptyMessage,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    if (rows.isEmpty) return EmptyLine(emptyMessage);

    final double max = rows.first.value <= 0 ? 1 : rows.first.value;
    const double plotHeight = 108;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          // +60 rather than +48: the column above each bar is value label,
          // gap, bar, gap, then a two-line caption. At +48 the caption's
          // second line was 11px past the box and clipped.
          height: plotHeight + 60,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              for (int i = 0; i < rows.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      Mono(
                        nf(rows[i].value.round()),
                        size: 12,
                        weight: FontWeight.w600,
                      ),
                      const SizedBox(height: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 72),
                        child: Container(
                          height: (rows[i].value / max * plotHeight).clamp(
                            3,
                            plotHeight,
                          ),
                          decoration: BoxDecoration(
                            color: t.seq2,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(4),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        rows[i].label,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: context.type.tiny.copyWith(fontSize: 10.5),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        _Legend(items: <_LegendItem>[_LegendItem(seriesLabel, t.seq2)]),
      ],
    );
  }
}

/// One filled portion of a track.
class _Segment {
  final double fraction;
  final Color color;

  const _Segment(this.fraction, this.color);
}

/// `.track` - the 14px bar the segments sit in. The 2px gap between adjacent
/// segments is required secondary encoding, not spacing taste.
class _Track extends StatelessWidget {
  final List<_Segment> segments;

  const _Track({required this.segments});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth.isFinite ? c.maxWidth : 0;
        final List<_Segment> drawn = segments
            .where((_Segment s) => s.fraction > 0)
            .toList();
        // The 2px gaps between segments are part of the track, not extra on
        // top of it. The fractions already sum to 1, so measuring them against
        // the full width and THEN adding the gaps overflowed the bar by
        // 2 x (segments - 1). Subtracting the gaps first keeps the total exact.
        const double gap = 2;
        final double usable =
            (w - gap * (drawn.length - 1).clamp(0, drawn.length)).clamp(0.0, w);
        return Container(
          height: 14,
          decoration: BoxDecoration(
            color: t.bgMuted,
            borderRadius: const BorderRadius.horizontal(
              right: Radius.circular(4),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: <Widget>[
              for (int i = 0; i < drawn.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: gap),
                Container(
                  width: drawn[i].fraction.clamp(0.0, 1.0) * usable,
                  decoration: BoxDecoration(
                    color: drawn[i].color,
                    borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(4),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _LegendItem {
  final String label;
  final Color color;

  const _LegendItem(this.label, this.color);
}

/// `.legend` - required on every chart in the module.
class _Legend extends StatelessWidget {
  final List<_LegendItem> items;

  const _Legend({required this.items});

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 12,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: <Widget>[
      for (final _LegendItem i in items)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: i.color,
                borderRadius: const BorderRadius.all(Radius.circular(3)),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                i.label,
                overflow: TextOverflow.ellipsis,
                style: context.type.small,
              ),
            ),
          ],
        ),
    ],
  );
}

/// One generator's spend card: authoring against evaluation, with both halves
/// labelled in figures beneath the bar.
class _ProjectCard extends StatelessWidget {
  final _Project project;
  final Generator? generator;

  const _ProjectCard({required this.project, required this.generator});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final double total = project.total <= 0 ? 1 : project.total;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: Radii.card,
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  generator?.name ??
                      (project.name.isNotEmpty
                          ? project.name
                          : 'Generator ${project.gid}'),
                  overflow: TextOverflow.ellipsis,
                  style: context.type.body.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (generator != null) ...<Widget>[
                const SizedBox(width: 9),
                StatusBadge('${generator!.questionCount} Q', Tone.inert),
                const SizedBox(width: 7),
                StatusBadge('${generator!.tags.length} tags', Tone.inert),
              ],
              const Spacer(),
              Mono(usd(project.total), weight: FontWeight.w600),
            ],
          ),
          const SizedBox(height: 9),
          _Track(
            segments: <_Segment>[
              _Segment(project.authoring / total, t.c1),
              _Segment(project.evaluation / total, t.c2),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: _Legend(
                  items: <_LegendItem>[
                    _LegendItem('Authoring ${usd(project.authoring)}', t.c1),
                    _LegendItem('Evaluation ${usd(project.evaluation)}', t.c2),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Mono(
                '${nf(project.tokens)} tokens  \u00b7  '
                '${project.requests} requests',
                size: 11,
                color: t.textMuted,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Spend that resolves to no project. Drawn explicitly, because a cost with no
/// owner is the one a budget review most needs to see.
class _UnattributedCard extends StatelessWidget {
  final double cost;
  final int requests;

  const _UnattributedCard({required this.cost, required this.requests});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: t.bgSubtle,
        borderRadius: Radii.card,
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: <Widget>[
          // Expanded, not Flexible + Spacer: those are both flex children and
          // split the free width, so the cost drifted left of the right edge
          // and did not line up with the rows above it.
          Expanded(
            child: Row(
              children: <Widget>[
                Text(
                  'Unattributed',
                  style: context.type.body.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    'no resolvable project',
                    overflow: TextOverflow.ellipsis,
                    style: context.type.small,
                  ),
                ),
              ],
            ),
          ),
          Mono('${usd(cost)}  \u00b7  $requests requests'),
        ],
      ),
    );
  }
}

// ── Number formatting ─────────────────────────────────────────────────────

/// A cost, always to the cent. Estimated spend is compared across rows, so the
/// decimal count is fixed rather than significant-figure trimmed.
String usd(double v) => '\$${v.toStringAsFixed(2)}';

/// A count with thousands separators, so a six-figure token total can be read
/// at a glance in a mono column.
String nf(int v) {
  final String s = v.abs().toString();
  final StringBuffer out = StringBuffer(v < 0 ? '-' : '');
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

/// Today's spend against the daily cap.
///
/// Rendered from `/api/v1/budget` rather than from the ledger rows: the cap is
/// a setting, and "capped" is a decision the server makes with the same
/// numbers it will use to refuse the next call. Recomputing either here would
/// be a second opinion on a question that must have exactly one answer.
class _TodayPanel extends StatelessWidget {
  final AppStore store;

  const _TodayPanel({required this.store});

  @override
  Widget build(BuildContext context) {
    final ({double spend, double cap, double? remaining, bool capped})? today =
        store.budgetToday;
    // Seed mode, or a refresh that has not run. Silence beats an invented zero.
    if (today == null) return const SizedBox.shrink();

    final bool uncapped = today.cap <= 0;
    final double frac = uncapped
        ? 0
        : (today.spend / today.cap).clamp(0.0, 1.0).toDouble();
    // 80% is a warning, not a failure: it is the point at which a long
    // generation run started now would probably not finish.
    final Tone tone = today.capped
        ? Tone.bad
        : (frac >= 0.8 ? Tone.warn : Tone.ok);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Panel(
        title: 'Today',
        note: uncapped ? 'No cap set' : '${(frac * 100).round()}% of cap',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (today.capped)
              const Notice(
                tone: Tone.bad,
                strong: 'The daily cap is reached.',
                text:
                    'Generation and scoring will refuse until tomorrow, or '
                    'until the cap is raised in Settings.',
              )
            else if (uncapped)
              const Notice(
                tone: Tone.warn,
                strong: 'No daily cap is set.',
                text:
                    'Spend is unbounded. Set one in Settings under Retention '
                    'and spend.',
              ),
            const SizedBox(height: 12),
            KpiStrip(<Widget>[
              Kpi(
                label: 'Spent today',
                value: usd(today.spend),
                sub: uncapped ? 'no cap' : 'of ${usd(today.cap)}',
                valueColor: tone == Tone.ok ? null : context.tokens.warnText,
              ),
              Kpi(
                label: 'Remaining today',
                // null is not zero: the server sends null when no cap exists,
                // and printing "$0.00" there would read as exhausted.
                value: today.remaining == null ? '-' : usd(today.remaining!),
                sub: uncapped ? 'unbounded' : 'before calls refuse',
              ),
              Kpi(
                label: 'Per-candidate cap',
                value: _perCandidate(store),
                sub: 'bounds one attempt',
              ),
            ]),
          ],
        ),
      ),
    );
  }

  static String _perCandidate(AppStore store) {
    // `per_evaluator_cap_usd` on the wire - the SETTINGS key is
    // `per_evaluator_llm_cap_usd`, and reading the settings name here
    // silently found nothing and reported 'none' over a real $2 cap.
    final Object? v = store.budget['per_evaluator_cap_usd'];
    if (v is num && v > 0) return usd(v.toDouble());
    return 'none';
  }
}
