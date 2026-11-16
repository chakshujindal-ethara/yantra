// Auto-submit at the limit threw away the answer the candidate had just given.
//
// Repro (product test, limit 2): pick an answer on Q2, then two tab switches
// inside the autosave debounce. The second violation ended the sitting, and
// `_endForViolation` cancelled the pending autosave - so no `/answer` was ever
// sent, the server blanked Q2 with its auto-submit placeholder, and the
// completion screen still said "Your answers were kept as they stood."
//
// The ending `/violation` now flushes the pending autosaves FIRST, and only
// posts once they are answered - so the server ends a paper that already holds
// the answer. A refused flush is not claimed as kept.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// Records every POST path in order; `/answer` answers [answerOk].
class _Backend extends http.BaseClient {
  final bool answerOk;
  final List<String> paths = <String>[];

  _Backend({this.answerOk = true});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final String path = request.url.path;
    paths.add(path);
    final Map<String, dynamic> payload;
    if (path.endsWith('/answer')) {
      payload = answerOk
          ? <String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{'saved': true},
            }
          : <String, dynamic>{
              'ok': false,
              'error': <String, dynamic>{
                'code': 'incomplete_answer',
                'message': 'This answer is incomplete for its question type',
              },
            };
    } else if (path.endsWith('/violation')) {
      // The server's own count: the second report reaches the cap of 2.
      // Reports go one at a time now (BR-D15), so the first reply comes back
      // before the second report is sent.
      final int count = paths
          .where((String p) => p.endsWith('/violation'))
          .length;
      payload = <String, dynamic>{
        'ok': true,
        'data': <String, dynamic>{
          'violation_count': count,
          'attempt_ended': count >= 2,
        },
      };
    } else {
      payload = <String, dynamic>{'ok': true, 'data': <String, dynamic>{}};
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      answerOk || !path.endsWith('/answer') ? 200 : 422,
      headers: <String, String>{'content-type': 'application/json'},
      request: request,
    );
  }
}

AppStore _store(_Backend backend) {
  final AppStore s = AppStore(
    api: ApiClient(client: backend, baseUrl: 'https://x.invalid', bearer: 't'),
    // Long enough that only a flush can send the answer inside this test.
    answerDebounce: const Duration(seconds: 30),
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': 1,
      'access_token': 'tok-1',
      'assessment_id': 55,
      'state': 'in_progress',
      'total_questions': 3,
    }),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 55,
      'name': 'Paper',
      'state': 'in_progress',
      'violation_action': 'auto_submit',
      'max_violations': 2,
    }),
  ];
  return s;
}

Future<void> _twoViolations(AppStore s) async {
  // Read on every change: the re-read after the ending replaces the rows.
  bool ended = false;
  void watch() => ended |= s.attemptById('1')?.isDone ?? false;
  s.addListener(watch);
  s.saveAnswerQuiet('1', 'q2', Response(lines: <String>['7']));
  expect(s.recordViolation('1', 'Tab switched / window hidden'), isFalse);
  // Live, the sitting ends on the server's `attempt_ended`, not before the
  // report has even gone out.
  expect(s.recordViolation('1', 'Exited fullscreen'), isFalse);
  expect(s.attemptById('1')!.isDone, isFalse);
  await Future<void>.delayed(const Duration(milliseconds: 60));
  expect(ended, isTrue, reason: 'the reply ended it');
  s.removeListener(watch);
}

void main() {
  test('the ending violation saves the pending answer, then posts', () async {
    final _Backend backend = _Backend();
    final AppStore s = _store(backend);

    await _twoViolations(s);

    final List<String> order = backend.paths
        .map((String p) => p.split('/').last)
        .toList();
    expect(order, contains('answer'), reason: 'the pending answer was sent');
    expect(
      order.indexOf('answer'),
      lessThan(order.lastIndexOf('violation')),
      reason: 'the answer must reach the server before the report that ends it',
    );
    expect(s.unsavedAtEnd, isEmpty);
  });

  test('a refused flush is not claimed as kept', () async {
    final _Backend backend = _Backend(answerOk: false);
    final AppStore s = _store(backend);

    await _twoViolations(s);

    // Tried before each report on an auto-submit paper (BR-D15 review,
    // P3-4), not only before the one this device counted as the last: a
    // refused save stays unsent, so it goes again before the second.
    expect(
      backend.paths.where((String p) => p.endsWith('/answer')),
      hasLength(2),
    );
    expect(s.unsavedAtEnd, contains('1'));
  });
}
