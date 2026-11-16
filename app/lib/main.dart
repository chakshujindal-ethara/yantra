import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import 'api/gateway_client.dart';
import 'api/assess_repository.dart';
import 'api/client_repository.dart';
import 'api/finance_repository.dart';
import 'api/ops_repository.dart';
import 'api/people_repository.dart';
import 'api/quality_ops_repository.dart';
import 'api/repositories.dart';
import 'api/support_repository.dart';
import 'api/talent_repository.dart';
import 'api/tracker_repository.dart';
import 'app_router.dart';
import 'app_scope.dart';
import 'auth/keycloak.dart';
import 'auth/session.dart';
import 'auth/token_store.dart';
import 'config.dart';
import 'core/action_keys.dart';
import 'core/download.dart';
import 'core/drafts.dart';
import 'core/errors.dart';
import 'core/network_status.dart';
import 'core/people.dart';
import 'core/platform/file_pick.dart';
import 'core/stale_marks.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'core/upload.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  final config = await AppConfig.load();
  runApp(YantraApp.production(config));
}

/// The root: wires the session, the repositories, the theme and the router; the router shows sign-in,
/// the no-access page or the shell by session state and the URL.
class YantraApp extends StatefulWidget {
  const YantraApp({
    super.key,
    required this.session,
    required this.gateway,
    this.theme,
    this.network,
    this.downloader,
    this.drafts,
    this.files,
    this.uploadClient,
    this.initialLocation,
  });

  factory YantraApp.production(AppConfig config) {
    final client = http.Client();
    final session = Session(
      auth: KeycloakAuth(client: client, config: config),
      store: PreferencesTokenStore(),
      config: config,
    );
    final network = NetworkStatus.platform();
    return YantraApp(
      session: session,
      gateway: GatewayClient(client: client, tokens: session, baseUrl: config.gatewayUrl, network: network),
      theme: ThemeController(),
      network: network,
      downloader: platformDownloader(),
      drafts: PreferencesDraftStore(),
      files: platformFilePicker(),
      uploadClient: client,
    );
  }

  final Session session;
  final GatewayClient gateway;
  final ThemeController? theme;

  /// The same status the gateway client reports to; tests pass their own.
  final NetworkStatus? network;
  final Downloader? downloader;
  final DraftStore? drafts;
  final FilePicker? files;

  /// The client presigned uploads go through (no bearer token); tests pass the fake backend's.
  final http.Client? uploadClient;

  /// Tests start the router here; in the browser the router reads the address bar.
  final String? initialLocation;

  @override
  State<YantraApp> createState() => _YantraAppState();
}

class _YantraAppState extends State<YantraApp> {
  final _keys = ActionKeys();
  final _stale = StaleMarks();
  late final ThemeController _theme = widget.theme ?? ThemeController(persist: false);
  late final NetworkStatus _network = widget.network ?? NetworkStatus();
  final _guards = ExitGuards();
  late final GoRouter _router = buildRouter(session: widget.session, guards: _guards, initialLocation: widget.initialLocation);
  late final PeopleRepository _peopleRepo = PeopleRepository(widget.gateway);
  late final PeopleCache _people = PeopleCache(_peopleRepo.lookup, announce: _peopleRepo.announceSelf);
  late final Uploader _uploader = Uploader(widget.uploadClient ?? http.Client());

  /// Staff (ops, finance, admin) see the server's message under an error's plain copy.
  void _syncErrorDetails() => showErrorDetails = widget.session.roles.any(const {'ops', 'finance', 'admin'}.contains);

  @override
  void initState() {
    super.initState();
    _syncErrorDetails();
    widget.session.addListener(_syncErrorDetails);
    widget.session.restore();
    _theme.restore();
  }

  @override
  void dispose() {
    widget.session.removeListener(_syncErrorDetails);
    _router.dispose();
    _people.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      session: widget.session,
      work: WorkRepository(widget.gateway),
      review: ReviewRepository(widget.gateway),
      payout: PayoutRepository(widget.gateway),
      notify: NotifyRepository(widget.gateway),
      talent: TalentRepository(widget.gateway),
      assess: AssessRepository(widget.gateway),
      ops: OpsRepository(widget.gateway),
      client: ClientRepository(widget.gateway),
      support: SupportRepository(widget.gateway),
      finance: FinanceRepository(widget.gateway),
      qualityOps: QualityOpsRepository(widget.gateway),
      tracker: TrackerRepository(widget.gateway),
      keys: _keys,
      stale: _stale,
      theme: _theme,
      network: _network,
      people: _people,
      downloader: widget.downloader ?? MemoryDownloader(supported: false),
      drafts: widget.drafts ?? MemoryDraftStore(),
      files: widget.files ?? MemoryFilePicker(),
      uploader: _uploader,
      exitGuards: _guards,
      serverNow: widget.gateway.serverNow,
      child: ListenableBuilder(
        listenable: _theme,
        builder: (context, _) => MaterialApp.router(
          title: 'Yantra',
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: _theme.mode,
          debugShowCheckedModeBanner: false,
          routerConfig: _router,
        ),
      ),
    );
  }
}
