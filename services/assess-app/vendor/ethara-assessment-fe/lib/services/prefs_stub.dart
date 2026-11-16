/// Small UI preferences that should survive a reload.
///
/// Separate from `token_store_*` on purpose: that holds a credential and uses
/// sessionStorage so it dies with the tab. These are layout choices - is the
/// chatter open, how wide is it - which are not secrets and SHOULD outlive the
/// tab, or the operator re-adjusts the same panel every morning.
///
/// Non-web builds have no browser storage. The app is web-only today, so this
/// stub exists to satisfy the conditional import and always reports "nothing
/// stored", mirroring `token_store_stub.dart` beside it.
library;

String? readPref(String key) => null;

void writePref(String key, String value) {}
