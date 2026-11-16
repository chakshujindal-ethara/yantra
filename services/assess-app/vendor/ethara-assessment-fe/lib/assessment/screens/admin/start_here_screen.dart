// The orientation page.
//
// The sidebar is ordered by daily use, not by the order the work flows in.
// This page states the pipeline once - document -> drafts -> bank ->
// assessment -> results - with each stage's live count and current problem
// beside it. Every figure comes from the store the rest of the console reads,
// so this page cannot disagree with the screen it links to.
import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../nav.dart';
import '../../state/app_store.dart';
import '../../theme.dart';
import '../../widgets/buttons.dart';
import '../../widgets/panel.dart';
import '../../widgets/marks.dart';

/// One step of the pipeline, as it appears on this page.
class _Stage {
  final int n;
  final String name;
  final String what;
  final String unit;
  final int count;

  /// The one thing wrong at this stage right now, or null when it is clean.
  final ({String text, Tone tone})? alert;
  final VoidCallback onOpen;

  const _Stage({
    required this.n,
    required this.name,
    required this.what,
    required this.unit,
    required this.count,
    required this.alert,
    required this.onOpen,
  });
}

class StartHereScreen extends StatelessWidget {
  final AppStore store;

  const StartHereScreen({super.key, required this.store});

  List<_Stage> _stages(BuildContext context) {
    final AssessmentNav nav = context.nav;

    // Stage 1 - generators. The alert is duplicate SOPs, which waste a
    // generation run and split a bank across two near-identical sources.
    //
    // `liveGenerators()`, not `generators`: the store fetches archived rows so
    // the generator list can restore them, and an archived generator is not a
    // stage anybody still has work to do in.
    final List<Generator> gens = store.liveGenerators();
    final int dupes = gens.where((Generator g) => g.possibleDuplicate).length;

    // Stage 2 - the review gate. Nothing reaches a candidate without it.
    final List<Question> pending = store.pendingDrafts();
    final int blocked = pending
        .where((Question d) => d.blockingWarnings.isNotEmpty)
        .length;

    // Stage 3 - the bank. A question with no usable key cannot be served.
    final List<Question> active = store.bank
        .where((Question q) => q.active)
        .toList();
    final int keyless = active
        .where((Question q) => q.type.isObjective && !q.hasCompleteKey)
        .length;

    // Stage 4 - assessments. Released results are the operator's own action,
    // so an unreleased pile is work waiting on a person, not on the system.
    //
    // `visibleAssessments`, not the raw `assessments` list, for exactly the
    // reason Stage 1 reaches for `liveGenerators()`: the store fetches
    // archived rows so the assessment list can restore them, and an archived
    // assessment is not work waiting on anybody. Counted raw, this stage
    // reported a sitting as live - and demanded results be released for it -
    // after somebody had deliberately filed it away.
    final List<Assessment> asms = store.visibleAssessments(Portal.admin);
    final int live = asms
        .where((Assessment a) => a.state == AsmState.inProgress)
        .length;
    final int releasable = asms.fold<int>(
      0,
      (int s, Assessment a) => s + a.releasableCount.clamp(0, 1 << 30),
    );

    // Stage 5 - results. A scoring error holds a result at pending rather than
    // recording a zero, so it needs a human, not a retry.
    final List<Attempt> submitted = store.attempts
        .where((Attempt e) => e.state == AttemptState.submitted)
        .toList();
    final int errored = submitted
        .where((Attempt e) => e.subjectiveState == LlmState.error)
        .length;

    return <_Stage>[
      _Stage(
        n: 1,
        name: 'Generators',
        what:
            'One per SOP document. Upload the SOP, extract its skills, '
            'generate draft questions from it.',
        unit: 'generators',
        count: gens.length,
        alert: dupes > 0
            ? (
                text: '$dupes look like duplicates of each other',
                tone: Tone.warn,
              )
            : null,
        onOpen: () => nav.reset(const GeneratorList()),
      ),
      _Stage(
        n: 2,
        name: 'Review queue',
        what:
            'Every generated question is a draft until a human approves it. '
            'Nothing skips this gate.',
        unit: 'awaiting review',
        count: pending.length,
        alert: blocked > 0
            ? (
                text: '$blocked carry a warning you must acknowledge',
                tone: Tone.warn,
              )
            : null,
        onOpen: () => nav.reset(const ReviewQueue()),
      ),
      _Stage(
        n: 3,
        name: 'Question bank',
        what:
            'Approved questions. This is the only pool an assessment can '
            'draw from.',
        unit: 'active questions',
        count: active.length,
        alert: keyless > 0
            ? (text: '$keyless with no correct answer marked', tone: Tone.bad)
            : null,
        onOpen: () => nav.reset(const QuestionBank()),
      ),
      _Stage(
        n: 4,
        name: 'Assessments',
        what:
            'Pick questions, assign people, launch. Candidates sit it once, '
            'in one timed sitting.',
        unit: 'live now',
        count: live,
        alert: releasable > 0
            ? (
                text: '$releasable results are waiting to be released',
                tone: Tone.warn,
              )
            : null,
        onOpen: nav.assessments,
      ),
      _Stage(
        n: 5,
        name: 'Results',
        what:
            'Marking, the grader audit trail, and the decision to release a '
            'score to a candidate.',
        unit: 'submitted attempts',
        count: submitted.length,
        alert: errored > 0
            ? (text: '$errored blocked by a scoring error', tone: Tone.bad)
            : null,
        onOpen: () => nav.reset(const ResponsesList()),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (BuildContext context, _) {
      final AppTokens t = context.tokens;
      final List<_Stage> stages = _stages(context);
      final List<_Stage> flagged = stages
          .where((_Stage s) => s.alert != null)
          .toList();
      final bool anyBad = flagged.any((_Stage s) => s.alert!.tone == Tone.bad);

      return PageBody(
        children: <Widget>[
          PageHead(
            'Stages',
            sub: 'How this module fits together, and where work is waiting.',
            // The return leg of the dashboard pair, in the same slot, so the
            // two pages swap under a pointer that has not moved. This page has
            // no rail row - without it the trip here is one-way.
            actions: <Widget>[
              Btn('Go to Dashboard', onPressed: () => context.nav.analytics()),
            ],
          ),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _Flow(),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: Text(
                    // "opens the section", not "is one item in the sidebar":
                    // stage 5 is called Results but opens the Responses row,
                    // under a RESULTS heading - the old wording sent operators
                    // hunting the rail for a word that is only a group title.
                    'Each stage below opens the section that does it. The '
                    'order here is how the work actually flows, which is not '
                    'the order you open them in day to day. Nothing reaches a '
                    'candidate without passing through step 2.',
                    style: context.type.bodySecondary.copyWith(height: 1.55),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (flagged.isNotEmpty) ...<Widget>[
            Row(
              children: <Widget>[
                const Eyebrow('Needs attention'),
                const SizedBox(width: 9),
                Pill(
                  '${flagged.length} of ${stages.length} stages',
                  anyBad ? Tone.bad : Tone.warn,
                ),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    'Each is marked on its stage below - open it to act.',
                    style: context.type.tiny.copyWith(color: t.textMuted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          for (final _Stage s in stages) ...<Widget>[
            _StageCard(stage: s),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 6),
          // THE ROLES THE MODULE ACTUALLY DEFINES.
          //
          // This used to describe a "Program Manager" who sees only the
          // assessments tagged to their projects. There is no such role:
          // security/etp_assessment_security.xml declares exactly two groups,
          // Evaluator and Manager, with no record rule and no menu for a third.
          // Describing a role the product does not have, on the first page an
          // operator reads, is worse than describing nothing.
          Panel(
            title: 'Who Sees What',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const <Widget>[
                _PortalNote(
                  role: 'Admin',
                  text:
                      'The full console. The only role that can release a '
                      'result or erase a candidate.',
                ),
                SizedBox(height: 10),
                _PortalNote(
                  role: 'Candidate',
                  text:
                      'Sees only their own sittings, and a score only once '
                      'it has been released. Never a percentage, never another '
                      "candidate's anything, never the answer key.",
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

/// The pipeline in one sentence, with the nouns carrying the emphasis.
class _Flow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final TextStyle base = context.type.body.copyWith(height: 1.6);
    final TextStyle strong = base.copyWith(fontWeight: FontWeight.w700);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: Text.rich(
        TextSpan(
          style: base,
          children: <TextSpan>[
            const TextSpan(text: 'A '),
            TextSpan(text: 'document', style: strong),
            const TextSpan(text: ' becomes '),
            TextSpan(text: 'draft questions', style: strong),
            const TextSpan(text: '. A human '),
            TextSpan(text: 'approves', style: strong),
            const TextSpan(text: ' them into a '),
            TextSpan(text: 'bank', style: strong),
            const TextSpan(text: '. An '),
            TextSpan(text: 'assessment', style: strong),
            const TextSpan(text: ' serves them to people, and you '),
            TextSpan(text: 'release', style: strong),
            const TextSpan(text: ' the results.'),
          ],
        ),
      ),
    );
  }
}

class _StageCard extends StatelessWidget {
  final _Stage stage;

  const _StageCard({required this.stage});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: stage.onOpen,
        child: Panel(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Mono so the step numbers line up.
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t.primarySubtle,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text(
                  '${stage.n}',
                  style: context.type.mono.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: t.primary,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Wrap(
                      spacing: 9,
                      runSpacing: 5,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        Text(
                          stage.name,
                          style: context.type.body.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (stage.alert != null)
                          StatusBadge(stage.alert!.text, stage.alert!.tone),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(stage.what, style: context.type.bodySecondary),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    '${stage.count}',
                    style: context.type.mono.copyWith(
                      fontSize: 21,
                      fontWeight: FontWeight.w500,
                      height: 1.15,
                    ),
                  ),
                  Text(
                    stage.unit.toUpperCase(),
                    style: context.type.tiny.copyWith(
                      fontSize: 10.5,
                      letterSpacing: 0.6,
                      color: t.textMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Icon(Icons.chevron_right, size: 18, color: t.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PortalNote extends StatelessWidget {
  final String role;
  final String text;

  const _PortalNote({required this.role, required this.text});

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      StatusBadge(role, Tone.inert),
      const SizedBox(width: 11),
      Expanded(child: Text(text, style: context.type.bodySecondary)),
    ],
  );
}
