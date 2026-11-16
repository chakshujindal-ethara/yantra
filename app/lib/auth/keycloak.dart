import 'package:http/http.dart' as http;

import '../config.dart';
import '../core/errors.dart';
import '../core/json.dart';
import 'tokens.dart';

/// The grants against the public `yantra-app` client: password (the local rig), authorization code with
/// PKCE (the browser redirect), refresh, and the back-channel logout that ends the Keycloak session.
class KeycloakAuth {
  KeycloakAuth({required this._client, required this._config, this.timeout = const Duration(seconds: 15)});

  final http.Client _client;
  final AppConfig _config;
  final Duration timeout;

  Future<Tokens> login(String username, String password) =>
      _grant({'grant_type': 'password', 'client_id': AppConfig.clientId, 'username': username, 'password': password});

  Future<Tokens> refresh(String refreshToken) =>
      _grant({'grant_type': 'refresh_token', 'client_id': AppConfig.clientId, 'refresh_token': refreshToken});

  /// The code Keycloak sent to the redirect URI, proven with the verifier of the same attempt.
  Future<Tokens> exchangeCode({required String code, required String verifier, required Uri redirectUri}) => _grant({
    'grant_type': 'authorization_code',
    'client_id': AppConfig.clientId,
    'code': code,
    'code_verifier': verifier,
    'redirect_uri': redirectUri.toString(),
  });

  /// Ends the Keycloak session behind the refresh token, so a later redirect asks for credentials again.
  /// Best effort: the local sign-out proceeds whatever the server says.
  Future<void> logout(String refreshToken) async {
    if (refreshToken.isEmpty) return;
    try {
      await _client.post(_config.logoutEndpoint, body: {'client_id': AppConfig.clientId, 'refresh_token': refreshToken}).timeout(timeout);
    } on Exception {
      // the local session is dropped regardless
    }
  }

  Future<Tokens> _grant(Map<String, String> form) async {
    final http.Response response;
    try {
      response = await _client.post(_config.tokenEndpoint, body: form).timeout(timeout);
    } on Exception catch (e) {
      throw TransportException('Identity server unreachable (${e.runtimeType})');
    }
    final body = decodeObjectOrEmpty(response.body);
    if (response.statusCode != 200) {
      final detail = readString(body, 'error_description');
      final error = readString(body, 'error');
      throw LoginFailedException(detail.isNotEmpty ? detail : (error.isNotEmpty ? error : 'Sign-in failed (${response.statusCode})'));
    }
    final tokens = Tokens.fromTokenResponse(body);
    if (tokens.accessToken.isEmpty) throw const LoginFailedException('Identity server sent no access token');
    return tokens;
  }
}
