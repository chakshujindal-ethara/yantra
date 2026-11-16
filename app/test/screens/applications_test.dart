import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/screens/assessment_screen.dart';
import 'package:yantra_app/screens/onboarding_screen.dart';

import '../support/fake_backend.dart';
import 'fixtures.dart';
import 'fixtures_talent.dart';

List<Map<String, Object?>> mixed() => [
  application(id: 'a1', status: 'offered', offerExpiresAt: inFuture(const Duration(days: 3)), note: 'Welcome aboard; start Monday.'),
  application(id: 'a2', listingId: 'l2', listingTitle: 'Tamil audio transcription', status: 'assessment'),
  application(id: 'a3', listingId: 'l3', listingTitle: 'Product photo tagging', status: 'screening'),
  application(id: 'a4', listingTitle: 'Old pool', status: 'accepted'),
  application(id: 'a5', listingTitle: 'Other pool', status: 'rejected', note: 'Not enough hours'),
  application(id: 'a6', listingTitle: 'Lapsed pool', status: 'expired'),
];

Future<TestHarness> openApplications(WidgetTester tester, FakeBackend backend, {Size size = const Size(900, 2400)}) async {
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
  backend.routes.putIfAbsent(
    'GET /v1/talent/listings/l2',
    () =>
        (_) => json(listing(id: 'l2', title: 'Tamil audio transcription', paperId: 'pp1')),
  );
  final harness = await pumpApp(tester, backend, size: size);
  if (size.width >= 960) {
    await tester.tap(find.byKey(const Key('nav-applications')));
    await tester.pumpAndSettle();
  } else {
    await openFromDrawer(tester, 'nav-applications');
  }
  return harness;
}

Finder chip(String label) => find.widgetWithText(StatusChip, label);

void main() {
  testWidgets('applications are grouped: the offer with its countdown, the ones in progress with steps, history muted', (tester) async {
    final backend = FakeBackend({'GET /v1/talent/applications/me': (_) => json(mixed())});
    await openApplications(tester, backend);
    expect(pageTitle(tester), 'Applications');
    expect(find.text('Needs your answer'), findsOneWidget);
    expect(find.text('In progress'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);

    expect(find.byKey(const Key('offer-a1')), findsOneWidget);
    expect(chip('Expires in 2 days'), findsOneWidget);
    expect(find.text('Welcome aboard; start Monday.'), findsOneWidget);
    expect(find.byKey(const Key('offer-accept-a1')), findsOneWidget);
    expect(find.byKey(const Key('offer-decline-a1')), findsOneWidget);

    expect(find.byKey(const Key('application-a2')), findsOneWidget);
    expect(chip('Paper pending'), findsOneWidget);
    expect(find.text('1 of 3'), findsOneWidget, reason: 'the paper is still pending');
    expect(find.text('2 of 3'), findsOneWidget, reason: 'screening: form and paper done');
    expect(find.text('Assessment paper'), findsNWidgets(2));
    expect(find.byKey(const Key('take-paper-a2')), findsOneWidget);
    expect(find.byKey(const Key('take-paper-a3')), findsNothing);
    expect(find.byKey(const Key('withdraw-a2')), findsOneWidget);
    expect(find.byKey(const Key('withdraw-a3')), findsOneWidget);

    expect(chip('Accepted'), findsOneWidget);
    expect(chip('Rejected'), findsOneWidget);
    expect(chip('Expired'), findsOneWidget);
    expect(find.text('Not enough hours'), findsOneWidget);
    expect(find.byKey(const Key('withdraw-a4')), findsNothing);
    expect(find.byKey(const Key('onboarding-nudge')), findsNothing, reason: 'onboarding unknown: no nudge');
    await expectAccessible(tester);
  });

  testWidgets('accepting an offer confirms, posts once with a key, and reloads', (tester) async {
    var accepted = false;
    final backend = FakeBackend({
      'GET /v1/talent/applications/me': (_) => json(accepted ? [application(id: 'a1', status: 'accepted')] : mixed()),
      'POST /v1/talent/applications/a1/offer': (_) {
        accepted = true;
        return json(application(id: 'a1', status: 'accepted'));
      },
    });
    await openApplications(tester, backend);
    await tester.tap(find.byKey(const Key('offer-accept-a1')));
    await tester.pumpAndSettle();
    expect(find.text('Accept the offer?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/talent/applications/a1/offer'), isEmpty);

    await tester.tap(find.byKey(const Key('offer-accept-a1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept').last);
    await tester.pumpAndSettle();
    final sent = backend.sent('POST', '/v1/talent/applications/a1/offer').single;
    expect(jsonDecode(sent.body), {'accept': true});
    expect(sent.headers['Idempotency-Key'], isNotEmpty);
    expect(find.text('Offer accepted; welcome to Hindi audio transcription'), findsOneWidget);
    expect(find.byKey(const Key('offer-a1')), findsNothing);
    expect(chip('Accepted'), findsOneWidget);
  });

  testWidgets('accepting an offer marks Home stale: the next visit loads it again', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/applications/me': (_) => json(mixed()),
      'POST /v1/talent/applications/a1/offer': (_) => json(application(id: 'a1', status: 'accepted')),
    });
    await openApplications(tester, backend, size: const Size(1280, 2400));
    expect(backend.sent('GET', '/v1/claims/active'), hasLength(1));
    await tester.tap(find.byKey(const Key('nav-home')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/claims/active'), hasLength(1), reason: 'nothing changed: the kept page is shown as is');
    await tester.tap(find.byKey(const Key('nav-applications')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('offer-accept-a1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-home')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/claims/active'), hasLength(2), reason: 'the offer changed what Home shows');
  });

  testWidgets('an onboarding read that fails for any reason but 404 is the page error', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/applications/me': (_) => json(mixed()),
      'GET /v1/talent/workers/me/onboarding': (_) => envelope(500, 'boom', message: 'Talent is away'),
    });
    await openApplications(tester, backend);
    expect(find.textContaining('Reference: req-1'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byKey(const Key('offer-a1')), findsNothing);
  });

  testWidgets('a 409 offer_expired flips the card to expired with the message', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/applications/me': (_) => json(mixed()),
      'POST /v1/talent/applications/a1/offer': (_) => envelope(409, 'offer_expired', message: 'The offer expired on Monday'),
    });
    await openApplications(tester, backend);
    await tester.tap(find.byKey(const Key('offer-accept-a1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept').last);
    await tester.pumpAndSettle();
    expect(find.text('This offer expired before you answered; expired counts as declined.'), findsOneWidget);
    expect(find.byKey(const Key('offer-accept-a1')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('offer-a1')), matching: chip('Expired')), findsOneWidget);
  });

  testWidgets('declining an offer posts accept false', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/applications/me': (_) => json(mixed()),
      'POST /v1/talent/applications/a1/offer': (_) => json(application(id: 'a1', status: 'declined')),
    });
    await openApplications(tester, backend);
    await tester.tap(find.byKey(const Key('offer-decline-a1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Decline').last);
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('POST', '/v1/talent/applications/a1/offer').single.body), {'accept': false});
    expect(find.text('Offer declined'), findsOneWidget);
  });

  testWidgets('withdraw confirms and posts; a 503 keeps the key for the retry', (tester) async {
    var calls = 0;
    final backend = FakeBackend({
      'GET /v1/talent/applications/me': (_) => json(mixed()),
      'POST /v1/talent/applications/a3/withdraw': (_) => ++calls == 1
          ? envelope(503, 'upstream_unavailable', headers: {'retry-after': '2'})
          : json(application(id: 'a3', status: 'withdrawn')),
    });
    await openApplications(tester, backend);
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const Key('withdraw-a3')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Withdraw').last);
      await tester.pumpAndSettle();
    }
    final keys = backend.sent('POST', '/v1/talent/applications/a3/withdraw').map((r) => r.headers['Idempotency-Key']).toList();
    expect(keys, hasLength(2));
    expect(keys[0], keys[1]);
    expect(find.text('Application withdrawn'), findsOneWidget);
  });

  testWidgets('Take the paper reads the listing for its paper and opens the assessment', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/applications/me': (_) => json(mixed()),
      'GET /v1/assess/papers/pp1/brief': (_) => json(brief()),
      'GET /v1/assess/sittings/me': (_) => json([]),
    });
    await openApplications(tester, backend);
    expect(backend.sent('GET', '/v1/talent/listings/l2'), hasLength(1));
    await tester.tap(find.byKey(const Key('take-paper-a2')));
    await tester.pumpAndSettle();
    expect(find.byType(AssessmentScreen), findsOneWidget);
    expect(find.byKey(const Key('start-exam')), findsOneWidget);
  });

  testWidgets('a paper already started reads Resume the paper: the newest attempt decides', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/applications/me': (_) => json(mixed()),
      'GET /v1/assess/sittings/me': (_) => json([
        workerSitting(status: 'failed', attemptNo: 1, score: 0.4),
        workerSitting(id: 's2', status: 'in_progress', attemptNo: 2, score: 0, released: false),
      ]),
    });
    await openApplications(tester, backend);
    expect(find.text('Resume the paper'), findsOneWidget);
    expect(find.text('Take the paper'), findsNothing);
  });

  testWidgets('a submitted paper shows Awaiting result and why, with View instead of Take the paper', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/applications/me': (_) => json(mixed()),
      'GET /v1/assess/sittings/me': (_) =>
          json([workerSitting(status: 'awaiting_result', score: 0, released: false, heldReason: 'needs_release')]),
    });
    await openApplications(tester, backend);
    expect(find.byKey(const Key('paper-awaiting-a2')), findsOneWidget);
    expect(find.text('Ops review the results before they are released'), findsOneWidget);
    expect(find.text('View'), findsOneWidget);
    expect(find.text('Take the paper'), findsNothing);
  });

  testWidgets('sittings that cannot be read leave Take the paper as it was', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/applications/me': (_) => json(mixed()),
      'GET /v1/assess/sittings/me': (_) => envelope(500, 'internal_error'),
    });
    await openApplications(tester, backend);
    expect(find.text('Take the paper'), findsOneWidget);
  });

  testWidgets('an accepted offer with onboarding unfinished shows the nudge to the onboarding route', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/applications/me': (_) => json([application(id: 'a4', status: 'accepted')]),
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding(done: {'profile'})),
    });
    await openApplications(tester, backend);
    expect(find.byKey(const Key('onboarding-nudge')), findsOneWidget);
    expect(find.textContaining('5 of 6 steps left'), findsOneWidget);
    await tester.tap(find.byKey(const Key('finish-onboarding')));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);
  });

  testWidgets('no applications shows the empty state with a way to Explore', (tester) async {
    final backend = FakeBackend({'GET /v1/talent/applications/me': (_) => json([]), 'GET /v1/talent/listings': (_) => json([])});
    await openApplications(tester, backend);
    expect(find.text('No applications yet. Open pools are waiting in Explore.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('applications-empty-explore')));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Explore');
  });

  testWidgets('a failed load shows the error and Retry', (tester) async {
    // Home reads the same list first (and tolerates the failure); the second call is the page's own.
    var calls = 0;
    final backend = FakeBackend({
      'GET /v1/talent/applications/me': (_) =>
          ++calls <= 2 ? envelope(503, 'upstream_unavailable', headers: {'retry-after': '4'}) : json(mixed()),
    });
    await openApplications(tester, backend);
    expect(find.text('Service is away. Retry in 4s.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('offer-a1')), findsOneWidget);
  });

  testWidgets('renders at phone width and at desktop width without overflow', (tester) async {
    final backend = FakeBackend({'GET /v1/talent/applications/me': (_) => json(mixed())});
    await openApplications(tester, backend, size: const Size(390, 3000));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('offer-accept-a1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('offer-accept-a1')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('the sidebar reaches Applications at desktop width', (tester) async {
    final backend = FakeBackend({'GET /v1/talent/applications/me': (_) => json(mixed())});
    await openApplications(tester, backend, size: const Size(1280, 1600));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('offer-a1')), findsOneWidget);
  });

  testWidgets('applications on a phone pass the checks and render in dark mode', (tester) async {
    final backend = FakeBackend({'GET /v1/talent/applications/me': (_) => json(mixed())});
    await openApplications(tester, backend, size: const Size(390, 2400));
    await expectAccessible(tester);
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester, backend, dark: true, at: '/work/applications');
    await expectRendersDark(tester);
  });
}
