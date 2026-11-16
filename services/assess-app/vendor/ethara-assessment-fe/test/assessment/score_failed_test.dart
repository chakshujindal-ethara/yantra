// "Score Failed Candidates (n)" - shown only when n > 0, and sent with the
// states that recover a failure.
//
// This codebase's own rule (responses_screen.dart): an always-on danger
// button that reports "nothing is errored" reads as a fault in the button,
// not an empty queue. So the button must be ABSENT at n == 0 and PRESENT with
// the right count at n > 0. `n` is derived client-side from the assessment's
// own attempts, using the LlmState vocabulary rather than hard-coded strings.
//
// The payload half proves the recovery actually asks for both states: a
// transient `failed` the automatic retry gave up on, and a terminal `error`.
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

class _Spy {
  final List<String> paths = <String>[];
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  http.Client get client => MockClient((http.Request req) async {
    paths.add(req.url.path);
    try {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
    } on FormatException {
      bodies.add(<String, dynamic>{});
    }
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });

  bool hit(String fragment) => paths.any((String p) => p.contains(fragment));
  Map<String, dynamic> bodyFor(String fragment) {
    for (int i = paths.length - 1; i >= 0; i--) {
      if (paths[i].contains(fragment)) return bodies[i];
    }
    return <String, dynamic>{};
  }
}

/// A launched assessment - the Score Failed button only appears once the paper
/// is out of draft.
Assessment _launched() => Assessment(
  id: 'A-1',
  name: 'Warehouse Safety',
  state: AsmState.inProgress,
);

Attempt _attempt(String id, LlmState subj) => Attempt(
  id: id,
  assessmentId: 'A-1',
  employeeId: 'P-$id',
  token: 'tok-$id',
  state: AttemptState.submitted,
  isLocked: true,
  subjectiveState: subj,
);

/// A SEED store, so the detail screen's `loadAssessment` is a no-op and leaves
/// the records this test seeded in place.
AppStore _seed({required List<Attempt> attempts}) {
  final AppStore s = AppStore();
  s.assessments = <Assessment>[_launched()];
  s.attempts = attempts;
  return s;
}

Future<void> _open(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1600, 2400);
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
  await t.pumpAndSettle();
}

void main() {
  testWidgets('no failed answers - the button is absent', (
    WidgetTester t,
  ) async {
    final AppStore s = _seed(
      attempts: <Attempt>[
        _attempt('1', LlmState.scored),
        _attempt('2', LlmState.scored),
      ],
    );
    await _open(t, s);

    expect(
      find.textContaining('Score Failed Candidates'),
      findsNothing,
      reason: 'an always-on button reporting "nothing is errored" reads as a '
          'fault in the button',
    );
  });

  testWidgets('failed and errored answers - the count is shown', (
    WidgetTester t,
  ) async {
    final AppStore s = _seed(
      attempts: <Attempt>[
        _attempt('1', LlmState.failed),
        _attempt('2', LlmState.error),
        _attempt('3', LlmState.scored),
      ],
    );
    await _open(t, s);

    // Two of the three are in a failed state (failed + error), and the count
    // in the label is derived from exactly those.
    //
    // THE NOUN MATCHES THE UNIT. This counts ATTEMPTS, not answers - two
    // candidates here, not two responses - and the label used to say
    // "Responses". On production that read "Score Failed Responses (1)" beside
    // a candidate holding TEN errored answers, so the number looked wrong to
    // whoever was chasing it.
    expect(find.textContaining('Score Failed Candidates (2)'), findsOneWidget);
  });

  testWidgets('a cancelled answer does NOT count as failed', (
    WidgetTester t,
  ) async {
    // A kill is a chosen outcome, not a failure to recover - so it must not
    // pad the Score Failed count.
    final AppStore s = _seed(
      attempts: <Attempt>[
        _attempt('1', LlmState.cancelled),
        _attempt('2', LlmState.scored),
      ],
    );
    await _open(t, s);

    expect(find.textContaining('Score Failed Responses'), findsNothing);
  });

  test('the request carries assessment_id and both failed states', () async {
    final _Spy spy = _Spy();
    final AppStore s = AppStore(
      api: ApiClient(baseUrl: 'http://stub', client: spy.client),
    );
    s.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');

    await s.requeueFailedFor(assessmentId: 'A-1');

    expect(spy.hit('/api/v1/scoring/requeue_errored'), isTrue);
    final Map<String, dynamic> body = spy.bodyFor('/scoring/requeue_errored');
    expect(body['assessment_id'], 'A-1');
    expect(
      body['states'],
      <String>['failed', 'error'],
      reason: 'the button recovers both a transient failure and a terminal '
          'error',
    );
  });
}
