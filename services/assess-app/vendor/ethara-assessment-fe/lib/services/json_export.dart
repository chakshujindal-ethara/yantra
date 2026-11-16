import 'dart:convert';

import 'download_stub.dart' if (dart.library.js_interop) 'download_web.dart';

/// Hands a JSON document to the browser as a file download.
///
/// Mirrors `csv_export.dart` next to it, and shares the same `saveTextFile`
/// Blob path, so there is ONE place that turns bytes into a download.
///
/// PRETTY-PRINTED, NOT COMPACT. What comes out of here is read and edited by
/// hand - an exported template gets diffed, tweaked and re-imported - so a
/// two-space indent is the point, not a nicety. `jsonEncode` with no indent
/// would put a whole form on one line.
void downloadJson(String filename, Object? doc) {
  saveTextFile(
    filename,
    const JsonEncoder.withIndent('  ').convert(doc),
    'application/json;charset=utf-8',
  );
}

/// Hands an ALREADY-SERIALISED JSON document to the browser, byte for byte.
///
/// [downloadJson] above encodes a Dart object, which is right when the app is
/// the author. This one is for a document the SERVER authored - the import
/// template - where re-encoding a decoded copy would hand the operator a file
/// that is merely equivalent to the one the backend renders and tests. The
/// bytes the route serves are the bytes that land in the downloads folder.
void downloadJsonText(String filename, String text) {
  saveTextFile(filename, text, 'application/json;charset=utf-8');
}

/// A filesystem-safe filename from a human title, e.g. `Verify Image Entities
/// (Yes/No)` -> `verify-image-entities-yes-no.json`.
///
/// Slashes matter here: a template named `Image + Video / Yes-No` would
/// otherwise produce a name the browser treats as a path.
String jsonFileName(String title, {String fallback = 'export'}) {
  final String slug = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return '${slug.isEmpty ? fallback : slug}.json';
}
