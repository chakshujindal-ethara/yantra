import 'package:web/web.dart' as web;

import 'token_store_stub.dart' show StoredSession;

export 'token_store_stub.dart' show StoredSession;

/// `localStorage` PLUS an idle cutoff, rather than `sessionStorage`.
///
/// sessionStorage is scoped to ONE TAB. Opening a second tab on the same origin
/// - same browser, same profile, same signed-in person - got the login form,
/// because the new tab's sessionStorage is a different, empty store. That is
/// not a session anybody recognises: every other console in the suite carries
/// across a new tab, and the first tab stayed signed in the whole time, so the
/// app was reporting two different answers about one session.
///
/// This file previously chose sessionStorage on purpose, and the reason was
/// sound: localStorage survives closing the tab, so on a shared machine the
/// next person would open the console already signed in as whoever used it
/// last. The token outliving the visit is a security problem, not a
/// convenience.
///
/// [_kIdleCutoff] is what buys the cross-tab behaviour without buying that
/// problem. Every save and every verified restore stamps [_kSeen]; a load older
/// than the cutoff is discarded and wiped rather than returned. So a session
/// follows the person across tabs and windows for as long as they are using it,
/// and a machine left alone stops offering it.
///
/// It is a cutoff, not a security boundary. The stored bearer is still
/// VERIFIED against `/auth/me` on every restore, and the server remains the
/// only thing that decides whether a token is good - a revoked or expired one
/// inside the window still lands on the login form.
const String _kBearer = 'etp.bearer';
const String _kRefresh = 'etp.refresh';

/// When the stored session was last used, as epoch milliseconds.
const String _kSeen = 'etp.seen';

/// How long a session may sit unused before it stops being offered.
///
/// Twelve hours covers a working day with a lunch break in it - shut the laptop
/// after standup, come back after lunch, still signed in - and does not cover
/// leaving for the night, which is the case the shared machine cares about.
const Duration _kIdleCutoff = Duration(hours: 12);

/// The stored tokens, or null when there is nothing to restore.
///
/// Returns null rather than a half-populated record when the bearer is missing:
/// a refresh token alone cannot authorise a call, and treating it as a session
/// would show the console for an instant before the first 401 tore it down.
StoredSession? loadSession() {
  final web.Storage s = web.window.localStorage;
  final String? bearer = s.getItem(_kBearer);
  if (bearer == null || bearer.isEmpty) return null;

  // An unparseable or absent stamp is treated as EXPIRED, not as fresh. The
  // stamp is written by this file on every save, so its absence means either a
  // token from the sessionStorage era or something hand-edited - neither is a
  // session this should silently resume.
  final int? seen = int.tryParse(s.getItem(_kSeen) ?? '');
  if (seen == null) {
    clearSession();
    return null;
  }
  final int age = DateTime.now().millisecondsSinceEpoch - seen;
  // `age < 0` is a clock that moved backwards, not a session from the future.
  // Treated as fresh: refusing here would sign somebody out for changing their
  // timezone, and the server still has the final say on the token.
  if (age > _kIdleCutoff.inMilliseconds) {
    clearSession();
    return null;
  }
  return StoredSession(bearer, s.getItem(_kRefresh) ?? '');
}

void saveSession(String bearer, String refresh) {
  final web.Storage s = web.window.localStorage;
  if (bearer.isEmpty) {
    s.removeItem(_kBearer);
  } else {
    s.setItem(_kBearer, bearer);
  }
  if (refresh.isEmpty) {
    s.removeItem(_kRefresh);
  } else {
    s.setItem(_kRefresh, refresh);
  }
  if (bearer.isEmpty) {
    s.removeItem(_kSeen);
  } else {
    touchSession();
  }
}

/// Restart the idle window.
///
/// Separate from [saveSession] because the tokens themselves usually do not
/// change when somebody uses the app: a bearer is good for an hour, so stamping
/// only on save would measure "time since the token last rotated" and sign out
/// a person who was working the whole time.
void touchSession() {
  final web.Storage s = web.window.localStorage;
  if ((s.getItem(_kBearer) ?? '').isEmpty) return;
  s.setItem(_kSeen, DateTime.now().millisecondsSinceEpoch.toString());
}

void clearSession() {
  final web.Storage s = web.window.localStorage;
  s.removeItem(_kBearer);
  s.removeItem(_kRefresh);
  s.removeItem(_kSeen);
}
