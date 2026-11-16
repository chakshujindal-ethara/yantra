import 'package:web/web.dart' as web;

import 'exam_session_stub.dart' as memory;

const String _kKey = 'etp.exam_session';

String? _key;

/// `sessionStorage`, not `localStorage`: the key names ONE TAB, and must
/// survive that tab's reloads (a reload is the same sitting, not a new one)
/// while a second tab gets its own. Storage that throws (Safari private mode,
/// blocked site data) falls back to a key held in memory for this page load.
String examSessionKey() => _key ??= _load();

String _load() {
  try {
    final web.Storage s = web.window.sessionStorage;
    final String? held = s.getItem(_kKey);
    if (held != null && held.isNotEmpty) return held;
    final String fresh = memory.newExamSessionKey();
    s.setItem(_kKey, fresh);
    return fresh;
  } catch (_) {
    return memory.examSessionKey();
  }
}
