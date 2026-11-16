import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'errors.dart';

/// One idempotency key per user action: the same key for every retry of that action,
/// a fresh key once the action finished.
class ActionKeys {
  ActionKeys({String Function()? generate}) : _generate = generate ?? const Uuid().v4;

  final String Function() _generate;
  final Map<String, String> _live = {};

  /// The key for [action], minted on first use and kept until [finish].
  String start(String action) => _live.putIfAbsent(action, _generate);

  /// Forgets the key: the next [start] for [action] is a new action.
  void finish(String action) => _live.remove(action);

  /// After a failure: keeps the key only when a retry may safely reuse it (see [retryKeepsKey]).
  void settle(String action, Object error) {
    if (!retryKeepsKey(error)) finish(action);
  }
}

/// A short, stable tag of a request body for an action name (`submit:<claim>:<tag>`): an edited body is a
/// new action with a new key, so a retry after a failure never sends a different body under an old key.
String bodyTag(Object? body) => sha256.convert(utf8.encode(jsonEncode(body))).toString().substring(0, 12);
