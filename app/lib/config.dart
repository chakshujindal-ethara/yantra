import 'dart:convert';

import 'package:http/http.dart' as http;

/// Where the app finds the gateway and Keycloak. At start the app reads `/config.json`, which the image
/// renders from its environment (so one build serves every environment); a field the file leaves out,
/// or a missing file, falls back to the build's `--dart-define` values
/// (`GATEWAY_URL`, `KEYCLOAK_URL`, `DIRECT_LOGIN`).
class AppConfig {
  const AppConfig({required this.gatewayUrl, required this.keycloakUrl, this.directLogin = false});

  static const AppConfig fromEnvironment = AppConfig(
    gatewayUrl: String.fromEnvironment('GATEWAY_URL', defaultValue: 'http://localhost:8090'),
    keycloakUrl: String.fromEnvironment('KEYCLOAK_URL', defaultValue: 'http://localhost:8180'),
    directLogin: bool.fromEnvironment('DIRECT_LOGIN', defaultValue: false),
  );

  final String gatewayUrl;
  final String keycloakUrl;

  /// The runtime file over the build values; any failure keeps the build values.
  static Future<AppConfig> load({http.Client? client, Uri? at}) async {
    const base = fromEnvironment;
    final c = client ?? http.Client();
    try {
      final r = await c.get(at ?? Uri.base.resolve('/config.json')).timeout(const Duration(seconds: 3));
      if (r.statusCode != 200) return base;
      return base.overlay(jsonDecode(r.body));
    } on Object {
      return base;
    } finally {
      if (client == null) c.close();
    }
  }

  /// [base] with the non-empty string (and boolean) fields of [doc] laid over it.
  AppConfig overlay(Object? doc) {
    if (doc is! Map) return this;
    String pick(String key, String fallback) {
      final v = doc[key];
      return v is String && v.trim().isNotEmpty ? v.trim() : fallback;
    }

    final direct = doc['direct_login'];
    return AppConfig(
      gatewayUrl: pick('gateway_url', gatewayUrl),
      keycloakUrl: pick('keycloak_url', keycloakUrl),
      directLogin: direct is bool ? direct : directLogin,
    );
  }

  /// Whether the username/password form is offered next to the Keycloak redirect. Off unless the build
  /// says `DIRECT_LOGIN=true` (the local rig does; its realm allows the password grant).
  final bool directLogin;

  static const realm = 'yantra';
  static const clientId = 'yantra-app';

  Uri get _oidc => Uri.parse('$keycloakUrl/realms/$realm/protocol/openid-connect');
  Uri get tokenEndpoint => Uri.parse('$_oidc/token');
  Uri get authorizeEndpoint => Uri.parse('$_oidc/auth');
  Uri get logoutEndpoint => Uri.parse('$_oidc/logout');
}
