// Cancel "appeared to do nothing" (L-246).
//
//  1. Cancel was offered on a DONE paper. `action_cancel` refuses
//     `state in ("done","cancelled")`; the client gated on `cancelled` alone,
//     and the refusal read "...or already cancelled".
//  2. A refused cancel still painted its optimistic Cancelled state, because
//     `cancel` passed `optimistic:` with no `rollback:`.
@TestOn('vm')
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

/// Refuses every call. The trailing background refresh fails too, so the
/// rollback is the only thing that can put the record back.
MockClient refusingServer() => MockClient(
  (http.Request r) async => http.Response(
    jsonEncode(<String, dynamic>{
      'ok': false,
      'error': <String, dynamic>{
        'code': 'rejected',
        'message': 'This assessment cannot be cancelled.',
      },
    }),
    422,
    headers: <String, String>{'content-type': 'application/json'},
  ),
);

Future<AppStore> open(
  WidgetTester t,
  AsmState state, {
  http.Client? client,
}) async {
  t.view.physicalSize = const Size(1500, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  // A store built with an api loads nothing until asked, so the fixture comes
  // from a seed store and is placed on whichever store the test drives.
  final Assessment a = AppStore().assessments.first.copyWith(state: state);
  final AppStore s = client == null
      ? AppStore()
      : AppStore(
          api: ApiClient(baseUrl: 'http://stub', client: client, bearer: 's'),
        );
  s.source = DataSource.live;
  s.assessments = <Assessment>[a];

  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: AssessmentDetailScreen(
            store: s,
            portal: Portal.admin,
            asmId: a.id,
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return s;
}

/// Tear the screen down before the store, so its poll timer is cancelled.
Future<void> close(WidgetTester t, AppStore s) async {
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump(const Duration(seconds: 4));
  s.dispose();
}

Finder btn(String label) =>
    find.byWidgetPredicate((Widget w) => w is Btn && w.label == label);

void main() {
  testWidgets('a Done paper has no Cancel button', (WidgetTester t) async {
    final AppStore s = await open(t, AsmState.done);
    expect(btn('Cancel'), findsNothing);
    await close(t, s);
  });

  testWidgets('a refused cancel puts the previous state back', (
    WidgetTester t,
  ) async {
    final AppStore s = await open(
      t,
      AsmState.inProgress,
      client: refusingServer(),
    );
    final String id = s.assessments.first.id;

    await t.tap(btn('Cancel'));
    await t.pump();
    await t.pump(const Duration(seconds: 1));

    expect(s.asmById(id)?.state, AsmState.inProgress);
    await t.pumpAndSettle();
    await close(t, s);
  });
}
