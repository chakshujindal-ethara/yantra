/// This tab's exam session key, sent on every candidate exam call so the
/// server can keep one sitting open in one place: the newest tab to load the
/// exam takes it over, and a write from an older one is refused with 409
/// `session_replaced`.
///
/// Non-web builds have no tab, so the key lives in memory for the process.
/// `exam_session_web.dart` falls back to this when sessionStorage throws.
library;

import 'dart:math';

String? _key;

String examSessionKey() => _key ??= newExamSessionKey();

/// 128 random bits as hex.
String newExamSessionKey() {
  final Random r = Random.secure();
  return <String>[
    for (int i = 0; i < 16; i++)
      r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}
