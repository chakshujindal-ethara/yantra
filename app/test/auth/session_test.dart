import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/auth/browser.dart';
import 'package:yantra_app/auth/keycloak.dart';
import 'package:yantra_app/auth/pkce.dart';
import 'package:yantra_app/auth/session.dart';
import 'package:yantra_app/auth/token_store.dart';
import 'package:yantra_app/auth/tokens.dart';

import '../support/fake_backend.dart';

const logoutPath = '/realms/yantra/protocol/openid-connect/logout';

void main() {
  Session make(FakeBackend backend, MemoryTokenStore store, {DateTime Function()? clock, MemoryBrowser? browser}) => Session(
    auth: KeycloakAuth(client: backend.client, config: testConfig),
    store: store,
    config: testConfig,
    browser: browser ?? MemoryBrowser(),
    clock: clock,
    rotationGrace: const Duration(milliseconds: 20),
  );

  test('restore reads the stored tokens and signs in', () async {
    final store = MemoryTokenStore()..write(liveTokens());
    final session = make(FakeBackend(), store);
    expect(session.state, SessionState.loading);
    await session.restore();
    expect(session.state, SessionState.signedIn);
    expect(session.username, 'worker1');
    expect(session.subject, 'worker-1');
  });

  test('an expiring access token is refreshed before use and persisted', () async {
    final backend = FakeBackend({'POST $tokenPath': (_) => json(tokenResponse(access: 'fresh', refresh: 'r2'))});
    final store = MemoryTokenStore()..write(Tokens(accessToken: 'stale', refreshToken: 'r1', expiresAt: DateTime(2026, 1, 1, 12, 0, 10)));
    final session = make(backend, store, clock: () => DateTime(2026, 1, 1, 12));
    await session.restore();
    expect(await session.accessToken(), 'fresh');
    expect((await store.read())?.refreshToken, 'r2');
    expect(backend.requests, hasLength(1));
  });

  test('a token that is still good is used without a refresh', () async {
    final backend = FakeBackend();
    final store = MemoryTokenStore()..write(liveTokens(access: 'good'));
    final session = make(backend, store);
    await session.restore();
    expect(await session.accessToken(), 'good');
    expect(backend.requests, isEmpty);
  });

  test('a refused refresh signs the worker out', () async {
    final backend = FakeBackend({
      'POST $tokenPath': (_) => json({'error': 'invalid_grant'}, status: 400),
    });
    final store = MemoryTokenStore()..write(liveTokens());
    final session = make(backend, store);
    await session.restore();
    expect(await session.refreshedAccessToken(), isNull);
    expect(session.state, SessionState.signedOut);
    expect(await store.read(), isNull);
  });

  test('logout clears the store and ends the Keycloak session with the refresh token', () async {
    final backend = FakeBackend({'POST $logoutPath': (_) => json({}, status: 204)});
    final store = MemoryTokenStore()..write(liveTokens(refresh: 'r-9'));
    final session = make(backend, store);
    await session.restore();
    await session.logout();
    expect(session.state, SessionState.signedOut);
    expect(await store.read(), isNull);
    final form = Uri.splitQueryString(backend.sent('POST', logoutPath).single.body);
    expect(form, {'client_id': 'yantra-app', 'refresh_token': 'r-9'});
  });

  test('logout survives an unreachable identity server', () async {
    final backend = FakeBackend({'POST $logoutPath': (_) => throw Exception('down')});
    final store = MemoryTokenStore()..write(liveTokens());
    final session = make(backend, store);
    await session.restore();
    await session.logout();
    expect(session.state, SessionState.signedOut);
  });

  test('a redirect sign-in stores the attempt and leaves for Keycloak with PKCE', () async {
    final browser = MemoryBrowser(canRedirect: true);
    final session = make(FakeBackend(), MemoryTokenStore(), browser: browser);
    await session.restore();
    session.beginRedirectLogin();
    final attempt = PkceAttempt.decode(browser.storage[Session.attemptKey]);
    expect(attempt, isNotNull);
    final uri = browser.navigations.single;
    expect(uri.path, '/realms/yantra/protocol/openid-connect/auth');
    expect(uri.queryParameters['code_challenge'], attempt!.challenge);
    expect(uri.queryParameters['state'], attempt.state);
    expect(uri.queryParameters['redirect_uri'], 'http://localhost:8095/auth/callback');
  });

  test('coming back with a code exchanges it, signs in, and cleans the URL and the storage', () async {
    final backend = FakeBackend({'POST $tokenPath': (_) => json(tokenResponse(access: fakeJwt(username: 'asha')))});
    final attempt = PkceAttempt(verifier: 'v' * 43, state: 'st-1');
    final browser = MemoryBrowser(current: Uri.parse('http://localhost:8095/?code=abc&state=st-1'), canRedirect: true)
      ..storage[Session.attemptKey] = attempt.encode();
    final store = MemoryTokenStore();
    final session = make(backend, store, browser: browser);
    await session.restore();
    expect(session.state, SessionState.signedIn);
    expect(session.username, 'asha');
    expect((await store.read())?.accessToken, isNotEmpty);
    expect(browser.currentUri().toString(), 'http://localhost:8095/auth/callback');
    expect(browser.storage.containsKey(Session.attemptKey), isFalse);
    final form = Uri.splitQueryString(backend.requests.single.body);
    expect(form, {
      'grant_type': 'authorization_code',
      'client_id': 'yantra-app',
      'code': 'abc',
      'code_verifier': 'v' * 43,
      'redirect_uri': 'http://localhost:8095/auth/callback',
    });
  });

  test('a state that does not match this tab is refused', () async {
    final backend = FakeBackend();
    final browser = MemoryBrowser(current: Uri.parse('http://localhost:8095/?code=abc&state=other'), canRedirect: true)
      ..storage[Session.attemptKey] = const PkceAttempt(verifier: 'v', state: 'mine').encode();
    final session = make(backend, MemoryTokenStore(), browser: browser);
    await session.restore();
    expect(session.state, SessionState.signedOut);
    expect(session.redirectError, contains('did not match'));
    expect(backend.requests, isEmpty);
  });

  test('a missing attempt, a cancelled sign-in and a refused code each explain themselves', () async {
    final noAttempt = make(
      FakeBackend(),
      MemoryTokenStore(),
      browser: MemoryBrowser(current: Uri.parse('http://localhost:8095/?code=abc&state=s'), canRedirect: true),
    );
    await noAttempt.restore();
    expect(noAttempt.redirectError, contains('could not be completed'));

    final cancelled = make(
      FakeBackend(),
      MemoryTokenStore(),
      browser: MemoryBrowser(current: Uri.parse('http://localhost:8095/?error=access_denied'), canRedirect: true),
    );
    await cancelled.restore();
    expect(cancelled.redirectError, contains('cancelled'));

    final refused = make(
      FakeBackend({
        'POST $tokenPath': (_) => json({'error': 'invalid_grant', 'error_description': 'Code not valid'}, status: 400),
      }),
      MemoryTokenStore(),
      browser: MemoryBrowser(current: Uri.parse('http://localhost:8095/?code=abc&state=s'), canRedirect: true)
        ..storage[Session.attemptKey] = const PkceAttempt(verifier: 'v', state: 's').encode(),
    );
    await refused.restore();
    expect(refused.state, SessionState.signedOut);
    expect(refused.redirectError, 'Code not valid');
  });

  test('a sign-out during a refresh wins: the refreshed tokens are never stored', () async {
    Session? session;
    final backend = FakeBackend({
      'POST $tokenPath': (_) {
        session!.authLost(); // the gateway said the session is dead while the refresh was in flight
        return json(tokenResponse(access: 'fresh', refresh: 'r2'));
      },
    });
    final store = MemoryTokenStore()..write(Tokens(accessToken: 'stale', refreshToken: 'r1', expiresAt: DateTime(2026)));
    session = make(backend, store, clock: () => DateTime(2026, 1, 1, 12));
    await session.restore();
    expect(await session.accessToken(), isNull);
    expect(await store.read(), isNull);
    expect(session.state, SessionState.signedOut);
  });

  test('a refresh token rotated by another tab is picked up instead of signing out', () async {
    var calls = 0;
    MemoryTokenStore? store;
    final backend = FakeBackend({
      'POST $tokenPath': (r) {
        calls++;
        final form = Uri.splitQueryString(r.body);
        if (form['refresh_token'] == 'r-new') return json(tokenResponse(access: 'fresh', refresh: 'r-newer'));
        // the other tab rotates the token while this refresh is in flight; this one is refused
        store!.write(Tokens(accessToken: 'theirs', refreshToken: 'r-new', expiresAt: DateTime(2026)));
        return json({'error': 'invalid_grant'}, status: 400);
      },
    });
    store = MemoryTokenStore()..write(Tokens(accessToken: 'stale', refreshToken: 'r-old', expiresAt: DateTime(2026)));
    final session = make(backend, store, clock: () => DateTime(2026, 1, 1, 12));
    await session.restore();
    expect(await session.accessToken(), 'fresh');
    expect(calls, 2);
    expect(session.state, SessionState.signedIn);
    expect((await store.read())?.refreshToken, 'r-newer');
  });

  test('a token another tab stores just after this tab was refused is still picked up', () async {
    MemoryTokenStore? store;
    final backend = FakeBackend({
      'POST $tokenPath': (r) {
        final form = Uri.splitQueryString(r.body);
        if (form['refresh_token'] == 'r-new') return json(tokenResponse(access: 'fresh', refresh: 'r-newer'));
        // the other tab's refresh won the race; its write lands a moment after this tab's refusal
        Future<void>.delayed(const Duration(milliseconds: 30), () {
          store!.write(Tokens(accessToken: 'theirs', refreshToken: 'r-new', expiresAt: DateTime(2026)));
        });
        return json({'error': 'invalid_grant'}, status: 400);
      },
    });
    store = MemoryTokenStore()..write(Tokens(accessToken: 'stale', refreshToken: 'r-old', expiresAt: DateTime(2026)));
    final session = make(backend, store, clock: () => DateTime(2026, 1, 1, 12));
    await session.restore();
    expect(await session.accessToken(), 'fresh');
    expect(session.state, SessionState.signedIn);
  });

  test('the newest stored refresh token is used before any request', () async {
    final backend = FakeBackend({'POST $tokenPath': (_) => json(tokenResponse(access: 'fresh', refresh: 'r-newer'))});
    final store = MemoryTokenStore()..write(Tokens(accessToken: 'stale', refreshToken: 'r-old', expiresAt: DateTime(2026)));
    final session = make(backend, store, clock: () => DateTime(2026, 1, 1, 12));
    await session.restore();
    await store.write(Tokens(accessToken: 'theirs', refreshToken: 'r-new', expiresAt: DateTime(2026)));
    expect(await session.accessToken(), 'fresh');
    expect(Uri.splitQueryString(backend.requests.single.body)['refresh_token'], 'r-new');
  });

  test('blocked storage stops the redirect before it starts', () async {
    final browser = _BlockedBrowser();
    final session = make(FakeBackend(), MemoryTokenStore(), browser: browser);
    await session.restore();
    session.beginRedirectLogin();
    expect(browser.navigations, isEmpty);
    expect(session.redirectError, contains('site storage'));
  });

  test('an unreadable store signs the worker out instead of spinning', () async {
    final session = make(FakeBackend(), _BrokenStore());
    await session.restore();
    expect(session.state, SessionState.signedOut);
  });
}

class _BlockedBrowser extends MemoryBrowser {
  _BlockedBrowser() : super(canRedirect: true);
  @override
  void write(String key, String? value) {}
}

class _BrokenStore extends MemoryTokenStore {
  @override
  Future<Tokens?> read() async => throw StateError('storage unavailable');
}
