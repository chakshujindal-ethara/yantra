import 'dart:async';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';

import 'assessment/data/api_client.dart';
import 'yantra_launch.dart' show rememberYantraReturn;

/// Who is signed in, and the client that speaks for them.
///
/// WHY THIS EXISTS. In the host portal the assessment feature was handed an
/// already-authenticated client: the portal signed you in, and
/// `AssessmentSection` borrowed `host.ApiClient.instance.accessToken`. This app
/// has no host, so it owns the session itself.
///
/// It deliberately holds NO business rules. The role is whatever
/// `/api/v1/auth/me` reports; the client never asks for one and never infers
/// it. That matters: a client-chosen role is a client-editable role, and the
/// entire difference between the operator console and the candidate portal
/// rests on the server's answer.
class Session extends ChangeNotifier {
  Session({ApiClient? api, Future<void> Function(Duration)? sleep})
    : api = api ?? ApiClient(),
      _sleep = sleep ?? Future<void>.delayed;

  /// The single client for the whole app. Long-lived so the bearer token it
  /// captures at sign-in is the same one every later call uses.
  final ApiClient api;

  /// The wait between [restore]'s tries while the server is not answering.
  /// A test swaps it so it does not wait real seconds.
  final Future<void> Function(Duration) _sleep;

  bool _busy = false;
  String? _error;
  String _name = '';
  String _email = '';
  String _uid = '';
  String _role = '';

  /// `access_role` from `/api/v1/auth/me` - `none`/`candidate`/`manager`/
  /// `admin`, matching the Odoo user form's own dropdown. Null when the backend
  /// does not send it, which the store reads as "no restriction".
  String? _accessRole;

  /// `capabilities` from the same payload: what this account may CHANGE. Null
  /// when absent, for the same reason.
  Set<String>? _capabilities;
  bool _signedIn = false;

  bool get busy => _busy;
  String? get error => _error;

  /// The HTTP status behind [error], or null when the failure never reached a
  /// server. Carried out of [signIn] alongside the sentence because a refusal
  /// is two facts, not one: WHAT the server said, and WHAT KIND of refusal it
  /// was. 429 is the kind the form has to act on.
  int? _errorStatus;
  int? get errorStatus => _errorStatus;

  /// Seconds left before the front door will accept another attempt; 0 when
  /// there is no cooldown.
  ///
  /// WHY THIS IS STATE AND NOT A SENTENCE. On 2026-09-17 the gateway started
  /// answering a rate-limited sign-in with 429 and `Retry-After: 60`, saying in
  /// so many words that the password was not the problem. The client parsed the
  /// header into [ApiError.retryAfter] and then dropped it on the floor: only
  /// `e.message` survived. So [busy] went false on the same frame, Sign in went
  /// live again, and "Forgot password?" sat right underneath with nothing
  /// stopping it - 679 password resets were sent for a problem no password
  /// could fix. The form needs to ASK whether it may try again, and a caller
  /// that has to grep [error] for the word "seconds" is a caller that will get
  /// it wrong the first time the server rewords itself.
  int _cooldown = 0;
  int get cooldownSeconds => _cooldown;

  /// Counted down rather than measured against a deadline, so a widget test can
  /// drive it with `tester.pump` and so there is exactly one place the value
  /// changes. The cost is that a backgrounded browser tab, whose timers are
  /// throttled, counts down slower than the wall clock - which errs toward
  /// waiting too long rather than knocking too early, and the server enforces
  /// the real limit regardless.
  Timer? _cooldownTimer;

  String get name => _name;

  /// The signed-in user's email, from `session_user`. Carried through to
  /// `AppStore.meEmail`: the exam instructions page names the candidate whose
  /// sitting it is, and for a candidate on an invitation link this is the only
  /// source - the exam state envelope has no applicant block.
  String get email => _email;
  String get uid => _uid;

  /// The SERVER's word on what this user is. Fed straight to
  /// `AppStore.adoptSession`, which turns it into a [Portal].
  String get role => _role;
  String? get accessRole => _accessRole;
  Set<String>? get capabilities => _capabilities;
  bool get signedIn => _signedIn;

  /// True while the app is deciding whether a stored token is still good.
  ///
  /// The login form must not paint during this window: showing it and then
  /// replacing it with the console a moment later is the flash that made a
  /// refresh look like a sign-out even once the session was restored.
  bool _restoring = false;
  bool get restoring => _restoring;

  /// True while [restore] waits to ask again a server that did not answer.
  bool _reconnecting = false;
  bool get reconnecting => _reconnecting;

  /// Completed by [stopReconnecting]; ends [restore]'s wait.
  Completer<void>? _stopWaiting;

  /// Stop waiting and show the sign-in form. The saved tokens stay, so a
  /// reload tries them again.
  void stopReconnecting() {
    final Completer<void>? stop = _stopWaiting;
    if (stop != null && !stop.isCompleted) stop.complete();
  }

  /// Resume a session left by a previous page load.
  ///
  /// A browser refresh restarts the Dart VM, so the bearer token held in
  /// [ApiClient] vanished and the app showed the login form over a session the
  /// server still considered open. The token now outlives the reload in
  /// sessionStorage; this asks the server to confirm it.
  ///
  /// VERIFIED, never trusted. Stored bytes say nothing about whether the token
  /// is still valid - it may have expired, been revoked, or belong to a user
  /// whose groups changed. `/auth/me` is the same call sign-in uses, so a
  /// restored session and a fresh one arrive at the role by one path. A refusal
  /// tries the refresh token once, and asks for a password only when the
  /// gateway retires it (its 401) or there is none.
  ///
  /// A SERVER THAT DOES NOT ANSWER IS NOT A REFUSAL. No answer, a 5xx, a 429,
  /// or the 404 Odoo serves on every route while its database is unusable
  /// keeps both tokens and asks again (2, 4, 8, 16, then every 30 s, each
  /// +-25%) while [restoring] keeps the login form off screen and
  /// [reconnecting] says why. Signing a whole room out because a pod
  /// restarted is the bug this replaced (SEB review #7).
  Future<bool> restore() async {
    if (!api.restoreTokens()) return false;

    _restoring = true;
    notifyListeners();
    try {
      // Each verified restore restarts the idle window, so the stored session
      // measures time since the app was last USED rather than since the bearer
      // last rotated. Opening a second tab is a use.
      final bool? resumed = await _resumeWhenReachable();
      if (resumed ?? false) {
        api.touchStoredSession();
        return true;
      }
      // Stopped waiting ([stopReconnecting]): the tokens stay for a reload.
      if (resumed == null) return false;
      await api.logout();
      return false;
    } catch (_) {
      // The sign-out above found no server, or a reply could not be read:
      // the login form at least states the problem.
      return false;
    } finally {
      _restoring = false;
      _reconnecting = false;
      _stopWaiting = null;
      notifyListeners();
    }
  }

  /// Yantra: sign in with a one-time launch ticket instead of a password.
  ///
  /// [onGrant] runs once the ticket is redeemed and BEFORE [signedIn] flips,
  /// so the caller can point the app at the sitting before the console is
  /// built. Shows [Resuming] meanwhile, like [restore]. A refusal leaves the
  /// person signed out with a sentence that sends them back to Yantra for a
  /// fresh link; the ticket cannot be tried twice.
  Future<bool> launch(
    String ticket, {
    void Function(LaunchGrant grant)? onGrant,
  }) async {
    _restoring = true;
    _error = null;
    _errorStatus = null;
    notifyListeners();
    try {
      final LaunchGrant grant = await api.redeemLaunchTicket(ticket);
      rememberYantraReturn(grant.returnUrl);
      onGrant?.call(grant);
      if (await _adoptWhoAmI()) {
        api.touchStoredSession();
        return true;
      }
      final ApiError? refused = _whoAmIError;
      _error = refused == null
          ? 'Signed in, but this account has no assessment role.'
          : 'Signed in, but the server refused the session: '
                '${refused.message}';
      _errorStatus = refused?.status;
      await api.logout();
      return false;
    } on ApiError catch (e) {
      _error = _launchRefusal(e);
      _errorStatus = e.status;
      return false;
    } finally {
      _restoring = false;
      notifyListeners();
    }
  }

  static String _launchRefusal(ApiError e) => switch (e.code) {
    'ticket_used' =>
      'This link has already been used. Go back to Yantra and open the '
          'assessment again for a new one.',
    'ticket_expired' =>
      'This link has expired. Go back to Yantra and open the assessment '
          'again for a new one.',
    'invalid_ticket' =>
      'This link is not valid. Go back to Yantra and open the assessment '
          'again.',
    'account_inactive' =>
      'Your assessment account is not active. Ask your Yantra contact.',
    _ => '${e.message} Go back to Yantra and try again.',
  };

  /// Whether the stored token, or its refresh, still opens a session. Waits
  /// out a server that is not answering instead of taking that for a no;
  /// null when the person stopped waiting.
  Future<bool?> _resumeWhenReachable() async {
    const List<int> backoff = <int>[2, 4, 8, 16, 30];
    for (int n = 0; ; n++) {
      try {
        if (await _verified()) return true;
        // Expired access token, live refresh token: the usual case for a tab
        // left open overnight. One renewal attempt, then the password.
        if (await api.refreshSession()) return await _verified();
        // Only the gateway's 401 retires the refresh token. Still held, the
        // renewal got no verdict (its 400 crash page, a 403, the HTML 404 of
        // a database that is down), so it is asked again like no answer.
        if (!api.canRenew) return false;
      } on ApiError catch (e) {
        if (!_noAnswer(e)) rethrow;
      }
      final Completer<void> stop = _stopWaiting ??= Completer<void>();
      _reconnecting = true;
      notifyListeners();
      final int s = backoff[n < backoff.length ? n : backoff.length - 1];
      await Future.any(<Future<void>>[
        _sleep(Duration(seconds: s) * (0.75 + 0.5 * Random().nextDouble())),
        stop.future,
      ]);
      if (stop.isCompleted) return null;
    }
  }

  /// No verdict on the token: nothing answered, the server was down or shed
  /// the call, or Odoo had no database to route it to (an HTML 404).
  static bool _noAnswer(ApiError e) => e.isRetryable || e.status == 404;

  /// [_adoptWhoAmI], but a check that got no answer is thrown, not read as
  /// "not signed in".
  Future<bool> _verified() async {
    if (await _adoptWhoAmI()) return true;
    final ApiError? e = _whoAmIError;
    if (e != null && _noAnswer(e)) throw e;
    return false;
  }

  /// Ask the server who this token belongs to and adopt the answer.
  Future<bool> _adoptWhoAmI() async {
    _whoAmIError = null;
    try {
      final Map<String, dynamic> me = await api.whoAmI();
      final Object? user = me['user'];
      final Map<String, dynamic> u = user is Map<String, dynamic>
          ? user
          : const <String, dynamic>{};
      final String role = (u['role'] ?? '').toString();
      // No role means the module does not recognise this user, whatever the
      // token says. Treat it as not signed in rather than opening a console
      // with no permissions behind it.
      if (role.isEmpty) return false;

      _name = (u['name'] ?? '').toString();
      _email = (u['email'] ?? '').toString();
      _uid = (u['uid'] ?? '').toString();
      _role = role;
      // WHICH RUNG, AND WHAT MAY BE CHANGED. `role` above is binary and reports
      // "admin" for the read-only Manager too, because both belong in the
      // operator console - so it cannot narrow anything on its own. These two
      // are what tell them apart, and both are the SERVER's answer: every route
      // re-checks its own group, so nothing here is a permission, only what is
      // worth drawing.
      //
      // Absent on a backend that predates them, which is why the store treats
      // null as full access rather than none.
      _accessRole = u.containsKey('access_role')
          ? (u['access_role'] ?? '').toString()
          : null;
      final Object? caps = u['capabilities'];
      _capabilities = caps is List
          ? caps.map((Object? c) => (c ?? '').toString()).toSet()
          : null;
      _signedIn = true;
      return true;
    } on ApiError catch (e) {
      _whoAmIError = e;
      return false;
    }
  }

  /// Why the last [_adoptWhoAmI] could not ask, as opposed to being told
  /// "no role", so a refused `/auth/me` - an expired token, say - is not
  /// reported as a missing role.
  ApiError? _whoAmIError;

  /// Sign in, then ask the server who that turned out to be.
  ///
  /// Two calls, not one, and on purpose. `/api/v1/auth_token` proves the
  /// password and returns a bearer token; `/api/v1/auth/me` reports the role
  /// under the module's own rules. The token response carries a `user_role`
  /// too, but that is the gateway's view of an ORG role - a portal candidate is
  /// not in any workflow group, so trusting it would hand a candidate the
  /// operator console. `/auth/me` is the module's own answer and is the one
  /// that decides which portal opens.
  Future<bool> signIn(String login, String password) async {
    _busy = true;
    _error = null;
    _errorStatus = null;
    notifyListeners();

    try {
      await api.login(login, password);
      // Same call the restore path uses, so a fresh session and a resumed one
      // reach the role by one route rather than two that can drift.
      if (await _adoptWhoAmI()) {
        _startCooldown(null);
        return true;
      }
      final ApiError? refused = _whoAmIError;
      _error = refused == null
          ? 'Signed in, but this account has no assessment role.'
          : 'Signed in, but the server refused the session: '
                '${refused.message}';
      _errorStatus = refused?.status;
      return false;
    } on ApiError catch (e) {
      // The module's own sentence, not one written here: it explains a refusal
      // far better than a generic "sign in failed" can. EXCEPT a wrong
      // password: the gateway's 400 overwrites its own sentence with Odoo's
      // raw `str(AccessDenied())` (`utility.return_Response`), which tells a
      // candidate nothing they can act on.
      _error = e.status == 400 && e.message == 'Access Denied'
          ? 'Wrong email or password.'
          : e.message;
      // ...AND THE REFUSAL'S TERMS, which the sentence alone cannot carry. See
      // [cooldownSeconds]: this is the half of the 2026-09-17 fix that lives on
      // the client. The server half - 429 plus `Retry-After` plus a message
      // saying the password is not at fault - only reaches the user if the form
      // can gate on it.
      _errorStatus = e.status;
      _startCooldown(e.retryAfter);
      return false;
    } catch (e) {
      _error = 'Could not reach the server. $e';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Arm, re-arm or clear the sign-in cooldown.
  ///
  /// A null [d] clears it, and that is the ONLY thing an absent, zero, negative
  /// or unparseable `Retry-After` can produce: `parseRetryAfter` has already
  /// turned all four into null, so there is no path here that can mint an
  /// infinite or absurd wait out of a header we could not trust. The ceiling on
  /// a header we CAN trust is that parser's too (300s).
  void _startCooldown(Duration? d) {
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    _cooldown = d?.inSeconds ?? 0;
    if (_cooldown <= 0) {
      _cooldown = 0;
      return;
    }
    // EXPIRES ON ITS OWN. Nothing else ticks this down - no frame callback, no
    // later request - so without this timer the door would stay shut until the
    // user reloaded the page, which is the same dead end the bug produced, only
    // in the other direction.
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      _cooldown--;
      if (_cooldown <= 0) {
        _cooldown = 0;
        t.cancel();
        _cooldownTimer = null;
      }
      notifyListeners();
    });
  }

  @override
  void dispose() {
    // A periodic timer holding `this` outlives the widget tree otherwise, which
    // in a test is the "a Timer is still pending" failure and in the app is a
    // notify against a disposed notifier.
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    super.dispose();
  }

  Future<void> signOut() async {
    try {
      // At most 2 s: a stalled connection must not keep the shell up.
      await api.logout().timeout(const Duration(seconds: 2));
    } catch (_) {
      // A failed logout still ends the LOCAL session. Staying signed in
      // because the server did not answer is worse than dropping a token the
      // server will expire on its own.
    }
    _signedIn = false;
    _name = '';
    _email = '';
    _uid = '';
    _role = '';
    notifyListeners();
  }
}
