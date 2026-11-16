import 'dart:convert';

import 'errors.dart';

/// Type-tested readers for wire data. A missing or mistyped field yields an empty value, never a throw;
/// a body of the wrong shape altogether is a [ShapeError].
typedef Json = Map<String, dynamic>;

String readString(Json m, String key) {
  final v = m[key];
  return v is String ? v : (v is num ? v.toString() : '');
}

int readInt(Json m, String key) {
  final v = m[key];
  return v is int ? v : (v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0));
}

bool readBool(Json m, String key) => m[key] is bool ? m[key] as bool : false;

Json readMap(Json m, String key) {
  final v = m[key];
  return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
}

List<dynamic> readList(Json m, String key) {
  final v = m[key];
  return v is List ? v : const [];
}

DateTime? readDateTime(Json m, String key) {
  final v = m[key];
  return v is String ? DateTime.tryParse(v)?.toLocal() : null;
}

/// Decodes a JSON object body. An empty body is an empty object (a 204-style answer); anything that is
/// not JSON, or JSON that is not an object, is a [ShapeError] the screen shows with a retry.
Json decodeObject(String body) {
  if (body.isEmpty) return {};
  final v = _parse(body, 'an object');
  if (v is Map) return Map<String, dynamic>.from(v);
  throw ShapeError('an object', body);
}

/// Decodes a JSON array body of objects (non-object items are skipped). An empty body is an empty list;
/// anything else is a [ShapeError].
List<Json> decodeObjects(String body) {
  if (body.isEmpty) return const [];
  final v = _parse(body, 'a list');
  if (v is! List) throw ShapeError('a list', body);
  return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
}

/// For the few readers that must never throw (error envelopes, stored and JWT tokens, the identity
/// server's answer): anything that is not a JSON object is an empty object.
Json decodeObjectOrEmpty(String body) {
  try {
    final v = jsonDecode(body);
    return v is Map ? Map<String, dynamic>.from(v) : {};
  } on FormatException {
    return {};
  }
}

Object? _parse(String body, String expected) {
  try {
    return jsonDecode(body);
  } on FormatException {
    throw ShapeError(expected, body);
  }
}

const prettyJson = JsonEncoder.withIndent('  ');
