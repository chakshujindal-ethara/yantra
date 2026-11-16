import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:yantra_app/screens/onboarding_screen.dart';
import 'package:yantra_app/screens/work_screen.dart';

import '../support/fake_backend.dart';
import 'fixtures.dart';
import 'fixtures_talent.dart';

void main() {
  testWidgets('home shows the KPIs, the pool with pay and TTL, and a complete readiness hides itself', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
      'GET /v1/workers/me': (_) => json(me(availability: {'weekly_hours': 20, 'paused_until': null})),
      'GET /v1/payout/statement': (_) => json(statement()),
      'GET /v1/notify/channel': (_) => json(channel),
    });
    await pumpApp(tester, backend);
    expect(find.text('Label street signs'), findsOneWidget);
    expect(find.text('Hindi transcription'), findsOneWidget);
    expect(find.text('₹12.50 per unit'), findsOneWidget);
    expect(find.text('4 h per claim'), findsOneWidget);
    expect(find.text('42 available'), findsOneWidget);
    expect(find.text('₹25.00'), findsOneWidget);
    expect(find.text('2 accepted units'), findsOneWidget);
    expect(find.text('Ready to work'), findsNothing);
    expect(find.byKey(const Key('claim-b1')), findsOneWidget);
    await expectAccessible(tester);
  });

  testWidgets('the side reads go out together, not one after another', (tester) async {
    final me0 = Completer<http.Response>();
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
      'GET /v1/payout/statement': (_) => json(statement()),
      'GET /v1/notify/channel': (_) => json(channel),
    });
    backend.slow['GET /v1/workers/me'] = (_) => me0.future;
    final harness = TestHarness(backend, tokens: liveTokens());
    await tester.pumpWidget(harness.app);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    for (final path in ['/v1/payout/statement', '/v1/notify/channel', '/v1/talent/workers/me/onboarding', '/v1/tracker/sessions/me']) {
      expect(backend.sent('GET', path), hasLength(1), reason: '$path is asked while /v1/workers/me is still out');
    }
    me0.complete(json(me()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a worker who is not onboarded sees the readiness checklist with what is missing', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([]),
      'GET /v1/workers/me': (_) => json(me(status: 'unknown', gates: [])),
      'GET /v1/payout/statement': (_) => envelope(404, 'not_found'),
      'GET /v1/notify/channel': (_) => json({'worker_id': 'worker-1', 'email': null}),
    });
    await pumpApp(tester, backend);
    expect(find.text('Ready to work'), findsOneWidget);
    expect(find.text('0 of 4'), findsOneWidget);
    expect(find.byKey(const Key('set-availability')), findsOneWidget);
    expect(find.byKey(const Key('set-email')), findsOneWidget);
    expect(find.textContaining('No open pools'), findsOneWidget);
    expect(find.text('None yet'), findsOneWidget);
    // the Set button moves to Profile
    await tester.tap(find.byKey(const Key('set-availability')));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Profile');
  });

  testWidgets('a paused worker sees the banner and no Claim', (tester) async {
    final until = DateTime.now().add(const Duration(days: 5)).toUtc().toIso8601String();
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
      'GET /v1/workers/me': (_) => json(me(availability: {'weekly_hours': 20, 'paused_until': until})),
    });
    await pumpApp(tester, backend);
    expect(find.textContaining('Your availability is paused'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byKey(const Key('claim-b1')));
    expect(button.onPressed, isNull);
    expect(find.byKey(const Key('resume-availability')), findsOneWidget);
  });

  testWidgets('a live claim is shown with its countdown and opens the Work screen', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json({'claim': claim(), 'unit': unit, 'batch': batch}),
    });
    await pumpApp(tester, backend);
    expect(find.byKey(const Key('live-claim')), findsOneWidget);
    expect(find.textContaining('left'), findsOneWidget);
    expect(find.byKey(const Key('claim-b1')), findsNothing);
    await tester.tap(find.text('Continue'));
    await pumpFor(tester);
    expect(find.byType(WorkScreen), findsOneWidget);
  });

  testWidgets('claim posts once with one key and opens the Work screen', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
      'POST /v1/batches/b1/claims': (_) => json(claim(), status: 201),
      'GET /v1/units/u1': (_) => json(unit),
    });
    await pumpApp(tester, backend);
    await tester.tap(find.byKey(const Key('claim-b1')));
    await pumpFor(tester);
    expect(find.byType(WorkScreen), findsOneWidget);
    final posts = backend.sent('POST', '/v1/batches/b1/claims');
    expect(posts, hasLength(1));
    expect(posts.single.headers['Idempotency-Key'], isNotEmpty);
  });

  testWidgets('claim conflicts are explained', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
      'POST /v1/batches/b1/claims': (_) => envelope(409, 'one_live_claim'),
    });
    await pumpApp(tester, backend);
    await tester.tap(find.byKey(const Key('claim-b1')));
    await tester.pumpAndSettle();
    expect(find.text('You already hold a claim. Finish it first.'), findsOneWidget);
  });

  testWidgets('a claim refused for withdrawn consent says how to give it again', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
      'POST /v1/batches/b1/claims': (_) => envelope(403, 'consent_withdrawn'),
    });
    await pumpApp(tester, backend);
    await tester.tap(find.byKey(const Key('claim-b1')));
    await tester.pumpAndSettle();
    expect(find.text("You withdrew consent, so you can't take new work. Give consent again in Profile → Your data."), findsOneWidget);
  });

  testWidgets('a paused refusal from the gateway points at Profile', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
      'POST /v1/batches/b1/claims': (_) => envelope(403, 'availability_paused'),
    });
    await pumpApp(tester, backend);
    await tester.tap(find.byKey(const Key('claim-b1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Resume it in Profile'), findsOneWidget);
  });

  testWidgets('a failed load shows the error and Retry', (tester) async {
    var calls = 0;
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) =>
          ++calls == 1 ? envelope(429, 'rate_limited', message: 'too many requests', headers: {'retry-after': '9'}) : json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
    });
    await pumpApp(tester, backend);
    expect(find.text('Too many requests. Wait 9s and try again.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Label street signs'), findsOneWidget);
  });

  testWidgets('a claim that landed but whose unit could not be read still reloads the page', (tester) async {
    var units = 0;
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(units == 0 ? emptyActive : {'claim': claim(), 'unit': unit, 'batch': batch}),
      'GET /v1/batches': (_) => json([batch]),
      'POST /v1/batches/b1/claims': (_) => json(claim(), status: 201),
      'GET /v1/units/u1': (_) {
        units++;
        return envelope(503, 'upstream_unavailable', headers: {'retry-after': '2'});
      },
    });
    await pumpApp(tester, backend);
    await tester.tap(find.byKey(const Key('claim-b1')));
    await pumpFor(tester);
    expect(find.byKey(const Key('live-claim')), findsOneWidget);
    expect(find.byKey(const Key('claim-b1')), findsNothing);
  });

  testWidgets('a refused claim mints a new key for the next attempt, a 503 keeps it', (tester) async {
    var calls = 0;
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
      'POST /v1/batches/b1/claims': (_) => ++calls == 1
          ? envelope(503, 'upstream_unavailable', headers: {'retry-after': '2'})
          : (calls == 2 ? envelope(403, 'forbidden') : json(claim(), status: 201)),
      'GET /v1/units/u1': (_) => json(unit),
    });
    await pumpApp(tester, backend);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const Key('claim-b1')));
      await pumpFor(tester);
    }
    final keys = backend.sent('POST', '/v1/batches/b1/claims').map((r) => r.headers['Idempotency-Key']).toList();
    expect(keys[0], keys[1]); // 503: the same action, the same key
    expect(keys[2], isNot(keys[1])); // 403 was stored for that key: a fresh action
  });

  testWidgets('pull to refresh keeps the page on screen while it reloads', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
    });
    await pumpApp(tester, backend);
    await tester.fling(find.text('Label street signs'), const Offset(0, 400), 1200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Label street signs'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing); // the Material refresh spinner is not ours
    await tester.pumpAndSettle();
  });

  testWidgets('the readiness card reads the onboarding checklist and Finish opens the onboarding route', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([]),
      'GET /v1/workers/me': (_) => json(me(status: 'unknown', gates: [])),
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding(done: {'profile', 'agreement'})),
      'GET /v1/talent/listings': (_) => json([]),
    });
    await pumpApp(tester, backend);
    expect(find.text('Ready to work'), findsOneWidget);
    expect(find.text('0 of 4'), findsOneWidget);
    expect(find.text('2 of 6 steps done; 4 left'), findsOneWidget);
    expect(find.byKey(const Key('offers-waiting')), findsNothing);
    await tester.tap(find.byKey(const Key('finish-onboarding')));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.text('2 of 6'), findsOneWidget);
    await tester.tap(find.byKey(const Key('back')));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(backend.sent('GET', '/v1/talent/workers/me/onboarding').length, greaterThanOrEqualTo(3), reason: 'home, the route, home again');
    await tester.tap(find.byKey(const Key('explore-pools')));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Explore');
  });

  testWidgets('a side read that fails for any reason but 404 is the page error, never fake empty data', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
      'GET /v1/workers/me': (_) => fail ? envelope(503, 'unavailable', headers: {'retry-after': '3'}) : json(me()),
    });
    await pumpApp(tester, backend);
    expect(find.text('Service is away. Retry in 3s.'), findsOneWidget);
    expect(find.text('Ready to work'), findsNothing);
    expect(find.text('Label street signs'), findsNothing);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Label street signs'), findsOneWidget);
  });

  testWidgets('a worker the talent module does not know yet still gets a page, with Start on the checklist', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([]),
      'GET /v1/workers/me': (_) => json(me(status: 'unknown', gates: [])),
      'GET /v1/talent/workers/me/onboarding': (_) => envelope(404, 'not_found'),
      'GET /v1/talent/applications/me': (_) => envelope(404, 'not_found'),
    });
    await pumpApp(tester, backend);
    expect(find.text('Ready to work'), findsOneWidget);
    expect(find.text('Profile, documents, identity and bank details: 0 of 6 steps done'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
  });

  testWidgets('offers waiting are counted on an emphasis card that goes to Applications', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
      'GET /v1/talent/applications/me': (_) => json([
        application(status: 'offered', offerExpiresAt: inFuture(const Duration(days: 3))),
        application(id: 'a2', status: 'screening'),
      ]),
    });
    await pumpApp(tester, backend);
    expect(find.byKey(const Key('offers-waiting')), findsOneWidget);
    expect(find.text('1 offer waiting for your answer'), findsOneWidget);
    await tester.tap(find.byKey(const Key('see-offers')));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Applications');
    expect(find.byKey(const Key('offer-a1')), findsOneWidget);
  });

  testWidgets('an application waiting on its paper puts "Your paper is waiting" on Home, one tap from the paper', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
      'GET /v1/talent/applications/me': (_) =>
          json([application(listingId: 'l1', listingTitle: 'Hindi audio transcription', status: 'assessment')]),
      'GET /v1/talent/listings/l1': (_) => json(listing()),
      'GET /v1/assess/papers/pp1/brief': (_) => json(brief()),
      'GET /v1/assess/sittings/me': (_) => json([]),
    });
    await pumpApp(tester, backend);
    expect(find.byKey(const Key('paper-waiting')), findsOneWidget);
    expect(find.textContaining('Hindi audio transcription on to screening'), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-paper')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/work/applications/assessment/pp1');
    expect(find.byKey(const Key('start-exam')), findsOneWidget);
  });

  testWidgets('several papers waiting send the worker to Applications; none waiting shows no card', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
      'GET /v1/talent/applications/me': (_) =>
          json([application(status: 'assessment'), application(id: 'a2', listingId: 'l2', status: 'assessment')]),
    });
    await pumpApp(tester, backend);
    expect(find.text('2 applications wait on a paper.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-paper')));
    await tester.pumpAndSettle();
    expect(pageTitle(tester), 'Applications');
  });

  testWidgets('a paper whose listing cannot be read says so instead of going nowhere', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
      'GET /v1/talent/applications/me': (_) => json([application(listingId: 'l9', status: 'assessment')]),
      'GET /v1/talent/listings/l9': (_) => envelope(404, 'not_found'),
    });
    await pumpApp(tester, backend);
    await tester.tap(find.byKey(const Key('open-paper')));
    await tester.pumpAndSettle();
    expect(find.text('This is no longer there. Refresh and try again.'), findsOneWidget);
    expect(find.byKey(const Key('paper-waiting')), findsOneWidget);
  });

  Map<String, Object?> activity({int active = 7200, bool over = false, int sessions = 2}) => {
    'open_session_id': null,
    'week': {
      'starts_at': '2026-11-02T00:00:00+05:30',
      'ends_at': '2026-11-09T00:00:00+05:30',
      'active_seconds': active,
      'idle_seconds': 600,
      'cap_hours': '40.00',
      'cap_source': 'default',
      'over_cap': over,
    },
    'sessions': [
      for (var i = 0; i < sessions; i++) {'id': 's$i', 'claim_id': 'c$i', 'active_seconds': 3600, 'idle_seconds': 300},
    ],
  };

  testWidgets('this week\'s activity shows hours against the cap and opens what we track', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([]),
      'GET /v1/tracker/sessions/me': (_) => json(activity()),
    });
    await pumpApp(tester, backend);
    expect(find.byKey(const Key('activity-card')), findsOneWidget);
    expect(find.text('2.0 h active of a 40 h weekly cap'), findsOneWidget);
    expect(find.textContaining('2 sessions this week. You are paid per accepted unit'), findsOneWidget);
    await tester.tap(find.byKey(const Key('activity-policy')));
    await tester.pumpAndSettle();
    expect(find.text('What we track'), findsWidgets);
    expect(find.textContaining('Keystrokes'), findsOneWidget, reason: 'the shipped copy when the tracker policy cannot be read');
  });

  testWidgets('over the cap the activity card says so; no activity and no claim hides it; a tracker error hides it', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([]),
      'GET /v1/tracker/sessions/me': (_) => json(activity(active: 41 * 3600, over: true, sessions: 1)),
    });
    await pumpApp(tester, backend);
    expect(find.textContaining('over this week\'s cap'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    backend.routes['GET /v1/tracker/sessions/me'] = (_) => json(activity(active: 0, sessions: 0));
    await pumpApp(tester, backend);
    expect(find.byKey(const Key('activity-card')), findsNothing);
    await tester.pumpWidget(const SizedBox());

    backend.routes['GET /v1/tracker/sessions/me'] = (_) => envelope(503, 'unavailable');
    await pumpApp(tester, backend);
    expect(find.byKey(const Key('activity-card')), findsNothing);
    expect(find.text('Open pools'), findsOneWidget, reason: 'the tracker never takes Home down');
  });

  testWidgets('the readiness row says when the bank is being checked or could not be confirmed', (tester) async {
    Map<String, Object?> bank(String status) => {
      'status': status,
      'verification': 'penny_drop',
      'account_name': 'A Rao',
      'account_last4': '9012',
      'ifsc': 'HDFC0001234',
      'failure_reason': status == 'failed' ? 'invalid_account' : null,
    };
    var status = 'verifying';
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([]),
      'GET /v1/workers/me': (_) => json(me(status: 'unknown', gates: [])),
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboarding(done: {'profile', 'agreement'})),
      'GET /v1/payout/accounts/me': (_) => json(bank(status)),
    });
    await pumpApp(tester, backend);
    expect(find.text('Checking your bank account with the bank; 4 steps left'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    status = 'failed';
    await pumpApp(tester, backend);
    expect(find.textContaining('could not be confirmed. Open onboarding to fix it.'), findsOneWidget);
  });

  testWidgets('a live claim is read again every minute, quietly', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json({'claim': claim(), 'unit': unit, 'batch': batch}),
    });
    await pumpApp(tester, backend);
    final before = backend.sent('GET', '/v1/claims/active').length;
    await tester.pump(const Duration(seconds: 61));
    await tester.pump();
    expect(backend.sent('GET', '/v1/claims/active').length, before + 1);
    expect(find.byKey(const Key('live-claim')), findsOneWidget);
  });

  testWidgets('home on a phone passes the checks and renders in dark mode', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([batch]),
      'GET /v1/tracker/sessions/me': (_) => json(activity()),
    });
    await pumpApp(tester, backend, size: const Size(390, 2400));
    await expectAccessible(tester);
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester, backend, dark: true);
    await expectRendersDark(tester);
  });
}
