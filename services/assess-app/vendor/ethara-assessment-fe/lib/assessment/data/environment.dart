/// Which deployment this bundle is running in, and therefore which backend it
/// talks to.
///
/// THE PROBLEM THIS SOLVES. The backend origin used to be nothing but
/// `--dart-define=API_BASE_URL`, which Dart compiles into `main.dart.js` as a
/// string constant. That makes the pairing a property of the BUILD, not of the
/// deployment: one image per environment, and an image promoted from stage to
/// production keeps talking to stage. The failure is silent from the server's
/// side - production's browser calls stage, stage answers correctly, and the
/// only symptom is production data that is not there.
///
/// So the origin is derived from the host the app is being SERVED from, which
/// for a DEPLOYED bundle is the one fact that is always true at runtime:
///
///   assessment.ethara.ai        -> https://projects.ethara.ai        (prod)
///   assessment-stage.ethara.ai  -> https://projects-stage.ethara.ai  (stage)
///
/// One bundle now serves both, and a bundle deployed to the wrong host corrects
/// itself instead of quietly crossing environments.
///
/// PRECEDENCE:
///
///   1. `--dart-define=API_BASE_URL` when non-empty.
///   2. The host table above.
///   3. Same origin (empty). The pre-existing default: the app runs on its
///      bundled seed data, which is what a design review wants and what the
///      widget tests rely on.
///
/// WHY localhost IS NOT IN THE TABLE, which is the first thing this looks like
/// it is missing. `localhost` identifies no deployment. It is the app under
/// `make serve-local` on :8200, a stage bundle under `make serve-stage` on
/// :8201, an unrelated project, and - the case that decides it - the page
/// `flutter test --platform chrome` serves the suite from, which is
/// `http://localhost:<random>/<name>_test.html`. Mapping it to `localhost:8069`
/// handed the entire widget suite a live backend: `hasBackend` became true, every
/// store that should have loaded seed data tried to sign in, and ~1280 tests went
/// red at once. There is no runtime signal that separates a dev server from a
/// test harness, so local development keeps naming its backend explicitly - which
/// is what `make serve-local` and `make build ENV=local` already do, and what the
/// Makefile's `LOCAL_BASE_URL` is for.
///
/// The consequence worth knowing: a bare `flutter run -d chrome` with no define
/// runs on seed data. Pass `--dart-define=API_BASE_URL=http://localhost:8069` to
/// reach a local Odoo, or use the Makefile.
library;

/// The deployments this app knows how to configure itself for.
///
/// [unknown] is not a failure - it is a host with no entry in the table (a
/// preview deploy, a bare IP, the Dart VM under test). Those fall back to the
/// same-origin default rather than guessing at a backend.
enum AppEnvironment { local, stage, production, unknown }

/// What one deployment needs to know to reach its backend.
class EnvironmentProfile {
  const EnvironmentProfile({
    required this.environment,
    required this.apiBaseUrl,
    this.apiDb = '',
  });

  final AppEnvironment environment;

  /// Origin of the Odoo instance, with no trailing slash. Empty means "the
  /// origin serving this page", which is the same-origin topology.
  final String apiBaseUrl;

  /// The Odoo database, which is only sent on the `/auth/session` fallback that
  /// a 404 on the gateway selects.
  ///
  /// Deliberately empty for [AppEnvironment.stage] and
  /// [AppEnvironment.production]: both answer `/api/v1/auth_token`, so the app
  /// takes the gateway (bearer) lane, which names no database. Setting it there
  /// would have no effect and would imply otherwise.
  final String apiDb;
}

/// The backend origin baked in at build time. See rule 1 above.
const String kApiBaseUrlOverride = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: '',
);

/// The database baked in at build time, paired with [kApiBaseUrlOverride].
const String kApiDbOverride = String.fromEnvironment(
  'API_DB',
  defaultValue: '',
);

/// Backend origin per environment. The single source of truth for the pairing,
/// mirrored on the server by `assessments_be_v2/services/app_origins.py` -
/// change one and the other has to follow, or the API starts refusing the app's
/// origin at CORS.
const Map<AppEnvironment, EnvironmentProfile> kEnvironmentProfiles =
    <AppEnvironment, EnvironmentProfile>{
      AppEnvironment.production: EnvironmentProfile(
        environment: AppEnvironment.production,
        apiBaseUrl: 'https://projects.ethara.ai',
      ),
      AppEnvironment.stage: EnvironmentProfile(
        environment: AppEnvironment.stage,
        apiBaseUrl: 'https://projects-stage.ethara.ai',
      ),
      // SAME-ORIGIN, not localhost:8069. A local build has to name its backend
      // with the define - see the note on localhost in the library comment.
      // Reached only when an override is supplied, in which case the override
      // is the base URL and this entry contributes nothing but the label.
      AppEnvironment.local: EnvironmentProfile(
        environment: AppEnvironment.local,
        apiBaseUrl: '',
      ),
      AppEnvironment.unknown: EnvironmentProfile(
        environment: AppEnvironment.unknown,
        apiBaseUrl: '',
      ),
    };

/// Which environment a given front-end host belongs to.
///
/// Keyed on HOST ALONE, never host:port, because a deployment is a domain and
/// the port is whatever the ingress terminated on.
///
/// The localhost entries LABEL a local page; they do not give it a backend -
/// `kEnvironmentProfiles[local]` is same-origin. Both spellings are listed
/// because a browser treats `localhost` and `127.0.0.1` as different origins, so
/// a label keyed on one would be wrong half the time.
const Map<String, AppEnvironment> kHostEnvironments = <String, AppEnvironment>{
  'assessment.ethara.ai': AppEnvironment.production,
  'assessment-stage.ethara.ai': AppEnvironment.stage,
  'localhost': AppEnvironment.local,
  '127.0.0.1': AppEnvironment.local,
  '[::1]': AppEnvironment.local,
  '::1': AppEnvironment.local,
};

/// Backend origin a local build is normally pointed at, for documentation and
/// for the Makefile to agree with. NOT applied automatically - see the note on
/// localhost in the library comment.
const String kLocalBackendUrl = 'http://localhost:8069';

/// Database a local Odoo is normally served from, paired with
/// [kLocalBackendUrl]. NOT `ethara_ops`: that was a deleted private checkout's
/// database and it still carries that checkout's shape, so this addon cannot
/// load there.
const String kLocalApiDb = 'etp_local';

/// The environment [host] is served from, or [AppEnvironment.unknown].
///
/// Case-insensitive because a hostname is, and a browser will hand back
/// whatever case the user typed.
AppEnvironment environmentForHost(String? host) {
  final String h = (host ?? '').trim().toLowerCase();
  if (h.isEmpty) return AppEnvironment.unknown;
  return kHostEnvironments[h] ?? AppEnvironment.unknown;
}

/// The `API_BASE_URL` value that means "the origin this page was served from".
const String kSameOrigin = 'same-origin';

/// Resolve the whole profile for a page loaded at [pageUrl].
///
/// Pure, and takes the URL as an argument rather than reading `Uri.base`, so
/// the table can be tested on the VM where `Uri.base` is a `file://` path.
///
/// [baseUrlOverride] and [dbOverride] are the build-time defines, passed in for
/// the same reason.
EnvironmentProfile resolveEnvironment(
  Uri pageUrl, {
  String baseUrlOverride = kApiBaseUrlOverride,
  String dbOverride = kApiDbOverride,
}) {
  final AppEnvironment env = environmentForHost(pageUrl.host);
  final String override = baseUrlOverride.trim();

  // Rule 1. An explicit define wins, but the ENVIRONMENT is still reported
  // from the host: `make serve-stage` really is a stage bundle, and labelling
  // it "unknown" would make the console's own backend readout useless.
  if (override.isNotEmpty) {
    return EnvironmentProfile(
      environment: env,
      // Yantra: `same-origin` means the API is proxied on the page's own
      // origin (Yantra's nginx), so one bundle serves any host.
      apiBaseUrl: override == kSameOrigin
          ? pageUrl.origin
          : _stripTrailingSlashes(override),
      apiDb: dbOverride.trim(),
    );
  }

  // Rule 2 and 3. `kEnvironmentProfiles` carries the same-origin fallback as
  // its `unknown` entry, so there is no third branch to get wrong.
  return kEnvironmentProfiles[env]!;
}

String _stripTrailingSlashes(String url) => url.replaceAll(RegExp(r'/+$'), '');

/// The profile for THIS page load.
///
/// Resolved once and cached. `Uri.base` changes as the app navigates - that is
/// why `main.dart` reads the exam token from it exactly once - and while the
/// host cannot change under a SPA, re-deriving on every media URL would make
/// the backend a moving target for no benefit.
final EnvironmentProfile activeEnvironment = _resolveActiveEnvironment();

/// [resolveEnvironment] against `Uri.base`, but it may not throw.
///
/// EVERY read of `kApiBaseUrl` goes through this lazy initialiser, so an
/// exception here is not a wrong backend - it is a blank screen, on every route,
/// with the failure reported at whatever line first touched the client. Dart
/// re-throws a failed lazy initialisation on each subsequent read, so there
/// would be no recovery and no useful stack.
///
/// `Uri.base` is the part that can throw: it needs a document base URL, and an
/// embedder that has none (a worker context, an unusual host page) raises
/// UnsupportedError rather than returning something. That is remote in this
/// app's topology, which is exactly why it is worth three lines instead of a
/// production incident.
///
/// The fallback still honours an explicit define, because a pinned bundle knows
/// its backend without asking the page where it came from.
EnvironmentProfile _resolveActiveEnvironment() {
  try {
    return resolveEnvironment(Uri.base);
  } catch (_) {
    final String override = kApiBaseUrlOverride.trim();
    return EnvironmentProfile(
      environment: AppEnvironment.unknown,
      apiBaseUrl: _stripTrailingSlashes(override),
      apiDb: override.isEmpty ? '' : kApiDbOverride.trim(),
    );
  }
}
