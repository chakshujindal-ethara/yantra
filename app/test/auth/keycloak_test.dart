import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/auth/keycloak.dart';
import 'package:yantra_app/core/errors.dart';

import '../support/fake_backend.dart';

void main() {
  test('login posts the password grant and returns tokens', () async {
    final backend = FakeBackend({'POST $tokenPath': (_) => json(tokenResponse(access: 'a', refresh: 'r', expiresIn: 300))});
    final auth = KeycloakAuth(client: backend.client, config: testConfig);
    final before = DateTime.now();
    final tokens = await auth.login('worker1', 'yantra');
    expect(tokens.accessToken, 'a');
    expect(tokens.refreshToken, 'r');
    expect(tokens.expiresAt.isAfter(before.add(const Duration(minutes: 4))), isTrue);
    final form = Uri.splitQueryString(backend.requests.single.body);
    expect(form, {'grant_type': 'password', 'client_id': 'yantra-app', 'username': 'worker1', 'password': 'yantra'});
  });

  test('a refused login surfaces Keycloak\'s description', () async {
    final backend = FakeBackend({
      'POST $tokenPath': (_) => json({'error': 'invalid_grant', 'error_description': 'Invalid user credentials'}, status: 401),
    });
    final auth = KeycloakAuth(client: backend.client, config: testConfig);
    await expectLater(
      auth.login('worker1', 'wrong'),
      throwsA(isA<LoginFailedException>().having((e) => e.message, 'message', 'Invalid user credentials')),
    );
  });

  test('refresh posts the refresh_token grant', () async {
    final backend = FakeBackend({'POST $tokenPath': (_) => json(tokenResponse(access: 'a2'))});
    final auth = KeycloakAuth(client: backend.client, config: testConfig);
    final tokens = await auth.refresh('r1');
    expect(tokens.accessToken, 'a2');
    final form = Uri.splitQueryString(backend.requests.single.body);
    expect(form['grant_type'], 'refresh_token');
    expect(form['refresh_token'], 'r1');
  });

  test('an unreachable identity server is a TransportException', () async {
    final backend = FakeBackend({'POST $tokenPath': (_) => throw Exception('socket')});
    final auth = KeycloakAuth(client: backend.client, config: testConfig);
    await expectLater(auth.login('a', 'b'), throwsA(isA<TransportException>()));
  });
}
