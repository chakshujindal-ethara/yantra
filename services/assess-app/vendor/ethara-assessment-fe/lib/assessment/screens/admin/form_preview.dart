// The respondent view of a form, rendered from the designer's own object.
//
// This is a PREVIEW: answers live in this widget and die with it. It still
// behaves exactly like the live form will - required gating and section paging,
// straight through in order - because the point of a preview is to try the form,
// not to look at a picture of it. There are no jumps: a form is linear, on both
// sides (see `FormOption`).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../domain/form_models.dart';
import '../../domain/models.dart' show Asset, LabelRegion;
import '../../domain/transcription.dart';
import '../../theme.dart';
import '../../widgets/buttons.dart';
import '../../widgets/controls.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../exam/stimulus.dart'
    show
        RegionOverlayImage,
        stimulusImage,
        stimulusImageProvider,
        stimulusMediaUrl;
import '../exam/audio_plate.dart';
import '../exam/clip_answers_form.dart';
import '../exam/clip_controls.dart';
import '../exam/transcription_box.dart';
import '../exam/video_plate.dart';
import 'zoomable_image.dart';

class FormPreview extends StatefulWidget {
  final FormDef form;

  /// Show the authored answer keys under each question. TRUE only on the
  /// examiner's preview; the future respondent runner renders this same
  /// widget with keys off - and the server must strip them anyway.
  final bool showKeys;

  const FormPreview({super.key, required this.form, this.showKeys = false});

  @override
  State<FormPreview> createState() => _FormPreviewState();
}

class _FormPreviewState extends State<FormPreview> {
  /// item id → answer. Shapes per kind: String (text, option id),
  /// Set&lt;String&gt; (checkboxes), int (scale, rating), Map&lt;int, String&gt; /
  /// Map&lt;int, Set&lt;String&gt;&gt; (grids).
  final Map<String, Object?> _answers = <String, Object?>{};

  /// −3 s / +3 s / Speed for each Transcription clip in the preview.
  final Map<String, ClipControls> _clipControls = <String, ClipControls>{};

  @override
  void dispose() {
    for (final ClipControls c in _clipControls.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Annotation items: the annotation number the single answer area is
  /// currently showing, per item. Tapping a chip or a plate marker moves it.
  final Map<String, int> _annSel = <String, int>{};

  /// Sections visited, as indexes. Kept as a stack because Back pops it; with
  /// branching gone the path is always 0..n in order.
  final List<int> _trail = <int>[0];

  /// Per-section display order of item indexes for THIS sitting.
  ///
  /// When [FormDef.shuffleQuestions] is on, each candidate sees a section's
  /// items in a random order that is FIXED for the life of their sitting -
  /// picked once in [_shuffleForSitting], not re-rolled on every rebuild (the
  /// old rebuild-reorders bug made a form impossible to read). When the flag
  /// is off this is identity order. Keyed by section id so adding/deleting a
  /// section in the designer does not misalign another section's order.
  final Map<String, List<int>> _order = <String, List<int>>{};

  /// Item id → the 1-based number the candidate sees. Counts in DISPLAY order
  /// across the whole form, so with shuffle on "Question 3" is their third
  /// question, not the third authored one. Content blocks (non-questions)
  /// take no number.
  final Map<String, int> _displayNo = <String, int>{};

  @override
  void initState() {
    super.initState();
    _shuffleForSitting();
    _seedFromKeys();
  }

  /// Pick this sitting's per-section item order and assign display numbers.
  ///
  /// Called once per sitting (open / "Fill in Again"), NOT per build, so the
  /// order a candidate sees holds still while they work. With shuffle off the
  /// order is identity, so numbering matches the authored sequence exactly.
  ///
  /// The number counts questions in DISPLAY order across the whole form: a
  /// content block consumes no number, and the per-section shuffle feeds
  /// straight into the running count, so what the candidate reads as
  /// "Question N" is genuinely their Nth question.
  void _shuffleForSitting() {
    _order.clear();
    _displayNo.clear();
    // A fresh RNG each sitting: two candidates (or two "Fill in Again" runs)
    // get independent orders, which is the whole point of a per-candidate
    // shuffle.
    final math.Random rng = math.Random();
    int running = 0;
    for (final FormSection s in _f.sections) {
      final List<int> idx = <int>[for (int i = 0; i < s.items.length; i++) i];
      if (_f.shuffleQuestions) idx.shuffle(rng);
      _order[s.id] = idx;
      for (final int i in idx) {
        final FormItem it = s.items[i];
        if (it.isAnswerable) _displayNo[it.id] = ++running;
      }
    }
  }

  /// The items of [sec] in this sitting's display order.
  List<FormItem> _orderedItems(FormSection sec) {
    final List<int>? order = _order[sec.id];
    if (order == null || order.length != sec.items.length) {
      // Order not computed yet, or the designer changed the item count since;
      // fall back to authored order rather than risk an out-of-range index.
      return sec.items;
    }
    return <FormItem>[for (final int i in order) sec.items[i]];
  }

  /// THE ANSWER-KEY-SEEDING REGISTRY. One entry per kind that HAS a key to
  /// seed from; a kind with none (textBlock, the media blocks) simply has no
  /// entry and is left blank, same as the old switch's
  /// `default: break`. Each entry writes straight into `_answers`, exactly
  /// as the switch cases did - no behaviour changed, only how a kind's case
  /// is found.
  late final Map<String, void Function(FormItem)> _seedRegistry =
      <String, void Function(FormItem)>{
        for (final FormItemKind k in <FormItemKind>[
          FormItemKind.multipleChoice,
          FormItemKind.dropdown,
          FormItemKind.comparePair,
        ])
          k.name: (FormItem it) {
            final FormOption? o = it.options
                .where((FormOption o) => o.correct)
                .firstOrNull;
            if (o != null) _answers[it.id] = o.id;
          },
        FormItemKind.checkboxes.name: (FormItem it) {
          final Set<String> ids = it.options
              .where((FormOption o) => o.correct)
              .map((FormOption o) => o.id)
              .toSet();
          if (ids.isNotEmpty) _answers[it.id] = ids;
        },
        // A radio grid holds ONE label per row, so the preview answer is that
        // label. The key is a set either way, so take its single member.
        FormItemKind.choiceGrid.name: (FormItem it) {
          if (it.gridKey.isNotEmpty) {
            _answers[it.id] = <int, Object?>{
              for (final MapEntry<int, Set<String>> e in it.gridKey.entries)
                if (e.value.isNotEmpty) e.key: e.value.first,
            };
          }
        },
        // A checkbox grid ticks EVERY keyed column on the row. This used to
        // wrap one label in a one-element set; spreading the real set is what
        // makes the examiner's preview show the perfect submission for a row
        // with several right answers.
        FormItemKind.checkboxGrid.name: (FormItem it) {
          if (it.gridKey.isNotEmpty) {
            _answers[it.id] = <int, Object?>{
              for (final MapEntry<int, Set<String>> e in it.gridKey.entries)
                e.key: <String>{...e.value},
            };
          }
        },
        for (final FormItemKind k in <FormItemKind>[
          FormItemKind.shortAnswer,
          FormItemKind.paragraph,
          // Prompt writing's key is the model PROMPT, stored in the same
          // field, so the examiner's preview opens with it already typed -
          // the same "perfect submission" every other keyed kind gets.
          FormItemKind.promptWriting,
        ])
          k.name: (FormItem it) {
            if (it.goldenAnswer.trim().isNotEmpty) {
              _answers[it.id] = it.goldenAnswer;
            }
          },
        FormItemKind.transcription.name: (FormItem it) {
          _answers[it.id] = _TxAnswer(it.goldenAnswer, it.goldenClip.copy());
        },
        FormItemKind.imageAnnotation.name: (FormItem it) {
          if (it.goldenLabels.isNotEmpty) {
            _answers[it.id] = Map<int, String>.of(it.goldenLabels);
          }
        },
        FormItemKind.linearScale.name: (FormItem it) {
          if (it.scaleGolden != null) {
            _answers[it.id] = it.scaleGolden!.clamp(it.scaleMin, it.scaleMax);
          }
        },
        FormItemKind.rating.name: (FormItem it) {
          if (it.ratingGolden != null) {
            _answers[it.id] = it.ratingGolden!.clamp(1, it.ratingMax);
          }
        },
      };

  /// Examiner preview only: pre-fill every answer from the authored key, so
  /// the preview opens as the PERFECT submission - correct options selected,
  /// golden text in the fields, every marker described. Verifying the key is
  /// then reading the form top to bottom. Items without a key stay blank.
  void _seedFromKeys() {
    if (!widget.showKeys) return;
    for (final FormSection s in _f.sections) {
      for (final FormItem it in s.items) {
        _seedRegistry[it.kind.name]?.call(it);
      }
    }
  }

  bool _done = false;
  bool _showErrors = false;

  /// Testing affordance: page through every task without answering.
  ///
  /// TEMPORARILY ON BY DEFAULT while the team reviews form content - flip
  /// back to `false` when enforcement should again match the live form.
  /// The notice bar states loudly which mode the preview is in either way.
  bool _skipRequired = true;

  FormDef get _f => widget.form;

  int get _cur {
    // The designer can delete sections while the preview holds a trail into
    // them; clamp rather than crash.
    while (_trail.length > 1 && _trail.last >= _f.sections.length) {
      _trail.removeLast();
    }
    if (_trail.last >= _f.sections.length) _trail[0] = 0;
    return _trail.last;
  }

  void _restart() => setState(() {
    _answers.clear();
    _shuffleForSitting();
    _seedFromKeys();
    _trail
      ..clear()
      ..add(0);
    _done = false;
    _showErrors = false;
  });

  // ── Answer state ─────────────────────────────────────────────────────────

  /// THE ANSWERED-CHECK REGISTRY. One entry per kind whose "is this filled
  /// in" test is not simply "yes" - a kind with no entry (date/time already
  /// covered below by string-shape kinds; textBlock/comparePair-with-no-
  /// options/etc that never reach this at all) falls through to `true`,
  /// exactly as the switch's `_ => true` did: a content block is never
  /// "missing" because it never collects an answer.
  late final Map<String, bool Function(FormItem, Object?)> _answeredRegistry =
      <String, bool Function(FormItem, Object?)>{
        for (final FormItemKind k in <FormItemKind>[
          FormItemKind.shortAnswer,
          FormItemKind.paragraph,
          FormItemKind.multipleChoice,
          FormItemKind.dropdown,
        ])
          k.name: (FormItem it, Object? v) =>
              v is String && v.trim().isNotEmpty,
        FormItemKind.checkboxes.name: (FormItem it, Object? v) =>
            v is Set && v.isNotEmpty,
        for (final FormItemKind k in <FormItemKind>[
          FormItemKind.linearScale,
          FormItemKind.rating,
        ])
          k.name: (FormItem it, Object? v) => v is int,
        FormItemKind.choiceGrid.name: (FormItem it, Object? v) =>
            v is Map && it.rows.asMap().keys.every(v.containsKey),
        FormItemKind.checkboxGrid.name: (FormItem it, Object? v) =>
            v is Map &&
            it.rows.asMap().keys.every(
              (int r) => v[r] is Set && (v[r] as Set).isNotEmpty,
            ),
        FormItemKind.comparePair.name: (FormItem it, Object? v) =>
            it.options.isEmpty || (v is String && v.isNotEmpty),
        // Required means EVERY annotation is described, the same all-rows
        // rule the grids use - a half-labelled plate is not an answer.
        FormItemKind.imageAnnotation.name: (FormItem it, Object? v) =>
            it.annotationNumbers.isEmpty ||
            (v is Map &&
                it.annotationNumbers.every(
                  (int n) => (v[n] as String?)?.trim().isNotEmpty ?? false,
                )),
        // The WRITTEN PROMPT is the answer. Optional rating axes ride along
        // and are deliberately not required with it: the server treats them
        // as optional too, and failing a candidate for skipping an axis the
        // examiner marked optional would be this app inventing a rule.
        FormItemKind.promptWriting.name: (FormItem it, Object? v) =>
            v is String && v.trim().isNotEmpty,
        // A category other than None is a complete answer with an empty box:
        // such a clip is not transcribed.
        FormItemKind.transcription.name: (FormItem it, Object? v) =>
            v is _TxAnswer && (!v.clip.transcribed || v.text.trim().isNotEmpty),
      };

  bool _answered(FormItem it) {
    final Object? v = _answers[it.id];
    return _answeredRegistry[it.kind.name]?.call(it, v) ?? true;
  }

  List<FormItem> _missing(FormSection sec) => _skipRequired
      ? <FormItem>[]
      : sec.items
            .where(
              (FormItem i) => i.isAnswerable && i.required && !_answered(i),
            )
            .toList();

  /// A FORM IS LINEAR: section N is followed by section N+1, and the last one
  /// ends it. Nothing an answer says can change that.
  ///
  /// This used to resolve a jump target - a section's own `goTo`, overridden by
  /// the last answered single-choice option carrying one. Both carriers are gone
  /// (see [FormSection] and [FormOption]): no branching reached the candidate,
  /// because the exam runner paginates one QUESTION at a time and decides the
  /// last page by counting, so the routing only ever steered THIS preview. It
  /// also produced the reported defect - a section left on "Submit form" ended
  /// the preview mid-form, which reads as the form being broken.
  bool _targetIsSubmit(FormSection sec, int index) =>
      index == _f.sections.length - 1;

  void _next() {
    final FormSection sec = _f.sections[_cur];
    if (_missing(sec).isNotEmpty) {
      setState(() => _showErrors = true);
      return;
    }
    setState(() {
      _showErrors = false;
      final int to = _cur + 1;
      if (to >= _f.sections.length) {
        _done = true;
      } else {
        _trail.add(to);
      }
    });
  }

  void _back() => setState(() {
    _showErrors = false;
    if (_trail.length > 1) _trail.removeLast();
  });

  // ── Rendering ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;

    if (_f.sections.isEmpty) {
      return const Notice(
        tone: Tone.inert,
        text: 'Nothing to preview - the form has no sections.',
      );
    }

    if (_done) {
      return Panel(
        child: Column(
          children: <Widget>[
            Icon(Icons.check_circle_outline, size: 34, color: t.successText),
            const SizedBox(height: 10),
            Text('Response recorded', style: context.type.panelTitle),
            const SizedBox(height: 4),
            Text(
              'Preview only - nothing was saved.',
              style: context.type.small.copyWith(color: t.textMuted),
            ),
            const SizedBox(height: 14),
            Btn('Fill in Again', onPressed: _restart),
          ],
        ),
      );
    }

    final int index = _cur;
    final FormSection sec = _f.sections[index];
    final List<FormItem> missing = _showErrors ? _missing(sec) : <FormItem>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Notice(
          tone: _skipRequired ? Tone.warn : Tone.inert,
          strong: 'Respondent view.',
          text:
              (_skipRequired
                  ? 'Required answers are NOT being enforced - testing only.'
                  : 'Answers here are not saved anywhere.') +
              (widget.showKeys
                  ? ' Pre-filled from the golden answer key where present - '
                        'respondents start blank.'
                  : ''),
          actions: <Widget>[
            Btn(
              _skipRequired ? 'Enforce required' : 'Skip required (testing)',
              size: BtnSize.sm,
              onPressed: () => setState(() {
                _skipRequired = !_skipRequired;
                _showErrors = false;
              }),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _formHeader(t),
        if (sec.title.isNotEmpty || sec.description.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          _sectionHeader(sec, index, t),
        ],
        for (final FormItem it in _orderedItems(sec)) ...<Widget>[
          const SizedBox(height: 16),
          _itemCard(it, invalid: missing.contains(it)),
        ],
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            if (_trail.length > 1) Btn('Back', onPressed: _back),
            const Spacer(),
            if (_f.sections.length > 1)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(
                    'Section ${index + 1} of ${_f.sections.length}',
                    style: context.type.small.copyWith(color: t.textMuted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            Btn.primary(
              _targetIsSubmit(sec, index) ? 'Submit' : 'Next',
              onPressed: _next,
            ),
          ],
        ),
      ],
    );
  }

  Widget _formHeader(AppTokens t) => Container(
    decoration: BoxDecoration(
      color: t.bgApp,
      borderRadius: Radii.panel,
      border: Border.all(color: t.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // The accent strip a respondent will recognise the form by.
        Container(
          height: 5,
          decoration: BoxDecoration(
            color: t.primary,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // `title`, NEVER `displayTitle`. This is the respondent's
              // heading: it is what a candidate reads at the top of the paper,
              // and `FormDef.internalName` is the operator's private label for
              // the same form ("Q7r cohort 3 - retake"). Every ADMIN surface
              // reads `displayTitle`; this one must not, or the preview stops
              // showing what a candidate will actually see and an internal
              // note walks into an exam.
              Text(
                _f.title.isEmpty ? 'Untitled form' : _f.title,
                style: context.type.pageTitle,
              ),
              if (_f.description.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(_f.description, style: context.type.bodySecondary),
              ],
              const SizedBox(height: 6),
              Text(
                '* means an answer is required',
                style: context.type.tiny.copyWith(color: t.destText),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _sectionHeader(FormSection sec, int index, AppTokens t) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (sec.title.isNotEmpty)
          Text(sec.title, style: context.type.panelTitle),
        if (sec.description.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            sec.description,
            style: context.type.small.copyWith(color: t.textMuted),
          ),
        ],
      ],
    ),
  );

  Widget _itemCard(FormItem it, {required bool invalid}) {
    final AppTokens t = context.tokens;

    if (it.kind == FormItemKind.comparePair && !it.isAnswerable) {
      return _pairBlock(it, t);
    }
    // A media block with no options is still a pure display, same as a
    // comparison with none; one WITH options is answered right here instead
    // of falling to `_block`.
    if (!it.kind.isQuestion && !it.isAnswerable) return _block(it, t);

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text.rich(
            TextSpan(
              // The number the candidate sees, counted in their own display
              // order (see _shuffleForSitting). Falls back to just the title
              // if this item somehow has no assigned number.
              text: _displayNo.containsKey(it.id)
                  ? 'Question ${_displayNo[it.id]}. '
                        '${it.title.isEmpty ? 'Untitled question' : it.title}'
                  : (it.title.isEmpty ? 'Untitled question' : it.title),
              style: context.type.body.copyWith(fontWeight: FontWeight.w600),
              children: <InlineSpan>[
                if (it.required)
                  TextSpan(
                    text: ' *',
                    style: TextStyle(color: t.destText),
                  ),
              ],
            ),
          ),
          if (it.help.isNotEmpty) ...<Widget>[
            const SizedBox(height: 3),
            Text(
              it.help,
              style: context.type.small.copyWith(color: t.textMuted),
            ),
          ],
          const SizedBox(height: 12),
          _input(it, t),
          if (invalid) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'This question is required.',
              style: context.type.small.copyWith(color: t.destText),
            ),
          ],
        ],
      ),
    );
  }

  /// A/B media, side by side - the comparison IS the point, so the pair
  /// shares one card and one eye-line. Below ~620px the halves stack.
  Widget _pairTiles(FormItem it, AppTokens t) {
    Widget tile(String tag, String url) {
      final String u = url.trim();
      // Through the shared classifier, not an inline extension test: a YouTube
      // link or `clip.mp4?sig=abc` has to reach the player here exactly as it
      // does in the designer, or Preview contradicts the card it previews.
      final bool isVideo = isVideoMedia(u);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(children: <Widget>[Pill(tag, Tone.inert)]),
          const SizedBox(height: 6),
          if (u.isEmpty)
            Text(
              'No media set',
              style: context.type.small.copyWith(color: t.textMuted),
            )
          else if (isVideo)
            // The exam runner's own player: a native <video> with the
            // browser's controls, so "watch both clips" means watching, not
            // reading a file name.
            clipPlateFor(
              Asset(
                id: '${it.id}-$tag',
                label: tag,
                url: u,
                slot: tag.toLowerCase(),
              ),
              allowDownload: true,
            )
          else
            // Both sides share ONE fixed frame (4:3) and COVER it, so A and
            // B are always the same size whatever their native dimensions -
            // a portrait next to a landscape no longer reads as two heights.
            // Click to open the full image and zoom in.
            // CONTAIN, never cover: both sides share one identical 4:3 frame
            // (so A and B always match), and the whole image stays visible -
            // a judgement call cropped away is a judgement made blind.
            ZoomableImage(
              url: stimulusMediaUrl(u),
              child: ClipRRect(
                borderRadius: Radii.card,
                child: Container(
                  color: t.bgMuted,
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: stimulusImage(
                      u,
                      fit: BoxFit.contain,
                      onError: (BuildContext c) => Container(
                        color: t.bgMuted,
                        alignment: Alignment.center,
                        child: Text(
                          'Media unavailable',
                          style: context.type.small.copyWith(
                            color: t.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (BuildContext c, BoxConstraints bc) => bc.maxWidth < 620
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                tile('A', it.mediaUrl),
                const SizedBox(height: 12),
                tile('B', it.mediaUrlB),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: tile('A', it.mediaUrl)),
                const SizedBox(width: 12),
                Expanded(child: tile('B', it.mediaUrlB)),
              ],
            ),
    );
  }

  /// An option-less pair: pure display, same card shape as the other blocks.
  Widget _pairBlock(FormItem it, AppTokens t) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (it.title.isNotEmpty) ...<Widget>[
          Text(
            it.title,
            style: context.type.body.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
        ],
        if (it.help.isNotEmpty) ...<Widget>[
          Text(it.help, style: context.type.bodySecondary),
          const SizedBox(height: 8),
        ],
        _pairTiles(it, t),
      ],
    ),
  );

  Widget _block(FormItem it, AppTokens t) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (it.title.isNotEmpty)
          Text(
            it.title,
            style: context.type.body.copyWith(fontWeight: FontWeight.w600),
          ),
        if (it.help.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          Text(it.help, style: context.type.bodySecondary),
        ],
        if (it.kind == FormItemKind.imageBlock &&
            it.mediaUrl.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          // The ONE single-image frame every project shares: a 4:3 plate the
          // image FITS inside whole (contain) - same size everywhere, never
          // stretched, never cropped.
          ZoomableImage(
            url: stimulusMediaUrl(it.mediaUrl.trim()),
            child: ClipRRect(
              borderRadius: Radii.card,
              child: Container(
                color: t.bgMuted,
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: stimulusImage(
                    it.mediaUrl.trim(),
                    fit: BoxFit.contain,
                    onError: (BuildContext c) => Container(
                      color: t.bgMuted,
                      alignment: Alignment.center,
                      child: Text(
                        'Image unavailable',
                        style: context.type.small.copyWith(color: t.textMuted),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
        if (it.kind == FormItemKind.videoBlock &&
            it.mediaUrl.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          clipPlateFor(
            Asset(
              id: it.id,
              label: it.title,
              url: it.mediaUrl.trim(),
              slot: 'single',
            ),
            allowDownload: true,
          ),
        ],
      ],
    ),
  );

  /// THE RESPONDENT-INPUT REGISTRY. One entry per kind that collects an
  /// answer here; a kind with no entry (content blocks that never reach
  /// `_input` at all, since `_itemCard` routes them to `_block`/`_pairBlock`
  /// first) falls through to the same empty box the switch's `_ => const
  /// SizedBox.shrink()` produced. Built once per State: every builder closes
  /// over `this` (`setState`, `_answers`, `context`), the same reason the
  /// editor's body registry is instance-level rather than static.
  late final Map<String, Widget Function(FormItem, AppTokens)>
  _inputRegistry = <String, Widget Function(FormItem, AppTokens)>{
    FormItemKind.shortAnswer.name: (FormItem it, AppTokens t) => FormTextInput(
      id: 'pv-${it.id}',
      value: (_answers[it.id] as String?) ?? '',
      hint: 'Your answer',
      onChanged: (String v) => setState(() => _answers[it.id] = v),
    ),
    FormItemKind.paragraph.name: (FormItem it, AppTokens t) => FormTextInput(
      id: 'pv-${it.id}',
      value: (_answers[it.id] as String?) ?? '',
      hint: 'Your answer',
      maxLines: 4,
      onChanged: (String v) => setState(() => _answers[it.id] = v),
    ),
    FormItemKind.comparePair.name: (FormItem it, AppTokens t) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _pairTiles(it, t),
        const SizedBox(height: 12),
        _choices(it, t, multi: false),
      ],
    ),
    // Reached only when `isAnswerable` let it past `_block` above - i.e. the
    // creator gave this media block options, so it is answered right here
    // instead of riding along on whatever question follows it.
    for (final FormItemKind k in <FormItemKind>[
      FormItemKind.imageBlock,
      FormItemKind.videoBlock,
    ])
      k.name: (FormItem it, AppTokens t) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (it.kind == FormItemKind.imageBlock &&
              it.mediaUrl.trim().isNotEmpty)
            ZoomableImage(
              url: stimulusMediaUrl(it.mediaUrl.trim()),
              child: ClipRRect(
                borderRadius: Radii.card,
                child: Container(
                  color: t.bgMuted,
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: stimulusImage(
                      it.mediaUrl.trim(),
                      fit: BoxFit.contain,
                      onError: (BuildContext c) => Container(
                        color: t.bgMuted,
                        alignment: Alignment.center,
                        child: Text(
                          'Image unavailable',
                          style: context.type.small.copyWith(
                            color: t.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (it.kind == FormItemKind.videoBlock &&
              it.mediaUrl.trim().isNotEmpty)
            clipPlateFor(
              Asset(
                id: it.id,
                label: it.title,
                url: it.mediaUrl.trim(),
                slot: 'single',
              ),
              allowDownload: true,
            ),
          const SizedBox(height: 12),
          _choices(it, t, multi: it.multiSelect),
        ],
      ),
    FormItemKind.multipleChoice.name: (FormItem it, AppTokens t) =>
        _choices(it, t, multi: false),
    FormItemKind.checkboxes.name: (FormItem it, AppTokens t) =>
        _choices(it, t, multi: true),
    FormItemKind.dropdown.name: (FormItem it, AppTokens t) => ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: SelectField<String>(
        value: (_answers[it.id] as String?) ?? '',
        options: <(String, String)>[
          ('', 'Choose'),
          for (final FormOption o in it.options)
            (o.id, o.label.isEmpty ? 'Option' : o.label),
        ],
        onChanged: (String v) =>
            setState(() => _answers[it.id] = v.isEmpty ? null : v),
      ),
    ),
    FormItemKind.linearScale.name: (FormItem it, AppTokens t) => _scale(it, t),
    FormItemKind.rating.name: (FormItem it, AppTokens t) => _rating(it, t),
    FormItemKind.choiceGrid.name: (FormItem it, AppTokens t) =>
        _grid(it, t, multi: false),
    FormItemKind.checkboxGrid.name: (FormItem it, AppTokens t) =>
        _grid(it, t, multi: true),
    FormItemKind.imageAnnotation.name: (FormItem it, AppTokens t) =>
        _annotation(it, t),
    // PROMPT WRITING, in the exam runner's own order: the plate(s) first, the
    // optional rating axes next, then the prompt box - see
    // `answer_layouts._ImagePromptLayout`, which this mirrors so the preview
    // cannot show a shape the live form does not.
    FormItemKind.transcription.name: (FormItem it, AppTokens t) =>
        _transcription(it),
    FormItemKind.promptWriting.name: (FormItem it, AppTokens t) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _promptStimulus(it, t),
        if (it.options.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          _choices(it, t, multi: false),
        ],
        const SizedBox(height: 12),
        Text(
          'Your prompt',
          style: context.type.small.copyWith(
            fontWeight: FontWeight.w600,
            color: t.textMuted,
          ),
        ),
        const SizedBox(height: 6),
        FormTextInput(
          id: 'pv-prompt-${it.id}',
          value: (_answers[it.id] as String?) ?? '',
          hint: _looksVideoUrl(it.mediaUrl)
              ? 'Write the video-generation prompt.'
              : 'Write the image-generation prompt.',
          maxLines: 7,
          onChanged: (String v) => setState(() => _answers[it.id] = v),
        ),
      ],
    ),
  };

  Widget _input(FormItem it, AppTokens t) =>
      _inputRegistry[it.kind.name]?.call(it, t) ?? const SizedBox.shrink();

  /// TRANSCRIPTION, as the exam runner draws it (`TranscriptionLayout`): the
  /// clip with its controls, the box, then the clip questions.
  Widget _transcription(FormItem it) {
    final _TxAnswer a =
        _answers.putIfAbsent(it.id, () => _TxAnswer('', ClipAnswers()))!
            as _TxAnswer;
    final ClipControls controls = _clipControls.putIfAbsent(
      it.id,
      ClipControls.new,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (it.mediaUrl.trim().isNotEmpty)
          AudioPlate(
            asset: Asset(
              id: it.id,
              label: it.title,
              url: it.mediaUrl.trim(),
              slot: 'single',
              kind: 'audio',
            ),
            allowDownload: true,
            controls: controls,
          ),
        const SizedBox(height: 12),
        if (a.clip.transcribed) ...<Widget>[
          TranscriptionBox(
            key: ValueKey<String>('pv-tx-${it.id}-${it.transcriptionLanguage}'),
            language: it.transcriptionLanguage,
            initialText: a.text,
            controls: controls,
            onChanged: (String v) => a.text = v,
          ),
          const SizedBox(height: 12),
        ],
        ClipAnswersForm(
          clip: a.clip,
          language: it.transcriptionLanguage,
          onChanged: (ClipAnswers c) => setState(() => a.clip = c),
        ),
      ],
    );
  }

  /// The annotation question as a respondent answers it: the image with its
  /// numbered boxes, and one text field per box. Tapping a box focuses its
  /// field; focusing a field lights its box - the exam runner's link, here.
  Widget _annotation(FormItem it, AppTokens t) {
    final String url = it.mediaUrl.trim();
    final ImageProvider? provider = stimulusImageProvider(url);
    final Map<int, String> ans = switch (_answers[it.id]) {
      final Map<dynamic, dynamic> m => m.cast<int, String>(),
      _ => <int, String>{},
    };

    // The drawn boxes are the optional upgrade; the numbers are the contract.
    // A pre-marked plate has no drawn boxes and simply numbers its fields
    // 1..annotationCount to match the markers baked into the picture.
    final List<int> numbers = it.annotationNumbers;
    final bool interactive = it.regions.isNotEmpty;
    final List<LabelRegion> ordered = List<LabelRegion>.of(it.regions)
      ..sort((LabelRegion a, LabelRegion b) => a.number.compareTo(b.number));
    final int filled = numbers
        .where((int n) => (ans[n] ?? '').trim().isNotEmpty)
        .length;

    // ONE answer area, driven by the numbered chip strip - never a stack of
    // inputs. A dense plate has 20-30 boxes, and thirty fields in a column is
    // unusable; a two-box plate loses nothing by the same layout.
    int sel = _annSel[it.id] ?? (numbers.isEmpty ? 0 : numbers.first);
    if (!numbers.contains(sel) && numbers.isNotEmpty) sel = numbers.first;

    final Widget plate = ClipRRect(
      borderRadius: Radii.card,
      child: Container(
        color: t.bgMuted,
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: provider == null
              ? const SizedBox.shrink()
              : (interactive
                    ? RegionOverlayImage(
                        provider: provider,
                        regions: ordered,
                        activeNumber: sel,
                        onRegionTap: (int n) =>
                            setState(() => _annSel[it.id] = n),
                        // A tap off every marker means "let me look closer".
                        onBackgroundTap: () =>
                            showImageLightbox(context, stimulusMediaUrl(url)),
                      )
                    : Image(image: provider, fit: BoxFit.contain)),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (url.isEmpty || provider == null)
          Text(
            url.isEmpty ? 'No image set' : 'Image unavailable',
            style: context.type.small.copyWith(color: t.textMuted),
          )
        else if (interactive)
          plate
        else
          // A pre-marked plate handles no taps of its own, so the stock
          // click-to-zoom wrapper applies whole.
          ZoomableImage(url: stimulusMediaUrl(url), child: plate),
        if (numbers.isEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            'No annotations set for this image yet.',
            style: context.type.small.copyWith(color: t.textMuted),
          ),
        ] else ...<Widget>[
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  interactive
                      ? 'Tap a numbered box to jump to its answer; tap '
                            'elsewhere on the image to zoom.'
                      : 'Click the image to zoom in on each numbered '
                            'annotation, then describe it below.',
                  style: context.type.tiny.copyWith(color: t.textMuted),
                ),
              ),
              Text(
                '$filled / ${numbers.length} answered',
                style: context.type.tiny.copyWith(color: t.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...<Widget>[
            // The chip strip: every annotation number, its answered state at
            // a glance, one click to jump. The strip IS the completion
            // overview a single visible answer box would otherwise hide.
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final int n in numbers)
                  _annChip(
                    n,
                    selected: n == sel,
                    answered: (ans[n] ?? '').trim().isNotEmpty,
                    onTap: () => setState(() => _annSel[it.id] = n),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            // Full width, no gutter label: the selected chip and the hint
            // both already name the annotation, and the chips are the only
            // navigation - click a number to jump anywhere.
            FormTextInput(
              // Keyed by the SELECTED number: switching chips swaps in
              // that annotation's saved text - nothing is ever lost, the
              // map held every answer all along.
              id: 'pv-ann-${it.id}-$sel',
              value: ans[sel] ?? '',
              hint: 'What is wrong at annotation $sel?',
              maxLines: 3,
              onChanged: (String v) => setState(
                () => _answers[it.id] = <int, String>{...ans, sel: v},
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Every box is submitted, not just this one.',
              textAlign: TextAlign.right,
              style: context.type.tiny.copyWith(color: t.textMuted),
            ),
          ],
        ],
      ],
    );
  }

  /// One annotation-number chip: selected carries the accent, answered shows
  /// a filled dot, empty a hollow one - the gaps are visible before submit.
  Widget _annChip(
    int n, {
    required bool selected,
    required bool answered,
    required VoidCallback onTap,
  }) {
    final AppTokens t = context.tokens;
    return InkWell(
      onTap: onTap,
      borderRadius: Radii.buttonSm,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? t.primary.o(.14) : t.bgApp,
          borderRadius: Radii.buttonSm,
          border: Border.all(color: selected ? t.primary.o(.65) : t.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              answered ? Icons.circle : Icons.circle_outlined,
              size: 8,
              color: answered
                  ? (selected ? t.primary : t.successText)
                  : t.textMuted,
            ),
            const SizedBox(width: 5),
            Text(
              '$n',
              style: context.type.monoSmall.copyWith(
                fontWeight: FontWeight.w700,
                color: selected ? t.primary : t.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The plate(s) a prompt-writing question is about: one on the from-scratch
  /// form, a captioned REFERENCE -> OUTPUT pair on the transform form. Both
  /// media kinds are accepted in either slot, read from the URL - the same
  /// test the server uses to pick `image_prompt` over `video_prompt`.
  Widget _promptStimulus(FormItem it, AppTokens t) {
    final String a = it.mediaUrl.trim();
    final String b = it.mediaUrlB.trim();

    Widget plate(String url, String slot, String caption) {
      if (url.isEmpty) {
        return Text(
          'No media set',
          style: context.type.small.copyWith(color: t.textMuted),
        );
      }
      final Widget media = _looksVideoUrl(url)
          ? clipPlateFor(
              Asset(id: '${it.id}-$slot', label: caption, url: url, slot: slot),
              caption: caption,
              allowDownload: true,
            )
          : ZoomableImage(
              url: stimulusMediaUrl(url),
              child: ClipRRect(
                borderRadius: Radii.card,
                child: Container(
                  color: t.bgMuted,
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: stimulusImage(
                      url,
                      fit: BoxFit.contain,
                      onError: (BuildContext c) => Container(
                        color: t.bgMuted,
                        alignment: Alignment.center,
                        child: Text(
                          'Media unavailable',
                          style: context.type.small.copyWith(
                            color: t.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
      // A video plate captions itself; an image needs the label saying which
      // side it is, and only on the pair form where that distinction exists.
      if (_looksVideoUrl(url) || caption.isEmpty) return media;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(children: <Widget>[Pill(caption, Tone.inert)]),
          const SizedBox(height: 6),
          media,
        ],
      );
    }

    if (b.isEmpty) return plate(a, 'single', '');

    return LayoutBuilder(
      builder: (BuildContext c, BoxConstraints bc) => bc.maxWidth < 620
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                plate(a, 'reference', 'Reference'),
                const SizedBox(height: 12),
                plate(b, 'output', 'Output'),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: plate(a, 'reference', 'Reference')),
                const SizedBox(width: 12),
                Expanded(child: plate(b, 'output', 'Output')),
              ],
            ),
    );
  }

  Widget _choices(FormItem it, AppTokens t, {required bool multi}) {
    final Object? raw = _answers[it.id];
    final Set<String> picked = multi
        ? ((raw as Set?)?.cast<String>() ?? <String>{})
        : <String>{if (raw is String) raw};

    void tap(String id) => setState(() {
      if (multi) {
        final Set<String> next = <String>{...picked};
        next.contains(id) ? next.remove(id) : next.add(id);
        _answers[it.id] = next;
      } else {
        _answers[it.id] = raw == id ? null : id;
      }
    });

    Widget row(String id, Widget label) {
      final bool on = picked.contains(id);
      return InkWell(
        onTap: () => tap(id),
        borderRadius: Radii.button,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: <Widget>[
              Icon(
                multi
                    ? (on
                          ? Icons.check_box_outlined
                          : Icons.check_box_outline_blank)
                    : (on
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked),
                size: 18,
                color: on ? t.primary : t.textMuted,
              ),
              const SizedBox(width: 10),
              Expanded(child: label),
            ],
          ),
        ),
      );
    }

    // The designer's shuffle flag is honoured in the LIVE form only; a
    // preview that reorders on every rebuild would make the form impossible
    // to check against what was typed.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final FormOption o in it.options)
          row(
            o.id,
            Text(
              o.label.isEmpty ? 'Option' : o.label,
              style: context.type.body,
            ),
          ),
        // NO "Other" ROW. A free-text Other can never match the answer key, so
        // every candidate picking it is marked wrong whatever they type - and the
        // publish path was already dropping it with a warning. See the designer's
        // own note where the 'Add "Other"' button used to be.
      ],
    );
  }

  Widget _scale(FormItem it, AppTokens t) {
    final int? v = _answers[it.id] as int?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            if (it.scaleMinLabel.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 10, bottom: 6),
                child: Text(
                  it.scaleMinLabel,
                  style: context.type.small.copyWith(color: t.textMuted),
                ),
              ),
            for (int s = it.scaleMin; s <= it.scaleMax; s++)
              Expanded(
                child: InkWell(
                  onTap: () =>
                      setState(() => _answers[it.id] = v == s ? null : s),
                  borderRadius: Radii.button,
                  child: Column(
                    children: <Widget>[
                      Text('$s', style: context.type.small),
                      const SizedBox(height: 4),
                      Icon(
                        v == s
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 18,
                        color: v == s ? t.primary : t.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
            if (it.scaleMaxLabel.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 10, bottom: 6),
                child: Text(
                  it.scaleMaxLabel,
                  style: context.type.small.copyWith(color: t.textMuted),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _rating(FormItem it, AppTokens t) {
    final int v = (_answers[it.id] as int?) ?? 0;
    return Wrap(
      children: <Widget>[
        for (int s = 1; s <= it.ratingMax; s++)
          InkWell(
            onTap: () => setState(() => _answers[it.id] = v == s ? null : s),
            borderRadius: Radii.button,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                s <= v ? Icons.star : Icons.star_border,
                size: 24,
                color: s <= v ? t.primary : t.textMuted,
              ),
            ),
          ),
      ],
    );
  }

  Widget _grid(FormItem it, AppTokens t, {required bool multi}) {
    final Map<int, Object?> ans = switch (_answers[it.id]) {
      final Map<dynamic, dynamic> m => m.cast<int, Object?>(),
      _ => <int, Object?>{},
    };

    bool on(int r, String col) => multi
        ? (ans[r] is Set && (ans[r] as Set).contains(col))
        : ans[r] == col;

    void tap(int r, String col) => setState(() {
      final Map<int, Object?> next = <int, Object?>{...ans};
      if (multi) {
        final Set<String> cell = <String>{
          ...?(next[r] as Set?)?.cast<String>(),
        };
        cell.contains(col) ? cell.remove(col) : cell.add(col);
        next[r] = cell;
      } else {
        next[r] = next[r] == col ? null : col;
        if (next[r] == null) next.remove(r);
      }
      _answers[it.id] = next;
    });

    const double labelW = 140;
    final Widget table = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            const SizedBox(width: labelW),
            for (final String c in it.columns)
              Expanded(
                child: Text(
                  c,
                  textAlign: TextAlign.center,
                  style: context.type.small.copyWith(color: t.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        for (int r = 0; r < it.rows.length; r++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: labelW,
                  child: Text(it.rows[r], style: context.type.body),
                ),
                for (final String c in it.columns)
                  Expanded(
                    child: Center(
                      child: InkWell(
                        onTap: () => tap(r, c),
                        borderRadius: Radii.pill,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            multi
                                ? (on(r, c)
                                      ? Icons.check_box_outlined
                                      : Icons.check_box_outline_blank)
                                : (on(r, c)
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked),
                            size: 18,
                            color: on(r, c) ? t.primary : t.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );

    // A grid keeps a readable column width and scrolls sideways in its own
    // container when the card is too narrow - the page itself never does.
    return LayoutBuilder(
      builder: (BuildContext ctx, BoxConstraints bc) {
        final double needed = labelW + it.columns.length * 90;
        if (needed <= bc.maxWidth) return table;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: needed, child: table),
        );
      },
    );
  }
}

/// Whether a media URL points at a clip rather than a still.
///
/// Delegates to the shared [mediaKindOf] so the preview, the designer and
/// `studio_form._looks_like_video` on the server all answer identically:
/// prompt-writing questions accept either medium in either slot, and it is
/// this test - not a picker the examiner could set wrong - that decides
/// whether a form emits `image_prompt` or `video_prompt`.
bool _looksVideoUrl(String url) => isVideoMedia(url);

/// A transcription answered in the preview: what is in the box, and the clip
/// answers beside it.
class _TxAnswer {
  _TxAnswer(this.text, this.clip);

  String text;
  ClipAnswers clip;
}
