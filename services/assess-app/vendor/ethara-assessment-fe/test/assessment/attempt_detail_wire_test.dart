// Attempt detail parses what `GET /api/v1/attempts/<id>` ACTUALLY sends.
//
// THE BUG THIS EXISTS FOR. The screen's "Score details" grid marks one row per
// answer, joining `asm.questions` to `ev.resp`. Neither side of that join was
// ever filled from this route:
//
//   - the answers arrive as a LIST under `answers`, and `Attempt.fromJson`
//     read only a MAP under `resp`, so `ev.resp` parsed empty;
//   - the grader's audit arrives under `grading`, and `Response.fromJson` read
//     only `judge`, so every live answer looked ungraded.
//
// The result was a grid reading "This candidate has not answered anything yet."
// underneath a header reading 10 / 10 answered, on an attempt the server had
// sent in full.
//
// The payloads below are the module's own shapes - `S.response_audit` and
// `S.evaluator_admin_row` in `controllers/api/serializers.py` - so a rename on
// either side fails here rather than blanking a screen.
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

/// One `response_audit` row, trimmed to the keys the screen reads.
Map<String, dynamic> audit({
  required int questionId,
  int score = 1,
  String llmState = 'scored',
  double? raw100,
  Map<String, dynamic>? grading,
}) => <String, dynamic>{
  'id': questionId * 10,
  'evaluator_id': 80,
  'question_id': questionId,
  'question_name': 'Q$questionId',
  'question_type': 'subjective_rubric',
  'state': 'submitted',
  'score': score,
  'max_score': 1,
  'llm_state': llmState,
  'llm_raw_100': raw100 ?? 0.0,
  'justification': 'because',
  'lines': <dynamic>[],
  // ALWAYS present on this route, graded or not. That is the whole reason the
  // parser cannot treat presence as evidence of a grading.
  'grading':
      grading ??
      <String, dynamic>{
        'gate': '',
        'profile': '',
        'verdict': '',
        'feedback': '',
        'reasoning': '',
        'reference_answer': '',
        'rubric_source': '',
        'judge_model': '',
        'attempts': 0,
        'key_closeness': 0.0,
        'sop_coverage': 0.0,
        'clarity': '',
        'ai_confidence': '',
        'verdict_consistency': '',
        'deductions': <dynamic>[],
        'credit': <dynamic>[],
        'golden_claims': <dynamic>[],
        'flags': <dynamic>[],
        'result': <String, dynamic>{},
      },
};

void main() {
  group('The answers land in resp', () {
    test('an `answers` list becomes a map keyed by question id', () {
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': 80,
        'assessment_id': 7,
        'state': 'submitted',
        'answered_count': 2,
        'answers': <dynamic>[
          audit(questionId: 11, score: 1),
          audit(questionId: 12, score: 0),
        ],
      });

      expect(
        ev.resp.keys.toSet(),
        <String>{'11', '12'},
        reason:
            'the grid asks the attempt for each question by id; keyed any '
            'other way the join finds nothing and the grid renders empty',
      );
      expect(ev.resp['11']!.score, 1);
      expect(ev.resp['12']!.score, 0);
    });

    test('the fixtures\' `resp` map still wins where it is sent', () {
      // Seed mode has no server, and its shape must keep parsing unchanged.
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': 'A-1',
        'assessmentId': '7',
        'resp': <String, dynamic>{
          'Q1': <String, dynamic>{'justification': 'typed', 'score': 1},
        },
      });
      expect(ev.resp.keys.toList(), <String>['Q1']);
      expect(ev.resp['Q1']!.justification, 'typed');
    });

    test('an answer with no question id is dropped, not filed under ""', () {
      // Every such row would collapse onto one key, so all but the last would
      // vanish silently - worse than losing the one that is malformed.
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': 80,
        'answers': <dynamic>[
          <String, dynamic>{'score': 1},
          <String, dynamic>{'score': 1},
          audit(questionId: 11),
        ],
      });
      expect(ev.resp.keys.toList(), <String>['11']);
    });

    test('answeredCount does not regress when the server also counts', () {
      // `answeredCount` takes the higher of the two. The local count now has
      // real answers behind it, so this pins that it cannot go DOWN.
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': 80,
        'answered_count': 2,
        'answers': <dynamic>[audit(questionId: 11), audit(questionId: 12)],
      });
      expect(ev.answeredCount, 2);
    });
  });

  group('The roster reports facts the client cannot recompute', () {
    test('a terminal grader error is read off the server, not walked for', () {
      // THE BUG: `hasScoringError` walked `asm.questions` against `ev.resp`,
      // and a ROSTER row has neither - `resp` is empty on every list route. It
      // therefore returned false for every attempt on every list, so the badge
      // that routes a person to the one state nothing clears by itself
      // (invariant 5) never appeared on a single screen.
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': 80,
        'assessment_id': 7,
        'subjective': <String, dynamic>{
          'score': 4,
          'max': 5,
          'state': 'error',
          'has_terminal_error': true,
        },
      });

      expect(ev.resp, isEmpty, reason: 'a list row carries no answers');
      expect(
        ev.hasScoringError(Assessment(id: '7', name: 'x')),
        isTrue,
        reason:
            'the module already flagged it on the row the badge is drawn '
            'from; the client cannot rebuild it from an empty answer map',
      );
    });

    test('with no flag it still walks the answers', () {
      // Seed mode has no server to ask.
      final Assessment asm = Assessment.fromJson(<String, dynamic>{
        'id': '7',
        'name': 'x',
        'questions': <dynamic>[
          <String, dynamic>{'id': 'Q1', 'question_type': 'subjective_rubric'},
        ],
      });
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': 'A-1',
        'assessmentId': '7',
        'resp': <String, dynamic>{
          'Q1': <String, dynamic>{'llmState': 'error'},
        },
      });
      expect(ev.subjectiveHasError, isNull);
      expect(ev.hasScoringError(asm), isTrue);
    });

    test('a false flag is a real answer, not a missing one', () {
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': 80,
        'subjective': <String, dynamic>{'has_terminal_error': false},
      });
      expect(ev.hasScoringError(Assessment(id: '7', name: 'x')), isFalse);
    });

    test('the deadline is parsed', () {
      // Sent on every admin row and read by nothing, so the one session fact
      // that says whether an open attempt is about to be swept by the expiry
      // cron appeared on no screen.
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': 80,
        'deadline': '2026-08-13T12:19:25Z',
      });
      expect(ev.deadline, isNotNull);
      expect(ev.deadline!.toUtc().hour, 12);
    });
  });

  group('The grading block IS the judge', () {
    Map<String, dynamic> graded() => <String, dynamic>{
      'gate': 'pass',
      'profile': 'rubric_v2',
      'verdict': 'Covers the shutdown steps in order.',
      'feedback': 'Good.',
      'reasoning': 'Matched 4 of 5 golden claims.',
      'reference_answer': 'Park, chock, log.',
      'rubric_source': 'sop',
      'judge_model': 'claude-opus-5',
      'attempts': 2,
      'key_closeness': 0.82,
      'sop_coverage': 0.61,
      'clarity': 'high',
      'ai_confidence': 'high',
      'verdict_consistency': 'consistent',
      'deductions': <dynamic>[
        <String, dynamic>{'label': 'Missed chocking', 'points': 1},
      ],
      'credit': <dynamic>[],
      'golden_claims': <dynamic>[
        <String, dynamic>{'label': 'Engine off before dismount'},
      ],
    };

    test('a graded answer gets its judge', () {
      final Response r = Response.fromJson(
        audit(questionId: 11, raw100: 78.0, grading: graded()),
      );

      expect(
        r.judge,
        isNotNull,
        reason:
            'the server sends the audit under `grading`; reading only `judge` '
            'left every live answer looking ungraded',
      );
      expect(r.judge!.gate, 'pass');
      expect(r.judge!.judgeModel, 'claude-opus-5');
      expect(r.judge!.keyCloseness, closeTo(0.82, 1e-9));
      expect(r.judge!.deductions, hasLength(1));
      expect(
        r.judge!.claims,
        hasLength(1),
        reason: '`golden_claims` is the wire spelling of `claims`',
      );
    });

    test('raw100 is carried in from the answer, not left at zero', () {
      // The module stores it on the response (`llm_raw_100`), not inside the
      // block, and the audit's headline meter reads it off the judge.
      final Response r = Response.fromJson(
        audit(questionId: 11, raw100: 78.0, grading: graded()),
      );
      expect(r.judge!.raw100, closeTo(78.0, 1e-9));
    });

    test('an EMPTY grading block is not a judge', () {
      // An objective answer no judge ever touched, and a subjective one still
      // pending, both carry the block with every field blank. A Judge here
      // puts an audit panel of zeros over a question with nothing to audit.
      final Response objective = Response.fromJson(
        audit(questionId: 11, llmState: 'not_needed'),
      );
      expect(objective.judge, isNull);
      expect(objective.llmState, LlmState.notNeeded);
    });

    test('an explicit `judge` key still wins', () {
      final Response r = Response.fromJson(<String, dynamic>{
        'score': 1,
        'judge': <String, dynamic>{'gate': 'review', 'raw100': 55.0},
        'grading': graded(),
      });
      expect(r.judge!.gate, 'review');
    });
  });
}
