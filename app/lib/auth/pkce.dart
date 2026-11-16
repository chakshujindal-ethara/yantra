import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../config.dart';

/// The pieces of one authorization-code-with-PKCE attempt (RFC 7636). Pure: no browser, no network.
class PkceAttempt {
  const PkceAttempt({required this.verifier, required this.state});

  final String verifier;
  final String state;

  /// A fresh verifier (43 characters of the unreserved alphabet) and a state nonce.
  factory PkceAttempt.generate([Random? random]) {
    final r = random ?? Random.secure();
    return PkceAttempt(verifier: _token(r, 43), state: _token(r, 24));
  }

  /// `BASE64URL(SHA256(verifier))` without padding.
  String get challenge => base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');

  Uri authorizeUri(AppConfig config, Uri redirectUri) => config.authorizeEndpoint.replace(
    queryParameters: {
      'client_id': AppConfig.clientId,
      'response_type': 'code',
      'scope': 'openid',
      'redirect_uri': redirectUri.toString(),
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    },
  );

  Map<String, String> toJson() => {'verifier': verifier, 'state': state};

  static PkceAttempt? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final v = m['verifier'];
      final s = m['state'];
      if (v is! String || s is! String || v.isEmpty || s.isEmpty) return null;
      return PkceAttempt(verifier: v, state: s);
    } on FormatException {
      return null;
    }
  }

  String encode() => jsonEncode(toJson());

  static const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  static String _token(Random r, int length) =>
      String.fromCharCodes(List.generate(length, (_) => _alphabet.codeUnitAt(r.nextInt(_alphabet.length))));
}

/// What Keycloak sent back on the redirect: a code and the state, or an error.
class AuthCallback {
  const AuthCallback({this.code = '', this.state = '', this.error = ''});

  final String code;
  final String state;
  final String error;

  bool get isPresent => code.isNotEmpty || error.isNotEmpty;

  static AuthCallback? parse(Uri uri) {
    final q = uri.queryParameters;
    final cb = AuthCallback(code: q['code'] ?? '', state: q['state'] ?? '', error: q['error'] ?? '');
    return cb.isPresent ? cb : null;
  }
}
