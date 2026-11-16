// New assessment - HANDOVER §4.3.
//
// The builder runs the SAME conditions as the launch gates, as readiness
// checks, while the draft is still being composed. A problem is found at
// authoring time rather than at the moment of going live.
//
// It additionally excludes non-launch-ready questions from an automatic draw,
// so the gates cannot fail for a reason the author did not choose.
import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../domain/gates.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../widgets/buttons.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../../widgets/controls.dart';
import '../../widgets/violation_policy.dart';
import '../../theme.dart';
import '../../nav.dart';

class NewAssessmentScreen extends StatefulWidget {
  final AppStore store;

  const NewAssessmentScreen({super.key, required this.store});

  @override
  State<NewAssessmentScreen> createState() => _NewAssessmentScreenState();
}

class _NewAssessmentScreenState extends State<NewAssessmentScreen> {
  final TextEditingController _name = TextEditingController();
  String _generatorId = '';

  /// Null until the operator touches it: the count then follows the ready
  /// pool (see [_count]), so a bank of 15 defaults to 15 rather than to a
  /// literal 6 that nobody chose.
  int? _limit;
  int _duration = 45;

  /// Null until the operator touches it: shows the Settings default.
  int? _pass;

  /// 70, the server's own default (`DEFAULT_SUBJECTIVE_THRESHOLD`).
  int _subjective = 70;

  /// A transcription clip's own bar; 0 follows [_subjective].
  int _transcription = 0;

  /// ON BY DEFAULT here, matching the assessment's own default. A fixed order
  /// lets side-by-side candidates read each other's screens position for
  /// position, which is the whole reason to shuffle; turning it off is the
  /// deliberate choice.
  bool _shuffleQuestions = true;

  /// OFF BY DEFAULT, matching the module's own default and the operator's
  /// instruction: automatic grading spends an LLM call per subjective answer
  /// the moment a candidate submits, so turning it on is the deliberate choice.
  /// It was a hard-coded literal in `_create` until this switch existed, which
  /// meant the create form silently overrode the Config tab's own switch.
  bool _autoScore = false;

  /// ON BY DEFAULT, the assessment's own default (`results_show_answers`).
  bool _showAnswers = true;

  /// `auto` draws the set; `manual` swaps the count spinner for a checkable
  /// question table.
  String _pick = 'auto';
  final Set<String> _picked = <String>{};

  RuleSet _rules = RuleSet.defaults();
  ViolationAction _violationAction = ViolationAction.logOnly;
  int _maxViolations = 5;

  /// The AI proctoring pair, counted apart; the server's defaults.
  ViolationAction _aiViolationAction = ViolationAction.logOnly;
  int _aiMaxViolations = 5;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Settings' `scoring.default_pass_threshold`, the bar a new assessment
  /// starts with on the server; 70 when not loaded or out of range.
  int get _passValue {
    if (_pass != null) return _pass!;
    final Object? scoring = widget.store.settings['scoring'];
    final Object? v = scoring is Map ? scoring['default_pass_threshold'] : null;
    final int n = v is num ? v.round() : 70;
    return n >= 1 && n <= 100 ? n : 70;
  }

  /// The pool an automatic draw may use: approved, active, media-complete and
  /// carrying a usable key. Excluding the rest here is what stops a gate
  /// failing on a question the author never picked.
  List<Question> _pool() => _generatorId.isEmpty
      ? const <Question>[]
      : widget.store.poolFor(_generatorId);

  /// The typed count, else the whole ready pool (at least 1, the stepper's
  /// floor).
  int get _count {
    final int n = _pool().length;
    return _limit ?? (n > 0 ? n : 1);
  }

  List<Question> _selection() {
    final List<Question> pool = _pool();
    if (_pick == 'manual') {
      return pool.where((Question q) => _picked.contains(q.id)).toList();
    }
    return pool.take(_count).toList();
  }

  /// Why the ready pool is short of [_count], or null when it is not. Counted
  /// off this generator's live (unretired) bank rows that are not ready.
  Notice? _shortfall(List<Question> pool) {
    if (_pick != 'auto' || _generatorId.isEmpty || pool.length >= _count) {
      return null;
    }
    final List<Question> unready = widget.store
        .liveBank()
        .where((Question q) => q.genId == _generatorId && !q.launchReady)
        .toList();
    // The server's own verdicts where it sent them; fixtures fall back to the
    // local derivations `launchReady` uses.
    final int noMedia = unready
        .where(
          (Question q) =>
              q.missingMediaWarning.isNotEmpty ||
              (q.servable == null && !q.mediaComplete),
        )
        .length;
    final int noKey = unready
        .where((Question q) => !(q.serverKeyValid ?? q.hasCompleteKey))
        .length;
    final List<String> why = <String>[
      if (noMedia > 0) '$noMedia missing media',
      if (noKey > 0) '$noKey missing an answer key',
    ];
    return Notice(
      tone: Tone.warn,
      strong:
          'Only ${pool.length} of $_count questions are ready'
          '${why.isEmpty ? '' : ' (${why.join(', ')})'}.',
      text: pool.isEmpty
          ? 'Nothing can be drawn yet - approve or fix questions in this '
                'bank first.'
          : 'The draft gets the ${pool.length} that are. Approve or fix more, '
                'then tick them on Selected Questions.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppStore s = widget.store;

    return ListenableBuilder(
      listenable: s,
      builder: (BuildContext context, _) {
        final List<Question> pool = _pool();
        final List<Question> selected = _selection();
        final Generator? gen = s.genById(_generatorId);

        final List<GateResult> checks = Gates.draftChecks(
          name: _name.text,
          generatorId: _generatorId,
          generator: gen,
          selected: selected,
          limit: _pick == 'manual' ? selected.length : _count,
          pool: pool,
        );
        final bool ready = Gates.allPass(checks);

        return PageBody(
          children: <Widget>[
            Crumbs(<Crumb>[
              const Crumb('Assessments'),
              const Crumb('New assessment'),
            ]),
            PageHead(
              'New Assessment',
              sub: 'The question pick is made explicit before launch.',
            ),
            Cols2(
              left: Stack16(<Widget>[
                Panel(
                  title: 'Name and Source',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Field(
                        label: 'Name',
                        child: TextField(
                          controller: _name,
                          style: context.type.body,
                          // The readiness panel re-evaluates live, so the
                          // author sees the gate open as they type.
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(isDense: true),
                        ),
                      ),
                      const SizedBox(height: 14),
                      FieldGrid(<Widget>[
                        Field(
                          label: 'Generator',
                          help: 'The bank this assessment draws from.',
                          child: SelectField<String>(
                            value: _generatorId,
                            onChanged: (String v) {
                              setState(() {
                                _generatorId = v;
                                _picked.clear();
                              });
                              // Fresh, not the cached copy: a draft approved a
                              // moment ago must count as ready here.
                              if (v.isNotEmpty) s.refreshBank();
                            },
                            options: <(String, String)>[
                              ('', 'Choose a generator'),
                              // `liveGenerators()`, not `generators`: the
                              // store now holds archived ones so the list can
                              // restore them, and offering one here would let
                              // a new assessment draw from a generator that
                              // was deliberately taken out of service.
                              for (final Generator g in s.liveGenerators())
                                (g.id, g.name),
                            ],
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
                Panel(
                  title: 'Questions',
                  note: '${pool.length} launch-ready in this bank',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          // Manual leads: picking the questions yourself is the
                          // deliberate act; the draw is the shortcut beside it.
                          Btn(
                            'Manual',
                            pressed: _pick == 'manual',
                            onPressed: () => setState(() => _pick = 'manual'),
                          ),
                          const SizedBox(width: 7),
                          Btn(
                            'Draw Automatically',
                            tooltip:
                                'Let the module pick questions from the bank against your '
                                'filters, instead of choosing each one. Only servable '
                                'questions are drawn - a retired one, or one with no valid '
                                'answer key, is never offered.',
                            pressed: _pick == 'auto',
                            onPressed: () => setState(() => _pick = 'auto'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      if (_pick == 'auto')
                        Field(
                          label: 'How many questions',
                          help:
                              'Drawn from the launch-ready pool only, so the '
                              'gates cannot fail on a question you did not pick.',
                          // NOT CAPPED AT THE POOL. That cap turned a typed
                          // 15 into 6 without a word; a count the bank cannot
                          // fill now stays as typed and the notice below says
                          // what is short. 99 is the Config tab's own ceiling.
                          child: NumberField(
                            value: _count,
                            min: 1,
                            max: pool.length > 99 ? pool.length : 99,
                            onChanged: (int v) => setState(() => _limit = v),
                          ),
                        )
                      else
                        DataGrid(
                          minWidth: 560,
                          emptyMessage: _generatorId.isEmpty
                              ? 'Choose a generator first.'
                              : 'That bank has no launch-ready question yet. '
                                    'Approve some in the review queue.',
                          cols: const <Col>[
                            Col('', width: 44),
                            Col('Question', flex: 3),
                            Col('Type', width: 140),
                            Col('Difficulty', width: 110),
                          ],
                          rows: pool
                              .map(
                                (Question q) => GridRow(
                                  onTap: () => setState(
                                    () => _picked.contains(q.id)
                                        ? _picked.remove(q.id)
                                        : _picked.add(q.id),
                                  ),
                                  <Widget>[
                                    Icon(
                                      _picked.contains(q.id)
                                          ? Icons.check_box
                                          : Icons.check_box_outline_blank,
                                      size: 17,
                                      color: _picked.contains(q.id)
                                          ? context.tokens.primary
                                          : context.tokens.textMuted,
                                    ),
                                    GridLink(q.name),
                                    Text(
                                      q.taskLabelLong,
                                      style: context.type.bodySecondary,
                                    ),
                                    Text(
                                      q.difficulty.label,
                                      style: context.type.bodySecondary,
                                    ),
                                  ],
                                ),
                              )
                              .toList(),
                        ),
                      if (_shortfall(pool) case final Notice n) ...<Widget>[
                        const SizedBox(height: 12),
                        n,
                      ],
                      if (selected.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: <Widget>[
                            for (final QType ty in QType.values)
                              if (selected
                                  .where((Question q) => q.type == ty)
                                  .isNotEmpty)
                                TagChip(
                                  '${ty.short} '
                                  '${selected.where((Question q) => q.type == ty).length}',
                                ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                Panel(
                  title: 'Schedule and Scoring',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      FieldGrid(<Widget>[
                        Field(
                          label: 'Duration (minutes)',
                          help: 'At least 2. Every assessment is timed.',
                          child: NumberField(
                            value: _duration,
                            // 2, not 0. Zero used to mean "no limit", and an
                            // untimed sitting never gets a deadline, so the
                            // expiry cron skips it and the attempt can never
                            // be swept. The server refuses anything below 2
                            // both on write and at launch; this stops the
                            // stepper reaching it in the first place.
                            min: 2,
                            max: 600,
                            onChanged: (int v) => setState(() => _duration = v),
                          ),
                        ),
                        Field(
                          label: 'Pass threshold (%)',
                          help:
                              'Decides whether the whole attempt passed. Never '
                              'shown to a candidate as a score.',
                          child: NumberField(
                            value: _passValue,
                            min: 1,
                            max: 100,
                            onChanged: (int v) => setState(() => _pass = v),
                          ),
                        ),
                        // The short form of the detail screen's help, and it
                        // has to AGREE with it: same bar, same three places it
                        // is applied. "One written answer ... its single mark"
                        // named one of the three and implied a question was
                        // worth one mark, which the component rule ended. What
                        // is dropped here is the sentence about stored raw
                        // scores re-deciding pass and fail - nothing has been
                        // graded yet on a paper being created, so it is the
                        // one half that means nothing at this point.
                        Field(
                          label: 'Subjective threshold (%)',
                          help:
                              'The bar every graded component clears to earn '
                              'its mark - a written answer, each labelling '
                              'box, then the share of those that cleared.',
                          child: NumberField(
                            value: _subjective,
                            min: 0,
                            max: 100,
                            onChanged: (int v) =>
                                setState(() => _subjective = v),
                          ),
                        ),
                        // Only where a transcription question is picked. The
                        // detail screen's help, less the sentence about
                        // re-deciding results nobody has yet.
                        if (selected.any(
                          (Question q) => q.type == QType.transcription,
                        ))
                          Field(
                            label: 'Transcription threshold (%)',
                            help:
                                "A transcription clip's own bar; 0 follows the "
                                'subjective threshold. A clip loses 20 per '
                                'critical mistake and 5 per minor one, and 1 '
                                'critical or 5 minor fail it whatever the bar, '
                                'so 80 or below adds nothing: 85 allows 3 minor '
                                'mistakes, 90 two, 95 one.',
                            child: NumberField(
                              value: _transcription,
                              min: 0,
                              max: 100,
                              commitOnSubmit: true,
                              onChanged: (int v) =>
                                  setState(() => _transcription = v),
                            ),
                          ),
                      ]),
                      const SizedBox(height: 12),
                      // No "Require a reviewed rubric" switch. Approving a
                      // draft now signs its marking guide, so the flag it set
                      // is true for everything in the bank and the gate reading
                      // it could never fail - a toggle whose only settings are
                      // "on, and passing" and "off".
                      //
                      // No "Same questions for everybody" switch either:
                      // everybody always gets the same questions (decided
                      // 2026-09-22), and the server ignores the key.
                      //
                      // Shuffle defaults on for the same reason it is on the
                      // assessment itself: same questions in a fixed order is a
                      // side-by-side leak the shuffle closes.
                      SwitchRow(
                        name: 'Shuffle Questions',
                        hint:
                            'Each candidate gets the questions in a random '
                            'order fixed for their sitting. The numbers they '
                            'read still count 1..N in the order they see.',
                        value: _shuffleQuestions,
                        onChanged: (bool v) =>
                            setState(() => _shuffleQuestions = v),
                      ),
                      // THE SWITCH THIS PANEL WAS MISSING. It exists on the
                      // assessment's Config tab, so the two screens disagreed:
                      // the create form set `llm_auto_score` to a hard-coded
                      // literal nobody could see, and an operator building an
                      // assessment could not tell - let alone decide - whether
                      // submitting would spend an LLM call per subjective
                      // answer. Same wording as the Config tab, because it is
                      // the same setting and reading two descriptions of one
                      // switch is how an operator concludes they are two.
                      SwitchRow(
                        name: 'Grade subjective answers automatically',
                        hint:
                            'On, a submit queues the candidate for the '
                            'background grader. Off, nothing is graded until '
                            'someone runs it by hand - and nothing tells you '
                            'it is waiting.',
                        value: _autoScore,
                        onChanged: (bool v) => setState(() => _autoScore = v),
                      ),
                      // The Config tab's switch, word for word, for the same
                      // reason as the one above.
                      SwitchRow(
                        name: 'Show correct answers and feedback',
                        hint:
                            "On, released candidates see the correct answers, "
                            "each answer's verdict and the grader's feedback. "
                            'Off, they see their own answers and marks only. '
                            'Read when they open the review, so a change '
                            'applies at once.',
                        value: _showAnswers,
                        last: true,
                        onChanged: (bool v) => setState(() => _showAnswers = v),
                      ),
                    ],
                  ),
                ),
                Panel(
                  title: 'Rules and Proctoring',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final (int i, ProctorRule rule)
                          in _rules.switches.indexed)
                        SwitchRow(
                          name: rule.label,
                          hint: rule.hint,
                          value: _rules[rule],
                          last: i == _rules.switches.length - 1,
                          onChanged: (bool v) {
                            final String? first = v
                                ? _rules.needsFirst(rule)
                                : null;
                            if (first != null) {
                              return widget.store.toaster.warn(first);
                            }
                            setState(() => _rules = _rules.set(rule, v));
                          },
                        ),
                      const SizedBox(height: 14),
                      ViolationPolicy(
                        action: _violationAction,
                        cap: _maxViolations,
                        minCap: 1,
                        onAction: (ViolationAction v) =>
                            setState(() => _violationAction = v),
                        onCap: (int v) => setState(() => _maxViolations = v),
                      ),
                      // AI proctoring violations count apart, against their
                      // own pair.
                      if (_rules[ProctorRule.aiProctor]) ...<Widget>[
                        const SizedBox(height: 16),
                        ViolationPolicy(
                          ai: true,
                          action: _aiViolationAction,
                          cap: _aiMaxViolations,
                          minCap: 1,
                          onAction: (ViolationAction v) =>
                              setState(() => _aiViolationAction = v),
                          onCap: (int v) =>
                              setState(() => _aiMaxViolations = v),
                        ),
                      ],
                    ],
                  ),
                ),
              ]),
              right: Panel(
                title: 'Readiness',
                note: 'The same conditions the launch gates run',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    CheckList(checks),
                    // DEFENCE IN DEPTH. A read-only Manager is kept off this
                    // route entirely, so on the happy path this gate never
                    // fires - but a route guard is one edit away from being
                    // wrong, and creating an assessment is a configure action
                    // the server refuses for them. Without this, a Manager who
                    // reached the form by any means filled it in, pressed
                    // Create and lost the lot to a 403.
                    //
                    // The button, its spacing and the sentence explaining what
                    // saving does go together: that copy is about pressing this
                    // control, so leaving it behind would describe a button
                    // that is not there and strand a gap where it was. The
                    // readiness checks above stay - they are a reading of the
                    // draft, not an action on it.
                    if (s.can(Capability.configure)) ...<Widget>[
                      const SizedBox(height: 14),
                      Btn.primary(
                        ready ? 'Create draft' : 'Save as draft',
                        tooltip: ready
                            ? 'Create the assessment as a DRAFT. Nothing is '
                                  'sent and no candidate can start until it is '
                                  'launched.'
                            : 'Save what you have. The checks above are LAUNCH '
                                  'requirements, not save requirements - finish '
                                  'them on the assessment itself.',
                        size: BtnSize.lg,
                        expand: true,
                        // A NAME IS THE ONLY REQUIREMENT, matching the server.
                        //
                        // This used to demand every check on the list, which
                        // made the checks above launch gates that behaved like
                        // save gates: an assessment could not be put down and
                        // picked up later, so a half-built one lived in this
                        // widget's fields and died with the tab. Every one of
                        // them is still enforced at launch, by the server, with
                        // `confirm: true` - see `_launch_gates` in
                        // controllers/api/admin.py.
                        onPressed: _canSaveDraft
                            ? () => _create(context, s, ready: ready)
                            : null,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        !_canSaveDraft
                            ? 'Give the assessment a name to save it.'
                            : ready
                            ? 'Creating a draft does not invite anybody. You '
                                  'assign candidates next, then launch.'
                            : 'The outstanding checks are needed to LAUNCH, '
                                  'not to save. You can finish them on the '
                                  'assessment and launch from there.',
                        style: context.type.tiny.copyWith(height: 1.45),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// The ONLY thing the server requires to create an assessment, restated so
  /// the button can honour the same rule.
  ///
  /// `assessment_create` (controllers/api/write.py) refuses on an empty name
  /// and on nothing else; it hard-codes `state: draft` and every other
  /// requirement is a LAUNCH gate, checked again with `confirm: true`. The
  /// screen used to demand all eight before it would save anything, so a
  /// half-built assessment could not be put down and picked up later - the
  /// work lived in this widget's fields and died with the tab.
  bool get _canSaveDraft => _name.text.trim().isNotEmpty;

  Future<void> _create(
    BuildContext context,
    AppStore s, {
    required bool ready,
  }) async {
    // Re-read before the pick, so the draw sees the bank as it is now.
    if (_generatorId.isNotEmpty) await s.refreshBank();
    if (!context.mounted) return;
    final List<Question> selected = _selection();
    final Generator? gen = s.genById(_generatorId);
    // A PLACEHOLDER id, used only by the seed path. Live, the server decides
    // the id and `addAssessment` returns it - navigating to a locally invented
    // one is why every successful create used to land on "not found".
    final String id = 'A-${s.assessments.length + 1}';
    final String? created = await s.addAssessment(
      Assessment(
        id: id,
        name: _name.text.trim(),
        generatorId: _generatorId,
        generatorName: gen?.name ?? '',
        durationMinutes: _duration,
        questionLimit: selected.length,
        questions: selected,
        passThreshold: _passValue.toDouble(),
        subjectiveThreshold: _subjective.toDouble(),
        transcriptionThreshold: _transcription.toDouble(),
        shuffleQuestions: _shuffleQuestions,
        // OFF BY DEFAULT, on the operator's instruction: nothing is graded
        // until they choose to grade it. This once argued the opposite - that
        // a product advertising AI grading should produce assessments that
        // grade - and turned it on for everything. The operator asked for the
        // reverse: automatic grading spends an LLM call per subjective answer
        // the moment a candidate submits, and they want to decide when that
        // spend happens rather than have a submit trigger it.
        //
        // It is a SWITCH ON THIS FORM now, not a literal. Hard-coding it meant
        // the decision was invisible at the one moment somebody was making it,
        // and the Config tab offered a switch the create form silently
        // overrode. `_autoScore` still defaults to false, so the default
        // behaviour is unchanged.
        llmAutoScore: _autoScore,
        resultsShowAnswers: _showAnswers,
        rules: _rules,
        violationAction: _violationAction,
        maxViolations: _maxViolations,
        aiViolationAction: _aiViolationAction,
        aiMaxViolations: _aiMaxViolations,
      ),
    );
    if (!context.mounted) return;
    if (created == null) return; // The store has already said why.
    // A finished draft goes to Assign, where the next thing to do is; a
    // half-built one goes to Config, which is the tab that still needs work.
    context.nav.assessment(created, tab: ready ? 'assign' : 'config');
  }
}
