import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'download.dart';

Downloader create() => _WebDownloader();

/// How long a saved file's object URL lives before it is freed.
const revokeAfter = Duration(seconds: 60);

class _WebDownloader implements Downloader {
  @override
  bool get supported => true;

  @override
  void save(String name, List<int> bytes, String mime) {
    final blob = web.Blob([Uint8List.fromList(bytes).toJS].toJS, web.BlobPropertyBag(type: mime));
    final url = web.URL.createObjectURL(blob);
    final a = web.HTMLAnchorElement()
      ..href = url
      ..download = name
      ..style.display = 'none';
    web.document.body?.append(a);
    a.click();
    a.remove();
    // the browser reads the blob after click() returns; revoking at once can cancel the save (Safari,
    // Firefox), so the URL is freed a minute later
    Timer(revokeAfter, () => web.URL.revokeObjectURL(url));
  }

  @override
  void open(Uri url) {
    final a = web.HTMLAnchorElement()
      ..href = url.toString()
      ..target = '_blank'
      ..rel = 'noopener noreferrer'
      ..style.display = 'none';
    web.document.body?.append(a);
    a.click();
    a.remove();
  }
}
