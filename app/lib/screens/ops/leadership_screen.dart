import 'package:flutter/material.dart';

import '../../api/analytics_models.dart';
import '../../api/analytics_repository.dart';
import '../../api/ops_models.dart';
import '../../app_scope.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/money.dart';
import '../../core/page_commands.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/action_dialog.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/form_sheet.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/people.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';
import '../shell.dart';

extension on AppScope {
  AnalyticsRepository get analytics => AnalyticsRepository(client.gateway);
}

/// Everything the page reads in one load.
class _Data {
  const _Data(this.lead, this.projects, this.funnel, this.workforce, this.baseline, this.rebuild);
  final Leadership lead;
  final Map<String, String> projects;
  final Funnel? funnel;
  final Workforce? workforce;
  final LeadBaseline? baseline;
  final RebuildState? rebuild;
}

/// The leadership page (ops, finance, admin): the four numbers of the plan against their baseline, gross
/// margin per project, the watch list, the hiring funnel and the bench this week. Every number says what
/// it is made of and opens the page that explains it. Ops set the baseline; admin rebuilds the warehouse.
class LeadershipScreen extends StatefulWidget {
  const LeadershipScreen({super.key});

  @override
  State<LeadershipScreen> createState() => _LeadershipScreenState();
}

class _LeadershipScreenState extends State<LeadershipScreen> {
  final _loader = GlobalKey<LoadViewState<_Data>>();
  int _days = 30;

  Future<T?> _optional<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on ApiException {
      return null; // a side panel that cannot load hides; the numbers still show
    }
  }

  Future<_Data> _load() async {
    final scope = AppScope.of(context);
    final roles = scope.session.roles;
    final a = scope.analytics;
    final lead = await a.leadership(days: _days);
    final results = await Future.wait<Object?>([
      roles.contains('ops') ? _optional(() => scope.ops.projects()) : Future.value(null),
      _optional(() => a.funnel(days: _days)),
      _optional(a.workforce),
      _optional<LeadBaseline?>(a.baseline),
      _optional(a.rebuild),
    ]);
    final projects = results[0] as List<ProjectSummary>?;
    return _Data(
      lead,
      {for (final p in projects ?? const <ProjectSummary>[]) p.id: p.name},
      results[1] as Funnel?,
      results[2] as Workforce?,
      results[3] as LeadBaseline?,
      results[4] as RebuildState?,
    );
  }

  Future<void> _reload() async => _loader.currentState?.reload();

  Future<void> _editBaseline(LeadBaseline? current) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => _BaselineSheet(current ?? const LeadBaseline()));
    if (saved == true && mounted) {
      toast(context, 'Baseline saved');
      await _reload();
    }
  }

  Future<void> _rebuild(String mode) async {
    final scope = AppScope.of(context);
    final ok = await confirm(
      context,
      title: mode == 'purge' ? 'Purge and rebuild the warehouse?' : 'Repair the warehouse?',
      body: mode == 'purge'
          ? 'Deletes the stored events of the last 30 days and replays them from the event stream. The numbers are empty until the replay ends.'
          : 'Replays the event stream into the warehouse and recomputes every number. Events already stored are kept.',
      confirmLabel: mode == 'purge' ? 'Purge and rebuild' : 'Repair',
      destructive: mode == 'purge',
    );
    if (!ok || !mounted) return;
    try {
      await withActionKey(scope.keys, 'rebuild:$mode', (key) => scope.analytics.requestRebuild(mode, key: key));
      if (!mounted) return;
      toast(context, 'Rebuild requested');
      await _reload();
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final roles = AppScope.of(context).session.roles;
    return LoadView<_Data>(
      key: _loader,
      firstWait: LoadWait.brand,
      wrapInCard: true,
      load: _load,
      builder: (context, d, reload) {
        final l = d.lead;
        return PortalPage(
          kicker: 'Insight · Leadership',
          title: 'Leadership',
          subtitle:
              'Last ${l.windowDays} days in ${l.currency}${l.asOf == null ? '' : ' · as of ${shortDate(l.asOf!.toLocal())}'}'
              '${l.baselineSetAt == null ? ' · no baseline set' : ' · baseline of ${shortDate(l.baselineSetAt!.toLocal())}'}',
          onRefresh: reload,
          commands: [
            PageCommand('Refresh the numbers', Icons.refresh, reload),
            if (roles.contains('ops')) PageCommand('Edit the baseline', Icons.flag_outlined, () => _editBaseline(d.baseline)),
          ],
          actions: [
            FilterChips<int>(
              values: const {'7 days': 7, '30 days': 30, '90 days': 90},
              selected: _days,
              onSelected: (v) {
                setState(() => _days = v ?? 30);
                _reload();
              },
            ),
          ],
          children: [
            const SectionTitle('The four numbers', subtitle: 'Against the baseline you set; each opens the page that explains it'),
            _TileGrid(l.numbers),
            const SectionTitle('Watch list'),
            _TileGrid(l.watch),
            SectionTitle('Margin per project', subtitle: 'Accepted units × price, less pay, review and audit'),
            _MarginTable(l.margin, d.projects),
            const SizedBox(height: Space.x16),
            TwoColumn(
              left: _FunnelCard(d.funnel),
              right: _BaselineCard(d.baseline, canEdit: roles.contains('ops'), onEdit: () => _editBaseline(d.baseline)),
            ),
            const SizedBox(height: Space.x16),
            const SectionTitle('The bench this week', subtitle: 'Active hours from the tracker, accepted units and earnings'),
            _WorkforceTable(d.workforce),
            if (d.rebuild != null) ...[
              const SizedBox(height: Space.x16),
              _RebuildCard(d.rebuild!, canRun: roles.contains('admin'), onRun: _rebuild),
            ],
          ],
        );
      },
    );
  }
}

/// A tile's value in its unit: money with the currency, a ratio as a percentage, days with one decimal.
String tileValue(String? v, String unit, String? currency) {
  if (v == null || v.isEmpty) return '—';
  final n = double.tryParse(v);
  return switch (unit) {
    'money' => formatMoney(v, currency: currency ?? ''),
    'ratio' => n == null ? v : '${(n * 100).toStringAsFixed(1)}%',
    'days' => n == null ? v : '${n.toStringAsFixed(1)} d',
    'per_1000' => n == null ? v : '${n.toStringAsFixed(1)} / 1,000',
    _ => v,
  };
}

/// What a number is made of, as one readable line (`batches 3 · reached 2`).
String basisLine(Map<String, dynamic> basis) => basis.entries
    .where((e) => e.value is num || e.value is String || e.value is bool)
    .map((e) => '${humanize(e.key).toLowerCase()} ${_plain(e.value)}')
    .join(' · ');

/// `150.000000` → `150`, `102.50` → `102.5`: database decimals read as plain figures.
String _plain(Object? v) {
  final text = '$v';
  if (!RegExp(r'^-?\d+\.\d+$').hasMatch(text)) return text;
  return text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

class _TileGrid extends StatelessWidget {
  const _TileGrid(this.tiles);
  final List<LeadershipTile> tiles;

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) return const PortalCard(child: EmptyView(message: 'No numbers yet. They appear once work flows.'));
    return KpiRow(children: [for (final t in tiles) LeadershipTileCard(t)]);
  }
}

/// One leadership number: the value, the baseline and whether it beats it, the basis, a link to its page.
class LeadershipTileCard extends StatelessWidget {
  const LeadershipTileCard(this.tile, {super.key});
  final LeadershipTile tile;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final scope = AppScope.of(context);
    final target = Destination.values.where((d) => d.name == tile.href).firstOrNull;
    final reachable = target != null && Destination.visibleTo(scope.session.roles).contains(target);
    final beats = tile.beatsBaseline;
    final (verdict, kind) = switch (beats) {
      true => ('On target', StatusKind.success),
      false => ('Off target', StatusKind.warn),
      null => (tile.baseline == null ? 'No baseline' : 'Not enough data', StatusKind.info),
    };
    final basis = basisLine(tile.basis);
    final value = tileValue(tile.value, tile.unit, tile.currency);
    final baseline = tileValue(tile.baseline, tile.unit, tile.currency);
    final open = reachable ? () => ShellActions.of(context).go(target) : null;
    return Semantics(
      container: true,
      button: reachable,
      label: '${tile.label}, $value. Baseline $baseline. $verdict${reachable ? '. Opens ${target.label}' : ''}',
      onTap: open, // the child's tap is excluded with its text, so the node carries it
      excludeSemantics: true,
      child: PortalCard(
        key: Key('tile-${tile.key}'),
        margin: EdgeInsets.zero,
        onTap: open,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(tile.label, style: theme.textTheme.titleSmall?.copyWith(color: t.textSecondary)),
                ),
                if (reachable) Icon(Icons.arrow_forward, size: Sizes.iconSm, color: t.textMuted),
              ],
            ),
            const SizedBox(height: Space.x8),
            Text(
              value,
              style: TextStyle(fontFamily: PortalType.familyMono, fontSize: 24, fontWeight: FontWeight.w500, color: t.textPrimary),
            ),
            const SizedBox(height: Space.x6),
            Wrap(
              spacing: Space.x8,
              runSpacing: Space.x4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusChip(verdict, kind: kind),
                Text('Baseline $baseline · ${tile.better} is better', style: theme.textTheme.bodySmall?.copyWith(color: t.textSecondary)),
              ],
            ),
            if (basis.isNotEmpty) ...[
              const SizedBox(height: Space.x6),
              Text(
                basis,
                style: AppTheme.figure(context, fontSize: 11, color: t.textSecondary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (tile.note != null) ...[
              const SizedBox(height: Space.x4),
              Text(
                tile.note!,
                style: theme.textTheme.bodySmall?.copyWith(color: t.textSecondary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MarginTable extends StatelessWidget {
  const _MarginTable(this.rows, this.names);
  final List<MarginRow> rows;
  final Map<String, String> names;

  @override
  Widget build(BuildContext context) {
    String pct(String? f) {
      final n = double.tryParse(f ?? '');
      return n == null ? '—' : '${(n * 100).toStringAsFixed(1)}%';
    }

    return PortalTable(
      minWidth: 860,
      emptyMessage: 'No accepted units in this window yet.',
      columns: const [
        PortalColumn('Project', flex: 3),
        PortalColumn('Accepted', numeric: true, width: 90),
        PortalColumn('Billed', numeric: true, flex: 2),
        PortalColumn('Pay', numeric: true, flex: 2),
        PortalColumn('Review + audit', numeric: true, flex: 2),
        PortalColumn('Margin', numeric: true, flex: 2),
        PortalColumn('Per unit', numeric: true, flex: 2),
        PortalColumn('Margin %', numeric: true, width: 90),
      ],
      rows: [
        for (final r in rows)
          PortalRow(key: Key('margin-${r.projectId}'), [
            names[r.projectId] == null ? ShortId(r.projectId) : Text(names[r.projectId]!, overflow: TextOverflow.ellipsis),
            Text('${r.accepted}'),
            Text(formatMoney(r.price, currency: r.currency)),
            Text(formatMoney(r.pay, currency: r.currency)),
            Text(
              formatMoney(((double.tryParse(r.review) ?? 0) + (double.tryParse(r.audit) ?? 0)).toStringAsFixed(2), currency: r.currency),
            ),
            Text(formatMoney(r.margin, currency: r.currency)),
            Text(r.marginPerUnit == null ? '—' : formatMoney(r.marginPerUnit!, currency: r.currency)),
            Text(pct(r.marginFraction)),
          ]),
      ],
    );
  }
}

const _stageOrder = ['applied', 'assessment', 'screening', 'offered', 'accepted', 'rejected', 'declined', 'withdrawn', 'expired'];

class _FunnelCard extends StatelessWidget {
  const _FunnelCard(this.f);
  final Funnel? f;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = this.f;
    if (f == null) {
      return const PortalCard(child: EmptyView(message: 'The hiring funnel could not be read.'));
    }
    final stages = [
      for (final s in _stageOrder)
        if (f.stages.containsKey(s) || f.stagesAvailable.contains(s)) s,
    ];
    final top = stages.isEmpty ? 0 : stages.map((s) => f.stages[s] ?? 0).reduce((a, b) => a > b ? a : b);
    return PortalCard(
      key: const Key('funnel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Hiring funnel', style: theme.textTheme.titleSmall),
          Text('Applications moving through every listing, last ${f.windowDays} days', style: theme.textTheme.bodySmall),
          const SizedBox(height: Space.x12),
          if (stages.isEmpty)
            const Text('No application has moved yet.')
          else
            for (final s in stages)
              ProgressRow(
                key: Key('funnel-$s'),
                label: humanize(s),
                value: (f.stages[s] ?? 0).toDouble(),
                total: top == 0 ? 1 : top.toDouble(),
                trailing: '${f.stages[s] ?? 0}',
              ),
        ],
      ),
    );
  }
}

class _BaselineCard extends StatelessWidget {
  const _BaselineCard(this.b, {required this.canEdit, required this.onEdit});
  final LeadBaseline? b;
  final bool canEdit;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = this.b;
    return PortalCard(
      key: const Key('baseline'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Baseline', style: theme.textTheme.titleSmall)),
              if (canEdit)
                TextButton.icon(
                  key: const Key('baseline-edit'),
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: Sizes.iconSm),
                  label: Text(b == null ? 'Set baseline' : 'Edit'),
                ),
            ],
          ),
          if (b == null)
            Text(
              'No baseline yet. Set the numbers you measured before Yantra, so each tile can say whether it is better.',
              style: theme.textTheme.bodySmall,
            )
          else ...[
            LabelValue(label: 'Days to staff a batch', value: tileValue(b.daysToStaff, 'days', b.currency)),
            LabelValue(label: 'Idle bench cost a week', value: tileValue(b.idleCostWeekly, 'money', b.currency)),
            LabelValue(label: 'First-pass acceptance', value: tileValue(b.firstPassAcceptance, 'ratio', b.currency)),
            LabelValue(label: 'Cost per accepted unit', value: tileValue(b.costPerAcceptedUnit, 'money', b.currency)),
            if (b.setAt != null)
              Text('Set ${shortDate(b.setAt!.toLocal())}${b.note == null ? '' : ' · ${b.note}'}', style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

class _WorkforceTable extends StatelessWidget {
  const _WorkforceTable(this.w);
  final Workforce? w;

  @override
  Widget build(BuildContext context) {
    final rows = w?.workers ?? const <WorkforceRow>[];
    String pct(String? f) {
      final n = double.tryParse(f ?? '');
      return n == null ? '—' : '${(n * 100).round()}%';
    }

    return PortalTable(
      minWidth: 720,
      emptyMessage: w == null ? 'The bench could not be read.' : 'Nobody has worked this week yet.',
      columns: const [
        PortalColumn('Worker', flex: 3),
        PortalColumn('Active hours', numeric: true, width: 110),
        PortalColumn('Accepted', numeric: true, width: 90),
        PortalColumn('Judged', numeric: true, width: 90),
        PortalColumn('Acceptance', numeric: true, width: 100),
        PortalColumn('Earnings', numeric: true, flex: 2),
      ],
      rows: [
        for (final r in rows)
          PortalRow(key: Key('workforce-${r.workerId}'), [
            NameOf(r.workerId),
            Text(r.activeHours.isEmpty ? '0' : r.activeHours),
            Text('${r.unitsAccepted}'),
            Text('${r.unitsJudged}'),
            Text(pct(r.acceptanceRate)),
            Text(r.earnings.isEmpty ? '—' : r.earnings.entries.map((e) => formatMoney(e.value, currency: e.key)).join(' + ')),
          ]),
      ],
    );
  }
}

class _RebuildCard extends StatelessWidget {
  const _RebuildCard(this.r, {required this.canRun, required this.onRun});
  final RebuildState r;
  final bool canRun;
  final void Function(String mode) onRun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = switch (r.status) {
      'done' => StatusKind.success,
      'requested' || 'running' => StatusKind.info,
      _ => StatusKind.info,
    };
    return PortalCard(
      key: const Key('rebuild'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Warehouse', style: theme.textTheme.titleSmall)),
              StatusChip(humanize(r.status), kind: kind),
            ],
          ),
          const SizedBox(height: Space.x6),
          Text(
            'Generation ${r.generation}${r.mode == null ? '' : ' · last ${r.mode}'}${r.events == null ? '' : ' · ${r.events} events replayed'}',
            style: theme.textTheme.bodySmall,
          ),
          if (canRun) ...[
            const SizedBox(height: Space.x12),
            Wrap(
              spacing: Space.x8,
              children: [
                OutlinedButton(
                  key: const Key('rebuild-repair'),
                  onPressed: r.busy ? null : () => onRun('repair'),
                  child: const Text('Repair'),
                ),
                OutlinedButton(
                  key: const Key('rebuild-purge'),
                  onPressed: r.busy ? null : () => onRun('purge'),
                  child: const Text('Purge and rebuild'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _BaselineSheet extends StatefulWidget {
  const _BaselineSheet(this.current);
  final LeadBaseline current;

  @override
  State<_BaselineSheet> createState() => _BaselineSheetState();
}

class _BaselineSheetState extends State<_BaselineSheet> {
  late final _days = TextEditingController(text: widget.current.daysToStaff ?? '');
  late final _idle = TextEditingController(text: widget.current.idleCostWeekly ?? '');
  late final _fp = TextEditingController(text: widget.current.firstPassAcceptance ?? '');
  late final _cpu = TextEditingController(text: widget.current.costPerAcceptedUnit ?? '');
  late final _hourly = TextEditingController(text: widget.current.idleHourlyCost);
  late final _staffing = TextEditingController(text: '${widget.current.staffingWorkers}');
  late final _note = TextEditingController(text: widget.current.note ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_days, _idle, _fp, _cpu, _hourly, _staffing, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _num(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    for (final c in [_days, _idle, _fp, _cpu, _hourly]) {
      if (c.text.trim().isNotEmpty && double.tryParse(c.text.trim()) == null) {
        setState(() => _error = 'Numbers only, like 4.5 or 0.82');
        return;
      }
    }
    final fp = double.tryParse(_fp.text.trim());
    if (fp != null && (fp < 0 || fp > 1)) {
      setState(() => _error = 'First-pass acceptance is a share between 0 and 1, like 0.82');
      return;
    }
    final staffing = int.tryParse(_staffing.text.trim());
    if (staffing == null || staffing < 1) {
      setState(() => _error = 'Workers to call a batch staffed is a whole number, 1 or more');
      return;
    }
    final scope = AppScope.of(context);
    final b = widget.current;
    final next = LeadBaseline(
      currency: b.currency,
      daysToStaff: _num(_days),
      idleCostWeekly: _num(_idle),
      firstPassAcceptance: _num(_fp),
      costPerAcceptedUnit: _num(_cpu),
      idleHourlyCost: _num(_hourly) ?? '0',
      idleHoursPerWeek: b.idleHoursPerWeek,
      staffingWorkers: staffing,
      railFeePerPayout: b.railFeePerPayout,
      levyRate: b.levyRate,
      payoutSlaDays: b.payoutSlaDays,
      note: _num(_note),
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await withActionKey(scope.keys, 'baseline:${next.toJson()}', (key) => scope.analytics.setBaseline(next, key: key));
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    TextField field(String key, TextEditingController c, String label, {String? hint}) => TextField(
      key: Key('baseline-$key'),
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, helperText: hint),
    );
    return FormSheet(
      title: 'Baseline',
      saveKey: const Key('baseline-save'),
      busy: _busy,
      error: ErrorBanner(_error),
      onSave: _save,
      children: [
        Text(
          'What you measured before Yantra. Every save is kept, so leadership can see what each number was compared against.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        fieldGap,
        FieldPair(field('days', _days, 'Days to staff a batch'), field('staffing', _staffing, 'Workers that make a batch staffed')),
        fieldGap,
        FieldPair(
          field('idle', _idle, 'Idle bench cost a week (${widget.current.currency})'),
          field('hourly', _hourly, 'Idle hourly cost (${widget.current.currency})'),
        ),
        fieldGap,
        FieldPair(
          field('fp', _fp, 'First-pass acceptance', hint: 'A share: 0.82 is 82%'),
          field('cpu', _cpu, 'Cost per accepted unit (${widget.current.currency})'),
        ),
        fieldGap,
        TextField(
          key: const Key('baseline-note'),
          controller: _note,
          decoration: const InputDecoration(labelText: 'Note (where these came from)'),
        ),
      ],
    );
  }
}
