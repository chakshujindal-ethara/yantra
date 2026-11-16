// The AI watch's latest status reaches the server (R9d).
//
// The bridge reports how it stands once per start, and the store posted that
// once with `.ignore()`. A `failed` lost on the wire (it is emitted just
// before the bridge stops, so nothing follows it) left the admin with no
// "AI proctoring could not start" line, which is what the status is for. Now
// the latest status is kept until the server takes it, tried again a few
// times, and never overtaken by an older one still on the wire.
library;

import 'dart:async';
import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// `/ai-status` drops [lose] requests on the wire, refuses every one with a
/// 409 when [refuse], holds the first reply on [hold], and records each status the server TOOK, in the order it took them.
class _Rig {
  _Rig({this.lose = 0, this.hold, this.refuse = false, this.garble = false}) {
    store = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        maxAttempts: 1,
        client: MockClient((http.Request req) async {
          if (req.url.path.endsWith('/ai-status')) {
            final String status =
                (jsonDecode(req.body) as Map<String, dynamic>)['status']
                    as String;
            tries++;
            if (lose > 0) {
              lose--;
              throw http.ClientException('Failed to fetch');
            }
            if (garble) {
              return http.Response(
                '[1]',
                200,
                headers: <String, String>{'content-type': 'application/json'},
              );
            }
            if (refuse) {
              return http.Response(
                jsonEncode(<String, dynamic>{
                  'ok': false,
                  'error': <String, dynamic>{
                    'code': 'attempt_locked',
                    'message': 'This attempt is closed.',
                  },
                }),
                409,
                headers: <String, String>{'content-type': 'application/json'},
              );
            }
            final Completer<void>? h = hold;
            hold = null;
            await h?.future;
            taken.add(status);
          }
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
      violationRetry: const Duration(milliseconds: 5),
    );
    store.assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': 18,
        'name': 'L1 Screening',
        'state': 'in_progress',
      }),
    ];
    store.attempts = <Attempt>[
      Attempt.fromJson(<String, dynamic>{
        'id': 7,
        'assessment_id': 18,
        'access_token': 'tok',
        'state': 'in_progress',
      }),
    ];
    addTearDown(store.dispose);
  }

  int lose;
  final bool refuse;

  /// Answers with JSON that is no envelope at all.
  final bool garble;
  Completer<void>? hold;
  int tries = 0;
  final List<String> taken = <String>[];
  late final AppStore store;

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 200));
}

void main() {
  test('a status lost on the wire is sent again', () async {
    final _Rig rig = _Rig(lose: 1);
    rig.store.reportAiStatus('tok', 'failed');
    await rig.settle();
    expect(rig.taken, <String>['failed']);
  });

  test('an older status still on the wire never lands last', () async {
    final Completer<void> hold = Completer<void>();
    final _Rig rig = _Rig(hold: hold);
    rig.store.reportAiStatus('tok', 'running');
    await pumpEventQueue();
    rig.store.reportAiStatus('tok', 'failed');
    await pumpEventQueue();
    hold.complete();
    await rig.settle();
    expect(rig.taken.last, 'failed');
  });

  test('the retries are bounded', () async {
    final _Rig rig = _Rig(lose: 100);
    rig.store.reportAiStatus('tok', 'failed');
    await rig.settle();
    expect(rig.taken, isEmpty);
    expect(rig.tries, 3);
  });

  test('a refusal is the answer: not sent again', () async {
    final _Rig rig = _Rig(refuse: true);
    rig.store.reportAiStatus('tok', 'failed');
    await rig.settle();
    expect(rig.tries, 1);
  });

  test('a newer status is not held behind one that never answers', () async {
    final _Rig rig = _Rig(hold: Completer<void>()); // never completed
    rig.store.reportAiStatus('tok', 'running');
    await pumpEventQueue();
    rig.store.reportAiStatus('tok', 'failed');
    await rig.settle();
    expect(rig.taken, <String>['failed']);
  });

  test('an unreadable reply is logged, not thrown', () async {
    final _Rig rig = _Rig(garble: true);
    rig.store.reportAiStatus('tok', 'failed');
    await rig.settle();
    expect(rig.tries, 1);
  });
}
