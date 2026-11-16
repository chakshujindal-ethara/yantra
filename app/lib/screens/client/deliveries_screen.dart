import 'package:flutter/material.dart';

import '../../api/client_models.dart';
import '../../app_scope.dart';
import '../../core/format.dart';
import '../../core/money.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';
import 'downloads.dart';
import 'project_screen.dart' show DeliveryButtons;

/// Every delivered batch across the org's projects, newest first: the units as JSONL and the manifest, both
/// saved as files.
class ClientDeliveriesScreen extends StatefulWidget {
  const ClientDeliveriesScreen({super.key});

  @override
  State<ClientDeliveriesScreen> createState() => _ClientDeliveriesScreenState();
}

class _ClientDeliveriesScreenState extends State<ClientDeliveriesScreen> {
  String? _held;

  Future<void> _units(Delivery d) async {
    final held = await downloadDeliverable(context, d.manifest.batchId);
    if (mounted) setState(() => _held = held);
  }

  @override
  Widget build(BuildContext context) {
    return LoadView<List<Delivery>>(
      firstWait: LoadWait.brand,
      wrapInCard: true,
      load: () => AppScope.of(context).client.deliveries(),
      builder: (context, deliveries, reload) => PortalPage(
        kicker: 'Client · Deliveries',
        title: 'Deliveries',
        subtitle: 'Every delivered batch: its units as JSONL and its manifest',
        onRefresh: reload,
        children: [
          if (_held != null) StatusBanner(_held!, kind: StatusKind.warn, icon: Icons.lock_clock_outlined, key: const Key('delivery-held')),
          PortalTable(
            minWidth: 920,
            emptyMessage: 'No delivery yet. A manifest appears here when a batch is delivered.',
            columns: const [
              PortalColumn('Project', flex: 2),
              PortalColumn('Batch', flex: 2),
              PortalColumn('Digest', flex: 3),
              PortalColumn('Accepted', numeric: true, width: 100),
              PortalColumn('Total', numeric: true, flex: 2),
              PortalColumn('Delivered', width: 110),
              PortalColumn('', width: 220),
            ],
            rows: [
              for (final d in deliveries)
                PortalRow(key: Key('delivery-${d.manifest.id}'), [
                  Text(d.projectName),
                  Text(d.batchTitle.isEmpty ? d.manifest.batchId : d.batchTitle),
                  Tooltip(
                    message: d.manifest.digest,
                    child: Text(d.manifest.digest, style: AppTheme.mono(context, fontSize: 12)),
                  ),
                  Text('${d.manifest.acceptedUnits}'),
                  Text(formatMoney(d.manifest.totalPrice, currency: d.currency)),
                  Text(d.manifest.createdAt == null ? '—' : shortDate(d.manifest.createdAt!)),
                  DeliveryButtons(
                    manifestId: d.manifest.id,
                    onManifest: () => downloadManifest(context, d.manifest.batchId),
                    onUnits: () => _units(d),
                  ),
                ]),
            ],
          ),
        ],
      ),
    );
  }
}
