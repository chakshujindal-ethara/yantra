// A re-score grades EXACTLY the answers it names - and the assessment's bulk
// re-score clears the errors its notice is about.
//
// THE BUGS (ETP_PLANS_AND_STRATEGY.md §3.8). The route took an attempt and nothing
// else, so every re-score button re-graded the candidate's UNRESOLVED answers:
// "Re-score" on a scored Q7 had nothing to grade and said "Nothing pending", and
// "Re-score 3 selected" re-scored whatever else was unresolved rather than the
// ticked three. The route now takes `question_ids` and QUEUES them, so the app
// has to send the ids and say "queued", not "re-scored".
//
// And "Re-score This Assessment" sits on the "held on a scoring error" notice
// while calling only `/scoring/queue`, which never picks up an errored answer -
// so the one button offered for those answers could not clear them.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// Records every request; answers a route by path suffix, or `{}`.
class _Spy {
  final List<String> paths = <String>[];
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];
  final Map<String, http.Response> canned = <String, http.Response>{};

  /// Holds the rescore route open until completed, so a test can look at the
  /// store while the request is in flight.
  Completer<void>? gate;

  http.Client get client => MockClient((http.Request req) async {
    paths.add(req.url.path);
    try {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
    } on FormatException {
      bodies.add(<String, dynamic>{});
    }
    if (req.url.path.endsWith('/rescore')) await gate?.future;
    for (final MapEntry<String, http.Response> e in canned.entries) {
      if (req.url.path.endsWith(e.key)) return e.value;
    }
    return _ok(<String, dynamic>{});
  });

  Map<String, dynamic> bodyOf(String suffix) =>
      bodies[paths.indexWhere((String p) => p.endsWith(suffix))];
}

http.Response _ok(Map<String, dynamic> data) => http.Response(
  jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

/// Asha's paper: Q205 scored 40/100, Q206 errored, Q207 an MCQ.
Assessment _paper() => Assessment.fromJson(<String, dynamic>{
  'id': '7',
  'name': 'Warehouse Safety',
  'state': 'in_progress',
  'subjective_threshold': 60.0,
  'questions': <dynamic>[
    <String, dynamic>{
      'id': 205,
      'name': 'Q7',
      'question_type': 'subjective_rubric',
    },
    <String, dynamic>{
      'id': 206,
      'name': 'Q8',
      'question_type': 'subjective_rubric',
    },
    <String, dynamic>{'id': 207, 'name': 'Q2', 'question_type': 'mcq'},
  ],
});

Attempt _asha() => Attempt.fromJson(<String, dynamic>{
  'id': '90',
  'assessment_id': '7',
  'candidate': <String, dynamic>{'id': 'p1', 'name': 'Asha'},
  'state': 'submitted',
  'answers': <dynamic>[
    <String, dynamic>{
      'question_id': 205,
      'needs_llm': true,
      'llm_state': 'scored',
      // Raw 90 against a bar of 60 earns the mark; the stored 0 is what a
      // re-grade has to overwrite, which is how the test can see it ran.
      'llm_raw_100': 90.0,
      'score': 0,
      'justification': 'The chart axes are mislabelled.',
    },
    <String, dynamic>{
      'question_id': 206,
      'needs_llm': true,
      'llm_state': 'error',
      'justification': 'The hands have six fingers.',
    },
    <String, dynamic>{
      'question_id': 207,
      'needs_llm': false,
      'llm_state': 'not_needed',
    },
  ],
});

AppStore _live(_Spy spy) =>
    AppStore(
        api: ApiClient(baseUrl: 'http://stub', client: spy.client),
      )
      ..assessments = <Assessment>[_paper()]
      ..attempts = <Attempt>[_asha()];

String _lastToast(AppStore s) => s.toaster.items.last.message;

void main() {
  group('the request names the answers', () {
    test('one answer -> question_ids: [that id]', () async {
      final _Spy spy = _Spy()
        ..canned['/attempts/90/rescore'] = _ok(<String, dynamic>{
          'queued': 1,
          'skipped': 0,
          'question_ids': <int>[205],
        });
      final AppStore s = _live(spy);

      await s.rescoreAttempt('90', questionIds: <String>['205']);

      expect(
        spy.bodyOf('/attempts/90/rescore'),
        <String, dynamic>{
          'question_ids': <int>[205],
        },
        reason:
            'the SCORED answer the admin clicked, alone - the old request '
            'named no answer and the server re-graded the unresolved ones',
      );
      expect(
        _lastToast(s),
        'Queued 1 answer(s) for re-scoring',
        reason:
            'the route queues; nothing is graded inside the click, so '
            '"re-scored" would be a claim about work not yet done',
      );
    });

    test(
      'no ids -> no question_ids key, so the server keeps its old set',
      () async {
        final _Spy spy = _Spy();
        final AppStore s = _live(spy);

        await s.rescoreAttempt('90');

        expect(spy.bodyOf('/attempts/90/rescore'), isEmpty);
        expect(_lastToast(s), 'Nothing to re-score');
      },
    );

    test(
      'an answer whose attempt is not cached still reaches the server',
      () async {
        // A Responses row can belong to an attempt outside the console's capped
        // attempts list. Returning early on the missing attempt made the button
        // do nothing at all.
        final _Spy spy = _Spy();
        final AppStore s = _live(spy)..attempts = <Attempt>[];

        await s.rescoreAttempt('91', questionIds: <String>['300']);

        expect(spy.bodyOf('/attempts/91/rescore'), <String, dynamic>{
          'question_ids': <int>[300],
        });
      },
    );
  });

  group('"Re-score queued" is shown from the click', () {
    test(
      'the chosen answer reads queued while the request is in flight',
      () async {
        final _Spy spy = _Spy()..gate = Completer<void>();
        final AppStore s = _live(spy);

        final Future<void> done = s.rescoreAttempt(
          '90',
          questionIds: <String>['205'],
        );
        await Future<void>.delayed(Duration.zero);

        final Map<String, Response> resp = s.attemptById('90')!.resp;
        expect(resp['205']!.rescoreRequested, isTrue);
        expect(
          resp['206']!.rescoreRequested,
          isFalse,
          reason: 'only the answer that was asked for is queued',
        );

        spy.gate!.complete();
        await done;
      },
    );

    test(
      'a refusal puts it back and says why, in the server\'s words',
      () async {
        final _Spy spy = _Spy()
          ..canned['/attempts/90/rescore'] = http.Response(
            jsonEncode(<String, dynamic>{
              'ok': false,
              'error': <String, dynamic>{
                'code': 'spend_limit',
                'message': 'The daily \$400 limit is reached - nothing queued.',
              },
            }),
            409,
            headers: <String, String>{'content-type': 'application/json'},
          );
        final AppStore s = _live(spy);
        // Held here because `_act` ends with a refresh that re-reads the lists.
        Response? afterRollback;
        s.toaster.addListener(() {
          afterRollback ??= s.attemptById('90')?.resp['205'];
        });

        await s.rescoreAttempt('90', questionIds: <String>['205']);

        expect(
          afterRollback?.rescoreRequested,
          isFalse,
          reason:
              'a refused request queued nothing, so the answer must not '
              'claim a re-score is on its way',
        );
        expect(_lastToast(s), contains('daily \$400 limit'));
        expect(s.toaster.items.last.tone, Tone.bad);
      },
    );
  });

  group('offline, the seed grades exactly the chosen answers', () {
    AppStore seed() => AppStore()
      ..assessments = <Assessment>[_paper()]
      ..attempts = <Attempt>[_asha()];

    test('a SCORED answer is re-graded when it is chosen', () async {
      final AppStore s = seed();

      await s.rescoreAttempt('90', questionIds: <String>['205']);

      final Map<String, Response> resp = s.attemptById('90')!.resp;
      expect(
        resp['205']!.score,
        1,
        reason:
            'raw 90 clears the bar of 60, so a re-grade writes 1 over the '
            'stored 0 - it ran on an answer that was already scored',
      );
      expect(
        resp['206']!.llmState,
        LlmState.error,
        reason: 'the errored answer was not chosen, so it is not touched',
      );
    });

    test(
      'with no ids it is still the unresolved answers, scored ones left alone',
      () async {
        final AppStore s = seed();

        await s.rescoreAttempt('90');

        final Map<String, Response> resp = s.attemptById('90')!.resp;
        expect(
          resp['205']!.score,
          0,
          reason: 'a scored answer is not unresolved',
        );
        expect(resp['206']!.llmState, LlmState.scored);
      },
    );
  });

  test(
    'Re-score This Assessment resets failed/errored answers, THEN queues',
    () async {
      final _Spy spy = _Spy()
        // The route's real shape: `requeued` is every attempt on the paper,
        // `answers_reset` the answers it reset. No `candidates` list.
        ..canned['/scoring/requeue_errored'] = _ok(<String, dynamic>{
          'requeued': 750,
          'answers_reset': 3,
          'states': <String>['failed', 'error'],
          'forced': false,
        })
        ..canned['/scoring/queue'] = _ok(<String, dynamic>{'queued': 2});
      final AppStore s = _live(spy);

      await s.rescore(_paper());

      final int reset = spy.paths.indexWhere(
        (String p) => p.endsWith('/scoring/requeue_errored'),
      );
      final int queue = spy.paths.indexWhere(
        (String p) => p.endsWith('/scoring/queue'),
      );
      expect(reset, isNot(-1), reason: 'queueing alone never clears an error');
      expect(queue, greaterThan(reset), reason: 'reset first, then queue');
      expect(spy.bodies[reset], <String, dynamic>{
        'assessment_id': '7',
        'states': <String>['failed', 'error'],
      });
      expect(spy.bodies[queue]['assessment_id'], '7');
      expect(
        _lastToast(s),
        'Reset 3 failed answer(s) and queued 2 attempt(s) for re-scoring',
      );
    },
  );
}
