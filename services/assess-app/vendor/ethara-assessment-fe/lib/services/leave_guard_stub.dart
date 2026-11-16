/// Non-web builds have no page to leave, so there is nothing to hold. The app
/// is web-only today; this satisfies the conditional import, like
/// `prefs_stub.dart`.
library;

void setLeaveGuard(void Function()? onLeave) {}
