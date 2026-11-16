/// Signing out must not shut the app's only HTTP client.
///
/// WHY THIS EXISTS. `AppShell` builds its `AppStore` over `session.api`, and
/// the `Session` outlives every shell it builds. `AppStore.dispose` closed
/// that client anyway, so signing out closed the one `http.Client` the app
/// has. The next sign-in threw `Client is already closed` before a byte left
/// the browser, which the client reports as a TRANSPORT failure - "Could not
/// reach the server at ... /api/v1/auth_token" - blaming the backend for a
/// socket this app had shut. Only a full page reload cured it. The same path
/// runs when switching accounts, because `AppShell` is keyed on `session.uid`.
///
/// A `MockClient` cannot catch this: its `close()` is a no-op and it keeps
/// answering afterwards. These tests use a client that records the close and
/// refuses afterwards, the way `BrowserClient` does.
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Mirrors `BrowserClient`: refuses every send once closed.
class _ClosableClient extends http.BaseClient {
  bool closed = false;
  int sends = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (closed) {
      throw http.ClientException(
        'HTTP request failed. Client is already closed.',
        request.url,
      );
    }
    sends++;
    return http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode('{"ok": true, "access_token": "t", "refresh_token": "r"}'),
      ),
      200,
    );
  }

  @override
  void close() => closed = true;
}

void main() {
  test('disposing a store does not close a client it was handed', () async {
    final _ClosableClient http_ = _ClosableClient();
    final ApiClient api = ApiClient(
      baseUrl: 'https://example.invalid',
      client: http_,
    );

    AppStore(api: api).dispose();

    expect(
      http_.closed,
      isFalse,
      reason: 'the Session owns this client and outlives the store; closing '
          'it on sign-out breaks the next sign-in',
    );
  });

  test('the client still works after a sign-out disposes its store', () async {
    final _ClosableClient http_ = _ClosableClient();
    final ApiClient api = ApiClient(
      baseUrl: 'https://example.invalid',
      client: http_,
    );

    // First session: a shell mounts, then sign-out unmounts and disposes it.
    AppStore(api: api).dispose();

    // Second sign-in over the SAME client - the step that used to throw.
    await expectLater(api.login('admin', 'secret'), completes);
    expect(http_.sends, greaterThan(0));
  });
}
