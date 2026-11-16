// The admin roster reports marks and progress; the client must READ them
// rather than recompute from data a list route never sends.
//
// The bug this pins: a submitted attempt with 3 answers and a score of "0 / 3"
// rendered "0" answered and "0 / 0" on the Candidates tab, because
// `answeredCount` counted an empty `resp` map and the marks denominator came
// from `asm.questions.length` on an assessment whose questions the detail
// route did not send either.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';

/// A trimmed copy of a real `/api/v1/assessments/<id>` candidates row.
///
/// The numbers are deliberately chosen so the SERVER's answer differs from
/// what a client would recompute. The live payload was "0 / 3" with an empty
/// answer map, where recomputing also yields 0 - so a test built on it passes
/// whether the code reads the server or silently recomputes. Earning 2 of 3
/// makes the two paths disagree, which is the only way this pins the bug.
Map<String, dynamic> rosterRow() => <String, dynamic>{
  'id': 4,
  'assessment_id': 18,
  'candidate': <String, dynamic>{
    'id': 2,
    'name': 'Priya Sharma',
    'email': 'priya.sharma@example.com',
  },
  'state': 'submitted',
  'is_locked': true,
  'invite_state': 'sent',
  'access_token': '00000000',
  'total_questions': 3,
  'answered_count': 3,
  'score_marks': '2 / 3',
  'score_percent': 66.7,
  'pass_threshold': 70.0,
  'result': 'fail',
  'results_released': true,
  'objective': <String, dynamic>{'score': 1, 'max': 2},
  'subjective': <String, dynamic>{
    'score': 0,
    'max': 1,
    'pending': 1,
    'state': 'pending',
  },
  'flags': <String, dynamic>{'integrity_alert': false},
};

/// The assessment as the DETAIL route now sends it, with its questions.
///
/// It carries FOUR questions against the attempt's three, so a denominator
/// taken from the assessment rather than from the attempt is visible as a
/// wrong number instead of an accidental match.
Map<String, dynamic> assessmentDetail() => <String, dynamic>{
  'id': 18,
  'name': 'Forklift Safety - Induction E2E',
  'state': 'done',
  'questions_available': 11,
  'questions': <dynamic>[
    <String, dynamic>{'id': 8, 'name': 'Q1', 'question_type': 'mcq'},
    <String, dynamic>{'id': 9, 'name': 'Q2', 'question_type': 'msq'},
    <String, dynamic>{
      'id': 10,
      'name': 'Q3',
      'question_type': 'subjective_rubric',
    },
    <String, dynamic>{'id': 11, 'name': 'Q4', 'question_type': 'mcq'},
  ],
};

void main() {
  group('the roster reports its own marks', () {
    test(
      'answered count comes from the server, not from an empty resp map',
      () {
        final Attempt a = Attempt.fromJson(rosterRow());
        expect(a.resp, isEmpty, reason: 'a list route sends no answers');
        expect(
          a.answeredCount,
          3,
          reason: 'the server said 3; counting resp would say 0',
        );
      },
    );

    test('marks are read off score_marks, not recomputed', () {
      final Assessment asm = Assessment.fromJson(assessmentDetail());
      final Attempt a = Attempt.fromJson(rosterRow());
      // 2 earned: recomputing from the empty answer map would say 0.
      expect(a.earnedMarks(asm), 2);
      // 3, from the ATTEMPT - not the 4 questions on the assessment.
      expect(a.maxMarks(asm), 3);
      expect(
        a.marksDisplay(asm),
        '2 / 3',
        reason: 'this rendered "0 / 0" before the fix',
      );
    });

    test('marks survive a copyWith', () {
      // copyWith dropped every server field, so any local state change
      // silently reverted a correct "0 / 3" back to "0 / 0".
      final Assessment asm = Assessment.fromJson(assessmentDetail());
      final Attempt a = Attempt.fromJson(rosterRow()).copyWith(isLocked: true);
      expect(
        a.marksDisplay(asm),
        '2 / 3',
        reason: 'copyWith used to drop the server marks, reverting to 0 / 4',
      );
      expect(a.answeredCount, 3);
    });

    test('the objective / subjective split is parsed', () {
      final Attempt a = Attempt.fromJson(rosterRow());
      expect(a.hasSplit, isTrue);
      expect(a.objectiveScore, 1);
      expect(a.objectiveMax, 2);
      expect(a.subjectiveScore, 0);
      expect(a.subjectiveMax, 1);
      expect(a.subjectivePending, 1);
    });

    test('a candidate row with no split does not claim one', () {
      final Map<String, dynamic> j = rosterRow()
        ..remove('objective')
        ..remove('subjective');
      expect(
        Attempt.fromJson(j).hasSplit,
        isFalse,
        reason: 'chips must not render on a surface with no breakdown',
      );
    });
  });

  group('the assessment detail carries its questions', () {
    test('questions parse off the detail payload', () {
      final Assessment asm = Assessment.fromJson(assessmentDetail());
      expect(asm.questions, hasLength(4));
      expect(
        asm.totalQuestions,
        4,
        reason: 'the header read "0 questions" before the fix',
      );
    });

    test('a list row still reports its counter, not zero', () {
      // A list row carries no `questions`; the count has to come from
      // `questions_available` or the list would read 0 for every row.
      final Assessment row = Assessment.fromJson(<String, dynamic>{
        'id': 18,
        'name': 'Forklift Safety - Induction E2E',
        'state': 'done',
        'questions_available': 11,
      });
      expect(row.questions, isEmpty);
      expect(row.questionsAvailable, 11);
    });
  });

  group('policy flags the module sends are read', () {
    test('retired policy keys on the wire are ignored, not fatal', () {
      // Both `require_objective_justification` and
      // `require_justification_image_comparison` have been removed. The
      // frontend and the backend deploy separately, so a build without them
      // WILL be served payloads that still carry them, and an unknown key must
      // fall out of `fromJson` rather than throw.
      final Assessment asm = Assessment.fromJson(<String, dynamic>{
        'id': 2,
        'name': 'Draft',
        'state': 'draft',
        'require_objective_justification': true,
        'require_justification_image_comparison': false,
      });

      expect(asm.name, 'Draft');
      expect(asm.llmAutoScore, isFalse);
    });
  });

  group('copyWith carries what it does not take', () {
    test('the server counters survive an unrelated edit', () {
      // THE DEFECT THIS PINS. These seven have no `copyWith` parameter, on
      // purpose - they are the server's to report - but they were not
      // forwarded either, and each defaults to -1. Every switch on the
      // Configuration tab goes through `store.updateAsm(asm.copyWith(...))`,
      // which writes the result straight into the store, so flipping any one
      // of them blanked the question and candidate counts across the screen.
      // It read as the toggle breaking the question details.
      final Assessment asm = Assessment.fromJson(<String, dynamic>{
        'id': 7,
        'name': 'Counted',
        'state': 'in_progress',
        'questions_available': 42,
        'assigned_count': 9,
        'submitted_count': 5,
        'releasable_count': 4,
        'released_count': 3,
        'awaiting_scoring_count': 2,
        'response_count': 11,
      });

      final Assessment edited = asm.copyWith(llmAutoScore: true);

      expect(edited.llmAutoScore, isTrue, reason: 'the edit still applies');
      expect(edited.questionsAvailable, 42);
      expect(edited.assignedCount, 9);
      expect(edited.submittedCount, 5);
      expect(edited.releasableCount, 4);
      expect(edited.releasedCount, 3);
      expect(edited.awaitingScoringCount, 2);
      expect(edited.responseCount, 11);
    });
  });
}
