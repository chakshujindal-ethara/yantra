/// Where the bearer token lives between page loads.
///
/// WHY THIS EXISTS: sign-in returns a bearer token that was held only in a Dart
/// field, so a browser refresh restarted the VM, dropped the token and threw the
/// user back to the login form - with a perfectly valid session still open on
/// the server. A refresh is not a sign-out.
///
/// Non-web builds have no browser storage; the app is web-only today, so this
/// stub exists to satisfy the conditional import and reading it always says
/// "nothing stored". Mirrors `file_pick_stub.dart` next to it.
library;

/// The tokens a session needs to survive a reload.
class StoredSession {
  final String bearer;
  final String refresh;

  const StoredSession(this.bearer, this.refresh);
}

StoredSession? loadSession() => null;

void saveSession(String bearer, String refresh) {}

/// Restart the idle window on the web store. A no-op here, like the rest.
void touchSession() {}

void clearSession() {}
