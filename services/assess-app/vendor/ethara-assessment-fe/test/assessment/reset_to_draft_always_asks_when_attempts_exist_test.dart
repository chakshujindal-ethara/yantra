// Reset to Draft asked only when results had been RELEASED, so one click
// deleted every attempt and answer on a paper whose submissions were still
// held. It now asks whenever the paper has any attempts, says how many go, and
// says the candidate list is kept. With no attempts it still resets at once.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';

final List<String> resets = <String>[];

Future<AppStore> open(WidgetTester t, {required int assigned}) async {
  t.view.physicalSize = const Size(1500, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      bearer: 's',
      client: MockClient((http.Request r) async {
        if (r.url.path.endsWith('/reset_draft')) resets.add(r.url.path);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    ),
  );
  s.source = DataSource.live;
  s.attempts = <Attempt>[];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': '5',
      'name': 'Held Paper',
      'state': 'cancelled',
      'active': true,
      'assigned_count': assigned,
    }),
  ];

  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: AssessmentDetailScreen(
            store: s,
            portal: Portal.admin,
            asmId: '5',
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return s;
}

Future<void> close(WidgetTester t, AppStore s) async {
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump(const Duration(seconds: 4));
  s.dispose();
}

Finder btn(String label) =>
    find.byWidgetPredicate((Widget w) => w is Btn && w.label == label);

void main() {
  setUp(resets.clear);

  testWidgets('attempts on the paper: it asks, names the count, keeps the '
      'candidate list', (WidgetTester t) async {
    final AppStore s = await open(t, assigned: 4);

    await t.tap(btn('Reset to Draft'));
    await t.pumpAndSettle();

    expect(find.text('Reset to Draft?'), findsOneWidget);
    expect(
      find.textContaining(
        'Deletes 4 attempts and their answers.',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('The candidate list is kept.', findRichText: true),
      findsOneWidget,
    );
    expect(resets, isEmpty, reason: 'nothing is sent before the yes');

    await t.tap(btn('Keep It Cancelled'));
    await t.pumpAndSettle();
    expect(resets, isEmpty, reason: 'backing out sends nothing');

    await t.tap(btn('Reset to Draft'));
    await t.pumpAndSettle();
    await t.tap(btn('Delete and Reset'));
    await t.pumpAndSettle();
    expect(resets, hasLength(1));
    await close(t, s);
  });

  testWidgets('no attempts: it resets without asking', (WidgetTester t) async {
    final AppStore s = await open(t, assigned: 0);

    await t.tap(btn('Reset to Draft'));
    await t.pumpAndSettle();

    expect(find.text('Reset to Draft?'), findsNothing);
    expect(resets, hasLength(1));
    await close(t, s);
  });
}
