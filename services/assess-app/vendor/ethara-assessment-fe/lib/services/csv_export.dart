import 'dart:convert';
import 'dart:typed_data';

import 'download_stub.dart' if (dart.library.js_interop) 'download_web.dart';

/// Builds a CSV and hands it to the browser as a download.
///
/// The Odoo dashboards put a download button on every table — that is how the
/// numbers get used offline today (pasted into sheets, mailed to leads). Losing
/// it in the rewrite would be a real regression, so every table here keeps one.
///
/// Escaping follows RFC 4180: wrap in quotes when the value contains a comma,
/// quote or newline, and double any embedded quote. A tasker email never needs
/// it, but a pod name like `Second Floor --> Zone B2, Bay 3` does.
String buildCsv(List<String> headers, List<List<Object?>> rows) {
  final buf = StringBuffer()..writeln(headers.map(_cell).join(','));
  for (final r in rows) {
    buf.writeln(r.map(_cell).join(','));
  }
  return buf.toString();
}

String _cell(Object? v) {
  if (v == null) return '';
  final s = v.toString();
  if (s.contains(',') ||
      s.contains('"') ||
      s.contains('\n') ||
      s.contains('\r')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

/// Triggers a download of [csv] named [filename] (web only; a no-op elsewhere).
///
/// A UTF-8 BOM is prepended so Excel on Windows reads accented names correctly
/// instead of mojibake — without it `José` opens as `JosÃ©`.
void downloadCsv(String filename, String csv) {
  const bom = '\u{FEFF}';
  saveTextFile(filename, bom + csv, 'text/csv;charset=utf-8');
}

/// Convenience: build and download in one call.
void exportCsv({
  required String filename,
  required List<String> headers,
  required List<List<Object?>> rows,
}) {
  downloadCsv(filename, buildCsv(headers, rows));
}

/// Timestamped filename, e.g. `leaderboard_all_2026-07-28.csv`.
String csvName(String base, String window) {
  final d = DateTime.now();
  final stamp =
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  return '${base}_${window}_$stamp.csv';
}

/// The cell escaping, reachable without a browser. Currently uncalled - the
/// escaping contract is exercised through [buildCsv].
String debugCsvCell(Object? v) => _cell(v);

/// Base64 of a CSV. Currently uncalled - downloads go through a Blob object
/// URL instead, because Chrome caps a `data:` URI around 2 MB.
String csvToDataUrl(String csv) =>
    'data:text/csv;charset=utf-8;base64,${base64Encode(utf8.encode(csv))}';

/// Downloads [bytes] unchanged - a zipped export, which is not text.
void downloadBytes(String filename, Uint8List bytes, String mimeType) =>
    saveBytesFile(filename, bytes, mimeType);

/// A CSV that arrived in pages, saved as one file: the UTF-8 BOM (see
/// [downloadCsv]) and then each page's bytes as they came.
void downloadCsvParts(String filename, List<Uint8List> parts) =>
    saveBytesParts(filename, <Uint8List>[
      Uint8List.fromList(const <int>[0xEF, 0xBB, 0xBF]),
      ...parts,
    ], 'text/csv;charset=utf-8');
