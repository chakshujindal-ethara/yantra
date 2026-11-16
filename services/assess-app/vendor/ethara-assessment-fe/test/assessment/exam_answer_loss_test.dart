// A candidate's answers must reach the server on submit.
//
// THE BUG. `finishExam` built its re-send set by iterating `asm.questions`.
// That list is EMPTY on a live exam - the exam payload has never carried a
// question list - so the map came out empty, which then became BOTH the
// attempt's local `resp` (wiping the answers) and the re-send set (so the
// documented "belt-and-braces" re-send posted nothing). Anything typed inside
// the 1s autosave debounce before a deadline or violation auto-submit was
// simply gone.
//
// WHY 400 TESTS MISSED IT. Every existing finishExam test injects
// `asmWith(q)`, which populates `asm.questions` - the one shape that cannot
// occur against a real server. These tests use the LIVE shape: an assessment
// with no questions, exactly what `/exam/<token>/state` returns.
import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

  /// The bodies posted to the answer route, in order.
  List<Map<String, dynamic>> get answerBodies {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (int i = 0; i < paths.length; i++) {
      if (paths[i].contains('/answer')) out.add(bodies[i]);
    }
    return out;
  }
}

AppStore _liveStore(_Spy spy) {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: spy.client),
  );
  s.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
  return s;
}

/// THE LIVE SHAPE: no `questions`, because the exam payload never sends one.
Assessment _liveAsm() =>
    Assessment(id: '7', name: 'Warehouse Safety', questions: const <Question>[]);

Attempt _attempt(Map<String, Response> resp) => Attempt(
  id: '41',
  assessmentId: '7',
  employeeId: 'P-1',
  token: 'tok',
  state: AttemptState.inProgress,
  resp: resp,
);

void main() {
  group('Submitting a live exam does not drop answers', () {
    test('every held answer is re-sent to the server', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.assessments = <Assessment>[_liveAsm()];
      store.attempts = <Attempt>[
        _attempt(<String, Response>{
          'Q1': const Response(justification: 'my written answer'),
          'Q2': const Response(lines: <String>['opt-3']),
        }),
      ];

      store.finishExam('41');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final List<Map<String, dynamic>> sent = spy.answerBodies;
      expect(
        sent.length,
        2,
        reason:
            'both answers must be re-sent; the re-send set was built from '
            'asm.questions, which is empty on a live exam, so it sent none',
      );
      final String all = jsonEncode(sent);
      expect(all, contains('my written answer'));
      expect(all, contains('opt-3'));
    });

    test('the local answers survive the submit', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.assessments = <Assessment>[_liveAsm()];
      store.attempts = <Attempt>[
        _attempt(<String, Response>{
          'Q1': const Response(justification: 'my written answer'),
        }),
      ];

      // Checked SYNCHRONOUSLY, on purpose. finishExam rewrites the local
      // attempt and only then fires its network work unawaited, ending in
      // `refresh()` - which, against a stub that returns no data, legitimately
      // clears the store. The wipe under test is the local rewrite, so this
      // asserts before any of that runs.
      store.finishExam('41');

      final Attempt? after = store.attemptById('41');
      expect(after, isNotNull);
      expect(
        after!.resp.containsKey('Q1'),
        isTrue,
        reason:
            'the attempt was rewritten with the empty graded map, so the '
            'candidate saw their own answers disappear on submit',
      );
      expect(after.resp['Q1']!.justification, 'my written answer');
    });

    test('the submit still runs', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.assessments = <Assessment>[_liveAsm()];
      store.attempts = <Attempt>[
        _attempt(<String, Response>{
          'Q1': const Response(justification: 'answer'),
        }),
      ];

      store.finishExam('41');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(spy.hit('/api/v1/exam/tok/submit'), isTrue);
    });

    test('an auto-submit re-sends too', () async {
      // The deadline and violation paths are the ones where a pending
      // debounce is most likely to still be in flight, so they are exactly
      // where a dropped re-send costs the candidate their last answer.
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.assessments = <Assessment>[_liveAsm()];
      store.attempts = <Attempt>[
        _attempt(<String, Response>{
          'Q1': const Response(justification: 'typed just before the bell'),
        }),
      ];

      store.finishExam('41', auto: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        jsonEncode(spy.answerBodies),
        contains('typed just before the bell'),
      );
    });
  });
}
