import 'package:flutter/material.dart';

import '../../api/client_models.dart';
import '../../app_scope.dart';
import '../../core/money.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';
import 'overview_screen.dart';
import '../../app_router.dart';
import 'package:go_router/go_router.dart';

/// Every project of the org: status, units by stage, acceptance, the invoice to date. A row opens the project.
class ClientProjectsScreen extends StatelessWidget {
  const ClientProjectsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return LoadView<List<ClientProject>>(
      firstWait: LoadWait.brand,
      wrapInCard: true,
      load: () => AppScope.of(context).client.projects(),
      builder: (context, projects, reload) => PortalPage(
        kicker: 'Client · Projects',
        title: 'Projects',
        subtitle: 'Progress, quality and invoices',
        onRefresh: reload,
        children: [
          PortalTable(
            minWidth: 720,
            emptyMessage: 'No project yet. Your Yantra contact sets one up with you; it appears here.',
            rowHeight: 52,
            columns: const [
              PortalColumn('Project', flex: 3),
              PortalColumn('Status', width: 110),
              PortalColumn('Units', flex: 3),
              PortalColumn('Acceptance', numeric: true, width: 110),
              PortalColumn('Invoice to date', numeric: true, flex: 2),
            ],
            rows: [
              for (final p in projects)
                PortalRow(key: Key('project-${p.id}'), onTap: () => context.push(Paths.clientProject(p.id), extra: p.name), [
                  Text(p.name),
                  FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: StatusChip.status(p.status)),
                  _UnitsCell(p.units),
                  Text(p.units.accepted + p.units.rejected + p.units.needsEdits == 0 ? '—' : '${p.acceptancePercent}%'),
                  Text(formatMoney(p.invoiceTotal, currency: p.currency)),
                ]),
            ],
          ),
        ],
      ),
    );
  }
}

class _UnitsCell extends StatelessWidget {
  const _UnitsCell(this.u);
  final UnitCounts u;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Tooltip(
      message:
          '${u.available} not started · ${u.inProgress} in progress · ${u.inReview} in review · ${u.accepted} accepted · ${u.rejected + u.needsEdits} returned',
      child: Row(
        children: [
          Expanded(child: unitsBar(context, u, legend: false)),
          const SizedBox(width: Space.x8),
          Text('${u.accepted}/${u.total}', style: AppTheme.figure(context, fontSize: 12, color: t.textSecondary)),
        ],
      ),
    );
  }
}
