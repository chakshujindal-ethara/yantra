import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../auth/session.dart';
import '../core/errors.dart';
import '../core/json.dart';
import '../core/network_status.dart';

/// The one door to the gateway. Adds the bearer token and the idempotency key, turns the error envelope
/// into [ApiException], repairs a 401 with one refresh, and waits out a `request_in_flight` 409.
class GatewayClient {
  GatewayClient({
    required this._client,
    required this._tokens,
    required String baseUrl,
    this.timeout = const Duration(seconds: 20),
    Future<void> Function(Duration)? sleep,
    this.network,
    DateTime Function()? deviceClock,
  }) : _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
       _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
       _deviceClock = deviceClock ?? DateTime.now;

  final http.Client _client;
  final TokenProvider _tokens;
  final String _baseUrl;
  final Duration timeout;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _deviceClock;

  /// How far the gateway's clock is ahead of this device's, from the last answer's `Date` header.
  Duration _skew = Duration.zero;

  /// Now on the gateway's clock: the device clock corrected by the last answer's `Date` header (the
  /// device clock until one arrives). Every countdown and expiry decision reads this, so a device set
  /// minutes off neither cuts a sitting short nor lets a claim run past its time.
  DateTime serverNow() => _deviceClock().add(_skew);

  /// Told after every attempt whether the gateway answered; the shell's offline banner reads it.
  final NetworkStatus? network;

  static const inFlightRetries = 3;
  static const inFlightWait = Duration(seconds: 1);

  /// [accept] asks for another representation (`text/csv` for a statement export); read `bodyBytes` for
  /// a file the user will save.
  Future<http.Response> get(String path, {Map<String, String>? query, String accept = 'application/json'}) =>
      _send('GET', path, query: query, accept: accept);

  /// A mutation. [idempotencyKey] is the per-action key: reuse it on a retry of the same action.
  Future<http.Response> post(String path, {required String idempotencyKey, Object? body, Map<String, String>? query}) =>
      _send('POST', path, idempotencyKey: idempotencyKey, body: body, query: query);

  Future<http.Response> put(String path, {required String idempotencyKey, Object? body}) =>
      _send('PUT', path, idempotencyKey: idempotencyKey, body: body);

  Future<http.Response> patch(String path, {required String idempotencyKey, Object? body}) =>
      _send('PATCH', path, idempotencyKey: idempotencyKey, body: body);

  Future<http.Response> delete(String path, {required String idempotencyKey}) => _send('DELETE', path, idempotencyKey: idempotencyKey);

  Future<http.Response> _send(
    String method,
    String path, {
    String? idempotencyKey,
    Object? body,
    Map<String, String>? query,
    String accept = 'application/json',
  }) async {
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: query);
    final token = await _tokens.accessToken();
    if (token == null) throw const AuthRequiredException();

    var bearer = token;
    var response = await _once(method, uri, bearer, idempotencyKey, body, accept);
    if (response.statusCode == 401) {
      final fresh = await _tokens.refreshedAccessToken();
      if (fresh == null) {
        await _tokens.authLost();
        throw const AuthRequiredException();
      }
      bearer = fresh;
      response = await _once(method, uri, bearer, idempotencyKey, body, accept);
      if (response.statusCode == 401) {
        await _tokens.authLost();
        throw const AuthRequiredException();
      }
    }
    for (var attempt = 0; attempt < inFlightRetries && _isInFlight(response); attempt++) {
      await _sleep(inFlightWait);
      response = await _once(method, uri, bearer, idempotencyKey, body, accept);
    }
    if (response.statusCode >= 400) throw _error(response);
    return response;
  }

  Future<http.Response> _once(String method, Uri uri, String token, String? key, Object? body, String accept) async {
    final headers = <String, String>{'Authorization': 'Bearer $token', 'Accept': accept};
    if (key != null) headers['Idempotency-Key'] = key;
    final raw = body is RawBody ? body : null;
    final encoded = body == null ? null : (raw != null ? raw.text : jsonEncode(body));
    if (encoded != null) headers['Content-Type'] = raw?.contentType ?? 'application/json';
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (encoded != null) request.body = encoded;
    try {
      final streamed = await _client.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamed);
      network?.reportReachable(true);
      _readClock(response);
      return response;
    } on Exception catch (e) {
      network?.reportReachable(false);
      throw TransportException('Gateway unreachable (${e.runtimeType})', offline: !(network?.online ?? true));
    }
  }

  /// `Date` has a one-second grain, so a change under two seconds is noise and is ignored (a countdown
  /// never jitters). A browser only exposes it when the gateway lists it in Access-Control-Expose-Headers.
  void _readClock(http.Response r) {
    final date = r.headers['date'];
    if (date == null) return;
    final DateTime server;
    try {
      server = parseHttpDate(date);
    } on FormatException {
      return;
    }
    final skew = server.difference(_deviceClock());
    if ((skew - _skew).abs() >= const Duration(seconds: 2)) _skew = skew;
  }

  bool _isInFlight(http.Response r) => r.statusCode == 409 && readString(decodeObjectOrEmpty(r.body), 'code') == 'request_in_flight';

  static ApiException _error(http.Response r) {
    final envelope = decodeObjectOrEmpty(r.body);
    final retryAfter = int.tryParse(r.headers['retry-after'] ?? '');
    return ApiException(
      status: r.statusCode,
      code: readString(envelope, 'code').isEmpty ? 'http_${r.statusCode}' : readString(envelope, 'code'),
      message: readString(envelope, 'message'),
      requestId: readString(envelope, 'request_id'),
      retryAfter: retryAfter == null ? null : Duration(seconds: retryAfter),
      context: readMap(envelope, 'context'),
    );
  }
}

/// A request body sent as is (a bank's CSV return file), not JSON-encoded.
class RawBody {
  const RawBody(this.text, {this.contentType = 'text/plain'});
  final String text;
  final String contentType;
}
