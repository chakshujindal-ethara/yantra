import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/screens/listing_screen.dart';

import '../support/fake_backend.dart';
import 'fixtures.dart';
import 'fixtures_talent.dart';

final pools = [
  listing(),
  listing(
    id: 'l2',
    title: 'Product photo tagging',
    domain: 'tagging',
    commitment: 'part_time',
    hours: 20,
    slotsTotal: 50,
    slotsFilled: 10,
    prequalified: true,
    payMin: '5',
    payMax: '9',
    paperId: '',
  ),
  listing(id: 'l3', title: 'Tamil audio transcription', slotsTotal: 5, slotsFilled: 5, applicationStatus: 'screening', applicationId: 'a3'),
];

Future<TestHarness> openExplore(WidgetTester tester, FakeBackend backend, {Size size = const Size(900, 2400)}) async {
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
  if (size.width >= 960) {
    await tester.tap(find.byKey(const Key('nav-explore')));
  } else {
    await tester.tap(find.text('Explore'));
  }
  await tester.pumpAndSettle();
  return harness;
}

Finder chip(String label) => find.widgetWithText(StatusChip, label);

void main() {
  testWidgets('listings render as cards with pay, commitment, slots and the worker standing', (tester) async {
    final backend = FakeBackend({'GET /v1/talent/listings': (_) => json(pools)});
    await openExplore(tester, backend);
    expect(pageTitle(tester), 'Explore');
    expect(find.text('Hindi audio transcription'), findsOneWidget);
    expect(find.text('₹28–40 per accepted unit'), findsNWidgets(2));
    expect(find.text('₹5–9 per accepted unit'), findsOneWidget);
    expect(find.text('Task-based · 10 h per week'), findsNWidgets(2));
    expect(find.text('Part-time · 20 h per week'), findsOneWidget);
    expect(find.text('Transcription'), findsNWidgets(3), reason: 'two domain chips and the filter chip');
    expect(chip('2 slots left'), findsOneWidget);
    expect(tester.widget<StatusChip>(chip('2 slots left')).kind, StatusKind.warn);
    expect(tester.widget<StatusChip>(chip('40 slots left')).kind, StatusKind.info);
    expect(chip('Full'), findsOneWidget);
    expect(chip('Prequalified'), findsOneWidget);
    expect(chip('Screening'), findsOneWidget);
    // the API's order is kept: open slots first
    expect(tester.getTopLeft(find.byKey(const Key('listing-l1'))).dy, lessThan(tester.getTopLeft(find.byKey(const Key('listing-l3'))).dy));
    await expectAccessible(tester);
  });

  testWidgets('filters by domain and by commitment narrow the cards', (tester) async {
    final backend = FakeBackend({'GET /v1/talent/listings': (_) => json(pools)});
    await openExplore(tester, backend);
    await tester.tap(find.byKey(const Key('filter-tagging')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('listing-l2')), findsOneWidget);
    expect(find.byKey(const Key('listing-l1')), findsNothing);
    await tester.tap(find.byKey(const Key('filter-all-domains')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-task-based')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('listing-l1')), findsOneWidget);
    expect(find.byKey(const Key('listing-l3')), findsOneWidget);
    expect(find.byKey(const Key('listing-l2')), findsNothing);
    await tester.tap(find.byKey(const Key('filter-tagging')));
    await tester.pumpAndSettle();
    expect(find.text('No pools match these filters.'), findsOneWidget);
  });

  testWidgets('no listings shows the empty state', (tester) async {
    final backend = FakeBackend({'GET /v1/talent/listings': (_) => json([])});
    await openExplore(tester, backend);
    expect(find.text('No open pools right now; your certifications unlock pools automatically.'), findsOneWidget);
  });

  testWidgets('a failed load shows the error and Retry', (tester) async {
    var calls = 0;
    final backend = FakeBackend({
      'GET /v1/talent/listings': (_) => ++calls == 1 ? envelope(503, 'upstream_unavailable', headers: {'retry-after': '3'}) : json(pools),
    });
    await openExplore(tester, backend);
    expect(find.text('Service is away. Retry in 3s.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('listing-l1')), findsOneWidget);
  });

  testWidgets('two columns of cards on a desktop, one on a phone', (tester) async {
    final backend = FakeBackend({'GET /v1/talent/listings': (_) => json(pools)});
    await openExplore(tester, backend, size: const Size(1280, 1600));
    expect(tester.getTopLeft(find.byKey(const Key('listing-l1'))).dy, tester.getTopLeft(find.byKey(const Key('listing-l2'))).dy);
    expect(tester.getTopLeft(find.byKey(const Key('listing-l1'))).dx, lessThan(tester.getTopLeft(find.byKey(const Key('listing-l2'))).dx));
    expect(tester.takeException(), isNull);
  });

  testWidgets('one column of cards on a phone without overflow', (tester) async {
    final backend = FakeBackend({'GET /v1/talent/listings': (_) => json(pools)});
    await openExplore(tester, backend, size: const Size(390, 3000));
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(find.byKey(const Key('listing-l1'))).dx, tester.getTopLeft(find.byKey(const Key('listing-l2'))).dx);
    expect(tester.getTopLeft(find.byKey(const Key('listing-l1'))).dy, lessThan(tester.getTopLeft(find.byKey(const Key('listing-l2'))).dy));
  });

  testWidgets('a card opens the listing with its description, requirements, steps, policy and apply card', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/listings': (_) => json(pools),
      'GET /v1/talent/listings/l1': (_) => json(listing(sensitive: true)),
    });
    await openExplore(tester, backend);
    await tester.tap(find.byKey(const Key('listing-l1')));
    await tester.pumpAndSettle();
    expect(find.byType(ListingScreen), findsOneWidget);
    expect(find.text('Listen to 10–30 second clips and type exactly what is said.'), findsOneWidget);
    expect(find.text('Native Hindi speaker'), findsOneWidget);
    expect(find.text('Quiet workspace'), findsOneWidget);
    expect(find.byKey(const Key('how-form')), findsOneWidget);
    expect(find.byKey(const Key('how-paper')), findsOneWidget);
    expect(find.byKey(const Key('how-availability')), findsOneWidget);
    expect(find.text('No LLM assistance; every transcript is typed by you.'), findsOneWidget);
    expect(find.textContaining('sensitive content'), findsOneWidget);
    expect(find.text('₹28–40'), findsOneWidget);
    expect(chip('2 slots left'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('apply'))).onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('back')));
    await tester.pumpAndSettle();
    expect(find.byType(ListingScreen), findsNothing);
    expect(backend.sent('GET', '/v1/talent/listings'), hasLength(2), reason: 'Explore reloads after the route pops');
  });

  testWidgets('apply enforces required questions, posts the answers with one key, and shows the status', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/listings': (_) => json(pools),
      'GET /v1/talent/listings/l1': (_) => json(listing()),
      'POST /v1/talent/listings/l1/applications': (_) => json(application(status: 'assessment'), status: 201),
    });
    await openExplore(tester, backend);
    await tester.tap(find.byKey(const Key('listing-l1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('apply')));
    await tester.pumpAndSettle();
    expect(find.text('Why this pool? *'), findsOneWidget);
    await tester.tap(find.byKey(const Key('apply-send')));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsOneWidget);
    expect(find.text('Pick one'), findsOneWidget);
    expect(backend.sent('POST', '/v1/talent/listings/l1/applications'), isEmpty);

    await tester.enterText(find.byKey(const Key('q-why')), 'I transcribe daily');
    await tester.tap(find.byKey(const Key('q-shift-night')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('apply-send')));
    await tester.pumpAndSettle();
    final sent = backend.sent('POST', '/v1/talent/listings/l1/applications').single;
    expect(jsonDecode(sent.body), {
      'answers': {'why': 'I transcribe daily', 'shift': 'night'},
    });
    expect(sent.headers['Idempotency-Key'], isNotEmpty);
    expect(find.text('Application sent'), findsOneWidget);
    expect(chip('Paper pending'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('apply'))).onPressed, isNull);
    expect(find.text('Applied'), findsOneWidget);
  });

  testWidgets('a 409 already_applied is shown as a banner on the apply card', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/listings': (_) => json(pools),
      'GET /v1/talent/listings/l1': (_) => json(listing(questions: [])),
      'POST /v1/talent/listings/l1/applications': (_) => envelope(409, 'already_applied', message: 'You already applied to this pool'),
    });
    await openExplore(tester, backend);
    await tester.tap(find.byKey(const Key('listing-l1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('apply-send')));
    await tester.pumpAndSettle();
    expect(find.text('You have already applied to this pool.'), findsOneWidget);
    expect(find.byKey(const Key('apply-send')), findsNothing, reason: 'the dialog closed');
  });

  testWidgets('an ended application lets the worker apply again; a 409 reloads the listing so the card is current', (tester) async {
    var reads = 0;
    final backend = FakeBackend({
      'GET /v1/talent/listings': (_) => json(pools),
      'GET /v1/talent/listings/l1': (_) =>
          json(listing(questions: [], applicationStatus: ++reads == 1 ? 'withdrawn' : 'screening', slotsFilled: reads == 1 ? 8 : 9)),
      'POST /v1/talent/listings/l1/applications': (_) => envelope(409, 'already_applied', message: 'You already applied to this pool'),
    });
    await openExplore(tester, backend);
    await tester.tap(find.byKey(const Key('listing-l1')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('apply'))).onPressed, isNotNull);
    expect(find.text('Your earlier application was withdrawn; you can apply again.'), findsOneWidget);
    expect(chip('2 slots left'), findsOneWidget);

    await tester.tap(find.byKey(const Key('apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('apply-send')));
    await tester.pumpAndSettle();
    expect(find.text('You have already applied to this pool.'), findsOneWidget);
    expect(backend.sent('GET', '/v1/talent/listings/l1'), hasLength(2), reason: 'the listing is read again after the refusal');
    expect(chip('Screening'), findsOneWidget);
    expect(chip('1 slot left'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('apply'))).onPressed, isNull);
  });

  testWidgets('the paper step a worker stands on offers Take the paper, which opens the paper in Applications', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/listings': (_) => json(pools),
      'GET /v1/talent/listings/l1': (_) => json(listing(applicationStatus: 'assessment')),
      'GET /v1/assess/papers/pp1/brief': (_) => json(brief()),
      'GET /v1/assess/sittings/me': (_) => json([]),
    });
    await openExplore(tester, backend);
    await tester.tap(find.byKey(const Key('listing-l1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('take-paper-listing')), findsOneWidget);
    await tester.tap(find.byKey(const Key('take-paper-listing')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/work/applications/assessment/pp1');
    expect(find.byKey(const Key('start-exam')), findsOneWidget);
  });

  testWidgets('before applying, and once past the paper, the step has no button', (tester) async {
    for (final status in [null, 'screening']) {
      final backend = FakeBackend({
        'GET /v1/talent/listings': (_) => json(pools),
        'GET /v1/talent/listings/l1': (_) => json(listing(applicationStatus: status)),
      });
      await openExplore(tester, backend);
      await tester.tap(find.byKey(const Key('listing-l1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('take-paper-listing')), findsNothing, reason: 'status $status');
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('a full pool, an applied pool and a closed pool disable Apply with the reason', (tester) async {
    final backend = FakeBackend({
      'GET /v1/talent/listings': (_) => json(pools),
      'GET /v1/talent/listings/l3': (_) => json(listing(id: 'l3', slotsTotal: 5, slotsFilled: 5, applicationStatus: 'screening')),
      'GET /v1/talent/listings/l2': (_) => json(listing(id: 'l2', slotsTotal: 5, slotsFilled: 5)),
      'GET /v1/talent/listings/l1': (_) => json(listing(status: 'closed', redirect: {'id': 'l9', 'title': 'Hindi evergreen'})),
      'GET /v1/talent/listings/l9': (_) => json(listing(id: 'l9', title: 'Hindi evergreen')),
    });
    await openExplore(tester, backend);
    await tester.tap(find.byKey(const Key('listing-l3')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('apply'))).onPressed, isNull);
    expect(find.text('You applied to this pool: screening.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('back')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('listing-l2')));
    await tester.pumpAndSettle();
    expect(find.text('Full'), findsWidgets);
    expect(find.text('Every slot in this pool is filled.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('back')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('listing-l1')));
    await tester.pumpAndSettle();
    expect(find.text('This pool is closed; the Hindi evergreen pool in the same domain is open.'), findsOneWidget);
    expect(find.text('This pool is closed to new applications.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('redirect-open')));
    await tester.pumpAndSettle();
    expect(find.text('Hindi evergreen'), findsWidgets);
    expect(find.byKey(const Key('redirect')), findsNothing);
  });

  testWidgets('on a phone the apply button sits in a sticky bottom bar', (tester) async {
    final backend = FakeBackend({'GET /v1/talent/listings': (_) => json(pools), 'GET /v1/talent/listings/l1': (_) => json(listing())});
    await openExplore(tester, backend, size: const Size(390, 844));
    await tester.tap(find.byKey(const Key('listing-l1')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('apply-bar')), findsOneWidget);
    final rect = tester.getRect(find.byKey(const Key('apply')));
    expect(rect.bottom, lessThanOrEqualTo(844));
    expect(rect.top, greaterThan(700));
  });

  testWidgets('a listing that fails to load offers Retry', (tester) async {
    var calls = 0;
    final backend = FakeBackend({
      'GET /v1/talent/listings': (_) => json(pools),
      'GET /v1/talent/listings/l1': (_) => ++calls == 1 ? envelope(429, 'rate_limited', headers: {'retry-after': '5'}) : json(listing()),
    });
    await openExplore(tester, backend);
    await tester.tap(find.byKey(const Key('listing-l1')));
    await tester.pumpAndSettle();
    expect(find.text('Too many requests. Wait 5s and try again.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('apply')), findsOneWidget);
  });

  testWidgets('a pool that hired this week says so on the card and the page; the listing\'s steps decide How to apply', (tester) async {
    final hiring = {
      ...listing(),
      'hired_this_week': 3,
      'steps': ['form', 'availability'],
    };
    final backend = FakeBackend({
      'GET /v1/talent/listings': (_) => json([hiring, listing(id: 'l2', title: 'Quiet pool', paperId: '')]),
      'GET /v1/talent/listings/l1': (_) => json(hiring),
    });
    await openExplore(tester, backend);
    expect(find.byKey(const Key('hired-this-week')), findsOneWidget);
    expect(find.text('3 hired this week'), findsOneWidget);
    await tester.tap(find.text('Hindi audio transcription'));
    await tester.pumpAndSettle();
    expect(find.text('3 hired this week'), findsWidgets);
    expect(find.byKey(const Key('how-form')), findsOneWidget);
    expect(find.byKey(const Key('how-paper')), findsNothing, reason: 'the listing says it has no paper step');
    expect(find.byKey(const Key('how-availability')), findsOneWidget);
  });

  testWidgets('explore on a phone passes the checks and renders in dark mode', (tester) async {
    final backend = FakeBackend({'GET /v1/talent/listings': (_) => json(pools)});
    await openExplore(tester, backend, size: const Size(390, 2400));
    await expectAccessible(tester);
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester, backend, dark: true, at: '/work/explore');
    await expectRendersDark(tester);
  });

  testWidgets('a listing page on a phone passes the checks and renders in dark mode', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([]),
      'GET /v1/talent/listings': (_) => json(pools),
      'GET /v1/talent/listings/l1': (_) => json({...listing(), 'hired_this_week': 2}),
    });
    await pumpApp(tester, backend, size: const Size(390, 2400), at: '/work/explore/l1');
    await expectAccessible(tester);
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester, backend, dark: true, at: '/work/explore/l1');
    await expectRendersDark(tester);
  });
}
