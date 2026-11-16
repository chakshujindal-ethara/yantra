// The three data contracts the 2026-09-09 UI pass introduced.
//
// Kept as UNIT tests rather than widget tests on purpose. Each of these is a
// value crossing a boundary - the wire into a model, or an enum into a glyph -
// and that is where they broke or could break. Mounting a screen to assert a
// parsed field tests the mount.
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

void main() {
  group('a question knows which section it was authored under (SNo 51)', () {
    test('the wire name is read', () {
      final Question q = Question.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'Q1',
        'prompt': 'Pick one',
        'question_type': 'mcq',
        'section_title': 'On the floor',
      });
      expect(
        q.sectionTitle,
        'On the floor',
        reason:
            'the runner keys its section heading off this; unread, a '
            'paper the examiner grouped renders as one flat run',
      );
    });

    test('a question with no section reports empty, never null', () {
      final Question q = Question.fromJson(<String, dynamic>{
        'id': 2,
        'name': 'Q2',
        'prompt': 'Pick one',
        'question_type': 'mcq',
      });
      expect(
        q.sectionTitle,
        '',
        reason:
            'the runner draws a heading only when this is non-empty, so '
            'an absent key must not become the string "null"',
      );
    });
  });

  group('the grading pipeline banner (SNo 112)', () {
    test('snake_case from the server reaches the model', () {
      final ScoringPipeline p = ScoringPipeline.fromJson(<String, dynamic>{
        'queued': 12,
        'needs_manual_requeue': 3,
        'drainer': <String, dynamic>{
          'stalled': true,
          'crons_total': 4,
          'crons_inactive': 4,
          'crons_overdue': 1,
          'reason': 'All scoring crons are inactive.',
        },
      });
      expect(p.queued, 12);
      expect(
        p.needsManualRequeue,
        3,
        reason:
            'these attempts never retry themselves (INVARIANT 5); if this '
            'reads 0 the banner never tells anyone to requeue them',
      );
      expect(p.stalled, isTrue);
      expect(p.cronsInactive, 4);
      expect(p.reason, 'All scoring crons are inactive.');
    });

    test('a healthy pipeline asks for no attention', () {
      final ScoringPipeline p = ScoringPipeline.fromJson(<String, dynamic>{
        'queued': 40,
        'needs_manual_requeue': 0,
        'drainer': <String, dynamic>{'stalled': false},
      });
      expect(
        p.needsAttention,
        isFalse,
        reason:
            'a queue that is draining normally is not a problem; a banner '
            'that is always up is one nobody reads when it matters',
      );
    });

    test('either condition alone raises the banner', () {
      expect(
        ScoringPipeline.fromJson(<String, dynamic>{
          'drainer': <String, dynamic>{'stalled': true},
        }).needsAttention,
        isTrue,
      );
      expect(
        ScoringPipeline.fromJson(<String, dynamic>{
          'needs_manual_requeue': 1,
          'drainer': <String, dynamic>{'stalled': false},
        }).needsAttention,
        isTrue,
      );
    });
  });

  group('a preview draws each stimulus exactly once', () {
    test('every answer layout draws its own media', () {
      // THE DUPLICATE A WALKTHROUGH FOUND. The question preview drew the
      // stimulus itself for any type where `layoutDrawsMedia` was false - mcq,
      // msq and subjective_rubric - and then `AnswerArea` drew it as well,
      // because all three had since learned to render media when the question
      // carries some. A question with ONE video row showed TWO players; before
      // the admin URL was fixed, two copies of "No video yet for this
      // question."
      //
      // Asserted as an invariant rather than as a widget count: the preview no
      // longer has a branch to test, and this is the property that would let
      // one come back.
      for (final QType t in QType.values) {
        expect(
          t.layoutDrawsMedia,
          isTrue,
          reason:
              '${t.name} claims its answer layout draws no media. If that '
              'is genuinely true, the preview needs its own stimulus branch '
              'back - and if it is not, the preview will draw a second copy',
        );
      }
    });
  });

  group('the candidate rule vocabulary is consistent (SNo 157)', () {
    // SNo 157 WAS ALREADY FIXED, and this file originally asserted a SECOND
    // vocabulary I had added without finding the first. `ProctorRule
    // .candidateRule` has carried `(text, prohibition)` for some time, the
    // pre-exam gate renders it with a deny mark and a check respectively, and
    // its own docstring explains why fullscreen and webcam take the check. The
    // duplicate has been removed; what stays is a guard on the real one, since
    // the defect the row named - words and glyph disagreeing - is still
    // reachable by editing one and not the other.
    test('every prohibition is phrased as one, and every requirement is not', () {
      for (final ProctorRule r in ProctorRule.values) {
        if (r == ProctorRule.watermark) continue;
        final ({String text, bool prohibition}) rule = r.candidateRule;
        expect(
          rule.text.toLowerCase().startsWith('do not'),
          rule.prohibition,
          reason:
              '${r.name} renders "${rule.text}" beside a '
              '${rule.prohibition ? "deny" : "check"} mark - the words and the '
              'glyph disagree',
        );
      }
    });

    test('the watermark is not phrased as an instruction', () {
      // There is nothing for a candidate to DO about it, so the gate keeps it
      // out of the rule list and prints it as a footnote.
      final ({String text, bool prohibition}) w =
          ProctorRule.watermark.candidateRule;
      expect(w.prohibition, isFalse);
      expect(w.text.toLowerCase().startsWith('do not'), isFalse);
    });

    test('the candidate wording is not the admin switch label', () {
      // Different audiences: `label` describes the SWITCH ("Block copy and
      // paste"); a candidate is not configuring anything.
      for (final ProctorRule r in ProctorRule.values) {
        expect(r.candidateRule.text, isNot(equals(r.label)));
      }
    });
  });
}
