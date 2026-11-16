// A RATE-LIMITED SIGN-IN HAS TO HOLD THE DOOR SHUT.
//
// On 2026-09-17 a cohort hit the gateway's sign-in limiter. The server answered
// correctly - 429, `Retry-After: 60`, and a sentence saying the password was
// not the problem - and the client threw half of it away: `Session.signIn`'s
// `on ApiError` kept `e.message` and dropped `e.status` and `e.retryAfter`. So
// `busy` went false on the same frame, Sign in was live again, and "Forgot
// password?" sat directly under the field with nothing stopping it. 679 reset
// emails went out for a problem no password could fix.
//
// `parseRetryAfter` was never the bug and is covered in `retry_ladder_test`;
// these tests are about what `Session` does with what it already parsed.
//
// The negative control for this file is the pre-fix behaviour itself: every
// assertion below reads `cooldownSeconds` or `errorStatus`, neither of which
// survived `signIn` before the fix, so the file cannot pass against the old
// code at all.
import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/session.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The gateway's own refusal: 429, and the header that says for how long.
const String _refusal =
    'Too many sign-in attempts from this address. Your password is not the '
    'problem - wait and try again.';

Session _session({String? retryAfter = '60'}) => Session(
  api: ApiClient(
    baseUrl: 'http://stub',
    client: MockClient(
      (http.Request req) async => http.Response(
        jsonEncode(<String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'rate_limited',
            'message': _refusal,
          },
        }),
        429,
        headers: <String, String>{
          'content-type': 'application/json',
          'retry-after': ?retryAfter,
        },
      ),
    ),
  ),
);

void main() {
  testWidgets('a 429 carries its status and its wait out of signIn', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final Session s = _session();
    addTearDown(s.dispose);

    expect(await s.signIn('ada@ethara.ai', 'hunter2'), isFalse);

    expect(s.error, _refusal, reason: "the server's sentence still survives");
    expect(
      s.errorStatus,
      429,
      reason:
          'WHAT KIND of refusal, not just its words - a caller cannot tell '
          'a rate limit from a wrong password by reading prose',
    );
    expect(
      s.cooldownSeconds,
      60,
      reason:
          'the header said 60 and the form has to be able to ask for it '
          'without string-matching the message',
    );
    expect(s.busy, isFalse, reason: 'the request is over; the wait is not');

    await tester.pump(const Duration(seconds: 61));
  });

  testWidgets('the cooldown counts down and expires on its own', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final Session s = _session(retryAfter: '3');
    addTearDown(s.dispose);

    int notifications = 0;
    s.addListener(() => notifications++);
    await s.signIn('ada@ethara.ai', 'hunter2');
    notifications = 0;

    await tester.pump(const Duration(seconds: 1));
    expect(s.cooldownSeconds, 2);
    expect(
      notifications,
      1,
      reason:
          'a countdown nobody is told about cannot '
          'be drawn as a countdown',
    );

    await tester.pump(const Duration(seconds: 1));
    expect(s.cooldownSeconds, 1);

    await tester.pump(const Duration(seconds: 1));
    expect(
      s.cooldownSeconds,
      0,
      reason:
          'NOTHING ELSE TICKS THIS. Without a timer of its own the door '
          'stays shut until the page is reloaded, which is the same dead end '
          'as never shutting it',
    );
    expect(notifications, 3);

    // Past the end: it must not run negative and must not keep firing.
    await tester.pump(const Duration(seconds: 5));
    expect(s.cooldownSeconds, 0);
    expect(notifications, 3, reason: 'the timer cancelled itself');
  });

  testWidgets('a 429 with no usable Retry-After does NOT invent a wait', (
    WidgetTester tester,
  ) async {
    // `parseRetryAfter` already turns absent, 0, negative and unparseable into
    // null. The only thing worth pinning here is that `Session` treats null as
    // "no cooldown" rather than as "wait forever" - a locked-out front door
    // with no countdown and no expiry is a worse bug than the one being fixed.
    await tester.pumpWidget(const SizedBox.shrink());
    for (final String? header in <String?>[null, '0', '-5', 'soon', '99999']) {
      final Session s = _session(retryAfter: header);
      addTearDown(s.dispose);
      await s.signIn('ada@ethara.ai', 'hunter2');
      expect(
        s.cooldownSeconds,
        0,
        reason: 'retry-after: ${header ?? '<absent>'} must leave the door open',
      );
      expect(s.errorStatus, 429, reason: 'the status still comes through');
    }
  });

  testWidgets('a cooldown is cancelled on dispose', (
    WidgetTester tester,
  ) async {
    // If the periodic timer outlives the session, this test fails with "a
    // Timer is still pending" - which in the app is a notify against a
    // disposed notifier.
    await tester.pumpWidget(const SizedBox.shrink());
    final Session s = _session(retryAfter: '300');
    await s.signIn('ada@ethara.ai', 'hunter2');
    expect(s.cooldownSeconds, 300);
    s.dispose();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a sign-in that succeeds clears a cooldown left behind', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    bool refuse = true;
    final Session s = Session(
      api: ApiClient(
        baseUrl: 'http://stub',
        client: MockClient((http.Request req) async {
          if (refuse) {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': false,
                'error': <String, dynamic>{'message': _refusal},
              }),
              429,
              headers: const <String, String>{'retry-after': '60'},
            );
          }
          if (req.url.path.endsWith('/auth/me')) {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': true,
                'data': <String, dynamic>{
                  'user': <String, dynamic>{'role': 'admin', 'uid': '7'},
                },
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{'access_token': 'tok'},
            }),
            200,
          );
        }),
      ),
    );
    addTearDown(s.dispose);

    await s.signIn('ada@ethara.ai', 'hunter2');
    expect(s.cooldownSeconds, 60);

    // The limiter's window is the SERVER's to end - a candidate who gets in on
    // a second device, or whose limit was lifted, must not be left staring at
    // a countdown the server has already forgotten about.
    refuse = false;
    expect(await s.signIn('ada@ethara.ai', 'hunter2'), isTrue);
    expect(s.cooldownSeconds, 0);
    expect(s.errorStatus, isNull);
  });
}
