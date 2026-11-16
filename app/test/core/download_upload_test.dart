import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yantra_app/core/download.dart';
import 'package:yantra_app/core/errors.dart';
import 'package:yantra_app/core/format.dart';
import 'package:yantra_app/core/platform/file_pick.dart';
import 'package:yantra_app/core/upload.dart';

void main() {
  test('the memory downloader records what would be saved; off the web nothing can be saved', () {
    final d = MemoryDownloader()..save('statement.csv', utf8.encode('a,b'), 'text/csv');
    expect(d.supported, isTrue);
    expect(d.saved.single.name, 'statement.csv');
    expect(utf8.decode(d.saved.single.bytes), 'a,b');
    expect(platformDownloader().supported, isFalse);
  });

  test('the memory picker hands back the next file once, and records what it was asked for', () async {
    final picker = MemoryFilePicker()..next = (name: 'units.jsonl', mime: 'application/jsonl', bytes: utf8.encode('{}'));
    expect((await picker.pick(accept: '.jsonl'))?.name, 'units.jsonl');
    expect(await picker.pick(), isNull);
    expect(picker.asked, ['.jsonl', '']);
    expect(platformFilePicker(), isA<MemoryFilePicker>());
  });

  test('a presigned upload is read from the backend shape', () {
    final p = PresignedUpload.fromJson({
      'url': 'http://minio:9000/yantra/k?sig=1',
      'method': 'PUT',
      'headers': {'content-type': 'image/png'},
      'expires_at': '2026-11-04T12:05:00Z',
      'key': 'workers/w/documents/x',
      'max_bytes': 10,
    });
    expect(p.url.host, 'minio');
    expect(p.headers, {'content-type': 'image/png'});
    expect(p.expiresAt, DateTime.utc(2026, 11, 4, 12, 5));
    expect(p.key, 'workers/w/documents/x');
    expect(p.maxBytes, 10);
    final bare = PresignedUpload.fromJson({'url': 'http://x/y'});
    expect(bare.method, 'PUT');
    expect(bare.maxBytes, isNull);
  });

  test('the uploader PUTs the bytes with exactly the signed headers and no bearer token', () async {
    late http.Request seen;
    final up = Uploader(
      MockClient((r) async {
        seen = r;
        return http.Response('', 200);
      }),
    );
    await up.put(PresignedUpload(url: Uri.parse('http://minio:9000/yantra/k?sig=1'), headers: const {'content-type': 'audio/wav'}), [
      1,
      2,
      3,
    ]);
    expect(seen.method, 'PUT');
    expect(seen.headers['content-type'], 'audio/wav');
    expect(seen.headers.containsKey('Authorization'), isFalse);
    expect(seen.bodyBytes, [1, 2, 3]);
  });

  test('the uploader refuses an oversize file before sending, and reports a refusal or an unreachable store', () async {
    var sent = 0;
    final refusing = Uploader(
      MockClient((_) async {
        sent++;
        return http.Response('<Error/>', 403);
      }),
    );
    final target = PresignedUpload(url: Uri.parse('http://minio/k'), maxBytes: 2);
    await expectLater(refusing.put(target, [1, 2, 3]), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'file_too_large')));
    expect(sent, 0);
    await expectLater(
      refusing.put(PresignedUpload(url: Uri.parse('http://minio/k')), [1]),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)),
    );
    final down = Uploader(MockClient((_) async => throw http.ClientException('refused')));
    await expectLater(down.put(PresignedUpload(url: Uri.parse('http://minio/k')), [1]), throwsA(isA<TransportException>()));
  });

  test('a file over the limit is described in MB, and storage refusals read as written', () async {
    final uploader = Uploader(MockClient((_) async => http.Response('<Error/>', 403)));
    final big = PresignedUpload(url: Uri.parse('http://minio/k'), maxBytes: 10 * 1024 * 1024);
    Object? error;
    try {
      await uploader.put(big, List.filled(12 * 1024 * 1024 + 512 * 1024, 0));
    } on Object catch (e) {
      error = e;
    }
    expect(describeError(error!), 'This file is 12.5 MB; the limit is 10.0 MB.');
    try {
      await uploader.put(PresignedUpload(url: Uri.parse('http://minio/k')), [1]);
    } on Object catch (e) {
      error = e;
    }
    expect(describeError(error), 'The upload was refused (403).');
    expect(fileSize(900), '1 KB');
    expect(fileSize(5 * 1024 * 1024), '5.0 MB');
  });
}
