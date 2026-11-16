// The Emails panel asks the route once per page, never once per candidate.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/emails_panel.dart';

final List<String> calls = <String>[];

/// Three invitations, served two per page like the route's `limit`/`offset`.
http.Client server() => MockClient((http.Request req) async {
  calls.add(req.url.path);
  final Map<String, dynamic> body = req.body.isEmpty
      ? <String, dynamic>{}
      : jsonDecode(req.body) as Map<String, dynamic>;
  final int offset = (body['offset'] as int?) ?? 0;
  final List<Map<String, dynamic>> all = <Map<String, dynamic>>[
    for (int i = 1; i <= 3; i++)
      <String, dynamic>{
        'id': i,
        'subject': 'Invitation $i',
        'state': 'sent',
        'email_to': 'cand$i@example.com',
        'date': '2026-09-21T04:33:00Z',
      },
  ];
  final List<Map<String, dynamic>> page = all.skip(offset).take(2).toList();
  return http.Response(
    jsonEncode(<String, dynamic>{
      'ok': true,
      'data': page,
      'meta': <String, dynamic>{
        'total': all.length,
        'has_more': offset + page.length < all.length,
      },
    }),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  setUp(calls.clear);

  testWidgets('an assessment pages its mail from one route', (
    WidgetTester t,
  ) async {
    final AppStore s = AppStore(
      api: ApiClient(client: server(), baseUrl: 'http://x'),
    );
    await t.pumpWidget(
      host(EmailsPanel(store: s, kind: 'assessment', recordId: '7')),
    );
    await t.pumpAndSettle();

    expect(find.text('Invitation 1'), findsOneWidget);
    expect(find.text('Invitation 3'), findsNothing);
    expect(find.text('Load more (1 left)'), findsOneWidget);

    await t.tap(find.text('Load more (1 left)'));
    await t.pumpAndSettle();

    expect(find.text('Invitation 3'), findsOneWidget);
    expect(find.textContaining('Load more'), findsNothing);
    expect(calls, everyElement(endsWith('/emails/assessment/7')));
    expect(calls, hasLength(2));
  });
}
