// What the candidate is told when the clock runs out under their fingers.
//
// `/answer` saves the answer in flight BEFORE it enforces the deadline, then
// answers 409 `time_expired` with an `answer_saved` flag. `examAdvance`'s catch
// used to swallow EVERY 409 into `_markExamComplete` with no toast, so the
// candidate heard nothing at the buzzer. Now every time-up path says
// `AppStore.timeUpMessage` (Q12), and `answer_saved: false` adds that the last
// change reached the server after the deadline and may not count - never "not
// saved", because the server still settles and grades a held draft (G2-05).
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

const String kToken = 'tok-1';

const String kSaved =
    'Your time has expired; the attempt was submitted and your last answer '
    'was saved.';
const String kDropped =
    'Your time has expired; the attempt was submitted, but your last answer '
    'was incomplete and was not saved.';
const String kLate =
    'Your time has expired; the attempt was submitted, but your last answer '
    'arrived after the deadline and was not saved.';

/// The module's own 409, with the flag it carries beside the sentence.
http.Client _expired({required bool answerSaved, String? message}) =>
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
          'error': <String, dynamic>{
            'code': 'time_expired',
            'message': message ?? (answerSaved ? kSaved : kDropped),
          },
          'answer_saved': answerSaved,
        }),
        409,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

AppStore _store({required bool answerSaved, String? message}) {
  final AppStore s = AppStore(
    api: ApiClient(
      client: _expired(answerSaved: answerSaved, message: message),
      baseUrl: 'https://example.invalid',
      bearer: 't',
    ),
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': 1,
      'access_token': kToken,
      'assessment_id': 55,
      'state': 'in_progress',
      'total_questions': 3,
    }),
  ];
  return s;
}

void main() {
  test('the buzzer says the answer was kept', () async {
    final AppStore s = _store(answerSaved: true);

    final bool done = await s.examAdvance(
      kToken,
      '10',
      const Response(justification: 'Forks lowered, brake on.'),
    );

    // Still settled onto the completion screen - that part was never wrong.
    expect(done, isTrue);

    // Q12: one sentence on every time-up path, in place of the server's.
    final List<ToastMsg> toasts = s.toaster.items;
    expect(toasts.single.message, AppStore.timeUpMessage);
    expect(
      toasts.single.tone,
      isNot(Tone.bad),
      reason: 'the answer WAS saved - that is not a failure',
    );
  });

  test('an incomplete last answer is said plainly, not as lost work', () async {
    final AppStore s = _store(answerSaved: false);

    await s.examAdvance(kToken, '10', const Response(lines: <String>['o-a']));

    // G2-05: the server still settles and grades a held draft, so "not saved"
    // in red was wrong.
    final List<ToastMsg> toasts = s.toaster.items;
    expect(toasts.map((ToastMsg m) => m.message), <String>[
      AppStore.timeUpMessage,
      AppStore.timeUpIncompleteMessage,
    ]);
    expect(toasts.map((ToastMsg m) => m.tone), isNot(contains(Tone.bad)));
    expect(
      toasts.map((ToastMsg m) => m.message).join(' '),
      isNot(contains('not saved')),
    );
  });

  test('a change past the 10s grace is not called incomplete', () async {
    // Past the grace the server stores nothing and says the answer ARRIVED
    // LATE. The line must be true of that as well as of an incomplete one.
    final AppStore s = _store(answerSaved: false, message: kLate);

    await s.examAdvance(
      kToken,
      '10',
      const Response(justification: 'Typed behind the overlay.'),
    );

    final List<String> said = s.toaster.items
        .map((ToastMsg m) => m.message)
        .toList();
    expect(said, <String>[
      AppStore.timeUpMessage,
      AppStore.timeUpIncompleteMessage,
    ]);
    expect(said.join(' '), isNot(contains('incomplete')));
    expect(said.join(' '), contains('after the deadline'));
    expect(
      s.toaster.items.map((ToastMsg m) => m.tone),
      isNot(contains(Tone.bad)),
    );
  });
}
