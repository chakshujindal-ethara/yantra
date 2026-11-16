// A REFUSED LAUNCH HAS TO SAY WHAT REFUSED IT.
//
// Reported from production: "I am getting this error 2 launch gates failed ...
// I do not even know which one failed?" Both sides of the wire had the same
// defect, and the client's half is the one that hid the server's.
//
// SERVER: `/assessments/<id>/launch` answered `"%d launch gate(s) failed"`
// while returning a `gates` array carrying every label and reason it had just
// computed. Whatever the client toasted, the diagnosis was already in the
// payload and thrown away.
//
// CLIENT: `AppStore.launch` runs the same gates locally first as a courtesy
// round-trip saver. When any failed it toasted "Launch is blocked - some checks
// have not passed" and RETURNED - so the server, which could have explained
// itself, was never called at all. Fixing only the server would have left this
// path saying nothing.
//
// `Gates.launch` evaluates every condition and returns all of them precisely so
// no caller has to recompute or guess. These tests pin that the refusal spends
// what was already paid for.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/gates.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// Serves one draft assessment. `roster` and `pool` decide which gates fail.
class _Rig {
  final int roster;

  /// Lifecycle state, so a test can fail the "is a draft" gate too.
  final String state;

  /// Whether the payload names a generator. Off, the generator gate fails and
  /// the pool gate falls with it, which is how several gates come to fail at
  /// once.
  final bool withGenerator;
  bool launchCalled = false;
  late final AppStore store;

  _Rig({this.roster = 1, this.state = 'draft', this.withGenerator = true}) {
    store = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        client: MockClient((http.Request req) async {
          if (req.url.path.endsWith('/launch')) {
            launchCalled = true;
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': false,
                'error': <String, dynamic>{
                  'code': 'launch_blocked',
                  'message':
                      'Launch blocked: Generator has servable questions - '
                      'No usable questions with their required media.',
                },
                'failed_gates': <String>['questions_available'],
              }),
              422,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode(<String, dynamic>{'ok': true, 'data': _detail}),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
  }

  Map<String, dynamic> get _detail => <String, dynamic>{
    'id': '7',
    'name': 'Sprint 3A',
    'state': state,
    'duration_minutes': 45,
    'question_limit': 0,
    if (withGenerator)
      'generator': <String, dynamic>{'id': 3, 'name': 'VAL Generator'},
    'roster': <Map<String, dynamic>>[
      for (int i = 0; i < roster; i++)
        <String, dynamic>{'id': 'a$i', 'name': 'Cand $i'},
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
  };

  Future<Assessment> load() async {
    await store.loadAssessment('7');
    return store.asmById('7')!;
  }

  String get lastToast =>
      store.toaster.items.isEmpty ? '' : store.toaster.items.last.message;
}

void main() {
  test('a client-side refusal names each failing gate, not a count', () async {
    final _Rig rig = _Rig(roster: 0);
    final Assessment asm = await rig.load();

    await rig.store.launch(asm);

    expect(
      rig.lastToast,
      isNot(contains('some checks have not passed')),
      reason: 'counting the gates is the defect under test',
    );
    expect(
      rig.lastToast.toLowerCase(),
      contains('candidate'),
      reason: 'the gate that refused must be named in the toast',
    );
  });

  test('the client-side refusal carries each gate\'s own reason', () async {
    final _Rig rig = _Rig(roster: 0);
    final Assessment asm = await rig.load();

    await rig.store.launch(asm);

    // `Gates.launch` supplies both halves. The name says WHICH check; the why
    // says what it found. A name alone sends the operator to the right screen
    // and no further.
    expect(rig.lastToast, contains('Nobody is assigned'));
  });

  test('a local refusal still never reaches the server', () async {
    // The pre-check exists to save a round trip. Naming the gates must not
    // turn it into one.
    final _Rig rig = _Rig(roster: 0);
    final Assessment asm = await rig.load();

    await rig.store.launch(asm);

    expect(rig.launchCalled, isFalse);
  });

  test('a server refusal is shown in the module\'s own words', () async {
    // Local gates all pass, so the call goes out and the server's message -
    // which now names the gates - is what the operator reads. The generator
    // and bank caches are filled directly: `launchGates` reads them, they are
    // loaded by endpoints this rig does not serve, and what is under test here
    // is the refusal, not the hydration.
    final _Rig rig = _Rig();
    final Assessment asm = await rig.load();
    rig.store.generators = <Generator>[
      Generator.fromJson(<String, dynamic>{
        'id': '3',
        'name': 'VAL Generator',
        'state': 'approved',
      }),
    ];
    rig.store.bank = <Question>[
      for (int i = 1; i <= 2; i++)
        Question.fromJson(<String, dynamic>{
          'id': '$i',
          'name': 'Q$i',
          // SUBJECTIVE on purpose: the answer-key gate only inspects
          // objective questions, and building a valid option set here would
          // be fixture work about a gate this test is not for.
          'question_type': 'subjective_rubric',
          'difficulty': 'medium',
          'state': 'approved',
          'active': true,
          'generator': <String, dynamic>{'id': '3', 'name': 'VAL Generator'},
          // The SERVER's own launch-readiness verdict, which is what a live
          // payload carries. Reconstructing it from dimensions and media rows
          // here would be a second copy of the rule under test.
          'servable': true,
        }),
    ];
    expect(
      rig.store.launchGates(asm).where((GateResult g) => !g.ok),
      isEmpty,
      reason: 'the fixture must clear every local gate, or this test is '
          'silently re-testing the client-side refusal above',
    );

    await rig.store.launch(asm);

    expect(rig.launchCalled, isTrue);
    expect(rig.lastToast, contains('Launch blocked:'));
    expect(rig.lastToast, contains('Generator has servable questions'));
  });

  test('every failing gate is named, not just the first', () async {
    // ONE GATE IS THE EASY CASE. The tests above all fail a single gate, so a
    // refusal that reported only `failing.first` would pass every one of them
    // and still hide four of the five things the operator has to fix.
    //
    // Already launched, nobody assigned and no generator: the draft, roster
    // and generator gates fail outright, and the pool gate falls with the
    // generator because there is then nothing to draw from.
    final _Rig rig = _Rig(roster: 0, state: 'in_progress', withGenerator: false);
    final Assessment asm = await rig.load();

    final List<GateResult> failing = rig.store
        .launchGates(asm)
        .where((GateResult g) => !g.ok)
        .toList();
    expect(
      failing.length,
      greaterThanOrEqualTo(4),
      reason: 'the fixture has to fail several gates, or this is the '
          'single-gate case again',
    );

    await rig.store.launch(asm);

    for (final GateResult g in failing) {
      expect(
        rig.lastToast,
        contains(g.name),
        reason: '"${g.name}" failed and was left out of the refusal',
      );
      expect(rig.lastToast, contains(g.why));
    }
    expect(rig.launchCalled, isFalse);
  });
}
