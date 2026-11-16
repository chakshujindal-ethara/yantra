import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app_scope.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/cards.dart';
import '../core/widgets/portal_page.dart';
import '../widgets/load_view.dart';
import 'shell.dart';
import '../core/widgets/loader.dart';

/// Every unit the worker submitted, newest first, with the verdict and the reason, and one dispute per unit.
class MyWorkScreen extends StatefulWidget {
  const MyWorkScreen({super.key});

  @override
  State<MyWorkScreen> createState() => _MyWorkScreenState();
}

enum _Filter {
  all('All'),
  inReview('In review'),
  accepted('Accepted'),
  needsEdits('Needs edits'),
  rejected('Rejected');

  const _Filter(this.label);
  final String label;

  bool matches(MyWorkItem item) => this == all || item.statusLabel == label;
}

/// The counts the tiles show. An upheld dispute clears the record, so it never counts as a rejection.
class _Counts {
  _Counts(List<MyWorkItem> items)
    : accepted = items.where((i) => i.statusLabel == 'Accepted').length,
      inReview = items.where((i) => i.statusLabel == 'In review').length,
      needsEdits = items.where((i) => i.statusLabel == 'Needs edits').length,
      rejected = items.where((i) => i.statusLabel == 'Rejected' && i.dispute?.status != 'upheld').length;

  final int accepted;
  final int inReview;
  final int needsEdits;
  final int rejected;

  int get decided => accepted + needsEdits + rejected;
  int? get acceptanceRate => decided == 0 ? null : (accepted * 100 / decided).round();
}

class _MyWorkScreenState extends State<MyWorkScreen> {
  final _loadKey = GlobalKey<LoadViewState<List<MyWorkItem>>>();
  _Filter _filter = _Filter.all;

  Future<List<MyWorkItem>> _load() async {
    final items = await AppScope.of(context).review.myWork();
    items.sort((a, b) {
      final x = a.createdAt, y = b.createdAt;
      if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
      return y.compareTo(x);
    });
    return items;
  }

  Future<void> _dispute(MyWorkItem item) async {
    final sent = await showDialog<bool>(
      context: context,
      builder: (_) => _DisputeDialog(taskId: item.taskId),
    );
    if (sent != true || !mounted) return;
    await _loadKey.currentState?.reload();
    if (mounted) toast(context, 'Dispute sent');
  }

  @override
  Widget build(BuildContext context) {
    return LoadView<List<MyWorkItem>>(
      key: _loadKey,
      load: _load,
      builder: (context, items, reload) {
        final shown = items.where(_filter.matches).toList();
        return PortalPage(
          kicker: 'Work',
          title: 'My work',
          subtitle: 'Every unit you submitted and how it was judged',
          onRefresh: reload,
          children: [
            if (items.isEmpty)
              const _EmptyWork()
            else ...[
              _Kpis(counts: _Counts(items)),
              _FilterBar(value: _filter, onChanged: (f) => setState(() => _filter = f)),
              if (shown.isEmpty)
                PortalCard(child: EmptyView(message: 'No units are ${_filter.label.toLowerCase()} right now.'))
              else
                for (final item in shown) _WorkCard(item: item, onDispute: () => _dispute(item)),
            ],
          ],
        );
      },
    );
  }
}

class _EmptyWork extends StatelessWidget {
  const _EmptyWork();

  @override
  Widget build(BuildContext context) {
    return PortalCard(
      child: Column(
        children: [
          const EmptyView(message: 'Nothing submitted yet. Claim a unit from Home.'),
          FilledButton(
            key: const Key('mywork-empty-home'),
            onPressed: () => ShellActions.of(context).go(Destination.home),
            child: const Text('Go to Home'),
          ),
          const SizedBox(height: Space.x8),
        ],
      ),
    );
  }
}

class _Kpis extends StatelessWidget {
  const _Kpis({required this.counts});
  final _Counts counts;

  @override
  Widget build(BuildContext context) {
    final rate = counts.acceptanceRate;
    return KpiRow(
      children: [
        KpiTile(
          label: 'Accepted',
          value: '${counts.accepted}',
          note: rate == null ? 'No verdict yet' : '$rate% of decided units; an upheld dispute does not count against you',
          kind: StatusKind.success,
          icon: Icons.check_circle_outline,
        ),
        KpiTile(
          label: 'In review',
          value: '${counts.inReview}',
          note: 'Waiting for a reviewer',
          kind: StatusKind.info,
          icon: Icons.schedule,
        ),
        KpiTile(
          label: 'Needs edits',
          value: '${counts.needsEdits}',
          note: 'Back in the pool to redo',
          kind: StatusKind.warn,
          icon: Icons.edit_outlined,
        ),
        KpiTile(
          label: 'Rejected',
          value: '${counts.rejected}',
          note: 'Excludes upheld disputes',
          kind: StatusKind.dest,
          icon: Icons.block_outlined,
        ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.value, required this.onChanged});
  final _Filter value;
  final ValueChanged<_Filter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<_Filter>(
          key: const Key('mywork-filter'),
          showSelectedIcon: false,
          segments: [for (final f in _Filter.values) ButtonSegment(value: f, label: Text(f.label))],
          selected: {value},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      ),
    );
  }
}

StatusKind _verdictKind(String label) => switch (label) {
  'Accepted' => StatusKind.success,
  'Needs edits' => StatusKind.warn,
  'Rejected' => StatusKind.dest,
  _ => StatusKind.info,
};

String _short(String id) => id.length > 8 ? id.substring(0, 8) : id;

class _WorkCard extends StatelessWidget {
  const _WorkCard({required this.item, required this.onDispute});
  final MyWorkItem item;
  final VoidCallback onDispute;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final created = item.createdAt;
    final decided = item.decidedAt;
    final reason = item.reasonCode.isEmpty ? null : (ReasonCode.byCode(item.reasonCode)?.label ?? humanize(item.reasonCode));
    final dispute = item.dispute;
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Space.x12,
            runSpacing: Space.x8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                label: 'Unit ${item.unitId}',
                container: true,
                excludeSemantics: true,
                child: Tooltip(
                  message: item.unitId,
                  child: Text(_short(item.unitId), style: AppTheme.mono(context, fontSize: 14)),
                ),
              ),
              if (created != null) Text('Submitted ${relative(created)}', style: theme.textTheme.bodySmall),
              _RubricChip(item.rubricVersion),
              StatusChip(item.statusLabel, kind: _verdictKind(item.statusLabel)),
            ],
          ),
          if (item.isDecided) ...[
            const SizedBox(height: Space.x12),
            Wrap(
              spacing: Space.x8,
              runSpacing: Space.x6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (reason != null) Text(reason, style: theme.textTheme.bodyMedium),
                // scaled down rather than clipped when a narrow phone cannot fit the whole label
                if (item.billable)
                  const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: StatusChip('Client-caused · billable rework', kind: StatusKind.info),
                  ),
              ],
            ),
            if (item.reviewerNote.isNotEmpty) ...[const SizedBox(height: Space.x8), _Quote(item.reviewerNote)],
            if (decided != null) ...[
              const SizedBox(height: Space.x8),
              Text('Decided ${relative(decided)}', style: theme.textTheme.labelSmall),
            ],
          ],
          if (item.statusLabel == 'Needs edits') ...[
            const SizedBox(height: Space.x8),
            Row(
              children: [
                Expanded(child: Text('This unit is back in your pools: claim it again from Home', style: theme.textTheme.bodySmall)),
                TextButton(
                  key: Key('go-home-${_short(item.unitId)}'),
                  onPressed: () => ShellActions.of(context).go(Destination.home),
                  child: const Text('Go to Home'),
                ),
              ],
            ),
          ],
          if (dispute != null) ...[
            const SizedBox(height: Space.x12),
            _DisputePanel(dispute),
          ] else if (item.canDispute()) ...[
            const SizedBox(height: Space.x12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(key: Key('dispute-${item.taskId}'), onPressed: onDispute, child: const Text('Dispute this verdict')),
            ),
          ],
          if (dispute == null && item.isDecided && !item.isAccepted && !item.canDispute()) ...[
            const SizedBox(height: Space.x8),
            Text('The 14-day dispute window has closed', style: theme.textTheme.labelSmall?.copyWith(color: t.textMuted)),
          ],
        ],
      ),
    );
  }
}

class _RubricChip extends StatelessWidget {
  const _RubricChip(this.version);
  final String version;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.x8, vertical: Space.x2),
      decoration: BoxDecoration(color: t.bgMuted, borderRadius: Radii.rFull),
      child: Text('Rubric ${version.isEmpty ? '—' : version}', style: AppTheme.mono(context, fontSize: 12, color: t.textSecondary)),
    );
  }
}

/// A reviewer's words, set apart quietly: a muted panel with a hairline at the left.
class _Quote extends StatelessWidget {
  const _Quote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Space.x12, vertical: Space.x8),
      decoration: BoxDecoration(
        color: t.bgMuted,
        borderRadius: Radii.rSm,
        border: Border(left: BorderSide(color: t.border, width: 3)),
      ),
      child: Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.textSecondary)),
    );
  }
}

class _DisputePanel extends StatelessWidget {
  const _DisputePanel(this.dispute);
  final Dispute dispute;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final (label, kind) = switch (dispute.status) {
      'upheld' => ('Upheld', StatusKind.success),
      'dismissed' => ('Dismissed', StatusKind.warn),
      _ => ('Open', StatusKind.info),
    };
    final raised = dispute.createdAt;
    final resolved = dispute.resolvedAt;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.x12),
      decoration: BoxDecoration(
        color: t.bgSubtle,
        borderRadius: Radii.rMd,
        border: Border.all(color: t.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Dispute', style: theme.textTheme.titleSmall)),
              StatusChip(label, kind: kind),
            ],
          ),
          const SizedBox(height: Space.x8),
          Text('Your reason', style: theme.textTheme.labelMedium),
          Text(dispute.reason, style: theme.textTheme.bodyMedium),
          if (!dispute.isOpen && dispute.answer.isNotEmpty) ...[
            const SizedBox(height: Space.x8),
            Text('Answer', style: theme.textTheme.labelMedium),
            Text(dispute.answer, style: theme.textTheme.bodyMedium),
          ],
          const SizedBox(height: Space.x8),
          Text(
            [if (raised != null) 'Raised ${relative(raised)}', if (resolved != null) 'Decided ${relative(resolved)}'].join('  ·  '),
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

/// One dispute per unit. Posts with one idempotency key per task; a 409 ends the action with a plain reason.
class _DisputeDialog extends StatefulWidget {
  const _DisputeDialog({required this.taskId});
  final String taskId;

  @override
  State<_DisputeDialog> createState() => _DisputeDialogState();
}

class _DisputeDialogState extends State<_DisputeDialog> {
  static const minLength = 10;
  final _reason = TextEditingController();
  String? _validation;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final reason = _reason.text.trim();
    if (reason.length < minLength) {
      setState(() => _validation = 'Give at least $minLength characters so a person can act on it');
      return;
    }
    final scope = AppScope.of(context);
    final action = 'dispute:${widget.taskId}';
    setState(() {
      _validation = null;
      _error = null;
      _busy = true;
    });
    try {
      await scope.review.dispute(widget.taskId, reason, key: scope.keys.start(action));
      scope.keys.finish(action);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = _message(e));
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _message(ApiException e) => switch (e.code) {
    'dispute_exists' => 'Already disputed',
    'dispute_window_closed' => 'The 14-day window has closed',
    'not_disputable' => 'This verdict cannot be disputed',
    _ => describeError(e),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Dispute this verdict'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ErrorBanner(_error),
            Text(
              'One dispute per unit, within 14 days of the verdict. A person reads it; the decision is final. '
              'An upheld dispute never changes pay, it clears your record.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: Space.x12),
            TextField(
              key: const Key('dispute-reason'),
              controller: _reason,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              enabled: !_busy,
              decoration: InputDecoration(labelText: 'Why the verdict is wrong', errorText: _validation),
              onChanged: (_) {
                if (_validation != null) setState(() => _validation = null);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('dispute-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(key: const Key('dispute-send'), onPressed: _busy ? null : _send, child: const Text('Send dispute')),
      ],
    );
  }
}
