import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:yantra_app/core/widgets/portal_page.dart';

import '../support/fake_backend.dart';
import 'fixtures_console.dart';

Map<String, Object?> me({String status = 'eligible', List<String> gates = const ['hindi_audio'], Map<String, Object?>? availability}) => {
  'id': 'worker-1',
  'status': status,
  'cert_gates': gates,
  'availability': availability ?? {'weekly_hours': 20, 'paused_until': null, 'updated_at': '2026-11-01T00:00:00Z'},
  'updated_at': '2026-11-01T00:00:00Z',
};

const channel = {'worker_id': 'worker-1', 'email': 'w1@example.com', 'updated_at': '2026-11-03T00:00:00Z'};

/// Echoes the availability the app sent, as the gateway does.
Handler echoAvailability = (request) {
  final body = jsonDecode(request.body) as Map<String, Object?>;
  return json({...body, 'updated_at': '2026-11-03T00:00:00Z'});
};

Map<String, Handler> baseRoutes({Map<String, Object?>? worker}) => {
  'GET /v1/claims/active': (_) => json({'claim': null, 'unit': null}),
  'GET /v1/batches': (_) => json([]),
  'GET /v1/notify/inbox': (_) => json([]),
  'GET /v1/workers/me': (_) => json(worker ?? me()),
  'GET /v1/notify/channel': (_) => json(channel),
  'GET /v1/notify/tickets/me': (_) => json([]),
};

/// Wide: the sidebar carries a Profile item. Narrow: Profile is behind the avatar in the top bar.
Future<void> openProfile(WidgetTester tester, FakeBackend backend, {bool wide = true}) async {
  await pumpApp(tester, backend, size: wide ? const Size(1280, 2400) : const Size(390, 2400));
  await tester.tap(find.byKey(Key(wide ? 'nav-profile' : 'avatar-menu')));
  await tester.pumpAndSettle();
}

/// Scrolls the page (not the sidebar) until [target] is built and on screen.
Future<void> reveal(WidgetTester tester, Finder target) async {
  final page = find.descendant(of: find.byType(PortalPage), matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(target, 300, scrollable: page);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('identity shows the worker, the status chip and certifications from GET /v1/workers/me', (tester) async {
    final backend = FakeBackend(baseRoutes());
    await openProfile(tester, backend);
    expect(find.text('worker1'), findsWidgets);
    expect(find.text('worker-1'), findsOneWidget);
    expect(find.text('Eligible'), findsOneWidget);
    expect(find.text('Hindi audio'), findsOneWidget);
    expect(find.text('20 h per week'), findsOneWidget);
    expect(find.text('w1@example.com'), findsOneWidget);
    expect(backend.sent('GET', '/v1/workers/me'), isNotEmpty);
    await expectAccessible(tester);
  });

  testWidgets('an unknown worker reads as not onboarded; a suspended one in the destructive family', (tester) async {
    await openProfile(tester, FakeBackend(baseRoutes(worker: {'id': 'worker-1', 'status': 'unknown', 'cert_gates': []})));
    expect(find.text('Not onboarded yet'), findsOneWidget);
    expect(find.textContaining('None yet.'), findsOneWidget);
  });

  testWidgets('an operator or client gets the account card, theme, policies, support and sign-out, and no worker calls', (tester) async {
    final backend = FakeBackend(baseRoutes());
    await pumpApp(tester, backend, size: const Size(1280, 2400), roles: ['ops', 'finance']);
    await tester.tap(find.byKey(const Key('nav-profile')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/workers/me'), isEmpty);
    expect(backend.sent('GET', '/v1/notify/channel'), isEmpty);
    expect(find.byKey(const Key('account-role')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('account-role'))).data, 'Operator');
    expect(find.text('Worker id'), findsNothing);
    expect(find.text('Availability'), findsNothing);
    expect(find.text('Notifications'), findsNothing);
    expect(find.byKey(const Key('theme-mode')), findsOneWidget);
    expect(find.text('Policies'), findsOneWidget);
    expect(find.byKey(const Key('report-problem')), findsOneWidget);
    expect(find.byKey(const Key('logout-profile')), findsOneWidget);
  });

  testWidgets('a failed worker load shows an inline error while notifications still render', (tester) async {
    final backend = FakeBackend({
      ...baseRoutes(),
      'GET /v1/workers/me': (_) => envelope(503, 'upstream_unavailable', headers: {'retry-after': '3'}),
    });
    await openProfile(tester, backend);
    expect(find.text('Service is away. Retry in 3s.'), findsWidgets);
    expect(find.text('w1@example.com'), findsOneWidget);
    expect(find.byKey(const Key('hours-slider')), findsNothing);
  });

  testWidgets('saving the slider PUTs weekly_hours with an idempotency key', (tester) async {
    final backend = FakeBackend({...baseRoutes(), 'PUT /v1/workers/me/availability': echoAvailability});
    await openProfile(tester, backend);
    final slider = tester.widget<Slider>(find.byKey(const Key('hours-slider')));
    expect(slider.value, 20);
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(
      tester.getSemantics(find.byKey(const Key('hours-slider'))).label,
      'Hours per week',
      reason: 'the slider is announced by its label',
    );
    semantics.dispose();
    slider.onChanged!(35);
    await tester.pump();
    expect(find.text('35 h per week'), findsOneWidget);

    await tester.tap(find.byKey(const Key('save-availability')));
    await tester.pumpAndSettle();
    final sent = backend.sent('PUT', '/v1/workers/me/availability').single;
    expect(jsonDecode(sent.body), {'weekly_hours': 35, 'paused_until': null});
    expect(sent.headers['Idempotency-Key'], isNotNull);
    expect(find.text('Availability saved'), findsOneWidget);
  });

  testWidgets('pause for a week PUTs paused_until a week ahead and the banner appears; resume clears it', (tester) async {
    final backend = FakeBackend({...baseRoutes(), 'PUT /v1/workers/me/availability': echoAvailability});
    await openProfile(tester, backend);
    expect(find.byKey(const Key('paused-banner')), findsNothing);

    await tester.tap(find.byKey(const Key('pause-1w')));
    await tester.pumpAndSettle();
    expect(find.text('Pause for 1 week?'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Pause')));
    await tester.pumpAndSettle();

    final sent = backend.sent('PUT', '/v1/workers/me/availability').single;
    final body = jsonDecode(sent.body) as Map<String, Object?>;
    expect(body['weekly_hours'], 20);
    final until = DateTime.parse(body['paused_until'] as String);
    final ahead = until.difference(DateTime.now());
    expect(ahead.inHours, inInclusiveRange(167, 168));
    expect(find.byKey(const Key('paused-banner')), findsOneWidget);
    expect(find.textContaining('Paused until'), findsOneWidget);
    expect(find.byKey(const Key('pause-1w')), findsNothing);

    await tester.tap(find.byKey(const Key('resume')));
    await tester.pumpAndSettle();
    final resumed = backend.sent('PUT', '/v1/workers/me/availability')[1];
    expect(jsonDecode(resumed.body), {'weekly_hours': 20, 'paused_until': null});
    expect(find.byKey(const Key('paused-banner')), findsNothing);
    expect(find.byKey(const Key('pause-1w')), findsOneWidget);
  });

  testWidgets('a worker already paused sees the banner on load', (tester) async {
    final until = DateTime.now().add(const Duration(days: 3)).toUtc().toIso8601String();
    await openProfile(tester, FakeBackend(baseRoutes(worker: me(availability: {'weekly_hours': 10, 'paused_until': until}))));
    expect(find.byKey(const Key('paused-banner')), findsOneWidget);
    expect(find.byKey(const Key('resume')), findsOneWidget);
  });

  testWidgets('the email dialog validates and saves through PUT /v1/notify/channel', (tester) async {
    final backend = FakeBackend({
      ...baseRoutes(),
      'GET /v1/notify/channel': (_) => json({'worker_id': 'worker-1', 'email': ''}),
      'PUT /v1/notify/channel': (_) => json(channel),
    });
    await openProfile(tester, backend, wide: false);
    expect(find.text('Not set'), findsOneWidget);
    await tester.tap(find.byKey(const Key('email-settings')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('email-input')), 'not-an-email');
    await tester.tap(find.byKey(const Key('email-save')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid email'), findsOneWidget);
    expect(backend.sent('PUT', '/v1/notify/channel'), isEmpty);

    await tester.enterText(find.byKey(const Key('email-input')), 'w1@example.com');
    await tester.tap(find.byKey(const Key('email-save')));
    await tester.pumpAndSettle();
    final sent = backend.sent('PUT', '/v1/notify/channel').single;
    expect(sent.body, '{"email":"w1@example.com"}');
    expect(sent.headers['Idempotency-Key'], isNotNull);
    expect(find.byKey(const Key('email-input')), findsNothing, reason: 'the dialog closed');
    expect(find.text('w1@example.com'), findsOneWidget);
  });

  testWidgets('a worker who never set an email (notify answers 404 no channel) is offered the form, not an error', (tester) async {
    final backend = FakeBackend({
      ...baseRoutes(),
      'GET /v1/notify/channel': (_) => http.Response(
        '{"code":"not_found","message":"no channel set","worker_id":"worker-1"}',
        404,
        headers: {'content-type': 'application/json'},
      ),
      'PUT /v1/notify/channel': (_) => json(channel),
    });
    await openProfile(tester, backend, wide: false);
    expect(find.text('Not set'), findsOneWidget);
    expect(find.textContaining('no longer there'), findsNothing);
    expect(find.byKey(const Key('email-settings')), findsOneWidget);
  });

  testWidgets('the theme segmented button switches the app brightness', (tester) async {
    await openProfile(tester, FakeBackend(baseRoutes()));
    final seg = find.byKey(const Key('theme-mode'));
    expect(Theme.of(tester.element(seg)).brightness, Brightness.light);
    await tester.tap(find.descendant(of: seg, matching: find.text('Dark')));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(seg)).brightness, Brightness.dark);
    await tester.tap(find.descendant(of: seg, matching: find.text('Light')));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(seg)).brightness, Brightness.light);
  });

  testWidgets('a policy tile opens the policies route on that policy', (tester) async {
    await openProfile(tester, FakeBackend(baseRoutes()));
    await tester.tap(find.byKey(const Key('policy-disputes')));
    await tester.pumpAndSettle();
    expect(find.text('Policies'), findsOneWidget);
    expect(find.byKey(const Key('policy-body-disputes')), findsOneWidget);
    expect(find.text('How to challenge a verdict you believe is wrong.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('policy-nav-glossary')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('policy-body-glossary')), findsOneWidget);
    expect(find.textContaining('Rubric version:'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('policy-disputes')), findsOneWidget, reason: 'back on Profile');
  });

  testWidgets('on a phone the policies route offers a dropdown instead of the side list', (tester) async {
    await openProfile(tester, FakeBackend(baseRoutes()), wide: false);
    await tester.tap(find.byKey(const Key('policy-pay-cycle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('policy-picker')), findsOneWidget);
    expect(find.byKey(const Key('policy-nav-glossary')), findsNothing);
    expect(find.textContaining('Saturday 00:00 to Friday 23:59'), findsOneWidget);
  });

  testWidgets('sign out asks first, then returns to the login screen', (tester) async {
    await openProfile(tester, FakeBackend(baseRoutes()));
    await reveal(tester, find.byKey(const Key('logout-profile')));
    await tester.tap(find.byKey(const Key('logout-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('logout-profile')), findsOneWidget);

    await reveal(tester, find.byKey(const Key('logout-profile')));
    await tester.tap(find.byKey(const Key('logout-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Sign out')));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to Yantra'), findsOneWidget);
  });

  testWidgets('"Report a problem" validates, POSTs the ticket with the screen and context, then lists it', (tester) async {
    var sent = false;
    final backend = FakeBackend({
      ...baseRoutes(),
      'GET /v1/notify/tickets/me': (_) => json(sent ? [ticket('t9', title: 'Slider will not move', category: 'bug')] : []),
      'POST /v1/notify/tickets': (r) {
        sent = true;
        final body = jsonDecode(r.body) as Map<String, Object?>;
        return json({...ticket('t9', title: body['title'] as String, category: body['category'] as String), ...body}, status: 201);
      },
    });
    await openProfile(tester, backend);
    expect(find.text('No tickets yet.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('report-problem')));
    await tester.pumpAndSettle();
    expect(find.text('Sent from Profile · /profile. Ops answer in your inbox; your ticket stays listed here.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ticket-send')));
    await tester.pumpAndSettle();
    expect(find.text('Give the problem a short title'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('ticket-title')), 'Slider will not move');
    await tester.tap(find.byKey(const Key('ticket-send')));
    await tester.pumpAndSettle();
    expect(find.text('Say what happened, in at least 10 characters'), findsOneWidget);
    expect(backend.sent('POST', '/v1/notify/tickets'), isEmpty);
    await tester.enterText(find.byKey(const Key('ticket-body')), 'The hours slider snaps back to 20 every time.');
    await tester.tap(find.descendant(of: find.byKey(const Key('ticket-category')), matching: find.text('Account')));
    await tester.tap(find.byKey(const Key('ticket-send')));
    await tester.pumpAndSettle();

    final req = backend.sent('POST', '/v1/notify/tickets').single;
    expect(req.headers['Idempotency-Key'], isNotNull);
    final body = jsonDecode(req.body) as Map<String, Object?>;
    expect(body['category'], 'account');
    expect(body['title'], 'Slider will not move');
    expect(body['body'], 'The hours slider snaps back to 20 every time.');
    expect(body['screen'], 'Profile · /profile');
    expect(body['context'], {'app': 'web', 'theme': 'light', 'width': 1280});
    expect(find.byKey(const Key('ticket-title')), findsNothing, reason: 'the dialog closed');
    expect(find.text('Ticket sent. Ops read it and answer in your inbox.'), findsOneWidget);
    expect(find.byKey(const Key('my-ticket-t9')), findsOneWidget, reason: 'the list reloaded');
    expect(find.text('Slider will not move'), findsOneWidget);
  });

  testWidgets('My tickets shows status chips and the ops note once resolved; a failed list leaves the button usable', (tester) async {
    final backend = FakeBackend({
      ...baseRoutes(),
      'GET /v1/notify/tickets/me': (_) => json([
        ticket('t1', title: 'Submit button does nothing'),
        ticket('t2', status: 'in_progress', category: 'payment', title: 'Payout reference missing'),
        ticket('t3', status: 'resolved', category: 'work', title: 'Unit payload empty', note: 'Re-imported the batch'),
      ]),
    });
    await openProfile(tester, backend, wide: false);
    await reveal(tester, find.byKey(const Key('my-ticket-t1')));
    expect(find.byKey(const Key('my-ticket-t1')), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('In progress'), findsOneWidget);
    expect(find.text('Resolved'), findsOneWidget);
    expect(find.text('Ops: Re-imported the batch'), findsOneWidget);
    expect(find.text('Bug · on Work · 5 h ago'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await openProfile(
      tester,
      FakeBackend({
        ...baseRoutes(),
        'GET /v1/notify/tickets/me': (_) => envelope(503, 'upstream_unavailable', headers: {'retry-after': '3'}),
      }),
    );
    expect(find.text('Service is away. Retry in 3s.'), findsOneWidget);
    expect(find.byKey(const Key('report-problem')), findsOneWidget);
  });

  testWidgets('a refused ticket stays in the dialog with the reason', (tester) async {
    final backend = FakeBackend({
      ...baseRoutes(),
      'POST /v1/notify/tickets': (_) => envelope(429, 'rate_limited', headers: {'retry-after': '9'}),
    });
    await openProfile(tester, backend);
    await tester.tap(find.byKey(const Key('report-problem')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ticket-title')), 'A title');
    await tester.enterText(find.byKey(const Key('ticket-body')), 'A body long enough to send.');
    await tester.tap(find.byKey(const Key('ticket-send')));
    await tester.pumpAndSettle();
    expect(find.text('Too many requests. Wait 9s and try again.'), findsOneWidget);
    expect(find.byKey(const Key('ticket-send')), findsOneWidget);
  });

  Map<String, Object?> onboardingWith({bool consent = true, Map<String, Object?>? erasure}) => {
    'complete': false,
    'steps': [
      if (consent) {'key': 'consent', 'status': 'done', 'group': 'Documents', 'done_at': '2026-11-01T00:00:00Z'},
    ],
    'consent_version': consent ? '2' : null,
    'erasure': erasure,
  };

  testWidgets('your data: what we track, withdraw consent after a warning, and ask for erasure', (tester) async {
    var consent = true;
    Map<String, Object?>? erasure;
    final backend = FakeBackend({
      ...baseRoutes(),
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboardingWith(consent: consent, erasure: erasure)),
      'PUT /v1/talent/workers/me/onboarding/consent': (r) {
        expect(jsonDecode(r.body), {'accepted': false});
        consent = false;
        return json(onboardingWith(consent: false));
      },
      'POST /v1/talent/workers/me/erasure': (_) {
        erasure = {
          'worker_id': 'worker-1',
          'status': 'requested',
          'requested_at': '2026-11-04T00:00:00Z',
          'due_at': '2026-12-04T00:00:00Z',
        };
        return json(erasure!, status: 201);
      },
    });
    await openProfile(tester, backend);
    await reveal(tester, find.byKey(const Key('data-card')));
    expect(find.text('You consented to the use of your personal data (version 2).'), findsOneWidget);

    await tester.tap(find.byKey(const Key('what-we-track')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Keystrokes'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('withdraw-consent')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.sent('PUT', '/v1/talent/workers/me/onboarding/consent'), isEmpty);
    await tester.tap(find.byKey(const Key('withdraw-consent')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Withdraw consent')));
    await tester.pumpAndSettle();
    expect(find.textContaining('You have not given data consent'), findsOneWidget);
    expect(find.byKey(const Key('withdraw-consent')), findsNothing);

    await tester.tap(find.byKey(const Key('request-erasure')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete my data')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/talent/workers/me/erasure').single.headers['Idempotency-Key'], isNotEmpty);
    expect(find.textContaining('Erasure requested. Your personal data is erased by 4 Dec'), findsOneWidget);
    expect(find.byKey(const Key('request-erasure')), findsNothing);
  });

  testWidgets('a finished erasure says so; failures to withdraw or erase say why', (tester) async {
    final backend = FakeBackend({
      ...baseRoutes(),
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboardingWith()),
      'PUT /v1/talent/workers/me/onboarding/consent': (_) => envelope(503, 'unavailable'),
      'POST /v1/talent/workers/me/erasure': (_) => envelope(409, 'erasure_pending', message: 'An erasure is already pending'),
    });
    await openProfile(tester, backend);
    await reveal(tester, find.byKey(const Key('data-card')));
    await tester.tap(find.byKey(const Key('withdraw-consent')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Withdraw consent')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.pump(const Duration(seconds: 6)); // let the toast go
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('request-erasure')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete my data')));
    await pumpFor(tester);
    expect(backend.sent('POST', '/v1/talent/workers/me/erasure'), hasLength(1));
    expect(find.text('You already asked for your data to be deleted; that request is being handled.'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());

    final done = FakeBackend({
      ...baseRoutes(),
      'GET /v1/talent/workers/me/onboarding': (_) => json(
        onboardingWith(
          consent: false,
          erasure: {
            'worker_id': 'worker-1',
            'status': 'done',
            'requested_at': '2026-10-01T00:00:00Z',
            'due_at': '2026-10-31T00:00:00Z',
            'done_at': '2026-10-20T00:00:00Z',
          },
        ),
      ),
    });
    await openProfile(tester, done);
    await reveal(tester, find.byKey(const Key('data-card')));
    expect(find.text('Your personal data was erased on 20 Oct.'), findsOneWidget);
  });

  testWidgets('policies come from the server, and an operator sees only conduct and the glossary', (tester) async {
    final backend = FakeBackend({
      ...baseRoutes(),
      'GET /v1/talent/policies': (_) => json([
        {'slug': 'pay-cycle', 'version': '3', 'title': 'Pay cycle (served)', 'summary': 'Served summary', 'sections': []},
        {'slug': 'conduct', 'version': '1', 'title': 'Conduct', 'summary': 'Rules', 'sections': []},
      ]),
    });
    await openProfile(tester, backend);
    await reveal(tester, find.byKey(const Key('policy-pay-cycle')));
    expect(find.text('Pay cycle (served)'), findsOneWidget);
    expect(find.byKey(const Key('policy-tracking')), findsOneWidget, reason: 'a shipped policy the server lacks is still offered');
    await tester.pumpWidget(const SizedBox());

    await pumpApp(tester, backend, size: const Size(1280, 2400), roles: const ['ops', 'finance'], at: '/profile');
    await reveal(tester, find.byKey(const Key('policy-conduct')));
    expect(find.byKey(const Key('policy-pay-cycle')), findsNothing);
    expect(find.byKey(const Key('policy-glossary')), findsOneWidget);
    expect(find.byKey(const Key('data-card')), findsNothing);
  });

  testWidgets('the policies page shows the served text and its version', (tester) async {
    final backend = FakeBackend({
      ...baseRoutes(),
      'GET /v1/talent/policies': (_) => json([
        {
          'slug': 'pay-cycle',
          'version': '3',
          'title': 'Pay cycle',
          'summary': 'When the week closes.',
          'sections': [
            {
              'title': 'Served section',
              'paragraphs': ['Served paragraph.'],
              'bullets': ['Served bullet.'],
            },
          ],
        },
      ]),
    });
    await pumpApp(tester, backend, size: const Size(1280, 2400), at: '/profile/policies/pay-cycle');
    expect(find.text('Served paragraph.'), findsOneWidget);
    expect(find.text('Version 3'), findsOneWidget);
    await tester.tap(find.byKey(const Key('policy-nav-tracking')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Keystrokes'), findsOneWidget);
  });

  testWidgets('Report a problem in the top bar fills in the page it was opened on', (tester) async {
    final backend = FakeBackend({
      ...baseRoutes(),
      'POST /v1/notify/tickets': (r) => json({
        ...jsonDecode(r.body) as Map<String, Object?>,
        'id': 't9',
        'author_id': 'worker-1',
        'status': 'open',
        'created_at': '2026-11-04T10:00:00Z',
        'updated_at': '2026-11-04T10:00:00Z',
      }, status: 201),
    });
    await pumpApp(tester, backend, size: const Size(1280, 2400), at: '/work/earnings');
    await tester.tap(find.byKey(const Key('report-problem-bar')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Sent from Earnings · /work/earnings'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('ticket-title')), 'Statement missing');
    await tester.enterText(find.byKey(const Key('ticket-body')), 'The statement button gives nothing for last week');
    await tester.tap(find.byKey(const Key('ticket-send')));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('POST', '/v1/notify/tickets').single.body)['screen'], 'Earnings · /work/earnings');
    expect(find.textContaining('Ticket sent'), findsOneWidget);
  });

  testWidgets('the palette offers Report a problem on every page', (tester) async {
    await pumpApp(tester, FakeBackend(baseRoutes()), size: const Size(1280, 2400));
    await tester.tap(find.byKey(const Key('command-palette')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('palette-query')), 'report');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('palette-report-problem')));
    await tester.pumpAndSettle();
    expect(find.text('Report a problem'), findsWidgets);
    expect(find.textContaining('Sent from Home · /work/home'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ticket-cancel')));
    await tester.pumpAndSettle();
  });

  testWidgets('profile on a phone passes the checks and renders in dark mode', (tester) async {
    final backend = FakeBackend({...baseRoutes(), 'GET /v1/talent/workers/me/onboarding': (_) => json(onboardingWith())});
    await openProfile(tester, backend, wide: false);
    await expectAccessible(tester);
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester, backend, dark: true, at: '/profile');
    await expectRendersDark(tester);
  });

  Map<String, Object?> pending({String? email, String pendingEmail = 'new@example.com', String? error, bool sent = true}) => {
    'worker_id': 'worker-1',
    'email': email,
    'email_verified_at': email == null ? null : '2026-11-01T00:00:00Z',
    'pending_email': pendingEmail,
    'verify_expires_at': '2026-11-05T10:15:00Z',
    'verify_sent_at': sent ? '2026-11-05T10:00:00Z' : null,
    'verify_error': error,
    'updated_at': '2026-11-05T10:00:00Z',
  };

  testWidgets('a pending email asks for its code: a short code is caught, a wrong one says how many tries are left', (tester) async {
    var calls = 0;
    final backend = FakeBackend({
      ...baseRoutes(),
      'GET /v1/notify/channel': (_) => json(pending(email: 'old@example.com')),
      'POST /v1/notify/channel/verify': (r) {
        calls++;
        if (calls == 1) return envelope(422, 'wrong_code', context: {'attempts_left': 2});
        expect(jsonDecode(r.body), {'code': '654321'});
        return json({'worker_id': 'worker-1', 'email': 'new@example.com', 'email_verified_at': '2026-11-05T10:05:00Z'});
      },
    });
    await openProfile(tester, backend);
    expect(find.text('old@example.com'), findsOneWidget, reason: 'mail still goes to the verified address');
    expect(find.text('We sent a code to new@example.com. Enter it here.'), findsOneWidget);
    expect(find.byKey(const Key('verify-expiry')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('verify-code')), '12');
    await tester.tap(find.byKey(const Key('verify-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Enter the 6-digit code from the email.'), findsOneWidget);
    expect(backend.sent('POST', '/v1/notify/channel/verify'), isEmpty);

    await tester.enterText(find.byKey(const Key('verify-code')), '123456');
    await tester.tap(find.byKey(const Key('verify-submit')));
    await tester.pumpAndSettle();
    expect(find.text('That code is not the one we sent. 2 tries left.'), findsOneWidget);
    expect(backend.sent('POST', '/v1/notify/channel/verify').single.headers['Idempotency-Key'], isNotEmpty);

    await tester.enterText(find.byKey(const Key('verify-code')), '654321');
    await tester.tap(find.byKey(const Key('verify-submit')));
    await tester.pumpAndSettle();
    expect(find.text('new@example.com'), findsOneWidget);
    expect(find.byKey(const Key('email-verified')), findsOneWidget);
    expect(find.byKey(const Key('verify-code')), findsNothing);
    expect(find.text('Email verified'), findsOneWidget);
    await expectAccessible(tester);
  });

  testWidgets('"Send a new code" PUTs the pending address again; expired, spent and unsent codes say what to do', (tester) async {
    var answer = envelope(409, 'code_expired');
    final backend = FakeBackend({
      ...baseRoutes(),
      'GET /v1/notify/channel': (_) => json(pending(error: 'smtp refused', sent: false)),
      'POST /v1/notify/channel/verify': (_) => answer,
      'PUT /v1/notify/channel': (_) => json(pending()),
    });
    await openProfile(tester, backend, wide: false);
    expect(find.text('Not set'), findsOneWidget);
    expect(find.text("We couldn't send a code to new@example.com. Send a new code."), findsOneWidget);

    await tester.enterText(find.byKey(const Key('verify-code')), '123456');
    await tester.tap(find.byKey(const Key('verify-submit')));
    await tester.pumpAndSettle();
    expect(find.text('This code expired; codes last 15 minutes. Send a new code.'), findsOneWidget);

    answer = envelope(409, 'too_many_attempts');
    await tester.tap(find.byKey(const Key('verify-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Too many wrong codes. Send a new code to try again.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('verify-resend')));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('PUT', '/v1/notify/channel').single.body), {'email': 'new@example.com'});
    expect(find.text('We sent a new code to new@example.com'), findsOneWidget);
    expect(find.text('We sent a code to new@example.com. Enter it here.'), findsOneWidget);
    expect(find.text('Too many wrong codes. Send a new code to try again.'), findsNothing, reason: 'a new code clears the old error');
  });

  testWidgets('saving a new address in the dialog says a code is on its way and opens the code field', (tester) async {
    final backend = FakeBackend({...baseRoutes(), 'PUT /v1/notify/channel': (_) => json(pending(email: 'w1@example.com', sent: false))});
    await openProfile(tester, backend);
    await tester.tap(find.byKey(const Key('email-settings')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('email-input')), 'new@example.com');
    await tester.tap(find.byKey(const Key('email-save')));
    await tester.pumpAndSettle();
    expect(find.text('We are sending a code to new@example.com'), findsWidgets);
    expect(find.byKey(const Key('verify-code')), findsOneWidget);
  });

  testWidgets('after withdrawing, "Give consent again" accepts the current consent text', (tester) async {
    var consent = false;
    final backend = FakeBackend({
      ...baseRoutes(),
      'GET /v1/talent/policies': (_) => json([
        {'slug': 'dpdp-consent', 'version': '3', 'title': 'Data consent', 'summary': 'What we keep.', 'sections': []},
      ]),
      'GET /v1/talent/workers/me/onboarding': (_) => json(onboardingWith(consent: consent)),
      'PUT /v1/talent/workers/me/onboarding/consent': (r) {
        consent = true;
        return json({...onboardingWith(), 'consent_version': '3'});
      },
    });
    await openProfile(tester, backend);
    await reveal(tester, find.byKey(const Key('data-card')));
    expect(find.textContaining('You have not given data consent'), findsOneWidget);
    expect(find.byKey(const Key('read-consent')), findsOneWidget);
    await tester.tap(find.byKey(const Key('give-consent')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.sent('PUT', '/v1/talent/workers/me/onboarding/consent'), isEmpty);

    await tester.tap(find.byKey(const Key('give-consent')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Give consent')));
    await tester.pumpAndSettle();
    final sent = backend.sent('PUT', '/v1/talent/workers/me/onboarding/consent').single;
    expect(jsonDecode(sent.body), {'accepted': true, 'version': '3'});
    expect(sent.headers['Idempotency-Key'], isNotEmpty);
    expect(find.text('You consented to the use of your personal data (version 3).'), findsOneWidget);
    expect(find.byKey(const Key('give-consent')), findsNothing);
    expect(find.text('Consent given. You can take new work again.'), findsOneWidget);
  });
}
