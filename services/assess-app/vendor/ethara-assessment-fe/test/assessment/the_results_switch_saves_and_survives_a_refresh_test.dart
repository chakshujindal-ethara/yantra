// A release can hold back the answer key (15 Oct, R6).
//
// "Show correct answers and feedback" (`results_show_answers`, default on) is
// read when a candidate opens the review, so it stays editable after launch
// and after release. Pinned here:
//   - toggling it sends `results_show_answers: false` and nothing else;
//   - it stays off through the list refresh every save ends with, whose rows
//     do not carry the key;
//   - it is editable on a done paper;
//   - the release sheet says which review the candidates will get.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String kSwitch = 'Show correct answers and feedback';

class _Rig {
  final String state;
  bool show;
  final List<Map<String, dynamic>> writes = <Map<String, dynamic>>[];
  late final AppStore store;

  /// False is a backend from before 19.0.3.27.0: no `results_show_answers`
  /// in the detail, and an update carrying it is accepted and ignored.
  final bool knows;

  _Rig({this.state = 'in_progress', this.show = true, this.knows = true}) {
    store = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String p = req.url.path;
          if (p.endsWith('/update')) {
            final Map<String, dynamic> body =
                jsonDecode(req.body) as Map<String, dynamic>;
            writes.add(body);
            if (body['results_show_answers'] case final bool v) show = v;
          }
          // LIST ROWS DO NOT CARRY THE KEY, which is what the merge must
          // survive.
          if (p.endsWith('/assessments')) {
            return _json(<dynamic>[
              <String, dynamic>{'id': '7', 'name': 'L1', 'state': state},
            ]);
          }
          if (p.endsWith('/attempts')) {
            return _json(<dynamic>[
              <String, dynamic>{
                'id': '100',
                'assessment_id': '7',
                'state': 'submitted',
                'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita'},
              },
            ]);
          }
          if (p.contains('/assessments/7')) {
            return _json(<String, dynamic>{
              'id': '7',
              'name': 'L1',
              'state': state,
              'duration_minutes': 45,
              if (knows) 'results_show_answers': show,
            });
          }
          return _json(<dynamic>[]);
        }),
      ),
    );
    store.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
  }

  static http.Response _json(Object data) => http.Response(
    jsonEncode(<String, dynamic>{
      'ok': true,
      'data': data,
      if (data is List) 'meta': <String, dynamic>{'total': data.length},
    }),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );

  Widget get app => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: AssessmentNavScope(
        nav: AssessmentNav(),
        child: AssessmentDetailScreen(
          store: store,
          portal: Portal.admin,
          asmId: '7',
        ),
      ),
    ),
  );
}

Future<_Rig> _open(
  WidgetTester t, {
  String state = 'in_progress',
  bool show = true,
  bool knows = true,
}) async {
  t.view.physicalSize = const Size(1600, 4000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final _Rig rig = _Rig(state: state, show: show, knows: knows);
  await rig.store.refresh();
  await t.pumpWidget(rig.app);
  await t.pumpAndSettle();
  return rig;
}

SwitchRow _row(WidgetTester t) => t
    .widgetList<SwitchRow>(find.byType(SwitchRow))
    .singleWhere((SwitchRow r) => r.name == kSwitch);

void main() {
  testWidgets('switching it off sends results_show_answers alone', (
    WidgetTester t,
  ) async {
    final _Rig rig = await _open(t);
    expect(_row(t).value, isTrue, reason: 'on by default, as before');
    expect(_row(t).hint, contains('Read when they open the review'));

    await t.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text(kSwitch),
          matching: find.byType(SwitchRow),
        ),
        matching: find.byType(Switcher),
      ),
    );
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 3300));

    expect(rig.writes, hasLength(1));
    expect(rig.writes.single['results_show_answers'], isFalse);
    expect(rig.writes.single.length, 1, reason: 'only what changed is sent');

    // THE TRAILING LIST REFRESH carries no key: the switch must not snap back.
    await rig.store.refresh(background: true);
    await t.pumpAndSettle();
    expect(_row(t).value, isFalse);
  });

  // A BACKEND FROM BEFORE THE FIELD drops the key from an update and answers
  // 200: the switch would read Saved and candidates would still see the key.
  testWidgets(
    'an older server, whose detail has no key, is offered no switch',
    (WidgetTester t) async {
      final _Rig rig = await _open(t, knows: false);
      expect(find.text(kSwitch), findsNothing);
      expect(rig.store.serverKnowsShowAnswers, isFalse);
      expect(rig.writes, isEmpty);
    },
  );

  testWidgets('a current server keeps the switch across a list refresh', (
    WidgetTester t,
  ) async {
    final _Rig rig = await _open(t);
    await rig.store.refresh(background: true);
    await t.pumpAndSettle();
    expect(rig.store.serverKnowsShowAnswers, isTrue);
    expect(find.text(kSwitch), findsOneWidget);
  });

  testWidgets('it stays editable once the paper is done', (
    WidgetTester t,
  ) async {
    await _open(t, state: 'done');
    expect(_row(t).onChanged, isNotNull);
  });

  testWidgets('the release sheet says which review candidates get', (
    WidgetTester t,
  ) async {
    await _open(t, show: false);

    await t.tap(find.widgetWithText(Btn, 'Release results (1)'));
    await t.pumpAndSettle();

    expect(find.text('Release Results'), findsOneWidget);
    expect(
      find.text(
        'Candidates will see their own answers and marks only - the correct '
        'answers and feedback stay hidden.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('and says so when the key is shown', (WidgetTester t) async {
    await _open(t);

    await t.tap(find.widgetWithText(Btn, 'Release results (1)'));
    await t.pumpAndSettle();

    expect(
      find.text('Candidates will see the correct answers and feedback.'),
      findsOneWidget,
    );
  });
}
