// The HTTP client.
//
// It speaks to the Odoo addon `assessments_be_v2`, and its shape is dictated by
// what that addon exposes - not by what this app would find convenient.
//
// THIS HEADER WAS PRE-FORK AND WRONG IN THREE WAYS until corrected. It named
// `etp_assessment_pro` (decommissioned), cited a path
// `../../odoo_addon/etp_assessment_api` that does not exist, and claimed the
// module had no admin routes to wrap. `lib/config.dart` already carried the
// correction; this file did not. Kept as a note because a wrong header is worse
// than none - it sent readers to a module that no longer serves any of this.
//
// Two surfaces:
//
//   CANDIDATE - `/api/v1/me/*` and `/api/v1/exam/<token>/*`. There is also a
//   server-rendered fallback on nine `/pro_assessment/*` and `/my/pro_*` paths.
//   Those are NOT stock Odoo: `assessments_be_v2` serves them itself and
//   deliberately shadows upstream's routes of the same name while both modules
//   are installed (see the addon's `__manifest__.py`). This client uses the
//   JSON API, not the rendered pages.
//
//   ADMIN - `/api/v1/*` under `controllers/api/admin.py` and `write.py`. The
//   addon has a full JSON admin surface; the Odoo backend views are a second
//   way into the same models, not the only one.
//
// Anything this client cannot reach is a deliberate gap, not an oversight: if
// a call is not here, the addon does not offer it.
import 'dart:async' show Completer;
import 'dart:convert';
import 'dart:math' show Random;

import 'package:http/http.dart' as http;

import '../domain/enums.dart';
import '../../services/exam_session_stub.dart'
    if (dart.library.js_interop) '../../services/exam_session_web.dart';
import '../../services/seb_stub.dart'
    if (dart.library.js_interop) '../../services/seb_web.dart'
    as seb;
import '../../services/token_store_stub.dart'
    if (dart.library.js_interop) '../../services/token_store_web.dart';
import 'environment.dart';

// Re-exported so a caller that already imports this client can read which
// deployment it resolved to without also importing `environment.dart`. The
// resolution table itself is NOT re-exported: it has one consumer, and a second
// path to it is a second thing to keep in step.
export 'environment.dart' show AppEnvironment, EnvironmentProfile;

/// Where the Odoo instance lives.
///
/// NOT a compile-time constant any more. It is derived from the host this
/// bundle is being served from, with `--dart-define=API_BASE_URL` as an
/// override - see `environment.dart` for the table and the precedence. As a
/// `const` it made the backend a property of the build, so an image promoted
/// from stage to production kept calling stage and nothing on the server side
/// looked wrong.
///
/// Still a top-level final, so every existing read is unchanged.
final String kApiBaseUrl = activeEnvironment.apiBaseUrl;

/// The database name. Odoo needs it on the login call when more than one
/// database is served. Empty on stage and production, which sign in through
/// the bearer gateway and name no database.
final String kApiDb = activeEnvironment.apiDb;

/// Which deployment this bundle decided it is running in.
AppEnvironment get kAppEnvironment => activeEnvironment.environment;

/// Which backend generation to talk to. The API surface is versioned by path
/// prefix, so switching module is a build flag rather than a code change:
///   assessments_be_v2      -> /api/v1  (default)
///   etp_assessment_pro_v2  -> /api/v2
const String kApiPrefix = String.fromEnvironment(
  'API_PREFIX',
  defaultValue: '/api/v1',
);

/// Prefix of the media proxies, which each addon registers under its own name.
///   assessments_be_v2      -> /assessments_be
///   etp_assessment_pro_v2  -> /etp_assessment_pro_v2
const String kMediaPrefix = String.fromEnvironment(
  'MEDIA_PREFIX',
  defaultValue: '/assessments_be',
);

/// Sign-in lives in a DIFFERENT addon. `auth_token`, `refresh_token` and
/// `auth_token_unlink` are served by `api_auth_gateway`, which every assessment
/// backend depends on and which registers them at /api/v1 whatever this client
/// is pointed at. Versioning them alongside the assessment API sends the login
/// to a route nobody serves, and the app reports the server as unreachable.
const String kGatewayPrefix = String.fromEnvironment(
  'GATEWAY_PREFIX',
  defaultValue: '/api/v1',
);

/// True when the app was built with a backend to talk to. When false the app
/// runs on its bundled seed, which is the default for design review.
bool get hasBackend => kApiBaseUrl.isNotEmpty;

/// Make a server-relative media path absolute against the ODOO origin.
///
/// Every media URL the API returns is relative - `question_media` sends
/// `/assessments_be/exam/qimage/<token>/<id>`, and the admin bank sends
/// `/assessments_be/admin_qimage/<id>`. Handed to `Image.network` as-is those
/// resolve against the APP's origin (`:8200` under `make serve`), not Odoo's,
/// so every stimulus 404'd and each question rendered with an empty panel.
///
/// The candidate routes are `auth="public"` and scoped by the token IN the
/// path, so no header or cookie is needed - absolutising is the whole fix.
///
/// Left alone: `data:` payloads (the module inlines rendered images) and
/// anything already absolute.
String resolveMediaUrl(String? src) {
  if (src == null || src.isEmpty) return '';
  if (src.startsWith('data:') || src.startsWith('http')) return src;
  if (kApiBaseUrl.isEmpty) return src;
  return '$kApiBaseUrl$src';
}

/// True when [url] is served by OUR backend, so our credential belongs on it.
///
/// THE POINT IS TO KNOW WHEN TO SEND NOTHING. A media fetch that carries the
/// `Authorization` header can only ever be an XHR: an `<img>` element cannot
/// carry headers, so Flutter skips the element path entirely once headers are
/// set (`_network_image_web.dart`, `containsNetworkImageHeaders`). An XHR then
/// needs the far host to send `Access-Control-Allow-Origin`, which almost no
/// third-party image host does - so sending our bearer to someone else's CDN
/// does not just fail to help, it is what STOPS the picture rendering.
///
/// Two topologies, one test. With a non-empty [kApiBaseUrl] (a dev bundle, or
/// stage) [resolveMediaUrl] has already prefixed our own paths with it. With an
/// empty one (same-origin production) our paths stay relative, so a leading
/// slash is the tell. Mirrors `_isOurOrigin` in `video_plate_web.dart`, which
/// makes the identical decision for a clip - it cannot be shared FROM there,
/// because that file is behind `if (dart.library.js_interop)` and this is
/// needed on the VM too.
bool isOurMediaOrigin(String url) {
  final String u = url.trim();
  if (u.isEmpty || u.startsWith('data:')) return false;
  return kApiBaseUrl.isEmpty ? u.startsWith('/') : u.startsWith(kApiBaseUrl);
}

Map<String, String> _mediaAuthHeaders = const <String, String>{};

/// The credential an ADMIN media GET has to carry, published by [ApiClient].
///
/// The candidate media routes are `auth="public"` and scoped by the token in
/// the path, so they need nothing. The admin proxies
/// (`/assessments_be/admin_qimage/<id>`) are `auth="user"`, and this app signs
/// in with a BEARER token precisely so it needs no cookie - `ir_http` already
/// accepts that bearer on the admin-media prefix and already allows the
/// `Authorization` header through CORS.
///
/// What was missing is this last hop. `Image.network(url)` with no headers
/// sends none, and a cross-origin XHR does not attach cookies either, so every
/// bank image came back 401 and rendered as the "has not rendered" empty state
/// over a picture the server was holding. A `<video>` element is a plain
/// subresource fetch that carries the browser's own cookie, which is why the
/// clips played while the stills did not - and why it only looked fixed on a
/// machine that happened to be signed into Odoo in another tab.
///
/// Empty when signed out, which keeps `Image.network` on its element path.
Map<String, String> get mediaAuthHeaders => _mediaAuthHeaders;

/// A failure that carries the module's own words.
///
/// The API answers a domain refusal ("This draft carries a blocking warning")
/// with `ok:false` and a 4xx, and a transport failure with a non-JSON body.
/// `isDomain` tells them apart: a domain refusal is text to show the user
/// verbatim, a transport failure is something to retry or report.
///
/// [code] is the machine-readable half of a refusal. Branch on it; the
/// [message] is written for a person and may be reworded at any time.
/// What a redeemed Yantra launch ticket opens: a sitting ([examToken]) or, for
/// staff, a page ([next]); and where "Back to Yantra" goes ([returnUrl]).
class LaunchGrant {
  const LaunchGrant({this.examToken, this.next, this.returnUrl});

  final String? examToken;
  final String? next;
  final String? returnUrl;
}

class ApiError implements Exception {
  final String message;
  final bool isDomain;

  /// The request never got an answer: connection refused, DNS, CORS, timeout.
  ///
  /// Distinct from [isDomain] and from any status: there is no server verdict
  /// to report. It is the one failure worth replaying unchanged, because the
  /// same call will start working the moment the host is back.
  final bool isTransport;

  /// The raw cause, for a developer. Never shown to a user.
  final String? detail;

  final int? status;
  final String? code;

  /// How long the server asked us to wait, from its `Retry-After` header.
  ///
  /// Only ever set on a shed response (503, or a 429). Honoured in preference to
  /// the client's own backoff: a server under load knows better than we do when
  /// it will be ready, and ignoring it is how a retry ladder turns a recovery
  /// into a second wave.
  final Duration? retryAfter;

  /// Whatever else the refusal carried, beside the envelope.
  ///
  /// `fail()` merges its keyword arguments into the TOP level of the body -
  /// `{"ok": false, "error": {...}, "candidate_count": 12}` - and some
  /// refusals are not errors so much as answers: the delete route's
  /// `confirm_required` IS the preview of what a confirmed delete would
  /// destroy, and `live_attempts` carries how many people are mid-sitting.
  /// Without these the client would have to re-derive numbers the server has
  /// already counted, and the sentence an operator confirms would be computed
  /// by different code from the work it authorises.
  final Map<String, dynamic> fields;

  const ApiError(
    this.message, {
    this.isDomain = false,
    this.isTransport = false,
    this.detail,
    this.status,
    this.code,
    this.retryAfter,
    this.fields = const <String, dynamic>{},
  });

  /// One of [fields] as an int, or [fallback] when the server did not send it.
  int intField(String key, [int fallback = -1]) {
    final Object? v = fields[key];
    return v is num ? v.toInt() : fallback;
  }

  /// Worth sending again UNCHANGED.
  ///
  /// THE STATUS DECIDES, NOT `isDomain`. That distinction is the whole fix and
  /// it is easy to get backwards: the module's own crash handler answers
  /// `fail("server_error", ..., status=500)`, which is `{"ok": false}` at 500
  /// (`controllers/api/common.py`), so `isDomain` is set on a genuine server
  /// error too. Gating retry on `!isDomain` therefore refuses to replay exactly
  /// the 14,759 answer-route 500s of 2026-09-03 - the case this ladder exists
  /// for. A first version of this getter did that.
  ///
  /// A 5xx or a shed 429 means the server did not get to decide, so the same
  /// bytes will succeed once it recovers. Every refusal this module raises on
  /// purpose is a 4xx, so status alone separates them cleanly.
  ///
  /// 409 is deliberately NOT retryable: the attempt was already settled, which
  /// is a race we lost and one the callers already treat as benign. Replaying it
  /// would only earn the same 409.
  bool get isRetryable {
    if (isTransport) return true;
    final int? s = status;
    if (s == null) return false;
    return s >= 500 || s == 429;
  }

  /// What a CANDIDATE is told. A transport failure's [message] is written for
  /// whoever runs the server - it names the host and CORS - and someone
  /// sitting an exam can only check their connection, so they are told that.
  /// Admin screens and the logs keep [message].
  String get candidateMessage => isTransport ? kNoConnection : message;

  @override
  String toString() => message;
}

/// The candidate's sentence for a request that got no answer at all.
///
/// "On this page", not "on this device": the answers live in the open tab's
/// memory until the server takes them, and a reload loses what has not
/// reached it yet - after a failed save nothing else warns before one.
const String kNoConnection =
    'No connection. Your answers are kept on this page, so do not reload it. '
    'Try again when you are back online.';

/// `Retry-After`, as a duration, or null when absent or unusable.
///
/// DELTA-SECONDS ONLY, on purpose. RFC 9110 also allows an HTTP-date, but
/// parsing that needs `HttpDate` from `dart:io`, which does not exist on web -
/// and this app's shipping target IS web. Odoo and nginx both emit
/// delta-seconds for a shed 503, so the date form is a hypothetical we would be
/// importing a platform break to serve. When one does arrive we return null and
/// the caller's own jittered backoff takes over, which is a correct fallback
/// rather than a failure.
///
/// Zero, negative and absurd values yield null for the same reason: a header we
/// cannot trust is worse than our own backoff, and a `0` would turn a shed
/// response into an immediate re-send - exactly the herd the header exists to
/// prevent.
Duration? parseRetryAfter(String? raw) {
  final String v = (raw ?? '').trim();
  if (v.isEmpty) return null;
  final int? secs = int.tryParse(v);
  if (secs == null || secs <= 0 || secs > 300) return null;
  return Duration(seconds: secs);
}

/// One rung of the retry ladder, announced before it is slept through.
///
/// EXISTS SO THE WAIT CAN BE SEEN. `toaster.busy('Submitting your exam...')`
/// never expires and cannot be dismissed, so every second the ladder spends
/// asleep looks exactly like a hung app to the candidate sitting in front of
/// it. Handing the caller the numbers - which try, of how many, how long, how
/// long already - lets it say so, and [cancel] lets the candidate stop waiting
/// without the client pretending the work is still in flight.
///
/// [cancel] ends the LADDER, not the attempt already sent: the call fails with
/// the server's own last error, exactly as it would have when the attempts ran
/// out. Answers are saved one-by-one on the server, so stopping the ladder
/// costs a retry, not a paper.
class RetryNotice {
  /// The attempt that just failed, 1-based.
  final int attempt;

  /// [ApiClient.maxAttempts], so a caller can say "try 2 of 5".
  final int of;

  /// How long the ladder is about to sleep - already clipped to whatever the
  /// budget has left, so this is the real number to show a person.
  final Duration wait;

  /// How long this call has spent waiting so far, [wait] included.
  final Duration spent;

  final void Function() cancel;

  const RetryNotice({
    required this.attempt,
    required this.of,
    required this.wait,
    required this.spent,
    required this.cancel,
  });
}

class ApiClient {
  final http.Client _http;
  final String base;

  /// THE RETRY LADDER. Attempts, not retries: 1 means "no retry".
  ///
  /// On 2026-09-03 the server returned 14,759 HTTP 500s on the answer route and
  /// this client re-issued NONE of them - `_syncAnswer` warned once and dropped
  /// the payload. Postgres-per-save is what made that incident lose zero
  /// answers, and that floor only protects answers that ARRIVE. So a shed or
  /// failed write is now replayed rather than discarded.
  final int maxAttempts;

  /// Base delay, doubled per attempt, with jitter added on top.
  final Duration retryBackoff;

  /// THE CEILING ON TIME SPENT ASLEEP across one call's whole ladder.
  ///
  /// `parseRetryAfter` accepts up to 300s and [maxAttempts] is 5, so a server
  /// shedding with `Retry-After: 300` bought four sleeps of five minutes -
  /// TWENTY MINUTES of silence behind "Submitting your exam...", a toast that
  /// by design never expires and cannot be dismissed. A candidate cannot tell
  /// that from a hang, and would reload the page long before it resolved.
  ///
  /// This does NOT cut the ladder back to one shot: the ladder is what stopped
  /// the 2026-09-03 answer loss, and trading it for responsiveness would be
  /// trading a candidate's work for a faster error. Attempts are unchanged; only
  /// the waiting between them is bounded, and the last wait is CLIPPED to what
  /// is left rather than skipped, so the budget is spent trying rather than
  /// abandoned part-way.
  final Duration retryBudget;

  /// Told before each rung of the write ladder sleeps. Null means nobody is
  /// watching, which is the case for every caller that is not a UI.
  ///
  /// Mutable, and set by whoever owns the screen: the client is built long
  /// before there is a toaster to narrate into. See [RetryNotice].
  void Function(RetryNotice)? onRetryWait;

  /// Injected so tests do not sleep for real. Production passes null.
  final Future<void> Function(Duration)? _sleep;

  /// Jitter source, injected for determinism in tests.
  final double Function()? _jitter;

  /// Odoo authenticates with a session cookie. It is held here rather than in
  /// a global so a test can drive two sessions at once.
  String? _session;

  /// The bearer token from `api_auth_gateway`, when that path signed in.
  ///
  /// Held separately from [_session] because the two are different auth
  /// systems, and which one is set decides how a request is signed and which
  /// logout route ends it.
  String? _bearer;

  /// The gateway's refresh token. Stored so a long exam sitting can renew
  /// rather than expiring mid-answer.
  String? _refresh;

  /// The Safe Exam Browser proof (`seb_url`, `seb_key`) every candidate exam
  /// call carries; empty outside SEB. Injected so a VM test can play SEB.
  final Map<String, String> Function() _sebProof;

  ApiClient({
    http.Client? client,
    String? baseUrl,
    String? bearer,
    this.maxAttempts = 5,
    this.retryBackoff = const Duration(milliseconds: 400),
    this.retryBudget = const Duration(seconds: 60),
    this.onRetryWait,
    Future<void> Function(Duration)? sleep,
    double Function()? jitter,
    Map<String, String> Function()? sebProof,
  }) : _http = client ?? http.Client(),
       _bearer = bearer,
       _sleep = sleep,
       _jitter = jitter,
       _sebProof = sebProof ?? seb.sebProof,
       base = (baseUrl ?? kApiBaseUrl).replaceAll(RegExp(r'/+$'), '') {
    _publishMediaCredential();
  }

  /// How long to wait before attempt [attempt] (1-based, so 1 is the retry
  /// after the first failure).
  ///
  /// The server's own `Retry-After` wins outright. Otherwise: exponential
  /// backoff with at least 10% jitter. The jitter is not decoration - 1,000
  /// candidates whose writes all failed in the same second would otherwise all
  /// retry in the SAME later second, which is a thundering herd aimed at a
  /// server that has just told us it is struggling.
  Duration _retryDelay(int attempt, Duration? serverAsked) {
    if (serverAsked != null) return serverAsked;
    final int ms = retryBackoff.inMilliseconds * (1 << (attempt - 1));
    final double r = (_jitter ?? Random().nextDouble)();
    return Duration(milliseconds: (ms * (1.0 + 0.1 + 0.4 * r)).round());
  }

  /// Mirror the bearer out to [mediaAuthHeaders] for image/video widgets.
  ///
  /// The token stays an instance field - a test drives two sessions at once -
  /// but a widget deep in the tree has no client to ask, so the credential is
  /// republished on every change instead of being read back through the store.
  void _publishMediaCredential() {
    final String? b = _bearer;
    _mediaAuthHeaders = (b == null || b.isEmpty)
        ? const <String, String>{}
        : <String, String>{'Authorization': 'Bearer $b'};
  }

  /// Adopt the tokens a previous page load stored.
  ///
  /// A browser refresh restarts the Dart VM, so a token held only in [_bearer]
  /// vanished and the app showed the login form over a session the server still
  /// considered open. Called before the first frame; returns whether there is a
  /// token worth verifying, so the caller knows to confirm it with `/auth/me`
  /// rather than trusting stored bytes.
  ///
  /// A bearer supplied to the CONSTRUCTOR counts. The host portal injects one
  /// that way, and so does a test; reading only the store would have made this
  /// answer "nothing to resume" while holding a perfectly good token.
  bool restoreTokens() {
    final StoredSession? s = loadSession();
    if (s != null) {
      _bearer = s.bearer;
      _refresh = s.refresh.isEmpty ? null : s.refresh;
      _publishMediaCredential();
      return true;
    }
    final String? existing = _bearer;
    return existing != null && existing.isNotEmpty;
  }

  /// Restart the stored session's idle window.
  ///
  /// Called once the server has CONFIRMED the token, not when it is merely
  /// found: a stored token that `/auth/me` rejects should be allowed to age
  /// out, not have its clock reset by the failed attempt to use it.
  void touchStoredSession() => touchSession();

  /// Persist the current tokens, or wipe them when signed out.
  ///
  /// Every bearer change runs through here, so this is also where the media
  /// credential is refreshed - a token that rotated mid-exam must not leave
  /// images authenticating with the retired one.
  void _persistTokens() {
    _publishMediaCredential();
    final String? b = _bearer;
    if (b == null || b.isEmpty) {
      clearSession();
    } else {
      saveSession(b, _refresh ?? '');
    }
  }

  bool get isAuthenticated => _session != null || _bearer != null;

  /// A refresh token is held. Only the gateway's 401 retires one, so a
  /// renewal that failed while this stays true got no verdict on it.
  bool get canRenew => (_refresh ?? '').isNotEmpty;

  Map<String, String> get _headers => <String, String>{
    'Content-Type': 'application/json',
    if (_bearer != null) 'Authorization': 'Bearer $_bearer',
    if (_session != null) 'Cookie': 'session_id=$_session',
  };

  /// Every route is Odoo 19's `json2` dispatcher: a plain JSON body in, a
  /// plain JSON body out, and a REAL HTTP status code.
  ///
  /// Not JSON-RPC. The legacy `type='json'` would force every call to be
  /// wrapped in `{"jsonrpc":"2.0","method":"call","params":{...}}` and would
  /// return 200 even for failures, which leaves a mobile client unable to tell
  /// "the server refused" from "the request never arrived". `json2` also reads
  /// only the BODY and ignores the query string, so filters and paging are
  /// sent as body fields even on a read.
  ///
  /// One guarded retry after refreshing an expired bearer.
  ///
  /// `refreshSession` existed and was called from exactly one place - cold
  /// start. So a token that expired WHILE the app was open was terminal: every
  /// autosave during an exam failed, and `_syncAnswer` only debugPrints, so the
  /// candidate saw nothing until submit failed. A 45-minute sitting outlasting
  /// a token is the ordinary case, not the edge case.
  ///
  /// Three guards. `allowRetry: false` on the replay, so a permanently rejected
  /// token cannot loop. `/api/v1/auth*` excluded, so a wrong password is never
  /// retried. And a refresh token must exist - the cookie path has none.
  ///
  /// THE PATH EXCLUSION IS NOT WHAT KEEPS `refreshSession` OUT OF THIS HOOK, and
  /// assuming it was cost a crashed browser tab: `refresh_token` sits BESIDE
  /// `auth*` rather than under it, so the prefix test never matched it and the
  /// renewal call refreshed itself in a loop. `refreshSession` now passes
  /// `allowRetry: false` explicitly. Anything else added here that renews or
  /// exchanges a credential has to do the same.
  Future<Map<String, dynamic>> _call(
    String path, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) => _send(path, params, allowRetry: true);

  /// [_call], but a shed or crashed server gets replayed instead of dropped.
  ///
  /// SCOPED TO THE CANDIDATE WRITE PATH, deliberately. A retry ladder is the
  /// right answer when losing the call loses a candidate's work, and the wrong
  /// answer everywhere else: applied to every call it also delays every ADMIN
  /// screen by the full backoff before showing an error, which is a worse
  /// console for a human who is sitting there watching it. A first version of
  /// this wrapped `_call` itself and turned one console test from instant into
  /// eight seconds - the same latency a real operator would have eaten.
  ///
  /// It wraps `_send` rather than living inside it so the 401-refresh replay
  /// stays exactly one guarded retry: that path already re-enters `_send` with
  /// `allowRetry: false`, and nesting a ladder inside it would multiply the two
  /// into 5x the auth traffic against a dead token.
  Future<Map<String, dynamic>> _callWithRetry(
    String path, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) async {
    Duration spent = Duration.zero;
    final Completer<void> stopped = Completer<void>();
    for (int n = 1; ; n++) {
      try {
        return await _send(path, params, allowRetry: true);
      } on ApiError catch (e) {
        if (!e.isRetryable || n >= maxAttempts) rethrow;

        // TIME, NOT JUST TRIES. Counting attempts alone let one honoured
        // `Retry-After: 300` turn a submit into a twenty-minute stare - see
        // [retryBudget]. What is left of the budget is both the gate and the
        // cap: nothing is skipped, it is only shortened.
        final Duration left = retryBudget - spent;
        if (left <= Duration.zero) rethrow;
        final Duration asked = _retryDelay(n, e.retryAfter);
        final Duration wait = asked > left ? left : asked;
        spent += wait;

        onRetryWait?.call(
          RetryNotice(
            attempt: n,
            of: maxAttempts,
            wait: wait,
            spent: spent,
            cancel: () {
              if (!stopped.isCompleted) stopped.complete();
            },
          ),
        );
        if (stopped.isCompleted) rethrow;

        if (_sleep != null) {
          await _sleep(wait);
        } else {
          // `Future.any`, so a cancel lands DURING the sleep rather than after
          // it. A 60s wait that only notices the cancel when it is over is not
          // cancellable, it is just slow.
          await Future.any(<Future<void>>[
            Future<void>.delayed(wait),
            stopped.future,
          ]);
        }
        if (stopped.isCompleted) rethrow;
      }
    }
  }

  Future<Map<String, dynamic>> _send(
    String path,
    Map<String, dynamic> params, {
    required bool allowRetry,
    Map<String, String>? as,
  }) async {
    final Uri uri = Uri.parse('$base$path');
    final String? sentWith = _bearer;
    late final http.Response res;
    try {
      // [as]: the headers of somebody this client has ALREADY forgotten (see
      // [logout]). Such a reply must not change this client's own state.
      res = await _http.post(
        uri,
        headers: as ?? _headers,
        body: jsonEncode(params),
      );
    } on Exception catch (e) {
      // NAMES THE HOST, NOT THE PATH. A refresh fires nine calls at once and
      // whichever lost the race named the banner - always /api/v1/assessments,
      // since it is first in that `Future.wait` - so "the backend is down" read
      // as "the assessments endpoint is broken", and people went looking at a
      // route that was perfectly healthy. The unreachable host is the fact; the
      // path that happened to notice first is noise. The cause is kept in
      // `detail` rather than the message: `ClientException: Failed to fetch` is
      // the browser's way of saying nothing answered, and pasting it in front
      // of an operator only invites a bug report about fetch.
      // "OR DOES NOT KNOW THIS ROUTE", because in a browser those two are the
      // same failure. Odoo answers an unregistered path with an HTML 404 that
      // carries no `Access-Control-Allow-Origin` - CORS headers are set by the
      // API routes themselves - so the browser refuses the response and this
      // client is handed a bare `Failed to fetch`, indistinguishable from a
      // dead host. Naming only the host sent people to check a server that was
      // running perfectly and was simply one restart behind the client.
      throw ApiError(
        'Could not reach the server at $base. Either nothing answered, or it '
        'answered without permission for this origin - a route the running '
        'server does not know, or a CORS origin it has not been told about, '
        'look identical from here.',
        isTransport: true,
        detail: '$uri: $e',
      );
    }

    if (as == null) _captureSession(res);

    Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } on FormatException {
      // A non-JSON body means the request never reached the API - a proxy
      // error page, or Odoo's HTML login redirect on an expired session.
      throw ApiError(
        res.statusCode == 401 || res.statusCode == 403
            ? 'Your session has expired. Sign in again.'
            : 'Unexpected response from $path',
        status: res.statusCode,
        // A shed 503 is an HTML proxy page as often as JSON, so the header has
        // to be read on THIS path too - it is the one that fires when a load
        // balancer, not Odoo, is doing the shedding.
        retryAfter: parseRetryAfter(res.headers['retry-after']),
      );
    }

    // The envelope is `{"ok": bool, ...}`. A refusal nests its reason under
    // `error`: `{"ok": false, "error": {"code": ..., "message": ...}}`.
    //
    // Reading `message` from the TOP level looks right and is not - the key
    // is not there, so the fallback fired and the user was shown a stringified
    // Dart map ("{code: missing_target, message: ...}") instead of the
    // sentence the module wrote for them. Some paths do answer flat, so both
    // shapes are accepted.
    if (res.statusCode == 401 &&
        allowRetry &&
        _refresh != null &&
        !path.startsWith('$kApiPrefix/auth') &&
        !path.startsWith('$kGatewayPrefix/auth')) {
      // ONE RENEWAL PER EXPIRY. The gateway rotates the access token on every
      // refresh, so each extra refresh kills the token the last one handed
      // out. A call whose bearer was already renewed while it was on the wire
      // just retries with the new one; the rest share `refreshSession`'s one
      // renewal. See `one_refresh_serves_every_expired_call_test.dart`.
      if (_bearer != sentWith || await refreshSession()) {
        return _send(path, params, allowRetry: false);
      }
    }

    if (body['ok'] == false || res.statusCode >= 400) {
      final Object? err = body['error'];
      final Map<String, dynamic> detail = err is Map<String, dynamic>
          ? err
          : const <String, dynamic>{};

      final Object? message =
          detail['message'] ?? body['message'] ?? (err is String ? err : null);

      throw ApiError(
        (message ?? 'Request failed').toString(),
        isDomain: body['ok'] == false,
        status: res.statusCode,
        code: (detail['code'] ?? body['code']) as String?,
        retryAfter: parseRetryAfter(res.headers['retry-after']),
        // Everything the refusal carried besides the envelope itself. See
        // [ApiError.fields]: some refusals are the answer, not the failure.
        fields: <String, dynamic>{
          for (final MapEntry<String, dynamic> e in body.entries)
            if (e.key != 'ok' && e.key != 'error') e.key: e.value,
        },
      );
    }

    final Object? data = body['data'];
    return data is Map<String, dynamic> ? data : body;
  }

  void _captureSession(http.Response res) {
    // Only on a SUCCESSFUL response.
    //
    // Odoo sets a session cookie on failures too - it tracks anonymous
    // visitors - so capturing unconditionally marked the client
    // "authenticated" after a rejected login, and the router's auth gate would
    // then wave that user straight into the app. The cookie exists; it just is
    // not a signed-in one.
    if (res.statusCode < 200 || res.statusCode >= 300) return;

    final String? raw = res.headers['set-cookie'];
    if (raw == null) return;
    final RegExpMatch? m = RegExp(r'session_id=([^;]+)').firstMatch(raw);
    if (m != null) _session = m.group(1);
  }

  // ── Session ────────────────────────────────────────────────────────────

  /// Signs in and returns the caller's role.
  ///
  /// TWO auth paths, tried in this order, because this app runs against two
  /// kinds of deployment:
  ///
  ///   1. `api_auth_gateway`'s `/api/v1/auth_token` - a BEARER token. This is
  ///      what the rest of the Ethara frontend already uses
  ///      (`lib/services/api_client.dart`), so signing in here means signing in
  ///      to the same session the workflow app holds. Preferred: a bearer token
  ///      needs no cookie, so no credentialed-CORS rules apply.
  ///   2. `assessments_be_v2`'s own `/api/v1/auth/session` - an Odoo session
  ///      COOKIE. Kept for a standalone deployment where the gateway addon is
  ///      not installed. (This said `etp_assessment_pro`; the route is served
  ///      by `controllers/api/auth.py` in the fork.)
  ///
  /// The role is decided SERVER-side either way; it is never sent by the
  /// client. A field on the login form could be edited, and the whole point of
  /// the two portals is that the server decides which one you get.
  Future<Map<String, dynamic>> login(String login, String password) async {
    try {
      return await _loginGateway(login, password);
    } on ApiError catch (e) {
      // A 404 means the gateway addon is absent; anything else is a real
      // refusal (wrong password) and must not be retried against a second
      // endpoint, or a user with a typo gets two failed attempts logged.
      if (e.status != 404) rethrow;
      return _loginModule(login, password);
    }
  }

  /// `api_auth_gateway`: bearer token, `type='http'`, form-encoded body.
  Future<Map<String, dynamic>> _loginGateway(
    String login,
    String password,
  ) async {
    final Map<String, dynamic> res = await _call(
      '$kGatewayPrefix/auth_token',
      <String, dynamic>{'login': login, 'password': password},
    );

    final String token = (res['access_token'] ?? '').toString();
    if (token.isEmpty) {
      throw ApiError(
        (res['message'] ?? 'Sign in failed').toString(),
        isDomain: true,
      );
    }

    _bearer = token;
    _refresh = (res['refresh_token'] ?? '').toString();
    _persistTokens();
    return <String, dynamic>{'user': res};
  }

  /// `assessments_be_v2`: Odoo session cookie.
  Future<Map<String, dynamic>> _loginModule(String login, String password) =>
      _call('$kApiPrefix/auth/session', <String, dynamic>{
        if (kApiDb.isNotEmpty) 'db': kApiDb,
        'login': login,
        'password': password,
      });

  Future<Map<String, dynamic>> whoAmI() => _call('$kApiPrefix/auth/me');

  /// Yantra: trade a one-time launch ticket for a bearer (see
  /// `lib/yantra_launch.dart`). Sent with no credential, never retried: a
  /// ticket is spent by the first call that reaches the server. The bearer
  /// has no refresh token; when it lapses, the person goes back through
  /// Yantra.
  Future<LaunchGrant> redeemLaunchTicket(String ticket) async {
    final Map<String, dynamic> res = await _send(
      '$kApiPrefix/yantra/launch/redeem',
      <String, dynamic>{'ticket': ticket},
      allowRetry: false,
      as: const <String, String>{'Content-Type': 'application/json'},
    );
    final String token = (res['access_token'] ?? '').toString();
    if (token.isEmpty) {
      throw ApiError('The launch link gave no session.', isDomain: true);
    }
    _session = null;
    _bearer = token;
    _refresh = null;
    _persistTokens();
    return LaunchGrant(
      examToken: _nonEmpty(res['exam_token']),
      next: _nonEmpty(res['next']),
      returnUrl: _nonEmpty(res['return_url']),
    );
  }

  static String? _nonEmpty(Object? v) {
    final String s = (v ?? '').toString();
    return s.isEmpty ? null : s;
  }

  /// Renews an expired bearer token without making the user sign in again.
  ///
  /// This matters most mid-exam: a sitting can run 45 minutes or more, and a
  /// token that expires while somebody is answering would otherwise throw away
  /// work. Only the gateway path has a refresh token; the cookie path has no
  /// equivalent, so it returns false and the caller falls back to signing in.
  ///
  /// Returns true when the session was renewed.
  ///
  /// Concurrent callers share one renewal: see the 401 hook in [_send].
  Future<bool> refreshSession() =>
      _renewing ??= _renew().whenComplete(() => _renewing = null);

  Future<bool>? _renewing;

  Future<bool> _renew() async {
    final String? token = _refresh;
    if (token == null || token.isEmpty) return false;

    try {
      // `_send(allowRetry: false)`, NEVER `_call`, AND THIS IS NOT A STYLE
      // CHOICE - it is what stops this method calling itself forever.
      //
      // `_send`'s 401 hook re-runs the request after `refreshSession()`, and it
      // exempts only `<prefix>/auth*`. `refresh_token` is a SIBLING of those,
      // not a child: the path is `/api/v1/refresh_token`, which starts with
      // neither `/api/v1/auth` nor `<gateway>/auth`. So a refresh token the
      // gateway has already rejected produced:
      //
      //     _send(/refresh_token) -> 401 -> refreshSession()
      //       -> _call(/refresh_token) -> _send(/refresh_token) -> 401 -> ...
      //
      // unbounded, with a real HTTP request per cycle. Measured in a browser
      // against a stale token: 195 consecutive 401s on `/api/v1/refresh_token`
      // in a few seconds, and the TAB CRASHED. Every client holding a spent
      // refresh token does this to itself and to the backend on page load - and
      // a spent refresh token is ordinary, not exotic: it is what a password
      // change, a logout elsewhere, or plain expiry leaves behind.
      //
      // `allowRetry: false` removes the hook for this one call, which is exactly
      // right: a refusal here IS the terminal answer, and the `on ApiError`
      // below already turns it into "sign in again" by clearing both tokens.
      final Map<String, dynamic> res = await _send(
        '$kGatewayPrefix/refresh_token',
        <String, dynamic>{'refresh_token': token},
        allowRetry: false,
      );
      final String next = (res['access_token'] ?? '').toString();
      if (next.isEmpty) return false;
      // A logout or another sign-in while this was out: the pair it would
      // install, and SAVE, belongs to a session that has ended on this
      // device. Dropped, so a renewal can never undo a sign-out.
      if (_refresh != token) return false;

      _bearer = next;
      // The gateway may rotate the refresh token; keep the new one when it
      // does, or the NEXT renewal would present a token the server retired.
      final String rotated = (res['refresh_token'] ?? '').toString();
      if (rotated.isNotEmpty) _refresh = rotated;
      // Persist the renewal too: a reload after a mid-exam refresh would
      // otherwise restore the token the gateway has just retired.
      _persistTokens();
      return true;
    } on ApiError catch (e) {
      // NO ANSWER IS NOT A NO. A pod restart, or an ingress 502/503 with no
      // CORS headers, lands here too, and clearing on it sent every candidate
      // in the room to the login form at once. The tokens are as good as they
      // were, so they stay and the caller tries again (SEB review #7).
      if (e.isRetryable) rethrow;
      // A refusal here means the refresh token is spent or revoked. Say so
      // plainly rather than throwing: the caller's job is to ask for a
      // password, and an exception would look like a transport failure.
      //
      // The stored copy goes with it - keeping a token the server has rejected
      // means every later reload tries it again and fails the same way. Only
      // on the gateway's own refusal, its 401 ("Invalid Refresh Token"). Its
      // 400 is what ANY exception becomes there, a database error included
      // (`api_auth_gateway/controllers/main.py`), so it proves nothing.
      //
      // Only while it is still THIS session's token: somebody who signed in
      // while the renewal was out must not be signed out by its refusal.
      if (_refresh != token || e.status != 401) return false;
      _bearer = null;
      _refresh = null;
      _persistTokens();
      return false;
    }
  }

  /// Sets a new password on the signed-in account, and stays signed in.
  ///
  /// Adopting the credentials in the reply is not an optimisation, it is what
  /// makes the call survivable. The server ends EVERY credential this account
  /// holds when the password changes - Odoo derives its session token from the
  /// password hash, and the gateway unlinks every bearer token for a user whose
  /// password is written - so the token this client is holding is dead by the
  /// time the response arrives. Without the swap below, the next call 401s and
  /// the app drops the user on the login screen having just told them the
  /// change worked.
  ///
  /// Returns whether the client is still authenticated afterwards. False is a
  /// SUCCESS with a caveat: the password did change, and the caller should send
  /// the user to sign in again rather than report a failure they would act on
  /// by retrying with a password that already works.
  Future<bool> changePassword(
    String newPassword, {
    String? confirmPassword,
    String? currentPassword,
  }) async {
    final Map<String, dynamic> res =
        await _call('$kApiPrefix/auth/password', <String, dynamic>{
          'new_password': newPassword,
          'confirm_password': ?confirmPassword,
          'current_password': ?currentPassword,
        });

    final String token = (res['access_token'] ?? '').toString();
    if (token.isNotEmpty) {
      _bearer = token;
      final String rotated = (res['refresh_token'] ?? '').toString();
      if (rotated.isNotEmpty) _refresh = rotated;
      // Persisted for the same reason `refreshSession` persists: a reload
      // holding the retired token would fail the resume and look like a bug in
      // the password change.
      _persistTokens();
    }
    final String sid = (res['session_id'] ?? '').toString();
    if (sid.isNotEmpty) _session = sid;

    return res['reauthenticated'] == true;
  }

  Future<void> logout() async {
    // ONE ROUTE FOR BOTH LANES. The module's own logout now revokes the bearer
    // as well as destroying the session, so it no longer matters which
    // credential this client is holding.
    //
    // It used to branch, sending a bearer session to the gateway's
    // `auth_token_unlink`. That route is declared GET-only and reads a custom
    // `access_token` request header, while `_send` always POSTs and this client
    // only ever sends `Authorization: Bearer` - so the call was a 405, and
    // fixing the verb alone would have made it a 401. The `finally` below
    // swallowed it, so sign-out looked clean while the token stayed valid on
    // the server until it expired. The `finally` is right and stays; it was
    // only ever hiding a server-side no-op.
    //
    // THE DEVICE FORGETS FIRST, before the request goes out. Sign-out bounds
    // this call (a stalled connection must not hold a candidate at a shared
    // machine), and anything left for when the request ENDS is left for as
    // long as the server takes. Clearing in a `finally` kept the saved token
    // past the sign-out, so a reload in that window signed the next person in
    // as this one; keeping the credential in memory for the request let a
    // renewal racing the logout save a fresh token back. So the credential
    // leaves memory and the device now, and rides this ONE request as its own
    // headers ([_send]'s `as`), which also keeps the reply from touching
    // whoever has signed in by the time it lands.
    final Map<String, String> leavingAs = _headers;
    _session = null;
    _bearer = null;
    _refresh = null;
    _persistTokens();
    await _send(
      '$kApiPrefix/auth/logout',
      const <String, dynamic>{},
      allowRetry: true,
      as: leavingAs,
    );
  }

  // ── Candidate ──────────────────────────────────────────────────────────
  //
  // One method per real portal route. The bucketing, the results gating and
  // the "Awaiting results" copy all come from the server: `_single_item` in
  // candidate_portal.py decides them, and duplicating that logic here would
  // create a second place for the release rule to be wrong.

  /// The candidate's own attempts, bucketed available / in_progress /
  /// upcoming / completed / closed.
  Future<Map<String, dynamic>> myAssessments() =>
      _call('$kApiPrefix/me/assessments');

  /// Their KPIs. Released results only - an unreleased attempt contributes
  /// nothing, because it has no score yet to average.
  Future<Map<String, dynamic>> myDashboard() =>
      _call('$kApiPrefix/me/dashboard');

  /// Resolves a token to exactly one gate outcome: `invalid`,
  /// `login_required`, `wrong_candidate`, `closed`, `instructions`,
  /// `question` or `complete`.
  ///
  /// This is the ONLY navigation authority for the runner. The client asks and
  /// renders what it is told; it never decides for itself which screen a token
  /// should show, so the gate logic has exactly one implementation.
  ///
  /// The runner's state for [token], optionally at a SPECIFIC question.
  ///
  /// [q] is the 1-based position in the candidate's frozen order, and the
  /// route honours it (`candidate.py` passes `arg("q")` into
  /// `_question_payload` as `requested_index`). It is what lets the client
  /// move between questions WITHOUT saving - `/answer` is the only other way
  /// to reach a question, and it refuses to move at all when the answer it is
  /// handed is incomplete.
  ///
  /// Every runner call below carries `session_key` (see `examSessionKey`):
  /// `/state` and `/begin` make this tab the one holding the sitting, and a
  /// write from a tab that no longer holds it is refused with 409
  /// `session_replaced`. All of them are POSTs, so it rides in the body.
  ///
  /// So does the Safe Exam Browser proof ([_sebProof]): with the rule on,
  /// `/state` answers `seb_required` and every write 403 `seb_required`
  /// without it.
  Future<Map<String, dynamic>> examState(String token, {int? q}) => _call(
    '$kApiPrefix/exam/$token/state',
    <String, dynamic>{'q': ?q, 'session_key': examSessionKey(), ..._sebProof()},
  );

  /// Stamps `started_at` and opens the sitting.
  ///
  /// RETRIED. A dropped begin leaves the candidate looking at instructions with
  /// no clock started, and it is idempotent server-side, so replaying it is
  /// safe.
  Future<Map<String, dynamic>> examBegin(String token) => _callWithRetry(
    '$kApiPrefix/exam/$token/begin',
    <String, dynamic>{'session_key': examSessionKey(), ..._sebProof()},
  );

  /// Saves one answer. The shape follows the question type: `optionIds` for
  /// the objective and dimension types, `justification` for prose, `labels`
  /// for the labelling types (keyed by marker number).
  ///
  /// TWO WIRE NAMES THAT ARE NOT THE DART NAMES. The route reads
  /// `id_list_arg("selected_option_ids")` and `arg("label_answers")`; this
  /// client used to send `option_ids` and `labels`, which the server never
  /// looks at. `_record_response` then saw no selection, and for an objective
  /// question that is not an error - it is a BLANK ANSWER, saved and
  /// submitted as such. Every multiple-choice answer a candidate gave was
  /// discarded and scored zero, with no error anywhere. Third instance of the
  /// same class after person_ids/applicant_ids and dry_run/confirm: a
  /// parameter name can only ever be settled against the route.
  ///
  /// [nav] is what makes this the NAVIGATION call as well as the save call.
  /// The route answers with the next question under `next` (`null` when the
  /// paper is finished, plus a `review` block), so the client never has to
  /// work out where it is - which is the whole point, because the exam payload
  /// carries no question list to index into.
  Future<Map<String, dynamic>> examAnswer(
    String token, {
    required String questionId,
    List<String> optionIds = const <String>[],
    String justification = '',
    Map<int, String> labels = const <int, String>{},
    // Transcription questions only: category, characteristics and speakers.
    Map<String, dynamic>? clipAnswers,
    String nav = 'next',
    // RETRIED, unlike every read on this client. Losing this call loses an
    // answer the candidate cannot get back, which is why it goes through the
    // ladder - see `_callWithRetry`.
  }) => _callWithRetry('$kApiPrefix/exam/$token/answer', <String, dynamic>{
    'question_id': questionId,
    'selected_option_ids': optionIds,
    'justification': justification,
    'label_answers': labels.map(
      (int k, String v) => MapEntry<String, String>(k.toString(), v),
    ),
    'clip_answers': ?clipAnswers,
    'nav': nav,
    'session_key': examSessionKey(),
    ..._sebProof(),
  });

  /// Delivery history for one record - Odoo's Technical > Emails, scoped.
  ///
  /// Separate from [chatter] on purpose. The chatter route deliberately
  /// EXCLUDES emails, because an invitation body carries that candidate's
  /// access-token link; this route returns metadata and only hands `body_html`
  /// to a manager. The two answer different questions: what people did, versus
  /// what the mail server did.
  Future<Map<String, dynamic>> emails(
    String kind,
    String recordId, {
    String? state,
    int limit = 40,
    int offset = 0,
  }) => _call('$kApiPrefix/emails/$kind/$recordId', <String, dynamic>{
    'state': ?state,
    'limit': limit,
    'offset': offset,
  });

  /// The review page: every question with its answered state, before submit.
  Future<Map<String, dynamic>> examReview(String token) => _call(
    '$kApiPrefix/exam/$token/review',
    <String, dynamic>{'session_key': examSessionKey(), ..._sebProof()},
  );

  /// Grades, locks and stamps. Irreversible - there is no un-submit.
  ///
  /// [force] is the candidate's answer to "submit with N unanswered?". The
  /// module REFUSES an incomplete submit with 409 `incomplete_attempt` unless
  /// the clock has run out or this flag is set (`candidate.py:376-386`), and
  /// this call used to send no body at all - so the confirmation dialog
  /// collected a decision the request then threw away. Pressing "Submit
  /// anyway" produced "Your exam was NOT submitted: 4 question(s) are still
  /// unanswered", with no way past it: the only escape was answering every
  /// question or running out of time.
  ///
  /// Sent as a real bool. The route reads it with `bool_arg`, which exists
  /// because a loosely typed client sending `"false"` walked past the guard.
  ///
  /// RETRIED. This is the call carrying a 0.00% error budget: a dropped submit
  /// leaves a finished paper looking abandoned, and the expiry cron settles it
  /// later as if the candidate walked away.
  Future<Map<String, dynamic>> examSubmit(String token, {bool force = false}) =>
      _callWithRetry('$kApiPrefix/exam/$token/submit', <String, dynamic>{
        'force': force,
        'session_key': examSessionKey(),
        ..._sebProof(),
      });

  /// Records a proctoring violation. Returns whether it ended the attempt,
  /// which happens only when the assessment's action is auto-submit AND the
  /// count reached the cap.
  ///
  /// RETRIED. A dropped violation is evidence lost from a proctoring record
  /// that a reviewer later has to defend, and the server is the only thing
  /// counting toward the cap.
  ///
  /// [at] is the report's own stamp: a report sent again after a lost reply
  /// carries the same one, and the server counts it once.
  Future<Map<String, dynamic>> examViolation(
    String token,
    String reason, {
    int? at,
  }) => _callWithRetry('$kApiPrefix/exam/$token/violation', <String, dynamic>{
    'reason': reason,
    'at': ?at,
    'session_key': examSessionKey(),
    ..._sebProof(),
  });

  /// Whether the AI watch ran on this device: `running` or `failed`
  /// (`ai_status`). Retried like a violation.
  Future<Map<String, dynamic>> examAiStatus(String token, String status) =>
      _callWithRetry('$kApiPrefix/exam/$token/ai-status', <String, dynamic>{
        'status': status,
        'session_key': examSessionKey(),
        ..._sebProof(),
      });

  /// Whether one AI proctoring snapshot ([key], as `web/proctor_ai.js` named
  /// it) is in S3. Asked only after an upload whose S3 reply the browser could
  /// not read. NOT retried: the bridge sends the snapshot again when unsure.
  Future<bool> examEvidenceLanded(String token, String key) async =>
      (await _call('$kApiPrefix/exam/$token/evidence/landed', <String, dynamic>{
        'key': key,
        'session_key': examSessionKey(),
        ..._sebProof(),
      }))['landed'] ==
      true;

  /// Per-answer review after release. Refused while `results_released` is
  /// false - the server substitutes its own gate rather than returning a
  /// score.
  Future<Map<String, dynamic>> examAnswers(String token) =>
      _call('$kApiPrefix/exam/$token/answers');

  /// A signed URL for a question's image or clip.
  ///
  /// Media is served through the token so it cannot be deep-linked out of the
  /// exam.
  ///
  /// Prefer the `url` the payload already carries and pass it through
  /// [resolveMediaUrl]; this builder exists for callers that hold only an id.
  /// It previously hardcoded `/pro_assessment/...`, a route the backend fork no
  /// longer serves.
  String mediaUrl(String token, String assetId, {bool video = false}) =>
      '$base/assessments_be/exam/${video ? 'qvideo' : 'qimage'}/$token/$assetId';

  // ── Admin ──────────────────────────────────────────────────────────────
  //
  // The module has no admin portal: these read and write the same models the
  // Odoo backend views do. Where the module already has a method that does the
  // work - action_start, action_release_all_results, action_llm_score - the
  // addon calls IT rather than reimplementing the rule.

  /// Every assessment, with its state and counts.
  Future<Map<String, dynamic>> assessments({
    String? state,
    String? search,
    int limit = 200,
    int offset = 0,
    bool includeArchived = false,
  }) => _call('$kApiPrefix/assessments', <String, dynamic>{
    'state': ?state,
    'search': ?search,
    // Archived assessments are out of the default list. Fetched anyway, for
    // the same reason the bank fetches retired rows: the list screen's
    // "Show archived" toggle and the restore path both need them in hand.
    if (includeArchived) 'include_archived': true,
    // Without an explicit limit the route applies DEFAULT_LIMIT = 40 and
    // says nothing about the rest. MAX_LIMIT is 200.
    'limit': limit,
    'offset': offset,
  });

  Future<Map<String, dynamic>> assessment(String id) =>
      _call('$kApiPrefix/assessments/$id');

  /// The roster and every attempt on it.
  ///
  /// PAGED. The route clamps to `DEFAULT_LIMIT = 40` and `MAX_LIMIT = 200`, so
  /// a caller that passes nothing gets the first 40 rows and no hint that more
  /// exist. Every admin KPI is computed from these attempts, so a cohort of
  /// 41 silently reported the wrong totals everywhere.
  ///
  /// THE ROSTER'S OWN ROUTE, and the one the Candidates tab reads. It scopes
  /// the query to one cohort, so the 200-row clamp bounds a 572-person roster
  /// instead of a 2,538-row console-wide walk, and it is the only route that can
  /// page a single assessment server-side.
  ///
  /// [search] and [state] are why this is not a straight port of the tab's old
  /// local filters. Paging a listing server-side while filtering it in the
  /// client is worse than either: the client filters ONE PAGE and the operator
  /// reads "no matches" over a cohort the server can see.
  ///
  /// [sortCol] ORDERS THE QUERY, which is the only place a sorted roster can
  /// be decided. The route pages at MAX_LIMIT = 200 and a live cohort runs to
  /// 711, so a client-side comparator would order 200 rows out of 711 and label
  /// the result "sorted by score" while the top scorer sat on page 3 - a wrong
  /// answer delivered confidently, which is worse than no sort at all.
  ///
  /// It is a UI COLUMN KEY, never a field name: `candidate`, `invite`, `state`,
  /// `answered`, `score`, `result`, `released`, `remarks`, `flag`. The route
  /// resolves it through its own allow-list and appends the `id` tiebreaker, so
  /// no client string reaches `search(order=...)`, and a key the server has not
  /// heard of degrades to the default order rather than losing the roster.
  Future<Map<String, dynamic>> candidates(
    String assessmentId, {
    String? search,
    String? state,
    String? result,
    bool manualFlaggedOnly = false,
    String? sortCol,
    bool sortAsc = true,
    int limit = 200,
    int offset = 0,
  }) => _call('$kApiPrefix/assessments/$assessmentId/candidates', <
    String,
    dynamic
  >{
    'search': ?search,
    'state': ?state,
    // `pass` | `fail`. Sent only while a verdict tile is pressed, like the
    // terms around it - and never beside `state`: the tiles are one choice.
    'result': ?result,
    // D1. ITS OWN PARAMETER, never folded into `flagged_only`: that one
    // means exactly the three automatic advisory signals and every existing
    // caller depends on it continuing to. Sent only when on, so a roster
    // read that does not care carries no extra term.
    if (manualFlaggedOnly) 'manual_flagged_only': true,
    // SENT ONLY WHILE A SORT IS ACTIVE, the same rule the flag above follows.
    // An unsorted roster - which is every roster until a header is clicked -
    // issues byte for byte the request it issued before this parameter
    // existed, so nothing about the default read depends on the server having
    // shipped its half yet. `sort_desc` never travels without `sort`,
    // because a direction with no column is a term the route would have to
    // invent a meaning for.
    //
    // THESE TWO NAMES ARE THE CONTRACT, and they are the route's, not ours:
    // `_attempt_order()` in `controllers/api/admin.py` reads `str_arg("sort")`
    // and `bool_arg("sort_desc")`. An unknown key there is not an error - it
    // degrades to newest-first - so a mismatch here does not fail loudly, it
    // silently serves an unsorted roster under a column header drawn with a
    // caret. That is exactly how it shipped the first time; do not rename one
    // side alone.
    //
    // Ascending sends no direction at all, matching `manual_flagged_only`
    // above: the route's default is ascending, so the term would be noise.
    'sort': ?sortCol,
    if (sortCol != null && !sortAsc) 'sort_desc': true,
    'limit': limit,
    'offset': offset,
  });

  /// D1 - set the flag and/or the remark on ONE ATTEMPT.
  ///
  /// KEYED BY THE ATTEMPT, not the person: a concern about how somebody sat
  /// one assessment is not a statement about them in general, so this changes
  /// that sitting and nothing else.
  ///
  /// BOTH ARGUMENTS ARE OPTIONAL AND INDEPENDENT, and the null-aware entries
  /// below are what makes that true on the wire: a key that is not sent is not
  /// changed server-side. Passing only [flagged] toggles the flag and leaves
  /// any remark intact; passing only [remark] edits the remark and leaves the
  /// flag alone. Sending `remark: ''` deliberately CLEARS the remark, which is
  /// why it is a nullable String rather than defaulting to empty.
  ///
  /// Admin rung only. A read-only Manager gets a 403 here and the console
  /// hides the control, from the same fact rather than from two lists.
  Future<Map<String, dynamic>> flagAttempt(
    String attemptId, {
    bool? flagged,
    String? remark,
  }) => _call('$kApiPrefix/attempts/$attemptId/flag', <String, dynamic>{
    'flagged': ?flagged,
    'remark': ?remark,
  });

  /// Assign or unassign candidates.
  ///
  /// THE WIRE NAME IS `applicant_ids`, not `person_ids`. The route reads
  /// `id_list_arg("applicant_ids")` and `arg("candidates")` and refuses with
  /// `no_candidates` when it finds neither - so the old `person_ids` body was
  /// rejected outright and nobody was ever assigned from this screen.
  ///
  /// [invites] adds people who are not in the system yet, by name and email:
  /// the server creates the applicant record. That is the only way to invite
  /// somebody who has never sat an assessment, and the reason an operator can
  /// build a roster at all.
  ///
  /// [dryRun] writes nothing: the server answers in about a second with what
  /// the real call WOULD do - counts, and who it would skip and why - where a
  /// large real import takes minutes. The key is left out otherwise.
  Future<Map<String, dynamic>> assign(
    String assessmentId, {
    List<String> personIds = const <String>[],
    List<String> userIds = const <String>[],
    List<({String name, String email})> invites =
        const <({String name, String email})>[],
    bool remove = false,
    bool dryRun = false,
  }) => _call('$kApiPrefix/assessments/$assessmentId/assign', <String, dynamic>{
    'applicant_ids': personIds,
    // A person picked out of the DIRECTORY is sent by user id. The server maps
    // it to that user's applicant, or makes one - so picking somebody who has
    // never sat an assessment is an ordinary assignment rather than a separate
    // "invite by email" flow with its own typo-shaped duplicates.
    if (userIds.isNotEmpty) 'user_ids': userIds,
    if (invites.isNotEmpty)
      'candidates': <Map<String, String>>[
        for (final ({String name, String email}) i in invites)
          <String, String>{'name': i.name, 'email': i.email},
      ],
    'remove': remove,
    if (dryRun) 'dry_run': true,
  });

  /// The directory the Assign-candidates picker searches.
  ///
  /// Server-side search and paging, because a roster can run to hundreds of
  /// people and the picker used to filter a list built by de-duplicating every
  /// attempt in the console - which could only ever offer somebody who had
  /// already sat something.
  Future<({List<dynamic> rows, int total})> users({
    String search = '',
    int limit = 10,
    int offset = 0,
  }) async {
    final Map<String, dynamic> r =
        await _call('$kApiPrefix/users', <String, dynamic>{
          if (search.trim().isNotEmpty) 'search': search.trim(),
          'limit': limit,
          'offset': offset,
        });
    final Object? data = r['data'];
    final Object? meta = r['meta'];
    return (
      rows: data is List ? data : const <dynamic>[],
      total: meta is Map && meta['total'] is num
          ? (meta['total'] as num).toInt()
          : (data is List ? data.length : 0),
    );
  }

  /// Runs the launch gates. With `dryRun` nothing is written and every gate is
  /// reported - which is what the confirmation sheet shows before anything
  /// happens. All gates are evaluated together; the API never stops at the
  /// first failure, because fixing a record one error at a time is guesswork.
  ///
  /// THE FLAG IS `confirm`, NOT `dry_run`. The route reads
  /// `bool_arg("confirm")` and treats a dry run as the DEFAULT, so sending
  /// `dry_run: false` set nothing the server looks at: every launch came back
  /// `{"ok": true, "launched": false}` and no attempt was ever created. The
  /// button reported success and the assessment stayed in draft. Same class as
  /// the `person_ids` / `applicant_ids` slip - a name only the wire can settle.
  Future<Map<String, dynamic>> launch(
    String assessmentId, {
    bool dryRun = false,
  }) => _call('$kApiPrefix/assessments/$assessmentId/launch', <String, dynamic>{
    'confirm': !dryRun,
  });

  /// Releases results. Skips any attempt still being graded, and says so.
  ///
  /// THERE IS NO DRY RUN. The route reads only `evaluator_ids` and has no
  /// preview mode, so a `dryRun` flag here would release for real.
  ///
  /// Pass [evaluatorIds] to release specific attempts; omit it to release
  /// every submitted attempt awaiting release. An empty list leaves the key
  /// out: the route reads an ABSENT key as the whole cohort, and a present
  /// but unreadable one (`[]`, null, junk) as 422 `invalid`.
  Future<Map<String, dynamic>> release(
    String assessmentId, {
    List<String> evaluatorIds = const <String>[],
  }) =>
      _call('$kApiPrefix/assessments/$assessmentId/release', <String, dynamic>{
        if (evaluatorIds.isNotEmpty) 'evaluator_ids': evaluatorIds,
      });

  /// Re-tag every question a generator already produced.
  ///
  /// Distinct from [extractTags], which reads the SOP into the generator's own
  /// vocabulary. This pushes that vocabulary DOWN onto questions authored
  /// before it existed, which is the only way to make an older bank searchable
  /// by tags a later extraction found.
  Future<Map<String, dynamic>> backfillTags(String genId) =>
      _call('$kApiPrefix/generators/$genId/backfill_tags');

  /// Live view of the subjective grading pipeline.
  ///
  /// Lane counts, how many are queued, and the attempts stuck in the terminal
  /// `error` lane. That last one matters because INVARIANT 5 says a terminal
  /// error is never retried automatically - it sits there until a person acts,
  /// and nothing else in the app says so.
  Future<Map<String, dynamic>> scoring({String? assessmentId}) => _call(
    '$kApiPrefix/scoring',
    <String, dynamic>{'assessment_id': ?assessmentId},
  );

  /// Every attempt the caller may see, across all assessments.
  ///
  /// The console-wide read. Attempts were only reachable per assessment, so
  /// loading them all meant one request per assessment on every refresh.
  ///
  /// [changedSince] (ISO-8601 UTC) asks only for rows written after it,
  /// newest change first. A backend without the filter ignores the key.
  Future<Map<String, dynamic>> attempts({
    int limit = 200,
    int offset = 0,
    String? assessmentId,
    String? changedSince,
  }) => _call('$kApiPrefix/attempts', <String, dynamic>{
    'limit': limit,
    'offset': offset,
    'assessment_id': ?assessmentId,
    'changed_since': ?changedSince,
  });

  /// Edit a draft question before approving it.
  ///
  /// A draft's answer key is `options` (a list of strings) plus
  /// `correctAnswer` (the TEXT of the right option - a String for mcq, a
  /// `List<String>` for msq). Not ids and not indexes: that is how the module
  /// stores it, and the server refuses a correct answer that is not one of
  /// the options, because such a question scores nobody correct while looking
  /// completely normal.
  Future<Map<String, dynamic>> updateDraft(
    String draftId, {
    String? name,
    String? prompt,
    String? description,
    String? difficulty,
    int? timeMinutes,
    String? officialReasoning,
    List<String>? options,
    Object? correctAnswer,
    List<Map<String, dynamic>>? dimensions,
  }) => _call('$kApiPrefix/drafts/$draftId/update', <String, dynamic>{
    'name': ?name,
    'question_prompt': ?prompt,
    'description': ?description,
    'difficulty': ?difficulty,
    'time_minutes': ?timeMinutes,
    'official_reasoning': ?officialReasoning,
    'options': ?options,
    'correct_answer': ?correctAnswer,
    // The structured key, for a type whose answer lives on several axes. The
    // server refuses the flat pair for those - a single list cannot express
    // more than one axis, and sending it would silently key only the first.
    // Send one or the other, never both; the server refuses that too.
    'dimensions': ?dimensions,
  });

  /// Edit a bank question, including its answer key.
  ///
  /// [dimensions] is the whole intended key - a row with an `id` updates, one
  /// without creates, and anything omitted is removed. Removing an option a
  /// candidate has already selected is refused by the server with that option
  /// named, because deleting it would rewrite their submitted answer.
  Future<Map<String, dynamic>> updateBankQuestion(
    String questionId, {
    String? name,
    String? prompt,
    String? description,
    String? difficulty,
    int? timeMinutes,
    String? officialReasoning,
    bool? rubricReviewed,
    bool? active,
    List<Map<String, dynamic>>? dimensions,
  }) => _call('$kApiPrefix/bank/$questionId/update', <String, dynamic>{
    'name': ?name,
    'prompt': ?prompt,
    'description': ?description,
    'difficulty': ?difficulty,
    'time_minutes': ?timeMinutes,
    'official_reasoning': ?officialReasoning,
    'rubric_reviewed': ?rubricReviewed,
    'active': ?active,
    'dimensions': ?dimensions,
  });

  /// Archive a generator, or restore one with `archive: false`.
  ///
  /// Retiring, not deleting: an archived generator keeps the questions it
  /// authored, and those keep their link back to the document that justified
  /// them. Deleting would break that chain for every assessment already sat.
  Future<Map<String, dynamic>> archiveGenerator(
    String genId, {
    bool archive = true,
  }) => _call('$kApiPrefix/generators/$genId/archive', <String, dynamic>{
    'archive': archive,
  });

  /// Archive an assessment, or restore one with `archive: false`.
  ///
  /// Its own route rather than a field on `assessmentUpdate`, matching
  /// [archiveGenerator]: archiving is a decision, not an edit, and `/update`
  /// refuses most writes once an assessment has left draft - which would have
  /// made a live sitting the one thing that could never be filed away.
  /// Nothing is destroyed: every attempt, response and score stays attached.
  ///
  /// Archiving is a SUSPEND: it stops the crons from picking the assessment up
  /// - no more LLM scoring, no more invitations, no more expiry - and leaves
  /// `scoring_requested`, `llm_state` and `invite_state` exactly as they were,
  /// so restoring resumes from those rows with no replay step.
  ///
  /// [confirmLiveAttempts] is the operator saying yes to archiving a paper
  /// people are SITTING. The route refuses that case on its own with
  /// `live_attempts`, naming how many, because stopping the clock under a live
  /// cohort is almost always a mistake; the key only travels once the operator
  /// has read the sheet and confirmed.
  ///
  /// `confirm_live_attempts` IS THE ROUTE'S OWN SPELLING - `bool_arg(
  /// "confirm_live_attempts")` in `_live_attempt_refusal`, `write.py`. It is
  /// spelled out here because an unknown argument is not an error to that
  /// route, it is an absent one: a rename on either side would not fail, it
  /// would silently stop confirming and leave every live archive refused. Sent
  /// only when true, like `include_archived` above.
  Future<Map<String, dynamic>> archiveAssessment(
    String assessmentId, {
    bool archive = true,
    bool confirmLiveAttempts = false,
  }) =>
      _call('$kApiPrefix/assessments/$assessmentId/archive', <String, dynamic>{
        'archive': archive,
        if (confirmLiveAttempts) 'confirm_live_attempts': true,
      });

  /// Destroy an assessment for good. There is no undo and no restore.
  ///
  /// TWO CALLS, AND THE ROUTE ORDERS THEM. Called WITHOUT [confirmName] it
  /// archives the assessment - reversible, and it stops the scoring, the
  /// invitations and the exam clock - then refuses with `confirm_required` at
  /// 409, carrying `candidate_count`, `response_count` and `llm_usage_kept`:
  /// exactly what a confirmed call would destroy and what it would keep. That
  /// refusal is the preview, and it is read off [ApiError.fields]. Called WITH
  /// [confirmName] it destroys the record.
  ///
  /// [confirmName] is the assessment's own name echoed back, compared
  /// case-insensitively after stripping. A boolean would have been cheaper and
  /// the route refuses one deliberately: `confirm: true` is a key any retry,
  /// copied payload or "confirm everything" helper can send without a human
  /// reading what it applies to, and this is the one call in the module whose
  /// mistake cannot be undone.
  ///
  /// [confirmLiveAttempts] is needed here too, and for the archive half rather
  /// than the destroy: step one interrupts anybody mid-sitting, so the route
  /// asks that question first and separately.
  ///
  /// What survives either way: the LLM spend already recorded against this
  /// assessment. `llm.usage.evaluator_id` is `ondelete="set null"`, not
  /// `cascade`, so the ledger rows outlive the cohort with a null evaluator
  /// and the day's spend is unchanged - a deleted assessment cannot be used to
  /// buy back headroom under the daily cap.
  Future<Map<String, dynamic>> deleteAssessment(
    String assessmentId, {
    String? confirmName,
    bool confirmLiveAttempts = false,
  }) => _call('$kApiPrefix/assessments/$assessmentId/delete', <String, dynamic>{
    'confirm_name': ?confirmName,
    if (confirmLiveAttempts) 'confirm_live_attempts': true,
  });

  /// Re-run the hybrid (lexical + semantic) similarity ranking.
  ///
  /// The Similarity tab reads the PERSISTED ranked pairs, which only exist
  /// once this has run - so it read "no similar generators" beside a count
  /// badge that said otherwise. The count is computed lexically on the fly;
  /// the pairs were never being computed at all from this app.
  ///
  /// Costs money (embeddings), hence a button rather than an automatic call.
  Future<Map<String, dynamic>> rankSimilarity(String genId) =>
      _call('$kApiPrefix/generators/$genId/rank_similarity');

  /// Replace one image slot on a DRAFT QUESTION with an uploaded file.
  ///
  /// On the draft, not the generator: the upload fields and the module's own
  /// apply action both live on the question, which is the only record whose
  /// slot letters mean anything.
  ///
  /// `image` may be bare base64 or a `data:` URL - the route strips the
  /// preamble either way, because a browser's FileReader produces the latter
  /// and storing that prefix as image bytes yields a corrupt slot.
  Future<Map<String, dynamic>> applyUploadedImage(
    String draftId, {
    required String image,
    String slot = 'a',
  }) => _call('$kApiPrefix/drafts/$draftId/apply_image', <String, dynamic>{
    'image': image,
    'slot': slot,
  });

  /// Re-attempt only the clips that failed on a draft, keeping the good ones.
  Future<Map<String, dynamic>> retryVideo(String draftId) =>
      _call('$kApiPrefix/drafts/$draftId/retry_video');

  /// Send a draft whose image failed back to the image queue. Slots already
  /// rendered are kept, so they are not paid for twice.
  Future<Map<String, dynamic>> retryDraftImages(String draftId) =>
      _call('$kApiPrefix/drafts/$draftId/retry_images');

  /// [retryDraftImages] for every failed draft of one generator. Answers
  /// `{retried: n}`.
  Future<Map<String, dynamic>> retryFailedImages(String generatorId) =>
      _call('$kApiPrefix/generators/$generatorId/retry_failed_images');

  /// One generator's run: phase, one-line summary, lane counts, stall reason.
  /// The light route the generator screen polls - counters, never rows.
  Future<Map<String, dynamic>> generationProgress(String generatorId) =>
      _call('$kApiPrefix/generators/$generatorId/progress');

  /// Recompute a draft's answer key from its stored generation payload.
  ///
  /// The recovery path for a key that drifted from its source: rebuilt
  /// deterministically rather than retyped, so it stays provable by
  /// construction.
  Future<Map<String, dynamic>> rebuildAnswerKey(String draftId) =>
      _call('$kApiPrefix/drafts/$draftId/rebuild_answer_key');

  /// Import questions into the bank from a parsed JSON payload.
  ///
  /// The module's importer owns validation, answer-key materialisation and the
  /// created-count report; this only carries the payload. Shape is
  /// `{project: {...}, question_bank: [...]}` for a normal import, or the
  /// object produced by the native export when [native] is true.
  /// Import a question file - CSV or either JSON shape - by uploading it.
  ///
  /// THE FILE, NOT A PAYLOAD THIS APP SHAPED. The server hands the bytes to the
  /// same wizard the Odoo back office uses, so both surfaces read the same
  /// thirty-three-column template. This app used to parse CSV itself with a
  /// six-column reader, which meant the template an operator downloaded from
  /// Odoo lost its dimensions, rubrics and images on the way in - silently, and
  /// reported as a success.
  Future<Map<String, dynamic>> importBankFile({
    required String content,
    required String filename,
    String? generatorName,
  }) => _call('$kApiPrefix/bank/import', <String, dynamic>{
    'content': content,
    'filename': filename,
    'generator_name': ?generatorName,
  });

  /// Upsert the tag vocabulary from a CSV.
  Future<Map<String, dynamic>> importTags({
    required String content,
    required String filename,
  }) => _call('$kApiPrefix/tags/import', <String, dynamic>{
    'content': content,
    'filename': filename,
  });

  /// Upsert generators from a CSV.
  Future<Map<String, dynamic>> importGenerators({
    required String content,
    required String filename,
  }) => _call('$kApiPrefix/generators/import', <String, dynamic>{
    'content': content,
    'filename': filename,
  });

  /// The CSV template for one importable entity.
  ///
  /// `{filename, mimetype, content}` with `content` base64, the same shape
  /// every other download on this API uses. Fetched rather than restated, so
  /// the column list the sheet shows cannot drift from the one the server
  /// reads.
  Future<Map<String, dynamic>> importTemplate(String entity) =>
      _call('$kApiPrefix/$entity/template');

  /// The Form Studio import template: one EMPTY item of every element kind.
  ///
  /// Not one of the [ImportEntity] templates above, and deliberately not bent
  /// into their shape. Those are CSVs for importers that run on the server;
  /// this is a JSON form document for an importer that runs here, so it has its
  /// own route rather than a `forms` entity that would imply a
  /// `/forms/import` that does not exist.
  Future<Map<String, dynamic>> formTemplate() =>
      _call('$kApiPrefix/forms/template/json');

  /// ── Exports ─────────────────────────────────────────────────────────────
  ///
  /// Each returns `{filename, mimetype, content}` where `content` is base64.
  /// The transport is JSON, so the CSV rides encoded rather than as a
  /// redirect to an attachment URL: a URL would outlive the request and only
  /// work in a browser.

  /// Every answer on one assessment, as CSV.
  ///
  /// `zip: true` - one too large to send as CSV comes back as a zip holding
  /// the same CSV (`mimetype: application/zip`) instead of a 413.
  ///
  /// [limit] > 0 asks for one PAGE of candidates from [offset]; the reply then
  /// also carries `total`, the number of candidates to page through.
  Future<Map<String, dynamic>> exportResponses(
    String assessmentId, {
    int offset = 0,
    int limit = 0,
  }) => _call(
    '$kApiPrefix/assessments/$assessmentId/export/responses',
    <String, dynamic>{
      'zip': true,
      if (limit > 0) ...<String, dynamic>{'offset': offset, 'limit': limit},
    },
  );

  /// The results sheet for one assessment: a row per candidate.
  Future<Map<String, dynamic>> exportResults(String assessmentId) => _call(
    '$kApiPrefix/assessments/$assessmentId/export/results',
    <String, dynamic>{'zip': true},
  );

  /// One candidate's answers, as CSV.
  Future<Map<String, dynamic>> exportAttemptResponses(String attemptId) =>
      _call(
        '$kApiPrefix/attempts/$attemptId/export/responses',
        <String, dynamic>{'zip': true},
      );

  /// The CSV template the candidate importer expects.
  Future<Map<String, dynamic>> candidateTemplate() =>
      _call('$kApiPrefix/candidates/template');

  /// Upload a filled candidate CSV against one assessment.
  ///
  /// The counterpart to [candidateTemplate]: the app could hand out the sheet
  /// but had no way to send it back, so a roster had to be assembled one
  /// candidate at a time. Returns the roster the server ended up with, so the
  /// caller can show what landed rather than assuming.
  Future<Map<String, dynamic>> importCandidates(
    String assessmentId, {
    required String base64Csv,
    String filename = 'candidates.csv',
  }) => _call(
    '$kApiPrefix/assessments/$assessmentId/candidates/import',
    <String, dynamic>{'content': base64Csv, 'filename': filename},
  );

  /// ── Bank media authoring ────────────────────────────────────────────────

  /// Re-run UI element detection on a labelling question's image.
  Future<Map<String, dynamic>> detectNow(String questionId) =>
      _call('$kApiPrefix/bank/$questionId/detect', <String, dynamic>{});

  /// Capture the live DOM at [sourceUrl] into the question's image.
  Future<Map<String, dynamic>> captureUrl(
    String questionId, {
    String? sourceUrl,
  }) => _call('$kApiPrefix/bank/$questionId/capture', <String, dynamic>{
    'source_url': ?sourceUrl,
  });

  /// Attach an uploaded clip to a slot on a bank question.
  Future<Map<String, dynamic>> applyVideo(
    String questionId, {
    required String content,
    String filename = 'clip.mp4',
    String slot = 'reference',
  }) => _call('$kApiPrefix/bank/$questionId/video', <String, dynamic>{
    'content': content,
    'filename': filename,
    'slot': slot,
  });

  /// Top candidates by average score across every assessment.
  ///
  /// NOT release-gated: `results_released` governs what a CANDIDATE sees in
  /// their own portal, and the admin sees every score. Gating it made the board
  /// disagree with the score distribution beside it - a candidate counted in
  /// the 85-100 bar was missing from the ranking.
  ///
  /// Rows carry `applicant_name`, `attempts`, `avg_score`, `best_score` and
  /// `passed`, already ranked and limited by the server.
  /// [assessmentId] ranks within one assessment instead of across every one.
  ///
  /// IT HAS TO BE THE SERVER. The rows are grouped by candidate, so by the
  /// time they reach this client the assessment dimension is gone and no
  /// client-side filter can recover it.
  Future<({List<dynamic> rows, Map<String, dynamic> meta})> leaderboard({
    // THE SERVER'S OWN CEILING, not 200. `MAX_LEADERBOARD` is 2000 and the
    // route clamps to it; asking for 200 meant the board was cut at 200 on the
    // CLIENT'S request while the panel claimed it showed everyone. The
    // 588-candidate cohort of 2026-09-03 would have ranked 200 deep.
    int limit = 2000,
    String? assessmentId,
  }) async {
    // LIMIT IN THE BODY, NOT THE QUERY STRING. `json2` merges the request body
    // with the path parameters and ignores the query entirely, so
    // `?limit=200` was read by nobody and the server quietly applied its own
    // default of 10 - the panel could never show an eleventh candidate, and
    // paging it would have paged over a list the server had already truncated.
    final Map<String, dynamic> r = await _call(
      '$kApiPrefix/leaderboard',
      <String, dynamic>{'limit': limit, 'assessment_id': ?assessmentId},
    );
    final Object? data = r['data'];
    // THE META COMES BACK TOO. The route answers with
    // `{total, returned, truncated}` beside the list precisely so truncation
    // is never silent - and this method threw it away, so the panel went on
    // calling a capped board "every submitted attempt". See
    // `AppStore.leaderboardTotal`.
    final Object? meta = r['meta'];
    return (
      rows: data is List ? data : const <dynamic>[],
      meta: meta is Map<String, dynamic> ? meta : const <String, dynamic>{},
    );
  }

  /// COHORT ANALYTICS, computed by the server across every assessment.
  ///
  /// The console cannot derive these. Its own aggregation reads a verdict off
  /// each attempt, and `Attempt.result` divides by the assessment's frozen
  /// question count - which a row from the LIST endpoint does not carry. So an
  /// assessment the operator had never opened contributed no decided results,
  /// and opening one retroactively changed every cohort figure on the
  /// dashboard: the same screen reported "nothing decided yet", then 0/1, then
  /// 3 of 6, purely as a function of where the operator had navigated.
  ///
  /// The server reads `evaluator.result` directly, so its counts are complete
  /// and stable. Returns `totals`, `flags`, `score_bands` and `by_assessment`.
  /// [assessmentId] scopes EVERY figure in the payload to one assessment -
  /// totals, flags, score bands, `by_assessment` and `cohort_categories` alike.
  ///
  /// The server has accepted this since the route was written; this client
  /// never sent it. The dashboard has an assessment filter on screen, so
  /// narrowing it moved the locally-computed figures and left every
  /// server-computed one all-up: Pass rate, Cohort outcome, Decided outcomes,
  /// Avg score and Strengths and weaknesses all kept describing the whole
  /// cohort under a heading that said otherwise.
  Future<Map<String, dynamic>> analytics({String? assessmentId}) => _call(
    '$kApiPrefix/analytics',
    <String, dynamic>{'assessment_id': ?assessmentId},
  );

  /// Live state of the subjective grading pipeline.
  ///
  /// The lane counts, and - the part that matters - whether the DRAINER is
  /// running. A terminal scoring error is never retried automatically
  /// (INVARIANT 5), so anything in the error lane sits there until a person
  /// requeues it. Nothing in the client read this route, so a stalled grader
  /// and a queue of ungraded candidates were both invisible to the admin who
  /// had to act on them.
  Future<Map<String, dynamic>> scoringPipeline({String? assessmentId}) => _call(
    '$kApiPrefix/scoring',
    <String, dynamic>{'assessment_id': ?assessmentId},
  );

  /// The signed-in candidate's own performance. Release-gated the same way.
  Future<Map<String, dynamic>> myAnalytics() =>
      _call('$kApiPrefix/me/analytics');

  Future<Map<String, dynamic>> closeAssessment(String assessmentId) =>
      _call('$kApiPrefix/assessments/$assessmentId/close');

  /// Cancel an assessment. Distinct from close: close means it finished,
  /// cancel means it will not run.
  Future<Map<String, dynamic>> cancelAssessment(String assessmentId) =>
      _call('$kApiPrefix/assessments/$assessmentId/cancel');

  /// Send an assessment back to draft so it can be reconfigured.
  ///
  /// The route refuses with 409 `released_results` when that would erase
  /// results a candidate has already been shown; [confirmReleased] is the
  /// admin having said yes to that, and is sent only then.
  Future<Map<String, dynamic>> resetToDraft(
    String assessmentId, {
    bool confirmReleased = false,
  }) => _call(
    '$kApiPrefix/assessments/$assessmentId/reset_draft',
    <String, dynamic>{if (confirmReleased) 'confirm_released': true},
  );

  /// Queue subjective scoring. The LLM call happens in the module's cron, not
  /// on this request.
  Future<Map<String, dynamic>> queueScoring({
    String? assessmentId,
    List<String> attemptIds = const <String>[],
  }) => _call('$kApiPrefix/scoring/queue', <String, dynamic>{
    'assessment_id': ?assessmentId,
    'evaluator_ids': attemptIds,
  });

  /// Reset terminally-errored answers and queue them again.
  ///
  /// The manual path on purpose: a terminal error is never retried
  /// automatically, so a Vertex outage cannot silently turn into a wrong
  /// score. A person decides.
  Future<Map<String, dynamic>> requeueErrored(List<String> attemptIds) => _call(
    '$kApiPrefix/scoring/requeue_errored',
    <String, dynamic>{'evaluator_ids': attemptIds},
  );

  /// Reset every FAILED or errored answer on one assessment and queue it again.
  ///
  /// The same route as [requeueErrored], scoped differently: rather than a list
  /// of hand-picked attempts, it hands the server an `assessment_id` and the
  /// `states` to sweep - `['failed','error']`, so a transient failure and a
  /// terminal error are both recovered by the one "Score Failed" button on the
  /// assessment. The server answers `requeued` - the ATTEMPTS swept, i.e.
  /// every attempt on the paper - and `answers_reset`, the count a toast may
  /// print. `candidates` comes back empty for a whole paper, and nothing here
  /// reads it.
  Future<Map<String, dynamic>> requeueFailed({String? assessmentId}) =>
      _call('$kApiPrefix/scoring/requeue_errored', <String, dynamic>{
        'assessment_id': ?assessmentId,
        'states': <String>['failed', 'error'],
      });

  /// Sign off an AI-authored rubric, so it can grade candidates.
  Future<Map<String, dynamic>> reviewRubric(
    String questionId, {
    bool reviewed = true,
  }) => _call('$kApiPrefix/bank/$questionId/review_rubric', <String, dynamic>{
    'reviewed': reviewed,
  });

  /// Replace the question types a generator may author.
  ///
  /// Codes ("mcq", "image_ab"), not database ids: the code is the stable
  /// identifier and survives a reinstall that renumbers the rows.
  ///
  /// The whole set, not a toggle: a toggle needs both sides to agree on the
  /// current state, and they will not after any concurrent edit.
  Future<Map<String, dynamic>> setQuestionTypes(
    String generatorId,
    List<String> codes,
  ) => _call(
    '$kApiPrefix/generators/$generatorId/question_types',
    <String, dynamic>{'codes': codes},
  );

  /// One candidate's attempt, with every answer and its grader audit.
  Future<Map<String, dynamic>> attempt(String attemptId) =>
      _call('$kApiPrefix/attempts/$attemptId');

  /// The camera snapshots AI proctoring saved for one attempt, newest first:
  /// `{items: [{key, url, at, rule, size}], count}`. Parse with
  /// `ProctoringEvidence.parsePage`. Each `url` is a presigned GET good for 15
  /// minutes, so read it when it is about to be shown, not once per session.
  /// Empty when storage is not configured; 403/404 outside the operator gate
  /// the attempt detail uses.
  Future<Map<String, dynamic>> attemptEvidence(String attemptId) =>
      _call('$kApiPrefix/attempts/$attemptId/evidence');

  /// Re-scores an attempt. This is the ONLY thing that clears a terminal
  /// `error`, and it is always a person's action - the automatic retry set
  /// excludes it on purpose.
  ///
  /// QUEUES, it does not grade: the lane's cron takes the request first and
  /// the reply counts `queued`. [questionIds] names exactly the answers to
  /// grade, scored ones included; without it the server takes the attempt's
  /// unresolved answers, which is what older builds of this app still send.
  /// [confirm] is the operator having said yes to re-scoring an answer on a
  /// RELEASED result - a paid call that can move a mark the candidate already
  /// holds. The route refuses that case without it (409
  /// `released_confirm_required`), the way the bulk requeue route demands
  /// `force`. Sent only when the operator said yes: a client that sent it on
  /// every call would satisfy the gate without ever asking anyone.
  Future<Map<String, dynamic>> rescore(
    String attemptId, {
    List<String>? questionIds,
    bool confirm = false,
  }) => _call('$kApiPrefix/attempts/$attemptId/rescore', <String, dynamic>{
    'question_ids': ?questionIds
        ?.map((String id) => int.tryParse(id) ?? id)
        .toList(),
    if (confirm) 'confirm': true,
  });

  /// Removes a candidate's personal data while keeping the scores and the
  /// integrity flags, mirroring `action_erase_candidate_data`.
  Future<Map<String, dynamic>> erasePii(String attemptId) =>
      _call('$kApiPrefix/attempts/$attemptId/erase');

  /// Every answer across every attempt, filterable and paged.
  ///
  /// The route pages on `limit`/`offset`, NOT `page`/`page_size`. Sending the
  /// wrong names is silently ignored - the server just applies its own default
  /// limit of 40 and reports `has_more`. Nothing errors, so the failure only
  /// shows up as answer 41 quietly never appearing.
  /// [search] narrows on the server across the three axes Odoo's own response
  /// search view offers - assessment, candidate and question. It is NOT the
  /// answer text: that is rendered and REDACTED client-side, and the server
  /// could only match it by carrying a second copy of the redaction rules.
  /// See `responses_screen.dart`, which unions this slice with its local pass
  /// rather than replacing it, so answer-text search keeps working.
  Future<Map<String, dynamic>> responses({
    String? assessmentId,
    String? questionType,
    String? scoringState,
    String? search,
    int limit = 200,
    int offset = 0,
  }) => _call('$kApiPrefix/responses', <String, dynamic>{
    'limit': limit,
    'offset': offset,
    'assessment_id': ?assessmentId,
    'question_type': ?questionType,
    'scoring_state': ?scoringState,
    'search': ?search,
  });

  // Authoring. Approval is the gate invariant 1 rests on: a draft carrying a
  // blocking warning is refused unless the caller states they saw it, and the
  // refusal is server-side so no client path can bypass it.

  /// Every generator. `includeArchived` is what makes the list screen's
  /// "Show archived" toggle possible at all - the route drops archived rows by
  /// default, which is right for the picker a new assessment draws from but
  /// leaves the restore path unreachable. Same arrangement as [bank] and its
  /// `include_retired`.
  /// [search] is accepted by `/generators` server-side and was simply not
  /// forwarded, so the generator list had no choice but to filter in memory.
  Future<Map<String, dynamic>> generators({
    String? search,
    int limit = 200,
    int offset = 0,
    bool includeArchived = false,
  }) => _call('$kApiPrefix/generators', <String, dynamic>{
    'search': ?search,
    if (includeArchived) 'include_archived': true,
    'limit': limit,
    'offset': offset,
  });

  Future<Map<String, dynamic>> generator(String id) =>
      _call('$kApiPrefix/generators/$id');

  Future<Map<String, dynamic>> drafts({
    String? generatorId,
    int limit = 200,
    int offset = 0,
  }) => _call('$kApiPrefix/drafts', <String, dynamic>{
    'generator_id': ?generatorId,
    'limit': limit,
    'offset': offset,
  });

  Future<Map<String, dynamic>> approveDraft(
    String draftId, {
    bool acknowledgeWarnings = false,
  }) => _call('$kApiPrefix/drafts/$draftId/approve', <String, dynamic>{
    'acknowledge_warnings': acknowledgeWarnings,
  });

  Future<Map<String, dynamic>> denyDraft(
    String draftId, {
    String reason = '',
  }) => _call('$kApiPrefix/drafts/$draftId/deny', <String, dynamic>{
    'reason': reason,
  });

  /// The audit trail for one record.
  ///
  /// Every operator action routes through the module's `_log_activity`, which
  /// posts a note to the record's chatter. That history existed from day one
  /// and no client surface could read it, so the console looked like a system
  /// with no memory. [kind] is one of `assessment`, `generator`, `attempt`.
  Future<Map<String, dynamic>> chatter(
    String kind,
    String recordId, {
    // 40, matching the route's own cap. Asking for 50 got 40 and made the
    // client's intent a fiction; `meta.total` is what tells the panel whether
    // there is more.
    int limit = 40,
    int offset = 0,
  }) => _call('$kApiPrefix/chatter/$kind/$recordId', <String, dynamic>{
    'limit': limit,
    'offset': offset,
  });

  /// Add to a record's audit trail.
  ///
  /// `note` is internal (Odoo's "Log note"); `message` notifies the record's
  /// followers (Odoo's "Send message"). Explicit rather than inferred, because
  /// the difference is who gets emailed.
  ///
  /// The wire name is `post_kind`: the route path already carries the RECORD
  /// kind as `kind`, and a body field of that name is swallowed by the path
  /// param before the handler sees it.
  ///
  /// [attachments] are `{name, content}` with `content` base64. They are filed
  /// against the message itself, so the same files appear in Odoo's chatter -
  /// the two surfaces agree rather than this app inventing its own idea of
  /// "attached".
  Future<Map<String, dynamic>> postChatter(
    String kind,
    String recordId, {
    required String body,
    String postKind = 'note',
    List<Map<String, String>> attachments = const <Map<String, String>>[],
  }) => _call('$kApiPrefix/chatter/$kind/$recordId/post', <String, dynamic>{
    'body': body,
    'post_kind': postKind,
    if (attachments.isNotEmpty) 'attachments': attachments,
  });

  /// ONE answer, in full.
  ///
  /// The list row omits `lines`, `subscores`, `justification`, `grading`,
  /// `correct_summary` and the nested `question` - the per-dimension marking
  /// an operator opens the answer to read.
  Future<Map<String, dynamic>> response(String attemptId, String questionId) =>
      _call('$kApiPrefix/responses/$attemptId/$questionId');

  /// ONE approved question, in full.
  ///
  /// The list route omits `images`, `videos`, `dimensions`, `solution`,
  /// `solution_rationale` and `subjective_rubric`. A preview built from a list
  /// row therefore shows no media and no answer key.
  Future<Map<String, dynamic>> bankQuestion(String id) =>
      _call('$kApiPrefix/bank/$id');

  /// A labelling question as a Form Studio annotation item, ready to edit.
  ///
  /// 404 `not_annotatable` when the question is not a labelling question or
  /// carries no markers - the caller uses that to decide whether to offer the
  /// action, because an empty item would open an editor with nothing in it.
  Future<Map<String, dynamic>> bankStudioItem(String id) =>
      _call('$kApiPrefix/bank/$id/studio_item');

  /// Save an edited annotation item back onto the SAME question.
  ///
  /// In place: no new Studio form, no second assessment. A corrected question
  /// in a fresh record would leave the paper being fixed just as broken.
  ///
  /// A separate path rather than a POST/GET split on [bankStudioItem], because
  /// this client posts every call it makes.
  Future<Map<String, dynamic>> saveBankStudioItem(
    String id,
    Map<String, dynamic> item,
  ) => _call('$kApiPrefix/bank/$id/studio_item/save', <String, dynamic>{
    'item': item,
  });

  /// ONE draft, in full.
  ///
  /// The list route omits `images`, `label_boxes`, `dimensions`, `options`,
  /// `rubric` and the answer key - everything a reviewer needs to actually
  /// judge the question rather than approve it blind.
  Future<Map<String, dynamic>> draft(String id) =>
      _call('$kApiPrefix/drafts/$id');

  /// The approved question bank.
  ///
  /// The type filter is `question_type` on the wire, NOT `type`. Sending
  /// `type` filtered nothing: the route ignored it and returned every row, so
  /// picking "MCQ" in the bank silently showed the whole library. Verified
  /// live - `type=mcq` gave 35 rows (all of them), `question_type=mcq` gave 9.
  Future<Map<String, dynamic>> bank({
    String? type,
    String? search,
    bool includeRetired = false,
    int limit = 200,
    int offset = 0,
  }) => _call('$kApiPrefix/bank', <String, dynamic>{
    'question_type': ?type,
    'search': ?search,
    // Retired questions are OUT of the bank by default. They are still active
    // records - the assessments using them must keep listing them - so nothing
    // else filters them, and omitting this would put deleted questions back in
    // front of the operator and back in the picker a new assessment draws from.
    if (includeRetired) 'include_retired': true,
    'limit': limit,
    'offset': offset,
  });

  /// What deleting these questions would cost, WITHOUT deleting anything.
  ///
  /// The sentence the operator confirms is built from this, and the server
  /// computes it with the same code that does the work - so the confirmation
  /// cannot promise something different from what follows it.
  Future<Map<String, dynamic>> bankDeletePreview(List<String> ids) => _call(
    '$kApiPrefix/bank/delete',
    <String, dynamic>{'ids': ids, 'preview': true},
  );

  /// Take questions out of the bank.
  ///
  /// NOT ALWAYS AN ERASE, and the server decides which: a question an
  /// assessment uses, or that anybody has answered, is RETIRED - the row and
  /// the answers survive and the paper keeps showing it, it simply leaves the
  /// bank and can never be picked again. Only a question nothing points at is
  /// really deleted. Each returned row carries its own `outcome`.
  Future<Map<String, dynamic>> bankDelete(List<String> ids) =>
      _call('$kApiPrefix/bank/delete', <String, dynamic>{'ids': ids});

  /// Put a retired question back in the bank.
  Future<Map<String, dynamic>> bankRestore(String id) =>
      _call('$kApiPrefix/bank/$id/restore');

  /// Archive questions, or put them back with [archive] false. Erases
  /// nothing - unlike [bankDelete], which erases what nothing points at.
  Future<Map<String, dynamic>> bankArchive(
    List<String> ids, {
    bool archive = true,
  }) => _call('$kApiPrefix/bank/archive', <String, dynamic>{
    'ids': ids,
    'archive': archive,
  });

  /// What deleting this generator would cost, writing nothing.
  ///
  /// Its drafts and SOP files go with it, and the questions it authored leave
  /// the bank under the same retire-or-erase rule as a direct delete.
  Future<Map<String, dynamic>> generatorDeletePreview(List<String> ids) =>
      _call('$kApiPrefix/generators/delete', <String, dynamic>{
        'ids': ids,
        'preview': true,
      });

  Future<Map<String, dynamic>> generatorDelete(List<String> ids) =>
      _call('$kApiPrefix/generators/delete', <String, dynamic>{'ids': ids});

  Future<Map<String, dynamic>> tags({int limit = 200, int offset = 0}) => _call(
    '$kApiPrefix/tags',
    <String, dynamic>{'limit': limit, 'offset': offset},
  );

  // Form Studio. One upsert carries the whole form document; the row the
  // server answers with is byte-comparable to what the designer sent.
  /// [search] matches a form's title. `/api/v1/forms` has accepted it since
  /// the route was written (`forms.py`); nothing was sending it, which is why
  /// the Form Studio box could only ever filter the page it held.
  Future<Map<String, dynamic>> forms({
    String? search,
    int limit = 200,
    int offset = 0,
  }) => _call('$kApiPrefix/forms', <String, dynamic>{
    'search': ?search,
    'limit': limit,
    'offset': offset,
  });

  Future<Map<String, dynamic>> saveForm(Map<String, dynamic> form) =>
      _call('$kApiPrefix/forms/save', <String, dynamic>{'form': form});

  Future<Map<String, dynamic>> deleteForm(String id) =>
      _call('$kApiPrefix/forms/delete', <String, dynamic>{'id': id});

  /// Send a form to candidates: the server materialises it as bank
  /// questions under a dedicated generator plus a draft assessment, so the
  /// existing assign/launch/exam/scoring pipeline carries it from there.
  /// Answers `{assessment_id, generator_id, questions_created, warnings}`.
  Future<Map<String, dynamic>> publishForm(String id) =>
      _call('$kApiPrefix/forms/publish', <String, dynamic>{'id': id});

  /// Designer media upload. The server answers `{url, storage}` - S3 when
  /// the bucket is configured, a public Odoo attachment otherwise.
  Future<Map<String, dynamic>> uploadFormMedia({
    required String name,
    required String contentType,
    required String dataB64,
  }) => _call('$kApiPrefix/forms/media', <String, dynamic>{
    'name': name,
    'content_type': contentType,
    'data': dataB64,
  });

  /// Step 1 of the direct upload: ask for a presigned S3 POST policy.
  ///
  /// Answers `{upload: {url, fields, prefix, expires_at}, key}`. The browser
  /// then POSTs the bytes to `upload.url` itself (see `postToS3`), so a 100 MB
  /// clip never rides in a base64 JSON body through this API. An older server
  /// has no such route: the caller falls back on a 404.
  Future<Map<String, dynamic>> presignFormMedia({
    required String name,
    required String contentType,
    required int size,
  }) => _call('$kApiPrefix/forms/media/presign', <String, dynamic>{
    'name': name,
    'content_type': contentType,
    'size': size,
  });

  /// Step 3 of the direct upload: tell the server the object is in the bucket.
  /// It verifies it (`head_object`) and answers `{url, storage, public}`, the
  /// same shape as [uploadFormMedia].
  Future<Map<String, dynamic>> completeFormMedia({required String key}) =>
      _call('$kApiPrefix/forms/media/complete', <String, dynamic>{'key': key});

  /// Copy a Google Drive share link into this app's own media storage.
  ///
  /// The server refuses any host but Drive - that allow-list is what keeps the
  /// route from being a fetch-anything primitive - so this is not a general
  /// "import from URL".
  Future<Map<String, dynamic>> importFormMedia({required String url}) =>
      _call('$kApiPrefix/forms/media/import', <String, dynamic>{'url': url});

  /// What KIND of media a public url serves: `'image'`, `'video'`, or null.
  ///
  /// NOT USED FOR GOOGLE DRIVE, and the reason is worth keeping. This was
  /// written to settle the medium of a pasted Drive link, since a Drive url
  /// carries no extension and the same url shape serves both media. It cannot:
  /// measured in Chrome, `drive.usercontent.google.com` answers a browser
  /// subresource request with 403 and no `Access-Control-Allow-Origin`, so the
  /// probe always failed closed. `curl` gets 200 with `ACAO: *` from that same
  /// url, which is why a curl-based check said the design worked while it never
  /// once worked in a browser. Drive is now resolved server-side by
  /// `/forms/media/import`, which sees the true `video/mp4`.
  ///
  /// Still correct for any host that does send CORS headers - `Content-Type` is
  /// CORS-safelisted, so a cross-origin response's type is readable even when
  /// its body is not - and kept for that.
  ///
  /// FAILS CLOSED, deliberately. A refusal, a timeout, a CORS-blocked probe or
  /// any content type that is neither image nor video all return null, and the
  /// caller must then leave the url alone rather than act on a guess. A wrong
  /// kind is worse than no answer: it is what sent a clip to a candidate as a
  /// still.
  ///
  /// NOT AUTHENTICATED and deliberately outside `_call`: this talks to a third
  /// party, not to our API, so it must carry no bearer. See `isOurMediaOrigin`.
  Future<String?> probeMediaKind(String url, {Duration? timeout}) async {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;
    try {
      final http.Response res = await _http
          .head(uri)
          .timeout(timeout ?? const Duration(seconds: 8));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      // `headers` is already lower-cased by package:http.
      final String type = (res.headers['content-type'] ?? '')
          .split(';')
          .first
          .trim();
      if (type.startsWith('image/')) return 'image';
      if (type.startsWith('video/')) return 'video';
      return null;
    } catch (_) {
      // A CORS refusal surfaces as a ClientException on web with no detail, and
      // is indistinguishable from the host being down. Either way: no answer.
      return null;
    }
  }

  // ── Writes ─────────────────────────────────────────────────────────────
  //
  // Create and update. Each mirrors a route in the module's `write.py`, which
  // allow-lists the fields it will accept: a field not named there cannot be
  // written through the API, so `state`, `results_released` and the scores
  // stay reachable only through the lifecycle actions that gate them.
  //
  // Every parameter below is optional and OMITTED when null, because the
  // server treats an absent key as "leave it alone". Sending nulls instead
  // would blank fields the caller never meant to touch.

  Future<Map<String, dynamic>> createAssessment({
    required String name,
    String? generatorId,
    int? questionLimit,
    int? durationMinutes,
    String? resultsRelease,
    double? subjectiveThreshold,
    double? passThreshold,
    String? startDate,
    String? endDate,
    List<String>? questionIds,
    // The proctoring and governance half of the form. The server allow-lists
    // every one of these on create (`ASSESSMENT_FIELDS`) and drops absent
    // keys, so sending them is safe - they were simply never sent, and an
    // operator who set eight proctoring rules got an assessment with the
    // defaults.
    Map<ProctorRule, bool>? rules,
    String? violationAction,
    int? maxViolations,
    String? aiViolationAction,
    int? aiMaxViolations,
    double? transcriptionThreshold,
    bool? requireReviewedRubric,
    bool? llmAutoScore,
    bool? resultsShowAnswers,
    // The POSITIVE the app reasons about. The server stores the inverse
    // (`preserve_question_order`) and does the flip itself; this side sends
    // `shuffle_questions` and never has to know the negative spelling exists.
    bool? shuffleQuestions,
  }) => _call('$kApiPrefix/assessments/create', <String, dynamic>{
    'name': name,
    'generator_id': ?generatorId,
    'question_limit': ?questionLimit,
    'duration_minutes': ?durationMinutes,
    'results_release': ?resultsRelease,
    'subjective_threshold': ?subjectiveThreshold,
    'pass_threshold': ?passThreshold,
    'start_date': ?startDate,
    'end_date': ?endDate,
    'question_ids': ?questionIds,
    ...?_ruleBody(rules),
    'violation_action': ?violationAction,
    'max_violations': ?maxViolations,
    'ai_violation_action': ?aiViolationAction,
    'ai_max_violations': ?aiMaxViolations,
    'transcription_threshold': ?transcriptionThreshold,
    'require_reviewed_rubric': ?requireReviewedRubric,
    'llm_auto_score': ?llmAutoScore,
    'results_show_answers': ?resultsShowAnswers,
    'shuffle_questions': ?shuffleQuestions,
  });

  /// The eight proctoring booleans, keyed by the FIELD names the module writes
  /// to (`rule_block_tab_switch` and friends). Null in, null out, so an omitted
  /// rule set leaves the server's defaults alone.
  ///
  /// `ProctorRule.field`, NOT `ProctorRule.wire`. The two differ - the module
  /// reports rules under the short names and accepts them only under the long
  /// ones - and this keyed by `wire`, so `ASSESSMENT_FIELDS` dropped all eight
  /// on create and the route still answered 200. See `ProctorRule.field`.
  static Map<String, dynamic>? _ruleBody(Map<ProctorRule, bool>? rules) =>
      rules == null
      ? null
      : <String, dynamic>{
          for (final MapEntry<ProctorRule, bool> e in rules.entries)
            e.key.field: e.value,
        };

  /// Edit a DRAFT assessment. The server refuses once it is running: the
  /// durations and proctoring rules are what candidates already agreed to.
  Future<Map<String, dynamic>> updateAssessment(
    String id, {
    String? name,
    String? generatorId,
    int? questionLimit,
    int? durationMinutes,
    String? resultsRelease,
    double? subjectiveThreshold,
    double? passThreshold,
    String? startDate,
    String? endDate,
    bool? blockTabSwitch,
    bool? blockCopyPaste,
    bool? blockRightClick,
    bool? blockDevtools,
    bool? watermark,
    bool? fullscreen,
    bool? webcam,
    bool? aiProctor,
    bool? requireSeb,
    int? maxViolations,
    String? violationAction,
    int? aiMaxViolations,
    String? aiViolationAction,
    bool? resultsShowAnswers,
    double? transcriptionThreshold,
    bool? llmAutoScore,
    bool? requireReviewedRubric,
    List<String>? questionIds,
    // See createAssessment: the app sends the POSITIVE and the server flips it.
    bool? shuffleQuestions,
  }) => _call('$kApiPrefix/assessments/$id/update', <String, dynamic>{
    'name': ?name,
    'generator_id': ?generatorId,
    'question_limit': ?questionLimit,
    'duration_minutes': ?durationMinutes,
    'results_release': ?resultsRelease,
    'subjective_threshold': ?subjectiveThreshold,
    'pass_threshold': ?passThreshold,
    'start_date': ?startDate,
    'end_date': ?endDate,
    'rule_block_tab_switch': ?blockTabSwitch,
    'rule_block_copy_paste': ?blockCopyPaste,
    'rule_block_right_click': ?blockRightClick,
    'rule_block_devtools': ?blockDevtools,
    'rule_watermark': ?watermark,
    'rule_fullscreen': ?fullscreen,
    'rule_webcam': ?webcam,
    'rule_ai_proctor': ?aiProctor,
    'rule_require_seb': ?requireSeb,
    'max_violations': ?maxViolations,
    'violation_action': ?violationAction,
    'ai_max_violations': ?aiMaxViolations,
    'ai_violation_action': ?aiViolationAction,
    'results_show_answers': ?resultsShowAnswers,
    'transcription_threshold': ?transcriptionThreshold,
    'llm_auto_score': ?llmAutoScore,
    'require_reviewed_rubric': ?requireReviewedRubric,
    'question_ids': ?questionIds,
    'shuffle_questions': ?shuffleQuestions,
  });

  Future<Map<String, dynamic>> createGenerator({
    required String name,
    String? sourceText,
    String? sopTitle,
    String? sopSummary,
  }) => _call('$kApiPrefix/generators/create', <String, dynamic>{
    'name': name,
    'source_text': ?sourceText,
    'sop_title': ?sopTitle,
    'sop_summary': ?sopSummary,
  });

  /// Edit a generator. Every argument is optional; only what is passed is sent.
  ///
  /// [questionCount] is how many questions a run should produce - **0 means
  /// "let the model decide from the SOP"**, any positive number is a target.
  /// The server derives the auto/fixed mode from this value, so there is only
  /// one thing to set and no way to send a contradiction.
  ///
  /// [imageLabelCount] caps how many labels one image-labelling question may
  /// carry. It is in the route's `GENERATOR_FIELDS` allow-list exactly like
  /// `sop_question_count`, and the module refuses anything below 1 - so it is
  /// sent only when a caller passes it, never as a defaulted 0 that a save
  /// would bounce.
  Future<Map<String, dynamic>> updateGenerator(
    String id, {
    String? name,
    String? sourceText,
    String? sopTitle,
    String? sopSummary,
    int? questionCount,
    Map<String, int>? shapeQuotas,
    int? imageLabelCount,
    bool? imageLabelLiveCapture,
  }) => _call('$kApiPrefix/generators/$id/update', <String, dynamic>{
    'name': ?name,
    'source_text': ?sourceText,
    'sop_title': ?sopTitle,
    'sop_summary': ?sopSummary,
    'sop_question_count': ?questionCount,
    // PER-SHAPE COUNTS: {'mcq': 2, 'template:7': 3}. An empty map CLEARS them,
    // so it must be sent when present rather than skipped as falsy.
    'shape_quotas': ?shapeQuotas,
    // Null-aware entry: an ABSENT key means "leave it alone" server-side, so
    // renaming a generator cannot quietly rewrite its label ceiling.
    'image_label_count': ?imageLabelCount,
    'image_label_live_capture': ?imageLabelLiveCapture,
  });

  /// The saved task templates, newest first.
  ///
  /// Cross-SOP on purpose: a shape authored for one project is often the right
  /// shape for the next, which is why the picker shows past templates.
  ///
  /// Returns the ALREADY-UNWRAPPED rows, the same `({rows, total})` shape
  /// [users] uses - and for the same reason: this route is paged, so `_call`
  /// hands back the whole envelope (its own unwrap only fires for a Map
  /// `data`), and that unwrap belongs HERE, once, rather than repeated ad hoc
  /// at each call site. A store-side `res['data']` read of this exact shape
  /// is what `envelope_unwrap_test.dart` exists to catch - it is
  /// indistinguishable, by source, from the double-unwrap bug that shipped a
  /// generator with no SOP attached and no error shown.
  /// [search] matches a template's name, and is accepted by
  /// `/api/v1/task_templates` (`task_templates.py`) - the same unused-parameter
  /// story as [forms] above.
  Future<({List<dynamic> rows, int total})> taskTemplates({
    String? search,
    int limit = 200,
    int offset = 0,
  }) async {
    final Map<String, dynamic> r = await _call(
      '$kApiPrefix/task_templates',
      <String, dynamic>{'search': ?search, 'limit': limit, 'offset': offset},
    );
    final Object? data = r['data'];
    final Object? meta = r['meta'];
    return (
      rows: data is List ? data : const <dynamic>[],
      total: meta is Map && meta['total'] is num
          ? (meta['total'] as num).toInt()
          : (data is List ? data.length : 0),
    );
  }

  /// Upsert one task template. Omit [id] to create.
  Future<Map<String, dynamic>> saveTaskTemplate(
    Map<String, dynamic> template,
  ) => _call('$kApiPrefix/task_templates/save', <String, dynamic>{
    'template': template,
  });

  /// Archive a task template. Never a hard delete: a launched assessment may
  /// cite it and its questions are already frozen.
  Future<Map<String, dynamic>> archiveTaskTemplate(int id) =>
      _call('$kApiPrefix/task_templates/delete', <String, dynamic>{'id': id});

  /// Ask the model to propose a template from this generator's SOP.
  ///
  /// Returns an EDITABLE draft; nothing is saved until the admin presses Save.
  /// This is a paid call, one per press.
  Future<Map<String, dynamic>> draftTaskTemplate(String generatorId) => _call(
    '$kApiPrefix/task_templates/draft',
    <String, dynamic>{'generator_id': int.tryParse(generatorId) ?? generatorId},
  );

  /// Attach a SOP or reference document to a generator.
  ///
  /// [bytes] is the raw file; it is base64-encoded here so callers hand over
  /// what they read from disk or a file picker rather than pre-encoding.
  ///
  /// Base64 in the JSON envelope, not multipart: the whole API keeps one auth
  /// path and one error shape. The server extracts text from docx/txt/md/csv
  /// on its own; PDFs and images are deliberately not extracted, because they
  /// are sent natively to the model.
  Future<Map<String, dynamic>> uploadResource(
    String generatorId, {
    required String name,
    required List<int> bytes,
    String category = 'sop',
  }) =>
      _call('$kApiPrefix/generators/$generatorId/resources', <String, dynamic>{
        'name': name,
        'category': category,
        'content': base64Encode(bytes),
      });

  Future<Map<String, dynamic>> deleteResource(
    String generatorId,
    String resourceId,
  ) =>
      _call('$kApiPrefix/generators/$generatorId/resources/$resourceId/delete');

  /// Read the SOP and derive its tags. Costs an LLM call.
  Future<Map<String, dynamic>> extractTags(String generatorId) =>
      _call('$kApiPrefix/generators/$generatorId/extract_tags');

  /// Generate question drafts from the SOP. The expensive one.
  Future<Map<String, dynamic>> generateQuestions(String generatorId) =>
      _call('$kApiPrefix/generators/$generatorId/generate');

  /// Ask for a password-reset email.
  ///
  /// ALWAYS SUCCEEDS FOR A WELL-FORMED ADDRESS, whether or not an account
  /// exists - the server answers identically either way so this call cannot be
  /// used to discover who holds one. The caller must render the returned
  /// message rather than inferring anything from it.
  ///
  /// This addon's own route, not `api_auth_gateway`'s: the emailed link has to
  /// point at THIS app, and the gateway's reset URL is one global value shared
  /// with every other Ethara front end.
  Future<Map<String, dynamic>> forgotPassword(String email) => _call(
    '$kApiPrefix/auth/forgot_password',
    <String, dynamic>{'email': email},
  );

  /// Set a new password from an emailed token.
  ///
  /// Signs the account out everywhere on success, including any session this
  /// browser still holds - so the caller sends the user back to sign in rather
  /// than trying to adopt a credential that has just been revoked.
  Future<Map<String, dynamic>> resetPassword({
    required String token,
    required String newPassword,
    required String confirmPassword,
  }) => _call('$kApiPrefix/auth/reset_password', <String, dynamic>{
    'token': token,
    'new_password': newPassword,
    'confirm_password': confirmPassword,
  });

  /// The password rules the server enforces: `{min_length, require}`.
  /// Public - the reset page calls it before anybody is signed in.
  Future<Map<String, dynamic>> passwordPolicy() =>
      _call('$kApiPrefix/auth/password_policy');

  /// Stop this generator's Extract skills run. Spends nothing; a reply still
  /// on its way is not applied.
  Future<Map<String, dynamic>> cancelTagExtract(String generatorId) =>
      _call('$kApiPrefix/generators/$generatorId/cancel_tag_extract');

  /// Stop a Draft from SOP still waiting on the model. The call already on
  /// the wire finishes and is billed; nothing after it is, and its draft is
  /// refused.
  Future<Map<String, dynamic>> cancelTemplateDraft(String generatorId) => _call(
    '$kApiPrefix/task_templates/cancel_draft',
    <String, dynamic>{'generator_id': int.tryParse(generatorId) ?? generatorId},
  );

  /// Stop this generator's run. Spends nothing, and keeps its drafts.
  ///
  /// A route of its own rather than a field on `update`, mirroring the server:
  /// the run's state is deliberately not writable through a general save.
  Future<Map<String, dynamic>> cancelGeneration(String generatorId) =>
      _call('$kApiPrefix/generators/$generatorId/cancel_generation');

  /// Stop this assessment's subjective scoring. Keeps every score already
  /// stored, and returns how many evaluators were settled.
  ///
  /// A route of its own rather than a field on `update`, mirroring the server
  /// and [cancelGeneration]: the scoring run's state is deliberately not
  /// writable through a general save. The single LLM call already in flight is
  /// not interrupted - it finishes and is billed - so this settles what is
  /// queued rather than pretending to claw back a request that has left.
  Future<Map<String, dynamic>> killScoring(String assessmentId) =>
      _call('$kApiPrefix/assessments/$assessmentId/kill_scoring');

  Future<Map<String, dynamic>> extractStructures(String generatorId) =>
      _call('$kApiPrefix/generators/$generatorId/extract_structures');

  Future<Map<String, dynamic>> approveAllDrafts(String generatorId) =>
      _call('$kApiPrefix/generators/$generatorId/approve_all');

  /// Merge near-duplicate tags into a canonical one.
  ///
  /// By id, not name: two tags can display the same text after normalisation,
  /// and merging by name would pick one of them arbitrarily.
  Future<Map<String, dynamic>> mergeTags({
    required String targetId,
    required List<String> sourceIds,
  }) => _call('$kApiPrefix/tags/merge', <String, dynamic>{
    'target_id': targetId,
    'source_ids': sourceIds,
  });

  Future<Map<String, dynamic>> normalizeTags(List<String> generatorIds) =>
      _call('$kApiPrefix/tags/normalize', <String, dynamic>{
        'generator_ids': generatorIds,
      });

  Future<Map<String, dynamic>> resendInvite(String attemptId) =>
      _call('$kApiPrefix/attempts/$attemptId/resend');

  Future<Map<String, dynamic>> resendAllInvites(String assessmentId) =>
      _call('$kApiPrefix/assessments/$assessmentId/resend_all');

  /// Write settings by their SHORT key.
  ///
  /// `Object` rather than `num`: the route's allow-list now carries text keys
  /// (the Vertex project, the model names, the bucket) and the three
  /// write-only secrets, alongside the numbers it started with. Only the keys
  /// present in the map are touched - an omitted secret keeps whatever is
  /// stored, which is what lets a form that can display "set" rather than the
  /// value itself save without wiping the credential.
  Future<Map<String, dynamic>> updateSettings(Map<String, Object> values) =>
      _call(
        '$kApiPrefix/settings/update',
        values.map((String k, Object v) => MapEntry<String, dynamic>(k, v)),
      );

  /// Replace the Vertex service-account JSON with an uploaded file.
  ///
  /// [content] is the file's bytes, base64 as every other upload on this API
  /// is. An empty string CLEARS the credential rather than replacing it.
  Future<Map<String, dynamic>> uploadServiceAccount({
    required String content,
    required String filename,
  }) => _call('$kApiPrefix/settings/service_account', <String, dynamic>{
    'content': content,
    'filename': filename,
  });

  /// Token spend and estimated cost, and the per-call ledger behind it.
  Future<Map<String, dynamic>> budget() => _call('$kApiPrefix/budget');

  /// The per-call spend ledger.
  ///
  /// `limit`/`offset`, not `page`/`page_size` - see `responses()`. This route
  /// shares the module's `paging()` helper, so the wrong names are accepted
  /// and ignored: the server silently caps at its default 40 and the ledger
  /// just stops after row 40 with no error anywhere.
  Future<Map<String, dynamic>> ledger({int limit = 200, int offset = 0}) =>
      _call('$kApiPrefix/ledger', <String, dynamic>{
        'limit': limit,
        'offset': offset,
      });

  /// Models, storage, retention and caps. The read side; [updateSettings]
  /// writes them.
  Future<Map<String, dynamic>> settings() => _call('$kApiPrefix/settings');

  void close() => _http.close();
}
