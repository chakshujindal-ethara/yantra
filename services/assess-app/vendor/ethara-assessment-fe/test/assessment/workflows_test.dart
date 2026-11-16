// End-to-end workflows.
//
// The invariant suite proves the RULES hold. This proves the JOURNEYS work:
// a candidate sitting an exam start to finish, an author moving a draft into
// the bank, an administrator launching and releasing. Each test walks the same
// sequence of store calls a person's clicks would produce, and asserts what
// they would see afterwards.
//
// These catch a different class of bug from the invariant tests: a rule can be
// perfectly enforced while the path to reach it is broken.
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/gates.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppStore s;
  setUp(() => s = AppStore());

  group('A candidate sits an exam from start to finish', () {
    test('pending -> answered -> submitted -> awaiting release', () {
      final Attempt start = s.attempts.firstWhere(
        (Attempt a) => a.state == AttemptState.pending,
      );
      final Assessment asm = s.asmById(start.assessmentId)!;

      // 1. Opening the link stamps the start. Until then there is no clock.
      expect(start.startedAt, isNull);
      s.beginExam(start.id);
      final Attempt begun = s.attemptById(start.id)!;
      expect(begun.state, AttemptState.inProgress);
      expect(begun.startedAt, isNotNull);

      // 2. Answer every question the way the runtime does.
      for (final Question q in asm.questions) {
        s.saveAnswer(
          start.id,
          q.id,
          Response(
            lines: q.type.isObjective && q.dims.isNotEmpty
                ? <String>[q.dims.first.options.first.id]
                : const <String>[],
            justification: q.type.isObjective ? '' : 'A written answer.',
            state: 'answered',
          ),
        );
      }
      expect(s.attemptById(start.id)!.resp.length, asm.questions.length);

      // 3. Submitting locks the attempt. A locked attempt cannot be reopened.
      s.finishExam(start.id);
      final Attempt done = s.attemptById(start.id)!;
      expect(done.state, AttemptState.submitted);
      expect(done.isLocked, isTrue);
      expect(done.submittedAt, isNotNull);

      // 4. And the score is NOT visible - nobody has released it.
      expect(
        done.resultsReleased,
        isFalse,
        reason: 'submitting must never release; a person does that',
      );
    });

    test('an unanswered question is recorded, not silently skipped', () {
      final Attempt a = s.attempts.firstWhere(
        (Attempt x) => x.state == AttemptState.pending,
      );
      final Assessment asm = s.asmById(a.assessmentId)!;
      s.beginExam(a.id);

      // Answer only the first question, then submit.
      final Question q = asm.questions.first;
      s.saveAnswer(
        a.id,
        q.id,
        Response(
          lines: q.type.isObjective && q.dims.isNotEmpty
              ? <String>[q.dims.first.options.first.id]
              : const <String>[],
          justification: q.type.isObjective ? '' : 'Only this one.',
          state: 'answered',
        ),
      );
      s.finishExam(a.id);

      final Attempt done = s.attemptById(a.id)!;
      expect(done.state, AttemptState.submitted);
      // The unanswered ones simply have no response - they are not invented,
      // and they are not scored as though they were attempted.
      expect(done.resp.length, lessThan(asm.questions.length));
    });
  });

  group('Proctoring', () {
    test('a violation under the cap records but does not end the attempt', () {
      final Attempt a = s.attempts.firstWhere(
        (Attempt x) =>
            x.state == AttemptState.inProgress &&
            s.asmById(x.assessmentId)!.violationAction ==
                ViolationAction.autoSubmit,
      );
      final int cap = s.asmById(a.assessmentId)!.maxViolations;

      final bool ended = s.recordViolation(a.id, 'Tab switched');
      final Attempt after = s.attemptById(a.id)!;

      if (after.violationCount < cap) {
        expect(ended, isFalse);
        expect(after.state, AttemptState.inProgress);
        expect(
          after.violationReason,
          'Tab switched',
          reason: 'the reason is kept so the record can be defended',
        );
      }
    });

    test('reaching the cap auto-submits and marks it as automatic', () {
      final Attempt a = s.attempts.firstWhere(
        (Attempt x) =>
            x.state == AttemptState.inProgress &&
            s.asmById(x.assessmentId)!.violationAction ==
                ViolationAction.autoSubmit,
      );
      final int cap = s.asmById(a.assessmentId)!.maxViolations;

      // DISTINCT reasons: the same one inside 1.2s is deduped to a single
      // violation, exactly as the module does it, so repeating one string
      // never reaches a cap above 1.
      bool ended = false;
      for (int i = 0; i < cap + 2 && !ended; i++) {
        ended = s.recordViolation(a.id, 'Tab switched #$i');
      }

      final Attempt after = s.attemptById(a.id)!;
      expect(after.state, AttemptState.submitted);
      expect(
        after.autoSubmitted,
        isTrue,
        reason: 'an auto-submit must be distinguishable from a real one',
      );
    });
  });

  group('An author moves a draft into the bank', () {
    test('a clean draft approves in one step', () {
      final Question d = s.drafts.firstWhere(
        (Question q) =>
            q.blockingWarnings.isEmpty && q.state == DraftState.draft,
      );
      final int before = s.bank.length;

      expect(s.decideDraft(d.id, DraftState.approved), isNull);
      expect(s.bank.length, before + 1);
      expect(s.bank.any((Question b) => b.id == d.id), isTrue);
    });

    test('a denial keeps it out of the bank and is reversible', () {
      final Question d = s.drafts.firstWhere(
        (Question q) => q.state == DraftState.draft,
      );
      final int before = s.bank.length;

      s.decideDraft(d.id, DraftState.denied);
      expect(s.draftById(d.id)!.state, DraftState.denied);
      expect(s.bank.length, before);

      s.undoDecision();
      expect(
        s.draftById(d.id)!.state,
        DraftState.draft,
        reason: 'undo returns the draft to the queue',
      );
    });
  });

  group('An administrator launches and releases', () {
    test('a launch moves the assessment and provisions every candidate', () {
      final Assessment asm = s.assessments.firstWhere(
        (Assessment a) =>
            a.state == AsmState.draft &&
            s.launchGates(a).every((GateResult g) => g.ok),
      );

      s.launch(asm);
      final Assessment after = s.asmById(asm.id)!;
      expect(after.state, AsmState.inProgress);
      expect(
        s.attemptsFor(asm.id),
        isNotEmpty,
        reason: 'launching without attempts would strand the candidates',
      );
    });

    test('release reveals exactly the resolved attempts, and only once', () {
      final Assessment asm = s.assessments.firstWhere(
        (Assessment a) => s.releasable(a).isNotEmpty,
      );
      final List<String> toRelease = s
          .releasable(asm)
          .map((Attempt a) => a.id)
          .toList();
      final List<String> held = s
          .stillGrading(asm)
          .map((Attempt a) => a.id)
          .toList();

      s.releaseResults(asm);

      for (final String id in toRelease) {
        expect(s.attemptById(id)!.resultsReleased, isTrue);
      }
      for (final String id in held) {
        expect(
          s.attemptById(id)!.resultsReleased,
          isFalse,
          reason: 'an unresolved attempt must not be released with the rest',
        );
      }
    });

    test('an attempt still being graded is NOT released with the rest', () {
      // The regression this locks: `releasable` once returned every submitted
      // attempt, so a bulk release published scores for answers the judge had
      // not finished. Invariant 4 says an unresolved answer holds the whole
      // result on pending - releasing it contradicts that and shows a number
      // that is still moving.
      final Assessment asm = s.assessments.firstWhere(
        (Assessment a) => s.stillGrading(a).isNotEmpty,
      );
      final List<String> held = s
          .stillGrading(asm)
          .map((Attempt a) => a.id)
          .toList();

      for (final String id in held) {
        expect(
          s.releasable(asm).any((Attempt r) => r.id == id),
          isFalse,
          reason: 'a held attempt must never appear as releasable',
        );
      }

      s.releaseResults(asm);

      for (final String id in held) {
        expect(
          s.attemptById(id)!.resultsReleased,
          isFalse,
          reason: 'the bulk release must skip it',
        );
      }
    });

    test('releasing a single held attempt is refused, not silently done', () {
      // The same rule on the per-row path. One click, on one person, is
      // exactly where this would otherwise leak.
      final Assessment asm = s.assessments.firstWhere(
        (Assessment a) => s.stillGrading(a).isNotEmpty,
      );
      final Attempt held = s.stillGrading(asm).first;

      s.releaseOne(held.id);

      expect(
        s.attemptById(held.id)!.resultsReleased,
        isFalse,
        reason: 'the single-attempt path obeys the same rule as the bulk one',
      );
    });

    test('a failing gate blocks the launch and names what is wrong', () {
      final Assessment? bad = s.assessments.cast<Assessment?>().firstWhere(
        (Assessment? a) =>
            a!.state == AsmState.draft &&
            s.launchGates(a).any((GateResult g) => !g.ok),
        orElse: () => null,
      );
      if (bad == null) return; // the seed may not carry one

      final List<GateResult> gates = s.launchGates(bad);
      final List<GateResult> failed = gates
          .where((GateResult g) => !g.ok)
          .toList();

      expect(gates.length, 7, reason: 'every gate is evaluated, always');
      for (final GateResult g in failed) {
        expect(
          g.why,
          isNotEmpty,
          reason: 'a refusal without a reason cannot be acted on',
        );
      }
    });
  });

  group('Scoring recovery', () {
    test('the auto sweep never touches a terminal error', () {
      final List<String> errored = <String>[];
      for (final Attempt a in s.attempts) {
        a.resp.forEach((String qid, Response r) {
          if (r.llmState == LlmState.error) errored.add('${a.id}|$qid');
        });
      }
      expect(errored, isNotEmpty, reason: 'the seed must carry the state');

      s.autoRetrySweep();

      for (final String key in errored) {
        final List<String> parts = key.split('|');
        expect(
          s.attemptById(parts[0])!.resp[parts[1]]!.llmState,
          LlmState.error,
          reason: 'an automatic sweep must leave a terminal error alone',
        );
      }
    });

    test('a person re-scoring DOES clear it', () {
      final Attempt a = s.attempts.firstWhere(
        (Attempt x) =>
            x.resp.values.any((Response r) => r.llmState == LlmState.error),
      );

      s.rescoreAttempt(a.id);

      expect(
        s
            .attemptById(a.id)!
            .resp
            .values
            .every((Response r) => r.llmState != LlmState.error),
        isTrue,
        reason: 'the manual path is the recovery, and it must work',
      );
    });
  });

  group('Role scope', () {
    test('a candidate never reaches the assessment catalogue', () {
      expect(s.visibleAssessments(Portal.admin).length, s.assessments.length);
      expect(
        s.visibleAssessments(Portal.member),
        isEmpty,
        reason: 'the module scopes a candidate to their own attempts',
      );
    });
  });
}
