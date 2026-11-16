import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app_scope.dart';
import '../core/errors.dart';
import '../core/widgets/detail_frame.dart';
import '../core/widgets/loader.dart';
import '../widgets/load_view.dart';
import 'work_screen.dart';

/// `/work/home/unit/<claimId>`: the Work screen for the live claim. Home hands over the claim it already
/// read; a link or a refresh reads the live claim again, and a claim that is no longer live (submitted,
/// released, expired) says so instead of showing a stale form.
class WorkRoute extends StatefulWidget {
  const WorkRoute({super.key, required this.claimId, this.initial});
  final String claimId;
  final ActiveWork? initial;

  static const crumbs = [Crumb('Work'), Crumb('Home', path: '/work/home'), Crumb('Unit')];

  @override
  State<WorkRoute> createState() => _WorkRouteState();
}

class _WorkRouteState extends State<WorkRoute> {
  late Future<ActiveWork> _load = _read();

  Future<ActiveWork> _read() async {
    final given = widget.initial;
    if (given != null && given.isLive && given.claim!.id == widget.claimId) return given;
    return AppScope.of(context).work.activeWork();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ActiveWork>(
      future: _load,
      builder: (context, snap) {
        final work = snap.data;
        if (work != null && work.isLive && work.claim!.id == widget.claimId) {
          return WorkScreen(claim: work.claim!, unit: work.unit!, batch: work.batch);
        }
        return DetailFrame(
          crumbs: WorkRoute.crumbs,
          body: switch (snap) {
            AsyncSnapshot(hasError: true, :final error) => ErrorView(
              message: describeError(error!),
              onRetry: () async => setState(() {
                _load = _read();
              }),
            ),
            AsyncSnapshot(connectionState: ConnectionState.done) => const ClaimNotLive(),
            _ => const Center(child: BrandLoader()),
          },
        );
      },
    );
  }
}
