import 'package:web/web.dart' as web;

/// `localStorage`, not `sessionStorage`.
///
/// The opposite choice from `token_store_web.dart`, and deliberately so. A
/// bearer token outliving the tab is a security problem; a panel width outliving
/// the tab is the entire point - otherwise every new tab reopens with the
/// chatter closed and the operator drags it back to the same place daily.
String? readPref(String key) {
  try {
    final String? v = web.window.localStorage.getItem(key);
    return (v == null || v.isEmpty) ? null : v;
  } catch (_) {
    // Storage can throw rather than return null: Safari in private mode, and
    // any browser with site data blocked. A preference is not worth taking the
    // app down for, so an unreadable store simply means "no preference".
    return null;
  }
}

void writePref(String key, String value) {
  try {
    web.window.localStorage.setItem(key, value);
  } catch (_) {
    // Same reasoning, plus QuotaExceededError on a full store.
  }
}
