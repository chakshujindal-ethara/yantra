// What the candidate typed must be what gets posted.
//
// THE BUG THIS EXISTS FOR, seen in the browser: a candidate filled the free
// text box on a `subjective_rubric` question, pressed "Save & next", and got
// the red toast "This answer is incomplete for its question type" over a box
// with four paragraphs in it. The header still read "0 answered".
//
// That string is the server's, and for a subjective type it has exactly one
// cause - `candidate.py:660`:
//
//     subjective = question.question_type in ("subjective_rubric", ...)
//     if subjective and not justification:
//         return False        # -> 422 incomplete_answer
//
// So an EMPTY justification was reaching the server. The cause is on the
// client, and it is a stale capture:
//
//   - `saveAnswerQuiet` deliberately does NOT notify. It has to not notify:
//     rebuilding the exam surface on every keystroke destroys the caret in a
//     free-text field.
//   - therefore nothing repaints while somebody types, and the `Attempt` a
//     widget captured at its last build never advances.
//   - `_navigate` read the outgoing answer off that captured object, so it
//     posted the response as it stood BEFORE the typing: empty.
//
// The same staleness had a quieter and worse consequence on a question
// carrying both options and prose (the
// image layouts with dimensions): `_Options._pick` merged onto the captured
// response too, so picking an option after typing wrote the typed answer back
// out of existence with no error at all.
//
// These are store-level tests on purpose. The defect is in which OBJECT is
// read, not in what is painted, so driving it through the store is what
// actually pins the contract.
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
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

const String kToken = '65a12c11-fb40-48b5-af51-3f3c6822b65f';
const String kTyped =
    'Score Q2 as NO. The principle is that an unconfirmable alignment is not '
    'a confirmed alignment; the burden is on the edit to demonstrate it.';

/// Every `/answer` body the client sent, in order.
final List<Map<String, dynamic>> sentBodies = <Map<String, dynamic>>[];

http.Client _server() => MockClient((http.Request req) async {
  final String p = req.url.path;
  if (p.endsWith('/answer')) {
    final Map<String, dynamic> body =
        jsonDecode(req.body) as Map<String, dynamic>;
    // Odoo type="json" nests the real arguments under `params`.
    final Object? params = body['params'];
    sentBodies.add(params is Map<String, dynamic> ? params : body);

    // The SERVER's own rule, reproduced: an empty justification on a
    // subjective question is refused. Without this the test would pass on a
    // stub more forgiving than the system it stands in for.
    final String justification = '${sentBodies.last['justification'] ?? ''}';
    if (justification.isEmpty) {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'incomplete_answer',
            'message': 'This answer is incomplete for its question type',
          },
        }),
        422,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    return http.Response(
      jsonEncode(<String, dynamic>{
        'ok': true,
        'data': <String, dynamic>{'saved': true, 'next': null},
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
  return http.Response(
    jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

/// An attempt mid-exam, exactly as the runner holds one.
Attempt seedAttempt() => Attempt.fromJson(<String, dynamic>{
  'id': 7,
  'access_token': kToken,
  'assessment_id': 21,
  'state': 'in_progress',
  'total_questions': 3,
  'answered_count': 0,
});

Question subjective() => Question.fromJson(<String, dynamic>{
  'id': 10,
  'name': 'End of Shift Parking Procedure',
  'prompt': 'Describe the exact physical state the forklift must be left in.',
  'question_type': 'subjective_rubric',
});

AppStore liveStore() {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: _server(), bearer: 'tok'),
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  s.attempts = <Attempt>[seedAttempt()];
  return s;
}

void main() {
  setUp(sentBodies.clear);

  test(
    'the justification typed after the last repaint is the one posted',
    () async {
      final AppStore s = liveStore();
      final Question q = subjective();

      // The captured attempt: what a widget holds from its last build. The
      // runner passes exactly this object into its nav callback.
      final Attempt captured = s.attemptByToken(kToken)!;

      // Typing. `saveAnswerQuiet` updates the store and deliberately does not
      // notify, so `captured` is now out of date - which is the whole bug.
      s.saveAnswerQuiet(
        captured.id,
        q.id,
        s.responseFor(captured, q).copyWith(justification: kTyped),
      );

      expect(
        captured.resp[q.id]?.justification ?? '',
        isEmpty,
        reason:
            'the captured object MUST still be stale - if it is not, this test '
            'has stopped reproducing the bug and proves nothing',
      );

      // What `_navigate` now does: re-read the sitting from the store.
      final Attempt current = s.attemptByToken(kToken) ?? captured;
      final Response r = current.resp[q.id] ?? const Response();

      await s.examAdvance(kToken, q.id, r);

      expect(sentBodies, hasLength(1));
      expect(
        sentBodies.single['justification'],
        kTyped,
        reason:
            'posting the captured response sent "" and the server answered 422 '
            '"This answer is incomplete for its question type"',
      );
    },
  );

  test('responseFor resolves through the store, not the passed object', () {
    final AppStore s = liveStore();
    final Question q = subjective();
    final Attempt captured = s.attemptByToken(kToken)!;

    s.saveAnswerQuiet(
      captured.id,
      q.id,
      s.responseFor(captured, q).copyWith(justification: kTyped),
    );

    // Handed the STALE object on purpose: every answer editor holds one.
    expect(
      s.responseFor(captured, q).justification,
      kTyped,
      reason:
          'each keystroke merges onto this; reading it off the stale object '
          'loses everything written since the last repaint',
    );
  });

  test('picking an option does not erase the typed justification', () {
    // The silent half of the defect. A question with options AND prose is
    // ordinary - an image layout with dimensions is one.
    final AppStore s = liveStore();
    final Question q = subjective();
    final Attempt captured = s.attemptByToken(kToken)!;

    s.saveAnswerQuiet(
      captured.id,
      q.id,
      s.responseFor(captured, q).copyWith(justification: kTyped),
    );

    // What `_Options._pick` now does: merge onto the store's response.
    final Response base = s.responseFor(captured, q);
    s.saveAnswer(captured.id, q.id, base.copyWith(lines: <String>['41']));

    final Response after = s.responseFor(captured, q);
    expect(after.lines, <String>['41']);
    expect(
      after.justification,
      kTyped,
      reason:
          'merging onto the captured response wrote the candidate typed '
          'answer out of existence, with no error shown',
    );
  });

  group('the answered count tracks the paper', () {
    // `serverAnswered ?? resp.length` read as "fall back to local", but a
    // sitting in progress sends a real `answered_count: 0`, so the fallback
    // could never fire. The exam header sat on "0 answered" for the whole
    // paper - which is exactly what the browser showed - while the server had
    // the answer stored and reported 1.
    test('a local answer counts even when the server last said 0', () {
      final AppStore s = liveStore();
      final Question q = subjective();
      final Attempt captured = s.attemptByToken(kToken)!;

      expect(captured.answeredCount, 0);

      s.saveAnswerQuiet(
        captured.id,
        q.id,
        s.responseFor(captured, q).copyWith(justification: kTyped),
      );

      expect(
        s.attemptByToken(kToken)!.answeredCount,
        1,
        reason: 'the header read "0 answered" over an answer the server held',
      );
    });

    test(
      'a list row still trusts the server, whose resp is empty by design',
      () {
        final Attempt fromList = Attempt.fromJson(<String, dynamic>{
          'id': 7,
          'token': kToken,
          'assessment_id': 21,
          'state': 'completed',
          'progress': <String, dynamic>{'answered': 3, 'total': 3},
        });
        expect(fromList.resp, isEmpty);
        expect(
          fromList.answeredCount,
          3,
          reason: 'counting `resp` alone reports 0 for a submitted attempt',
        );
      },
    );

    test('a box typed into and then cleared is not an answer', () {
      final AppStore s = liveStore();
      final Question q = subjective();
      final Attempt captured = s.attemptByToken(kToken)!;

      s.saveAnswerQuiet(
        captured.id,
        q.id,
        s.responseFor(captured, q).copyWith(justification: kTyped),
      );
      s.saveAnswerQuiet(
        captured.id,
        q.id,
        s.responseFor(captured, q).copyWith(justification: '   '),
      );

      expect(
        s.attemptByToken(kToken)!.answeredCount,
        0,
        reason:
            'an empty response row exists after the first keystroke; counting '
            'it would call a question answered that the server refuses',
      );
    });
  });

  // The one that drives the REAL screen. The three above pin the store's
  // contract; this one presses the button the candidate pressed, so it fails
  // if `_navigate` ever goes back to reading its captured attempt.
  testWidgets('typing then pressing Next posts the typed answer', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final AppStore s = liveStore();
    final Question q = subjective();

    // The runner mid-exam: the sitting is started, and the server's envelope
    // holds question 1. Both are what `/exam/<token>/state` leaves behind.
    s.attempts = <Attempt>[seedAttempt().copyWith(startedAt: DateTime.now())];
    s.assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': 21,
        'name': 'sample test',
        'state': 'in_progress',
        'duration_minutes': 45,
      }),
    ];
    s.examByToken[kToken] = ExamView(
      outcome: 'question',
      question: q,
      index: 1,
      total: 3,
    );

    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AssessmentNavScope(
          nav: AssessmentNav(),
          child: ExamScreen(
            store: s,
            token: kToken,
            sub: ExamSub.question,
            questionNumber: 1,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField).first, kTyped);
    await t.pump();

    // No repaint has happened - that is exactly the condition the bug needed.
    await t.tap(find.text('Next'));
    await t.pumpAndSettle();
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );

    expect(sentBodies, isNotEmpty, reason: 'Save & next must post the answer');
    expect(
      sentBodies.last['justification'],
      kTyped,
      reason:
          'the screen posted "" and the server refused the whole answer with '
          '422 "This answer is incomplete for its question type"',
    );
  });
}
