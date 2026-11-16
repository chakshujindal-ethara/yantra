// Settings became WRITABLE, and a credential must survive a save that was not
// about it.
//
// THE HAZARD THIS EXISTS FOR. `/api/v1/settings` reports a secret as a
// boolean - it never sends the API key, the OAuth bearer or the S3 secret
// back - so the form can only ever render an EMPTY box next to a "Configured"
// badge. If Save then posted every field it holds, opening the screen to
// change a bucket name and pressing Save would post `s3_secret_key: ""` and
// silently disconnect storage. The rule is therefore asymmetric and easy to
// get backwards:
//
//   - a TEXT field is sent even when blank, because blank is how an override
//     is removed so the module falls back to its own default;
//   - a SECRET field is sent ONLY when something was typed into it.
//
// The wire keys are the SHORT ones. `settings_update` walks its own allow-list
// and reads `arg(key.split(".", 1)[1])`, so a qualified name matches nothing -
// and an unread key is silence rather than a 400, which once made Save report
// success over a value that never moved.
//
// Only the socket is faked; the real ApiClient, envelope handling and store
// logic all run.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter/material.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/admin/settings_screen.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

/// What `/api/v1/settings` really answers: every secret as a boolean, the
/// identity of the service account as plain text, and no key material at all.
Map<String, dynamic> get settingsPayload => <String, dynamic>{
  'models': <String, dynamic>{
    'generation': 'gemini-3.1-pro-preview',
    'scoring': 'gemini-3.1-pro-preview',
    'detection': 'gemini-3.1-pro-preview',
    'image': 'gemini-3-pro-image',
    'video': 'veo-3.1-generate-001',
    'fallback': 'gemini-2.5-pro',
    'default': 'gemini-3-pro-image',
  },
  'vertex': <String, dynamic>{
    'project_id': 'agon-development-499205',
    'location': 'global',
    'api_key_set': true,
    'access_token_set': false,
    'service_account': <String, dynamic>{
      'set': true,
      'filename': 'agon-development-499205-5cb4f96649ef.json',
      'client_email': 'etp@agon-development-499205.iam.gserviceaccount.com',
    },
  },
  'video': <String, dynamic>{
    'model': 'veo-3.1-generate-001',
    'location': 'us-central1',
    'default_duration_s': '8',
  },
  'scoring': <String, dynamic>{
    'shards': 1,
    'tick_limit': 20,
    'batch_size': 0,
    'llm_max_attempts': 0,
  },
  'storage': <String, dynamic>{
    's3_bucket': 'ethara-etp-assessment',
    's3_region': 'ap-south-1',
    's3_folder': 'assessments_be',
    's3_cdn_url': '',
    's3_max_retries': 3,
    's3_access_key_id': 'AKIAEXAMPLE',
    's3_secret_set': true,
    'configured': true,
  },
  'governance': <String, dynamic>{
    'daily_llm_cap_usd': 100.0,
    'per_evaluator_llm_cap_usd': 5.0,
    'pii_retention_days': 0,
    'score_outlier_sigma': 2.0,
  },
};

class _Spy {
  final List<String> paths = <String>[];
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  /// What `/api/v1/settings` answers. Mutable so a test can move the server
  /// under an open form, which is what a background refresh really does.
  Map<String, dynamic> settings = settingsPayload;

  /// Set: `/settings/update` refuses with this message, as the route does.
  String? refuse;

  http.Client get client => MockClient((http.Request req) async {
    paths.add(req.url.path);
    try {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
    } on FormatException {
      bodies.add(<String, dynamic>{});
    }
    if (refuse != null && req.url.path.endsWith('/update')) {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{'code': 'invalid', 'message': refuse},
        }),
        422,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    final Object data = req.url.path.endsWith('/settings')
        ? settings
        : <String, dynamic>{'updated': <String, dynamic>{}};
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });

  /// The body of the last call whose path contains [fragment].
  Map<String, dynamic> bodyFor(String fragment) {
    for (int i = paths.length - 1; i >= 0; i--) {
      if (paths[i].contains(fragment)) return bodies[i];
    }
    return <String, dynamic>{};
  }

  bool hit(String fragment) => paths.any((String p) => p.contains(fragment));
}

AppStore _live(_Spy spy) {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: spy.client),
  );
  s.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
  return s;
}

/// A store whose `/api/v1/settings` answers [settingsPayload] with [section]
/// overridden key by key - which is how a server that is a deploy behind, or
/// one holding a value this payload does not, is put under an open form.
_Spy _spyWith(String section, Map<String, dynamic> keys) {
  final _Spy spy = _Spy();
  spy.settings = <String, dynamic>{
    ...settingsPayload,
    section: <String, dynamic>{
      ...settingsPayload[section]! as Map<String, dynamic>,
      ...keys,
    },
  };
  return spy;
}

Future<void> open(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1600, 4000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: SettingsScreen(store: s)),
    ),
  );
  await t.pumpAndSettle();
}

/// The input under a given field LABEL.
///
/// Not `find.widgetWithText(TextField, <value>)`: a hint is rendered as a
/// Text too, so a value that happens to equal another field's placeholder
/// matches two inputs and the finder throws.
Finder inputNamed(String label) => find.descendant(
  of: find
      .ancestor(
        of: find.text(label.toUpperCase()),
        matching: find.byType(Field),
      )
      .first,
  matching: find.byType(TextField),
);

/// What [inputNamed] is currently showing.
String shown(WidgetTester t, String label) =>
    t.widget<TextField>(inputNamed(label)).controller!.text;

/// The Save button of the panel that contains [fieldLabel].
///
/// Every block has one, and `find.text('Save').last` reaches the LAST of
/// them - Retention, whose button is disabled because nothing in it was
/// touched. Tapping that is a no-op the test then reads as "the form did
/// not post", which is the wrong diagnosis of a passing form.
Finder saveNear(String fieldLabel) => find.descendant(
  of: find
      .ancestor(
        of: find.text(fieldLabel.toUpperCase()),
        matching: find.byType(Panel),
      )
      .first,
  matching: find.widgetWithText(Btn, 'Save'),
);

/// Press the Save of the panel holding [fieldLabel] and let the round trip,
/// the re-read and the toast's own dismiss timer all finish.
Future<void> save(WidgetTester t, String fieldLabel) async {
  await t.tap(saveNear(fieldLabel));
  await t.pumpAndSettle();
  await t.pump(const Duration(seconds: 4));
}

void main() {
  group('A save sends the short keys, and only what it was given', () {
    test('a text setting travels under its unqualified name', () async {
      final _Spy spy = _Spy();
      await _live(spy).saveSettings(<String, Object>{
        'vertex_project_id': 'agon-development-499205',
        's3_bucket': 'ethara-etp-assessment',
      });

      final Map<String, dynamic> body = spy.bodyFor('/settings/update');
      expect(body['vertex_project_id'], 'agon-development-499205');
      expect(body['s3_bucket'], 'ethara-etp-assessment');
      // Not `assessments_be_v2.vertex_project_id`, which the route reads
      // nothing from and answers 200 to.
      expect(
        body.keys.any((String k) => k.contains('.')),
        isFalse,
        reason: 'a qualified key matches no allow-list entry and is dropped',
      );
    });

    test('an untouched key is absent, not blank', () async {
      final _Spy spy = _Spy();
      await _live(spy).saveSettings(<String, Object>{'s3_bucket': 'b'});

      final Map<String, dynamic> body = spy.bodyFor('/settings/update');
      expect(body.containsKey('s3_secret_key'), isFalse);
      expect(body.containsKey('vertex_api_key'), isFalse);
    });

    test('a save re-reads the settings afterwards', () async {
      // `updated` echoes only what changed, and a secret comes back as a
      // boolean, so the screen cannot rebuild its own state from the response.
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await s.saveSettings(<String, Object>{'s3_bucket': 'b'});

      expect(spy.hit('/api/v1/settings'), isTrue);
      expect(
        (s.settings['storage'] as Map<String, dynamic>)['s3_bucket'],
        'ethara-etp-assessment',
      );
    });
  });

  group('The service account is uploaded, validated and never read back', () {
    test('the file rides as base64 with its filename', () async {
      final _Spy spy = _Spy();
      const String json = '{"type":"service_account"}';
      await _live(spy).uploadServiceAccount(utf8.encode(json), 'sa-key.json');

      final Map<String, dynamic> body = spy.bodyFor(
        '/settings/service_account',
      );
      expect(body['filename'], 'sa-key.json');
      expect(utf8.decode(base64Decode(body['content'] as String)), json);
    });

    test('no bytes CLEARS it rather than posting an empty file', () async {
      final _Spy spy = _Spy();
      await _live(spy).uploadServiceAccount(<int>[], '');

      expect(spy.bodyFor('/settings/service_account')['content'], '');
    });

    test('the read payload carries the identity but never the key', () async {
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await s.reloadSettings();

      final Map<String, dynamic> sa =
          (s.settings['vertex'] as Map<String, dynamic>)['service_account']
              as Map<String, dynamic>;
      expect(sa['set'], isTrue);
      expect(
        sa['client_email'],
        'etp@agon-development-499205.iam.gserviceaccount.com',
      );
      // The whole point: an identity, not key material.
      expect(sa.containsKey('private_key'), isFalse);
      expect(jsonEncode(s.settings), isNot(contains('BEGIN PRIVATE KEY')));
    });

    test('every secret is reported as a boolean', () async {
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await s.reloadSettings();

      final Map<String, dynamic> v =
          s.settings['vertex'] as Map<String, dynamic>;
      expect(v['api_key_set'], isTrue);
      expect(v['access_token_set'], isFalse);
      expect(v.containsKey('api_key'), isFalse);
      expect(
        (s.settings['storage'] as Map<String, dynamic>)['s3_secret_set'],
        isTrue,
      );
    });
  });

  test('nothing is posted at all without a backend', () async {
    final _Spy spy = _Spy();
    // A seeded store has no server to save to; it must say so rather than
    // appear to succeed.
    final AppStore s = AppStore();
    await s.saveSettings(<String, Object>{'s3_bucket': 'b'});
    expect(spy.hit('/settings/update'), isFalse);
  });

  // THROUGH THE REAL SCREEN. The store tests above prove the client sends
  // what it is given; these prove the FORM gives it the right thing.
  group('The form edits the four blocks and uploads the key', () {
    testWidgets('the four blocks carry the fields they always had', (
      WidgetTester t,
    ) async {
      await open(t, _live(_Spy())..settings = settingsPayload);

      for (final String label in <String>[
        // Models
        'Default model', 'Generation model', 'Scoring model',
        'Detection model', 'Flaw verification model', 'Utility model',
        'Image model', 'Video model', 'Video location',
        'Clip duration (seconds)', 'Fallback model', 'Thinking level',
        // Vertex
        'Vertex project ID', 'Vertex location', 'Vertex calls per minute',
        // Scoring
        'Retry attempts', 'Batch size', 'Tick limit', 'Shards',
        // Storage
        'Image storage bucket', 'Region', 'Access key ID', 'Key prefix',
        'CDN base URL', 'Upload retries', 'Redirect media to S3',
        // Retention and spend
        'Daily LLM cap (USD)', 'Per-candidate LLM cap (USD)',
        'PII retention (days)', 'Score outlier threshold (sigma)',
      ]) {
        expect(
          find.text(label.toUpperCase()),
          findsOneWidget,
          reason: 'missing: $label',
        );
      }
    });

    testWidgets('a spend cap of 0 is posted, not dropped', (
      WidgetTester t,
    ) async {
      // REPORTED FROM THE UI: "I set it to 0.00 and it broke."
      //
      // 0 and unset are different instructions and the whole stack has to keep
      // them apart. The original defect was on the Odoo form - core coerces a
      // falsy numeric to False and `set_param(False)` UNLINKS the row, so a
      // typed 0 silently restored the $100 default and re-saving could never
      // fix it. This test pins the CLIENT half of the same contract: the box
      // must post a real 0 rather than treat an empty-looking value as
      // "unchanged" and send nothing.
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Daily LLM cap (USD)'), '0');
      await t.enterText(inputNamed('Per-candidate LLM cap (USD)'), '0');
      await t.pumpAndSettle();
      await t.tap(saveNear('Daily LLM cap (USD)'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 4));

      final Map<String, dynamic> body = spy.bodyFor('/settings/update');
      expect(body['daily_llm_cap_usd'], 0);
      expect(body['per_evaluator_llm_cap_usd'], 0);
    });

    testWidgets('an ordinary cap value round-trips from the box', (
      WidgetTester t,
    ) async {
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Daily LLM cap (USD)'), '250');
      await t.pumpAndSettle();
      await t.tap(saveNear('Daily LLM cap (USD)'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 4));

      expect(spy.bodyFor('/settings/update')['daily_llm_cap_usd'], 250);
    });

    testWidgets('a cap box that will not parse is refused, never coerced', (
      WidgetTester t,
    ) async {
      // Coercing "abc" to 0 would REMOVE a spend cap on a typo - the one
      // direction this field must never fail in.
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Daily LLM cap (USD)'), 'abc');
      await t.pumpAndSettle();
      await t.tap(saveNear('Daily LLM cap (USD)'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 4));

      expect(
        spy.bodyFor('/settings/update'),
        isEmpty,
        reason:
            'nothing may be posted for an unparseable cap - coercing it '
            'to 0 would remove the cap on a typo',
      );
    });

    testWidgets('an on/off setting posts a real boolean, not a string', (
      WidgetTester t,
    ) async {
      // `ir.config_parameter` stores TEXT, and every falsy-looking string it
      // can hold - "0", "false", "" - is truthy to a plain bool(). A flag sent
      // as text is one careless read away from being permanently on, so the
      // route refuses anything that is not a real boolean and this pins that
      // the client sends one.
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.tap(find.byType(Switcher).first);
      await t.pumpAndSettle();
      await t.tap(saveNear('Redirect media to S3'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 4));

      final Object? sent = spy.bodyFor(
        '/settings/update',
      )['media_redirect_to_s3'];
      expect(sent, isA<bool>());
      expect(sent, isTrue);
    });

    testWidgets('a setting Odoo has and this screen lacked now saves', (
      WidgetTester t,
    ) async {
      // THE REPORTED GAP, pinned end to end. Sixteen settings existed on the
      // Odoo form and on no Flutter field; the API already read and wrote
      // almost all of them, so the app could not change values it was already
      // being sent. `vertex_location` is the one that costs the most when it is
      // wrong - Gemini 3.x serves from `global` only, and a 404 naming a model
      // that plainly exists is nearly always this.
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Vertex location'), 'us-central1');
      await t.pumpAndSettle();
      await t.tap(saveNear('Vertex location'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 4));

      expect(spy.bodyFor('/settings/update')['vertex_location'], 'us-central1');
    });

    testWidgets('a refusal names the field, not the wire key (RT-3)', (
      WidgetTester t,
    ) async {
      final _Spy spy = _Spy()
        ..refuse = 'scoring_shards must be between 1 and 8.';
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Shards'), '99');
      await t.pumpAndSettle();
      await t.tap(saveNear('Shards'));
      await t.pump();
      await t.pump();

      final List<String> said = s.toaster.items
          .map((ToastMsg m) => m.message)
          .toList();
      expect(said, contains('Shards must be between 1 and 8.'));
      expect(said.join(' '), isNot(contains('scoring_shards')));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 10));
    });

    testWidgets('a refusal that names no field of the panel is shown whole', (
      WidgetTester t,
    ) async {
      // Only a message that STARTS with a key of this panel is relabelled;
      // anything else is the module's own words, untouched.
      final _Spy spy = _Spy()..refuse = 'Settings are read-only right now.';
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Shards'), '2');
      await t.pumpAndSettle();
      await t.tap(saveNear('Shards'));
      await t.pump();
      await t.pump();

      expect(
        s.toaster.items.map((ToastMsg m) => m.message),
        contains('Settings are read-only right now.'),
      );
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 10));
    });

    testWidgets('a governance refusal names the cap, not its key (RT-3)', (
      WidgetTester t,
    ) async {
      final _Spy spy = _Spy()
        ..refuse = 'per_evaluator_llm_cap_usd must be at most 100.';
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Per-candidate LLM cap (USD)'), '500');
      await t.pumpAndSettle();
      await t.tap(saveNear('Per-candidate LLM cap (USD)'));
      await t.pump();
      await t.pump();

      final List<String> said = s.toaster.items
          .map((ToastMsg m) => m.message)
          .toList();
      expect(
        said,
        contains('Per-candidate LLM cap (USD) must be at most 100.'),
      );
      expect(said.join(' '), isNot(contains('per_evaluator_llm_cap_usd')));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 10));
    });

    testWidgets('a cap the screen refuses names the cap, not its key (RT-3)', (
      WidgetTester t,
    ) async {
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Daily LLM cap (USD)'), 'abc');
      await t.pumpAndSettle();
      await t.tap(saveNear('Daily LLM cap (USD)'));
      await t.pump();

      final List<String> said = s.toaster.items
          .map((ToastMsg m) => m.message)
          .toList();
      expect(said, contains('Daily LLM cap (USD) must be a number, 0 or more'));
      expect(said.join(' '), isNot(contains('daily_llm_cap_usd')));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 10));
    });

    testWidgets('a model name is editable and saves under its short key', (
      WidgetTester t,
    ) async {
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Fallback model'), 'gemini-3-pro');
      await t.pumpAndSettle();
      await t.tap(saveNear('Fallback model'));
      await t.pumpAndSettle();
      // Drain the success toast's own dismiss timer, which outlives the frame
      // and fails the test at teardown if it is still pending.
      await t.pump(const Duration(seconds: 4));

      expect(spy.bodyFor('/settings/update')['fallback_model'], 'gemini-3-pro');
    });

    testWidgets('a bucket is editable and saves', (WidgetTester t) async {
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(
        inputNamed('Image storage bucket'),
        'a-different-bucket',
      );
      await t.pumpAndSettle();
      await t.tap(saveNear('Image storage bucket'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 4));

      expect(
        spy.bodyFor('/settings/update')['s3_bucket'],
        'a-different-bucket',
      );
    });

    testWidgets('no credential is asked for as a text field', (
      WidgetTester t,
    ) async {
      await open(t, _live(_Spy())..settings = settingsPayload);

      // The S3 SECRET and the Vertex API key stay in Odoo; the service account
      // is a FILE. A password box on this screen would mean one of those
      // moved, which is a decision, not a refactor.
      //
      // 'ACCESS KEY ID' USED TO BE ON THIS LIST AND SHOULD NOT HAVE BEEN. It
      // is the identifier half of the credential, not the secret half: the
      // read route returns it in plain text and argues the distinction, the
      // Odoo form renders it unmasked beside the masked secret, and it already
      // travelled in both directions on the wire. Listing it here made the
      // panel's "credentials never reach this app" note true by omission -
      // there was no field because nobody had written one, not because the
      // value was withheld.
      for (final String gone in <String>[
        'SECRET ACCESS KEY',
        'API KEY',
        'STATIC OAUTH BEARER',
      ]) {
        expect(find.text(gone), findsNothing, reason: 'unexpected: $gone');
      }
      expect(
        find.text('ACCESS KEY ID'),
        findsOneWidget,
        reason: 'the identifier half is editable here; the secret is not',
      );
      expect(
        find.byWidgetPredicate((Widget w) => w is TextField && w.obscureText),
        findsNothing,
      );
    });

    testWidgets('the key is a file, and its identity is what is shown', (
      WidgetTester t,
    ) async {
      await open(t, _live(_Spy())..settings = settingsPayload);

      expect(find.text('Service account JSON'), findsOneWidget);
      expect(find.text('Configured'), findsOneWidget);
      // The two facts read OUT of the uploaded file - which is what makes an
      // upload visibly an act with a result.
      //
      // `findsWidgets`, not `findsOneWidget`: the project id now appears twice
      // and the two are different facts. The card states what the UPLOADED KEY
      // resolved to; the Vertex panel above holds the OVERRIDE an operator can
      // type. They agree on a healthy deployment, and the case worth seeing on
      // screen is the one where they do not - "the key is for the wrong
      // project" used to be diagnosable in this app and fixable only in Odoo.
      expect(find.text('agon-development-499205'), findsWidgets);
      expect(
        find.text('etp@agon-development-499205.iam.gserviceaccount.com'),
        findsOneWidget,
      );
      expect(
        find.text('agon-development-499205-5cb4f96649ef.json'),
        findsOneWidget,
      );
      // Never the key.
      expect(find.textContaining('BEGIN PRIVATE KEY'), findsNothing);
    });

    testWidgets('picking no file leaves the stored key alone', (
      WidgetTester t,
    ) async {
      // `pickFile` returns null off the web, which is exactly the "operator
      // pressed cancel" path. Nothing may be posted for it.
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.tap(find.widgetWithText(Btn, 'Replace'));
      await t.pumpAndSettle();

      expect(spy.hit('/settings/service_account'), isFalse);
    });

    testWidgets('an untouched field follows the server, a typed one holds', (
      WidgetTester t,
    ) async {
      // An upload changes values server-side, and the fields showing them have
      // to follow. But a background refresh must never overwrite what somebody
      // is halfway through typing - the store notifies on every refresh, and
      // one runs while this form is open.
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Image model'), 'half-typed');
      await t.pumpAndSettle();

      spy.settings = <String, dynamic>{
        ...settingsPayload,
        'models': <String, dynamic>{
          ...settingsPayload['models']! as Map<String, dynamic>,
          'image': 'changed-on-the-server',
          'fallback': 'also-changed',
        },
      };
      await s.reloadSettings();
      await t.pumpAndSettle();

      expect(find.text('half-typed'), findsOneWidget);
      expect(find.text('changed-on-the-server'), findsNothing);
      expect(find.text('also-changed'), findsOneWidget);
    });
  });

  // WHAT IS ON SCREEN IS WHAT SAVE WILL POST, and what comes back is what is
  // in force. A control that reports one value and saves another is worse than
  // a control that is missing: the operator has no reason to look again.
  group('The panel never shows one value and posts another', () {
    testWidgets('the S3 redirect toggle still moves after another box was '
        'edited', (WidgetTester t) async {
      // The toggle is fully controlled and the panel used to be the only thing
      // that repainted it - through a callback that stops calling setState once
      // the panel is already dirty. So after any other edit the switch kept
      // drawing its old position while the controller behind it, and therefore
      // Save, held the new one.
      final _Spy spy = _spyWith('storage', <String, dynamic>{
        'media_redirect_to_s3': true,
      });
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Key prefix'), 'assessments_be_stage');
      await t.pumpAndSettle();
      await t.tap(find.byType(Switcher));
      await t.pumpAndSettle();

      expect(
        t.widget<Switcher>(find.byType(Switcher)).value,
        isFalse,
        reason: 'the toggle has to show the value it is about to save',
      );

      await save(t, 'Redirect media to S3');
      expect(spy.bodyFor('/settings/update')['media_redirect_to_s3'], isFalse);
    });

    testWidgets('a setting this server never reported is not written back as '
        'blank', (WidgetTester t) async {
      // DEPLOY ORDER. `models.thinking_level` is new on the read route and old
      // on the write route, so a bundle that is ahead of its backend reads
      // nothing, shows blank - and, posting the whole panel, would clear a
      // configured LOW/MEDIUM/HIGH that nobody on this screen ever saw.
      final _Spy spy = _Spy(); // settingsPayload predates all three keys
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Detection model'), 'gemini-3.1-flash-lite');
      await t.pumpAndSettle();
      await save(t, 'Detection model');

      final Map<String, dynamic> body = spy.bodyFor('/settings/update');
      expect(body['detection_model'], 'gemini-3.1-flash-lite');
      for (final String unreported in <String>[
        'thinking_level',
        'verify_model',
        'utility_model',
      ]) {
        expect(
          body.containsKey(unreported),
          isFalse,
          reason:
              'the server did not report $unreported, so this screen has '
              'no value for it and must not overwrite the stored one',
        );
      }
    });

    testWidgets('an override the server reports as empty is still cleared', (
      WidgetTester t,
    ) async {
      // The other half of the rule, and the one that keeps the guard honest:
      // it keys off "the server never mentioned this field", not off "the box
      // is empty". A reported-empty value means no override is set, and
      // clearing a box is still how one is removed.
      final _Spy spy = _spyWith('models', <String, dynamic>{
        'thinking_level': 'HIGH',
        'utility': '',
      });
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Thinking level'), '');
      await t.pumpAndSettle();
      await save(t, 'Thinking level');

      final Map<String, dynamic> body = spy.bodyFor('/settings/update');
      expect(body['thinking_level'], '');
      expect(body['utility_model'], '');
    });

    testWidgets('an emptied number box comes back holding what is stored', (
      WidgetTester t,
    ) async {
      // An empty number is not a number the route can take - `float("")`
      // refuses the whole panel - so it is left out and the stored value
      // stands. The box then has to say so rather than sitting blank beside a
      // success toast.
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Upload retries'), '');
      await t.pumpAndSettle();
      await save(t, 'Upload retries');

      expect(
        spy.bodyFor('/settings/update').containsKey('s3_max_retries'),
        isFalse,
      );
      expect(
        shown(t, 'Upload retries'),
        '3',
        reason: 'the box must show the retry budget that is actually stored',
      );
    });

    testWidgets('a number the server resolves differently is shown resolved', (
      WidgetTester t,
    ) async {
      // `scoring.batch_size` is REPORTED RESOLVED: the route stores 0 happily
      // and the grader reads it back as 8. A box still reading 0 tells an
      // operator they have forced one answer per call while every call packs
      // eight.
      final _Spy spy = _spyWith('scoring', <String, dynamic>{
        'batch_size': 8,
        'llm_max_attempts': 3,
      });
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Batch size'), '0');
      await t.pumpAndSettle();
      await save(t, 'Batch size');

      expect(spy.bodyFor('/settings/update')['scoring_batch_size'], 0);
      expect(
        shown(t, 'Batch size'),
        '8',
        reason: 'the box must show the batch size the grader will really use',
      );
    });

    testWidgets('a clip length Veo will not take is refused before it is '
        'posted', (WidgetTester t) async {
      // `settings_update` validates the whole payload before its first write,
      // so posting 5 here would throw away every other edit in the Models
      // panel and return one 422 line about a field nobody was working on.
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Generation model'), 'gemini-3.8-flash');
      await t.enterText(inputNamed('Clip duration (seconds)'), '5');
      await t.pumpAndSettle();
      await save(t, 'Clip duration (seconds)');

      expect(
        spy.bodyFor('/settings/update'),
        isEmpty,
        reason:
            'a refusal the client can see costs nothing; the same refusal '
            'from the route discards the eleven fields beside it',
      );
      // And the allowed set is on screen, the way the scoring bounds are.
      expect(find.textContaining('4, 6 or 8'), findsOneWidget);
    });

    testWidgets('an unrecognised thinking level is refused, a real one saves', (
      WidgetTester t,
    ) async {
      // Stored verbatim, ignored by every call, and read straight back onto
      // this screen as though it were in force - and, because the parameter
      // backs an Odoo Selection, capable of breaking the back office's own
      // Settings page on the next save of any tab.
      final _Spy spy = _spyWith('models', <String, dynamic>{
        'thinking_level': '',
      });
      final AppStore s = _live(spy);
      await s.reloadSettings();
      await open(t, s);

      await t.enterText(inputNamed('Thinking level'), 'HIGHEST');
      await t.pumpAndSettle();
      await save(t, 'Thinking level');
      expect(spy.bodyFor('/settings/update'), isEmpty);

      await t.enterText(inputNamed('Thinking level'), 'HIGH');
      await t.pumpAndSettle();
      await save(t, 'Thinking level');
      expect(spy.bodyFor('/settings/update')['thinking_level'], 'HIGH');
    });

    testWidgets('the throughput knob is counted in candidates, not answers', (
      WidgetTester t,
    ) async {
      // `scoring_tick_limit` caps the EVALUATOR rows one shard claims, and one
      // evaluator is a candidate carrying every subjective answer on their
      // paper. Calling them answers under-reports the real answer rate by the
      // questions-per-paper factor - and puts Batch size, which really is
      // counted in answers, directly above it in the same apparent unit.
      await open(t, _live(_Spy())..settings = settingsPayload);

      expect(
        find.textContaining('Candidates one shard drains per minute'),
        findsOneWidget,
      );
      expect(find.textContaining('Answers one shard'), findsNothing);
      expect(
        find.textContaining('Answers packed into ONE Vertex call'),
        findsOneWidget,
      );
    });

    testWidgets('the banner does not promise a number box can be cleared', (
      WidgetTester t,
    ) async {
      // It promised it for every box on the page while it was true of the text
      // ones only, which is how an operator ends up believing they have
      // removed a rate ceiling that is still being enforced.
      await open(t, _live(_Spy())..settings = settingsPayload);

      expect(
        find.textContaining('Clearing a text box removes the override'),
        findsOneWidget,
      );
      expect(find.textContaining('A number cannot be cleared'), findsOneWidget);
    });
  });

  // The shuffle is another writable assessment setting, and it travels as the
  // POSITIVE `shuffle_questions` - never the module's `preserve_question_order`
  // negative. Both write paths must carry it under that snake_case key.
  group('The shuffle setting reaches the wire as shuffle_questions', () {
    test('create sends it, on by default', () async {
      final _Spy spy = _Spy();
      await _live(
        spy,
      ).addAssessment(Assessment(id: '', name: 'Warehouse Safety'));

      final Map<String, dynamic> body = spy.bodyFor('/assessments/create');
      expect(
        body['shuffle_questions'],
        isTrue,
        reason: 'a fresh assessment shuffles unless told otherwise',
      );
      // The negative spelling must never appear - that is the server's, and
      // sending it would double-flip the meaning.
      expect(body.containsKey('preserve_question_order'), isFalse);
    });

    test('an edit that flips it off sends shuffle_questions:false', () async {
      final _Spy spy = _Spy();
      // `updateAsm` diffs against what it already holds, so seed the store with
      // the shuffled default and then turn it off.
      final AppStore s = _live(spy);
      s.assessments = <Assessment>[
        Assessment(id: '7', name: 'Warehouse Safety'),
      ];

      await s.updateAsm(s.assessments.first.copyWith(shuffleQuestions: false));

      final Map<String, dynamic> body = spy.bodyFor('/assessments/7/update');
      expect(body['shuffle_questions'], isFalse);
    });

    test('an edit that does not touch it omits the key', () async {
      // The update route sends ONLY what changed, so a duration edit must not
      // drag shuffle_questions along.
      final _Spy spy = _Spy();
      final AppStore s = _live(spy);
      s.assessments = <Assessment>[
        Assessment(id: '7', name: 'Warehouse Safety', durationMinutes: 60),
      ];

      await s.updateAsm(s.assessments.first.copyWith(durationMinutes: 90));

      final Map<String, dynamic> body = spy.bodyFor('/assessments/7/update');
      expect(body.containsKey('shuffle_questions'), isFalse);
      expect(body['duration_minutes'], 90);
    });
  });
}
