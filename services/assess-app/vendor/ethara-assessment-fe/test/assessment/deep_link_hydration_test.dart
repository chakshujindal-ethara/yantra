// Cold-cache deep link into an ANSWER, against the real payload shapes.
//
// THE BUG: `_loadResponse` fetched the answer, then hit `if (ev == null) return;`
// because the attempt was not in the cache - a deep link or a browser refresh
// arrives with nothing loaded. The answer was discarded and the screen settled
// on "That answer is no longer on this attempt" over a live record. The attempt
// screen had the same shape: no fetch at all, so it claimed the attempt was
// removed.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// The three payloads the live server returns, trimmed to the keys these
/// screens read. Verified against localhost:8069 for attempt 4 / question 10.
Map<String, dynamic> payloadFor(String path) {
  if (path.contains('/attempts/')) {
    return <String, dynamic>{
      'id': '4',
      'assessment_id': '18',
      'employee_id': '2',
      'state': 'submitted',
    };
  }
  if (path.contains('/assessments/')) {
    return <String, dynamic>{
      'id': '18',
      'name': 'Forklift Safety - Induction E2E',
      'state': 'done',
      'questions': <dynamic>[
        <String, dynamic>{
          'id': '10',
          'name': 'End of Shift Parking Procedure',
          'question_type': 'subjective_rubric',
        },
      ],
    };
  }
  // The answer route embeds its question in FULL - `bank_question_detail`,
  // dimensions and answer key included - which is the only shape that carries
  // the options the screen names a pick and a key from.
  return <String, dynamic>{
    'id': '1',
    'evaluator_id': '4',
    'question_id': '10',
    'state': 'submitted',
    'justification': 'Left blank.',
    'question': <String, dynamic>{
      'id': '10',
      'name': 'End of Shift Parking Procedure',
      'question_type': 'mcq',
      'prompt': 'Where does the truck go at end of shift?',
      'dimensions': <dynamic>[
        <String, dynamic>{
          'id': '1',
          'name': 'Parking',
          'options': <dynamic>[
            <String, dynamic>{'id': '5', 'name': 'Bay 3', 'is_correct': true},
            <String, dynamic>{'id': '6', 'name': 'Anywhere'},
          ],
        },
      ],
    },
  };
}

AppStore coldStore(List<String> calls) => AppStore(
  api: ApiClient(
    client: MockClient((http.Request req) async {
      calls.add(req.url.path);
      return http.Response(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'data': payloadFor(req.url.path),
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }),
    baseUrl: 'http://x',
  ),
);

void main() {
  test('a deep-linked ANSWER hydrates its attempt and assessment', () async {
    final List<String> calls = <String>[];
    final AppStore s = coldStore(calls);

    expect(s.attempts, isEmpty);
    expect(s.assessments, isEmpty);

    await s.loadResponse('4', '10');

    expect(
      s.attemptById('4'),
      isNotNull,
      reason: 'the attempt must be fetched, not assumed',
    );
    expect(
      s.asmById('18'),
      isNotNull,
      reason: 'the question and marking scheme live on the assessment',
    );
    expect(
      s.attemptById('4')!.resp['10'],
      isNotNull,
      reason: 'the answer was fetched and then silently discarded',
    );

    // The screen can now find every piece it renders.
    final String qid = s.asmById('18')!.questions.first.id;
    expect(qid, '10');
  });

  test('a deep-linked ATTEMPT hydrates its assessment too', () async {
    final List<String> calls = <String>[];
    final AppStore s = coldStore(calls);

    await s.loadAttempt('4');

    expect(s.attemptById('4'), isNotNull);
    expect(
      s.asmById('18'),
      isNotNull,
      reason: 'without it the screen says "Assessment not found"',
    );
    expect(calls.any((String c) => c.contains('/attempts/4')), isTrue);
    expect(calls.any((String c) => c.contains('/assessments/18')), isTrue);
  });

  test('an already-cached record is not refetched', () async {
    final List<String> calls = <String>[];
    final AppStore s = coldStore(calls);

    await s.loadAttempt('4');
    final int after = calls.length;
    await s.loadResponse('4', '10');

    // Only the answer itself: the attempt and assessment are already here.
    expect(
      calls.length - after,
      1,
      reason: 'hydration must not refetch what the cache already holds',
    );
  });

  test('an answer opened from All responses finds its question', () async {
    // THE BUG: the screen resolves its question through
    // `asm.questionById(qid)` and says "That answer is no longer on this
    // attempt" when it comes back null. Reached from All responses BOTH
    // records are already cached from their list routes - so nothing was
    // refetched - and the assessment list row carries no question list at all.
    // A live answer therefore rendered as "Response not found".
    //
    // This seeds exactly that state: attempt present, assessment present but
    // hollow, which is what the console-wide read actually leaves behind.
    final List<String> calls = <String>[];
    final AppStore s = coldStore(calls);
    s.attempts = <Attempt>[
      Attempt.fromJson(<String, dynamic>{
        'id': '4',
        'assessment_id': '18',
        'state': 'submitted',
      }),
    ];
    s.assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': '18',
        'name': 'Forklift Safety - Induction E2E',
        'state': 'done',
      }),
    ];
    expect(s.asmById('18')!.questionById('10'), isNull);

    await s.loadResponse('4', '10');

    // The screen's four preconditions, in the order it checks them.
    final Attempt? ev = s.attemptById('4');
    expect(ev, isNotNull);
    final Assessment? asm = s.asmById(ev!.assessmentId);
    expect(asm, isNotNull);
    expect(
      asm!.questionById('10'),
      isNotNull,
      reason: 'the question the request already returned must be findable',
    );
    expect(ev.resp['10'], isNotNull);
  });

  test('the embedded question arrives with its options', () async {
    // Not just findable - USABLE. `bank_question_row`, which is what the
    // assessment route puts on the list, spells the dimensions as a count; the
    // panel needs the options themselves to name a pick and print a key.
    final List<String> calls = <String>[];
    final AppStore s = coldStore(calls);

    await s.loadResponse('4', '10');

    final Question q = s.asmById('18')!.questionById('10')!;
    expect(q.dims, hasLength(1));
    expect(q.dims.first.options, hasLength(2));
    expect(q.dims.first.options.where((QOption o) => o.correct), hasLength(1));
    expect(
      s.bank.any((Question x) => x.id == '10'),
      isTrue,
      reason: 'the bank gets the full record too, at no extra cost',
    );
  });

  test('merging one question does not shrink the assessment', () async {
    // The marks denominator counts `asm.questions`. Replacing the list with
    // the single question just fetched would make a ten-question paper read
    // "/ 1", which is the kind of fix that is worse than the bug.
    final List<String> calls = <String>[];
    final AppStore s = coldStore(calls);
    s.assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': '18',
        'name': 'Forklift Safety - Induction E2E',
        'state': 'done',
        'questions': <dynamic>[
          <String, dynamic>{'id': '10', 'name': 'Parking', 'sequence': 1},
          <String, dynamic>{'id': '11', 'name': 'Chocking', 'sequence': 2},
        ],
      }),
    ];

    await s.loadResponse('4', '10');

    final Assessment asm = s.asmById('18')!;
    expect(asm.questions.map((Question q) => q.id), <String>['10', '11']);
    expect(
      asm.questionById('10')!.dims,
      isNotEmpty,
      reason: 'in place, and upgraded',
    );
  });

  test('a cached assessment with NO questions is refetched', () async {
    // THE BUG: the guard was `asmById(...) == null`. The assessments LIST
    // route sends counters, not records - no `questions` - so an assessment
    // reached from anywhere but its own detail screen sits in the cache
    // present but hollow. The guard saw a record, skipped the fetch, and
    // Attempt detail's "Score details" - which walks `asm.questions` - had
    // nothing to walk and reported the candidate had answered nothing.
    //
    // Present-but-hollow is the shape that actually reaches this screen, so it
    // is the shape the guard has to test for.
    final List<String> calls = <String>[];
    final AppStore s = coldStore(calls);
    s.assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': '18',
        'name': 'Forklift Safety - Induction E2E',
        'state': 'done',
        'candidate_count': 4,
      }),
    ];
    expect(s.asmById('18')!.questions, isEmpty);

    await s.loadAttempt('4');

    expect(
      calls.any((String c) => c.contains('/assessments/18')),
      isTrue,
      reason: 'a list row cannot answer what the question list is',
    );
    expect(s.asmById('18')!.questions, isNotEmpty);
  });
}
