// FORM STUDIO MEDIA GOES TO THE BUCKET, NOT THROUGH THE API.
//
// The base64 route buffered a whole clip as one JSON body (100 MB cap, a
// 133 MB request, a worker held for the duration). Audio makes big files the
// normal case, so `AppStore.uploadFormMedia` now asks for a presigned S3 POST,
// sends the bytes to the bucket itself, and tells the server it is done:
//
//     POST /forms/media/presign {name, content_type, size}
//       -> {upload: {url, fields, prefix, expires_at}, key}
//     POST <upload.url>   multipart: every upload.fields entry, then key, then file
//     POST /forms/media/complete {key}  -> {url, storage, public}
//
// WHAT THIS PINS, each a way the feature fails without an error:
//   * the S3 request carries NO Authorization header (S3 rejects a POST with
//     both a header credential and a policy signature) and the file part comes
//     LAST (S3 ignores form fields after it);
//   * an OLDER server - no presign route, which answers 405 (its GET-only
//     `<path:key>` route matches the path) or 404 - still uploads, through
//     base64; but a 503 `s3_not_configured` is an answer, not a missing route;
//   * an S3 failure is SURFACED and never retried through base64, which would
//     push the same large file down the slow path the operator never chose.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

const String _key = 'form_studio/u1/clip.mp3';
const String _bucketUrl = 'https://bucket.s3.amazonaws.com/';
final List<int> _bytes = <int>[1, 2, 3, 4, 5];

/// The presign answer, in the shape the server returns.
Map<String, dynamic> get _ticket => <String, dynamic>{
  'upload': <String, dynamic>{
    'url': _bucketUrl,
    'fields': <String, dynamic>{
      'policy': 'POLICY',
      'x-amz-signature': 'SIG',
      'Content-Type': 'audio/mpeg',
    },
    'prefix': 'form_studio/u1/',
    'expires_at': '2026-10-06T12:00:00Z',
  },
  'key': _key,
};

http.Response _ok(Object data) => http.Response(
  jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

http.Response _refused(
  int status,
  String message, {
  String code = 'refused',
}) => http.Response(
  jsonEncode(<String, dynamic>{
    'ok': false,
    'error': <String, dynamic>{'code': code, 'message': message},
  }),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

/// A little rig: one fake API, one fake bucket, one shared call log.
class _Rig {
  _Rig({
    this.presign,
    this.s3 = 204,
    this.s3Throws = false,
    this.complete,
  }) {
    store = AppStore(
      api: ApiClient(
        // Authenticated, so a leak of this bearer onto the S3 request is visible.
        bearer: 'ADMIN-TOKEN',
        baseUrl: 'http://localhost:8069',
        client: MockClient(_api),
      ),
      s3Client: MockClient(_bucket),
    );
  }

  /// Answers `/forms/media/presign`. Null means the default good ticket.
  final http.Response Function()? presign;

  /// What the bucket answers with, or [s3Throws] for a dead network / CORS.
  final int s3;
  final bool s3Throws;

  /// Answers `/forms/media/complete`. Null means the default good answer.
  final http.Response Function()? complete;

  late final AppStore store;

  final List<String> log = <String>[];
  final Map<String, Map<String, dynamic>> bodies =
      <String, Map<String, dynamic>>{};
  final List<http.Request> bucketRequests = <http.Request>[];

  Future<http.Response> _api(http.Request req) async {
    final String route = req.url.path.replaceFirst('/api/v1/forms/media', '');
    final String name = route.isEmpty ? 'base64' : route.substring(1);
    log.add(name);
    bodies[name] = jsonDecode(req.body) as Map<String, dynamic>;
    switch (name) {
      case 'presign':
        return presign?.call() ?? _ok(_ticket);
      case 'complete':
        return complete?.call() ??
            _ok(<String, dynamic>{
              'url': '/api/v1/forms/media/$_key',
              'storage': 's3',
              'public': true,
            });
      case 'base64':
        return _ok(<String, dynamic>{
          'url': '/api/v1/forms/media/form_studio/legacy.mp3',
          'storage': 's3',
          'public': true,
        });
    }
    return _refused(404, 'no such route');
  }

  Future<http.Response> _bucket(http.Request req) async {
    log.add('s3');
    bucketRequests.add(req);
    if (s3Throws) throw http.ClientException('Failed to fetch', req.url);
    return http.Response('', s3);
  }

  Future<String?> upload() => store.uploadFormMedia(
    name: 'clip.mp3',
    bytes: _bytes,
    contentType: 'audio/mpeg',
  );

  List<ToastMsg> get toasts => store.toaster.items;
}

/// Where [needle] sits in a multipart [body], or -1.
int _at(String body, String needle) => body.indexOf('name="$needle"');

void main() {
  group('the happy path: presign, bucket, complete', () {
    test('the three calls run in order with the right bodies', () async {
      final _Rig rig = _Rig();

      final String? url = await rig.upload();

      expect(rig.log, <String>['presign', 's3', 'complete']);
      expect(rig.bodies['presign'], <String, dynamic>{
        'name': 'clip.mp3',
        'content_type': 'audio/mpeg',
        'size': 5,
      });
      expect(rig.bodies['complete'], <String, dynamic>{'key': _key});
      expect(url, '/api/v1/forms/media/$_key');
      expect(rig.toasts.single.message, 'Uploaded to S3');
    });

    test('the bucket gets the fields, then the key, then the file, no bearer',
        () async {
      final _Rig rig = _Rig();
      await rig.upload();

      final http.Request req = rig.bucketRequests.single;
      expect(req.method, 'POST');
      expect(req.url.toString(), _bucketUrl);
      expect(req.headers.keys.map((String k) => k.toLowerCase()),
          isNot(contains('authorization')),
          reason: 'S3 rejects a header credential beside a policy signature');
      expect(req.headers['content-type'], startsWith('multipart/form-data'));

      final String body = req.body;
      final List<int> order = <int>[
        _at(body, 'policy'),
        _at(body, 'x-amz-signature'),
        _at(body, 'Content-Type'),
        _at(body, 'key'),
        _at(body, 'file'),
      ];
      expect(order.every((int i) => i >= 0), isTrue,
          reason: 'a part is missing: $order');
      expect(order, orderedEquals(<int>[...order]..sort()),
          reason: 'every field must precede the file part: $order');
      expect(body, contains('POLICY'));
      expect(body, contains(_key));
      // THE STORED TYPE IS THE `Content-Type` FORM FIELD, which S3 checks
      // against the signed policy - not the file part's own header. It must
      // carry the signed type and come before the file part.
      expect(
        body,
        contains('name="Content-Type"\r\n\r\naudio/mpeg\r\n'),
        reason: 'the Content-Type field must carry the type the policy signed',
      );
      expect(_at(body, 'Content-Type'), lessThan(_at(body, 'file')));
    });

    test('the key is the one the server returned, even if fields names another',
        () async {
      final Map<String, dynamic> ticket = _ticket;
      (ticket['upload'] as Map<String, dynamic>)['fields']['key'] = 'stale';
      final _Rig rig = _Rig(presign: () => _ok(ticket));

      await rig.upload();

      final String body = rig.bucketRequests.single.body;
      expect(body, contains(_key));
      expect(body, isNot(contains('stale')));
    });
  });

  group('an older server falls back to base64', () {
    test('a JSON 404 from presign uploads through the old route', () async {
      final _Rig rig = _Rig(presign: () => _refused(404, 'not found'));

      final String? url = await rig.upload();

      expect(rig.log, <String>['presign', 'base64']);
      expect(rig.bucketRequests, isEmpty);
      expect(rig.bodies['base64']!['data'], base64Encode(_bytes));
      expect(rig.bodies['base64']!['content_type'], 'audio/mpeg');
      expect(url, '/api/v1/forms/media/form_studio/legacy.mp3');
    });

    test('an HTML 404 (an unregistered Odoo route) does too', () async {
      final _Rig rig = _Rig(
        presign: () => http.Response('<html>Not Found</html>', 404),
      );

      expect(await rig.upload(), isNotNull);
      expect(rig.log, <String>['presign', 'base64']);
    });

    // THE REAL PRE-PRESIGN SERVER. Its `<path:key>` media route is GET-only and
    // matches `/forms/media/presign`, so a POST there is a 405, not a 404.
    test('a 405 (a GET-only route matched the path) uploads through base64',
        () async {
      final _Rig rig = _Rig(
        presign: () => http.Response(
          '<!doctype html><title>405 Method Not Allowed</title>',
          405,
          headers: <String, String>{'content-type': 'text/html'},
        ),
      );

      final String? url = await rig.upload();

      expect(rig.log, <String>['presign', 'base64']);
      expect(rig.bucketRequests, isEmpty);
      expect(rig.bodies['base64']!['data'], base64Encode(_bytes));
      expect(url, '/api/v1/forms/media/form_studio/legacy.mp3');
    });

    test('a JSON 405 does too', () async {
      final _Rig rig = _Rig(presign: () => _refused(405, 'method not allowed'));

      expect(await rig.upload(), isNotNull);
      expect(rig.log, <String>['presign', 'base64']);
    });

    test('so does a browser that cannot tell a missing route from a dead host',
        () async {
      // Cross-origin dev: the 405 (or 404) of an older server carries no CORS
      // headers, so the browser hands the client a bare ClientException - a
      // transport error, not a status.
      final List<String> log = <String>[];
      final AppStore store = AppStore(
        api: ApiClient(
          baseUrl: 'http://localhost:8069',
          client: MockClient((http.Request req) async {
            final String route = req.url.path.split('/').last;
            log.add(route);
            if (route == 'presign') {
              throw http.ClientException('Failed to fetch', req.url);
            }
            return _ok(<String, dynamic>{'url': '/u', 'storage': 'attachment'});
          }),
        ),
      );

      final String? url = await store.uploadFormMedia(
        name: 'a.png',
        bytes: _bytes,
        contentType: 'image/png',
      );

      expect(log, <String>['presign', 'media']);
      expect(url, '/u');
    });
  });

  group('a failure is surfaced, never papered over', () {
    test('an S3 5xx says so, and neither completes nor falls back', () async {
      final _Rig rig = _Rig(s3: 503);

      final String? url = await rig.upload();

      expect(url, isNull);
      expect(rig.log, <String>['presign', 's3'],
          reason: 'no base64 retry, and the server is never told it succeeded');
      expect(rig.toasts.single.message, contains('503'));
      expect(rig.toasts.single.message, contains('Nothing was saved'));
    });

    test('an S3 403 (a bad policy) is surfaced the same way', () async {
      final _Rig rig = _Rig(s3: 403);

      expect(await rig.upload(), isNull);
      expect(rig.log, <String>['presign', 's3']);
      expect(rig.toasts.single.message, contains('403'));
    });

    test('a reply the browser may not read (no bucket CORS): the server '
        'confirms what landed', () async {
      // The POST reached S3 and the file is stored; only the answer was
      // withheld from the page. `/complete` asks S3 itself.
      final _Rig rig = _Rig(s3Throws: true);

      expect(await rig.upload(), '/api/v1/forms/media/$_key');
      expect(rig.log, <String>['presign', 's3', 'complete'],
          reason: 'never base64: the bytes go to S3 or nowhere');
    });

    test('a POST that never arrived is surfaced, in words', () async {
      final _Rig rig = _Rig(
        s3Throws: true,
        complete: () => _refused(404, 'Nothing was uploaded at that key.',
            code: 'not_found'),
      );

      expect(await rig.upload(), isNull);
      expect(rig.log, <String>['presign', 's3', 'complete']);
      expect(rig.toasts.single.message,
          contains('did not reach the storage bucket'));
    });

    test('a 503 s3_not_configured is surfaced, and base64 is NOT tried',
        () async {
      // Base64 would 503 too (there is no bucket to put it in), and a 100 MB
      // body would be sent to find that out.
      final _Rig rig = _Rig(
        presign: () => _refused(
          503,
          'Uploads are not configured on this server.',
          code: 's3_not_configured',
        ),
      );

      expect(await rig.upload(), isNull);
      expect(rig.log, <String>['presign'],
          reason: 'no base64 call, no bucket call');
      expect(rig.bucketRequests, isEmpty);
      expect(rig.toasts.single.message,
          'Uploads are not configured on this server.');
    });

    test('a presign refusal (a type the server will not take) is surfaced',
        () async {
      final _Rig rig = _Rig(
        presign: () => _refused(400, 'That file type is not allowed.'),
      );

      expect(await rig.upload(), isNull);
      expect(rig.log, <String>['presign'],
          reason: 'a 400 is a verdict, not a missing route');
      expect(rig.toasts.single.message, 'That file type is not allowed.');
    });

    test('a refused complete is surfaced', () async {
      final _Rig rig = _Rig(
        complete: () => _refused(400, 'Stored type is not allowed.'),
      );

      expect(await rig.upload(), isNull);
      expect(rig.log, <String>['presign', 's3', 'complete']);
      expect(rig.toasts.single.message, 'Stored type is not allowed.');
    });

    test('an incomplete ticket is surfaced, not posted to nowhere', () async {
      final _Rig rig = _Rig(
        presign: () => _ok(<String, dynamic>{'key': _key}),
      );

      expect(await rig.upload(), isNull);
      expect(rig.log, <String>['presign']);
      expect(rig.toasts.single.message, contains('incomplete'));
    });
  });
}
