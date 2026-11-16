/// The browser address bar, off the web: there is none.
///
/// Exists to satisfy the conditional import in `assessment/route_url.dart` and
/// `main.dart`, and does nothing, mirroring `reset_url_stub.dart` beside it.
/// The VM test suite runs against this file, so no test can touch
/// `window.history` by accident.
library;

Uri? readBrowserUrl() => null;

void writeBrowserUrl(String url, {required bool push}) {}

void Function() onBrowserPop(void Function(Uri url) listener) => () {};

void takeOverBrowserHistory() {}
