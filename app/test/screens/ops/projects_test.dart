import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/widgets/cards.dart';
import 'package:yantra_app/core/widgets/tables.dart';

import '../../support/fake_backend.dart';
import 'fixtures_ops.dart';

Finder tile(String label) => find.ancestor(of: find.text(label), matching: find.byType(KpiTile));

Map<String, dynamic> bodyOf(FakeBackend backend, String method, String path, {int index = 0}) =>
    jsonDecode(backend.sent(method, path)[index].body) as Map<String, dynamic>;

Map<String, Handler> projectRoutes() => {
  ...overviewRoutes(),
  'GET /v1/projects': (_) => json([projectSummary(), projectSummary(id: 'p2', name: 'Street signs', status: 'draft')]),
  'GET /v1/projects/p1': (_) => json(projectDetail()),
  'GET /v1/client-orgs': (_) => json(clientOrgs),
  'POST /v1/projects': (r) => json({...projectDetail(), 'id': 'p9', 'name': (jsonDecode(r.body) as Map)['name']}, status: 201),
  'PATCH /v1/projects/p9': (_) => json({...projectDetail(), 'id': 'p9', 'name': 'Tamil OCR'}),
  'PATCH /v1/projects/p1': (_) => json(projectDetail()),
  'POST /v1/projects/p1/batches': (_) => json(batchSummary(id: 'b3', title: 'Night shift', status: 'draft'), status: 201),
};

Future<void> openProject(WidgetTester tester, FakeBackend backend, {Size size = wide}) async {
  await pumpOps(tester, backend, size: size, navKey: 'nav-projects');
  await tester.tap(find.byKey(const Key('project-p1')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists projects, searches by name and filters by status', (tester) async {
    final backend = FakeBackend(projectRoutes());
    await pumpOps(tester, backend, navKey: 'nav-projects');
    expect(find.text('OPERATE · PROJECTS'), findsOneWidget);
    expect(find.text('Hindi transcription'), findsOneWidget);
    expect(find.text('Street signs'), findsOneWidget);
    expect(chip('Active'), findsOneWidget);
    expect(chip('Draft'), findsOneWidget);
    expect(find.text('transcription'), findsNWidgets(2), reason: 'the gate column');

    await tester.enterText(find.byKey(const Key('projects-search')), 'street');
    await tester.pumpAndSettle();
    expect(find.text('Hindi transcription'), findsNothing);
    expect(find.text('Street signs'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('projects-search')), '');
    await tester.tap(find.byKey(const Key('filter-active')));
    await tester.pumpAndSettle();
    expect(find.text('Hindi transcription'), findsOneWidget);
    expect(find.text('Street signs'), findsNothing);
    await expectAccessible(tester);
  });

  testWidgets('a new project posts what creation accepts and patches the rest', (tester) async {
    final backend = FakeBackend(projectRoutes());
    await pumpOps(tester, backend, navKey: 'nav-projects');
    await tester.tap(find.byKey(const Key('new-project')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/client-orgs'), hasLength(1));

    await tester.enterText(find.byKey(const Key('project-name')), 'Tamil OCR');
    await tester.enterText(find.byKey(const Key('project-gate')), 'ocr');
    await tester.enterText(find.byKey(const Key('project-rubric')), 'v3');
    await tester.enterText(find.byKey(const Key('project-floor')), '25');
    await tester.enterText(find.byKey(const Key('project-brief')), 'Read the plates.');
    await tester.enterText(find.byKey(const Key('project-llm')), 'Allowed for spelling.');
    await tester.ensureVisible(find.byKey(const Key('project-sensitive')));
    await tester.tap(find.byKey(const Key('project-sensitive')));
    await tester.ensureVisible(find.byKey(const Key('project-org')));
    await tester.tap(find.byKey(const Key('project-org')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Acme Labs').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('project-payload-schema')), '{"type": "object", oops');
    await tester.tap(find.byKey(const Key('project-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Payload schema is not valid JSON'), findsOneWidget);
    expect(backend.sent('POST', '/v1/projects'), isEmpty, reason: 'bad JSON never leaves the device');

    await tester.enterText(find.byKey(const Key('project-payload-schema')), '["not", "an object"]');
    await tester.tap(find.byKey(const Key('project-save')));
    await tester.pumpAndSettle();
    expect(find.text('Payload schema must be a JSON object'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('project-payload-schema')),
      '{"type": "object", "properties": {"plate": {"type": "string"}}}',
    );
    await tester.enterText(find.byKey(const Key('project-answer-schema')), '{"type": "object"}');
    await tester.tap(find.byKey(const Key('project-save')));
    await tester.pumpAndSettle();

    final post = backend.sent('POST', '/v1/projects').single;
    expect(post.headers['Idempotency-Key'], isNotEmpty);
    expect(jsonDecode(post.body), {
      'name': 'Tamil OCR',
      'currency': 'INR',
      'payload_schema': {
        'type': 'object',
        'properties': {
          'plate': {'type': 'string'},
        },
      },
      'answer_schema': {'type': 'object'},
      'rubric_version': 'v3',
      'margin_floor': '0.2500',
      'cert_gate': 'ocr',
      'retention_days': 180,
    });
    final patch = backend.sent('PATCH', '/v1/projects/p9').single;
    expect(patch.headers['Idempotency-Key'], isNot(post.headers['Idempotency-Key']), reason: 'two actions, two keys');
    expect(jsonDecode(patch.body), {
      'brief': 'Read the plates.',
      'llm_policy': 'Allowed for spelling.',
      'sensitive': true,
      'client_org_id': 'org-1',
    });
    expect(find.text('Project "Tamil OCR" created'), findsOneWidget);
    expect(backend.sent('GET', '/v1/projects'), hasLength(3), reason: 'overview, the page, the reload');
  });

  testWidgets('a PATCH that fails after the POST keeps the created project; Retry only PATCHes', (tester) async {
    var patches = 0;
    final backend = FakeBackend({
      ...projectRoutes(),
      'PATCH /v1/projects/p9': (_) => ++patches == 1
          ? envelope(422, 'invalid', message: 'brief: too long')
          : json({...projectDetail(), 'id': 'p9', 'name': 'Tamil OCR'}),
    });
    await pumpOps(tester, backend, navKey: 'nav-projects');
    await tester.tap(find.byKey(const Key('new-project')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('project-name')), 'Tamil OCR');
    await tester.enterText(find.byKey(const Key('project-brief')), 'Read the plates.');
    await tester.tap(find.byKey(const Key('project-save')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/projects'), hasLength(1));
    expect(backend.sent('PATCH', '/v1/projects/p9'), hasLength(1));
    expect(find.textContaining('Project created; the extra fields were not saved'), findsOneWidget);
    expect(find.textContaining('Details: brief: too long'), findsOneWidget);
    expect(find.byKey(const Key('project-save')), findsOneWidget, reason: 'the dialog stays open for the retry');

    await tester.tap(find.byKey(const Key('project-patch-retry')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/projects'), hasLength(1), reason: 'the retry never creates a second project');
    final patchKeys = backend.sent('PATCH', '/v1/projects/p9').map((r) => r.headers['Idempotency-Key']).toSet();
    expect(backend.sent('PATCH', '/v1/projects/p9'), hasLength(2));
    expect(patchKeys, hasLength(2), reason: 'a 422 ends the action; the retry is a new one');
    expect(find.byKey(const Key('project-save')), findsNothing);
    expect(find.text('Project "Tamil OCR" created'), findsOneWidget);
  });

  testWidgets('creation with nothing extra skips the PATCH', (tester) async {
    final backend = FakeBackend(projectRoutes());
    await pumpOps(tester, backend, navKey: 'nav-projects');
    await tester.tap(find.byKey(const Key('new-project')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('project-name')), 'Plain');
    await tester.tap(find.byKey(const Key('project-save')));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/projects'), hasLength(1));
    expect(backend.sent('PATCH', '/v1/projects/p9'), isEmpty);
    expect(bodyOf(backend, 'POST', '/v1/projects')['margin_floor'], isNull);
  });

  testWidgets('the project screen shows the stages, the batches with pay against bill, reasons, feedback and the brief', (tester) async {
    final backend = FakeBackend(projectRoutes());
    await openProject(tester, backend);
    expect(backend.sent('GET', '/v1/projects/p1'), hasLength(1));
    expect(find.text('OPERATE · PROJECT'), findsOneWidget);
    expect(find.text('INR · gate transcription · rubric v2 · floor 30% · kept 180 days'), findsOneWidget);
    expect(find.descendant(of: tile('Available'), matching: find.text('40')), findsOneWidget);
    expect(find.descendant(of: tile('In review'), matching: find.text('5')), findsOneWidget);
    expect(find.descendant(of: tile('Accepted'), matching: find.text('50')), findsOneWidget);

    expect(find.text('Label street signs'), findsOneWidget);
    expect(find.text('₹28.00 pay'), findsOneWidget);
    expect(find.text('₹60.00 bill'), findsNWidgets(2));
    expect(find.text('47% margin'), findsOneWidget);
    expect(find.text('10% margin'), findsOneWidget, reason: 'the draft batch pays 50 of 60');
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget, reason: 'the under-floor mark');
    expect(find.text('sha256:abcde'), findsNothing);
    expect(find.text('5'), findsWidgets, reason: 'live claims');

    await reveal(tester, find.text('Verdict reasons'));
    expect(find.text('Guideline miss'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(chip('Billable'), findsOneWidget);
    expect(chip('Not billable'), findsOneWidget);
    expect(find.text('Please keep the diacritics.'), findsOneWidget);
    expect(find.text('Diacritics required'), findsOneWidget);
    expect(find.text('Transcribe the audio exactly as spoken.'), findsOneWidget);
    expect(find.text('No LLM assistance.'), findsOneWidget);
    expect(chip('Not sensitive'), findsOneWidget);
  });

  testWidgets('edit patches the fields a PATCH accepts and never the payload schema', (tester) async {
    final backend = FakeBackend(projectRoutes());
    await openProject(tester, backend);
    await tester.tap(find.byKey(const Key('project-edit')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('project-name'))).controller!.text, 'Hindi transcription');
    expect(tester.widget<TextField>(find.byKey(const Key('project-payload-schema'))).enabled, isFalse);
    expect(tester.widget<TextField>(find.byKey(const Key('project-floor'))).controller!.text, '30');
    await tester.enterText(find.byKey(const Key('project-name')), 'Hindi transcription v2');
    await tester.ensureVisible(find.byKey(const Key('project-status')));
    await tester.tap(find.byKey(const Key('project-status')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Closed').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-save')));
    await tester.pumpAndSettle();
    final body = bodyOf(backend, 'PATCH', '/v1/projects/p1');
    expect(body['name'], 'Hindi transcription v2');
    expect(body['status'], 'closed');
    expect(body['margin_floor'], '0.3000');
    expect(body['brief'], 'Transcribe the audio exactly as spoken.');
    expect(body['client_org_id'], 'org-1');
    expect(body['answer_schema'], {
      'type': 'object',
      'properties': {
        'label': {'type': 'string'},
      },
    });
    expect(body.containsKey('payload_schema'), isFalse);
    expect(find.text('Project saved'), findsOneWidget);
    expect(backend.sent('GET', '/v1/projects/p1'), hasLength(2), reason: 'reloaded after the save');
  });

  testWidgets('a new batch previews the margin live, warns under the floor and posts the batch', (tester) async {
    final backend = FakeBackend(projectRoutes());
    await openProject(tester, backend);
    await tester.tap(find.byKey(const Key('new-batch')));
    await tester.pumpAndSettle();
    String margin() => tester.widget<Text>(find.byKey(const Key('batch-margin'))).data!;
    expect(margin(), 'Margin — · floor 30%');
    await tester.enterText(find.byKey(const Key('batch-unit-pay')), '28');
    await tester.enterText(find.byKey(const Key('batch-unit-price')), '60');
    await tester.enterText(find.byKey(const Key('batch-review-pay')), '4');
    await tester.pump();
    expect(margin(), 'Margin 47% · floor 30%');
    expect(find.byKey(const Key('batch-floor-warning')), findsNothing);
    await tester.enterText(find.byKey(const Key('batch-unit-pay')), '50');
    await tester.pump();
    expect(margin(), 'Margin 10% · floor 30%');
    expect(find.byKey(const Key('batch-floor-warning')), findsOneWidget);

    await tester.tap(find.byKey(const Key('batch-save')));
    await tester.pumpAndSettle();
    expect(find.text('Title is required'), findsOneWidget);
    expect(backend.sent('POST', '/v1/projects/p1/batches'), isEmpty);

    await tester.enterText(find.byKey(const Key('batch-title')), 'Night shift');
    await tester.tap(find.byKey(const Key('batch-save')));
    await tester.pumpAndSettle();
    final post = backend.sent('POST', '/v1/projects/p1/batches').single;
    expect(post.headers['Idempotency-Key'], isNotEmpty);
    expect(jsonDecode(post.body), {
      'title': 'Night shift',
      'mode': 'open',
      'unit_pay': '50.00',
      'unit_price': '60.00',
      'review_pay': '4.00',
      'claim_ttl_minutes': 240,
    });
    expect(find.text('Batch "Night shift" created as a draft'), findsOneWidget);
    expect(backend.sent('GET', '/v1/projects/p1'), hasLength(2));
  });

  testWidgets('a failed load offers retry', (tester) async {
    var fail = false;
    final backend = FakeBackend({
      ...projectRoutes(),
      'GET /v1/projects': (_) => fail ? envelope(503, 'unavailable', headers: {'retry-after': '5'}) : json([projectSummary()]),
    });
    await pumpOps(tester, backend);
    fail = true;
    await tester.tap(find.byKey(const Key('nav-projects')));
    await tester.pumpAndSettle();
    expect(find.text('Service is away. Retry in 5s.'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Hindi transcription'), findsOneWidget);
  });

  testWidgets('an empty list says what to do next', (tester) async {
    final backend = FakeBackend({...projectRoutes(), 'GET /v1/projects': (_) => json([])});
    await pumpOps(tester, backend, navKey: 'nav-projects');
    expect(find.text('No projects yet. "New project" starts the first one.'), findsOneWidget);
  });

  testWidgets('renders on a phone: the table scrolls sideways, the forms stack', (tester) async {
    final backend = FakeBackend(projectRoutes());
    await pumpOps(tester, backend, size: phone, navKey: 'nav-projects');
    expect(tester.takeException(), isNull);
    expect(find.descendant(of: find.byType(PortalTable), matching: find.byType(SingleChildScrollView)), findsOneWidget);
    await tester.tap(find.byKey(const Key('new-project')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('project-name')), findsOneWidget);
    await tester.tap(find.byKey(const Key('form-cancel')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const Key('project-p1')));
    await tester.tap(find.descendant(of: find.byKey(const Key('project-p1')), matching: find.text('Hindi transcription')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Hindi transcription'), findsOneWidget);
    await tester.tap(find.byKey(const Key('new-batch')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the project page shows the 30-day trend, the client org by name, and answers the client', (tester) async {
    var answered = false;
    final backend = FakeBackend({
      ...projectRoutes(),
      'GET /v1/projects/p1': (_) => json({
        ...projectDetail(),
        'feedback': [
          {
            'id': 'f1',
            'author_id': 'client-user-1',
            'author_kind': 'client',
            'author_name': 'Rhea (Acme)',
            'body': 'Please keep the diacritics.',
            'created_at': '2026-10-28T09:00:00Z',
          },
          if (answered)
            {
              'id': 'f2',
              'author_id': 'ops-1',
              'author_kind': 'staff',
              'author_name': 'Ops One',
              'body': 'Done from batch 3 on.',
              'created_at': '2026-10-29T09:00:00Z',
            },
        ],
      }),
      'GET /v1/analytics/projects/p1/trend': (_) => json({
        'project_id': 'p1',
        'currency': 'INR',
        'days': [
          for (var i = 0; i < 30; i++)
            {
              'day': '2026-10-${(i + 1).toString().padLeft(2, '0')}',
              'published': i == 0 ? 100 : 0,
              'claimed': 2,
              'submitted': 2,
              // even days judge 2 at 100% first pass, odd days 4 at 25%: weighted 50%, a plain mean says 63%
              'accepted': i.isEven ? 2 : 1,
              'rejected': i.isEven ? 0 : 3,
              'first_pass_rate': i.isEven ? '1.0' : '0.25',
              'pay': '56.00',
              'price': '120.00',
              'review_cost': '12.00',
              'margin': '10.00',
            },
        ],
      }),
      'POST /v1/projects/p1/feedback': (r) {
        answered = true;
        return json({
          'id': 'f2',
          'author_id': 'ops-1',
          'author_kind': 'staff',
          'body': (jsonDecode(r.body) as Map)['body'],
          'created_at': '2026-10-29T09:00:00Z',
        }, status: 201);
      },
    });
    await openProject(tester, backend);
    expect(backend.sent('GET', '/v1/analytics/projects/p1/trend').single.url.queryParameters['days'], '30');
    expect(find.byKey(const Key('project-trend')), findsOneWidget);
    expect(find.text('45 accepted · 45 rejected · first pass 50% · margin ₹300.00'), findsOneWidget, reason: 'weighted by volume');
    await reveal(tester, find.text('Acme Labs'));
    expect(find.text('Acme Labs'), findsOneWidget, reason: 'the org by name, not its id');

    await reveal(tester, find.byKey(const Key('feedback-body')));
    expect(find.text('Rhea (Acme)'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('feedback-body')), 'Done from batch 3 on.');
    await tester.tap(find.byKey(const Key('feedback-send')));
    await tester.pumpAndSettle();
    final sent = backend.sent('POST', '/v1/projects/p1/feedback').single;
    expect(jsonDecode(sent.body), {'body': 'Done from batch 3 on.'});
    expect(sent.headers['Idempotency-Key'], isNotEmpty);
    expect(find.byKey(const Key('feedback-staff-badge')), findsOneWidget, reason: 'the answer is back in the thread, marked Yantra');
    await expectAccessible(tester);
  });

  testWidgets('an empty trend says so; the schema box checks as you type and offers a sample; retention is bounded', (tester) async {
    final backend = FakeBackend({
      ...projectRoutes(),
      'GET /v1/analytics/projects/p1/trend': (_) => json({'project_id': 'p1', 'currency': 'INR', 'days': []}),
    });
    await openProject(tester, backend);
    expect(find.text('No activity in the last 30 days.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('nav-projects')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-project')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('project-answer-schema')), '{"type": "array"');
    await tester.pump(const Duration(milliseconds: 510));
    expect(find.textContaining('Answer schema is not valid JSON'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('project-answer-schema')), '');
    await tester.pump(const Duration(milliseconds: 510));
    await tester.ensureVisible(find.byKey(const Key('project-answer-sample')));
    await tester.tap(find.byKey(const Key('project-answer-sample')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('project-answer-schema'))).controller!.text, contains('"transcript"'));
    await tester.ensureVisible(find.byKey(const Key('project-payload-sample')));
    await tester.tap(find.byKey(const Key('project-payload-sample')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('project-payload-schema'))).controller!.text, contains('"audio_ref"'));

    await tester.enterText(find.byKey(const Key('project-name')), 'Kept forever');
    await tester.enterText(find.byKey(const Key('project-retention')), '9999');
    await tester.tap(find.byKey(const Key('project-save')));
    await tester.pumpAndSettle();
    expect(find.text('Retention is a number of days from 1 to 3650'), findsOneWidget);
    expect(backend.sent('POST', '/v1/projects'), isEmpty);
  });

  testWidgets('the project page renders dark and on a phone without overflow', (tester) async {
    final backend = FakeBackend(projectRoutes());
    await pumpApp(tester, backend, size: phone, roles: const ['ops', 'finance'], dark: true, at: '/ops/projects/p1');
    expect(tester.takeException(), isNull);
    expect(find.text('Hindi transcription'), findsWidgets);
  });

  testWidgets('a trend with claims but no verdict says so instead of drawing an empty chart', (tester) async {
    final backend = FakeBackend({
      ...projectRoutes(),
      'GET /v1/analytics/projects/p1/trend': (_) => json({
        'project_id': 'p1',
        'currency': 'INR',
        'days': [
          {
            'day': '2026-11-04',
            'published': 8,
            'claimed': 2,
            'submitted': 1,
            'accepted': 0,
            'rejected': 0,
            'first_pass_rate': null,
            'pay': '0',
            'price': '0',
            'review_cost': '0',
            'margin': '0',
          },
        ],
      }),
    });
    await openProject(tester, backend);
    expect(find.text('Nothing judged yet: 2 claims and 1 submissions in the window.'), findsOneWidget);
  });
}
