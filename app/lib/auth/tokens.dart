import 'dart:convert';

import '../core/json.dart';

/// A Keycloak token pair with the instant the access token stops working.
class Tokens {
  const Tokens({required this.accessToken, required this.refreshToken, required this.expiresAt});

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  /// From Keycloak's token response: `{access_token, refresh_token, expires_in}`.
  factory Tokens.fromTokenResponse(Json body, {DateTime? now}) {
    final issued = now ?? DateTime.now();
    return Tokens(
      accessToken: readString(body, 'access_token'),
      refreshToken: readString(body, 'refresh_token'),
      expiresAt: issued.add(Duration(seconds: readInt(body, 'expires_in'))),
    );
  }

  factory Tokens.fromJson(Json m) => Tokens(
    accessToken: readString(m, 'access_token'),
    refreshToken: readString(m, 'refresh_token'),
    expiresAt: readDateTime(m, 'expires_at') ?? DateTime.fromMillisecondsSinceEpoch(0),
  );

  Json toJson() => {'access_token': accessToken, 'refresh_token': refreshToken, 'expires_at': expiresAt.toUtc().toIso8601String()};

  String encode() => jsonEncode(toJson());

  static Tokens? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final m = decodeObjectOrEmpty(raw);
    if (readString(m, 'access_token').isEmpty) return null;
    return Tokens.fromJson(m);
  }

  /// True when the access token expires within [leeway] from [now].
  bool isExpiring({DateTime? now, Duration leeway = const Duration(seconds: 30)}) => (now ?? DateTime.now()).add(leeway).isAfter(expiresAt);

  /// The JWT payload, or an empty object when the token is not a JWT. Display and routing only; the
  /// gateway verifies.
  Json get claims {
    final parts = accessToken.split('.');
    if (parts.length != 3) return const {};
    try {
      return decodeObjectOrEmpty(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    } on FormatException {
      return const {};
    }
  }

  /// A `sub` claim read off the JWT payload, or empty.
  String get subject => readString(claims, 'sub');

  /// `preferred_username` off the JWT payload, or empty.
  String get username => readString(claims, 'preferred_username');

  /// The realm roles (`realm_access.roles`), the shell's only input for which destinations to show.
  Set<String> get roles => readList(readMap(claims, 'realm_access'), 'roles').whereType<String>().toSet();
}
