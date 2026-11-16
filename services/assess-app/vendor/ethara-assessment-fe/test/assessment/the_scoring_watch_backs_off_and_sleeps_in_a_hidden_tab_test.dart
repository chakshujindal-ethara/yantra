// The assessment's scoring watch backs off while nothing changes, sleeps in a
// hidden tab, and spreads its run-end detail read (ETP_PLANS_AND_STRATEGY.md
// §2.6 W4.4, §3.15).
//
// THE LOAD. Every open tab on a paper being graded asked `/scoring` every 5 s -
// 12 requests a minute - against a cron that moves once a minute, so most
// answers repeated the last one. A tab left open in the background asked just
// as often with nobody looking. And when a run ended, every tab saw it on the
// same tick and fetched the heavy detail route in the same second.
//
// Now: 5 s, then 15 s after one unchanged answer, 30 s after two, and back to
// 5 s on any change; nothing while the tab is hidden and a read the moment it
// is shown; the run-end read lands 0-5 s after the run ends, not at once.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// Answers `/scoring` from a script, the last entry repeating.
class _Spy {
  final List<String> paths = <String>[];
  final List<Map<String, dynamic>> scoring;

  _Spy(List<Map<String, dynamic>> scoring)
    : scoring = <Map<String, dynamic>>[...scoring];

  int hits(String suffix) =>
      paths.where((String p) => p.endsWith(suffix)).length;

  http.Client get client => MockClient((http.Request req) async {
    paths.add(req.url.path);
    Map<String, dynamic> body = const <String, dynamic>{};
    if (req.url.path.endsWith('/scoring')) {
      body = scoring.length > 1 ? scoring.removeAt(0) : scoring.first;
    }
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': body}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
}

/// A fixed draw for the run-end spread, remembering the bound it was asked for.
class _Draw implements math.Random {
  final int ms;
  int? askedMax;

  _Draw(this.ms);

  @override
  int nextInt(int max) {
    askedMax = max;
    return ms;
  }

  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;
}

Map<String, dynamic> _count(int queued) => <String, dynamic>{
  'phase': 'scoring',
  'summary': '$queued queued',
  'queued': queued,
};

Future<_Spy> _open(WidgetTester t, List<Map<String, dynamic>> script) async {
  final _Spy spy = _Spy(script);
  final AppStore s =
      AppStore(
          api: ApiClient(baseUrl: 'http://stub', client: spy.client),
        )
        ..assessments = <Assessment>[
          Assessment.fromJson(<String, dynamic>{
            'id': 'A-1',
            'name': 'Warehouse Safety',
            'state': 'in_progress',
            'scoring_phase': 'scoring',
            'scoring_summary': '2 queued',
          }),
        ];
  t.view.physicalSize = const Size(1600, 2600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: AssessmentDetailScreen(
            store: s,
            portal: Portal.admin,
            asmId: 'A-1',
            tab: 'config',
          ),
        ),
      ),
    ),
  );
  await t.pump();
  addTearDown(() async => t.pumpWidget(const SizedBox.shrink()));
  return spy;
}

/// What the browser tab reports, sent the way the engine sends it.
Future<void> _tab(WidgetTester t, AppLifecycleState state) async {
  await t.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.lifecycle.name,
    SystemChannels.lifecycle.codec.encodeMessage(state.toString()),
    (_) {},
  );
}

/// Advance [seconds] and let the tick's request land.
Future<void> _wait(WidgetTester t, double seconds) async {
  await t.pump(Duration(milliseconds: (seconds * 1000).round()));
  await t.pump();
}

void main() {
  testWidgets('unchanged numbers back the watch off to 15 s, then 30 s', (
    WidgetTester t,
  ) async {
    final _Spy spy = await _open(t, <Map<String, dynamic>>[_count(2)]);

    await _wait(t, 5.5);
    expect(spy.hits('/v1/scoring'), 1, reason: 'the first tick is at 5 s');
    await _wait(t, 5);
    expect(spy.hits('/v1/scoring'), 2, reason: 'a first answer is news: 5 s');

    await _wait(t, 14);
    expect(spy.hits('/v1/scoring'), 2, reason: 'one unchanged answer: 15 s');
    await _wait(t, 1);
    expect(spy.hits('/v1/scoring'), 3);

    await _wait(t, 29);
    expect(spy.hits('/v1/scoring'), 3, reason: 'two unchanged answers: 30 s');
    await _wait(t, 1);
    expect(spy.hits('/v1/scoring'), 4);

    await _wait(t, 600);
    expect(
      spy.hits('/v1/scoring'),
      lessThanOrEqualTo(25),
      reason:
          'ten more minutes at 30 s is 20 requests; the old fixed 5 s '
          'spent 120 on numbers that never moved',
    );
  });

  testWidgets('a change snaps it back to 5 s', (WidgetTester t) async {
    final _Spy spy = await _open(t, <Map<String, dynamic>>[
      _count(2),
      _count(2),
      _count(2),
      _count(1),
    ]);

    // Ticks at 5, 10, 25 s answer "2 queued"; the 55 s tick sees "1 queued".
    await _wait(t, 55.5);
    expect(spy.hits('/v1/scoring'), 4);

    await _wait(t, 5);
    expect(
      spy.hits('/v1/scoring'),
      5,
      reason: 'the numbers moved, so the run is moving: watch it closely again',
    );
  });

  testWidgets('a hidden tab asks nothing, and reads at once when shown', (
    WidgetTester t,
  ) async {
    final _Spy spy = await _open(t, <Map<String, dynamic>>[_count(2)]);
    addTearDown(() => _tab(t, AppLifecycleState.resumed));

    await _tab(t, AppLifecycleState.hidden);
    await _wait(t, 600);
    expect(
      spy.hits('/v1/scoring'),
      0,
      reason: 'nobody is looking at a hidden tab, so its numbers cost nothing',
    );

    await _tab(t, AppLifecycleState.resumed);
    await _wait(t, 0);
    expect(
      spy.hits('/v1/scoring'),
      1,
      reason: 'shown again, it catches up now rather than after a wait',
    );
  });

  testWidgets('a blurred but visible tab keeps watching', (
    WidgetTester t,
  ) async {
    // `inactive` is a blur: the console on a second monitor while the admin
    // types in Odoo. It is still on screen, so it still updates.
    final _Spy spy = await _open(t, <Map<String, dynamic>>[_count(2)]);
    addTearDown(() => _tab(t, AppLifecycleState.resumed));

    await _tab(t, AppLifecycleState.inactive);
    await _wait(t, 5.5);
    expect(spy.hits('/v1/scoring'), 1);
  });

  testWidgets('the run-end detail read is spread over 0-5 s', (
    WidgetTester t,
  ) async {
    final _Draw draw = _Draw(3000);
    final math.Random real = AssessmentDetailScreen.runEndJitter;
    AssessmentDetailScreen.runEndJitter = draw;
    addTearDown(() => AssessmentDetailScreen.runEndJitter = real);

    final _Spy spy = await _open(t, <Map<String, dynamic>>[
      <String, dynamic>{'phase': 'idle', 'summary': ''},
    ]);
    final int before = spy.hits('/assessments/A-1');

    await _wait(t, 5.5);
    expect(spy.hits('/v1/scoring'), 1, reason: 'the tick that sees the end');
    expect(
      spy.hits('/assessments/A-1'),
      before,
      reason: 'not in the same second as every other open tab',
    );
    expect(draw.askedMax, 5001, reason: 'a draw of 0 to 5000 ms');

    await _wait(t, 2.5);
    expect(spy.hits('/assessments/A-1'), before + 1, reason: 'at the draw');
    await _wait(t, 60);
    expect(spy.hits('/assessments/A-1'), before + 1, reason: 'and only once');
  });
}
