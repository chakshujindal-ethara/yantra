// Re-posting an answer the server already holds must cost NOTHING.
//
// THE DEFECT, measured over the real assessment of 2026-09-03 from the stage
// access log (1,368,213 lines):
//
//   /api/v1/exam/<token>/answer   300,092 POSTs from 1,230 candidates
//   median per candidate              240 POSTs
//   papers actually sat            19 and 35 questions
//   => amplification              ~7x to ~13x over one-post-per-answer
//
//   median SQL queries per POST         39   (12 stored computes on the response
//                                             row, 7 more on the evaluator)
//   /answer share of ALL db traffic   86.6%  (12.4M of 14.3M queries in 3h)
//   queries that re-stored a known value ~89%
//
// The debounce was never the problem: it correctly collapses keystrokes. What was
// missing is a check that the value had CHANGED. Every navigation, every
// re-render that re-emitted the same value, and every keystroke pause after a
// no-op edit fired a full 39-query write.
//
// WHAT THESE TESTS ASSERT, by counting REAL requests over a fake transport rather
// than inspecting store state: the defect was request volume, so request volume
// is what has to be pinned.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// Answers the exam routes and tallies every `/answer` POST.
class _CountingBackend extends http.BaseClient {
  int answerPosts = 0;
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final String path = request.url.path;
    Map<String, dynamic> body = <String, dynamic>{};
    if (request is http.Request && request.body.isNotEmpty) {
      final Object? decoded = jsonDecode(request.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    }

    Object payload;
    if (path.endsWith('/answer')) {
      answerPosts++;
      bodies.add(body);
      payload = <String, dynamic>{
        'ok': true,
        'data': <String, dynamic>{
          'saved': true,
          'attempt_closed': false,
          'next': null,
        },
      };
    } else if (path.endsWith('/auth_token')) {
      payload = <String, dynamic>{
        'data': <String, dynamic>{
          'access_token': 't',
          'user_type': 'candidate',
          'name': 'Cand',
        },
      };
    } else {
      payload = <String, dynamic>{'ok': true, 'data': <String, dynamic>{}};
    }

    final List<int> bytes = utf8.encode(jsonEncode(payload));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      200,
      headers: <String, String>{'content-type': 'application/json'},
      request: request,
    );
  }
}

/// A store the autosave will actually post from.
///
/// `_syncAnswer` opens with `if (!_live) return;`, so a store left on the seed
/// source sends nothing and every assertion below would pass on zero requests —
/// proving nothing. Same shape as `answer_not_stale_test.dart:liveStore`.
AppStore _store(_CountingBackend backend) {
  final AppStore s = AppStore(
    api: ApiClient(
      client: backend,
      baseUrl: 'https://example.invalid',
      bearer: 't',
    ),
    // THE SHIPPED PACING IS 5s / 15s. Waiting that out would put roughly two
    // minutes of pure sleep in this file, so the clock is injected - the same
    // seam `api` uses. The RATIO is preserved (debounce : ceiling = 1 : 3), so
    // what these tests exercise is the real relationship between the two, at a
    // scale a test suite can afford.
    answerDebounce: _testDebounce,
    answerMaxWait: _testMaxWait,
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  // `saveAnswerQuiet` looks the attempt up by id and returns early when it is
  // absent, so without this every assertion below would pass on ZERO requests
  // and prove nothing.
  s.attempts = <Attempt>[_attempt()];
  return s;
}

Attempt _attempt() => Attempt.fromJson(<String, dynamic>{
  'id': 1,
  'access_token': 'tok-1',
  'assessment_id': 55,
  'state': 'in_progress',
  'total_questions': 3,
  'answered_count': 0,
});

const Duration _testDebounce = Duration(milliseconds: 200);
const Duration _testMaxWait = Duration(milliseconds: 600);

/// Comfortably past [_testDebounce], so a pending save has certainly gone.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 700));

/// The live assessment `finishExam` looks up before it will do anything.
///
/// `questions` is EMPTY because that is what a LIVE payload carries - the
/// server grades, so it never sends the paper back. A seed-shaped assessment
/// here would take a different branch in `finishExam` and prove nothing about
/// the real submit; see `exam_answer_loss_test.dart`.
Assessment _liveAsm() => Assessment(
  id: '55',
  name: 'Warehouse Safety',
  questions: const <Question>[],
);

void main() {
  group('an unchanged answer is not re-sent', () {
    test('posting the SAME answer ten times writes once', () async {
      final _CountingBackend backend = _CountingBackend();
      final AppStore store = _store(backend);
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': '1',
        'assessment_id': '55',
        'access_token': 'tok-1',
      });
      final Response r = Response(lines: <String>['7'], justification: 'ok');

      for (int i = 0; i < 10; i++) {
        store.saveAnswerQuiet(ev.id, 'q1', r);
        await _settle();
      }

      expect(
        backend.answerPosts,
        1,
        reason:
            'sent ${backend.answerPosts} posts for one unchanged answer. On '
            '2026-09-03 this amplification made /answer 86.6% of all database '
            'traffic, ~89% of it re-storing a value the server already held',
      );
    });

    test('a REAL edit still writes, every time it changes', () async {
      final _CountingBackend backend = _CountingBackend();
      final AppStore store = _store(backend);
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': '1',
        'assessment_id': '55',
        'access_token': 'tok-1',
      });

      for (final String text in <String>['a', 'ab', 'abc']) {
        store.saveAnswerQuiet(
          ev.id,
          'q1',
          Response(lines: const <String>[], justification: text),
        );
        await _settle();
      }

      expect(
        backend.answerPosts,
        3,
        reason:
            'the dirty check suppressed a genuine edit — an answer the '
            'candidate changed must always reach the server',
      );
      expect(
        backend.bodies.last['justification'],
        'abc',
        reason: 'the last value the candidate typed must be the stored one',
      );
    });

    test('reordering the same options is not a change', () async {
      final _CountingBackend backend = _CountingBackend();
      final AppStore store = _store(backend);
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': '1',
        'assessment_id': '55',
        'access_token': 'tok-1',
      });

      // The option list is a SET on both sides: the server reconciles it
      // against the question's dimensions, so order carries no meaning and a
      // reordered selection must not cost a 39-query write.
      store.saveAnswerQuiet(
        ev.id,
        'q1',
        Response(lines: <String>['3', '9'], justification: ''),
      );
      await _settle();
      store.saveAnswerQuiet(
        ev.id,
        'q1',
        Response(lines: <String>['9', '3'], justification: ''),
      );
      await _settle();

      expect(
        backend.answerPosts,
        1,
        reason: 'a reordered option list is the same answer',
      );
    });

    test('deselecting an option IS a change', () async {
      final _CountingBackend backend = _CountingBackend();
      final AppStore store = _store(backend);
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': '1',
        'assessment_id': '55',
        'access_token': 'tok-1',
      });

      store.saveAnswerQuiet(
        ev.id,
        'q1',
        Response(lines: <String>['3', '9'], justification: ''),
      );
      await _settle();
      store.saveAnswerQuiet(
        ev.id,
        'q1',
        Response(lines: <String>['3'], justification: ''),
      );
      await _settle();

      expect(
        backend.answerPosts,
        2,
        reason:
            'dropping an option must reach the server, or the candidate is '
            'marked on a choice they withdrew',
      );
    });

    test('two questions are tracked independently', () async {
      final _CountingBackend backend = _CountingBackend();
      final AppStore store = _store(backend);
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': '1',
        'assessment_id': '55',
        'access_token': 'tok-1',
      });
      final Response same = Response(
        lines: const <String>['1'],
        justification: 'x',
      );

      // Identical payloads on DIFFERENT questions are different answers. A
      // fingerprint keyed on payload alone would store only the first.
      store.saveAnswerQuiet(ev.id, 'q1', same);
      await _settle();
      store.saveAnswerQuiet(ev.id, 'q2', same);
      await _settle();

      expect(
        backend.answerPosts,
        2,
        reason:
            'the second question never reached the server, so it would be '
            'marked unanswered',
      );
    });
  });

  group('the shipped pacing and the save-only sentinel', () {
    // TWO GAPS A REVIEW FOUND, both of the same kind: a thing that is true in
    // production and asserted nowhere.

    test('the SHIPPED debounce and ceiling are what we think they are', () {
      // Every other test in this file injects 200ms/600ms so the suite does not
      // sleep for minutes, and asserts the RATIO. That leaves the real values
      // free to drift to anything at all with the suite still green - which is
      // the "a target nothing measures is not a target" problem these files
      // exist to prevent, reintroduced one level up.
      expect(
        AppStore.answerDebounceDefault,
        const Duration(seconds: 5),
        reason:
            'the debounce is the single biggest lever on write volume; '
            'changing it should be a deliberate act with a test to update',
      );
      expect(
        AppStore.answerMaxWaitDefault,
        const Duration(seconds: 15),
        reason:
            'the ceiling is what stops a longer debounce becoming a '
            'data-loss bug for somebody typing without pause',
      );
      expect(
        AppStore.answerMaxWaitDefault,
        greaterThan(AppStore.answerDebounceDefault),
        reason: 'a ceiling below the debounce would fire on every keystroke',
      );
    });

    test('the autosave tells the server it wants nothing back', () async {
      // `nav: "stay"` is what stops the route composing the next question -
      // prompt, options and a signed URL per plate - for a call that discards
      // its response. Measured at 29 queries -> 20. The SERVER contract has its
      // own tests; nothing asserted the client actually asks for it, so a
      // refactor dropping the argument would silently give the saving back and
      // no test would notice.
      final _CountingBackend backend = _CountingBackend();
      final AppStore store = _store(backend);
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': '1',
        'assessment_id': '55',
        'access_token': 'tok-1',
      });

      store.saveAnswerQuiet(
        ev.id,
        'q1',
        Response(lines: <String>['7'], justification: 'ok'),
      );
      await _settle();

      expect(backend.bodies, isNotEmpty, reason: 'nothing was posted at all');
      expect(
        backend.bodies.last['nav'],
        'stay',
        reason:
            'the debounced autosave asked the server to build the next '
            'question it is about to throw away',
      );
    });
  });

  group('an answer cannot stay unsaved while typing continues', () {
    test('steady typing that never pauses still reaches the server', () async {
      // THE HAZARD A LONGER DEBOUNCE CREATES, and the reason the ceiling
      // exists. A plain debounce restarts on every keystroke, so somebody
      // typing steadily through a long-form answer never pauses long enough to
      // trigger it and NEVER SAVES. At a 1s debounce that was invisible: almost
      // nobody types for a minute without a one-second pause. At 5s it is
      // ordinary, and a dropped connection would take the whole answer.
      //
      // WITHOUT `_answerMaxWait` THIS TEST COUNTS ZERO. That is the negative
      // control: every edit below lands inside the debounce window, so the only
      // thing that can produce a write is the ceiling.
      final _CountingBackend backend = _CountingBackend();
      final AppStore store = _store(backend);
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': '1',
        'assessment_id': '55',
        'access_token': 'tok-1',
      });

      // Edits at half the debounce interval, for five ceilings' worth of time.
      final int step = _testDebounce.inMilliseconds ~/ 2;
      final int edits = (_testMaxWait.inMilliseconds * 5) ~/ step;
      for (int i = 0; i < edits; i++) {
        store.saveAnswerQuiet(
          ev.id,
          'q1',
          Response(lines: const <String>[], justification: 'word $i'),
        );
        await Future<void>.delayed(Duration(milliseconds: step));
      }

      expect(
        backend.answerPosts,
        greaterThan(0),
        reason:
            'nothing was saved across ${_testMaxWait.inMilliseconds * 5}ms of '
            'continuous typing. A debounce alone never fires while somebody '
            'keeps typing, so at the shipped 5s the candidate could lose a '
            'whole long-form answer to a dropped connection',
      );
      // BOUNDED AT BOTH ENDS. Saving on every keystroke would also satisfy the
      // assertion above, and that is the amplification this file exists to
      // prevent - so the ceiling has to be a ceiling, not a floor.
      expect(
        backend.answerPosts,
        lessThanOrEqualTo(6),
        reason:
            'sent ${backend.answerPosts} posts for ~5 ceiling periods of '
            'typing; the ceiling is meant to bound writes, not restore the '
            'per-keystroke write it replaced',
      );
    });
  });

  group('the submit burst does not re-send what the server already stored', () {
    // WHY THIS IS THE WORST-SHAPED WRITE ON THE PLATFORM. `finishExam` re-sends
    // every answer serially, and every candidate presses Submit at roughly the
    // same moment because they all started together on a shared clock. A
    // 35-question paper therefore fired 35 sequential POSTs into the narrowest
    // window of the sitting, from every candidate at once.

    test('an answer the server acknowledged is not sent again', () async {
      final _CountingBackend backend = _CountingBackend();
      final AppStore store = _store(backend);
      store.assessments = <Assessment>[_liveAsm()];
      store.attempts = <Attempt>[_attempt()];

      store.saveAnswerQuiet(
        '1',
        'q1',
        Response(lines: <String>['7'], justification: 'ok'),
      );
      await _settle();
      final int afterAutosave = backend.answerPosts;
      expect(
        afterAutosave,
        1,
        reason:
            'the fixture never stored an answer, so the submit below '
            'would have nothing to skip and this test would prove nothing',
      );

      store.finishExam('1');
      await _settle();

      expect(
        backend.answerPosts,
        afterAutosave,
        reason:
            'submit re-sent ${backend.answerPosts - afterAutosave} answer(s) '
            'the server had already acknowledged. Multiplied by the paper '
            'length and by a whole cohort submitting at once, this is the '
            'heaviest write burst of the sitting and all of it redundant',
      );
    });

    test('an answer the server never acknowledged IS sent', () async {
      // THE OTHER HALF, and the one that makes the skip safe to ship. The
      // re-send is the safety net under the autosave: an answer typed inside
      // the debounce window, or one whose autosave was refused, has no accepted
      // fingerprint and must still reach the server. Dropping those would turn
      // a saving into silent answer loss - which is exactly the defect
      // `exam_answer_loss_test.dart` was written for.
      final _CountingBackend backend = _CountingBackend();
      final AppStore store = _store(backend);
      store.assessments = <Assessment>[_liveAsm()];
      store.attempts = <Attempt>[
        Attempt.fromJson(<String, dynamic>{
          'id': 1,
          'access_token': 'tok-1',
          'assessment_id': 55,
          'state': 'in_progress',
          'total_questions': 3,
          'answered_count': 0,
        })..resp['q1'] = Response(lines: <String>['7'], justification: 'ok'),
      ];

      store.finishExam('1');
      await _settle();

      expect(
        backend.answerPosts,
        1,
        reason:
            'an answer with no accepted fingerprint was not re-sent at submit, '
            'so an answer typed inside the debounce window would be lost',
      );
    });
  });
}
