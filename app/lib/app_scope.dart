import 'package:flutter/widgets.dart';

import 'api/assess_repository.dart';
import 'api/client_repository.dart';
import 'api/finance_repository.dart';
import 'api/ops_repository.dart';
import 'api/quality_ops_repository.dart';
import 'api/repositories.dart';
import 'api/support_repository.dart';
import 'api/talent_repository.dart';
import 'api/tracker_repository.dart';
import 'app_router.dart';
import 'auth/session.dart';
import 'core/action_keys.dart';
import 'core/download.dart';
import 'core/drafts.dart';
import 'core/network_status.dart';
import 'core/people.dart';
import 'core/platform/file_pick.dart';
import 'core/stale_marks.dart';
import 'core/theme/theme_controller.dart';
import 'core/upload.dart';

/// The dependencies every screen reads: the session, the repositories, the idempotency keys, the theme.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.session,
    required this.work,
    required this.review,
    required this.payout,
    required this.notify,
    required this.talent,
    required this.assess,
    required this.ops,
    required this.client,
    required this.support,
    required this.finance,
    required this.qualityOps,
    required this.tracker,
    required this.keys,
    required this.stale,
    required this.theme,
    required this.network,
    required this.people,
    required this.downloader,
    required this.drafts,
    required this.files,
    required this.uploader,
    required this.exitGuards,
    required this.serverNow,
    required super.child,
  });

  final Session session;
  final WorkRepository work;
  final ReviewRepository review;
  final PayoutRepository payout;
  final NotifyRepository notify;
  final TalentRepository talent;
  final AssessRepository assess;
  final OpsRepository ops;
  final ClientRepository client;
  final SupportRepository support;
  final FinanceRepository finance;
  final QualityOpsRepository qualityOps;

  /// Activity sessions and samples while a claim is open; the worker's week against the cap.
  final TrackerRepository tracker;
  final ActionKeys keys;

  /// Destinations a mutation has outdated; the shell rebuilds them on their next visit.
  final StaleMarks stale;
  final ThemeController theme;

  /// Browser online and gateway reachability; the shell's offline banner listens to it.
  final NetworkStatus network;

  /// Names for ids (`NameOf`); one batched request per frame of misses.
  final PeopleCache people;

  /// Saves a file the user asked for (statement CSV, bank file, manifest, deliverable).
  final Downloader downloader;

  /// Work in progress kept on this device (unit answers, sitting answers).
  final DraftStore drafts;

  /// The browser's file chooser (batch import, documents).
  final FilePicker files;

  /// PUTs bytes to a presigned object-storage URL.
  final Uploader uploader;

  /// What a timed page answers when someone leaves it (see `GuardedRoute`).
  final ExitGuards exitGuards;

  /// Now on the gateway's clock (`GatewayClient.serverNow`): every countdown and expiry decision uses it.
  final DateTime Function() serverNow;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope missing above this widget');
    return scope ?? (throw StateError('AppScope missing'));
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => session != oldWidget.session || theme != oldWidget.theme || network != oldWidget.network;
}
