/// The admin can see the UNGATED raw total, and the candidate cannot.
///
/// THE DEFECT. `assessments_be_v2` computes `raw_result` and
/// `evaluator_admin_row` already puts it on the wire - this side never parsed
/// it, so the only score an admin could read was the thresholded mark. Every
/// component is won or lost whole against a threshold, so `0 / 5` is printed
/// both for a paper of near-misses and for a blank one. On this rig attempt 27 scores `0 / 5` marks
/// against a raw of `2.25`; before this change nothing on any screen could tell
/// those two papers apart. `etp_assessment_pro` has shown the same number to
/// the same audience all along.
library;

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// The wire shape `evaluator_admin_row` sends, trimmed to what is asserted.
Map<String, dynamic> adminRow({Object? raw = 2.25, Object? rawMax = 5}) =>
    <String, dynamic>{
      'id': 27,
      'assessment_id': 4,
      'assessment_name': 'Test 17/8',
      'state': 'submitted',
      'score_marks': '0 / 5',
      'score_percent': 0.0,
      'pass_threshold': 70.0,
      'raw_result': ?raw,
      'raw_max': ?rawMax,
      'result': 'fail',
      'subjective': <String, dynamic>{'score': 0, 'max': 5, 'pending': 0},
    };

void main() {
  group('The raw total survives the wire', () {
    test('it is parsed off the admin row', () {
      // The whole defect in one assertion: this used to be null for every
      // attempt because nothing read the key.
      expect(Attempt.fromJson(adminRow()).rawResult, 2.25);
    });

    test('a camelCase payload parses too', () {
      // `jget` accepts both spellings so the seed fixtures and the live API
      // stay interchangeable. Proving it here keeps a fixture-only test from
      // passing while the live shape fails.
      final Map<String, dynamic> j = adminRow()
        ..remove('raw_result')
        ..['rawResult'] = 3.5;
      expect(Attempt.fromJson(j).rawResult, 3.5);
    });

    test('an integer on the wire is accepted, not dropped', () {
      // Odoo sends a Float, but a whole number can arrive as `4` rather than
      // `4.0`. A cast that only accepted double would null out exactly the
      // clean scores.
      expect(Attempt.fromJson(adminRow(raw: 4)).rawResult, 4.0);
    });

    test('an absent key stays NULL rather than becoming a real zero', () {
      // This is the important one. Candidate routes never send `raw_result`,
      // and defaulting to 0.0 would let a candidate screen print "Raw score
      // 0.00" - an ungated number, shown to the one audience that must never
      // see one, and wrong as well.
      expect(Attempt.fromJson(adminRow(raw: null)).rawResult, isNull);
    });

    test('a genuine zero is kept as zero', () {
      // The flip side of the line above: 0.0 sent explicitly is a real score
      // (a paper that earned nothing), and must not be confused with absence.
      expect(Attempt.fromJson(adminRow(raw: 0)).rawResult, 0.0);
    });
  });

  group('The raw total is not confused with the grade', () {
    test('marks and raw can disagree, and both are preserved', () {
      // The demo case. `score_marks` remains the grade; the raw total is the
      // explanation sitting beside it. A change that "fixed" the disagreement
      // by overwriting one with the other would break the marking rules.
      final Attempt a = Attempt.fromJson(adminRow());

      expect(a.serverEarned, 0, reason: 'the grade is still 0 marks');
      expect(a.serverTotal, 5);
      expect(a.rawResult, 2.25, reason: 'the quality behind it is not 0');
      expect(a.serverResult, isNotNull);
    });

    test('copyWith carries it through a local state change', () {
      // Attempts are rebuilt constantly as the store folds in updates. A field
      // missing from `copyWith` reverts to null on the first rebuild, which is
      // how the server's own marks were once silently reset to "0 / 0".
      final Attempt a = Attempt.fromJson(adminRow());
      expect(a.copyWith(isLocked: true).rawResult, 2.25);
    });
  });

  group('The raw is quoted out of the denominator the server states', () {
    test('`raw_max` is read off the attempt rather than derived', () {
      // The reason the key was added. `rawOutOf` used to be summed from
      // `raw_max` across the ANSWERS, and only the detail route sends answers -
      // so every list route printed a bare raw with nothing to read it
      // against.
      final Attempt a = Attempt.fromJson(adminRow());

      expect(a.serverRawMax, 5);
      expect(a.rawOutOf, 5, reason: 'no answers on this row, and it still knows');
    });

    test('it is the SAME denominator as the marks', () {
      // The whole point of the change. "1.40 / 2" beside "3 / 5" described one
      // attempt out of two different totals, which reads as a defect rather
      // than a distinction.
      final Attempt a = Attempt.fromJson(adminRow());

      expect(a.rawOutOf, a.serverTotal);
    });

    test('an absent denominator leaves the raw to print bare', () {
      // A server that predates the key. Guessing one from the question count
      // is the scale error this used to be.
      final Attempt a = Attempt.fromJson(adminRow(rawMax: null));

      expect(a.serverRawMax, isNull);
      expect(a.rawOutOf, isNull);
    });

    test('a camelCase denominator parses too', () {
      final Map<String, dynamic> j = adminRow()
        ..remove('raw_max')
        ..['rawMax'] = 7;
      expect(Attempt.fromJson(j).rawOutOf, 7);
    });

    test('copyWith carries the denominator through a rebuild', () {
      // Same failure mode as `rawResult`: a field missing from `copyWith`
      // reverts to null on the first store rebuild, and the line silently
      // loses its "/ N".
      final Attempt a = Attempt.fromJson(adminRow());
      expect(a.copyWith(isLocked: true).rawOutOf, 5);
    });
  });
}
