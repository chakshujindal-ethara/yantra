// Which backend this bundle talks to, per host it is served from.
//
// WHY THIS IS WORTH A TEST. The pairing used to be a compile-time define, so
// getting it wrong produced a bundle that ran perfectly against the WRONG
// environment: production's browser calling stage, stage answering 200 to
// everything, and no server-side symptom at all. The table below is now the
// only thing standing between a promoted image and that failure, and it is
// mirrored by `assessments_be_v2/services/app_origins.py` on the server - so a
// silent edit here is a CORS refusal there.
//
// Pure functions only. `resolveEnvironment` takes the page URL and the defines
// as ARGUMENTS precisely so this runs on the VM, where `Uri.base` is a
// `file://` path with no host.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/data/environment.dart';

void main() {
  group('the host decides the environment', () {
    test('the new production console pairs with the new backend', () {
      final EnvironmentProfile p = resolveEnvironment(
        Uri.parse('https://assessment.ethara.ai/'),
        baseUrlOverride: '',
        dbOverride: '',
      );
      expect(p.environment, AppEnvironment.production);
      expect(p.apiBaseUrl, 'https://projects.ethara.ai');
      // Stage and production sign in through the bearer gateway, which names
      // no database. A value here would be sent on a lane that is never taken.
      expect(p.apiDb, isEmpty);
    });

    test('stage pairs with stage, NOT with production', () {
      final EnvironmentProfile p = resolveEnvironment(
        Uri.parse('https://assessment-stage.ethara.ai/'),
        baseUrlOverride: '',
        dbOverride: '',
      );
      expect(p.environment, AppEnvironment.stage);
      expect(p.apiBaseUrl, 'https://projects-stage.ethara.ai');
      expect(p.apiDb, isEmpty);
    });

    test('the two Ethara hosts never resolve to each other', () {
      // The whole point of the change. Spelled out as its own assertion
      // because a copy-paste in the table would satisfy both tests above
      // individually while pointing stage at production.
      final String prod = resolveEnvironment(
        Uri.parse('https://assessment.ethara.ai/'),
        baseUrlOverride: '',
      ).apiBaseUrl;
      final String stage = resolveEnvironment(
        Uri.parse('https://assessment-stage.ethara.ai/'),
        baseUrlOverride: '',
      ).apiBaseUrl;
      expect(prod, isNot(stage));
      expect(prod, isNot(contains('-stage')));
      expect(stage, contains('-stage'));
    });

    test('localhost is LABELLED local but is given no backend', () {
      // THE ONE THAT DECIDED THE DESIGN. `flutter test --platform chrome`
      // serves this very suite from `http://localhost:<random>/x_test.html`, so
      // a table that mapped localhost to `localhost:8069` handed ~1280 widget
      // tests a live backend: `hasBackend` went true, stores that should have
      // loaded seed data tried to sign in, and the whole Chrome suite went red.
      //
      // No runtime signal separates a dev server from a test harness, so local
      // development names its backend with the define - which is what
      // `make serve-local` already passes.
      for (final String url in <String>[
        'http://localhost:8200/',
        'http://127.0.0.1:8200/',
        'http://localhost:63649/environment_resolution_test.html',
        'http://localhost/',
      ]) {
        final EnvironmentProfile p = resolveEnvironment(
          Uri.parse(url),
          baseUrlOverride: '',
          dbOverride: '',
        );
        expect(p.environment, AppEnvironment.local, reason: url);
        expect(p.apiBaseUrl, isEmpty, reason: url);
      }
    });

    test('the port is ignored, and 127.0.0.1 is not a different deployment',
        () {
      // A browser treats localhost and 127.0.0.1 as different origins, so a
      // label keyed on one would be wrong half the time.
      expect(environmentForHost('localhost'), AppEnvironment.local);
      expect(environmentForHost('127.0.0.1'), AppEnvironment.local);
    });

    test('a local build reaches a local Odoo when it is told to', () {
      // The supported path, and what `make serve-local` / `make build ENV=local`
      // pass. Odoo is on 8069 while the app is served on 8200, so without this
      // every call POSTs at the static file server - a 501 that surfaces as
      // "Unexpected response from /api/v1/auth_token".
      final EnvironmentProfile p = resolveEnvironment(
        Uri.parse('http://localhost:8200/'),
        baseUrlOverride: kLocalBackendUrl,
        dbOverride: kLocalApiDb,
      );
      expect(p.environment, AppEnvironment.local);
      expect(p.apiBaseUrl, 'http://localhost:8069');
      expect(p.apiDb, 'etp_local');
    });

    test('a hostname matches whatever case it arrives in', () {
      expect(
        environmentForHost('Assessment.Ethara.AI'),
        AppEnvironment.production,
      );
    });

    test('an unlisted host falls back to its own origin, not to a guess', () {
      // A preview deploy or a bare IP must NOT be pointed at production. Empty
      // means same-origin, which is also what puts the app on seed data.
      for (final String url in <String>[
        'https://assessment-preview-42.example.com/',
        'https://10.0.0.5/',
        'file:///Users/cj/build/web/index.html',
      ]) {
        final EnvironmentProfile p = resolveEnvironment(
          Uri.parse(url),
          baseUrlOverride: '',
          dbOverride: '',
        );
        expect(p.environment, AppEnvironment.unknown, reason: url);
        expect(p.apiBaseUrl, isEmpty, reason: url);
      }
    });
  });

  group('an explicit define still wins', () {
    test('a stage bundle served from localhost talks to STAGE', () {
      // `make serve-stage` serves a stage bundle on 127.0.0.1:8201. Without
      // this rule the host table would send it at localhost:8069 and break the
      // only workflow for pointing a local build at a remote backend.
      final EnvironmentProfile p = resolveEnvironment(
        Uri.parse('http://127.0.0.1:8201/'),
        baseUrlOverride: 'https://projects-stage.ethara.ai',
        dbOverride: '',
      );
      expect(p.apiBaseUrl, 'https://projects-stage.ethara.ai');
    });

    test('the environment is still reported from the host, not the override',
        () {
      // The console shows its own backend, and labelling a served-locally
      // stage bundle "unknown" would make that readout useless.
      final EnvironmentProfile p = resolveEnvironment(
        Uri.parse('http://127.0.0.1:8201/'),
        baseUrlOverride: 'https://projects-stage.ethara.ai',
      );
      expect(p.environment, AppEnvironment.local);
    });

    test('a trailing slash on the override is stripped', () {
      // Every path is concatenated onto this, so a trailing slash produces
      // `//api/v1/...` - which Odoo does not route.
      final EnvironmentProfile p = resolveEnvironment(
        Uri.parse('https://assessment.ethara.ai/'),
        baseUrlOverride: 'https://projects.ethara.ai///',
      );
      expect(p.apiBaseUrl, 'https://projects.ethara.ai');
    });

    test('an override of whitespace only is treated as absent', () {
      // A Makefile or Docker build-arg that expands to nothing arrives as "",
      // and CI has been seen to pass a bare space. Either must fall through to
      // the host table rather than blanking the backend.
      final EnvironmentProfile p = resolveEnvironment(
        Uri.parse('https://assessment.ethara.ai/'),
        baseUrlOverride: '   ',
      );
      expect(p.apiBaseUrl, 'https://projects.ethara.ai');
    });
  });

  group('the table itself', () {
    test('every environment has a profile that reports itself', () {
      for (final AppEnvironment e in AppEnvironment.values) {
        final EnvironmentProfile? p = kEnvironmentProfiles[e];
        expect(p, isNotNull, reason: '$e has no profile');
        expect(p!.environment, e, reason: '$e profile reports ${p.environment}');
      }
    });

    test('every DEPLOYED environment names a backend', () {
      // A deployed environment with an empty base URL would silently put the
      // app on seed data in front of real users. local and unknown are the two
      // that legitimately have none - see the localhost note above.
      for (final AppEnvironment e in AppEnvironment.values) {
        final bool empty = kEnvironmentProfiles[e]!.apiBaseUrl.isEmpty;
        final bool mayBeEmpty =
            e == AppEnvironment.unknown || e == AppEnvironment.local;
        expect(empty, mayBeEmpty, reason: '$e');
      }
    });

    test('the two deployed profiles are the only https ones, and are distinct',
        () {
      expect(
        <String>[
          kEnvironmentProfiles[AppEnvironment.production]!.apiBaseUrl,
          kEnvironmentProfiles[AppEnvironment.stage]!.apiBaseUrl,
        ],
        <String>['https://projects.ethara.ai', 'https://projects-stage.ethara.ai'],
      );
    });

    test('no profile URL carries a trailing slash', () {
      for (final EnvironmentProfile p in kEnvironmentProfiles.values) {
        expect(p.apiBaseUrl.endsWith('/'), isFalse, reason: p.apiBaseUrl);
      }
    });

    test('every host maps to an environment that is not unknown', () {
      for (final MapEntry<String, AppEnvironment> e
          in kHostEnvironments.entries) {
        expect(e.value, isNot(AppEnvironment.unknown), reason: e.key);
      }
    });
  });

  group('resolution cannot take the app down', () {
    test('a page URL with no host resolves instead of throwing', () {
      // `activeEnvironment` is a lazy top-level final that EVERY read of
      // `kApiBaseUrl` goes through, and Dart re-throws a failed lazy
      // initialisation on every subsequent read. A throw here is not a wrong
      // backend, it is a blank screen on every route with no recovery.
      for (final String odd in <String>[
        'about:blank',
        'data:text/html,<p>x',
        '/relative/only',
        '',
      ]) {
        expect(
          () => resolveEnvironment(Uri.parse(odd), baseUrlOverride: ''),
          returnsNormally,
          reason: odd,
        );
        expect(
          resolveEnvironment(Uri.parse(odd), baseUrlOverride: '').apiBaseUrl,
          isEmpty,
          reason: odd,
        );
      }
    });

    test('an odd page URL still honours an explicit pin', () {
      // A pinned bundle knows its backend without asking the page.
      expect(
        resolveEnvironment(Uri.parse('about:blank'),
                baseUrlOverride: 'https://projects.ethara.ai')
            .apiBaseUrl,
        'https://projects.ethara.ai',
      );
    });
  });

  group('under test the app stays on seed data', () {
    test('activeEnvironment has no backend on EITHER platform', () {
      // THE GUARD FOR THE WHOLE SUITE. `hasBackend` false is what keeps ~1280
      // widget tests off the network - see the note in
      // test/assessment/password_change_test.dart.
      //
      // Asserted without naming an environment, because the two platforms
      // disagree and both are correct: on the VM `Uri.base` is a `file://`
      // directory with no host (unknown), and under `--platform chrome` it is
      // `http://localhost:<random>/..._test.html` (local). What has to hold on
      // both is that no backend comes out of it.
      expect(activeEnvironment.apiBaseUrl, isEmpty);
      expect(activeEnvironment.apiDb, isEmpty);
    });
  });
}
