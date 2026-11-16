// Review queue - HANDOVER 4.3 and 6.3. The human approval gate.
//
// Invariant 1: nothing reaches a candidate unreviewed. This screen is where
// that invariant is enforced against a person in a hurry, so two things matter
// more than layout:
//
//   1. EVERY decision goes through `store.decideDraft`. The keyboard, the
//      footer buttons and the queue-list row all call the same method, so a
//      fast keystroke cannot become a way around the acknowledgement gate.
//   2. When `decideDraft` REFUSES an approval it returns the draft id. That is
//      not an error code to swallow - it is the instruction to force the
//      preview sheet open, so the reviewer is shown the warning they were
//      about to skip past.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../widgets/answer_key.dart';
import '../../widgets/buttons.dart';
import '../../widgets/controls.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/feedback.dart';
import '../../widgets/import_sheet.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../../widgets/question_editor.dart';
import '../exam/stimulus.dart';
import '../exam/video_plate.dart';
import 'assessment_detail_screen.dart' show showQuestionPreview;
import '../../theme.dart';
import '../../nav.dart';

class ReviewQueueScreen extends StatefulWidget {
  final AppStore store;
  final String genFilter;
  final String? focusDraftId;

  const ReviewQueueScreen({
    super.key,
    required this.store,
    this.genFilter = '',
    this.focusDraftId,
  });

  @override
  State<ReviewQueueScreen> createState() => _ReviewQueueScreenState();
}

class _ReviewQueueScreenState extends State<ReviewQueueScreen> {
  int _idx = 0;
  late String _gen = widget.genFilter;

  /// The shortcuts live on this node. A text field inside the page takes focus
  /// away from it, which is exactly the guard the source expresses as "not
  /// while an INPUT is focused".
  final FocusNode _keys = FocusNode(debugLabel: 'review-queue-shortcuts');

  @override
  void initState() {
    super.initState();
    // `/admin/review/:draftId` opens on that draft rather than at the top.
    final String? want = widget.focusDraftId;
    if (want != null) {
      final int at = _list().indexWhere((Question d) => d.id == want);
      if (at >= 0) _idx = at;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keys.requestFocus();
      _hydrateCurrent();
    });
  }

  /// Pull the FULL record for the card on screen.
  ///
  /// The list row carries 21 of the 35 fields; the stimulus image, the label
  /// boxes, the options and the rubric are only on the detail route. Without
  /// this the reviewer was asked to approve a labelling question while the
  /// card showed "The stimulus for this question has not rendered" - under a
  /// badge that correctly read "Rendered", because the server had the image
  /// the whole time.
  ///
  /// Fetched per card rather than for the whole queue: the images are inline
  /// base64 data URLs, so hydrating fifty drafts up front would pull megabytes
  /// nobody has scrolled to yet.
  void _hydrateCurrent() {
    final List<Question> list = _list();
    if (list.isEmpty) return;
    final Question d = list[_clamped(list)];
    // Already full. `images` alone was the sentinel, and it is never set on a
    // text-only mcq - so every plain question re-fetched on every keystroke
    // through the queue. Any detail-only field answers the question honestly.
    if (d.images.isNotEmpty ||
        d.answerKey.isNotEmpty ||
        d.officialReasoning.isNotEmpty ||
        d.advanced.isNotEmpty) {
      return;
    }
    widget.store.loadDraft(d.id);
  }

  @override
  void dispose() {
    _keys.dispose();
    super.dispose();
  }

  List<Question> _list() => _gen.isEmpty
      ? widget.store.pendingDrafts()
      : widget.store.pendingDrafts(_gen);

  /// The index, clamped against a list that shrinks under it every time a
  /// decision lands.
  int _clamped(List<Question> list) =>
      list.isEmpty ? 0 : _idx.clamp(0, list.length - 1);

  void _move(int step) {
    final List<Question> list = _list();
    if (list.isEmpty) return;
    setState(() => _idx = (_clamped(list) + step).clamp(0, list.length - 1));
    _hydrateCurrent();
  }

  /// THE one decision path. Everything - keyboard, footer, row - comes here.
  void _decide(Question? d, DraftState verdict) {
    if (d == null) return;
    final String? refused = widget.store.decideDraft(d.id, verdict);
    if (refused != null) {
      // Refused: an unacknowledged blocking warning. Show the reviewer what
      // they were about to approve rather than merely toasting at them.
      showQuestionPreview(context, widget.store, d);
      return;
    }
    setState(() {
      final int len = _list().length;
      _idx = len == 0 ? 0 : _idx.clamp(0, len - 1);
      // A decision removes the card and slides the next one under the
      // cursor: that new card needs its own detail fetch.
      WidgetsBinding.instance.addPostFrameCallback((_) => _hydrateCurrent());
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final List<Question> list = _list();
    final Question? cur = list.isEmpty ? null : list[_clamped(list)];

    switch (e.logicalKey) {
      case LogicalKeyboardKey.keyJ:
        _move(1);
      case LogicalKeyboardKey.keyK:
        _move(-1);
      case LogicalKeyboardKey.keyA:
        // Same gate as the mouse path, by construction.
        _decide(cur, DraftState.approved);
      case LogicalKeyboardKey.keyD:
        _decide(cur, DraftState.denied);
      case LogicalKeyboardKey.keyU:
        widget.store.undoDecision();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final AppStore s = widget.store;
    final AppTokens t = context.tokens;
    // The generator filter, live: it outranks the one the route opened with
    // (`/review?gen=<id>`), and empty means every generator.
    context.setNavQuery(<String, Object?>{'gen': _gen});

    return Focus(
      focusNode: _keys,
      autofocus: true,
      onKeyEvent: _onKey,
      child: ListenableBuilder(
        listenable: s,
        builder: (BuildContext context, _) {
          final List<Question> all = s.pendingDrafts();
          final List<Question> list = _list();
          final int idx = _clamped(list);
          final Question? cur = list.isEmpty ? null : list[idx];
          final int decided = s.drafts
              .where((Question d) => d.state != DraftState.draft)
              .length;
          final int blockedByAssets = all
              .where(
                (Question d) => d.blockingWarnings.any(
                  (QualityWarning w) => w.title.contains('Image'),
                ),
              )
              .length;
          final int flagged = all
              .where((Question d) => d.warnings.isNotEmpty)
              .length;

          return PageBody(
            children: <Widget>[
              // No breadcrumb here: this IS a root destination, and the shell
              // already prints "Admin / <page>" in its top bar. Repeating it
              // put the same words on screen three times in 100px.
              PageHead(
                'Review Queue',
                sub:
                    'Every generated question is a draft until a human '
                    'approves it. Nothing here has reached a candidate.',
                actions: <Widget>[
                  Btn(
                    'Import CSV / JSON',
                    tooltip:
                        'Load questions from a file. CSV and harness JSON arrive '
                        'here as drafts for review; a native bank export restores '
                        'straight into the bank.',
                    onPressed: () => showImportSheet(
                      context,
                      s,
                      entity: ImportEntity.questions,
                    ),
                  ),
                  // Only offered when there is something to reverse.
                  if (s.lastDecision != null)
                    Btn('Undo', keyHint: 'U', onPressed: s.undoDecision),
                ],
              ),
              KpiStrip(<Widget>[
                Kpi(
                  label: 'Awaiting review',
                  value: '${all.length}',
                  sub: 'across every generator',
                  // No drafts at all is not "all reviewed", it is
                  // "nothing has been generated yet".
                  valueColor: all.isEmpty ? null : t.warnText,
                ),
                Kpi(
                  label: 'Decided',
                  value: '$decided',
                  sub: 'approved or denied',
                ),
                Kpi(
                  label: 'Waiting for images',
                  value: '$blockedByAssets',
                  sub: 'cannot judge yet',
                  valueColor: blockedByAssets > 0 ? t.infoText : null,
                ),
                Kpi(
                  label: 'Needs a closer look',
                  value: '$flagged',
                  sub: 'tick the warning first',
                  valueColor: flagged > 0 ? t.warnText : null,
                ),
              ]),
              _FilterRow(
                store: s,
                active: _gen,
                total: all.length,
                // The filter is local state, not a destination: changing it
                // must not push a page the user then has to come back from.
                onChanged: (String g) => setState(() {
                  _gen = g;
                  _idx = 0;
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _hydrateCurrent(),
                  );
                }),
              ),
              const SizedBox(height: 14),
              if (list.isEmpty)
                Panel(
                  // Two DIFFERENT empty states, because they mean opposite
                  // things. A cleared queue is an achievement and gets a tick;
                  // a queue that never had anything in it is step 2 of the
                  // flow not having run, and its way out is the generator.
                  child: all.isEmpty
                      ? EmptyState(
                          icon: Icons.auto_awesome_outlined,
                          title: 'No drafts to review',
                          body:
                              'Drafts arrive here after a generator runs '
                              'against its SOP. Nothing has been generated '
                              'yet.',
                          compact: false,
                          action: Btn(
                            'Go to Generators',
                            size: BtnSize.sm,
                            onPressed: () =>
                                context.nav.go(const GeneratorList()),
                          ),
                        )
                      : const EmptyState(
                          icon: Icons.task_alt,
                          tone: Tone.ok,
                          title: 'Queue is clear',
                          body:
                              'Every draft from this generator has been '
                              'decided. Pick another generator above, or '
                              'generate more.',
                          compact: false,
                        ),
                )
              else
                Cols2(
                  left: _DraftCard(
                    store: s,
                    draft: cur!,
                    idx: idx,
                    total: list.length,
                    onDecide: (DraftState v) => _decide(cur, v),
                    onSkip: () => _move(1),
                  ),
                  right: _QueueList(
                    list: list,
                    store: widget.store,
                    active: idx,
                    onPick: (int i) {
                      setState(() => _idx = i);
                      _hydrateCurrent();
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The per-generator filter, plus the keyboard legend.
class _FilterRow extends StatelessWidget {
  final AppStore store;
  final String active;
  final int total;
  final ValueChanged<String> onChanged;

  const _FilterRow({
    required this.store,
    required this.active,
    required this.total,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 7,
            runSpacing: 7,
            children: <Widget>[
              const Eyebrow('Generator'),
              Btn(
                'All  $total',
                size: BtnSize.sm,
                pressed: active.isEmpty,
                onPressed: () => onChanged(''),
              ),
              // Only generators with something pending are offered, so the
              // filter row never leads to an empty result.
              // `liveGenerators()` - an archived generator's leftover drafts
              // are not a queue anybody is working.
              for (final Generator g in store.liveGenerators())
                if (store.pendingDrafts(g.id).isNotEmpty)
                  Btn(
                    '${g.name}  ${store.pendingDrafts(g.id).length}',
                    size: BtnSize.sm,
                    pressed: active == g.id,
                    onPressed: () => onChanged(g.id),
                  ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Text(
          'Keys: J/K move  \u00b7  A approve  \u00b7  D deny  \u00b7  U undo',
          style: context.type.monoSmall.copyWith(color: t.textMuted),
        ),
      ],
    );
  }
}

/// The SOP a draft came from, in the most durable spelling available.
///
/// `genName` is what the API sends on the row itself and needs nothing loaded.
/// The store lookup is the fallback for a payload that carried only an id.
/// `sourceRef` is stamped at approval time and is the ONLY attribution that
/// survives the generator being deleted, since `generator_id` is
/// ondelete="set null".
///
/// Empty when none of the three is known - a raw database id is worse than
/// saying nothing, because it reads as a name.
String _attribution(Question draft, Generator? g) {
  if (draft.genName.isNotEmpty) return draft.genName;
  if (g != null && g.name.isNotEmpty) return g.name;
  return draft.sourceRef;
}

/// The decision surface: prompt, stimulus, answer key, warnings, and the
/// acknowledgement checkbox that gates approval.
class _DraftCard extends StatelessWidget {
  final AppStore store;
  final Question draft;
  final int idx;
  final int total;
  final ValueChanged<DraftState> onDecide;
  final VoidCallback onSkip;

  const _DraftCard({
    required this.store,
    required this.draft,
    required this.idx,
    required this.total,
    required this.onDecide,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final List<QualityWarning> warnings = draft.warnings;
    final List<QualityWarning> blocking = draft.blockingWarnings;
    final bool acked = store.acknowledged.contains(draft.id);
    final bool canApprove = blocking.isEmpty || acked;
    final Generator? g = store.genById(draft.genId);

    return Panel(
      title: draft.name,
      headActions: <Widget>[
        StatusBadge(draft.taskLabel, Tone.inert),
        const SizedBox(width: 5),
        StatusBadge(draft.difficulty.label, Tone.inert),
        // WHICH SOP THIS CAME FROM. The card carried an "Open generator"
        // button and never said which generator it would open, so a reviewer
        // working a mixed queue judged an answer key with no idea which
        // document justified it. Read off the draft rather than resolved
        // through the store, so it is right even before the generators load
        // and stays right if that generator is later deleted.
        const SizedBox(width: 9),
        Btn(
          'Preview as Candidate',
          tooltip:
              'See the question exactly as a candidate will, answer area '
              'and all. This is when a clumsy option or a wrong '
              'correct-flag becomes obvious.',
          size: BtnSize.sm,
          onPressed: () => showQuestionPreview(context, store, draft),
        ),
        if (g != null) ...<Widget>[
          const SizedBox(width: 5),
          Btn(
            'Open Generator',
            size: BtnSize.sm,
            onPressed: () => context.nav.generator(g.id, tab: 'drafts'),
          ),
        ],
        // Recovery actions, offered ONLY when they apply. A reviewer meets a
        // broken draft here, so the fix belongs here rather than three screens
        // away - but a retry that would re-spend on Veo for an identical
        // result is worse than no button, so both are conditional.
        if (draft.videoState == AssetState.failed ||
            draft.videoState == AssetState.partial) ...<Widget>[
          const SizedBox(width: 5),
          Btn(
            'Retry Clips',
            tooltip:
                'Generate the missing video again. Veo runs asynchronously, '
                'so the clip lands minutes later rather than on this click.',
            size: BtnSize.sm,
            onPressed: () => store.retryVideo(draft.id),
          ),
        ],
        if (!draft.answerKeyValid) ...<Widget>[
          const SizedBox(width: 5),
          Btn(
            'Rebuild Answer Key',
            tooltip:
                'Ask the model to derive the correct options again from the '
                'question and the SOP. Costs an LLM call. For a draft whose '
                'key is missing or marks nothing correct - which the sixth '
                'launch gate would refuse.',
            size: BtnSize.sm,
            onPressed: () => store.rebuildAnswerKey(draft.id),
          ),
        ],
        // THE MISSING HALF OF HUMAN-IN-THE-LOOP REVIEW. Odoo's draft form is
        // editable down to the correct-answer toggle, so a reviewer fixes a
        // generated question and approves it. Here the only choices were
        // approve-as-generated or deny, which threw away a paid model call
        // over a typo.
        //
        // A pencil, matching the preview sheet: this row already carries four
        // word-labelled buttons competing for attention.
        const SizedBox(width: 5),
        IconBtn(
          Icons.edit_outlined,
          tooltip: 'Edit this draft',
          // An icon button has no busy spinner, so the in-flight state becomes
          // a disable instead - which is the half that mattered anyway: it is
          // what stops a second editor opening over a save already running.
          onPressed: store.isLive && !store.isBusy('draft:${draft.id}')
              ? () => showDraftEditor(context, store, draft)
              : null,
        ),
      ],
      footer: Row(
        children: <Widget>[
          Btn.danger(
            'Deny',
            tooltip:
                'Reject this draft so it is never offered again. The '
                'generator keeps its record of having produced it.',
            keyHint: 'D',
            onPressed: () => onDecide(DraftState.denied),
          ),
          const Spacer(),
          if (!canApprove)
            Padding(
              padding: const EdgeInsets.only(right: 9),
              child: Text(
                'Tick the warning to approve',
                style: context.type.small.copyWith(color: t.textMuted),
              ),
            ),
          Btn('Skip', keyHint: 'J', onPressed: onSkip),
          const SizedBox(width: 8),
          Btn.primary(
            'Approve into Bank',
            tooltip:
                'Move this draft into the bank, where an assessment can draw '
                'it. Nothing reaches a candidate before this - it is the one '
                'human gate in the pipeline. Refused by the server if the '
                'answer key or required media is missing.',
            keyHint: 'A',
            // Disabled here AND refused in the store: the button is the
            // courtesy, the store is the guarantee.
            onPressed: canApprove ? () => onDecide(DraftState.approved) : null,
          ),
        ],
      ),
      child: Stack16(<Widget>[
        Row(
          children: <Widget>[
            Mono(
              '${(idx + 1).toString().padLeft(2, '0')} / $total',
              size: 11,
              color: t.textMuted,
            ),
            // WHICH SOP THIS DRAFT CAME FROM. Both ordinary ways into this
            // screen - the sidebar and the bank's "Go to review queue" -
            // arrive unfiltered, so the usual queue is mixed across generators
            // and without this a reviewer approves a question into the bank
            // with nothing on the card saying which document justified it.
            //
            // IN THE BODY, not in `headActions`: that row overflowed by 109px,
            // and capping the text to 26 characters produced the same 109px.
            if (_attribution(draft, g).isNotEmpty) ...<Widget>[
              const SizedBox(width: 10),
              // Flexible + ellipsis so a long SOP name shrinks rather than
              // overflowing. There is room here, but the head row showed the
              // failure mode is a test-breaking assertion rather than a
              // cosmetic one, so it is bounded by construction.
              Flexible(
                child: Text(
                  _attribution(draft, g),
                  style: context.type.small.copyWith(color: t.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            // Medium and time budget, for the same reason and in the same place
            // as the attribution: both are on the wire, both are on the Odoo
            // form, and `headActions` has no width left to put them in.
            if (draft.medium.isNotEmpty || draft.timeMinutes > 0) ...<Widget>[
              const SizedBox(width: 10),
              Text(
                <String>[
                  if (draft.medium.isNotEmpty) draft.mediumLabel,
                  if (draft.timeMinutes > 0) '${draft.timeMinutes} min',
                ].join('  ·  '),
                style: context.type.small.copyWith(color: t.textMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Eyebrow('Question, as the candidate sees it'),
            const SizedBox(height: 6),
            Text(
              draft.prompt,
              style: context.type.body.copyWith(
                fontSize: 14.5,
                fontWeight: FontWeight.w500,
                height: 1.55,
              ),
            ),
            if (draft.desc.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Text(draft.desc, style: context.type.bodySecondary),
            ],
          ],
        ),
        if (draft.images.isNotEmpty ||
            draft.videos.isNotEmpty ||
            draft.imageState != null ||
            draft.videoState != null)
          _StimulusBlock(store: store, draft: draft),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Eyebrow('Answer Key'),
            const SizedBox(height: 7),
            AnswerKeyView(store: store, question: draft),
            // THE GENERATOR'S OWN ARGUMENT FOR THAT KEY, which is what the
            // grader will mark a candidate's justification against. Directly
            // under the key rather than folded beneath it: on an image_ab
            // draft this text IS the standard the written justification is
            // marked against, so folding it hid a quarter of what is approved.
            if (draft.officialReasoning.isNotEmpty) ...<Widget>[
              const SizedBox(height: 11),
              const Eyebrow('Answer rationale (hidden from candidate)'),
              const SizedBox(height: 4),
              Text(
                draft.officialReasoning,
                style: context.type.bodySecondary.copyWith(height: 1.6),
              ),
            ],
          ],
        ),
        if (warnings.isEmpty)
          const Notice(
            tone: Tone.ok,
            strong: 'No warnings.',
            text:
                'The question stands on its own, the options give nothing '
                'away, and the key looks clean.',
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Align(
                alignment: Alignment.centerLeft,
                child: Eyebrow('Quality warnings'),
              ),
              const SizedBox(height: 7),
              for (final QualityWarning w in warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Notice(
                    tone: w.blocking ? Tone.bad : Tone.warn,
                    strong: '${w.title}.',
                    text: w.detail,
                  ),
                ),
              if (blocking.isNotEmpty) ...<Widget>[
                const SizedBox(height: 3),
                AckBox(
                  checked: acked,
                  count: blocking.length,
                  onToggle: () => store.toggleAck(draft.id),
                ),
              ],
            ],
          ),
      ]),
    );
  }
}

/// The stimulus block. A failed render is stated in words, because a candidate
/// would see an empty plate and a reviewer must know that before approving.
class _StimulusBlock extends StatelessWidget {
  final AppStore store;
  final Question draft;

  const _StimulusBlock({required this.store, required this.draft});

  @override
  Widget build(BuildContext context) {
    final bool failed = draft.imageState == AssetState.failed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Eyebrow('Image'),
            const SizedBox(width: 9),
            if (draft.imageState != null) Pill.state(draft.imageState!),
            if (draft.videoState != null) ...<Widget>[
              const SizedBox(width: 5),
              Pill.state(draft.videoState!),
            ],
          ],
        ),
        const SizedBox(height: 7),
        if (failed)
          Notice(
            tone: Tone.bad,
            strong: 'No image to judge.',
            text:
                '${draft.imageError ?? 'The image was never created.'} Approving '
                'now would send a candidate a question whose image never '
                'sees.',
            // Regenerating re-spends and may return something no better;
            // supplying the picture directly is the reliable way out. The
            // upload itself lives in the editor, so this is the pointer to it.
            actions: <Widget>[
              // The render again, for a failure that was the renderer's rather
              // than the prompt's. Slots already drawn are kept, not re-paid.
              if (store.can(Capability.authoring))
                Btn(
                  'Retry Images',
                  tooltip:
                      'Send this draft back to the image queue. The next '
                      'image batch renders it; images already made are kept.',
                  size: BtnSize.sm,
                  onPressed: () => store.retryDraftImages(draft.id),
                ),
              Btn.primary(
                'Edit to Supply an Image',
                tooltip:
                    'This draft needs a picture before it can be approved - its '
                    'type is answered against a stimulus that does not exist '
                    'yet.',
                size: BtnSize.sm,
                onPressed: store.isLive
                    ? () => showDraftEditor(context, store, draft)
                    : null,
              ),
            ],
          )
        else if (draft.imageState == AssetState.rendering)
          const JobCard(
            name: 'Creating the image',
            state: JobState.running,
            meta: '~40s',
            progress: 55,
          )
        else if (draft.images.isEmpty && draft.videos.isEmpty)
          const MissingStimulus()
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final (int i, Asset a) in draft.images.indexed)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: StimulusPlate(
                      asset: a,
                      caption: draft.isSideFreeAb
                          ? sideFreeCaption(a.label, i)
                          : a.label,
                      showRegions: draft.type == QType.imageLabel,
                    ),
                  ),
                ),
              for (final Asset v in draft.videos)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: clipPlateFor(v),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// The scrolling queue. Each row carries its warning badges, so the reviewer
/// can see what is coming rather than being surprised by it one at a time.
class _QueueList extends StatelessWidget {
  final List<Question> list;
  final int active;
  final ValueChanged<int> onPick;

  /// Only for resolving a generator NAME from an id - see [_attribution]. With
  /// the filter on All this list mixes every generator together, so a row that
  /// does not name its SOP cannot be placed without clicking it.
  final AppStore store;

  const _QueueList({
    required this.list,
    required this.active,
    required this.onPick,
    required this.store,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Panel(
      title: 'Queue',
      headActions: <Widget>[TagChip('${active + 1} of ${list.length}')],
      flush: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 620),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: list.length,
          itemBuilder: (BuildContext context, int i) {
            final Question d = list[i];
            final bool on = i == active;
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => onPick(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: on ? t.primarySubtle : t.bgApp,
                    border: Border(bottom: BorderSide(color: t.borderSubtle)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Mono(
                          (i + 1).toString().padLeft(2, '0'),
                          size: 10.5,
                          color: on ? t.primary : t.textMuted,
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              d.name,
                              style: context.type.body.copyWith(
                                fontWeight: FontWeight.w600,
                                color: on ? t.primary : t.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(d.taskLabelLong, style: context.type.tiny),
                            // THE SOP THIS CAME FROM. The chips above filter
                            // the queue, they do not label it - on All, 23
                            // drafts from five generators sit in one list with
                            // nothing distinguishing them.
                            //
                            // Its own line rather than appended to the type:
                            // this panel is ~370px and the joined string would
                            // ellipsise away the half worth reading.
                            if (_attribution(
                              d,
                              store.genById(d.genId),
                            ).isNotEmpty) ...<Widget>[
                              const SizedBox(height: 2),
                              Text(
                                _attribution(d, store.genById(d.genId)),
                                style: context.type.tiny.copyWith(
                                  color: on ? t.primary : t.textMuted,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            if (d.warnings.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 5),
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: <Widget>[
                                  for (final QualityWarning w in d.warnings)
                                    StatusBadge(
                                      w.title,
                                      w.blocking ? Tone.bad : Tone.warn,
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
