import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'format.dart';

/// A presigned upload the backend handed out (`POST …/presign`, `…/payload-uploads`): PUT the bytes to
/// [url] with exactly [headers] (they are part of the signature) before [expiresAt].
class PresignedUpload {
  const PresignedUpload({required this.url, this.method = 'PUT', this.headers = const {}, this.expiresAt, this.key = '', this.maxBytes});

  final Uri url;
  final String method;
  final Map<String, String> headers;
  final DateTime? expiresAt;

  /// The object key the backend expects back when the upload is registered.
  final String key;
  final int? maxBytes;

  factory PresignedUpload.fromJson(Map<String, Object?> m) => PresignedUpload(
    url: Uri.parse('${m['url'] ?? ''}'),
    method: '${m['method'] ?? 'PUT'}',
    headers: {for (final e in ((m['headers'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
    expiresAt: DateTime.tryParse('${m['expires_at'] ?? ''}'),
    key: '${m['key'] ?? ''}',
    maxBytes: m['max_bytes'] is int ? m['max_bytes'] as int : null,
  );
}

/// Sends bytes straight to object storage (MinIO) through a presigned URL: no bearer token, no gateway.
class Uploader {
  Uploader(this._client, {this.timeout = const Duration(minutes: 2)});

  final http.Client _client;
  final Duration timeout;

  /// Reads an object back through a presigned GET link (a deliverable, a manifest file): no bearer token.
  Future<Uint8List> fetch(Uri url) async {
    final http.Response response;
    try {
      response = await _client.get(url).timeout(timeout);
    } on Exception catch (e) {
      throw TransportException('Storage unreachable (${e.runtimeType})');
    }
    if (response.statusCode >= 300) {
      throw StorageException(
        status: response.statusCode,
        code: 'download_failed',
        message: 'The file could not be fetched (${response.statusCode}).',
      );
    }
    return response.bodyBytes;
  }

  Future<void> put(PresignedUpload target, List<int> bytes) async {
    final max = target.maxBytes;
    if (max != null && bytes.length > max) {
      throw StorageException(
        status: 413,
        code: 'file_too_large',
        message: 'This file is ${fileSize(bytes.length)}; the limit is ${fileSize(max)}.',
      );
    }
    final request = http.Request(target.method, target.url)
      ..headers.addAll(target.headers)
      ..bodyBytes = Uint8List.fromList(bytes);
    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(timeout);
    } on Exception catch (e) {
      throw TransportException('Storage unreachable (${e.runtimeType})');
    }
    await response.stream.drain<void>();
    if (response.statusCode >= 300) {
      throw StorageException(
        status: response.statusCode,
        code: 'upload_failed',
        message: 'The upload was refused (${response.statusCode}).',
      );
    }
  }
}
