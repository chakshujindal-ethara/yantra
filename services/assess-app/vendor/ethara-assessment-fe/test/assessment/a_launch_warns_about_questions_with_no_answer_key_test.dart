// Launch warns - and only warns - about questions with no usable answer key.
//
// The module added a launch gate, `grading_keys`, that always PASSES but
// carries `warning: true` and names every question the grader will read with
// no usable answer key: their answers are graded against the task alone and
// flagged "no answer key". The launch sheet runs its own gates locally and
// never showed it, so an operator launched without ever being told.
//
// The sheet now asks the server with a DRY RUN (`confirm: false`, nothing is
// written) and adds each warning to the same checklist, amber, without ever
// disabling Launch. The rule stays in the module (`lacks_answer_key`): a copy
// here would drift, as the hand-copied `answer_keys` gate once did.
//
// The payload is the route's own (`_launch_gates` in controllers/api/admin.py,
// pinned by `test_launch_warns_but_never_blocks`): `{code, label, passed,
// reason}` from `launch_gate`, plus `warning`.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/gates.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/theme.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';

const String kReason =
    'Warning: 2 question(s) have no answer key; their answers will be graded '
    "against the task alone and flagged 'no answer key': Describe the hazard, "
    'Explain the fix';

/// The dry run's `gates`, abridged to one ordinary gate and the warning.
List<Map<String, dynamic>> _gates({bool warn = true}) => <Map<String, dynamic>>[
  <String, dynamic>{
    'code': 'answer_keys',
    'label': 'Every question has something markable on it',
    'passed': true,
    'reason': '',
  },
  <String, dynamic>{
    'code': 'grading_keys',
    'label': 'Graded questions have an answer key',
    'passed': true,
    'reason': warn ? kReason : '',
    'warning': warn,
  },
];

class _Server {
  final List<Map<String, dynamic>> launches = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> gates;
  final bool fail;

  _Server({List<Map<String, dynamic>>? gates, this.fail = false})
    : gates = gates ?? _gates();

  http.Client get client => MockClient((http.Request req) async {
    Object data = <String, dynamic>{};
    if (req.url.path.endsWith('/launch')) {
      launches.add(jsonDecode(req.body) as Map<String, dynamic>);
      if (fail) return http.Response('boom', 500);
      data = <String, dynamic>{
        'gates': gates,
        'can_launch': true,
        'launched': false,
        'dry_run': true,
      };
    }
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
}

/// A draft that clears every client-side gate, so the only thing that could
/// disable Launch in the widget test is the warning under test.
Assessment _draft() => Assessment.fromJson(<String, dynamic>{
  'id': '7',
  'name': 'Sprint 3A',
  'state': 'draft',
  'duration_minutes': 45,
  'question_limit': 0,
  'generator': <String, dynamic>{'id': '3', 'name': 'VAL Generator'},
  'roster': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'a0', 'name': 'Cand 0'},
  ],
  'pool': <Map<String, dynamic>>[
    for (int i = 1; i <= 2; i++)
      <String, dynamic>{
        'id': i,
        'name': 'Q$i',
        'question_type': 'subjective_rubric',
        'difficulty': 'medium',
        'sequence': i,
        'active': true,
        'state': 'approved',
        'servable': true,
        'in_use': true,
      },
  ],
});

AppStore _store(_Server server) {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: server.client),
  )..assessments = <Assessment>[_draft()];
  s.accessRole = AccessRole.admin;
  s.caps = Capability.values.toSet();
  s.generators = <Generator>[
    Generator.fromJson(<String, dynamic>{
      'id': '3',
      'name': 'VAL Generator',
      'state': 'approved',
    }),
  ];
  s.bank = <Question>[
    for (int i = 1; i <= 2; i++)
      Question.fromJson(<String, dynamic>{
        'id': '$i',
        'name': 'Q$i',
        'question_type': 'subjective_rubric',
        'difficulty': 'medium',
        'state': 'approved',
        'active': true,
        'generator': <String, dynamic>{'id': '3', 'name': 'VAL Generator'},
        'servable': true,
      }),
  ];
  return s;
}

void main() {
  group('the store reads the warnings from a dry run', () {
    test(
      'a warning gate comes back amber, passing, in the module\'s words',
      () async {
        final _Server server = _Server();
        final AppStore s = _store(server);

        final List<GateResult> w = await s.launchWarnings(s.asmById('7')!);

        expect(w, hasLength(1));
        expect(w.single.name, 'Graded questions have an answer key');
        expect(w.single.why, kReason);
        expect(w.single.why, contains('Describe the hazard'));
        expect(w.single.warning, isTrue);
        expect(w.single.ok, isTrue, reason: 'a warning never blocks');
        expect(
          Gates.allPass(<GateResult>[...s.launchGates(_draft()), ...w]),
          isTrue,
        );
      },
    );

    test('opening the checks never launches', () async {
      final _Server server = _Server();
      final AppStore s = _store(server);
      await s.launchWarnings(s.asmById('7')!);
      expect(server.launches.single['confirm'], isFalse);
    });

    test('a gate that passed without a warning adds nothing', () async {
      final AppStore s = _store(_Server(gates: _gates(warn: false)));
      expect(await s.launchWarnings(s.asmById('7')!), isEmpty);
    });

    test('a failed dry run adds nothing and throws nothing', () async {
      final AppStore s = _store(_Server(fail: true));
      expect(await s.launchWarnings(s.asmById('7')!), isEmpty);
    });

    test('offline there is no server to ask', () async {
      final AppStore s = AppStore()..assessments = <Assessment>[_draft()];
      expect(await s.launchWarnings(_draft()), isEmpty);
    });
  });

  testWidgets('the launch sheet lists the warning and Launch stays enabled', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1600, 2600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final _Server server = _Server();
    final AppStore s = _store(server);
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: AssessmentNavScope(
            nav: AssessmentNav(),
            child: AssessmentDetailScreen(
              store: s,
              portal: Portal.admin,
              asmId: '7',
              tab: 'config',
            ),
          ),
        ),
      ),
    );
    addTearDown(() async => t.pumpWidget(const SizedBox.shrink()));
    await t.pump();

    await t.tap(find.widgetWithText(Btn, 'Launch & Invite').first);
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));

    expect(find.text('Launch Checks'), findsOneWidget);
    expect(find.text('Graded questions have an answer key'), findsOneWidget);
    expect(find.text(kReason), findsOneWidget);
    // Amber, not red: every client gate passes here, so the one '!' marker on
    // screen is the warning's, and it must not read as a failed gate.
    final AppTokens tok = t.element(find.text('!')).tokens;
    expect(t.widget<Text>(find.text('!')).style!.color, tok.warnText);
    expect(t.widget<Text>(find.text(kReason)).style!.color, tok.warnText);
    // The sheet's own Launch - the LAST one, the header button sits behind it.
    final Btn launch = t.widget<Btn>(
      find.widgetWithText(Btn, 'Launch & Invite').last,
    );
    expect(launch.onPressed, isNotNull, reason: 'a warning never blocks');
    expect(
      server.launches.every((Map<String, dynamic> b) => b['confirm'] == false),
      isTrue,
    );
  });
}
