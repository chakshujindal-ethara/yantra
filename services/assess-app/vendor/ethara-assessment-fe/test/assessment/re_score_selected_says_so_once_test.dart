// "Re-score N selected" is one action, so it says so once.
//
// THE BUG. The Responses screen sends one request per candidate - right, the
// route takes one attempt - but each went through the single-attempt action,
// so ticking answers across seven candidates fired seven toasts and seven
// full background refreshes. The operator read a stack of "Queued 1 answer(s)"
// and the console re-walked every list seven times.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

/// Every rescore queues what it was asked for, except attempt 92's, which the
/// server refuses with a spend limit.
class _Server {
  final List<String> paths = <String>[];

  http.Client get client => MockClient((http.Request req) async {
    paths.add(req.url.path);
    if (req.url.path.endsWith('/attempts/92/rescore')) {
      return _json(<String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{
          'code': 'spend_limit',
          'message': 'The daily \$400 limit is reached - nothing queued.',
        },
      }, 409);
    }
    if (req.url.path.endsWith('/rescore')) {
      final Object? ids = (jsonDecode(req.body) as Map)['question_ids'];
      return _json(<String, dynamic>{
        'ok': true,
        'data': <String, dynamic>{'queued': ids is List ? ids.length : 0},
      });
    }
    return _json(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}});
  });

  /// One per store refresh: every refresh starts with the assessments list.
  int get refreshes =>
      paths.where((String p) => p.endsWith('/assessments')).length;
}

Attempt _attempt(String id) => Attempt.fromJson(<String, dynamic>{
  'id': id,
  'assessment_id': '7',
  'state': 'submitted',
  'answers': <dynamic>[
    for (final int q in <int>[205, 206])
      <String, dynamic>{
        'question_id': q,
        'needs_llm': true,
        'llm_state': 'scored',
      },
  ],
});

AppStore _live(_Server server) =>
    AppStore(
        api: ApiClient(baseUrl: 'http://stub', client: server.client),
      )
      ..assessments = <Assessment>[
        Assessment.fromJson(<String, dynamic>{'id': '7', 'name': 'Paper'}),
      ]
      ..attempts = <Attempt>[_attempt('90'), _attempt('91'), _attempt('92')];

void main() {
  test('three candidates: one summary toast, one refresh', () async {
    final _Server server = _Server();
    final AppStore s = _live(server);

    await s.rescoreAnswers(<String, List<String>>{
      '90': <String>['205', '206'],
      '91': <String>['205'],
    });

    expect(
      server.paths.where((String p) => p.endsWith('/rescore')).length,
      2,
      reason: 'still one request per candidate',
    );
    expect(s.toaster.items.map((m) => m.message), <String>[
      'Queued 3 answer(s) for re-scoring across 2 candidate(s)',
    ]);
    expect(server.refreshes, 1);
  });

  test('a refusal is in the one toast, in the server\'s words', () async {
    final _Server server = _Server();
    final AppStore s = _live(server);
    // Held at the toast: the trailing refresh re-reads the (empty) stub lists.
    Map<String, bool>? queuedAtToast;
    s.toaster.addListener(() {
      queuedAtToast ??= <String, bool>{
        for (final String id in <String>['90', '91', '92'])
          id: s.attemptById(id)!.resp['205']!.rescoreRequested,
      };
    });

    await s.rescoreAnswers(<String, List<String>>{
      '90': <String>['205'],
      '91': <String>['205'],
      '92': <String>['205'],
    });

    expect(s.toaster.items, hasLength(1));
    expect(s.toaster.items.single.tone, Tone.bad);
    expect(
      s.toaster.items.single.message,
      'Queued 2 answer(s) for re-scoring across 2 candidate(s); 1 '
      'candidate(s) not queued: The daily \$400 limit is reached - nothing '
      'queued.',
    );
    expect(queuedAtToast, <String, bool>{
      '90': true,
      '91': true,
      '92': false,
    }, reason: 'only the refused candidate\'s mark goes back');
    expect(server.refreshes, 1);
  });
}
