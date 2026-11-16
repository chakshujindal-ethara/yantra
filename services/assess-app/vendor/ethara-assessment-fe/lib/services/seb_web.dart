import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// `SafeExamBrowser.security.configKey`, or null outside Safe Exam Browser.
///
/// SEB injects this object into every page it loads: the SHA-256 of the load
/// URL and its Config Key. The server rebuilds the same hash from the settings
/// it served in the `.seb` file, so a match proves this page runs under them.
String? _configKey() {
  try {
    final JSObject w = web.window as JSObject;
    if (!w.has('SafeExamBrowser')) return null;
    final JSObject? security = w
        .getProperty<JSObject?>('SafeExamBrowser'.toJS)
        ?.getProperty<JSObject?>('security'.toJS);
    final Object? key = security
        ?.getProperty<JSAny?>('configKey'.toJS)
        .dartify();
    return key is String && key.isNotEmpty ? key : null;
  } catch (_) {
    return null;
  }
}

bool insideSeb() => _configKey() != null;

/// The proof every candidate exam call carries inside SEB; empty outside it.
///
/// `seb_url` is the URL the page LOADED at, captured by `web/index.html`
/// before the app ran: SEB hashed that one, and the app has rewritten the
/// address bar with `pushState` since. Without the fragment, as SEB hashes it.
Map<String, String> sebProof() {
  final String? key = _configKey();
  if (key == null) return const <String, String>{};
  final Object? boot = (web.window as JSObject)
      .getProperty<JSAny?>('__sebBootUrl'.toJS)
      .dartify();
  return <String, String>{
    'seb_url': boot is String && boot.isNotEmpty
        ? boot
        : web.window.location.href.split('#').first,
    'seb_key': key,
  };
}

/// Same window: a `sebs://` link hands the page to SEB, and SEB closes itself
/// on its quit URL.
void navigateTo(String url) => web.window.location.assign(url);

void openInNewTab(String url) => web.window.open(url, '_blank', 'noopener');
