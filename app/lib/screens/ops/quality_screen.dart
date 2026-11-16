import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../api/models.dart';
import '../../api/ops_models.dart' show Anomaly;
import '../../app_router.dart';
import '../../api/quality_ops_models.dart';
import '../../app_scope.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/action_dialog.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/people.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';

/// Quality for the operator: flags to answer, disputes to decide, the review queue and its numbers.
class QualityScreen extends StatefulWidget {
  const QualityScreen({super.key});

  @override
  State<QualityScreen> createState() => _QualityScreenState();
}

enum _Tab {
  flags('Flags'),
  disputes('Disputes'),
  queue('Queue'),
  integrity('Integrity');

  const _Tab(this.label);
  final String label;
}

class _QualityScreenState extends State<QualityScreen> {
  _Tab _tab = _Tab.flags;

  /// The batch the queue is narrowed to: from `?batch=` (the batch page's "Review queue") or typed.
  String _batch = '';
  String? _linked;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final asked = GoRouterState.of(context).uri.queryParameters['batch'];
    if (asked != null && asked.isNotEmpty && asked != _linked) {
      _linked = asked;
      _batch = asked;
      _tab = _Tab.queue;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PortalPage(
      kicker: 'Operate · Quality',
      title: 'Quality',
      subtitle: 'Flags to answer, disputes to decide, the review queue, integrity',
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Space.x16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<_Tab>(
              key: const Key('quality-tab'),
              showSelectedIcon: false,
              segments: [for (final t in _Tab.values) ButtonSegment(value: t, label: Text(t.label))],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
          ),
        ),
        switch (_tab) {
          _Tab.flags => const _FlagsTab(),
          _Tab.disputes => const _DisputesTab(),
          _Tab.queue => _QueueTab(batch: _batch, onBatch: (b) => setState(() => _batch = b)),
          _Tab.integrity => const _IntegrityTab(),
        },
      ],
    );
  }
}

String _short(String id) => id.length > 8 ? id.substring(0, 8) : id;

/// A chip in a table cell: scaled down rather than clipped when the column is narrower than its label.
Widget _fit(Widget chip) => FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: chip);

/// An id in mono, shortened on screen, whole for assistive tech and on hover.
class _Id extends StatelessWidget {
  const _Id(this.label, this.id);
  final String label;
  final String id;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    return Semantics(
      label: '$label ${id.isEmpty ? 'unknown' : id}',
      container: true,
      excludeSemantics: true,
      child: Tooltip(
        message: id.isEmpty ? '—' : id,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$label ', style: theme.textTheme.labelSmall),
            Text(id.isEmpty ? '—' : _short(id), style: AppTheme.mono(context, fontSize: 12, color: t.textSecondary)),
          ],
        ),
      ),
    );
  }
}

// ── Flags ──────────────────────────────────────────────────────────────────

class _FlagsTab extends StatelessWidget {
  const _FlagsTab();

  @override
  Widget build(BuildContext context) {
    return LoadView<List<QualityFlag>>(
      firstWait: LoadWait.brand,
      wrapInCard: true,
      load: () => AppScope.of(context).qualityOps.flags(),
      isEmpty: (f) => f.isEmpty,
      emptyMessage: 'Nothing to answer. A reviewer who finds the rubric unclear raises a flag here.',
      builder: (context, flags, reload) {
        final overdue = flags.where((f) => f.overdue).length;
        final ordered = [...flags.where((f) => f.overdue), ...flags.where((f) => !f.overdue)];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionTitle(
              'Flags',
              subtitle: '${flags.length} waiting for an answer${overdue == 0 ? '' : ' · $overdue past the two-day answer'}',
            ),
            for (final f in ordered) _FlagCard(flag: f, onAnswered: reload),
          ],
        );
      },
    );
  }
}

class _FlagCard extends StatelessWidget {
  const _FlagCard({required this.flag, required this.onAnswered});
  final QualityFlag flag;
  final Future<void> Function() onAnswered;

  Future<void> _answer(BuildContext context) async {
    final scope = AppScope.of(context);
    final sent = await showActionDialog<QualityFlag>(
      context,
      title: 'Answer the flag',
      body: 'The reviewer reads this with the rubric. Say what the rule means here.',
      fieldLabel: 'Answer',
      confirmLabel: 'Send answer',
      fieldKey: const Key('flag-answer-text'),
      sendKey: const Key('flag-answer-send'),
      onSend: (text) => withActionKey(scope.keys, 'flag:${flag.id}', (key) => scope.qualityOps.answerFlag(flag.id, text, key: key)),
    );
    if (sent == null || !context.mounted) return;
    toast(context, 'Answer sent');
    await onAnswered();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final created = flag.createdAt;
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(flag.note, style: theme.textTheme.bodyMedium)),
              if (flag.overdue) StatusChip('Overdue', key: Key('flag-overdue-${flag.id}'), kind: StatusKind.dest),
            ],
          ),
          const SizedBox(height: Space.x8),
          Wrap(
            spacing: Space.x16,
            runSpacing: Space.x6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Id('Batch', flag.batchId),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Reviewer ', style: theme.textTheme.labelSmall),
                  NameOf(flag.reviewerId, style: theme.textTheme.labelSmall),
                ],
              ),
              _Id('Task', flag.taskId),
              if (created != null) Text('Raised ${relative(created)}', style: theme.textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: Space.x12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(key: Key('flag-answer-${flag.id}'), onPressed: () => _answer(context), child: const Text('Answer')),
          ),
        ],
      ),
    );
  }
}

// ── Disputes ───────────────────────────────────────────────────────────────

class _DisputesTab extends StatelessWidget {
  const _DisputesTab();

  @override
  Widget build(BuildContext context) {
    return LoadView<List<DisputeQueueItem>>(
      firstWait: LoadWait.brand,
      wrapInCard: true,
      load: () => AppScope.of(context).qualityOps.disputes(),
      isEmpty: (d) => d.isEmpty,
      emptyMessage: 'Nothing to decide. A worker who contests a verdict raises a dispute here.',
      builder: (context, disputes, reload) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionTitle('Disputes', subtitle: '${disputes.length} open · the decision is final and never changes pay'),
          for (final d in disputes) _DisputeCard(dispute: d, onResolved: reload),
        ],
      ),
    );
  }
}

(String, StatusKind) _verdict(String verdict) => switch (verdict) {
  'accept' => ('Accepted', StatusKind.success),
  'needs_edits' => ('Needs edits', StatusKind.warn),
  'reject' => ('Rejected', StatusKind.dest),
  '' => ('No verdict', StatusKind.info),
  _ => (humanize(verdict), StatusKind.info),
};

class _DisputeCard extends StatelessWidget {
  const _DisputeCard({required this.dispute, required this.onResolved});
  final DisputeQueueItem dispute;
  final Future<void> Function() onResolved;

  Future<void> _resolve(BuildContext context, {required String outcome}) async {
    final scope = AppScope.of(context);
    final overturn = outcome == 'upheld';
    final sent = await showActionDialog<DisputeQueueItem>(
      context,
      title: overturn ? 'Overturn the verdict' : 'Uphold the verdict',
      body: overturn
          ? 'The dispute is upheld: the worker was not at fault and the verdict leaves their record. Pay does not change.'
          : 'The dispute is dismissed: the verdict stands. Tell the worker why.',
      fieldLabel: 'Note to the worker',
      confirmLabel: overturn ? 'Overturn' : 'Uphold',
      fieldKey: const Key('dispute-note'),
      sendKey: const Key('dispute-resolve-send'),
      messageFor: (e) => e.code == 'dispute_resolved' ? 'Already decided by someone else' : describeError(e),
      onSend: (text) => withActionKey(
        scope.keys,
        'dispute:${dispute.id}:$outcome',
        (key) => scope.qualityOps.resolveDispute(dispute.id, outcome: outcome, answer: text, key: key),
      ),
    );
    if (sent == null || !context.mounted) return;
    toast(context, overturn ? 'Verdict overturned' : 'Verdict upheld');
    await onResolved();
  }

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final (label, kind) = _verdict(dispute.verdict);
    final reason = ReasonCode.byCode(dispute.reasonCode);
    final created = dispute.createdAt;
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Space.x8,
            runSpacing: Space.x6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusChip(label, kind: kind),
              if (dispute.reasonCode.isNotEmpty) Text(reason?.label ?? humanize(dispute.reasonCode), style: theme.textTheme.bodyMedium),
              if (reason?.clientCaused ?? false) const StatusChip('Billable rework', kind: StatusKind.info),
            ],
          ),
          const SizedBox(height: Space.x8),
          Text("The worker's reason", style: theme.textTheme.labelMedium),
          const SizedBox(height: Space.x4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: Space.x12, vertical: Space.x8),
            decoration: BoxDecoration(
              color: t.bgMuted,
              borderRadius: Radii.rSm,
              border: Border(left: BorderSide(color: t.border, width: 3)),
            ),
            child: Text(dispute.reason, style: theme.textTheme.bodyMedium),
          ),
          const SizedBox(height: Space.x8),
          Wrap(
            spacing: Space.x16,
            runSpacing: Space.x6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Id('Worker', dispute.workerId),
              _Id('Unit', dispute.unitId),
              _Id('Batch', dispute.batchId),
              if (created != null) Text('Raised ${relative(created)}', style: theme.textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: Space.x12),
          Wrap(
            spacing: Space.x8,
            runSpacing: Space.x8,
            children: [
              FilledButton(
                key: Key('dispute-overturn-${dispute.id}'),
                onPressed: () => _resolve(context, outcome: 'upheld'),
                child: const Text('Overturn verdict'),
              ),
              OutlinedButton(
                key: Key('dispute-uphold-${dispute.id}'),
                onPressed: () => _resolve(context, outcome: 'dismissed'),
                child: const Text('Uphold verdict'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Queue ──────────────────────────────────────────────────────────────────

class _QueueTab extends StatefulWidget {
  const _QueueTab({required this.batch, required this.onBatch});
  final String batch;
  final ValueChanged<String> onBatch;

  @override
  State<_QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<_QueueTab> {
  late final _field = TextEditingController(text: widget.batch);
  Timer? _typing;

  @override
  void didUpdateWidget(_QueueTab old) {
    super.didUpdateWidget(old);
    if (widget.batch != _field.text) _field.text = widget.batch;
  }

  @override
  void dispose() {
    _typing?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 300), () => widget.onBatch(v.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final batch = widget.batch;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Space.x12),
          child: TextField(
            key: const Key('queue-batch'),
            controller: _field,
            onChanged: _changed,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.filter_alt_outlined),
              labelText: 'Batch',
              hintText: 'A batch id: the queue, its numbers and its reasons for that batch only',
              suffixIcon: batch.isEmpty
                  ? null
                  : IconButton(
                      key: const Key('queue-batch-clear'),
                      tooltip: 'All batches',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _field.clear();
                        widget.onBatch('');
                      },
                    ),
            ),
          ),
        ),
        LoadView<QualityStats>(
          key: ValueKey('stats/$batch'),
          firstWait: LoadWait.brand,
          wrapInCard: true,
          load: () => AppScope.of(context).qualityOps.stats(batchId: batch.isEmpty ? null : batch),
          isEmpty: (s) => s.isEmpty,
          emptyMessage: 'The queue is empty. Numbers appear once a submission reaches review.',
          builder: (context, s, _) => _Stats(s),
        ),
        _TasksTable(batch: batch),
      ],
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats(this.s);
  final QualityStats s;

  @override
  Widget build(BuildContext context) {
    final oldest = s.oldestPendingAt;
    final decided = s.accepted + s.rejected + s.needsEdits;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KpiRow(
          children: [
            KpiTile(
              label: 'Pending',
              value: '${s.pending}',
              note: 'Waiting for a reviewer',
              kind: s.pending > 0 ? StatusKind.info : null,
              icon: Icons.schedule,
            ),
            KpiTile(label: 'Claimed', value: '${s.claimed}', note: 'Being reviewed now', icon: Icons.rate_review_outlined),
            KpiTile(
              label: 'In audit',
              value: '${s.inAudit}',
              note: '${s.auditDisagreements} audit disagreements',
              icon: Icons.policy_outlined,
            ),
            KpiTile(
              label: 'Accepted',
              value: '${s.accepted}',
              note: 'of $decided decided',
              kind: StatusKind.success,
              icon: Icons.check_circle_outline,
            ),
            KpiTile(
              label: 'Rejected',
              value: '${s.rejected}',
              note: 'Worker at fault',
              kind: s.rejected > 0 ? StatusKind.dest : null,
              icon: Icons.block_outlined,
            ),
            KpiTile(
              label: 'Needs edits',
              value: '${s.needsEdits}',
              note: 'Back in the pool',
              kind: s.needsEdits > 0 ? StatusKind.warn : null,
              icon: Icons.edit_outlined,
            ),
            KpiTile(
              label: 'Acceptance rate',
              value: decided == 0 ? '—' : '${s.acceptancePercent}%',
              note: 'First-pass, across the queue',
              kind: decided == 0 ? null : (s.acceptancePercent >= 80 ? StatusKind.success : StatusKind.warn),
              icon: Icons.insights_outlined,
            ),
            KpiTile(
              label: 'Oldest waiting',
              value: oldest == null ? '—' : _waiting(oldest),
              note: oldest == null ? 'Nothing pending' : 'Since ${dateTime(oldest)}',
              kind: oldest == null
                  ? null
                  : (DateTime.now().difference(oldest) > const Duration(hours: 24) ? StatusKind.warn : StatusKind.info),
              icon: Icons.hourglass_bottom_outlined,
            ),
          ],
        ),
        if (s.reasons.isNotEmpty) ...[
          const SectionTitle('Reasons', subtitle: 'Why units came back; billable reasons are the client\'s cost'),
          PortalTable(
            minWidth: 420,
            columns: const [PortalColumn('Reason', flex: 3), PortalColumn('Count', numeric: true), PortalColumn('Billable', width: 150)],
            rows: [
              for (final r in s.reasons)
                PortalRow(key: Key('reason-${r.reasonCode}'), [
                  Text(ReasonCode.byCode(r.reasonCode)?.label ?? humanize(r.reasonCode)),
                  Text('${r.count}'),
                  _fit(
                    r.billable ? const StatusChip('Billable', kind: StatusKind.info) : const StatusChip('Worker', kind: StatusKind.warn),
                  ),
                ]),
            ],
          ),
          const SizedBox(height: Space.x16),
        ],
      ],
    );
  }

  static String _waiting(DateTime since) {
    final d = DateTime.now().difference(since);
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    if (d.inHours < 48) return '${d.inHours} h';
    return '${d.inDays} days';
  }
}

(String, StatusKind) _taskStatus(String status) => switch (status) {
  'pending' => ('Pending', StatusKind.info),
  'claimed' => ('Claimed', StatusKind.info),
  'audit_pending' => ('Audit pending', StatusKind.warn),
  'audit_claimed' => ('In audit', StatusKind.warn),
  'canonical' => ('Decided', StatusKind.success),
  _ => (humanize(status), StatusKind.info),
};

class _TasksTable extends StatefulWidget {
  const _TasksTable({this.batch = ''});
  final String batch;

  @override
  State<_TasksTable> createState() => _TasksTableState();
}

class _TasksTableState extends State<_TasksTable> {
  static const limit = 50;
  static const filters = <String, String?>{
    'All': null,
    'Pending': 'pending',
    'Claimed': 'claimed',
    'Audit pending': 'audit_pending',
    'In audit': 'audit_claimed',
    'Decided': 'canonical',
  };
  String? _status;
  int _offset = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Tasks', subtitle: 'Every review task, oldest first'),
        Padding(
          padding: const EdgeInsets.only(bottom: Space.x12),
          child: FilterChips<String>(
            values: filters,
            selected: _status,
            onSelected: (v) => setState(() {
              _status = v;
              _offset = 0;
            }),
          ),
        ),
        LoadView<QualityTaskPage>(
          wrapInCard: true,
          key: ValueKey('tasks/${widget.batch}/$_status/$_offset'),
          load: () => AppScope.of(
            context,
          ).qualityOps.tasks(status: _status, batchId: widget.batch.isEmpty ? null : widget.batch, limit: limit, offset: _offset),
          isEmpty: (p) => p.items.isEmpty && _offset == 0,
          emptyMessage: _status == null
              ? 'No review tasks yet.'
              : 'No tasks are ${filters.keys.firstWhere((k) => filters[k] == _status).toLowerCase()} right now.',
          builder: (context, page, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PortalTable(
                minWidth: 760,
                columns: const [
                  PortalColumn('Task', flex: 2),
                  PortalColumn('Unit', flex: 2),
                  PortalColumn('Batch', flex: 2),
                  PortalColumn('Worker', flex: 2),
                  PortalColumn('Status', width: 150),
                  PortalColumn('Verdict', width: 140),
                  PortalColumn('Age', width: 110, numeric: true),
                ],
                rows: [
                  for (final r in page.items)
                    PortalRow(key: Key('task-${r.id}'), [
                      _Mono(r.id),
                      _Mono(r.unitId),
                      _Mono(r.batchId),
                      NameOf(r.workerId),
                      _fit(StatusChip(_taskStatus(r.status).$1, kind: _taskStatus(r.status).$2)),
                      r.canonicalVerdict.isEmpty
                          ? const Text('—')
                          : _fit(StatusChip(_verdict(r.canonicalVerdict).$1, kind: _verdict(r.canonicalVerdict).$2)),
                      Text(r.createdAt == null ? '—' : relative(r.createdAt!)),
                    ]),
                ],
              ),
              Pager(offset: _offset, limit: limit, total: page.total, onPage: (o) => setState(() => _offset = o)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Mono extends StatelessWidget {
  const _Mono(this.id);
  final String id;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: id.isEmpty ? '—' : id,
    child: Text(id.isEmpty ? '—' : _short(id), style: AppTheme.mono(context, fontSize: 12)),
  );
}

// ── Integrity ──────────────────────────────────────────────────────────────

/// What the tracker found odd. Dismiss when it is explained; uphold to put the worker's payouts on an
/// integrity hold until someone lifts it.
class _IntegrityTab extends StatefulWidget {
  const _IntegrityTab();

  @override
  State<_IntegrityTab> createState() => _IntegrityTabState();
}

class _IntegrityTabState extends State<_IntegrityTab> {
  static const filters = <String, String?>{'Open': 'open', 'Upheld': 'upheld', 'Dismissed': 'dismissed', 'All': null};
  String? _status = 'open';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Integrity', subtitle: 'What the activity tracker found; upholding one holds the worker\'s payouts'),
        Padding(
          padding: const EdgeInsets.only(bottom: Space.x12),
          child: FilterChips<String>(values: filters, selected: _status, onSelected: (v) => setState(() => _status = v)),
        ),
        LoadView<List<Anomaly>>(
          key: ValueKey('anomalies/$_status'),
          firstWait: LoadWait.brand,
          wrapInCard: true,
          load: () => AppScope.of(context).ops.anomalies(status: _status),
          isEmpty: (a) => a.isEmpty,
          emptyMessage: _status == 'open' ? 'Nothing to look at. The tracker checks every five minutes.' : 'None.',
          builder: (context, items, reload) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final a in items) _AnomalyCard(anomaly: a, onDecided: reload)],
          ),
        ),
      ],
    );
  }
}

/// `Over 20 h active in a day (21.5 h)`, from the anomaly's kind and detail.
String anomalySummary(Anomaly a) {
  final d = a.detail;
  double? hours(String key) => d[key] is num ? (d[key] as num) / 3600 : null;
  return switch (a.kind) {
    'impossible_activity' =>
      'More than 20 h active in 24 h${hours('active_seconds') == null ? '' : ' (${hours('active_seconds')!.toStringAsFixed(1)} h)'}',
    'over_cap' => 'Past the weekly hour cap${d['cap_hours'] == null ? '' : ' of ${d['cap_hours']} h'}',
    'no_live_claim' => 'Active after the claim ended${d['minutes_after'] == null ? '' : ' (${d['minutes_after']} min later)'}',
    'duplicate_device' => 'Same device as ${(d['worker_ids'] is List ? (d['worker_ids'] as List).length - 1 : 1)} other worker(s)',
    _ => humanize(a.kind),
  };
}

class _AnomalyCard extends StatelessWidget {
  const _AnomalyCard({required this.anomaly, required this.onDecided});
  final Anomaly anomaly;
  final Future<void> Function() onDecided;

  Future<void> _decide(BuildContext context, String outcome) async {
    final scope = AppScope.of(context);
    final uphold = outcome == 'uphold';
    final done = await showActionDialog<Anomaly>(
      context,
      title: uphold ? 'Uphold and hold payouts?' : 'Dismiss this?',
      body: uphold
          ? 'The worker\'s payouts go on an integrity hold for 30 days. They are told; nothing they earned is lost.'
          : 'Say why it is explained; the note stays with the record.',
      fieldLabel: 'Note',
      confirmLabel: uphold ? 'Uphold' : 'Dismiss',
      fieldKey: const Key('anomaly-note'),
      sendKey: const Key('anomaly-send'),
      onSend: (note) => withActionKey(
        scope.keys,
        'anomaly:$outcome:${anomaly.id}',
        (key) => scope.ops.decideAnomaly(anomaly.id, outcome, note: note, key: key),
      ),
    );
    if (done == null || !context.mounted) return;
    toast(context, uphold ? 'Upheld; payouts held' : 'Dismissed');
    await onDecided();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = anomaly;
    final kind = switch (a.status) {
      'upheld' => StatusKind.dest,
      'dismissed' => StatusKind.info,
      _ => StatusKind.warn,
    };
    return PortalCard(
      key: Key('anomaly-${a.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(anomalySummary(a), style: theme.textTheme.titleSmall)),
              StatusChip(humanize(a.status), kind: kind),
            ],
          ),
          const SizedBox(height: Space.x8),
          Wrap(
            spacing: Space.x16,
            runSpacing: Space.x6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                key: Key('anomaly-worker-${a.id}'),
                onPressed: () => context.go(Paths.worker(a.workerId)),
                child: NameOf(a.workerId),
              ),
              if (a.createdAt != null) Text('Found ${relative(a.createdAt!)}', style: theme.textTheme.labelSmall),
              if (a.note.isNotEmpty) Text('Note: ${a.note}', style: theme.textTheme.labelSmall),
            ],
          ),
          if (a.isOpen) ...[
            const SizedBox(height: Space.x8),
            Wrap(
              spacing: Space.x8,
              children: [
                OutlinedButton(
                  key: Key('anomaly-dismiss-${a.id}'),
                  onPressed: () => _decide(context, 'dismiss'),
                  child: const Text('Dismiss'),
                ),
                FilledButton(key: Key('anomaly-uphold-${a.id}'), onPressed: () => _decide(context, 'uphold'), child: const Text('Uphold')),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
