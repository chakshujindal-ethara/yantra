import 'download_stub.dart' if (dart.library.js_interop) 'download_web.dart' as impl;

/// Hands the user a file to save. On the web a Blob and a temporary `<a download>`; elsewhere (and in
/// tests) [MemoryDownloader] records what would have been saved.
abstract class Downloader {
  /// False where no save is possible; screens then show the content in a copyable box instead.
  bool get supported;

  void save(String name, List<int> bytes, String mime);

  /// Opens a short-lived link (a presigned document) in a new tab, without handing it this page.
  void open(Uri url);
}

Downloader platformDownloader() => impl.create();

class MemoryDownloader implements Downloader {
  MemoryDownloader({this.supported = true});

  /// Tests flip it to see the copyable-box fallback.
  @override
  bool supported;

  final List<({String name, List<int> bytes, String mime})> saved = [];

  @override
  void save(String name, List<int> bytes, String mime) => saved.add((name: name, bytes: bytes, mime: mime));

  final List<Uri> opened = [];

  @override
  void open(Uri url) => opened.add(url);
}
