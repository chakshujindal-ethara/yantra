// Response detail parses what `GET /api/v1/responses/<ev>/<q>` ACTUALLY sends.
//
// TWO SCREENS' WORTH OF BUGS, all from the same habit: the route returns the
// answer, its question and the grader's working, and the client read about a
// third of it.
//
//   1. "Response not found" - the screen looks its question up on the
//      ASSESSMENT. Reached from All responses the cached assessment is the LIST
//      row, which carries no question list, so a live answer resolved to "That
//      answer is no longer on this attempt" - while the same request had just
//      returned that question in full, under `question`, unread.
//
//   2. "Nothing selected" - `lines` is one OBJECT per selected line on the
//      admin routes, and the parser stringified each object whole. Every screen
//      then compared `{id: 138, dimension_id: 88, ...}` against an option id, a
//      comparison that can never match, so a fully-answered msq scored 1 / 1
//      printed as unanswered.
//
//   3. "No key recorded" - the key can only be rebuilt from per-option
//      `is_correct` flags, which no list shape carries. The module sends its own
//      resolved `answer_summary` and `correct_summary` on every response row,
//      and nothing read either.
//
// Every payload below is verbatim from the running module: attempt 80,
// question 205, an msq the candidate answered in full.
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/admin/response_detail_screen.dart';

/// `S.response_audit` + `data["question"]`, trimmed to the read keys.
Map<String, dynamic> liveAnswer() => <String, dynamic>{
  'id': 1,
  'evaluator_id': 80,
  'assessment_id': 126,
  'question_id': 205,
  'question_name': 'Logical Correctness Evaluation',
  'question_type': 'msq',
  'state': 'submitted',
  'score': 1,
  'max_score': 1,
  'llm_state': 'not_needed',
  'llm_raw_100': 0.0,
  'has_objective': true,
  'needs_llm': false,
  'justification': '',
  'answer_summary':
      'Physics correctness, Mechanical plausibility, '
      'Mathematical/chart accuracy, Anatomical correctness, '
      'Spatial/layout correctness',
  'correct_summary':
      'Physics correctness, Mechanical plausibility, '
      'Mathematical/chart accuracy, Anatomical correctness, '
      'Spatial/layout correctness',
  // ONE OBJECT PER LINE. `id` is the response line's own row id, NOT the
  // option - reading it would match some unrelated option by collision.
  'lines': <dynamic>[
    <String, dynamic>{
      'id': 138,
      'dimension_id': 88,
      'dimension_name': 'Logical Correctness Evaluation',
      'selected_option_id': 264,
      'selected_option_name': 'Physics correctness',
      'is_correct': true,
    },
    <String, dynamic>{
      'id': 139,
      'dimension_id': 88,
      'dimension_name': 'Logical Correctness Evaluation',
      'selected_option_id': 265,
      'selected_option_name': 'Mechanical plausibility',
      'is_correct': true,
    },
  ],
  'grading': <String, dynamic>{'gate': '', 'profile': '', 'judge_model': ''},
};

/// `S.bank_question_detail`, which the route embeds under `question`.
Map<String, dynamic> liveQuestion() => <String, dynamic>{
  'id': 205,
  'name': 'Logical Correctness Evaluation',
  'question_type': 'msq',
  'prompt':
      "The guidelines state that 'Instruction Following' is not just about "
      "the presence of elements, but also 'Logical Correctness.'",
  'dimension_count': 1,
  'dimensions': <dynamic>[
    <String, dynamic>{
      'id': 88,
      'name': 'Logical Correctness Evaluation',
      'sequence': 10,
      'options': <dynamic>[
        <String, dynamic>{
          'id': 264,
          'name': 'Physics correctness',
          'sequence': 10,
          'is_correct': true,
        },
        <String, dynamic>{
          'id': 265,
          'name': 'Mechanical plausibility',
          'sequence': 20,
          'is_correct': true,
        },
        <String, dynamic>{
          'id': 269,
          'name': 'Color vibrancy',
          'sequence': 60,
          'is_correct': false,
        },
      ],
    },
  ],
};

/// `S.bank_question_row`, which is what an assessment's question list holds.
/// Note what it does NOT carry: `dimensions`. Only a COUNT of them.
Map<String, dynamic> thinQuestion() => <String, dynamic>{
  'id': 205,
  'name': 'Logical Correctness Evaluation',
  'question_type': 'msq',
  'prompt': 'The guidelines state that...',
  'dimension_count': 1,
};

void main() {
  group('The selected options survive the parse', () {
    test('a line OBJECT yields its option id, not its own row id', () {
      final Response r = Response.fromJson(liveAnswer());

      expect(
        r.lines,
        <String>['264', '265'],
        reason:
            'the option is `selected_option_id`; `id` is the response line, '
            'and matching on it would name an unrelated option',
      );
    });

    test('bare ids still parse, for the runner and the fixtures', () {
      // The exam route posts and stores option ids flat. That shape must keep
      // working or the candidate's own answer sheet breaks.
      final Response r = Response.fromJson(<String, dynamic>{
        'lines': <dynamic>['264', 265],
      });
      expect(r.lines, <String>['264', '265']);
    });

    test('a line with no selected option is dropped', () {
      final Response r = Response.fromJson(<String, dynamic>{
        'lines': <dynamic>[
          <String, dynamic>{'id': 1, 'selected_option_id': null},
          <String, dynamic>{'id': 2, 'selected_option_id': 264},
        ],
      });
      expect(r.lines, <String>['264']);
    });
  });

  group('The answer and the key read correctly WITHOUT a question record', () {
    // This is the case that was broken on screen: All responses builds its
    // question from a name and a type, and an assessment's list holds the bank
    // ROW. Neither has an option to join against.
    final Question thin = Question.fromJson(thinQuestion());

    test('the candidate answer names the picks', () {
      final Response r = Response.fromJson(liveAnswer());

      expect(thin.dims, isEmpty, reason: 'the row shape carries no options');
      expect(
        answerSummary(thin, r),
        startsWith('Physics correctness, Mechanical plausibility'),
        reason:
            'the module resolved these labels itself and sends them on every '
            'response row; rebuilding them locally is what failed',
      );
      expect(answerSummary(thin, r), isNot('Nothing selected'));
    });

    test('the correct answer names the key', () {
      final Response r = Response.fromJson(liveAnswer());
      expect(correctSummary(thin, r), isNot('No key recorded'));
      expect(correctSummary(thin, r), contains('Spatial/layout correctness'));
    });

    test('with no server string it still joins locally', () {
      // Seed mode has no server to ask, so the local join stays the fallback.
      final Question full = Question.fromJson(liveQuestion());
      final Response r = Response.fromJson(<String, dynamic>{
        'question_type': 'msq',
        'lines': <dynamic>['264', '265'],
      });

      expect(r.serverAnswerSummary, isEmpty);
      expect(
        answerSummary(full, r),
        'Physics correctness, Mechanical plausibility',
      );
      expect(
        correctSummary(full, r),
        'Physics correctness, Mechanical plausibility',
        reason: 'option 269 is not correct and must not appear in the key',
      );
    });

    test('an unanswered question still reads as unanswered', () {
      // The server sends an EMPTY summary for one, so the preference must not
      // turn "nothing" into a blank line where "Nothing selected" belongs.
      final Question full = Question.fromJson(liveQuestion());
      final Response r = Response.fromJson(<String, dynamic>{
        'question_type': 'msq',
        'answer_summary': '',
        'lines': <dynamic>[],
      });
      expect(answerSummary(full, r), 'Nothing selected');
    });
  });

  group('The answer breaks down per dimension, as Odoo shows it', () {
    // The module's own response form has a "Dimension Answers" page: one row
    // per axis, the axis on the left and the option picked on the right. A
    // four-axis image_ab joined to "Response A, Both Good, Both Good, Response
    // A" cannot be read back against anything - it does not say which axis each
    // verdict was cast on, which is the only thing that makes the row mean
    // something. Verbatim from evaluator 78 / question 204.
    Map<String, dynamic> abAnswer() => <String, dynamic>{
      'question_id': 204,
      'question_type': 'image_ab',
      'score': 0,
      'answer_summary': 'Response A, Both Good, Both Good, Response A',
      'lines': <dynamic>[
        <String, dynamic>{
          'id': 555,
          'dimension_id': 84,
          'dimension_name': 'Instruction Following (IF)',
          'selected_option_id': 250,
          'selected_option_name': 'Response A',
          'is_correct': true,
        },
        <String, dynamic>{
          'id': 556,
          'dimension_id': 85,
          'dimension_name': 'Visual Quality (VQ)',
          'selected_option_id': 256,
          'selected_option_name': 'Both Good',
          'is_correct': true,
        },
        <String, dynamic>{
          'id': 558,
          'dimension_id': 87,
          'dimension_name': 'Overall Choice (OC)',
          'selected_option_id': 263,
          'selected_option_name': 'Response B',
          'is_correct': false,
        },
      ],
    };

    test('every line keeps its axis, its pick and its verdict', () {
      final Response r = Response.fromJson(abAnswer());

      expect(r.details, hasLength(3));
      expect(r.details.first.dimensionName, 'Instruction Following (IF)');
      expect(r.details.first.optionName, 'Response A');
      expect(r.details.first.isCorrect, isTrue);
      expect(r.details.last.optionName, 'Response B');
      expect(
        r.details.last.isCorrect,
        isFalse,
        reason:
            "`is_correct` is the module's own verdict on the pick; recomputing "
            'it cannot tell a wrong answer from an axis with no key set',
      );
    });

    test('the flat option ids still come through beside it', () {
      // The runner and the local grader compare ids, not names, so both
      // readings of `lines` have to survive the same parse.
      final Response r = Response.fromJson(abAnswer());
      expect(r.lines, <String>['250', '256', '263']);
    });

    test('the flat shape yields no breakdown, and must not invent one', () {
      final Response r = Response.fromJson(<String, dynamic>{
        'lines': <dynamic>['250', '256'],
      });
      expect(r.details, isEmpty, reason: 'bare ids carry no dimension');
      expect(r.lines, <String>['250', '256']);
    });

    test('a line with nothing picked is dropped from the breakdown', () {
      final Response r = Response.fromJson(<String, dynamic>{
        'lines': <dynamic>[
          <String, dynamic>{'dimension_name': 'Empty axis'},
          <String, dynamic>{
            'dimension_name': 'Real axis',
            'selected_option_id': 250,
            'selected_option_name': 'Response A',
          },
        ],
      });
      expect(r.details.map((ResponseLine l) => l.dimensionName), <String>[
        'Real axis',
      ]);
    });
  });

  group('The embedded question is the full one', () {
    test('it carries the dimensions the assessment row omits', () {
      final Question full = Question.fromJson(liveQuestion());
      final Question thin = Question.fromJson(thinQuestion());

      expect(thin.dims, isEmpty);
      expect(full.dims, hasLength(1));
      expect(full.dims.first.options, hasLength(3));
      expect(
        full.dims.first.options.where((QOption o) => o.correct).length,
        2,
        reason: '`is_correct` is the wire spelling of `correct`',
      );
      expect(full.type, QType.msq);
    });
  });

  group('A written answer on a list row reads its preview', () {
    // THE BUG: a `response_row` carries no `justification`, and the module's
    // `answer_summary` is empty for a written answer - so All Responses read
    // "Left blank" over every written answer that had text.
    final Question written = Question.fromJson(<String, dynamic>{
      'id': 301,
      'question_type': 'subjective_rubric',
    });
    Response row(Map<String, dynamic> extra) => Response.fromJson(
      <String, dynamic>{'question_type': 'subjective_rubric', ...extra},
    );

    test('the preview is shown, blank only when the server says so, and an '
        'older server that cannot say reads "-"', () {
      expect(
        answerSummary(
          written,
          row(<String, dynamic>{'justification_preview': 'The arm is bent...'}),
        ),
        'The arm is bent...',
      );
      expect(
        answerSummary(
          written,
          row(<String, dynamic>{'justification_preview': ''}),
        ),
        'Left blank',
      );
      expect(answerSummary(written, row(<String, dynamic>{})), '-');
    });
  });
}
