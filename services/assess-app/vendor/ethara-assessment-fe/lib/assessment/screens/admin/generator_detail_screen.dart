// Generator detail - HANDOVER 4.3 and 4.4 (GEN_TABS).
//
// The working surface for one SOP. Five tabs, never disabled and never hidden,
// so the shape of the record stays legible whatever state it is in.
//
// Two tabs gate their own BODY rather than their tab button:
//   - Similar Projects shows an empty state when nothing matched.
//   - Generation refuses to offer the count and type controls until skills
//     have been extracted. That gating is the point of the screen: tag
//     extraction runs inline and therefore has no observable running state, so
//     the surface that depends on it is gated on the RESULT rather than on a
//     spinner.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/file_pick_stub.dart'
    if (dart.library.js_interop) '../../../services/file_pick_web.dart';

import '../../domain/category_scores.dart' show humanDuration;
import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import 'budget_screen.dart' show usd;
import 'task_template_editor.dart';
import '../../widgets/buttons.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/delete_sheet.dart';
import '../../widgets/editable_title.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/controls.dart';
import 'assessment_detail_screen.dart' show showQuestionPreview;
import 'generator_list_screen.dart' show showGeneratorDelete;
import '../../theme.dart';
import '../../nav.dart';

class GeneratorDetailScreen extends StatefulWidget {
  final AppStore store;
  final String genId;
  final String? tab;

  /// Open with the name ready to type into - see [GeneratorDetail.focusName].
  final bool focusName;

  const GeneratorDetailScreen({
    super.key,
    required this.store,
    required this.genId,
    this.tab,
    this.focusName = false,
  });

  /// How the per-category uploaders ask for a file. A seam so a test can
  /// answer the picker (`pickFile` is null off the web); production never
  /// sets it.
  @visibleForTesting
  static Future<PickedFile?> Function({String accept}) pick = pickFile;

  @override
  State<GeneratorDetailScreen> createState() => _GeneratorDetailScreenState();
}

class _GeneratorDetailScreenState extends State<GeneratorDetailScreen>
    with WidgetsBindingObserver {
  static const List<String> _tabKeys = <String>[
    'corpus',
    'skills',
    'similarity',
    'generation',
    'drafts',
  ];

  String? _override;

  /// This generator's run, as the last `/progress` tick reported it (§4.9).
  ///
  /// THE SCORING WATCH ON THE ASSESSMENT PAGE, COPIED: a screen-local one-shot
  /// timer on the light route, 5 s backing off to 15 s then 30 s while the
  /// answer holds still, a minute while stalled, 720 ticks at most, asleep in a
  /// hidden tab, stopped when the server says the run is no longer `active`.
  /// It replaces `store.pollGeneration` for THIS generator - see
  /// [AppStore.screenWatchedGenerators] - whose 2 s tick re-read every page of
  /// `/generators` and `/drafts` and gave up after 3 minutes, often before a
  /// queued run had even started.
  ///
  /// A tick that fails keeps what is on screen: a background read never swaps
  /// the page for a spinner or an error.
  GenerationProgress? _progress;
  Timer? _genPoll;
  int _genTicks = 0;
  bool _genInFlight = false;
  int _unchanged = 0;
  String? _lastNumbers;
  bool _hidden = false;

  /// The rate the watch is running at, or null when it is off.
  Duration? _pollEvery;

  /// The generator this screen took over from `pollGeneration`, if any.
  String? _watchedId;

  /// The store's last word on whether this generator is running, to catch a
  /// run STARTING - from any of the five Generate buttons on this page.
  bool _wasGenerating = false;

  static const Duration _kGenPollEvery = Duration(seconds: 5);
  static const List<Duration> _kRunBackoff = <Duration>[
    _kGenPollEvery,
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];
  static const Duration _kStalledRecheckEvery = Duration(minutes: 1);
  static const int _kGenPollMaxTicks = 720;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hidden = _isHidden(WidgetsBinding.instance.lifecycleState);
    _wasGenerating = widget.store.genById(widget.genId)?.isGenerating ?? false;
    widget.store.addListener(_onStore);
    // Hydrate from the DETAIL route. The list row that got us here carries
    // counts but no records, so without this the corpus tab reports "No files
    // attached" for a generator whose document the server has.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.store.loadGenerator(widget.genId);
      // The template library, for the Question templates panel and the
      // Task-to-generate picker. Quiet: nothing on screen to preserve yet, but
      // it must not flash the panel on every later refresh either.
      widget.store.loadTaskTemplates();
      // Read now: a finished run's "ready" line and a live run's banner both
      // come from this first tick.
      _watchGeneration(after: Duration.zero);
    });
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStore);
    WidgetsBinding.instance.removeObserver(this);
    _stopWatch(handBack: true);
    super.dispose();
  }

  /// Same reading as the assessment page: `hidden`/`paused` is a tab nobody is
  /// looking at, `inactive` is only a blur and keeps watching.
  static bool _isHidden(AppLifecycleState? s) =>
      s == AppLifecycleState.hidden || s == AppLifecycleState.paused;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool hidden = _isHidden(state);
    if (hidden == _hidden) return;
    _hidden = hidden;
    _genPoll?.cancel();
    // Shown again: read now rather than finishing a backed-off wait. A tick
    // still in flight re-arms itself when it lands.
    if (!hidden && _pollEvery != null && !_genInFlight) {
      _genPoll = Timer(Duration.zero, _tickGeneration);
    }
  }

  /// A run starting, whichever button started it. `startGeneration` flips the
  /// record to `queued` before its call goes out, so this is also what takes
  /// the generator off `pollGeneration` before that call's refresh starts it.
  void _onStore() {
    final bool busy = widget.store.genById(widget.genId)?.isGenerating ?? false;
    if (busy && !_wasGenerating) _watchGeneration();
    _wasGenerating = busy;
  }

  /// (Re)start the watch at its fastest rate. After Generate the first read
  /// waits one interval, so it lands after the server has queued the run
  /// rather than racing the call that queues it.
  void _watchGeneration({Duration after = _kGenPollEvery}) {
    if (!mounted) return;
    _genPoll?.cancel();
    _genTicks = 0;
    _unchanged = 0;
    _lastNumbers = null;
    _pollEvery = _kGenPollEvery;
    _watchedId = widget.genId;
    widget.store.screenWatchedGenerators.add(widget.genId);
    if (!_hidden && !_genInFlight) {
      _genPoll = Timer(after, _tickGeneration);
    }
  }

  /// Turn the watch off. [handBack] gives the generator back to
  /// `pollGeneration` when this screen stops watching a run that may still be
  /// going - closed, navigated away, out of ticks, or on a server without the
  /// `/progress` route - so the list screens keep following it as before. A run
  /// the server called finished needs no hand-back.
  void _stopWatch({bool handBack = false}) {
    _genPoll?.cancel();
    _genPoll = null;
    _pollEvery = null;
    final String? id = _watchedId;
    _watchedId = null;
    if (id != null &&
        widget.store.screenWatchedGenerators.remove(id) &&
        handBack) {
      unawaited(widget.store.pollGeneration());
    }
  }

  void _scheduleGenTick() {
    final Duration? every = _pollEvery;
    if (every == null || _hidden || (_genPoll?.isActive ?? false)) return;
    _genPoll = Timer(
      every == _kGenPollEvery
          ? _kRunBackoff[math.min(_unchanged, _kRunBackoff.length - 1)]
          : every,
      _tickGeneration,
    );
  }

  Future<void> _tickGeneration() async {
    if (!mounted || _pollEvery == null || _genInFlight) return;
    if (++_genTicks > _kGenPollMaxTicks) {
      _stopWatch(handBack: true);
      return;
    }
    _genInFlight = true;
    final String asked = widget.genId;
    try {
      final GenerationProgress? p = await widget.store.loadGenerationProgress(
        asked,
      );
      // Re-checked after the await: the router reuses this State across a walk
      // to another generator, so a late answer must not land under its name.
      if (!mounted || asked != widget.genId || _pollEvery == null) return;
      if (p == null) {
        // QUIET: the numbers on screen stay. A route that has never answered
        // leaves nothing to watch with, so the store's poll takes it back.
        if (_progress == null) {
          _stopWatch(handBack: true);
        } else {
          _unchanged++;
        }
        return;
      }
      final GenerationProgress? was = _progress;
      final String numbers = '${p.phase}|${p.summary}|${p.stalled}';
      _unchanged = numbers == _lastNumbers ? _unchanged + 1 : 0;
      _lastNumbers = numbers;
      setState(() => _progress = p);
      // THE ROWS UNDER THE BANNER, re-read quietly when the run moves a phase
      // or a lane count - including the one read a run ending earns. This is
      // what `pollGeneration` used to keep current: the Generation state pill
      // and the Drafts tab's image pills.
      String rows(GenerationProgress x) =>
          '${x.phase}|${x.drafts.total}|${x.images.done}|${x.images.failed}|'
          '${x.videos.ready}|${x.videos.failed}';
      final bool storeBusy = widget.store.genById(asked)?.isGenerating ?? false;
      if ((was != null && rows(was) != rows(p)) || (!p.active && storeBusy)) {
        unawaited(widget.store.reloadGeneration(asked));
      }
      if (!p.active) {
        _stopWatch();
        return;
      }
      _pollEvery = p.stalled ? _kStalledRecheckEvery : _kGenPollEvery;
    } finally {
      _genInFlight = false;
      if (mounted) _scheduleGenTick();
    }
  }

  /// A retry, then the watch from its fastest rate: the drafts it re-queued are
  /// media work the server now reports as `active` again.
  Future<void> _retryImages(Future<void> Function() retry) async {
    await retry();
    _watchGeneration(after: Duration.zero);
  }

  /// RE-HYDRATE WHEN THE ROUTE POINTS AT A DIFFERENT GENERATOR.
  ///
  /// `initState` runs once per State, and the router builds this screen with
  /// no key at a fixed slot - so walking from one generator to another reuses
  /// the same State and never fetched the second one. Only the DETAIL route
  /// carries `similar`; the list row does not. So "Similar Projects" on the
  /// generator you just opened rendered its empty state over pairs the server
  /// was holding, and a browser refresh - which restarts the State - "fixed"
  /// it. Reported live: opening a match from one generator's Similarity tab
  /// showed the other's as empty, in both directions.
  @override
  void didUpdateWidget(GeneratorDetailScreen old) {
    super.didUpdateWidget(old);
    if (old.genId != widget.genId) {
      // The override is the PREVIOUS record's tab choice; keeping it would
      // land the next generator on a tab its own route never asked for.
      _override = null;
      // The watch belongs to the generator being looked at, not to this State.
      _stopWatch(handBack: true);
      _progress = null;
      _wasGenerating =
          widget.store.genById(widget.genId)?.isGenerating ?? false;
      widget.store.loadGenerator(widget.genId);
      _watchGeneration(after: Duration.zero);
    }
    // Back or Forward between two tabs of this generator: the route moved and
    // this State stayed (`pageOf`), so the route's tab takes over again.
    if (old.tab != widget.tab) _override = null;
  }

  /// Open tab [k], as a history entry: the address bar and Back follow it.
  void _showTab(String k) {
    setState(() => _override = k);
    AssessmentNavScope.maybeRead(
      context,
    )?.go(GeneratorDetail(widget.genId, tab: k));
  }

  /// An unrecognised `?tab=` resolves to corpus rather than to an error, so a
  /// stale link still lands somewhere useful.
  String get _active {
    final String? want = _override ?? widget.tab;
    return _tabKeys.contains(want) ? want! : 'corpus';
  }

  @override
  Widget build(BuildContext context) {
    final AppStore s = widget.store;

    return ListenableBuilder(
      listenable: s,
      builder: (BuildContext context, _) {
        final Generator? g = s.genById(widget.genId);
        if (g == null) {
          // The fetch is deferred to a post-frame callback, so this branch was
          // rendered BEFORE the request even went out, on every entry.
          if (s.isHydrating('generator', widget.genId)) {
            return const DetailScreenSkeleton();
          }
          return PageBody(
            children: <Widget>[
              Crumbs(<Crumb>[
                Crumb('Admin'),
                Crumb(
                  'Generators',
                  () => context.nav.go(const GeneratorList()),
                ),
                Crumb('Not found'),
              ]),
              const PageHead('Generator not found'),
              const Panel(
                child: EmptyLine(
                  'This generator may have been removed. Go back to the list '
                  'and pick another one.',
                ),
              ),
            ],
          );
        }

        final int pend = s.pendingDrafts(g.id).length;
        final GenerationProgress? p = _progress;
        final List<Job> running = s.jobs
            .where((Job j) => j.genId == g.id && j.state == JobState.running)
            .toList();

        return PageBody(
          children: <Widget>[
            Crumbs(<Crumb>[
              const Crumb('Admin'),
              Crumb('Generators', () => context.nav.go(const GeneratorList())),
              Crumb(g.name),
            ]),
            if (g.deleted) ...<Widget>[
              const Notice(
                tone: Tone.inert,
                strong: 'This generator is deleted.',
                text:
                    'An assessment uses it, so it is kept with every result, '
                    'but it cannot be restored or used again.',
              ),
              const SizedBox(height: 14),
            ] else if (!g.active) ...<Widget>[
              Notice(
                tone: Tone.inert,
                strong: 'This generator is archived.',
                text:
                    'It leaves the default list and cannot be chosen for a new assessment.',
                actions: <Widget>[
                  Btn(
                    'Restore',
                    tooltip:
                        'Un-archive this generator so it can author questions '
                        'again.',
                    size: BtnSize.sm,
                    busy: s.isBusy('archive:${g.id}'),
                    onPressed: s.isLive
                        ? () => s.archiveGenerator(g.id, archive: false)
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            // THE RUN, WHILE IT RUNS - the scoring notices of the Assessment
            // page, for generation (§4.9). ONE banner: a stalled run is red and
            // outranks the live blue one, a finished run leaves a neutral line,
            // and failed or cancelled runs keep their own banners below.
            if (p != null && p.stalled) ...<Widget>[
              Notice(
                tone: Tone.bad,
                strong: 'Generation is not running.',
                text: <String>[
                  p.stalledReason.trim().isNotEmpty
                      ? p.stalledReason.trim()
                      : 'A generation or media cron is stopped or overdue, so '
                            'this run will not move until it runs again.',
                  if (p.summary.isNotEmpty) p.summary,
                ].join('  \u00b7  '),
              ),
              const SizedBox(height: 14),
            ] else if (p != null && p.active) ...<Widget>[
              Notice(
                tone: Tone.info,
                text: p.summary.isNotEmpty
                    ? p.summary
                    : 'This page follows the run and refreshes itself when it '
                          'finishes.',
                actions: const <Widget>[Spinner()],
              ),
              const SizedBox(height: 14),
            ] else if (p != null &&
                p.phase == 'ready' &&
                p.summary.isNotEmpty) ...<Widget>[
              Notice(tone: Tone.inert, text: p.summary),
              const SizedBox(height: 14),
            ],
            // NO DOCUMENT is an ordinary state now, not an edge case: creating
            // a generator collects a name and nothing else. It gets its own
            // notice, because "extract its skills" is not an instruction
            // anybody can follow here - that call comes back 409 `no_source`,
            // and the button offering it is disabled below. None of the three
            // steps for a deleted generator: it can never be used again.
            if (!g.deleted && g.fileCount == 0) ...<Widget>[
              Notice(
                tone: Tone.info,
                strong: 'Step 1 of 3 - attach the SOP.',
                text:
                    'Nothing to read yet. Upload the document on the Resources tab.',
                actions: <Widget>[
                  // A SIGNPOST, not a second upload control. The Resources
                  // tab is the one place in the product that attaches an SOP,
                  // and putting a picker here would rebuild the exact
                  // duplication the New generator page was deleted for.
                  Btn.primary(
                    'Go to Resources',
                    size: BtnSize.sm,
                    onPressed: () => _showTab('corpus'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ] else if (!g.deleted && !g.hasTags) ...<Widget>[
              // THREE OUTCOMES, NOT TWO. A run that failed and a run that was
              // never started both left this banner reading "has not read its
              // document yet", which is the sentence that turned a Vertex
              // refusal into an app that looked like it ignored the click.
              // A failure states itself, in the reason the module recorded.
              Notice(
                tone: !g.isExtractingTags && g.tagFailure != null
                    ? Tone.bad
                    : Tone.info,
                strong: g.isExtractingTags
                    ? 'Step 2 of 3 - reading the document now.'
                    : (g.tagFailure != null
                          ? 'Step 2 of 3 - reading the document failed.'
                          : 'Step 2 of 3 - this generator has not read its '
                                'document yet.'),
                text: g.isExtractingTags
                    ? 'Runs on the server - you can leave this page.'
                    : (g.tagFailure ??
                          'Extract its skills, then choose what to generate '
                              'from them.'),
                actions: <Widget>[
                  Btn.primary(
                    g.isExtractingTags
                        ? 'Extracting...'
                        : (g.tagFailure != null
                              ? 'Try again'
                              : 'Extract skills'),
                    size: BtnSize.sm,
                    busy: g.isExtractingTags,
                    onPressed: () => _extract(g),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            // GENERATION failure, at PAGE level and not only inside the
            // Generation tab. The reason reached the screen in exactly one
            // place, below the hasTags gate on one of five tabs, so a manager
            // who clicked Generate and switched to Drafts to watch questions
            // arrive saw an empty grid and no explanation - indistinguishable
            // from a run still going. Extraction has had this banner since it
            // was written; generation is the more expensive step and had none.
            //
            // Suppressed while a new run is in flight so a stale message never
            // argues with live progress - the same guard the extraction banner
            // above uses.
            // Keyed on `sopGenError`, NOT `lastError`: lastError covers BOTH
            // halves of the pipeline (models.dart:1774), so using it here made
            // this banner fire on an EXTRACTION failure too and print the same
            // reason the extraction banner directly above was already showing.
            if (!g.isGenerating && g.sopGenError.isNotEmpty) ...<Widget>[
              Notice(
                tone: Tone.bad,
                strong: 'The last generation run failed.',
                text: g.sopGenError,
                actions: <Widget>[
                  Btn.primary(
                    'Try Again',
                    size: BtnSize.sm,
                    tooltip:
                        'Send the SOP to the generator again. Nothing '
                        'already authored is affected; a run that failed wrote '
                        'no drafts.',
                    busy: g.isGenerating,
                    onPressed: g.hasTags && _canGenerate(g)
                        ? () => s.startGeneration(g.id)
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            // A KILLED RUN GETS ITS OWN BANNER, not the failure one above.
            //
            // `sop_gen_error` is deliberately left empty on a cancel, so this
            // is the only thing that says what happened - and it has to,
            // because the outcome an operator sees otherwise is a generator
            // that simply stopped with fewer drafts than they asked for.
            if (g.sopGenState == GenState.cancelled) ...<Widget>[
              Notice(
                tone: Tone.inert,
                strong: 'The last run was cancelled.',
                text:
                    'Drafts it produced are in the review queue - approve '
                    'or discard them there. Generating again is a fresh run '
                    'and a new set of calls.',
                actions: <Widget>[
                  Btn.primary(
                    'Generate Again',
                    size: BtnSize.sm,
                    tooltip:
                        'Start a fresh run from the same SOP. The drafts the '
                        'cancelled run produced are kept, and this costs a new '
                        'set of model calls.',
                    busy: g.isGenerating,
                    onPressed: g.hasTags && _canGenerate(g)
                        ? () => s.startGeneration(g.id)
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            // STEP 3 OF 3. The wizard counted the manager through steps 1 and 2
            // and then stopped, at the point they most need telling what is
            // left: skills extracted, nothing generated, no failure to explain.
            // Suppressed once anything exists or a run is in flight, and it
            // never competes with the two banners above because each of those
            // owns an earlier state.
            if (g.fileCount > 0 &&
                g.hasTags &&
                !g.deleted &&
                !g.isGenerating &&
                g.sopGenError.isEmpty &&
                // A cancelled run has its own banner directly above, and two
                // notices arguing about the same generator is how the first
                // one stops being read.
                g.sopGenState != GenState.cancelled &&
                g.questionCount == 0) ...<Widget>[
              Notice(
                tone: Tone.info,
                strong: 'Step 3 of 3 - generate the questions.',
                text: !_canGenerate(g)
                    ? 'The skills are read. Choose at least one question type '
                          'or a task to generate on the Generation tab, then '
                          'generate.'
                    : 'The skills are read and the types are chosen. '
                          'Generating runs on the server, so you can leave '
                          'this page.',
                actions: <Widget>[
                  Btn.primary(
                    'Generate Questions',
                    size: BtnSize.sm,
                    tooltip: !_canGenerate(g)
                        ? 'Pick at least one question type, or a task to '
                              'generate, on the Generation tab first.'
                        : 'Author drafts from this SOP. They land in the '
                              'review queue for approval, not straight into '
                              'the bank.',
                    busy: g.isGenerating,
                    onPressed: !_canGenerate(g)
                        ? null
                        : () => s.startGeneration(g.id),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            PageHead(
              g.name,
              // The name is a FIELD of the record, edited where it is read
              // rather than through a Rename dialog for one text box.
              // No rename for a deleted generator: Deleted is final.
              titleChild: g.deleted
                  ? null
                  : EditableTitle(
                      value: g.name,
                      startEditing: widget.focusName,
                      onCommit: (String next) =>
                          s.saveGeneratorName(g.id, next),
                    ),
              // A FILTERED join, not an interpolation. `sopFile` is empty for a
              // generator with no document - and empty again for one whose
              // skills have not been extracted, because it carries `sop_title`
              // rather than a filename - so the old spelling opened the line on
              // a stray separator.
              sub: <String>[
                g.fileCount == 0 ? 'No SOP attached' : g.sopFile,
                g.owner,
                if (g.created.isNotEmpty) 'created ${g.created}',
              ].where((String s) => s.trim().isNotEmpty).join('  \u00b7  '),
              actions: <Widget>[
                if (!g.deleted)
                Btn(
                  g.isExtractingTags
                      ? 'Extracting...'
                      : (g.hasTags ? 'Re-extract skills' : 'Extract skills'),
                  busy: g.isExtractingTags,
                  // Disabled with no document: the call can only come back 409
                  // `no_source`. Same argument as Generate below - the button
                  // says so before the operator spends a click.
                  onPressed: g.fileCount > 0 ? () => _extract(g) : null,
                ),
                // Extract skills' own kill, beside the button that started it.
                if (g.canCancelTagExtract)
                  Btn.danger(
                    'Stop extracting',
                    icon: Icons.stop_circle_outlined,
                    tooltip:
                        'Stop reading the SOP. The skills already on this '
                        'generator are kept.',
                    onPressed: () => _confirmStopExtract(g, s),
                  ),
                if (g.isStoppingTagExtract)
                  Btn(
                    'Stopping...',
                    busy: true,
                    tooltip:
                        'The reply of the call already in flight will not be '
                        'applied.',
                    onPressed: null,
                  ),
                // No Rename button and no "Check for duplicates": the title
                // is the rename control, and Similar Projects is a tab two
                // centimetres below already saying what it is.
                //
                // Retiring, not deleting. An archived generator keeps the
                // questions it authored and they keep their link back to it,
                // so an assessment already sat stays explicable.
                // Neither for a deleted generator: Deleted is final.
                if (!g.deleted)
                  Btn(
                    g.active ? 'Archive' : 'Restore',
                    busy: s.isBusy('archive:${g.id}'),
                    onPressed: s.isLive
                        ? () => s.archiveGenerator(g.id, archive: g.active)
                        : null,
                  ),
                // DELETE, next to Archive on purpose. They read as neighbours
                // and are not the same decision: archiving hides the generator
                // and leaves every question it authored in the bank; deleting
                // takes those questions out of the bank too. The sheet spells
                // that out before anything happens.
                //
                // HIDDEN - see [showGeneratorDelete]. Archive stays.
                if (showGeneratorDelete && !g.deleted)
                  Btn.danger(
                    'Delete',
                    // What `_delete_generator` (write.py) does, both branches.
                    tooltip:
                        'Remove this generator. Not used by any assessment: '
                        'it is erased with its drafts and SOP files. Used by '
                        'an assessment: it moves to Deleted, kept with every '
                        'result but never restorable. Either way its '
                        'questions are erased if nothing uses them, and moved '
                        'to Deleted if an assessment uses them or a candidate '
                        'answered them. No score changes. The exact counts '
                        'are shown before anything happens.',
                    onPressed: s.isLive ? () => _delete(g) : null,
                  ),
                if (!g.deleted)
                Btn.primary(
                  g.isGenerating ? 'Generating...' : 'Generate questions',
                  // Generation needs skills; the store guards it too, but the
                  // button says so before the operator spends a click.
                  //
                  // No `fileCount` condition here on purpose: `hasTags` can
                  // only become true through an extraction, and extraction now
                  // requires a document. This is transitively gated, and
                  // spelling it out again would imply the two are independent.
                  //
                  // `allowedTypes` IS checked, matching the button on the
                  // Generation tab. The store refuses an empty list
                  // (app_store.dart, startGeneration), so without this the
                  // header offered a live button that could only ever answer
                  // with a warning toast.
                  busy: g.isGenerating,
                  tooltip: !_canGenerate(g)
                      ? 'Pick at least one question type, or a task to '
                            'generate, on the Generation tab.'
                      : null,
                  onPressed: g.hasTags && !g.isGenerating && _canGenerate(g)
                      ? () => s.startGeneration(g.id)
                      : null,
                ),
                // BESIDE Generate, and only while there is something to stop.
                //
                // A run costs money for as long as it lasts, so the control
                // that ends it belongs on the screen the operator is already
                // watching - not behind a menu they would have to know about.
                if (g.canCancelGeneration)
                  Btn.danger(
                    'Kill Generation',
                    icon: Icons.stop_circle_outlined,
                    tooltip:
                        'Stop this run at its next model call. Draft questions '
                        'it has already produced are kept.',
                    onPressed: () => _confirmKill(g, s),
                  ),
                if (g.isStopping)
                  Btn(
                    'Stopping...',
                    // Deliberately dead rather than absent: the operator
                    // pressed something and needs to see that it took. The run
                    // stops at its next model call, which can be a call away.
                    busy: true,
                    tooltip:
                        'No further model calls will be made. The run finishes '
                        'the one already in flight and then stops.',
                    onPressed: null,
                  ),
                // The scoring page's "Score Failed Candidates (n)", for images.
                // The server decides who may (`can_retry_images`: Admin, and
                // something failed); the count is this run's failures.
                if (!g.deleted &&
                    p != null &&
                    p.canRetryImages &&
                    p.images.failed > 0)
                  Btn(
                    'Retry failed images (${p.images.failed})',
                    tooltip:
                        'Send the drafts whose image failed back to the image '
                        'queue. Images already rendered are kept, so they are '
                        'not paid for twice.',
                    busy: s.isBusy('retryimages:${g.id}'),
                    onPressed: () =>
                        _retryImages(() => s.retryFailedImages(g.id)),
                  ),
              ],
            ),
            if (running.isNotEmpty) ...<Widget>[
              Stack16(<Widget>[
                for (final Job j in running)
                  JobCard(
                    name: j.name,
                    state: j.state,
                    meta: j.meta,
                    detail: j.detail,
                    progress: j.progress,
                    onRetry: j.state.canRetry ? () => s.retryJob(j.id) : null,
                  ),
              ], gap: 9),
              const SizedBox(height: 14),
            ],
            if (g.possibleDuplicate) ...<Widget>[
              Notice(
                tone: Tone.warn,
                strong: 'This SOP looks like one you already have.',
                text: g.similar.first.why,
                actions: <Widget>[
                  Btn(
                    'Compare',
                    tooltip:
                        'Open the two projects side by side to see which tags they '
                        'share. This is what the duplicate-SOP warning is derived '
                        'from.',
                    size: BtnSize.sm,
                    onPressed: () => _showTab('similarity'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            Panel(
              flush: true,
              toolbar: TabStrip(
                active: _active,
                onChanged: _showTab,
                tabs: <TabDef>[
                  const TabDef('corpus', 'Resources'),
                  const TabDef('skills', 'Skills & Templates'),
                  const TabDef('similarity', 'Similar Projects'),
                  const TabDef('generation', 'Generation'),
                  // The count chip is rendered only when non-zero: a zero
                  // badge is noise.
                  TabDef('drafts', 'Drafts', count: pend == 0 ? null : pend),
                ],
              ),
              // A deleted generator is read here and changed nowhere: every
              // control in its tabs would only meet the server's 409.
              child: IgnorePointer(
                ignoring: g.deleted,
                child: switch (_active) {
                'skills' => _SkillsTab(store: s, g: g),
                'similarity' => _SimilarityTab(store: s, g: g),
                'generation' => _GenerationTab(
                  store: s,
                  g: g,
                  progress: p,
                  onShowSkills: () => _showTab('skills'),
                ),
                'drafts' => _DraftsTab(
                  store: s,
                  g: g,
                  onRetryImages: (String id) =>
                      _retryImages(() => s.retryDraftImages(id)),
                ),
                _ => _CorpusTab(store: s, g: g),
                },
              ),
            ),
            // The audit trail is in the right-hand dock now - see
            // assessment_section's ChatterDock. Inline here it would render
            // twice and scroll away.
          ],
        );
      },
    );
  }

  /// Delete this generator, after showing what it costs.
  ///
  /// Archiving retires it and leaves its questions in the bank; deleting takes
  /// the questions out too, and the sheet says so. Navigates back to the list
  /// on success - staying on a record that no longer exists would render the
  /// "Generator not found" gate.
  Future<void> _confirmStopExtract(Generator g, AppStore s) async {
    final bool? go = await showSheet<bool>(
      context,
      title: 'Stop extracting skills?',
      sub: 'This generator only.',
      body: const Text(
        'The skills already on this generator are kept. The model call '
        'already in flight finishes and is billed, but its reply is not '
        'applied. Press Extract skills again whenever you are ready.',
      ),
      actions: <Widget>[
        Btn(
          'Keep Going',
          tooltip: 'Leave the extraction running. Nothing changes.',
          onPressed: () => Navigator.of(context).pop(false),
        ),
        Btn.danger(
          'Stop extracting',
          tooltip: 'Stop reading the SOP now.',
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (go != true || !mounted) return;
    await s.cancelTagExtract(g.id);
  }

  Future<void> _confirmKill(Generator g, AppStore s) async {
    // CONFIRMED, because it is not free to undo: restarting means paying for
    // the whole run again. Not `confirmDelete` - nothing is being destroyed,
    // and borrowing that sheet's "This cannot be undone" would say the
    // opposite of what this does to the drafts.
    final bool? go = await showSheet<bool>(
      context,
      title: 'Stop generating questions?',
      sub: 'This generator only. Any other run keeps going.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Notice(
            tone: Tone.info,
            strong: 'Draft questions already produced are kept.',
            text:
                'They stay in the review queue for you to approve or discard. '
                'Nothing that has been paid for is thrown away.',
          ),
          const SizedBox(height: 12),
          Text(
            'The run stops at its next model call, so the one already in '
            'flight finishes and is billed. Everything after it - including '
            'any images or video clips still queued for this generator - is '
            'cancelled.',
            style: context.type.body,
          ),
        ],
      ),
      actions: <Widget>[
        Btn(
          'Keep Going',
          tooltip: 'Leave the run going. Nothing changes.',
          onPressed: () => Navigator.of(context).pop(false),
        ),
        Btn.danger(
          'Kill Generation',
          tooltip:
              'Stop this generator at its next model call. Drafts already '
              'produced are kept.',
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (go != true || !mounted) return;
    await s.cancelGeneration(g.id);
    // Back to the fast rate: the kill lands at the run's next model call.
    _watchGeneration(after: Duration.zero);
  }

  Future<void> _delete(Generator g) async {
    final DeletePreview? preview = await widget.store.previewGeneratorDelete(
      <String>[g.id],
    );
    if (!mounted || preview == null) return;
    final bool go = await confirmDelete(
      context,
      subject: g.name,
      preview: preview,
      isGenerator: true,
    );
    if (!go || !mounted) return;
    await widget.store.deleteGenerators(<String>[g.id]);
    if (mounted) context.nav.go(const GeneratorList());
  }

  void _extract(Generator g) {
    widget.store.extractTags(g.id);
    // Land on the tab that is about to change. The skills are what this
    // button produces, so its progress and its result both belong on Skills &
    // metadata rather than on Generation.
    _showTab('skills');
  }
}

/// Where a role sorts in the Resources table. The SOP is what the questions are
/// written FROM and the only file that is required, so it leads; everything
/// else is material that sharpens the writing, in the order the Generation tab
/// asks for it.
int _kindRank(ResourceKind k) => switch (k) {
  ResourceKind.sop => 0,
  // Old `golden` rows parse as sample (see ResourceKind.parse), so they sort
  // here too, straight after the SOP they illustrate.
  ResourceKind.sample => 1,
  ResourceKind.reference => 2,
  ResourceKind.vendor => 3,
  ResourceKind.client => 4,
  ResourceKind.other => 5,
};

/// Resources: every uploaded file, with a per-row replace and a re-upload for
/// the ones whose text never came out.
///
/// THE ONLY PLACE IN THE PRODUCT THAT ATTACHES AN SOP. Creating a generator
/// takes a name and nothing else; every SOP arrives through this tab.
class _CorpusTab extends StatelessWidget {
  final AppStore store;
  final Generator g;

  const _CorpusTab({required this.store, required this.g});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final List<Resource> failed = g.resources
        .where((Resource r) => r.status == ResourceStatus.failed)
        .toList();
    // EVERY FILE, WHATEVER ITS ROLE. Excluding sample and reference documents
    // left an operator who had uploaded three opening the one tab named for
    // the generator's files and seeing one, with no screen anywhere that
    // answered "what has this generator got". The Role column already names
    // the distinction the filter was drawing.
    //
    // Sorted by role so the SOP - the only required file - leads, rather than
    // appearing wherever upload order happened to put it.
    final List<Resource> sopRows = g.resources.toList()
      ..sort((Resource a, Resource b) {
        final int byKind = _kindRank(a.kind).compareTo(_kindRank(b.kind));
        return byKind != 0 ? byKind : a.file.compareTo(b.file);
      });
    // The server COUNTED files whose rows have not arrived yet, i.e. the
    // post-frame `loadGenerator` is still in flight. That is the exact window
    // this screen's initState comment was written about, and it matters more
    // now: the empty state below is a loud call to action, and flashing it over
    // a document the server is holding is worse than the quiet line it replaced.
    //
    // `resources`, NOT `sopRows`. A hydrated generator carrying only reference
    // or sample files has rows - they are simply all filtered out of this tab -
    // so testing the filtered list would leave it loading for ever on a record
    // that had in fact arrived. The unfiltered list empty against a non-zero
    // server count is the only thing that means "not here yet".
    final bool fetching = g.resources.isEmpty && g.resourceCount > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
      child: Stack16(<Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Everything this generator reads, and what each file is for. '
                'The SOP is sent to the model as-is and the questions are '
                'authored straight from it.',
                style: context.type.bodyMuted,
              ),
            ),
            // ONE upload control on screen at a time. With no files the empty
            // state below carries it, where it reads as the thing to do rather
            // than as a button beside an empty table.
            if (sopRows.isNotEmpty) ...<Widget>[
              const SizedBox(width: 12),
              _UploadBtn(store: store, genId: g.id),
            ],
          ],
        ),
        if (failed.isNotEmpty)
          Notice(
            tone: Tone.bad,
            strong: '${failed.length} file could not be read.',
            text:
                failed.first.error ??
                'The extractor found no text layer in it.',
            actions: <Widget>[
              Btn(
                'Re-upload',
                tooltip:
                    'Replace this document with a new file. The generator keeps '
                    'its questions and tags; only the source changes.',
                size: BtnSize.sm,
                onPressed: () => store.fixResource(g.id, failed.first.id),
              ),
            ],
          ),
        if (fetching)
          // The count says files exist; their rows have not arrived yet.
          const TableSkeleton(rows: 1, columns: 6)
        else
          DataGrid(
            minWidth: 860,
            emptyIcon: Icons.upload_file_outlined,
            // One headline sentence, then the body: DataGrid splits an empty
            // message on its first '. ' to build the EmptyState out of it.
            emptyMessage:
                'No SOP attached yet. Extracting skills and generating '
                'questions both wait on it.',
            // The empty state CARRIES the upload, which is why the header row
            // above drops its own copy while this is showing.
            emptyAction: _UploadBtn(store: store, genId: g.id),
            cols: const <Col>[
              Col('File', flex: 3),
              // "Type", not "Role": the question this column answers is what
              // KIND of document a row is, and "role" was a word the product
              // used nowhere else.
              Col('Type', width: 140),
              Col('Extraction', flex: 2),
              Col('Size', width: 82, numeric: true),
              Col('Pages', width: 70, numeric: true),
              Col('', width: 96, numeric: true),
            ],
            rows: sopRows.map((Resource r) {
              return GridRow(<Widget>[
                Text(
                  r.file,
                  style: context.type.tableCell.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                StatusBadge(r.kind.label, Tone.inert),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Pill.state(r.status),
                    if (r.error != null) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(r.error!, style: context.type.tiny),
                    ],
                  ],
                ),
                Mono(r.size, size: 11.5, color: t.textSecondary),
                r.pages == 0
                    ? Text('-', style: context.type.bodyMuted)
                    : Mono('${r.pages}', size: 11.5, color: t.textSecondary),
                // Remove, not Replace: there is no swap-in-place on the server,
                // and "Replace" that only ever deletes is a lie. Re-upload is
                // the button above.
                Btn(
                  'Remove',
                  tooltip:
                      'Detach this document from the generator. Questions already '
                      'authored from it are unaffected.',
                  size: BtnSize.sm,
                  onPressed: () => store.removeResource(g.id, r.id),
                ),
              ]);
            }).toList(),
          ),
        Text(
          'Only the SOP is required. Reference, vendor, client and sample '
          'files sharpen what the generator writes, and are added on the '
          'Generation tab.',
          style: context.type.small.copyWith(color: t.textMuted),
        ),
      ]),
    );
  }
}

/// A backend metadata key as a readable field label.
///
/// `sop_domain` -> `SOP domain`. Derived rather than looked up so a key the
/// server starts sending tomorrow still reads as English instead of appearing
/// as an unlabelled internal token.
String _prettyMetaLabel(String key) {
  const Map<String, String> acronyms = <String, String>{
    'sop': 'SOP',
    'llm': 'LLM',
    'ab': 'A/B',
    'id': 'ID',
    'url': 'URL',
    'qa': 'QA',
  };
  final List<String> words = key
      .replaceAll(RegExp(r'[_\-]+'), ' ')
      .trim()
      .split(RegExp(r'\s+'))
      .where((String w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return key;
  final List<String> out = <String>[];
  for (int i = 0; i < words.length; i++) {
    final String w = words[i].toLowerCase();
    if (acronyms.containsKey(w)) {
      out.add(acronyms[w]!);
    } else if (i == 0) {
      out.add(w[0].toUpperCase() + w.substring(1));
    } else {
      out.add(w);
    }
  }
  return out.join(' ');
}

/// Skills and templates: the extracted SOP profile in one grid.
class _SkillsTab extends StatelessWidget {
  final AppStore store;
  final Generator g;

  const _SkillsTab({required this.store, required this.g});

  @override
  Widget build(BuildContext context) {
    // THE RUN NARRATES ITSELF, HERE. This progress lived on the Generation
    // tab, which is neither where the button is nor where the result lands.
    if (g.isExtractingTags) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Notice(
              tone: Tone.info,
              strong: 'Reading the SOP now.',
              text:
                  'Appears as soon as the document has been read, and the '
                  'generation options unlock with it. Runs in the '
                  'background.',
            ),
            const SizedBox(height: 14),
            // Real fields are on their way, so a skeleton of the grid they
            // will fill is a truer wait than a spinner: it says what is
            // coming, and the layout does not jump when it lands.
            const TableSkeleton(rows: 4, columns: 2),
          ],
        ),
      );
    }
    if (g.meta.isEmpty && g.tags.isEmpty) {
      // A FAILED RUN SAYS SO, HERE FIRST. This is the tab the operator is sent
      // to to watch the extraction and the tab the result lands on, so it is
      // the one place a failure must not read as "not started yet". The empty
      // line below was doing exactly that: the run went "Extracting...", came
      // back, and left the screen identical to the one before the click.
      final String? failure = g.tagFailure;
      if (failure != null && g.fileCount > 0) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
          child: Notice(
            tone: Tone.bad,
            strong: 'Reading the SOP failed.',
            text: failure,
            actions: <Widget>[
              Btn.primary(
                'Try Again',
                tooltip:
                    'Run the extraction again on the same document. Costs '
                    'one LLM call. If the reason above names a configuration '
                    'problem or a spent budget, fix that first - a retry on '
                    'its own will fail the same way.',
                size: BtnSize.sm,
                // The SERVER's state for the spinner, same as every other
                // extract control: the work runs in a cron and outlives
                // this tab.
                busy: store.isBusy('tags:${g.id}') || g.isExtractingTags,
                onPressed: () => store.extractTags(g.id),
              ),
            ],
          ),
        );
      }
      // Point at the document before pointing at the button that reads it:
      // with nothing attached, "Run Extract skills" names a control that is
      // disabled and a call that would 409.
      return EmptyLine(
        g.fileCount == 0
            ? 'No document attached yet. Upload the SOP on the Resources tab - '
                  'the skills are read out of it.'
            : 'Nothing extracted yet. Run "Extract skills" to read the '
                  'document.',
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
      child: Stack16(<Widget>[
        const Notice(
          tone: Tone.inert,
          text:
              'Read from the SOP during skills extraction. Re-extract to '
              'refresh these values.',
        ),
        FieldGrid(<Widget>[
          for (final MapEntry<String, String> e in g.meta.entries)
            Field(
              // De-snaked, not the raw key. These come straight off the
              // backend map, so the grid was labelling a manager's fields
              // `sop_domain` and `output_format`. A lookup table would go
              // stale the moment the server adds a key; deriving the label
              // keeps any new field readable without a code change.
              label: _prettyMetaLabel(e.key),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  e.value,
                  style: context.type.body.copyWith(height: 1.55),
                ),
              ),
            ),
        ]),
        const Hr(),
        Row(
          children: <Widget>[
            const Eyebrow('Tags'),
            const SizedBox(width: 9),
            TagChip('${g.tags.length}'),
            const Spacer(),
            // Apply this vocabulary to questions authored BEFORE it existed.
            // Only offered when there is a vocabulary to apply: on a generator
            // whose skills have never been extracted the button would report
            // "extract first", which is a worse way to say "not yet".
            if (g.tags.isNotEmpty) ...<Widget>[
              Btn(
                'Backfill onto Questions',
                tooltip:
                    'Copy this project\'s skill tags onto the questions it '
                    'authored, so an older bank becomes searchable by the skills '
                    'a later extraction found. Adds only what is missing, so a '
                    'tag a reviewer set by hand survives and running it twice '
                    'changes nothing. No LLM call.',
                size: BtnSize.sm,
                onPressed: () => store.backfillTags(g.id),
              ),
              const SizedBox(width: 5),
            ],
            Btn(
              'Manage Vocabulary',
              tooltip:
                  'Open the shared tag vocabulary. It spans every project, so a '
                  'merge here changes what similarity ranking compares '
                  'everywhere.',
              size: BtnSize.sm,
              onPressed: () => context.nav.go(const TagsAdmin()),
            ),
          ],
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final String tag in g.tags) StatusBadge(tag, Tone.accent),
          ],
        ),
        // THE SOP'S OWN TASKS, one card each, with the axes and options the SOP
        // names. This is the evidence that a project the platform has never seen
        // can be assessed: what a candidate is asked comes from here, not from a
        // shape hardcoded in the generator.
        if (g.tasks.isNotEmpty) _SopTasksPanel(tasks: g.tasks),
        // QUESTION TEMPLATES. Mounted here because this tab already holds what
        // was read OUT of the SOP, and a template is the examiner's own
        // correction to that reading.
        _TaskTemplatePanel(store: store, g: g),
      ]),
    );
  }
}

/// Similarity: the directed pairs, or the empty state when nothing matched.
class _SimilarityTab extends StatelessWidget {
  final AppStore store;
  final Generator g;

  const _SimilarityTab({required this.store, required this.g});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;

    // TWO DIFFERENT NUMBERS, AND THE DIFFERENCE IS THE WHOLE POINT.
    //
    // `similarCount` is computed lexically on the fly, so it can be positive
    // while `similar` - the PERSISTED ranked pairs - is empty, because those
    // pairs only exist once the ranking has been run. This tab used to answer
    // "no similar generators" flatly next to a badge reading "4 similar",
    // which reads as a bug in the count rather than as work not yet done.
    // Now the empty state says which of the two it is, and offers the run.
    if (g.similar.isEmpty) {
      final bool lexicalMatches = g.similarCount > 0;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            EmptyLine(
              lexicalMatches
                  ? '${g.similarCount} generator(s) look similar by wording, '
                        'but the ranking has not been run - so there is '
                        'nothing to compare in detail yet.'
                  : 'No similar generators. Nothing else in the library '
                        "covers this SOP's ground.",
            ),
            const SizedBox(height: 12),
            _RankBtn(store: store, g: g),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
      child: Stack16(<Widget>[
        Row(
          children: <Widget>[
            const Eyebrow('Ranked Pairs'),
            const SizedBox(width: 9),
            TagChip('${g.similar.length}'),
            const Spacer(),
            _RankBtn(store: store, g: g),
          ],
        ),
        ...g.similar.map((Similarity sim) {
          final Generator? other = store.genById(sim.id);
          final List<String> shared = g.tags
              .where((String x) => other?.tags.contains(x) ?? false)
              .toList();
          final List<String> only = g.tags
              .where((String x) => !shared.contains(x))
              .toList();

          return Panel(
            title: other?.name ?? sim.name,
            headActions: <Widget>[
              Pill(sim.band.label, sim.band.tone),
              const SizedBox(width: 9),
              // PERCENT, not a 0-1 fraction. The module stores and labels this
              // as "Match %", and `toStringAsFixed(2)` printed a 0-100 number
              // as "91.00", which reads as a fraction of something else.
              Mono('${sim.score.round()}%', color: t.textSecondary),
              const SizedBox(width: 9),
              Btn(
                'Open',
                size: BtnSize.sm,
                onPressed: () => context.nav.generator(sim.id),
              ),
            ],
            child: Stack16(<Widget>[
              Text(sim.why, style: context.type.body.copyWith(height: 1.6)),
              // What the band means for what to do next, and how the number
              // was arrived at. A blend resting on a FAILED semantic pass is
              // filed as lexical-fallback by the module, and saying so is the
              // difference between a number and a number you can act on.
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(sim.band.guidance, style: context.type.bodyMuted),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      StatusBadge(
                        sim.mode.label,
                        sim.mode == SimMode.lexicalFallback
                            ? Tone.warn
                            : Tone.inert,
                      ),
                      StatusBadge(
                        'lexical ${sim.lexical.round()}%',
                        Tone.inert,
                      ),
                      if (sim.semantic > 0)
                        StatusBadge(
                          'by meaning ${sim.semantic.round()}%',
                          Tone.inert,
                        ),
                    ],
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Eyebrow('Shared tags - ${shared.length} of ${g.tags.length}'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final String x in shared) StatusBadge(x, Tone.warn),
                    ],
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Eyebrow('Only in ${g.name}'),
                  const SizedBox(height: 6),
                  if (only.isEmpty)
                    Text('-', style: context.type.bodyMuted)
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final String x in only) StatusBadge(x, Tone.inert),
                      ],
                    ),
                ],
              ),
            ], gap: 12),
          );
        }),
      ]),
    );
  }
}

/// The most questions one run will author.
///
/// Not a server limit - a sanity limit on the control. Every press of `+` is a
/// write and the value drives a paid, multi-minute LLM run, so an unbounded
/// stepper invited a request whose cost and duration nobody had considered.
const int _kMaxQuestionCount = 50;

/// How many items this run WILL author, matching the harness's own
/// `effective_generation_count` exactly (`max(pinned, sum-of-quotas)`).
///
/// THE SINGLE SOURCE for every place on this screen that shows a count -
/// the field itself, the help line, and the Generate button. Before this,
/// each read its own half of the truth: the button read the raw
/// `sopQuestionCount` the operator had typed, the help line computed its own
/// max() locally, and neither reacted to the other. An operator who set
/// `template x2 + MCQ x3` while the pinned count still said 10 saw "10
/// questions - 2 from a saved task, 3 MCQ, 5 the model's choice" in the help
/// text and "Generate 10 questions" on the button - both technically
/// consistent with each other, but the two committed picks were free to be
/// silently swallowed by "the model's choice" once the harness could not
/// satisfy them (a template whose own type was not on the allow-list), and
/// nothing on screen would have shown that happening. Only a live run
/// surfaced it, as "10 MCQ, 0 from the template".
/// Whether this generator has ENOUGH to run.
///
/// THE DEFECT THIS FIXES. The gate was `allowedTypes.isEmpty`, which reads
/// "no legacy question type ticked". But a TASK TEMPLATE quota already names
/// its own question type - that is what `_widen_allowed_for_templates` exists
/// for server-side - so demanding a legacy type on top is asking the operator
/// to repeat a decision they already made. An operator who picked `T2I x2` and
/// nothing else saw a dead "Generate 2 questions" button with "Pick at least
/// one question type" beside it, while the server would have run the job
/// happily: an empty allow-list means Auto, and it logs "any (model picks)".
///
/// A shape quota of any kind is therefore sufficient on its own.
bool _canGenerate(Generator g) =>
    !g.deleted && (g.allowedTypes.isNotEmpty || g.shapeQuotas.isNotEmpty);

/// Both live on `Generator` now - see `quotaFloor` and
/// `effectiveQuestionCount`. They moved off this screen because the number has
/// to match `effective_generation_count` on the server exactly, and a rule
/// that must agree with another codebase is worth being able to test on its
/// own.
int _quotaFloor(Generator g) => g.quotaFloor;

int _effectiveCount(Generator g) => g.effectiveQuestionCount;

/// Set how many questions a run should target, or hand the choice back to the
/// model.
///
/// `sop_question_count` is a single integer where 0 means auto, so the two
/// controls here write one field: Auto sends 0, the stepper sends its value.
/// Exposing a separate mode as well would let the two disagree.
class _CountControl extends StatefulWidget {
  final AppStore store;
  final Generator g;

  const _CountControl({required this.store, required this.g});

  @override
  State<_CountControl> createState() => _CountControlState();
}

class _CountControlState extends State<_CountControl> {
  @override
  Widget build(BuildContext context) {
    final Generator g = widget.g;
    final AppStore s = widget.store;
    final bool busy = s.isBusy('count:${g.id}');
    final int n = g.sopQuestionCount;
    // A sensible starting point when switching off Auto, rather than 1.
    const int fallback = 10;
    // A QUOTA SETS A FLOOR, IT DOES NOT TAKE THE FIELD AWAY. `MCQ x3` and
    // `template x2` are commitments the run must honour, so the count can
    // never drop below their sum - but `effectiveQuestionCount` is
    // `max(typed, floor)`, which RAISES a total that is too small and never
    // caps one that is large enough. "20 across these three types" was always
    // expressible in the model; locking the stepper meant it could not be
    // asked for on this screen, and the field simply vanished mid-edit the
    // moment a first quota was set.
    //
    // The two-numbers-disagreeing problem that lock was guarding against is
    // solved by the floor being the field's own `min` instead: there is still
    // only ever one number on screen, it is the one the run will use, and the
    // help line below already spells out the split ("4 questions - 2 MCQ,
    // 2 Rubric") plus any remainder as "the model's choice".
    final bool hasQuota = g.shapeQuotas.isNotEmpty;
    final int effective = _effectiveCount(g);
    final int floor = _quotaFloor(g);

    if (hasQuota) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (s.isLive)
            NumberField(
              value: effective,
              // THE FLOOR IS THE MINIMUM, not a reason to disable the field.
              // Typing under it clamps to it, which is the same answer the
              // locked number gave and one the operator can see happen.
              min: floor < 1 ? 1 : floor,
              max: _kMaxQuestionCount,
              onChanged: busy
                  ? (int _) {}
                  : (int v) => s.setQuestionCount(g.id, v),
            )
          else
            Mono('$effective', size: 13, weight: FontWeight.w600),
          const SizedBox(height: 6),
          // BELOW THE FIELD, and only claiming what is true. Once the count is
          // raised past the floor the total is the operator's number, not the
          // picks' - so it says how much of it the picks account for instead.
          Pill(
            effective > floor
                ? '$floor of it from the picks below'
                : 'derived from the picks below',
            Tone.inert,
          ),
        ],
      );
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        // TYPEABLE, like Image labelling count beside it.
        //
        // This was a printed number with a - and a + either side, so "generate
        // 30" cost twenty-two clicks and there was no way to see that the
        // number was editable at all. `NumberField` is the same control the
        // field next to it uses - stepper AND direct entry - so the two now
        // behave the same way and the cap is enforced by the widget rather
        // than by disabling a button.
        //
        // AUTO STAYS A BUTTON, not a magic 0 in the box. It is a real choice
        // ("the model decides how many"), and a number field that silently
        // meant something else at one particular value would be a trap.
        if (s.isLive && !g.countIsAuto)
          NumberField(
            value: n < 1 ? fallback : n,
            min: 1,
            // CAPPED. The value drives a paid multi-minute run, and an
            // unbounded field let a manager ask for 200 questions with no hint
            // that the bill and the wait scale with it.
            max: _kMaxQuestionCount,
            onChanged: busy
                ? (int _) {}
                : (int v) => s.setQuestionCount(g.id, v),
          )
        else
          Mono(
            g.countIsAuto ? 'Auto' : '$n',
            size: 13,
            weight: FontWeight.w600,
          ),
        Pill(g.countIsAuto ? 'model decides' : 'fixed', Tone.inert),
        if (s.isLive)
          Btn(
            g.countIsAuto ? 'Set a number' : 'Auto',
            size: BtnSize.sm,
            pressed: g.countIsAuto,
            busy: busy,
            tooltip: g.countIsAuto
                ? 'Pin the run to a fixed number of questions.'
                : 'Let the model decide how many the SOP is worth.',
            onPressed: busy
                ? null
                : () => s.setQuestionCount(g.id, g.countIsAuto ? fallback : 0),
          ),
      ],
    );
  }
}

/// "Advanced options (optional)" - collapsed until asked for.
class _Advanced extends StatefulWidget {
  const _Advanced({required this.child});

  final Widget child;

  @override
  State<_Advanced> createState() => _AdvancedState();
}

class _AdvancedState extends State<_Advanced> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 10),
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  _open ? Icons.arrow_drop_down : Icons.arrow_right,
                  size: 20,
                  color: t.textSecondary,
                ),
                Text(
                  'Advanced options (optional)',
                  style: context.type.body.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open) ...<Widget>[const SizedBox(height: 6), widget.child],
      ],
    );
  }
}

/// Free-text steering, saved on blur.
class _ExtraInstructions extends StatefulWidget {
  const _ExtraInstructions({required this.store, required this.g});

  final AppStore store;
  final Generator g;

  @override
  State<_ExtraInstructions> createState() => _ExtraInstructionsState();
}

class _ExtraInstructionsState extends State<_ExtraInstructions> {
  late final TextEditingController _c = TextEditingController(
    text: widget.g.sourceText,
  );
  late String _saved = widget.g.sourceText;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      const Eyebrow('Extra instructions'),
      const SizedBox(height: 7),
      // Saved on blur rather than on every keystroke: this is a paragraph, and
      // a write per character would be a write per character.
      Focus(
        onFocusChange: (bool has) {
          if (has) return;
          final String next = _c.text;
          if (next == _saved) return;
          _saved = next;
          widget.store.saveExtraInstructions(widget.g.id, next);
        },
        child: TextField(
          controller: _c,
          minLines: 3,
          maxLines: 8,
          style: context.type.body.copyWith(fontSize: 13),
          decoration: const InputDecoration(
            isDense: true,
            hintText:
                'e.g. focus on edge-case moderation calls; keep language '
                'plain, avoid legalese.',
          ),
        ),
      ),
      const SizedBox(height: 5),
      Text(
        'Appended to the source material the model reads. Saved when you click '
        'away.',
        style: context.type.small.copyWith(color: context.tokens.textMuted),
      ),
    ],
  );
}

/// The files attached under ONE category, with an add button.
class _CategoryFiles extends StatefulWidget {
  const _CategoryFiles({
    required this.store,
    required this.g,
    required this.kind,
    required this.title,
    required this.help,
  });

  /// THE ONE SAMPLE QUESTIONS LIST, shown on Skills & templates and under
  /// Generation > Advanced options. One constructor so the two can never
  /// drift: same rows (`g.resources`, re-read from the store after every
  /// upload or delete), same file types, same words. "Golden examples" was a
  /// second, text-only list of the same thing (owner, 2026-09-29).
  const _CategoryFiles.samples({required this.store, required this.g})
    : kind = ResourceKind.sample,
      title = 'Sample questions',
      help =
          'Also called golden questions. PDF, Word, text, CSV, HTML, JSON, '
          'XML or images.';

  final AppStore store;
  final Generator g;
  final ResourceKind kind;
  final String title;
  final String help;

  @override
  State<_CategoryFiles> createState() => _CategoryFilesState();
}

class _CategoryFilesState extends State<_CategoryFiles> {
  bool _busy = false;

  Future<void> _add() async {
    setState(() => _busy = true);
    try {
      final PickedFile? file = await GeneratorDetailScreen.pick(
        accept:
            '.pdf,.docx,.txt,.md,.markdown,.csv,.html,.json,.xml,'
            '.png,.jpg,.jpeg,.webp,.gif',
      );
      if (file == null) return;
      await widget.store.uploadResource(
        widget.g.id,
        name: file.name,
        bytes: file.bytes,
        category: widget.kind.wire,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final List<Resource> mine = widget.g.resources
        .where((Resource r) => r.kind == widget.kind)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Eyebrow('${widget.title} (optional)'),
            const SizedBox(width: 8),
            IconBtn(
              Icons.add,
              tooltip: 'Attach a ${widget.title.toLowerCase()} file',
              onPressed: _busy || !widget.store.isLive ? null : _add,
            ),
            if (_busy) ...<Widget>[
              const SizedBox(width: 8),
              Text('Uploading...', style: context.type.small),
            ],
          ],
        ),
        if (mine.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final Resource r in mine)
                Chip(
                  label: Text(r.file, style: context.type.tiny),
                  onDeleted: widget.store.isLive
                      ? () => widget.store.removeResource(widget.g.id, r.id)
                      : null,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
        const SizedBox(height: 4),
        Text(
          widget.help,
          style: context.type.small.copyWith(color: t.textMuted),
        ),
      ],
    );
  }
}

/// The SOP's own tasks, each with the axes and options the SOP names.
///
/// Read-only: this is what extraction found, and the way to change it is to fix
/// the SOP or author a template. Shown because "the platform assesses whatever
/// the SOP defines" is a claim an examiner should be able to CHECK, not take on
/// trust - the axis labels and per-axis options here are exactly what a
/// candidate will be asked.
class _SopTasksPanel extends StatelessWidget {
  const _SopTasksPanel({required this.tasks});

  final List<SopTask> tasks;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Panel(
      title: tasks.length == 1
          ? 'The task this SOP defines'
          : 'The ${tasks.length} tasks this SOP defines',
      note:
          'Read from the document. Questions reproduce these shapes, using '
          "the SOP's own wording for every axis and option.",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int i = 0; i < tasks.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 14),
            Text(tasks[i].display, style: context.type.body),
            if (tasks[i].subjectInputs.isNotEmpty ||
                tasks[i].workerOutput.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  <String>[
                    if (tasks[i].subjectInputs.isNotEmpty)
                      'Looks at ${tasks[i].subjectInputs}',
                    if (tasks[i].workerOutput.isNotEmpty)
                      'produces ${tasks[i].workerOutput}',
                  ].join(' · '),
                  style: context.type.tiny,
                ),
              ),
            for (final TaskAxis axis in tasks[i].axes)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(axis.label, style: context.type.small),
                    for (final String option in axis.options)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: t.bgSubtle,
                          border: Border.all(color: t.borderSubtle),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(option, style: context.type.tiny),
                      ),
                  ],
                ),
              ),
            if (tasks[i].justification == 'required')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'A written justification is required.',
                  style: context.type.tiny,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Reusable question templates: the shape of a task, saved once, generated from
/// many times.
///
/// Lives on Skills & templates because that tab already holds what was read OUT
/// of the SOP, and a template is the examiner's own correction to that reading.
class _TaskTemplatePanel extends StatelessWidget {
  const _TaskTemplatePanel({required this.store, required this.g});

  final AppStore store;
  final Generator g;

  /// THIS SOP's templates, and only these.
  ///
  /// The panel used to append every OTHER project's templates under a "From
  /// other projects" heading, on the reasoning that a shape authored for one
  /// project is often right for the next. Form Studio's **Question types** tab
  /// is now that surface - it lists the whole library, built-in and designed,
  /// with edit and preview on each row - so repeating it here made this panel
  /// grow without bound as the library did, and buried the two things it is
  /// actually for: what was drafted from THIS SOP and what was authored by hand
  /// against it.
  List<TaskTemplate> get _mine => store.taskTemplates
      .where((TaskTemplate t) => t.originId?.toString() == g.id)
      .toList();

  @override
  Widget build(BuildContext context) {
    final bool hasSop = g.fileCount > 0;
    return Panel(
      title: 'Question Templates',
      note:
          'Describe a task once - its axes and their options - then ask for '
          'that many of it on the Generation tab.',
      headActions: <Widget>[
        Btn(
          'Draft from SOP',
          size: BtnSize.sm,
          icon: Icons.auto_awesome,
          busy: store.isBusy('draft:${g.id}'),
          // The cost belongs on the control: this is a real model call, and the
          // result is a starting point rather than a finished template.
          tooltip: hasSop
              ? 'One model call (real money). Returns an editable draft - '
                    'nothing is saved until you press Save.'
              : 'Upload the SOP on the Resources tab first.',
          onPressed: hasSop ? () => _draft(context) : null,
        ),
        // Draft from SOP's kill: frees the button at once and drops the reply.
        if (store.isBusy('draft:${g.id}'))
          Btn.danger(
            'Stop',
            size: BtnSize.sm,
            icon: Icons.stop_circle_outlined,
            tooltip:
                'Stop drafting. Nothing is saved; the model call already in '
                'flight finishes and is billed.',
            onPressed: () => store.cancelTemplateDraft(g.id),
          ),
        Btn(
          'New Template',
          variant: BtnVariant.primary,
          size: BtnSize.sm,
          icon: Icons.add,
          tooltip: 'Author a task shape by hand.',
          onPressed: () => _open(context, null),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // SAMPLE QUESTIONS LIVE WITH "DRAFT FROM SOP" TOO, because it reads
          // them as the shape of a right answer. The same list as Generation >
          // Advanced options, not a second one. Above the list rather than
          // beside the button: an operator uploads them once, then drafts.
          _CategoryFiles.samples(store: store, g: g),
          const SizedBox(height: 16),
          // `_mine`, NOT `store.taskTemplates`. The empty line has to describe
          // THIS panel: with the other-projects block gone, a library full of
          // templates authored elsewhere would otherwise suppress the "no
          // templates yet" line on a generator that genuinely has none, and the
          // operator would see an empty panel with no explanation.
          if (_mine.isEmpty)
            const EmptyLine(
              'No templates yet for this SOP. Draft one from the SOP, or '
              'author one by hand. The whole question-type library lives under '
              'Form Studio, on the Question types tab.',
            )
          else
            for (final TaskTemplate tpl in _mine)
              _TemplateRow(store: store, g: g, tpl: tpl),
        ],
      ),
    );
  }

  Future<void> _draft(BuildContext context) async {
    final TaskTemplate? draft = await store.draftTaskTemplate(g.id);
    if (draft == null || !context.mounted) return;
    // Straight into the designer: an unedited draft is never saved, so the
    // editor IS the review step.
    _open(context, draft);
  }

  void _open(BuildContext context, TaskTemplate? tpl) {
    showToastedDialog<void>(
      context,
      builder: (BuildContext _) =>
          TaskTemplateEditor(store: store, generatorId: g.id, template: tpl),
    );
  }
}

/// One template in the list: what it is, and what it costs to use.
class _TemplateRow extends StatelessWidget {
  const _TemplateRow({required this.store, required this.g, required this.tpl});

  final AppStore store;
  final Generator g;
  final TaskTemplate tpl;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final int used = g.shapeQuotas[tpl.shapeKey] ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // WRAP, NOT ROW. The name is Flexible but every badge beside it
                // is fixed-width, so four of them - "Model draft, edited",
                // "Generates nothing", "Needs attention", "x 2 this run" - blew
                // past the panel on a narrow window and Flutter painted the
                // yellow overflow stripe over the Edit button. A Wrap degrades
                // to a second line instead, which is what a row of independent
                // labels should do.
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: Text(
                        tpl.name,
                        style: context.type.small,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (tpl.isModelDrafted)
                      StatusBadge('Model draft, edited', Tone.inert),
                    // WOULD THIS ACTUALLY GENERATE? A template whose questions
                    // fail their answer-key contract is indistinguishable from
                    // a healthy one here - same name, same type, same count -
                    // and only announces itself when a paid run returns
                    // nothing. Four of six live templates were in that state.
                    if (tpl.isUnusable)
                      StatusBadge('Generates nothing', Tone.bad)
                    else if (tpl.isPartlyBroken)
                      StatusBadge(
                        'Only ${tpl.usableCount} of ${tpl.itemCount} usable',
                        Tone.warn,
                      ),
                    // WOULD IT GENERATE THE WRONG THING? Separate from
                    // "generates nothing": the shape is authored fine and the
                    // run will succeed, but what comes out is not what the SOP
                    // describes - an image task shown no picture, or a media
                    // task with no brief so every item invents its own
                    // subject. Computed on the record, so it survives the
                    // drafting toast and is here on every visit.
                    if (tpl.shapeWarnings.isNotEmpty)
                      StatusBadge(
                        tpl.shapeWarnings.length == 1
                            ? 'Needs attention'
                            : '${tpl.shapeWarnings.length} things to fix',
                        Tone.warn,
                      ),
                    if (used > 0) StatusBadge('× $used this run', Tone.accent),
                  ],
                ),
                Text(
                  <String>[
                    '${tpl.itemCount} question(s)',
                    if (tpl.questionType.isNotEmpty) tpl.questionType,
                    // No "from <project>" line: this panel now lists only the
                    // templates belonging to THIS SOP, so naming their origin
                    // would restate the panel they are already in.
                  ].join(' · '),
                  style: context.type.tiny.copyWith(color: t.textMuted),
                ),
                // WHAT THIS TEMPLATE ACTUALLY ASKS, not just its item count.
                // Every LLM-drafted A/B template is named "Compare
                // AI-Generated Images" - the same title on every row - so
                // "5 question(s) · image_ab" was the ONLY thing distinguishing
                // three unrelated templates in the picker, and it did not.
                // This is the first question's own wording, read straight off
                // the same structure the generator will use.
                if (tpl.shapeSummary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      tpl.shapeSummary,
                      style: context.type.tiny,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                // THE WARNING ITSELF, not only a badge. A badge says something
                // is wrong; this says WHAT, on the row where the operator is
                // about to set a quota against it. One line each, because every
                // warning is already written as a single actionable sentence.
                for (final String w in tpl.shapeWarnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      w,
                      style: context.type.tiny.copyWith(color: t.warnDot),
                    ),
                  ),
              ],
            ),
          ),
          // TOP-ALIGNED, so the actions stay level with the template name
          // instead of drifting down the card as warnings and the shape summary
          // make the left column taller.
          const SizedBox(width: 10),
          Btn(
            'Edit',
            size: BtnSize.sm,
            onPressed: () => showToastedDialog<void>(
              context,
              builder: (BuildContext _) => TaskTemplateEditor(
                store: store,
                generatorId: g.id,
                template: tpl,
              ),
            ),
          ),
          Btn(
            'Archive',
            size: BtnSize.sm,
            // Archiving also drops any count that referenced it, so generation
            // is never handed a shape it cannot resolve.
            tooltip:
                'Hides it from the picker. Questions already generated '
                'from it are unaffected.',
            busy: store.isBusy('template:${tpl.id}'),
            onPressed: () => store.archiveTaskTemplate(tpl.id),
          ),
        ],
      ),
    );
  }
}

/// The help line under "Questions to generate", including the quota split.
///
/// Reads like the examiner's own request back at them: "8 questions — 2 MCQ,
/// 3 Rubric, 3 the model's choice". The total is `_effectiveCount`, the SAME
/// number the field and the Generate button show - never computed twice.
String _countHelp(Generator g) {
  final Map<String, int> quotas = g.shapeQuotas;
  if (_quotaFloor(g) == 0) {
    return g.countIsAuto
        ? 'Auto - the model decides from what the SOP contains.'
        : 'Pinned to ${g.sopQuestionCount}. Drafts only; nothing reaches a '
              'candidate until a human approves it.';
  }
  final int total = _effectiveCount(g);
  final List<String> parts = <String>[
    for (final MapEntry<String, int> e in quotas.entries)
      e.key.startsWith('template:')
          ? '${e.value} from a saved task'
          : '${e.value} ${QType.parse(e.key).short}',
    // The "any" chips, one item each. Listed rather than folded into the
    // remainder below, so the parts add up to the total in front of them and
    // a reader can check the arithmetic without opening the type row.
    for (final QType t in g.allowedTypes)
      if (!quotas.containsKey(t.wire)) '1 ${t.short}',
  ];
  final int free = total - _quotaFloor(g);
  if (free > 0) parts.add("$free the model's choice");
  return '$total question${total == 1 ? '' : 's'} - ${parts.join(', ')}. '
      'Drafts only; nothing '
      'reaches a candidate until a human approves it.';
}

/// One allowed type, with how many items of it to generate: `MCQ  x 2  - +`.
///
/// The count lives ON the chip rather than in a separate table, so the examiner
/// reads the split off the same control they used to pick the type. A type with
/// no explicit count still gets at least one item (the coverage floor), which is
/// why the resting state reads "any" rather than "0".
class _TypeQuotaChip extends StatelessWidget {
  const _TypeQuotaChip({
    required this.store,
    required this.g,
    required this.type,
    required this.locked,
    required this.onRemove,
  });

  final AppStore store;
  final Generator g;
  final QType type;
  final bool locked;
  final VoidCallback onRemove;

  int get _count => g.shapeQuotas[type.wire] ?? 0;

  void _set(int next) {
    final Map<String, int> quotas = Map<String, int>.of(g.shapeQuotas);
    if (next <= 0) {
      quotas.remove(type.wire);
    } else {
      quotas[type.wire] = next;
    }
    store.setShapeQuotas(g.id, quotas);
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final int count = _count;

    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: t.bgSubtle,
        border: Border.all(color: count > 0 ? t.primary : t.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(type.short, style: context.type.small),
          const SizedBox(width: 6),
          Text(
            count > 0 ? '× $count' : '× any',
            style: context.type.small.copyWith(
              color: count > 0 ? t.primary : t.textMuted,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          if (!locked) ...<Widget>[
            _StepButton(
              icon: Icons.remove,
              // At 1, stepping down clears the quota back to "any" rather than
              // reaching 0 - a type in the allow-list always gets an item.
              tooltip: count <= 1 ? 'Let the model decide' : 'One fewer',
              onTap: () => _set(count - 1),
              enabled: count > 0,
            ),
            _StepButton(
              icon: Icons.add,
              tooltip: 'One more',
              onTap: () => _set(count + 1),
              enabled: true,
            ),
            _StepButton(
              icon: Icons.close,
              tooltip: 'Remove this type',
              onTap: onRemove,
              enabled: true,
            ),
          ],
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.enabled,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 14, color: enabled ? t.textMuted : t.border),
        ),
      ),
    );
  }
}

/// Choose which question shapes a run may author, and how many of each.
///
/// ONE PICKER FOR BOTH KINDS OF SHAPE. A legacy question type and a Form Studio
/// task template are the same decision to the person making it - "what should
/// this run produce?" - but they used to live in two controls on two parts of
/// the screen: this dropdown for the built-in types, and a separate quota list
/// further down for templates. An operator had to know that a template was not
/// a "question type" to find it, and the two lists could disagree about what a
/// run would actually author. They are now one list: built-in types first, then
/// every active template, each as a removable chip with its own count.
///
/// Empty means "the model decides", which is the recommended setting - it lets
/// the generator pick the shape that reproduces the SOP's real task for each
/// item rather than forcing one.
/// The width of the "Add a type" dropdown.
///
/// STATED HERE RATHER THAN LEFT TO THE CONTENT, because the content is data.
/// Wide enough for the longest built-in label ("Image - Side-by-side
/// comparison") and for the hint, so nothing the MODULE ships ever truncates;
/// a task-template name longer than this ellipsises in the open menu, which is
/// the right trade against it setting the width of a box the operator sees
/// while the menu is shut.
const double _kAddTypeWidth = 280;

class _TypePicker extends StatelessWidget {
  const _TypePicker({
    required this.store,
    required this.g,
    required this.disabled,
  });

  final AppStore store;
  final Generator g;
  final bool disabled;

  /// Templates this run already asks for, in template order.
  List<TaskTemplate> get _chosenTemplates => store.taskTemplates
      .where((TaskTemplate tpl) => (g.shapeQuotas[tpl.shapeKey] ?? 0) > 0)
      .toList();

  /// Quota keys naming a template the store cannot resolve, with their counts.
  ///
  /// THESE STILL COUNT, WHICH IS WHY THEY MUST BE VISIBLE. `quotaFloor` and
  /// `effectiveQuestionCount` sum the RAW map, so an unresolvable key keeps
  /// inflating the run's total while `_chosenTemplates` filters it out of the
  /// display. Archiving a template a generator references is enough to get
  /// there - the store-level archive only sweeps generators currently in
  /// memory - and the result was a Generate button promising 8 questions beside
  /// a picker showing 5, with no control anywhere to clear the missing 3. The
  /// run then authored generic items to make up the difference.
  ///
  /// Shown as a chip that says what it is and offers only removal: there is
  /// nothing to raise or lower on a shape that no longer exists.
  Map<String, int> get _orphanQuotas {
    final Set<String> known = store.taskTemplates
        .map((TaskTemplate t) => t.shapeKey)
        .toSet();
    return <String, int>{
      for (final MapEntry<String, int> e in g.shapeQuotas.entries)
        if (e.key.startsWith('template:') &&
            !known.contains(e.key) &&
            e.value > 0)
          e.key: e.value,
    };
  }

  void _dropQuotaKey(String key) {
    final Map<String, int> next = Map<String, int>.from(g.shapeQuotas)
      ..remove(key);
    store.setShapeQuotas(g.id, next);
  }

  /// One dropdown row's worth of description for a template.
  ///
  /// The bare name is not enough: an SOP draft run can produce three templates
  /// sharing one generic title, and picking the wrong one is
  /// invisible until the questions come back. The shape summary distinguishes
  /// them, and the health note is what stops an operator paying for a run that
  /// authors nothing - `usable_count` is server-derived, so this is the only
  /// place it can be surfaced at the moment of choosing.
  static String _templateSubtitle(TaskTemplate tpl) {
    final List<String> bits = <String>[];
    final String shape = tpl.shapeSummary.trim();
    if (shape.isNotEmpty) bits.add(shape);
    if (tpl.isUnusable) {
      bits.add('GENERATES NOTHING');
    } else if (tpl.isPartlyBroken) {
      bits.add('only ${tpl.usableCount}/${tpl.itemCount} usable');
    }
    return bits.join('  ·  ');
  }

  void _setTemplate(TaskTemplate tpl, int count) {
    final Map<String, int> next = Map<String, int>.from(g.shapeQuotas);
    if (count <= 0) {
      next.remove(tpl.shapeKey);
    } else {
      next[tpl.shapeKey] = count;
    }
    store.setShapeQuotas(g.id, next);
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final List<QType> chosen = g.allowedTypes;
    // Only the types the pipeline can actually author. Offering one it cannot
    // would let an operator build a generator that silently produces nothing
    // for that type. Nothing is excluded today, but the filter stays so a type
    // the module retires from generation leaves the picker with it.
    final List<QType> remaining = QType.generatable
        .where((QType q) => !chosen.contains(q))
        .toList();
    final List<TaskTemplate> chosenTpl = _chosenTemplates;
    final List<TaskTemplate> remainingTpl = store.taskTemplates
        .where((TaskTemplate tpl) => (g.shapeQuotas[tpl.shapeKey] ?? 0) <= 0)
        .toList();
    final bool locked = disabled;
    final bool anythingToAdd = remaining.isNotEmpty || remainingTpl.isNotEmpty;

    // THE FRAME FILLS ONCE ITS CONTENT WRAPS, and hugs it until then.
    //
    // Hugging was never broken: a `Wrap` sizes to its widest ROW and this box
    // takes the child's width, so an empty picker was already its dropdown and
    // each chip already widened it. Measured at 0, 1 and 2 chips the frame is
    // identical with and without the wrapper below.
    //
    // What WAS broken is the moment the content wraps. The widest row is then
    // less than the card - three chips ended at ~1388 of ~1433 - so the frame
    // stood two rows tall while stopping short, reading as a field cut off with
    // the "Add a type" dropdown dangling under it.
    //
    // `IntrinsicWidth` asks the `Wrap` how wide it would be on ONE line, which
    // is the sum of every item. Below the card that is the hug it already did;
    // above it, the incoming constraint clamps to the card and the frame is
    // honestly full. Either honestly narrow or honestly full, never stranded
    // between the two.
    //
    // AN EARLIER VERSION WRAPPED THIS IN `Align` TOO, on the theory that the
    // column above stretches its children. It does not - the frame hugs
    // perfectly well without it, and the belief came from a measurement that
    // had picked up the page card rather than this box.
    final Widget frame = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        border: Border.all(color: t.border),
        borderRadius: Radii.input,
        color: t.bgApp,
      ),
      child: Wrap(
        spacing: 0,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: _spaced(<Widget>[
          for (final QType q in chosen)
            // COUNT ON THE CHIP: "MCQ x 2" with steppers, because the examiner
            // asked to see the split on the type they picked rather than in a
            // separate table that could disagree with it.
            _TypeQuotaChip(
              store: store,
              g: g,
              type: q,
              // A type this build does not know (L2) is shown, never edited:
              // its steppers would post "unsupported" as a quota key. It goes
              // back to the server as sent - see `Generator.typeCodes`.
              locked: locked || q == QType.unsupported,
              onRemove: () =>
                  store.setAllowedTypes(g.id, <QType>[...chosen]..remove(q)),
            ),
          // A TEMPLATE READS AS A SHAPE, not as a second kind of setting: same
          // chip, same steppers, same remove affordance as a built-in type.
          for (final TaskTemplate tpl in chosenTpl)
            _TemplateQuotaChip(
              name: tpl.name,
              count: g.shapeQuotas[tpl.shapeKey] ?? 1,
              locked: locked,
              onLess: () =>
                  _setTemplate(tpl, (g.shapeQuotas[tpl.shapeKey] ?? 1) - 1),
              onMore: () =>
                  _setTemplate(tpl, (g.shapeQuotas[tpl.shapeKey] ?? 0) + 1),
              onRemove: () => _setTemplate(tpl, 0),
            ),
          // A quota whose template is gone. Named plainly and removable, so the
          // count on the Generate button and the chips in here can never
          // disagree about what the run will author.
          for (final MapEntry<String, int> e in _orphanQuotas.entries)
            _TemplateQuotaChip(
              name: 'Missing form (${e.key.split(":").last})',
              count: e.value,
              locked: locked,
              missing: true,
              onLess: null,
              onMore: null,
              onRemove: locked ? null : () => _dropQuotaKey(e.key),
            ),
          if (anythingToAdd && !locked)
            // A FIXED WIDTH, BECAUSE A DROPDOWN SIZES TO ITS WIDEST MENU ITEM.
            //
            // `DropdownButton` measures every item to decide how wide the
            // CLOSED control is, and the frame above is an `IntrinsicWidth`
            // over this - so the longest string in a menu nobody has opened was
            // setting the width of the box. The items include task-template
            // names, which are data: an environment holding one called
            // "Task: Describe UI Elements - Spotify Web Player (Full Coverage)"
            // drew a 933pt frame around a 480pt one, measured, with nothing
            // ticked either way. Production looked like a half-empty field and
            // local looked fine, and the only difference between them was that
            // `etp_local` had no templates in it at all.
            //
            // So the control is sized by the control, not by the menu. Chips
            // still widen the frame and it still fills once they wrap - that is
            // the picker growing with what the examiner PICKED, which is the
            // behaviour worth keeping. `isExpanded` is what lets the hint and
            // the items lay out inside that width instead of overflowing it.
            SizedBox(
              width: _kAddTypeWidth,
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  hint: Text(
                    chosen.isEmpty && chosenTpl.isEmpty
                        ? 'Any type'
                        : 'Add a type',
                    style: context.type.small.copyWith(color: t.textMuted),
                  ),
                  value: null,
                  isDense: true,
                  items: <DropdownMenuItem<String>>[
                    for (final QType q in remaining)
                      DropdownMenuItem<String>(
                        value: 'type:${q.wire}',
                        child: Text(
                          q.label,
                          style: context.type.body,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    // The heading is a disabled row rather than a divider so a
                    // reader can tell WHY the second group is different: these
                    // are the forms someone designed, not built-in shapes.
                    if (remaining.isNotEmpty && remainingTpl.isNotEmpty)
                      DropdownMenuItem<String>(
                        enabled: false,
                        value: null,
                        child: Text(
                          'From Form Studio',
                          style: context.type.tiny.copyWith(color: t.textMuted),
                        ),
                      ),
                    // NAME PLUS SHAPE PLUS HEALTH, not the bare name. An SOP
                    // draft run can mint three templates sharing one generic
                    // title, and with only the name on the row an
                    // operator cannot tell them apart - picking the wrong one is
                    // invisible until the questions come back. The health note is
                    // the other half: `usable_count` is server-derived, so this
                    // row is the only place it can be read at the moment of
                    // choosing, and an unusable template selected here spends a
                    // paid generation run authoring nothing.
                    for (final TaskTemplate tpl in remainingTpl)
                      DropdownMenuItem<String>(
                        value: tpl.shapeKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              tpl.name,
                              style: context.type.body,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (_templateSubtitle(tpl).isNotEmpty)
                              Text(
                                _templateSubtitle(tpl),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.type.tiny.copyWith(
                                  color: tpl.isUnusable
                                      ? t.destText
                                      : (tpl.isPartlyBroken
                                            ? t.warnText
                                            : t.textMuted),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                  onChanged: (String? picked) {
                    if (picked == null) return;
                    if (picked.startsWith('type:')) {
                      final String wire = picked.substring(5);
                      // `parse` falls back to mcq for an unknown wire, so guard
                      // on membership first rather than silently adding mcq.
                      final bool known = QType.generatable.any(
                        (QType x) => x.wire == wire,
                      );
                      if (known) {
                        store.setAllowedTypes(g.id, <QType>[
                          ...chosen,
                          QType.parse(wire),
                        ]);
                      }
                      return;
                    }
                    for (final TaskTemplate tpl in store.taskTemplates) {
                      if (tpl.shapeKey == picked) {
                        _setTemplate(tpl, 1);
                        return;
                      }
                    }
                  },
                ),
              ),
            ),
          if (chosen.isEmpty && chosenTpl.isEmpty && !anythingToAdd)
            Text(
              'Every type is allowed',
              style: context.type.small.copyWith(color: t.textMuted),
            ),
        ]),
      ),
    );

    // `IntrinsicWidth` asks the `Wrap` how wide it would be on ONE line - every
    // chip plus the dropdown - and sizes to that, so an empty picker is its
    // dropdown, one chip is wider, two wider still. Once that single-line width
    // exceeds the card the incoming constraint clamps it, the frame becomes
    // exactly the card, and the `Wrap` wraps inside it.
    //
    // A `Wrap` alone reports its WIDEST ROW, so once it wrapped the frame
    // stopped at ~810 of ~1060 while standing two rows tall - a field cut off
    // mid-row with the dropdown dangling under it. Asking for the unwrapped
    // width means the frame is either honestly narrow or honestly full.
    //
    // `Align` is insurance rather than the fix. The one caller today is the
    // `CrossAxisAlignment.start` column holding the "Allowed question types"
    // group, which already hands this a loose constraint - but a stretching
    // parent would hand it a tight full-width one, and the hug would silently
    // stop working. Aligning left keeps the width this widget's own business.
    return IntrinsicWidth(child: frame);
  }
}

/// The picker's items with their gaps folded in, as a LEADING pad on each.
///
/// `Wrap.spacing` would be the obvious place for this, and it is the wrong one:
/// `RenderWrap.computeMaxIntrinsicWidth` sums its children's own max intrinsic
/// widths and never adds `spacing` (`rendering/wrap.dart`), so a frame sized by
/// `IntrinsicWidth` comes out short by one gap for every item after the first -
/// and the last of them, the "Add a type" dropdown, drops to a row of its own
/// with the row beside it still half empty.
///
/// Leading rather than trailing so the frame has no dead strip down its right
/// edge, and so the first item still sits flush against the padding.
List<Widget> _spaced(List<Widget> items) => <Widget>[
  for (int i = 0; i < items.length; i++)
    Padding(
      padding: EdgeInsets.only(left: i == 0 ? 0 : 6),
      child: items[i],
    ),
];

/// A chosen Form Studio template, shown exactly like a built-in type chip.
class _TemplateQuotaChip extends StatelessWidget {
  const _TemplateQuotaChip({
    required this.name,
    required this.count,
    required this.locked,
    required this.onLess,
    required this.onMore,
    required this.onRemove,
    this.missing = false,
  });

  final String name;
  final int count;
  final bool locked;
  // NULLABLE, for the missing-form case: a shape that no longer exists has
  // nothing to raise or lower, and offering a stepper that cannot mean anything
  // is worse than offering none. Only removal stays.
  final VoidCallback? onLess;
  final VoidCallback? onMore;
  final VoidCallback? onRemove;

  /// This quota names a template the store cannot resolve. Drawn in the danger
  /// tint so it reads as something to clear, not as a shape to configure.
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: const EdgeInsets.only(left: 9, right: 3),
      decoration: BoxDecoration(
        color: missing ? t.destBg : t.bgMuted,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: missing ? t.destText : t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // The icon says "this came from a designed form" without spending a
          // word on it, so the chip stays the same width as a type chip.
          Icon(
            missing ? Icons.error_outline : Icons.dashboard_customize_outlined,
            size: 12,
            color: missing ? t.destText : t.textMuted,
          ),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Text(
              name,
              style: context.type.small,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            '× $count',
            style: context.type.small.copyWith(
              color: missing ? t.destText : t.primary,
            ),
          ),
          if (!locked) ...<Widget>[
            // Steppers only when there is a shape to ask more or less of.
            if (onLess != null)
              _StepButton(
                icon: Icons.remove,
                tooltip: 'One fewer',
                enabled: true,
                onTap: onLess!,
              ),
            if (onMore != null)
              _StepButton(
                icon: Icons.add,
                tooltip: 'One more',
                enabled: true,
                onTap: onMore!,
              ),
            if (onRemove != null)
              _StepButton(
                icon: Icons.close,
                tooltip: missing
                    ? 'Clear this quota - the form it names no longer exists, '
                          'but it is still being counted'
                    : 'Do not generate this task',
                enabled: true,
                onTap: onRemove!,
              ),
          ],
        ],
      ),
    );
  }
}

/// Re-run the paid hybrid ranking.
///
/// Its own widget because both the empty state and the populated one offer it:
/// an empty tab needs it to produce anything at all, and a populated one needs
/// it after the library has grown, when the stored pairs no longer reflect
/// what is in it.
class _RankBtn extends StatelessWidget {
  final AppStore store;
  final Generator g;

  const _RankBtn({required this.store, required this.g});

  @override
  Widget build(BuildContext context) => Btn(
    'Re-run AI Ranking',
    tooltip:
        'Score this project against every other one again and rebuild '
        'the similar-projects list. Costs an LLM call. Worth re-running '
        'after Manage vocabulary, since ranking compares tag sets '
        'and a cleaned vocabulary changes what matches.',
    size: BtnSize.sm,
    busy: store.isBusy('similarity:${g.id}'),
    onPressed: store.isLive ? () => store.rankSimilarity(g.id) : null,
  );
}

/// Generation: count and types, but only once the document has been read.
class _GenerationTab extends StatelessWidget {
  final AppStore store;
  final Generator g;

  /// Switch the page to Skills & templates.
  ///
  /// The tab strip is owned by the screen above, so a tab cannot move the
  /// selection itself. Passed in rather than reached for through a global so
  /// this widget stays testable on its own.
  final VoidCallback onShowSkills;

  /// The screen's last `/progress` reading, for the run stats. Null until the
  /// first tick lands, and then the stats are simply absent.
  final GenerationProgress? progress;

  const _GenerationTab({
    required this.store,
    required this.g,
    required this.onShowSkills,
    this.progress,
  });

  /// A field value sitting on the same baseline as the pills beside it.
  static Widget _inset(Widget child) =>
      Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: child);

  static Widget _num(String v) =>
      _inset(Mono(v, size: 13, weight: FontWeight.w600));

  /// The parts joined by a dot, or [none] when there are none.
  static String _line(List<String> parts, String none) =>
      parts.isEmpty ? none : parts.join(' \u00b7 ');

  static List<Widget> _runStats(GenerationProgress? p) {
    if (p == null || !p.hasRun) return const <Widget>[];
    final GenLane im = p.images;
    final GenLane vid = p.videos;
    return <Widget>[
      Field(
        label: 'Drafts this run',
        help:
            '${p.drafts.pending} pending \u00b7 ${p.drafts.approved} approved '
            '\u00b7 ${p.drafts.denied} denied',
        child: _num('${p.drafts.total}'),
      ),
      if (im.total > 0)
        Field(
          label: 'Images rendered',
          help: _line(<String>[
            if (im.failed > 0) '${im.failed} failed',
            if (im.pending > 0) '${im.pending} waiting',
            if (p.estMinutesLeft != null) 'about ${p.estMinutesLeft} min left',
          ], 'All rendered.'),
          child: _num('${im.done}/${im.total}'),
        ),
      if (vid.total > 0)
        Field(
          label: 'Videos ready',
          help: _line(<String>[
            if (vid.failed > 0) '${vid.failed} failed',
            if (vid.pending > 0) '${vid.pending} waiting',
          ], 'All ready.'),
          child: _num('${vid.ready}/${vid.total}'),
        ),
      // Only with a start stamp: the ledger is read from it, so a run from
      // before the stamp existed has no calls to count, not zero calls.
      if (p.startedAt != null)
        Field(
          label: 'Model calls',
          help: <String>[
            p.finishedAt == null
                ? '${humanDuration(Duration(seconds: p.elapsedS))} elapsed'
                : 'took ${humanDuration(Duration(seconds: p.elapsedS))}',
            if (p.lastStep.isNotEmpty && p.active) 'step ${p.lastStep}',
            if (p.costUsd != null) 'cost ${usd(p.costUsd!)}',
          ].join(' \u00b7 '),
          child: _num('${p.llmCalls}'),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;

    // THE GATE. You cannot sensibly choose what to generate before the
    // platform has read the document, so the whole surface waits on the
    // extraction RESULT. It DOES have an observable running state - the server
    // publishes `tag_extract_state` while the cron works - so a run in
    // progress says so here rather than showing the idle prompt again.
    if (!g.hasTags) {
      // FOUR STATES. A run that was refused is not a run that was never asked
      // for, and this gate told both of them "Extract the skills first" - an
      // instruction to repeat the thing that had just failed, with the reason
      // the module recorded sitting unread in the payload. Null while a run is
      // in flight, so a stale message never argues with live progress.
      final String? failure = g.isExtractingTags ? null : g.tagFailure;
      final bool noFile = g.fileCount == 0;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Notice(
              tone: g.isExtractingTags
                  ? Tone.info
                  : (failure != null && !noFile ? Tone.bad : Tone.warn),
              // Three states, not two. With no document the blocker is not the
              // extraction, it is the file the extraction reads - and saying
              // "extract the skills first" there sends the operator at a button
              // that is disabled for a reason it does not explain.
              strong: noFile
                  ? 'Attach the SOP first.'
                  : (g.isExtractingTags
                        ? 'Reading the SOP now.'
                        : (failure != null
                              ? 'Reading the SOP failed.'
                              : 'Extract the skills first.')),
              // While a run is in flight this tab states the BLOCK and points
              // at the tab doing the work. Narrating the same progress in two
              // places is how the operator ended up watching it somewhere the
              // result was never going to appear.
              text: noFile
                  ? 'Nothing uploaded yet. Add the document on the Resources tab.'
                  : (g.isExtractingTags
                        ? 'Progress is on the Skills & templates tab, and these '
                              'options unlock as soon as it finishes.'
                        : (failure ??
                              'How many questions are worth generating, and '
                                  'which types make sense, both depend on what '
                                  'this SOP turns out to contain - so that '
                                  'choice is not offered until the document '
                                  'has been read.')),
              actions: <Widget>[
                if (g.isExtractingTags)
                  Btn(
                    'View Progress',
                    tooltip:
                        'Follow the extraction while it runs. It works in the '
                        'background on a cron tick, so the page does not block and '
                        'the state here is the server\'s, not a guess.',
                    size: BtnSize.sm,
                    onPressed: onShowSkills,
                  )
                else
                  Btn.primary(
                    failure != null ? 'Try again' : 'Extract skills',
                    tooltip:
                        'Read the SOP and write this project\'s skill vocabulary: the '
                        'domain, modality, output format and skills it covers. Costs '
                        'one LLM call, runs in the background, and REPLACES the tags '
                        'currently on the project. Everything else here depends on it '
                        '- similarity ranking, and Backfill onto questions.',
                    size: BtnSize.sm,
                    // The SERVER's state, not a local in-flight flag: the work
                    // runs in a cron and outlives this tab.
                    busy: store.isBusy('tags:${g.id}'),
                    onPressed: g.fileCount > 0
                        ? () => store.extractTags(g.id)
                        : null,
                  ),
              ],
            ),
            const EmptyLine(
              'Nothing to configure until the skills are extracted.',
            ),
          ],
        ),
      );
    }

    final bool running = g.isGenerating;
    final List<Job> mine = store.jobs
        .where((Job j) => j.genId == g.id)
        .toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
      child: Stack16(<Widget>[
        Notice(
          tone: Tone.inert,
          text:
              'Reading this SOP found ${g.tags.length} tags. Generate '
              'against them below - everything arrives as a draft for review.',
        ),
        // A failed run, stated. The module records why; the console used to
        // discard it, so a generator that produced nothing looked idle.
        if (g.lastError != null)
          Notice(
            tone: Tone.bad,
            strong: 'The last run failed.',
            text: g.lastError!,
          ),
        FieldGrid(<Widget>[
          Field(
            label: 'Questions to generate',
            // THE TOTAL IS DERIVED once per-shape counts exist. Stating the
            // pinned number alone would let the whole disagree with the parts:
            // generation treats the quotas as a floor and raises the total to
            // their sum, so the screen must say the same thing.
            help: _countHelp(g),
            // EDITABLE NOW. This printed the number and offered no way to
            // change it, so "generate 10 from this SOP" could only be said in
            // Odoo. Auto is a real choice rather than the absence of one, so
            // it is a button beside the number instead of a magic 0.
            child: _inset(_CountControl(store: store, g: g)),
          ),
          // "Task to generate" USED TO LIVE HERE. A template is one of the
          // shapes a run may author, so it now sits in the single question-type
          // picker above with the built-in types rather than in a second
          // control an operator had to know to look for. `_TaskToGenerate` is
          // gone; `_TypePicker` writes the same `shapeQuotas` map.
          // Beside the count, because the two answer the same question about
          // a run: how many questions, and how big each labelling one may
          // get. A plain stepper, NOT `_CountControl` - that control exists
          // only because "Questions to generate" has an Auto state where 0
          // means "the model decides", and this field has no such state: the
          // module refuses 0 outright, so every value here is a real number
          // and 1 is the floor.
          Field(
            label: 'Image annotation point count',
            // NAMES THE TYPE IT GOVERNS, IN THE TYPE'S CURRENT NAME. It read as
            // a limit on the whole run, so a generator with no annotation type
            // ticked still invited the operator to tune a number that could not
            // affect anything it was about to author. It then went on calling
            // the type "Labelling" after that word was retired from every badge
            // and picker in the app - so the one field that governs the type
            // was the last place still using a name the operator no longer sees
            // anywhere else. `QType.imageLabel.short` is the label it matches.
            help:
                'Image annotation questions only: the most numbered points any '
                'one of them may carry.',
            child: _inset(
              store.isLive
                  ? NumberField(
                      value: g.imageLabelCount,
                      // 1, not 0: the module rejects anything lower, and this
                      // control posts on every change - a reachable 0 would be
                      // a value the server answers with a toast.
                      min: 1,
                      max: 99,
                      onChanged: (int v) => store.setImageLabelCount(g.id, v),
                    )
                  : Mono(
                      '${g.imageLabelCount}',
                      size: 13,
                      weight: FontWeight.w600,
                    ),
            ),
          ),
          Field(
            label: 'Screenshot live websites',
            help:
                'Image annotation questions only. Off: the picture is AI-made. '
                'On: a real public website is screenshotted (an AI-made picture '
                'is used if the page cannot be captured).',
            child: _inset(
              Align(
                alignment: Alignment.centerLeft,
                // Named for screen readers; the Field label is only visual.
                child: Semantics(
                  label: 'Screenshot live websites',
                  child: Switch(
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    value: g.imageLabelLiveCapture,
                    onChanged: store.isLive
                        ? (bool v) => store.setImageLabelLiveCapture(g.id, v)
                        : null,
                  ),
                ),
              ),
            ),
          ),
          Field(
            label: 'Generation state',
            // THE RUN'S OWN RESULT FIRST, when the module sent one.
            //
            // This read the BANK - "Nothing generated yet" - which is a true
            // statement about the drafts and no answer at all about the run. A
            // paid call that returned five items and had every one rejected
            // printed exactly the same words as a generator nobody had ever
            // pressed the button on, beside a green "Done" pill.
            //
            // The FAILURE case leads, because it was still falling through to
            // the never-run string: a run that could not reach the model and a
            // generator nobody has touched are different facts and the operator
            // acts on them differently. The reason itself is on the page-level
            // banner; this tile only has to say WHICH of the two it is.
            help: (!g.isGenerating && g.sopGenError.isNotEmpty)
                ? 'The last run failed - see the banner above.'
                : g.sopGenReport.isNotEmpty
                ? g.sopGenReport
                : g.questionCount > 0
                ? '${g.questionCount} generated, ${g.approvedCount} approved '
                      'into the bank'
                : 'Nothing generated yet',
            child: _inset(
              Align(
                alignment: Alignment.centerLeft,
                child: Pill.state(g.sopGenState),
              ),
            ),
          ),
          // THE RUN IN NUMBERS, beside its state (§4.9). The banner above says
          // what the run is doing; these say how far it got.
          ..._runStats(progress),
          Field(
            label: 'Skills extraction',
            help: g.tagExtractLastRun.isEmpty
                ? 'Not run yet.'
                : 'Last run ${g.tagExtractLastRun}'
                      '${g.lastExtractSummary.isEmpty ? '' : ' - '
                                '${g.lastExtractSummary}'}',
            child: _inset(
              Align(
                alignment: Alignment.centerLeft,
                child: Pill.state(g.tagExtractState),
              ),
            ),
          ),
          Field(
            label: 'Attached files',
            // The help here described SIMILAR GENERATORS - a copy-paste from
            // the field below it - so the file count read "No similar
            // generators found", which is not an answer to "how many files".
            help: g.fileCount > 0
                ? 'Documents this generator reads when it writes questions.'
                : 'Nothing attached. Upload an SOP on the Resources tab.',
            child: _inset(
              Mono('${g.fileCount}', size: 13, weight: FontWeight.w600),
            ),
          ),
          if (g.structureCount > 0)
            Field(
              label: 'Question structures',
              help: g.structureMode == 'all'
                  ? 'Generating against every extracted structure.'
                  : '${g.selectedStructureCount} of ${g.structureCount} '
                        'selected.',
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Mono(
                  '${g.structureCount}',
                  size: 13,
                  weight: FontWeight.w600,
                ),
              ),
            ),
        ]),
        // THE SHAPES THIS RUN MAY AUTHOR. Above the optional line, because
        // it is not optional: `_canGenerate` refuses a run with no type
        // ticked, so a picker hidden behind "Advanced options (optional)" was
        // a required step filed under refinements - and the button it gates
        // gave no hint where to go.
        //
        // ONE `Stack16` CHILD, NOT FOUR. Stack16 puts 16px between every child
        // it is handed (`panel.dart:608`), so a `SizedBox(height: 6)` between
        // the picker and its help line actually spent 38 - and the note read
        // as a paragraph about the screen rather than as this field's own.
        // Grouped here, the internal rhythm is the 4px `Field` uses and the 16
        // lands around the whole group, where it was meant to.
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Eyebrow('Allowed question types'),
                const Spacer(),
                // "Select all" - the module's own `select_all_types`, which
                // means "let the model pick any shape" rather than "tick every
                // box". Beside the picker, as in the backend form.
                Text('Select all', style: context.type.small),
                const SizedBox(width: 6),
                // DERIVED, not stored. "all selected" is simply every
                // generatable type being in the allow-list - which is what the
                // module's own `types_all_selected` computes too.
                Switch(
                  // Its 48px tap target set the height of the label row, which
                  // is a row of 16px text.
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  value: g.allowedTypes.length == QType.generatable.length,
                  onChanged: running
                      ? null
                      : (bool v) => store.selectAllTypes(g.id, v),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // A PICKER, not a row of toggles. Every type was a button whose
            // pressed state came from `allowedTypes` - which the console
            // then wiped on the next background refresh, so a tick appeared
            // to do nothing. With that fixed, a dropdown that ADDS a
            // removable chip shows the selection as a short list; a row of
            // equal buttons said nothing about which were chosen.
            //
            // It sizes to what is in it, and does that itself now - see the
            // `IntrinsicWidth` at the end of `_TypePicker.build`. Stack16
            // stretches its children, so a generator with nothing ticked once
            // drew a full-bleed box around one short "Any type" control; today
            // the frame grows with the chips and stops at the panel width,
            // whatever alignment it is placed under.
            _TypePicker(store: store, g: g, disabled: running),
            const SizedBox(height: 4),
            Text(
              'Pick the shapes this generator may author. At least one is '
              'required; tick several and the generator chooses per item.',
              style: context.type.tiny.copyWith(height: 1.45),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // EVERYTHING BELOW IS OPTIONAL, and says so. Upload an SOP, set a
        // count, pick the shapes, press Generate is the whole job; the
        // refinements below are collapsed by default, as the backend form
        // does it.
        Text(
          'That is all you need. Press Generate questions below; everything '
          'else here is optional.',
          style: context.type.small.copyWith(color: t.textMuted),
        ),
        _Advanced(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Allowed question types used to live here. It is a
              // REQUIREMENT, not a refinement - `_canGenerate` refuses a run
              // without at least one type - so it now sits above the
              // "everything else is optional" line with the rest of the job.
              const SizedBox(height: 18),
              // EXTRA INSTRUCTIONS - `source_text`. The server has always
              // accepted it and no screen showed it, so the only way to steer a
              // run in words was to open Odoo.
              _ExtraInstructions(store: store, g: g),
              const SizedBox(height: 18),
              // SAMPLE QUESTIONS and REFERENCE FILES. The upload route has
              // always taken a category and the app only ever sent `sop`, so
              // several were unreachable. Each lists what is already attached.
              _CategoryFiles.samples(store: store, g: g),
              const SizedBox(height: 14),
              _CategoryFiles(
                store: store,
                g: g,
                kind: ResourceKind.reference,
                title: 'Reference Files',
                help:
                    'Background the model may draw on but must not quiz '
                    'directly.',
              ),
            ],
          ),
        ),
        Row(
          children: <Widget>[
            Btn.primary(
              running
                  ? 'Generating...'
                  // "Generate questions" when the count is automatic AND no
                  // quota is set: naming a number the operator never chose is
                  // a promise the run will not keep.
                  //
                  // Reads `_effectiveCount`, NOT `g.plannedCount` (a raw echo
                  // of `sopQuestionCount`): a generator with `template x2 +
                  // MCQ x3` and an un-pinned/stale server count showed
                  // "Generate 0 questions" here while the help text above
                  // correctly said "10 questions - ...". Same screen, two
                  // different numbers - this makes the button read the one
                  // the run will actually honour.
                  : (g.countIsAuto && g.shapeQuotas.isEmpty)
                  ? 'Generate questions'
                  : 'Generate ${_effectiveCount(g)} '
                        'question${_effectiveCount(g) == 1 ? '' : 's'}',
              busy: running,
              onPressed: running || !_canGenerate(g)
                  ? null
                  : () => store.startGeneration(g.id),
            ),
            if (!_canGenerate(g)) ...<Widget>[
              const SizedBox(width: 9),
              Text(
                'Pick at least one question type, or a task to generate.',
                style: context.type.small.copyWith(color: t.textMuted),
              ),
            ],
          ],
        ),
        // PIPELINES IS A SEED-MODE ANIMATION, and only ever was.
        //
        // `store.jobs` is filled in exactly two places, both inside the seed
        // branch: `_load()` from the fixtures, and `generateQuestions` after
        // its `if (_live) { ...; return; }`. That method says so itself - "the
        // local job list below is the seed's animation, not a real queue". A
        // live generation writes drafts server-side and moves `sop_gen_state`;
        // nothing ever adds a Job.
        //
        // So against a real backend this panel read "No jobs yet. Run a
        // generation to see progress here." permanently - including on a
        // generator that had just produced ten questions. It was not merely
        // redundant with the Generation state and Skills extraction tiles
        // above; it contradicted them. Kept for the design-review build, where
        // it animates and is the only progress there is.
        if (!store.isLive) ...<Widget>[
          const Hr(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Align(
                alignment: Alignment.centerLeft,
                child: Eyebrow('Pipelines'),
              ),
              const SizedBox(height: 9),
              if (mine.isEmpty)
                const EmptyLine(
                  'No jobs yet. Run a generation to see progress here.',
                )
              else
                Stack16(<Widget>[
                  for (final Job j in mine)
                    JobCard(
                      name: j.name,
                      state: j.state,
                      meta: j.meta,
                      detail: j.detail,
                      progress: j.progress,
                      onRetry: j.state.canRetry
                          ? () => store.retryJob(j.id)
                          : null,
                    ),
                ], gap: 9),
            ],
          ),
        ],
      ]),
    );
  }
}

/// Drafts: every question this generator produced, with a decision per row.
class _DraftsTab extends StatelessWidget {
  final AppStore store;
  final Generator g;

  /// Retry one draft's failed image, through the screen so its watch restarts.
  final void Function(String draftId)? onRetryImages;

  const _DraftsTab({required this.store, required this.g, this.onRetryImages});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;

    // EVERY QUESTION THIS GENERATOR PRODUCED, not just the undecided ones.
    //
    // Approving moved a row out of `store.drafts` and into `store.bank`, so
    // this tab emptied itself as it was worked: a generator whose ten
    // questions had all been approved reported "No drafts yet" and there was
    // no screen anywhere that answered "what did this generator author". The
    // bank can be filtered by generator, but only by someone who already knows
    // to go looking.
    //
    // Two sources because approval crosses two MODELS - a pending row is an
    // `assessments.be.prompt.question`, an approved one is an
    // `assessments.be.question` - and `/api/v1/drafts` defaults to
    // `state='draft'`, so the server stops sending the draft the moment it is
    // decided.
    //
    // KEYED BY ID to survive the window in between: `decideDraft` leaves the
    // record in `drafts` AND appends a copy to `bank` under the same id until
    // the next refresh, which would otherwise show it twice. The bank copy
    // wins, because once a question is in the bank that record is the truth.
    final Map<String, Question> byId = <String, Question>{};
    for (final Question d in store.drafts.where(
      (Question d) => d.genId == g.id,
    )) {
      byId[d.id] = d;
    }
    final Set<String> inBank = <String>{};
    for (final Question q in store.bank.where(
      (Question q) => q.genId == g.id,
    )) {
      byId[q.id] = q;
      inBank.add(q.id);
    }

    // Undecided first: they are the only rows carrying an action.
    final List<Question> all = byId.values.toList()
      ..sort((Question a, Question b) {
        final bool aPend =
            !inBank.contains(a.id) && a.state == DraftState.draft;
        final bool bPend =
            !inBank.contains(b.id) && b.state == DraftState.draft;
        if (aPend != bPend) return aPend ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    final int pend = all
        .where(
          (Question d) => !inBank.contains(d.id) && d.state == DraftState.draft,
        )
        .length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
      child: Stack16(<Widget>[
        Notice(
          tone: Tone.inert,
          strong: pend == 0
              ? '${all.length} question${all.length == 1 ? '' : 's'} '
                    'authored, all decided.'
              : '$pend of ${all.length} still need a decision.',
          text:
              'The review queue works across every generator at once - that '
              'is usually the faster way in.',
          actions: <Widget>[
            Btn.primary(
              'Open Review Queue',
              size: BtnSize.sm,
              onPressed: () => context.nav.review(gen: g.id),
            ),
            // Odoo's "Approve All Drafts". The endpoint and the client method
            // both existed with nothing calling them, so 40 clean drafts had
            // to be approved one at a time.
            Btn(
              'Approve All Drafts',
              tooltip:
                  'Approve every remaining draft into the bank in one pass. '
                  'Each is approved separately, so one bad draft - an image '
                  'whose planted flaw never rendered - cannot roll back the '
                  'good ones. A draft carrying a quality warning is HELD and '
                  'named in the result, not approved: acknowledging a warning '
                  'is a per-question judgement, so those go through the review '
                  'queue one at a time.',
              size: BtnSize.sm,
              busy: store.isBusy('approveall:${g.id}'),
              onPressed: pend == 0 ? null : () => store.approveAllDrafts(g.id),
            ),
          ],
        ),
        DataGrid(
          minWidth: 940,
          emptyMessage:
              'No questions yet. Run a generation on the Generation tab to '
              'produce some.',
          // THE DECISION COLUMN APPEARS ONLY WHEN IT CAN DO SOMETHING. It
          // holds the approve/deny controls, which exist only on a pending
          // row, so on a fully-reviewed generator it was 140px of header over
          // a column of dashes. Conditional rather than deleted: a new
          // generation brings it straight back.
          cols: <Col>[
            const Col('Question', flex: 3),
            const Col('Type', width: 128),
            const Col('Difficulty', width: 96),
            // 120: the Assets cell shows an image and a video chip side by
            // side, which needed 120 and overflowed 104 by 16px.
            const Col('Assets', width: 120),
            const Col('Warnings', width: 82, numeric: true),
            const Col('State', width: 128),
            if (pend > 0) const Col('Decision', width: 140, numeric: true),
          ],
          rows: all.map((Question d) {
            final int warn = d.warnings.length;
            // Being IN THE BANK is the fact, not the draft's own `state`: a
            // question fetched from `/api/v1/bank` carries `state: approved`,
            // but so does a draft that was approved a moment ago and has not
            // been refreshed away yet. Membership answers both.
            final bool approved = inBank.contains(d.id);
            final bool pending = !approved && d.state == DraftState.draft;
            return GridRow(<Widget>[
              GridLink(d.name),
              // THE TASK, not the engine. A template-authored draft reproduces
              // a shape a human named; "Image A/B" is the renderer underneath
              // and says nothing about which task is being approved - and reads
              // as plainly wrong when the task is not an A/B comparison.
              StatusBadge(d.taskLabel, Tone.inert),
              Text(d.difficulty.label, style: context.type.bodySecondary),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // RENDER STATE while it is still a draft, COUNT once it is
                  // in the bank.
                  //
                  // `imageState`/`videoState` are draft fields - they answer
                  // "did the render finish" - and a bank row carries neither,
                  // so every approved question reported "-" for its assets
                  // including the A/B ones holding two pictures each. Once the
                  // render is done and decided, the question worth answering
                  // is no longer "did it work" but "what is attached".
                  if (d.imageState != null)
                    Pill.state(d.imageState!)
                  else if (d.images.isNotEmpty)
                    StatusBadge(
                      '${d.images.length} image'
                      '${d.images.length == 1 ? '' : 's'}',
                      Tone.inert,
                    ),
                  if (d.videoState != null) ...<Widget>[
                    if (d.imageState != null || d.images.isNotEmpty)
                      const SizedBox(width: 4),
                    Pill.state(d.videoState!),
                  ] else if (d.videos.isNotEmpty) ...<Widget>[
                    if (d.imageState != null || d.images.isNotEmpty)
                      const SizedBox(width: 4),
                    StatusBadge(
                      '${d.videos.length} clip'
                      '${d.videos.length == 1 ? '' : 's'}',
                      Tone.inert,
                    ),
                  ],
                  // Nothing at all, rather than a dash. A text question has no
                  // assets and never will; a placeholder implies a value that
                  // is missing, and on a column where most rows are legitimately
                  // empty it prints a wall of punctuation.
                ],
              ),
              warn == 0
                  ? Text('-', style: context.type.bodyMuted)
                  : StatusBadge('$warn', Tone.warn),
              approved
                  ? const Pill('Approved', Tone.ok)
                  : (pending
                        ? const Pill('Pending', Tone.warn)
                        : Pill.state(d.state)),
              // Cell present only while the column is - see `cols` above.
              // A decided row inside a still-pending batch keeps an empty cell
              // rather than a dash: it has no action, and a placeholder in a
              // column of buttons reads as a control that failed to draw.
              if (pend > 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    // No View button: the row opens the draft (onTap below).
                    // Retry sits with the other per-row actions: only on a
                    // failed image, as Retry Clips is only on a failed clip,
                    // and only for a role that may write.
                    if (pending &&
                        d.imageState == AssetState.failed &&
                        store.can(Capability.authoring) &&
                        onRetryImages != null) ...<Widget>[
                      IconBtn(
                        Icons.refresh,
                        tooltip: 'Retry images',
                        onPressed: () => onRetryImages!(d.id),
                      ),
                      const SizedBox(width: 5),
                    ],
                    if (pending) ...<Widget>[
                      IconBtn(
                        Icons.check,
                        tinted: IconTone.yes,
                        tooltip: 'Approve into the bank',
                        // Through the shared decision path, so a fast tick
                        // meets the same acknowledgement gate the keyboard
                        // does.
                        onPressed: () =>
                            _decide(context, d, DraftState.approved),
                      ),
                      const SizedBox(width: 5),
                      IconBtn(
                        Icons.close,
                        tinted: IconTone.no,
                        tooltip: 'Deny',
                        onPressed: () => _decide(context, d, DraftState.denied),
                      ),
                    ],
                  ],
                ),
            ], onTap: () => showQuestionPreview(context, store, d));
          }).toList(),
        ),
        Text(
          'Everything this generator has authored. A pending question is not '
          'in the bank and has reached no candidate; an approved one is in '
          'the bank and can be drawn onto an assessment.',
          style: context.type.small.copyWith(color: t.textMuted),
        ),
      ]),
    );
  }

  void _decide(BuildContext context, Question d, DraftState verdict) {
    final String? refused = store.decideDraft(d.id, verdict);
    // A non-null id means the store REFUSED: the draft carries an
    // unacknowledged blocking warning. Force its preview open so the reviewer
    // sees what they were about to wave through.
    if (refused != null) showQuestionPreview(context, store, d);
  }
}

/// "Upload SOP" - opens the browser file chooser and posts the bytes.
///
/// Stateful for one reason: the button must go disabled while the request is
/// in flight. A SOP is a multi-MB base64 body, so the round trip is long
/// enough to invite a second click, and two clicks would attach the same
/// document twice.
class _UploadBtn extends StatefulWidget {
  final AppStore store;
  final String genId;

  const _UploadBtn({required this.store, required this.genId});

  @override
  State<_UploadBtn> createState() => _UploadBtnState();
}

class _UploadBtnState extends State<_UploadBtn> {
  // Nothing is uploaded to a deleted generator: Deleted is final.
  bool get _deleted => widget.store.genById(widget.genId)?.deleted ?? false;

  bool _busy = false;

  /// SOP ONLY. The three category toggles that used to sit beside this button
  /// duplicated the Sample-questions and Reference sections under Generation.
  Future<void> _pick() async {
    setState(() => _busy = true);
    try {
      final PickedFile? file = await pickFile(
        // The formats the module reads: text is extracted from the document
        // types, while PDF and images go to the model natively.
        accept:
            '.pdf,.docx,.txt,.md,.csv,.html,.json,.xml,'
            '.png,.jpg,.jpeg,.webp,.gif',
      );
      if (file == null) return;
      await widget.store.uploadResource(
        widget.genId,
        name: file.name,
        bytes: file.bytes,
      );
    } finally {
      // `mounted` because the upload outlives a tab switch: setState on a
      // disposed widget throws.
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _deleted
      ? const SizedBox.shrink()
      : Btn.primary(
    _busy ? 'Uploading...' : 'Upload SOP',
    size: BtnSize.sm,
    onPressed: _busy ? null : _pick,
  );
}
