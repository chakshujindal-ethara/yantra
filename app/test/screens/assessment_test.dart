import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/app_router.dart';
import 'package:yantra_app/screens/assessment_screen.dart';

import '../support/fake_backend.dart';
import 'fixtures.dart';
import 'fixtures_talent.dart';

/// Opens the paper the way a link does, inside the shell, with the brief and the history served.
Future<TestHarness> openPaper(WidgetTester tester, FakeBackend backend, {Size size = const Size(900, 2400), bool dark = false}) async {
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
    'GET /v1/assess/papers/pp1/brief',
    () =>
        (_) => json(brief()),
  );
  backend.routes.putIfAbsent(
    'GET /v1/assess/sittings/me',
    () =>
        (_) => json([]),
  );
  backend.routes.putIfAbsent(
    'GET /v1/talent/listings',
    () =>
        (_) => json([listing(), listing(id: 'l2', certGate: 'captions')]),
  );
  final harness = await pumpApp(tester, backend, size: size, dark: dark);
  await goTo(tester, Paths.assessment('pp1'));
  return harness;
}

void main() {
  testWidgets('the brief shows time, pass mark, questions, attempts, question kinds, proctoring and Start', (tester) async {
    await openPaper(tester, FakeBackend({}));
    expect(find.text('Hindi transcription basics'), findsWidgets);
    expect(find.text('20 min'), findsOneWidget);
    expect(find.text('Pass mark 70%'), findsOneWidget);
    expect(find.text('3 questions'), findsOneWidget);
    expect(find.text('2 attempts left'), findsOneWidget);
    expect(find.text('Single choice'), findsOneWidget);
    expect(find.text('Multiple choice'), findsOneWidget);
    expect(find.text('Your camera stays on'), findsOneWidget);
    expect(find.text('The exam runs full screen'), findsOneWidget);
    expect(find.byKey(const Key('rule-ai_proctor')), findsNothing, reason: 'a rule that is off is not listed');
    expect(find.byKey(const Key('start-exam')), findsOneWidget);
    expect(find.textContaining('opens in Assessment in this tab'), findsOneWidget);
    await expectAccessible(tester);
  });

  testWidgets('Start asks for a one-time link and opens it in this tab', (tester) async {
    final backend = FakeBackend({'POST /v1/assess/papers/pp1/launch': (_) => json(launchTicket())});
    final harness = await openPaper(tester, backend);
    await tester.tap(find.byKey(const Key('start-exam')));
    await tester.pumpAndSettle();
    final sent = backend.sent('POST', '/v1/assess/papers/pp1/launch').single;
    expect(sent.headers['Idempotency-Key'], isNotEmpty);
    expect(harness.browser.navigations, [Uri.parse('http://localhost:8096/yantra/launch#ticket=t-1')]);
  });

  testWidgets('an exam already open offers Resume, which opens a fresh link', (tester) async {
    final backend = FakeBackend({
      'GET /v1/assess/papers/pp1/brief': (_) =>
          json(brief(current: workerSitting(status: 'in_progress', score: 0, released: false, attemptNo: 2))),
      'POST /v1/assess/papers/pp1/launch': (_) => json(launchTicket(url: 'http://localhost:8096/yantra/launch#ticket=t-2')),
    });
    final harness = await openPaper(tester, backend);
    expect(find.byKey(const Key('start-exam')), findsNothing);
    expect(find.textContaining('in progress'), findsWidgets);
    await tester.tap(find.byKey(const Key('resume-exam')));
    await tester.pumpAndSettle();
    expect(harness.browser.navigations.single.fragment, 'ticket=t-2');
  });

  testWidgets('after submitting, the brief waits for the result and updates itself until certified', (tester) async {
    var marked = false;
    final backend = FakeBackend({
      'GET /v1/assess/papers/pp1/brief': (_) => json(
        marked
            ? brief(certified: true, attemptsLeft: 1)
            : brief(
                current: workerSitting(status: 'awaiting_result', score: 0, released: false, heldReason: 'llm_scoring'),
              ),
      ),
      'GET /v1/assess/sittings/me': (_) => json([
        marked ? workerSitting(status: 'passed', score: 0.9) : workerSitting(status: 'awaiting_result', score: 0, released: false),
      ]),
    });
    await openPaper(tester, backend);
    expect(find.byKey(const Key('exam-awaiting')), findsOneWidget);
    expect(find.textContaining('your written answers are being marked'), findsOneWidget);
    expect(find.byKey(const Key('start-exam')), findsNothing);
    final before = backend.sent('GET', '/v1/assess/papers/pp1/brief').length;
    marked = true;
    await tester.pump(assessmentPollEvery);
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/assess/papers/pp1/brief').length, greaterThan(before));
    expect(find.byKey(const Key('exam-certified')), findsOneWidget);
    expect(find.textContaining('Certified with 90%'), findsOneWidget);
    expect(find.textContaining('1 pool open right now'), findsOneWidget);
    // once certified the page stops asking
    final settled = backend.sent('GET', '/v1/assess/papers/pp1/brief').length;
    await tester.pump(assessmentPollEvery * 3);
    expect(backend.sent('GET', '/v1/assess/papers/pp1/brief').length, settled);
  });

  testWidgets('a failed attempt says how far off it was, what is left, and that a retake is a fresh paper', (tester) async {
    final backend = FakeBackend({
      'GET /v1/assess/papers/pp1/brief': (_) => json(brief(attemptsLeft: 1)),
      'GET /v1/assess/sittings/me': (_) => json([workerSitting(status: 'failed', score: 0.55)]),
    });
    await openPaper(tester, backend);
    expect(find.byKey(const Key('exam-failed')), findsOneWidget);
    expect(find.textContaining('Not passed: 55% against a pass mark of 70%'), findsOneWidget);
    expect(find.textContaining('a retake is a fresh paper with new questions'), findsOneWidget);
    expect(find.text('Start the retake'), findsOneWidget);
    expect(find.text('Attempt 1'), findsOneWidget);
    expect(find.text('Not passed'), findsOneWidget);
  });

  testWidgets('with no attempts left the brief says so and offers nothing to start', (tester) async {
    final backend = FakeBackend({'GET /v1/assess/papers/pp1/brief': (_) => json(brief(attemptsLeft: 0, attemptsUsed: 2))});
    await openPaper(tester, backend);
    expect(find.byKey(const Key('start-exam')), findsNothing);
    expect(find.textContaining('used every attempt'), findsOneWidget);
  });

  testWidgets('a refused start explains itself; attempts_exhausted also reloads the brief', (tester) async {
    var calls = 0;
    final backend = FakeBackend({
      'GET /v1/assess/papers/pp1/brief': (_) {
        calls++;
        return json(brief());
      },
      'POST /v1/assess/papers/pp1/launch': (_) => envelope(409, 'attempts_exhausted', message: 'no attempts left'),
    });
    final harness = await openPaper(tester, backend);
    final loaded = calls;
    await tester.tap(find.byKey(const Key('start-exam')));
    await tester.pumpAndSettle();
    expect(find.textContaining('used every attempt on this paper'), findsOneWidget);
    expect(calls, greaterThan(loaded));
    expect(harness.browser.navigations, isEmpty);
  });

  testWidgets('the engine refusing names its reason; the author of a paper is told why they cannot sit it', (tester) async {
    var code = 'engine_refused';
    final backend = FakeBackend({
      'POST /v1/assess/papers/pp1/launch': (_) => code == 'engine_refused'
          ? envelope(409, 'engine_refused', message: 'x', context: {'engine_code': 'nothing_assigned'})
          : envelope(403, 'paper_author', message: 'x'),
    });
    await openPaper(tester, backend);
    await tester.tap(find.byKey(const Key('start-exam')));
    await tester.pumpAndSettle();
    expect(find.text('The assessment could not be started. Nothing assigned.'), findsOneWidget);
    code = 'paper_author';
    await tester.tap(find.byKey(const Key('start-exam')));
    await tester.pumpAndSettle();
    expect(find.textContaining('You wrote or published this paper'), findsOneWidget);
  });

  testWidgets('a brief that cannot be read offers Retry; a history that cannot be read leaves the brief standing', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      'GET /v1/assess/papers/pp1/brief': (_) => fail ? envelope(500, 'internal_error') : json(brief()),
      'GET /v1/assess/sittings/me': (_) => envelope(500, 'internal_error'),
    });
    await openPaper(tester, backend);
    expect(find.text('Retry'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('start-exam')), findsOneWidget);
    expect(find.text('Your attempts'), findsNothing);
  });

  testWidgets('the paper on a phone passes the checks and renders in dark mode', (tester) async {
    final backend = FakeBackend({
      'GET /v1/assess/sittings/me': (_) => json([workerSitting(status: 'failed', score: 0.4)]),
    });
    await openPaper(tester, backend, size: const Size(390, 1600));
    expect(tester.takeException(), isNull);
    await expectAccessible(tester);
    await tester.pumpWidget(const SizedBox());
    await openPaper(tester, backend, size: const Size(390, 1600), dark: true);
    expect(tester.takeException(), isNull);
    await expectRendersDark(tester);
  });

  test('sitting statuses read the same everywhere', () {
    expect(sittingStatus('awaiting_result').$1, 'Awaiting result');
    expect(sittingStatus('void').$1, 'Withdrawn');
    expect(sittingStatus('assigned').$1, 'Ready');
    expect(sittingStatus('odd_one').$1, 'Odd one');
  });
}
