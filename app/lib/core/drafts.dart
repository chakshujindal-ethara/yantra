import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Work in progress kept on this device: a unit's answer, a sitting's answers. Keys are
/// `yantra.draft.<kind>.<id>`; values are JSON objects. A draft is a convenience: losing one loses
/// typing, never a submission, so every failure reads as "no draft".
abstract class DraftStore {
  Future<Map<String, Object?>?> read(String key);
  Future<void> write(String key, Map<String, Object?> value);
  Future<void> remove(String key);

  static String unit(String claimId) => 'yantra.draft.unit.$claimId';
  static String sitting(String sittingId) => 'yantra.draft.sitting.$sittingId';
}

class PreferencesDraftStore implements DraftStore {
  @override
  Future<Map<String, Object?>?> read(String key) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      if (raw == null) return null;
      final v = jsonDecode(raw);
      return v is Map<String, Object?> ? v : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String key, Map<String, Object?> value) async {
    try {
      await (await SharedPreferences.getInstance()).setString(key, jsonEncode(value));
    } on Object {
      // storage full or blocked: the draft is lost, the work is not
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      await (await SharedPreferences.getInstance()).remove(key);
    } on Object {
      // nothing to clean up if storage is unavailable
    }
  }
}

/// The store tests use.
class MemoryDraftStore implements DraftStore {
  final Map<String, Map<String, Object?>> drafts = {};

  @override
  Future<Map<String, Object?>?> read(String key) async => drafts[key];

  @override
  Future<void> write(String key, Map<String, Object?> value) async => drafts[key] = jsonDecode(jsonEncode(value)) as Map<String, Object?>;

  @override
  Future<void> remove(String key) async => drafts.remove(key);
}
