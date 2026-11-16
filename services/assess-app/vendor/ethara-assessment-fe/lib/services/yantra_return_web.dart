import 'package:web/web.dart' as web;

/// Beside the session tokens (`token_store_web.dart`), so a reload mid-exam
/// still knows the way back to Yantra.
const String _kReturn = 'yantra.return';

String? readYantraReturn() {
  try {
    return web.window.localStorage.getItem(_kReturn);
  } catch (_) {
    // Storage blocked (a private window, a sandboxed frame): no way back is
    // shown, which is the honest answer.
    return null;
  }
}

void writeYantraReturn(String? url) {
  try {
    final web.Storage s = web.window.localStorage;
    if (url == null || url.isEmpty) {
      s.removeItem(_kReturn);
    } else {
      s.setItem(_kReturn, url);
    }
  } catch (_) {
    // As above: without storage there is simply no "Back to Yantra".
  }
}
