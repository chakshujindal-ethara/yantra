import 'package:flutter/material.dart';
import '../../core/money.dart';
import '../../core/widgets/action_dialog.dart';
import '../../widgets/feedback_thread.dart';

import '../../api/ops_models.dart';
import '../../app_scope.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/json.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/form_sheet.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/stage_bar.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';
import '../shell.dart';
import 'projects_screen.dart';
import '../../core/widgets/detail_frame.dart';
import '../../app_router.dart';
import 'package:go_router/go_router.dart';

/// One project as a pushed route: units by stage, the batches with pay against bill, the verdict reasons,
/// the client's feedback, the rubric log, the brief. Edit and "New batch" live in the header.
class ProjectScreen extends StatelessWidget {
  const ProjectScreen({super.key, required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context) {
    return DetailFrame(
      crumbs: [
        const Crumb('Operate'),
        Crumb('Projects', path: Destination.projects.path),
        const Crumb('Project'),
      ],
      body: LoadView<ProjectDetail>(
        firstWait: LoadWait.brand,
        load: () => AppScope.of(context).ops.project(projectId),
        builder: (context, p, reload) => _ProjectBody(p, reload: reload),
      ),
    );
  }
}

class _ProjectBody extends StatelessWidget {
  const _ProjectBody(this.p, {required this.reload});
  final ProjectDetail p;
  final Future<void> Function() reload;

  Future<void> _edit(BuildContext context) async {
    final saved = await showDialog<ProjectDetail>(
      context: context,
      builder: (_) => ProjectFormDialog(initial: p),
    );
    if (saved == null || !context.mounted) return;
    AppScope.of(context).stale.mark([Destination.projects, Destination.opsOverview]);
    toast(context, 'Project saved');
    await reload();
  }

  Future<void> _newBatch(BuildContext context) async {
    final created = await showDialog<BatchSummary>(
      context: context,
      builder: (_) => BatchFormDialog(project: p),
    );
    if (created == null || !context.mounted) return;
    AppScope.of(context).stale.mark([Destination.projects, Destination.opsOverview]);
    toast(context, 'Batch "${created.title}" created as a draft');
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    final gate = p.certGate.isEmpty ? 'no gate' : 'gate ${p.certGate}';
    final floor = p.marginFloor == null ? 'no margin floor' : 'floor ${percent(p.marginFloor)}';
    return PortalPage(
      kicker: 'Operate · Project',
      title: p.name,
      subtitle:
          '${p.currency} · $gate · rubric ${p.rubricVersion} · $floor · kept ${p.retentionDays} days'
          '${p.closedAt == null ? '' : ' · closed ${shortDate(p.closedAt!)}'}',
      onRefresh: reload,
      actions: [
        ConsoleStatus(p.status),
        OutlinedButton.icon(
          key: const Key('project-edit'),
          onPressed: () => _edit(context),
          icon: const Icon(Icons.edit_outlined, size: Sizes.iconSm),
          label: const Text('Edit'),
        ),
        FilledButton.icon(
          key: const Key('new-batch'),
          onPressed: () => _newBatch(context),
          icon: const Icon(Icons.add, size: Sizes.iconSm),
          label: const Text('New batch'),
        ),
      ],
      children: [
        _UnitKpis(p.units),
        _Trend(projectId: p.id, currency: p.currency),
        SectionTitle('Batches', subtitle: 'Pay and bill side by side; a worker never sees the bill'),
        _Batches(p),
        const SizedBox(height: Space.x16),
        TwoColumn(
          left: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_Reasons(p.reasons), _RubricLog(p.rubricLog)]),
          right: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Brief(p),
              PortalCard(
                child: FeedbackThread(
                  key: const Key('project-feedback'),
                  items: p.feedback,
                  title: 'Client feedback',
                  subtitle: p.clientOrgId.isEmpty
                      ? 'The project has no client org; notes stay inside Yantra'
                      : 'The client reads your answers on their project page',
                  emptyMessage: 'Nothing from the client yet',
                  composerLabel: 'Answer the client',
                  sendLabel: 'Send answer',
                  onSend: (body) async {
                    final scope = AppScope.of(context);
                    await withActionKey(
                      scope.keys,
                      'feedback:${p.id}:${body.hashCode}',
                      (key) => scope.ops.sendFeedback(p.id, body, key: key),
                    );
                    await reload();
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _UnitKpis extends StatelessWidget {
  const _UnitKpis(this.u);
  final UnitCounts u;

  @override
  Widget build(BuildContext context) {
    return KpiRow(
      children: [
        KpiTile(label: 'Available', value: '${u.available}', note: 'of ${u.total} units', icon: Icons.inventory_2_outlined),
        KpiTile(label: 'In progress', value: '${u.claimed}', note: 'claimed right now', kind: StatusKind.info, icon: Icons.bolt_outlined),
        KpiTile(
          label: 'In review',
          value: '${u.reviewing}',
          note: '${u.submitted} submitted · ${u.inReview} in review',
          kind: StatusKind.warn,
          icon: Icons.rate_review_outlined,
        ),
        KpiTile(
          label: 'Accepted',
          value: '${u.accepted}',
          note: '${u.needsEdits} need edits · ${u.rejected} rejected',
          kind: StatusKind.success,
          icon: Icons.verified_outlined,
        ),
      ],
    );
  }
}

class _Batches extends StatelessWidget {
  const _Batches(this.p);
  final ProjectDetail p;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return PortalTable(
      minWidth: 960,
      emptyMessage: 'No batches yet. "New batch" creates a draft you can import units into.',
      columns: const [
        PortalColumn('Batch', flex: 2),
        PortalColumn('Status', width: 130),
        PortalColumn('Pay · bill', flex: 3),
        PortalColumn('Units', flex: 2),
        PortalColumn('Live', width: 70, numeric: true),
        PortalColumn('Manifest', width: 130),
      ],
      rows: [
        for (final b in p.batches)
          PortalRow(key: Key('batch-${b.id}'), onTap: () => context.push(Paths.batch(p.id, b.id), extra: p.marginFloor), [
            Text(b.title),
            ConsoleStatus(b.status),
            PayBill(
              pay: b.unitPay,
              bill: b.unitPrice,
              currency: b.currency,
              margin: b.margin,
              underFloor: b.underFloor(p.marginFloor),
              compact: true,
            ),
            StageBar(
              legend: false,
              available: b.units.available,
              inProgress: b.units.claimed,
              inReview: b.units.reviewing,
              accepted: b.units.accepted,
              rejected: b.units.rejected,
              needsEdits: b.units.needsEdits,
            ),
            Text('${b.liveClaims}'),
            Text(b.manifest == null ? '—' : b.manifest!.shortDigest, style: AppTheme.mono(context, fontSize: 12, color: t.textSecondary)),
          ]),
      ],
    );
  }
}

class _Reasons extends StatelessWidget {
  const _Reasons(this.reasons);
  final List<ReasonRow> reasons;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Verdict reasons', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x4),
          Text('Why units came back; billable ones count as rework on the invoice', style: theme.textTheme.bodySmall),
          const SizedBox(height: Space.x12),
          PortalTable(
            minWidth: 320,
            emptyMessage: 'No verdicts yet',
            columns: const [
              PortalColumn('Reason', flex: 2),
              PortalColumn('Count', width: 80, numeric: true),
              PortalColumn('Billable', width: 120),
            ],
            rows: [
              for (final r in reasons)
                PortalRow(key: Key('reason-${r.reasonCode}'), [
                  Text(humanize(r.reasonCode)),
                  Text('${r.count}'),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: StatusChip(r.billable ? 'Billable' : 'Not billable', kind: r.billable ? StatusKind.warn : StatusKind.info),
                  ),
                ]),
            ],
          ),
        ],
      ),
    );
  }
}

class _RubricLog extends StatelessWidget {
  const _RubricLog(this.log);
  final List<RubricLogEntry> log;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Rubric log', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x8),
          if (log.isEmpty) Text('No rubric change recorded', style: theme.textTheme.bodySmall),
          for (final e in log)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.x4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.version, style: AppTheme.mono(context, fontSize: 13)),
                  const SizedBox(width: Space.x12),
                  Expanded(child: Text(e.note.isEmpty ? '—' : e.note, style: theme.textTheme.bodyMedium)),
                  if (e.at != null) ...[
                    const SizedBox(width: Space.x12),
                    Text(shortDate(e.at!), style: theme.textTheme.labelSmall?.copyWith(color: t.textMuted)),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Brief extends StatelessWidget {
  const _Brief(this.p);
  final ProjectDetail p;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Brief', style: theme.textTheme.titleMedium)),
              p.sensitive ? const StatusChip('Sensitive', kind: StatusKind.warn) : const StatusChip('Not sensitive', kind: StatusKind.info),
            ],
          ),
          const SizedBox(height: Space.x8),
          Text(p.brief.isEmpty ? 'No brief yet. Edit the project to add one.' : p.brief, style: theme.textTheme.bodyMedium),
          const SizedBox(height: Space.x12),
          LabelValue(label: 'LLM policy', value: p.llmPolicy.isEmpty ? '—' : p.llmPolicy),
          _OrgName(p.clientOrgId),
          LabelValue(label: 'Retention', value: '${p.retentionDays} days after delivery, then payloads and answers are purged'),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const Key('project-schemas'),
              tilePadding: EdgeInsets.zero,
              title: Text('Schemas', style: theme.textTheme.labelMedium),
              subtitle: Text(
                'payload ${p.payloadSchema.isEmpty ? 'none' : '${readMap(p.payloadSchema, 'properties').length} fields'} · answer ${p.answerSchema.isEmpty ? 'none' : '${readMap(p.answerSchema, 'properties').length} fields'}',
                style: theme.textTheme.bodySmall,
              ),
              children: [
                LabelValue(label: 'Payload schema', value: p.payloadSchema.isEmpty ? '—' : prettyJson.convert(p.payloadSchema), mono: true),
                LabelValue(label: 'Answer schema', value: p.answerSchema.isEmpty ? '—' : prettyJson.convert(p.answerSchema), mono: true),
              ],
            ),
          ),
          if (p.createdAt != null)
            Text('Created ${shortDate(p.createdAt!)}', style: theme.textTheme.labelSmall?.copyWith(color: t.textMuted)),
        ],
      ),
    );
  }
}

/// The client org by name; the id is in the tooltip. Falls back to the id while the list loads.
class _OrgName extends StatelessWidget {
  const _OrgName(this.orgId);
  final String orgId;

  @override
  Widget build(BuildContext context) {
    if (orgId.isEmpty) return const LabelValue(label: 'Client org', value: 'None');
    return FutureBuilder<List<ClientOrg>>(
      future: AppScope.of(context).ops.clientOrgs(),
      builder: (context, snap) {
        final name = snap.data?.where((o) => o.id == orgId).map((o) => o.name).firstOrNull;
        return Tooltip(
          message: orgId,
          child: LabelValue(label: 'Client org', value: name ?? shortId(orgId), mono: name == null),
        );
      },
    );
  }
}

/// Thirty days of the project from analytics: accepted and rejected units per day, first-pass rate and
/// margin. Empty days show as gaps, so a quiet project reads as quiet, not as broken.
class _Trend extends StatelessWidget {
  const _Trend({required this.projectId, required this.currency});
  final String projectId;
  final String currency;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Last 30 days', subtitle: 'Accepted and rejected units per day, from the analytics marts'),
        LoadView<ProjectTrend>(
          wrapInCard: true,
          load: () => AppScope.of(context).ops.projectTrend(projectId),
          isEmpty: (t) => t.accepted + t.rejected == 0 && t.days.every((d) => d.published == 0 && d.claimed == 0),
          emptyMessage: 'No activity in the last 30 days.',
          builder: (context, trend, _) => PortalCard(
            key: const Key('project-trend'),
            child: _TrendChart(trend: trend, currency: currency),
          ),
        ),
      ],
    );
  }
}

class _TrendChart extends StatelessWidget {
  const _TrendChart({required this.trend, required this.currency});
  final ProjectTrend trend;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final days = trend.days;
    final peak = days.fold<int>(1, (m, d) => d.accepted + d.rejected > m ? d.accepted + d.rejected : m);
    final judged = trend.accepted + trend.rejected;
    // weighted by volume: first-pass accepts over everything judged, never a mean of daily rates
    final rated = days.where((d) => d.firstPassRate != null && d.accepted + d.rejected > 0);
    final ratedJudged = rated.fold<int>(0, (a, d) => a + d.accepted + d.rejected);
    final rate = ratedJudged == 0 ? null : rated.fold<double>(0, (a, d) => a + d.firstPassRate! * (d.accepted + d.rejected)) / ratedJudged;
    final summary =
        '${trend.accepted} accepted · ${trend.rejected} rejected${rate == null ? '' : ' · first pass ${percent(rate)}'}'
        ' · margin ${formatMoney(trend.margin.toStringAsFixed(2), currency: trend.currency.isEmpty ? currency : trend.currency)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(summary, style: theme.textTheme.bodyMedium),
        const SizedBox(height: Space.x12),
        if (judged == 0)
          Text(
            'Nothing judged yet: ${days.fold<int>(0, (a, d) => a + d.claimed)} claims and ${days.fold<int>(0, (a, d) => a + d.submitted)} submissions in the window.',
            key: const Key('trend-nothing-judged'),
            style: theme.textTheme.bodySmall?.copyWith(color: t.textSecondary),
          )
        else
          Semantics(
            label: 'Accepted units per day over ${days.length} days: $judged judged in all',
            excludeSemantics: true,
            child: SizedBox(
              height: 96,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final d in days)
                    Expanded(
                      child: Tooltip(
                        message: '${d.day == null ? '' : shortDate(d.day!)}: ${d.accepted} accepted, ${d.rejected} rejected',
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Container(height: 92 * d.rejected / peak, color: t.destDot),
                              Container(height: 92 * d.accepted / peak, color: t.successDot),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: Space.x8),
        Wrap(
          spacing: Space.x16,
          children: [
            _Legend(color: t.successDot, label: 'Accepted'),
            _Legend(color: t.destDot, label: 'Rejected'),
            if (days.isNotEmpty && days.first.day != null && days.last.day != null)
              Text(dateRange(days.first.day!, days.last.day!), style: theme.textTheme.labelSmall?.copyWith(color: t.textSecondary)),
          ],
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: Space.x6),
      Text(label, style: Theme.of(context).textTheme.labelSmall),
    ],
  );
}

/// Creates a batch under [project]: the margin preview follows the numbers and warns under the floor.
class BatchFormDialog extends StatefulWidget {
  const BatchFormDialog({super.key, required this.project});
  final ProjectDetail project;

  @override
  State<BatchFormDialog> createState() => _BatchFormDialogState();
}

class _BatchFormDialogState extends State<BatchFormDialog> {
  final _title = TextEditingController();
  final _pay = TextEditingController();
  final _price = TextEditingController();
  final _review = TextEditingController(text: '0');
  final _ttl = TextEditingController(text: '240');
  String _mode = 'open';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_title, _pay, _price, _review, _ttl]) {
      c.dispose();
    }
    super.dispose();
  }

  double? get _margin => marginOf(_price.text.trim(), _pay.text.trim(), _review.text.trim());
  bool get _underFloor {
    final floor = widget.project.marginFloor;
    final m = _margin;
    return floor != null && m != null && m < floor;
  }

  String? _money(String text, String label) {
    final v = double.tryParse(text.trim());
    if (v == null || v < 0) {
      _error = '$label must be a number, 0 or more';
      return null;
    }
    return v.toStringAsFixed(2);
  }

  BatchInput? _input() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      _error = 'Title is required';
      return null;
    }
    final pay = _money(_pay.text, 'Unit pay');
    if (pay == null) return null;
    final price = _money(_price.text, 'Unit price');
    if (price == null) return null;
    final review = _money(_review.text.isEmpty ? '0' : _review.text, 'Review pay');
    if (review == null) return null;
    final ttl = int.tryParse(_ttl.text.trim());
    if (ttl == null || ttl < 1 || ttl > 10080) {
      _error = 'Claim TTL is minutes, from 1 to 10080';
      return null;
    }
    return BatchInput(title: title, mode: _mode, unitPay: pay, unitPrice: price, reviewPay: review, claimTtlMinutes: ttl);
  }

  Future<void> _save() async {
    final scope = AppScope.of(context);
    _error = null;
    final input = _input();
    if (input == null) {
      setState(() {});
      return;
    }
    final action = 'batch:create:${widget.project.id}';
    setState(() => _busy = true);
    try {
      final created = await scope.ops.createBatch(widget.project.id, input, key: scope.keys.start(action));
      scope.keys.finish(action);
      if (mounted) Navigator.of(context).pop(created);
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final floor = widget.project.marginFloor;
    final margin = _margin;
    return FormSheet(
      title: 'New batch',
      saveLabel: 'Create draft',
      saveKey: const Key('batch-save'),
      busy: _busy,
      error: ErrorBanner(_error),
      onSave: _save,
      children: [
        TextField(
          key: const Key('batch-title'),
          controller: _title,
          decoration: const InputDecoration(labelText: 'Title'),
        ),
        fieldGap,
        FieldPair(
          DropdownButtonFormField<String>(
            key: const Key('batch-mode'),
            isExpanded: true,
            initialValue: _mode,
            decoration: const InputDecoration(labelText: 'Mode'),
            items: const [
              DropdownMenuItem(value: 'open', child: Text('Open: anyone eligible claims')),
              DropdownMenuItem(value: 'assigned', child: Text('Assigned: each unit names its worker')),
            ],
            onChanged: (v) => setState(() => _mode = v ?? 'open'),
          ),
          TextField(
            key: const Key('batch-ttl'),
            controller: _ttl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Claim TTL (minutes)'),
          ),
        ),
        fieldGap,
        FieldPair(
          TextField(
            key: const Key('batch-unit-pay'),
            controller: _pay,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: 'Unit pay (${widget.project.currency})', helperText: 'What the worker earns'),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            key: const Key('batch-unit-price'),
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: 'Unit price (${widget.project.currency})', helperText: 'What the client is billed'),
            onChanged: (_) => setState(() {}),
          ),
        ),
        fieldGap,
        TextField(
          key: const Key('batch-review-pay'),
          controller: _review,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'Review pay (${widget.project.currency})', helperText: 'Per review of one unit'),
          onChanged: (_) => setState(() {}),
        ),
        fieldGap,
        Container(
          padding: const EdgeInsets.all(Space.x12),
          decoration: BoxDecoration(color: t.bgMuted, borderRadius: Radii.rMd),
          child: Row(
            children: [
              Expanded(child: Text('Margin preview', style: theme.textTheme.labelMedium)),
              Text(
                'Margin ${percent(margin)}${floor == null ? '' : ' · floor ${percent(floor)}'}',
                key: const Key('batch-margin'),
                style: AppTheme.figure(context, fontSize: 14, color: _underFloor ? t.destText : t.textPrimary),
              ),
            ],
          ),
        ),
        if (_underFloor) ...[
          fieldGap,
          StatusBanner(
            key: const Key('batch-floor-warning'),
            'Under the project\'s ${percent(floor)} floor. Publishing will ask who approved it and why.',
            kind: StatusKind.warn,
            icon: Icons.warning_amber_rounded,
          ),
        ],
      ],
    );
  }
}
