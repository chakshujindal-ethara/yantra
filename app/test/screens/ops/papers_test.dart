import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/widgets/cards.dart';

import '../../support/fake_backend.dart';
import 'fixtures_ops.dart';

Finder tile(String label) => find.ancestor(of: find.text(label), matching: find.byType(KpiTile));

Map<String, Handler> paperRoutes() => {
  ...overviewRoutes(),
  'GET /v1/assess/papers': (_) => json([paper(), paper(id: 'paper-2', title: 'Labelling basics', status: 'draft', awaiting: 0)]),
  'GET /v1/assess/papers/paper-1': (_) => json(paper()),
  'GET /v1/assess/papers/paper-2': (_) => json(paper(id: 'paper-2', title: 'Labelling basics', status: 'draft', awaiting: 0)),
  'GET /v1/assess/papers/paper-1/sittings': (_) => json([
    paperSitting(),
    paperSitting(id: 'ps2', workerId: 'w-0000-0002', workerName: 'Ravi Kumar'),
    paperSitting(
      id: 'ps3',
      workerName: 'Meera Iyer',
      status: 'passed',
      score: 0.9,
      released: true,
      heldReason: '',
      flags: ['score_outlier'],
    ),
  ]),
  'GET /v1/assess/papers/paper-2/sittings': (_) => json([]),
  'GET /v1/assess/engine/assessments': (_) => json([engineAssessment(), engineAssessment(id: 22, name: 'OCR plates v2')]),
  'POST /v1/assess/papers': (r) =>
      json({...paper(id: 'paper-9', status: 'draft'), 'title': (jsonDecode(r.body) as Map)['title']}, status: 201),
  'POST /v1/assess/papers/paper-2/publish': (_) => json(paper(id: 'paper-2', title: 'Labelling basics')),
  'POST /v1/assess/papers/paper-1/release': (r) => json({'released': (jsonDecode(r.body) as Map).containsKey('sitting_ids') ? 1 : 2}),
  'POST /v1/assess/papers/paper-1/rotate': (_) => json(paper()),
  'POST /v1/assess/sync': (_) => json({'synced': 3}),
  'POST /v1/assess/admin-launch': (_) => json({'launch_url': 'http://localhost:8096/yantra/launch#ticket=staff-1'}),
};

Future<void> openPaper(WidgetTester tester, FakeBackend backend, String id, String title, {Size size = const Size(1400, 2400)}) async {
  await pumpOps(tester, backend, size: size, navKey: 'nav-papers');
  await tester.tap(find.descendant(of: find.byKey(Key('paper-$id')), matching: find.text(title)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists papers with gate, the v2 assessment, status, attempts, passes, awaiting release and pass rate', (tester) async {
    final backend = FakeBackend(paperRoutes());
    await pumpOps(tester, backend, navKey: 'nav-papers');
    expect(find.text('OPERATE · PAPERS'), findsOneWidget);
    expect(find.text('Certification exams, sat in Assessment v2'), findsOneWidget);
    expect(find.text('Transcription basics'), findsOneWidget);
    expect(find.text('Labelling basics'), findsOneWidget);
    expect(find.text('Hindi transcription v3 · #12'), findsNWidgets(2));
    expect(chip('Published'), findsOneWidget);
    expect(chip('Draft'), findsOneWidget);
    expect(find.text('30 / 40'), findsNWidgets(2));
    expect(tester.widget<Text>(find.byKey(const Key('awaiting-paper-1'))).data, '2');
    expect(find.text('75%'), findsNWidgets(2));
    await expectAccessible(tester);
  });

  testWidgets('a new paper links a draft assessment from Assessment v2', (tester) async {
    final backend = FakeBackend(paperRoutes());
    await pumpOps(tester, backend, navKey: 'nav-papers');
    await tester.tap(find.byKey(const Key('new-paper')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/assess/engine/assessments').single.url.queryParameters['state'], 'draft');
    await tester.tap(find.byKey(const Key('paper-save')));
    await tester.pumpAndSettle();
    expect(find.text('Gate and title are required'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('paper-gate')), 'captions');
    await tester.enterText(find.byKey(const Key('paper-title')), 'Captions QA');
    await tester.enterText(find.byKey(const Key('paper-attempts')), '3');
    await tester.tap(find.byKey(const Key('paper-save')));
    await tester.pumpAndSettle();
    expect(find.text('Pick the assessment this paper uses'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('paper-assessment')));
    await tester.tap(find.byKey(const Key('paper-assessment')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OCR plates v2 · #22 · 8 questions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('paper-save')));
    await tester.pumpAndSettle();
    final post = backend.sent('POST', '/v1/assess/papers').single;
    expect(post.headers['Idempotency-Key'], isNotEmpty);
    expect(jsonDecode(post.body), {
      'gate': 'captions',
      'title': 'Captions QA',
      'description': '',
      'max_attempts': 3,
      'release_policy': 'manual',
      'assigned_ttl_days': 14,
      'source': {'kind': 'assessment', 'assessment_id': 22},
    });
    expect(find.text('Paper "Captions QA" created as a draft'), findsOneWidget);
  });

  testWidgets('a quick paper validates its single and multiple choice questions and posts them', (tester) async {
    final backend = FakeBackend(paperRoutes());
    await pumpOps(tester, backend, navKey: 'nav-papers');
    await tester.tap(find.byKey(const Key('new-paper')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quick paper'));
    await tester.pumpAndSettle();
    expect(find.text('Text (exact match)'), findsNothing);
    await tester.enterText(find.byKey(const Key('paper-gate')), 'ocr');
    await tester.enterText(find.byKey(const Key('paper-title')), 'OCR basics');
    await tester.enterText(find.byKey(const Key('paper-duration')), '20');
    await tester.enterText(find.byKey(const Key('paper-pass-mark')), '80');
    await tester.enterText(find.byKey(const Key('pq-id-0')), 'q1');
    await tester.enterText(find.byKey(const Key('pq-prompt-0')), 'Which is a plate?');
    await tester.enterText(find.byKey(const Key('pq-options-0')), 'KA01\nhello');
    await tester.enterText(find.byKey(const Key('pq-answer-0')), 'KA09');
    await tester.tap(find.byKey(const Key('paper-save')));
    await tester.pumpAndSettle();
    expect(find.text('Question 1: answer "KA09" is not one of its options'), findsOneWidget);
    expect(backend.sent('POST', '/v1/assess/papers'), isEmpty);
    await tester.enterText(find.byKey(const Key('pq-answer-0')), 'KA01');
    await tester.ensureVisible(find.byKey(const Key('pq-add')));
    await tester.tap(find.byKey(const Key('pq-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pq-id-1')), 'q2');
    await tester.enterText(find.byKey(const Key('pq-prompt-1')), 'Pick the digits');
    await tester.ensureVisible(find.byKey(const Key('pq-kind-1')));
    await tester.tap(find.byKey(const Key('pq-kind-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Multiple choice').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pq-options-1')), '1\nA\n2');
    await tester.enterText(find.byKey(const Key('pq-answer-1')), '1, 2');
    await tester.ensureVisible(find.byKey(const Key('paper-release')));
    await tester.tap(find.byKey(const Key('paper-release')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Released at once when fully objective').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('paper-save')));
    await tester.pumpAndSettle();
    final body = jsonDecode(backend.sent('POST', '/v1/assess/papers').single.body) as Map;
    expect(body['release_policy'], 'auto_objective');
    expect(body['source'], {
      'kind': 'quick',
      'duration_minutes': 20,
      'pass_mark': '0.8000',
      'questions': [
        {
          'id': 'q1',
          'prompt': 'Which is a plate?',
          'kind': 'single',
          'options': ['KA01', 'hello'],
          'answer': 'KA01',
        },
        {
          'id': 'q2',
          'prompt': 'Pick the digits',
          'kind': 'multi',
          'options': ['1', 'A', '2'],
          'answer': ['1', '2'],
        },
      ],
    });
  });

  testWidgets('with no drafts in Assessment v2 the dialog says where to build one; a failed list offers Retry', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      ...paperRoutes(),
      'GET /v1/assess/engine/assessments': (_) => fail ? envelope(503, 'engine_unavailable') : json([]),
    });
    await pumpOps(tester, backend, navKey: 'nav-papers');
    await tester.tap(find.byKey(const Key('new-paper')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('assessments-retry')), findsOneWidget);
    fail = false;
    await tester.tap(find.byKey(const Key('assessments-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('assessments-empty')), findsOneWidget);
  });

  testWidgets('the paper shows the exam, its cohorts and attempts; publish lists the checks v2 failed', (tester) async {
    var refuse = true;
    final backend = FakeBackend({
      ...paperRoutes(),
      'POST /v1/assess/papers/paper-2/publish': (_) => refuse
          ? envelope(
              422,
              'launch_blocked',
              message: 'the assessment cannot launch yet',
              context: {
                'gates': [
                  {'code': 'answer_keys', 'label': 'Add at least one question with an answer key', 'reason': ''},
                  {'code': 'duration', 'label': 'Set a duration', 'reason': '2 minutes or more'},
                ],
              },
            )
          : json(paper(id: 'paper-2', title: 'Labelling basics')),
    });
    await openPaper(tester, backend, 'paper-2', 'Labelling basics');
    expect(find.text('OPERATE · PAPER'), findsOneWidget);
    expect(find.text('gate transcription · Hindi transcription v3 · #12 · 2 attempts'), findsOneWidget);
    expect(find.text('Audio transcription'), findsOneWidget);
    expect(find.textContaining('Proctoring: Your camera stays on · An AI proctor'), findsOneWidget);
    expect(find.byKey(const Key('cohort-c2')), findsOneWidget);
    expect(find.text('No attempts yet. Workers start the exam from their application.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('paper-publish')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Publish').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Assessment v2 cannot open this exam yet'), findsOneWidget);
    expect(find.textContaining('• Add at least one question with an answer key'), findsOneWidget);
    expect(find.textContaining('• Set a duration (2 minutes or more)'), findsOneWidget);
    refuse = false;
    await tester.tap(find.byKey(const Key('paper-publish')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Publish').last);
    await tester.pumpAndSettle();
    expect(find.text('Paper published'), findsOneWidget);
    expect(backend.sent('POST', '/v1/assess/papers/paper-2/publish'), hasLength(2));
  });

  testWidgets('results waiting for release are released one by one or all at once', (tester) async {
    final backend = FakeBackend(paperRoutes());
    await openPaper(tester, backend, 'paper-1', 'Transcription basics');
    expect(find.descendant(of: tile('Awaiting result'), matching: find.text('2')), findsOneWidget);
    expect(find.text('Asha Rao'), findsOneWidget);
    expect(find.text('Ops review the results before they are released'), findsNWidgets(2));
    expect(find.text('Score outlier'), findsOneWidget);
    expect(find.byKey(const Key('select-ps3')), findsNothing, reason: 'a released result has nothing to release');
    await tester.ensureVisible(find.byKey(const Key('select-ps2')));
    await tester.tap(find.byKey(const Key('select-ps2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('release-selected')));
    await tester.pumpAndSettle();
    expect(find.text('Release 1 selected result?'), findsOneWidget);
    await tester.tap(find.text('Release').last);
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('POST', '/v1/assess/papers/paper-1/release').single.body), {
      'sitting_ids': ['ps2'],
    });
    expect(find.text('1 result released'), findsOneWidget);
    await tester.tap(find.byKey(const Key('release-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Release').last);
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('POST', '/v1/assess/papers/paper-1/release').last.body), <String, Object?>{});
    expect(find.text('2 results released'), findsOneWidget);
  });

  testWidgets('Rotate and Sync now run with a key; Open in Assessment admin opens a signed-in tab', (tester) async {
    final backend = FakeBackend(paperRoutes());
    final harness = await pumpOps(tester, backend, navKey: 'nav-papers');
    await tester.tap(find.descendant(of: find.byKey(const Key('paper-paper-1')), matching: find.text('Transcription basics')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('paper-rotate')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rotate').last);
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/assess/papers/paper-1/rotate').single.headers['Idempotency-Key'], isNotEmpty);
    expect(find.text('Paper rotated'), findsOneWidget);
    await tester.tap(find.byKey(const Key('paper-sync')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/assess/sync'), hasLength(1));
    await tester.tap(find.byKey(const Key('paper-open-admin')));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('POST', '/v1/assess/admin-launch').single.body), {'next': '/assessments/12'});
    expect(harness.downloads.opened, [Uri.parse('http://localhost:8096/yantra/launch#ticket=staff-1')]);
  });

  testWidgets('an empty list and a failed load each say what happened', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      ...paperRoutes(),
      'GET /v1/assess/papers': (_) => fail ? envelope(500, 'boom', message: 'Assess is away') : json([]),
    });
    await pumpOps(tester, backend, navKey: 'nav-papers');
    expect(find.textContaining('Details: Assess is away'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No papers yet. "New paper" links an assessment or writes a quick one.'), findsOneWidget);
  });

  testWidgets('renders on a phone without overflow and passes the checks', (tester) async {
    final backend = FakeBackend(paperRoutes());
    await pumpOps(tester, backend, size: phone, navKey: 'nav-papers');
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('new-paper')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('form-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const Key('paper-paper-1')), matching: find.text('Transcription basics')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectAccessible(tester);
  });

  testWidgets('renders in dark mode on a phone without overflow', (tester) async {
    final backend = FakeBackend(paperRoutes());
    await pumpApp(tester, backend, size: const Size(390, 2400), roles: const ['ops', 'finance'], dark: true, at: '/ops/papers/paper-1');
    expect(tester.takeException(), isNull);
    await expectRendersDark(tester);
  });
}
