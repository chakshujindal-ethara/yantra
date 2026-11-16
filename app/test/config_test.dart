import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yantra_app/config.dart';

void main() {
  const base = AppConfig(gatewayUrl: 'http://g', keycloakUrl: 'http://k');

  test('the runtime file overrides the non-empty fields only', () {
    final c = base.overlay({'gateway_url': ' https://api.example.org ', 'keycloak_url': '', 'direct_login': true});
    expect(c.gatewayUrl, 'https://api.example.org');
    expect(c.keycloakUrl, 'http://k');
    expect(c.directLogin, isTrue);
    expect(base.overlay([1]).gatewayUrl, 'http://g');
    expect(base.overlay({'direct_login': 'yes'}).directLogin, isFalse);
  });

  test('load reads /config.json and keeps the build values on any failure', () async {
    Future<AppConfig> load(http.Response Function() answer) =>
        AppConfig.load(client: MockClient((_) async => answer()), at: Uri.parse('http://app/config.json'));
    expect((await load(() => http.Response('{"gateway_url":"https://api"}', 200))).gatewayUrl, 'https://api');
    expect((await load(() => http.Response('', 404))).gatewayUrl, AppConfig.fromEnvironment.gatewayUrl);
    expect((await load(() => http.Response('<html>', 200))).gatewayUrl, AppConfig.fromEnvironment.gatewayUrl);
    final down = await AppConfig.load(client: MockClient((_) async => throw http.ClientException('x')), at: Uri.parse('http://app/c'));
    expect(down.keycloakUrl, AppConfig.fromEnvironment.keycloakUrl);
  });
}
