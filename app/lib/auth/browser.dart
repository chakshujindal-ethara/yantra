import 'browser_stub.dart' if (dart.library.js_interop) 'browser_web.dart' as impl;

/// The sliver of the browser the sign-in redirect needs. On the web it is the real window; elsewhere
/// (and in tests) an in-memory stand-in, so nothing here ever imports `dart:html`-like APIs directly.
abstract class Browser {
  /// The page's current URL.
  Uri currentUri();

  /// Where Keycloak must send the user back: this app's origin, `/auth/callback`.
  Uri redirectUri();

  /// Leaves the app for [url] (the Keycloak sign-in page).
  void navigate(Uri url);

  /// Rewrites the address bar without a reload (drops `?code=...` after the exchange).
  void replaceUrl(Uri url);

  /// Per-tab storage for the in-flight PKCE attempt. Null when absent or blocked.
  String? read(String key);
  void write(String key, String? value);

  /// True only where a redirect can actually happen (a real browser).
  bool get canRedirect;
}

Browser platformBrowser() => impl.create();

/// An in-memory browser: the default off the web and the one every test uses.
class MemoryBrowser implements Browser {
  MemoryBrowser({Uri? current, this.canRedirect = false}) : _current = current ?? Uri.parse('http://localhost:8095/');

  Uri _current;
  final Map<String, String> storage = {};
  final List<Uri> navigations = [];

  @override
  final bool canRedirect;

  @override
  Uri currentUri() => _current;

  @override
  Uri redirectUri() => Uri(scheme: _current.scheme, host: _current.host, port: _current.port, path: '/auth/callback');

  @override
  void navigate(Uri url) => navigations.add(url);

  @override
  void replaceUrl(Uri url) => _current = url;

  @override
  String? read(String key) => storage[key];

  @override
  void write(String key, String? value) {
    if (value == null) {
      storage.remove(key);
    } else {
      storage[key] = value;
    }
  }
}
