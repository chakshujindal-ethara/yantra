import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/widgets/steps.dart';
import 'package:yantra_app/core/widgets/tables.dart';

import '../../support/fake_backend.dart';
import 'fixtures_ops.dart';

List<Object?> applications() => [
  application('a1', 'applied'),
  application('a2', 'assessment', worker: 'worker-cccc-dddd'),
  application('a3', 'screening', worker: 'worker-eeee-ffff'),
  application('a4', 'offered', worker: 'worker-0000-1111'),
  application('a5', 'accepted', worker: 'worker-2222-3333'),
  application('a6', 'rejected', worker: 'worker-4444-5555'),
];

Map<String, Handler> listingRoutes() => {
  ...overviewRoutes(),
  'GET /v1/talent/listings': (_) => json([listing(), listing(id: 'l2', title: 'Street sign labelling', status: 'closed', slotsFilled: 10)]),
  'GET /v1/talent/listings/l1': (_) => json(listing()),
  'GET /v1/talent/listings/l1/applications': (_) => json(applications()),
  'GET /v1/assess/papers': (_) => json([paper(), paper(id: 'paper-2', title: 'Labelling basics')]),
  'POST /v1/talent/listings': (r) =>
      json({...listing(id: 'l9', status: 'draft'), 'title': (jsonDecode(r.body) as Map)['title']}, status: 201),
  'PATCH /v1/talent/listings/l1': (r) => json({...listing(), ...(jsonDecode(r.body) as Map)}),
  'POST /v1/talent/applications/a3/decide': (r) =>
      json(application('a3', (jsonDecode(r.body) as Map)['decision'] == 'offer' ? 'offered' : 'rejected')),
};

Future<void> openListing(WidgetTester tester, FakeBackend backend, {Size size = wide}) async {
  await pumpOps(tester, backend, size: size, navKey: 'nav-listings');
  await tester.tap(find.descendant(of: find.byKey(const Key('listing-l1')), matching: find.text('Hindi transcription pool')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists every listing with status, pay range, slots and application counts', (tester) async {
    final backend = FakeBackend(listingRoutes());
    await pumpOps(tester, backend, navKey: 'nav-listings');
    expect(backend.sent('GET', '/v1/talent/listings').single.url.queryParameters['all'], 'true');
    expect(find.text('OPERATE · LISTINGS'), findsOneWidget);
    expect(find.text('Hindi transcription pool'), findsOneWidget);
    expect(find.text('Street sign labelling'), findsOneWidget);
    expect(chip('Open'), findsOneWidget);
    expect(chip('Closed'), findsOneWidget);
    expect(find.text('₹20–40'), findsNWidgets(2));
    expect(find.text('3/10'), findsOneWidget);
    expect(find.text('10/10'), findsOneWidget);
    expect(find.text('4 applied · 2 screening · 1 offered · 3 accepted'), findsNWidgets(2));
    await expectAccessible(tester);
  });

  testWidgets('a new listing posts every field, the questions and the requirements', (tester) async {
    final backend = FakeBackend(listingRoutes());
    await pumpOps(tester, backend, navKey: 'nav-listings');
    await tester.tap(find.byKey(const Key('new-listing')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/assess/papers'), hasLength(1));

    await tester.tap(find.byKey(const Key('listing-save')));
    await tester.pumpAndSettle();
    expect(find.text('Title and domain are required'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('listing-title')), 'Tamil OCR pool');
    await tester.enterText(find.byKey(const Key('listing-domain')), 'OCR');
    await tester.enterText(find.byKey(const Key('listing-gate')), 'ocr');
    await tester.enterText(find.byKey(const Key('listing-summary')), 'Read plates.');
    await tester.enterText(find.byKey(const Key('listing-description')), 'Longer text.');
    await tester.enterText(find.byKey(const Key('listing-pay-min')), '40');
    await tester.enterText(find.byKey(const Key('listing-pay-max')), '20');
    await tester.tap(find.byKey(const Key('listing-save')));
    await tester.pumpAndSettle();
    expect(find.text('Pay range needs a minimum and a maximum, minimum first'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('listing-pay-max')), '80');
    await tester.enterText(find.byKey(const Key('listing-hours')), '15');
    await tester.enterText(find.byKey(const Key('listing-slots')), '25');
    await tester.enterText(find.byKey(const Key('listing-closes')), '2026-12-15');
    await tester.ensureVisible(find.byKey(const Key('listing-paper')));
    await tester.tap(find.byKey(const Key('listing-paper')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Labelling basics · transcription').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('listing-requirements')), 'Tamil reader\n\nA laptop');
    await tester.enterText(find.byKey(const Key('listing-llm')), 'None');
    await tester.ensureVisible(find.byKey(const Key('listing-sensitive')));
    await tester.tap(find.byKey(const Key('listing-sensitive')));
    await tester.ensureVisible(find.byKey(const Key('question-add')));
    await tester.tap(find.byKey(const Key('question-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('question-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('question-key-0')), 'exp');
    await tester.enterText(find.byKey(const Key('question-prompt-0')), 'Years of experience?');
    await tester.enterText(find.byKey(const Key('question-key-1')), 'shift');
    await tester.enterText(find.byKey(const Key('question-prompt-1')), 'Preferred shift');
    await tester.ensureVisible(find.byKey(const Key('question-kind-1')));
    await tester.tap(find.byKey(const Key('question-kind-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choice').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('listing-save')));
    await tester.pumpAndSettle();
    expect(find.text('Question 2 needs at least two options'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('question-options-1')), 'day, night');
    await tester.ensureVisible(find.byKey(const Key('question-required-1')));
    await tester.tap(find.byKey(const Key('question-required-1')));
    await tester.tap(find.byKey(const Key('listing-save')));
    await tester.pumpAndSettle();

    final post = backend.sent('POST', '/v1/talent/listings').single;
    expect(post.headers['Idempotency-Key'], isNotEmpty);
    expect(jsonDecode(post.body), {
      'title': 'Tamil OCR pool',
      'domain': 'OCR',
      'summary': 'Read plates.',
      'description': 'Longer text.',
      'pay_min': '40.00',
      'pay_max': '80.00',
      'pay_unit': 'per_unit',
      'currency': 'INR',
      'commitment': 'task_based',
      'hours_per_week': 15,
      'slots_total': 25,
      'cert_gate': 'ocr',
      'paper_id': 'paper-2',
      'requirements': ['Tamil reader', 'A laptop'],
      'questions': [
        {'key': 'exp', 'prompt': 'Years of experience?', 'kind': 'text', 'required': true},
        {
          'key': 'shift',
          'prompt': 'Preferred shift',
          'kind': 'choice',
          'options': ['day', 'night'],
          'required': false,
        },
      ],
      'llm_policy': 'None',
      'sensitive': true,
      'closes_at': '2026-12-15T00:00:00.000Z',
      'steps': ['form', 'paper'],
    });
    expect(find.text('Listing "Tamil OCR pool" created as a draft'), findsOneWidget);
    expect(backend.sent('GET', '/v1/talent/listings'), hasLength(2));
  });

  testWidgets('the detail shows the summary and the pipeline in four columns on a desktop', (tester) async {
    final backend = FakeBackend(listingRoutes());
    await openListing(tester, backend);
    expect(backend.sent('GET', '/v1/talent/listings/l1'), hasLength(1));
    expect(backend.sent('GET', '/v1/talent/listings/l1/applications'), hasLength(1));
    expect(find.text('OPERATE · LISTING'), findsOneWidget);
    expect(find.text('Transcription · ₹20–40 per unit · 3 of 10 slots filled'), findsOneWidget);
    expect(find.text('• Native Hindi'), findsOneWidget);
    expect(find.text('Preferred shift (optional) · day / night'), findsOneWidget);
    expect(find.text('Applied · 2'), findsOneWidget);
    expect(find.text('Screening · 1'), findsOneWidget);
    expect(find.text('Offered · 1'), findsOneWidget);
    expect(find.text('Accepted · 1'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const Key('pipeline-applied')), matching: find.byKey(const Key('application-a2'))),
      findsOneWidget,
      reason: 'assessment sits with applied',
    );
    expect(find.byType(Countdown), findsOneWidget, reason: 'the offer counts down');
    expect(find.text('1 ended (rejected, declined, withdrawn or expired)'), findsOneWidget);
    expect(find.byKey(const Key('offer-a3')), findsOneWidget);
    expect(find.byKey(const Key('reject-a3')), findsOneWidget);
    expect(find.byKey(const Key('offer-a1')), findsNothing, reason: 'only screening decides');
    expect(find.byKey(const Key('listing-close')), findsOneWidget);
    expect(find.byKey(const Key('listing-open')), findsNothing);
  });

  testWidgets('offer sends the days and the note; reject needs a note', (tester) async {
    final backend = FakeBackend(listingRoutes());
    await openListing(tester, backend);
    await tester.tap(find.byKey(const Key('offer-a3')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('offer-days'))).controller!.text, '7');
    await tester.enterText(find.byKey(const Key('offer-days')), '10');
    await tester.enterText(find.byKey(const Key('offer-note')), 'Welcome aboard');
    await tester.tap(find.byKey(const Key('offer-confirm')));
    await tester.pumpAndSettle();
    final offer = backend.sent('POST', '/v1/talent/applications/a3/decide').single;
    expect(offer.headers['Idempotency-Key'], isNotEmpty);
    expect(jsonDecode(offer.body), {'decision': 'offer', 'note': 'Welcome aboard', 'offer_days': 10});
    expect(find.text('Offer sent to eee-ffff'), findsOneWidget);
    expect(backend.sent('GET', '/v1/talent/listings/l1/applications'), hasLength(2), reason: 'reloaded');

    backend.routes['GET /v1/talent/listings/l1/applications'] = (_) => json(applications());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reject-a3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reject-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('A note is required to reject; the applicant reads it'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('reject-note')), 'Not enough experience');
    await tester.tap(find.byKey(const Key('reject-confirm')));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('POST', '/v1/talent/applications/a3/decide')[1].body), {
      'decision': 'reject',
      'note': 'Not enough experience',
    });
    expect(find.text('Application rejected'), findsOneWidget);
  });

  testWidgets('close confirms and patches the status; edit patches the listing', (tester) async {
    final backend = FakeBackend(listingRoutes());
    await openListing(tester, backend);
    await tester.tap(find.byKey(const Key('listing-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close listing'));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('PATCH', '/v1/talent/listings/l1').single.body), {'status': 'closed'});
    expect(find.text('Listing closed'), findsOneWidget);

    await tester.tap(find.byKey(const Key('listing-edit')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('listing-title'))).controller!.text, 'Hindi transcription pool');
    expect(tester.widget<TextField>(find.byKey(const Key('listing-closes'))).controller!.text, '2026-11-30');
    expect(tester.widget<TextField>(find.byKey(const Key('question-key-1'))).controller!.text, 'shift');
    await tester.enterText(find.byKey(const Key('listing-slots')), '12');
    await tester.tap(find.byKey(const Key('listing-save')));
    await tester.pumpAndSettle();
    final body = jsonDecode(backend.sent('PATCH', '/v1/talent/listings/l1')[1].body) as Map;
    expect(body['slots_total'], 12);
    expect(body['paper_id'], 'paper-1');
    expect(body['questions'], hasLength(2));
    expect(find.text('Listing saved'), findsOneWidget);
  });

  testWidgets('a close that failed with a 503 keeps its key; an Open after that is a different action', (tester) async {
    var fail = true;
    var closed = false;
    final backend = FakeBackend({
      ...listingRoutes(),
      'GET /v1/talent/listings/l1': (_) => json(listing(status: closed ? 'closed' : 'open')),
      'PATCH /v1/talent/listings/l1': (r) {
        if (fail) return envelope(503, 'unavailable', headers: {'retry-after': '1'});
        closed = (jsonDecode(r.body) as Map)['status'] == 'closed';
        return json(listing(status: closed ? 'closed' : 'open'));
      },
    });
    await openListing(tester, backend);
    await tester.tap(find.byKey(const Key('listing-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close listing'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('listing-error')), findsOneWidget);
    // ops closed it elsewhere meanwhile: a refresh shows it closed, and Open is a new action
    fail = false;
    closed = true;
    await tester.fling(find.text('Applications'), const Offset(0, 400), 1200);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('listing-open')), findsOneWidget);
    await tester.tap(find.byKey(const Key('listing-open')));
    await tester.pumpAndSettle();
    final patches = backend.sent('PATCH', '/v1/talent/listings/l1');
    expect(patches, hasLength(2));
    expect(jsonDecode(patches[1].body), {'status': 'open'});
    expect(patches[1].headers['Idempotency-Key'], isNot(patches[0].headers['Idempotency-Key']));
  });

  testWidgets('a closed listing offers Open and falls back to the list when the single read 404s', (tester) async {
    final backend = FakeBackend({
      ...listingRoutes(),
      'GET /v1/talent/listings/l1': (_) => envelope(404, 'not_found'),
      'GET /v1/talent/listings': (_) => json([listing(status: 'closed')]),
      'PATCH /v1/talent/listings/l1': (_) => json(listing(status: 'open')),
    });
    await openListing(tester, backend);
    expect(find.byKey(const Key('listing-open')), findsOneWidget);
    await tester.tap(find.byKey(const Key('listing-open')));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('PATCH', '/v1/talent/listings/l1').single.body), {'status': 'open'});
    expect(find.text('Listing is open'), findsOneWidget);
  });

  testWidgets('a failed load offers retry', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      ...listingRoutes(),
      'GET /v1/talent/listings': (_) => fail ? envelope(500, 'boom', message: 'Talent is away') : json([listing()]),
    });
    await pumpOps(tester, backend, navKey: 'nav-listings');
    expect(find.textContaining('Details: Talent is away'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Hindi transcription pool'), findsOneWidget);
  });

  testWidgets('on a phone the pipeline is one filtered column and nothing overflows', (tester) async {
    final backend = FakeBackend(listingRoutes());
    await openListing(tester, backend, size: phone);
    expect(tester.takeException(), isNull);
    await reveal(tester, find.text('Applications'));
    expect(find.byType(FilterChips<int>), findsOneWidget);
    await reveal(tester, find.byKey(const Key('filter-screening-1')));
    await tester.tap(find.byKey(const Key('filter-screening-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('application-a3')), findsOneWidget);
    expect(find.byKey(const Key('application-a1')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('offer-a3')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('offer-days')), findsOneWidget);
  });

  testWidgets('an applicant opens in a side sheet with answers against the questions, steps and the paper; Offer from there', (
    tester,
  ) async {
    final backend = FakeBackend({
      ...listingRoutes(),
      'GET /v1/talent/listings/l1': (_) => json({
        ...listing(),
        'hired_this_week': 2,
        'steps': ['form', 'paper'],
      }),
      'GET /v1/talent/listings/l1/applications': (_) => json([
        {
          ...application('a3', 'screening'),
          'worker_name': 'Asha Verma',
          'answers': {'exp': '3', 'shift': 'night', 'portfolio': 'https://example.test/asha'},
          'paper': {'status': 'passed', 'score': '0.92', 'at': '2026-11-03T10:00:00Z', 'attempts_left': null},
        },
      ]),
    });
    await openListing(tester, backend);
    expect(find.textContaining('2 hired this week'), findsOneWidget);
    expect(find.text('Asha Verma'), findsOneWidget, reason: 'the card names the applicant');
    expect(find.text('Paper passed · 92% · 3 Nov'), findsOneWidget);
    await tester.tap(find.byKey(const Key('application-a3')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('applicant-sheet')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('applicant-answer-exp')), matching: find.text('Years of experience?')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('applicant-answer-exp')), matching: find.text('3')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('applicant-answer-shift')), matching: find.text('night')), findsOneWidget);
    expect(find.byKey(const Key('applicant-answer-portfolio')), findsOneWidget, reason: 'answers to questions no longer asked still show');
    expect(find.text('Assessment'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sheet-offer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('applicant-sheet')), findsNothing);
    expect(find.text('Offer Asha Verma a slot'), findsOneWidget, reason: 'the same offer dialog as the card button, by name');
  });

  testWidgets('a new listing can ask for availability as a step', (tester) async {
    final backend = FakeBackend(listingRoutes());
    await pumpOps(tester, backend, navKey: 'nav-listings');
    await tester.tap(find.byKey(const Key('new-listing')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('listing-availability')));
    await tester.tap(find.byKey(const Key('listing-availability')));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byKey(const Key('listing-availability'))).value, isTrue);
  });

  testWidgets('renders in dark mode on a phone without overflow', (tester) async {
    final backend = FakeBackend(listingRoutes());
    await pumpApp(tester, backend, size: const Size(390, 2400), roles: const ['ops', 'finance'], dark: true, at: '/ops/listings/l1');
    expect(tester.takeException(), isNull);
    expect(find.text('Hindi transcription pool'), findsWidgets);
  });
}
