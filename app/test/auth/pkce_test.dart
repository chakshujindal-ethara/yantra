import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/auth/pkce.dart';

import '../support/fake_backend.dart';

void main() {
  test('the challenge is the RFC 7636 vector', () {
    const attempt = PkceAttempt(verifier: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk', state: 's');
    expect(attempt.challenge, 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  });

  test('a generated attempt is long enough, unreserved, and different each time', () {
    final a = PkceAttempt.generate(Random(1));
    final b = PkceAttempt.generate(Random(2));
    expect(a.verifier.length, 43);
    expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(a.verifier), isTrue);
    expect(a.verifier, isNot(b.verifier));
    expect(a.state, isNot(b.state));
  });

  test('the authorize URL carries the public client, S256 and the redirect', () {
    const attempt = PkceAttempt(verifier: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk', state: 'st');
    final uri = attempt.authorizeUri(testConfig, Uri.parse('http://localhost:8095/'));
    expect(uri.toString(), startsWith('http://keycloak.test/realms/yantra/protocol/openid-connect/auth?'));
    expect(uri.queryParameters, {
      'client_id': 'yantra-app',
      'response_type': 'code',
      'scope': 'openid',
      'redirect_uri': 'http://localhost:8095/',
      'state': 'st',
      'code_challenge': 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      'code_challenge_method': 'S256',
    });
  });

  test('an attempt survives storage and refuses junk', () {
    final attempt = PkceAttempt(verifier: 'v' * 43, state: 'st');
    expect(PkceAttempt.decode(attempt.encode())?.verifier, 'v' * 43);
    expect(PkceAttempt.decode(null), isNull);
    expect(PkceAttempt.decode('nope'), isNull);
    expect(PkceAttempt.decode('{"verifier":""}'), isNull);
    expect(PkceAttempt.decode('[1]'), isNull);
  });

  test('a callback is only present with a code or an error', () {
    expect(AuthCallback.parse(Uri.parse('http://localhost:8095/')), isNull);
    expect(AuthCallback.parse(Uri.parse('http://localhost:8095/?code=c&state=s'))?.code, 'c');
    expect(AuthCallback.parse(Uri.parse('http://localhost:8095/?error=access_denied'))?.error, 'access_denied');
  });
}
