import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

/// The page's URL as the browser shows it now.
Uri? readBrowserUrl() => Uri.parse(web.window.location.href);

/// Put [url] (a same-origin path and query) in the address bar.
///
/// [push] adds a history entry, which Back returns from; otherwise the current
/// entry is rewritten in place. Wrapped like `reset_url_web.dart`: a sandboxed
/// iframe refuses history writes, and Safari throws past ~100 writes in 30s.
/// A stale address bar is untidy; taking the page down for it is not.
void writeBrowserUrl(String url, {required bool push}) {
  try {
    if (push) {
      web.window.history.pushState(null, '', url);
    } else {
      web.window.history.replaceState(null, '', url);
    }
  } catch (_) {}
}

/// Call [listener] with the new URL whenever Back or Forward moves the page.
/// Returns the unsubscribe.
void Function() onBrowserPop(void Function(Uri url) listener) {
  final web.EventListener js = ((web.Event _) => listener(
    Uri.parse(web.window.location.href),
  )).toJS;
  web.window.addEventListener('popstate', js);
  return () => web.window.removeEventListener('popstate', js);
}

/// Stop Flutter's engine from managing browser history, so the app can.
///
/// MUST RUN BEFORE `runApp`. The engine's default (hash strategy, single
/// entry) pushes its own sentinel entry and answers every `popstate` by
/// bouncing the browser forward again - it would swallow the app's own
/// entries and turn Back into a no-op. Null is the engine's documented "no
/// browser integration" value; `AssessmentSection` then owns the address bar.
void takeOverBrowserHistory() {
  ui_web.urlStrategy = null;
}
