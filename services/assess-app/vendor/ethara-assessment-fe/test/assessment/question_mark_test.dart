// A question's MARK is the module's, not one half of it guessed at here.
//
// THE BUG THIS PINS. An `image_ab` answer is made of two halves - the objective
// sub-verdicts and the written justification - and `response_row` puts them in
// separate fields. `score` is the objective half and `_compute_score`
// short-circuits it to 0 for every type that is not mcq/msq, so this client
// read `llm_score` instead and called it the mark. That is the justification
// verdict ALONE.
//
// The module's rule is the AND of the two: every sub-verdict exactly right AND
// the justification over the threshold, or the question scores nothing. So a
// candidate who wrote a convincing paragraph over the wrong call had
// `llm_score` 1 and a real mark of 0, and every admin surface printed the 1 -
// in a column headed "Mark", in group totals, in the "scored zero" count and in
// the export. `final_mark` is that composition, computed once on the server.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

/// One `/api/v1/responses` row for an image_ab answer, as the module sends it.
///
/// `hasObjective` is FALSE on this type - it is the module's own discriminator
/// and it names mcq/msq only - which is precisely why neither `score` nor
/// `llmScore` can answer for it on its own.
Map<String, dynamic> abRow({
  required int llmScore,
  required double finalMark,
  required double mcqMark,
}) => <String, dynamic>{
  'id': 56,
  'assessment_id': 12,
  'evaluator_id': 7,
  'question_id': 21,
  'question_name': 'Which render is better - Q02',
  'question_type': 'image_ab',
  'state': 'submitted',
  'has_objective': false,
  'needs_llm': true,
  'score': 0,
  'max_score': 0,
  'final_mark': finalMark,
  'mcq_mark': mcqMark,
  'llm_state': 'scored',
  'llm_raw_100': 71.5,
  'llm_score': llmScore,
  'llm_max_score': 1,
  'llm_passed': llmScore == 1,
  'subjective_result': llmScore == 1 ? 'pass' : 'fail',
  'integrity_alert': false,
};

void main() {
  componentRuleTests();

  group('the mark is the composition the server computed', () {
    test('a passed justification over a wrong verdict scores nothing', () {
      // THE REGRESSION, in one row. The justification cleared its threshold, so
      // `llm_score` is 1 - and the sub-verdicts were not all right, so the
      // module awarded 0. Reading `llmScore` here printed the 1.
      final Response r = Response.fromJson(
        abRow(llmScore: 1, finalMark: 0.0, mcqMark: 0.0),
      );

      expect(r.llmScore, 1, reason: 'fixture no longer holds');
      expect(
        r.mark,
        0,
        reason:
            'the module scored this question 0; printing the justification '
            'verdict instead reads as a mark the candidate did not earn',
      );
    });

    test('both halves earned scores the mark', () {
      final Response r = Response.fromJson(
        abRow(llmScore: 1, finalMark: 1.0, mcqMark: 1.0),
      );
      expect(r.mark, 1);
    });

    test('right verdicts and a failed justification score nothing', () {
      // The other half of the old blend: this used to be worth 0.75 of the
      // question on the server, and the client showed it as a flat 0 anyway.
      // Both now agree on 0, for the same reason.
      final Response r = Response.fromJson(
        abRow(llmScore: 0, finalMark: 0.0, mcqMark: 1.0),
      );
      expect(r.mcqMark, 1.0, reason: 'the verdicts were right');
      expect(r.mark, 0);
    });

    test('mcq_mark says WHICH half was lost', () {
      // The reason both fields are sent: a 0 mark alone cannot tell an admin
      // whether the candidate called it wrong or could not defend a right call.
      final Response wrongCall = Response.fromJson(
        abRow(llmScore: 1, finalMark: 0.0, mcqMark: 0.0),
      );
      final Response undefended = Response.fromJson(
        abRow(llmScore: 0, finalMark: 0.0, mcqMark: 1.0),
      );

      expect(wrongCall.mark, undefended.mark);
      expect(wrongCall.mcqMark, 0.0);
      expect(undefended.mcqMark, 1.0);
    });
  });

  group('a payload without the field still reads', () {
    test('a subjective row falls back to llm_score', () {
      // A cached row written before the server sent `final_mark`, and every
      // seed fixture. Falling back to 0 here would blank a real score.
      final Map<String, dynamic> j = abRow(
        llmScore: 1,
        finalMark: 0.0,
        mcqMark: 0.0,
      )..removeWhere((String k, _) => k == 'final_mark' || k == 'mcq_mark');
      final Response r = Response.fromJson(j);

      expect(r.finalMark, isNull);
      expect(r.mark, 1, reason: 'the old reading, unchanged');
    });

    test('an objective row falls back to score', () {
      final Response r = Response.fromJson(<String, dynamic>{
        'id': 4,
        'question_type': 'mcq',
        'has_objective': true,
        'score': 1,
        'max_score': 1,
        'llm_score': 0,
        'llm_max_score': 0,
      });
      expect(r.finalMark, isNull);
      expect(r.mark, 1);
    });

    test('an mcq row prefers the server field once it is there', () {
      final Response r = Response.fromJson(<String, dynamic>{
        'id': 4,
        'question_type': 'mcq',
        'has_objective': true,
        'score': 1,
        'max_score': 1,
        'final_mark': 1.0,
        'mcq_mark': 1.0,
      });
      expect(r.mark, 1);
    });
  });

  group('the field survives the round trips a screen puts it through', () {
    test('copyWith keeps it', () {
      // `copyWith` dropping a server field is a bug this app has had before:
      // any local state change would silently revert the mark to the half.
      final Response r = Response.fromJson(
        abRow(llmScore: 1, finalMark: 0.0, mcqMark: 0.0),
      ).copyWith(state: 'submitted');
      expect(r.mark, 0);
    });

    test('toJson round-trips it', () {
      // The cache writes `toJson` and reads `fromJson` back, so a field missing
      // from either one is a mark that changes when the app is reopened.
      final Response r = Response.fromJson(
        abRow(llmScore: 1, finalMark: 0.0, mcqMark: 0.0),
      );
      expect(Response.fromJson(r.toJson()).mark, 0);
      expect(Response.fromJson(r.toJson()).mcqMark, 0.0);
    });
  });

  group('the attempt total stays parseable', () {
    // `_marksPart` reads each side of `score_marks` with `int.tryParse`. The
    // old 75/25 blend could hand it '4.25 / 10', which parsed to null - the app
    // then dropped the server's own total and re-derived the score from
    // whatever answers the screen happened to be holding. Every COMPONENT is
    // still won whole or lost whole - only the number of them per question
    // changed - so both sides stay integers.
    Map<String, dynamic> rosterRow(String marks) => <String, dynamic>{
      'id': 4,
      'assessment_id': 18,
      'candidate': <String, dynamic>{'id': 2, 'name': 'Priya Sharma'},
      'state': 'submitted',
      'total_questions': 10,
      'answered_count': 10,
      'score_marks': marks,
      'result': 'fail',
    };

    test('whole marks parse to the server figure', () {
      final Attempt a = Attempt.fromJson(rosterRow('4 / 10'));
      expect(a.serverEarned, 4);
      expect(a.serverTotal, 10);
    });

    test('a fractional total is what used to break it', () {
      // Kept as an explicit statement of the contract the server now holds up:
      // if this ever parses again, something upstream started emitting marks
      // this client cannot read, and it fails silently rather than loudly.
      final Attempt a = Attempt.fromJson(rosterRow('4.25 / 10'));
      expect(
        a.serverEarned,
        isNull,
        reason:
            'int.tryParse cannot read a fraction - the server must never '
            'send one, which is what the all-or-nothing mark guarantees',
      );
    });
  });
}

// ── The component rule ─────────────────────────────────────────────────────
//
// The unit of scoring is the COMPONENT, not the question: one mark per keyed
// dimension (a sub-question - mcq, msq, and every image_ab verdict axis), one
// for the LLM-graded free text, one for a labelling box set as a whole. So a
// three-sub-question mcq is worth 3 and `final_mark` is no longer 0 or 1.
//
// THE BUG THIS PINS. Every denominator in this client was a hardcoded 1 or a
// question count, so a candidate who got 2 of 3 sub-questions right read
// "2 / 1" on the answer panel and their paper's ring read "9 / 5".

/// One `/api/v1/responses` row for a THREE-SUB-QUESTION mcq, as the module
/// sends it under the component rule.
Map<String, dynamic> mcqRow({
  required double finalMark,
  required int finalMax,
  required double mcqMark,
  required int objectiveMarksMax,
}) => <String, dynamic>{
  'id': 91,
  'question_id': 44,
  'question_type': 'mcq',
  'state': 'submitted',
  'has_objective': true,
  'needs_llm': false,
  'score': 0,
  'max_score': 1,
  'final_mark': finalMark,
  'final_max': finalMax,
  'mcq_mark': mcqMark,
  'objective_marks_max': objectiveMarksMax,
  // A purely objective question has NO raw at all. `raw_max: 0` says so, and
  // that is a different fact from a raw OF zero.
  'raw_score': 0.0,
  'raw_max': 0,
  'llm_state': 'not_needed',
  'llm_score': 0,
  'llm_max_score': 0,
};

void componentRuleTests() {
  group('a question is worth its component count', () {
    test('a three-sub-question mcq with two right reads 2 / 3', () {
      final Response r = Response.fromJson(
        mcqRow(
          finalMark: 2.0,
          finalMax: 3,
          mcqMark: 2.0,
          objectiveMarksMax: 3,
        ),
      );

      expect(
        r.markOutOf,
        3,
        reason:
            'three marks are available; `max_score` still says 1 and reading '
            'it printed "2 / 1"',
      );
      expect(r.mark, 2, reason: 'two sub-questions were right');
      expect(r.finalMax, 3);
      expect(r.objectiveMarksMax, 3);
      expect(
        r.mcqMark,
        2.0,
        reason: 'mcq_mark is a COUNT of sub-questions passed now, not a flag',
      );
    });

    test('the server denominator wins over both local halves', () {
      // `max_score` is 1 on the row above and `has_objective` is true, so the
      // old derivation answers 1. The server said 3.
      final Response r = Response.fromJson(
        mcqRow(
          finalMark: 3.0,
          finalMax: 3,
          mcqMark: 3.0,
          objectiveMarksMax: 3,
        ),
      );
      expect(r.maxScore, 1, reason: 'fixture no longer holds');
      expect(r.markOutOf, 3);
    });

    test('a row that predates the field keeps the old denominator', () {
      final Map<String, dynamic> j = mcqRow(
        finalMark: 1.0,
        finalMax: 1,
        mcqMark: 1.0,
        objectiveMarksMax: 1,
      )..removeWhere((String k, _) => k == 'final_max');
      final Response r = Response.fromJson(j);
      expect(r.finalMax, isNull);
      expect(r.markOutOf, 1, reason: 'falls back to max_score, as it always did');
    });

    test('no raw at all is not a raw of zero', () {
      final Response objective = Response.fromJson(
        mcqRow(
          finalMark: 3.0,
          finalMax: 3,
          mcqMark: 3.0,
          objectiveMarksMax: 3,
        ),
      );
      expect(objective.rawMax, 0);
      expect(
        objective.hasRaw,
        isFalse,
        reason: 'a purely objective question has nothing to ungate',
      );

      final Response graded = Response.fromJson(<String, dynamic>{
        'question_type': 'subjective_rubric',
        'has_objective': false,
        'final_mark': 0.0,
        'final_max': 1,
        'raw_score': 0.0,
        'raw_max': 1,
      });
      expect(
        graded.hasRaw,
        isTrue,
        reason: 'this one HAS a raw, and it happens to be zero',
      );
      expect(graded.rawScore, 0.0);
    });

    test('the pairs survive copyWith and a toJson round trip', () {
      // The cache writes `toJson` and reads `fromJson` back, so a field missing
      // from either is a denominator that changes when the app is reopened.
      final Response r = Response.fromJson(
        mcqRow(
          finalMark: 2.0,
          finalMax: 3,
          mcqMark: 2.0,
          objectiveMarksMax: 3,
        ),
      ).copyWith(state: 'submitted');

      expect(r.markOutOf, 3);
      final Response back = Response.fromJson(r.toJson());
      expect(back.markOutOf, 3);
      expect(back.mark, 2);
      expect(back.objectiveMarksMax, 3);
      expect(back.rawMax, 0);
    });
  });

  group('the component count the client derives for itself', () {
    Question mcqWith(int keyed, int unkeyed) => Question(
      id: 'q',
      genId: 'g',
      type: QType.mcq,
      name: 'n',
      prompt: 'p',
      dims: <QDimension>[
        for (int i = 0; i < keyed; i++)
          QDimension(
            code: 'K$i',
            name: 'K$i',
            options: <QOption>[
              QOption(id: 'k$i-a', label: 'Right', correct: true),
              QOption(id: 'k$i-b', label: 'Wrong'),
            ],
          ),
        for (int i = 0; i < unkeyed; i++)
          QDimension(
            code: 'U$i',
            name: 'U$i',
            options: <QOption>[QOption(id: 'u$i-a', label: 'Opinion')],
          ),
      ],
    );

    test('three keyed dimensions are three marks', () {
      expect(mcqWith(3, 0).componentCount, 3);
    });

    test('an unkeyed dimension is not a component', () {
      expect(
        mcqWith(2, 4).componentCount,
        2,
        reason: 'only a dimension with a correct option is marked',
      );
    });

    test('a graded write-up adds one', () {
      const Question rubric = Question(
        id: 'q',
        genId: 'g',
        type: QType.subjectiveRubric,
        name: 'n',
        prompt: 'p',
      );
      expect(rubric.componentCount, 1);
    });

    test('a labelling box set is one component however many boxes', () {
      const Question label = Question(
        id: 'q',
        genId: 'g',
        type: QType.imageLabel,
        name: 'n',
        prompt: 'p',
        labelBoxes: <int>[1, 2, 3, 4, 5, 6],
      );
      expect(label.componentCount, 1);
    });

    test('an image_ab is its verdict axes plus its justification', () {
      final Question ab = Question(
        id: 'q',
        genId: 'g',
        type: QType.imageAb,
        name: 'n',
        prompt: 'p',
        dims: mcqWith(4, 0).dims,
      );
      expect(ab.componentCount, 5);
    });

    test('a LIST row with no dimensions degrades to 1, never to 0', () {
      // `/api/v1/bank` and an assessment's `questions` send `dimension_count`
      // rather than the dimensions, so `dims` is empty through no fault of the
      // question. Counting keys off it would report a real mcq as worth no
      // marks and shrink the whole paper's total.
      const Question row = Question(
        id: 'q',
        genId: 'g',
        type: QType.mcq,
        name: 'n',
        prompt: 'p',
      );
      expect(row.componentCount, 1);
    });
  });
}
