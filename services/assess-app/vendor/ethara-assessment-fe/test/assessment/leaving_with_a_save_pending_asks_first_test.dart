// Leaving the page within a second of typing lost the typing.
//
// The page-hide flush started the `/answer` fetch, and the browser cancelled
// it as the page unloaded (browser Back, another URL). Now, while any answer
// save is debounced or in flight, the page holds a `beforeunload` handler that
// flushes and asks "Leave site?" - and lets go the moment nothing is pending.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

void main() {
  test('the page is held exactly while a save is pending', () async {
    final List<String> posts = <String>[];
    Completer<void> reply = Completer<void>();
    // Each change of hold: the flush to run on `beforeunload`, or null.
    final List<void Function()?> holds = <void Function()?>[];

    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        bearer: 't',
        client: MockClient((http.Request req) async {
          posts.add(req.url.path.split('/').last);
          await reply.future;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
      answerDebounce: const Duration(minutes: 5),
      leaveGuard: holds.add,
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
      }),
    ];
    expect(holds, isEmpty, reason: 'nothing pending, nothing held');

    // Typed: debounced, so the page is held.
    s.saveAnswerQuiet('1', 'q1', Response(justification: 'just typed'));
    expect(holds, hasLength(1));
    expect(holds.single, isNotNull);

    // Leaving: the handler flushes, and the fetch is in flight - still held.
    holds.single!();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(posts, <String>['answer']);
    expect(holds, hasLength(1), reason: 'in flight is still pending');

    // Answered: nothing pending, so the page lets go.
    reply.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(holds, hasLength(2));
    expect(holds.last, isNull);

    // Typed again, then the exam ends: the hold goes with it.
    reply = Completer<void>()..complete();
    s.saveAnswerQuiet('1', 'q1', Response(justification: 'more'));
    expect(holds.last, isNotNull);
    s.dispose();
    expect(holds.last, isNull);
  });
}
