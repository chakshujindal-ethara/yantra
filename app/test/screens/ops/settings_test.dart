import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:yantra_app/api/settings_models.dart';
import 'package:yantra_app/core/widgets/cards.dart';

import '../../support/fake_backend.dart';

const client1 = '00000000-0000-4000-8000-0000000000c1';
const worker2 = '00000000-0000-4000-8000-000000000002';

Map<String, Object?> policy({int revision = 1}) => {
  'slug': 'contractor-agreement',
  'version': '2026-11',
  'revision': revision,
  'title': 'Contractor agreement',
  'summary': 'What you agree to.',
  'sections': [
    {
      'title': 'Pay',
      'paragraphs': ['Paid per accepted unit.'],
      'bullets': ['Weekly windows', 'TDS withheld'],
    },
  ],
  'updated_at': '2026-11-01T10:00:00Z',
};

Map<String, Handler> routes({Map<String, Handler> extra = const {}}) => {
  'GET /v1/client-orgs': (_) => json([
    {
      'id': 'org-1',
      'name': 'Acme Labs',
      'created_at': '2026-11-01T10:00:00Z',
      'members': [client1],
    },
  ]),
  'GET /v1/talent/policies': (_) => json([policy()]),
  'GET /v1/quality/reasons': (_) => json([
    {
      'code': 'client_glossary_change',
      'label': 'Client changed the glossary',
      'detail': '',
      'billable': true,
      'applies_to': ['needs_edits'],
      'sort': 1,
      'active': true,
    },
    {
      'code': 'old_code',
      'label': 'Old',
      'detail': '',
      'billable': false,
      'applies_to': ['reject'],
      'sort': 9,
      'active': false,
    },
  ]),
  'GET /v1/tracker/caps': (_) => json([
    {'scope': 'worker', 'scope_id': worker2, 'weekly_cap_hours': '30.00', 'set_by': 'ops-1', 'updated_at': '2026-11-02T10:00:00Z'},
    {
      'scope': 'project',
      'scope_id': 'p0000000-0000-4000-8000-000000000001',
      'weekly_cap_hours': '20.00',
      'set_by': 'ops-1',
      'updated_at': null,
    },
  ]),
  'GET /v1/talent/erasures': (_) => json([
    {
      'worker_id': worker2,
      'status': 'requested',
      'requested_at': '2026-11-03T10:00:00Z',
      'due_at': '2026-12-03T10:00:00Z',
      'approved_at': null,
      'approved_by': null,
      'done_at': null,
    },
    {
      'worker_id': 'w-done',
      'status': 'done',
      'requested_at': '2026-10-01T10:00:00Z',
      'due_at': '2026-10-31T10:00:00Z',
      'approved_at': null,
      'approved_by': null,
      'done_at': '2026-10-31T10:00:00Z',
    },
  ]),
  'GET /v1/projects': (_) => json([
    {'id': 'p0000000-0000-4000-8000-000000000001', 'name': 'Hindi transcription', 'currency': 'INR', 'status': 'active'},
  ]),
  'GET /v1/people': (_) => json({
    client1: {'name': 'Client One', 'kind': 'client'},
    worker2: {'name': 'Worker Two', 'kind': 'worker'},
  }),
  ...extra,
};

Future<TestHarness> open(WidgetTester tester, FakeBackend backend, {Size? size, bool dark = false}) =>
    pumpApp(tester, backend, size: size ?? const Size(1280, 2400), roles: ['ops', 'finance'], at: '/ops/settings', dark: dark);

Future<void> tab(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(Key('tab-$name')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('client organisations list members by name; ops create one and add and remove members', (tester) async {
    final backend = FakeBackend(
      routes(
        extra: {
          'POST /v1/client-orgs': (r) => json({
            'id': 'org-2',
            'name': jsonDecode(r.body)['name'],
            'created_at': '2026-11-04T10:00:00Z',
            'members': <String>[],
          }, status: 201),
          'PUT /v1/client-orgs/org-1/members/00000000-0000-4000-8000-0000000000c2': (_) => json({'org_id': 'org-1', 'user_id': 'c2'}),
          'DELETE /v1/client-orgs/org-1/members/$client1': (_) => json({'org_id': 'org-1', 'user_id': client1}),
        },
      ),
    );
    await open(tester, backend);
    expect(find.text('ADMIN · SETTINGS'), findsOneWidget);
    expect(find.text('Acme Labs'), findsOneWidget);
    expect(find.text('Client One'), findsOneWidget);
    await expectAccessible(tester);

    await tester.tap(find.byKey(const Key('org-new')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('org-name')), 'Beta Corp');
    await tester.tap(find.byKey(const Key('org-create')));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('POST', '/v1/client-orgs').single.body), {'name': 'Beta Corp'});
    expect(find.text('Beta Corp created'), findsOneWidget);

    await tester.tap(find.byKey(const Key('org-add-org-1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Keycloak admin console'), findsOneWidget, reason: 'the helper says where to find it');
    await tester.enterText(find.byKey(const Key('member-id')), 'client2');
    await tester.tap(find.byKey(const Key('member-add')));
    await tester.pumpAndSettle();
    expect(find.textContaining('A user id looks like'), findsOneWidget);
    expect(find.text('User id (from Keycloak → Users)'), findsOneWidget);
    expect(backend.sent('PUT', '/v1/client-orgs/org-1/members/client2'), isEmpty);
    await tester.enterText(find.byKey(const Key('member-id')), '00000000-0000-4000-8000-0000000000c2');
    await tester.tap(find.byKey(const Key('member-add')));
    await tester.pumpAndSettle();
    expect(backend.sent('PUT', '/v1/client-orgs/org-1/members/00000000-0000-4000-8000-0000000000c2'), hasLength(1));
    expect(find.text('Member added'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byKey(const Key('member-org-1-$client1')), matching: find.byIcon(Icons.close)));
    await tester.pumpAndSettle();
    expect(find.text('Remove this member?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(backend.sent('DELETE', '/v1/client-orgs/org-1/members/$client1'), hasLength(1));
    expect(find.text('Member removed'), findsOneWidget);
  });

  testWidgets('no organisation says what to do; a failed remove is a toast; cancelling changes nothing', (tester) async {
    var orgs = true;
    final backend = FakeBackend(
      routes(
        extra: {
          'GET /v1/client-orgs': (_) => json(
            orgs
                ? [
                    {
                      'id': 'org-1',
                      'name': 'Acme Labs',
                      'created_at': null,
                      'members': [client1],
                    },
                  ]
                : <Object>[],
          ),
          'DELETE /v1/client-orgs/org-1/members/$client1': (_) => envelope(404, 'not_found', message: 'not a member'),
        },
      ),
    );
    await open(tester, backend);
    await tester.tap(find.descendant(of: find.byKey(const Key('member-org-1-$client1')), matching: find.byIcon(Icons.close)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.sent('DELETE', '/v1/client-orgs/org-1/members/$client1'), isEmpty);
    await tester.tap(find.descendant(of: find.byKey(const Key('member-org-1-$client1')), matching: find.byIcon(Icons.close)));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Details: not a member'), findsOneWidget);
    orgs = false;
    await tab(tester, 'policies');
    await tab(tester, 'orgs');
    expect(find.textContaining('No client organisation yet.'), findsOneWidget);
  });

  testWidgets('policies: view the text, publish a new version with a label; an empty body is refused', (tester) async {
    final backend = FakeBackend(
      routes(
        extra: {
          'PUT /v1/talent/policies/contractor-agreement': (r) => json({...policy(revision: 2), 'version': jsonDecode(r.body)['label']}),
        },
      ),
    );
    await open(tester, backend);
    await tab(tester, 'policies');
    expect(find.text('2026-11 (rev 1)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('policy-view-contractor-agreement')));
    await tester.pumpAndSettle();
    expect(find.text('•  TDS withheld'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('policy-publish-contractor-agreement')));
    await tester.pumpAndSettle();
    final body = tester.widget<TextField>(find.byKey(const Key('policy-body'))).controller!.text;
    expect(body, contains('## Pay'));
    expect(body, contains('- TDS withheld'));
    await tester.enterText(find.byKey(const Key('policy-body')), 'no heading here');
    await tester.tap(find.byKey(const Key('policy-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Write at least one section'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('policy-title')), '');
    await tester.tap(find.byKey(const Key('policy-save')));
    await tester.pumpAndSettle();
    expect(find.text('A title and a summary are needed'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('policy-title')), 'Contractor agreement');
    await tester.enterText(find.byKey(const Key('policy-body')), '## Pay\nPaid per accepted unit,\nweekly.\n\n- Weekly windows');
    await tester.enterText(find.byKey(const Key('policy-label')), '2026-12');
    await tester.tap(find.byKey(const Key('policy-save')));
    await tester.pumpAndSettle();
    final sent = jsonDecode(backend.sent('PUT', '/v1/talent/policies/contractor-agreement').single.body) as Map<String, Object?>;
    expect(sent['label'], '2026-12');
    expect(sent['sections'], [
      {
        'title': 'Pay',
        'paragraphs': ['Paid per accepted unit, weekly.'],
        'bullets': ['Weekly windows'],
      },
    ]);
    expect(find.text('New version of Contractor agreement published'), findsOneWidget);
  });

  testWidgets('a failed publish keeps the form open with the reason', (tester) async {
    final backend = FakeBackend(
      routes(extra: {'PUT /v1/talent/policies/contractor-agreement': (_) => envelope(422, 'invalid', message: 'too long')}),
    );
    await open(tester, backend);
    await tab(tester, 'policies');
    await tester.tap(find.byKey(const Key('policy-publish-contractor-agreement')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('policy-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Details: too long'), findsOneWidget);
    expect(find.byKey(const Key('policy-save')), findsOneWidget);
  });

  testWidgets('reason codes: retired ones show; add a code, validated; edit one', (tester) async {
    final backend = FakeBackend(
      routes(
        extra: {
          'PUT /v1/quality/reasons/brief_unclear': (r) => json({'code': 'brief_unclear', ...jsonDecode(r.body) as Map<String, Object?>}),
          'PUT /v1/quality/reasons/client_glossary_change': (r) =>
              json({'code': 'client_glossary_change', ...jsonDecode(r.body) as Map<String, Object?>}),
        },
      ),
    );
    await open(tester, backend);
    await tab(tester, 'reasons');
    expect(backend.sent('GET', '/v1/quality/reasons').last.url.queryParameters['all'], 'true');
    expect(find.descendant(of: find.byKey(const Key('reason-old_code')), matching: find.text('Retired')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('reason-client_glossary_change')), matching: find.text('Billable')), findsOneWidget);
    await expectAccessible(tester);

    await tester.tap(find.byKey(const Key('reason-new')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('reason-code')), 'Brief Unclear');
    await tester.tap(find.byKey(const Key('reason-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('lower case letters'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('reason-code')), 'brief_unclear');
    await tester.tap(find.byKey(const Key('reason-save')));
    await tester.pumpAndSettle();
    expect(find.text('A label and at least one verdict are needed'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('reason-label')), 'The brief was unclear');
    await tester.tap(find.byKey(const Key('reason-applies-reject')));
    await tester.tap(find.byKey(const Key('reason-billable')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reason-save')));
    await tester.pumpAndSettle();
    final added = jsonDecode(backend.sent('PUT', '/v1/quality/reasons/brief_unclear').single.body) as Map<String, Object?>;
    expect(added['applies_to'], ['needs_edits']);
    expect(added['billable'], true);
    expect(find.text('Reason code added'), findsOneWidget);

    await tester.tap(find.byKey(const Key('reason-edit-client_glossary_change')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('reason-code'))).enabled, isFalse);
    await tester.tap(find.byKey(const Key('reason-active')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reason-save')));
    await tester.pumpAndSettle();
    final edited = jsonDecode(backend.sent('PUT', '/v1/quality/reasons/client_glossary_change').single.body) as Map<String, Object?>;
    expect(edited['active'], false);
    expect(find.text('Reason code saved'), findsOneWidget);
  });

  testWidgets('a reason the server refuses keeps the form open', (tester) async {
    final backend = FakeBackend(
      routes(extra: {'PUT /v1/quality/reasons/old_code': (_) => envelope(422, 'invalid', message: 'label too long')}),
    );
    await open(tester, backend);
    await tab(tester, 'reasons');
    await tester.tap(find.byKey(const Key('reason-edit-old_code')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reason-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Details: label too long'), findsOneWidget);
  });

  testWidgets('hour caps: worker caps by name, project caps by id; set a cap, validated', (tester) async {
    final backend = FakeBackend(
      routes(
        extra: {
          'PUT /v1/tracker/caps/project/a0000000-0000-4000-8000-000000000009': (r) => json({
            'scope': 'project',
            'scope_id': 'p9',
            'weekly_cap_hours': jsonDecode(r.body)['weekly_cap_hours'],
            'set_by': 'ops-1',
            'updated_at': '2026-11-04T10:00:00Z',
          }),
        },
      ),
    );
    await open(tester, backend);
    await tab(tester, 'caps');
    expect(find.descendant(of: find.byKey(const Key('cap-worker-$worker2')), matching: find.text('Worker Two')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('cap-worker-$worker2')), matching: find.text('30.00')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('cap-project-p0000000-0000-4000-8000-000000000001')),
        matching: find.text('Hindi transcription'),
      ),
      findsOneWidget,
      reason: 'a project cap names the project, not an id tail',
    );
    await tester.tap(find.byKey(const Key('cap-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cap-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining("worker's account id looks like"), findsOneWidget);
    await tester.tap(find.byKey(const Key('cap-scope')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everyone on a project').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cap-id')), 'a0000000-0000-4000-8000-000000000009');
    await tester.enterText(find.byKey(const Key('cap-hours')), '200');
    await tester.tap(find.byKey(const Key('cap-save')));
    await tester.pumpAndSettle();
    expect(find.text('Hours a week is a number from 0 to 168'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('cap-hours')), '25');
    await tester.tap(find.byKey(const Key('cap-save')));
    await tester.pumpAndSettle();
    expect(jsonDecode(backend.sent('PUT', '/v1/tracker/caps/project/a0000000-0000-4000-8000-000000000009').single.body), {
      'weekly_cap_hours': '25',
    });
    expect(find.text('Cap saved'), findsOneWidget);
  });

  testWidgets('switching tabs shows a loader, never a blank card', (tester) async {
    final caps = Completer<http.Response>();
    final backend = FakeBackend(routes());
    backend.slow['GET /v1/tracker/caps'] = (_) => caps.future;
    await open(tester, backend);
    await tester.tap(find.byKey(const Key('tab-caps')));
    await tester.pump();
    expect(find.byType(Skeleton), findsOneWidget);
    caps.complete(json([]));
    await tester.pumpAndSettle();
    expect(find.byType(Skeleton), findsNothing);
  });

  testWidgets('a cap the server refuses keeps the form open', (tester) async {
    final backend = FakeBackend(
      routes(extra: {'PUT /v1/tracker/caps/worker/$worker2': (_) => envelope(422, 'invalid', message: 'bad cap')}),
    );
    await open(tester, backend);
    await tab(tester, 'caps');
    await tester.tap(find.byKey(const Key('cap-new')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cap-id')), worker2);
    await tester.tap(find.byKey(const Key('cap-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Details: bad cap'), findsOneWidget);
  });

  testWidgets('erasure requests: approve one after confirming', (tester) async {
    final backend = FakeBackend(
      routes(
        extra: {
          'POST /v1/talent/erasures/$worker2/approve': (_) => json({
            'worker_id': worker2,
            'status': 'approved',
            'requested_at': '2026-11-03T10:00:00Z',
            'due_at': '2026-11-04T10:00:00Z',
            'approved_at': '2026-11-04T10:00:00Z',
            'approved_by': 'ops-1',
            'done_at': null,
          }),
        },
      ),
    );
    await open(tester, backend);
    await tab(tester, 'erasures');
    expect(find.textContaining('1 waiting.'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('erasure-$worker2')), matching: find.text('Worker Two')), findsOneWidget);
    expect(find.byKey(const Key('erasure-approve-w-done')), findsNothing);
    await expectAccessible(tester);
    await tester.tap(find.byKey(const Key('erasure-approve-$worker2')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Approve erasure'));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/talent/erasures/$worker2/approve'), hasLength(1));
    expect(find.text('Erasure approved'), findsOneWidget);
  });

  testWidgets('the palette offers the page actions', (tester) async {
    await open(tester, FakeBackend(routes()));
    await tester.tap(find.byKey(const Key('command-palette')));
    await tester.pumpAndSettle();
    expect(find.text('New client organisation'), findsOneWidget);
    await tester.tap(find.text('Set an hour cap'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cap-save')), findsOneWidget);
    await tester.tap(find.byKey(const Key('form-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('command-palette')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New reason code'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reason-save')), findsOneWidget);
  });

  testWidgets('renders at phone width and in dark mode without overflow', (tester) async {
    await open(tester, FakeBackend(routes()), size: const Size(390, 2400));
    expect(tester.takeException(), isNull);
    for (final t in ['policies', 'reasons', 'caps', 'erasures']) {
      await tab(tester, t);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    await open(tester, FakeBackend(routes()), dark: true);
    expect(tester.takeException(), isNull);
  });

  test('section text round-trips', () {
    final parts = sectionsFromText('ignored\n## A\nOne\ntwo\n\n- b1\n## \n## C\n- c');
    expect(parts.map((p) => p.title), ['A', 'C']);
    expect(parts.first.paragraphs, ['One two']);
    expect(parts.first.bullets, ['b1']);
    expect(sectionsFromText(sectionsToText(parts)).map((p) => p.toJson()), parts.map((p) => p.toJson()));
  });
}
