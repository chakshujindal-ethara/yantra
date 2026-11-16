/// Non-web builds have no browser file picker; the app is web-only today, so
/// this exists solely to satisfy the conditional import.
///
/// Mirrors `download_stub.dart` / `download_web.dart` next to it - the same
/// pattern the CSV export already uses.
library;

/// A file the user chose, as raw bytes plus its original name.
class PickedFile {
  final String name;
  final List<int> bytes;

  const PickedFile(this.name, this.bytes);
}

Future<PickedFile?> pickFile({String accept = ''}) async => null;
