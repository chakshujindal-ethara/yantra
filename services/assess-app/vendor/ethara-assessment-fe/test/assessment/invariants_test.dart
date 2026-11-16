// The six invariants.
//
// Each of these rules exists because its absence causes a specific harm. A
// test that only checks the happy path would let any of them regress silently,
// so every test here asserts the CONSEQUENCE, not the implementation.
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/gates.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppStore store;

  setUp(() => store = AppStore());

  group('Invariant 1 - nothing reaches a candidate unreviewed', () {
    test('a draft carrying a blocking warning cannot be approved', () {
      final Question d = store.drafts.firstWhere(
        (Question q) => q.blockingWarnings.isNotEmpty,
      );
      final int bankBefore = store.bank.length;

      final String? refused = store.decideDraft(d.id, DraftState.approved);

      expect(
        refused,
        d.id,
        reason: 'the decision path must refuse and name the draft',
      );
      expect(
        store.draftById(d.id)!.state,
        DraftState.draft,
        reason: 'the draft must not move',
      );
      expect(
        store.bank.length,
        bankBefore,
        reason: 'nothing may enter the bank',
      );
    });

    test('acknowledging the warning unblocks approval', () {
      final Question d = store.drafts.firstWhere(
        (Question q) => q.blockingWarnings.isNotEmpty,
      );

      store.toggleAck(d.id);
      final String? refused = store.decideDraft(d.id, DraftState.approved);

      expect(refused, isNull);
      expect(store.draftById(d.id)!.state, DraftState.approved);
      expect(store.bank.any((Question q) => q.id == d.id), isTrue);
    });

    test('undo reverses both halves of an approval', () {
      final Question d = store.drafts.firstWhere(
        (Question q) => q.blockingWarnings.isEmpty,
      );
      store.decideDraft(d.id, DraftState.approved);
      expect(store.bank.any((Question q) => q.id == d.id), isTrue);

      store.undoDecision();

      expect(store.draftById(d.id)!.state, DraftState.draft);
      expect(
        store.bank.any((Question q) => q.id == d.id),
        isFalse,
        reason: 'the bank row the approval created must be removed too',
      );
    });

    test('only approved, active, media-complete questions can be served', () {
      for (final Question q in store.bank) {
        if (!q.launchReady) continue;
        expect(q.state, DraftState.approved);
        expect(q.active, isTrue);
        expect(q.mediaComplete, isTrue);
        expect(q.hasCompleteKey, isTrue);
      }
    });
  });

  group('Invariant 2 - marks, never percentages', () {
    // WAS 'every question is worth exactly one mark', which the module no
    // longer does. The unit of scoring is the COMPONENT: one mark per keyed
    // sub-question, one for a graded write-up, one for a labelling box set. A
    // question is worth as many marks as it has components, and the half of
    // the old invariant that survives is that a COMPONENT is won or lost
    // whole - there is still no fractional credit anywhere.
    test('every component is worth exactly one mark', () {
      final Assessment asm = store.assessments.first;
      for (final Attempt ev in store.attemptsFor(asm.id)) {
        for (final MapEntry<String, Response> e in ev.resp.entries) {
          final Question q = asm.questionById(e.key)!;
          expect(
            e.value.maxScore,
            q.componentCount,
            reason: 'the denominator is the question\'s component count',
          );
          expect(e.value.score, inInclusiveRange(0, q.componentCount));
          expect(
            e.value.score,
            e.value.score.roundToDouble(),
            reason: 'a component is won whole or lost whole',
          );
        }
      }
    });

    test('the total is earned over the paper\'s mark count', () {
      final Assessment asm = store.assessments.first;
      final Attempt ev = store
          .attemptsFor(asm.id)
          .firstWhere((Attempt e) => e.isDone);

      // `maxMarks`, not `totalQuestions`: the two agree only on a paper whose
      // every question happens to hold one component.
      expect(ev.marksDisplay(asm), '${ev.earnedMarks(asm)} / ${ev.maxMarks(asm)}');
      expect(ev.earnedMarks(asm), lessThanOrEqualTo(ev.maxMarks(asm)));
    });

    test('the percentage exists only to compare against the threshold', () {
      final Assessment asm = store.assessments.first;
      final Attempt ev = store
          .attemptsFor(asm.id)
          .firstWhere((Attempt e) => e.isDone);

      final double pct = ev.internalPercent(asm);
      expect(
        pct,
        closeTo(100.0 * ev.earnedMarks(asm) / ev.maxMarks(asm), 0.001),
      );

      // The verdict follows the percentage against the threshold, which is the
      // only thing the percentage is for.
      if (ev.unresolvedQuestionIds(asm).isEmpty) {
        expect(
          ev.result(asm),
          pct >= asm.passThreshold ? ResultState.pass : ResultState.fail,
        );
      }
    });
  });

  group('Invariant 3 - results are never revealed automatically', () {
    test('a fresh submission is not released', () {
      final Assessment asm = store.assessments.firstWhere(
        (Assessment a) => a.state == AsmState.inProgress,
      );
      final Attempt ev = store.attemptsFor(asm.id).first;

      store.beginExam(ev.id);
      store.finishExam(ev.id);

      expect(
        store.attemptById(ev.id)!.resultsReleased,
        isFalse,
        reason: 'submitting must never release',
      );
    });

    test('release only touches submitted, unreleased attempts', () {
      final Assessment asm = store.assessments.firstWhere(
        (Assessment a) => store.releasable(a).isNotEmpty,
      );
      final Set<String> targets = store
          .releasable(asm)
          .map((Attempt a) => a.id)
          .toSet();
      final Set<String> untouched = store
          .attemptsFor(asm.id)
          .where((Attempt a) => !a.isDone)
          .map((Attempt a) => a.id)
          .toSet();

      store.releaseResults(asm);

      for (final String id in targets) {
        expect(store.attemptById(id)!.resultsReleased, isTrue);
      }
      for (final String id in untouched) {
        expect(
          store.attemptById(id)!.resultsReleased,
          isFalse,
          reason: 'an unsubmitted attempt has no result to release',
        );
      }
    });

    test('there is no un-release', () {
      final Assessment asm = store.assessments.firstWhere(
        (Assessment a) => store.releasable(a).isNotEmpty,
      );
      store.releaseResults(asm);
      final List<Attempt> released = store
          .attemptsFor(asm.id)
          .where((Attempt a) => a.resultsReleased)
          .toList();

      // Releasing again is a no-op rather than a toggle.
      store.releaseResults(asm);

      for (final Attempt a in released) {
        expect(store.attemptById(a.id)!.resultsReleased, isTrue);
      }
    });
  });

  group('Invariant 4 - an unresolved answer holds the whole result', () {
    test('every unresolved state forces pending', () {
      for (final LlmState ls in LlmState.unresolved) {
        final Assessment asm = store.assessments.first;
        final Attempt ev = store
            .attemptsFor(asm.id)
            .firstWhere((Attempt e) => e.isDone);

        final String qid = asm.questions
            .firstWhere(
              (Question q) => q.type.isSubjective,
              orElse: () => asm.questions.first,
            )
            .id;
        final Map<String, Response> resp = Map<String, Response>.from(ev.resp);
        // Full marks everywhere, so only the unresolved state can be what
        // holds the result.
        for (final String k in resp.keys) {
          resp[k] = resp[k]!.copyWith(score: 1);
        }
        resp[qid] = (resp[qid] ?? const Response()).copyWith(
          llmState: ls,
          score: 1,
        );

        final Attempt held = ev.copyWith(resp: resp);

        expect(
          held.result(asm),
          ResultState.pending,
          reason: '$ls must hold the result whatever the score',
        );
      }
    });

    test('a terminal error holds the result rather than failing it', () {
      final Assessment asm = store.assessments.first;
      final Attempt ev = store
          .attemptsFor(asm.id)
          .firstWhere((Attempt e) => e.isDone);
      final String qid = asm.questions.first.id;

      final Attempt errored = ev.copyWith(
        resp: <String, Response>{
          ...ev.resp,
          qid: (ev.resp[qid] ?? const Response()).copyWith(
            llmState: LlmState.error,
            score: 0,
          ),
        },
      );

      expect(errored.result(asm), ResultState.pending);
      expect(
        errored.result(asm),
        isNot(ResultState.fail),
        reason:
            'an infrastructure failure must never be recorded as a '
            'candidate failure',
      );
    });
  });

  group('Invariant 5 - a terminal error is never retried automatically', () {
    test('the automatic retry set excludes error', () {
      expect(LlmState.autoRetry.contains(LlmState.error), isFalse);
      expect(
        LlmState.autoRetry,
        containsAll(<LlmState>[
          LlmState.pending,
          LlmState.queued,
          LlmState.failed,
        ]),
      );
    });

    test('the automatic sweep leaves a terminal error alone', () {
      final int before = store.scoringErrorCount;
      expect(
        before,
        greaterThan(0),
        reason: 'the seed must carry a terminal error to test against',
      );

      store.autoRetrySweep();

      expect(
        store.scoringErrorCount,
        before,
        reason: 'nothing automatic may clear a terminal error',
      );
    });

    test('a person re-scoring does clear it', () {
      final Assessment asm = store.assessments.firstWhere(
        (Assessment a) =>
            store.attemptsFor(a.id).any((Attempt e) => e.hasScoringError(a)),
      );
      final Attempt ev = store
          .attemptsFor(asm.id)
          .firstWhere((Attempt e) => e.hasScoringError(asm));

      store.rescoreAttempt(ev.id);

      expect(
        store.attemptById(ev.id)!.hasScoringError(asm),
        isFalse,
        reason: 'a person is exactly what the terminal state waits for',
      );
    });
  });

  group('Invariant 6 - advisory flags never change a score', () {
    test('an integrity alert does not move the marks or the verdict', () {
      final Assessment asm = store.assessments.first;
      final Attempt ev = store
          .attemptsFor(asm.id)
          .firstWhere((Attempt e) => e.isDone);

      final int marks = ev.earnedMarks(asm);
      final ResultState verdict = ev.result(asm);

      final Attempt flagged = ev.copyWith(
        integrityAlert: true,
        scoreOutlier: true,
      );

      expect(flagged.earnedMarks(asm), marks);
      expect(flagged.result(asm), verdict);
    });

    test('erasing the candidate data keeps every score', () {
      final Assessment asm = store.assessments.first;
      final Attempt ev = store
          .attemptsFor(asm.id)
          .firstWhere((Attempt e) => e.isDone);
      final int marks = ev.earnedMarks(asm);
      final ResultState verdict = ev.result(asm);

      store.erasePii(ev.id);
      final Attempt after = store.attemptById(ev.id)!;

      expect(after.piiAnonymized, isTrue);
      expect(
        after.earnedMarks(asm),
        marks,
        reason: 'a result you cannot defend is worse than no result',
      );
      expect(after.result(asm), verdict);
      for (final Response r in after.resp.values) {
        expect(r.justification, isEmpty);
      }
    });
  });

  group('Launch gates - all six, evaluated together', () {
    test('every gate is reported, not just the first failure', () {
      final Assessment asm = store.assessments.firstWhere(
        (Assessment a) => a.state == AsmState.draft,
      );

      final List<GateResult> gates = store.launchGates(asm);

      // SIX, not seven. The rubric sign-off gate is gone: approving a draft
      // now signs its marking guide, so that check could only ever pass, and a
      // checklist row that cannot fail teaches a reader to skim the ones that
      // can. The module keeps its own server-side gate.
      expect(
        gates.length,
        6,
        reason:
            'reporting the first failure turns fixing a record into a '
            'guessing game',
      );
      for (final GateResult g in gates) {
        expect(
          g.why,
          isNotEmpty,
          reason: 'every gate states what it found, pass or fail',
        );
      }
    });

    test('a failing gate blocks the launch', () {
      final Assessment asm = Assessment(
        id: 'A-TEST',
        name: 'No candidates assigned',
        generatorId: 'GEN-1',
        questions: store.bank.take(3).toList(),
      );
      store.assessments = <Assessment>[...store.assessments, asm];

      final List<GateResult> gates = store.launchGates(asm);
      expect(Gates.allPass(gates), isFalse);

      store.launch(asm);
      expect(
        store.asmById('A-TEST')!.state,
        AsmState.draft,
        reason: 'the guard must sit in the action, not only on the button',
      );
    });

    test('gate 6 names the offending questions rather than counting them', () {
      final Question keyless = Question(
        id: 'Q-KEYLESS',
        genId: 'GEN-1',
        type: QType.mcq,
        name: 'A question with no key',
        prompt: 'Which one?',
        dims: const <QDimension>[
          QDimension(
            code: 'D1',
            name: 'Answer',
            options: <QOption>[
              QOption(id: 'D1-0', label: 'One'),
              QOption(id: 'D1-1', label: 'Two'),
            ],
          ),
        ],
        state: DraftState.approved,
      );
      final Assessment asm = Assessment(
        id: 'A-KEY',
        name: 'Keyless',
        generatorId: 'GEN-1',
        questions: <Question>[keyless],
      );

      final GateResult g6 = store.launchGates(asm)[5];

      expect(g6.ok, isFalse);
      expect(g6.offenders, contains('A question with no key'));
    });
  });

  // WAS 'Objective scoring is all-or-nothing'. It is all-or-nothing PER
  // SUB-QUESTION now: each keyed dimension is one component and is marked on
  // its own, so a question can score 2 of 3. What is still all-or-nothing is
  // the component itself.
  group('Objective scoring is per sub-question', () {
    test('a three-sub-question mcq is out of 3, and two right earns 2', () {
      // THE COMPONENT RULE IN ONE QUESTION. Under the old rule this answer
      // scored 0 - the selected set did not equal the key exactly - so demo
      // mode reported a zero against a paper the module marks 2.
      const Question q = Question(
        id: 'Q-3SUB',
        genId: 'GEN-1',
        type: QType.mcq,
        name: 'Three sub-questions',
        prompt: 'Answer all three parts.',
        dims: <QDimension>[
          QDimension(
            code: 'D1',
            name: 'Part one',
            options: <QOption>[
              QOption(id: 'd1-a', label: 'Right', correct: true),
              QOption(id: 'd1-b', label: 'Wrong'),
            ],
          ),
          QDimension(
            code: 'D2',
            name: 'Part two',
            options: <QOption>[
              QOption(id: 'd2-a', label: 'Right', correct: true),
              QOption(id: 'd2-b', label: 'Wrong'),
            ],
          ),
          QDimension(
            code: 'D3',
            name: 'Part three',
            options: <QOption>[
              QOption(id: 'd3-a', label: 'Right', correct: true),
              QOption(id: 'd3-b', label: 'Wrong'),
            ],
          ),
        ],
      );

      expect(
        q.componentCount,
        3,
        reason: 'three keyed dimensions are three marks',
      );

      // Two right, one wrong.
      final Response? graded = store.gradeOne(
        store.assessments.first,
        q,
        const Response(lines: <String>['d1-a', 'd2-a', 'd3-b']),
      );

      expect(graded!.maxScore, 3, reason: '3 marks available');
      expect(graded.score, 2, reason: 'two of the three sub-questions right');
      expect(graded.mark, 2);
      expect(graded.markOutOf, 3);
    });

    test('a paper of multi-part questions is worth more than its length', () {
      // The denominator `maxMarks` falls back to when no server total was
      // sent. The question COUNT is 2; the paper is worth 4.
      final Assessment asm = Assessment.fromJson(<String, dynamic>{
        'id': 'a-comp',
        'name': 'Components',
        'state': 'done',
        'questions': <dynamic>[
          <String, dynamic>{
            'id': 'q1',
            'question_type': 'mcq',
            'dimensions': <dynamic>[
              for (final String d in <String>['x', 'y', 'z'])
                <String, dynamic>{
                  'id': d,
                  'name': d,
                  'options': <dynamic>[
                    <String, dynamic>{
                      'id': '$d-a',
                      'name': 'Right',
                      'is_correct': true,
                    },
                    <String, dynamic>{'id': '$d-b', 'name': 'Wrong'},
                  ],
                },
            ],
          },
          <String, dynamic>{'id': 'q2', 'question_type': 'subjective_rubric'},
        ],
      });
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': '1',
        'assessment_id': 'a-comp',
        'state': 'submitted',
      });

      expect(asm.totalQuestions, 2);
      expect(
        ev.maxMarks(asm),
        4,
        reason: '3 sub-questions plus 1 graded write-up',
      );
    });

    test('an exactly matching selection earns the mark', () {
      final Assessment asm = store.assessments.first;
      final Question q = asm.questions.firstWhere(
        (Question x) => x.type.isObjective,
      );
      final Set<String> key = <String>{
        for (final QDimension d in q.dims) ...d.correctIds,
      };

      final Response? graded = store.gradeOne(
        asm,
        q,
        Response(lines: key.toList()),
      );

      expect(graded!.score, graded.maxScore);
    });

    test('one extra selection in a sub-question loses it', () {
      final Assessment asm = store.assessments.first;
      final Question q = asm.questions.firstWhere(
        (Question x) => x.type.isObjective,
      );
      final Set<String> key = <String>{
        for (final QDimension d in q.dims) ...d.correctIds,
      };
      final String extra = q.dims.first.options
          .firstWhere((QOption o) => !o.correct)
          .id;

      final Response? graded = store.gradeOne(
        asm,
        q,
        Response(lines: <String>[...key, extra]),
      );

      expect(
        graded!.score,
        0,
        reason: 'there is no partial credit WITHIN a component',
      );
    });

    test('an empty subjective answer is discarded, not scored zero', () {
      final Assessment asm = store.assessments.first;
      final Question q = asm.questions.firstWhere(
        (Question x) => x.type.isSubjective,
        orElse: () =>
            store.bank.firstWhere((Question x) => x.type.isSubjective),
      );

      final Response? graded = store.gradeOne(asm, q, const Response());

      expect(
        graded,
        isNull,
        reason: 'an empty answer is an unanswered question, not a wrong one',
      );
    });
  });

  group('Subjective scoring uses the stored raw score', () {
    test('moving the threshold re-decides without re-grading', () {
      final Assessment asm = store.assessments.first.copyWith(
        subjectiveThreshold: 50,
      );
      final Question q = store.bank.firstWhere(
        (Question x) => x.type == QType.subjectiveRubric,
      );

      final Response answered = const Response(
        justification: 'A real answer.',
        llmRaw100: 60,
      );

      expect(store.gradeOne(asm, q, answered)!.score, 1);
      expect(
        store
            .gradeOne(asm.copyWith(subjectiveThreshold: 80), q, answered)!
            .score,
        0,
        reason: 'the raw score is stored, so the threshold alone decides',
      );
    });
  });

  group('The proctoring cap', () {
    test('auto-submit ends the attempt at the cap', () {
      final Assessment asm = store.assessments.firstWhere(
        (Assessment a) => a.violationAction == ViolationAction.autoSubmit,
      );
      final Attempt ev = store
          .attemptsFor(asm.id)
          .firstWhere((Attempt e) => !e.isDone);
      store.beginExam(ev.id);

      // DISTINCT reasons. The store mirrors the module's own dedup - the same
      // reason inside 1.2s is one violation, not several - so a loop firing
      // one string counted once here and reached no cap. Real sittings look
      // like this anyway: a switch, then a paste, then a right-click.
      bool ended = false;
      for (int i = 0; i < asm.maxViolations; i++) {
        ended = store.recordViolation(ev.id, 'Tab switched #$i');
      }

      expect(ended, isTrue);
      final Attempt after = store.attemptById(ev.id)!;
      expect(after.isLocked, isTrue);
      expect(
        after.autoSubmitted,
        isTrue,
        reason: 'the candidate is told it was automatic, not left to guess',
      );
    });

    // LOG ONLY MEANS LOG ONLY. `violationAction` decides WHETHER proctoring
    // may end a sitting; the cap only decides WHEN. This briefly ran the other
    // way - any cap that was set fired regardless of the action - which ended
    // sittings under operators who had deliberately chosen the one option
    // promising not to act. A limit is still meaningful here: the count keeps
    // rising and is what the operator reads afterwards.
    test('log-only records the violations and ends nothing', () {
      final Assessment asm = store.assessments.firstWhere(
        (Assessment a) => a.violationAction == ViolationAction.logOnly,
      );
      expect(
        asm.maxViolations,
        greaterThan(0),
        reason: 'this test is about the cap-is-set case',
      );
      final Attempt ev = store
          .attemptsFor(asm.id)
          .firstWhere((Attempt e) => !e.isDone);
      store.beginExam(ev.id);

      // DISTINCT reasons: the store folds a repeat of one reason inside 1.2s,
      // so a loop firing one string records exactly ONE violation and proves
      // nothing about a cap.
      bool ended = false;
      for (int i = 0; i < asm.maxViolations + 2; i++) {
        ended = store.recordViolation(ev.id, 'Tab switched #$i');
      }
      expect(ended, isFalse, reason: 'log only must never end a sitting');
      final Attempt after = store.attemptById(ev.id)!;
      expect(after.isLocked, isFalse);
      expect(after.autoSubmitted, isFalse);
      expect(
        after.violationCount,
        greaterThanOrEqualTo(asm.maxViolations),
        reason: 'they are still COUNTED - that tally is the whole point of '
            'log only, and the operator reads it after the sitting',
      );
    });

    test('log-only with no cap never ends the attempt', () {
      final Assessment seed = store.assessments.firstWhere(
        (Assessment a) => a.violationAction == ViolationAction.logOnly,
      );
      // Cap 0 is the only configuration that still means never-end.
      final Assessment asm = seed.copyWith(maxViolations: 0);
      store.assessments = <Assessment>[
        for (final Assessment a in store.assessments)
          if (a.id == seed.id) asm else a,
      ];
      final Attempt ev = store
          .attemptsFor(asm.id)
          .firstWhere((Attempt e) => !e.isDone);
      store.beginExam(ev.id);

      for (int i = 0; i < 8; i++) {
        expect(store.recordViolation(ev.id, 'Tab switched #$i'), isFalse);
      }
      expect(
        store.attemptById(ev.id)!.violationCount,
        8,
        reason: 'every one of them has to have been counted for the '
            'assertion below to mean anything',
      );
      expect(store.attemptById(ev.id)!.isLocked, isFalse);
    });
  });

  group('Role scope', () {
    // The module defines exactly two groups: Manager and Evaluator. These
    // assert the Flutter side matches, so a third role cannot be reintroduced
    // without a test naming the group it is supposed to correspond to.
    test('there are exactly two roles', () {
      expect(Portal.values.length, 2);
      expect(Portal.values.map((Portal p) => p.wire).toSet(), <String>{
        'admin',
        'member',
      });
    });

    // CAPABILITIES COME FROM THE SERVER NOW, so they are a property of the
    // STORE rather than of `Portal`. `Portal` is binary and reports `admin` for
    // the read-only Manager too - both belong in the operator console - so it
    // could never have told the two apart, and asking it answered `true` for a
    // role that may change nothing.
    test('an Admin holds every capability', () {
      store.accessRole = AccessRole.admin;
      store.caps = Capability.values.toSet();
      for (final Capability c in Capability.values) {
        expect(store.can(c), isTrue);
      }
      expect(
        store.visibleAssessments(Portal.admin).length,
        store.assessments.length,
        reason: 'the admin record rule grants full access',
      );
    });

    test('a read-only Manager holds NONE, but keeps the console', () {
      // The whole point of the role: every capability means "may mutate", so a
      // Manager holds none of them - and still gets `Portal.admin`, because the
      // candidate surface would be the wrong shell, not a narrower one.
      store.accessRole = AccessRole.manager;
      store.caps = <Capability>{};
      for (final Capability c in Capability.values) {
        expect(store.can(c), isFalse);
      }
      expect(
        store.visibleAssessments(Portal.admin).length,
        store.assessments.length,
        reason: 'a Manager READS the catalogue; it is writing that is refused',
      );
    });

    test('a candidate holds none, and reaches no assessment list', () {
      store.accessRole = AccessRole.candidate;
      store.caps = <Capability>{};
      for (final Capability c in Capability.values) {
        expect(store.can(c), isFalse);
      }
      expect(
        store.visibleAssessments(Portal.member),
        isEmpty,
        reason: 'a candidate sees their own attempts, never the catalogue',
      );
    });

    test('an unknown or absent role keeps full access, not none', () {
      // A client talking to a backend that predates `access_role` must behave
      // exactly as it did before the field existed. Failing the other way would
      // blank the console for everybody on the first payload mismatch - and the
      // server is the boundary regardless, so a wrong guess costs a 403.
      store.adoptSession(orgRole: 'admin');
      expect(store.accessRole, AccessRole.admin);
      expect(store.can(Capability.authoring), isTrue);
    });
  });

  group('Determinism', () {
    test('two builds of the seed produce identical scores', () {
      final AppStore a = AppStore();
      final AppStore b = AppStore();

      for (int i = 0; i < a.attempts.length; i++) {
        final Assessment? asm = a.asmById(a.attempts[i].assessmentId);
        if (asm == null) continue;
        expect(
          a.attempts[i].earnedMarks(asm),
          b.attempts[i].earnedMarks(asm),
          reason: 'a screenshot taken today must match one taken next month',
        );
      }
    });
  });
}
