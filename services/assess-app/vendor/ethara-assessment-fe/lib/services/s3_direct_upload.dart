/// Browser-to-S3 upload: POST the bytes straight to a presigned policy.
///
/// Step 2 of `AppStore.uploadFormMedia` (presign -> this -> complete). It lives
/// apart from `ApiClient` on purpose: the API client signs every call with a
/// bearer and a JSON content type, and S3 rejects a POST that carries an
/// `Authorization` header next to a policy signature. So this builds its own
/// request, with only the multipart headers `http` adds itself.
///
/// No JSON-sized timeout either: a 100 MB clip on a slow link legitimately takes
/// minutes, and the call is the one place in the app where that is correct.
library;

import 'package:http/http.dart' as http;

/// POST [bytes] to the presigned [upload] policy (`{url, fields, ...}` exactly as
/// the presign route answers) and return the HTTP status. S3 answers 204 when the
/// object is stored; the caller decides what counts as success.
///
/// ORDER IS PART OF THE CONTRACT: every entry of `upload['fields']` first, then
/// `key` (the one the server returned - it is what the policy is signed for),
/// then the `file` part LAST. S3 ignores any form field that follows the file.
///
/// THE STORED TYPE IS A FORM FIELD. S3 checks the signed `Content-Type` field in
/// `upload['fields']`, not the file part's own header, so the part carries none
/// here (`http` labels it application/octet-stream) and nothing is added to the
/// policy's fields - an extra field the policy did not sign is refused.
///
/// [client] is injected for tests; left null, a bare `http.Client` is made and
/// closed here. Network or CORS failures throw (`http.ClientException`) rather
/// than return a status - there is no response to report.
Future<int> postToS3({
  required Map<String, dynamic> upload,
  required String key,
  required String name,
  required List<int> bytes,
  http.Client? client,
}) async {
  final Object? url = upload['url'];
  if (url is! String || url.isEmpty) {
    throw const FormatException('The presign answer has no upload url.');
  }
  final http.MultipartRequest req = http.MultipartRequest(
    'POST',
    Uri.parse(url),
  );
  final Object? fields = upload['fields'];
  if (fields is Map) {
    for (final MapEntry<Object?, Object?> e in fields.entries) {
      req.fields['${e.key}'] = '${e.value}';
    }
  }
  // After the policy's own fields; replaces in place if `fields` already named it.
  req.fields['key'] = key;
  req.files.add(http.MultipartFile.fromBytes('file', bytes, filename: name));

  final http.Client c = client ?? http.Client();
  try {
    final http.StreamedResponse res = await c.send(req);
    // Read the body out so the connection is released; S3's own error XML is not
    // shown to the operator, the status is what the caller reports.
    await res.stream.drain<void>();
    return res.statusCode;
  } finally {
    if (client == null) c.close();
  }
}
