// Every "reset" toast counts ANSWERS reset - never `requeued`.
//
// THE BUG. `/scoring/requeue_errored` answers `requeued: len(evaluators)`: the
// ATTEMPTS it swept, which with `assessment_id` is every attempt on the paper.
// Three toasts read it as answers, so "Re-score This Assessment" on a
// 750-candidate paper with three errored answers said "Reset 750 failed
// answer(s)". The server now also answers `answers_reset`; an older one does
// not, and then no toast may put a number on the answers at all.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// Answers `/scoring/requeue_errored` with [reset] and `/scoring/queue` with
/// two queued attempts; everything else `{}`.
AppStore _live(Map<String, dynamic> reset) {
  final http.Client client = MockClient((http.Request req) async {
    final Map<String, dynamic> data = req.url.path.endsWith('/requeue_errored')
        ? reset
        : req.url.path.endsWith('/scoring/queue')
        ? <String, dynamic>{'queued': 2}
        : <String, dynamic>{};
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
  return AppStore(
      api: ApiClient(baseUrl: 'http://stub', client: client),
    )
    ..assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{'id': '7', 'name': 'Paper'}),
    ];
}

/// The new server: 750 attempts on the paper, three answers actually reset.
const Map<String, dynamic> _now = <String, dynamic>{
  'requeued': 750,
  'answers_reset': 3,
  'states': <String>['failed', 'error'],
  'forced': false,
};

/// A server from before `answers_reset`: the attempt count and nothing else.
const Map<String, dynamic> _old = <String, dynamic>{
  'requeued': 750,
  'states': <String>['failed', 'error'],
  'forced': false,
};

String _toast(AppStore s) => s.toaster.items.last.message;

void main() {
  group('Re-score This Assessment', () {
    test('names the answers reset, not the attempts swept', () async {
      final AppStore s = _live(_now);
      await s.rescore(s.assessments.single);
      expect(
        _toast(s),
        'Reset 3 failed answer(s) and queued 2 attempt(s) for re-scoring',
      );
    });

    test('an older server: no reset count rather than a wrong one', () async {
      final AppStore s = _live(_old);
      await s.rescore(s.assessments.single);
      expect(_toast(s), 'Queued 2 attempt(s) for re-scoring');
    });
  });

  group('Score Failed Responses (assessment_id)', () {
    test('names the answers reset', () async {
      final AppStore s = _live(_now);
      await s.requeueFailedFor(assessmentId: '7');
      expect(_toast(s), 'Reset and queued 3 failed answer(s)');
    });

    test('none reset says so', () async {
      final AppStore s = _live(<String, dynamic>{..._now, 'answers_reset': 0});
      await s.requeueFailedFor(assessmentId: '7');
      expect(_toast(s), 'Nothing is in a failed state');
    });

    test('an older server: no count, since 750 is the whole paper', () async {
      final AppStore s = _live(_old);
      await s.requeueFailedFor(assessmentId: '7');
      expect(_toast(s), isNot(contains('750')));
      expect(_toast(s), 'Reset and queued any failed answers');
    });
  });

  group('Reset & re-score errored (evaluator_ids)', () {
    test('names the answers reset', () async {
      final AppStore s = _live(_now);
      await s.requeueErrored(attemptIds: <String>['90', '91']);
      expect(_toast(s), 'Reset and queued 3 errored answer(s)');
    });

    test('an older server: `requeued` is the candidates named', () async {
      final AppStore s = _live(<String, dynamic>{..._old, 'requeued': 2});
      await s.requeueErrored(attemptIds: <String>['90', '91']);
      expect(_toast(s), 'Reset and queued errored answers on 2 candidate(s)');
    });
  });
}
