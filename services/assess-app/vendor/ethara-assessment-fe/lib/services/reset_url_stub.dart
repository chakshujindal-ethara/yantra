/// Taking the reset token back out of the browser URL.
///
/// WHY IT HAS TO GO. The token in `?token=` is a one-time credential that the
/// server burns the moment it is used. Leaving it in the address bar means a
/// refresh - or the browser restoring the tab tomorrow - re-enters the reset
/// form on a token that no longer works, and tells somebody who succeeded a
/// second ago that their link has expired. It also keeps the credential in
/// history, in the back stack, and in anything that syncs open tabs.
///
/// Non-web builds have no address bar. The app is web-only today, so this stub
/// exists to satisfy the conditional import and does nothing, mirroring
/// `prefs_stub.dart` beside it.
library;

void clearResetTokenFromUrl() {}
