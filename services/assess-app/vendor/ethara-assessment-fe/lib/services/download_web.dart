import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Saves [content] as a file download in the browser.
///
/// Uses a Blob + object URL rather than a `data:` URI: Chrome caps data URIs
/// around 2 MB and the full leaderboard export (738 rows) can exceed it. The
/// object URL is revoked immediately after the click so the blob is not held
/// for the life of the tab.
void saveTextFile(String filename, String content, String mimeType) {
  final blob = web.Blob(
    [content.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}

/// [saveTextFile] for binary content - a zipped export. The bytes go into the
/// Blob as they are; a String part would be re-encoded as UTF-8 and corrupt it.
void saveBytesFile(String filename, Uint8List bytes, String mimeType) {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}

/// Saves [parts] as ONE file without joining them first.
///
/// A paged export of 10,000+ candidates is hundreds of MB. Concatenating it
/// into one Dart String would double that (UTF-16) and copy it again for the
/// Blob; handing the pages to the Blob as separate parts lets the browser
/// write them out one after another.
void saveBytesParts(String filename, List<Uint8List> parts, String mimeType) {
  final blob = web.Blob(
    <JSAny>[for (final Uint8List p in parts) p.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
