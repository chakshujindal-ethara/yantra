// The launch gates and the builder's readiness checks - HANDOVER §5.5.
//
// Both surfaces run the same conditions. The rule this encodes is:
// EVALUATE EVERY CONDITION AND SHOW THEM TOGETHER. Reporting the first
// failure and stopping turns fixing a record into a guessing game.
//
// Nothing here short-circuits: every condition is evaluated and returned,
// whatever fails.
import '../domain/models.dart';

/// One evaluated condition: did it pass, and what did it find?
class GateResult {
  final String name;

  /// What it found. On a pass this states the evidence; on a failure it says
  /// what is wrong.
  final String why;
  final bool ok;

  /// Gate 6 names the offending questions rather than reporting a count. The
  /// list is capped at ten by the sheet that renders it.
  final List<String> offenders;

  /// Passes, but says something to read before launching - the server's
  /// `grading_keys` naming the questions that will be graded with no answer
  /// key. Drawn amber. NEVER A BLOCK: [ok] stays true, so [Gates.allPass]
  /// and the Launch button ignore it.
  final bool warning;

  const GateResult(
    this.name,
    this.why, {
    required this.ok,
    this.offenders = const <String>[],
    this.warning = false,
  });
}

class Gates {
  const Gates._();

  /// The launch gates. All are evaluated together and reported together;
  /// the action stays disabled while any one fails.
  static List<GateResult> launch(
    Assessment asm, {
    required List<Attempt> attempts,
    required Generator? generator,
    required List<Question> bank,
  }) {
    final List<Attempt> assigned = attempts
        .where((Attempt a) => a.assessmentId == asm.id)
        .toList();

    // How many people are on the roster, counting BOTH shapes.
    //
    // Before launch there are no Attempt records at all - the roster lives in
    // `asm.roster` (hr.applicant). Counting attempts alone made this gate
    // report "Nobody is assigned" for an assessment with a full roster, which
    // is the one thing that gate exists to check, and it blocked the launch
    // that would have created those attempts.
    final int rosterCount = assigned.isNotEmpty
        ? assigned.length
        : asm.roster.length;

    // Gate 4 counts against the generator's own pool, not the frozen selection,
    // because it asks whether the source could serve this assessment at all.
    final List<Question> pool = bank
        .where((Question q) => q.genId == asm.generatorId && q.launchReady)
        .toList();

    // WHAT WOULD ACTUALLY GO OUT, resolved exactly as the server resolves it.
    //
    // These two lines read `asm.questions` before, and on a draft nobody has
    // ticked that list is EMPTY - the launch route only fills it once a paper has
    // been drawn. So a brand-new assessment, which is every assessment at the
    // moment it is created, reported:
    //
    //     "Asked for 0 but only 0 are selected."   <- gate refused
    //     "VAL Generator · 0 questions"            <- beside a pool of six
    //
    // while `action_start` would have launched all six quite happily: an empty
    // shortlist means "the whole generator" there, and `limit` falls back to
    // `len(available_questions)`. The client was the only thing saying no, and
    // the only way past it was to toggle a tick - any tick - to make the count
    // real. See `Assessment.effectiveQuestionCount`.
    final List<Question> selected = asm.effectiveQuestions;
    final int want = asm.questionLimit > 0
        ? asm.questionLimit
        : selected.length;

    // Gate 6: an objective question with no correct option marked can never be
    // scored. Name them. Reads the effective selection for the same reason as
    // above - against `asm.questions` this check was vacuous on every draft,
    // which is precisely when an authoring fault is still cheap to fix.
    final List<Question> keyless = selected
        .where((Question q) => q.type.isObjective && !q.hasCompleteKey)
        .toList();

    // NO RUBRIC SIGN-OFF GATE. Approving a draft is what signs its marking
    // guide now, so `rubric_reviewed` is true for everything that reached the
    // bank and this check could only ever pass. A checklist row that cannot
    // fail teaches a reader to skim the rows that can.
    //
    // The module keeps its own gate and its `require_reviewed_rubric` flag, so
    // a deployment that sets that flag outside this app is still enforced
    // server-side. Nothing here can set it any more.

    return <GateResult>[
      GateResult(
        'The assessment is a draft',
        asm.state.isDraft
            ? 'It is in draft and has not been launched.'
            : 'This assessment is already ${asm.state.label.toLowerCase()}. '
                  'Only a draft can be launched.',
        ok: asm.state.isDraft,
      ),
      GateResult(
        'At least one candidate is assigned',
        rosterCount == 0
            ? 'Nobody is assigned. Add candidates on the Assign tab.'
            : '$rosterCount candidate(s) assigned.',
        ok: rosterCount > 0,
      ),
      GateResult(
        'A question generator is selected',
        generator == null
            ? 'No generator is set, so there is no bank to draw from.'
            : 'Drawing from ${generator.name}.',
        ok: generator != null,
      ),
      GateResult(
        'The generator has usable questions',
        pool.isEmpty
            ? 'That generator has no approved, active, media-complete question. '
                  'Approve some in the review queue first.'
            : '${pool.length} question(s) ready to serve.',
        ok: pool.isNotEmpty,
      ),
      GateResult(
        'The requested question count is available',
        selected.length >= want && want > 0
            ? '$want question(s) selected.'
            : selected.isEmpty
            ? 'Nothing is selected. Tick at least one question on the Selected '
                  'Questions tab.'
            : 'Asked for $want but only ${selected.length} are selected.',
        ok: want > 0 && selected.length >= want,
      ),
      GateResult(
        'Every objective question has an answer key',
        keyless.isEmpty
            ? 'Every selected objective question has a correct option marked.'
            : '${keyless.length} question(s) have no correct option marked and '
                  'could never be scored.',
        ok: keyless.isEmpty,
        offenders: keyless.take(10).map((Question q) => q.name).toList(),
      ),
    ];
  }

  static bool allPass(List<GateResult> gates) =>
      gates.every((GateResult g) => g.ok);

  /// The builder's readiness checks. The same conditions as the launch gates,
  /// run while the draft is still being composed, so a problem is found at
  /// authoring time rather than at the moment of going live.
  ///
  /// [selected] is the working question set the author has picked so far.
  static List<GateResult> draftChecks({
    required String name,
    required String generatorId,
    required Generator? generator,
    required List<Question> selected,
    required int limit,
    required List<Question> pool,
  }) {
    final List<Question> keyless = selected
        .where((Question q) => q.type.isObjective && !q.hasCompleteKey)
        .toList();
    final int want = limit > 0 ? limit : selected.length;

    return <GateResult>[
      GateResult(
        'The assessment has a name',
        name.trim().isEmpty
            ? 'Give it a name people will recognise.'
            : 'Named "$name".',
        ok: name.trim().isNotEmpty,
      ),
      GateResult(
        'A generator is selected',
        generator == null
            ? 'Pick the generator this assessment draws its questions from.'
            : 'Drawing from ${generator.name}.',
        ok: generatorId.isNotEmpty && generator != null,
      ),
      GateResult(
        'Enough questions are available',
        pool.length >= want && want > 0
            ? '${pool.length} launch-ready question(s) in that bank.'
            : want <= 0
            ? 'Choose how many questions to serve.'
            : 'Asked for $want but the bank holds only ${pool.length} '
                  'launch-ready question(s).',
        ok: want > 0 && pool.length >= want,
      ),
      GateResult(
        'Every objective question has an answer key',
        keyless.isEmpty
            ? 'Every objective question in the selection is scorable.'
            : '${keyless.length} question(s) have no correct option marked.',
        ok: keyless.isEmpty,
        offenders: keyless.take(10).map((Question q) => q.name).toList(),
      ),
    ];
  }
}
