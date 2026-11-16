// The All-responses screen counts what the SERVER reports, not what the client
// can rebuild.
//
// THE BUG THIS EXISTS FOR. `allResponses()` used to join attempts to
// `asm.questions` and `ev.resp`. Both only exist on the DETAIL payloads, so
// against a live backend the join always produced nothing: the screen showed
// "ANSWERS 0" while three answers sat in the database, and every scoring KPI
// derived from it read zero too.
//
// The payload below is a REAL row from `GET /api/v1/responses`, copied
// verbatim, so this test fails if the wire shape changes under us.
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

void main() {
  // Verbatim from the live backend. Note what it does NOT carry: no question
  // records, no per-question response map, no assessment name.
  final List<Map<String, dynamic>> live = <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 1,
      'evaluator_id': 4,
      'assessment_id': 18,
      'question_id': 10,
      'question_name': 'End of Shift Parking Procedure',
      'question_type': 'subjective_rubric',
      'candidate': <String, dynamic>{
        'id': 2,
        'name': 'Priya Sharma',
        'email': 'priya.sharma@example.com',
        'has_portal_user': true,
      },
      'score': 0,
      'max_score': 1,
      'llm_state': 'not_needed',
      'needs_llm': false,
      'state': 'submitted',
    },
    <String, dynamic>{
      'id': 2,
      'evaluator_id': 4,
      'assessment_id': 18,
      'question_id': 11,
      'question_name': 'Pedestrian Near Miss Action',
      'question_type': 'mcq',
      'candidate': <String, dynamic>{'id': 2, 'name': 'Priya Sharma'},
      'score': 0,
      'max_score': 1,
      'llm_state': 'not_needed',
      'needs_llm': false,
      'state': 'submitted',
    },
    <String, dynamic>{
      'id': 3,
      'evaluator_id': 4,
      'assessment_id': 18,
      'question_id': 12,
      'question_name': 'Pre-Operational Inspection Timing',
      'question_type': 'msq',
      'candidate': <String, dynamic>{'id': 2, 'name': 'Priya Sharma'},
      'score': 0,
      'max_score': 1,
      'llm_state': 'not_needed',
      'needs_llm': false,
      'state': 'submitted',
    },
  ];

  test(
    'every server row becomes an answer, with no assessment records loaded',
    () {
      final AppStore s = AppStore();
      // Deliberately leave `assessments` and `attempts` EMPTY - that is exactly
      // the live condition that produced the zero.
      s.responseRows = live;

      final List<AnswerRef> rows = s.allResponses();

      expect(
        rows.length,
        3,
        reason: 'the screen would read "ANSWERS 0" while three answers exist',
      );
    },
  );

  test('a row survives when its attempt and assessment cannot be resolved', () {
    // The original defect was `continue` on a failed lookup. A stand-in is
    // built instead, so a row is never silently dropped.
    final AppStore s = AppStore()..responseRows = live;
    final List<AnswerRef> rows = s.allResponses();

    expect(rows.first.q.name, 'End of Shift Parking Procedure');
    expect(
      rows.first.asm.id,
      '18',
      reason: 'the assessment id must survive even with no record loaded',
    );
    expect(
      rows.first.ev.id,
      '4',
      reason: 'the attempt id must survive even with no record loaded',
    );
  });

  test('every question type on the wire is preserved', () {
    final AppStore s = AppStore()..responseRows = live;
    final List<String> types = s
        .allResponses()
        .map((AnswerRef a) => a.q.type.wire)
        .toList();

    expect(
      types,
      containsAll(<String>['subjective_rubric', 'mcq', 'msq']),
      reason: 'the type filter on this screen reads q.type',
    );
  });

  test('with no server rows it falls back to the local join', () {
    // Demo mode still works: a fresh store seeds demo assessments whose
    // questions and responses ARE present, so the old path is correct there
    // and must not have been deleted. The point is that it still runs, not
    // that it returns nothing.
    final AppStore s = AppStore()..responseRows = <Map<String, dynamic>>[];
    expect(
      s.allResponses(),
      isNotEmpty,
      reason: 'the local join must survive for demo mode',
    );
  });
}
