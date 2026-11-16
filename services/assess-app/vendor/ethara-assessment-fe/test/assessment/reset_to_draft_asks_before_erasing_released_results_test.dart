// Reset to Draft on a paper with RELEASED results asks first (A-040).
//
// The route refuses with 409 `released_results` - its message says how many
// candidates' released results would be erased - unless the body carries
// `confirm_released: true`. That refusal is a question for the admin: it is
// put to them in the server's own words, and the flag travels only on a yes.
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

const String _refusal =
    'Resetting to draft would permanently erase released results for 3 '
    'candidates. Confirm to continue.';

/// Every `reset_draft` body the server was sent, in order.
final List<Map<String, dynamic>> resets = <Map<String, dynamic>>[];

MockClient server() => MockClient((http.Request r) async {
  if (r.url.path.endsWith('/reset_draft')) {
    final Map<String, dynamic> body = r.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(r.body) as Map<String, dynamic>;
    resets.add(body);
    if (body['confirm_released'] != true) {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'released_results',
            'message': _refusal,
          },
        }),
        409,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
  }
  return http.Response(
    jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

Future<AppStore> open(WidgetTester t) async {
  t.view.physicalSize = const Size(1500, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  final Assessment a = AppStore().assessments.first.copyWith(
    state: AsmState.cancelled,
  );
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: server(), bearer: 's'),
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

Future<void> close(WidgetTester t, AppStore s) async {
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump(const Duration(seconds: 4));
  s.dispose();
}

Finder btn(String label) =>
    find.byWidgetPredicate((Widget w) => w is Btn && w.label == label);

void main() {
  setUp(resets.clear);

  testWidgets('a released_results refusal asks, and a yes retries with the '
      'flag', (WidgetTester t) async {
    final AppStore s = await open(t);

    await t.tap(btn('Reset to Draft'));
    await t.pumpAndSettle();

    expect(find.text('Erase released results?'), findsOneWidget);
    expect(find.textContaining('released results for 3'), findsOneWidget);
    expect(resets, hasLength(1));
    expect(resets.single.containsKey('confirm_released'), isFalse);

    await t.tap(btn('Erase and Reset'));
    await t.pumpAndSettle();

    expect(resets, hasLength(2));
    expect(resets.last['confirm_released'], isTrue);
    await close(t, s);
  });

  testWidgets('backing out sends nothing more', (WidgetTester t) async {
    final AppStore s = await open(t);

    await t.tap(btn('Reset to Draft'));
    await t.pumpAndSettle();
    await t.tap(btn('Keep Results'));
    await t.pumpAndSettle();

    expect(find.text('Erase released results?'), findsNothing);
    expect(resets, hasLength(1));
    await close(t, s);
  });
}
