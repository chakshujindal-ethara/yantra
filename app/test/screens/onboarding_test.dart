import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:yantra_app/core/theme/app_theme.dart';

import '../support/fake_backend.dart';
import 'fixtures.dart';
import 'fixtures_talent.dart';

Future<TestHarness> openOnboarding(WidgetTester tester, FakeBackend backend, {Size size = const Size(900, 2400)}) async {
  backend.routes.putIfAbsent(
    'GET /v1/claims/active',
    () =>
        (_) => json(emptyActive),
  );
  backend.routes.putIfAbsent(
    'GET /v1/batches',
    () =>
        (_) => json([]),
  );
  final harness = await pumpApp(tester, backend, size: size);
  await goTo(tester, '/work/home/onboarding');
  return harness;
}

Map<String, dynamic> putBody(FakeBackend backend, String step) =>
    jsonDecode(backend.sent('PUT', '/v1/talent/workers/me/onboarding/$step').single.body) as Map<String, dynamic>;

Finder chip(String label) => find.widgetWithText(StatusChip, label);

Map<String, Object?> bankJson({required String status, String? reason}) => {
  'status': status,
  'verification': 'penny_drop',
  'account_name': 'A Rao',
  'account_last4': '9012',
  'ifsc': 'HDFC0001234',
  'registered_name_match': status == 'verified' ? true : null,
  'verified_at': status == 'verified' ? '2026-11-04T10:00:00Z' : null,
  'failure_reason': reason,
};

Map<String, Object?> policyJson(String slug, String version, String text) => {
  'slug': slug,
  'version': version,
  'revision': 1,
  'title': slug == 'dpdp-consent' ? 'Data consent' : 'Contractor agreement',
  'summary': 'Summary',
  'sections': [
    {
      'title': 'Terms',
      'paragraphs': [text],
      'bullets': <String>[],
    },
  ],
  'updated_at': '2026-11-01T00:00:00Z',
};

void main() {
  testWidgets('the grouped checklist shows n of 6, what is left, what blocks the first claim, and gates bank on profile', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding(done: {'profile', 'agreement'})),
    });
    await openOnboarding(tester, backend);
    expect(find.text('2 of 6'), findsOneWidget);
    expect(find.text('4 steps left; you can finish later'), findsOneWidget);
    expect(find.text('Still blocking your first claim: Documents, Identity, Payment.'), findsOneWidget);
    for (final g in ['Profile', 'Documents', 'Identity', 'Payment']) {
      expect(find.text(g), findsOneWidget);
    }
    expect(chip('Done'), findsNWidgets(2));
    expect(find.byKey(const Key('step-profile')), findsNothing, reason: 'a done step has no form');
    expect(tester.widget<TextButton>(find.byKey(const Key('step-bank'))).onPressed, isNotNull);
    expect(find.byKey(const Key('onboarding-complete')), findsNothing);
    await expectAccessible(tester);
  });

  testWidgets('profile validates the phone, saves with one key, and unlocks bank with the name prefilled', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding()),
      'PUT /v1/talent/workers/me/onboarding/profile': (_) => json(onboarding(done: {'profile'})),
    });
    await openOnboarding(tester, backend);
    expect(find.text('0 of 6'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const Key('step-bank'))).onPressed, isNull);
    expect(find.text('Fill in your profile first'), findsOneWidget);

    await tester.tap(find.byKey(const Key('step-profile')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('f-legal_name')), 'Asha Rao');
    await tester.enterText(find.byKey(const Key('f-phone')), '12345');
    await tester.enterText(find.byKey(const Key('f-city')), 'Pune');
    await tester.tap(find.byKey(const Key('save-profile')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a 10-digit Indian mobile number'), findsOneWidget);
    expect(backend.sent('PUT', '/v1/talent/workers/me/onboarding/profile'), isEmpty);

    await tester.enterText(find.byKey(const Key('f-phone')), '9876543210');
    await tester.tap(find.byKey(const Key('save-profile')));
    await tester.pumpAndSettle();
    expect(putBody(backend, 'profile'), {'legal_name': 'Asha Rao', 'phone': '9876543210', 'city': 'Pune'});
    expect(backend.sent('PUT', '/v1/talent/workers/me/onboarding/profile').single.headers['Idempotency-Key'], isNotEmpty);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('1 of 6'), findsOneWidget);
    expect(find.byKey(const Key('f-legal_name')), findsNothing, reason: 'the form closes once saved');

    await tester.tap(find.byKey(const Key('step-bank')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(find.byKey(const Key('f-account_name'))).controller?.text, 'Asha Rao');
    expect(find.text('Must match your legal name exactly'), findsOneWidget);
  });

  testWidgets('identity forces PAN upper case, validates both fields, and shows a 409 pan_in_use inline', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding(done: {'profile'})),
      'PUT /v1/talent/workers/me/onboarding/identity': (_) => envelope(409, 'pan_in_use'),
    });
    await openOnboarding(tester, backend);
    await tester.tap(find.byKey(const Key('step-identity')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('f-pan')), 'abcde1234f');
    expect(tester.widget<TextFormField>(find.byKey(const Key('f-pan'))).controller?.text, 'ABCDE1234F');
    await tester.enterText(find.byKey(const Key('f-aadhaar_last4')), '12');
    await tester.tap(find.byKey(const Key('save-identity')));
    await tester.pumpAndSettle();
    expect(find.text('Enter the last 4 digits'), findsOneWidget);
    expect(backend.sent('PUT', '/v1/talent/workers/me/onboarding/identity'), isEmpty);

    await tester.enterText(find.byKey(const Key('f-aadhaar_last4')), '4321');
    await tester.tap(find.byKey(const Key('save-identity')));
    await tester.pumpAndSettle();
    expect(putBody(backend, 'identity'), {'pan': 'ABCDE1234F', 'aadhaar_last4': '4321'});
    expect(find.textContaining('This PAN is already on another account'), findsOneWidget);
    expect(find.byKey(const Key('f-pan')), findsOneWidget, reason: 'the form stays open to fix it');

    await tester.enterText(find.byKey(const Key('f-pan')), 'ABCD1234F');
    await tester.tap(find.byKey(const Key('save-identity')));
    await tester.pumpAndSettle();
    expect(find.text('PAN looks like ABCDE1234F'), findsOneWidget);
  });

  testWidgets('bank validates locally, saves to payout (not talent) and shows the bank check', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding(done: {'profile'})),
      'PUT /v1/payout/accounts/me': (_) => json(bankJson(status: 'verifying')),
    });
    await openOnboarding(tester, backend);
    await tester.tap(find.byKey(const Key('step-bank')));
    await tester.pumpAndSettle();
    expect(find.textContaining('We send ₹1'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('f-account_name')), 'A Rao');
    await tester.enterText(find.byKey(const Key('f-account_number')), '1234');
    await tester.enterText(find.byKey(const Key('f-ifsc')), 'hdfc0001234');
    await tester.tap(find.byKey(const Key('save-bank')));
    await tester.pumpAndSettle();
    expect(find.text('9 to 18 digits'), findsOneWidget);
    expect(backend.sent('PUT', '/v1/payout/accounts/me'), isEmpty);

    await tester.enterText(find.byKey(const Key('f-account_number')), '123456789012');
    await tester.tap(find.byKey(const Key('save-bank')));
    await tester.pump();
    await tester.pump();
    final sent = backend.sent('PUT', '/v1/payout/accounts/me').single;
    expect(jsonDecode(sent.body), {'account_name': 'A Rao', 'account_number': '123456789012', 'ifsc': 'HDFC0001234'});
    expect(sent.headers['Idempotency-Key'], isNotEmpty);
    expect(backend.sent('PUT', '/v1/talent/workers/me/onboarding/bank'), isEmpty);
    expect(find.byKey(const Key('bank-checking')), findsOneWidget);
    expect(find.textContaining('Checking the account ending 9012'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stop the check's timer
  });

  testWidgets('while the bank checks, the page asks again and ticks the step once talent marks it', (tester) async {
    var bank = bankJson(status: 'verifying');
    var done = <String>{'profile'};
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding(done: done)),
      'GET /v1/payout/accounts/me': (_) => json(bank),
    });
    await openOnboarding(tester, backend);
    expect(find.byKey(const Key('bank-checking')), findsOneWidget);
    bank = bankJson(status: 'verified');
    done = {'profile', 'bank'};
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('2 of 6'), findsOneWidget);
    expect(find.byKey(const Key('bank-checking')), findsNothing);
  });

  testWidgets('a failed bank check says why in plain words and offers Try again', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding(done: {'profile'})),
      'GET /v1/payout/accounts/me': (_) => json(bankJson(status: 'failed', reason: 'name_mismatch')),
      'PUT /v1/payout/accounts/me': (_) => envelope(409, 'account_in_use'),
    });
    await openOnboarding(tester, backend);
    expect(find.textContaining('not the name you gave'), findsOneWidget);
    await tester.tap(find.byKey(const Key('step-bank')));
    await tester.pumpAndSettle();
    expect(find.text('Close'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('f-account_name')), 'A Rao');
    await tester.enterText(find.byKey(const Key('f-account_number')), '123456789012');
    await tester.enterText(find.byKey(const Key('f-ifsc')), 'HDFC0001234');
    await tester.tap(find.byKey(const Key('save-bank')));
    await tester.pumpAndSettle();
    expect(find.textContaining('already registered to another worker'), findsOneWidget);
  });

  testWidgets('a verified account waiting on the name match says so; a payout read failure keeps the checklist', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding(done: {'profile'})),
      'GET /v1/payout/accounts/me': (_) => json(bankJson(status: 'verified')),
    });
    await openOnboarding(tester, backend);
    expect(find.textContaining('is verified. This step completes once the name'), findsOneWidget);
    expect(find.text('Change'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    final down = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding(done: {'profile'})),
      'GET /v1/payout/accounts/me': (_) => envelope(503, 'unavailable'),
    });
    await openOnboarding(tester, down);
    expect(find.text('1 of 6'), findsOneWidget);
    expect(find.text('Fill in'), findsWidgets);
  });

  testWidgets('agreement and consent need the box ticked; the last step completes onboarding', (tester) async {
    var saved = <String>{'profile', 'agreement', 'identity', 'bank', 'payout_ack'};
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding(done: saved)),
      'PUT /v1/talent/workers/me/onboarding/consent': (_) => json(onboarding(done: saved = {...saved, 'consent'})),
    });
    await openOnboarding(tester, backend);
    expect(find.text('1 step left; you can finish later'), findsOneWidget);
    expect(find.text('Still blocking your first claim: Documents.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('step-consent')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Digital Personal Data Protection Act'),
      findsOneWidget,
      reason: 'the shipped text when the server has none',
    );
    await tester.tap(find.byKey(const Key('save-consent')));
    await tester.pumpAndSettle();
    expect(find.text('Tick the box to accept.'), findsOneWidget);
    expect(backend.sent('PUT', '/v1/talent/workers/me/onboarding/consent'), isEmpty);

    await tester.tap(find.byKey(const Key('f-consent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-consent')));
    await tester.pumpAndSettle();
    expect(putBody(backend, 'consent'), {'accepted': true});
    expect(find.byKey(const Key('onboarding-complete')), findsOneWidget);
    expect(find.text('You are eligible; pools you are certified for are open to you.'), findsOneWidget);
    expect(find.text('All 6 steps are done'), findsOneWidget);
    expect(find.text('Onboarding complete'), findsOneWidget);
    expect(find.text('6 of 6'), findsOneWidget);
  });

  testWidgets('the agreement shows the served text and sends its version; an outdated version reloads the text', (tester) async {
    var label = '2026-12';
    var refused = true;
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding()),
      'GET /v1/talent/policies': (_) => json([policyJson('contractor-agreement', label, 'Clause $label applies.')]),
      'PUT /v1/talent/workers/me/onboarding/agreement': (_) {
        if (refused) {
          refused = false;
          label = '2027-01';
          return envelope(422, 'policy_outdated', context: {'latest': '2027-01'});
        }
        return json(onboarding(done: {'agreement'}));
      },
    });
    await openOnboarding(tester, backend);
    await tester.tap(find.byKey(const Key('step-agreement')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Clause 2026-12 applies.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('f-agreement')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-agreement')));
    await tester.pumpAndSettle();
    expect(putBody(backend, 'agreement'), {'accepted': true, 'version': '2026-12'});
    expect(find.textContaining('updated while you were reading it'), findsOneWidget);
    expect(find.textContaining('Clause 2027-01 applies.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('f-agreement')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-agreement')));
    await tester.pumpAndSettle();
    final last = jsonDecode(backend.sent('PUT', '/v1/talent/workers/me/onboarding/agreement').last.body);
    expect(last, {'accepted': true, 'version': '2027-01'});
  });

  testWidgets('without the server the agreement falls back to the shipped text and version', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding()),
      'PUT /v1/talent/workers/me/onboarding/agreement': (_) => json(onboarding(done: {'agreement'})),
    });
    await openOnboarding(tester, backend);
    await tester.tap(find.byKey(const Key('step-agreement')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agreement-text')), findsOneWidget);
    await tester.tap(find.byKey(const Key('f-agreement')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-agreement')));
    await tester.pumpAndSettle();
    expect(putBody(backend, 'agreement'), {'accepted': true, 'version': '2026-11'});
  });

  testWidgets('consent sends the version of the text the worker read', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding()),
      'GET /v1/talent/policies': (_) => json([policyJson('dpdp-consent', '3', 'We keep your PAN as a digest.')]),
      'PUT /v1/talent/workers/me/onboarding/consent': (_) => json(onboarding(done: {'consent'})),
    });
    await openOnboarding(tester, backend);
    await tester.tap(find.byKey(const Key('step-consent')));
    await tester.pumpAndSettle();
    expect(find.textContaining('We keep your PAN as a digest.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('f-consent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-consent')));
    await tester.pumpAndSettle();
    expect(putBody(backend, 'consent'), {'accepted': true, 'version': '3'});
  });

  testWidgets('a document goes to storage through the presigned link, then is registered with its digest', (tester) async {
    var docs = <Map<String, Object?>>[];
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json({...onboarding(), 'documents': docs}),
      'POST /v1/talent/workers/me/documents/presign': (_) => json({
        'key': 'workers/w1/documents/identity_front/abc',
        'url': 'http://minio.test/yantra/workers/w1/documents/identity_front/abc?X-Amz-Signature=x',
        'method': 'PUT',
        'headers': {'content-type': 'image/png'},
        'expires_at': '2026-11-04T10:05:00Z',
        'max_bytes': 10485760,
      }),
      'PUT /yantra/workers/w1/documents/identity_front/abc': (_) => http.Response('', 200),
      'PUT /v1/talent/workers/me/documents/identity_front': (_) {
        docs = [
          {'kind': 'identity_front', 'uploaded_at': DateTime.now().toUtc().toIso8601String()},
        ];
        return json({
          'kind': 'identity_front',
          'sha256': 'x',
          'size_bytes': 4,
          'content_type': 'image/png',
          'uploaded_at': '2026-11-04T10:00:00Z',
        });
      },
    });
    final harness = await openOnboarding(tester, backend);
    expect(find.byKey(const Key('documents-card')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('document-state-identity_front'))).data, 'Not uploaded');
    harness.files.next = (name: 'pan.png', mime: 'image/png', bytes: [1, 2, 3, 4]);
    await tester.tap(find.byKey(const Key('upload-identity_front')));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('POST', '/v1/talent/workers/me/documents/presign').single.body), {
      'kind': 'identity_front',
      'content_type': 'image/png',
      'size_bytes': 4,
    });
    final put = backend.sent('PUT', '/yantra/workers/w1/documents/identity_front/abc').single;
    expect(put.bodyBytes, [1, 2, 3, 4]);
    expect(put.headers['content-type'], 'image/png');
    final reg = jsonDecode(backend.sent('PUT', '/v1/talent/workers/me/documents/identity_front').single.body);
    expect(reg['key'], 'workers/w1/documents/identity_front/abc');
    expect(reg['sha256'], '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a');
    expect(reg['size_bytes'], 4);
    expect(tester.widget<Text>(find.byKey(const Key('document-state-identity_front'))).data, startsWith('Uploaded'));
    expect(find.text('Replace'), findsOneWidget);
  });

  testWidgets('a document of the wrong type or too large is refused before any upload', (tester) async {
    final backend = FakeBackend({'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding())});
    final harness = await openOnboarding(tester, backend);
    harness.files.next = (name: 'notes.txt', mime: 'text/plain', bytes: [1]);
    await tester.tap(find.byKey(const Key('upload-address_proof')));
    await tester.pumpAndSettle();
    expect(find.text('notes.txt is not a JPEG, PNG or PDF.'), findsOneWidget);
    harness.files.next = (name: 'scan.PDF', mime: '', bytes: List.filled(10 * 1024 * 1024 + 1, 0));
    await tester.tap(find.byKey(const Key('upload-address_proof')));
    await tester.pumpAndSettle();
    expect(find.textContaining('documents must be under 10 MB'), findsOneWidget);
    harness.files.next = (name: 'empty.jpg', mime: '', bytes: <int>[]);
    await tester.tap(find.byKey(const Key('upload-address_proof')));
    await tester.pumpAndSettle();
    expect(find.textContaining('documents must be under 10 MB'), findsOneWidget);
    await tester.tap(find.byKey(const Key('upload-address_proof'))); // cancelled
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/talent/workers/me/documents/presign'), isEmpty);
  });

  testWidgets('a refused document upload says why and keeps the button', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding()),
      'POST /v1/talent/workers/me/documents/presign': (_) =>
          json({'key': 'k1', 'url': 'http://minio.test/yantra/k1', 'headers': <String, String>{}, 'max_bytes': 10}),
      'PUT /yantra/k1': (_) => http.Response('denied', 403),
    });
    final harness = await openOnboarding(tester, backend);
    harness.files.next = (name: 'id.jpg', mime: 'image/jpeg', bytes: [1, 2]);
    await tester.tap(find.byKey(const Key('upload-identity_back')));
    await tester.pumpAndSettle();
    expect(find.textContaining('The upload was refused (403)'), findsOneWidget);
    expect(backend.sent('PUT', '/v1/talent/workers/me/documents/identity_back'), isEmpty);
    expect(find.text('Upload'), findsNWidgets(4));
  });

  testWidgets('onboarding at 390 px passes the contrast and tap-target checks, and renders in dark mode', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding(done: {'profile'})),
      'GET /v1/payout/accounts/me': (_) => json(bankJson(status: 'failed', reason: 'invalid_account')),
    });
    backend.routes['GET /v1/claims/active'] = (_) => json(emptyActive);
    backend.routes['GET /v1/batches'] = (_) => json([]);
    await pumpApp(tester, backend, size: const Size(390, 2400));
    await goTo(tester, '/work/home/onboarding');
    expect(find.textContaining('do not match an open account'), findsOneWidget);
    await expectAccessible(tester);
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester, backend, size: const Size(390, 2400), dark: true);
    await goTo(tester, '/work/home/onboarding');
    await expectRendersDark(tester);
  });

  testWidgets('a 404 from the talent module reads as not started; a 503 offers Retry', (tester) async {
    final backend = FakeBackend({'GET /v1/talent/workers/me/onboarding': (_) => envelope(404, 'not_found')});
    await openOnboarding(tester, backend);
    expect(find.text('0 of 6'), findsOneWidget);
    expect(find.text('6 steps left; you can finish later'), findsOneWidget);
  });

  testWidgets('a failed load offers Retry', (tester) async {
    // Home reads the checklist first (and tolerates the failure); the second call is the route's own.
    var calls = 0;
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) =>
          ++calls <= 2 ? envelope(503, 'upstream_unavailable', headers: {'retry-after': '2'}) : json(onboarding()),
    });
    await openOnboarding(tester, backend);
    expect(find.text('Service is away. Retry in 2s.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('0 of 6'), findsOneWidget);
  });

  testWidgets('renders at phone width with a form open, without overflow', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding(done: {'profile'})),
    });
    await openOnboarding(tester, backend, size: const Size(390, 3000));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('step-bank')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('f-ifsc')), findsOneWidget);
    expect(find.byKey(const Key('back')), findsOneWidget);
  });

  testWidgets('a step edited after a 5xx is saved under a new key; the same body keeps its key', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding()),
      'PUT /v1/talent/workers/me/onboarding/profile': (_) => envelope(503, 'upstream_unavailable'),
    });
    await openOnboarding(tester, backend);
    await tester.tap(find.byKey(const Key('step-profile')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('f-legal_name')), 'Asha Rao');
    await tester.enterText(find.byKey(const Key('f-phone')), '9876543210');
    await tester.enterText(find.byKey(const Key('f-city')), 'Pune');
    await tester.tap(find.byKey(const Key('save-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-profile')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('f-city')), 'Mumbai');
    await tester.tap(find.byKey(const Key('save-profile')));
    await tester.pumpAndSettle();
    final keys = [for (final r in backend.sent('PUT', '/v1/talent/workers/me/onboarding/profile')) r.headers['Idempotency-Key']];
    expect(keys, hasLength(3));
    expect(keys[1], keys[0]);
    expect(keys[2], isNot(keys[0]));
  });

  testWidgets('another file for the same document goes out under new keys', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding()),
      'POST /v1/talent/workers/me/documents/presign': (_) => envelope(503, 'upstream_unavailable'),
    });
    final harness = await openOnboarding(tester, backend);
    harness.files.next = (name: 'id.jpg', mime: 'image/jpeg', bytes: [1, 2]);
    await tester.tap(find.byKey(const Key('upload-identity_back')));
    await tester.pumpAndSettle();
    harness.files.next = (name: 'id2.png', mime: 'image/png', bytes: [1, 2, 3]);
    await tester.tap(find.byKey(const Key('upload-identity_back')));
    await tester.pumpAndSettle();
    final keys = [for (final r in backend.sent('POST', '/v1/talent/workers/me/documents/presign')) r.headers['Idempotency-Key']];
    expect(keys, hasLength(2));
    expect(keys[1], isNot(keys[0]));
  });

  testWidgets('each upload button names its document for a screen reader', (tester) async {
    final backend = FakeBackend({'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding())});
    await openOnboarding(tester, backend);
    final handle = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel('Upload ID card, back'), findsOneWidget);
    expect(find.bySemanticsLabel('Upload Proof of address'), findsOneWidget);
    handle.dispose();
  });
}
