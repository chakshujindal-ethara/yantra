import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../core/errors.dart';
import 'browser.dart';
import 'keycloak.dart';
import 'pkce.dart';
import 'token_store.dart';
import 'tokens.dart';

/// What the gateway client needs from the session: a bearer token, a way to get a fresh one, and a way
/// to say the session is dead.
abstract class TokenProvider {
  /// A usable access token, refreshed first if it is about to expire. Null when signed out.
  Future<String?> accessToken();

  /// A token refreshed right now (the gateway said the last one was bad). Null when refresh is impossible.
  Future<String?> refreshedAccessToken();

  /// The gateway refused even a refreshed token: drop the session.
  Future<void> authLost();
}

enum SessionState { loading, signedOut, signedIn }

/// Why the last session ended: the person signed out, or the tokens could not be renewed. The login
/// screen explains the second.
enum SessionEnd { user, expired }

/// Holds the token pair; refreshes lazily; persists through [TokenStore]; runs the Keycloak redirect
/// sign-in (authorization code + PKCE) through [Browser].
class Session extends ChangeNotifier implements TokenProvider {
  /// [rotationGrace]: how long a refused refresh waits, three times, for another tab's rotated token to reach the store
  /// before signing out. Refresh tokens are single use, so two tabs refreshing together leave one refused; the winner
  /// writes its new token a moment later.
  Session({
    required KeycloakAuth auth,
    required TokenStore store,
    required AppConfig config,
    Browser? browser,
    DateTime Function()? clock,
    Duration rotationGrace = const Duration(milliseconds: 400),
  }) : this._(auth, store, config, browser ?? platformBrowser(), clock ?? DateTime.now, rotationGrace);

  Session._(this._auth, this._store, this._config, this._browser, this._clock, this._rotationGrace);

  final Duration _rotationGrace;

  static const attemptKey = 'yantra.pkce';
  static const nextKey = 'yantra.next';

  final KeycloakAuth _auth;
  final TokenStore _store;
  final AppConfig _config;
  final Browser _browser;
  final DateTime Function() _clock;

  Tokens? _tokens;
  SessionState _state = SessionState.loading;
  Future<Tokens?>? _refreshing;
  String? _redirectError;
  SessionEnd? _lastEnd;

  SessionState get state => _state;

  /// Why the previous session ended; cleared by the next sign-in.
  SessionEnd? get lastEnd => _lastEnd;
  Tokens? get tokens => _tokens;
  String get username => _tokens?.username ?? '';
  String get subject => _tokens?.subject ?? '';

  /// Realm roles off the token; empty when signed out.
  Set<String> get roles => _tokens?.roles ?? const {};
  AppConfig get config => _config;

  /// Whether "Continue with Keycloak" can work here (a real browser).
  bool get canRedirect => _browser.canRedirect;

  /// Why the last redirect sign-in failed, shown once on the login screen.
  String? get redirectError => _redirectError;

  /// Remembers the page a signed-out person was going to, in per-tab storage so it survives the
  /// Keycloak redirect; [takeNext] hands it back once after sign-in.
  void rememberNext(String location) => _browser.write(nextKey, location);

  /// Leaves the app for [url] in this tab: the exam app (Assessment v2) through a one-time signed-in link.
  void openExternal(Uri url) => _browser.navigate(url);

  String? takeNext() {
    final next = _browser.read(nextKey);
    if (next != null) _browser.write(nextKey, null);
    return next;
  }

  /// Restores a stored session, or finishes a redirect sign-in when the page URL carries Keycloak's answer.
  Future<void> restore() async {
    final callback = AuthCallback.parse(_browser.currentUri());
    if (callback != null) {
      await _completeRedirect(callback);
      return;
    }
    try {
      _tokens = await _store.read();
    } on Object {
      _tokens = null; // unreadable storage: sign in again rather than spin forever
    }
    _set(_tokens == null ? SessionState.signedOut : SessionState.signedIn);
  }

  Future<void> login(String username, String password) async {
    final tokens = await _auth.login(username, password);
    await _store.write(tokens);
    _tokens = tokens;
    _redirectError = null;
    _lastEnd = null;
    _set(SessionState.signedIn);
  }

  /// Leaves for Keycloak's sign-in page. The verifier waits in per-tab storage for the way back; when
  /// that storage is blocked the redirect could never complete, so it is not started.
  void beginRedirectLogin() {
    final attempt = PkceAttempt.generate();
    _browser.write(attemptKey, attempt.encode());
    if (_browser.read(attemptKey) != attempt.encode()) {
      _redirectError = 'This browser blocks site storage, which the sign-in needs. Allow it for this site and try again.';
      notifyListeners();
      return;
    }
    _redirectError = null;
    _browser.navigate(attempt.authorizeUri(_config, _browser.redirectUri()));
  }

  Future<void> _completeRedirect(AuthCallback callback) async {
    final attempt = PkceAttempt.decode(_browser.read(attemptKey));
    _browser.write(attemptKey, null);
    _browser.replaceUrl(_browser.redirectUri());
    if (callback.error.isNotEmpty) {
      _redirectError = 'Sign-in was cancelled (${callback.error})';
    } else if (attempt == null) {
      _redirectError = 'Sign-in could not be completed in this tab. Please try again.';
    } else if (attempt.state != callback.state) {
      _redirectError = 'Sign-in did not match this tab. Please try again.';
    } else {
      try {
        final tokens = await _auth.exchangeCode(code: callback.code, verifier: attempt.verifier, redirectUri: _browser.redirectUri());
        await _store.write(tokens);
        _tokens = tokens;
        _redirectError = null;
        _lastEnd = null;
        _set(SessionState.signedIn);
        return;
      } on AppException catch (e) {
        _redirectError = e.message;
      }
    }
    _tokens = null;
    _set(SessionState.signedOut);
  }

  Future<void> logout() async {
    final refresh = _tokens?.refreshToken ?? '';
    _tokens = null;
    _lastEnd = SessionEnd.user;
    await _store.write(null);
    _set(SessionState.signedOut);
    await _auth.logout(refresh);
  }

  @override
  Future<String?> accessToken() async {
    final current = _tokens;
    if (current == null) return null;
    if (!current.isExpiring(now: _clock())) return current.accessToken;
    return (await _refresh())?.accessToken;
  }

  @override
  Future<String?> refreshedAccessToken() async => (await _refresh())?.accessToken;

  @override
  Future<void> authLost() async {
    if (_tokens != null) _lastEnd = SessionEnd.expired;
    _tokens = null;
    await _store.write(null);
    _set(SessionState.signedOut);
  }

  /// One refresh at a time; concurrent callers share it.
  Future<Tokens?> _refresh() {
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    final run = _doRefresh().whenComplete(() => _refreshing = null);
    _refreshing = run;
    return run;
  }

  /// Refreshes with the newest refresh token on record: another tab may have rotated it since this one
  /// read it. A refusal is final only when the store holds nothing newer; a sign-out that happened
  /// meanwhile wins over the refreshed tokens.
  Future<Tokens?> _doRefresh() async {
    final current = _tokens;
    if (current == null) return null;
    final stored = await _store.read();
    final using = stored ?? current;
    if (using.refreshToken.isEmpty) return null;
    try {
      final fresh = await _auth.refresh(using.refreshToken);
      if (_tokens == null) return null; // signed out while refreshing: never resurrect the session
      await _store.write(fresh);
      _tokens = fresh;
      return fresh;
    } on LoginFailedException {
      for (var attempt = 0; attempt < 3; attempt++) {
        final latest = await _store.read();
        if (latest != null && latest.refreshToken.isNotEmpty && latest.refreshToken != using.refreshToken) {
          _tokens = latest; // another tab rotated the token after we read it; use theirs
          return _doRefresh();
        }
        if (_tokens == null) return null; // signed out meanwhile
        await Future<void>.delayed(_rotationGrace);
      }
      await authLost();
      return null;
    }
  }

  void _set(SessionState s) {
    _state = s;
    notifyListeners();
  }
}
