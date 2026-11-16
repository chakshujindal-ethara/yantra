import 'dart:typed_data';

/// Non-web builds have no browser download; the app is web-only today, so this
/// exists solely to satisfy the conditional import.
void saveTextFile(String filename, String content, String mimeType) {}

void saveBytesFile(String filename, Uint8List bytes, String mimeType) {}

void saveBytesParts(String filename, List<Uint8List> parts, String mimeType) {}
