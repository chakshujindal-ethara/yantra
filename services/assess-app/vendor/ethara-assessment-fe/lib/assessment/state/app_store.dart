// The application store - one mutable source of truth for the whole module.
//
// Every screen reads from here and every action writes through here, so the
// domain invariants are enforced in one place rather than at each call site.
// The store is a `ChangeNotifier`: a mutation notifies, and the widget tree
// rebuilds from the new state.
//
// Three of the module's six invariants are enforced here:
//   1. Nothing reaches a candidate unreviewed - `approveDraft` is the only
//      path into the bank, and it refuses a draft with an unacknowledged
//      blocking warning.
//   3. Results are never revealed automatically - `resultsReleased` is only
//      ever set by `releaseResults` / `releaseOne`, both of which are wired to
//      an explicit human action. There is no un-release.
//   5. A terminal error is never retried automatically - `autoRetrySweep`
//      uses `LlmState.autoRetry`, which excludes `error`.
import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random, min;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/api_client.dart';
import '../domain/enums.dart';
import '../domain/form_models.dart';
import '../domain/gates.dart';
import '../domain/models.dart';
import '../domain/transcription.dart';
import '../../services/csv_export.dart';
import '../../services/json_export.dart';
import '../../services/leave_guard_stub.dart'
    if (dart.library.js_interop) '../../services/leave_guard_web.dart';
import '../../services/s3_direct_upload.dart';
import '../util/seed.dart';
import '../widgets/feedback.dart';
import 'seed_data.dart';

/// Where the store's data came from, which decides what the UI may promise.
///
/// `seed` is a complete, self-consistent fixture set covering every designed
/// state, so the app is reviewable with no backend at all. `live` is the Odoo
/// module. They are deliberately the same shape: a screen never asks which one
/// it is looking at.
enum DataSource { seed, live }

/// Where a load got to. Screens branch on this rather than on `data == null`,
/// because "loading", "loaded and genuinely empty" and "failed" are three
/// different things to a person and only one of them is an error.
enum LoadState { idle, loading, ready, failed }

/// A share link the server copied into this app's own storage, plus the MEDIUM
/// it turned out to be.
///
/// Two values, because they answer two different questions and the second one
/// cannot be derived from the first: the url says where the bytes now live, the
/// kind says whether the exam should draw a picture or a player. See
/// [AppStore.importFormMediaDetailed] for why only the server can tell.
class ImportedMedia {
  const ImportedMedia({required this.url, required this.kind});

  /// This app's own `/api/v1/forms/media/...` url.
  final String url;

  /// `'image'`, `'video'`, or `''` when the server named neither.
  final String kind;
}

/// Somebody an import left out, and the server's reason.
typedef SkippedInvite = ({String name, String email, String reason});

/// One skipped person as a line: `Name <email>: reason`.
String skippedLine(SkippedInvite s) => '${s.name} <${s.email}>: ${s.reason}';

/// What importing a roster WOULD do, from a dry run that writes nothing.
///
/// [error] is set, and the rest empty, when the check itself failed.
/// [refused] when the server turned the FILE down (400 / 422): the real import
/// would refuse it too, batch by batch, after landing every batch before the
/// bad row - so the sheet must not send it.
typedef ImportCheck = ({
  int added,
  int already,
  List<SkippedInvite> skipped,
  String? error,
  bool refused,
});

/// One row of an assessment's roster: the attempt, and the name that arrived
/// with it.
///
/// The name travels ON THE ROW rather than through [AppStore.people] because
/// that list is rebuilt wholesale by the console-wide attempts walk - a name
/// contributed only by the roster route would survive until the next refresh and
/// then vanish, which reads on screen as a candidate turning into an id.
class RosterRow {
  const RosterRow(this.attempt, this.name);

  final Attempt attempt;
  final String name;
}

/// A violation report the server has not answered yet (BR-D15).
class ViolationRow {
  const ViolationRow({
    required this.reason,
    required this.at,
    this.ends = false,
  });

  final String reason;

  /// Epoch milliseconds on the server's clock: the report's own stamp, sent
  /// as `at` on every try, so the server counts a resent report once.
  final int at;

  /// This one took the sitting to its limit under auto-submit: until the
  /// server answers it, the exam is locked.
  final bool ends;
}

/// What destroying an assessment would cost, as the SERVER counted it.
///
/// Built from the delete route's `confirm_required` refusal, which is the
/// answer to step one rather than a failure: the paper is archived by then and
/// these are the numbers the final confirmation states. Every count is the
/// server's own, because the sentence an operator agrees to and the work that
/// follows it must come from the same place.
class AssessmentDeletePlan {
  const AssessmentDeletePlan({
    this.candidateCount = -1,
    this.responseCount = -1,
    this.ledgerRowsKept = -1,
    this.liveAttemptCount = 0,
  });

  /// Candidates on the roster, whose attempts go with the assessment.
  final int candidateCount;

  /// Recorded responses that go with them.
  final int responseCount;

  /// LLM ledger rows that SURVIVE the delete, still counting against the
  /// day's spend. The one number here that is not a loss.
  final int ledgerRowsKept;

  /// People mid-sitting. Non-zero means nothing has been archived yet and the
  /// operator owes a separate answer first - stopping their clock is a
  /// different question from destroying the paper.
  final int liveAttemptCount;

  bool get needsLiveConfirm => liveAttemptCount > 0;
}

/// One list screen's SERVER-side search result set.
///
/// A slice of its own, deliberately kept out of the console-wide caches
/// ([AppStore.assessments], [AppStore.bank], [AppStore.generators]). Those are
/// walked in full at boot and every KPI, picker and "show archived" toggle on
/// the screen reads them; writing one search's page over the top would shrink
/// every one of those counts to whatever the operator last typed.
class SearchSlice<T> {
  /// The rows the server matched. ONE page - see [partial].
  List<T> rows = <T>[];

  /// How many rows the server says match, across every page.
  int total = 0;

  /// The term [rows] answers. Empty means no server search is in effect and the
  /// screen renders its own cache.
  String term = '';

  bool loading = false;
  String error = '';

  /// Monotonic, so a slow response for an abandoned term can be dropped rather
  /// than painted over a newer one.
  int seq = 0;

  bool get active => term.trim().isNotEmpty;

  /// True when the server matched more rows than this page holds, which is the
  /// case a screen must SAY rather than imply away (requirement 2.5).
  bool get partial => total > rows.length;

  void clear() {
    rows = <T>[];
    total = 0;
    term = '';
    loading = false;
    error = '';
  }
}

/// Rows per roster page.
///
/// 100, not 200 and not 572. The route clamps at 200, and a 572-person cohort is
/// six pages at this size - so no page can reach the clamp and the operator is
/// not handed a table longer than the one this change exists to make readable.
const int _kRosterPageSize = 100;

class AppStore extends ChangeNotifier {
  AppStore({
    Toaster? toaster,
    ApiClient? api,
    // INJECTED THE SAME WAY `api` IS, and for the same reason: so a test can
    // drive the real code path without waiting real seconds. Production never
    // passes either, so the defaults below ARE the shipped behaviour - this is
    // a seam for the clock, not a switch on the feature.
    Duration answerDebounce = answerDebounceDefault,
    Duration answerMaxWait = answerMaxWaitDefault,
    // The wait before an unsent violation report is tried again, the same
    // seam. See [violationRetryDefault].
    Duration violationRetry = violationRetryDefault,
    // The page's `beforeunload` hold, injected for the same reason.
    void Function(void Function()? onLeave) leaveGuard = setLeaveGuard,
    // The client the browser-to-S3 media POST goes through. Null in production
    // (a bare client is made per upload); a test injects one to see the request.
    http.Client? s3Client,
  }) : toaster = toaster ?? Toaster(),
       _api = api ?? ApiClient(),
       _debounceFor = answerDebounce,
       _maxWaitFor = answerMaxWait,
       _reportRetryEvery = violationRetry,
       _leaveGuard = leaveGuard,
       _s3Client = s3Client,
       // Whether this store may CLOSE that client - see dispose().
       _ownsApi = api == null,
       // An explicitly injected client means a backend, whatever the build
       // was configured with. Without this a test binary - which has no
       // --dart-define, so `hasBackend` is false - would fall back to
       // fixtures and report itself signed in before anyone signed in.
       source = (api != null || hasBackend)
           ? DataSource.live
           : DataSource.seed {
    // With no backend the app runs on its fixtures, which is the default for
    // design review. With one, nothing loads until somebody signs in: the API
    // scopes every response to the caller.
    if (source == DataSource.seed) {
      _load();
      loadState = LoadState.ready;
    }
  }

  final Toaster toaster;

  /// The live pacing for answer writes. See [answerDebounceDefault], [answerMaxWaitDefault].
  final Duration _debounceFor;
  final Duration _maxWaitFor;
  final Duration _reportRetryEvery;

  final ApiClient _api;

  /// True only when this store built its own [ApiClient].
  ///
  /// A store handed a client is a BORROWER: the Session owns it and outlives
  /// this store. Same rule `AssessmentSection.dispose` already follows.
  final bool _ownsApi;

  /// The client, for LEAF panels that fetch their own detail.
  ///
  /// Read-only and null in seed mode. A panel like the chatter timeline is
  /// embedded on several screens and belongs to none of them; routing it
  /// through the store would put an unrelated list on the global refresh path
  /// and make every screen pay for it.
  ApiClient? get api => _live ? _api : null;

  // ── Session ─────────────────────────────────────────────────────────────

  /// Where the data in this store came from.
  ///
  /// It must NOT default to `seed` when there is a server: `isAuthenticated`
  /// treats seed as always signed in (there is no account behind fixtures), so
  /// a seed default would report the user authenticated before they had signed
  /// in and the router's auth gate would never fire.
  DataSource source;
  LoadState loadState = LoadState.idle;

  /// Actions currently in flight, keyed `verb:recordId`.
  ///
  /// `loadState` is page-level and says nothing about a single slow call, so a
  /// generation run, a tag extraction or an upload looked identical to an idle
  /// screen until its toast landed - and operators pressed the button twice.
  /// Keyed rather than a single flag because two generators can be working at
  /// once and only the one being looked at should show a spinner.
  final Set<String> _busy = <String>{};

  bool isBusy(String key) => _busy.contains(key);

  /// Run [body] with [key] marked busy. The flag is cleared in a finally, so a
  /// thrown call cannot leave a button spinning for the rest of the session.
  Future<T> withBusy<T>(String key, Future<T> Function() body) async {
    _busy.add(key);
    notifyListeners();
    try {
      return await body();
    } finally {
      _busy.remove(key);
      notifyListeners();
    }
  }

  /// Why the last load failed, in the module's own words where it said so.
  String? loadError;

  /// True once `/api/v1/auth/session` has succeeded.
  ///
  /// Fixtures are "authenticated" by definition - there is no server to
  /// refuse them, and gating the demo behind a login nobody can pass would
  /// make the app unreviewable without a backend.
  bool get isAuthenticated =>
      source == DataSource.seed ? true : _api.isAuthenticated;

  /// What the login screen shows under the title, so it is never ambiguous
  /// which server the credentials are about to go to.
  String get backendLabel =>
      hasBackend ? kApiBaseUrl : 'Demo data - no backend configured';

  /// Takes over the session the HOST portal already established.
  ///
  /// The user signed in once, on the host app's own login screen: no second
  /// sign-in, no second session to expire, same bearer token throughout.
  ///
  /// [orgRole] is the portal's role (`admin`/`pm`/`pl`/`tasker`/`guest`),
  /// mapped onto a portal here. It decides which SURFACE opens; it is not the
  /// security boundary. Every endpoint re-checks the caller's ETP groups and
  /// the record rules scope the rows, so a wrong guess here shows the wrong
  /// menu, never the wrong data.
  void adoptSession({
    String? orgRole,
    String name = '',
    String uid = '',
    String email = '',
    String? accessRoleWire,
    Set<Capability>? capabilities,
  }) {
    portal = Portal.fromOrgRole(orgRole);
    // WHICH RUNG, and WHAT MAY BE CHANGED - two facts, both from the server.
    //
    // `orgRole` above still decides which SHELL is drawn, and it reports "admin"
    // for a read-only Manager too, because a Manager belongs in the console.
    // These two narrow it: `accessRole` filters the rail, `caps` gates the
    // controls. Both default to full access when the server sends neither, which
    // is what keeps a client working against a backend that predates the fields.
    accessRole = AccessRole.parse(accessRoleWire);
    caps = capabilities ?? Capability.values.toSet();
    meName = name;
    meEmail = email;
    meId = uid;
    source = DataSource.live;
    notifyListeners();
    // Deliberately fire-and-forget: `initState` cannot await, and the load
    // reports its own progress through `loadState` for the banner to read.
    refresh();
  }

  /// Sets a new password on the signed-in account.
  ///
  /// Thin on purpose. Validation belongs to the SERVER - a rule enforced only
  /// in Dart is a rule a caller can skip - so this forwards the refusal as the
  /// module worded it and lets the screen render it. The one thing it adds is
  /// refusing to pretend on fixtures, where there is no account to change.
  ///
  /// Returns whether the client is still signed in. False means the password
  /// DID change but the credential could not be renewed, so the caller should
  /// send the user back to the login screen rather than report a failure.
  Future<bool> changePassword(
    String newPassword, {
    String? confirmPassword,
  }) async {
    if (source == DataSource.seed || !hasBackend) {
      throw const ApiError(
        'This is demo data with no backend, so there is no account to change.',
        isDomain: true,
      );
    }
    final bool stillIn = await _api.changePassword(
      newPassword,
      confirmPassword: confirmPassword,
    );
    toaster.ok('Password updated');
    return stillIn;
  }

  /// What ELSE has to happen when this store signs out.
  ///
  /// The store can end the API session, but only [Session] decides which
  /// screen the app is on - `main.dart` switches on `session.signedIn` - so a
  /// sign-out raised inside the portal (the account card's "Sign In Again",
  /// the wrong-candidate gate's "Switch account") needs this to reach the
  /// login form. Set once, by the shell that owns both.
  VoidCallback? onSignedOut;

  Future<void> signOut() async {
    try {
      // Bounded, like [Session.signOut]: a stalled connection must not keep
      // the paper on screen. The client has already forgotten the credential
      // ([ApiClient.logout]), so nothing waits on the reply.
      await _api.logout().timeout(const Duration(seconds: 2));
    } catch (_) {
      // A failed logout still ends the local session: leaving the app looking
      // signed-in because the server did not answer would be worse than
      // dropping a cookie the server will expire on its own.
    }
    // A retry armed before sign-out would re-fetch as the signed-out user and
    // raise a fresh banner over the login screen.
    _cancelReconnect();
    _clear();
    loadError = null;
    source = hasBackend ? DataSource.live : DataSource.seed;
    loadState = hasBackend ? LoadState.idle : LoadState.ready;
    if (!hasBackend) _load();
    notifyListeners();
    onSignedOut?.call();
  }

  /// Pulls everything the current role may see.
  ///
  /// One method rather than per-screen fetching: the store is the single
  /// source of truth, and a screen that fetched for itself could disagree with
  /// the rail's badge counts sitting right next to it.
  /// [background] keeps the screen still.
  ///
  /// A refresh that flips `loadState` to `loading` makes every screen swap to
  /// its skeleton and back. That is right for a first load and WRONG for a
  /// poll: `pollGeneration` calls this every 2 seconds while a generator runs,
  /// so the generator page - images and all - was tearing down and rebuilding
  /// twice per cycle. That is the flicker. Same story in the review queue,
  /// where `_act` refreshes after every approve/deny.
  ///
  /// ONE RUN AT A TIME. Calls that arrive while a run is in flight share a
  /// single trailing run instead of each starting their own: every action ends
  /// in a refresh, a refresh takes seconds, and overlapping ones stacked
  /// identical bursts on prod (ledger x5, bank x4 in the same second). The
  /// trailing run still happens, so a write that landed mid-run is re-read.
  Future<void> refresh({bool background = false}) {
    if (source != DataSource.live) return Future<void>.value();
    _refreshLoud = _refreshLoud || !background;
    final Future<void>? running = _refreshRun;
    if (running == null) {
      final bool loud = _refreshLoud;
      _refreshLoud = false;
      return _refreshRun = _refreshOnce(
        background: !loud,
      ).whenComplete(() => _refreshRun = null);
    }
    return _refreshNext ??= running.then((_) {
      _refreshNext = null;
      if (_disposed) return null;
      return refresh(background: !_refreshLoud);
    });
  }

  Future<void>? _refreshRun;
  Future<void>? _refreshNext;
  bool _refreshLoud = false;

  Future<void> _refreshOnce({required bool background}) async {
    if (!background) {
      loadState = LoadState.loading;
      notifyListeners();
    }
    loadError = null;

    try {
      if (portal == Portal.admin) {
        // A loud load is the full picture; a background one only catches up.
        await _loadAdmin(full: !background || attempts.isEmpty);
      } else {
        await _loadCandidate();
      }
      loadState = LoadState.ready;
      _cancelReconnect();
      // A job the SERVER is still running gets watched again, even though this
      // tab is not the one that started it. Both jobs live in a cron now, so
      // they outlive the page that asked: reloading mid-extraction used to
      // leave the run completely unobserved, and the tags only turned up if
      // the operator reloaded a second time on a hunch. No-op when nothing is
      // busy, and `pollGeneration` guards its own re-entry.
      if (generators.any(
        (Generator g) => g.sopGenState.isBusy || g.isExtractingTags,
      )) {
        unawaited(pollGeneration());
      }
    } on ApiError catch (e) {
      loadState = LoadState.failed;
      // A candidate gets no host name and no CORS: only what they can act on.
      loadError = e.isTransport && portal != Portal.admin
          ? 'No connection.'
          : e.message;
      // Only a transport failure earns a replay. A 4xx is the server's
      // considered answer and will say exactly the same thing next time, so
      // retrying it burns requests and keeps a banner up that a human has to
      // act on anyway.
      if (e.isTransport) _scheduleReconnect();
    } catch (e) {
      // Deliberately catching EVERYTHING, not just ApiError.
      //
      // A TypeError thrown inside a `fromJson` used to escape this method, so
      // `loadState` never left `loading`: the screen span a loader forever,
      // every list stayed empty behind it, and nothing was reported. A
      // spinner that never stops is the worst possible failure mode - it is
      // indistinguishable from a slow network, so nobody knows to look.
      //
      // Surfacing the exception text means a payload change shows up as a
      // readable error on the screen instead of an eternal spinner.
      loadState = LoadState.failed;
      loadError = 'Could not read the response from the server. $e';
    } finally {
      notifyListeners();
    }
  }

  /// Pending self-retry of a load that failed because nothing answered.
  Timer? _reconnect;
  int _reconnectAttempt = 0;

  /// True while the store is waiting to retry a failed load by itself, so the
  /// banner can say so instead of looking like a dead end.
  bool get isReconnecting => _reconnect != null;

  /// Keep trying until the server answers again.
  ///
  /// WHY THIS EXISTS: nothing in the app re-fetches on navigation. The store
  /// is loaded once and the banner lives above the router, so a backend that
  /// was down for ten seconds - a restart, a reload of an addon - left a red
  /// "could not load from the server" across every screen for the rest of the
  /// session, on pages whose own data had loaded perfectly well. The server
  /// coming back fixed nothing on its own, and the only way out was a Retry
  /// button most people read as "this app is broken" rather than "press me".
  ///
  /// Backs off 2s, 4s, 8s, 16s, then every 30s, so a long outage costs two
  /// requests a minute rather than a tight loop against a host that is down.
  void _scheduleReconnect() {
    _reconnect?.cancel();
    if (_disposed) return;
    const List<int> backoff = <int>[2, 4, 8, 16, 30];
    final int wait =
        backoff[_reconnectAttempt < backoff.length - 1
            ? _reconnectAttempt
            : backoff.length - 1];
    _reconnectAttempt++;
    _reconnect = Timer(Duration(seconds: wait), () {
      _reconnect = null;
      // Something else may have succeeded in the meantime - a Retry press, or
      // the background refresh that follows any action. Nothing to recover.
      if (_disposed || loadState != LoadState.failed) return;
      refresh(background: true);
    });
  }

  void _cancelReconnect() {
    _reconnect?.cancel();
    _reconnect = null;
    _reconnectAttempt = 0;
  }

  /// Run [call] only for an Admin; hand back [empty] for anyone else.
  ///
  /// Not a permission check - the server decides, and it will refuse this call
  /// whatever the client believes. It is there so a role that is REFUSED does
  /// not ASK: `_loadAdmin` fans out with `Future.wait`, which fails as a unit,
  /// so one expected 403 would paint a load-failure banner over the screens the
  /// role can legitimately use.
  Future<T> _ifAdmin<T>(Future<T> Function() call, T empty) =>
      accessRole == AccessRole.admin ? call() : Future<T>.value(empty);

  Future<void> _loadAdmin({bool full = true}) async {
    // The counters as they stood BEFORE this load, to tell which assessments'
    // attempts can have moved - see [_loadAttempts].
    final Map<String, String> stampsBefore = <String, String>{
      for (final Assessment a in assessments) a.id: _attemptsStamp(a),
    };
    // Form saves that land after this are newer than the list below.
    final int formTick = _formTick;
    // Issued together rather than one after another: sequential round trips
    // multiply the latency for data with no dependency between the parts.
    // Every list follows its pages. They used to take a single limit:200 call
    // each and silently drop row 201, which on the bank meant a question that
    // simply did not exist as far as the console was concerned.
    final List<Object> res = await Future.wait(<Future<Object>>[
      // ARCHIVED ROWS INCLUDED, for the same reason the bank includes retired
      // ones - see below. Everything that must not SEE an archived assessment
      // reads `visibleAssessments`, which filters them out; the list grid is
      // the one caller that wants them, because revealing them is what its
      // "Show archived" toggle is for.
      _allPages(
        (int l, int o) =>
            _api.assessments(limit: l, offset: o, includeArchived: true),
      ),
      // RETIRED ROWS INCLUDED, and filtered in the client. The route excludes
      // them by default - right for the picker a new assessment draws from,
      // but the bank screen's "Show archived" toggle would then reveal nothing
      // and the restore path would be unreachable.
      _allPages(
        (int l, int o) => _api.bank(limit: l, offset: o, includeRetired: true),
      ),
      _allPages((int l, int o) => _api.tags(limit: l, offset: o)),
      // ARCHIVED ROWS INCLUDED - same bargain as the two lists above. Every
      // count and picker reads `liveGenerators()`; only the generator list
      // reads `generators` raw.
      // ADMIN ONLY, so a read-only Manager must not ask for it.
      //
      // `Future.wait` fails as a unit and this method's `catchError` paints the
      // "Could not load from the server" banner over EVERY screen - so one
      // 403 on a list a Manager has no rail row for would make the six screens
      // they can use look broken. `/api/v1/generators` and `/api/v1/settings`
      // are the only two calls on this list a Manager is refused; every other
      // one is a read they are entitled to.
      //
      // The SLOT is kept and resolves empty, for the same reason the drafts
      // slot is kept: every assignment below is positional.
      _ifAdmin(
        () => _allPages(
          (int l, int o) =>
              _api.generators(limit: l, offset: o, includeArchived: true),
        ),
        const <Map<String, dynamic>>[],
      ),
      // DRAFTS ARE NOT WAITED FOR. This slot resolves instantly and the real
      // fetch runs after the screen is up - see `_loadDraftsInBackground`.
      //
      // WHY. Measured against the live-shaped database with all 14 of these
      // calls in flight at once, exactly as the browser issues them:
      //
      //     drafts       6.18s   <- sets the wall clock for the whole load
      //     forms        0.69s
      //     assessments  0.61s
      //     ...          every other call under 0.5s
      //
      // `Future.wait` finishes when its SLOWEST member does, so one endpoint
      // held the entire console on its skeleton while thirteen replies sat
      // there already parsed. Drafts is the heaviest list by far because a
      // draft carries rendered image specs, and it is the ONLY one on this
      // list that no landing screen reads: the dashboard shows none of it, and
      // its two real consumers (the review queue and a generator's detail)
      // are screens an operator has to navigate to.
      //
      // The rail's Review Queue badge does read it, so the badge appears a
      // moment after the rest of the console rather than with it. That is the
      // deliberate trade: a late badge against a blank screen.
      //
      // THE SLOT IS KEPT rather than removed. Every assignment below is
      // POSITIONAL, so deleting an entry here silently hands each list the
      // payload of its neighbour - the note that used to live on this line.
      // Holding the position means the indices below are untouched.
      Future<List<Map<String, dynamic>>>.value(const <Map<String, dynamic>>[]),
      // APPEND, never insert: every assignment below is positional, so
      // adding a call in the middle silently hands each list the payload of
      // its neighbour.
      // Admin only - see the generators slot above.
      _ifAdmin(() => _api.settings(), const <String, dynamic>{}),
      // CAPPED, unlike every other list here. This one grows with each answer
      // each candidate gives - one 30-question sitting adds 30 rows - so it is
      // the only list whose page count is unbounded in normal use. At 31,462
      // rows on stage the walk was 158 sequential POSTs per load. Two pages
      // cover the 400 most recent answers, which is what All responses shows
      // before an operator filters; the screen paginates the rest on demand.
      _allPages(
        (int l, int o) => _api.responses(limit: l, offset: o),
        maxPages: 2,
        // The population, kept beside the sample. Without it the screen can
        // only count what it holds, and a capped load reads as the whole table.
        reportTotal: (int n) => responsesTotal = n,
      ),
      // CAPPED (SNo 107). The ledger is one row per billable LLM call, so it
      // is the fastest-growing table on the platform - a grading wave writes
      // one per call per candidate - and this walked ALL of it on every
      // console refresh, at 200 rows a request.
      //
      // The cap could only be taken once the aggregate consumers stopped
      // needing the whole table: spend against the caps comes from
      // `_api.budget()` on the very next line, which the client cannot derive
      // by summing anyway, and the Budget screen's cost and call cards read
      // its `lifetime` totals. What is left reading `ledger` is the Budget
      // screen's other cards and panels, summed from these rows; the cards say
      // "last N calls" when that is a sample (F2-01).
      //
      // `ledgerTotal` carries the server's real count so the screen can say
      // how much it is not showing, the same bargain `/responses` already
      // takes two lines above.
      _allPages(
        (int l, int o) => _api.ledger(limit: l, offset: o),
        maxPages: 5,
        reportTotal: (int n) => ledgerTotal = n,
      ),
      // THE CAPS, which no client-side sum can produce. Summing the ledger
      // gives spend; it cannot say whether today's spend has reached the cap -
      // and "generation will refuse until tomorrow" is the one thing about
      // spend an operator has to know BEFORE pressing Generate.
      _api.budget(),
      // The RANKING, which the client cannot derive: it spans every assessment
      // and the cache holds only what has been opened. Appended last, per the
      // note above.
      // A SMALL PAGE HERE, THE CEILING ON DEMAND.
      //
      // This fan-out is what `pollGeneration` re-runs EVERY TWO SECONDS while
      // a generator is going. Raising the request to the server's 2,000-row
      // ceiling - which is what the honesty fix for the panel's "every
      // submitted attempt" claim first did - put up to ten times the payload
      // on a two-second poll, on exactly the cohort size that made the claim
      // wrong in the first place. That is a performance regression shipped
      // inside a performance pass.
      //
      // The claim is fixed by the NOTE, not by the size: the panel reads the
      // route's own `{total, returned, truncated}` and says "top 200 of 2,431"
      // when it is holding a sample. So a small page here is honest AND cheap,
      // and `loadLeaderboard` still asks for the ceiling when an operator
      // scopes to one assessment and actually wants the whole ranking.
      _api.leaderboard(limit: 200),
      // THE COHORT TOTALS, which the client also cannot derive. Deciding a
      // verdict locally needs the assessment's frozen question count, and a
      // list row carries none - so every attempt of an unopened assessment
      // counted as undecided, and opening one moved every figure on the
      // dashboard. Appended last, per the note above.
      _api.analytics(),
      _allPages((int l, int o) => _api.forms(limit: l, offset: o)),
    ]);

    List<Map<String, dynamic>> rows(int i) =>
        res[i] as List<Map<String, dynamic>>;

    // MERGE, never replace - see [_mergeAssessments]. A list row is a strict
    // subset of a detail row, and this line assigning it wholesale is what
    // erased the roster the Assign tab had just written.
    assessments = _mergeAssessments(assessments, rows(0));
    // MERGE, never replace - see [_mergeQuestions]. This line and the drafts
    // one below were the two the earlier fixes missed, and they erased the
    // answer key a reviewer had just opened.
    bank = _mergeQuestions(bank, rows(1));
    tags = rows(2).map(Tag.fromJson).toList();
    // MERGE, never replace. A LIST row is a strict SUBSET of a detail row:
    // it carries no `resources`, `allowed_types`, `select_all_types`,
    // `sop_question_count`, `question_count_mode` or `similar`. Assigning it
    // wholesale therefore ERASED everything the detail screen had hydrated -
    // and `_act` ends every mutation with a background refresh, so the erasure
    // fired on every action the operator took.
    //
    // That single line was both reported generator bugs. Upload an SOP: the
    // toast said "attached", then the corpus grid emptied a moment later,
    // because `resources` had been wiped. Tick a question type: the chip lit,
    // the server saved it, then the chip un-ticked, because `allowed_types`
    // had been wiped - indistinguishable from "the checkbox does not work".
    // It also reverted the question count to Auto after any other action, and
    // `pollGeneration` re-wiped both every 2 seconds during a run.
    generators = _mergeGenerators(generators, rows(3));
    // rows(4) IS DELIBERATELY NOT ASSIGNED. That slot is the placeholder for the
    // deferred drafts fetch above, so it is always empty - and
    // `_mergeQuestions` maps over the INCOMING rows, so assigning it would
    // clear `drafts` on every load. The Review Queue badge would blank on every
    // refresh, and `pollGeneration` calls this every 2 seconds during a run, so
    // it would blank repeatedly while an operator watched.
    //
    // The real fetch is `_loadDraftsInBackground`, kicked off below.
    final Map<String, dynamic> settingsBody = res[5] as Map<String, dynamic>;
    final Object? cfg = settingsBody['data'] ?? settingsBody;
    settings = cfg is Map<String, dynamic> ? cfg : <String, dynamic>{};
    responseRows = rows(6);
    // The LLM budget screen sums these. Without the fetch it summed an
    // empty list and reported $0.00 against $17.44 of real spend.
    ledger = rows(7).map(LedgerRow.fromJson).toList();
    final Map<String, dynamic> budgetBody = res[8] as Map<String, dynamic>;
    final Object? budgetData = budgetBody['data'] ?? budgetBody;
    budget = budgetData is Map<String, dynamic>
        ? budgetData
        : <String, dynamic>{};
    // MERGED, never replaced: a form with an edit the server has not taken
    // yet, or whose save landed after this list was read, keeps the local
    // copy (the one the designer holds), and one only this tab has so far
    // (just created or imported) stays.
    bool keepLocal(String id) =>
        _formUnsaved.containsKey(id) || (_formSavedAt[id] ?? -1) > formTick;
    final Map<String, FormDef> localForms = <String, FormDef>{
      for (final FormDef f in forms) f.id: f,
    };
    final List<FormDef> servedForms = rows(11).map(FormDef.fromJson).toList();
    final Set<String> servedIds = <String>{
      for (final FormDef f in servedForms) f.id,
    };
    forms = <FormDef>[
      for (final FormDef f in servedForms)
        (keepLocal(f.id) ? localForms[f.id] : null) ?? f,
      for (final FormDef f in localForms.values)
        if (!servedIds.contains(f.id) && keepLocal(f.id)) f,
    ];

    final Object board = res[9];
    if (board is ({List<dynamic> rows, Map<String, dynamic> meta})) {
      leaderboard = <Map<String, dynamic>>[
        for (final Object? r in board.rows)
          if (r is Map<String, dynamic>) r,
      ];
      leaderboardTotal = jval(board.meta, 'total', 0);
      leaderboardReturned = jval(board.meta, 'returned', leaderboard.length);
    }

    final Object analyticsBody = res[10];
    analytics = analyticsBody is Map<String, dynamic>
        ? CohortAnalytics.fromJson(analyticsBody)
        : null;
    // A full refresh is ALL-UP by definition, so the scope has to be reset with
    // it. Leaving a stale scope here would let the dashboard keep a filter
    // selected over numbers that had just been refetched for every assessment.
    analyticsScope = '';

    await _loadAttempts(
      full: full,
      moved: <String>{
        for (final Assessment a in assessments)
          if (stampsBefore[a.id] != _attemptsStamp(a)) a.id,
      },
    );

    // NOT AWAITED. The console is usable at this point; drafts arrive after.
    _loadDraftsInBackground();
  }

  /// True while the deferred drafts fetch is in flight.
  ///
  /// Guards re-entry: `pollGeneration` calls `refresh()` every two seconds
  /// during a generation run, and without this each tick would start another
  /// 6-second walk on top of the last.
  bool _draftsLoading = false;

  /// The deferred drafts fetch, while it is in flight.
  ///
  /// Exposed through [draftsSettled] because one caller genuinely CANNOT work
  /// without the drafts: `pollGeneration` decides whether to keep watching by
  /// reading their asset states, so with an empty list it sees nothing
  /// rendering and returns on its first tick - the exact regression the render
  /// poll's own test caught when this deferral was introduced.
  Future<void>? _draftsInFlight;

  /// Resolves once the deferred drafts fetch has landed (immediately if none is
  /// outstanding). For callers that read `drafts` to make a decision rather
  /// than to paint a badge.
  Future<void> draftsSettled() => _draftsInFlight ?? Future<void>.value();

  /// Fetch the draft list AFTER the blocking load has finished.
  ///
  /// Deliberately fire-and-forget: nothing on the landing screen reads
  /// `drafts`, so there is nothing to wait for. See the long note on the
  /// placeholder slot in [_loadAdmin] for the measurements behind this.
  ///
  /// Failure is swallowed on purpose. This runs outside the load's own error
  /// handling, so an exception here would surface as an unhandled async error
  /// and, worse, `loadError` would raise a banner over a console that is
  /// working perfectly - the drafts are a badge count, not the page. The next
  /// refresh tries again.
  void _loadDraftsInBackground() {
    if (source != DataSource.live || _draftsLoading) return;
    // NOT FOR A READ-ONLY MANAGER. `/api/v1/drafts` is Admin-only, and the
    // only thing `drafts` feeds is the Review Queue rail badge - a row a
    // Manager does not have. The `catchError` above meant the 403 was silent
    // rather than harmful, but it is still a refused request on every console
    // load, and a silent 403 in the network log is the first thing anybody
    // debugging this app will chase. Same argument as `_ifAdmin`; this call
    // sits outside `Future.wait`, so it needs its own gate.
    if (accessRole != AccessRole.admin) return;
    _draftsLoading = true;
    _draftsInFlight = _allPages((int l, int o) => _api.drafts(limit: l, offset: o))
        .then((List<Map<String, dynamic>> rows) {
          // MERGE, never replace - same reason as every other list here: a list
          // row is a strict subset of a detail row, and assigning it wholesale
          // erases what a reviewer has open.
          drafts = _mergeQuestions(drafts, rows);
          notifyListeners();
        })
        .catchError((Object _) {
          // Left as-is: the badge stays at its previous count rather than
          // dropping to zero, which would read as "nothing to review".
        })
        .whenComplete(() {
          _draftsLoading = false;
          _draftsInFlight = null;
        });
  }

  /// Every row of a paged list endpoint, following the pages.
  ///
  /// The routes clamp at 200 per call and report `total`. Stopping after the
  /// first page silently dropped row 201 onward, and because every admin KPI
  /// is derived from these lists the whole console would have under-reported
  /// without a single error to show for it.
  ///
  /// Bounded by `total` rather than "until a short page": a server that
  /// returns a full last page would otherwise loop forever.
  /// [maxPages] BOUNDS THE WALK. Following `has_more` to the end is right for
  /// a list whose size tracks the number of assessments; it is wrong for one
  /// that grows with every answer every candidate gives. `/responses` reached
  /// 31,462 rows on stage, so a single load issued 158 sequential POSTs - and
  /// with `pollGeneration` calling `refresh()` every two seconds, stage served
  /// a sustained 813 requests a minute against that one route and the whole
  /// console read as "the platform is slow". A cap turns an unbounded walk into
  /// a known ceiling; [pagesTruncated] records when one was hit, so the
  /// shortfall is visible instead of silent.
  Future<List<Map<String, dynamic>>> _allPages(
    Future<Map<String, dynamic>> Function(int limit, int offset) fetch, {
    int maxPages = 1000,

    /// Where to record the SERVER's own row count, when the caller has a
    /// screen that must name the real population rather than the sample.
    ///
    /// `meta.total` was read here to decide when to stop and then thrown away,
    /// so a capped walk left the client holding 400 rows and no idea that
    /// 4,471 existed. Every count on the Responses screen is folded from the
    /// rows, which is how "Answers 400" came to describe a table of 4,471.
    void Function(int total)? reportTotal,
  }) async {
    const int pageSize = 200;
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    int offset = 0;
    int pages = 0;
    while (true) {
      final Map<String, dynamic> page = await fetch(pageSize, offset);
      final List<Map<String, dynamic>> rows = _rows(page);
      out.addAll(rows);
      pages++;
      // `total` lives in `meta`, NOT at the top level and NOT inside `data`
      // (which is the row list itself). `_call` returns the whole envelope
      // when `data` is a list, so `meta` is reachable here - reading
      // `page['total']` would always miss and stop after the first page,
      // which is the exact bug this method exists to fix.
      final Map<String, dynamic> meta =
          (jget(page, 'meta') as Map<String, dynamic>?) ?? <String, dynamic>{};
      final int total = jval(meta, 'total', out.length);
      final bool hasMore = jval(meta, 'hasMore', false);
      // Reported on EVERY page, not only when the cap is hit: a walk that
      // completes must overwrite a stale total from a previous load, or a
      // filter that shrinks the table would leave the old, larger figure on
      // screen claiming rows that are no longer there.
      reportTotal?.call(total);
      offset += pageSize;
      if (rows.isEmpty || (!hasMore && out.length >= total)) break;
      // NO SILENT TRUNCATION. Stopping short is a deliberate trade against an
      // unbounded route, but a screen showing a subset while reading like the
      // whole set is the failure this records.
      if (pages >= maxPages) {
        pagesTruncated = true;
        break;
      }
    }
    return out;
  }

  /// Fold list rows into the generators already held, keeping detail-only
  /// fields the list route does not send.
  ///
  /// A generator the list no longer returns is dropped, so an archive still
  /// takes effect; a generator not yet hydrated is taken as-is.
  List<Generator> _mergeGenerators(
    List<Generator> current,
    List<Map<String, dynamic>> rows,
  ) {
    final Map<String, Generator> held = <String, Generator>{
      for (final Generator g in current) g.id: g,
    };
    return rows.map((Map<String, dynamic> row) {
      final Generator fresh = Generator.fromJson(row);
      final Generator? old = held[fresh.id];
      if (old == null) return fresh;
      // The list row is authoritative for everything it carries; the held
      // record is authoritative for everything it does not.
      return fresh.copyWith(
        resources: fresh.resources.isEmpty ? old.resources : fresh.resources,
        // PER-SHAPE COUNTS and the TASK REGISTRY are detail-only fields. A list
        // row omits both, so assigning them wholesale would wipe the quotas the
        // examiner just set and empty the task registry - the same erasure this
        // merge exists to prevent for `resources` and `allowedTypes`.
        shapeQuotas: row.containsKey('shape_quotas')
            ? fresh.shapeQuotas
            : old.shapeQuotas,
        tasks: row.containsKey('tasks') ? fresh.tasks : old.tasks,
        allowedTypes:
            row.containsKey('allowed_types') || row.containsKey('allowedTypes')
            ? fresh.allowedTypes
            : old.allowedTypes,
        sopQuestionCount:
            row.containsKey('sop_question_count') ||
                row.containsKey('sopQuestionCount')
            ? fresh.sopQuestionCount
            : old.sopQuestionCount,
        // DETAIL-ONLY, so it has to be listed here too. The list route does
        // not send `image_label_count`, and `Generator.fromJson` defaults an
        // absent key to 20 - so without this line every background refresh
        // would quietly reset a generator pinned to 8 labels back to 20, and
        // `_act` fires a refresh after every mutation. That is the same bug
        // this whole method exists for, one field further down.
        imageLabelCount:
            row.containsKey('image_label_count') ||
                row.containsKey('imageLabelCount')
            ? fresh.imageLabelCount
            : old.imageLabelCount,
        imageLabelLiveCapture:
            row.containsKey('image_label_live_capture') ||
                row.containsKey('imageLabelLiveCapture')
            ? fresh.imageLabelLiveCapture
            : old.imageLabelLiveCapture,
        questionCountMode:
            row.containsKey('question_count_mode') ||
                row.containsKey('questionCountMode')
            ? fresh.questionCountMode
            : old.questionCountMode,
        similar: fresh.similar.isEmpty ? old.similar : fresh.similar,
        meta: fresh.meta.isEmpty ? old.meta : fresh.meta,
        // Detail-only, same as the counts above.
        draftCounts:
            row.containsKey('draft_counts') || row.containsKey('draftCounts')
            ? fresh.draftCounts
            : old.draftCounts,
      );
    }).toList();
  }

  /// Fold list rows into the assessments already held, keeping detail-only
  /// fields the list route does not send.
  ///
  /// EXACTLY THE BUG [_mergeGenerators] EXISTS FOR, on the model beside it.
  /// `assessment_row` carries no `roster`, no `questions` and none of the
  /// policy block; `assessment_detail` adds all of them. Assigning list rows
  /// wholesale therefore ERASED whatever the detail screen had hydrated - and
  /// `_act` ends every mutation with a background refresh, so the erasure
  /// fired on every action the operator took.
  ///
  /// That is both reported Assign bugs. Press Assign, or invite by email, or
  /// import a CSV: the server stored the person, the toast said so, and a
  /// moment later `roster` was wiped back to empty, so the tab went on
  /// reading "Nobody is assigned yet" over a roster the database held. It
  /// also blanked `questions`, which is what rendered "0 questions" beside a
  /// launch gate complaining that 0 of 6 were selected.
  ///
  /// AND THE SHORTLIST, third of exactly this shape. `pool` and `inUseIds`
  /// arrived with the Selected Questions tab and were never added to the list
  /// below, so every background list refresh emptied both. Ticking a question
  /// on a draft emptied the whole tab about 600ms later - the moment the save's
  /// own background refresh landed. The toast read "Shortlist saved" over a
  /// table saying "Pick a question generator on the Configuration tab", with a
  /// non-zero badge still above it, because `questions` IS preserved here and
  /// `effectiveQuestionCount` falls back to `questions.length` when `pool` is
  /// empty. Nothing was lost server-side; re-opening the assessment restored
  /// it, which is what made it read as a display fault rather than a save one.
  /// `inUseIds` rides the same `sent('pool')` signal because it has no wire key
  /// of its own - `Assessment.fromJson` derives it from the pool rows'
  /// `in_use` flags.
  ///
  /// THE LIST BELOW HAS BEEN AUDITED, not extended by symptom: diffing
  /// `assessment_detail` against `assessment_row` in the backend's
  /// `controllers/api/serializers.py` leaves exactly these entries plus `pool`.
  /// There is no third gap. A fourth bug of this shape needs a NEW detail-only
  /// field, which must be added here at the same time it is added to the
  /// serializer - not another one already sitting in the payload unhandled.
  ///
  /// An assessment the list no longer returns is dropped, so a cancel still
  /// takes effect; one not yet hydrated is taken as-is.
  List<Assessment> _mergeAssessments(
    List<Assessment> current,
    List<Map<String, dynamic>> rows,
  ) {
    final Map<String, Assessment> held = <String, Assessment>{
      for (final Assessment a in current) a.id: a,
    };
    return rows.map((Map<String, dynamic> row) {
      final Assessment fresh = Assessment.fromJson(row);
      final Assessment? old = held[fresh.id];
      if (old == null) return fresh;
      // PRESENCE, not emptiness. An assessment whose roster the operator has
      // just emptied must be allowed to go back to empty, and a detail row
      // always carries the key - so the key is the signal, never the value.
      // `jget` is used rather than `containsKey` so both spellings count.
      bool sent(String camel) => jget(row, camel) != null;
      return fresh.copyWith(
        questions: sent('questions') ? fresh.questions : old.questions,
        // ONE SIGNAL FOR BOTH, and it has to be `pool`. There is no `inUseIds`
        // on the wire at all - `Assessment.fromJson` derives it from the pool
        // rows' `in_use` flags - so testing the two separately would let the
        // ticks and the rows they tick disagree: four rows kept from `old`, an
        // empty tick set taken from `fresh`, and a header reading "0 of 4 in
        // use" over them.
        pool: sent('pool') ? fresh.pool : old.pool,
        inUseIds: sent('pool') ? fresh.inUseIds : old.inUseIds,
        roster: sent('roster') ? fresh.roster : old.roster,
        rules: sent('rules') ? fresh.rules : old.rules,
        // Same key, same signal: it travels inside the rules block.
        watermarkLabel: sent('rules')
            ? fresh.watermarkLabel
            : old.watermarkLabel,
        // Detail-only, added with locked mode (`assessment_detail`).
        // On BOTH routes, so a row that lacks the KEY (a build that predates it)
        // must not blank the stamp a fresher read brought. A row carrying the
        // key as null is the server saying "not launched", and wins: `sent`
        // cannot tell the two apart, so this tests the key itself.
        launchedAt:
            row.containsKey('launched_at') || row.containsKey('launchedAt')
            ? fresh.launchedAt
            : old.launchedAt,
        sebQuitPassword: sent('sebQuitPassword')
            ? fresh.sebQuitPassword
            : old.sebQuitPassword,
        shuffleQuestions: sent('shuffleQuestions')
            ? fresh.shuffleQuestions
            : old.shuffleQuestions,
        subjectiveThreshold: sent('subjectiveThreshold')
            ? fresh.subjectiveThreshold
            : old.subjectiveThreshold,
        passThreshold: sent('subjectiveThreshold') || sent('passThreshold')
            ? fresh.passThreshold
            : old.passThreshold,
        resultsRelease: sent('resultsRelease')
            ? fresh.resultsRelease
            : old.resultsRelease,
        llmAutoScore: sent('llmAutoScore')
            ? fresh.llmAutoScore
            : old.llmAutoScore,
        requireReviewedRubric: sent('requireReviewedRubric')
            ? fresh.requireReviewedRubric
            : old.requireReviewedRubric,
        thresholdRecomputePending: sent('thresholdRecomputePending')
            ? fresh.thresholdRecomputePending
            : old.thresholdRecomputePending,
        violationAction: sent('violationAction')
            ? fresh.violationAction
            : old.violationAction,
        maxViolations: sent('maxViolations')
            ? fresh.maxViolations
            : old.maxViolations,
        aiViolationAction: sent('aiViolationAction')
            ? fresh.aiViolationAction
            : old.aiViolationAction,
        resultsShowAnswers: sent('resultsShowAnswers')
            ? fresh.resultsShowAnswers
            : old.resultsShowAnswers,
        transcriptionThreshold: sent('transcriptionThreshold')
            ? fresh.transcriptionThreshold
            : old.transcriptionThreshold,
        aiMaxViolations: sent('aiMaxViolations')
            ? fresh.aiMaxViolations
            : old.aiMaxViolations,
        // THE SAME PRESENCE RULE, and for these two it is not theoretical.
        // `refresh(background: true)` runs after EVERY `_act`, so flagging one
        // candidate while a cohort graded would land a list row over the
        // record - and a payload that did not carry these keys would take the
        // phase back to null. That is the banner going out mid-run, the watch
        // stopping, and the Kill button dropping back to the page-capped
        // attempts cache: the exact fault this field exists to end, re-entered
        // through the back door.
        scoringPhase: sent('scoringPhase')
            ? fresh.scoringPhase
            : old.scoringPhase,
        scoringSummary: sent('scoringSummary')
            ? fresh.scoringSummary
            : old.scoringSummary,
        scoringScored: sent('scoringScored')
            ? fresh.scoringScored
            : old.scoringScored,
        scoringCandidates: sent('scoringCandidates')
            ? fresh.scoringCandidates
            : old.scoringCandidates,
        scoringFinishedAt: sent('scoringFinishedAt')
            ? fresh.scoringFinishedAt
            : old.scoringFinishedAt,
      );
    }).toList();
  }

  /// Merge a question LIST payload over what the detail routes hydrated.
  ///
  /// Same reason as [_mergeAssessments] and `_mergeGenerators`, for the two
  /// caches that never got it: `/drafts` and `/bank` rows are a strict subset
  /// of their detail rows, and assigning them wholesale erased the answer key,
  /// the media, the rubric and the marking guide that opening the record had
  /// just fetched. Because `_act` ends every mutation with a background
  /// refresh, that erasure fired on every action the reviewer took - the key
  /// appeared, then vanished a second later, with no way to tell it apart from
  /// the server not having one.
  ///
  /// Called separately per cache on purpose: draft ids and bank ids are
  /// independent sequences that collide constantly, so one shared map across
  /// both would hand a draft the bank row that happens to share its number.
  List<Question> _mergeQuestions(
    List<Question> current,
    List<Map<String, dynamic>> rows,
  ) {
    final Map<String, Question> held = <String, Question>{
      for (final Question q in current) q.id: q,
    };
    return rows.map((Map<String, dynamic> row) {
      final Question fresh = Question.fromJson(row);
      final Question? old = held[fresh.id];
      if (old == null) return fresh;
      // PRESENCE, not emptiness - see [_mergeAssessments]. A list of keys
      // rather than one, because every detail-only field here has two wire
      // spellings and reading only one would treat a present field as absent.
      bool sent(List<String> keys) =>
          keys.any((String k) => jget(row, k) != null);
      return fresh.copyWith(
        // `options`/`correctAnswer` belong in THIS test, not only in their own.
        // A draft-detail row carries the flat key and no `dimensions`, and
        // `Question.fromJson` synthesises `dims` from it - so testing only for
        // `dimensions` would call that synthesised key absent and replace it
        // with the thin row's empty one, throwing away the very thing the
        // detail fetch went to get.
        dims: sent(<String>['dims', 'dimensions', 'options', 'correctAnswer'])
            ? fresh.dims
            : old.dims,
        options: sent(<String>['options']) ? fresh.options : old.options,
        correctAnswers: sent(<String>['correctAnswer'])
            ? fresh.correctAnswers
            : old.correctAnswers,
        rubric: sent(<String>['rubric', 'subjectiveRubric'])
            ? fresh.rubric
            : old.rubric,
        answerKey: sent(<String>['answerKey', 'subjectiveRubric'])
            ? fresh.answerKey
            : old.answerKey,
        images: sent(<String>['images']) ? fresh.images : old.images,
        videos: sent(<String>['videos', 'videoFiles'])
            ? fresh.videos
            : old.videos,
        boxKey: sent(<String>['boxKey']) ? fresh.boxKey : old.boxKey,
        labelBoxes: sent(<String>['labelBoxes'])
            ? fresh.labelBoxes
            : old.labelBoxes,
        officialReasoning: sent(<String>['officialReasoning'])
            ? fresh.officialReasoning
            : old.officialReasoning,
        solution: sent(<String>['solution']) ? fresh.solution : old.solution,
        solutionRationale: sent(<String>['solutionRationale'])
            ? fresh.solutionRationale
            : old.solutionRationale,
        coversElements: sent(<String>['coversElements'])
            ? fresh.coversElements
            : old.coversElements,
        imageBriefs: sent(<String>['imageBriefs'])
            ? fresh.imageBriefs
            : old.imageBriefs,
        videoBriefs: sent(<String>['videoBriefs'])
            ? fresh.videoBriefs
            : old.videoBriefs,
        detectionMode: sent(<String>['detectionMode'])
            ? fresh.detectionMode
            : old.detectionMode,
        usage: sent(<String>['usage']) ? fresh.usage : old.usage,
        advanced: sent(<String>['advanced']) ? fresh.advanced : old.advanced,
      );
    }).toList();
  }

  /// What an assessment's LIST ROW says about its attempts. Any change here
  /// means that assessment's attempts moved and are worth re-reading.
  static String _attemptsStamp(Assessment a) => <Object?>[
    a.state,
    a.assignedCount,
    a.submittedCount,
    a.releasableCount,
    a.releasedCount,
    a.awaitingScoringCount,
    a.responseCount,
    a.scoringPhase,
    a.scoringScored,
    a.scoringFinishedAt,
  ].join('|');

  /// [full] walks the capped table; otherwise this is a CATCH-UP read.
  ///
  /// The full walk is 25 sequential pages on prod (the route clamps a page at
  /// 200, `common.py` MAX_LIMIT) and it ran after EVERY action. A background
  /// refresh now reads the newest page, plus the attempts of each assessment
  /// in [moved] (its list-row counters changed), and keeps every other row it
  /// already held - so nothing on screen shrinks, and a quiet console costs
  /// one `/attempts` call instead of 25.
  ///
  /// On a backend that stamps its pages with `meta.server_time`, a background
  /// refresh asks only for what changed since the last read instead - see
  /// [_changedAttempts]. That also catches an old row of an assessment whose
  /// counters did not move, which the catch-up below never re-reads.
  Future<void> _loadAttempts({
    bool full = true,
    Set<String> moved = const <String>{},
  }) async {
    if (assessments.isEmpty) {
      attempts = <Attempt>[];
      return;
    }
    final DateTime? seen = _attemptsSeenAt;
    if (!full && seen != null) return _changedAttempts(seen);
    // ponytail: past 10 moved assessments the capped walk is the cheaper read.
    // Only reached on a backend without `changed_since` (see above).
    if (!full && moved.length <= 10) return _catchUpAttempts(moved);

    // ONE PAGED CALL, not one per assessment.
    //
    // This fanned out across every assessment - fine at five, a hundred round
    // trips at a hundred, on a refresh that runs every couple of seconds while
    // a generation is polling. `/api/v1/attempts` returns the same rows under
    // the same record rules in one query.
    //
    // The per-assessment route still exists and is still correct; it is what
    // an assessment's own roster asks for. This is the console-wide read.
    // CAPPED (SNo 107). One row per SITTING across every assessment, so this
    // grows with the cohort and not with the operator's screen: the
    // 741-sitting rig walks four pages, a 5,000-candidate programme would walk
    // twenty-five, on a refresh that runs every couple of seconds while a
    // generation polls.
    //
    // Safe to cap only because the figures that must be complete no longer
    // come from here: `analytics` supplies decided/passed/failed and the
    // distinct-people count, and `leaderboard` supplies the ranking - both
    // server-side, both added precisely because the client could not derive
    // them from a partial walk. What still reads `attempts` is the roster
    // table, which pages client-side.
    //
    // 5,000 rows is well past any roster anyone scrolls, and `attemptsTotal`
    // names the real population so a capped table cannot read as a complete
    // one.
    DateTime? now;
    final List<Map<String, dynamic>> rows = await _allPages(
      (int l, int o) =>
          _api.attempts(limit: l, offset: o).then((Map<String, dynamic> page) {
            // The FIRST page's clock: the walk has seen everything written
            // before it, and nothing after it is guaranteed.
            if (o == 0) now = _serverTime(page);
            return page;
          }),
      maxPages: 25,
      reportTotal: (int n) => attemptsTotal = n,
    );

    final List<Attempt> flat = rows.map(Attempt.fromJson).toList();
    // MERGE, never replace - see [_mergeAttempts].
    attempts = _mergeAttempts(attempts, rows, flat);
    people = _peopleIn(rows).values.toList();
    // Only once the walk has landed: a walk that threw part-way must not move
    // the stamp past rows it never merged.
    _attemptsSeenAt = now;
  }

  /// `meta.server_time` of the last `/attempts` read that landed. Null on a
  /// backend that sends none, which keeps the catch-up read.
  DateTime? _attemptsSeenAt;

  /// `meta.server_time` off an `/attempts` page. Null when absent, and when
  /// it is not UTC: a naive time would be read in this browser's zone.
  static DateTime? _serverTime(Map<String, dynamic> page) {
    final Object? meta = jget(page, 'meta');
    if (meta is! Map<String, dynamic>) return null;
    final DateTime? t = DateTime.tryParse(jval(meta, 'serverTime', ''));
    return t != null && t.isUtc ? t : null;
  }

  /// The background read on a backend that stamps its pages: only the rows
  /// written since [seen], less 5 s for writes that committed while that read
  /// ran. Merged by id over what is held - the server copy wins, nothing
  /// leaves the cache, and a sitting not held yet goes to the top, where the
  /// full walk's newest-first order would put it.
  ///
  /// `attemptsTotal` is left alone: its one reader compares it with
  /// `attempts.length`, and a new sitting grows that side instead.
  Future<void> _changedAttempts(DateTime seen) async {
    final String stamp = seen
        .subtract(const Duration(seconds: 5))
        .toIso8601String();
    // Whole seconds, rounded down: earlier is safe, and plainer to parse.
    final String since = '${stamp.substring(0, 19)}Z';
    DateTime? now;
    final List<Map<String, dynamic>> rows = await _allPages(
      (int l, int o) => _api
          .attempts(limit: l, offset: o, changedSince: since)
          .then((Map<String, dynamic> page) {
            if (o == 0) now = _serverTime(page);
            return page;
          }),
      maxPages: 25,
    );
    final Map<String, Attempt> fresh = <String, Attempt>{
      for (final Attempt a in _mergeAttempts(
        attempts,
        rows,
        rows.map(Attempt.fromJson).toList(),
      ))
        a.id: a,
    };
    final Set<String> held = <String>{for (final Attempt a in attempts) a.id};
    attempts = <Attempt>[
      for (final Attempt a in fresh.values)
        if (!held.contains(a.id)) a,
      for (final Attempt a in attempts) fresh[a.id] ?? a,
    ];
    people = <String, Person>{
      for (final Person p in people) p.id: p,
      ..._peopleIn(rows),
    }.values.toList();
    _attemptsSeenAt = now;
  }

  /// The person behind each attempt row, so a roster row shows a name rather
  /// than an employee id. De-duplicated: one person may sit several.
  static Map<String, Person> _peopleIn(List<Map<String, dynamic>> rows) {
    final Map<String, Person> byId = <String, Person>{};
    for (final Map<String, dynamic> row in rows) {
      final Object? who = row['candidate'];
      if (who is Map<String, dynamic>) {
        final Person p = Person.fromJson(who);
        if (p.id.isNotEmpty) byId[p.id] = p;
      }
    }
    return byId;
  }

  /// The background half of [_loadAttempts]: fresh rows win, held rows of
  /// unmoved, still-listed assessments stay where they were.
  Future<void> _catchUpAttempts(Set<String> moved) async {
    DateTime? now;
    final List<List<Map<String, dynamic>>> pages = await Future.wait(
      <Future<List<Map<String, dynamic>>>>[
        _api.attempts(limit: 200, offset: 0).then((Map<String, dynamic> page) {
          final Object? meta = jget(page, 'meta');
          if (meta is Map<String, dynamic>) {
            attemptsTotal = jval(meta, 'total', attemptsTotal);
          }
          // A backend upgraded mid-session starts stamping here, and the
          // next background read switches to `changed_since`.
          now = _serverTime(page);
          return _rows(page);
        }),
        for (final String id in moved)
          _allPages(
            (int l, int o) =>
                _api.attempts(limit: l, offset: o, assessmentId: id),
            maxPages: 25,
          ),
      ],
    );
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
      for (final List<Map<String, dynamic>> p in pages) ...p,
    ];
    final Set<String> listed = <String>{
      for (final Assessment a in assessments) a.id,
    };
    final Map<String, Attempt> next = <String, Attempt>{
      for (final Attempt a in _mergeAttempts(
        attempts,
        rows,
        rows.map(Attempt.fromJson).toList(),
      ))
        a.id: a,
    };
    for (final Attempt a in attempts) {
      if (listed.contains(a.assessmentId) && !moved.contains(a.assessmentId)) {
        next.putIfAbsent(a.id, () => a);
      }
    }
    attempts = next.values.toList();
    people = <String, Person>{
      for (final Person p in people) p.id: p,
      ..._peopleIn(rows),
    }.values.toList();
    _attemptsSeenAt = now;
  }

  /// [attempts], keeping what only the DETAIL route carries.
  ///
  /// The same hazard as [_mergeAssessments], on the one console cache that
  /// never got its merge: a list row is a strict SUBSET of a detail row.
  /// `evaluator_admin_row` sends no `answers` at all, and no `token` unless a
  /// Manager asked a detail route for it - so assigning the list wholesale
  /// erased the answer map `loadAttempt` had just filled, and `_act` ends
  /// every mutation with a background refresh. Re-score or Erase therefore
  /// emptied "Score details" to "This candidate has not answered anything
  /// yet." under a header still reading 10 / 10, and `pollGeneration` re-ran
  /// the same wipe every two seconds while a generation was in flight.
  ///
  /// [fresh] is passed in rather than re-parsed so the person-map walk above
  /// and this merge read the same rows exactly once.
  List<Attempt> _mergeAttempts(
    List<Attempt> current,
    List<Map<String, dynamic>> rows,
    List<Attempt> fresh,
  ) {
    final Map<String, Attempt> held = <String, Attempt>{
      for (final Attempt a in current) a.id: a,
    };
    return <Attempt>[
      for (int i = 0; i < fresh.length; i++)
        () {
          final Attempt now = fresh[i];
          final Attempt? old = held[now.id];
          if (old == null) return now;
          // PRESENCE, not emptiness - see [_mergeAssessments]. An attempt
          // whose answers an operator has just erased must be allowed to go
          // back to empty, so the KEY is the signal and never the value.
          bool sent(String camel) => jget(rows[i], camel) != null;
          return now.copyWith(
            resp: sent('answers') || sent('resp') ? now.resp : old.resp,
            token: sent('token') || sent('accessToken') ? now.token : old.token,
            // Detail-only, like the answers: a list row never carries the
            // test's median, so a fresh null must not blank the held one.
            testMedian: now.testMedian ?? old.testMedian,
          );
        }(),
    ];
  }

  Future<void> _loadCandidate() async {
    final Map<String, dynamic> mine = await _api.myAssessments();
    // The candidate endpoint returns attempts bucketed by state; the store
    // keeps one flat list and lets `attemptsForPerson` do the bucketing, so
    // both data sources feed the same screens.
    final Object? buckets = mine['buckets'];
    final List<Attempt> flat = <Attempt>[];
    if (buckets is Map<String, dynamic>) {
      for (final Object? bucket in buckets.values) {
        if (bucket is! List<dynamic>) continue;
        for (final Map<String, dynamic> row
            in bucket.whereType<Map<String, dynamic>>()) {
          flat.add(Attempt.fromJson(row));
        }
      }
    }
    attempts = flat;

    // WHO THIS CANDIDATE IS, off the block that was being dropped.
    //
    // `/me/assessments` has always sent `applicant` - id, name and email - and
    // this method read only `buckets`. The exam instructions page is what
    // wanted it: it named the candidate through `personById`, which is null for
    // a candidate twice over (this method never fills `people`, and the rows it
    // parses carry no `candidate` object, so `employeeId` is empty), and so it
    // read "the invited candidate" to every real candidate who ever saw it.
    //
    // This is the APPLICANT record, not the portal user, so it wins over
    // whatever the auth path set. Only when it says something, though: the
    // block is null for a signed-in user who is not a candidate, and blanking a
    // name `adoptSession` already supplied would trade one empty line for
    // another.
    final Object? who = mine['applicant'];
    if (who is Map<String, dynamic>) {
      final String n = (who['name'] ?? '').toString().trim();
      final String e = (who['email'] ?? '').toString().trim();
      if (n.isNotEmpty) meName = n;
      if (e.isNotEmpty) meEmail = e;
    }
  }

  /// The list inside an envelope, whatever key it arrived under.
  ///
  /// `_call` already unwraps `data`, but a list endpoint may return the array
  /// directly or nest it under `items`/`rows` depending on paging.
  List<Map<String, dynamic>> _rows(Map<String, dynamic> res) {
    for (final String key in const <String>[
      'items',
      'rows',
      'data',
      'results',
    ]) {
      final Object? v = res[key];
      if (v is List<dynamic>) {
        return v.whereType<Map<String, dynamic>>().toList();
      }
    }
    return const <Map<String, dynamic>>[];
  }

  void _clear() {
    generators = <Generator>[];
    drafts = <Question>[];
    bank = <Question>[];
    assessments = <Assessment>[];
    attempts = <Attempt>[];
    _attemptsSeenAt = null;
    people = <Person>[];
    jobs = <Job>[];
    ledger = <LedgerRow>[];
    budget = <String, dynamic>{};
    tags = <Tag>[];
    forms = <FormDef>[];
    meName = '';
    meEmail = '';
    // Per-sitting client state, and the one place a leak ACROSS sittings is
    // possible: with no backend, `signOut` calls `_load()`, which re-seeds the
    // SAME fixture attempt ids with a fresh violation count - so an entry that
    // survived would fold the first violation of the next demo sitting.
    _lastViolation.clear();
    sessionReplaced.clear();
    for (final String token in _reports.keys.toList()) {
      _dropReports(token);
    }
    _endedByViolation.clear();
    _changedAt.clear();
    // Same hazard, worse consequence: a surviving fingerprint tells the next
    // sitting its answer is already stored, so the autosave declines to send it
    // and the answer is never written. Question ids repeat across sittings of
    // the same paper, so this is reachable in the live path too, not just in
    // fixtures. See `_answerSent`.
    _answerSent.clear();
    _answerDirtySince.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _jobTicker?.cancel();
    _cancelReconnect();
    // A pending autosave firing after disposal would touch a closed client.
    for (final Timer t in _answerSync.values) {
      t.cancel();
    }
    _answerSync.clear();
    if (_leaveGuarded) _leaveGuard(null);
    _leaveGuarded = false;
    // Cleared with the timers: a fingerprint that outlived the store would tell
    // the next sitting an answer had already been sent.
    _answerSent.clear();
    _answerDirtySince.clear();
    _lastViolation.clear();
    for (final Timer t in _reportRetry.values) {
      t.cancel();
    }
    _reportRetry.clear();
    for (final Timer t in _formSync.values) {
      t.cancel();
    }
    _formSync.clear();
    for (final Timer t in _shortlistSync.values) {
      t.cancel();
    }
    _shortlistSync.clear();
    // ONLY a client this store created itself. `AppShell` injects
    // `session.api`, and the Session outlives every shell it builds - so
    // closing it here killed the app's one and only http.Client on sign-out.
    // The next sign-in then threw "Client is already closed" before a byte
    // left the browser, which surfaces as the transport error "Could not
    // reach the server at ... /api/v1/auth_token" - a message that blames the
    // backend for a client this app had shut. Only a full page reload cured
    // it, because only that built a new client. Signing in as a DIFFERENT
    // user hit the same path: AppShell is keyed on session.uid, so the shell
    // is disposed on every account switch.
    if (_ownsApi) _api.close();
    super.dispose();
  }

  // ── Entity tables ───────────────────────────────────────────────────────
  List<Generator> generators = <Generator>[];
  List<Question> drafts = <Question>[];
  List<Question> bank = <Question>[];
  List<Assessment> assessments = <Assessment>[];

  List<Attempt> attempts = <Attempt>[];
  List<Person> people = <Person>[];
  List<Job> jobs = <Job>[];

  /// Nothing has arrived from the server yet.
  ///
  /// Separates "still fetching" from "fetched, and genuinely empty": the first
  /// wants a skeleton, the second wants the screen's own empty state.
  bool get isEmpty =>
      generators.isEmpty &&
      drafts.isEmpty &&
      bank.isEmpty &&
      assessments.isEmpty &&
      // `attempts` too: the CANDIDATE portal loads only this list, so without
      // it `isEmpty` stayed true after a successful load and the first-paint
      // skeleton fired on every member refresh, not just the first.
      attempts.isEmpty;

  /// Records whose DETAIL fetch is in flight, as `kind:id`.
  ///
  /// Lets a detail screen tell "still arriving" from "genuinely not here". Every
  /// one of them used to render "not found - it may have been removed" while its
  /// own fetch was still running, which states a deletion that never happened.
  final Set<String> _hydrating = <String>{};

  bool isHydrating(String kind, String id) => _hydrating.contains('$kind:$id');

  /// Run [body] with `kind:id` marked in flight, notifying either way.
  Future<void> _withHydration(
    String kind,
    String id,
    Future<void> Function() body,
  ) async {
    _hydrating.add('$kind:$id');
    notifyListeners();
    try {
      await body();
    } finally {
      _hydrating.remove('$kind:$id');
      notifyListeners();
    }
  }

  /// Replace a record in a list, or append it when it is not there yet.
  ///
  /// The detail routes hydrate into a cache the LIST route filled. On a deep
  /// link or a refresh that cache is empty, so a plain `.map()` silently
  /// discarded the record it had just fetched.
  static List<T> _upsert<T>(List<T> items, T fresh, bool Function(T) matches) =>
      items.any(matches)
      ? items.map((T i) => matches(i) ? fresh : i).toList()
      : <T>[...items, fresh];

  List<LedgerRow> ledger = <LedgerRow>[];

  /// The server's own row counts for the two walks that are now capped.
  ///
  /// 0 means "not fetched yet". A screen folding a count out of the rows it
  /// holds must prefer these, or a capped walk reports its sample as the
  /// population - which is how "Answers 400" came to describe a table of
  /// 4,471 before `/responses` was capped and reported the same way.
  int ledgerTotal = 0;
  int attemptsTotal = 0;

  /// The server's spend aggregate: today's spend against the daily cap, the
  /// per-candidate cap, and lifetime totals. Empty until a live refresh.
  Map<String, dynamic> budget = <String, dynamic>{};

  /// Today's spend, the daily cap, and what is left - or null when the server
  /// has not reported them (seed mode, or a refresh that has not run).
  ({double spend, double cap, double? remaining, bool capped})?
  get budgetToday {
    final Object? today = budget['today'];
    if (today is! Map) return null;
    double d(Object? v) => v is num ? v.toDouble() : 0.0;
    final Object? rem = today['remaining_usd'];
    return (
      spend: d(today['spend_usd']),
      cap: d(today['cap_usd']),
      // null is MEANINGFUL: the server sends it when no cap is set, which is
      // a different state from "nothing left", and colouring them the same
      // would report an uncapped instance as one that had run out.
      remaining: rem is num ? rem.toDouble() : null,
      capped: today['capped'] == true,
    );
  }

  /// Spend and calls over the WHOLE ledger, or null from a server that does
  /// not send them. `ledger` holds only the newest 1,000 rows (F2-01).
  ({double spend, int calls})? get budgetLifetime {
    final Object? life = budget['lifetime'];
    if (life is! Map<String, dynamic>) return null;
    return (spend: jval(life, 'spendUsd', 0.0), calls: jval(life, 'calls', 0));
  }

  List<Tag> tags = <Tag>[];

  /// Form Studio's forms. LOCAL-ONLY for now: the collection backend ships in
  /// a later phase, so these live for the session and are deliberately left
  /// out of [isEmpty] (they never arrive from the server, so counting them
  /// would change what the first-paint skeleton means).
  List<FormDef> forms = <FormDef>[];

  FormDef? formById(String id) {
    for (final FormDef f in forms) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// A new form, already in the list, ready for the designer to open.
  FormDef createForm() {
    final FormDef f = formNewForm();
    forms = <FormDef>[...forms, f];
    persistForm(f);
    return f;
  }

  /// One pending save per form, so edits to two forms cannot cancel each
  /// other's write, and a burst of keystrokes becomes one request.
  final Map<String, Timer> _formSync = <String, Timer>{};

  /// Forms with an edit the server has not confirmed, by that edit's tick.
  final Map<String, int> _formUnsaved = <String, int>{};

  /// When each form's last save landed, on the same clock.
  final Map<String, int> _formSavedAt = <String, int>{};

  /// The save of each form still on the wire, for Publish to wait on.
  final Map<String, Future<void>> _formSaving = <String, Future<void>>{};

  /// The clock for both: bumped by every edit and every landed save, so a
  /// refresh can tell a save that landed after it began.
  int _formTick = 0;

  /// A save of [f] carrying edit [edit] landed.
  void _formLanded(String id, int? edit) {
    _formSavedAt[id] = ++_formTick;
    if (_formUnsaved[id] == edit) _formUnsaved.remove(id);
  }

  /// Every designer edit lands here: repaint immediately, save shortly.
  ///
  /// The whole document goes on every save (`/forms/save` upserts by the
  /// form's own id), so a lost request costs nothing - the next edit carries
  /// the full state again.
  void persistForm(FormDef f) {
    f.touch();
    notifyListeners();
    if (!_live) return;
    final int edit = _formUnsaved[f.id] = ++_formTick;
    _formSync[f.id]?.cancel();
    _formSync[f.id] = Timer(const Duration(milliseconds: 900), () {
      _formSync.remove(f.id);
      // ONE AT A TIME, IN ORDER: behind the save still on the wire. Two side by
      // side could land out of order and leave the older form on the server.
      late final Future<void> save;
      save = (_formSaving[f.id] ?? Future<void>.value())
          .then((_) async {
            // Deleted while it waited, which clears the unsaved mark: sending
            // it would bring the form back.
            if (!_formUnsaved.containsKey(f.id)) return;
            await _api.saveForm(f.toJson());
            _formLanded(f.id, edit);
          })
          .catchError((Object e) {
            // Still unsaved: a refresh keeps the local copy over the server's.
            toaster.bad(e is ApiError ? e.message : 'Form save failed');
          })
          .whenComplete(() {
            if (identical(_formSaving[f.id], save)) _formSaving.remove(f.id);
          });
      _formSaving[f.id] = save;
    });
  }

  /// See the `s3Client` constructor argument.
  final http.Client? _s3Client;

  /// Get [bytes] into the media store and answer `{url, storage, public}`.
  ///
  /// DIRECT TO S3 FIRST: presign, POST the bytes to the bucket, then tell the
  /// server it is done - a 100 MB clip never rides through the API as base64.
  /// The base64 route is used ONLY when presign says the server cannot do this
  /// (no such route: 404 or 405). Anything else - a 400 verdict, a 503
  /// `s3_not_configured` (base64 would 503 too) - and every failure once S3 has
  /// been asked is surfaced and never retried through base64: that would quietly
  /// push the same large file through the slow path the operator never chose.
  Future<Map<String, dynamic>> _sendFormMedia({
    required String name,
    required List<int> bytes,
    required String contentType,
  }) async {
    final Map<String, dynamic> ticket;
    try {
      ticket = await _api.presignFormMedia(
        name: name,
        contentType: contentType,
        size: bytes.length,
      );
    } on ApiError catch (e) {
      // 405 AS WELL AS 404. A server that predates the presign route does not
      // answer 404: its `<path:key>` media route is GET-only and matches the
      // path, so Werkzeug answers 405 Method Not Allowed.
      //
      // `isTransport` is for cross-origin dev, where that 405 (or a 404) comes
      // back with no CORS headers and the browser hands over a bare "Failed to
      // fetch". The cost is only a doubled failure during a real outage: nothing
      // has been uploaded yet, and the base64 call fails the same way.
      if (e.status == 404 || e.status == 405 || e.isTransport) {
        return _api.uploadFormMedia(
          name: name,
          contentType: contentType,
          dataB64: base64Encode(bytes),
        );
      }
      rethrow;
    }

    final Object? upload = ticket['upload'];
    final String key = (ticket['key'] ?? '').toString();
    if (upload is! Map<String, dynamic> || key.isEmpty) {
      throw const ApiError('The server sent an incomplete upload ticket.');
    }

    int? status;
    Object? postError;
    try {
      status = await postToS3(
        upload: upload,
        key: key,
        name: name,
        bytes: bytes,
        client: _s3Client,
      );
    } on Exception catch (e) {
      // AN UNREADABLE REPLY, NOT A LOST FILE. With no CORS on the bucket a
      // multipart POST still goes out (it is a "simple" request) and S3 stores
      // the file; only the answer is withheld from the page, which sees a bare
      // "Failed to fetch". Proven against the real bucket on 8 Oct 2026. So the
      // server, which asks S3 itself (`head_object`), decides below.
      postError = e;
    }
    if (status != null && (status < 200 || status >= 300)) {
      throw ApiError(
        'The storage bucket refused the upload (HTTP $status). '
        'Nothing was saved.',
        status: status,
      );
    }
    try {
      return await _api.completeFormMedia(key: key);
    } on ApiError catch (e) {
      if (postError != null && e.status == 404) {
        throw ApiError(
          'The file did not reach the storage bucket. Check the connection '
          'and try again. Nothing was saved.',
          isTransport: true,
          detail: '$postError',
        );
      }
      rethrow;
    }
  }

  /// Upload designer media; the returned URL goes into the item's field.
  /// Returns null on failure (already toasted) or in seed mode.
  Future<String?> uploadFormMedia({
    required String name,
    required List<int> bytes,
    required String contentType,
  }) async {
    if (!_live) {
      toaster.bad('Uploads need the live backend.');
      return null;
    }
    try {
      final Map<String, dynamic> r = await _sendFormMedia(
        name: name,
        bytes: bytes,
        contentType: contentType,
      );
      final String url = (r['url'] ?? '').toString();
      if (url.isEmpty) {
        toaster.bad('Upload failed: the server returned no URL.');
        return null;
      }
      if (r['storage'] == 's3' && r['public'] == false) {
        // Stored fine, but the bucket refused the public flag - the file
        // will not display until the team allows reads (policy or CDN).
        // Say so NOW, not when someone finds a broken image.
        toaster.bad(
          'Uploaded, but the bucket blocks public viewing - '
          'ask the team for a policy or CDN.',
        );
      } else {
        toaster.ok(r['storage'] == 's3' ? 'Uploaded to S3' : 'Uploaded');
      }
      return url;
    } on ApiError catch (e) {
      toaster.bad(e.message);
      return null;
    }
  }

  /// What kind of media a public url serves - `'image'`, `'video'`, or null.
  ///
  /// A thin passthrough to [ApiClient.probeMediaKind], here because the designer
  /// reaches the network only through the store. Returns null on any failure and
  /// the caller must then leave the url alone - see the doc there for why a
  /// guess is worse than no answer.
  Future<String?> probeMediaKind(String url) => _api.probeMediaKind(url);

  /// Copy a Google Drive share link into this app's own media storage, and
  /// return the app-local URL that replaces it.
  ///
  /// WHY THE SERVER DOES THE FETCHING. A Drive share link answers with the
  /// viewer PAGE, not the bytes, so nothing in the browser can render it - and
  /// the browser could not fetch it cross-origin anyway. Copying it once,
  /// server-side, is also what stops an exam depending on a third-party link
  /// the owner can move or unshare mid-sitting.
  Future<String?> importFormMedia(String sourceUrl) async =>
      (await importFormMediaDetailed(sourceUrl))?.url;

  /// Import a share link AND report which medium came back.
  ///
  /// WHY THE KIND MATTERS AND CANNOT BE GUESSED HERE. A Drive url carries no
  /// extension, and the browser cannot read the file's type for itself:
  /// `drive.usercontent.google.com` answers a subresource request with 403 and
  /// no `Access-Control-Allow-Origin`, while `lh3.googleusercontent.com` - the
  /// one Drive host a browser CAN read - reports `image/jpeg` even for a video,
  /// because it serves the poster frame. Trusting it publishes a clip as a
  /// still. The server has no such limit: it fetches with `requests` and sees
  /// the real `video/mp4`, and this route already reports it back as
  /// `content_type`. That value is the only trustworthy answer available, so it
  /// is what sets the item's kind.
  Future<ImportedMedia?> importFormMediaDetailed(String sourceUrl) async {
    if (!_live) {
      toaster.bad('Importing media needs the live backend.');
      return null;
    }
    try {
      final Map<String, dynamic> r = await _api.importFormMedia(url: sourceUrl);
      final String url = (r['url'] ?? '').toString();
      if (url.isEmpty) {
        toaster.bad('Import failed: the server returned no URL.');
        return null;
      }
      final String type = (r['content_type'] ?? '').toString().toLowerCase();
      return ImportedMedia(
        url: url,
        kind: type.startsWith('video/')
            ? 'video'
            : type.startsWith('image/')
            ? 'image'
            : '',
      );
    } on ApiError catch (e) {
      // The server's own words: it distinguishes "not shared" from "too large"
      // from "not a media file", and each one needs a different action from
      // the examiner.
      toaster.bad(e.message);
      return null;
    }
  }

  FormDef? duplicateForm(String id) {
    final FormDef? src = formById(id);
    if (src == null) return null;
    // Deep re-mint: sections, items and options too, not just the form id.
    // Two forms sharing item ids make the designer share text-field edit state
    // between them - see `formReminted`.
    final FormDef copy = formReminted(src, title: '${src.title} (copy)');
    forms = <FormDef>[...forms, copy];
    persistForm(copy);
    return copy;
  }

  /// Build a whole form from an uploaded JSON document and save it.
  ///
  /// Returns the new form, or null when the file could not be used (the reason
  /// is toasted). The document is never merged into an existing form: every id
  /// is re-minted, so importing twice gives two independent forms instead of
  /// the second silently overwriting the first.
  Future<FormDef?> importForm({
    required List<int> bytes,
    required String filename,
  }) async {
    if (bytes.length > kMaxFormStructureBytes) {
      toaster.bad(
        'That file is ${(bytes.length / 1024).round()} KB; the limit is '
        '${kMaxFormStructureBytes ~/ 1024} KB.',
      );
      return null;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      // Naming the position is what turns "invalid" into something fixable.
      toaster.bad('That file is not valid JSON: ${e.message}');
      return null;
    }

    final FormDef form;
    try {
      form = formFromImportedJson(
        decoded,
        // A file called `onboarding-quiz.json` is a better title than
        // "Imported form" when the document itself carries none.
        fallbackTitle: filename.replaceAll(
          RegExp(r'\.json$', caseSensitive: false),
          '',
        ),
      );
    } on FormImportException catch (e) {
      toaster.bad(e.message);
      return null;
    }

    forms = <FormDef>[...forms, form];
    persistForm(form);
    toaster.ok(
      'Imported "${form.title}" - ${form.sections.length} section'
      '${form.sections.length == 1 ? '' : 's'}, '
      '${form.questionCount} question${form.questionCount == 1 ? '' : 's'}',
    );
    return form;
  }

  /// Publish a form into the exam pipeline. Returns the new assessment's id
  /// plus the server's conversion notes, or null on failure (toasted).
  ///
  /// Flushes the debounced save FIRST: publish converts what the server
  /// holds, and a 900 ms-old edit still in the timer would silently not be
  /// part of the paper the candidates get.
  /// The problems from the last refused publish, for the caller to RENDER.
  ///
  /// A refusal is a work list, not a notification. It names one item per line
  /// ('"Q4 MCQ grid" (section "Part 2"): rows without an answer key: R1, R2.')
  /// and a form can fail on a dozen at once - but it was only ever toasted, and
  /// a toast lives 3200 ms and is `pointer-events: none`, so it cannot even be
  /// held open to be read. Testers were screenshotting the screen to keep their
  /// own to-do list, which is the clearest possible signal that the wrong
  /// surface was carrying it.
  ///
  /// Cleared at the START of every publish so a stale list can never be shown
  /// beside a fresh attempt.
  List<String> publishProblems = <String>[];

  Future<(String, List<String>)?> publishForm(String id) async {
    publishProblems = <String>[];
    final FormDef? f = formById(id);
    if (f == null) return null;
    if (!_live) {
      toaster.bad('Publishing needs the live backend.');
      return null;
    }
    // THE LAST EDIT GOES FIRST: one still in its debounce, one whose save
    // failed, and one on the wire (waited for). Publishing past any of them
    // published the server's stale copy and called it published.
    final Timer? pending = _formSync.remove(id);
    pending?.cancel();
    await _formSaving[id];
    if (pending != null || _formUnsaved.containsKey(id)) {
      try {
        final int? edit = _formUnsaved[id];
        await _api.saveForm(f.toJson());
        _formLanded(id, edit);
      } on ApiError catch (e) {
        toaster.bad(
          'Not published: the latest edits did not save. ${e.message}',
        );
        return null;
      }
    }
    try {
      final Map<String, dynamic> res = await _api.publishForm(id);
      f.published = true;
      final String asmId = jid(jget(res, 'assessment_id'));
      final List<String> warnings = <String>[
        for (final Object? w
            in (jget(res, 'warnings') as List<dynamic>?) ?? const <dynamic>[])
          '$w',
      ];
      toaster.ok('${f.title} published - assign candidates next');
      await refresh();
      return asmId.isEmpty ? null : (asmId, warnings);
    } on ApiError catch (e) {
      // A REFUSAL IS HANDED BACK, NOT JUST ANNOUNCED. `unpublishable` is the
      // one error on this route whose message is a LIST of items to go and fix,
      // one per line; every other error is a single sentence a toast suits
      // fine. Split here rather than at the call site so the parsing of the
      // server's wire shape stays in the layer that knows it.
      if (e.code == 'unpublishable') {
        publishProblems = <String>[
          for (final String line in e.message.split('\n'))
            if (line.trim().replaceFirst(RegExp(r'^-\s*'), '').isNotEmpty)
              line.trim().replaceFirst(RegExp(r'^-\s*'), ''),
        ];
        // The first line is the server's own heading ("The form is not ready to
        // publish:"), which the sheet supplies itself.
        if (publishProblems.length > 1 && publishProblems.first.endsWith(':')) {
          publishProblems = publishProblems.sublist(1);
        }
        notifyListeners();
        return null;
      }
      toaster.bad(e.message);
      return null;
    }
  }

  void deleteForm(String id) {
    // A save still in flight for a form being deleted would resurrect it.
    _formSync.remove(id)?.cancel();
    _formUnsaved.remove(id);
    forms = forms.where((FormDef f) => f.id != id).toList();
    notifyListeners();
    if (!_live) return;
    _api.deleteForm(id).catchError((Object e) {
      toaster.bad(e is ApiError ? e.message : 'Form delete failed');
      return <String, dynamic>{};
    });
  }

  // ── UI state that outlives a single screen ──────────────────────────────
  Portal portal = Portal.admin;

  /// Which rung of the Assessment v2 ladder the signed-in account is on.
  ///
  /// Defaults to [AccessRole.admin] so a fixture, a seed-data session and a
  /// client talking to a backend that does not send `access_role` all behave
  /// exactly as they did before the field existed. The server refuses what it
  /// refuses regardless; this only decides what is worth drawing.
  AccessRole accessRole = AccessRole.admin;

  /// What this account may CHANGE, as sent on the session payload.
  Set<Capability> caps = Capability.values.toSet();

  /// Whether the signed-in account may change [c].
  ///
  /// Read this instead of the old `portal.can(...)`: `Portal` is binary and
  /// cannot tell a read-only Manager from an Admin, so it answered `true` for
  /// both and every control stayed live for a role that may write nothing.
  bool can(Capability c) => caps.contains(c);

  /// Every answer, as `/api/v1/responses` reports it.
  ///
  /// This screen used to REBUILD its rows by joining attempts to
  /// `asm.questions` and `ev.resp`. Neither list payload carries those, so the
  /// join always produced nothing and the page read "0 answers" while three
  /// existed. The server already flattens this join; use its answer.
  List<Map<String, dynamic>> responseRows = <Map<String, dynamic>>[];

  /// True when a paged walk stopped at its cap rather than at the end of the
  /// list, so a screen can say it is showing the most recent rows instead of
  /// implying it holds every one. See [_allPages].
  bool pagesTruncated = false;

  /// How many answers EXIST, from `/api/v1/responses`' own `meta.total`.
  ///
  /// NOT the number held. The responses walk is capped at two pages (400 rows)
  /// because that list grows with every answer every candidate gives, and every
  /// count on the Responses screen is folded from the rows the client happens
  /// to hold - so "Answers 400" described a table of 4,471 on this dev
  /// database, and the operator had no way to tell. This is the denominator
  /// that makes the sample legible as a sample.
  ///
  /// 0 means "not loaded", which reads the same as "no answers" and is
  /// correct for both: a screen with no rows has nothing to qualify.
  int responsesTotal = 0;

  /// What the module is actually configured with, straight from
  /// `/api/v1/settings`. Empty until loaded.
  ///
  /// The settings screen used to print model names as literals in Dart. They
  /// were wrong the moment the deployment changed - it showed `imagen-4.0`
  /// and `veo-3.0` while the module was really calling `gemini-3-pro-image`
  /// and `veo-3.1-generate-001`. A screen whose whole job is "what is this
  /// configured to do" must not invent the answer.
  Map<String, dynamic> settings = <String, dynamic>{};

  String meId = 'P-1';

  /// The signed-in person's display name, as the server reported it.
  ///
  /// Held separately from the `people` table because a live session knows who
  /// you are before it knows the roster - and a candidate never loads a roster
  /// at all, so `personById(meId)` would be null for them.
  String meName = '';

  /// The signed-in person's email, as the server reported it.
  ///
  /// Same reason as [meName], and the exam instructions page is what needs it:
  /// it names the candidate whose sitting this is, and `personById` returns
  /// null there for BOTH the reasons above - no roster, and `employeeId` is
  /// empty on rows that came from `/me/assessments`.
  ///
  /// TWO WRITERS, because neither covers every way in. The auth paths read it
  /// off `session_user`, which every session fetches; `_loadCandidate` reads it
  /// off `/me/assessments`'s `applicant` block, which is the APPLICANT record
  /// rather than the portal user and so wins where both answer. A candidate
  /// arriving on an invitation link may never call the second - the exam state
  /// envelope carries no applicant block at all - which is why the first one
  /// exists.
  String meEmail = '';

  /// The last approve/deny, so it can be undone. Cleared once undone.
  ({String id, DraftState verdict})? lastDecision;

  /// Drafts whose blocking warnings the reviewer has acknowledged. This is the
  /// gate that unlocks approval, and it deliberately does not persist: an
  /// acknowledgement is for this sitting only.
  final Set<String> acknowledged = <String>{};

  void _load() {
    final SeedData s = SeedData.build();
    generators = s.generators;
    drafts = s.drafts;
    bank = s.bank;
    assessments = s.assessments;
    attempts = s.attempts;
    people = s.people;
    jobs = s.jobs;
    ledger = s.ledger;
    tags = s.tags;
    // One worked example, so the first visit to Form Studio demonstrates the
    // designer instead of opening on an empty list.
    forms = <FormDef>[formSample()];
  }

  // ── Lookups ─────────────────────────────────────────────────────────────

  /// The candidate's own answer sheet for one token.
  ///
  /// This is the only fetch a screen issues for itself, and it has to be: the
  /// route is scoped to a TOKEN, so there is nothing for the store's
  /// role-scoped `refresh()` to key it on, and a candidate holds exactly one
  /// sheet at a time. Everything the review renders comes back in this one
  /// response - name, marks and rows - so it never needs the Assessment
  /// record that `/api/v1/assessments` refuses a candidate.
  ///
  /// On seed data there is no server, so the sheet is built from the fixtures
  /// instead and design review keeps working without a backend.
  Future<AnswerSheet> answerSheet(String token) async {
    if (source != DataSource.live) return _seedAnswerSheet(token);
    return AnswerSheet.fromJson(await _api.examAnswers(token));
  }

  /// Answer sheets already fetched, by token.
  ///
  /// THE CANDIDATE'S ONLY ROUTE TO THEIR OWN PER-ANSWER MARKS.
  /// `/api/v1/attempts/<id>` is a manager route that 403s for them, and
  /// `/api/v1/me/assessments` is a list with no answers in it - but that list
  /// DOES carry a token per sitting, and `/api/v1/exam/<token>/answers` is
  /// theirs to call. So a cross-assessment breakdown for a candidate is built
  /// from N sheets rather than N attempt records.
  ///
  /// Cached because the performance screen asks per released sitting on every
  /// rebuild; without this each rebuild would re-request every sheet.
  final Map<String, AnswerSheet> sheetByToken = <String, AnswerSheet>{};

  /// Tokens currently in flight, so a rebuild cannot double-request one.
  final Set<String> _sheetsLoading = <String>{};

  /// Fetch one sheet into [sheetByToken], then notify.
  ///
  /// Silent on failure: a candidate whose sheet will not load still gets every
  /// other panel on the screen, and a toast per sitting would bury the page for
  /// a breakdown that is supplementary.
  Future<void> loadAnswerSheet(String token) async {
    if (token.isEmpty ||
        sheetByToken.containsKey(token) ||
        !_sheetsLoading.add(token)) {
      return;
    }
    try {
      sheetByToken[token] = await answerSheet(token);
      notifyListeners();
    } on ApiError {
      // Leave it absent rather than caching an empty sheet: absent means "not
      // fetched", and an empty one would read as "no categories".
    } finally {
      _sheetsLoading.remove(token);
    }
  }

  /// The same shape, out of the fixtures. Written through the JSON factory so
  /// the seed path exercises the same parser and the same release gate as the
  /// live one - a second hand-built path would be a second place for the gate
  /// to be wrong.
  AnswerSheet _seedAnswerSheet(String token) {
    final Attempt? ev = attemptByToken(token);
    if (ev == null) return const AnswerSheet();
    final Assessment? asm = asmById(ev.assessmentId);
    if (asm == null) return const AnswerSheet();

    final bool released = ev.resultsReleased;
    return AnswerSheet.fromJson(<String, dynamic>{
      'assessment': <String, dynamic>{'name': asm.name},
      'result': <String, dynamic>{
        'released': released,
        // `maxMarks`, not the question count: the seed has to fabricate the
        // string the SERVER would send, and the server's denominator is the
        // paper's component count.
        if (released)
          'score_marks': '${ev.earnedMarks(asm)} / ${ev.maxMarks(asm)}',
        if (released) 'result': ev.result(asm).wire,
      },
      'rows': <Map<String, dynamic>>[
        for (int i = 0; i < asm.questions.length; i++)
          _seedRow(asm.questions[i], ev.resp[asm.questions[i].id], i + 1),
      ],
    });
  }

  Map<String, dynamic> _seedRow(Question q, Response? r, int number) {
    // THE SEED FABRICATES WHAT THE SERVER WOULD SEND, so it has to read a
    // score the way the server reads one. `score > 0` was a two-state reading
    // left from the rule where a question was one mark taken whole, and under
    // the component rule it is not merely coarse, it is INVERTED: an answer
    // that took 1 of 3 sub-questions came back to the candidate as a flat
    // "Correct". The module sends three outcomes now, and the middle one is
    // the whole point of marking by component - it is the only place a
    // candidate sees that part of a question landed and part did not.
    //
    // `mark` and `markOutOf`, not the `score`/`maxScore` pair: those two hold
    // the OBJECTIVE half alone and are 0 on a graded answer, so a subjective
    // question read off them scored "Incorrect" however well it was written.
    // They are also the pair `earnedMarks` sums for the total printed above
    // this row, so a row that disagreed with them would contradict the header
    // on the same sheet.
    //
    // The denominator falls back to the question's own component count where
    // the response states none, because "Partly correct (2 of 0)" is worse
    // than the bug it would be reporting. `componentCount` is never 0.
    final int marks = r?.mark ?? 0;
    final int outOf = (r?.markOutOf ?? 0) > 0 ? r!.markOutOf : q.componentCount;
    final bool full = r != null && marks >= outOf;
    final bool some = r != null && marks > 0 && !full;
    return <String, dynamic>{
      'index': number,
      'name': q.name,
      'prompt': q.prompt,
      'question_type': q.type.wire,
      'chosen': <String>[
        if (r != null)
          for (final QDimension d in q.dims)
            for (final QOption o in d.options)
              if (r.lines.contains(o.id)) o.label,
      ],
      'correct': <String>[
        if (q.type.isObjective)
          for (final QDimension d in q.dims)
            for (final QOption o in d.options)
              if (o.correct) o.label,
      ],
      'justification': r?.justification ?? '',
      'verdict': r == null
          ? 'Not answered'
          : full
          ? 'Correct'
          : some
          ? 'Partly correct ($marks of $outOf)'
          : 'Incorrect',
      'kind': r == null
          ? 'info'
          : full
          ? 'ok'
          : some
          ? 'partial'
          : 'fail',
      'feedback': r?.judge?.verdict ?? '',
      'credit': <String>[
        for (final JudgeNote n in r?.judge?.credit ?? const <JudgeNote>[])
          n.reason,
      ],
      'deductions': <String>[
        for (final JudgeNote n in r?.judge?.deductions ?? const <JudgeNote>[])
          n.reason,
      ],
    };
  }

  Assessment? asmById(String? id) {
    for (final Assessment a in assessments) {
      if (a.id == id) return a;
    }
    return null;
  }

  Generator? genById(String? id) {
    for (final Generator g in generators) {
      if (g.id == id) return g;
    }
    return null;
  }

  Attempt? attemptById(String? id) {
    for (final Attempt a in attempts) {
      if (a.id == id) return a;
    }
    return null;
  }

  Attempt? attemptByToken(String? token) {
    for (final Attempt a in attempts) {
      if (a.token == token) return a;
    }
    return null;
  }

  Question? draftById(String? id) {
    for (final Question q in drafts) {
      if (q.id == id) return q;
    }
    return null;
  }

  Question? bankById(String? id) {
    for (final Question q in bank) {
      if (q.id == id) return q;
    }
    return null;
  }

  /// A question by id from wherever it lives - draft queue, approved bank, or
  /// frozen onto an assessment. The preview sheet needs this because it opens
  /// from all three.
  ///
  /// [preferDraft] SELECTS THE ID SPACE and is not a hint: the caller must set
  /// it from the record it already holds. A draft id
  /// (`etp.assessment.pro.prompt.question`) and a bank id
  /// (`etp.assessment.pro.question`) come from two independent Postgres
  /// sequences, so they collide constantly - draft 12 is "Task: Unintended
  /// Extra Change" while bank question 12 is "Extra Change in Edit". Searching
  /// drafts first for EVERY caller meant opening a bank question showed a
  /// different question's text and a different question's answer key, with no
  /// sign anything was wrong; it only looked correct for ids high enough that
  /// no pending draft happened to share them.
  ///
  /// There is deliberately no fallback into the other space. Returning the
  /// caller's own thin list row is honest; returning a same-numbered row from
  /// the wrong model is the bug this exists to prevent.
  Question? anyQuestionById(String? id, {bool preferDraft = false}) {
    if (preferDraft) return draftById(id);
    final Question? b = bankById(id);
    if (b != null) return b;
    for (final Assessment a in assessments) {
      final Question? q = a.questionById(id ?? '');
      if (q != null) return q;
    }
    return null;
  }

  Person? personById(String? id) {
    for (final Person p in people) {
      if (p.id == id) return p;
    }
    return null;
  }

  Person get me => personById(meId) ?? people.first;

  // ── Derived collections ─────────────────────────────────────────────────
  /// Drafts still awaiting a decision, optionally scoped to one generator.
  /// This is the rail badge on Review queue.
  List<Question> pendingDrafts([String? genId]) => drafts
      .where(
        (Question q) =>
            q.state == DraftState.draft && (genId == null || q.genId == genId),
      )
      .toList();

  List<Attempt> attemptsFor(String asmId) =>
      attempts.where((Attempt a) => a.assessmentId == asmId).toList();

  List<Attempt> attemptsForPerson(String personId) => attempts
      .where(
        (Attempt a) =>
            // A candidate's OWN list (`/api/v1/me/assessments`) carries no
            // `candidate` object - the endpoint is already scoped to them,
            // so repeating who they are would be noise. That leaves
            // `employeeId` empty, and matching on it alone returned nothing
            // for the one person the screen is built for. An unowned attempt
            // in this store arrived on that self-scoped endpoint and is
            // therefore theirs by construction.
            a.employeeId == personId || a.employeeId.isEmpty,
      )
      .toList();

  /// Every attempt ONE named candidate has sat, newest first.
  ///
  /// Strict on the id, unlike [attemptsForPerson]. That one also matches an
  /// EMPTY `employeeId`, because a candidate's own `/me/assessments` rows are
  /// already scoped to them and carry no `candidate` object - a concession that
  /// is right there and wrong here. On an admin surface an unowned attempt is
  /// somebody else's, and sweeping it in would put another person's marks on
  /// this candidate's page.
  ///
  /// Newest first because the question this screen answers is "how are they
  /// doing", and the answer starts with the most recent sitting. Attempts with
  /// no submission date sort last: they have not been sat.
  List<Attempt> attemptsByCandidate(String personId) {
    final List<Attempt> out = attempts
        .where((Attempt a) => a.employeeId == personId)
        .toList();
    out.sort((Attempt a, Attempt b) {
      final DateTime? x = a.submittedAt ?? a.startedAt;
      final DateTime? y = b.submittedAt ?? b.startedAt;
      if (x == null && y == null) return 0;
      if (x == null) return 1;
      if (y == null) return -1;
      return y.compareTo(x);
    });
    return out;
  }

  /// Every answer across every assessment, flattened - what the All responses
  /// screen lists and what the scoring KPIs count.
  // ── The ledger screen's own page ───────────────────────────────────────
  //
  // The LLM call ledger grows by one row per billable call and is the
  // fastest-growing table on the platform. The console bootstrap walks it at
  // `maxPages: 5` - 1,000 rows - and the ledger SCREEN paged a slice of that
  // walk in memory, so its pagination control offered pages of a sample: past
  // row 1,000 the ledger simply stopped, and the only hint was a chip.
  //
  // A SCREEN-OWNED CACHE rather than a bigger walk. `store.ledger` stays
  // exactly as it is because `budget_screen` aggregates over it and a walk is
  // the right shape for an aggregate; this is the page the LEDGER screen
  // renders, read one page at a time from the server, so the last page is the
  // last row rather than the cap.
  List<LedgerRow> ledgerPageRows = <LedgerRow>[];
  int ledgerPageTotal = 0;
  int ledgerPageNumber = 1;
  int ledgerPageSize = 20;
  bool ledgerPageLoading = false;
  String ledgerPageError = '';
  int _ledgerPageSeq = 0;

  /// One page of the ledger, from the server.
  Future<void> loadLedgerPage({int page = 1, int pageSize = 20}) async {
    // The route clamps to MAX_LIMIT = 200 and falls back to 40 on nothing, so
    // a control offering a larger size would page a different number of rows
    // than it displayed.
    final int limit = pageSize.clamp(1, 200);
    final int wanted = page < 1 ? 1 : page;
    ledgerPageNumber = wanted;
    ledgerPageSize = limit;

    if (source == DataSource.seed) {
      ledgerPageTotal = ledger.length;
      ledgerPageRows = ledger.skip((wanted - 1) * limit).take(limit).toList();
      ledgerPageError = '';
      scheduleMicrotask(notifyListeners);
      return;
    }

    final int seq = ++_ledgerPageSeq;
    ledgerPageLoading = true;
    try {
      final Map<String, dynamic> res = await _api.ledger(
        limit: limit,
        offset: (wanted - 1) * limit,
      );
      if (seq != _ledgerPageSeq) return;
      final List<Map<String, dynamic>> rows = _rows(res);
      final Map<String, dynamic> meta =
          (jget(res, 'meta') as Map<String, dynamic>?) ?? <String, dynamic>{};
      ledgerPageRows = rows.map(LedgerRow.fromJson).toList();
      ledgerPageTotal = jval(meta, 'total', rows.length);
      ledgerPageError = '';
      ledgerPageLoading = false;
      notifyListeners();
    } on ApiError catch (e) {
      if (seq != _ledgerPageSeq) return;
      ledgerPageRows = <LedgerRow>[];
      ledgerPageTotal = 0;
      ledgerPageError = e.message;
      ledgerPageLoading = false;
      notifyListeners();
    }
  }

  // ── The answers a search term reaches past the walk's cap ──────────────
  //
  // `responseRows` is a walk of `/api/v1/responses` capped at 2 pages - 400 of
  // 31,462 rows measured on stage - and the Responses screen filters it in
  // memory. That cap is why searching for a candidate on that screen "only
  // works for 400 entries": the rows simply were not there to match.
  //
  // A SUPPLEMENT, NOT A REPLACEMENT, and that distinction is the whole design.
  // The screen's box searches a haystack that includes the RENDERED, REDACTED
  // answer text and the judge's verdict - strings built client-side, which the
  // server cannot reproduce without a second copy of the redaction rules.
  // Sending the term to the server INSTEAD would therefore have broken
  // answer-text search outright: the server would answer "no rows" and the
  // screen would say "no matches" over answers it was holding.
  //
  // So the term goes to the server for the three axes it CAN answer
  // (assessment, candidate, question - the same three Odoo's own response
  // search view offers), and the rows that come back are UNIONED with the
  // cache before the local pass runs over the result. Every row the box used
  // to find, it still finds; the rows it could never reach now arrive.
  List<Map<String, dynamic>> responseSearchRows = <Map<String, dynamic>>[];

  /// The term [responseSearchRows] answers, so a stale slice is never unioned
  /// into a different query's results.
  String responseSearch = '';
  bool responseSearchLoading = false;
  int _responseSearchSeq = 0;

  /// True when the server had more matches than one page could carry.
  bool responseSearchPartial = false;

  /// Fetch the server's answer to [term], for the axes it can answer.
  Future<void> searchResponses(String term) async {
    final String q = term.trim();
    responseSearch = q;
    if (q.isEmpty || source == DataSource.seed) {
      responseSearchRows = <Map<String, dynamic>>[];
      responseSearchPartial = false;
      responseSearchLoading = false;
      _responseSearchSeq++;
      notifyListeners();
      return;
    }

    final int seq = ++_responseSearchSeq;
    responseSearchLoading = true;
    try {
      final Map<String, dynamic> res = await _api.responses(
        search: q,
        limit: 200,
      );
      if (seq != _responseSearchSeq) return;
      final List<Map<String, dynamic>> rows = _rows(res);
      final Map<String, dynamic> meta =
          (jget(res, 'meta') as Map<String, dynamic>?) ?? <String, dynamic>{};
      responseSearchRows = rows;
      // One page, like the other server-backed search boxes. Stated rather
      // than silently walked: 200 matching answers is already far more than
      // anybody reads, and a term that broad wants narrowing, not paging.
      responseSearchPartial = jval(meta, 'total', rows.length) > rows.length;
      responseSearchLoading = false;
      notifyListeners();
    } on ApiError catch (e) {
      if (seq != _responseSearchSeq) return;
      // The CACHE still answers. A failed supplement must degrade to the old
      // behaviour rather than emptying a screen that was working.
      responseSearchRows = <Map<String, dynamic>>[];
      responseSearchPartial = false;
      responseSearchLoading = false;
      toaster.bad(e.message);
      notifyListeners();
    }
  }

  List<AnswerRef> allResponses() {
    // Prefer the SERVER's flattened rows.
    //
    // The join below needs `asm.questions` and `ev.resp`, which only exist on
    // the DETAIL payloads. Against a live backend the list endpoints carry
    // neither, so it always yielded nothing and this screen reported "0
    // answers" while three sat in the database. `/api/v1/responses` already
    // did the join server-side.
    if (responseRows.isNotEmpty || responseSearchRows.isNotEmpty) {
      // UNION, de-duplicated by id, cache first so a row the screen already
      // rendered keeps its identity. The server slice adds only what the
      // capped walk never reached.
      final Set<String> seen = <String>{};
      final List<Map<String, dynamic>> merged = <Map<String, dynamic>>[];
      for (final Map<String, dynamic> row in <Map<String, dynamic>>[
        ...responseRows,
        ...responseSearchRows,
      ]) {
        final String key = '${row['id'] ?? ''}';
        // A row with no id cannot be de-duplicated; keep it rather than drop
        // it, because dropping rows on a failed lookup is the bug this whole
        // area exists to fix.
        if (key.isNotEmpty && !seen.add(key)) continue;
        merged.add(row);
      }
      final List<AnswerRef> out = <AnswerRef>[];
      for (final Map<String, dynamic> row in merged) {
        final String attemptId = '${row['evaluator_id'] ?? ''}';
        final String asmId = '${row['assessment_id'] ?? ''}';
        // Fall back to a row-derived stand-in rather than SKIPPING when a
        // lookup misses. Dropping a row on a failed lookup is the very bug
        // being fixed here.
        final Attempt ev = attempts.firstWhere(
          (Attempt a) => a.id == attemptId,
          orElse: () => Attempt.fromJson(<String, dynamic>{
            'id': attemptId,
            'assessment_id': asmId,
            'candidate': row['candidate'],
          }),
        );
        final Assessment asm =
            asmById(asmId) ??
            Assessment.fromJson(<String, dynamic>{
              'id': asmId,
              'name': row['assessment_name'] ?? 'Assessment $asmId',
            });
        out.add(
          AnswerRef(
            ev: ev,
            asm: asm,
            q: Question.fromJson(<String, dynamic>{
              'id': '${row['question_id'] ?? ''}',
              'name': row['question_name'] ?? '',
              'prompt': row['prompt'] ?? row['question_name'] ?? '',
              'question_type': row['question_type'] ?? '',
            }),
            r: Response.fromJson(row),
          ),
        );
      }
      return out;
    }

    final List<AnswerRef> out = <AnswerRef>[];
    for (final Attempt ev in attempts) {
      final Assessment? asm = asmById(ev.assessmentId);
      if (asm == null) continue;
      for (final Question q in asm.questions) {
        final Response? r = ev.resp[q.id];
        if (r == null) continue;
        out.add(AnswerRef(ev: ev, asm: asm, q: q, r: r));
      }
    }
    return out;
  }

  /// Answers sitting in the terminal grader-error state - the rail badge on
  /// Scoring pipeline, and the count "Reset & re-score errored" acts on.
  int get scoringErrorCount =>
      allResponses().where((AnswerRef a) => a.isRescorableError).length;

  /// The assessments a role may see.
  ///
  /// A Manager sees every assessment; that is what the module's
  /// "manager full access" record rule grants. A candidate never reaches this
  /// list at all - their own attempts come from `attemptsForPerson`, which is
  /// the Flutter twin of the "candidate sees only own row" rule.
  ///
  /// ARCHIVED ONES ARE OUT unless asked for. This is THE chokepoint: the
  /// assessments list AND the whole dashboard - every KPI, the analytics band,
  /// the Performance panel - read this one method. `_loadAdmin` now fetches
  /// archived rows so the list can offer to restore them, so without the
  /// filter here archiving an assessment would hide it from the list while
  /// still counting it in every figure on the dashboard beside it.
  ///
  /// `includeArchived` is for the list grid alone, where showing them is what
  /// the toggle is for.
  List<Assessment> visibleAssessments(
    Portal p, {
    bool includeArchived = false,
  }) {
    if (p != Portal.admin) return <Assessment>[];
    if (includeArchived) return assessments;
    return assessments.where((Assessment a) => a.active).toList();
  }

  /// The launch-ready pool a generator can serve - the questions a NEW
  /// assessment may draw from.
  ///
  /// `!q.retired` is the whole point of retiring, and it has to be here rather
  /// than only in the route: the store now fetches retired rows so the bank
  /// screen can offer to restore them, which puts them in `bank` - and this is
  /// what the assessment builder picks from. Without this filter, deleting a
  /// question would take it out of the bank list and leave it in the picker,
  /// which is precisely the "no further use" promise broken.
  List<Question> poolFor(String genId) => bank
      .where((Question q) => q.genId == genId && !q.retired && q.launchReady)
      .toList();

  /// Re-read the bank alone, so [poolFor] sees what the server holds NOW.
  ///
  /// New assessment draws from `bank`, which is only as fresh as the last
  /// console load - a draft approved a minute ago in another tab was not in it,
  /// so a create asking for 15 drew the 6 the cache knew about. Quiet: on a
  /// failure the cached bank stays and the screen works from that.
  Future<void> refreshBank() async {
    if (!_live) return;
    try {
      bank = _mergeQuestions(
        bank,
        await _allPages(
          (int l, int o) =>
              _api.bank(limit: l, offset: o, includeRetired: true),
        ),
      );
      notifyListeners();
    } on ApiError {
      // Keep the cached bank.
    }
  }

  /// The bank as the product means it: everything except the retired rows.
  ///
  /// EVERY COUNT ABOUT THE BANK MUST COME FROM HERE, not from `bank`. `bank`
  /// is the fetched list, and it deliberately carries retired rows so the bank
  /// screen's "Show retired" toggle has something to reveal and the restore
  /// path stays reachable (see `_loadAdmin`). A retired row is still `active`
  /// on the wire - retiring is not archiving - so nothing else filters it out
  /// and a KPI counted straight off `bank` reports questions no assessment can
  /// ever draw again: 40 "Bank questions" over a grid listing 39.
  ///
  /// The grid itself is the one caller that wants `bank`, because hiding the
  /// retired rows is exactly what its toggle is for.
  List<Question> liveBank() =>
      bank.where((Question q) => !q.retired).toList(growable: false);

  /// The generators as the product means them: everything except archived.
  ///
  /// THE SAME BARGAIN AS [liveBank], on the list beside it. `_loadAdmin` now
  /// fetches with `include_archived` so the generator list's toggle has rows
  /// to reveal and Restore stays reachable - which puts archived generators in
  /// `generators`, where four other readers would silently pick them up: the
  /// Start-here counters, the review-queue filter chips, and - the one that
  /// actually breaks something - the generator picker on New assessment, which
  /// would offer a generator that has been deliberately taken out of service.
  ///
  /// The generator list itself is the one caller that wants `generators` raw.
  List<Generator> liveGenerators() =>
      generators.where((Generator g) => g.active).toList(growable: false);

  // ══════════════════════════════════════════════════════════════════════
  //  Review queue: the human approval gate
  // ══════════════════════════════════════════════════════════════════════

  /// Invariant 1 lives here. A draft carrying an unacknowledged blocking
  /// warning cannot be approved by any route, including the keyboard one, so
  /// the check sits in the shared decision path rather than on a button.
  ///
  /// Returns the id of the draft whose preview must be force-opened when the
  /// approval was refused, or null when the decision went through.
  String? decideDraft(String id, DraftState verdict) {
    final Question? d = draftById(id);
    if (d == null || d.state != DraftState.draft) return null;

    final bool approving = verdict == DraftState.approved;

    // READ ONCE, then both gate on it and SEND it. The server runs this same
    // check (`/drafts/<id>/approve` answers 422 `warnings_unacknowledged`) and
    // decides from the request alone - it cannot see this set. Approving used
    // to post `acknowledge_warnings: false` unconditionally, so a draft
    // carrying either authoring smell was refused by the server no matter how
    // many times the reviewer ticked the box, and the queue had no way through.
    final bool acked = acknowledged.contains(id);

    if (approving && d.blockingWarnings.isNotEmpty && !acked) {
      toaster.warn(
        'This one carries a warning - open it and acknowledge before approving',
      );
      return id;
    }

    // The optimistic edit and its exact inverse, as a pair.
    //
    // SURGICAL, not a snapshot restore: the reviewer works a queue, so several
    // decisions can be in flight at once and rolling back to a captured list
    // would discard the ones that landed in between. Both closures touch only
    // this draft, so they compose in any order.
    void applyLocally() {
      drafts = drafts
          .map((Question q) => q.id == id ? q.copyWith(state: verdict) : q)
          .toList();
      if (approving) {
        bank = <Question>[
          ...bank,
          d.copyWith(
            state: DraftState.approved,
            approvedOn: DateTime.now(),
            answerKeyValid: d.hasCompleteKey,
          ),
        ];
      }
      lastDecision = (id: id, verdict: verdict);
    }

    void rollbackLocally() {
      drafts = drafts
          .map(
            (Question q) =>
                q.id == id ? q.copyWith(state: DraftState.draft) : q,
          )
          .toList();
      if (approving) bank = bank.where((Question q) => q.id != id).toList();
      // Only if it is still OURS - a later decision owns the undo slot by then.
      if (lastDecision?.id == id) lastDecision = null;
    }

    // THE TOAST IS THE SERVER'S TO EARN. It used to fire here, before the
    // request, which is how a refused approval put "Approved - ... is in the
    // bank" on screen next to the refusal that contradicted it - and, on the
    // happy path, printed the same success twice. `_act` toasts once, from the
    // outcome, and `rollback` takes the row back out of the bank when the
    // server says no.
    //
    // Still not awaited: a reviewer must not wait a round trip per card, and
    // `optimistic` runs synchronously before `_act`'s first await, so the card
    // still leaves the queue on the keystroke.
    if (_live) {
      unawaited(
        _act(
          approving ? 'Approve' : 'Deny',
          () => approving
              ? _api.approveDraft(id, acknowledgeWarnings: acked)
              : _api.denyDraft(id),
          optimistic: applyLocally,
          rollback: rollbackLocally,
          okMessage: (_) => approving
              ? 'Approved - ${d.name} is in the bank'
              : 'Denied - ${d.name}',
        ),
      );
    } else {
      applyLocally();
      if (approving) {
        toaster.ok('Approved - ${d.name} is in the bank');
      } else {
        toaster.info('Denied - ${d.name}');
      }
      notifyListeners();
    }
    return null;
  }

  /// Reverses both halves of a decision: the draft goes back to `draft` and,
  /// when the verdict was an approval, the bank row it created is removed.
  void undoDecision() {
    final ({String id, DraftState verdict})? last = lastDecision;
    if (last == null) {
      toaster.info('Nothing to undo');
      return;
    }
    final Question? d = draftById(last.id);
    drafts = drafts
        .map(
          (Question q) =>
              q.id == last.id ? q.copyWith(state: DraftState.draft) : q,
        )
        .toList();
    if (last.verdict == DraftState.approved) {
      bank = bank.where((Question q) => q.id != last.id).toList();
    }
    lastDecision = null;
    toaster.ok('Restored - ${d?.name ?? last.id} is back in the queue');
    notifyListeners();
  }

  void toggleAck(String draftId) {
    if (!acknowledged.remove(draftId)) acknowledged.add(draftId);
    notifyListeners();
  }

  /// Sign off (or un-sign) a BANK question's marking guide.
  ///
  /// Bank only, deliberately. `rubric_reviewed` is a column on
  /// `assessments.be.question` and the route browses that model, so this used
  /// to answer "Question not found" for every draft the review queue offered
  /// it on. The control is gone from that screen; this method no longer
  /// touches `drafts` either, so an id that is not in the bank now changes
  /// nothing on screen rather than changing something that cannot be saved.
  Future<void> signRubric(String questionId) async {
    final bool nowReviewed = !(bankById(questionId)?.rubricReviewed ?? false);

    // Toggling is its OWN inverse, which is what lets the same closure serve
    // as both the optimistic edit and the undo.
    void flipAll() {
      bank = bank
          .map(
            (Question q) => q.id == questionId
                ? q.copyWith(rubricReviewed: !q.rubricReviewed)
                : q,
          )
          .toList();
      notifyListeners();
    }

    if (!_live) {
      flipAll();
      return;
    }

    // Persisted because this is a GATE: an assessment with
    // `require_reviewed_rubric` refuses to launch until a person has signed
    // off every AI-authored rubric. A sign-off that lived only in the browser
    // would let the launch check pass on screen and fail on the server.
    //
    // ROLLED BACK ON FAILURE, unlike most actions here. The optimistic edit is
    // not a preview of a value the next refresh will restate - it is the claim
    // "a human has checked this key", and a reviewer who reads it moves on. If
    // the write did not land, saying so and putting the pill back is the only
    // honest outcome.
    await _act(
      'Approve guide',
      () => _api.reviewRubric(questionId, reviewed: nowReviewed),
      optimistic: flipAll,
      rollback: flipAll,
      okMessage: (_) =>
          nowReviewed ? 'Marking guide approved' : 'Sign-off withdrawn',
    );
  }

  Future<void> toggleAllowedType(String genId, QType type) async {
    final Generator? g = genById(genId);
    if (g == null) return;
    final List<QType> next = List<QType>.from(g.allowedTypes);
    next.contains(type) ? next.remove(type) : next.add(type);
    updateGenerator(g.copyWith(allowedTypes: next));
    if (!_live) return;

    // The whole set, not the one that changed: the route replaces the list,
    // which is idempotent and cannot drift from a concurrent edit.
    await _act(
      'Save',
      () =>
          _api.setQuestionTypes(genId, next.map((QType t) => t.wire).toList()),
      okMessage: (_) => 'Question types saved',
      refreshAfter: false,
    );
    await loadGenerator(genId);
  }

  // ══════════════════════════════════════════════════════════════════════
  //  Assessment lifecycle
  // ══════════════════════════════════════════════════════════════════════

  void _replaceAsm(Assessment next) {
    assessments = assessments
        .map((Assessment a) => a.id == next.id ? next : a)
        .toList();
    notifyListeners();
  }

  void _replaceAttempt(Attempt next) {
    attempts = attempts.map((Attempt a) => a.id == next.id ? next : a).toList();
    notifyListeners();
  }

  List<GateResult> launchGates(Assessment asm) => Gates.launch(
    asm,
    attempts: attempts,
    generator: genById(asm.generatorId),
    bank: bank,
  );

  /// The server's launch WARNINGS: gates that pass but carry `warning: true`.
  /// Today that is `grading_keys`, naming the questions whose answers will be
  /// graded against the task alone because their answer key is unusable.
  ///
  /// READ FROM A DRY RUN (`confirm: false` - nothing is written), not worked
  /// out here. Which key is "usable" is `scoring.lacks_answer_key` in the
  /// module, and a copy of that rule on this side would drift from it the way
  /// the old hand-copied `answer_keys` gate did.
  ///
  /// Advisory, so it never holds anything up: offline, or when the dry run
  /// fails, there are simply no warnings - the launch itself is still judged
  /// by the server.
  Future<List<GateResult>> launchWarnings(Assessment asm) async {
    if (!_live) return const <GateResult>[];
    try {
      final Object? gates = (await _api.launch(asm.id, dryRun: true))['gates'];
      return <GateResult>[
        if (gates is List)
          for (final Object? g in gates)
            if (g is Map && g['warning'] == true)
              GateResult(
                '${g['label'] ?? ''}',
                // The module's own sentence, names and all. The names are not
                // split out into bullets: they arrive joined by ", " inside
                // prose, and a question name may contain one.
                '${g['reason'] ?? ''}',
                ok: true,
                warning: true,
              ),
      ];
    } catch (_) {
      return const <GateResult>[];
    }
  }

  // ── Server actions ──────────────────────────────────────────────────────
  //
  // Every mutation below goes through [_act]. On seed data it runs the local
  // fallback and nothing else; against a live backend it calls the API and
  // then RE-READS from the server rather than trusting the optimistic local
  // edit. That re-read is the point: the module runs its own gates, its own
  // scoring queue and its own record rules, so what the server says happened
  // is the truth and a local guess is at best a coincidence.

  /// True when actions must go to the server rather than mutate memory.
  bool get _live => source == DataSource.live;

  /// Public form of [_live], for screens that must not run the fixture
  /// demo's client-side logic against a real server.
  bool get isLive => _live;

  /// Whether the server knows `results_show_answers`: every assessment
  /// detail carries it from backend 19.0.3.27.0 on, the release that also
  /// brought the CSV import check (`dry_run` on `/assign`). A backend before
  /// it ignores both - the switch would say Saved and change nothing, and a
  /// "check" of a CSV would import it for real - so neither is offered until
  /// a detail has shown the key. Offline there is no server to disagree.
  bool get serverKnowsShowAnswers => !_live || _sawShowAnswers;
  bool _sawShowAnswers = false;

  /// Bumped each time a [_act] call lands, so an open History panel re-reads
  /// its record. Release, Cancel, Reset and the rest each log a line
  /// server-side that the panel otherwise showed only after being reopened.
  int historyRevision = 0;

  /// Runs a server action, then refreshes. Falls back to [ifSeed] offline.
  ///
  /// [optimistic] runs immediately so the UI responds on the same frame; if
  /// the call fails the refresh puts the server's version back, so a rejected
  /// action cannot leave the screen showing a state the database never had.
  Future<void> _act(
    String label,
    Future<Map<String, dynamic>> Function() call, {
    void Function()? optimistic,

    /// Undo [optimistic] when the call did not land.
    ///
    /// The trailing `refresh` already re-reads the truth, so most actions need
    /// nothing here. It matters when the optimistic state is a CLAIM the user
    /// will act on - a governance sign-off, say - because that refresh can
    /// itself fail, leaving the screen asserting something untrue.
    void Function()? rollback,
    void Function()? ifSeed,
    String Function(Map<String, dynamic> data)? okMessage,

    /// The tone of the [okMessage] toast: [Tone.warn] for a success that left
    /// somebody out.
    Tone Function(Map<String, dynamic> data)? okTone,

    /// A refusal that is a QUESTION for the operator rather than a failure.
    /// Returns true to take it over, and then no toast is shown.
    bool Function(ApiError e)? asks,

    /// False when the caller re-reads the ONE record it wrote instead. A
    /// generator field save used to end in the whole console reload - about
    /// 45 requests, 25 of them `/attempts` - on every autosave (prod,
    /// 2026-09-29: 550 `/attempts` calls in two minutes while one generator
    /// was edited).
    bool refreshAfter = true,
  }) async {
    if (!_live) {
      ifSeed?.call();
      return;
    }

    optimistic?.call();
    notifyListeners();

    try {
      final Map<String, dynamic> res = await call();
      historyRevision++;
      notifyListeners();
      // A PARTIAL success is not a success, and the module says so in its own
      // words. An Odoo action reports one by RETURNING a notification rather
      // than raising, so it arrives on a 200 with `ok: true` - "Approve all"
      // came back clean while four drafts had been refused and left in the
      // queue, and the toast claimed every one of them had reached the bank.
      // Whoever read that went looking for a missing question in the bank
      // instead of at the reason it never got there.
      final Object? notice = res['notice'];
      if (notice is Map<String, dynamic> &&
          (notice['message'] as String? ?? '').isNotEmpty) {
        final String text = notice['message'] as String;
        if (notice['is_warning'] == true) {
          toaster.bad(text);
        } else {
          toaster.ok(text);
        }
      } else {
        toaster.show(
          okMessage?.call(res) ?? '$label done',
          okTone?.call(res) ?? Tone.ok,
        );
      }
    } on ApiError catch (e) {
      rollback?.call();
      if (asks?.call(e) ?? false) return;
      // The module's own words: it explains WHY a gate refused far better
      // than any sentence written here could.
      toaster.bad(e.message);
    } catch (e) {
      // Anything else - a TypeError from a changed payload, a socket drop.
      // Caught for the same reason `refresh` catches everything: an escaping
      // exception leaves the optimistic edit on screen with no toast, so the
      // action looks like it worked. The `finally` re-read then silently
      // contradicts it. Better to say what happened.
      rollback?.call();
      toaster.bad('$label failed. $e');
    } finally {
      // Background: an approve/deny in the review queue should not flash the
      // whole console back to its skeleton between cards.
      if (refreshAfter) await refresh(background: true);
    }
  }

  /// Sets the assessment live and queues every invitation. Refuses when any
  /// gate fails - the sheet disables the button too, but the guard is here so
  /// no other path can bypass it.
  ///
  /// The SERVER re-runs those gates. The client-side check is a courtesy that
  /// saves a round trip; it is never the thing that protects the data.
  Future<void> launch(Assessment asm) async {
    final List<GateResult> gates = launchGates(asm);
    if (!Gates.allPass(gates)) {
      // NAME THEM, for the same reason the server now does. This said "some
      // checks have not passed" and returned without ever calling the server,
      // so the one path that could have explained itself was never reached and
      // the operator was left with a count. Every GateResult already carries
      // the reason - `Gates.launch` evaluates all of them precisely so none of
      // this has to be recomputed or guessed at.
      final List<GateResult> failing = gates
          .where((GateResult g) => !g.ok)
          .toList();
      toaster.bad(
        'Launch blocked: '
        '${failing.map((GateResult g) => '${g.name} - ${g.why}').join('; ')}',
      );
      return;
    }
    await _act(
      'Launch',
      () => _api.launch(asm.id),
      optimistic: () => _replaceAsm(asm.copyWith(state: AsmState.inProgress)),
      // A LIFECYCLE STATE IS A CLAIM THE OPERATOR ACTS ON, which is the case
      // `_act`'s own note says `rollback` is for. Without it a refused action
      // leaves the pill asserting a state the server never wrote, until the
      // background refresh happens to correct it - and the refusal toast reads
      // as though it had worked. Put the record back at once.
      rollback: () => _replaceAsm(asm),
      okMessage: (Map<String, dynamic> d) {
        final int n = (d['invited'] ?? d['assigned_count'] ?? 0) as int;
        return n > 0 ? 'Launched - $n invitation(s) queued' : 'Launched';
      },
      ifSeed: () {
        _replaceAsm(asm.copyWith(state: AsmState.inProgress));
        final List<Attempt> mine = attemptsFor(asm.id);
        attempts = attempts
            .map(
              (Attempt a) => a.assessmentId == asm.id
                  ? a.copyWith(inviteState: InviteState.sent)
                  : a,
            )
            .toList();
        toaster.ok('Launched - ${mine.length} invitations queued');
        notifyListeners();
      },
    );
  }

  Future<void> markDone(Assessment asm) => _act(
    'Close',
    () => _api.closeAssessment(asm.id),
    optimistic: () => _replaceAsm(asm.copyWith(state: AsmState.done)),
    // Same reason as `launch` above.
    rollback: () => _replaceAsm(asm),
    okMessage: (_) => 'Assessment closed',
    ifSeed: () {
      _replaceAsm(asm.copyWith(state: AsmState.done));
      toaster.ok('Assessment closed');
    },
  );

  Future<void> cancel(Assessment asm) => _act(
    'Cancel',
    () => _api.cancelAssessment(asm.id),
    optimistic: () => _replaceAsm(asm.copyWith(state: AsmState.cancelled)),
    // Same reason as `launch` above.
    rollback: () => _replaceAsm(asm),
    okMessage: (_) => 'Assessment cancelled',
    ifSeed: () {
      _replaceAsm(asm.copyWith(state: AsmState.cancelled));
      toaster.warn('Assessment cancelled');
    },
  );

  /// Returns the server's own words when the reset would erase RELEASED
  /// results and [confirmReleased] was not sent (409 `released_results`), for
  /// the screen to put to the admin; null otherwise.
  Future<String?> resetToDraft(
    Assessment asm, {
    bool confirmReleased = false,
  }) async {
    String? released;
    bool reset = false;
    await _act(
      'Reset',
      () async {
        final Map<String, dynamic> res = await _api.resetToDraft(
          asm.id,
          confirmReleased: confirmReleased,
        );
        reset = true;
        return res;
      },
      optimistic: () => _replaceAsm(asm.copyWith(state: AsmState.draft)),
      // Same reason as `launch` above.
      rollback: () => _replaceAsm(asm),
      asks: (ApiError e) {
        if (e.code != 'released_results') return false;
        released = e.message;
        return true;
      },
      okMessage: (_) => 'Reset to draft',
      ifSeed: () {
        _replaceAsm(asm.copyWith(state: AsmState.draft));
        toaster.info('Reset to draft');
      },
    );
    // THE DETAIL, quietly. The server just cleared the question selection and
    // the schedule, and no list row carries `pool`, so `_act`'s refresh kept
    // the old ticks: "2 of 10 in use" over a paper the server had reset.
    if (reset) await _loadAssessment(asm.id);
    return released;
  }

  Future<void> resendInvites(Assessment asm) => _act(
    'Resend',
    () => _api.resendAllInvites(asm.id),
    okMessage: (Map<String, dynamic> d) {
      final int n = (d['requeued'] ?? 0) as int;
      return n > 0 ? 'Resent $n invitation(s)' : 'Invitations resent';
    },
    ifSeed: () {
      attempts = attempts
          .map(
            (Attempt a) => a.assessmentId == asm.id
                ? a.copyWith(inviteState: InviteState.sent)
                : a,
          )
          .toList();
      toaster.ok('Invitations resent');
      notifyListeners();
    },
  );

  Future<void> requeueInvite(String attemptId) async {
    final Attempt? a = attemptById(attemptId);
    if (a == null) return;
    await _act(
      'Resend',
      () => _api.resendInvite(attemptId),
      optimistic: () =>
          _replaceAttempt(a.copyWith(inviteState: InviteState.sent)),
      okMessage: (_) => 'Invitation resent',
      ifSeed: () {
        _replaceAttempt(a.copyWith(inviteState: InviteState.sent));
        toaster.ok('Invitation resent');
      },
    );
  }

  /// Attempts that could be released now: submitted, not yet released, and
  /// fully resolved.
  ///
  /// The resolved check is not a refinement, it is the point. An attempt with
  /// an unresolved subjective answer has no final score yet - its result is
  /// `pending` by Invariant 4 - so releasing it would publish a number that is
  /// still moving, or worse, a pass/fail decided on a partial score. The
  /// release sheet reports these separately as "still grading" precisely
  /// because they are NOT part of what gets released.
  List<Attempt> releasable(Assessment asm) {
    // A set: with roster rows now carrying the grader's count, hundreds of a
    // 900-candidate cohort can be held at once, and a list scan per attempt
    // was quadratic on every build.
    final Set<String> held = <String>{
      for (final Attempt h in stillGrading(asm)) h.id,
    };
    return attemptsFor(asm.id)
        .where(
          (Attempt a) => a.isDone && !a.resultsReleased && !held.contains(a.id),
        )
        .toList();
  }

  /// What the release button releases: every submitted attempt not yet
  /// released, still-grading ones included. The server holds back only one a
  /// grading lane is writing at that second, so the label counts them all
  /// rather than the [releasable] ones alone.
  List<Attempt> toRelease(Assessment asm) => attemptsFor(
    asm.id,
  ).where((Attempt a) => a.isDone && !a.resultsReleased).toList();

  /// Attempts blocking a clean release: submitted but still carrying an
  /// unresolved subjective answer.
  List<Attempt> stillGrading(Assessment asm) => attemptsFor(
    asm.id,
  ).where((Attempt a) => a.isDone && a.awaitingGrader(asm)).toList();

  /// Invariant 3: the only path that sets `resultsReleased`. There is no
  /// automatic caller and there is no un-release.
  ///
  /// Against a live backend the SERVER decides which attempts qualify - it
  /// owns the scoring queue and knows which are still being graded. The local
  /// `releasable` filter is what the button count shows beforehand, not what
  /// authorises the release.
  Future<void> releaseResults(Assessment asm) => _act(
    'Release',
    () => _api.release(asm.id),
    okMessage: (Map<String, dynamic> d) {
      // THE KEYS THE SERVER ACTUALLY SENDS. This read was `d['released'] ??
      // d['count'] ?? 0` against a route that returns `released_count` and
      // `still_grading_count`, so the fallback fired on every success and the
      // toast said "Released 0 result(s)" however many went out - and the
      // `held` clause below could never fire at all. Read through `jval` like
      // `inviteMany` does rather than indexing raw: it resolves the camel name
      // to the snake_case wire form AND coerces the number, where a bare
      // `as int` throws on the web, since compiled to JS there is one numeric
      // type. The seed path computes the count locally, which is why this only
      // ever showed against a live backend.
      final int n = jval(d, 'releasedCount', 0);
      final int held = jval(d, 'stillGradingCount', 0);
      if (held > 0) {
        // Invariant 4 surfaced honestly: say what was held back and why,
        // rather than reporting a total that quietly excluded them.
        return 'Released $n result(s); $held still being graded';
      }
      return 'Released $n result(s)';
    },
    ifSeed: () {
      final List<Attempt> targets = releasable(asm);
      attempts = attempts
          .map(
            (Attempt a) => targets.any((Attempt t) => t.id == a.id)
                ? a.copyWith(resultsReleased: true)
                : a,
          )
          .toList();
      toaster.ok('Released ${targets.length} result(s)');
      notifyListeners();
    },
  );

  Future<void> releaseOne(String attemptId) async {
    final Attempt? a = attemptById(attemptId);
    if (a == null) return;

    // The same rule the bulk release obeys, enforced on the single-attempt
    // path too. A per-row Release button is exactly where this would otherwise
    // leak: it is one click, on one person, and it would publish a score that
    // is still being graded. Refusing with a reason is the honest answer.
    final Assessment? asm = asmById(a.assessmentId);
    if (asm != null && a.awaitingGrader(asm)) {
      toaster.warn(
        'Still grading. This attempt has an unresolved answer, so there is '
        'no final score to release yet.',
      );
      return;
    }

    await _act(
      'Release',
      // RELEASE EXACTLY THIS ONE.
      //
      // The route reads an ABSENT `evaluator_ids` as "release the whole
      // submitted cohort", so a per-candidate Release that sent none would
      // publish EVERY candidate's score - a one-click, irreversible disclosure
      // from a control that names one person. The ids are filtered to
      // submitted attempts and released through the same model action, so
      // the chatter audit line is written either way.
      () async {
        final Map<String, dynamic> d = await _api.release(
          a.assessmentId,
          evaluatorIds: <String>[a.id],
        );
        // The server skips a candidate a lane is still grading (G1-23).
        if (jval(d, 'releasedCount', 1) == 0 &&
            jval(d, 'skippedCount', 0) > 0) {
          _replaceAttempt(a);
          return <String, dynamic>{
            ...d,
            'notice': <String, dynamic>{
              'message': 'Not released - this candidate is still being graded',
              'is_warning': true,
            },
          };
        }
        return d;
      },
      optimistic: () => _replaceAttempt(a.copyWith(resultsReleased: true)),
      okMessage: (_) => 'Result released',
      ifSeed: () {
        _replaceAttempt(a.copyWith(resultsReleased: true));
        toaster.ok('Result released');
      },
    );
  }

  /// Rows [inviteMany] sends per request.
  ///
  /// The server provisions a login per new candidate, about a quarter of a
  /// second each (measured locally, 2026-10-20), so a 1000-row CSV sent whole
  /// was one ~4-minute request: no progress to show, and long past the idle
  /// timeout of the proxy in front of Odoo - the operator got an error while
  /// the import carried on behind it. 50 keeps each request near 12 seconds.
  static const int inviteBatch = 50;

  /// The CSV import in flight - rows sent so far of the total - or null.
  ({int done, int total})? importProgress;

  /// Invite a whole roster, [inviteBatch] rows per request.
  ///
  /// The route reports `assigned_count`, `already_assigned` and `skipped` per
  /// request; they are summed, so the operator still gets ONE honest summary
  /// rather than a toast per batch. [importProgress] moves after each batch.
  ///
  /// A failed batch stops the import and says how far it got. The file was
  /// already refused whole on any bad row before sending
  /// (`parseCandidateCsv`), and assigning is idempotent - a row already on
  /// the roster comes back as `already_assigned` - so importing the same file
  /// again finishes the job.
  Future<void> inviteMany(
    Assessment asm,
    List<({String name, String email})> rows,
  ) async {
    if (rows.isEmpty || importProgress != null) return;
    importProgress = (done: 0, total: rows.length);
    notifyListeners();
    try {
      await _act(
        'Import',
        () async {
          int added = 0;
          int already = 0;
          final List<dynamic> skipped = <dynamic>[];
          Map<String, dynamic> last = const <String, dynamic>{};
          for (int i = 0; i < rows.length; i += inviteBatch) {
            final List<({String name, String email})> batch = rows.sublist(
              i,
              min(i + inviteBatch, rows.length),
            );
            try {
              last = await _api.assign(asm.id, invites: batch);
            } on ApiError catch (e) {
              if (i == 0) rethrow;
              throw ApiError(
                'Imported $i of ${rows.length}, then stopped: ${e.message} '
                'Import the same file again to finish - rows already on the '
                'roster are skipped.',
                isDomain: e.isDomain,
                isTransport: e.isTransport,
                detail: e.detail,
                status: e.status,
                code: e.code,
                retryAfter: e.retryAfter,
                fields: e.fields,
              );
            }
            added += jval(last, 'assignedCount', 0);
            already += jval(last, 'alreadyAssigned', 0);
            skipped.addAll(
              jget(last, 'skipped') as List<dynamic>? ?? const <dynamic>[],
            );
            importProgress = (done: i + batch.length, total: rows.length);
            notifyListeners();
          }
          return <String, dynamic>{
            ...last,
            'assignedCount': added,
            'alreadyAssigned': already,
            'skipped': skipped,
          };
        },
        okMessage: (Map<String, dynamic> res) {
          final int added = jval(res, 'assignedCount', 0);
          final int already = jval(res, 'alreadyAssigned', 0);
          final List<SkippedInvite> skipped = _skippedInvites(res);
          // Report what the SERVER did. Saying "imported 60" when it created 4
          // and skipped 56 is the kind of lie that gets discovered at exam time.
          final List<String> parts = <String>[
            '$added invited',
            if (already > 0) '$already already assigned',
            if (skipped.isNotEmpty) '${skipped.length} skipped',
          ];
          // The first reason or two, so "66 skipped" says why without opening
          // anything. The assessment's History has the full list.
          final String eg = skipped.isEmpty
              ? ''
              : ' (e.g. ${skipped.take(2).map(skippedLine).join('; ')})';
          return '${parts.join(', ')}$eg';
        },
        okTone: (Map<String, dynamic> res) =>
            _skippedInvites(res).isEmpty ? Tone.ok : Tone.warn,
      );
      // The DETAIL route, not another full refresh. `_act` has already
      // refreshed the lists, and no list row carries `roster` - so a second
      // `refresh()` here cost a round trip and still could not show the people
      // just imported. Only `/assessments/<id>` returns them.
      await loadAssessment(asm.id);
    } finally {
      importProgress = null;
      notifyListeners();
    }
  }

  /// What [inviteMany] WOULD do with [rows], asked as a dry run that writes
  /// nothing.
  ///
  /// ONE request, not batched like the real import: the server only looks the
  /// rows up (0.26 s for 900 rows measured locally, 21 Oct 2026), it makes no
  /// login. No toast, no refresh, no store state: the import sheet shows the
  /// answer itself. A failed check comes back as [ImportCheck.error] rather
  /// than a throw, because the sheet still lets the file go - the real import
  /// skips whoever cannot sit either way. Offline there is nothing to ask.
  static const Duration importCheckTimeout = Duration(seconds: 30);

  Future<ImportCheck> checkImport(
    Assessment asm,
    List<({String name, String email})> rows,
  ) async {
    if (!_live) {
      return (
        added: 0,
        already: 0,
        skipped: const <SkippedInvite>[],
        error: null,
        refused: false,
      );
    }
    try {
      // BOUNDED: the client has no timeout of its own, and an answer that
      // never comes would hold the sheet at "Checking..." for good.
      final Map<String, dynamic> res = await _api
          .assign(asm.id, invites: rows, dryRun: true)
          .timeout(importCheckTimeout);
      return (
        added: jval(res, 'assignedCount', 0),
        already: jval(res, 'alreadyAssigned', 0),
        skipped: _skippedInvites(res),
        error: null,
        refused: false,
      );
    } catch (e) {
      // Not only ApiError: a garbled answer throws a TypeError, and an
      // escaping one would leave the sheet saying "Checking..." for good.
      return (
        added: 0,
        already: 0,
        skipped: const <SkippedInvite>[],
        error: e is ApiError
            ? e.message
            : e is TimeoutException
            ? 'the check took too long'
            : '$e',
        refused: e is ApiError && (e.status == 400 || e.status == 422),
      );
    }
  }

  /// The assign route's `skipped` list, typed. Entries that are not records
  /// are dropped rather than thrown on.
  static List<SkippedInvite> _skippedInvites(Map<String, dynamic> res) {
    final Object? raw = jget(res, 'skipped');
    return <SkippedInvite>[
      if (raw is List)
        for (final Object? row in raw)
          if (row is Map)
            (
              name: jval<String>(jmap(row), 'name', ''),
              email: jval<String>(jmap(row), 'email', ''),
              reason: jval<String>(jmap(row), 'reason', ''),
            ),
    ];
  }

  /// Invite somebody who is not in the system yet, by name and email.
  ///
  /// The roster on this screen only ever held people who had ALREADY sat an
  /// assessment - it is built from the candidates of existing attempts - so
  /// there was no way to add a new person at all. The server creates the
  /// applicant record from name + email, which is what makes a first
  /// invitation possible.
  Future<void> inviteByEmail(
    Assessment asm, {
    required String name,
    required String email,
  }) async {
    final String n = name.trim();
    // LOWER-CASED, not just trimmed. See [normalizeEmail]: an admin typing
    // `Foo.Bar@Example.COM` and a CSV carrying `foo.bar@example.com` were
    // minting two applicants for one person, because Odoo matched the address
    // verbatim. Both invite paths now share the one rule.
    final String e = normalizeEmail(email);
    if (n.isEmpty || e.isEmpty) {
      toaster.bad('A name and an email are both required');
      return;
    }
    await _act(
      'Invite',
      () => _api.assign(
        asm.id,
        invites: <({String name, String email})>[(name: n, email: e)],
      ),
      okMessage: (_) => '$n invited',
    );
    // Re-read rather than patch locally: the server decides whether this
    // created a new applicant, reused one, or skipped it, and it queues the
    // invitation. Guessing here would show an invite that was never sent.
    //
    // The DETAIL route specifically. `refresh()` re-reads the LIST, and the
    // list row has no `roster` at all - so the person who was just created
    // and assigned had nowhere to appear, and the tab kept saying nobody was.
    await loadAssessment(asm.id);
  }

  // ── The Assign-candidates directory picker ─────────────────────────────

  /// The current page of the user directory the picker is showing.
  List<Person> pickerUsers = <Person>[];

  /// How many users match the current search, across every page.
  int pickerTotal = 0;

  /// Which search the rows in [pickerUsers] answer, so a slow response for an
  /// abandoned search cannot overwrite a newer one.
  String _pickerSearch = '';
  int _pickerSeq = 0;

  /// One page of `res.users`, searched SERVER-side.
  ///
  /// The picker used to filter `people`, which the console builds by
  /// de-duplicating the candidate off every attempt it has loaded. That list
  /// can only contain somebody who has already sat an assessment, so the first
  /// assignment of a new person was impossible from the picker and had to go
  /// through the invite-by-email sheet instead. It also meant the console
  /// walked every page of `/attempts` to populate a search box.
  Future<void> loadPickerUsers({
    String search = '',
    int offset = 0,
    int limit = 10,
  }) async {
    if (source == DataSource.seed) {
      pickerUsers = people;
      pickerTotal = people.length;
      notifyListeners();
      return;
    }
    final int seq = ++_pickerSeq;
    try {
      final ({List<dynamic> rows, int total}) page = await _api.users(
        search: search,
        limit: limit,
        offset: offset,
      );
      // A response for a search the operator has already typed past is stale;
      // adopting it would make the list flicker back to older results.
      if (seq != _pickerSeq) return;
      _pickerSearch = search;
      pickerUsers = <Person>[
        for (final dynamic row in page.rows)
          if (row is Map)
            Person(
              // The DIRECTORY id, not an applicant id. `assignPickedUser`
              // sends it as `user_ids` and the server maps it.
              id: jid(jget(jmap(row), 'id')),
              name: jval<String>(jmap(row), 'name', ''),
              email: jval<String>(jmap(row), 'email', ''),
            ),
      ];
      pickerTotal = page.total;
      notifyListeners();
    } on ApiError catch (e) {
      if (seq != _pickerSeq) return;
      pickerUsers = <Person>[];
      pickerTotal = 0;
      toaster.bad(e.message);
      notifyListeners();
    }
  }

  /// Which search [pickerUsers] currently answers.
  String get pickerSearch => _pickerSearch;

  // ── The Candidates tab roster ──────────────────────────────────────────
  //
  // A SEPARATE CACHE FROM [attempts], and that separation is the fix rather
  // than a convenience.
  //
  // The Candidates tab used to filter `attempts` - the console-wide walk of
  // `/api/v1/attempts` - in memory. That walk pages by `create_date desc` over a
  // bulk-invited cohort whose rows all share one `create_date`, so offset paging
  // over the unstable sort returned some attempts twice and others never:
  // measured on stage, 2,538 rows collected and 2,077 distinct. Searching a
  // corrupted sample is how one candidate rendered twice and another could not
  // be found at all.
  //
  // `/assessments/<id>/candidates` returns the cohort correctly, and it can page
  // and search it server-side. What it must NOT do is arrive through
  // [_mergeAttempts]: that rebuilds `attempts` from the rows it is handed and
  // cannot retain a row absent from the incoming page, so folding ONE
  // assessment's page into the console-wide list would evict every other
  // assessment and shrink the dashboard KPIs reading it. Requirement 3.4 is
  // preserved BY CONSTRUCTION here, not by re-verification.
  //
  // The roster carries no `answers` and no `token`, so it needs no merge at all:
  // a page replaces the page.

  /// The page of roster rows the Candidates tab is showing.
  List<RosterRow> rosterRows = <RosterRow>[];

  /// The SERVER's count for the current filter, which is what the tab's "of n"
  /// reports. Never the length of [rosterRows] - that is one page.
  int rosterTotal = 0;

  /// Every chip's count, keyed by the wire value the chip sends (`all`,
  /// `pending`, `in_progress`, `submitted`, `scored`, `score_pending`, `pass`,
  /// `fail`), from the route's `meta.counts`. Empty when the server sent none.
  ///
  /// FROM THE ROSTER RESPONSE, not the console-wide [attempts] cache: that
  /// cache is not refreshed when a scoring run ends, and it cannot tell Scored
  /// from Score Pending at all.
  Map<String, int> rosterCounts = const <String, int>{};

  int rosterPage = 1;
  int rosterPageSize = _kRosterPageSize;

  /// Which search and state filter [rosterRows] answers.
  String rosterSearch = '';
  String rosterState = '';

  /// The verdict filter [rosterRows] answers: '', `pass` or `fail`. The tab
  /// sends it in place of [rosterState], never beside it.
  String rosterResult = '';

  /// D1 - whether [rosterRows] is narrowed to operator-flagged candidates.
  bool rosterManualFlagged = false;

  /// WHICH ASSESSMENT the rows belong to.
  ///
  /// Scoping is by this tag rather than by a map keyed on assessment id: the tab
  /// shows one cohort at a time, a map would hold every cohort ever opened for
  /// the life of the session, and rows for the wrong assessment are the one
  /// failure that matters. [rosterRowsFor] is what readers use, and it refuses
  /// to answer for any other id.
  String rosterAssessmentId = '';

  bool rosterLoading = false;

  /// The server's message when the page could not be read, so the tab can say
  /// what went wrong instead of rendering as an empty cohort.
  String rosterError = '';

  /// The rows on screen answer an EARLIER filter, page or sort than the one in
  /// flight: the tab dims them until it lands. A refetch of the same slice
  /// (after an action, a scoring run) does not set it.
  bool rosterStale = false;

  /// The filter slice [rosterRows] were last asked for, to tell the two apart.
  String _rosterSlice = '';

  int _rosterSeq = 0;

  /// [rosterRows], but only when they are this assessment's.
  List<RosterRow> rosterRowsFor(String assessmentId) =>
      rosterAssessmentId == assessmentId ? rosterRows : const <RosterRow>[];

  /// The server's population for this assessment under the current filter.
  int rosterTotalFor(String assessmentId) =>
      rosterAssessmentId == assessmentId ? rosterTotal : 0;

  /// [rosterCounts], but only when they are this assessment's.
  Map<String, int> rosterCountsFor(String assessmentId) =>
      rosterAssessmentId == assessmentId ? rosterCounts : const <String, int>{};

  /// One page of ONE assessment's roster, searched, filtered and ORDERED
  /// SERVER-side.
  ///
  /// [page] is 1-based, because that is what the [Pagination] control speaks.
  ///
  /// [sortCol] is a UI column key - empty means the server's own default order.
  /// IT IS SENT WITH EVERY PAGE, not applied to the page in hand: this call
  /// returns at most 200 rows of a cohort that reaches 711, so a comparator
  /// here would order one page and present it as the cohort's order. The whole
  /// point of threading it down to the request is that page 2 of a sorted
  /// roster is the server's page 2 of that same sort.
  Future<void> loadRoster(
    String assessmentId, {
    int page = 1,
    int pageSize = _kRosterPageSize,
    String search = '',
    String state = '',
    String result = '',
    bool manualFlaggedOnly = false,
    String sortCol = '',
    bool sortAsc = true,
  }) async {
    // CLAMPED HERE, not at the call site. The route refuses anything over
    // MAX_LIMIT = 200 and silently applies DEFAULT_LIMIT = 40 when it gets
    // nothing, so a page control offering a larger size would page a different
    // number of rows than it displayed.
    final int limit = pageSize.clamp(1, 200);
    final int wanted = page < 1 ? 1 : page;
    rosterPage = wanted;
    rosterPageSize = limit;
    rosterSearch = search;
    rosterState = state;
    rosterResult = result;
    rosterManualFlagged = manualFlaggedOnly;

    if (source == DataSource.seed) {
      // The seed rig has no server. Page the fixtures the same way so the
      // control behaves identically in a demo.
      final List<Attempt> mine = attemptsFor(assessmentId).where((Attempt a) {
        // `.wire`, not `.name` - [state] arrives in the ROUTE's vocabulary
        // (`in_progress`), and the Dart identifier is `inProgress`. The seed
        // rig has to answer the same question the server would or the demo
        // disagrees with production on exactly one chip.
        if (state.isNotEmpty && a.state.wire != state) return false;
        if (result.isNotEmpty && a.serverResult?.wire != result) return false;
        if (manualFlaggedOnly && !a.candidateFlag.flagged) return false;
        if (search.trim().isEmpty) return true;
        final String name = personById(a.employeeId)?.name ?? a.employeeId;
        return name.toLowerCase().contains(search.trim().toLowerCase());
      }).toList();
      // The seed rig ignores [sortCol]: it is a demo fixture, and the ordering
      // under test is the route's, not a second comparator written here to
      // imitate it.
      rosterAssessmentId = assessmentId;
      rosterTotal = mine.length;
      // The seed rig has no answers to split Submitted by, so it counts the
      // states only and the two scoring chips stay hidden in a demo.
      final List<Attempt> cohort = attemptsFor(assessmentId);
      rosterCounts = <String, int>{
        'all': cohort.length,
        for (final AttemptState s in AttemptState.values)
          s.wire: cohort.where((Attempt a) => a.state == s).length,
      };
      rosterRows = <RosterRow>[
        for (final Attempt a in mine.skip((wanted - 1) * limit).take(limit))
          RosterRow(a, personById(a.employeeId)?.name ?? a.employeeId),
      ];
      rosterError = '';
      // AFTER THE FRAME, not during it. This branch is synchronous and the tab
      // calls `loadRoster` from `initState`, so notifying inline would mark a
      // ListenableBuilder dirty in the middle of the build that created it.
      scheduleMicrotask(notifyListeners);
      return;
    }

    // LAST WRITE WINS, and it is a sequence number rather than a timestamp
    // because two requests issued in the same millisecond are ordinary while a
    // slow first response painting over a fast second one is the bug. Every
    // return path below re-checks it, including the failure path: an error from
    // an abandoned search must not clear a page the operator is now reading.
    final int seq = ++_rosterSeq;
    // NO NOTIFY BEFORE THE REQUEST. The flag is set synchronously, so the build
    // that follows the caller's own `setState` (or `initState`) already renders
    // the loading line - and notifying from `initState` would throw
    // "setState() called during build". Same arrangement as `loadPickerUsers`.
    rosterLoading = true;
    final String slice =
        '$assessmentId|$wanted|$limit|$search|$state|$result|'
        '$manualFlaggedOnly|$sortCol|$sortAsc';
    rosterStale = rosterStale || slice != _rosterSlice;
    _rosterSlice = slice;
    try {
      final Map<String, dynamic> page0 = await _api.candidates(
        assessmentId,
        search: search.trim().isEmpty ? null : search.trim(),
        state: state.isEmpty ? null : state,
        result: result.isEmpty ? null : result,
        manualFlaggedOnly: manualFlaggedOnly,
        sortCol: sortCol.isEmpty ? null : sortCol,
        sortAsc: sortAsc,
        limit: limit,
        offset: (wanted - 1) * limit,
      );
      if (seq != _rosterSeq) return;
      final List<Map<String, dynamic>> rows = _rows(page0);
      final Map<String, dynamic> meta =
          (jget(page0, 'meta') as Map<String, dynamic>?) ?? <String, dynamic>{};
      rosterAssessmentId = assessmentId;
      rosterTotal = jval(meta, 'total', rows.length);
      final Object? counts = meta['counts'];
      rosterCounts = <String, int>{
        if (counts is Map)
          for (final MapEntry<dynamic, dynamic> e in counts.entries)
            if (e.value is num) '${e.key}': (e.value as num).toInt(),
      };
      rosterRows = <RosterRow>[
        for (final Map<String, dynamic> row in rows)
          RosterRow(Attempt.fromJson(row), _candidateName(row)),
      ];
      rosterError = '';
      rosterLoading = false;
      rosterStale = false;
      notifyListeners();
    } catch (e, st) {
      // ANY failure, not only a refusal: a reply this build cannot read left
      // "Loading the roster..." up for ever over dimmed rows.
      if (seq != _rosterSeq) return;
      if (e is! ApiError) debugPrint('loadRoster failed: $e\n$st');
      rosterRows = <RosterRow>[];
      rosterTotal = 0;
      rosterCounts = const <String, int>{};
      rosterAssessmentId = assessmentId;
      rosterError = e is ApiError
          ? e.message
          : 'The roster could not be read. Try again.';
      rosterLoading = false;
      rosterStale = false;
      notifyListeners();
    }
  }

  /// The candidate's name off a roster row.
  ///
  /// Read from the ROW rather than from [people]: that list is rebuilt wholesale
  /// by the console-wide walk, so a name only this route knows about would
  /// survive until the next refresh and then disappear. Falls back to the
  /// console cache and finally to the id, so a row always has something to show.
  String _candidateName(Map<String, dynamic> row) {
    final Object? who = row['candidate'];
    if (who is! Map) return '';
    final Map<String, dynamic> m = jmap(who);
    final String name = jval<String>(m, 'name', '');
    if (name.trim().isNotEmpty) return name;
    final String id = jid(jget(m, 'id'));
    return personById(id)?.name ?? id;
  }

  // ── The Leaderboard tab's own cohort ───────────────────────────────────
  //
  // WHY THIS EXISTS AT ALL. The tab used to rank `attemptsFor(asm.id)`, which
  // reads the console-wide `attempts` cache - a walk capped at 25 pages across
  // EVERY assessment. One assessment's share of that cap is whatever is left
  // after the others have taken theirs, so a large cohort could be ranked from
  // a subset with nothing on screen saying so. A leaderboard built from a
  // sample is not a leaderboard; it is a guess with an ordinal beside it.
  //
  // A SCREEN-OWNED CACHE, exactly like the roster's, and for the same reason:
  // writing into the shared `leaderboard` field would evict the dashboard's
  // global board, and writing into `attempts` would let one assessment's walk
  // define a console-wide cache.
  //
  // WALKED RATHER THAN PAGED, unlike the roster. Ranking needs the whole
  // cohort in hand - a page cannot be sorted into a rank - so this reads every
  // page of `/api/v1/assessments/<id>/candidates` and stops. That is safe only
  // BECAUSE of the tiebreaker work: the route now orders by
  // `create_date desc, id desc`, so the union of the pages is a true partition
  // of the cohort. Walking it before that fix would have ranked duplicates.
  List<Attempt> cohortRows = <Attempt>[];
  String cohortAssessmentId = '';
  bool cohortLoading = false;
  String cohortError = '';

  /// True when the walk stopped at [_kCohortMaxPages] rather than at the end.
  bool cohortTruncated = false;
  int _cohortSeq = 0;

  /// 25 pages of 200 is 5,000 candidates in ONE assessment - far past any
  /// cohort this platform has run (stage's largest is 572) and still a bound,
  /// so a runaway cannot walk a table forever.
  static const int _kCohortMaxPages = 25;

  List<Attempt> cohortFor(String assessmentId) =>
      cohortAssessmentId == assessmentId ? cohortRows : const <Attempt>[];

  /// Every attempt in ONE assessment, for a surface that must rank them.
  Future<void> loadCohort(String assessmentId) async {
    if (source == DataSource.seed) {
      cohortAssessmentId = assessmentId;
      cohortRows = attemptsFor(assessmentId);
      cohortError = '';
      cohortTruncated = false;
      scheduleMicrotask(notifyListeners);
      return;
    }

    final int seq = ++_cohortSeq;
    cohortLoading = true;
    try {
      final List<Attempt> out = <Attempt>[];
      bool truncated = false;
      for (int page = 0; ; page++) {
        if (page >= _kCohortMaxPages) {
          truncated = true;
          break;
        }
        final Map<String, dynamic> res = await _api.candidates(
          assessmentId,
          limit: 200,
          offset: page * 200,
        );
        if (seq != _cohortSeq) return;
        final List<Map<String, dynamic>> rows = _rows(res);
        out.addAll(rows.map(Attempt.fromJson));
        final Map<String, dynamic> meta =
            (jget(res, 'meta') as Map<String, dynamic>?) ?? <String, dynamic>{};
        if (rows.isEmpty || !jval(meta, 'hasMore', false)) break;
      }
      if (seq != _cohortSeq) return;
      cohortAssessmentId = assessmentId;
      cohortRows = out;
      cohortTruncated = truncated;
      cohortError = '';
      cohortLoading = false;
      notifyListeners();
    } on ApiError catch (e) {
      if (seq != _cohortSeq) return;
      cohortRows = <Attempt>[];
      cohortAssessmentId = assessmentId;
      cohortTruncated = false;
      cohortError = e.message;
      cohortLoading = false;
      notifyListeners();
    }
  }

  /// D1 - set the flag and/or the remark on ONE attempt.
  ///
  /// PER-ATTEMPT. The previous design hung the flag off the person and patched
  /// every attempt they had ever sat; this one changes the sitting that was
  /// clicked and nothing else, so the same candidate can be flagged on one
  /// assessment and clean on another.
  ///
  /// [flagged] and [remark] are independent: pass either, or both. A null
  /// argument is not sent, and a key the server does not receive is a key it
  /// does not change - so toggling the flag never disturbs a remark.
  ///
  /// The server is the source of truth for the block: it stamps who and when,
  /// so the response is applied rather than a locally-guessed value.
  Future<void> flagAttempt(String attemptId, {bool? flagged, String? remark}) {
    // A NO-OP IS NOT AN EDIT. Cancelling out of the remark sheet returns null
    // and never reaches here, but SAVING it unchanged - including saving an
    // empty sheet on an attempt that never had a remark - used to spend a
    // request and toast "Remark saved" for a write that changed nothing. The
    // toast is the part that matters: it tells the operator something happened
    // when nothing did, which is how a person learns to distrust the toasts
    // that do mean something.
    //
    // Only guards the remark-ONLY call. A flag toggle is meaningful even when
    // the value matches what the client believes, because the client's belief
    // can be stale and the server is the authority.
    if (flagged == null && remark != null) {
      final Attempt? now = attemptById(attemptId);
      if (now != null && now.candidateFlag.remark == remark) {
        return Future<void>.value();
      }
    }
    return _act(
      flagged == null
          ? 'Save remark'
          : (flagged ? 'Flag candidate' : 'Clear flag'),
      () => _api.flagAttempt(attemptId, flagged: flagged, remark: remark),
      ifSeed: () {
        final Attempt? now = attemptById(attemptId);
        final CandidateFlag was = now?.candidateFlag ?? CandidateFlag.none;
        _patchFlag(
          attemptId,
          CandidateFlag(
            flagged: flagged ?? was.flagged,
            remark: remark ?? was.remark,
            by: (flagged ?? was.flagged) ? 'You' : '',
            at: was.at,
          ),
        );
      },
      okMessage: (Map<String, dynamic> res) {
        // `res` IS THE DATA, already unwrapped.
        //
        // `ApiClient._call` unwraps a Map `data` out of the envelope before it
        // returns, so reading `res['data']` here found nothing and handed
        // `CandidateFlag.none` to the patch - which wrote `flagged: false` over
        // the row the operator had just flagged. Every surface EXCEPT the
        // Leaderboard hid it, because the background refresh that follows the
        // action re-read `/attempts` from the server and quietly corrected
        // `attempts`; the Leaderboard reads its own cohort cache, which nothing
        // re-reads, so it was the only screen telling the truth about the bug.
        //
        // The `data` fallback stays for an envelope that is not unwrapped (a
        // List payload keeps its wrapper), so this reads correctly either way.
        final Map<String, dynamic> body =
            res.containsKey('candidate_flag') ||
                res.containsKey('candidateFlag')
            ? res
            : jmap(jget(res, 'data') ?? const <String, dynamic>{});
        _patchFlag(
          attemptId,
          CandidateFlag.fromJson(jobj(body, 'candidateFlag')),
        );
        if (flagged == null) return 'Remark saved';
        return flagged ? 'Candidate flagged' : 'Flag cleared';
      },
    );
  }

  /// Apply [flag] to ONE attempt, in every cache that holds it.
  ///
  /// Three caches, because three surfaces read three different ones and an
  /// operator who flags from the roster then opens the Leaderboard must not
  /// see the old state: `attempts` is the console-wide list, `rosterRows` is
  /// the Candidates tab's page, and `cohortRows` is the Leaderboard tab's walk.
  void _patchFlag(String attemptId, CandidateFlag flag) {
    Attempt patch(Attempt a) =>
        a.id == attemptId ? a.copyWith(candidateFlag: flag) : a;

    attempts = attempts.map(patch).toList();
    cohortRows = cohortRows.map(patch).toList();
    rosterRows = <RosterRow>[
      for (final RosterRow r in rosterRows) RosterRow(patch(r.attempt), r.name),
    ];
    notifyListeners();
  }

  // ── Server-side search for the three list screens ──────────────────────
  //
  // The Assessments list, the question Bank and the Generators list each had a
  // box that filtered the rows the console happened to hold. All three routes
  // already accept `search`; nothing was sending it. `/generators` was not even
  // reachable - `api_client.generators()` dropped the parameter.
  //
  // Each screen keeps rendering its own cache when the box is EMPTY, so the
  // ordinary case costs no request and no KPI moves. A term switches the grid
  // to the slice, and only the grid: the counters beside it still describe the
  // population, which is what they are for.

  final SearchSlice<Assessment> assessmentSearch = SearchSlice<Assessment>();
  final SearchSlice<Question> bankSearch = SearchSlice<Question>();
  final SearchSlice<Generator> generatorSearch = SearchSlice<Generator>();

  /// ARCHIVED ROWS INCLUDED, the same bargain `_loadAdmin` takes: each of these
  /// screens has a "Show archived" toggle, and a search that dropped them would
  /// make an archived record unfindable on the one screen that can restore it.
  Future<void> searchAssessments(String term) => _runSearch<Assessment>(
    assessmentSearch,
    term,
    (String q, int limit) =>
        _api.assessments(search: q, limit: limit, includeArchived: true),
    Assessment.fromJson,
  );

  Future<void> searchBank(String term) => _runSearch<Question>(
    bankSearch,
    term,
    (String q, int limit) =>
        _api.bank(search: q, limit: limit, includeRetired: true),
    Question.fromJson,
  );

  Future<void> searchGenerators(String term) => _runSearch<Generator>(
    generatorSearch,
    term,
    (String q, int limit) =>
        _api.generators(search: q, limit: limit, includeArchived: true),
    Generator.fromJson,
  );

  /// One page of server-side matches for [term].
  ///
  /// An empty term is not a query: it clears the slice and issues NOTHING, which
  /// is what keeps clearing the box free and keeps the boot path untouched.
  Future<void> _runSearch<T>(
    SearchSlice<T> slice,
    String term,
    Future<Map<String, dynamic>> Function(String term, int limit) fetch,
    T Function(Map<String, dynamic>) parse, {
    int limit = 200,
  }) async {
    final String q = term.trim();
    if (q.isEmpty) {
      slice.seq++;
      slice.clear();
      scheduleMicrotask(notifyListeners);
      return;
    }
    if (source == DataSource.seed) {
      // No server to ask. The screen falls back to filtering its fixtures,
      // which is what an inactive slice means.
      slice.seq++;
      slice.clear();
      scheduleMicrotask(notifyListeners);
      return;
    }
    final int seq = ++slice.seq;
    slice.loading = true;
    try {
      // 200 is MAX_LIMIT. One page, not a walk: a walk here would put a request
      // per page behind a keystroke, and `partial` is how the screen stays
      // honest about the rows beyond it.
      final Map<String, dynamic> res = await fetch(q, limit);
      if (seq != slice.seq) return;
      final List<Map<String, dynamic>> rows = _rows(res);
      final Map<String, dynamic> meta =
          (jget(res, 'meta') as Map<String, dynamic>?) ?? <String, dynamic>{};
      slice.rows = rows.map(parse).toList();
      slice.total = jval(meta, 'total', slice.rows.length);
      slice.term = q;
      slice.error = '';
      slice.loading = false;
      notifyListeners();
    } on ApiError catch (e) {
      if (seq != slice.seq) return;
      slice.rows = <T>[];
      slice.total = 0;
      slice.term = q;
      slice.error = e.message;
      slice.loading = false;
      notifyListeners();
    }
  }

  /// Put a directory user on the roster.
  ///
  /// Separate from [toggleAssign], which is keyed on an APPLICANT id and
  /// refuses anybody it cannot find in `people` or the roster - which is every
  /// person who has never sat an assessment, i.e. exactly who this is for. The
  /// server creates the applicant and the portal account when they are new.
  Future<void> assignPickedUser(Assessment asm, Person user) async {
    await _act(
      'Assign',
      () => _api.assign(asm.id, userIds: <String>[user.id]),
      okMessage: (_) => '${user.name} assigned',
    );
    await loadAssessment(asm.id);
  }

  /// Assign or unassign a person. Assigning seeds an attempt with its own
  /// token; unassigning removes it entirely, because an attempt with no
  /// candidate is not a record anybody can act on.
  Future<void> toggleAssign(Assessment asm, String personId) async {
    // `people` is built from the candidates of EXISTING ATTEMPTS, so somebody
    // invited to a draft an hour ago is not in it - and this bailed out on
    // exactly those people. Their chip's Remove did nothing at all, silently,
    // which is the worst way for a control to refuse. The roster names them.
    final Person? p =
        personById(personId) ??
        asm.roster.where((Person r) => r.id == personId).firstOrNull;
    if (p == null) return;
    final Attempt? existing = attempts
        .where(
          (Attempt a) => a.assessmentId == asm.id && a.employeeId == personId,
        )
        .firstOrNull;
    // ATTEMPTS *OR* ROSTER. This read attempts alone, and a DRAFT has none -
    // the whole point of the roster is that it holds people before launch
    // creates their attempts. So every press on a draft resolved to "assign",
    // including the presses meant to undo one: the button never turned into
    // Remove, and a candidate added by mistake could not be taken off.
    final bool removing =
        existing != null || asm.roster.any((Person r) => r.id == personId);

    await _act(
      removing ? 'Remove' : 'Assign',
      () =>
          _api.assign(asm.id, personIds: <String>[personId], remove: removing),
      okMessage: (_) => removing ? '${p.name} removed' : '${p.name} assigned',
      ifSeed: () {
        if (removing) {
          // `existing?.id`, because `removing` is now also true for somebody
          // on the roster with no attempt yet - and no attempt has a null id,
          // so that case correctly drops nothing here.
          attempts = attempts
              .where((Attempt a) => a.id != existing?.id)
              .toList();
          toaster.info('${p.name} removed');
        } else {
          final String id = 'EV-${asm.id}-$personId';
          attempts = <Attempt>[
            ...attempts,
            Attempt(
              id: id,
              assessmentId: asm.id,
              employeeId: personId,
              token: 'tok-${stableHash(id).toRadixString(36)}',
              questionOrder: asm.questions.map((Question q) => q.id).toList(),
            ),
          ];
          toaster.ok('${p.name} assigned');
        }
        notifyListeners();
      },
    );
    // The roster only exists on the detail route, so without this the server
    // stored the assignment and the tab went on reading "Nobody is assigned
    // yet" - the button looked dead while it was working perfectly.
    await loadAssessment(asm.id);
  }

  /// Persist an assessment's configuration edits.
  ///
  /// Sends ONLY what changed. The route refuses any non-threshold field once
  /// the assessment has left draft, so sending the whole record - which is
  /// what this used to do - meant a perfectly legal threshold change was
  /// rejected because `duration_minutes` rode along unchanged beside it.
  Future<void> updateAsm(Assessment next) async {
    final Assessment? before = asmById(next.id);
    final int call = _asmEdits[next.id] = (_asmEdits[next.id] ?? 0) + 1;
    _replaceAsm(next);
    if (!_live) return;
    bool refused = false;

    bool changed(Object? a, Object? b) => before == null || a != b;

    await _act(
      'Save',
      () => _api.updateAssessment(
        next.id,
        name: changed(before?.name, next.name) ? next.name : null,
        questionLimit: changed(before?.questionLimit, next.questionLimit)
            ? next.questionLimit
            : null,
        durationMinutes: changed(before?.durationMinutes, next.durationMinutes)
            ? next.durationMinutes
            : null,
        shuffleQuestions:
            changed(before?.shuffleQuestions, next.shuffleQuestions)
            ? next.shuffleQuestions
            : null,
        subjectiveThreshold:
            changed(before?.subjectiveThreshold, next.subjectiveThreshold)
            ? next.subjectiveThreshold
            : null,
        passThreshold: changed(before?.passThreshold, next.passThreshold)
            ? next.passThreshold
            : null,
        llmAutoScore: changed(before?.llmAutoScore, next.llmAutoScore)
            ? next.llmAutoScore
            : null,
        resultsRelease: changed(before?.resultsRelease, next.resultsRelease)
            ? next.resultsRelease
            : null,
        // The proctoring rules are a RuleSet here and five booleans on the
        // model, so they are unpacked rather than passed through.
        blockTabSwitch:
            changed(
              before?.rules[ProctorRule.tabSwitch],
              next.rules[ProctorRule.tabSwitch],
            )
            ? next.rules[ProctorRule.tabSwitch]
            : null,
        blockCopyPaste:
            changed(
              before?.rules[ProctorRule.copyPaste],
              next.rules[ProctorRule.copyPaste],
            )
            ? next.rules[ProctorRule.copyPaste]
            : null,
        blockRightClick:
            changed(
              before?.rules[ProctorRule.rightClick],
              next.rules[ProctorRule.rightClick],
            )
            ? next.rules[ProctorRule.rightClick]
            : null,
        blockDevtools:
            changed(
              before?.rules[ProctorRule.devtools],
              next.rules[ProctorRule.devtools],
            )
            ? next.rules[ProctorRule.devtools]
            : null,
        watermark:
            changed(
              before?.rules[ProctorRule.watermark],
              next.rules[ProctorRule.watermark],
            )
            ? next.rules[ProctorRule.watermark]
            : null,
        fullscreen:
            changed(
              before?.rules[ProctorRule.fullscreen],
              next.rules[ProctorRule.fullscreen],
            )
            ? next.rules[ProctorRule.fullscreen]
            : null,
        webcam:
            changed(
              before?.rules[ProctorRule.webcam],
              next.rules[ProctorRule.webcam],
            )
            ? next.rules[ProctorRule.webcam]
            : null,
        aiProctor:
            changed(
              before?.rules[ProctorRule.aiProctor],
              next.rules[ProctorRule.aiProctor],
            )
            ? next.rules[ProctorRule.aiProctor]
            : null,
        requireSeb:
            changed(before?.rules[ProctorRule.seb], next.rules[ProctorRule.seb])
            ? next.rules[ProctorRule.seb]
            : null,
        maxViolations: changed(before?.maxViolations, next.maxViolations)
            ? next.maxViolations
            : null,
        violationAction: changed(before?.violationAction, next.violationAction)
            ? next.violationAction.wire
            : null,
        aiMaxViolations: changed(before?.aiMaxViolations, next.aiMaxViolations)
            ? next.aiMaxViolations
            : null,
        aiViolationAction:
            changed(before?.aiViolationAction, next.aiViolationAction)
            ? next.aiViolationAction.wire
            : null,
        requireReviewedRubric:
            changed(before?.requireReviewedRubric, next.requireReviewedRubric)
            ? next.requireReviewedRubric
            : null,
        resultsShowAnswers:
            changed(before?.resultsShowAnswers, next.resultsShowAnswers)
            ? next.resultsShowAnswers
            : null,
        transcriptionThreshold:
            changed(before?.transcriptionThreshold, next.transcriptionThreshold)
            ? next.transcriptionThreshold
            : null,
      ),
      okMessage: (_) => 'Saved',
      // A REFUSED EDIT COMES OFF THE SCREEN. The re-read `_act` ends with is
      // the list, whose rows lack the detail-only fields (the AI pair, "show
      // answers", the transcription bar), so the refused value stayed.
      //
      // ONLY THIS CALL'S EDIT. Putting back the whole record as it stood at
      // the call also erased a second edit made while this one was on the
      // wire. Each field goes back to its value before the call, unless a
      // later edit has changed it since.
      rollback: () {
        refused = true;
        final Assessment? now = asmById(next.id);
        if (before == null || now == null) return;
        T back<T>(T Function(Assessment a) f) =>
            f(now) == f(next) ? f(before) : f(now);
        _replaceAsm(
          now.copyWith(
            name: back((Assessment a) => a.name),
            questionLimit: back((Assessment a) => a.questionLimit),
            durationMinutes: back((Assessment a) => a.durationMinutes),
            shuffleQuestions: back((Assessment a) => a.shuffleQuestions),
            subjectiveThreshold: back((Assessment a) => a.subjectiveThreshold),
            passThreshold: back((Assessment a) => a.passThreshold),
            llmAutoScore: back((Assessment a) => a.llmAutoScore),
            resultsRelease: back((Assessment a) => a.resultsRelease),
            rules: RuleSet(<ProctorRule, bool>{
              for (final ProctorRule r in ProctorRule.values)
                r: back((Assessment a) => a.rules[r]),
            }),
            maxViolations: back((Assessment a) => a.maxViolations),
            violationAction: back((Assessment a) => a.violationAction),
            aiMaxViolations: back((Assessment a) => a.aiMaxViolations),
            aiViolationAction: back((Assessment a) => a.aiViolationAction),
            requireReviewedRubric: back(
              (Assessment a) => a.requireReviewedRubric,
            ),
            resultsShowAnswers: back((Assessment a) => a.resultsShowAnswers),
            transcriptionThreshold: back(
              (Assessment a) => a.transcriptionThreshold,
            ),
          ),
        );
      },
    );
    // And the detail says what the server holds now - but only from the last
    // save of overlapping ones: read while a later save is still on the wire,
    // it would wipe that edit off the screen too.
    if (refused && _asmEdits[next.id] == call) await loadAssessment(next.id);
  }

  /// How many [updateAsm] calls each assessment has had, so a refused one can
  /// tell whether a later one started after it.
  final Map<String, int> _asmEdits = <String, int>{};

  /// Create an assessment and return the id the SERVER gave it.
  ///
  /// Returning the id matters: the screen used to navigate to
  /// `'A-${assessments.length + 1}'`, an id that exists nowhere, so every
  /// successful create landed on "Assessment not found".
  ///
  /// It sends the WHOLE form. The eight proctoring rules, the violation
  /// policy, the thresholds, the rubric gate and the manual question pick were
  /// all collected by the UI, accepted by `ApiClient.createAssessment` and
  /// allow-listed by the server - and none of them were being passed, so an
  /// operator's proctoring choices were silently discarded at creation.
  ///
  /// Not routed through `_act`: that helper throws the response away, and the
  /// new id is in it.
  Future<String?> addAssessment(Assessment a) async {
    if (!_live) {
      assessments = <Assessment>[a, ...assessments];
      toaster.ok('${a.name} created - assign candidates next');
      notifyListeners();
      return a.id;
    }
    try {
      final Map<String, dynamic> res = await _api.createAssessment(
        name: a.name,
        generatorId: a.generatorId.isEmpty ? null : a.generatorId,
        questionLimit: a.questionLimit,
        durationMinutes: a.durationMinutes,
        // Sent explicitly for the same reason as llmAutoScore below - the
        // create form defaults it ON, and an omitted key would let the module
        // fall back to the AUTHORED order the shuffle exists to break.
        shuffleQuestions: a.shuffleQuestions,
        subjectiveThreshold: a.subjectiveThreshold,
        // The form starts it at the Settings default; the typed value wins.
        passThreshold: a.passThreshold,
        questionIds: a.questions.map((Question q) => q.id).toList(),
        rules: a.rules.asMap,
        violationAction: a.violationAction.wire,
        maxViolations: a.maxViolations,
        aiViolationAction: a.aiViolationAction.wire,
        aiMaxViolations: a.aiMaxViolations,
        transcriptionThreshold: a.transcriptionThreshold,
        requireReviewedRubric: a.requireReviewedRubric,
        // SENT EXPLICITLY. The module defaults `llm_auto_score` to False and
        // this call used to omit it, so every assessment created from here had
        // subjective grading off and its answers starved silently - the cron
        // only ever drains evaluators whose `scoring_requested` was set, and
        // that flag is only set on submit when this is on.
        llmAutoScore: a.llmAutoScore,
        resultsRelease: a.resultsRelease,
        resultsShowAnswers: a.resultsShowAnswers,
      );
      // `_call` has already unwrapped `data`, so the id is at the top level.
      final String id = jid(jget(res, 'id'));
      toaster.ok('${a.name} created - assign candidates next');
      await refresh();
      return id.isEmpty ? null : id;
    } on ApiError catch (e) {
      toaster.bad(e.message);
      return null;
    }
  }

  /// Create a generator by NAME, and hand back its id.
  ///
  /// THE DOCUMENT IS NOT COLLECTED HERE. `/generators/create` takes a name and
  /// nothing file-shaped; the SOP has always been a second call, to
  /// `/generators/<id>/resources`. The wizard this replaced bound the two
  /// together and then dropped the operator on the corpus tab, which uploads
  /// SOPs too - so the product asked for the same document twice. The corpus
  /// tab is now the only one.
  ///
  /// Not routed through `_act`, for the same reason `addAssessment` is not:
  /// that helper throws the response away and the new id is in it. Without the
  /// id there is no way to open the screen the document goes on.
  ///
  /// Returns the new generator's id, or null when the create failed.
  Future<String?> addGenerator(String name) async {
    if (!_live) {
      final String id = 'GEN-${generators.length + 1}';
      generators = <Generator>[
        Generator(
          id: id,
          name: name,
          owner: 'Aarav Mehta',
          created: 'just now',
        ),
        ...generators,
      ];
      toaster.ok('$name created - attach its SOP next');
      notifyListeners();
      return id;
    }
    try {
      // No source text: the SOP arrives as an uploaded document, and the
      // module reads it from the attached resource rather than from a field
      // the client fills in.
      final Map<String, dynamic> res = await _api.createGenerator(name: name);
      // `_call` ALREADY unwraps the envelope and returns `data` itself, so the
      // id is at the top level of what comes back. Reading `res['data']` here
      // reads as obviously correct, finds nothing, and leaves the caller with
      // no id to navigate to - the generator exists and the flow dead-ends.
      final String id = jid(jget(res, 'id'));
      if (id.isEmpty) {
        toaster.bad('The server did not return a generator id');
        return null;
      }
      await refresh();
      // ATTACH, not extract. Extraction 409s `no_source` with no document, so
      // naming it as the next step is naming a refusal.
      toaster.ok('$name created - attach its SOP next');
      return id;
    } on ApiError catch (e) {
      toaster.bad(e.message);
      return null;
    } catch (e) {
      toaster.bad('$e');
      return null;
    }
  }

  /// Load ONE answer in full and merge it into the attempt that owns it.
  ///
  /// The `/responses` LIST row omits `lines`, `subscores`, `justification`,
  /// `grading`, `correct_summary` and the nested `question`. Those are the
  /// per-dimension marking - literally what an operator opens an answer to
  /// read - so the detail screen rendered a chosen option with no breakdown
  /// and no reasoning, which looks like a grader that produced nothing.
  Future<void> loadResponse(String attemptId, String questionId) =>
      _withHydration(
        'response',
        '$attemptId/$questionId',
        () => _loadResponse(attemptId, questionId),
      );

  Future<void> _loadResponse(String attemptId, String questionId) async {
    if (!_live) return;
    try {
      // The answer needs its ATTEMPT to land anywhere: the attempt owns the
      // response map. On a cold cache - a deep link, or a browser refresh -
      // it was absent, so the fetched answer was dropped at the `ev == null`
      // guard below and the screen settled on "That answer is no longer on
      // this attempt" over a live record.
      //
      // `_loadAttempt` pulls the assessment in behind it, which is where the
      // question and the marking scheme come from.
      Attempt? ev = attemptById(attemptId);
      if (ev == null) {
        await _loadAttempt(attemptId);
        ev = attemptById(attemptId);
      }

      final Map<String, dynamic> res = await _api.response(
        attemptId,
        questionId,
      );
      if (ev == null) return;
      final Response full = Response.fromJson(res);
      final Map<String, Response> merged = <String, Response>{
        ...ev.resp,
        questionId: full,
      };
      attempts = attempts
          .map((Attempt a) => a.id == attemptId ? a.copyWith(resp: merged) : a)
          .toList();

      // THE QUESTION IS HALF THE SCREEN, and it was being thrown away.
      //
      // The response screen looks its question up on the ASSESSMENT
      // (`asm.questionById`), and gives up with "That answer is no longer on
      // this attempt" when it finds none. Reached from All responses the
      // assessment in cache is the LIST row, which carries no question list at
      // all - so a perfectly live answer resolved to "Response not found",
      // while the very request above had already returned that question in
      // full, under `question`, and nothing read it.
      //
      // Merged rather than merely cached in `bank`, because the lookup goes
      // through the assessment. And it is an UPGRADE in both directions: the
      // detail shape is a superset of the bank row the list route puts there,
      // so it fills in the dimensions, the options and the answer key that the
      // row spelled only as a count.
      await _mergeResponseQuestion(
        ev.assessmentId,
        jmap(jget(res, 'question')),
      );

      notifyListeners();
    } on ApiError catch (e) {
      toaster.bad(e.message);
    } catch (e, st) {
      _hydrationFailed('loadResponse', e, st);
    }
  }

  /// File one fully-detailed question onto its assessment, and into the bank.
  ///
  /// Called with whatever `/api/v1/responses/<ev>/<q>` sent under `question`.
  /// An empty or id-less payload is a no-op rather than an error: the answer
  /// itself has already been merged by then, and losing the question record
  /// should cost the panels that need it, not the whole load.
  ///
  /// The assessment is fetched first when it is absent or hollow, so the
  /// question has a list to be merged INTO. Without that step a single
  /// question would be the only one on the assessment, and the marks
  /// denominator - which counts that list - would read "/ 1".
  Future<void> _mergeResponseQuestion(
    String assessmentId,
    Map<String, dynamic> raw,
  ) async {
    if (raw.isEmpty || assessmentId.isEmpty) return;
    final Question q = Question.fromJson(raw);
    if (q.id.isEmpty) return;

    bank = _upsert<Question>(bank, q, (Question x) => x.id == q.id);

    Assessment? asm = asmById(assessmentId);
    if (asm == null || asm.questions.isEmpty) {
      await _loadAssessment(assessmentId);
      asm = asmById(assessmentId);
    }
    // STILL HOLLOW IS A NO-OP, not something to append to. `_loadAssessment`
    // swallows an ApiError into a toast and returns, so a failed pre-fetch
    // leaves the cached `assessment_row` in place - non-null, and still
    // carrying no questions. Appending here would then write the one question
    // just merged as the assessment's ENTIRE list: the "/ 1" denominator this
    // pre-fetch exists to prevent, and one that survives every later refresh
    // because `_mergeAssessments` keeps `old.questions` whenever a list row
    // omits the key.
    if (asm == null || asm.questions.isEmpty) return;

    // Replace in place where the row already sits, so the question order the
    // assessment was built with survives; append only when it is genuinely
    // absent.
    final List<Question> next = asm.questions
        .map((Question x) => x.id == q.id ? q : x)
        .toList();
    if (!next.any((Question x) => x.id == q.id)) next.add(q);

    final Assessment updated = asm.copyWith(questions: next);
    assessments = _upsert<Assessment>(
      assessments,
      updated,
      (Assessment a) => a.id == updated.id,
    );
  }

  /// Load ONE bank question in full and merge it into the cache.
  ///
  /// The LIST route sends 21 keys; the DETAIL route sends 31. The ten it adds
  /// are exactly what a preview needs - `images`, `videos`, `dimensions`,
  /// `solution`, `solution_rationale`, `subjective_rubric` - so previewing a
  /// question straight off the list showed the prompt with no media, no
  /// dimensions and no answer key, and looked like a question that had been
  /// authored badly rather than one that was never fully fetched.
  Future<void> loadQuestion(String id) =>
      _withHydration('question', id, () => _loadQuestion(id));

  Future<void> _loadQuestion(String id) async {
    if (!_live) return;
    try {
      final Map<String, dynamic> res = await _api.bankQuestion(id);
      final Question full = Question.fromJson(res);
      bank = _upsert<Question>(bank, full, (Question q) => q.id == full.id);
      notifyListeners();
    } on ApiError catch (e) {
      toaster.bad(e.message);
    } catch (e, st) {
      _hydrationFailed('loadQuestion', e, st);
    }
  }

  /// Load the FULL attempt and merge it into the cache.
  ///
  /// `AttemptDetailScreen` never hydrated: it relied entirely on the list having
  /// been loaded, so a deep link or a browser refresh landed on "Attempt not
  /// found. It may have been removed." over a live record. The route and the
  /// client method both existed already; nothing called them.
  Future<void> loadAttempt(String id) =>
      _withHydration('attempt', id, () => _loadAttempt(id));

  Future<void> _loadAttempt(String id) async {
    if (!_live) return;
    try {
      final Map<String, dynamic> res = await _api.attempt(id);
      final Attempt full = Attempt.fromJson(res);
      attempts = _upsert<Attempt>(
        attempts,
        full,
        (Attempt a) => a.id == full.id,
      );

      // The attempt route embeds its assessment, so take it and skip a second
      // request - but ONLY when it carries the questions, because an upsert
      // with a thinner record would downgrade a cache the detail route had
      // already filled.
      final Assessment embedded = Assessment.fromJson(
        jmap(jget(res, 'assessment')),
      );
      if (embedded.id.isNotEmpty && embedded.questions.isNotEmpty) {
        assessments = _upsert<Assessment>(
          assessments,
          embedded,
          (Assessment a) => a.id == embedded.id,
        );
      }
      notifyListeners();

      // The screen also needs the assessment: it reads the question list and
      // the marking scheme from there, and rendered "Assessment not found"
      // when only the attempt had been fetched.
      //
      // `== null` WAS NOT ENOUGH. The assessments LIST route sends counters,
      // not records, so an assessment reached from anywhere but its own detail
      // screen sits in the cache WITH AN EMPTY QUESTION LIST. The guard saw a
      // record, skipped the fetch, and "Score details" - which walks
      // `asm.questions` - had nothing to walk. Present but hollow is the shape
      // that actually reaches this screen, so it is the shape to test for.
      final Assessment? cached = asmById(full.assessmentId);
      if (cached == null || cached.questions.isEmpty) {
        await _loadAssessment(full.assessmentId);
      }
    } on ApiError catch (e) {
      toaster.bad(e.message);
    } catch (e, st) {
      _hydrationFailed('loadAttempt($id)', e, st);
    }
  }

  /// Report a hydration failure instead of swallowing it.
  ///
  /// A thin list row is still a valid record, so the screen must not blank.
  /// But a silent `catch (_)` also hid a TypeError that discarded a whole
  /// draft, leaving the card claiming the server had sent no image.
  void _hydrationFailed(String what, Object e, StackTrace st) {
    debugPrint('$what failed: $e\n$st');
    toaster.warn('Could not load the full record - showing partial data');
  }

  /// Load the FULL draft and merge it into the review queue.
  ///
  /// The `/drafts` LIST route sends 21 keys; the DETAIL route sends 35. The
  /// fourteen it adds are exactly what a reviewer needs to judge the question:
  /// `images` (the rendered stimulus, as a data URL), `label_boxes`,
  /// `dimensions`, `options`, `rubric`, `answer_key`, `solution` and the
  /// video files.
  ///
  /// Without this the queue said "The stimulus for this question has not
  /// rendered" directly under a badge reading "Rendered" - the server had the
  /// PNG all along, the list row simply never carried it. A reviewer was being
  /// asked to approve a labelling question without seeing the image.
  Future<void> loadDraft(String id) =>
      _withHydration('draft', id, () => _loadDraft(id));

  Future<void> _loadDraft(String id) async {
    if (!_live) return;
    try {
      final Map<String, dynamic> res = await _api.draft(id);
      final Question full = Question.fromJson(res);
      drafts = _upsert<Question>(drafts, full, (Question q) => q.id == full.id);
      notifyListeners();
    } on ApiError catch (e) {
      toaster.bad(e.message);
    } catch (e, st) {
      _hydrationFailed('loadDraft($id)', e, st);
    }
  }

  /// Load the FULL assessment record and merge it into the cache.
  ///
  /// The LIST route sends counts, not records: `candidate_count` but no
  /// `roster`. So an assessment opened from the list knows two people are
  /// invited and cannot name either - the Assign tab said "Nobody is assigned
  /// yet" over a roster the server had stored correctly. Same shape as
  /// `loadGenerator`, and for the same reason.
  Future<void> loadAssessment(String id) =>
      _withHydration('assessment', id, () => _loadAssessment(id));

  Future<void> _loadAssessment(String id) async {
    if (!_live) return;
    try {
      final Map<String, dynamic> res = await _api.assessment(id);
      final Assessment full = Assessment.fromJson(res);
      if (jget(res, 'resultsShowAnswers') != null) _sawShowAnswers = true;
      // UPSERT, not map. `.map()` replaces a match and drops the record
      // entirely when there is none, so a deep link or a page refresh - which
      // arrives with an empty cache - fetched the record successfully and then
      // threw it away, leaving the screen on "Assessment not found" forever.
      assessments = _upsert<Assessment>(
        assessments,
        full,
        (Assessment a) => a.id == full.id,
      );
      notifyListeners();
    } on ApiError catch (e) {
      toaster.bad(e.message);
    } catch (e, st) {
      _hydrationFailed('loadAssessment', e, st);
    }
  }

  /// Load the FULL generator record and merge it into the cache.
  ///
  /// The list route sends counts, not records: `resource_count` but no
  /// `resources`, so a generator opened from the list has an empty resource
  /// list and its corpus tab says "No files attached" over a document the
  /// server holds. Only `/api/v1/generators/<id>` carries the records, and
  /// nothing was calling it.
  Future<void> loadGenerator(String id) =>
      _withHydration('generator', id, () => _loadGenerator(id));

  Future<void> _loadGenerator(String id) async {
    if (!_live) return;
    try {
      final Map<String, dynamic> res = await _api.generator(id);
      final Generator full = Generator.fromJson(res);
      generators = _upsert<Generator>(
        generators,
        full,
        (Generator g) => g.id == full.id,
      );
      notifyListeners();
    } on ApiError catch (e) {
      toaster.bad(e.message);
    } catch (e, st) {
      _hydrationFailed('loadGenerator', e, st);
    }
  }

  /// The server's runner state, per token. See [ExamView].
  final Map<String, ExamView> examByToken = <String, ExamView>{};

  /// The pre-submit checklist, per token, from `/exam/<token>/review`.
  final Map<String, List<ExamReviewRow>> examReviewByToken =
      <String, List<ExamReviewRow>>{};

  ExamView? examView(String token) => examByToken[token];

  /// Load ONE sitting by its access token and merge it into the cache.
  ///
  /// WHY THIS EXISTS. `attemptByToken` searches attempts that are already
  /// loaded. A candidate arriving from an invitation link has loaded nothing
  /// for that token yet, so the exam screen found no attempt and rendered
  /// "This link does not work" over a perfectly valid link - the server
  /// answers `/api/v1/exam/<token>/state` with `ok: true` for the same token.
  ///
  /// `/exam/<token>/state` is scoped to the token itself, so it works for a
  /// candidate who cannot read `/api/v1/assessments` at all.
  ///
  /// NOT while another tab holds the sitting: any `/state` from this tab
  /// takes it back, so only [continueExamHere] may ask.
  Future<void> loadExamByToken(String token) async {
    if (!_live || token.isEmpty || sessionReplaced.contains(token)) return;
    try {
      final Map<String, dynamic> res = await _api.examState(token);

      // The OUTCOME is the navigation authority. Reading only `attempt` meant
      // `invalid`, `login_required` and `wrong_candidate` - none of which
      // carry an attempt - all fell through to the same "this link does not
      // work" screen, including for a candidate who was simply not signed in.
      examByToken[token] = ExamView.fromJson(res);

      // The attempt row does not carry its own token - the caller supplied it -
      // so put it back, or `attemptByToken` still will not find this record.
      final Object? rawAttempt = jget(res, 'attempt');
      if (rawAttempt is Map<String, dynamic>) {
        final Map<String, dynamic> row = <String, dynamic>{
          ...rawAttempt,
          'access_token': token,
        };
        final Object? asm = jget(res, 'assessment');
        if (asm is Map<String, dynamic>) {
          row['assessment_id'] = jget(asm, 'id');
        }
        // The MARKS live under `result`, not on the attempt. Merging the
        // attempt alone left the summary reading "0 of 0" for a released
        // result the server reports as "0 / 3".
        final Object? result = jget(res, 'result');
        if (result is Map<String, dynamic>) {
          row['result'] = result;
        }
        final Attempt ev = Attempt.fromJson(row);
        attempts = <Attempt>[
          ...attempts.where((Attempt a) => a.id != ev.id),
          ev,
        ];
      }
      // AFTER the attempt is in place (A-068). Adopted first, a cold resume
      // had no attempt to seed and a warm one had its seed overwritten by the
      // row above, so the landing question opened blank over a stored answer.
      _adoptServerAnswer(token, jget(res, 'question'));

      // The assessment too, when the payload named one. A candidate cannot
      // read the assessment list, so this is the only way the exam runner
      // learns the name and the duration.
      final Object? asm = jget(res, 'assessment');
      if (asm is Map<String, dynamic>) {
        final Assessment a = Assessment.fromJson(asm);
        assessments = <Assessment>[
          ...assessments.where((Assessment x) => x.id != a.id),
          a,
        ];
      }
      // THE REPORTS THIS TAB STILL HOLDS GO NOW (BR-D15), onto a sitting
      // still open: the server has just answered, and they go before any
      // answer typed after them.
      if ((_reports[token]?.isNotEmpty ?? false) &&
          (examByToken[token]?.isQuestion ?? false)) {
        unawaited(_sendReportsSoon(token));
      }
      notifyListeners();
    } on ApiError {
      // A genuinely dead token leaves the cache untouched, and the exam screen
      // then shows its own "link does not work" gate - which is correct here.
    } catch (e, st) {
      _hydrationFailed('loadExamByToken', e, st);
    }
  }

  /// Open question [index] WITHOUT saving anything.
  ///
  /// The runner's other way to reach a question is `/answer`, which saves and
  /// moves in one call and refuses to do either when the answer it is handed
  /// is incomplete. That made a blank question a dead end: a candidate who
  /// wanted to skip it, or who cleared a box to think again, could not go
  /// forward, back, or to the review page - the same 422 blocked all three.
  ///
  /// `/state` takes the same 1-based `q` and answers with the question
  /// envelope, so moving and saving are separable. Anything the candidate has
  /// already typed stays in `resp`, and [_adoptServerAnswer] only seeds a
  /// question the store holds nothing for, so a local edit is never
  /// overwritten by the server's older copy.
  Future<void> loadExamQuestion(String token, int index) async {
    // Same rule as [loadExamByToken]: a stood-down tab sends no `/state`.
    if (!_live || token.isEmpty || index < 1) return;
    if (sessionReplaced.contains(token)) return;
    try {
      final Map<String, dynamic> res = await _api.examState(token, q: index);
      examByToken[token] = ExamView.fromJson(res);
      _adoptServerAnswer(token, jget(res, 'question'));
      notifyListeners();
    } on ApiError catch (e) {
      toaster.bad(e.candidateMessage);
    } catch (e, st) {
      _hydrationFailed('loadExamQuestion($index)', e, st);
    }
  }

  /// Replace a generator in the local list. LOCAL ONLY - it does not write.
  ///
  /// It used to POST `name` and nothing else, then trigger a full console
  /// reload. Every caller is an optimistic UI update, not a save:
  /// `setAllowedTypes` follows it with `setQuestionTypes`, and
  /// `startGeneration` uses it to paint the Queued pill. So every type change
  /// and every Generate press fired a pointless name-only write plus an
  /// 8-request refresh, racing the call that actually mattered.
  ///
  /// It could not have persisted what those callers wanted anyway: the route's
  /// writable fields are name/source_text/sop_title/sop_summary -
  /// `allowed_question_type_ids` and `sop_gen_state` are not among them.
  /// Renaming goes through [saveGeneratorName].
  void updateGenerator(Generator next) {
    generators = generators
        .map((Generator g) => g.id == next.id ? next : g)
        .toList();
    notifyListeners();
  }

  /// Rename an assessment. Same shape as [saveGeneratorName].
  ///
  /// Allowed in every state, unlike the rest of the configuration: the server
  /// carries `name` in `POST_DRAFT_FIELDS`, because a name is not part of the
  /// exam a candidate agreed to and a wrong one would otherwise be permanent
  /// the moment the assessment launched.
  Future<void> saveAssessmentName(String id, String name) async {
    final Assessment? current = assessments
        .where((Assessment a) => a.id == id)
        .firstOrNull;
    if (current == null) return;
    // The local record first, so the header shows the new name immediately
    // rather than snapping back until the reload lands.
    _replaceAsm(current.copyWith(name: name));
    if (!_live) return;
    await _act(
      'Save',
      () => _api.updateAssessment(id, name: name),
      okMessage: (_) => 'Saved',
    );
  }

  /// One pending shortlist save per assessment, so ticking two assessments'
  /// questions cannot cancel each other's write. See [persistForm].
  final Map<String, Timer> _shortlistSync = <String, Timer>{};

  /// Shortlist which of an assessment's pool questions actually get drawn.
  ///
  /// DRAFT ONLY, and the guard is real rather than defensive: the server keeps
  /// `question_ids` out of `POST_DRAFT_FIELDS`, so a write after launch is a 409
  /// for the whole request - which would also lose the `question_limit` riding
  /// along with it. The tab renders its ticks inert in that state; this is the
  /// second lock.
  ///
  /// NEVER LEAVES ZERO TICKED. The server reads an empty `question_ids` as "the
  /// whole generator", so unticking the last question would silently mean the
  /// exact opposite of what the operator just did - a full paper, not an empty
  /// one. The last tick refuses to come off and says why.
  ///
  /// THE LIMIT IS THE TICK COUNT. Launch draws ONE shared set of
  /// `question_limit` from the ticked questions, so a limit above the ticks is
  /// a draft that cannot start, and a limit below them is a random subset
  /// nobody asked for - 15 ticked over a limit of 6 launched a 6-question
  /// paper (prod, 2026-09-29).
  void setQuestionsInUse(String asmId, Set<String> ids) {
    final Assessment? current = assessments
        .where((Assessment a) => a.id == asmId)
        .firstOrNull;
    if (current == null || current.state != AsmState.draft) return;

    final Set<String> next = current.pool
        .where((Question q) => ids.contains(q.id))
        .map((Question q) => q.id)
        .toSet();
    if (next.isEmpty) {
      toaster.bad(
        'Keep at least one question. An empty shortlist means the whole '
        'generator, not an empty paper.',
      );
      return;
    }

    final int limit = next.length;
    // The local record first, so the tick lands under the cursor rather than
    // after the round trip - the same reason [setQuestionCount] does it.
    _replaceAsm(current.copyWith(inUseIds: next, questionLimit: limit));
    if (!_live) return;

    // ONE request for the whole burst. Select-all over forty questions is forty
    // taps' worth of state but one instrument, and the full set goes every time,
    // so a dropped request costs nothing - the next tick carries it again.
    _shortlistSync[asmId]?.cancel();
    _shortlistSync[asmId] = Timer(const Duration(milliseconds: 600), () {
      _shortlistSync.remove(asmId);
      unawaited(
        _act(
          'Save',
          () => _api.updateAssessment(
            asmId,
            questionIds: next.toList(),
            questionLimit: limit,
          ),
          okMessage: (_) => 'Shortlist saved',
        ),
      );
    });
  }

  /// Flip one question in or out of the shortlist.
  void toggleQuestionInUse(String asmId, String questionId) {
    final Assessment? current = assessments
        .where((Assessment a) => a.id == asmId)
        .firstOrNull;
    if (current == null) return;
    final Set<String> next = <String>{...current.inUseIds};
    next.contains(questionId) ? next.remove(questionId) : next.add(questionId);
    setQuestionsInUse(asmId, next);
  }

  /// The one place a generator's own fields are actually saved.
  Future<void> saveGeneratorName(String id, String name) async {
    updateGenerator(
      (generators.firstWhere((Generator g) => g.id == id)).copyWith(name: name),
    );
    if (!_live) return;
    await _act(
      'Save',
      () => _api.updateGenerator(id, name: name),
      okMessage: (_) => 'Saved',
      refreshAfter: false,
    );
    await loadGenerator(id);
    // The one other place the name shows: assessment rows carry their own copy
    // of it, which the skipped console reload used to re-read.
    final String now = genById(id)?.name ?? name;
    assessments = assessments
        .map(
          (Assessment a) =>
              a.generatorId == id ? a.copyWith(generatorName: now) : a,
        )
        .toList();
    notifyListeners();
  }

  /// How many questions a generation run should produce.
  ///
  /// 0 means "let the model decide from the SOP". The app could only DISPLAY
  /// this before - "generate 10 questions from this SOP" was not expressible,
  /// and an operator got whatever was last pinned in Odoo.
  Future<void> setQuestionCount(String genId, int count) async {
    final Generator? g = genById(genId);
    if (g == null || count < 0) return;
    // THE LOCAL RECORD FIRST, for the reason [setImageLabelCount] gives: the
    // control is a stepper that posts on every change and computes its next
    // value from the one it is showing, so leaving the display on the server's
    // old number until `loadGenerator` returns lets two quick presses both
    // compute from the same stale figure - and the second write undoes the
    // first. This mattered less when the control was a pair of icon buttons
    // that could be disabled mid-write; it is a real field now.
    // The MODE moves with the number. `countIsAuto` reads
    // `questionCountMode`, not the count, so updating only the count would
    // leave the control showing "Auto" over a number the user just typed
    // until the reload landed - and briefly render the field with a
    // placeholder while switching the other way.
    updateGenerator(
      g.copyWith(
        sopQuestionCount: count,
        questionCountMode: count == 0 ? 'auto' : 'fixed',
      ),
    );
    await withBusy('count:$genId', () async {
      await _act(
        'Save',
        () => _api.updateGenerator(genId, questionCount: count),
        ifSeed: () => toaster.info('Editing runs against a live server'),
        okMessage: (_) => count == 0
            ? 'The model will decide how many to generate'
            : 'Next run will target $count question(s)',
        refreshAfter: false,
      );
    });
    await loadGenerator(genId);
  }

  /// The most labels ONE image-labelling question this generator writes may
  /// carry.
  ///
  /// The local record is replaced FIRST, unlike [setQuestionCount]. The
  /// control here is a plain stepper that posts on every change and computes
  /// its next value from the one it is showing, so leaving the display on the
  /// server's old number until `loadGenerator` returns would make two quick
  /// presses of `+` send the same value twice - and in demo mode, where
  /// nothing is written at all, the stepper would never move.
  ///
  /// The floor is 1 because the module refuses 0, so a call below it is
  /// dropped rather than sent and answered with a toast.
  /// Live website screenshots instead of AI-made labelling pictures, for a
  /// project that asks for them. Same local-first save as [setImageLabelCount].
  Future<void> setImageLabelLiveCapture(String genId, bool on) async {
    final Generator? g = genById(genId);
    if (g == null) return;
    updateGenerator(g.copyWith(imageLabelLiveCapture: on));
    await withBusy('capture:$genId', () async {
      await _act(
        'Save',
        () => _api.updateGenerator(genId, imageLabelLiveCapture: on),
        ifSeed: () => toaster.info('Editing runs against a live server'),
        okMessage: (_) => on
            ? 'Annotation pictures: live website screenshots'
            : 'Annotation pictures: AI-made',
        refreshAfter: false,
      );
    });
    await loadGenerator(genId);
  }

  Future<void> setImageLabelCount(String genId, int count) async {
    final Generator? g = genById(genId);
    if (g == null || count < 1) return;
    updateGenerator(g.copyWith(imageLabelCount: count));
    await withBusy('labels:$genId', () async {
      await _act(
        'Save',
        () => _api.updateGenerator(genId, imageLabelCount: count),
        ifSeed: () => toaster.info('Editing runs against a live server'),
        okMessage: (_) => 'Up to $count label(s) per question',
        refreshAfter: false,
      );
    });
    await loadGenerator(genId);
  }

  // ══════════════════════════════════════════════════════════════════════
  //  Scoring and recovery
  // ══════════════════════════════════════════════════════════════════════

  /// How many of a question's KEYED dimensions this answer got exactly right.
  ///
  /// EACH KEYED DIMENSION IS ONE COMPONENT AND IS MARKED ON ITS OWN. That is
  /// the module's rule now, and it is why this counts rather than returning a
  /// bool: a three-sub-question mcq with two right is worth 2, where the old
  /// all-or-nothing test across the whole question awarded 0 and demo mode
  /// disagreed with every live paper.
  ///
  /// The picks are INTERSECTED WITH EACH DIMENSION'S OWN OPTIONS rather than
  /// compared whole, because `lines` is one flat list of option ids across
  /// every axis - a pick on another axis is not evidence about this one.
  ///
  /// An UNKEYED dimension is skipped, not failed. The module counts only
  /// dimensions with at least one correct option as components (an A/B rating
  /// axis with no key is a prompt for an opinion, not a question with an
  /// answer), so counting it would deny a mark for a key the author never
  /// wrote.
  static int _dimensionsPassed(Question q, Response r) {
    final Set<String> got = r.lines.toSet();
    int passed = 0;
    for (final QDimension d in q.dims) {
      final Set<String> want = d.correctIds;
      if (want.isEmpty) continue;
      final Set<String> mine = <String>{
        for (final QOption o in d.options)
          if (got.contains(o.id)) o.id,
      };
      if (mine.length == want.length && want.every(mine.contains)) passed++;
    }
    return passed;
  }

  /// Grade one answer, THE SEED'S WAY. See the live short-circuit below.
  ///
  /// THE UNIT IS THE COMPONENT, NOT THE QUESTION, exactly as the module scores
  /// it: one mark per keyed dimension, marked independently, plus one for the
  /// LLM-graded free text where the type has any. So a three-sub-question mcq
  /// is out of 3 and an image_ab is out of its verdict axes plus one - and
  /// [Question.componentCount] is the same arithmetic, so the denominator this
  /// writes and the one [Attempt.maxMarks] falls back to cannot drift.
  ///
  /// IMAGE LABELLING IS DELIBERATELY UNCHANGED: the module scores the box set
  /// AS A WHOLE for one mark, which is what the single thresholded component
  /// below already awards it. There is nothing per-box to threshold here in
  /// any case - the seed carries one blended raw per answer and no per-box
  /// scores - so splitting it would mean inventing them.
  ///
  /// A subjective answer with nothing in it is discarded entirely rather than
  /// scored zero, so an empty answer becomes an unanswered question.
  Response? gradeOne(Assessment asm, Question q, Response r) {
    if (q.type.isObjective) {
      return r.copyWith(
        score: _dimensionsPassed(q, r),
        maxScore: q.componentCount,
        state: 'submitted',
        llmState: LlmState.notNeeded,
      );
    }

    if (!r.hasInput) return null;

    // AGAINST A LIVE SERVER, THIS CLIENT DOES NOT GRADE.
    //
    // The module's scoring cron owns the subjective verdict. The seeded
    // fallback below is demo scaffolding, and it was running in live mode too:
    // combined with the `llm_raw_100` parse miss it fired on EVERY subjective
    // answer, so finishing an exam briefly wrote a random pass/fail and a
    // fabricated Judge rationale into the live store. Nothing reached the
    // candidate - the completion screen gates on resultsReleased - but a made-up
    // score has no business existing next to real ones.
    if (_live) {
      return r.copyWith(state: 'submitted', llmState: LlmState.pending);
    }

    // Subjective: the grader returns a raw 0-100. The WRITTEN answer is ONE
    // component and earns its single mark when that raw is at or above the
    // assessment's subjective threshold. The RAW value is stored, not the
    // derived mark, so moving the threshold re-decides pass and fail without
    // re-grading.
    //
    // The keyed dimensions are added on top because image_ab is the one type
    // made of both: its verdict axes are components in their own right and the
    // justification is another, so a candidate who called every axis right and
    // could not defend it keeps the axes. Every other subjective type has no
    // keyed dimensions, so this term is 0 for them and the answer stays out of
    // 1 exactly as before.
    final double raw =
        r.llmRaw100 ?? seededDouble('${asm.id}|${q.id}|grade', 18, 96);
    final bool earned = raw >= asm.barFor(q.type);
    return r.copyWith(
      score: _dimensionsPassed(q, r) + (earned ? 1 : 0),
      maxScore: q.componentCount,
      state: 'submitted',
      llmState: LlmState.scored,
      llmRaw100: raw,
      judge: r.judge ?? SeedData.judgeFor(asm, q, raw),
    );
  }

  /// Re-score answers on one attempt. This is the MANUAL path, so it does
  /// include the terminal `error` state - a person is exactly what that state
  /// was waiting for.
  ///
  /// [questionIds] names exactly the answers to grade, scored ones included -
  /// never the rest of the candidate's paper. Without it, the server takes
  /// every unresolved answer.
  Future<void> rescoreAttempt(
    String attemptId, {
    List<String>? questionIds,
    bool confirmed = false,
  }) => rescoreAnswers(<String, List<String>?>{
    attemptId: questionIds,
  }, confirmed: confirmed);

  /// [rescoreAttempt] for several attempts at once - "Re-score N selected".
  ///
  /// Still one request per attempt, because the route takes one, and awaited
  /// in turn so a paper of candidates is not one burst. But ONE toast and ONE
  /// background refresh for the press, not one of each per candidate.
  ///
  /// [confirmed] says the operator passed the released-result confirmation
  /// (`confirmRescore`), and is forwarded to the route as its `confirm` flag.
  /// The sheet is the screens' job, not the store's - a store cannot show one.
  Future<void> rescoreAnswers(
    Map<String, List<String>?> byAttempt, {
    bool confirmed = false,
  }) async {
    if (!_live) {
      int n = 0;
      for (final MapEntry<String, List<String>?> e in byAttempt.entries) {
        n += _gradeLocally(e.key, e.value);
      }
      if (n == 0) {
        toaster.info('Nothing pending');
      } else {
        toaster.ok('Re-scored $n answer(s) - result recomputed');
      }
      return;
    }

    int queued = 0;
    int reached = 0;
    final List<String> refused = <String>[];
    for (final MapEntry<String, List<String>?> e in byAttempt.entries) {
      // The server QUEUES the answers for its own grader; nothing is graded
      // on this request, which is why the toast says "queued". [ev] is only
      // needed for the "Re-score queued" mark: a Responses row whose attempt
      // is not cached still reaches the server.
      final Attempt? ev = attemptById(e.key);
      final List<String>? ids = e.value;
      if (ev != null && ids != null) {
        _replaceAttempt(
          ev.copyWith(
            resp: <String, Response>{
              for (final MapEntry<String, Response> r in ev.resp.entries)
                r.key: ids.contains(r.key)
                    ? r.value.copyWith(rescoreRequested: true)
                    : r.value,
            },
          ),
        );
      }
      try {
        final Map<String, dynamic> d = await _api.rescore(
          e.key,
          questionIds: ids,
          confirm: confirmed,
        );
        queued += jval(d, 'queued', 0);
        reached++;
      } catch (err) {
        // A refusal (a spend limit) queues nothing, so the mark goes back.
        if (ev != null) _replaceAttempt(ev);
        refused.add(err is ApiError ? err.message : 'Re-score failed. $err');
      }
    }

    final String done = queued == 0 && refused.isEmpty
        ? 'Nothing to re-score'
        : 'Queued $queued answer(s) for re-scoring'
              '${byAttempt.length > 1 ? ' across $reached candidate(s)' : ''}';
    if (refused.isEmpty) {
      toaster.ok(done);
    } else if (byAttempt.length == 1) {
      // The module's own words: it explains a refusal better than we can.
      toaster.bad(refused.single);
    } else {
      toaster.bad(
        '$done; ${refused.length} candidate(s) not queued: '
        '${refused.toSet().join('; ')}',
      );
    }
    await refresh(background: true);
  }

  /// The seed stand-in for the grader: grade [questionIds] on one attempt
  /// (its unresolved answers when null) and say how many were graded.
  int _gradeLocally(String attemptId, List<String>? questionIds) {
    final Attempt? ev = attemptById(attemptId);
    final Assessment? asm = ev == null ? null : asmById(ev.assessmentId);
    if (ev == null || asm == null) return 0;

    int n = 0;
    final Map<String, Response> next = Map<String, Response>.from(ev.resp);
    for (final Question q in asm.questions) {
      final Response? r = next[q.id];
      if (r == null) continue;
      if (questionIds == null
          ? !LlmState.manualRescore.contains(r.llmState)
          : !questionIds.contains(q.id)) {
        continue;
      }
      final Response? graded = gradeOne(asm, q, r.copyWith(clearError: true));
      if (graded != null) {
        next[q.id] = graded;
        n++;
      }
    }
    if (n > 0) _replaceAttempt(ev.copyWith(resp: next));
    return n;
  }

  /// "Re-score This Assessment": the bulk sweep of one paper.
  ///
  /// There is no org-wide form: the route refuses a queue call with no
  /// assessment (`missing_target`).
  Future<void> rescore(Assessment asm) async {
    if (_live) {
      // The server queues; its cron calls Vertex. Nothing is graded on this
      // request, which is why the message says "queued" and not "re-scored".
      //
      // RESET FIRST, like Score Failed. `/scoring/queue` only flags candidates
      // for the cron, which never picks up a failed or errored answer - and
      // this button sits on the notice about exactly those answers.
      await _act(
        'Re-score',
        () async {
          final Map<String, dynamic> reset = await _api.requeueFailed(
            assessmentId: asm.id,
          );
          return <String, dynamic>{
            ...await _api.queueScoring(assessmentId: asm.id),
            'answers_reset': _answersReset(reset),
          };
        },
        okMessage: (Map<String, dynamic> d) {
          final int n = (d['queued'] ?? d['count'] ?? 0) as int;
          final int reset = jval(d, 'answersReset', 0);
          if (n == 0) return 'Nothing to re-score';
          return reset > 0
              ? 'Reset $reset failed answer(s) and queued $n attempt(s) for '
                    're-scoring'
              : 'Queued $n attempt(s) for re-scoring';
        },
      );
      return;
    }

    final List<Attempt> targets = attempts
        .where((Attempt a) => a.assessmentId == asm.id)
        .toList();
    int n = 0;
    for (final Attempt ev in targets) {
      final Assessment? a = asmById(ev.assessmentId);
      if (a == null) continue;
      final Map<String, Response> next = Map<String, Response>.from(ev.resp);
      bool touched = false;
      for (final Question q in a.questions) {
        final Response? r = next[q.id];
        if (r == null) continue;
        if (!LlmState.manualRescore.contains(r.llmState)) continue;
        final Response? graded = gradeOne(a, q, r.copyWith(clearError: true));
        if (graded != null) {
          next[q.id] = graded;
          touched = true;
          n++;
        }
      }
      if (touched) {
        attempts = attempts
            .map((Attempt x) => x.id == ev.id ? ev.copyWith(resp: next) : x)
            .toList();
      }
    }
    if (n == 0) {
      toaster.info('Nothing to re-score');
      return;
    }
    toaster.ok('Re-scored $n answer(s)');
    notifyListeners();
  }

  /// Reset terminally-errored answers and queue them again.
  ///
  /// The MANUAL counterpart to [autoRetrySweep], and the reason that sweep
  /// skips `error`: a terminal fault is never retried on its own, because a
  /// Vertex outage would otherwise turn into a silent zero. A person looks at
  /// it and decides.
  Future<void> requeueErrored({List<String> attemptIds = const <String>[]}) =>
      _act(
        'Re-score',
        () => _api.requeueErrored(
          attemptIds.isEmpty
              ? attempts
                    .where((Attempt a) {
                      // An attempt is errored only relative to its assessment's
                      // question set - that is what `hasScoringError` needs.
                      // A cancelled paper is left out: the server will not
                      // re-score it, and an older one refused the whole call.
                      final Assessment? asm = asmById(a.assessmentId);
                      return asm != null &&
                          asm.state != AsmState.cancelled &&
                          a.hasScoringError(asm);
                    })
                    .map((Attempt a) => a.id)
                    .toList()
              : attemptIds,
        ),
        okMessage: (Map<String, dynamic> d) {
          final int? n = _answersReset(d);
          // An older server: `requeued` here is the candidates NAMED, which is
          // the one count it can vouch for.
          final int named = n ?? jval(d, 'requeued', 0);
          // Candidates the server passed over. Cancelled papers are already
          // left out above, so these are mostly ones whose Kill is still
          // stopping (L1) - the sentence names both.
          final int skipped = jval(d, 'skipped', 0);
          final String tail = skipped > 0
              ? ', skipped $skipped candidate(s) on cancelled or stopping '
                    'papers'
              : '';
          if (named == 0) return 'Nothing is in an errored state$tail';
          return n != null
              ? 'Reset and queued $n errored answer(s)$tail'
              : 'Reset and queued errored answers on $named candidate(s)$tail';
        },
        ifSeed: () => toaster.info('Re-scoring needs a live backend'),
      );

  /// Reset every FAILED or errored answer on ONE assessment and queue it
  /// again - the "Score Failed Responses (n)" button on the assessment detail.
  ///
  /// The same route and shape as [requeueErrored], scoped by `assessment_id`
  /// and told which states to sweep rather than handed a hand-picked list. It
  /// covers `failed` as well as `error`, so a transient failure the automatic
  /// retry already gave up on is recovered by the same press.
  Future<void> requeueFailedFor({String? assessmentId}) => _act(
    'Score failed',
    () => _api.requeueFailed(assessmentId: assessmentId),
    okMessage: (Map<String, dynamic> d) {
      final int? n = _answersReset(d);
      // An older server's only count is every attempt on the paper, which
      // says nothing about how many answers were failed.
      if (n == null) return 'Reset and queued any failed answers';
      return n > 0
          ? 'Reset and queued $n failed answer(s)'
          : 'Nothing is in a failed state';
    },
    ifSeed: () => toaster.info('Re-scoring needs a live backend'),
  );

  /// How many ANSWERS `/scoring/requeue_errored` reset, or null from a server
  /// too old to say.
  ///
  /// Never `requeued`: that is the ATTEMPTS the sweep covered - with
  /// `assessment_id`, every attempt on the paper - so reading it as answers
  /// told a 750-candidate paper with three errored answers "Reset 750".
  int? _answersReset(Map<String, dynamic> d) {
    final Object? n = jget(d, 'answersReset');
    return n is num ? n.toInt() : null;
  }

  /// Invariant 5: the AUTOMATIC sweep. It uses `LlmState.autoRetry`, which
  /// deliberately excludes `error`, so a terminal fault waits for a person
  /// rather than being retried into the same failure forever.
  ///
  /// Against a live backend this is the SERVER's cron, not a client loop: the
  /// module drains its own scoring queue on a timer. Nothing to do here, and
  /// firing `requeue_errored` would be the opposite of this invariant - that
  /// route is the manual "Reset & Re-score Errored" path a person chooses.
  Future<void> autoRetrySweep() async {
    if (_live) return;
    for (final Attempt ev in attempts) {
      final Assessment? asm = asmById(ev.assessmentId);
      if (asm == null) continue;
      final Map<String, Response> next = Map<String, Response>.from(ev.resp);
      bool touched = false;
      for (final Question q in asm.questions) {
        final Response? r = next[q.id];
        if (r == null) continue;
        if (!LlmState.autoRetry.contains(r.llmState)) continue;
        final Response? graded = gradeOne(asm, q, r);
        if (graded != null) {
          next[q.id] = graded;
          touched = true;
        }
      }
      if (touched) {
        attempts = attempts
            .map((Attempt x) => x.id == ev.id ? ev.copyWith(resp: next) : x)
            .toList();
      }
    }
    notifyListeners();
  }

  /// Erase the candidate's free text but keep every score and flag, so the
  /// record stays reviewable after the person has been forgotten.
  Future<void> erasePii(String attemptId) async {
    final Attempt? ev = attemptById(attemptId);
    if (ev == null) return;

    await _act(
      'Erase',
      () => _api.erasePii(attemptId),
      okMessage: (_) => 'Candidate data erased - scores and flags kept',
      ifSeed: () {
        final Map<String, Response> next = ev.resp.map(
          (String k, Response r) => MapEntry<String, Response>(
            k,
            r.copyWith(
              justification: '',
              labels: r.labels == null ? null : <int, String>{},
            ),
          ),
        );
        _replaceAttempt(ev.copyWith(piiAnonymized: true, resp: next));
        toaster.warn('Candidate data erased - scores and flags kept');
      },
    );
  }

  /// ── Server-side exports ────────────────────────────────────────────────
  ///
  /// These download what the MODULE produces, not what the client can
  /// reconstruct. A response export carries per-answer scoring, judge feedback
  /// and rubric columns that never reach the client.
  /// Rebuilding it here would quietly produce a different file from the one
  /// the Odoo button emits, and the export is an audit artefact.

  /// Fetch a base64 CSV envelope and hand it to the browser as a download.
  Future<void> _download(
    String label,
    Future<Map<String, dynamic>> Function() call,
  ) async {
    if (!_live) {
      toaster.info('$label needs the live backend');
      return;
    }
    try {
      final Map<String, dynamic> res = await call();
      final Object? content = res['content'];
      if (content is! String || content.isEmpty) {
        toaster.bad('$label returned nothing');
        return;
      }
      final String filename = (res['filename'] ?? 'export.csv').toString();
      // An export too large to send as CSV arrives zipped (the export routes
      // are asked with `zip: true`). Those bytes are saved as they are -
      // decoding them as UTF-8 text would throw or corrupt the archive.
      if (res['mimetype'] == 'application/zip') {
        downloadBytes(filename, base64Decode(content), 'application/zip');
        toaster.ok('$filename downloaded - a zip, as the CSV was too large');
        return;
      }
      // The server sends bytes; the browser wants text. Decoding here keeps
      // `downloadCsv` a single path for every CSV the app produces.
      final String csv = utf8.decode(base64Decode(content));
      downloadCsv(filename, csv);
      toaster.ok('$filename downloaded');
    } on ApiError catch (e) {
      toaster.bad(e.message);
    } catch (e) {
      toaster.bad('$label failed: $e');
    }
  }

  /// Candidates per request of a paged responses export.
  static const int exportBatch = 50;

  /// How far a responses export has got, in candidates; null when none runs.
  ///
  /// `total` is 0 until the first page says how many there are.
  ({int done, int total})? exportProgress;

  /// The pages the last paged export saved, so a test can check the join.
  @visibleForTesting
  List<Uint8List>? lastExportParts;

  /// Every answer on one assessment, with its scoring, as CSV.
  ///
  /// FETCHED IN PAGES OF [exportBatch] CANDIDATES and joined here. One request
  /// for a 691-candidate paper was 15.3 MB and refused; a page is a fraction
  /// of that, and progress can be shown between pages. Each page is a valid
  /// CSV with its own header, so every header after the first is dropped. A
  /// server that predates paging answers the first call with the whole file
  /// and no `total`, which is then downloaded as it is.
  Future<void> exportResponses(Assessment asm) async {
    if (!_live) {
      toaster.info('Export responses needs the live backend');
      return;
    }
    if (exportProgress != null) return;
    exportProgress = (done: 0, total: 0);
    notifyListeners();
    try {
      // Raw UTF-8 pages, never one String: see [downloadCsvParts].
      final List<Uint8List> parts = <Uint8List>[];
      String filename = 'responses.csv';
      int offset = 0;
      while (true) {
        final Map<String, dynamic> res = await _api.exportResponses(
          asm.id,
          offset: offset,
          limit: exportBatch,
        );
        final Object? content = res['content'];
        final Object? total = res['total'];
        if (total is! int || res['mimetype'] == 'application/zip') {
          // Not paged (an older server): the whole export in one reply.
          exportProgress = null;
          await _download('Export responses', () async => res);
          return;
        }
        if (content is! String) {
          toaster.bad('Export responses returned nothing');
          return;
        }
        Uint8List page = base64Decode(content);
        // A UTF-8 BOM is added once, for the whole file, when it is saved.
        if (page.length >= 3 &&
            page[0] == 0xEF &&
            page[1] == 0xBB &&
            page[2] == 0xBF) {
          page = Uint8List.sublistView(page, 3);
        }
        if (offset == 0) {
          filename = (res['filename'] ?? filename).toString();
          parts.add(page);
        } else {
          // Every page repeats the header line; keep only the first one.
          final int nl = page.indexOf(0x0A);
          if (nl >= 0) parts.add(Uint8List.sublistView(page, nl + 1));
        }
        offset += exportBatch;
        exportProgress = (done: min(offset, total), total: total);
        notifyListeners();
        if (offset >= total) break;
      }
      lastExportParts = parts;
      downloadCsvParts(filename, parts);
      toaster.ok('$filename downloaded');
    } on ApiError catch (e) {
      final ({int done, int total})? p = exportProgress;
      toaster.bad(
        p != null && p.done > 0
            ? 'Export stopped after ${p.done} of ${p.total} candidates: '
                  '${e.message} Nothing was saved - try again.'
            : e.message,
      );
    } catch (e) {
      toaster.bad('Export responses failed: $e');
    } finally {
      exportProgress = null;
      notifyListeners();
    }
  }

  /// The results sheet: one row per candidate.
  ///
  /// One request (a row per candidate is small), marked busy under
  /// `exportResults:<id>` so the button shows it is working.
  Future<void> exportResults(Assessment asm) {
    final String key = 'exportResults:${asm.id}';
    if (isBusy(key)) return Future<void>.value();
    return withBusy(
      key,
      () => _download('Export results', () => _api.exportResults(asm.id)),
    );
  }

  /// One candidate's answers, as CSV.
  Future<void> exportAttemptResponses(String attemptId) => _download(
    'Export responses',
    () => _api.exportAttemptResponses(attemptId),
  );

  /// The CSV template the candidate importer expects.
  Future<void> downloadCandidateTemplate() =>
      _download('Template', () => _api.candidateTemplate());

  /// ── Bank media authoring ───────────────────────────────────────────────

  /// Re-run UI element detection on a labelling question's image.
  Future<void> detectNow(String questionId) => _act(
    'Detect',
    () => _api.detectNow(questionId),
    okMessage: (_) => 'Detection finished',
  ).then((_) => loadQuestion(questionId));

  /// Capture the live DOM at [sourceUrl] into the question's image.
  Future<void> captureUrl(String questionId, {String? sourceUrl}) => _act(
    'Capture',
    () => _api.captureUrl(questionId, sourceUrl: sourceUrl),
    okMessage: (_) => 'Page captured',
  ).then((_) => loadQuestion(questionId));

  /// Attach an uploaded clip to a slot on a bank question.
  ///
  /// Takes raw bytes and encodes here, matching `uploadResource`: a caller
  /// that has just read a file off disk should not have to know the wire
  /// format.
  Future<void> applyVideo(
    String questionId, {
    required List<int> bytes,
    String filename = 'clip.mp4',
    String slot = 'reference',
  }) => _act(
    'Upload clip',
    () => _api.applyVideo(
      questionId,
      content: base64Encode(bytes),
      filename: filename,
      slot: slot,
    ),
    okMessage: (_) => 'Clip attached',
  ).then((_) => loadQuestion(questionId));

  /// A labelling question as an annotation item the designer's editor can open.
  ///
  /// Returns null when the server says the question has no markers to edit
  /// (404 `not_annotatable`), which is the answer the caller uses to decide
  /// whether to offer the action - so it is NOT toasted. Any other failure is,
  /// because that one the examiner needs to know about.
  Future<Map<String, dynamic>?> bankStudioItem(String questionId) async {
    if (!_live) return null;
    try {
      final Map<String, dynamic> res = await _api.bankStudioItem(questionId);
      final Object? item = res['item'];
      return item is Map<String, dynamic> ? item : null;
    } on ApiError catch (e) {
      if (e.code != 'not_annotatable') toaster.bad(e.message);
      return null;
    }
  }

  /// Save an edited annotation item back onto the SAME question.
  ///
  /// Retroactive, like every bank edit: a labelling answer is free text scored
  /// against the golden labels, so a corrected key corrects the marks on the
  /// next grade. That is the point of being able to move a wrong box.
  ///
  /// Returns whether it landed, so the editor can stay open on a refusal
  /// rather than closing over an unsaved key.
  Future<bool> saveBankStudioItem(
    String questionId,
    Map<String, dynamic> item,
  ) async {
    if (!_live) {
      toaster.info('Editing runs against a live server');
      return false;
    }
    bool saved = false;
    await withBusy('studio-item:$questionId', () async {
      await _act('Save annotations', () async {
        final Map<String, dynamic> res = await _api.saveBankStudioItem(
          questionId,
          item,
        );
        // FLAGGED FROM THE CALL, not from `okMessage`. That callback is
        // SKIPPED whenever the server returns its own `notice` - so reading
        // success from it would report a landed save as a failure the moment
        // the route grew a notification, and the editor would stay open over
        // an answer key that is already stored.
        saved = true;
        return res;
      }, okMessage: (_) => 'Annotations saved');
    });
    if (saved) await loadQuestion(questionId);
    return saved;
  }

  // ══════════════════════════════════════════════════════════════════════
  //  Exam runtime
  // ══════════════════════════════════════════════════════════════════════

  /// Start the clock, and ADOPT the first question the server answers with.
  ///
  /// Awaited by its one caller so the runner has a question before it
  /// navigates. The local stamp below still lands first, so a slow call never
  /// leaves the candidate looking at the instructions twice.
  Future<void> beginExam(String attemptId) async {
    final Attempt? ev = attemptById(attemptId);
    if (ev == null) return;
    // On the server's clock, so a deadline derived from it matches the Clock.
    _replaceAttempt(
      ev.copyWith(
        startedAt: DateTime.now().add(ev.clockOffset),
        state: AttemptState.inProgress,
      ),
    );

    // The SERVER stamps the real start time, because the countdown must not be
    // something the candidate's clock can move.
    if (!_live) return;
    try {
      final Map<String, dynamic> res = await _api.examBegin(ev.token);
      // `/exam/<token>/begin` answers with the FIRST question envelope, and it
      // was being thrown away. A candidate's assessment record carries no
      // questions - only the runner's envelope does - so the page that opened
      // on Begin had nothing to render and read "This assessment has no
      // questions" until some later call happened to refill the envelope.
      examByToken[ev.token] = ExamView.fromJson(res);
      _adoptServerAnswer(ev.token, jget(res, 'question'));
      notifyListeners();
    } on ApiError catch (e) {
      if (!_standDown(e, ev.token)) toaster.bad(e.candidateMessage);
    } catch (e, st) {
      _hydrationFailed('beginExam', e, st);
    }
  }

  /// Write one answer. Called on every keystroke of a free-text field, so it
  /// must not be expensive and must not force a rebuild of the exam surface -
  /// see `saveAnswerQuiet`.
  void saveAnswer(String attemptId, String questionId, Response r) {
    final Attempt? ev = attemptById(attemptId);
    if (ev == null) return;
    final Map<String, Response> next = Map<String, Response>.from(ev.resp)
      ..[questionId] = r;
    _replaceAttempt(ev.copyWith(resp: next));
    _syncAnswer(ev, questionId, r);
  }

  /// The same write with NO notification.
  ///
  /// The free-text answer fields must never trigger a rebuild: the source
  /// states the reason directly - focus and caret would be lost. The value is
  /// written straight into the response and the widget keeps its own
  /// controller as the display state.
  void saveAnswerQuiet(String attemptId, String questionId, Response r) {
    final Attempt? ev = attemptById(attemptId);
    if (ev == null) return;
    final Map<String, Response> next = Map<String, Response>.from(ev.resp)
      ..[questionId] = r;
    attempts = attempts
        .map((Attempt a) => a.id == attemptId ? a.copyWith(resp: next) : a)
        .toList();
    // Deliberately no notifyListeners().
    _syncAnswer(ev, questionId, r);
  }

  /// Pending per-question debounce timers for answer writes.
  final Map<String, Timer> _answerSync = <String, Timer>{};

  /// Answer saves posted and not yet answered.
  int _answersInFlight = 0;

  final void Function(void Function()? onLeave) _leaveGuard;
  bool _leaveGuarded = false;

  /// Hold the page (`beforeunload`: flush, and ask "Leave site?") exactly
  /// while an answer save is debounced or in flight. An unload cancels the
  /// fetch a flush starts, so leaving within a second of typing lost it.
  ///
  /// And while a violation report is unanswered (BR-D15): nothing on the
  /// device keeps it past a reload, so leaving would lose it.
  void _syncLeaveGuard() {
    final bool pending =
        _answersInFlight > 0 ||
        _answerSync.values.any((Timer t) => t.isActive) ||
        _reports.values.any((List<ViolationRow> q) => q.isNotEmpty);
    if (pending == _leaveGuarded) return;
    _leaveGuarded = pending;
    _leaveGuard(pending ? _onLeave : null);
  }

  /// What the page does as it is left with something unsent: everything
  /// pending goes now.
  void _onLeave() {
    unawaited(flushAnswers());
    for (final String token in _reports.keys.toList()) {
      if (_reports[token]?.isNotEmpty ?? false) {
        unawaited(_sendReportsSoon(token));
      }
    }
  }

  /// Each question this session has answered, by id. See [_syncAnswer].
  final Map<String, Question> answeredQuestions = <String, Question>{};

  /// How long typing must pause before the answer goes.
  ///
  /// WAS ONE SECOND, which is a pause almost everybody takes mid-sentence: it
  /// fired on commas, on stopping to read the question again, on hesitating
  /// over a word. On a paper with written answers that is several writes per
  /// sentence, every one of them superseded moments later.
  ///
  /// Five seconds is longer than a thinking pause and shorter than a candidate
  /// walking away. It costs nothing in durability because it is bounded from
  /// both ends: [answerMaxWaitDefault] below caps how long an unsaved answer may
  /// exist, and `finishExam` re-sends anything the server never acknowledged.
  static const Duration answerDebounceDefault = Duration(seconds: 5);

  /// The ceiling on how long an answer may stay unsaved while typing CONTINUES.
  ///
  /// WITHOUT THIS A LONGER DEBOUNCE IS A DATA-LOSS BUG, not a saving. A plain
  /// debounce restarts on every keystroke, so somebody typing steadily for four
  /// minutes on a long-form answer never pauses for five seconds and therefore
  /// never saves - and a closed lid, a flat battery or a dropped connection
  /// takes the whole thing. The 1s debounce hid that by being shorter than any
  /// human pause.
  ///
  /// So the timer measures from when the answer FIRST diverged from what the
  /// server holds, not from the last keystroke: once that reaches 15 seconds
  /// the next change saves immediately. Steady typing therefore costs one write
  /// per 15 seconds - bounded, and far below the one-per-second the old
  /// debounce allowed.
  static const Duration answerMaxWaitDefault = Duration(seconds: 15);

  /// When each question's answer first diverged from the stored copy.
  ///
  /// Absent means "matches the server". Removed on acceptance and on every path
  /// that stores the answer, so the ceiling measures unsaved time and nothing
  /// else.
  final Map<String, DateTime> _answerDirtySince = <String, DateTime>{};

  /// The payload last ACCEPTED by the server, per question, so an autosave that
  /// would re-send an identical answer sends nothing at all.
  ///
  /// WHY THIS EXISTS. Measured over the real assessment of 2026-09-03: 300,092
  /// `/answer` POSTs from 1,230 candidates - a median of **240 posts per
  /// candidate** on papers of 19 and 35 questions, so ~7-13x more writes than
  /// answers. Each one costs the server a median of 39 SQL queries because
  /// writing a response recomputes 12 stored fields on the row and 7 more on the
  /// evaluator. That single route was **86.6% of all database traffic** on stage
  /// (12.4M of 14.3M queries in three hours), and ~89% of it re-stored an answer
  /// the server already had.
  ///
  /// The amplification is not a bug in the debounce - it is that nothing checked
  /// whether the value had CHANGED. Every navigation, every re-render that
  /// re-emits the same value, and every keystroke pause after a no-op edit fired
  /// a full write.
  ///
  /// Keyed on question id, holding a fingerprint of exactly what goes on the
  /// wire. Cleared on sign-out with the timers.
  final Map<String, String> _answerSent = <String, String>{};

  /// Fingerprint of the wire payload for [r]: option ids, prose, labels and a
  /// transcription's clip answers.
  ///
  /// Order-independent on `lines`, because the option list is a SET on both
  /// sides - the server reconciles it against the dimensions - so a reordered
  /// selection is not a change and must not cost a write.
  static String _answerFingerprint(Response r) {
    final List<String> lines = List<String>.of(r.lines)..sort();
    final Map<int, String> labels = r.labels ?? const <int, String>{};
    final List<int> keys = labels.keys.toList()..sort();
    return '${lines.join(",")}|${r.justification}|'
        '${keys.map((int k) => "$k=${labels[k]}").join(",")}|'
        '${r.clip?.fingerprint ?? ""}';
  }

  /// The last violation this client recorded, per attempt id.
  ///
  /// THE DEDUP'S MEMORY LIVES HERE AND NOWHERE ELSE.
  ///
  /// It used to live on the Attempt, in `violationAt` - and the Attempt is
  /// rebuilt from the wire by `_loadCandidate` (a wholesale `attempts = flat`),
  /// by `loadExamByToken` and by `_mergeAttempts`, none of which can carry a
  /// timestamp the API does not send. `serializers.attempt` sends the count and
  /// the reason; `violation_datetime` exists on the evaluator and is written by
  /// `_record_violation`, but NO serializer emits it. So `violationAt` was
  /// non-null only for as long as one optimistic `copyWith` survived, and the
  /// first refresh disarmed the guard for the rest of the sitting - silently,
  /// because a dedup that has stopped folding looks exactly like a candidate
  /// who has stopped repeating themselves.
  ///
  /// It must NOT be re-derived from a server timestamp either: that compares
  /// the BROWSER's clock against the SERVER's, and a browser running slow
  /// yields a negative difference, which is inside the window, which folds
  /// every same-reason violation for the rest of the exam. Today's bug
  /// over-counts; that one would silently stop counting.
  ///
  /// ONE pair per attempt, not a map of reason -> time. `_record_violation`
  /// compares against the single `violation_reason`/`violation_datetime` pair
  /// it stores, so A-B-A inside 1.2s counts three times there. A per-reason map
  /// would fold the third and leave this client BELOW the server's tally.
  final Map<String, ({String reason, DateTime at})> _lastViolation =
      <String, ({String reason, DateTime at})>{};

  /// VIOLATION REPORTS THE SERVER HAS NOT ANSWERED, per token, oldest first
  /// (BR-D15). Each waits until it is answered, goes out in order, and holds
  /// back any answer typed after it ([_heldByReports]).
  ///
  /// IN MEMORY ONLY. There is no device store behind the answers here, so a
  /// reload loses what is still queued; while anything is, the page asks
  /// before it is left ([_syncLeaveGuard]).
  ///
  /// ONE SEND AT A TIME per sitting, so replies arrive in order and the last
  /// one is the newest: the out-of-order guard concurrent POSTs needed is gone
  /// with them.
  final Map<String, List<ViolationRow>> _reports =
      <String, List<ViolationRow>>{};

  /// Attempts [_endForViolation] ended in this session, for a Submit that was
  /// in flight when the ending reply landed ([finishExam]).
  final Set<String> _endedByViolation = <String>{};

  /// The send of a sitting's reports in progress ([_sendReports]).
  final Map<String, Future<bool>> _reporting = <String, Future<bool>>{};

  /// The next try of a sitting's reports after one did not reach the server.
  final Map<String, Timer> _reportRetry = <String, Timer>{};

  /// The wait before an unsent report is tried again.
  static const Duration violationRetryDefault = Duration(seconds: 5);

  /// What a candidate is told when a save waits behind a report that cannot
  /// be sent.
  static const String reportsHeldMessage = kNoConnection;

  /// The server folds a second report of the same reason inside 1.2s into
  /// the first, as one physical action. Reports sent back to back after a
  /// reconnect are not one action, so the same reason waits this long.
  static const Duration _reportGap = Duration(milliseconds: 1500);

  /// Questions whose authoritative save (`examAdvance`) is in flight.
  ///
  /// The debounced autosave skips these: it would post the same answer a
  /// second time, and two concurrent INSERTs of one answer is what produced a
  /// spurious "incomplete" refusal on a question the candidate had answered.
  final Set<String> _advancing = <String>{};

  /// Drives [advanceJobs] in fixture mode. Null whenever nothing is running.
  Timer? _jobTicker;

  /// True while [pollGeneration] is looping, so a second call from another
  /// screen does not start a parallel poll against the same generators.
  bool _polling = false;

  /// Generators whose detail screen is following the run itself, on the light
  /// `/progress` route with a backed-off timer. [pollGeneration] leaves them to
  /// it: its 2 s re-read of every page of `/generators` and `/drafts` is the
  /// cost that screen's watch replaces (ETP_PLANS_AND_STRATEGY.md §4.9). Every
  /// other generator, and every skills extraction, it still watches.
  final Set<String> screenWatchedGenerators = <String>{};

  /// Ticks [pollGeneration] will spend waiting on asset renders alone, with no
  /// generation running. Bounded because a failed render stays `pending`
  /// forever; see the check that reads it.
  static const int _assetOnlyTicks = 15;

  /// Set in [dispose]. An in-flight poll checks it after every await, because
  /// a `refresh()` that lands after disposal would notify a dead listener.
  bool _disposed = false;

  /// Approve every pending draft on one generator.
  ///
  /// The API and the client method for this have both existed since the port;
  /// nothing ever called them, so a generator with 40 clean drafts had to be
  /// approved one card at a time. The module's own `action_approve_all_drafts`
  /// does the work - per-draft savepoints, skip-and-continue, one rollup note -
  /// so a single bad draft cannot take the batch down.
  Future<void> approveAllDrafts(String genId) async {
    if (!_live) {
      toaster.info('Bulk approve needs a live backend');
      return;
    }
    await withBusy(
      'approveall:$genId',
      () => _act(
        'Approve all',
        () => _api.approveAllDrafts(genId),
        okMessage: (_) => 'Every clean draft approved into the bank',
      ),
    );
  }

  /// Adopt the answer the SERVER already holds for a question.
  ///
  /// `question_for_candidate` returns an `answer` block - the selected options,
  /// the justification, and `label_answers` for the labelling types. None of it
  /// was ever read, so a candidate who navigated back to a question they had
  /// already answered found it blank and had to type it again. Local edits win:
  /// this only seeds a question the store has nothing for.
  void _adoptServerAnswer(String token, Object? questionJson) {
    if (questionJson is! Map<String, dynamic>) return;
    final String qid = jid(jget(questionJson, 'id'));
    if (qid.isEmpty) return;
    final Attempt? ev = attemptByToken(token);
    if (ev == null || ev.resp.containsKey(qid)) return;

    final Map<String, dynamic> a = jobj(questionJson, 'answer');
    if (a.isEmpty) return;
    final List<String> lines =
        ((jget(a, 'selected_option_ids') ?? const <dynamic>[]) as List<dynamic>)
            .map(jid)
            .toList();
    final Map<String, dynamic> raw = jobj(a, 'label_answers');
    final Map<int, String> labels = <int, String>{
      for (final MapEntry<String, dynamic> e in raw.entries)
        if (int.tryParse(e.key) != null) int.parse(e.key): '${e.value}',
    };
    final String justification = jval(a, 'justification', '');
    final Object? clipRaw = jget(a, 'clip_answers');
    final ClipAnswers? clip = clipRaw is Map && clipRaw.isNotEmpty
        ? ClipAnswers.fromJson(clipRaw)
        : null;
    if (lines.isEmpty &&
        labels.isEmpty &&
        justification.isEmpty &&
        clip == null) {
      return;
    }

    final Attempt seeded = ev.copyWith(
      resp: <String, Response>{
        ...ev.resp,
        qid: Response(
          lines: lines,
          justification: justification,
          labels: labels.isEmpty ? null : labels,
          clip: clip,
        ),
      },
    );
    attempts = <Attempt>[
      ...attempts.where((Attempt x) => x.id != seeded.id),
      seeded,
    ];
  }

  /// Save the current answer AND move, letting the server decide where to.
  ///
  /// [nav] is `next` | `prev` | `review`. The response carries the next
  /// question, or `next: null` plus a `review` block when the paper is done.
  /// Returns true when the caller should show the review screen.
  ///
  /// This is separate from the debounced [_syncAnswer] on purpose: that one
  /// exists to protect the caret while somebody is typing and deliberately
  /// throws the response away. A navigation press has to consume it.
  Future<bool> examAdvance(
    String token,
    String questionId,
    Response r, {
    String nav = 'next',
  }) async {
    if (!_live) return nav == 'review';
    // Any pending debounce is now redundant and would race this call.
    //
    // CANCELLING IS NOT ENOUGH ON ITS OWN. A timer that has ALREADY fired has
    // an HTTP request in flight, and cancel() cannot recall it - so the
    // autosave and this save both POST the same answer microseconds apart,
    // both find no existing row, and both INSERT. One wins; the other hits the
    // (evaluator, question) unique index. The server no longer answers that
    // collision with "This answer is incomplete for its question type", but
    // the duplicate post is still pointless work on a candidate's connection,
    // so the autosave is told to stand down for this question while the
    // authoritative save is in flight.
    _answerSync[questionId]?.cancel();
    _syncLeaveGuard();
    _advancing.add(questionId);
    try {
      // AFTER AN UNSENT VIOLATION REPORT, THE REPORTS GO FIRST (BR-D15). If
      // they cannot, neither does this save: the answer stays on this page.
      if (_heldByReports(token, _stampFor(token, questionId, r))) {
        if (!await _sendReportsSoon(token)) {
          toaster.bad(reportsHeldMessage);
          return false;
        }
        // Answered, they may have ended the sitting.
        if (attemptByToken(token)?.isDone ?? true) return false;
      }
      final Map<String, dynamic> res = await _api.examAnswer(
        token,
        questionId: questionId,
        optionIds: r.lines,
        justification: r.justification,
        labels: r.labels ?? const <int, String>{},
        clipAnswers: r.clip?.toJson(),
        nav: nav,
      );
      // THIS PATH POSTS THE SAME PAYLOAD, so it records the same fingerprint.
      //
      // Without this the navigation save and the debounced autosave never learn
      // from each other: pressing Next stored the answer, and the pending
      // autosave (or the next re-render of an unchanged field) then wrote the
      // identical value again. That double-write is a large part of the ~7-13x
      // amplification measured on 2026-09-03 - see `_answerSent`.
      _answerSent[questionId] = _answerFingerprint(r);
      _answerDirtySince.remove(questionId);
      // THE LAST ANSWER ENDS THE ATTEMPT. The server locks it as soon as every
      // question has a submitted response, so the save that completes the set
      // is also the end of the sitting. Take the runner straight to the
      // completion screen: navigating on to a question that can no longer be
      // written refused every keystroke with "This attempt is already
      // submitted", one toast per press, over an exam that had in fact just
      // been finished successfully.
      if (jget(res, 'attempt_closed') == true) {
        _markExamComplete(token);
        return true;
      }
      final Object? next = jget(res, 'next');
      if (next is Map<String, dynamic>) {
        _adoptServerAnswer(token, jget(next, 'question'));
        final ExamView? cur = examByToken[token];
        final ExamView fresh = ExamView.fromJson(next);
        // `next` is a question envelope, not a full state envelope, so the
        // gate-level fields (preview, instructions) are not repeated in it.
        examByToken[token] = cur == null
            ? fresh
            : cur.copyWith(
                outcome: 'question',
                question: fresh.question,
                index: fresh.index,
                total: fresh.total,
                answeredIds: fresh.answeredIds.isEmpty
                    ? <String>{...cur.answeredIds, questionId}
                    : fresh.answeredIds,
                progressPercent: fresh.progressPercent,
                // A newer snapshot policy wins; an envelope without one keeps
                // the policy the sitting already holds.
                evidenceUpload: fresh.evidenceUpload ?? cur.evidenceUpload,
              );
        notifyListeners();
        return false;
      }
      // No next question: the server handed back the review block instead.
      final Object? review = jget(res, 'review');
      if (review is Map<String, dynamic>) {
        _adoptReviewRows(token, review);
      }
      notifyListeners();
      return true;
    } on ApiError catch (e) {
      if (_standDown(e, token)) return false;
      // An attempt that is already locked is not a failure to report over and
      // over - it is news. Show it once and move the runner to the completion
      // screen; repeating the same sentence per press is what produced a stack
      // of identical toasts over a finished exam.
      if (e.code == 'attempt_locked' || e.status == 409) {
        // THE BUZZER IS NEWS. `/answer` saves the answer in flight BEFORE it
        // enforces the deadline and says with `answer_saved` whether it was
        // kept; [_tellTimeUp] turns that into the one time-up message.
        if (e.code == 'time_expired') {
          _tellTimeUp(token, lastAnswerKept: e.fields['answer_saved'] != false);
        }
        _markExamComplete(token);
        return true;
      }
      // The module's own sentence: it says why far better than a generic one.
      // A transport failure has none, only the host it could not reach.
      toaster.bad(e.candidateMessage);
      return false;
    } finally {
      _advancing.remove(questionId);
    }
  }

  static const String timeUpMessage = "Time's up - your answers are saved.";

  /// A tab that another tab or device took over (`session_replaced`) has
  /// saved nothing since, so it must not claim its answers are saved.
  static const String timeUpElsewhereMessage =
      "Time's up. This exam continued in another tab or device, and the "
      'answers saved there are the ones that count.';

  /// `answer_saved: false` means one of three things on `/answer`: past the
  /// 10s grace (not stored), incomplete and refused, or incomplete and held
  /// as a draft that is still graded. Only this sentence is true of all three.
  static const String timeUpIncompleteMessage =
      'Your last change reached us after the deadline, so it may not count.';

  /// Tokens already told, so the Next save, the autosave and the submit flush
  /// that all meet the deadline say it once.
  final Set<String> _timeUpTold = <String>{};

  /// The one time-up message, for every path that meets the deadline.
  ///
  /// `answer_saved: false` gets a neutral line, never a red "not saved": the
  /// server still settles and grades a held draft (G2-05).
  void _tellTimeUp(String token, {bool lastAnswerKept = true}) {
    if (_timeUpTold.add(token)) {
      toaster.info(
        sessionReplaced.contains(token)
            ? timeUpElsewhereMessage
            : timeUpMessage,
      );
    }
    if (!lastAnswerKept) toaster.warn(timeUpIncompleteMessage);
  }

  /// Move the runner to its completion screen and stop writing.
  ///
  /// Any debounced autosave still pending would land on a locked attempt and
  /// be refused, so they are cancelled rather than left to fire.
  void _markExamComplete(String token) {
    for (final Timer t in _answerSync.values) {
      t.cancel();
    }
    _answerSync.clear();
    // A closed sitting records no violation and stores no answer.
    _dropReports(token);
    final ExamView? cur = examByToken[token];
    if (cur != null) {
      examByToken[token] = cur.copyWith(outcome: 'complete');
    }
    notifyListeners();
    // Re-read the authoritative gate: it carries the submitted timestamp and
    // whether results are released, which the completion screen shows.
    unawaited(loadExamByToken(token));
  }

  /// Tokens whose sitting another tab or device has taken over (409
  /// `session_replaced`). This tab sends no answers and records no violations
  /// for them until [continueExamHere] takes the sitting back.
  final Set<String> sessionReplaced = <String>{};

  /// True, with this tab stood down, when [e] says another tab holds the
  /// sitting. Checked BEFORE any "409 means locked" branch: the attempt is
  /// still open, and this must never end the exam.
  ///
  /// Also true for 403 `seb_required`: the write came from outside Safe Exam
  /// Browser (or with a stale key), so nothing else this page sends will land
  /// either. `/state` then answers `seb_required`, which puts up the gate.
  bool _standDown(Object e, String token) {
    if (e is ApiError && e.code == 'seb_required') {
      unawaited(loadExamByToken(token));
      return true;
    }
    if (e is! ApiError || e.code != 'session_replaced') return false;
    if (sessionReplaced.add(token)) {
      for (final Timer t in _answerSync.values) {
        t.cancel();
      }
      _answerSync.clear();
      _answerSend.clear();
      // The other tab may have written since, so nothing this one sent is
      // known to be what the server holds any more.
      _answerSent.clear();
      _syncLeaveGuard();
      notifyListeners();
    }
    return true;
  }

  /// "Continue Here", the ONLY way a stood-down tab calls `/state` again:
  /// that registers this tab's key, which takes the sitting back, and re-reads
  /// where the paper stands - including what the other tab saved.
  Future<void> continueExamHere(String token) async {
    // Cleared first, or [loadExamByToken] refuses. Nothing repaints until the
    // re-read lands, so the notice stays up while it is in flight; if the call
    // fails the next write meets the 409 again and puts it back.
    sessionReplaced.remove(token);
    await loadExamByToken(token);
    notifyListeners();
  }

  void _adoptReviewRows(String token, Map<String, dynamic> payload) {
    final Object? rows = jget(payload, 'rows');
    if (rows is! List<dynamic>) return;
    examReviewByToken[token] = rows
        .whereType<Map<String, dynamic>>()
        .map(ExamReviewRow.fromJson)
        .toList();
  }

  /// Load the pre-submit checklist for [token].
  Future<void> loadExamReview(String token) async {
    if (!_live || token.isEmpty) return;
    try {
      _adoptReviewRows(token, await _api.examReview(token));
      notifyListeners();
    } on ApiError catch (e) {
      // The runner still renders from what it has; a failed checklist fetch
      // must not block a candidate from submitting.
      _standDown(e, token);
    }
  }

  /// Told the candidate once that their answers are not reaching the server.
  ///
  /// Once, not per failure: a dropped connection fails every autosave, and a
  /// toast per keystroke-debounce would bury the exam. Reset on the next
  /// success so a recovered connection can warn again if it drops later.
  bool _autosaveWarned = false;

  void _warnAutosaveFailing() {
    if (_autosaveWarned) return;
    _autosaveWarned = true;
    toaster.show(
      'Your answers are not reaching the server. Check your connection - '
      'do not close this tab.',
      Tone.warn,
    );
  }

  /// Persist one answer, at most once per second per question.
  ///
  /// Debounced because `saveAnswerQuiet` fires on EVERY KEYSTROKE: sending
  /// each one would put a request per character on the wire and let a slow
  /// network reorder them, so the last write to arrive might not be the last
  /// the candidate typed. One second after they stop, the current value goes
  /// once.
  ///
  /// Failures do not interrupt the candidate: an answer is also submitted in
  /// full by `finishExam`, so a dropped autosave costs nothing, whereas a red
  /// banner mid-question would alarm somebody sitting a timed exam over a
  /// problem that resolves itself.
  ///
  /// They are NOT silent, though. This swallowed a permanent 422 - the route
  /// rejecting every objective answer because the client sent `option_ids`
  /// instead of `selected_option_ids` - and because nothing was logged, the
  /// exam looked like it was working while no selection was ever stored. A
  /// transient failure deserves no interruption; a rejection the server will
  /// give every single time deserves a line somebody can find.
  void _syncAnswer(Attempt ev, String questionId, Response r) {
    // The question being answered is the one on screen - a live paper sends
    // them one at a time - kept for the review's blank-row check.
    final Question? shown = examByToken[ev.token]?.question;
    if (shown != null && shown.id == questionId) {
      answeredQuestions[questionId] = shown;
    }
    if (!_live) return;
    // Another tab holds this sitting, and would have this write refused.
    if (sessionReplaced.contains(ev.token)) return;
    // NEVER post an answer the server is certain to refuse. An empty response
    // fails `_record_response`'s per-type completeness check and comes back
    // 422 "This answer is incomplete for its question type" - a refusal that
    // is correct, useless, and races the real save: a blank autosave landing
    // in the same second as a genuine one put that error on screen over an
    // answer box the candidate had plainly filled in, and which had in fact
    // just been stored. There is nothing to save here, so save nothing; a
    // cleared box is an unanswered question either way.
    if (!r.hasInput) {
      _answerSync[questionId]?.cancel();
      _answerSync.remove(questionId);
      _answerDirtySince.remove(questionId);
      _syncLeaveGuard();
      return;
    }
    // NOTHING CHANGED SINCE THE SERVER LAST ACCEPTED THIS ANSWER: SEND NOTHING.
    //
    // This is the cheapest large win available on the whole platform. Writing an
    // answer costs a median of 39 SQL queries (12 stored computes on the response
    // row, 7 more on the evaluator), and on 2026-09-03 candidates posted a median
    // of 240 times each on papers of 19 and 35 questions - so ~89% of the 12.4M
    // queries `/answer` issued in three hours re-stored a value the server
    // already held. `/answer` alone was 86.6% of all database traffic.
    //
    // Checked here rather than in the timer body so a repeat does not even hold a
    // pending timer, and checked BEFORE `_advancing` so a navigation save that
    // already sent this exact payload cannot be followed by a duplicate.
    final String print_ = _answerFingerprint(r);
    if (_answerSent[questionId] == print_) {
      _answerSync[questionId]?.cancel();
      _answerSync.remove(questionId);
      // Back in step with the server, so the ceiling has nothing to measure.
      _answerDirtySince.remove(questionId);
      _syncLeaveGuard();
      return;
    }
    // THE CEILING, measured from the first divergence rather than the last
    // keystroke - see `answerMaxWaitDefault`. Steady typing that never pauses long
    // enough to trip the debounce still saves once every 15 seconds.
    final DateTime dirtySince = _answerDirtySince.putIfAbsent(
      questionId,
      DateTime.now,
    );
    final bool overdue = DateTime.now().difference(dirtySince) >= _maxWaitFor;
    _answerSync[questionId]?.cancel();
    // When this content was typed, for [_heldByReports].
    final int stamp = _stampFor(ev.token, questionId, r);
    // Completes with whether the answer was KEPT, for [flushAnswers].
    Future<bool> send() {
      // The authoritative save got there first. Posting now would be a second
      // INSERT of the same answer racing the first - see `examAdvance`.
      if (_advancing.contains(questionId)) return Future<bool>.value(true);
      // AFTER AN UNSENT VIOLATION REPORT IT WAITS (BR-D15): the reports go
      // first. It stays unacknowledged ([_answerDirtySince]), and goes once
      // they are answered ([_flushDirty]).
      if (_heldByReports(ev.token, stamp)) {
        unawaited(_sendReports(ev.token));
        return Future<bool>.value(false);
      }
      _answersInFlight++;
      return _api
          .examAnswer(
            ev.token,
            questionId: questionId,
            // `lines` IS the selected-option list. On the wire the route
            // reads `selected_option_ids` (see ApiClient.examAnswer, which
            // does the renaming); `option_ids` was silently refused with a
            // 422 "This answer is incomplete for its question type".
            optionIds: r.lines,
            justification: r.justification,
            labels: r.labels ?? const <int, String>{},
            clipAnswers: r.clip?.toJson(),
            // SAVE ONLY (SNo 147). This call throws its response away - it
            // exists to protect the caret while somebody types - and `nav`
            // defaults to `next`, so the server was composing the next
            // question, its options and a signed URL per plate for a client
            // that discards them. It is also the most frequent call the runner
            // makes.
            nav: 'stay',
          )
          .then((Map<String, dynamic> res) {
            if (jget(res, 'ok') != false) {
              // RECORDED ONLY ON ACCEPTANCE. A refused or failed post must not
              // mark the payload as sent, or the retry the candidate's next
              // keystroke would trigger is suppressed and the answer is lost.
              _answerSent[questionId] = print_;
              _answerDirtySince.remove(questionId);
              // Answers are landing again; re-arm the warning so a later drop
              // is not swallowed by the first one.
              _autosaveWarned = false;
              return true;
            }
            {
              final Object? err = jget(res, 'error');
              final String code = err is Map<String, dynamic>
                  ? '${jget(err, 'code') ?? ''}'
                  : '';
              final String why = err is Map<String, dynamic>
                  ? '${jget(err, 'message') ?? jget(err, 'code')}'
                  : 'unknown';
              debugPrint(
                'answer autosave REFUSED for question $questionId: $why',
              );
              // A refusal used to be a debugPrint and nothing else, which meant
              // a candidate whose answers were being rejected had no way to
              // know until results came back wrong. `attempt_locked` is exempt:
              // it is the ordinary end-of-exam race, already handled.
              //
              // `incomplete_answer` IS NOT A CONNECTIVITY PROBLEM and must not
              // be reported as one. It means the payload does not yet satisfy
              // this question type - one more axis to tick, or a box to label -
              // and the fix is a click, not a network. Sending the candidate to
              // check their wifi over that is a wrong instruction, and
              // `_warnAutosaveFailing` fires ONCE PER SITTING, so the false
              // alarm also burns the one warning we get for a real outage.
              //
              // IT IS NOT AN ERROR EITHER, on THIS path. `_record_response`
              // holds a half-finished answer as a DRAFT and returns False, so
              // the work is stored; the refusal only means it does not count
              // as answered yet. An A/B answer written verdicts first meets it
              // on every autosave, and a red sentence there reads as data
              // loss. `examAdvance` surfaces the refusal at Next, where it
              // changes what the candidate should do; a mid-answer autosave
              // says nothing.
              if (code != 'incomplete_answer' && code != 'attempt_locked') {
                _warnAutosaveFailing();
              }
            }
            return false;
          })
          .catchError((Object e) {
            debugPrint('answer autosave failed for question $questionId: $e');
            if (_standDown(e, ev.token)) return false;
            // Answering the LAST question auto-submits server-side, so a
            // debounced autosave already in flight lands on a locked attempt
            // and throws 409. That is a state change, not a lost answer -
            // warning about connectivity here is a false alarm. Settle through
            // the same path the navigation route uses so both agree.
            if (e is ApiError &&
                (e.code == 'attempt_locked' || e.status == 409)) {
              if (e.code == 'time_expired') {
                _tellTimeUp(
                  ev.token,
                  lastAnswerKept: e.fields['answer_saved'] != false,
                );
              }
              _markExamComplete(ev.token);
              return e.code == 'time_expired' &&
                  e.fields['answer_saved'] != false;
            }
            // THE REFUSAL ARRIVES HERE, NOT IN THE BRANCH ABOVE: `_send`
            // throws on `ok: false`, so a 422 is an exception rather than a
            // body. Same rule as there - a draft hold is not an outage, and
            // must not spend the one connectivity warning a sitting gets.
            if (e is ApiError && e.code == 'incomplete_answer') return false;
            _warnAutosaveFailing();
            return false;
          })
          .whenComplete(() {
            _answersInFlight--;
            _syncLeaveGuard();
          });
    }

    _answerSend[questionId] = send;
    _answerSync[questionId] = Timer(
      overdue ? Duration.zero : _debounceFor,
      send,
    );
    _syncLeaveGuard();
  }

  /// The send each pending [_answerSync] timer will make, so [flushAnswers]
  /// can make it early. Trusted only while that timer is still active.
  final Map<String, Future<bool> Function()> _answerSend =
      <String, Future<bool> Function()>{};

  /// Attempts whose last change was flushed as a violation ended them and was
  /// not kept, so the completion screen does not say every answer was.
  final Set<String> unsavedAtEnd = <String>{};

  /// Time is up on this client's clock: send every pending autosave NOW, then
  /// drop the debounce (MT3-02).
  ///
  /// The server keeps an answer that lands within ~10s of its deadline and
  /// refuses one after, so a sentence typed just before the buzzer must not
  /// sit out a 5s debounce - and nothing may be queued behind the time-up
  /// overlay afterwards.
  ///
  /// The sends go out at once; the future completes when their replies are
  /// in, with whether every one was kept (M1).
  Future<bool> flushAnswers() async {
    final List<Future<bool> Function()> due = <Future<bool> Function()>[
      for (final MapEntry<String, Timer> e in _answerSync.entries)
        if (e.value.isActive) ?_answerSend[e.key],
    ];
    for (final Timer t in _answerSync.values) {
      t.cancel();
    }
    _answerSync.clear();
    _answerSend.clear();
    for (final Future<bool> Function() send in due) {
      final Future<bool> sent = send();
      _flushing.add(sent);
      unawaited(sent.whenComplete(() => _flushing.remove(sent)));
    }
    _syncLeaveGuard();
    // An earlier flush's sends still in flight count too: a page-hide flush
    // can take the pending saves just before the violation that ends the
    // sitting asks for them.
    final List<bool> kept = await Future.wait(_flushing.toList());
    return !kept.contains(false);
  }

  /// Sends started by [flushAnswers] and not yet answered.
  final Set<Future<bool>> _flushing = <Future<bool>>{};

  /// The answer this attempt currently holds for [q].
  ///
  /// Resolved through the STORE's copy of [ev], never through the object the
  /// caller passed. The answer editors write with `saveAnswerQuiet`, which
  /// does not notify - so a widget holding an `Attempt` from its last build
  /// holds one whose `resp` predates everything since typed, and merging onto
  /// it silently discards the candidate's own text. The id is stable across
  /// those rewrites; the object is not.
  Response responseFor(Attempt ev, Question q) =>
      (attemptById(ev.id) ?? ev).resp[q.id] ?? Response.seed(q);

  /// Record a proctoring violation and, at the cap, end the exam.
  ///
  /// Returns true when the violation ended the attempt, so the caller knows to
  /// route to the completion screen rather than re-render the question. Live,
  /// that is never decided here: the server ends the sitting on the reply to
  /// the report ([_drainReports]), and until it answers the exam is locked
  /// ([violationLocked]).
  bool recordViolation(String attemptId, String reason) {
    final Attempt? ev = attemptById(attemptId);
    if (ev == null) return false;
    // A FINISHED SITTING CANNOT BE VIOLATED.
    //
    // A candidate reading their own submitted paper is not sitting an exam,
    // and without this guard any stray event reaching here re-entered
    // `finishExam` on an already-submitted attempt: every answer re-POSTed,
    // `/submit` called again, the auto-submit toast shown again, and a full
    // `refresh()` - on every further right-click.
    if (ev.isDone) return false;
    // Nor one another tab holds: this tab records nothing until it takes the
    // sitting back.
    if (sessionReplaced.contains(ev.token)) return false;
    // NOR ONE BEING SUBMITTED. The sitting stays open until the server takes
    // the submit (BR-D1), so the watchers still fire under "Submitting...".
    // A candidate who pressed Submit is done; a violation counted now could
    // only let the server end the sitting as a violation (its own cap) instead
    // of as their submit. A submit that fails clears the busy key, and
    // violations count again from there.
    if (isBusy('submit:$attemptId')) return false;
    final Assessment? asm = asmById(ev.assessmentId);
    if (asm == null) return false;

    // MIRRORS THE SERVER'S DEDUP (`_record_violation`, 1.2s on the same
    // reason). Without it the two tallies diverge in the one direction that
    // matters: the client counts an event the server discarded, reaches the
    // cap first, and auto-submits a sitting whose authoritative count is
    // still below its own threshold. Two Ctrl+C presses inside a second did
    // exactly that at a cap of 2.
    // Read from [_lastViolation], NEVER from `ev`: see that field's comment.
    // The attempt's own `violationAt` is gone at the next re-parse, because
    // the wire carries no violation timestamp at all.
    final ({String reason, DateTime at})? last = _lastViolation[attemptId];
    if (last != null &&
        last.reason == reason &&
        DateTime.now().difference(last.at) <
            const Duration(milliseconds: 1200)) {
      return false;
    }

    final DateTime now = DateTime.now();
    // AI reasons count against the paper's AI pair, apart (R5).
    final bool ai = isAiReason(reason);
    final ({ViolationAction action, int cap}) policy = asm.policy(ai);
    final int count = ev.countOf(ai) + 1;
    final int cap = policy.cap > 0 ? policy.cap : 1;
    // Armed BEFORE the report below, so a second event arriving in the same
    // turn is already folded.
    _lastViolation[attemptId] = (reason: reason, at: now);
    final Attempt next = ev.copyWith(
      violationCount: ai ? null : count,
      aiViolationCount: ai ? count : null,
      violationReason: reason,
      // Display and round-trip state only - NOT the dedup's memory. This is
      // null again after the next refresh. See [_lastViolation].
      violationAt: now,
    );
    _replaceAttempt(next);

    // Report it. A violation is an integrity record: it has to reach the
    // server even if the candidate closes the tab immediately after, so it is
    // sent now rather than batched with the submission.
    //
    // The RESPONSE is read rather than thrown away. It carries the server's
    // own tally and its `attempt_ended` verdict, and the server is the
    // authority on both: the local count restarts at zero on every reload, so
    // a candidate who refreshed got a fresh allowance of violations, and an
    // attempt the server had already auto-submitted went on rendering
    // questions here until something else happened to refetch.
    //
    // NEVER LOST (BR-D15). A report that got no answer used to be dropped,
    // while the answers typed meanwhile went in on reconnect: go offline, use
    // a phone, come back, and the paper landed with no violation behind it.
    // Now each report waits in [_reports] until the server answers it, goes
    // before any answer typed after it ([_heldByReports]) and before the
    // submit, and is tried again ([_retryReports]). Its stamp rides every
    // try, so a report whose reply was lost counts once.
    //
    // LOG ONLY MEANS LOG ONLY (A-074, owner rule). The cap decides WHEN an
    // attempt ends; the action decides WHETHER it ends at all. Under Log only
    // reaching the cap only marks the attempt as over the limit
    // (`violation_limit_breached`), which the server reports.
    final bool ends = policy.action.isAuto && count >= cap;
    if (_live) {
      _queueReport(
        ev.token,
        ViolationRow(reason: reason, at: _nextStamp(ev.token), ends: ends),
      );
    }

    // LIVE, THE SERVER ENDS IT AND THEN THIS SCREEN SAYS SO. The sitting used
    // to be marked auto-submitted here, before the `/violation` above had gone
    // out; with the network down the report never arrived, the server kept
    // the sitting open, and the candidate was told it was over.
    // [_drainReports] ends it when the reply carries `attempt_ended`, and
    // until then the exam is locked ([violationLocked]). With no backend
    // there is nobody to ask.
    if (ends && !_live) {
      _endForViolation(attemptId, ai: ai);
      return true;
    }
    return false;
  }

  /// Tell the server whether the AI watch ran on this device ([status]:
  /// `running` or `failed`).
  ///
  /// THE LATEST ONE HAS TO LAND. The bridge reports once per start, and
  /// `failed` comes just before it stops, so a lost POST was the admin's only
  /// "AI proctoring could not start" gone for good. A status that got no
  /// answer is tried again ([_aiStatusTries] in all) while it is still the
  /// latest, and an older one that lands after a newer one is followed by the
  /// newer one again, so the server is left holding the latest.
  void reportAiStatus(String token, String status) {
    if (!_live || sessionReplaced.contains(token)) return;
    final Attempt? ev = attemptByToken(token);
    if (ev == null || ev.isDone) return;
    _aiStatusLatest[token] = status;
    unawaited(_sendAiStatus(token, status, _aiStatusTries));
  }

  static const int _aiStatusTries = 3;

  /// The last AI status reported for each sitting.
  final Map<String, String> _aiStatusLatest = <String, String>{};

  Future<void> _sendAiStatus(String token, String status, int tries) async {
    try {
      await _api.examAiStatus(token, status);
    } on ApiError catch (e) {
      // No answer, or "not now": tried again. A refusal is the answer.
      final bool again = e.isTransport || e.status == 429 || e.status == 503;
      if (!again || tries <= 1 || _disposed) {
        debugPrint('AI status not sent (${e.status}): ${e.message}');
        return;
      }
      final Duration? asked = e.retryAfter;
      await Future<void>.delayed(
        asked == null ? _spread(_reportRetryEvery) : _spreadAsked(asked),
      );
      if (_aiStatusLatest[token] == status && !_disposed) {
        await _sendAiStatus(token, status, tries - 1);
      }
      return;
    } catch (e) {
      debugPrint('AI status reply unreadable: $e');
      return;
    }
    final String? latest = _aiStatusLatest[token];
    if (latest != null && latest != status && !_disposed) {
      await _sendAiStatus(token, latest, 1);
    }
  }

  /// End a sitting because proctoring ended it.
  ///
  /// NOT `finishExam`. That method POSTs `/submit`, and the module REFUSES a
  /// submit while questions are unanswered unless the clock has run out - so a
  /// violation auto-submit, which by its nature lands on a half-finished
  /// paper, was refused with "10 question(s) are still unanswered" and the
  /// candidate was shown "Assessment submitted" and "Your exam was NOT
  /// submitted" at the same time, on a sitting the server had in fact just
  /// ended correctly.
  ///
  /// The server owns this ending: `_record_violation` calls
  /// `_auto_submit_expired` itself the moment the cap is reached, blanking the
  /// unanswered questions with the violation named as the reason. The client's
  /// job is only to stop writing and show what happened - so this marks the
  /// attempt done locally and re-reads the server's copy, which is already
  /// authoritative. With no backend there is nobody to do that, so seed mode
  /// keeps grading through `finishExam`.
  ///
  /// Live, only ever called with the server's reply in hand, so the re-read
  /// below cannot race the `/violation` POST that ended the sitting. That
  /// includes a reply that lands while a Submit is in flight: the submit
  /// sends the queued reports first, and an ending one stands in for it.
  ///
  /// [ai]: the AI count ended it, stamped `ai_violation` (R5).
  void _endForViolation(String attemptId, {bool ai = false}) {
    final String why = ai ? 'ai_violation' : 'violation';
    if (!_live) {
      finishExam(attemptId, auto: true, autoReason: why);
      return;
    }
    final Attempt? ev = attemptById(attemptId);
    if (ev == null || ev.isDone) return;
    // A Submit still in flight must not call this one manual (N2, F5).
    _endedByViolation.add(attemptId);

    // A debounced autosave still pending would land on an attempt the server
    // has already locked, and answer 403.
    for (final Timer t in _answerSync.values) {
      t.cancel();
    }
    _answerSync.clear();
    // The sitting is over. `recordViolation` refuses a done attempt, so this
    // entry can never be consulted again; dropping it keeps the map from
    // accumulating one entry per sitting for the life of the process.
    _lastViolation.remove(attemptId);
    // The answer timers above as well: the guard is re-read here.
    _dropReports(ev.token);

    _replaceAttempt(
      ev.copyWith(
        state: AttemptState.submitted,
        isLocked: true,
        autoSubmitted: true,
        // Stamped locally as well as server-side: the completion screen paints
        // before the background refresh lands, and an unnamed cause there
        // reads as the exam having ended for no reason at all.
        autoSubmitReason: why,
        submittedAt: DateTime.now(),
      ),
    );
    toaster.show(
      ai
          ? 'Exam auto-submitted at the AI proctoring violation threshold'
          : 'Exam auto-submitted at the violation threshold',
      Tone.warn,
    );
    notifyListeners();
    // The server graded the blanks; its marks are the ones that count.
    //
    // BACKGROUND, like every other refresh in this file. A foreground refresh
    // flips `loadState` to `loading` and nulls `loadError`, which pins a
    // progress bar over the completion screen - and because `ApiClient` sets
    // no request timeout, a hung call leaves the app in `loading` for the rest
    // of the session with no error, no banner and no reconnect.
    unawaited(refresh(background: true));
  }

  /// The sitting reached its violation limit on this device under
  /// auto-submit, and the server has not answered that report yet (BR-D15):
  /// the exam is locked until it does. It says nothing of a submission,
  /// because there has not been one. Never under Log only, whose reports
  /// never end anything.
  ///
  /// Also when a report flagged below the limit is still queued and the
  /// device's count is at it (N3): the server may count it as the ending one,
  /// and the paper must not stay open to answers the server will blank. One
  /// raised under "Submitting..." is never flagged and locks nothing while
  /// that submit runs; a submit that then fails leaves it locking.
  bool violationLocked(String token) {
    final List<ViolationRow>? q = _reports[token];
    final Attempt? ev = attemptByToken(token);
    if (q == null || q.isEmpty || ev == null || ev.isDone) return false;
    if (q.any((ViolationRow r) => r.ends)) return true;
    final Assessment? asm = asmById(ev.assessmentId);
    if (asm == null || isBusy('submit:${ev.id}')) return false;
    // Each kind with a report queued, against its own pair (R5).
    for (final bool ai in <bool>{
      for (final ViolationRow r in q) isAiReason(r.reason),
    }) {
      final ({ViolationAction action, int cap}) p = asm.policy(ai);
      if (p.action.isAuto && ev.countOf(ai) >= (p.cap > 0 ? p.cap : 1)) {
        return true;
      }
    }
    return false;
  }

  /// A report did not reach the server and waits to be tried again.
  bool violationReportsWaiting(String token) => _reportRetry.containsKey(token);

  /// A report has not been answered by the server yet: "noted", not
  /// "recorded" (RT-2).
  bool violationReportsUnsent(String token) =>
      _reports[token]?.isNotEmpty ?? false;

  /// Try the waiting reports now: the lock's own button. With nothing left
  /// to send, ask the server where the sitting stands instead (N1).
  void retryViolationReports(String token) {
    if (violationReportsUnsent(token)) {
      unawaited(_sendReportsSoon(token));
    } else {
      unawaited(_askWhereTheSittingStands(token));
    }
  }

  /// The server's word on [token]'s sitting, on the question it is on: ended
  /// there, it is complete here; open, the screen simply repaints. For a
  /// report that would have ended it and that the server refused (N1): its
  /// own ending can raise and answer 500, and then only this can tell.
  Future<void> _askWhereTheSittingStands(String token) async {
    if (!_live || _disposed || sessionReplaced.contains(token)) return;
    try {
      final Map<String, dynamic> res = await _api.examState(
        token,
        q: examByToken[token]?.index,
      );
      if (_disposed) return;
      if (jval(res, 'outcome', '') == 'complete') {
        _markExamComplete(token);
      } else {
        // OPEN: the server's count, plus what has not been sent yet (F3).
        // The device's count still had the dropped report in it, and at the
        // limit the next violation would have been flagged as the ending one
        // and locked the exam again. Per kind (R5).
        final Map<String, dynamic> at = jobj(res, 'attempt');
        final int served = jval(at, 'violationCount', -1);
        final int servedAi = jval(at, 'aiViolationCount', -1);
        final List<ViolationRow> q = _reports[token] ?? const <ViolationRow>[];
        int unsent(bool ai) =>
            q.where((ViolationRow r) => isAiReason(r.reason) == ai).length;
        final Attempt? ev = attemptByToken(token);
        if ((served >= 0 || servedAi >= 0) && ev != null && !ev.isDone) {
          _replaceAttempt(
            ev.copyWith(
              violationCount: served >= 0 ? served + unsent(false) : null,
              aiViolationCount: servedAi >= 0 ? servedAi + unsent(true) : null,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('where the sitting stands: no answer: $e');
    }
    if (!_disposed) notifyListeners();
  }

  /// [r] will not be sent again (N1): a lock it may have held comes off on
  /// screen, and for one that would have ended the sitting the server is
  /// asked whether it did.
  void _dropReport(String token, ViolationRow r) {
    _reports[token]?.remove(r);
    _syncLeaveGuard();
    notifyListeners();
    if (r.ends) unawaited(_askWhereTheSittingStands(token));
  }

  /// Answers stamped after [stamp] wait for [token]'s oldest unsent report.
  /// One typed BEFORE it goes freely: first, because the server blanks it if
  /// not and does not hold it when the report ends the sitting.
  bool _heldByReports(String token, int stamp) {
    final List<ViolationRow>? q = _reports[token];
    return q != null && q.isNotEmpty && stamp >= q.first.at;
  }

  void _queueReport(String token, ViolationRow r) {
    (_reports[token] ??= <ViolationRow>[]).add(r);
    _syncLeaveGuard();
    notifyListeners();
    unawaited(_sendReportsSoon(token));
  }

  /// [_sendReports] for a NEW reason to try - a report just queued, "Try
  /// again", Next, Submit, a re-read - rather than for a save held behind
  /// the queue. True when none are left.
  ///
  /// A send already out may be one that is about to fail (or has, and not yet
  /// let go): joining it, the new report or the press waited for the retry
  /// timer instead of going now. So one more pass runs once that send ends,
  /// whatever it got, if anything is left - one per trigger, never a loop.
  Future<bool> _sendReportsSoon(String token) {
    final Future<bool>? running = _reporting[token];
    if (running == null) return _sendReports(token);
    return running.then<bool>((bool done) {
      final bool left = _reports[token]?.isNotEmpty ?? false;
      if (_disposed || !left) return !left;
      // The send that ended may have started the next pass itself.
      return _reporting[token] ?? _sendReports(token);
    });
  }

  void _dropReports(String token) {
    _reports.remove(token);
    _reportRetry.remove(token)?.cancel();
    // Nothing of this sitting is left to lose by leaving.
    _syncLeaveGuard();
  }

  /// [after]: the wait a 429 or 503 asked for (`Retry-After`), obeyed over the
  /// store's own.
  void _retryReports(String token, {Duration? after}) {
    final Duration wait = after == null
        ? _spread(_reportRetryEvery)
        : _spreadAsked(after);
    _reportRetry[token] ??= Timer(wait, () {
      _reportRetry.remove(token);
      unawaited(_sendReports(token));
    });
    if (!_disposed) notifyListeners();
  }

  /// Send [token]'s unsent reports, oldest first. One send per sitting at a
  /// time: while one runs a caller gets that one, which also takes what was
  /// queued meanwhile. True when none are left.
  Future<bool> _sendReports(String token) {
    final Future<bool>? running = _reporting[token];
    if (running != null) return running;
    // IN PLACE BEFORE THE DRAIN STARTS. Its first step flushes the answers,
    // and one held behind these reports asks for them from inside that
    // flush, synchronously: registered only after `_drainReports` returned,
    // that call found nothing running and started a drain of its own, which
    // did the same, without end.
    final Completer<bool> started = Completer<bool>();
    final Future<bool> run = started.future;
    _reporting[token] = run;
    unawaited(
      _drainReports(token)
          .catchError((Object e) {
            debugPrint('violation reports threw: $e');
            return false;
          })
          .then(started.complete),
    );
    return run.then((bool done) {
      if (identical(_reporting[token], run)) _reporting.remove(token);
      // Queued between the drain's last look and this line.
      if (done && (_reports[token]?.isNotEmpty ?? false)) {
        return _sendReports(token);
      }
      return done;
    });
  }

  /// The loop behind [_sendReports]. A report is let go only once the server
  /// has answered it; one that got no answer stays, and is tried again
  /// ([_retryReports]) - and by the next Next, submit or re-read.
  Future<bool> _drainReports(String token) async {
    _reportRetry.remove(token)?.cancel();
    bool sent = false;
    while (_reports[token]?.isNotEmpty ?? false) {
      sent = true;
      final Attempt? ev = attemptByToken(token);
      if (!_live ||
          _disposed ||
          ev == null ||
          sessionReplaced.contains(token)) {
        return false;
      }
      if (ev.isDone) {
        _dropReports(token);
        return true;
      }
      final ViolationRow r = _reports[token]!.first;
      // THE ANSWERS TYPED BEFORE THIS REPORT GO FIRST, on a paper where a
      // report can end it: the server blanks every unsaved question the
      // moment it ends the sitting, and `_endForViolation` cancels the timers
      // that would have saved them. Before EVERY report there, not only the
      // one this device counted as the last: a re-read resets the count to
      // the server's, which leaves out the reports still queued. Nothing typed
      // after it goes ([_heldByReports]).
      //
      // What it kept is THIS report's to say: only if the reply ends the
      // sitting does it decide what the completion screen says (N5). An
      // answer held behind it is no reason to mark the end, so this asks
      // whether anything typed BEFORE it is still unsaved, not whether the
      // flush as a whole was kept.
      bool? keptBefore;
      final bool ai = isAiReason(r.reason);
      if (asmById(ev.assessmentId)?.policy(ai).action.isAuto ?? true) {
        await _flushDirty(token);
        keptBefore = !_unsavedBefore(token, r.at);
      }
      final Map<String, dynamic> res;
      try {
        res = await _api.examViolation(token, r.reason, at: r.at);
      } on ApiError catch (e) {
        // PAST THE DEADLINE THE SERVER RECORDS NO VIOLATION (MT3-01): it ends
        // the attempt on the clock and answers exactly as `/answer` does.
        // Settle through the same time-up path, never as a proctoring
        // auto-submit.
        //
        // SAVE THE PENDING TYPING FIRST (M1). Inside its 10s grace the server
        // leaves the paper open for exactly this, and `_markExamComplete`
        // cancels an unsent autosave. The flushed `/answer` then meets the
        // deadline itself and says whether it was kept, and settles; only
        // when nothing did is it said here - "saved" only if nothing was
        // dropped. The reports go first: none is recorded, so none holds the
        // typing back.
        if (e.code == 'time_expired') {
          _dropReports(token);
          final bool kept = await _flushDirty(token);
          if (!_timeUpTold.contains(token)) {
            _tellTimeUp(token, lastAnswerKept: kept);
            _markExamComplete(token);
          }
          return true;
        }
        if (_standDown(e, token)) return false;
        // NO ANSWER, OR "NOT NOW": kept, and tried again. Only these. A 500
        // that outlived the retry ladder is the server's answer to this
        // report: retried every 5 s for ever it held every later answer and
        // Submit back - "No connection" over a working one - until the
        // deadline closed the paper with them blank.
        //
        // `not_started` too: the local `beginExam` opens the paper before its
        // `/begin` lands, and a report in that gap is the server not having
        // seen the sitting begin yet - never counted, kept, and tried again
        // on the same timer once `/begin` has had time to land.
        if (e.isTransport ||
            e.status == 429 ||
            e.status == 503 ||
            e.code == 'not_started') {
          _retryReports(token, after: e.retryAfter);
          return false;
        }
        // The server's own refusal of THIS report: not sent again. A sitting
        // already closed over there is over here too.
        debugPrint(
          'violation report refused (${e.status} ${e.code}), not sent '
          'again: ${r.reason}: ${e.message}',
        );
        if (e.status == 409) {
          _reports[token]?.remove(r);
          _markExamComplete(token);
          return true;
        }
        _dropReport(token, r);
        continue;
      } catch (e) {
        // A reply this client could not read: answered all the same.
        debugPrint('violation report reply unreadable, not sent again: $e');
        _dropReport(token, r);
        continue;
      }
      _reports[token]?.remove(r);
      _syncLeaveGuard();
      final bool last = _reports[token]?.isEmpty ?? true;

      // The server's tally, read only off the reply to the LAST report: the
      // reply to an earlier one does not count the ones still queued, and
      // would walk the count back down. It may be lower than the local count
      // (the server dedups), and then that is the correction it should be.
      final Attempt now = attemptById(ev.id) ?? ev;
      final int served = last ? jval(res, 'violationCount', -1) : -1;
      final int servedAi = last ? jval(res, 'aiViolationCount', -1) : -1;
      // The limit reached, in either mode (A-074): the candidate is told.
      final bool breached = jval(res, 'violationLimitBreached', false);
      final bool aiBreached = jval(res, 'aiViolationLimitBreached', false);
      if ((served >= 0 && served != now.violationCount) ||
          (servedAi >= 0 && servedAi != now.aiViolationCount) ||
          (breached && !now.violationLimitBreached) ||
          (aiBreached && !now.aiViolationLimitBreached)) {
        _replaceAttempt(
          now.copyWith(
            violationCount: served >= 0 ? served : null,
            aiViolationCount: servedAi >= 0 ? servedAi : null,
            violationLimitBreached: breached ? true : null,
            aiViolationLimitBreached: aiBreached ? true : null,
          ),
        );
      }

      // The server ends an attempt on its OWN cap and policy. Ended, the exam
      // screen's ListenableBuilder routes to the completion surface off
      // `isDone`. Not ended, the lock this report held comes off (BR-D15):
      // the server counted less, and the sitting goes on.
      if (jval(res, 'attemptEnded', false) && !now.isDone) {
        if (keptBefore != null) {
          keptBefore ? unsavedAtEnd.remove(ev.id) : unsavedAtEnd.add(ev.id);
        }
        // The report that ended it names the kind that did.
        _endForViolation(ev.id, ai: ai);
        return true;
      }
      notifyListeners();
      // The server folds a second report of the same reason inside 1.2s into
      // the first: back-to-back sends after a reconnect are not one action.
      final List<ViolationRow> rest = _reports[token] ?? const <ViolationRow>[];
      if (rest.isNotEmpty && rest.first.reason == r.reason) {
        await Future<void>.delayed(_reportGap);
      }
    }
    // What waited behind the reports goes now.
    if (sent) unawaited(_flushDirty(token));
    return true;
  }

  /// Every answer of [token]'s sitting the server has not acknowledged
  /// ([_answerDirtySince]) goes now: the ones still on their debounce, and the
  /// ones no timer holds any more - an autosave that was refused, got no
  /// answer, or waited behind a report. Completes with whether every one was
  /// kept, as [flushAnswers] does.
  Future<bool> _flushDirty(String token) {
    final Attempt? ev = attemptByToken(token);
    if (ev != null && !ev.isDone) {
      for (final String q in _answerDirtySince.keys.toList()) {
        if (_answerSync[q]?.isActive ?? false) continue;
        final Response? r = ev.resp[q];
        if (r != null) _syncAnswer(ev, q, r);
      }
    }
    return flushAnswers();
  }

  /// Whether an answer of [token]'s sitting changed before [at] and is still
  /// not acknowledged by the server.
  bool _unsavedBefore(String token, int at) => _answerDirtySince.keys.any(
    (String q) => (_changedAt['$token:$q']?.at ?? at) < at,
  );

  /// [d] times a random factor in [0.75, 1.25].
  ///
  /// A pod restart fails a whole room's writes in the same second, and fixed
  /// timers bring the room back in the same later second, aimed at a server
  /// that has just come up. The report and AI-status retries go through here.
  Duration _spread(Duration d) => d * (0.75 + 0.5 * _jitter());

  /// A wait the server asked for (`Retry-After`): never shortened, but up to
  /// 25% longer, for the same reason as [_spread].
  Duration _spreadAsked(Duration asked) => asked * (1 + 0.25 * _jitter());

  final double Function() _jitter = Random().nextDouble;

  /// A new stamp on the server's clock, later than every one issued before
  /// in this store. Answers and violation reports share it, so the two never
  /// tie (BR-D15). A report sends its stamp as `at`, and the server counts a
  /// report sent again with the same one once.
  int _nextStamp(String token) {
    final Duration offset = attemptByToken(token)?.clockOffset ?? Duration.zero;
    final int now = DateTime.now().add(offset).millisecondsSinceEpoch;
    final int at = now > _stampMark ? now : _stampMark + 1;
    _stampMark = at;
    return at;
  }

  /// The highest stamp [_nextStamp] has issued.
  int _stampMark = 0;

  /// When [r] was typed, for [_heldByReports]: the stamp of the last change
  /// to that question's content, the same one again for content that has not
  /// changed since (a re-render re-emits it).
  int _stampFor(String token, String questionId, Response r) {
    final String key = '$token:$questionId';
    final String print_ = _answerFingerprint(r);
    final ({String print, int at})? last = _changedAt[key];
    if (last != null && last.print == print_) return last.at;
    final int at = _nextStamp(token);
    _changedAt[key] = (print: print_, at: at);
    return at;
  }

  /// Per `<token>:<question>`: the content last stamped, and its stamp.
  final Map<String, ({String print, int at})> _changedAt =
      <String, ({String print, int at})>{};

  /// Grade every answered question, lock the attempt, stamp the time.
  /// [autoReason] names the cause when [auto] is set - `'violation'` or
  /// `'expired'`. Both UIs print it, so an attempt that ended under the
  /// candidate is never left saying only that it "was submitted
  /// automatically", which is the one thing they already knew.
  /// [force] carries a decision the candidate has ALREADY been asked for:
  /// either they confirmed "Submit anyway" over the named gaps, or the clock
  /// ran out and the sitting has to settle. It is never set on the candidate's
  /// behalf - a plain Submit on a paper the client believes is complete still
  /// goes without it, so a client/server disagreement about what is answered
  /// surfaces as a refusal instead of silently ending the exam.
  ///
  /// Completes with true once the attempt IS submitted: at once with no
  /// backend, and live only when the server has accepted it (BR-D1), so the
  /// caller moves to the completion screen then and not before.
  Future<bool> finishExam(
    String attemptId, {
    bool auto = false,
    String autoReason = '',
    bool force = false,
  }) {
    final Attempt? ev = attemptById(attemptId);
    if (ev == null) return Future<bool>.value(false);
    // ONE SUBMIT PER SITTING (A-052). A second tap landing before the rebuild
    // re-sent every answer and POSTed `/submit` again. `isDone` covers a
    // settled sitting; the busy key covers the submit still in flight, which
    // no longer marks the attempt done until the server accepts it.
    final String busyKey = 'submit:$attemptId';
    if (ev.isDone) return Future<bool>.value(true);
    if (isBusy(busyKey)) return Future<bool>.value(false);
    final Assessment? asm = asmById(ev.assessmentId);
    if (asm == null) return Future<bool>.value(false);

    // LIVE AND SEED BUILD THIS DIFFERENTLY, and conflating them lost answers.
    //
    // `asm.questions` is EMPTY on a live exam - the payload has never carried a
    // question list (Assessment.questions says so, and so does the runner).
    // Grading over it therefore yielded {}, which then became BOTH the
    // attempt's local `resp` (wiping what the candidate had typed) and the
    // re-send set below - so the "belt-and-braces" re-send posted nothing at
    // all, on every real submit. Every test that covered this injected a
    // seed-shaped assessment, the one shape where asm.questions is populated,
    // which is why 400 passing tests never saw it.
    //
    // Live: the SERVER grades, so answers pass through untouched.
    // Seed: there is no server, so grade locally exactly as before.
    final Map<String, Response> next = <String, Response>{};
    if (_live) {
      next.addAll(ev.resp);
    } else {
      for (final Question q in asm.questions) {
        final Response? r = ev.resp[q.id];
        if (r == null) continue;
        final Response? graded = gradeOne(asm, q, r);
        // A null result means the candidate left it blank: the answer is
        // discarded so it reads as unanswered rather than as a zero.
        if (graded != null) next[q.id] = graded;
      }
    }

    // THE ATTEMPT IS NOT MARKED SUBMITTED UNTIL THE SERVER ACCEPTS (BR-D1).
    //
    // It used to be flipped here, before a single request had been made, and
    // put back on failure. With the network down that showed "Assessment
    // submitted" for as long as the retry ladder ran - about ten seconds -
    // and then dropped the candidate back into the exam at question 1, in the
    // app shell, with a toast over the footer. Live, the sitting stays open
    // while the submit runs: the Submit control shows it is busy, and a
    // refusal leaves the candidate exactly where they were. Seed mode has no
    // server to wait for and settles at once, as before.
    void settle() {
      _replaceAttempt(
        (attemptById(attemptId) ?? ev).copyWith(
          state: AttemptState.submitted,
          isLocked: true,
          autoSubmitted: auto,
          autoSubmitReason: auto ? autoReason : '',
          submittedAt: DateTime.now(),
          resp: next,
        ),
      );
      // Same as _endForViolation: nothing can violate a finished sitting.
      _lastViolation.remove(attemptId);
      _dropReports(ev.token);
    }

    // SUCCESS IS NOT CLAIMED UNTIL THE SERVER ACCEPTS.
    //
    // This said "Assessment submitted" here, before a single request had been
    // made - so a candidate whose submit was then refused was told both that
    // it worked and that it did not.
    //
    // With no backend there is nothing to wait for, so seed mode keeps the
    // immediate confirmation.
    // The clock, never proctoring, for a time-out (G2-04).
    bool timeUp = auto && autoReason == 'expired';
    bool lastKept = true;
    void announce() {
      if (timeUp) {
        _tellTimeUp(ev.token, lastAnswerKept: lastKept);
        return;
      }
      toaster.show(
        auto
            ? 'Exam auto-submitted at the violation threshold'
            : 'Assessment submitted',
        auto ? Tone.warn : Tone.ok,
      );
    }

    // Submit for real. A debounced autosave still pending is CANCELLED rather
    // than awaited - letting it fire would put a write after the submit, on an
    // attempt the server has already locked.
    //
    // That is only safe because `next` above now carries every answer the
    // candidate typed, the not-yet-debounced one included, and the loop below
    // re-sends all of them. While `next` came from the empty asm.questions this
    // cancel was a straight answer-drop: the comment here claimed the pending
    // save was "flushed first", and nothing flushed it.
    if (_live) {
      // ONE TOAST, NOT TWO STACKED ON TOP OF EACH OTHER.
      //
      // "Submitting your exam..." used to be an ordinary 3200ms toast, so the
      // outcome below simply landed underneath it and the candidate was shown
      // a question and its answer side by side - still submitting, and already
      // submitted. It is progress, not a statement, so it is held open for
      // exactly as long as the request runs and taken down the instant there
      // is something truer to say.
      final int busyToast = toaster.busy('Submitting your exam...');

      // NARRATE THE WAIT, BECAUSE THE LADDER IS LONG AND SILENT OTHERWISE.
      //
      // This is the one call in the app that retries (losing it loses a
      // candidate's work), and the retry budget lets a shedding server buy up
      // to a minute of sleeping while a toast that never expires says only
      // "Submitting your exam...". A candidate cannot tell that from a hang,
      // and the reasonable thing for them to do about a hang - reload, press
      // it again - is the one thing that costs them. So each rung says how
      // long it is waiting, that their answers are already saved, and offers
      // a way out.
      _api.onRetryWait = (RetryNotice r) => toaster.update(
        busyToast,
        'Still submitting - the server is busy. Next try in '
        '${r.wait.inSeconds}s (try ${r.attempt + 1} of ${r.of}). Your answers '
        'are already saved.',
        onAction: r.cancel,
        actionLabel: 'Stop waiting',
      );

      for (final Timer t in _answerSync.values) {
        t.cancel();
      }
      _answerSync.clear();
      _syncLeaveGuard();

      _busy.add(busyKey);
      // The Submit control shows it is busy: nothing else repaints now that
      // the attempt is no longer flipped here.
      notifyListeners();
      // Settles the moment the outcome is known, before the re-read below.
      final Completer<bool> outcome = Completer<bool>();
      unawaited(() async {
        try {
          // EACH RE-SEND IS GUARDED SEPARATELY, AND THE SUBMIT ALWAYS RUNS.
          //
          // This loop used to share one try with the submit, so a single 422
          // on one answer - an empty justification, a locked attempt after a
          // violation auto-submit - aborted it and `examSubmit` was NEVER
          // CALLED. The candidate had already been shown "Assessment
          // submitted" and their attempt was locked locally, while the server
          // still had them in progress and would later expire them. The paper
          // was lost silently, and the toast said the opposite.
          //
          // The re-send is belt-and-braces over autosave; the submit is the
          // thing that must happen. So one failing answer can no longer take
          // the submit down with it.
          //
          // THE VIOLATION REPORTS GO BEFORE THE SUBMIT (BR-D15): it carries
          // answers typed after them. Unsent, the submit is held like any
          // refusal, and Submit can be pressed again. Answered, they may have
          // ended the sitting, and then that is the outcome.
          if (_reports[ev.token]?.isNotEmpty ?? false) {
            if (!await _sendReportsSoon(ev.token)) {
              // Nothing to put back: the sitting was never marked submitted.
              toaster.dismiss(busyToast);
              toaster.bad('Your exam was NOT submitted. $reportsHeldMessage');
              notifyListeners();
              outcome.complete(false);
              return;
            }
            if (attemptById(ev.id)?.isDone ?? false) {
              toaster.dismiss(busyToast);
              outcome.complete(true);
              return;
            }
          }
          int refused = 0;
          int skipped = 0;
          for (final MapEntry<String, Response> e in next.entries) {
            // ALREADY ACCEPTED BY THE SERVER, UNCHANGED SINCE: SEND NOTHING.
            //
            // THE SUBMIT BURST WAS THE WORST-SHAPED WRITE ON THE PLATFORM.
            // This loop is serial and unconditional, so a 35-question paper
            // fired 35 sequential POSTs the moment Submit was pressed - and
            // every candidate presses Submit at roughly the same time, because
            // they all started at roughly the same time and the clock is
            // shared. On 2026-09-03 that put the heaviest write of the sitting
            // into the narrowest window of it. Nearly all of those writes
            // re-stored a value the server already had.
            //
            // `_answerSent` is written ONLY when the server accepted a payload
            // (see `_syncAnswer` and `examAdvance`), so a match here is the
            // server's own acknowledgement, not the client's optimism. Anything
            // it does not cover - the answer typed inside the debounce window,
            // one whose autosave was refused, one from a reconnect - has no
            // matching fingerprint and is still sent. The belt-and-braces is
            // intact; it just stopped re-sending what was already fastened.
            final String print_ = _answerFingerprint(e.value);
            if (_answerSent[e.key] == print_) {
              skipped++;
              continue;
            }
            try {
              await _api.examAnswer(
                ev.token,
                questionId: e.key,
                optionIds: e.value.lines,
                justification: e.value.justification,
                labels: e.value.labels ?? const <int, String>{},
                clipAnswers: e.value.clip?.toJson(),
                // Nothing follows these: the submit is the next call. Building
                // a next question for each would be pure waste at exactly the
                // moment the whole cohort presses Submit together.
                nav: 'stay',
              );
              // A retry of a failed submit must not re-send this one either.
              _answerSent[e.key] = print_;
            } on ApiError catch (err) {
              // Another tab holds the sitting: the rest would be refused too.
              if (_standDown(err, ev.token)) break;
              // The server saved the answer, then settled on its deadline:
              // not a refusal (G2-03).
              if (err.code == 'time_expired') {
                timeUp = true;
                if (err.fields['answer_saved'] == false) lastKept = false;
              } else if (!err.isRetryable) {
                // A busy server (429/503) or a dropped line refused nothing:
                // calling that "rejected" sent the candidate to re-answer
                // questions that were fine.
                refused++;
              }
            }
          }
          if (skipped > 0) {
            debugPrint(
              'submit: re-sent ${next.length - skipped} of ${next.length} '
              'answer(s); $skipped were already stored',
            );
          }

          try {
            // AN AUTO SUBMIT IS ALWAYS FORCED, and the rule lives here rather
            // than at the call site because this is the one place every submit
            // path passes through. An auto submit fires because the clock ran
            // out, and an expired paper is incomplete by definition. The module
            // does allow that on its own reading of the deadline - but the two
            // clocks are not the same clock, and a candidate whose browser
            // reached zero a moment early would be refused at exactly the
            // instant they can no longer do anything about it.
            await _api.examSubmit(ev.token, force: force || auto);
          } on ApiError catch (e) {
            _standDown(e, ev.token);
            // `attempt_locked` means the server settled it first - a violation
            // auto-submit, or the expiry cron. That IS the outcome we wanted,
            // so it is success, not failure.
            if (e.code != 'attempt_locked') {
              // Nothing to put back: the sitting was never marked submitted,
              // so the candidate is still on the screen they pressed it from.
              // Down BEFORE the refusal goes up: "Submitting your exam..."
              // left alongside "was NOT submitted" reads as a contradiction.
              toaster.dismiss(busyToast);
              // NAME THE REAL CAUSE WHEN WE KNOW IT.
              //
              // `refused` counts answers the server would not store during the
              // re-send above, and it was counted and then dropped. That is
              // exactly the case where the server then says "N question(s) are
              // still unanswered" about questions the candidate HAS answered:
              // the answers never landed. Reporting only the server's count
              // sent them back to re-answer questions that already had text in
              // them, which is the one instruction guaranteed not to work.
              toaster.bad(
                // No host and no CORS for a candidate, in any branch
                // (BR-D3). And a dropped connection FIRST (N4): answers the
                // re-send could not store are not "why" when the submit
                // itself never reached the server.
                e.isTransport
                    ? 'Your exam was NOT submitted. ${e.candidateMessage}'
                    // A server too busy to take it (the whole room submitting
                    // at once) is not the candidate's answers either.
                    : e.isRetryable
                    ? 'Your exam was NOT submitted: the server is busy. Your '
                          'answers are kept on this page, so do not reload it. '
                          'Press Submit again in a moment.'
                    : refused > 0
                    ? 'Your exam was NOT submitted: ${e.candidateMessage} '
                          '$refused answer(s) were rejected when saving, which '
                          'is why. Re-open those questions and check the answer '
                          'is complete for the question type, then Submit '
                          'again.'
                    : 'Your exam was NOT submitted: ${e.candidateMessage} '
                          'Your answers are saved - please try Submit again.',
              );
              notifyListeners();
              outcome.complete(false);
              return;
            }
          }

          // NOW it is true - so the progress toast comes down first and the
          // outcome takes its place, rather than joining it on screen.
          toaster.dismiss(busyToast);
          // ENDED BY A VIOLATION MEANWHILE (N2): one raised under
          // "Submitting..." that the server ended the sitting on, which is why
          // this one came back `attempt_locked`. That ending already said so;
          // calling it a manual submit now would overwrite the truth. ONLY
          // that ending (F5): a refresh that merely read the sitting back as
          // done - this very submit, accepted - still gets its confirmation.
          if (!_endedByViolation.contains(attemptId)) {
            settle();
            announce();
          }
          outcome.complete(true);
          if (refused > 0) {
            // Submitted, but say so honestly rather than silently.
            toaster.warn(
              '$refused answer(s) could not be re-sent, so the copy already '
              'saved on the server was used for them.',
            );
          }
          // The server grades, so re-read rather than trusting the local
          // pass above: its scores are the ones that count.
          await refresh();
        } finally {
          // A toast with no expiry needs a floor under it: an unforeseen throw
          // anywhere above would otherwise strand "Submitting your exam..." on
          // screen for the rest of the session. Dismissing an already-gone ID
          // is a no-op, so the paths that took it down themselves are unhurt.
          toaster.dismiss(busyToast);
          // The callback closes over `busyToast`, so leaving it attached would
          // have the NEXT submit narrate into a dismissed toast id.
          _api.onRetryWait = null;
          _busy.remove(busyKey);
          // An unforeseen throw is a submit that did not happen.
          if (!outcome.isCompleted) outcome.complete(false);
          if (!_disposed) notifyListeners();
        }
      }());
      return outcome.future;
    }

    settle();
    announce();
    return Future<bool>.value(true);
  }

  // ══════════════════════════════════════════════════════════════════════
  //  Generators
  // ══════════════════════════════════════════════════════════════════════

  Future<void> extractTags(String genId) async {
    final Generator? g = genById(genId);
    if (g == null) return;
    if (g.isExtractingTags) {
      toaster.info('Already reading this SOP - the skills land in a moment');
      return;
    }
    // RE-EXTRACTION IS ALLOWED, and deliberately asks nothing first.
    //
    // A `hasTags` early return used to sit here and answer with an info toast
    // instead, which made "Re-extract skills" - a button whose entire purpose
    // is to re-run - do nothing whenever there was anything to re-run. It only
    // ever fired on the one generator state where it was useless.
    //
    // The call does cost money, but pressing a button labelled "Re-extract" is
    // the consent, and "Generate questions" spends more from the same screen
    // without asking. The server swaps the whole tag set in one write, so a
    // re-run cannot leave a half-merged vocabulary behind - and it keeps the
    // old tags visible until the new ones land.
    final bool isRerun = g.hasTags;
    // NOTHING TO READ. The server refuses this with 409 `no_source` when the
    // generator has no document, and a generator with no SOP is an ordinary
    // state now that creating one no longer collects the file. The button is
    // disabled too; this is the guard behind it, and it also stops the seed
    // path below inventing tags for a document that is not there.
    if (g.fileCount == 0) {
      toaster.warn('Attach the SOP first - there is nothing to read yet');
      return;
    }

    if (_live) {
      // The module reads the SOP and calls an LLM. Nothing is faked locally,
      // because the tags it derives are what every later question generation
      // is anchored to.
      //
      // QUEUED on the server, so this returns straight away. The busy key only
      // covers the enqueue round trip; what keeps the button spinning after
      // that - and after a reload - is the server's own `tag_extract_state`,
      // read back through `Generator.isExtractingTags`.
      await withBusy(
        'tags:$genId',
        () => _act(
          'Extract',
          () => _api.extractTags(genId),
          okMessage: (_) => isRerun
              ? 'Re-reading the SOP - the skills refresh in a minute'
              : 'Reading the SOP - the skills land in a minute',
        ),
      );
      // Watch it through to done, the same way a generation run is watched.
      unawaited(pollGeneration());
      return;
    }

    updateGenerator(
      g.copyWith(
        tags: SeedData.tagsFor(g),
        meta: SeedData.metaFor(g),
        tagExtractState: TagExtractState.done,
        allowedTypes: g.allowedTypes.isEmpty
            ? const <QType>[QType.mcq, QType.msq, QType.subjectiveRubric]
            : g.allowedTypes,
      ),
    );
    toaster.ok(
      'Skills extracted - now choose how many questions and which types',
    );
  }

  /// Import a parsed question bank. Returns the module's own summary.
  ///
  /// Deliberately NOT routed through [_act]: the caller is a sheet that has to
  /// report how many questions landed and which rows the importer warned
  /// about, and `_act`'s uniform "Import done" toast would throw that away.
  /// The refresh and the error surface are done here instead.
  /// Import a FILE into one of the three importable entities.
  ///
  /// ONE METHOD FOR ALL THREE, because the outcome shape is the same and the
  /// only thing that differs is the route. Questions report
  /// `questions_created`; tags and generators report `created` / `updated`;
  /// all three report `warnings`, and a skipped row is the one thing the
  /// operator actually has to be told.
  ///
  /// The bytes go up untouched. This app used to parse CSV itself, against a
  /// six-column spec the server's thirty-three-column template did not match -
  /// see [ApiClient.importBankFile].
  Future<Map<String, dynamic>?> importFile(
    ImportEntity entity,
    String filename,
    List<int> bytes,
  ) async {
    if (!_live) {
      toaster.info('Import runs against a live server');
      return null;
    }
    final String content = base64Encode(bytes);
    try {
      final Map<String, dynamic> res = switch (entity) {
        ImportEntity.questions => await _api.importBankFile(
          content: content,
          filename: filename,
          generatorName: _stemOf(filename),
        ),
        ImportEntity.tags => await _api.importTags(
          content: content,
          filename: filename,
        ),
        ImportEntity.generators => await _api.importGenerators(
          content: content,
          filename: filename,
        ),
      };
      final List<dynamic> warn =
          (res['warnings'] ?? const <dynamic>[]) as List<dynamic>;
      // The SERVER'S own sentence when it wrote one - it knows whether a
      // generator now needs its SOP attached, and this does not.
      final String? message = res['message'] as String?;
      final String summary = message ?? _importSummary(entity, res);
      if (warn.isEmpty) {
        toaster.ok(summary);
      } else {
        // `warn` is the reason anyone reads this, so the count goes in the
        // toast and the rows go in the console rather than being dropped.
        toaster.warn('$summary  ${warn.length} row(s) need attention.');
      }
      await refresh();
      return res;
    } on ApiError catch (e) {
      // The importer names the offending row; that sentence is worth more
      // than any wording invented here.
      toaster.bad(e.message);
      return null;
    } catch (e) {
      toaster.bad('Import failed. $e');
      return null;
    }
  }

  static String _importSummary(ImportEntity entity, Map<String, dynamic> res) {
    if (entity == ImportEntity.questions) {
      return 'Imported ${res['questions_created'] ?? 0} question(s)';
    }
    return 'Imported ${res['created'] ?? 0} new, '
        'updated ${res['updated'] ?? 0}';
  }

  static String _stemOf(String filename) {
    final int dot = filename.lastIndexOf('.');
    return dot > 0 ? filename.substring(0, dot) : filename;
  }

  /// The CSV template for [entity], saved to the browser.
  ///
  /// FETCHED, NEVER BUILT HERE. A template written on this side is a second
  /// copy of the column spec, and a second copy is what let the two importers
  /// disagree in the first place.
  Future<void> downloadImportTemplate(ImportEntity entity) async {
    if (!_live) {
      toaster.info('Templates come from the server');
      return;
    }
    try {
      final Map<String, dynamic> res = await _api.importTemplate(entity.route);
      final String name =
          (res['filename'] as String?) ?? '${entity.route}_template.csv';
      downloadCsv(name, utf8.decode(base64Decode(res['content'] as String)));
    } on ApiError catch (e) {
      toaster.bad(e.message);
    } catch (e) {
      toaster.bad('Could not fetch the template. $e');
    }
  }

  /// The Form Studio import template, saved to the operator's machine.
  ///
  /// FETCHED, NEVER BUILT HERE, for the same reason
  /// [downloadImportTemplate] is: a template written on this side is a second
  /// copy of the spec. The backend renders it from `constants.FORM_ITEM_KINDS`,
  /// the catalogue publish itself branches on, so a kind this app cannot yet
  /// draw still cannot go missing from the file.
  ///
  /// A SKELETON, NOT A FORM. It carries no questions and no answer keys, so it
  /// is not publishable as downloaded - filling it in is the author's job, and
  /// Publish names whatever is still blank.
  Future<void> downloadFormTemplate() async {
    if (!_live) {
      toaster.info('Templates come from the server');
      return;
    }
    try {
      final Map<String, dynamic> res = await _api.formTemplate();
      final String name =
          (res['filename'] as String?) ?? 'form_studio_import_template.json';
      downloadJsonText(
        name,
        utf8.decode(base64Decode(res['content'] as String)),
      );
      toaster.ok('$name downloaded - fill it in, then import it.');
    } on ApiError catch (e) {
      toaster.bad(e.message);
    } catch (e) {
      toaster.bad('Could not fetch the template. $e');
    }
  }

  /// The columns [entity]'s template carries, read off its header row.
  ///
  /// Used by the import sheet so the list it shows is the list the server
  /// reads. Empty on any failure: a sheet that cannot show the columns is
  /// still a working import, and refusing to open would be worse.
  Future<List<String>> importTemplateColumns(ImportEntity entity) async {
    if (!_live) return const <String>[];
    try {
      final Map<String, dynamic> res = await _api.importTemplate(entity.route);
      final String csv = utf8.decode(base64Decode(res['content'] as String));
      final String header = const LineSplitter().convert(csv).firstOrNull ?? '';
      return header
          .split(',')
          .map((String c) => c.trim())
          .where((String c) => c.isNotEmpty)
          .toList();
    } catch (_) {
      return const <String>[];
    }
  }

  /// Push the generator's vocabulary onto questions authored before it existed.
  ///
  /// The counterpart to [extractTags], and the only way to make an older bank
  /// searchable by tags a later extraction found. Server-only: there is nothing
  /// meaningful to simulate against fixtures whose tags are already coherent.
  Future<void> backfillTags(String genId) async {
    final Generator? g = genById(genId);
    if (g == null) return;
    if (!g.hasTags) {
      toaster.info(
        'Extract the skills first - there is no vocabulary to '
        'apply yet',
      );
      return;
    }
    await _act(
      'Backfill',
      () => _api.backfillTags(genId),
      ifSeed: () => toaster.info('Backfill runs against a live server'),
      okMessage: (_) => 'Re-tagging every question this generator produced',
    );
  }

  /// The live grading pipeline, from the server's own aggregate.
  ///
  /// Not derived from loaded attempts: the lane counts are a filtered
  /// search_count over EVERY submitted attempt, and the `error` lane is the
  /// one INVARIANT 5 says never drains on its own. A console that infers it
  /// from the page it happens to have loaded reports a smaller queue than
  /// exists, which is the reverse of useful.
  Map<String, dynamic> scoring = <String, dynamic>{};

  /// The cross-assessment ranking, as the SERVER ranked it.
  ///
  /// Not derived in the client. The dashboard used to rebuild this from whatever
  /// attempts happened to be cached and dropped every unreleased one, so the
  /// panel read "Nobody can be ranked yet" while the server was returning nine
  /// ranked candidates - and it disagreed with the score distribution printed
  /// beside it.
  List<Map<String, dynamic>> leaderboard = <Map<String, dynamic>>[];

  /// How many candidates the leaderboard COULD have ranked, from the server.
  ///
  /// The route answers `{total, returned, truncated}` beside the rows so a
  /// capped board is never presented as a complete one. Nothing read it, and
  /// the panel's note said "every submitted attempt" whatever the numbers were
  /// - on a cohort past the ceiling that is simply untrue, and it is untrue in
  /// the direction that matters: a candidate absent from the board looks
  /// unranked rather than unshown. 0 means "not fetched yet".
  int leaderboardTotal = 0;
  int leaderboardReturned = 0;
  bool get leaderboardTruncated =>
      leaderboardTotal > 0 && leaderboardReturned < leaderboardTotal;

  /// The server's cohort aggregation. NULL until a live refresh has landed -
  /// seed mode never fetches it - and every reader must fall back to its own
  /// arithmetic in that case rather than rendering zeros over real fixtures.
  CohortAnalytics? analytics;

  /// Live state of the subjective grader, or null when it has not been read.
  ///
  /// SNo 112: `GET /api/v1/scoring` reports a stalled drainer and the error
  /// lane that never retries itself, and nothing in the client read it - so
  /// both were invisible to the admin who has to act on them. Fetched
  /// alongside the analytics because they answer the same question ("is this
  /// cohort finished?") and a second refresh button for it would be a worse
  /// answer than a banner.
  ScoringPipeline? scoringPipeline;

  /// The assessment the analytics and leaderboard currently in memory describe.
  ///
  /// Empty means all-up. Held here rather than on the dashboard because the
  /// two server payloads are STORE state: a screen that re-mounted while a
  /// filter was applied would otherwise read scoped numbers while believing
  /// they were global.
  String analyticsScope = '';

  Future<void> loadLeaderboard({int limit = 2000, String? assessmentId}) async {
    if (!_live) return;
    await withBusy('leaderboard', () async {
      try {
        final ({List<dynamic> rows, Map<String, dynamic> meta}) board =
            await _api.leaderboard(limit: limit, assessmentId: assessmentId);
        leaderboard = <Map<String, dynamic>>[
          for (final Object? r in board.rows)
            if (r is Map<String, dynamic>) r,
        ];
        leaderboardTotal = jval(board.meta, 'total', 0);
        leaderboardReturned = jval(board.meta, 'returned', leaderboard.length);
        notifyListeners();
      } on ApiError catch (e) {
        toaster.bad(e.message);
      }
    });
  }

  /// Re-read the two server-computed payloads for one assessment, or for all.
  ///
  /// WHY BOTH TOGETHER. They are the two halves of one screen and they are
  /// read side by side: refetching the analytics without the leaderboard would
  /// leave a board ranking the whole cohort beside figures describing one
  /// assessment, which is the exact mismatch this method exists to end.
  ///
  /// `analyticsScope` is set BEFORE the awaits and cleared to the requested
  /// value regardless of outcome, so a failed refresh cannot leave the screen
  /// believing the numbers on it are scoped when they are not.
  Future<void> loadAnalyticsScope(String assessmentId) async {
    if (!_live) return;
    final String scope = assessmentId.trim();
    analyticsScope = scope;
    notifyListeners();
    await withBusy('analytics', () async {
      try {
        final Map<String, dynamic> res = await _api.analytics(
          assessmentId: scope.isEmpty ? null : scope,
        );
        analytics = CohortAnalytics.fromJson(res);
      } on ApiError catch (e) {
        toaster.bad(e.message);
      } catch (_) {
        // A shape this build cannot parse is not worth a toast: the screen
        // falls back to its own arithmetic, which is what `analytics == null`
        // already means everywhere that reads it.
        analytics = null;
      }
      // BEST EFFORT, AND SEPARATELY GUARDED. The grading pipeline is a
      // secondary read: a deployment whose scoring route is unavailable must
      // still get its dashboard numbers, so a failure here clears the banner
      // rather than failing the refresh.
      try {
        final Map<String, dynamic> pipe = await _api.scoringPipeline(
          assessmentId: scope.isEmpty ? null : scope,
        );
        scoringPipeline = ScoringPipeline.fromJson(pipe);
      } catch (_) {
        scoringPipeline = null;
      }
      await loadLeaderboard(assessmentId: scope.isEmpty ? null : scope);
      notifyListeners();
    });
  }

  /// Re-read the grading pipeline, and land the phase it reports on the record
  /// it describes.
  ///
  /// ONE HOME FOR THE PHASE. The Kill button's gate, the status banner on the
  /// detail screen and the poll that drives both read `Assessment.scoringPhase`
  /// and nothing else. Parking the polled answer in a second place instead
  /// would have rebuilt the very fault this surface exists to end: two readings
  /// of "is grading running", disagreeing, with the operator left to guess
  /// which one to believe.
  ///
  /// Returns the parsed pipeline as well, because the DRAINER in it is a
  /// property of the machine rather than of this assessment - a stalled cron
  /// stalls every cohort at once - so it has no business being stored on one
  /// record. The detail screen holds it for as long as it is looking at it.
  Future<ScoringPipeline?> loadScoring({String? assessmentId}) async {
    if (!_live) return null;
    ScoringPipeline? out;
    await withBusy('scoring', () async {
      try {
        final Map<String, dynamic> res = await _api.scoring(
          assessmentId: assessmentId,
        );
        final Object? data = res['data'] ?? res;
        final Map<String, dynamic> body = data is Map<String, dynamic>
            ? data
            : <String, dynamic>{};
        // [scoring] IS THE COHORT-WIDE AGGREGATE and says so where it is
        // declared. A scoped read lands one assessment's lane counts, so
        // assigning it here would have put them under an all-up label - and on
        // a five-second tick, permanently.
        if (assessmentId == null) scoring = body;
        final ScoringPipeline pipe = ScoringPipeline.fromJson(body);
        out = pipe;
        // ONLY FOR A SCOPED READ, and only when the server actually named a
        // phase. Cohort-wide the route answers null on purpose, and writing
        // that over a record would erase a phase the detail load had just
        // reported correctly.
        final Assessment? asm = assessmentId == null
            ? null
            : asmById(assessmentId);
        // ONLY ON A CHANGE, the rule `pollGeneration` already follows. This
        // runs every few seconds for as long as a cohort takes to grade, and
        // minting a fresh record on every tick would rebuild the roster under
        // an operator who is in the middle of reading it.
        if (asm != null &&
            pipe.phase != null &&
            (asm.scoringPhase != pipe.phase ||
                asm.scoringSummary != pipe.summary)) {
          assessments = _upsert<Assessment>(
            assessments,
            asm.copyWith(
              scoringPhase: pipe.phase,
              scoringSummary: pipe.summary,
            ),
            (Assessment a) => a.id == asm.id,
          );
        }
        notifyListeners();
      } on ApiError catch (e) {
        toaster.bad(e.message);
      } catch (_) {
        // BEST EFFORT, the same guard `loadAnalyticsScope` puts round its own
        // read of this route, and here it is load-bearing rather than tidy: the
        // detail screen calls this from a periodic timer whose callback nothing
        // awaits, so a shape this build cannot parse would escape as an
        // unhandled async error - invisible in release - and do it again every
        // five seconds. A tick that cannot read the pipeline reports nothing
        // and leaves the phase as it was.
      }
    });
    return out;
  }

  /// Queue everything still waiting, then re-read the pipeline.
  Future<void> queueScoringFor({String? assessmentId}) async {
    await withBusy('scoring:queue', () async {
      await _act(
        'Queue grading',
        () => _api.queueScoring(assessmentId: assessmentId),
        ifSeed: () => toaster.info('Grading runs against a live server'),
        // `_call` has already unwrapped `data`, so `queued` is at the top
        // level. Re-unwrapping is the mistake `envelope_unwrap_test` exists
        // to catch.
        okMessage: (Map<String, dynamic> d) {
          final Object? n = jget(d, 'queued');
          return n is num
              ? 'Queued $n candidate(s) for grading'
              : 'Queued for grading';
        },
      );
    });
    await loadScoring(assessmentId: assessmentId);
  }

  /// Stop this assessment's subjective scoring, then re-read the record.
  ///
  /// KEEPS EVERY SCORE ALREADY STORED, and does not claw back the single LLM
  /// call already in flight - it finishes and is billed. What this settles is
  /// the queue behind it, so an operator who queued a large cohort by mistake
  /// is not left waiting for it to drain and pay for every call. The reload
  /// afterwards is what turns the affected evaluators' pills to `cancelled`.
  Future<void> killScoring(String assessmentId) async {
    await withBusy('scoring:kill:$assessmentId', () async {
      await _act(
        'Kill scoring',
        () => _api.killScoring(assessmentId),
        ifSeed: () => toaster.info('Killing scoring needs a live server'),
        okMessage: (Map<String, dynamic> d) {
          // `settled_count` FIRST, and that is the whole fix. The kill route
          // answers `settled_count` (`admin.py`), so reading `settled` alone
          // never found a number and EVERY kill fell through to the bare
          // sentence - an operator stopping a 700-candidate run got no
          // confirmation of what had actually been stopped, which is the same
          // class of bug as the release toast's `released` / `released_count`.
          // The other two keys stay for any deployment still answering them.
          final Object? n =
              jget(d, 'settledCount') ??
              jget(d, 'settled') ??
              jget(d, 'cancelled');
          // THE QUEUED RE-SCORES THE KILL ALSO DROPS. `action_kill_scoring`
          // clears every `rescore_request_key` on the assessment - the keys
          // only, no mark, state or attempt count moves - so re-queueing them
          // is the recovery, and the operator has to be told there is one to
          // do.
          final Object? cleared = jget(d, 'clearedCount') ?? jget(d, 'cleared');
          final int dropped = cleared is num ? cleared.toInt() : 0;
          // Candidates a lane holds mid-call: the kill stops them at their
          // next call, so they are not "nothing to stop" (R1-05).
          final int held = jval(d, 'heldCount', 0);
          final String drop = <String>[
            if (dropped > 0) '; $dropped queued re-score(s) dropped',
            if (held > 0)
              '; $held being graded now will stop at their next call',
          ].join();
          // ZERO IS A REAL ANSWER: the route counts what THIS kill stopped,
          // not every evaluator the paper has ever parked, so 0 means what
          // Odoo's "Nothing to stop" means.
          if (n is num && n.toInt() == 0) {
            return drop.isEmpty
                ? 'Nothing to stop - no candidate was being graded'
                : 'Stopped grading$drop';
          }
          // CANDIDATES, not answers. `settled_count` is the length of the
          // evaluator set the route parks (`admin.py`), and one candidate
          // carries many answers - so "238 answers" over a 711-person cohort
          // understated a kill by whatever the paper's question count is, and
          // the module's own notification says "candidate(s)" for the same
          // number.
          return n is num
              ? 'Stopped grading - $n candidate(s) settled$drop'
              : 'Stopped grading$drop';
        },
      );
    });
    await loadAssessment(assessmentId);
  }

  ///
  /// The point of the review queue is a human in the loop, and until this
  /// existed the human had no loop: approve as generated, or deny and pay for
  /// another run. A typo now gets fixed in place, and so does a wrong key:
  /// it travels as the axis tree in [dimensions], never as the flat options
  /// and correct-answer pair, which a template-authored draft does not carry.
  ///
  /// True once the server took the save: a refused one keeps the editor
  /// open over what was typed.
  Future<bool> saveDraft(
    String draftId, {
    String? name,
    String? prompt,
    String? description,
    String? difficulty,
    int? timeMinutes,
    String? officialReasoning,
    List<Map<String, dynamic>>? dimensions,
  }) async {
    bool saved = false;
    await withBusy('draft:$draftId', () async {
      await _act(
        'Save',
        () async {
          final Map<String, dynamic> res = await _api.updateDraft(
            draftId,
            name: name,
            prompt: prompt,
            description: description,
            difficulty: difficulty,
            timeMinutes: timeMinutes,
            // The API has accepted this since the route was written; the store
            // had no parameter for it, so no widget could ever reach the wire.
            // A sheet that displays a field nobody can correct is half a fix.
            officialReasoning: officialReasoning,
            dimensions: dimensions,
          );
          saved = true;
          return res;
        },
        ifSeed: () => toaster.info('Editing runs against a live server'),
        okMessage: (_) => 'Draft updated',
      );
    });
    await loadDraft(draftId);
    return saved;
  }

  /// Edit a bank question, including which option is correct.
  ///
  /// Retroactive by design: the module scores against the live key, so
  /// correcting a wrong key corrects the marks of everyone who has already sat
  /// it. That is the reason being able to fix it matters.
  ///
  /// True once the server took the save, and then the question is re-read:
  /// the held key is otherwise the one from before the edit.
  Future<bool> saveBankQuestion(
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
  }) async {
    bool saved = false;
    await withBusy('bank:$questionId', () async {
      await _act(
        'Save',
        () async {
          final Map<String, dynamic> res = await _api.updateBankQuestion(
            questionId,
            name: name,
            prompt: prompt,
            description: description,
            difficulty: difficulty,
            timeMinutes: timeMinutes,
            // Same reason the draft save carries it: the route has accepted it
            // since it was written, and the editor now renders the box on this
            // form too. Without this the box would save on a draft and be
            // dropped on a bank question, which is the bug it just fixed.
            officialReasoning: officialReasoning,
            rubricReviewed: rubricReviewed,
            active: active,
            dimensions: dimensions,
          );
          saved = true;
          return res;
        },
        ifSeed: () => toaster.info('Editing runs against a live server'),
        okMessage: (_) => 'Question updated',
      );
    });
    if (saved) await loadQuestion(questionId);
    return saved;
  }

  /// Free-text steering appended to what the model reads.
  Future<void> saveExtraInstructions(String genId, String text) async {
    final Generator? g = genById(genId);
    if (g == null) return;
    updateGenerator(g.copyWith(sourceText: text));
    await withBusy('instructions:$genId', () async {
      await _act(
        'Save',
        () => _api.updateGenerator(genId, sourceText: text),
        ifSeed: () => toaster.info('Editing runs against a live server'),
        okMessage: (_) => text.trim().isEmpty
            ? 'Extra instructions cleared'
            : 'Extra instructions saved',
        refreshAfter: false,
      );
    });
    await loadGenerator(genId);
  }

  /// Set how many items of each SHAPE to generate, e.g. `{'mcq': 2}`.
  ///
  /// An EMPTY map clears every quota. The total is DERIVED from these rather
  /// than stored separately, so the parts can never disagree with the whole.
  Future<void> setShapeQuotas(String genId, Map<String, int> quotas) async {
    final Generator? g = genById(genId);
    if (g == null) return;
    final Map<String, int> clean = <String, int>{
      for (final MapEntry<String, int> e in quotas.entries)
        if (e.value > 0) e.key: e.value,
    };
    // THE PINNED COUNT FOLLOWS THE PICKS. `sopQuestionCount` is a SECOND
    // stored number, and writing quotas without it left the two disagreeing:
    // removing a task dropped its quota but the count stayed at whatever it
    // had been, so the screen kept insisting on "10 questions" over picks
    // totalling four - and generation, which raises the total to the quota
    // sum but never lowers it, really would have authored six items nobody
    // asked for. Sending the derived total with every quota write is what
    // makes "remove a task" actually reduce the run.
    final int asked = clean.values.fold(0, (int a, int b) => a + b);
    final bool pin = clean.isNotEmpty;
    updateGenerator(
      g.copyWith(
        shapeQuotas: clean,
        sopQuestionCount: pin ? asked : g.sopQuestionCount,
      ),
    );
    await withBusy('quotas:$genId', () async {
      await _act(
        'Per-shape counts',
        () => _api.updateGenerator(
          genId,
          shapeQuotas: clean,
          questionCount: pin ? asked : null,
        ),
        ifSeed: () => toaster.info('Editing runs against a live server'),
        okMessage: (_) => clean.isEmpty
            ? 'The model will choose the mix'
            : _quotaSummary(clean),
        refreshAfter: false,
      );
    });
    await loadGenerator(genId);
  }

  /// "2 MCQ, 3 Rubric" - the examiner's own words back at them.
  String _quotaSummary(Map<String, int> quotas) => quotas.entries
      .map(
        (MapEntry<String, int> e) => e.key.startsWith('template:')
            ? '${e.value} x ${templateById(int.tryParse(e.key.substring(9)) ?? 0)?.name ?? 'task'}'
            : '${e.value} ${QType.parse(e.key).short}',
      )
      .join(', ');

  /// The saved task templates, newest first. Empty until [loadTaskTemplates].
  List<TaskTemplate> taskTemplates = <TaskTemplate>[];

  /// True when the LAST attempt to load the library failed.
  ///
  /// AN EMPTY LIST AND A FAILED LOAD ARE DIFFERENT FACTS, and until this
  /// existed a screen could not tell them apart: `loadTaskTemplates` is quiet by
  /// default and swallows the exception, so a 500 left `taskTemplates` empty and
  /// the Form Studio types tab rendered "7 of 7" as though that were the whole
  /// library. An operator reads that as "my twelve templates were deleted".
  ///
  /// Deliberately a FLAG, not an error string: the screens need to say "we
  /// could not load these" in their own words, and a server message pasted into
  /// a table header is not that.
  bool taskTemplatesFailed = false;

  TaskTemplate? templateById(int id) => taskTemplates
      .cast<TaskTemplate?>()
      .firstWhere((TaskTemplate? t) => t?.id == id, orElse: () => null);

  /// Load the template library.
  ///
  /// QUIET by default: this runs on entering the generator screen and after
  /// every save, and a spinner over a list the operator is already reading is
  /// the flash this codebase has fixed three times.
  Future<void> loadTaskTemplates({bool quiet = true}) async {
    if (!_live) return;
    try {
      // `taskTemplates()` already unwraps the paged envelope - see its own
      // doc comment for why that unwrap belongs in the API layer and not
      // here. Reading `res['data']` in THIS file is exactly the shape
      // `envelope_unwrap_test.dart` guards against.
      // WALKED, not a single page. This was one call at the route's 200-row
      // clamp, so a 201st template was unreachable - and the Form Studio box
      // that searches this list filters it in memory, which meant the search
      // could not find what the load had never fetched. Same shape as the
      // Responses cap, one route along.
      //
      // Bounded at 25 pages (5,000 templates) so a runaway cannot walk
      // forever, and `total` is compared rather than trusted so the loop stops
      // as soon as the server says there is no more.
      final List<dynamic> all = <dynamic>[];
      int total = 0;
      for (int p = 0; p < 25; p++) {
        final ({List<dynamic> rows, int total}) page = await _api.taskTemplates(
          limit: 200,
          offset: p * 200,
        );
        total = page.total;
        all.addAll(page.rows);
        if (page.rows.isEmpty || all.length >= total) break;
      }
      taskTemplates = all
          .whereType<Map<String, dynamic>>()
          .map(TaskTemplate.fromJson)
          .toList();
      // Cleared on success, so a screen that showed the warning stops as soon
      // as a later load works.
      taskTemplatesFailed = false;
      notifyListeners();
    } catch (e, st) {
      // A quiet failure must not destroy the view: the list the operator is
      // reading stays, and they find out on the next deliberate action.
      //
      // But it must not be INVISIBLE either. The flag is set on both paths and
      // notified either way, because the screens read it to say "we could not
      // load these" instead of presenting a short list as complete.
      taskTemplatesFailed = true;
      if (!quiet) _hydrationFailed('loadTaskTemplates', e, st);
      notifyListeners();
    }
  }

  /// Create or update a template. Returns the saved row, or null on failure.
  Future<TaskTemplate?> saveTaskTemplate(TaskTemplate template) async {
    TaskTemplate? saved;
    await withBusy('template:${template.id}', () async {
      await _act(
        'Task template',
        () async {
          // `_call` already unwrapped the envelope: this IS the row.
          final Map<String, dynamic> res = await _api.saveTaskTemplate(
            template.toWire(),
          );
          if (res.isNotEmpty) saved = TaskTemplate.fromJson(res);
          return res;
        },
        ifSeed: () => toaster.info('Editing runs against a live server'),
        okMessage: (_) => 'Saved "${template.name}"',
      );
    });
    if (saved != null) await loadTaskTemplates();
    return saved;
  }

  /// Archive a template, and drop any quota that referenced it.
  ///
  /// Leaving the quota behind would send generation a shape it can no longer
  /// resolve, which the harness reports as an unresolved template - correct, but
  /// a confusing thing to hand an operator who just archived it themselves.
  Future<void> archiveTaskTemplate(int id) async {
    await withBusy('template:$id', () async {
      await _act(
        'Task template',
        () => _api.archiveTaskTemplate(id),
        ifSeed: () => toaster.info('Editing runs against a live server'),
        okMessage: (_) => 'Template archived',
      );
    });
    final String shape = 'template:$id';
    for (final Generator g in generators) {
      if (g.shapeQuotas.containsKey(shape)) {
        final Map<String, int> next = Map<String, int>.of(g.shapeQuotas)
          ..remove(shape);
        await setShapeQuotas(g.id, next);
      }
    }
    await loadTaskTemplates();
  }

  /// Which Draft from SOP press is current, per generator. Stop moves it on,
  /// so a reply to an earlier press is dropped when it finally lands.
  final Map<String, int> _draftRun = <String, int>{};

  /// Stop a Draft from SOP. The button frees at once and the reply is
  /// dropped; the server refuses any further model call for that draft. The
  /// call already on the wire finishes and is billed.
  Future<void> cancelTemplateDraft(String genId) async {
    if (!isBusy('draft:$genId')) return;
    _draftRun[genId] = (_draftRun[genId] ?? 0) + 1;
    _busy.remove('draft:$genId');
    notifyListeners();
    toaster.info('Drafting stopped - nothing was saved');
    if (!_live) return;
    try {
      await _api.cancelTemplateDraft(genId);
    } on ApiError catch (e) {
      toaster.bad(e.message);
    } catch (e) {
      toaster.bad('Stop failed. $e');
    }
  }

  /// Ask the model for a template draft. Returns null when it refused, or
  /// when it was stopped ([cancelTemplateDraft]).
  ///
  /// NOTHING IS SAVED: the caller opens the result in the designer, and only the
  /// admin's own Save persists it.
  Future<TaskTemplate?> draftTaskTemplate(String genId) async {
    TaskTemplate? draft;
    final int run = (_draftRun[genId] ?? 0) + 1;
    _draftRun[genId] = run;
    bool stopped() => _draftRun[genId] != run;
    // Not `withBusy`: a stopped press must not clear the spinner of a newer
    // one when its own reply finally lands.
    _busy.add('draft:$genId');
    notifyListeners();
    try {
      await _act(
        'Draft a task template',
        () async {
          // `_call` already unwrapped the envelope: this IS the draft.
          final Map<String, dynamic> data = await _api.draftTaskTemplate(genId);
          if (stopped()) {
            throw const ApiError('Drafting was stopped.', code: 'cancelled');
          }
          final Map<String, dynamic> res = data;
          if (data.isNotEmpty) {
            // Parsed BEFORE the record is built so the draft carries them:
            // the editor shows a standing notice, and a toast alone was gone
            // the moment it faded - a draft that would generate the wrong
            // thing then opened looking clean.
            final List<String> shapeWarnings = <String>[
              for (final dynamic w
                  in (data['warnings'] ?? const <dynamic>[]) as List<dynamic>)
                if (w.toString().trim().isNotEmpty) w.toString().trim(),
            ];
            draft = TaskTemplate(
              // id 0: unsaved. The designer creates it on Save.
              id: 0,
              name: (data['name'] ?? 'Untitled task').toString(),
              instructions: (data['instructions'] ?? '').toString(),
              response: (data['response'] ?? 'single_choice').toString(),
              structure:
                  (data['structure'] ?? const <dynamic>[]) as List<dynamic>,
              itemCount: (data['item_count'] as num?)?.toInt() ?? 0,
              // The brief the model wrote for the plate its media items need.
              // Dropped here once, which meant a draft that correctly chose a
              // media kind still arrived with an empty brief and the examiner
              // had to write it from scratch - the editor shows this field for
              // exactly those primitives.
              mediaBrief: (data['media_brief'] ?? '').toString(),
              shapeWarnings: shapeWarnings,
              authoredBy: 'llm_edited',
              originId: (data['origin_id'] as num?)?.toInt(),
            );
            final List<dynamic> warnings =
                (data['warnings'] ?? const <dynamic>[]) as List<dynamic>;
            // SURFACED, NOT SWALLOWED: the admin fixes these in the designer.
            // Dropping the flagged items instead would lose authored content.
            for (final dynamic w in warnings) {
              toaster.info(w.toString());
            }
          }
          return res;
        },
        ifSeed: () => toaster.info('Drafting runs against a live server'),
        okMessage: (_) => 'Draft ready - edit it, then save',
        // Stopped here: [cancelTemplateDraft] already said so.
        asks: (ApiError e) => stopped(),
      );
    } finally {
      if (!stopped()) {
        _busy.remove('draft:$genId');
        notifyListeners();
      }
    }
    return draft;
  }

  /// Replace the whole allowed-type set.
  ///
  /// The route is idempotent by design - it takes the full list rather than a
  /// toggle, because a toggle needs both sides to agree on the current state
  /// and they will not after any concurrent edit.
  Future<void> setAllowedTypes(String genId, List<QType> types) async {
    final Generator? g = genById(genId);
    if (g == null) return;
    // CANONICAL ORDER ON THE OPTIMISTIC WRITE, and this is what stops the
    // picker shaking when a type is chosen.
    //
    // The picker appends the new type to the end of the list it already holds,
    // which is the obvious thing for a caller to do. `loadGenerator` below then
    // replaces the record with the server's copy, and the server returns the
    // types in its own fixed order - so a type that sorts early arrived at the
    // right-hand end of the row, the refetch landed a moment later, and EVERY
    // chip slid sideways to make room for it. Measured in a browser with the
    // refetch delayed: `Rubric > Video > MCQ` at 313ms, `MCQ > Rubric > Video`
    // at 1771ms.
    //
    // Sorting here makes the optimistic frame and the server's frame identical,
    // so the refetch changes nothing anyone can see. Dropping the refetch
    // instead would trade a visible shake for a record that silently disagrees
    // with the server about its own derived fields.
    updateGenerator(g.copyWith(allowedTypes: _inTypeOrder(types)));
    await withBusy('types:$genId', () async {
      await _act(
        'Question Types',
        () => _api.setQuestionTypes(genId, g.typeCodes(types)),
        ifSeed: () => toaster.info('Editing runs against a live server'),
        okMessage: (_) => types.isEmpty
            ? 'The model will choose the type for each question'
            : '${types.length} question type(s) allowed',
        refreshAfter: false,
      );
    });
    await loadGenerator(genId);
  }

  /// [types] in the order the SERVER lists them, which is [QType.generatable].
  ///
  /// A type outside that list keeps its place at the end rather than being
  /// dropped: this exists to stop the row jumping, and silently losing a type
  /// would be a far worse way to achieve that.
  List<QType> _inTypeOrder(List<QType> types) {
    int rank(QType t) {
      final int i = QType.generatable.indexOf(t);
      return i < 0 ? QType.generatable.length : i;
    }

    return <QType>[...types]
      ..sort((QType a, QType b) => rank(a).compareTo(rank(b)));
  }

  /// "Select all" - load every type, or clear back to "the model decides".
  ///
  /// NOT the module's `select_all_types` field. That is a momentary trigger
  /// whose own help says "it resets immediately": ticking it in Odoo loads
  /// every type into the allow-list and then clears itself. Writing it over
  /// the API therefore looked like it did nothing, because it had already
  /// undone itself by the time anything read it back. The real effect is the
  /// allow-list, so that is what this writes.
  Future<void> selectAllTypes(String genId, bool all) =>
      setAllowedTypes(genId, all ? QType.generatable : const <QType>[]);

  Future<void> archiveGenerator(String genId, {bool archive = true}) async {
    final Generator? g = genById(genId);
    if (g == null) return;
    await withBusy('archive:$genId', () async {
      await _act(
        archive ? 'Archive' : 'Restore',
        () => _api.archiveGenerator(genId, archive: archive),
        ifSeed: () => toaster.info('Archiving runs against a live server'),
        okMessage: (_) => archive
            ? '${g.name} archived. Its questions stay in the bank.'
            : '${g.name} restored',
      );
    });
  }

  /// Archive or restore several generators: the list's selection bar. One
  /// call per generator - the route is per-record - but one toast and one
  /// refresh for the lot.
  Future<void> archiveGenerators(
    List<String> ids, {
    bool archive = true,
  }) async {
    if (ids.isEmpty) return;
    final String n = '${ids.length} generator${ids.length == 1 ? '' : 's'}';
    await _act(
      archive ? 'Archive' : 'Restore',
      () async {
        for (final String id in ids) {
          await _api.archiveGenerator(id, archive: archive);
        }
        return <String, dynamic>{};
      },
      ifSeed: () => toaster.info('Archiving runs against a live server'),
      okMessage: (_) => archive
          ? '$n archived. Their questions stay in the bank.'
          : '$n restored',
    );
  }

  /// Archive an assessment, or restore one with `archive: false`.
  ///
  /// ALLOWED IN ANY STATE, including a sitting that is in progress. Archiving
  /// is a SUSPEND and not a cancel: the row leaves the default list and every
  /// dashboard figure, and the crons stop picking it up - no more LLM scoring,
  /// no more invitations, no more expiry - but nothing a candidate has done is
  /// touched and no work is thrown away. The queue columns are left exactly as
  /// they were, so they ARE the saved state and [archive]`: false` resumes from
  /// them. Cancelling is the control that ENDS a sitting; this one pauses it.
  ///
  /// [confirmLiveAttempts] is the operator's explicit yes to archiving a paper
  /// people are sitting RIGHT NOW. The route refuses that without it, because
  /// stopping the clock under a live cohort is almost always a mistake - see
  /// `_confirmArchiveLiveSitting` on the detail screen for the sentence they
  /// read first. This layer never sets it on its own.
  /// Answers 0 when it is done - and the NUMBER MID-SITTING when the route
  /// refused because of them, so the caller can ask that question and come
  /// back. Not `_act`, which reports a refusal as a toast and returns nothing:
  /// `live_attempts` is a question, and a toast is a dead end an operator
  /// cannot answer. Every other failure is still a toast, because there is
  /// nothing to ask.
  Future<int> archiveAssessment(
    String asmId, {
    bool archive = true,
    bool confirmLiveAttempts = false,
  }) async {
    final Assessment? a = asmById(asmId);
    if (a == null) return 0;
    if (!_live) {
      toaster.info('Archiving runs against a live server');
      return 0;
    }
    return withBusy('archive:$asmId', () async {
      try {
        await _api.archiveAssessment(
          asmId,
          archive: archive,
          confirmLiveAttempts: confirmLiveAttempts,
        );
      } on ApiError catch (e) {
        if (e.code == 'live_attempts') {
          // Nothing was written: the route refuses before it archives.
          return e.intField('live_attempt_count', 1);
        }
        toaster.bad(e.message);
        return 0;
      } catch (e) {
        toaster.bad('${archive ? 'Archive' : 'Restore'} failed. $e');
        return 0;
      }
      _replaceAsm(a.copyWith(active: !archive));
      toaster.ok(
        archive
            ? '${a.name} archived. Its results are kept.'
            : '${a.name} restored',
      );
      await refresh(background: true);
      return 0;
    });
  }

  /// Step ONE of deleting an assessment: archive it, and ask the server what
  /// destroying it would cost. Null when the step did not happen.
  ///
  /// NOTHING IS DESTROYED HERE. The route archives the paper - which stops the
  /// scoring, the invitations and the exam clock, and reverses cleanly - and
  /// then refuses with `confirm_required`, carrying the counts. That refusal is
  /// the answer, not a failure: [AssessmentDeletePlan] is built from it and is
  /// what the second sheet states before anybody presses the last button.
  ///
  /// Reporting the counts this way rather than from the client's own fields is
  /// the same rule the question-bank delete follows: the sentence an operator
  /// confirms and the work that follows it must be computed by the same code.
  /// A list row's `assignedCount` can be stale or absent (-1) and would be a
  /// guess dressed as a fact on the one sheet that must not guess.
  ///
  /// [confirmLiveAttempts] answers the OTHER question - interrupting people
  /// mid-sitting - which the route asks first and separately, because it is
  /// the archive that stops their clock. Until it is answered the plan comes
  /// back with [AssessmentDeletePlan.needsLiveConfirm] set and nothing has
  /// been archived.
  Future<AssessmentDeletePlan?> planAssessmentDelete(
    String asmId, {
    bool confirmLiveAttempts = false,
  }) async {
    final Assessment? a = asmById(asmId);
    if (a == null) return null;
    if (!_live) {
      toaster.info('Deleting runs against a live server');
      return null;
    }
    return withBusy('delete:$asmId', () async {
      try {
        // A 200 means the route destroyed it without being asked to, which it
        // will not do without `confirm_name`. Treated as the plan being
        // unavailable rather than pretended away.
        await _api.deleteAssessment(
          asmId,
          confirmLiveAttempts: confirmLiveAttempts,
        );
        await refresh(background: true);
        return null;
      } on ApiError catch (e) {
        if (e.code == 'live_attempts') {
          return AssessmentDeletePlan(
            liveAttemptCount: e.intField('live_attempt_count', 1),
          );
        }
        if (e.code != 'confirm_required') {
          toaster.bad(e.message);
          return null;
        }
        // IT IS ARCHIVED NOW. Said locally so the screen behind the sheet
        // agrees with the server - an operator who reads the numbers and backs
        // out is left looking at a suspended paper, and the button beside the
        // one they pressed has to offer Restore rather than Archive.
        if (e.fields['archived'] == true) {
          _replaceAsm(a.copyWith(active: false));
        }
        return AssessmentDeletePlan(
          candidateCount: e.intField('candidate_count'),
          responseCount: e.intField('response_count'),
          ledgerRowsKept: e.intField('llm_usage_kept'),
        );
      } catch (e) {
        toaster.bad('Delete failed. $e');
        return null;
      }
    });
  }

  /// Step TWO: destroy it. True when the record is really gone.
  ///
  /// NOT `_act`, and the return value is the reason. `_act` swallows a refusal
  /// into a toast and answers nothing, and the caller navigates away from the
  /// record on success - so a refused delete handled that way would walk the
  /// operator off a screen whose assessment is still there, having just been
  /// told it was gone.
  ///
  /// The name is echoed back because the route asks for it instead of a
  /// boolean: a flag can be re-sent by a retry or a copied payload with nobody
  /// reading what it applies to, and this is the one call here that cannot be
  /// undone.
  ///
  /// The rows are dropped locally rather than waiting for the refresh, because
  /// the list the operator lands on is rebuilt from `assessments` on the next
  /// frame and would otherwise show the deleted paper until the fetch
  /// answered. The LLM spend is NOT dropped: the ledger keeps its rows against
  /// a null evaluator and the day's budget still counts them, which is what
  /// the confirmation promised.
  Future<bool> destroyAssessment(String asmId) async {
    final Assessment? a = asmById(asmId);
    if (a == null) return false;
    if (!_live) {
      toaster.info('Deleting runs against a live server');
      return false;
    }
    return withBusy('delete:$asmId', () async {
      try {
        await _api.deleteAssessment(asmId, confirmName: a.name);
      } on ApiError catch (e) {
        toaster.bad(e.message);
        return false;
      } catch (e) {
        toaster.bad('Delete failed. $e');
        return false;
      }
      assessments = assessments.where((Assessment x) => x.id != asmId).toList();
      attempts = attempts
          .where((Attempt t) => t.assessmentId != asmId)
          .toList();
      notifyListeners();
      toaster.warn('${a.name} deleted.');
      await refresh(background: true);
      return true;
    });
  }

  // ══════════════════════════════════════════════════════════════════════
  //  Deleting
  //
  //  "Delete" means TAKE IT OUT OF THE BANK, and the server decides whether
  //  that can be an erase. A question an assessment uses, or that anybody has
  //  answered, is RETIRED: the row survives, the paper keeps listing it and
  //  the answers stay attached - it simply leaves the bank and can never be
  //  picked again. Only a question nothing points at is really deleted.
  //
  //  The client never makes that decision and never guesses at it. It asks for
  //  a PREVIEW, shows the operator exactly what the server intends, and then
  //  sends the same call for real. Deciding locally would mean the sentence
  //  somebody confirmed and the work that followed were computed by two
  //  different pieces of code.
  // ══════════════════════════════════════════════════════════════════════

  /// What deleting [ids] would do. Null when there is no backend to ask.
  Future<DeletePreview?> previewQuestionDelete(List<String> ids) async {
    if (!_live || ids.isEmpty) return null;
    try {
      return DeletePreview.fromQuestions(
        await _api.bankDeletePreview(ids),
        ids.length,
      );
    } on ApiError catch (e) {
      toaster.bad(e.message);
      return null;
    }
  }

  Future<DeletePreview?> previewGeneratorDelete(List<String> ids) async {
    if (!_live || ids.isEmpty) return null;
    try {
      return DeletePreview.fromGenerators(
        await _api.generatorDeletePreview(ids),
        ids.length,
      );
    } on ApiError catch (e) {
      toaster.bad(e.message);
      return null;
    }
  }

  /// Take questions out of the bank. [ids] may be one or many.
  Future<void> deleteQuestions(List<String> ids) async {
    if (ids.isEmpty) return;
    await _act(
      'Delete',
      () => _api.bankDelete(ids),
      ifSeed: () {
        bank = bank.where((Question q) => !ids.contains(q.id)).toList();
        toaster.ok('${ids.length} removed from the bank');
        notifyListeners();
      },
      // The server's own counts, not a guess: how many were erased and how
      // many had to be kept is the one thing the operator could not have known
      // before pressing it.
      okMessage: (Map<String, dynamic> res) =>
          DeletePreview.fromQuestions(res, ids.length).outcomeSentence,
    );
  }

  /// Archive questions, or restore them with [archive] false. Never erases:
  /// that is [deleteQuestions], behind its own button and sheet.
  Future<void> archiveQuestions(List<String> ids, {bool archive = true}) async {
    if (ids.isEmpty) return;
    final String n = '${ids.length} question${ids.length == 1 ? '' : 's'}';
    await _act(
      archive ? 'Archive' : 'Restore',
      () => _api.bankArchive(ids, archive: archive),
      ifSeed: () => toaster.info('Archiving runs against a live server'),
      okMessage: (_) => archive
          ? '$n archived. Restore puts ${ids.length == 1 ? 'it' : 'them'} '
                'back.'
          : '$n back in the bank',
    );
  }

  /// Put a retired question back in the bank.
  Future<void> restoreQuestion(String id) async {
    await _act(
      'Restore',
      () => _api.bankRestore(id),
      ifSeed: () => toaster.info('Restoring runs against a live server'),
      okMessage: (_) => 'Back in the bank',
    );
  }

  /// Delete generators. Their questions leave the bank under the same rule.
  ///
  /// A generator an assessment points at is ARCHIVED rather than erased - the
  /// row survives with every question it authored retired - so the toast has
  /// to name what happened to the generators AND what happened to their
  /// questions. `outcomeSentence` counts only the questions, which is why this
  /// reads `generatorOutcomeSentence`: sending five generators away used to
  /// report whatever number of questions they happened to hold.
  Future<void> deleteGenerators(List<String> ids) async {
    if (ids.isEmpty) return;
    await _act(
      'Delete',
      () => _api.generatorDelete(ids),
      ifSeed: () {
        generators = generators
            .where((Generator g) => !ids.contains(g.id))
            .toList();
        toaster.ok(
          '${ids.length} generator${ids.length == 1 ? '' : 's'} deleted',
        );
        notifyListeners();
      },
      okMessage: (Map<String, dynamic> res) => DeletePreview.fromGenerators(
        res,
        ids.length,
      ).generatorOutcomeSentence,
    );
  }

  /// Re-run the hybrid similarity ranking for one generator.
  ///
  /// Guarded on having a source, matching what the route refuses: ranking
  /// reads the SOP text, so pressing this on a generator with nothing attached
  /// spends nothing and achieves nothing.
  Future<void> rankSimilarity(String genId) async {
    final Generator? g = genById(genId);
    if (g == null) return;
    await withBusy('similarity:$genId', () async {
      await _act(
        'Ranking',
        () => _api.rankSimilarity(genId),
        ifSeed: () => toaster.info('Ranking runs against a live server'),
        okMessage: (_) =>
            'Ranked this generator against the library by meaning',
      );
    });
  }

  /// Replace one image slot on a draft question.
  ///
  /// [image] is whatever the file picker produced - bare base64 or a `data:`
  /// URL. The route normalises both, so no caller has to remember which.
  Future<void> applyUploadedImage(
    String draftId, {
    required String image,
    String slot = 'a',
  }) async {
    if (image.isEmpty) {
      toaster.info('Choose an image first');
      return;
    }
    await withBusy('image:$draftId', () async {
      await _act(
        'Apply image',
        () => _api.applyUploadedImage(draftId, image: image, slot: slot),
        ifSeed: () => toaster.info('Uploading runs against a live server'),
        okMessage: (_) => 'Slot ${slot.toUpperCase()} now uses your image',
      );
    });
  }

  /// Re-attempt only the clips that failed on a draft.
  ///
  /// Guarded on the failure states rather than always offered: a retry on a
  /// draft whose clips all rendered would re-spend on Veo for the same result,
  /// and a button that bills money for nothing is worse than a disabled one.
  Future<void> retryVideo(String draftId) async {
    final Question? d = drafts
        .where((Question q) => q.id == draftId)
        .firstOrNull;
    if (d == null) return;
    if (d.videoState != AssetState.failed &&
        d.videoState != AssetState.partial) {
      toaster.info('Nothing to retry - no clip on this draft has failed');
      return;
    }
    await _act(
      'Retry',
      () => _api.retryVideo(draftId),
      ifSeed: () => toaster.info('Video retry runs against a live server'),
      okMessage: (_) => 'Re-queued the failed clips',
    );
  }

  /// Send a draft whose image failed back to the image queue. Guarded the way
  /// [retryVideo] is: only a failed draft has anything to retry.
  Future<void> retryDraftImages(String draftId) async {
    final Question? d = drafts
        .where((Question q) => q.id == draftId)
        .firstOrNull;
    if (d == null) return;
    if (d.imageState != AssetState.failed) {
      toaster.info('Nothing to retry - this draft has no failed image');
      return;
    }
    await _act(
      'Retry',
      () => _api.retryDraftImages(draftId),
      ifSeed: () => toaster.info('Image retry runs against a live server'),
      okMessage: (_) =>
          'Re-queued the failed images - the next image batch picks them up',
    );
  }

  /// [retryDraftImages] for every failed draft of one generator.
  Future<void> retryFailedImages(String genId) => withBusy(
    'retryimages:$genId',
    () => _act(
      'Retry',
      () => _api.retryFailedImages(genId),
      ifSeed: () => toaster.info('Image retry runs against a live server'),
      okMessage: (Map<String, dynamic> r) {
        final int n = jval(r, 'retried', 0);
        return 'Re-queued the images on $n draft${n == 1 ? '' : 's'} - the '
            'next image batch picks them up';
      },
    ),
  );

  /// One generator's run, from the light `/progress` route - see
  /// [GenerationProgress]. Null offline or when the read fails.
  ///
  /// QUIET BY DESIGN, unlike [loadScoring]: the generator screen calls this on
  /// a timer, so a failure toasting would repeat every tick. A tick that
  /// cannot read keeps what is already on screen.
  Future<GenerationProgress?> loadGenerationProgress(String genId) async {
    if (!_live) return null;
    try {
      return GenerationProgress.fromJson(await _api.generationProgress(genId));
    } catch (_) {
      return null;
    }
  }

  /// Re-read ONE generator and its drafts, quietly, for the generator screen's
  /// watch when its run moves. The drafts of every other generator are kept;
  /// only this one's are replaced, since `/drafts` answers pending rows only
  /// and a decided draft has left the list for good.
  Future<void> reloadGeneration(String genId) async {
    if (!_live) return;
    try {
      final List<Map<String, dynamic>> rows = await _allPages(
        (int l, int o) => _api.drafts(generatorId: genId, limit: l, offset: o),
      );
      drafts = <Question>[
        ...drafts.where((Question d) => d.genId != genId),
        ..._mergeQuestions(drafts, rows),
      ];
      notifyListeners();
    } catch (_) {
      // Quiet: the rows on screen stay; the next move of the run tries again.
    }
    await loadGenerator(genId);
  }

  /// Recompute a draft's answer key from its stored generation payload.
  ///
  /// The recovery path for a key that drifted from its source. Rebuilt
  /// deterministically rather than retyped, so the key stays provable by
  /// construction rather than by a reviewer's memory.
  Future<void> rebuildAnswerKey(String draftId) => _act(
    'Rebuild',
    () => _api.rebuildAnswerKey(draftId),
    ifSeed: () => toaster.info('Answer-key rebuild runs against a live server'),
    okMessage: (_) => 'Answer key rebuilt from the generation payload',
  );

  Future<void> startGeneration(String genId) async {
    final Generator? g = genById(genId);
    if (g == null) return;
    if (g.isGenerating) {
      toaster.info('Already generating');
      return;
    }
    if (!g.hasTags) {
      toaster.warn('Extract the skills first - generation needs them');
      return;
    }
    // A TASK TEMPLATE QUOTA IS ENOUGH ON ITS OWN.
    //
    // This used to demand a legacy question type even when the operator had
    // committed `T2I x2` - a shape that already names its own question type,
    // which is exactly what the server widens the allow-list for. The server
    // accepts an empty list (it means Auto, logged as "any (model picks)"), so
    // this was the only thing standing in the way, and it refused a run the
    // backend would have completed.
    if (g.allowedTypes.isEmpty && g.shapeQuotas.isEmpty) {
      toaster.warn('Pick at least one question type, or a task to generate');
      return;
    }

    if (_live) {
      // The module writes drafts and moves its own sop_gen_state; the local
      // job list below is the seed's animation, not a real queue.
      await _act(
        'Generate',
        () => _api.generateQuestions(genId),
        optimistic: () =>
            updateGenerator(g.copyWith(sopGenState: GenState.queued)),
        okMessage: (_) => 'Generation started - drafts will appear for review',
      );
      // Not awaited: the caller is a button handler, and the poll runs for as
      // long as the cron takes. Awaiting here would keep the press "in
      // flight" for minutes; the store notifies listeners as states change.
      unawaited(pollGeneration());
      return;
    }

    updateGenerator(g.copyWith(sopGenState: GenState.queued));
    jobs = <Job>[
      Job(
        id: 'JOB-${jobs.length + 1}',
        genId: genId,
        name: 'Generating questions',
        state: JobState.running,
        progress: 4,
        meta: '0 / ${g.plannedCount}',
        detail: 'Reading the SOP. Drafts appear as each batch lands.',
        want: g.plannedCount,
      ),
      ...jobs,
    ];
    toaster.ok('Generation queued - drafts land in the review queue');
    notifyListeners();
    _startJobTicker();
  }

  /// Stop a generator's Extract skills run. Same optimistic flag as
  /// [cancelGeneration]: the screen shows "Stopping..." until the server
  /// settles it, then the poll carries it to Cancelled.
  Future<void> cancelTagExtract(String genId) async {
    final Generator? g = genById(genId);
    if (g == null) return;
    if (!g.canCancelTagExtract) {
      toaster.info('This generator is not extracting skills');
      return;
    }
    await _act(
      'Stop extract skills',
      () => _api.cancelTagExtract(genId),
      optimistic: () =>
          updateGenerator(g.copyWith(tagExtractCancelRequested: true)),
      rollback: () =>
          updateGenerator(g.copyWith(tagExtractCancelRequested: false)),
      ifSeed: () => toaster.info('Stopping needs a live server'),
    );
    unawaited(pollGeneration());
  }

  /// Stop a generator's run. Costs nothing, and keeps whatever it produced.
  ///
  /// OPTIMISTIC ON `cancelRequested`, NOT ON THE STATE. The run stops at its
  /// next model call, which can be a call away, so claiming `cancelled` here
  /// would show a finished run over one that is still going. Flipping the
  /// flag instead is honest and is what the screen needs: it swaps the Kill
  /// button for "Stopping...", so the press is visibly acknowledged without
  /// asserting an outcome that has not happened.
  ///
  /// The poll below is re-armed because the generator is still busy - it is
  /// what carries the screen from "Stopping..." to "Cancelled" when the
  /// checkpoint actually fires.
  Future<void> cancelGeneration(String genId) async {
    final Generator? g = genById(genId);
    if (g == null) return;
    if (!g.canCancelGeneration) {
      toaster.info('Nothing is running for this generator');
      return;
    }
    await _act(
      'Kill generation',
      () => _api.cancelGeneration(genId),
      optimistic: () => updateGenerator(g.copyWith(cancelRequested: true)),
      rollback: () => updateGenerator(g.copyWith(cancelRequested: false)),
      ifSeed: () => toaster.info('Killing a run needs a live server'),
    );
    unawaited(pollGeneration());
  }

  /// Poll until every queued generation finishes.
  ///
  /// The module generates on a cron, so `startGeneration` returns `queued`
  /// and the drafts appear some seconds later. Without this the screen sits
  /// on "queued" until the user reloads, which reads as "nothing happened".
  ///
  /// Stops on its own: when no generator is still queued or running, when the
  /// cap is reached, or when the store is disposed. It refreshes only on a
  /// STATE CHANGE, so a slow generation does not repaint the list every two
  /// seconds.
  Future<void> pollGeneration({
    Duration every = const Duration(seconds: 2),
    int maxTicks = 90,
  }) async {
    if (!_live || _polling) return;
    _polling = true;
    // WAIT FOR THE DRAFTS FIRST. They are fetched outside the blocking load now
    // (see `_loadDraftsInBackground`), and this loop decides whether to keep
    // watching by reading their asset states - so starting before they land
    // would see nothing rendering and return on the first tick, leaving the
    // Drafts list on "Pending" until the operator clicked into a row. That is
    // the very bug this poll exists to fix, so the two changes have to know
    // about each other. No-op when nothing is outstanding.
    await draftsSettled();
    try {
      // Both server-side jobs, not just question generation: tag extraction
      // moved to the same cron, and polling only `sopGenState` left an
      // extraction running with nothing watching it, so the tags appeared
      // only if the operator happened to reload.
      //
      // ASSET RENDERS TOO. Image and video rendering runs on its OWN cron that
      // finishes AFTER generation reports `done`, so a poll that watched only
      // the two generator states stopped while drafts were still rendering: the
      // Drafts list sat on "Pending" assets until the operator clicked into a
      // draft, whose detail fetch returned `rendered` and made the list look
      // wrong rather than stale. The draft states are in the fingerprint as
      // well, so a render finishing repaints the list on its own.
      // `cancelRequested` is in the fingerprint for the same reason the states
      // are: a kill landing is a change the screen must repaint for, and it
      // moves this flag before it moves any state.
      String fingerprint() =>
          '${generators.map((Generator g) => '${g.id}:${g.sopGenState.name}:'
              '${g.tagExtractState.name}:${g.cancelRequested}').join(',')}'
          '|'
          '${drafts.map((Question d) => '${d.id}:${d.imageState?.wire ?? '-'}:'
              '${d.videoState?.wire ?? '-'}').join(',')}';

      for (int tick = 0; tick < maxTicks; tick++) {
        // Read each tick, so a screen taking a generator over ends this loop
        // on its next pass - see [screenWatchedGenerators].
        final bool generating = generators.any(
          (Generator g) =>
              (g.sopGenState.isBusy &&
                  !screenWatchedGenerators.contains(g.id)) ||
              g.isExtractingTags,
        );
        // A draft whose assets have not settled is still work in flight, even
        // once its generator says done.
        final bool rendering = drafts.any(
          (Question d) =>
              !screenWatchedGenerators.contains(d.genId) &&
              (d.imageState == AssetState.pending ||
                  d.imageState == AssetState.rendering ||
                  d.videoState == AssetState.pending ||
                  d.videoState == AssetState.rendering),
        );
        if (!generating && !rendering) return;
        // A RENDER THAT NEVER MOVES MUST NOT HOLD THIS LOOP OPEN.
        //
        // `rendering` is true while any draft sits at `pending`, and a draft
        // whose render cron failed sits there permanently - stage has four. So
        // with nothing generating, this loop ran its full 90 ticks every time
        // any admin action started it, forever. Waiting on an asset is worth a
        // short watch, not the whole budget: past this point only a live
        // generation keeps polling, and a stalled render is left for the
        // Drafts screen to show as pending.
        if (!generating && tick >= _assetOnlyTicks) return;

        await Future<void>.delayed(every);
        if (_disposed) return;

        final String before = fingerprint();
        // ONLY THE TWO LISTS THIS LOOP WATCHES, never a full `refresh()`.
        //
        // This is what made stage slow. `refresh()` reloads EVERY admin list,
        // and one of them - `/responses` - is unbounded: at 31,462 rows its
        // walk was 158 sequential POSTs. Calling it on a 2-second tick meant a
        // sustained 813 requests a minute against a route this loop does not
        // even read, for as long as the loop ran.
        //
        // The fingerprint is built from `generators` and `drafts` alone, so
        // those are the only two that have to be current for the tick to
        // decide anything. Refreshing the rest was pure cost.
        await _pollGenerationLists();
        if (_disposed) return;
        // Nothing moved: no repaint, no toast, just wait for the next tick.
        if (fingerprint() == before) continue;
      }
    } finally {
      _polling = false;
    }
  }

  /// Re-read ONLY the generators and drafts, for [pollGeneration]'s tick.
  ///
  /// Deliberately not `refresh()`: see the note at the call site. Merged, never
  /// assigned, for the same reason `_loadAdmin` merges - a list row is a strict
  /// subset of a detail row, and assigning it wholesale erases what a detail
  /// screen has hydrated.
  Future<void> _pollGenerationLists() async {
    final List<List<Map<String, dynamic>>> res =
        await Future.wait(<Future<List<Map<String, dynamic>>>>[
          _allPages(
            (int l, int o) =>
                _api.generators(limit: l, offset: o, includeArchived: true),
          ),
          _allPages((int l, int o) => _api.drafts(limit: l, offset: o)),
        ]);
    generators = _mergeGenerators(generators, res[0]);
    drafts = _mergeQuestions(drafts, res[1]);
    notifyListeners();
  }

  /// Drive the fixture job list.
  ///
  /// Started when a job is queued in fixture mode and stopped as soon as
  /// nothing is running, so an idle store holds no timer.
  void _startJobTicker() {
    if (_live || _jobTicker != null) return;
    _jobTicker = Timer.periodic(const Duration(milliseconds: 400), (Timer t) {
      if (_disposed || !advanceJobs()) {
        t.cancel();
        _jobTicker = null;
      }
    });
  }

  /// Advance every running job. Returns whether anything changed, so the
  /// ticker can stop once everything has settled.
  ///
  /// FIXTURE MODE ONLY. Against a live backend the module's cron owns
  /// generation, and progress is whatever the server reports in
  /// `sop_gen_state` - a client-side counter would invent a percentage that
  /// no longer corresponds to anything. [pollGeneration] is the live path.
  bool advanceJobs() {
    if (_live) return false;
    bool changed = false;
    final List<Job> next = <Job>[];
    for (final Job j in jobs) {
      if (j.state != JobState.running) {
        next.add(j);
        continue;
      }
      final int p = (j.progress + 3).clamp(0, 100);
      changed = changed || p != j.progress;
      if (p >= 100) {
        if (j.kind == JobKind.generate && !j.landed) {
          _landDrafts(j);
          next.add(
            j.copyWith(
              state: JobState.done,
              progress: 100,
              meta: '${j.want} / ${j.want}',
              detail: '${j.want} drafts created and queued for review.',
              landed: true,
            ),
          );
          final Generator? g = genById(j.genId);
          if (g != null) {
            generators = generators
                .map(
                  (Generator x) => x.id == g.id
                      ? x.copyWith(
                          sopGenState: GenState.done,
                          questionCount: x.questionCount + j.want,
                        )
                      : x,
                )
                .toList();
          }
        } else {
          next.add(
            j.copyWith(
              state: JobState.done,
              progress: 100,
              meta: '17 / 17',
              detail: 'All images rendered.',
            ),
          );
        }
      } else {
        next.add(
          j.copyWith(
            progress: p,
            meta: j.kind == JobKind.generate
                ? '${(p * j.want / 100).round()} / ${j.want}'
                : j.meta,
          ),
        );
      }
    }
    jobs = next;
    return changed;
  }

  void _landDrafts(Job j) {
    final Generator? g = genById(j.genId);
    if (g == null) return;
    drafts = <Question>[
      ...drafts,
      ...SeedData.generateDrafts(g, j.want, drafts.length),
    ];
  }

  void retryJob(String jobId) {
    jobs = jobs
        .map(
          (Job j) => j.id == jobId
              ? j.copyWith(
                  state: JobState.running,
                  progress: 67,
                  detail: 'Retrying clip 3 only.',
                )
              : j,
        )
        .toList();
    toaster.info('Retrying the failed clip');
    notifyListeners();
  }

  /// Attach a SOP document to a generator.
  ///
  /// Step 1 of the question-bank flow, and the one everything else waits on:
  /// `extractTags` and `startGeneration` both refuse until a generator has a
  /// document, because the module sends the SOP natively to the model and
  /// authors the questions straight from it.
  ///
  /// THE ONLY UPLOAD PATH. Creating a generator collects a name and nothing
  /// else, so every SOP in the product arrives through here - from the corpus
  /// tab, which is the one screen that offers it.
  Future<void> uploadResource(
    String genId, {
    required String name,
    required List<int> bytes,
    String category = 'sop',
  }) async {
    if (!_live) {
      toaster.info('Uploads need a live backend');
      return;
    }
    await _act(
      'Upload',
      () => _api.uploadResource(
        genId,
        name: name,
        bytes: bytes,
        category: category,
      ),
      okMessage: (Map<String, dynamic> d) {
        final Map<String, dynamic>? r = d['resource'] as Map<String, dynamic>?;
        final Object? err = r?['extraction_error'];
        if (err is String && err.isNotEmpty) {
          // Surfaced rather than swallowed: the file uploaded, but the model
          // will read nothing from it, so saying "uploaded" alone would be
          // misleading.
          return '$name attached, but text extraction failed: $err';
        }
        return '$name attached - extract skills next';
      },
    );
    // See removeResource: only the DETAIL route knows the file list changed.
    // Without this the toast said "attached" and the corpus grid did not move
    // until the operator reloaded the page.
    await loadGenerator(genId);
  }

  Future<void> removeResource(String genId, String resourceId) async {
    await _act(
      'Remove',
      () => _api.deleteResource(genId, resourceId),
      okMessage: (_) => 'Document removed',
    );
    // Re-read the DETAIL. The merge in `_loadAdmin` stops a list refresh from
    // erasing `resources`, but it cannot invent the change either - it
    // preserves what was already held. Only the detail route knows the file
    // list changed, so an upload or a delete has to ask for it.
    await loadGenerator(genId);
  }

  void fixResource(String genId, String resId) {
    final Generator? g = genById(genId);
    if (g == null) return;
    updateGenerator(
      g.copyWith(
        resources: g.resources
            .map(
              (Resource r) => r.id == resId
                  ? r.copyWith(
                      status: ResourceStatus.ready,
                      clearError: true,
                      pages: r.pages > 0 ? r.pages : 14,
                    )
                  : r,
            )
            .toList(),
      ),
    );
    toaster.ok('File replaced - text extracted');
  }

  // ══════════════════════════════════════════════════════════════════════
  //  Settings and governance
  // ══════════════════════════════════════════════════════════════════════

  /// Write the five governance numbers the server allows.
  ///
  /// `/api/v1/settings/update` allow-lists exactly these keys and refuses the
  /// rest, so this is deliberately not a general settings writer: models, S3
  /// and prompts stay read-only because changing them from here would diverge
  /// from what the Odoo settings form validates.
  ///
  /// The spend caps are the reason this exists at all - a run-away generation
  /// bill is bounded by a number nobody could change without opening Odoo.
  Future<void> saveGovernance(Map<String, num> values) async =>
      saveSettings(values);

  /// Write any allow-listed setting by its SHORT key.
  ///
  /// The route validates the whole payload before its first write, so a
  /// refusal is total and the screen never has to reason about a half-applied
  /// save. Only the keys present are touched: an omitted secret keeps what is
  /// stored, which is what lets a form that shows "set" rather than the value
  /// itself save the fields around it without wiping the credential.
  ///
  /// Re-reads afterwards. `updated` echoes only what changed, and a secret
  /// comes back as a BOOLEAN by design, so the screen cannot rebuild its own
  /// state from the response - it has to ask the server what the settings now
  /// are, which is also how a value the server normalised gets shown.
  /// [labels]: the screen's name for each key, by key. The route's refusal
  /// starts with the key it refused ("scoring_shards must be ..."), and the
  /// operator is shown the field's own label instead (RT-3).
  Future<void> saveSettings(
    Map<String, Object> values, {
    Map<String, String> labels = const <String, String>{},
  }) async {
    if (!_live) {
      toaster.info('Saving settings needs a live backend');
      return;
    }
    await withBusy(
      'settings',
      () => _act(
        'Save',
        () => _api.updateSettings(values),
        okMessage: (_) => 'Settings saved',
        asks: (ApiError e) {
          final String? key = labels.keys
              .where((String k) => e.message.startsWith('$k '))
              .firstOrNull;
          if (key == null) return false;
          toaster.bad('${labels[key]}${e.message.substring(key.length)}');
          return true;
        },
      ),
    );
    await reloadSettings();
  }

  /// Replace the Vertex service account from a file the operator picked.
  ///
  /// [bytes] empty CLEARS the credential. The route validates that the file
  /// really is a service-account key before storing it, so a wrong download
  /// (an OAuth client, an API key) is refused by name here rather than
  /// surfacing an hour later as an opaque 401 on a generation run.
  Future<void> uploadServiceAccount(List<int> bytes, String filename) async {
    if (!_live) {
      toaster.info('Uploading credentials needs a live backend');
      return;
    }
    await withBusy(
      'settings',
      () => _act(
        'Upload',
        () => _api.uploadServiceAccount(
          content: bytes.isEmpty ? '' : base64Encode(bytes),
          filename: filename,
        ),
        okMessage: (Map<String, dynamic> d) => d['cleared'] == true
            ? 'Service account removed'
            : 'Service account updated - ${d['client_email'] ?? filename}',
      ),
    );
    await reloadSettings();
  }

  /// Re-read `/api/v1/settings` on its own.
  ///
  /// A full `refresh()` would do it too, but it also re-fetches nine other
  /// lists to show one panel the result of its own Save - and the settings
  /// screen is the one place where that round trip is the whole interaction.
  Future<void> reloadSettings() async {
    if (!_live) return;
    try {
      final Map<String, dynamic> body = await _api.settings();
      final Object? cfg = body['data'] ?? body;
      if (cfg is Map<String, dynamic>) {
        settings = cfg;
        notifyListeners();
      }
    } on ApiError catch (e, st) {
      // A failed re-read leaves the previous values on screen, which is right:
      // the write already succeeded, and blanking the form would suggest it
      // had not.
      _hydrationFailed('reloadSettings', e, st);
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  Tags
  // ══════════════════════════════════════════════════════════════════════

  /// Odoo's "Normalize Tags": ask the model to consolidate the vocabulary
  /// across generators, folding spelling variants into one canonical tag.
  ///
  /// The endpoint and the client method have both existed since the port with
  /// nothing calling them, so the console could show that 42 tags contain
  /// near-duplicates and offer no way to do anything about it.
  ///
  /// Costs an LLM call, so it is scoped to the generators that actually carry
  /// tags rather than firing at everything.
  Future<void> normalizeTags() async {
    if (!_live) {
      toaster.info('Normalising tags needs a live backend');
      return;
    }
    final List<String> ids = generators
        .where((Generator g) => g.hasTags)
        .map((Generator g) => g.id)
        .toList();
    if (ids.isEmpty) {
      toaster.info('No generator has tags to normalise yet');
      return;
    }
    await withBusy(
      'normalizetags',
      () => _act(
        'Normalize',
        () => _api.normalizeTags(ids),
        okMessage: (_) =>
            'Vocabulary normalised across ${ids.length} '
            'generator${ids.length == 1 ? '' : 's'}',
      ),
    );
  }

  Future<void> mergeTag(String name) async {
    final Tag? t = tags.where((Tag x) => x.name == name).firstOrNull;
    if (t?.mergeInto == null) return;
    final String target = t!.mergeInto!;

    if (_live) {
      // By id, not name: the server merges RECORDS, and two tags can display
      // the same text once normalised.
      final Tag? canonical = tags
          .where((Tag x) => x.name == target)
          .firstOrNull;
      if (canonical == null || canonical.id.isEmpty || t.id.isEmpty) {
        toaster.bad('Cannot merge - the tag has no server id');
        return;
      }
      await _act(
        'Merge',
        () => _api.mergeTags(targetId: canonical.id, sourceIds: <String>[t.id]),
        okMessage: (_) => 'Merged into $target',
      );
      return;
    }

    tags = tags
        .map(
          (Tag x) => x.name == target ? x.copyWith(uses: x.uses + t.uses) : x,
        )
        .where((Tag x) => x.name != name)
        .toList();
    toaster.ok('Merged into $target');
    notifyListeners();
  }

  Future<void> mergeAllTags() async {
    final List<Tag> dupes = tags.where((Tag t) => !t.isCanonical).toList();

    if (_live) {
      // One call per canonical target rather than one per duplicate: the
      // route takes a list of sources, and a merge is a write that reindexes
      // every question carrying the tag.
      final Map<String, List<String>> bySource = <String, List<String>>{};
      for (final Tag d in dupes) {
        final Tag? canonical = tags
            .where((Tag x) => x.name == d.mergeInto)
            .firstOrNull;
        if (canonical == null || canonical.id.isEmpty || d.id.isEmpty) continue;
        bySource.putIfAbsent(canonical.id, () => <String>[]).add(d.id);
      }
      if (bySource.isEmpty) {
        toaster.info('Nothing to merge');
        return;
      }
      await _act('Merge', () async {
        for (final MapEntry<String, List<String>> e in bySource.entries) {
          await _api.mergeTags(targetId: e.key, sourceIds: e.value);
        }
        return <String, dynamic>{};
      }, okMessage: (_) => 'Near-duplicates merged');
      return;
    }

    for (final Tag d in dupes) {
      tags = tags
          .map(
            (Tag x) =>
                x.name == d.mergeInto ? x.copyWith(uses: x.uses + d.uses) : x,
          )
          .toList();
    }
    tags = tags.where((Tag t) => t.isCanonical).toList();
    toaster.ok('Near-duplicates merged');
    notifyListeners();
  }

  void setPortal(Portal p) {
    portal = p;
    notifyListeners();
  }
}

/// One answer, with everything needed to render a row without a second lookup.
class AnswerRef {
  final Attempt ev;
  final Assessment asm;
  final Question q;
  final Response r;

  const AnswerRef({
    required this.ev,
    required this.asm,
    required this.q,
    required this.r,
  });

  /// A terminal grader error a person can still reset - not one on a
  /// cancelled paper, which the server will not re-score.
  bool get isRescorableError =>
      r.llmState == LlmState.error && asm.state != AsmState.cancelled;
}
