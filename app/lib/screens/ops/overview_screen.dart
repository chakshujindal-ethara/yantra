import 'package:flutter/material.dart';

import '../../api/ops_models.dart';
import '../../app_scope.dart';
import '../../core/format.dart';
import '../../core/poller.dart';
import '../../core/money.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/stage_bar.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';
import '../shell.dart';
import '../../app_router.dart';
import 'package:go_router/go_router.dart';

/// The ops home: the numbers, what needs attention, the latest projects. A module that is still empty
/// (404) paints a dash, never an error. It re-reads itself quietly every minute while the tab is visible.
class OpsOverviewScreen extends StatefulWidget {
  const OpsOverviewScreen({super.key});

  @override
  State<OpsOverviewScreen> createState() => _OpsOverviewScreenState();
}

class _OpsOverviewScreenState extends State<OpsOverviewScreen> {
  final _loader = GlobalKey<LoadViewState<OpsOverview>>();
  late final Poller _poller = Poller(every: const Duration(seconds: 60), tick: () async => _loader.currentState?.reload());

  @override
  void initState() {
    super.initState();
    _poller.start();
  }

  @override
  void dispose() {
    _poller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LoadView<OpsOverview>(
      key: _loader,
      firstWait: LoadWait.brand,
      load: () => AppScope.of(context).ops.overview(),
      builder: (context, o, reload) => PortalPage(
        kicker: 'Operate · Overview',
        title: 'Overview',
        subtitle: 'The platform today',
        onRefresh: reload,
        children: [_Kpis(o), _Attention(o), _Projects(o)],
      ),
    );
  }
}

const _dash = '—';

/// `in 12 min`, `in 5 h`, `in 3 days` from a number of seconds, rounded to the nearest unit.
String closesIn(int seconds) {
  if (seconds <= 0) return 'now';
  if (seconds < 3600) return 'in ${(seconds / 60).round()} min';
  if (seconds < 48 * 3600) return 'in ${(seconds / 3600).round()} h';
  return 'in ${(seconds / 86400).round()} days';
}

/// `45 min`, `3 h`, `2 days`: how long the oldest pending review has waited.
String waitingLabel(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 48) return '${d.inHours} h';
  return '${d.inDays} days';
}

class _Kpis extends StatelessWidget {
  const _Kpis(this.o);
  final OpsOverview o;

  @override
  Widget build(BuildContext context) {
    final units = o.units;
    final stats = o.stats;
    final payout = o.payout;
    final oldest = o.attention?.oldestPendingAt ?? stats?.oldestPendingAt;
    final payable = payout == null
        ? const <MapEntry<String, String>>[]
        : (payout.payableNow.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    final window = payout?.openWindow;
    final bench = o.bench;
    void go(Destination d) => ShellActions.of(context).go(d);
    return KpiRow(
      children: [
        KpiTile(
          label: 'Open units',
          value: '${units.available}',
          note: 'Available to claim',
          icon: Icons.inventory_2_outlined,
          onTap: () => go(Destination.projects),
        ),
        KpiTile(
          label: 'Live claims',
          value: '${units.claimed}',
          note: 'Units someone is working on',
          kind: StatusKind.info,
          icon: Icons.bolt_outlined,
          onTap: () => go(Destination.projects),
        ),
        KpiTile(
          label: 'In review',
          value: '${units.reviewing}',
          note: oldest == null ? 'Submitted and in review' : 'oldest waiting ${waitingLabel(DateTime.now().difference(oldest))}',
          kind: oldest != null && DateTime.now().difference(oldest) > const Duration(hours: 24) ? StatusKind.warn : null,
          icon: Icons.rate_review_outlined,
          onTap: () => go(Destination.quality),
        ),
        KpiTile(
          label: 'Acceptance',
          value: stats?.acceptanceRate == null ? _dash : percent(stats!.acceptanceRate),
          note: stats == null ? 'Quality has no figures yet' : 'First-pass, ${stats.accepted} accepted · ${stats.rejected} rejected',
          kind: stats == null ? null : StatusKind.success,
          icon: Icons.verified_outlined,
          onTap: () => go(Destination.quality),
        ),
        KpiTile(
          label: 'Bench',
          value: bench == null ? _dash : '${bench.bench}',
          note: bench == null ? 'Market has no bench figures yet' : '${bench.paused} paused · ${bench.held} held · ${bench.total} in all',
          kind: bench != null && bench.held > 0 ? StatusKind.warn : null,
          icon: Icons.groups_outlined,
          onTap: () => go(Destination.workers),
        ),
        KpiTile(
          label: 'Payable now',
          value: payable.isEmpty ? _dash : formatMoney(payable.first.value, currency: payable.first.key),
          note: payable.length > 1
              ? payable.skip(1).map((e) => formatMoney(e.value, currency: e.key)).join(' · ')
              : (payout == null ? 'Payout has no figures yet' : 'Earned, not yet in a window'),
          icon: Icons.account_balance_wallet_outlined,
          onTap: () => go(Destination.finance),
        ),
        KpiTile(
          label: 'Margin to date',
          value: payout == null ? _dash : moneyList(payout.marginTotal, dash: _dash),
          note: payout == null ? _dash : 'Paid ${moneyList(payout.paidTotal, dash: '0')} · held ${moneyList(payout.heldTotal, dash: '0')}',
          icon: Icons.trending_up,
          onTap: () => go(Destination.finance),
        ),
        KpiTile(
          label: 'Window closes',
          value: window == null ? _dash : closesIn(window.closesInSeconds),
          note: window == null || window.startsAt == null || window.endsAt == null
              ? 'No open pay window'
              : payWindowRange(window.startsAt!, window.endsAt!),
          icon: Icons.lock_clock_outlined,
          onTap: () => go(Destination.finance),
        ),
      ],
    );
  }
}

class _Attention extends StatelessWidget {
  const _Attention(this.o);
  final OpsOverview o;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final under = o.underFloor;
    final a = o.attention;
    final m = o.payoutAttention;
    Widget row(int n, String one, String many, String key, Destination d) =>
        _AttentionRow(label: _count(n, one, many), buttonKey: Key('attention-$key'), destination: d);
    final rows = <Widget>[
      if (a != null) ...[
        if (a.flagsOverdue > 0)
          row(a.flagsOverdue, 'flag past its 2-day answer', 'flags past their 2-day answer', 'flags-overdue', Destination.quality),
        if (a.flagsOpen - a.flagsOverdue > 0) row(a.flagsOpen - a.flagsOverdue, 'open flag', 'open flags', 'quality', Destination.quality),
        if (a.disputesOpen > 0) row(a.disputesOpen, 'open dispute', 'open disputes', 'disputes', Destination.quality),
        if (a.expiredClaims + a.expiredReviews > 0)
          row(
            a.expiredClaims + a.expiredReviews,
            'claim or review past its time',
            'claims and reviews past their time',
            'stuck',
            Destination.system,
          ),
        if (a.stuckAssignedUnits > 0)
          row(
            a.stuckAssignedUnits,
            'unit waiting days for one worker',
            'units waiting days for one worker',
            'stuck-assigned',
            Destination.system,
          ),
        if (a.applicationsScreening > 0)
          row(
            a.applicationsScreening,
            'applicant waiting for screening',
            'applicants waiting for screening',
            'applicants',
            Destination.listings,
          ),
        if (a.ticketsOpen > 0) row(a.ticketsOpen, 'open ticket', 'open tickets', 'support', Destination.support),
        if (a.erasuresDue > 0) row(a.erasuresDue, 'erasure request due', 'erasure requests due', 'erasures', Destination.workers),
        if (a.deadLetterTotal > 0)
          row(a.deadLetterTotal, 'event that could not be handled', 'events that could not be handled', 'dead', Destination.system),
      ],
      if (m != null) ...[
        if (m.windowsAwaitingSecondApproval > 0)
          row(
            m.windowsAwaitingSecondApproval,
            'window waiting for a second approval',
            'windows waiting for a second approval',
            'finance',
            Destination.finance,
          ),
        if (m.failedLines > 0)
          row(m.failedLines, 'payout the bank refused', 'payouts the bank refused', 'failed-lines', Destination.finance),
        if (m.linesBlocked > 0)
          row(m.linesBlocked, 'payout line that cannot go out', 'payout lines that cannot go out', 'lines-blocked', Destination.finance),
        if (m.accountsAwaitingConfirmation > 0)
          row(
            m.accountsAwaitingConfirmation,
            'bank account waiting for finance to confirm it',
            'bank accounts waiting for finance to confirm them',
            'accounts-to-confirm',
            Destination.finance,
          ),
        if (m.erasuresPending > 0)
          row(
            m.erasuresPending,
            'bank account to erase once what is owed is paid',
            'bank accounts to erase once what is owed is paid',
            'payout-erasures',
            Destination.finance,
          ),
        if (m.reconciliationDeltas > 0)
          row(m.reconciliationDeltas, 'window that does not reconcile', 'windows that do not reconcile', 'deltas', Destination.finance),
        if (m.pendingAdjustments > 0)
          row(m.pendingAdjustments, 'adjustment to approve', 'adjustments to approve', 'adjustments', Destination.finance),
        if (m.deadLetters > 0)
          row(
            m.deadLetters,
            'payout event that could not be handled',
            'payout events that could not be handled',
            'dead-money',
            Destination.system,
          ),
      ],
      if (under.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.x6),
          child: Text(
            _count(under.length, 'batch under its margin floor', 'batches under their margin floor'),
            style: theme.textTheme.bodyMedium,
          ),
        ),
        for (final (p, b) in under)
          _AttentionRow(
            label: '${b.title} · ${p.name} · ${percent(b.margin)} < ${percent(p.marginFloor)}',
            buttonKey: Key('attention-floor-${b.id}'),
            buttonLabel: 'Open project',
            onTap: () => context.go(Paths.project(p.id)),
          ),
      ],
    ];
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Attention', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x8),
          if (rows.isEmpty)
            Text('Nothing needs attention', style: theme.textTheme.bodyMedium?.copyWith(color: PortalTokens.of(context).textSecondary))
          else
            ...rows,
        ],
      ),
    );
  }

  static String _count(int n, String one, String many) => '$n ${n == 1 ? one : many}';
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({required this.label, required this.buttonKey, this.destination, this.onTap, this.buttonLabel = 'Open'});
  final String label;
  final Key buttonKey;
  final Destination? destination;
  final VoidCallback? onTap;
  final String buttonLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.x4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          const SizedBox(width: Space.x12),
          OutlinedButton(key: buttonKey, onPressed: onTap ?? () => ShellActions.of(context).go(destination!), child: Text(buttonLabel)),
        ],
      ),
    );
  }
}

class _Projects extends StatelessWidget {
  const _Projects(this.o);
  final OpsOverview o;

  @override
  Widget build(BuildContext context) {
    final latest = [...o.projects]..sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
    final shown = latest.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          'Projects',
          subtitle: 'The latest ${shown.length}',
          trailing: TextButton(
            key: const Key('overview-all-projects'),
            onPressed: () => ShellActions.of(context).go(Destination.projects),
            child: const Text('See all'),
          ),
        ),
        PortalTable(
          emptyMessage: 'No projects yet. Create one on the Projects page.',
          columns: const [
            PortalColumn('Project', flex: 2),
            PortalColumn('Status', width: 130),
            PortalColumn('Batches', width: 90, numeric: true),
            PortalColumn('Units', flex: 2),
            PortalColumn('Created', width: 110),
          ],
          rows: [
            for (final p in shown)
              PortalRow(key: Key('overview-project-${p.id}'), onTap: () => context.go(Paths.project(p.id)), [
                Text(p.name),
                ConsoleStatus(p.status),
                Text('${p.batchCount}'),
                StageBar(
                  legend: false,
                  available: p.units.available,
                  inProgress: p.units.claimed,
                  inReview: p.units.reviewing,
                  accepted: p.units.accepted,
                  rejected: p.units.rejected,
                  needsEdits: p.units.needsEdits,
                ),
                Text(p.createdAt == null ? _dash : shortDate(p.createdAt!)),
              ]),
          ],
        ),
      ],
    );
  }
}
