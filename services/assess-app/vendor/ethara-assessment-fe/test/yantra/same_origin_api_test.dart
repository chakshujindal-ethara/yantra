// Yantra serves this bundle behind its own nginx, which proxies the API on the
// page's origin. `API_BASE_URL=same-origin` says exactly that, so one bundle
// runs on any host Yantra deploys it to.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/data/environment.dart';

void main() {
  test('same-origin resolves to the page origin, whatever the host', () {
    for (final String page in <String>[
      'http://localhost:8096/yantra/launch#ticket=x',
      'https://assess.yantra.example/exam/abc',
    ]) {
      final Uri url = Uri.parse(page);
      final EnvironmentProfile p = resolveEnvironment(
        url,
        baseUrlOverride: 'same-origin',
        dbOverride: '',
      );
      expect(p.apiBaseUrl, url.origin);
      expect(p.environment, environmentForHost(url.host));
    }
  });

  test('a real URL is still taken as given', () {
    final EnvironmentProfile p = resolveEnvironment(
      Uri.parse('http://localhost:8096/'),
      baseUrlOverride: 'http://odoo:8069/',
      dbOverride: '',
    );
    expect(p.apiBaseUrl, 'http://odoo:8069');
  });
}
