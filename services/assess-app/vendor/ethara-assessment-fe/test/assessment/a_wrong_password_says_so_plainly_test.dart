// A wrong password reads "Wrong email or password.", not Odoo's raw "Access
// Denied": the gateway's 400 overwrites its own sentence with
// `str(AccessDenied())` (`utility.return_Response`). Every other refusal keeps
// the server's own words.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/session.dart';

Session _refusedWith(String message) => Session(
  api: ApiClient(
    baseUrl: 'http://stub',
    client: MockClient(
      (http.Request req) async => http.Response(
        jsonEncode(<String, dynamic>{
          'message': message,
          'errors': <String>[message],
          'status_code': 400,
        }),
        400,
        headers: <String, String>{'content-type': 'application/json'},
      ),
    ),
  ),
);

void main() {
  test('Access Denied becomes a sentence the candidate can act on', () async {
    final Session s = _refusedWith('Access Denied');
    addTearDown(s.dispose);
    expect(await s.signIn('ada@ethara.ai', 'nope'), isFalse);
    expect(s.error, 'Wrong email or password.');
  });

  test('any other refusal keeps the server sentence', () async {
    const String deactivated =
        'Your account has been deactivated. To reactivate it, please contact '
        'to the Administrator.';
    final Session s = _refusedWith(deactivated);
    addTearDown(s.dispose);
    expect(await s.signIn('ada@ethara.ai', 'hunter2'), isFalse);
    expect(s.error, deactivated);
  });
}
