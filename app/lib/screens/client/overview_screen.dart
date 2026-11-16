import 'package:flutter/material.dart';

import '../../api/client_models.dart';
import '../../app_scope.dart';
import '../../core/format.dart';
import '../../core/money.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/steps.dart';
import '../../widgets/load_view.dart';
import '../shell.dart';
import '../../app_router.dart';
import 'package:go_router/go_router.dart';

/// The client's overview: units delivered and in progress, acceptance, rework billed, deliveries and the
/// invoice to date across the org's projects, then the projects. Prices only; never a pay rate.
class ClientOverviewScreen extends StatelessWidget {
  const ClientOverviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return LoadView<(ClientOverview, List<ClientProject>)>(
      firstWait: LoadWait.brand,
      wrapInCard: true,
      load: () async {
        final client = AppScope.of(context).client;
        // Future.wait, not a record wait: the first failure surfaces as itself, so Retry shows its reason.
        final results = await Future.wait<Object>([client.overview(), client.projects()]);
        return (results[0] as ClientOverview, results[1] as List<ClientProject>);
      },
      builder: (context, data, reload) {
        final (o, projects) = data;
        final orgs = o.orgs.map((x) => x.name).where((n) => n.isNotEmpty).join(', ');
        return PortalPage(
          kicker: 'Client · Overview',
          title: 'Overview',
          subtitle: orgs.isEmpty ? 'Your work with Yantra' : orgs,
          onRefresh: reload,
          children: [
            _Kpis(o),
            SectionTitle(
              'Projects',
              subtitle: '${projects.length} ${projects.length == 1 ? 'project' : 'projects'}',
              trailing: TextButton(
                key: const Key('overview-all-projects'),
                onPressed: () => ShellActions.of(context).go(Destination.clientProjects),
                child: const Text('All projects'),
              ),
            ),
            if (projects.isEmpty)
              const PortalCard(child: Text('No project yet. Your Yantra contact sets one up with you; it appears here.'))
            else
              for (final p in projects) _ProjectCard(p),
          ],
        );
      },
    );
  }
}

class _Kpis extends StatelessWidget {
  const _Kpis(this.o);
  final ClientOverview o;

  @override
  Widget build(BuildContext context) {
    final u = o.units;
    final decided = u.accepted + u.rejected + u.needsEdits;
    return KpiRow(
      children: [
        KpiTile(
          label: 'Units delivered',
          value: '${u.accepted}',
          note: 'Accepted of ${u.total} in total',
          kind: StatusKind.success,
          icon: Icons.inventory_2_outlined,
        ),
        KpiTile(
          label: 'In progress',
          value: '${u.inProgress + u.inReview}',
          note: '${u.inReview} in review · ${u.available} not started',
          kind: StatusKind.info,
          icon: Icons.schedule,
        ),
        KpiTile(
          label: 'Acceptance rate',
          value: decided == 0 ? '—' : '${o.acceptancePercent}%',
          note: decided == 0 ? 'No verdict yet' : 'First-pass, across $decided decided units',
          kind: decided == 0 ? null : (o.acceptancePercent >= 80 ? StatusKind.success : StatusKind.warn),
          icon: Icons.insights_outlined,
        ),
        KpiTile(
          label: 'Rework billed',
          value: '${o.billableRework}',
          note: o.billableRework == 0 ? 'No client-caused rework' : 'Units redone after a brief or glossary change',
          kind: o.billableRework == 0 ? null : StatusKind.warn,
          icon: Icons.replay_outlined,
        ),
        KpiTile(label: 'Deliveries', value: '${o.deliveries}', note: 'Manifests delivered to you', icon: Icons.local_shipping_outlined),
        _nextDelivery(o.nextDelivery),
        if (o.invoiceTotal.isEmpty)
          const KpiTile(
            label: 'Invoice to date',
            value: '—',
            note: 'Accepted units × price, plus billable rework',
            icon: Icons.receipt_long_outlined,
          )
        else
          for (final e in o.invoiceTotal.entries)
            KpiTile(
              label: 'Invoice to date',
              value: formatMoney(e.value, currency: e.key),
              note: 'Accepted units × price, plus billable rework',
              icon: Icons.receipt_long_outlined,
            ),
      ],
    );
  }
}

/// The open batch due first: when, which, and how far along.
Widget _nextDelivery(NextDelivery? n) {
  if (n == null) {
    return const KpiTile(
      key: Key('next-delivery'),
      label: 'Next delivery',
      value: '—',
      note: 'No open batch has a due date',
      icon: Icons.event_outlined,
    );
  }
  final due = n.dueAt;
  final late = due != null && due.isBefore(DateTime.now());
  return KpiTile(
    key: const Key('next-delivery'),
    label: 'Next delivery',
    value: due == null ? '—' : shortDate(due.toLocal()),
    note: '${n.title.isEmpty ? 'Batch' : n.title} · ${n.projectName} · ${n.accepted} of ${n.total} accepted${late ? ' · past due' : ''}',
    kind: late ? StatusKind.warn : StatusKind.info,
    icon: Icons.event_outlined,
  );
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard(this.p);
  final ClientProject p;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final u = p.units;
    return PortalCard(
      key: Key('project-${p.id}'),
      onTap: () => context.go(Paths.clientProject(p.id), extra: p.name),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(p.name, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: Space.x8),
              StatusChip.status(p.status),
              const SizedBox(width: Space.x8),
              Icon(Icons.chevron_right, color: t.textMuted),
            ],
          ),
          const SizedBox(height: Space.x8),
          Wrap(
            spacing: Space.x16,
            runSpacing: Space.x4,
            children: [
              Text('${u.accepted} of ${u.total} accepted', style: theme.textTheme.bodySmall),
              Text(
                u.accepted + u.rejected + u.needsEdits == 0 ? 'No verdict yet' : '${p.acceptancePercent}% acceptance',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                'Invoice ${formatMoney(p.invoiceTotal, currency: p.currency)}',
                style: AppTheme.figure(context, fontSize: 12, color: t.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: Space.x8),
          unitsBar(context, u, legend: false),
        ],
      ),
    );
  }
}

/// Units by stage as one bar: not started · in progress · in review · accepted · returned.
Widget unitsBar(BuildContext context, UnitCounts u, {bool legend = true}) {
  final t = PortalTokens.of(context);
  return StackedBar(
    legend: legend,
    segments: [
      ('Not started', u.available.toDouble(), t.border),
      ('In progress', u.inProgress.toDouble(), t.infoDot),
      ('In review', u.inReview.toDouble(), t.warnDot),
      ('Accepted', u.accepted.toDouble(), t.successDot),
      ('Returned', (u.rejected + u.needsEdits).toDouble(), t.destDot),
    ],
  );
}
