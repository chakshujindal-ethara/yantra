import 'package:web/web.dart' as web;

/// Rewrite the address bar to the app root, in place.
///
/// `replaceState`, never `pushState`: this is erasing a spent credential, not
/// navigating, and a history entry would let Back put the token straight back
/// on screen. Flutter's own router is not involved - `main.dart` decides what
/// to show from a field it has already cleared, and this only makes the URL
/// agree with it.
void clearResetTokenFromUrl() {
  try {
    final web.Location location = web.window.location;
    // Origin + pathname, with the query AND the fragment dropped: a
    // hash-routed link carries the token in the fragment instead.
    web.window.history.replaceState(
      null,
      '',
      '${location.origin}${location.pathname}',
    );
  } catch (_) {
    // A sandboxed iframe refuses history writes. The token staying in the URL
    // is untidy, not dangerous - it has already been spent - and is not worth
    // taking the page down for.
  }
}
