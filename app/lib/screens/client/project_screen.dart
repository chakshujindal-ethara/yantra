import 'package:flutter/material.dart';

import '../../api/client_models.dart';
import '../../api/models.dart';
import '../../app_scope.dart';
import '../../core/format.dart';
import '../../core/money.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/action_dialog.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';
import 'overview_screen.dart';
import '../../core/widgets/detail_frame.dart';
import '../shell.dart';
import '../../widgets/feedback_thread.dart';
import 'downloads.dart';

/// One project for the client: batches with progress and price, the reasons behind rework, the rubric,
/// deliveries with their manifests, the invoice to date and the feedback thread. Pushed from Overview or
/// Projects. Prices only; never a pay rate.
class ClientProjectScreen extends StatefulWidget {
  const ClientProjectScreen({super.key, required this.projectId, this.name = ''});
  final String projectId;
  final String name;

  @override
  State<ClientProjectScreen> createState() => _ClientProjectScreenState();
}

class _ClientProjectScreenState extends State<ClientProjectScreen> {
  final _loader = GlobalKey<LoadViewState<ClientProjectDetail>>();
  String? _held;

  Future<void> _deliverable(Manifest m) async {
    final held = await downloadDeliverable(context, m.batchId);
    if (mounted) setState(() => _held = held);
  }

  Future<void> _send(String text) async {
    final scope = AppScope.of(context);
    await withActionKey(
      scope.keys,
      'feedback:${widget.projectId}:${text.hashCode}',
      (key) => scope.client.sendFeedback(widget.projectId, text, key: key),
    );
    if (!mounted) return;
    toast(context, 'Feedback sent');
    await _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return DetailFrame(
      crumbs: [
        const Crumb('Client'),
        Crumb('Projects', path: Destination.clientProjects.path),
        Crumb(widget.name.isEmpty ? 'Project' : widget.name),
      ],
      body: LoadView<ClientProjectDetail>(
        firstWait: LoadWait.brand,
        wrapInCard: true,
        key: _loader,
        load: () => AppScope.of(context).client.project(widget.projectId),
        builder: (context, p, reload) => PortalPage(
          kicker: 'Client · Projects',
          title: p.name.isEmpty ? widget.name : p.name,
          subtitle: 'Rubric ${p.rubricVersion.isEmpty ? '—' : p.rubricVersion} · ${p.currency}',
          actions: [StatusChip.status(p.status, key: const Key('project-status'))],
          onRefresh: reload,
          children: [
            _Kpis(p),
            const SectionTitle('Batches', subtitle: 'Progress and the price per accepted unit'),
            if (p.batches.isEmpty)
              const PortalCard(child: Text('No batch yet.'))
            else
              for (final b in p.batches) _BatchCard(b, currency: p.currency),
            if (p.reasons.isNotEmpty) ...[
              const SectionTitle('Rework', subtitle: 'Why units were returned; billable reasons are rework at your cost'),
              PortalTable(
                minWidth: 420,
                columns: const [PortalColumn('Reason', flex: 3), PortalColumn('Units', numeric: true), PortalColumn('Billing', width: 150)],
                rows: [
                  for (final r in p.reasons)
                    PortalRow(key: Key('reason-${r.reasonCode}'), [
                      Text(ReasonCode.byCode(r.reasonCode)?.label ?? humanize(r.reasonCode)),
                      Text('${r.count}'),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: r.billable
                            ? const StatusChip('Billable', kind: StatusKind.warn)
                            : const StatusChip('Not billed', kind: StatusKind.success),
                      ),
                    ]),
                ],
              ),
              const SizedBox(height: Space.x16),
            ],
            const SectionTitle('Deliveries', subtitle: 'Per delivered batch: the units as JSONL and the manifest'),
            if (_held != null)
              StatusBanner(_held!, kind: StatusKind.warn, icon: Icons.lock_clock_outlined, key: const Key('delivery-held')),
            _Deliveries(p, onManifest: (m) => downloadManifest(context, m.batchId), onUnits: _deliverable),
            const SizedBox(height: Space.x16),
            FeedbackThread(
              items: p.feedback,
              onSend: _send,
              subtitle: 'Your thread with the Yantra team on this project',
              emptyMessage: 'Nothing yet. Tell the team what to prioritise or what looks off.',
              composerLabel: 'Write to the team',
            ),
          ],
        ),
      ),
    );
  }
}

class _Kpis extends StatelessWidget {
  const _Kpis(this.p);
  final ClientProjectDetail p;

  @override
  Widget build(BuildContext context) {
    final u = p.units;
    final decided = u.accepted + u.rejected + u.needsEdits;
    return KpiRow(
      children: [
        KpiTile(
          label: 'Accepted',
          value: '${u.accepted}',
          note: 'of ${u.total} units',
          kind: StatusKind.success,
          icon: Icons.check_circle_outline,
        ),
        KpiTile(
          label: 'In progress',
          value: '${u.inProgress + u.inReview}',
          note: '${u.inReview} in review',
          kind: StatusKind.info,
          icon: Icons.schedule,
        ),
        KpiTile(
          label: 'Acceptance rate',
          value: decided == 0 ? '—' : '${p.acceptancePercent}%',
          note: decided == 0 ? 'No verdict yet' : 'First-pass',
          kind: decided == 0 ? null : (p.acceptancePercent >= 80 ? StatusKind.success : StatusKind.warn),
          icon: Icons.insights_outlined,
        ),
        KpiTile(
          label: 'Invoice to date',
          value: formatMoney(p.invoiceTotal, currency: p.currency),
          note: 'Accepted units × price, plus billable rework',
          icon: Icons.receipt_long_outlined,
        ),
      ],
    );
  }
}

class _BatchCard extends StatelessWidget {
  const _BatchCard(this.b, {required this.currency});
  final ClientBatch b;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final m = b.manifest;
    return PortalCard(
      key: Key('batch-${b.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Space.x12,
            runSpacing: Space.x6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(b.title.isEmpty ? 'Batch' : b.title, style: theme.textTheme.titleMedium),
              StatusChip.status(b.status),
              Text(
                '${formatMoney(b.unitPrice, currency: currency)} per accepted unit',
                style: AppTheme.figure(context, fontSize: 12, color: t.textSecondary),
              ),
              if (m != null) const StatusChip('Delivered', kind: StatusKind.success),
            ],
          ),
          const SizedBox(height: Space.x12),
          unitsBar(context, b.units),
        ],
      ),
    );
  }
}

class _Deliveries extends StatelessWidget {
  const _Deliveries(this.p, {required this.onManifest, required this.onUnits});
  final ClientProjectDetail p;
  final Future<void> Function(Manifest) onManifest;
  final Future<void> Function(Manifest) onUnits;

  @override
  Widget build(BuildContext context) {
    if (p.deliveries.isEmpty) {
      return const PortalCard(child: EmptyView(message: 'No delivery yet. A manifest appears when a batch is delivered.'));
    }
    return PortalTable(
      minWidth: 820,
      columns: const [
        PortalColumn('Batch', flex: 2),
        PortalColumn('Digest', flex: 3),
        PortalColumn('Accepted', numeric: true, width: 100),
        PortalColumn('Total', numeric: true, flex: 2),
        PortalColumn('Delivered', width: 110),
        PortalColumn('', width: 220),
      ],
      rows: [
        for (final m in p.deliveries)
          PortalRow(key: Key('delivery-${m.id}'), [
            Text(p.batchOf(m)?.title ?? m.batchId),
            Tooltip(
              message: m.digest,
              child: Text(m.digest, style: AppTheme.mono(context, fontSize: 12)),
            ),
            Text('${m.acceptedUnits}'),
            Text(formatMoney(m.totalPrice, currency: p.currency)),
            Text(m.createdAt == null ? '—' : shortDate(m.createdAt!)),
            DeliveryButtons(manifestId: m.id, onManifest: () => onManifest(m), onUnits: () => onUnits(m)),
          ]),
      ],
    );
  }
}

/// The two downloads of a delivered batch: its units as JSONL and its manifest.
class DeliveryButtons extends StatelessWidget {
  const DeliveryButtons({super.key, required this.manifestId, required this.onManifest, required this.onUnits});
  final String manifestId;
  final VoidCallback onManifest;
  final VoidCallback onUnits;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: Space.x4,
    children: [
      TextButton.icon(
        key: Key('units-download-$manifestId'),
        onPressed: onUnits,
        icon: const Icon(Icons.download_outlined, size: Sizes.iconSm),
        label: const Text('Units'),
      ),
      TextButton.icon(
        key: Key('manifest-download-$manifestId'),
        onPressed: onManifest,
        icon: const Icon(Icons.description_outlined, size: Sizes.iconSm),
        label: const Text('Manifest'),
      ),
    ],
  );
}
