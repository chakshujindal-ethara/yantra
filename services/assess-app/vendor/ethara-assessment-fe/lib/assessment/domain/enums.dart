// Domain enums and their state machines - HANDOVER §5.2.
//
// Every enum here carries its own label and tone so no screen has to decide
// how a state should read. The tone map enforces the one rule the design system
// states twice in the source: RED MEANS FAILURE OR ABSENCE ONLY. Pending,
// queued and scoring are inert or informational - never red.

/// The six tones a status mark may take (HANDOVER §1.10).
enum Tone {
  /// A terminal good outcome: Done, Sent, Submitted, Scored, Pass.
  ok,

  /// Attention needed, still recoverable: a queued invite, a grader failure
  /// that can be re-run.
  warn,

  /// Terminal failure or absence: Cancelled, Failed, Fail, Scoring error.
  bad,

  /// Something is actively happening: In progress, Queued, Scoring.
  info,

  /// No state yet, or a state that carries no judgement: Draft, Not started,
  /// None, Not needed, Pending.
  inert,

  /// A designation rather than a state - the item the surface is about.
  accent,
}

/// ── Assessment lifecycle ──────────────────────────────────────────────────
///
///     draft ──launch (all gates pass)──▶ in_progress ──mark done──▶ done
///       │                                     │
///       │                                     └──cancel──▶ cancelled
///       └──cancel──▶ cancelled ──reset──▶ draft
///
/// Configuration is editable only in [draft]. [cancelled] is the one state
/// that leaves the linear bar and is drawn separately.
enum AsmState {
  draft('draft', 'Draft', Tone.inert),
  inProgress('in_progress', 'In progress', Tone.info),
  done('done', 'Done', Tone.ok),
  cancelled('cancelled', 'Cancelled', Tone.bad);

  final String wire;
  final String label;
  final Tone tone;

  const AsmState(this.wire, this.label, this.tone);

  static AsmState parse(String? v) => values.firstWhere(
    (AsmState s) => s.wire == v,
    orElse: () => AsmState.draft,
  );

  bool get isDraft => this == AsmState.draft;
  bool get isLive => this == AsmState.inProgress;

  /// The linear bar renders draft -> in progress -> done; cancelled is drawn
  /// as a single chip instead.
  static const List<AsmState> linear = <AsmState>[draft, inProgress, done];
}

/// ── Attempt ───────────────────────────────────────────────────────────────
///
///     pending ──begin──▶ in_progress ──submit──▶ submitted
///                             │                      ▲
///                             └──violation cap ──────┤
///                             └──deadline ───────────┘
///
/// [submitted] sets `isLocked` and is terminal. Reaching it by cap or deadline
/// additionally sets `autoSubmitted`, which is surfaced to the candidate
/// rather than hidden.
enum AttemptState {
  pending('pending', 'Not started', Tone.inert),
  inProgress('in_progress', 'In progress', Tone.info),
  submitted('submitted', 'Submitted', Tone.ok);

  final String wire;
  final String label;
  final Tone tone;

  const AttemptState(this.wire, this.label, this.tone);

  static AttemptState parse(String? v) => values.firstWhere(
    (AttemptState s) => s.wire == v,
    // The admin roster reports the MODEL's state (`submitted`), while a
    // candidate's own list reports the BUCKET it was filed under
    // (`completed`, `closed`). Both mean the same terminal thing, and
    // falling back to `pending` for the second spelling silently made a
    // submitted attempt look unstarted - which hid every released result
    // on the candidate's own screens.
    orElse: () => v == 'completed' || v == 'closed'
        ? AttemptState.submitted
        : AttemptState.pending,
  );
}

/// ── Scoring filter ────────────────────────────────────────────────────────
///
/// The Candidates tab's two chips after Submitted. NOT attempt states: they
/// split `submitted` by its ANSWERS, server-side - Scored = no answer that
/// needs the grader is unscored, Score Pending = at least one is, and the two
/// add up to Submitted. An objective-only candidate never gets a
/// candidate-level "scored", so a candidate state could not answer this.
///
/// [wire] travels in the roster route's `state` parameter and keys
/// `meta.counts`, beside the [AttemptState] wires.
enum ScoringFilter {
  scored('scored', 'Scored'),
  scorePending('score_pending', 'Score Pending');

  final String wire;
  final String label;

  const ScoringFilter(this.wire, this.label);
}

/// ── Invitation ────────────────────────────────────────────────────────────
///
/// `none -> queued -> sent`, with `failed` reachable from `queued` and
/// recoverable back to `sent` by requeueing. [none] means assigned but not yet
/// launched.
enum InviteState {
  none('none', 'Not sent', Tone.inert),
  queued('queued', 'Queued', Tone.warn),
  sent('sent', 'Sent', Tone.ok),
  failed('failed', 'Failed', Tone.bad);

  final String wire;
  final String label;
  final Tone tone;

  const InviteState(this.wire, this.label, this.tone);

  static InviteState parse(String? v) => values.firstWhere(
    (InviteState s) => s.wire == v,
    orElse: () => InviteState.none,
  );
}

/// ── Subjective scoring ────────────────────────────────────────────────────
///
///     not_needed
///     pending -> queued -> scoring -> scored
///                            │
///                            ├──▶ failed    (retried automatically)
///                            ├──▶ error     (terminal; NOT retried)
///                            └──▶ cancelled (terminal; an admin killed the run)
///
/// [notNeeded] covers every objective answer and every blank subjective one.
enum LlmState {
  notNeeded('not_needed', 'Not needed', Tone.inert),
  pending('pending', 'Pending', Tone.inert),
  queued('queued', 'Queued', Tone.info),
  scoring('scoring', 'Scoring', Tone.info),
  scored('scored', 'Scored', Tone.ok),
  failed('failed', 'Failed', Tone.warn),

  /// Terminal. Deliberately excluded from the automatic retry set - an
  /// attempt frozen on pending until a person acts is the point.
  error('error', 'Scoring error', Tone.bad),

  /// An admin killed the scoring run before it reached this answer. NOT `bad`:
  /// a kill is an outcome somebody chose, the same way a cancelled generation
  /// is - colouring it like a failure invites a support question about a run
  /// that stopped exactly when asked.
  ///
  /// It IS terminal, and it IS [unresolved]. The answer was never graded, so
  /// letting the attempt compute a verdict on it would score it zero and turn
  /// an admin pressing Kill into a candidate's FAIL - a worse version of the
  /// exact outcome Invariant 4 exists to prevent, because nobody decided
  /// anything about the candidate. Holding the result at pending is the safe
  /// direction and says the true thing: this paper is not finished.
  ///
  /// It stays out of [autoRetry] (a cron must never undo a deliberate stop) and
  /// out of [manualRescore] / [scoringFailed] (Score Failed Responses must not
  /// re-spend on somebody an admin just stopped - a person queues them again on
  /// purpose).
  cancelled('cancelled', 'Cancelled', Tone.inert);

  final String wire;
  final String label;
  final Tone tone;

  const LlmState(this.wire, this.label, this.tone);

  static LlmState parse(String? v) => values.firstWhere(
    (LlmState s) => s.wire == v,
    orElse: () => LlmState.notNeeded,
  );

  /// Invariant 4: any subjective answer in one of these states forces the
  /// attempt's result to pending, whatever the score. This prevents an
  /// infrastructure failure - or an admin's own Kill - from being recorded as
  /// a candidate's failure. [cancelled] belongs here for the same reason the
  /// rest do: the answer carries no grade, so a verdict computed over it is a
  /// verdict over a zero nobody awarded.
  static const Set<LlmState> unresolved = <LlmState>{
    pending,
    queued,
    scoring,
    failed,
    error,
    cancelled,
  };

  bool get isUnresolved => unresolved.contains(this);

  /// Invariant 5: the automatic retry set excludes [error].
  static const Set<LlmState> autoRetry = <LlmState>{pending, queued, failed};

  /// The two states the "Score Failed Responses" button reasons about: a
  /// recoverable [failed] and a terminal [error]. This is the client half of
  /// the `states: ['failed','error']` the requeue route now takes, kept here
  /// rather than as a pair of string literals so a rename of either state
  /// cannot leave the button counting the wrong thing. [cancelled] is NOT in
  /// it - a deliberate stop is not a failure to recover.
  static const Set<LlmState> scoringFailed = <LlmState>{failed, error};

  /// What a person may re-score by hand - this one does include [error],
  /// because a person is the thing the terminal state was waiting for.
  static const Set<LlmState> manualRescore = <LlmState>{
    pending,
    queued,
    scoring,
    failed,
    error,
  };
}

/// ── Scoring run ───────────────────────────────────────────────────────────
///
///     idle ──an operator queues a cohort──▶ queued ──▶ scoring ──▶ idle
///                                             │  ▲        │
///                            the cron dies ───┘  └── it   │
///                                             │   is revived
///                                          stalled        │
///                                             │           │
///                                             └──kill─────┴─▶ stopping ──▶ idle
///
/// WHAT THE SERVER SAYS THE CRON IS DOING, as opposed to what this client can
/// infer. The console's attempts cache is capped at 25 pages x 200 rows across
/// EVERY assessment, so on a cohort past that window "is grading running?"
/// derived client-side answers according to how much of the roster happened to
/// be loaded. The module computes this from the scoring cron's own selection
/// predicate, which is the only thing that knows what the cron will pick up.
///
/// A NULL PHASE IS NOT [idle]. Absent means a deployment that predates the
/// field, and reading that as "there is nothing to stop" would hide the Kill
/// button on a server where grading genuinely was in flight. Readers fall back
/// to their own client-side derivation on null, so [parse] answers null for a
/// value it does not recognise as well as for one that never arrived - a phase
/// this build has not met must not be flattened into the one phase that turns
/// the controls off.
enum ScoringPhase {
  /// There is genuinely nothing to stop.
  idle('idle', 'Idle', Tone.inert),

  /// Candidates carry `scoring_requested` and are waiting for the grader.
  queued('queued', 'Queued', Tone.info),

  /// A worker is holding a row and an LLM call is on the wire.
  scoring('scoring', 'Scoring', Tone.info),

  /// A kill has been requested and the in-flight lane will refuse its next
  /// call. Not `bad` for the same reason [LlmState.cancelled] is not: a stop
  /// is an outcome somebody chose.
  stopping('stopping', 'Stopping', Tone.warn),

  /// Work is QUEUED AND NOTHING WILL DRAIN IT: the grading cron is inactive,
  /// or more than fifteen minutes past its own `nextcall`. `bad` under the one
  /// rule the tone map exists to keep - red means failure or absence - because
  /// this is the absence of the grader itself, not a state the work passes
  /// through on its way somewhere.
  ///
  /// THE DISTINCTION IS THE WHOLE VALUE. On 2026-09-03 all four grading crons
  /// sat inactive with `nextcall` frozen six hours in the past, 1,948 answers
  /// queued and 6 scored. A queue that grows because nobody is draining it
  /// looks exactly like a queue that grows because the cohort is large, so
  /// [queued] was true and completely misleading for the length of the outage.
  ///
  /// The module's own label is "Grader Not Running". This one is shorter
  /// because it renders into a 120px list column, where the long form
  /// ellipsizes to "Grader Not..." and says nothing at all.
  stalled('stalled', 'Not running', Tone.bad);

  final String wire;
  final String label;
  final Tone tone;

  const ScoringPhase(this.wire, this.label, this.tone);

  static ScoringPhase? parse(String? v) {
    for (final ScoringPhase p in values) {
      if (p.wire == v) return p;
    }
    return null;
  }

  /// Is something going to change on its own? Kept here so the status banner
  /// and the poll that drives it cannot come to disagree about which phases
  /// count as a run in flight.
  ///
  /// [stalled] IS NOT BUSY, and that is the point of it rather than an
  /// oversight. Nothing settles a stalled queue - the cron that would drain it
  /// is dead - so a watch armed on it would poll for the rest of the session
  /// waiting for a change that cannot arrive. Leaving it out is also what
  /// SURFACES it: a watch running on [queued] reads `stalled`, finds it
  /// terminal, stops, and spends its one closing detail read putting the
  /// warning on screen. The module's `be_auto_refresh` widget omits it from
  /// its own busy set for exactly this reason, and the two must not diverge.
  bool get isBusy =>
      this == ScoringPhase.queued ||
      this == ScoringPhase.scoring ||
      this == ScoringPhase.stopping;

  /// Can a Kill still settle something? This STOPPED BEING THE SAME QUESTION
  /// as [isBusy] when [stalled] arrived, and collapsing the two would have
  /// taken the Kill button away at the one phase where it matters most: a
  /// stalled run has a queue - having one is what makes it stalled - and
  /// parking that queue is the only thing an operator can do about a dead cron
  /// from this console. So the button stays reachable exactly where the watch
  /// must not arm. Mirrors the module's own gate, `scoring_phase != 'idle'`.
  bool get isStoppable => this != ScoringPhase.idle;
}

/// ── Result ────────────────────────────────────────────────────────────────
///
/// `pending -> pass | fail`. [pending] is not merely an initial state: it is
/// FORCED whenever any subjective answer on the attempt is unresolved, which
/// includes the terminal error.
enum ResultState {
  pending('pending', 'Pending', Tone.inert),
  pass('pass', 'Pass', Tone.ok),
  fail('fail', 'Fail', Tone.bad);

  final String wire;
  final String label;
  final Tone tone;

  const ResultState(this.wire, this.label, this.tone);

  static ResultState parse(String? v) => values.firstWhere(
    (ResultState s) => s.wire == v,
    orElse: () => ResultState.pending,
  );
}

/// ── Draft question ────────────────────────────────────────────────────────
///
/// `draft -> approved | denied`. Approval creates a bank question; the undo
/// reverses both halves.
enum DraftState {
  draft('draft', 'Draft', Tone.inert),
  approved('approved', 'Approved', Tone.ok),
  denied('denied', 'Denied', Tone.bad);

  final String wire;
  final String label;
  final Tone tone;

  const DraftState(this.wire, this.label, this.tone);

  static DraftState parse(String? v) => values.firstWhere(
    (DraftState s) => s.wire == v,
    orElse: () => DraftState.draft,
  );
}

/// ── Asset render - image and video ────────────────────────────────────────
///
/// `pending -> rendering -> rendered`, with `failed` from `rendering`,
/// `uploaded` reachable at any point by human replacement, and `partial` for
/// video only, meaning some clips rendered and others did not.
enum AssetState {
  pending('pending', 'Pending', Tone.inert),
  rendering('rendering', 'Rendering', Tone.info),
  rendered('rendered', 'Rendered', Tone.ok),
  failed('failed', 'Failed', Tone.bad),
  uploaded('uploaded', 'Uploaded', Tone.ok),

  /// Video only.
  partial('partial', 'Partial', Tone.warn);

  final String wire;
  final String label;
  final Tone tone;

  const AssetState(this.wire, this.label, this.tone);

  static AssetState? parse(String? v) {
    if (v == null || v.isEmpty) return null;
    for (final AssetState s in values) {
      if (s.wire == v) return s;
    }
    return null;
  }

  bool get needsAttention => this == failed || this == partial;
}

/// ── Generation ────────────────────────────────────────────────────────────
///
/// `idle -> queued -> generating -> finalizing -> done | failed`.
///
/// All six states the module actually stores. An earlier version knew only
/// four, so `queued`, `generating` and `finalizing` all fell through the
/// parser's fallback and rendered as **Idle** - a generation that was really
/// running looked like one that had never started.
enum GenState {
  idle('idle', 'Idle', Tone.inert),
  queued('queued', 'Queued', Tone.info),
  generating('generating', 'Generating', Tone.info),
  finalizing('finalizing', 'Finalizing', Tone.info),
  done('done', 'Done', Tone.ok),
  failed('failed', 'Failed', Tone.bad),

  /// An admin stopped the run. NOT `bad`: a kill is an outcome somebody chose,
  /// and colouring it like a failure invites a support question about a run
  /// that worked exactly as asked.
  cancelled('cancelled', 'Cancelled', Tone.inert);

  final String wire;
  final String label;
  final Tone tone;

  const GenState(this.wire, this.label, this.tone);

  /// Every state where work is outstanding, whether the cron has picked it up
  /// yet or not. Callers that poll should ask this rather than compare
  /// against one value, so a new intermediate state cannot silently end the
  /// wait early.
  bool get isBusy => this == queued || this == generating || this == finalizing;

  /// Whether a run in this state can still be stopped. `finalizing` counts:
  /// the spending is over but the verdict is not yet written, and an admin who
  /// pressed Kill should see 'Cancelled' rather than 'Done'.
  bool get isCancellable => isBusy;

  static GenState parse(String? v) => values.firstWhere(
    (GenState s) => s.wire == v,
    orElse: () => GenState.idle,
  );
}

/// All FIVE server values. It carried only idle and done, so `queued`,
/// `generating` and - the one that matters - `failed` all fell through to the
/// `orElse` and rendered as "Not extracted". A failed extraction was therefore
/// indistinguishable from one nobody had run, and the error text sitting in
/// `tagExtractError` had no badge to explain it.
/// A generator's own lifecycle, distinct from either of its two run states.
///
/// The server has sent this as `state` all along (`generator_row`) and this
/// side never read it, so the list had no way to show that a generator was
/// still a draft - the one thing an examiner scanning it wants to know before
/// opening anything.
/// The three things this app can import from a CSV.
///
/// ONE ENUM RATHER THAN THREE CODE PATHS. All three uploads go to the same
/// server-side spec and come back in the same shape, so the only thing that
/// varies is the route and the words on the sheet. Keeping that in one place
/// is what stops a fourth entity growing its own parser - which is exactly how
/// question import ended up with two incompatible column specs.
enum ImportEntity {
  questions(
    'bank',
    'questions',
    'Import questions',
    'CSV or harness JSON arrive as drafts for review; a native JSON bank '
        'export restores questions straight into the bank.',
  ),
  generators(
    'generators',
    'generators',
    'Import generators',
    'CSV. A row whose name already exists updates that generator; the SOP '
        'document is uploaded separately.',
  ),
  tags(
    'tags',
    'tags',
    'Import tags',
    'CSV. A row whose name already exists updates that tag rather than adding '
        'a second one.',
  );

  /// The API path segment: `/api/v1/<route>/import` and `/<route>/template`.
  final String route;
  final String plural;
  final String title;
  final String sub;

  const ImportEntity(this.route, this.plural, this.title, this.sub);

  /// What a file picker should offer. Questions accept JSON as well, because
  /// the module has two JSON formats besides its CSV one.
  String get accept => this == ImportEntity.questions
      ? '.csv,.json,text/csv,application/json'
      : '.csv,text/csv';
}

enum GeneratorState {
  draft('draft', 'Draft', Tone.inert),
  skillsReady('skills_ready', 'Tags extracted', Tone.info),
  generating('generating', 'Generating', Tone.info),
  done('done', 'Ready', Tone.ok);

  final String wire;
  final String label;
  final Tone tone;

  const GeneratorState(this.wire, this.label, this.tone);

  static GeneratorState parse(String? v) => values.firstWhere(
    (GeneratorState s) => s.wire == v,
    orElse: () => GeneratorState.draft,
  );
}

enum TagExtractState {
  idle('idle', 'Not extracted', Tone.inert),
  queued('queued', 'Queued', Tone.info),
  generating('generating', 'Extracting', Tone.info),
  done('done', 'Extracted', Tone.ok),
  failed('failed', 'Extraction failed', Tone.bad);

  final String wire;
  final String label;
  final Tone tone;

  const TagExtractState(this.wire, this.label, this.tone);

  static TagExtractState parse(String? v) => values.firstWhere(
    (TagExtractState s) => s.wire == v,
    orElse: () => TagExtractState.idle,
  );
}

/// ── Job ───────────────────────────────────────────────────────────────────
///
/// `queued -> running -> done`, with `failed` and `partial` as recoverable
/// ends carrying a retry.
enum JobState {
  queued('queued', 'Queued', Tone.info),
  running('running', 'Running', Tone.info),
  done('done', 'Done', Tone.ok),
  failed('failed', 'Failed', Tone.bad),
  partial('partial', 'Partial', Tone.warn);

  final String wire;
  final String label;
  final Tone tone;

  const JobState(this.wire, this.label, this.tone);

  static JobState parse(String? v) => values.firstWhere(
    (JobState s) => s.wire == v,
    orElse: () => JobState.queued,
  );

  bool get isTerminal => this == done || this == failed || this == partial;
  bool get canRetry => this == failed || this == partial;
}

enum JobKind { generate, image, video, detect, tags }

/// What happened to an uploaded file.
///
/// ONE WORD FOR EVERY FILE THAT LANDED, and it is "Stored".
///
/// The module distinguishes four outcomes - `pending` (held, text not pulled
/// yet), `ready` (a text layer came out), `native` (a PDF or image that goes to
/// the model as an inline document part, so no text is expected) and `failed`.
/// Three of those are the same fact from the operator's seat: the file is on
/// the record and the generator will read it. Which of them a document landed
/// in is decided by its FORMAT, not by anything anyone did or should do about
/// it - a .docx read "Ready" and the SOP beside it read "Stored", inviting the
/// question of what was wrong with the PDF. Nothing was.
///
/// `failed` stays its own state because it is the one that is actionable: the
/// file did not land, and there is a Re-upload beside it.
enum ResourceStatus {
  pending('pending', 'Stored', Tone.inert),
  ready('ready', 'Stored', Tone.inert),
  native('native', 'Stored', Tone.inert),
  failed('failed', 'Failed', Tone.bad);

  final String wire;
  final String label;
  final Tone tone;

  const ResourceStatus(this.wire, this.label, this.tone);

  static ResourceStatus parse(String? v) => values.firstWhere(
    (ResourceStatus s) => s.wire == v,
    orElse: () => ResourceStatus.ready,
  );
}

/// What a file is FOR, in the same words the tab that uploads it uses.
///
/// `reference` read "Reference" while the section that attaches one is titled
/// "Reference files", so the Resources table named a role the operator had
/// never seen written that way. The chip and the uploader now agree.
enum ResourceKind {
  sop('sop', 'SOP'),
  reference('reference', 'Reference files'),
  vendor('vendor', 'Vendor'),
  client('client', 'Client'),
  sample('sample', 'Sample questions'),
  // The server accepts this and the client did not know it, so an
  // "other" document silently displayed as "Reference".
  other('other', 'Other');

  final String wire;
  final String label;

  const ResourceKind(this.wire, this.label);

  /// `golden` is the OLD NAME FOR [sample] (owner, 2026-09-29: "Golden
  /// questions and Sample questions are the same thing"). Rows stored before
  /// the server migrates them still say `golden`, so they parse into the one
  /// Sample questions list. There is deliberately no `golden` value, so
  /// nothing in this app can upload a new one.
  static ResourceKind parse(String? v) => v == 'golden'
      ? ResourceKind.sample
      : values.firstWhere(
          (ResourceKind k) => k.wire == v,
          orElse: () => ResourceKind.reference,
        );
}

/// ── The seven question types ───────────────────────────────────────────────
///
/// Mirrors `QUESTION_TYPE_SELECTION` in the module's `constants.py`. Only
/// [mcq] and [msq] are objective; the other five are marked by the judge.
/// ONE VOCABULARY, SHARED WITH FORM STUDIO.
///
/// These labels are the FALLBACK shown when no template authored a question
/// (see `Question.taskLabel`, which prefers the examiner's task name). The
/// fallback used to speak a second, older vocabulary: an annotation question
/// badged "Labelling" on the Responses table and "Image annotation" in Form
/// Studio, and a side-by-side comparison badged "Image A/B" - the name of the
/// rendering engine - on one screen and "Side-by-side comparison" on the other.
/// An operator reading both screens had no way to know those were the same
/// type, and "Labelling" is not a phrase the designer ever shows them.
///
/// The wire values are UNCHANGED and are what the module stores; only the
/// display strings move. `FormItemKind.label` in `form_models.dart` is the
/// other half of this pairing - change one and change both, or the two screens
/// drift apart again.
enum QType {
  mcq('mcq', 'Objective · MCQ', 'MCQ'),
  msq('msq', 'Objective · MSQ', 'MSQ'),
  subjectiveRubric('subjective_rubric', 'Subjective · Rubric', 'Rubric'),
  imageAb(
    'image_ab',
    'Image · Side-by-side comparison',
    'Side-by-side comparison',
  ),
  imagePrompt('image_prompt', 'Image · Prompt writing', 'Prompt writing'),
  imageLabel('image_label', 'Image · Annotation', 'Image annotation'),
  videoPrompt('video_prompt', 'Video · Prompt writing', 'Video prompt writing'),

  /// A clip the candidate transcribes (Hindi or English) and describes:
  /// category, sound characteristics, speakers. Authored only in Form Studio
  /// and graded by the LLM judge with the client's critical/minor rule.
  transcription('transcription', 'Audio · Transcription', 'Transcription'),

  /// A type the server sent that this build does not know (A-053). It used to
  /// parse as [mcq], so a new type rendered as a multiple-choice question with
  /// nothing to pick. The runner shows a "not supported" panel instead, and it
  /// is never offered as something to author - see [isGeneratable], [known].
  unsupported('unsupported', 'Unsupported question type', 'Unsupported');

  final String wire;

  /// `TYPE_LABEL` - the long form used in tables and headers.
  final String label;

  /// The short form used where a column is narrow.
  final String short;

  const QType(this.wire, this.label, this.short);

  /// A MISSING type still reads as [mcq], as it always has; only a type that
  /// is present and unrecognised becomes [unsupported].
  static QType parse(String? v) => values.firstWhere(
    (QType q) => q.wire == v,
    orElse: () => v == null || v.isEmpty ? QType.mcq : QType.unsupported,
  );

  /// Every type this build can draw - [values] without [unsupported].
  static List<QType> get known =>
      values.where((QType q) => q != QType.unsupported).toList();

  /// `OBJECTIVE_TYPES = ["mcq", "msq"]`.
  ///
  /// This is a SCORING question - is the mark decided by matching options, or
  /// by a grader? Do not widen it to cover `image_ab` just because that type
  /// has options: it is graded subjectively, and moving it here would silently
  /// change how it is seed-graded, whether it is queued for the LLM, whether it
  /// needs a reviewed rubric, and whether launch gate 6 applies to it - a gate
  /// the module does not enforce for it, so the client would start refusing
  /// launches the server would accept. Use [hasOptionKey] for shape.
  bool get isObjective => this == QType.mcq || this == QType.msq;
  bool get isSubjective => !isObjective;

  /// Types whose answer key IS a dimension tree - options carrying a correct
  /// flag - and which therefore render and edit as chips.
  ///
  /// Deliberately not [isObjective]. `image_ab` keys one axis per rating
  /// criterion and is still marked by a grader, so "how is it scored" and "what
  /// shape is its key" are two different questions; this is the second. Three
  /// surfaces used to answer it three different ways, which is why an A/B
  /// question's axes rendered nowhere in the preview.
  bool get hasOptionKey =>
      this == QType.mcq || this == QType.msq || this == QType.imageAb;

  /// True when the type's own answer layout draws the stimulus.
  ///
  /// The three that do not are the reason a preview has to draw it itself: an
  /// mcq carrying an image showed the question and no picture.
  /// EVERY answer layout draws its own media now, so this is always true.
  ///
  /// It used to exclude mcq, msq and subjective_rubric, and a preview screen
  /// used that to decide whether to draw the stimulus itself. Those three
  /// learned to draw media when Form Studio began publishing an
  /// imageBlock/videoBlock WITH options as an mcq - each guarded on the
  /// question actually carrying some - and nothing revisited this getter, so
  /// the preview drew a second copy of every clip and picture.
  ///
  /// Kept rather than deleted: the question it answers ("must a caller draw
  /// the stimulus itself?") is a real one, and a future layout that renders no
  /// media would want to say so here rather than have every caller rediscover
  /// it.
  bool get layoutDrawsMedia => true;

  /// Mirrors the module's `NON_GENERATABLE_QUESTION_TYPES`: [transcription]
  /// only, because its clip and correct answers come from a real recording the
  /// examiner uploads, which a generator cannot invent.
  ///
  /// It stays a getter rather than being deleted because the rule it encodes
  /// outlives any one type. A type the LLM pipeline cannot author must not be
  /// offerable as a generation target: selecting it would produce a generator
  /// that silently yields nothing for that type, which reads as a broken
  /// generator rather than an unsupported choice. The module keeps its own
  /// constant for the same reason, so retiring a type from generation stays a
  /// one-line change on both sides instead of a hunt for the guards.
  ///
  /// [unsupported] is the one exception: nothing can author a type this build
  /// cannot even name.
  bool get isGeneratable =>
      this != QType.unsupported && this != QType.transcription;

  /// The types a generator may be asked to author. Derived, so adding a type
  /// to the enum does not require finding every picker.
  static List<QType> get generatable =>
      values.where((QType q) => q.isGeneratable).toList();

  bool get needsImage =>
      this == QType.imageAb ||
      this == QType.imagePrompt ||
      this == QType.imageLabel;
  bool get needsVideo => this == QType.videoPrompt;

  bool get isMultiSelect => this == QType.msq;
}

/// The server's vocabulary, from `etp_assessment_pro/constants.py`:
/// `DIFFICULTY_SELECTION = [("easy",...), ("medium",...), ("hard",...)]`.
///
/// This used to read `recall|application|judgement`, which the module has never
/// sent - so `parse` fell to its `orElse` on every row and the whole bank
/// displayed as one difficulty.
enum Difficulty {
  easy('easy', 'Easy'),
  medium('medium', 'Medium'),
  hard('hard', 'Hard');

  final String wire;
  final String label;

  const Difficulty(this.wire, this.label);

  static Difficulty parse(String? v) => values.firstWhere(
    (Difficulty d) => d.wire == v,
    orElse: () => Difficulty.medium,
  );
}

/// How close two generators are, in the MODULE'S OWN vocabulary.
///
/// These were `high` / `medium` / `low`, which no server ever sends: Odoo
/// stores `near-duplicate` / `same-family` / `new-territory`. So every band
/// fell through `parse`'s fallback and rendered as "Low", including a pair the
/// module had labelled a near-duplicate.
///
/// The module's names are kept rather than translated back to high/medium/low
/// because they carry the ACTION, which a severity word does not: a
/// near-duplicate is probably a revision (diff it before rebuilding), a
/// same-family SOP is a different task whose worker pool and renderer likely
/// carry over, and new territory is a build from scratch.
enum SimBand {
  nearDuplicate('near-duplicate', 'Near-duplicate', Tone.bad),
  sameFamily('same-family', 'Same family', Tone.warn),
  newTerritory('new-territory', 'New territory', Tone.inert);

  final String wire;
  final String label;
  final Tone tone;

  const SimBand(this.wire, this.label, this.tone);

  /// What the band means for what to do next.
  String get guidance => switch (this) {
    SimBand.nearDuplicate =>
      'Probably a revision of the other SOP. Diff them before rebuilding.',
    SimBand.sameFamily =>
      'A different task, but the worker pool, cutoff and renderer likely '
          'carry over.',
    SimBand.newTerritory => 'Nothing else covers this ground. Build fresh.',
  };

  static SimBand parse(String? v) => values.firstWhere(
    (SimBand b) => b.wire == v,
    orElse: () => SimBand.newTerritory,
  );
}

/// How a similarity score was arrived at.
///
/// Carried because the module degrades honestly: a semantic pass that fails
/// its retries is filed as `lexical-fallback`, never `hybrid`, so a
/// lexical-only number is never read as a blended one.
enum SimMode {
  hybrid('hybrid', 'Lexical + AI'),
  lexicalFallback('lexical-fallback', 'Lexical only - the AI pass failed'),
  lexical('lexical', 'Lexical only');

  final String wire;
  final String label;

  const SimMode(this.wire, this.label);

  static SimMode parse(String? v) => values.firstWhere(
    (SimMode m) => m.wire == v,
    orElse: () => SimMode.lexical,
  );
}

/// What happens when the violation cap is reached.
enum ViolationAction {
  autoSubmit('auto_submit', 'Auto-submit the exam'),
  logOnly('log_only', 'Log only');

  final String wire;
  final String label;

  const ViolationAction(this.wire, this.label);

  static ViolationAction parse(String? v) => values.firstWhere(
    (ViolationAction a) => a.wire == v,
    orElse: () => ViolationAction.logOnly,
  );

  bool get isAuto => this == ViolationAction.autoSubmit;
}

/// What the violation settings actually DO, as a strong line and a body line,
/// in the one place all three surfaces read it from.
///
/// THE ACTION DECIDES WHETHER, THE CAP DECIDES WHEN (A-074, owner rule):
/// reaching the limit marks the attempt "Violation Limit Breached" for the
/// candidate and the organiser in BOTH modes, and only Auto-submit also ends
/// the exam there (cap 0: on the first one). Log only never ends it, at any
/// cap, and with no cap has no limit to breach. Derived here from both
/// fields, because three screens state it.
///
/// [candidate]: the instructions page, which speaks to the candidate as "you".
/// The admin wording is unchanged.
({String strong, String text}) violationConsequence(
  ViolationAction action,
  int cap, {
  bool candidate = false,
}) {
  final String breached = candidate
      ? 'marks the attempt Violation Limit Breached, shown to you and the '
            'organiser'
      : 'marks the attempt Violation Limit Breached for the candidate and the '
            'organiser';
  if (!action.isAuto) {
    return (
      strong: 'The exam is never ended automatically.',
      text: cap > 0
          ? 'Violations are recorded and surfaced for review. Reaching $cap '
                '$breached - only Auto-submit ends the exam.'
          : 'Violations are recorded and surfaced for review.',
    );
  }
  if (cap > 0) {
    final String warned = cap == 1
        ? 'At this setting the first violation ends the exam.'
        : !candidate
        ? 'Candidates get ${cap - 1} warned violation(s) first.'
        : 'You get ${cap - 1} warned '
              '${cap == 2 ? 'violation' : 'violations'} first.';
    return (
      strong: 'The exam auto-submits on violation $cap.',
      text: '$warned Reaching $cap also $breached.',
    );
  }
  return (
    strong: 'The exam auto-submits on the first violation.',
    text:
        'With no cap set, Auto-submit ends the exam as soon as one '
        'violation is recorded, and $breached.',
  );
}

/// The nine proctoring rules. Seven can produce a violation; [watermark] and
/// [seb] cannot - one tiles the candidate's name across the exam surface, the
/// other is a gate the server enforces before a question is served. [webcam]
/// BOTH blocks (while the camera is off) and fires, once a granted camera is
/// lost mid-exam.
///
/// There was an eighth, `screenshot`. It was removed: OS capture shortcuts
/// are consumed by the operating system before the browser is told, so it
/// could only ever be best-effort, and on macOS - a large share of these
/// sittings - the bare PrintScreen key it started life detecting does not
/// exist at all. A control that reports nothing on the platform half your
/// candidates use is worse than no control, because it reads as one.
enum ProctorRule {
  tabSwitch('tab_switch', 'Block tab switching', 'Tab switched'),
  copyPaste('copy_paste', 'Block copy and paste', 'Clipboard action: paste'),
  rightClick('right_click', 'Block right-click', 'Right-click attempted'),
  devtools('devtools', 'Detect developer tools', 'Developer tools detected'),
  fullscreen('fullscreen', 'Require fullscreen', 'Exited fullscreen'),
  webcam('webcam', 'Require webcam', 'Webcam turned off / lost'),

  /// Face and phone detection on the webcam preview (`web/proctor_ai.js`).
  /// Fires four reasons, all prefixed `AI: `; [violationLabel] is the one the
  /// simulator rig fires. Needs [webcam]: the server refuses it alone.
  aiProctor('ai_proctor', 'AI proctoring', 'AI: phone detected'),
  watermark('watermark', 'Watermark the exam', ''),
  seb('seb', 'Require Safe Exam Browser', '');

  final String wire;

  /// The label on the settings switch.
  final String label;

  /// `data-violate` - the recorded reason. Empty for the two rules that do not
  /// produce a violation.
  final String violationLabel;

  const ProctorRule(this.wire, this.label, this.violationLabel);

  static ProctorRule parse(String? v) => values.firstWhere(
    (ProctorRule r) => r.wire == v,
    orElse: () => ProctorRule.tabSwitch,
  );

  /// The ODOO FIELD NAME this rule writes to, which is NOT [wire].
  ///
  /// The module reads rules back out under the short names ([wire]) but only
  /// accepts them on a write under these longer ones - `ASSESSMENT_FIELDS` in
  /// `controllers/api/write.py` allow-lists `rule_block_tab_switch` and
  /// friends, and drops any key it does not name. `createAssessment` sent the
  /// short spellings, so every one of the eight toggles was discarded and the
  /// route still answered 200: an operator configured proctoring on a new
  /// assessment and got the module's defaults instead, with nothing to show
  /// anything had been ignored. The update route always used these names,
  /// which is why editing an assessment worked and creating one did not.
  String get field => switch (this) {
    ProctorRule.tabSwitch => 'rule_block_tab_switch',
    ProctorRule.copyPaste => 'rule_block_copy_paste',
    ProctorRule.rightClick => 'rule_block_right_click',
    ProctorRule.devtools => 'rule_block_devtools',
    ProctorRule.fullscreen => 'rule_fullscreen',
    ProctorRule.webcam => 'rule_webcam',
    ProctorRule.aiProctor => 'rule_ai_proctor',
    ProctorRule.watermark => 'rule_watermark',
    ProctorRule.seb => 'rule_require_seb',
  };

  /// The switch this one needs on first (the server refuses it alone), or
  /// null. Turning the parent off turns this off in the same save
  /// (`RuleSet.set`).
  ProctorRule? get parent => switch (this) {
    ProctorRule.aiProctor => ProctorRule.webcam,
    _ => null,
  };

  /// The seven rules that can be recorded as a violation.
  ///
  /// [watermark] cannot: it tiles a name across the page and fires nothing.
  /// Nor can [seb]: outside Safe Exam Browser the server serves no question. [webcam] joined this set when the real watcher gained a reason
  /// string for a camera lost mid-exam.
  bool get firesViolation => violationLabel.isNotEmpty;

  /// The hint shown under each switch on the configuration surface.
  String get hint => switch (this) {
    ProctorRule.tabSwitch => 'Leaving the exam tab is recorded as a violation.',
    ProctorRule.copyPaste =>
      'Paste into an answer field is blocked and recorded.',
    ProctorRule.rightClick =>
      'The context menu is suppressed on the exam surface.',
    ProctorRule.devtools => 'An open inspector is detected and recorded.',
    ProctorRule.fullscreen =>
      'The exam asks for fullscreen; leaving it is recorded.',
    ProctorRule.webcam =>
      'Only the on-off state is monitored, unless AI proctoring is also on. '
          'No video is stored.',
    ProctorRule.aiProctor =>
      'Flags an empty seat, a second person or a phone on camera. Stores a '
          'camera snapshot at the start, every 2 minutes, and when a check '
          'trips (every 30 seconds while it lasts). Needs Require webcam. '
          'Made for Chrome.',
    ProctorRule.watermark =>
      'The candidate name and email are tiled across the exam surface.',
    ProctorRule.seb =>
      'Candidates can open the exam only in Safe Exam Browser (free, for '
          'Windows and macOS), which keeps the computer locked to the exam '
          'until they submit. Invigilators close it early with the quit '
          'password.',
  };

  /// The rule as the CANDIDATE reads it: imperative, second person, one line.
  ///
  /// SEPARATE FROM [hint], and that separation is the point. [hint] is operator
  /// copy on a configuration switch, written in the third person about the
  /// system - "The candidate name and email are tiled across the exam
  /// surface." The instructions page printed [hint] verbatim, which is how a
  /// page of prohibitions came to read as a system description, and why a
  /// candidate could finish it without learning that switching tabs would end
  /// their exam. Rewording [hint] for a candidate was not an option: the two
  /// admin config surfaces read it, and an operator needs to know what the
  /// switch DOES.
  ///
  /// [prohibition] picks the glyph. [fullscreen] and [webcam] are states to
  /// HOLD rather than acts to avoid, so "Do not leave fullscreen" would be a
  /// double negative for the thing being asked; they keep the imperative mood
  /// without the negation and take a check rather than a deny mark.
  ({String text, bool prohibition}) get candidateRule => switch (this) {
    ProctorRule.tabSwitch => (
      text: 'Do not switch tabs or windows.',
      prohibition: true,
    ),
    ProctorRule.copyPaste => (text: 'Do not copy or paste.', prohibition: true),
    ProctorRule.rightClick => (text: 'Do not right-click.', prohibition: true),
    ProctorRule.devtools => (
      text: 'Do not open developer tools.',
      prohibition: true,
    ),
    ProctorRule.fullscreen => (text: 'Stay in fullscreen.', prohibition: false),
    ProctorRule.webcam => (text: 'Keep your camera on.', prohibition: false),
    ProctorRule.aiProctor => (
      text: 'Stay in view, alone, with no phone.',
      prohibition: false,
    ),
    // Not an instruction: there is nothing for a candidate to do about it.
    // The instructions page keeps it out of the rule list for that reason and
    // prints it as a footnote, so it cannot dilute the seven that bite.
    ProctorRule.watermark => (
      text: 'Your name and email are shown on screen.',
      prohibition: false,
    ),
    // A footnote like the watermark: by the time a candidate reads it they
    // are already inside Safe Exam Browser.
    ProctorRule.seb => (
      text:
          'This assessment runs in Safe Exam Browser, which keeps your '
          'computer locked to the exam until you submit.',
      prohibition: false,
    ),
  };
}

/// The bucket a candidate's attempt falls into on `#/me/assessments`.
///
/// Resolution order matters: [completed] is checked first, so it wins over
/// every assessment state.
enum Bucket {
  all('all', 'All'),
  available('available', 'Available'),
  inProgress('in_progress', 'In progress'),
  upcoming('upcoming', 'Upcoming'),
  completed('completed', 'Completed'),
  closed('closed', 'Closed');

  final String wire;
  final String label;

  const Bucket(this.wire, this.label);

  static Bucket parse(String? v) =>
      values.firstWhere((Bucket b) => b.wire == v, orElse: () => Bucket.all);
}

/// The two roles the module actually defines.
///
/// `etp_assessment_pro/security/etp_assessment_security.xml` declares exactly
/// two groups - `group_assessment_manager` ("Manager") and
/// `group_assessment_evaluator` ("Evaluator"). There is no Program Manager
/// group, no record rule for one and no menu scoped to one, so a third portal
/// here would be a surface with nothing behind it.
enum Portal {
  admin('admin', 'Admin', 'Aarav Mehta'),
  member('member', 'Candidate', 'Sana Kapoor');

  final String wire;
  final String label;

  /// The persona the rail's account block shows.
  final String persona;

  const Portal(this.wire, this.label, this.persona);

  /// Maps an ORG role from `pod_roles` / `api_auth_gateway` onto a portal.
  ///
  /// The two systems describe different things and both are right:
  /// `pod_roles` says what someone's JOB is (admin / pm / pl / tasker /
  /// guest); the ETP groups say what they may do INSIDE an assessment
  /// (Manager / Evaluator). This is the bridge, so a Tasker signing in through
  /// the shared gateway lands in the candidate portal without anyone having to
  /// assign them a second group by hand.
  ///
  /// Anything unrecognised maps to `member`, which is the SAFE direction: a
  /// candidate surface shows a person only their own attempts, so an unknown
  /// role can never be handed the console by accident.
  static Portal fromOrgRole(String? role) => switch (role?.toLowerCase()) {
    'admin' || 'pm' || 'pl' => Portal.admin,
    _ => Portal.member,
  };

  /// The URL segment. Candidate routes are rooted at `/me`, not `/member`.
  String get seg => this == Portal.member ? 'me' : wire;

  String get homeRoute => switch (this) {
    Portal.admin => '/admin/assessments',
    Portal.member => '/me/assessments',
  };
}

/// Which rung of the Assessment v2 ladder the signed-in account is on.
///
/// The four values match the field on the Odoo user form exactly, and the
/// server sends the same words in `access_role` - so an operator reading the
/// dropdown and a developer reading a payload are looking at one vocabulary.
///
/// WHY THIS EXISTS BESIDE [Portal]. `Portal` answers "which shell do we draw",
/// and it is binary because there are only two shells: the operator console and
/// the candidate surface. Both [admin] and [manager] belong in the console, so
/// `Portal` cannot tell them apart - and a read-only Manager dropped into the
/// candidate surface would not be a narrower console, it would be the wrong one.
enum AccessRole {
  /// No Assessment v2 access. Reaches nothing; the server refuses every route.
  none('none'),

  /// Sits assessments. The candidate surface.
  candidate('candidate'),

  /// READ-ONLY operator. Sees the console, changes nothing.
  manager('manager'),

  /// Full power.
  admin('admin');

  const AccessRole(this.wire);
  final String wire;

  /// Unknown values fall to [admin], which preserves the behaviour of every
  /// client build that predates this field: before it existed the console was
  /// unconditional. Failing the other way would blank the console for
  /// everybody the moment a server sent something unexpected, and the SERVER
  /// is the security boundary either way - every route re-checks its own group,
  /// so a wrong guess here costs a 403, not access.
  static AccessRole parse(String? v) => values.firstWhere(
    (AccessRole r) => r.wire == v,
    orElse: () => AccessRole.admin,
  );

  /// What to CALL this role on screen, in the words the Odoo user form uses.
  ///
  /// The account card and the Account screen both said "Admin" for a Manager,
  /// because they read [Portal] - which is binary and reports `admin` for both -
  /// rather than this. Telling a read-only operator they are an Admin is worse
  /// than saying nothing: it is the label they would quote when asking why a
  /// button 403'd, and it sent them looking for a bug in the button.
  String get label => switch (this) {
    AccessRole.none => 'No access',
    AccessRole.candidate => 'Candidate',
    AccessRole.manager => 'Manager',
    AccessRole.admin => 'Admin',
  };

  /// One sentence on what this rung may DO, for the Account screen.
  ///
  /// Phrased as authority rather than as a screen list, because the screens a
  /// role can open and the actions it can take are different facts - a Manager
  /// opens Assessments and Form Studio and changes neither.
  ///
  /// Read-only is stated FIRST for the Manager. It is the one thing about the
  /// rung somebody needs to know before they try something, and the sentence
  /// they would otherwise have to infer from a 403.
  String get canDo => switch (this) {
    AccessRole.none =>
      'Nothing here yet - ask an admin to enable Assessment access',
    AccessRole.candidate => 'Sit assessments and read released results',
    AccessRole.manager =>
      'Read only - review assessments, questions, tags and results',
    AccessRole.admin => 'Author, launch, score and release',
  };

  /// The sidebar rows this role may open, by `NavEntry.key`.
  ///
  /// Manager is read-only and sees six of the ten: Dashboard, Assessments,
  /// Question Bank, Tags, Form Studio and LLM Budget - plus Responses, which
  /// is a pure read of data the Dashboard already summarises. It does NOT see
  /// Generators, Review Queue or Settings.
  ///
  /// Null means "no restriction", which is what [admin] gets. An empty set
  /// would be wrong for admin and is the reason this is nullable rather than
  /// a set of every key: a key added to the rail must appear for an admin
  /// without also having to be added here.
  Set<String>? get navKeys => switch (this) {
    AccessRole.manager => const <String>{
      'analytics',
      'assessments',
      'bank',
      'tags',
      'forms',
      'responses',
      'budget',
    },
    _ => null,
  };
}

/// What a role is allowed to CHANGE.
///
/// Every value means "may mutate something", which is why a read-only Manager
/// holds none of them. The set is supplied by the server on the session payload
/// (`capabilities`) and read through `AppStore.can`, so what the console hides
/// and what the API refuses are derived from the same fact instead of two
/// hand-maintained lists that drift.
///
/// It is NOT a security boundary - a client can believe whatever it likes, and
/// every route re-checks its own group.
enum Capability {
  /// Edit an assessment's own settings and thresholds.
  configure,

  /// Assign candidates and start a sitting.
  launch,

  /// Publish results to candidates.
  release,

  /// Cancel, archive, reset to draft, re-score.
  lifecycle,

  /// Generators, Review Queue, question and tag authoring.
  authoring,

  /// Settings, LLM budget configuration, credentials.
  platform;

  static Capability? parse(String? v) => values.firstWhere(
    (Capability c) => c.name == v,
    orElse: () => Capability.configure,
  );
}

enum LedgerOp {
  extractTags('extract_tags', 'Extract skills'),
  generateQuestions('generate_questions', 'Generate questions'),
  renderImage('render_image', 'Render image'),
  renderVideo('render_video', 'Render video'),
  detectRegions('detect_regions', 'Detect regions'),
  similarity('similarity', 'Similarity check'),
  scoreSubjective('score_subjective', 'Score subjective'),
  scoreImageAb('score_image_ab', 'Score image A/B'),
  scoreImagePrompt('score_image_prompt', 'Score image prompt'),
  scoreVideoPrompt('score_video_prompt', 'Score video prompt'),
  scoreLabels('score_labels', 'Score labels'),
  summarize('summarize', 'Summarize attempt'),
  // Verified against a live ledger. Without these four, $16.87 of $17.44
  // was silently relabelled 'Summarize attempt' by the fallback below.
  generateImage('generate_image', 'Generate image'),
  submitVideoOp('submit_video_op', 'Generate video'),
  verifyPlantedFlaws('verify_planted_flaws', 'Verify planted flaws'),
  // The rest of `llm_usage.operation`, which fell through to Other (F2-01).
  extractSkills('extract_skills', 'Extract skills (legacy)'),
  detectImageElements('detect_image_elements', 'Detect image elements'),
  locateDefect('locate_defect', 'Locate defect'),
  generateVideo('generate_video', 'Generate video (legacy)'),
  fetchVideoOp('fetch_video_op', 'Poll video'),
  scoringCacheCreate('scoring_cache_create', 'Scoring cache create'),
  scoringCacheRefresh('scoring_cache_refresh', 'Scoring cache refresh'),
  assignQuestionSkills('assign_question_skills', 'Assign question skills'),
  draftTaskTemplate('draft_task_template', 'Draft task template'),
  consolidateVocab('consolidate_vocab', 'Consolidate vocabulary'),
  mapSimilarity('map_similarity', 'Map SOP similarity'),
  other('other', 'Other');

  final String wire;
  final String label;

  const LedgerOp(this.wire, this.label);

  static LedgerOp parse(String? v) => values.firstWhere(
    (LedgerOp o) => o.wire == v,
    // `other`, never `summarize`. Falling back to a REAL operation makes
    // an unrecognised call indistinguishable from a genuine one, so the
    // cost-by-operation chart attributed every unknown model call to
    // "Summarize attempt" and read as authoritative while being wrong.
    orElse: () => LedgerOp.other,
  );

  /// Authoring spend against evaluation spend - the split the budget screen
  /// reports by project.
  bool get isAuthoring => switch (this) {
    LedgerOp.extractTags ||
    LedgerOp.generateQuestions ||
    LedgerOp.renderImage ||
    LedgerOp.renderVideo ||
    LedgerOp.detectRegions ||
    LedgerOp.similarity ||
    // Producing a question's media and checking its planted flaws is part
    // of AUTHORING it. Omitting them reported "Authoring share 0%" on a
    // ledger that was almost entirely authoring.
    LedgerOp.generateImage ||
    LedgerOp.submitVideoOp ||
    LedgerOp.verifyPlantedFlaws ||
    LedgerOp.extractSkills ||
    LedgerOp.detectImageElements ||
    LedgerOp.locateDefect ||
    LedgerOp.generateVideo ||
    LedgerOp.fetchVideoOp ||
    LedgerOp.assignQuestionSkills ||
    LedgerOp.draftTaskTemplate ||
    LedgerOp.consolidateVocab ||
    LedgerOp.mapSimilarity => true,
    _ => false,
  };
}
