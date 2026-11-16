// "Reset & re-score errored (N)" leaves cancelled papers out.
//
// THE BUG: the org-wide sweep gathered errored attempts from EVERY paper, and
// the server refuses to re-score one on a cancelled paper - so a single
// errored candidate on a cancelled paper made the whole press do nothing,
// while the button kept counting that candidate's answers.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Assessment _paper(String id, AsmState state) => Assessment(
  id: id,
  name: 'Paper $id',
  state: state,
  questions: <Question>[
    Question.fromJson(<String, dynamic>{
      'id': 'q-$id',
      'question_type': 'subjective_rubric',
    }),
  ],
);

Attempt _errored(String id, String asmId) => Attempt(
  id: id,
  assessmentId: asmId,
  employeeId: 'p$id',
  token: 't$id',
  state: AttemptState.submitted,
  resp: <String, Response>{
    'q-$asmId': const Response(llmState: LlmState.error),
  },
);

void main() {
  test('a cancelled paper is neither counted nor sent', () async {
    Map<String, dynamic> sent = <String, dynamic>{};
    final http.Client client = MockClient((http.Request req) async {
      final bool sweep = req.url.path.endsWith('/requeue_errored');
      if (sweep) sent = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'data': sweep
              ? <String, dynamic>{'answers_reset': 1, 'skipped': 1}
              : <String, dynamic>{},
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final AppStore s =
        AppStore(api: ApiClient(baseUrl: 'http://stub', client: client))
          ..assessments = <Assessment>[
            _paper('1', AsmState.inProgress),
            _paper('2', AsmState.cancelled),
          ]
          ..attempts = <Attempt>[_errored('90', '1'), _errored('91', '2')];

    expect(s.scoringErrorCount, 1);

    await s.requeueErrored();

    expect(sent['evaluator_ids'], <String>['90']);
    // Cancelled papers never reach the server now, so its `skipped` counts
    // the ones whose Kill is still stopping too (L1) - the toast names both.
    expect(
      s.toaster.items.last.message,
      'Reset and queued 1 errored answer(s), skipped 1 candidate(s) on '
      'cancelled or stopping papers',
    );
  });
}
