// The debounced autosave must not call a safely-stored draft a failure.
//
// THE BUG. The autosave fires five seconds after any keystroke or pick, once
// `Response.hasInput` is true - one option is enough. For an image_ab question
// with "require justification" on, `_record_response` HOLDS that answer as a
// draft and returns False, which the route turns into 422 `incomplete_answer`.
// The client toasted the server's sentence in destructive red, mid-answer, over
// an answer the server had safely stored - and `_answerSent` is only written on
// acceptance, so it fired again on the next change. A candidate answering an
// A/B question the natural way (verdicts first, write-up second) got a red
// error per pause, which during a timed exam reads as data loss.
//
// `examAdvance` surfaces the real refusal when it matters - pressing Next -
// and `completeness_gate_mirrors_server_test` pins that gate. This file pins
// the QUIET path: a draft hold is not an error.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

const Duration _debounce = Duration(milliseconds: 200);
const Duration _maxWait = Duration(milliseconds: 600);

/// Comfortably past [_debounce], so a pending save has certainly gone.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 700));

/// The route's refusal for an answer it has parked as a draft, and its
/// refusal for something genuinely broken.
http.Client _refusing({required String code, required String message}) =>
    MockClient((http.Request req) async {
      if (!req.url.path.endsWith('/answer')) {
        return http.Response(
          jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{'code': code, 'message': message},
        }),
        // A 4xx either way: a 5xx goes through the retry ladder, which is a
        // different test (`retry_ladder_test`) and would outlive this one.
        code == 'incomplete_answer' ? 422 : 400,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

AppStore _store({required String code, required String message}) {
  final AppStore s = AppStore(
    api: ApiClient(
      client: _refusing(code: code, message: message),
      baseUrl: 'https://example.invalid',
      bearer: 't',
    ),
    answerDebounce: _debounce,
    answerMaxWait: _maxWait,
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
  return s;
}

void main() {
  test('a held draft raises no alarm on the candidate', () async {
    final AppStore s = _store(
      code: 'incomplete_answer',
      message: 'This answer is incomplete for its question type',
    );

    // The verdict is picked; the write-up is not typed yet.
    s.saveAnswerQuiet('1', '10', const Response(lines: <String>['o-a']));
    await _settle();

    expect(
      s.toaster.items.map((ToastMsg m) => m.message).join(' | '),
      isEmpty,
      reason:
          'the server stored it as a draft; nothing has gone wrong yet, and '
          'the runner refuses the same answer at Next where it matters',
    );
  });

  test('a real autosave failure is still reported', () async {
    final AppStore s = _store(
      code: 'bad_request',
      message: 'Something went wrong.',
    );

    s.saveAnswerQuiet('1', '10', const Response(justification: 'Forks down.'));
    await _settle();

    expect(
      s.toaster.items.map((ToastMsg m) => m.message).join(' | '),
      isNotEmpty,
      reason:
          'answers failing to land is exactly what the one-per-sitting '
          'warning exists for',
    );
  });
}
