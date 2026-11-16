// The answer layouts - HANDOVER §4.7.
//
// Count deliberately not stated: the module's type table has both grown and
// shrunk, so a number here goes stale the next time one moves.
//
// `AnswerArea` builds them all. In read-only mode every input hook is stripped
// and every control is disabled or readonly.
//
// The rule that shapes this file: THE FREE-TEXT FIELDS MUST NOT TRIGGER A
// REBUILD - focus and caret would be lost. So every textarea and label input
// owns a `TextEditingController` and writes through `saveAnswerQuiet`, which
// mutates the store WITHOUT notifying. The live "n / m labelled" counter is
// patched from local state for the same reason.
import 'transcription_layout.dart';
import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../widgets/controls.dart';
import '../../widgets/feedback.dart';
import '../../widgets/panel.dart';
import 'stimulus.dart';
import 'video_plate.dart';
import '../../theme.dart';

/// The media plate for a question: a clip when it has one, otherwise the
/// image, otherwise the empty state.
///
/// VIDEO FIRST. A `video_prompt` question carries `video_files` and no
/// `images`, so an images-only check fell through to "No image yet for this
/// question" while the server had sent a perfectly good clip. Nothing errored;
/// the candidate was simply asked about a video they could not watch.
Widget mediaFor(Question q, {String caption = ''}) {
  if (q.videos.isNotEmpty) {
    final Asset v = q.videos.first;
    return clipPlateFor(v, caption: caption.isNotEmpty ? caption : v.label);
  }
  if (q.images.isNotEmpty) {
    final Asset a = q.images.first;
    return StimulusPlate(
      asset: a,
      caption: caption.isNotEmpty ? caption : a.label,
    );
  }
  return const MissingStimulus();
}

/// EVERY plate the question carries, captioned.
///
/// [mediaFor] deliberately shows one - it is the "this question has a
/// stimulus" helper. But the preferred form of both prompt-authoring types is
/// a PAIR: `reference` and `output`, with the candidate writing the
/// transformation that turns one into the other. Showing only the first asked
/// them to describe a change to something they were never shown, which is not
/// a question anyone can answer.
///
/// The captions are the other half: on a pair, the label is the only thing
/// saying which clip is the reference and which is the output, so dropping it
/// lets a candidate write the transformation backwards.
Widget allMedia(Question q) {
  // `echoes: q.prompt` - a plate whose label merely repeats the question is
  // captioned with nothing. The publish path names a media block from its item
  // title, and for a videoBlock/imageBlock that IS the question, so the same
  // sentence was printed twice: once as the bold prompt and again under the
  // plate ("Watch the clip, then answer." above and below the player). A
  // caption earns its place only when it says something the prompt did not -
  // which is exactly the case the reference/output pair depends on.
  final List<Widget> plates = mediaPlates(
    q.images,
    q.videos,
    echoes: q.prompt,
    sideFree: q.isSideFreeAb,
  );
  if (plates.isEmpty) return const MissingStimulus();
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: plates,
  );
}

/// The plates themselves, clips before stills, with no verdict on an empty
/// set.
///
/// Split out of [allMedia] so the post-release answer sheet can show the same
/// pictures the exam showed. The two callers disagree about nothing except
/// emptiness: a live question with no stimulus is a broken question and says
/// so, while a review row for an mcq simply has no media and must stay quiet.
/// That is the caller's call, so this returns the list and judges nothing.
List<Widget> mediaPlates(
  List<Asset> images,
  List<Asset> videos, {
  bool showRegions = false,

  /// A caption identical to this is dropped as redundant. See [allMedia].
  String echoes = '',

  /// A side-free image_ab pair ([abIsSideFree]): no Response A/B, so the
  /// stills are captioned by [sideFreeCaption] and sit left and right.
  bool sideFree = false,
}) => <Widget>[
  for (final Asset v in videos)
    Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: clipPlateFor(
        _echoFree(v, echoes),
        caption: _caption(v.label, echoes),
      ),
    ),
  if (sideFree && images.isNotEmpty)
    Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: _PlatePair(<Widget>[
        for (final (int i, Asset a) in images.indexed)
          StimulusPlate(
            asset: a,
            caption: sideFreeCaption(_caption(a.label, echoes), i),
          ),
      ]),
    )
  else
    for (final Asset a in images)
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: StimulusPlate(
          // THE MARKED PLATE for a labelling question, matching what
          // `_ImageLabelLayout` hands the candidate. The numbered boxes come
          // from one of two places: region geometry the client draws, or a
          // baked annotated bitmap. With only the bitmap - which is what
          // `bank_label_boxes` leaves when it returns bare integers - the plain
          // plate shows an unmarked screenshot beside answers reading "Box 3:
          // ...", so the reader is asked to audit a picture that does not show
          // the thing being audited.
          asset:
              showRegions &&
                  a.regions.isEmpty &&
                  (a.annotatedUrl ?? '').isNotEmpty
              ? a.copyWith(url: a.annotatedUrl)
              : a,
          caption: _caption(a.label, echoes),
          showRegions: showRegions,
        ),
      ),
];

/// [v] without a label that only repeats the prompt. The audio plate names its
/// clip from the label when it has no caption, so blanking the caption alone
/// printed the question a second time above the player.
Asset _echoFree(Asset v, String echoes) => _caption(v.label, echoes).isEmpty
    ? Asset(
        id: v.id,
        label: '',
        url: v.url,
        svg: v.svg,
        slot: v.slot,
        annotatedUrl: v.annotatedUrl,
        regions: v.regions,
        posterUrl: v.posterUrl,
        kind: v.kind,
      )
    : v;

/// A plate label, unless it only repeats what the prompt already said.
///
/// Compared on the trimmed, case-folded text with any trailing full stop
/// dropped, because "Watch the clip, then answer." as a prompt and "Watch the
/// clip, then answer" as a label are the same sentence to a reader and differ
/// only in how the publish path happened to store them.
String _caption(String label, String echoes) {
  String flatten(String v) {
    final String t = v.trim().toLowerCase();
    return t.endsWith('.') ? t.substring(0, t.length - 1) : t;
  }

  if (echoes.trim().isEmpty) return label;
  return flatten(label) == flatten(echoes) ? '' : label;
}

/// A left/right pair of plates: side by side when each can be at least ~210px
/// wide, stacked (left first) when not, so a phone never gets two slivers.
class _PlatePair extends StatelessWidget {
  final List<Widget> plates;

  const _PlatePair(this.plates);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) => c.maxWidth < 440
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final (int i, Widget p) in plates.indexed) ...<Widget>[
                if (i > 0) const SizedBox(height: 14),
                p,
              ],
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final (int i, Widget p) in plates.indexed) ...<Widget>[
                if (i > 0) const SizedBox(width: 14),
                Expanded(child: p),
              ],
            ],
          ),
  );
}

/// The question's description, with a scale legend the CONTROL now draws
/// removed.
///
/// The publish path folds an examiner's `scale_min_label`/`scale_max_label` into
/// the description as "Scale: 1 = Unsure, 5 = Certain", because that legend was
/// the only place the ends of the range were named - the old boxed control had
/// no room for them. The scale draws its own ends now, so leaving the line in
/// prints the same two words twice, directly above themselves.
///
/// Stripped HERE rather than at the source. That legend is what the QWeb portal
/// runner shows, and it renders no scale control at all, so it stays on the
/// record and on the wire for the candidates who have nothing else. Only the
/// runner that has drawn the ends drops the sentence, and only when it actually
/// drew them: a question with no scale axis, or a legend whose ends were left
/// blank, keeps its description exactly as written.
String questionDesc(Question q) {
  final bool drawn = q.dims.any(_Options.isScaleAxis);
  if (!drawn) return q.desc;
  final (String lo, String hi) = _Options.scaleEnds(q.desc);
  if (lo.isEmpty && hi.isEmpty) return q.desc;
  return q.desc
      .split('\n')
      .where((String line) => !line.trimLeft().startsWith('Scale: '))
      .join('\n')
      .trim();
}

class AnswerArea extends StatelessWidget {
  final AppStore store;
  final Attempt ev;
  final Question q;

  /// Read-only: the preview sheet and every post-submission replay.
  ///
  /// An option keeps its FULL-STRENGTH resting and selected appearance here:
  /// a submitted answer must stay legible under audit, so it is not dimmed.
  final bool readOnly;

  const AnswerArea({
    super.key,
    required this.store,
    required this.ev,
    required this.q,
    this.readOnly = false,
  });

  /// The assessment may require a written justification ALONGSIDE the option.

  @override
  Widget build(BuildContext context) {
    final Response r = store.responseFor(ev, q);
    return switch (q.type) {
      // An mcq/msq can carry attached media too - Form Studio publishes an
      // imageBlock/videoBlock WITH options as exactly this type, with the
      // block's own image/video attached (see studio_form.py's imageBlock/
      // videoBlock branch). Neither branch used to look, so a media-backed
      // question rendered as options with no picture or clip above them.
      QType.mcq =>
        (q.images.isNotEmpty || q.videos.isNotEmpty)
            ? _ImgLayout(
                stimulus: allMedia(q),
                answer: _Options(
                  store: store,
                  ev: ev,
                  q: q,
                  r: r,
                  readOnly: readOnly,
                  multi: false,
                ),
              )
            : _Options(
                store: store,
                ev: ev,
                q: q,
                r: r,
                readOnly: readOnly,
                multi: false,
              ),
      QType.msq =>
        (q.images.isNotEmpty || q.videos.isNotEmpty)
            ? _ImgLayout(
                stimulus: allMedia(q),
                answer: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const _MsqHint(),
                    const SizedBox(height: 10),
                    _Options(
                      store: store,
                      ev: ev,
                      q: q,
                      r: r,
                      readOnly: readOnly,
                      multi: true,
                    ),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const _MsqHint(),
                  const SizedBox(height: 10),
                  _Options(
                    store: store,
                    ev: ev,
                    q: q,
                    r: r,
                    readOnly: readOnly,
                    multi: true,
                  ),
                ],
              ),
      // A subjective_rubric question can carry attached media (Form Studio
      // folds standalone image/video blocks into the next real question), but
      // this branch used to go straight to the text box and never looked -
      // the candidate saw a plain answer field for a question that referred
      // to a clip or image they were never shown. Only wrap with a stimulus
      // panel when there IS media, so an ordinary text-only question renders
      // exactly as before.
      //
      // IT CAN ALSO CARRY AXES. A task template drawn in the Form Studio
      // editor authors real multiple-choice items - "is it sharp?", "is it a
      // real photo?" - and generation now keeps that structure instead of
      // flattening it to prose. Those questions arrive here as
      // subjective_rubric WITH dimensions, and this branch drew one textarea
      // for all six judgements: unanswerable per axis, and unmarkable per
      // axis by a grader that scores per component. When axes are present the
      // candidate gets the pickers AND the prose box, because a template that
      // asks for a reason still wants one.
      QType.subjectiveRubric => _RubricLayout(
        store: store,
        ev: ev,
        q: q,
        r: r,
        readOnly: readOnly,
      ),
      QType.imageAb => _ImageAbLayout(
        store: store,
        ev: ev,
        q: q,
        r: r,
        readOnly: readOnly,
      ),
      QType.imagePrompt => _ImagePromptLayout(
        store: store,
        ev: ev,
        q: q,
        r: r,
        readOnly: readOnly,
      ),
      QType.videoPrompt => _VideoPromptLayout(
        store: store,
        ev: ev,
        q: q,
        r: r,
        readOnly: readOnly,
      ),
      QType.imageLabel => _ImageLabelLayout(
        store: store,
        ev: ev,
        q: q,
        r: r,
        readOnly: readOnly,
      ),
      QType.transcription => TranscriptionLayout(
        store: store,
        ev: ev,
        q: q,
        r: r,
        readOnly: readOnly,
      ),
      // Nothing to answer here, so nothing is saved: Next moves on and the
      // question counts as unanswered (A-053).
      QType.unsupported => const Notice(
        tone: Tone.warn,
        strong:
            'This question type is not supported in this version of the '
            'app.',
        text:
            'Please contact your assessment organiser. You can still move '
            'on to the next question and submit.',
      ),
    };
  }
}

/// `.hint-msq` - the redundant text cue that pairs with the square checkbox
/// shape. Shape alone distinguishes single from multi-select; this chip is the
/// second signal.
class _MsqHint extends StatelessWidget {
  const _MsqHint();

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      height: 21,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.primarySubtle,
        borderRadius: Radii.pill,
      ),
      child: Text(
        'Select all that apply',
        style: context.type.tiny.copyWith(
          fontWeight: FontWeight.w700,
          color: t.primary,
        ),
      ),
    );
  }
}

/// One dimension's option set. Single-select strips every other option id
/// belonging to the same dimension before appending the clicked one, so a
/// multi-dimension question cannot end up with two answers on one axis.
class _Options extends StatelessWidget {
  final AppStore store;
  final Attempt ev;
  final Question q;
  final Response r;
  final bool readOnly;
  final bool multi;

  /// When null every dimension is rendered; the A/B layout passes one at a
  /// time so each gets its own legend.
  final QDimension? only;

  const _Options({
    required this.store,
    required this.ev,
    required this.q,
    required this.r,
    required this.readOnly,
    required this.multi,
    this.only,
  });

  void _pick(QDimension d, QOption o) {
    if (readOnly) return;
    // MERGE ONTO THE STORE'S RESPONSE, not onto `r`.
    //
    // `r` was resolved once when this layout was built, and a free-text write
    // does not rebuild it - `saveAnswerQuiet` exists precisely so typing does
    // not repaint. So on a question carrying BOTH options and prose - any
    // the image layouts with dimensions - picking an option merged the new
    // lines onto a
    // response whose justification was still empty, and wrote the candidate's
    // typed answer back out of existence.
    final Response base = store.responseFor(ev, q);
    final List<String> lines = List<String>.from(base.lines);
    // Multi-select is a property of THIS AXIS, not of the whole question: a
    // template can put a checkboxes axis next to single-choice ones.
    if (multi || _isMulti(d)) {
      lines.contains(o.id) ? lines.remove(o.id) : lines.add(o.id);
    } else {
      final Set<String> mine = d.options.map((QOption x) => x.id).toSet();
      lines.removeWhere(mine.contains);
      lines.add(o.id);
    }
    store.saveAnswer(ev.id, q.id, base.copyWith(lines: lines));
  }

  @override
  Widget build(BuildContext context) {
    final List<QDimension> dims = only != null ? <QDimension>[only!] : q.dims;
    // Parsed once here, not per axis: it is a regex over the description and
    // every scale axis of a question shares the same one.
    final (String, String) ends = scaleEnds(q.desc);
    // A GRID IS ONE QUESTION, NOT N QUESTIONS.
    //
    // The server turns a `choiceGrid`/`checkboxGrid` into one dimension per ROW
    // (name = the row label, options = the columns), which is the right storage
    // shape - each row is independently keyed and scored. But rendering that
    // shape row-by-row gave the candidate a stack of separate option lists with
    // the column labels repeated under every row, while Form Studio's own
    // Preview drew a real matrix. The examiner authored a grid, previewed a
    // grid, and the candidate answered something else.
    //
    // Drawn here instead as one matrix: column headers once, row labels down
    // the side, a control at each intersection. Everything below the render is
    // untouched - `_pick` still writes per row, so scoring and the answer key
    // are unaffected.
    if (only == null && _isGrid(dims)) {
      return _GridMatrix(
        key: const Key('axis-grid'),
        dimensions: dims,
        selected: r.lines,
        multi: _isMulti(dims.first),
        onTap: readOnly ? null : _pick,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final QDimension d in dims)
          // ONE GROUP PER AXIS, NAMED - the replacement for the QWeb runner's
          // `<fieldset><legend>`.
          //
          // Without it a screen reader reads a flat run of options with nothing
          // saying which axis they belong to. On an A/B evaluation that is six
          // axes of near-identical choices in a row - "Better", "Worse",
          // "Better", "Worse"... - and no way to tell which question any pair
          // answers. The label is attached to the CONTAINER rather than to each
          // option, so the axis name is spoken once on entering the group
          // instead of being prefixed onto all five options.
          Semantics(
            container: true,
            explicitChildNodes: true,
            label: d.name.isNotEmpty ? d.name : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if ((only != null || dims.length > 1) &&
                    d.name.isNotEmpty) ...<Widget>[
                  // The NAME alone. `code` is a fixture-only display label
                  // defaulting to 'D1', and the server sends none - so every
                  // axis of every question was prefixed with the same "D1",
                  // including all six axes of an A/B evaluation.
                  //
                  // Excluded from semantics: the group label above already speaks
                  // it, and a reader would otherwise announce the axis name twice
                  // on the way in.
                  ExcludeSemantics(
                    child: Text(
                      d.name.toUpperCase(),
                      style: context.type.eyebrow,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                // The axis renders as the control the examiner DREW. Everything
                // used to be a stack of radios, so a 1-5 rating became five tall
                // rows and a checkboxes item silently allowed only one pick.
                // An axis with no authored kind keeps the stacked radios, which
                // is every question written before templates carried a control.
                // A DROPDOWN IS A DROPDOWN. `input_kind` arrives as 'dropdown'
                // and nothing read it, so the examiner drew a select, previewed a
                // select in Form Studio, and the candidate answered a radio list
                // - visually indistinguishable from a plain multiple choice, which
                // is exactly how it was reported. Same `SelectField` and same
                // 320px cap as the designer's own preview, so the two surfaces
                // cannot drift.
                if (_isDropdown(d))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: SelectField<String>(
                        key: const Key('axis-dropdown'),
                        value: d.options
                            .map((QOption o) => o.id)
                            .firstWhere(r.lines.contains, orElse: () => ''),
                        options: <(String, String)>[
                          ('', 'Choose'),
                          for (final QOption o in d.options)
                            (o.id, o.label.isEmpty ? 'Option' : o.label),
                        ],
                        onChanged: readOnly
                            ? (String _) {}
                            : (String v) {
                                if (v.isEmpty) return;
                                _pick(
                                  d,
                                  d.options.firstWhere(
                                    (QOption o) => o.id == v,
                                  ),
                                );
                              },
                      ),
                    ),
                  )
                // A RATING IS STARS, A LINEAR SCALE IS NUMBERED BUTTONS. Both were
                // `_ScaleRow`, so the two controls were pixel-identical on the
                // candidate's screen while Form Studio previewed them as different
                // things. The designer draws a rating as cumulative filled stars
                // (form_preview._rating), and that is what is mirrored here.
                else if (_isStarRating(d))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _StarRow(
                      key: const Key('axis-rating'),
                      dimension: d,
                      selected: r.lines,
                      onTap: readOnly ? null : (QOption o) => _pick(d, o),
                    ),
                  )
                else if (isScaleAxis(d))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ScaleRow(
                      // Stable handle: the exam tests assert that a rating axis
                      // renders as ONE row rather than a stack of radios, and
                      // the widget itself is private to this file.
                      key: const Key('axis-scale'),
                      dimension: d,
                      selected: r.lines,
                      minLabel: ends.$1,
                      maxLabel: ends.$2,
                      onTap: readOnly ? null : (QOption o) => _pick(d, o),
                    ),
                  )
                else
                  for (final QOption o in d.options)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _Option(
                        label: o.label,
                        checked: r.lines.contains(o.id),
                        multi: multi || _isMulti(d),
                        onTap: readOnly ? null : () => _pick(d, o),
                      ),
                    ),
                const SizedBox(height: 10),
              ],
            ),
          ),
      ],
    );
  }

  /// A scale reads as one continuous range, not a stack of full-width rows.
  ///
  /// Only when the options are SHORT: `linearScale` and `rating` are numeric by
  /// construction, but an examiner can label the points, and long labels do not
  /// fit above a track.
  ///
  /// Library-visible, unlike its two siblings, because [questionDesc] has to ask
  /// the same question to know whether the control drew the scale's ends - if
  /// the two ever disagreed, the description would drop a legend nothing
  /// replaced.
  static bool isScaleAxis(QDimension d) {
    if (d.inputKind != 'linearScale' && d.inputKind != 'rating') return false;
    if (d.options.length < 3 || d.options.length > 10) return false;
    return d.options.every((QOption o) => o.label.trim().length <= 3);
  }

  /// The examiner's names for the two ends of a scale, read off the legend the
  /// publish path composes into the question's description.
  ///
  /// `scale_min_label`/`scale_max_label` are authored in Form Studio and are NOT
  /// separate keys on the candidate payload: `studio_form._item_spec` folds them
  /// into the description as "Scale: 1 = Unsure, 5 = Certain". So the scale
  /// control had numbers and no ends, and the only place the range was named was
  /// a line of prose above it - which is exactly the shape reported as not
  /// looking like a scale.
  ///
  /// Parsed rather than added to the wire on purpose. That legend is also what
  /// the QWeb portal runner shows, and it renders no scale control at all, so
  /// dropping it would leave those candidates with no idea what the ends mean.
  /// A description with no legend, or one an examiner wrote by hand in another
  /// shape, simply yields no labels and the scale draws its numbers alone.
  static (String, String) scaleEnds(String desc) {
    final RegExpMatch? m = RegExp(
      r'^Scale:\s*\S+\s*=\s*(.+?),\s*\S+\s*=\s*(.+?)$',
      multiLine: true,
    ).firstMatch(desc);
    if (m == null) return ('', '');
    // The publish path writes the BOUND itself when its label is blank
    // ("1 = 1"), which says nothing the number above the mark does not.
    String end(String? s) {
      final String v = (s ?? '').trim();
      return int.tryParse(v) == null ? v : '';
    }

    return (end(m.group(1)), end(m.group(2)));
  }

  /// A select the examiner drew, not a radio list.
  ///
  /// Only the kind is tested: a dropdown of two options is still a dropdown, and
  /// unlike a scale there is no label-length condition that could make one
  /// unrenderable.
  static bool _isDropdown(QDimension d) => d.inputKind == 'dropdown';

  /// A star rating: cumulative, 1..N, numeric labels only.
  ///
  /// Split from [_isScale] rather than replacing it - `linearScale` keeps the
  /// numbered-button row, which is what it is in every form tool, and only
  /// `rating` becomes stars. The same numeric and length guards apply: an
  /// examiner who labelled the points ("Poor".."Great") gets the labelled row
  /// back, because a star carries no text and those labels would vanish.
  static bool _isStarRating(QDimension d) {
    if (d.inputKind != 'rating') return false;
    if (d.options.length < 3 || d.options.length > 10) return false;
    // The publish path builds these as str(1)..str(max), so a non-numeric label
    // means an examiner overrode them and the text has to stay visible.
    return d.options.every((QOption o) => int.tryParse(o.label.trim()) != null);
  }

  /// Checkbox-shaped axes accept several answers; every other axis accepts one.
  static bool _isMulti(QDimension d) =>
      d.inputKind == 'checkboxes' || d.inputKind == 'checkboxGrid';

  /// True when these axes are the ROWS of one grid the examiner drew.
  ///
  /// Two conditions, and both are load-bearing:
  ///
  ///   * every axis names a grid kind. `input_kind` is only set by an authored
  ///     control, so a question written before templates carried one falls
  ///     through to the stacked rows it has always rendered as.
  ///   * every axis offers the SAME option labels, in the same order. A matrix
  ///     has one set of column headers by definition; if the rows disagree
  ///     there is no honest header row to draw, and guessing one would put a
  ///     control under the wrong column - a wrong answer the candidate cannot
  ///     see. Falling back to the per-row lists is correct in that case.
  ///
  /// A single row is still drawn as a matrix: a one-row grid with its header is
  /// what the examiner drew, and it reads better than a bare option list.
  static bool _isGrid(List<QDimension> dims) {
    if (dims.length < 2 && (dims.isEmpty || dims.first.options.length < 2)) {
      return false;
    }
    if (!dims.every(
      (QDimension d) =>
          d.inputKind == 'choiceGrid' || d.inputKind == 'checkboxGrid',
    )) {
      return false;
    }
    final List<String> header = dims.first.options
        .map((QOption o) => o.label)
        .toList();
    if (header.length < 2) return false;
    for (final QDimension d in dims) {
      if (d.options.length != header.length) return false;
      for (int i = 0; i < header.length; i++) {
        if (d.options[i].label != header[i]) return false;
      }
    }
    return true;
  }
}

/// A grid question drawn as a matrix: column headers once, one row per axis.
///
/// Row labels sit in a fixed-width column so every control lines up under its
/// header; the columns share the remaining width equally. On a narrow viewport
/// the label column shrinks rather than the controls, because an unreadable
/// control is worse than a truncated label.
class _GridMatrix extends StatelessWidget {
  final List<QDimension> dimensions;
  final List<String> selected;
  final bool multi;
  final void Function(QDimension, QOption)? onTap;

  const _GridMatrix({
    required this.dimensions,
    required this.selected,
    required this.multi,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final List<QOption> header = dimensions.first.options;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double labelW = c.maxWidth < 520
            ? 96
            : (c.maxWidth * 0.30).clamp(120, 260);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // Header row. Kept out of the scroll of the rows below it because a
            // grid this size never needs one, and a detached header that can
            // drift out of alignment is worse than none.
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: <Widget>[
                  SizedBox(width: labelW),
                  for (final QOption o in header)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          o.label,
                          textAlign: TextAlign.center,
                          style: context.type.eyebrow,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            for (final QDimension d in dimensions)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    SizedBox(
                      width: labelW,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Text(d.name, style: context.type.body),
                      ),
                    ),
                    // Matched BY INDEX, not by label: two columns may legally
                    // share a label, and the option id is what `_pick` writes.
                    for (int i = 0; i < d.options.length; i++)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Center(
                            child: _GridCell(
                              label: '${d.name}, ${d.options[i].label}',
                              checked: selected.contains(d.options[i].id),
                              multi: multi,
                              onTap: onTap == null
                                  ? null
                                  : () => onTap!(d, d.options[i]),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One intersection of a [_GridMatrix]: a radio or checkbox with no visible
/// label of its own - the row and the column header say what it means, so
/// [label] ("row, column") says it to a screen reader.
class _GridCell extends StatefulWidget {
  final String label;
  final bool checked;
  final bool multi;
  final VoidCallback? onTap;

  const _GridCell({
    required this.label,
    required this.checked,
    required this.multi,
    this.onTap,
  });

  @override
  State<_GridCell> createState() => _GridCellState();
}

class _GridCellState extends State<_GridCell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool on = widget.checked;
    // Same semantics as `_Option`: the tap lives on the node because the
    // detector's own is excluded, and a radio is a radio to a reader.
    return Semantics(
      label: widget.label,
      checked: on,
      enabled: widget.onTap != null,
      inMutuallyExclusiveGroup: !widget.multi,
      onTap: widget.onTap,
      child: ExcludeSemantics(
        child: MouseRegion(
          cursor: widget.onTap == null
              ? MouseCursor.defer
              : SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            // The whole cell is the target, not just the 20px mark, so a
            // candidate does not have to hit a small circle to answer.
            behavior: HitTestBehavior.opaque,
            // Same tokens, radius and selected tint as `_ScalePoint` and
            // `_Option`: a grid cell is the same control in a different
            // geometry, so it must not read as a different design.
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              constraints: const BoxConstraints(minHeight: 44),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? t.primarySubtle.o(.5) : t.bgApp,
                borderRadius: Radii.option,
                border: Border.all(
                  width: 1.5,
                  color: on
                      ? t.primary
                      : (_hover && widget.onTap != null
                            ? t.borderHover
                            : t.border),
                ),
              ),
              child: Icon(
                widget.multi
                    ? (on ? Icons.check_box : Icons.check_box_outline_blank)
                    : (on
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked),
                size: 20,
                color: on ? t.primary : t.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A LINEAR SCALE DRAWN AS A SCALE, mirroring `form_preview._scale`.
///
/// WHY IT IS NOT A ROW OF BOXES. It was: N equal-width bordered cells, which is
/// the same geometry as a row of choice boxes and the same geometry a `rating`
/// used before stars - so a linear scale read as "pick one of these buttons"
/// rather than as a graded range, and Form Studio previewed something the
/// candidate never saw. Reported as "Linear scale should look like it and not
/// boxes", and correctly: nothing about the old control said the points were
/// ORDERED, which is the entire meaning of a scale.
///
/// WHAT MAKES IT READ AS A SCALE. One continuous track behind the points, so the
/// range is a line rather than N separate targets; a mark per point sitting ON
/// that track; the numbers above it; and the examiner's END LABELS at the two
/// ends, which is where the low and high ends of the range are actually named.
/// Selecting fills the track up to the chosen point, so the answer's POSITION in
/// the range is visible at a glance instead of being one highlighted box.
///
/// THE STORED ANSWER IS UNCHANGED - exactly one option, the one whose label is
/// the chosen point, written by the same `onTap`. Only the drawing differs, so
/// the answer key, the mark arithmetic and every admin screen are untouched.
class _ScaleRow extends StatelessWidget {
  final QDimension dimension;
  final List<String> selected;
  final void Function(QOption)? onTap;

  /// The names of the two ends of the range, when the examiner wrote them.
  ///
  /// Authored as `scale_min_label`/`scale_max_label` in the designer, and
  /// carried to the candidate on the question's own description as the
  /// "Scale: 1 = Unsure, 5 = Certain" legend the publish path composes
  /// (`studio_form._item_spec`). They are parsed back out of it rather than
  /// added to the wire: the legend is what the QWeb portal runner shows, and it
  /// renders no scale control at all, so removing it would leave those
  /// candidates with no idea what the ends mean.
  final String minLabel;
  final String maxLabel;

  const _ScaleRow({
    required this.dimension,
    required this.selected,
    this.onTap,
    this.minLabel = '',
    this.maxLabel = '',
    super.key,
  });

  // ONE SOURCE FOR THE GEOMETRY. The track is drawn by this widget and the
  // marks by [_ScalePoint], so a mark that computed its own offset would drift
  // off the line the moment either changed. The marks are POSITIONED against
  // these rather than laid out in a column: a column's height depends on the
  // label's text metrics, so it overflowed its box by a pixel at the default
  // scale and would overflow further at any larger accessibility text size.
  static const double rowHeight = 56;
  static const double trackTop = 40;
  static const double trackThickness = 4;

  /// The vertical centre of the track, which is what a mark centres itself on.
  static const double trackCentre = trackTop + trackThickness / 2;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final List<QOption> points = dimension.options;
    final int chosen = points.indexWhere(
      (QOption o) => selected.contains(o.id),
    );
    final bool enabled = onTap != null;

    return Semantics(
      // A track with marks on it carries little text, so the chosen point has
      // to be announced - and a scale is meaningless without its ends.
      label: chosen < 0
          ? 'Unanswered scale, ${points.length} points'
                '${minLabel.isEmpty && maxLabel.isEmpty ? '' : ', $minLabel to $maxLabel'}'
          : 'Point ${points[chosen].label} of ${points.length} selected',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // The track and the marks, in ONE stack so the line runs behind the
          // points rather than between them. A Row of cells cannot do this -
          // that is what made the old control read as separate boxes.
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              // Each point owns an equal slice and sits at its centre, so the
              // marks are evenly spaced and the track spans mark-to-mark.
              final double slice = c.maxWidth / points.length;
              final double inset = slice / 2;
              return SizedBox(
                height: rowHeight,
                child: Stack(
                  children: <Widget>[
                    // The unfilled range.
                    Positioned(
                      key: const Key('scale-track'),
                      left: inset,
                      right: inset,
                      top: trackTop,
                      child: Container(
                        height: trackThickness,
                        decoration: BoxDecoration(
                          color: t.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    // Filled up to the answer, so how FAR along the range the
                    // candidate landed is legible without reading the number.
                    if (chosen > 0)
                      Positioned(
                        key: const Key('scale-fill'),
                        left: inset,
                        width: slice * chosen,
                        top: trackTop,
                        child: Container(
                          height: trackThickness,
                          decoration: BoxDecoration(
                            color: t.primary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    for (int i = 0; i < points.length; i++)
                      Positioned(
                        left: slice * i,
                        width: slice,
                        top: 0,
                        bottom: 0,
                        child: _ScalePoint(
                          label: points[i].label,
                          checked: i == chosen,
                          // Every point up to the answer sits on the filled
                          // part of the track, so its mark has to be tinted
                          // too or the line appears to pass through gaps.
                          passed: chosen >= 0 && i < chosen,
                          onTap: enabled ? () => onTap!(points[i]) : null,
                          tokens: t,
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          // THE ENDS OF THE RANGE, NAMED. Without these a 1-7 scale is seven
          // numbers and the candidate has to guess which end is good.
          if (minLabel.isNotEmpty || maxLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      minLabel,
                      style: context.type.small.copyWith(color: t.textMuted),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      maxLabel,
                      textAlign: TextAlign.right,
                      style: context.type.small.copyWith(color: t.textMuted),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A rating drawn as CUMULATIVE stars, mirroring `form_preview._rating`.
///
/// WHY IT IS NOT A [_ScaleRow]. Both kinds rendered through that one widget, so
/// a rating and a linear scale were pixel-identical on the candidate's screen
/// while Form Studio previewed them as different controls - reported as "UI of
/// Rating & Linear Scale is same and not true to their design", and correctly.
///
/// CUMULATIVE, not one-of-N, is the whole point of a star control: picking 4
/// fills stars 1-4. The stored answer is still exactly ONE option - the option
/// whose label is "4" - so the answer key, the mark arithmetic and every admin
/// screen are untouched. Only the drawing differs.
class _StarRow extends StatelessWidget {
  final QDimension dimension;
  final List<String> selected;
  final void Function(QOption)? onTap;

  const _StarRow({
    required this.dimension,
    required this.selected,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    // The chosen point's VALUE, which is what decides how many stars are lit.
    // Read from the selected option's label rather than its index: the options
    // are built from the authored range and a linear scale may not start at 1.
    final int value = dimension.options
        .where((QOption o) => selected.contains(o.id))
        .map((QOption o) => int.tryParse(o.label.trim()) ?? 0)
        .fold<int>(0, (int a, int b) => b > a ? b : a);

    return Semantics(
      // A row of icons carries no text, so the answer would be invisible to a
      // screen reader and to the accessibility tree the E2E driver walks.
      label: value == 0
          ? 'Not rated'
          : 'Rated $value of ${dimension.options.length}',
      child: Wrap(
        children: <Widget>[
          for (final QOption o in dimension.options)
            Builder(
              builder: (BuildContext context) {
                final int v = int.tryParse(o.label.trim()) ?? 0;
                final bool lit = v > 0 && v <= value;
                final VoidCallback? tap = onTap == null
                    ? null
                    : () => onTap!(o);
                // Each star is one pick of the stored answer, so it reads as
                // a radio - the tap on the node, the InkWell's own excluded.
                return Semantics(
                  label: '$v of ${dimension.options.length} stars',
                  checked: value > 0 && v == value,
                  enabled: tap != null,
                  inMutuallyExclusiveGroup: true,
                  onTap: tap,
                  child: ExcludeSemantics(
                    child: InkWell(
                      onTap: tap,
                      borderRadius: Radii.button,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          lit ? Icons.star : Icons.star_border,
                          size: 30,
                          color: lit ? t.primary : t.textMuted,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// One point of a [_ScaleRow]: its number, and a mark sitting on the track.
///
/// Not a bordered cell. The cell WAS the defect - a box per point is the same
/// shape as a row of choice boxes, so the control did not read as a range. The
/// number sits above a small round mark on the line, which is the same anatomy
/// the designer's own preview draws.
///
/// Both parts are POSITIONED against [_ScaleRow]'s track constants rather than
/// stacked in a column. A column's height is the sum of its children, so it
/// depended on the label's text metrics: it overflowed the row by a pixel at the
/// default text scale, and would have pushed the marks off the track entirely at
/// a larger accessibility size. Positioned, the mark is on the line whatever the
/// label does.
class _ScalePoint extends StatefulWidget {
  final String label;
  final bool checked;

  /// This point is below the chosen one, so it sits on the filled track.
  final bool passed;
  final VoidCallback? onTap;
  final AppTokens tokens;

  const _ScalePoint({
    required this.label,
    required this.checked,
    required this.tokens,
    this.passed = false,
    this.onTap,
  });

  @override
  State<_ScalePoint> createState() => _ScalePointState();
}

class _ScalePointState extends State<_ScalePoint> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = widget.tokens;
    final bool on = widget.checked;
    final bool lit = on || widget.passed;
    // The selected mark is wider so the answer is findable at a glance; the
    // rest stay small so the LINE is the dominant shape rather than the dots.
    final double size = on ? 20 : 14;
    return MouseRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        // The whole slice is the target, not the 14px mark - the same reason
        // the grid cell is opaque. A candidate must not have to hit a dot.
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: <Widget>[
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Text(
                widget.label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.type.body.copyWith(
                  color: on ? t.primary : t.textPrimary,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
            Positioned(
              top: _ScaleRow.trackCentre - size / 2,
              left: 0,
              right: 0,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  height: size,
                  width: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: lit ? t.primary : t.bgApp,
                    border: Border.all(
                      // A thick border on a filled circle reads as a ring, so
                      // the chosen point is a target rather than a bigger dot.
                      width: on ? 5 : 2,
                      color: lit
                          ? t.primary
                          : (_hover && widget.onTap != null
                                ? t.borderHover
                                : t.border),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `.opt` - one answer option. 52px minimum height, a 1.5px border that tints
/// on selection, and a marker whose SHAPE distinguishes the two modes: circular
/// for one-of-N, 5px-radius square for many-of-N.
class _Option extends StatefulWidget {
  final String label;
  final bool checked;
  final bool multi;
  final VoidCallback? onTap;

  const _Option({
    required this.label,
    required this.checked,
    required this.multi,
    this.onTap,
  });

  @override
  State<_Option> createState() => _OptionState();
}

class _OptionState extends State<_Option> with SingleTickerProviderStateMixin {
  bool _hover = false;

  /// Keyboard focus, drawn as a ring. Separate from [_hover] because a focused
  /// option and a hovered one are different states and must not be confusable:
  /// focus says "Space will pick THIS", hover says nothing at all.
  bool _focused = false;

  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: widget.checked ? 1 : 0,
  );

  @override
  void didUpdateWidget(covariant _Option old) {
    super.didUpdateWidget(old);
    // The only elastic motion in the system, reserved for confirming an answer
    // selection.
    if (widget.checked && !old.checked) _pop.forward(from: 0);
    if (!widget.checked && old.checked) _pop.value = 0;
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool on = widget.checked;
    final bool enabled = widget.onTap != null;

    // AN ANSWER OPTION WAS NOT A CONTROL, only a painted box with a tap
    // listener. Three consequences, all of them the same bug seen from
    // different sides:
    //
    //   * A screen reader announced the label as static text with no state, so
    //     a candidate could not tell a chosen option from an unchosen one, and
    //     nothing indicated it could be picked at all. The QWeb runner used
    //     real `<input type=radio|checkbox>` with a `<label for>`, which gets
    //     all of this from the browser.
    //   * `GestureDetector` takes no focus, so the options were unreachable by
    //     Tab. The exam could not be sat from a keyboard.
    //   * Single-select and multi-select were visually distinct (the glyph) and
    //     semantically identical, so "pick one" and "pick any" sounded the same.
    //
    // `FocusableActionDetector` supplies focus, the hover callback the old
    // `MouseRegion` provided, and Space/Enter activation through the default
    // `ActivateIntent` binding in `WidgetsApp`. `inMutuallyExclusiveGroup`
    // is what makes a reader say "radio button" rather than "checkbox".
    return Semantics(
      label: widget.label,
      checked: on,
      enabled: enabled,
      inMutuallyExclusiveGroup: !widget.multi,
      // `onTap` ON THE SEMANTICS NODE, not only on the GestureDetector below.
      //
      // The detector is wrapped in `ExcludeSemantics` so its label is not read
      // twice, and that also strips its semantic tap action - leaving a node a
      // reader could FOCUS and not ACTIVATE. VoiceOver and TalkBack both
      // activate through this action, so "double-tap to select" did nothing:
      // the option was reachable and unpickable, which is worse than being
      // unreachable because it looks like it should work.
      onTap: enabled ? widget.onTap : null,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onShowHoverHighlight: (bool h) => setState(() => _hover = h),
        onShowFocusHighlight: (bool f) => setState(() => _focused = f),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent _) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: ExcludeSemantics(
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              constraints: const BoxConstraints(minHeight: 52),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: on ? t.primarySubtle.o(.5) : t.bgApp,
                borderRadius: Radii.option,
                // FOCUS OUTRANKS SELECTION in the border, because a keyboard
                // user needs to know where they ARE more than what they picked
                // - the glyph and the fill already say what is picked. 2.5px
                // and the accent so the ring survives against both the plain
                // and the selected fill.
                border: Border.all(
                  width: _focused ? 2.5 : 1.5,
                  color: _focused
                      ? t.primary
                      : on
                      ? t.primary
                      : (_hover && enabled ? t.borderHover : t.border),
                ),
              ),
              child: Row(
                children: <Widget>[
                  ScaleTransition(
                    scale: TweenSequence<double>(<TweenSequenceItem<double>>[
                      TweenSequenceItem<double>(
                        tween: Tween<double>(begin: .7, end: 1.12),
                        weight: 60,
                      ),
                      TweenSequenceItem<double>(
                        tween: Tween<double>(begin: 1.12, end: 1),
                        weight: 40,
                      ),
                    ]).animate(_pop),
                    child: Container(
                      width: 19,
                      height: 19,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: on ? t.primary : t.bgApp,
                        border: Border.all(
                          width: 1.5,
                          color: on ? t.primary : t.border,
                        ),
                        borderRadius: widget.multi
                            ? const BorderRadius.all(Radius.circular(5))
                            : null,
                        shape: widget.multi
                            ? BoxShape.rectangle
                            : BoxShape.circle,
                      ),
                      child: on
                          ? Icon(
                              widget.multi ? Icons.check : Icons.circle,
                              size: widget.multi ? 13 : 8,
                              color: const Color(0xFFFFFFFF),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(widget.label, style: context.type.option),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A free-text answer field.
///
/// It owns its controller and writes through `saveAnswerQuiet`, so typing
/// never rebuilds the exam surface and the caret is never lost.
class _FreeText extends StatefulWidget {
  final AppStore store;
  final Attempt ev;
  final Question q;
  final Response r;
  final bool readOnly;
  final String eyebrow;
  final int rows;

  const _FreeText({
    required this.store,
    required this.ev,
    required this.q,
    required this.r,
    required this.readOnly,
    required this.eyebrow,
    this.rows = 8,
  });

  @override
  State<_FreeText> createState() => _FreeTextState();
}

class _FreeTextState extends State<_FreeText> {
  late final TextEditingController _c = TextEditingController(
    text: widget.r.justification,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Eyebrow(widget.eyebrow),
        const SizedBox(height: 6),
        TextField(
          controller: _c,
          readOnly: widget.readOnly,
          maxLines: widget.rows,
          minLines: widget.rows,
          style: context.type.body.copyWith(fontSize: 13.5, height: 1.55),
          cursorColor: t.primary,
          onChanged: (String v) {
            // No render. The value goes straight into the response.
            widget.store.saveAnswerQuiet(
              widget.ev.id,
              widget.q.id,
              widget.store
                  .responseFor(widget.ev, widget.q)
                  .copyWith(justification: v),
            );
          },
          // NO HINT TEXT in any box a candidate answers in (owner,
          // 2026-09-29): a placeholder is a suggestion of what to write.
          decoration: InputDecoration(
            filled: true,
            fillColor: t.bgApp,
            contentPadding: const EdgeInsets.all(12),
            border: OutlineInputBorder(
              borderRadius: Radii.option,
              borderSide: BorderSide(color: t.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: Radii.option,
              borderSide: BorderSide(color: t.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: Radii.option,
              borderSide: BorderSide(color: t.primary.o(.55)),
            ),
          ),
        ),
      ],
    );
  }
}

/// `.imglayout` - stimulus beside answer at 1.08fr / 1fr, collapsing to a
/// single stacked column under 900px.
class _ImgLayout extends StatelessWidget {
  final Widget stimulus;
  final Widget answer;

  const _ImgLayout({required this.stimulus, required this.answer});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) {
      if (c.maxWidth < 900) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[stimulus, const SizedBox(height: 22), answer],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(flex: 108, child: stimulus),
          const SizedBox(width: 22),
          Expanded(flex: 100, child: answer),
        ],
      );
    },
  );
}

/// Layout 3b: a rubric question that carries AXES.
///
/// A task template is drawn in the Form Studio editor, so an examiner authors
/// real multiple-choice items - "is the picture sharp?", "is it a real photo?"
/// - and generation keeps that structure. Those questions arrive as
/// subjective_rubric with dimensions attached, and used to render as a single
/// textarea: six distinct judgements collapsed into one prose box that no
/// per-component grader could mark axis by axis.
///
/// With no axes this is byte-for-byte the old free-text layout, so an ordinary
/// rubric question is untouched. With axes the candidate gets one picker per
/// axis and still gets the prose box, because a template that asks for a
/// reason wants the reason too.
class _RubricLayout extends StatelessWidget {
  final AppStore store;
  final Attempt ev;
  final Question q;
  final Response r;
  final bool readOnly;

  const _RubricLayout({
    required this.store,
    required this.ev,
    required this.q,
    required this.r,
    required this.readOnly,
  });

  @override
  Widget build(BuildContext context) {
    final Widget prose = _FreeText(
      store: store,
      ev: ev,
      q: q,
      r: r,
      readOnly: readOnly,
      eyebrow: q.dims.isEmpty ? 'Your answer' : 'Your reasoning',
      rows: q.dims.isEmpty ? 8 : 5,
    );

    final Widget answer = q.dims.isEmpty
        ? prose
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (int i = 0; i < q.dims.length; i++) ...<Widget>[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 18, bottom: 18),
                    child: Container(
                      height: 1,
                      color: context.tokens.borderSubtle,
                    ),
                  ),
                _Options(
                  store: store,
                  ev: ev,
                  q: q,
                  r: r,
                  readOnly: readOnly,
                  multi: false,
                  only: q.dims[i],
                ),
              ],
              const SizedBox(height: 18),
              prose,
            ],
          );

    if (q.images.isEmpty && q.videos.isEmpty) return answer;
    return _ImgLayout(stimulus: allMedia(q), answer: answer);
  }
}

/// Layout 4: Image A/B evaluation. Two zoomable slots on the left; one legended
/// dimension block per construction dimension on the right, then a
/// justification textarea.
class _ImageAbLayout extends StatelessWidget {
  final AppStore store;
  final Attempt ev;
  final Question q;
  final Response r;
  final bool readOnly;

  const _ImageAbLayout({
    required this.store,
    required this.ev,
    required this.q,
    required this.r,
    required this.readOnly,
  });

  @override
  Widget build(BuildContext context) => _ImgLayout(
    // `allMedia` RATHER THAN A BARE LOOP, so an A/B question with no plates
    // says so instead of rendering nothing.
    //
    // This was `for (final Asset a in q.images) StimulusPlate(...)`, and an
    // empty `images` made that loop produce an empty Column - no plate, no
    // caption, no warning. An image_ab question then looked exactly like an
    // ordinary six-axis question, so a reviewer had no way to tell a draft
    // whose plates never rendered from one that was never supposed to have
    // any, and the Drafts tab showed a picture-less A/B draft as if it were
    // fine. Every other layout here already used `MissingStimulus` for this;
    // this branch was the one that did not.
    stimulus: allMedia(q),
    answer: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < q.dims.length; i++) ...<Widget>[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 18),
              child: Container(height: 1, color: context.tokens.borderSubtle),
            ),
          _Options(
            store: store,
            ev: ev,
            q: q,
            r: r,
            readOnly: readOnly,
            multi: false,
            only: q.dims[i],
          ),
        ],
        // ONLY WHEN THE EXAMINER ASKED FOR IT.
        //
        // The box used to be unconditional, on the argument that the
        // justification is part of an image A/B question rather than a setting.
        // That is no longer true: Form Studio's "Require justification" switch
        // decides it per question, and the server sends the answer as
        // `requiresJustification`.
        //
        // Hiding it is the honest thing, not a shortcut. The judge marks prose
        // against the question's answer rationale, and with the switch off
        // there is no rationale - so a box shown anyway is collected, never
        // read, and worth nothing, while a box of its own implies a mark of
        // its own. That spends the candidate's remaining minutes on the one
        // part of the paper where they cannot gain anything.
        if (q.requiresJustification) ...<Widget>[
          const SizedBox(height: 8),
          _FreeText(
            store: store,
            ev: ev,
            q: q,
            r: r,
            readOnly: readOnly,
            // The box only exists when it is required; the label says so,
            // because the box itself carries no hint text.
            eyebrow: 'Justification (required)',
            rows: 5,
          ),
        ],
      ],
    ),
  );
}

/// Layout 5: Image prompt. The source plates, the defect dimension, then the
/// prompt field.
class _ImagePromptLayout extends StatelessWidget {
  final AppStore store;
  final Attempt ev;
  final Question q;
  final Response r;
  final bool readOnly;

  const _ImagePromptLayout({
    required this.store,
    required this.ev,
    required this.q,
    required this.r,
    required this.readOnly,
  });

  @override
  Widget build(BuildContext context) => _ImgLayout(
    // EVERY plate. The transformation form of this type carries two - a
    // `reference` and an `output` - and the candidate writes the prompt that
    // turns one into the other, so being shown only the first made the
    // question unanswerable. `allMedia` also covers the clip case that a
    // rendered-image-only check used to miss.
    stimulus: allMedia(q),
    answer: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _Options(
          store: store,
          ev: ev,
          q: q,
          r: r,
          readOnly: readOnly,
          multi: false,
        ),
        const SizedBox(height: 8),
        _FreeText(
          store: store,
          ev: ev,
          q: q,
          r: r,
          readOnly: readOnly,
          eyebrow: 'Your prompt',
          rows: 7,
        ),
      ],
    ),
  );
}

/// Layout 6: Video prompt. The clip slots, the rating axes when the question
/// carries any, then a single prompt field.
class _VideoPromptLayout extends StatelessWidget {
  final AppStore store;
  final Attempt ev;
  final Question q;
  final Response r;
  final bool readOnly;

  const _VideoPromptLayout({
    required this.store,
    required this.ev,
    required this.q,
    required this.r,
    required this.readOnly,
  });

  @override
  Widget build(BuildContext context) => _ImgLayout(
    // `allMedia` RATHER THAN A BARE LOOP OVER `q.videos`, for two reasons the
    // loop got wrong:
    //
    //   * A video_prompt whose clip never rendered - unset, still generating,
    //     or a dead URL - produced an EMPTY Column. The candidate saw a blank
    //     space where the stimulus should be, with no indication anything was
    //     missing, and was asked to write a prompt about it. `allMedia` returns
    //     `MissingStimulus` for an empty set, which says so.
    //   * It ignored `q.images` entirely, so the reference/output pair with a
    //     STILL reference and a CLIP output showed only the clip - asking the
    //     candidate to describe a transformation from something never shown.
    //
    // Captions are preserved, and they are what carry which plate is the
    // reference and which the output. `mediaPlates` orders clips before stills,
    // so a mixed pair can read output-first; the labels remain the authority,
    // and this now matches `_ImagePromptLayout` exactly rather than having its
    // own rules.
    stimulus: allMedia(q),
    answer: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // A video question CAN carry rating axes, and this layout rendered no
        // option control for them at all. Unlike the labelling type there is no
        // server-side gate, so the answer saved cleanly with every axis
        // unanswered and scored zero on it - a silent loss of marks with no
        // symptom on either side.
        if (q.dims.isNotEmpty) ...<Widget>[
          _Options(
            store: store,
            ev: ev,
            q: q,
            r: r,
            readOnly: readOnly,
            multi: false,
          ),
          const SizedBox(height: 16),
        ],
        _FreeText(
          store: store,
          ev: ev,
          q: q,
          r: r,
          readOnly: readOnly,
          eyebrow: 'Your prompt',
          rows: 8,
        ),
      ],
    ),
  );
}

/// Layout 7: Image labelling. One zoomable slot with the numbered overlay, and
/// one text input per box, paginated at 8 a page.
///
/// The live "n / m labelled" counter is the piece that justifies the local
/// state: it must stay truthful while the candidate types, and it cannot cost
/// a rebuild of the surface.
class _ImageLabelLayout extends StatefulWidget {
  final AppStore store;
  final Attempt ev;
  final Question q;
  final Response r;
  final bool readOnly;

  const _ImageLabelLayout({
    required this.store,
    required this.ev,
    required this.q,
    required this.r,
    required this.readOnly,
  });

  @override
  State<_ImageLabelLayout> createState() => _ImageLabelLayoutState();
}

class _ImageLabelLayoutState extends State<_ImageLabelLayout> {
  static const int pageSize = 8;

  int _page = 1;
  late Map<int, String> _labels = Map<int, String>.from(
    widget.r.labels ?? const <int, String>{},
  );
  final Map<int, TextEditingController> _controllers =
      <int, TextEditingController>{};

  // The numbers the SERVER asked about, not the answer key.
  //
  // This read `widget.q.boxKey.keys`, and `boxKey` is the marking scheme - the
  // exam route correctly never sends it. So `_boxes` was always empty: no
  // inputs, no pager, and a counter reading "0 / 0 labelled" under a plate the
  // candidate was being asked to label.
  List<int> get _boxes => widget.q.labelBoxes;

  int get _pageCount =>
      _boxes.isEmpty ? 1 : ((_boxes.length - 1) ~/ pageSize) + 1;

  int get _filled =>
      _labels.values.where((String v) => v.trim().isNotEmpty).length;

  TextEditingController _ctl(int n) => _controllers.putIfAbsent(
    n,
    () => TextEditingController(text: _labels[n] ?? ''),
  );

  @override
  void dispose() {
    for (final TextEditingController c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _write(int n, String v) {
    // Only the counter re-renders. The store write is silent.
    _labels = <int, String>{..._labels, n: v};
    widget.store.saveAnswerQuiet(
      widget.ev.id,
      widget.q.id,
      widget.store.responseFor(widget.ev, widget.q).copyWith(labels: _labels),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final int from = (_page - 1) * pageSize;
    final int to = (from + pageSize).clamp(0, _boxes.length);
    final List<int> shown = _boxes.sublist(from.clamp(0, _boxes.length), to);

    // The stimulus is the MARKED plate - the `single` slot. Picking it by slot
    // rather than by position keeps a mis-seeded question honest: wire order is
    // not a contract, and a question that arrived carrying a spare asset would
    // otherwise render whichever one happened to sort first. The fall back to
    // the first asset covers a payload that omits the slot.
    final Asset? rawMarked =
        widget.q.images.where((Asset a) => a.slot == 'single').firstOrNull ??
        (widget.q.images.isEmpty ? null : widget.q.images.first);

    // The ANNOTATED plate only when the server's one overlay is the baked
    // picture: it then sends `annotated_url` and no region geometry
    // (services/labelling.label_overlay, mode baked). The overlay is burned in
    // server-side,
    // so the candidate can see which region is "box 3" - without it they get an
    // unmarked photograph and numbered inputs that refer to nothing.
    //
    // NEVER BOTH OVERLAYS: with region geometry the client draws the boxes
    // itself, and the baked bitmap on top would show a second numbering
    // (q1170 showed 4 drawn panels over 17 baked markers). Same rule as
    // [mediaPlates].
    final bool baked =
        _boxes.isNotEmpty &&
        (rawMarked?.regions.isEmpty ?? true) &&
        (rawMarked?.annotatedUrl ?? '').isNotEmpty;
    final Asset? marked = rawMarked == null
        ? null
        : (baked ? rawMarked.copyWith(url: rawMarked.annotatedUrl) : rawMarked);

    // ARE THERE ACTUALLY MARKERS ON THIS PICTURE? Two independent channels can
    // put them there - the overlay baked in by the media route, and the
    // client-drawn one `_assetsWithBoxes` builds from per-marker geometry -
    // and the server sends neither for a planted-defect question (the markers
    // would sit on the defects, so they are the answer key). The caption
    // promises "the numbered overlay" only when there is one.
    final bool hasMarkers = baked || (rawMarked?.regions.isNotEmpty ?? false);

    return _ImgLayout(
      stimulus: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (marked == null)
            const MissingStimulus()
          else
            StimulusPlate(
              asset: marked,
              caption: marked.label,
              showRegions: true,
            ),
          const SizedBox(height: 8),
          Text(
            hasMarkers
                ? 'Click the image to zoom and pan. The numbered overlay '
                      'marks each region you need to name.'
                : 'Click the image to zoom and pan. This picture carries no '
                      'numbered markers - name each region the question asks '
                      'about, one per box below.',
            style: context.type.tiny.copyWith(height: 1.45),
          ),
        ],
      ),
      // NO BOXES: a single free-text answer, matching the portal's fallback.
      //
      // Detection can legitimately come back empty, and the module then serves
      // the question anyway. Rendering an empty box list leaves the candidate
      // with nothing to type into, and `_record_response` REFUSES an image_label
      // answer whose justification is blank - so the question becomes
      // unanswerable and the attempt cannot be completed.
      answer: _LabelAnswer(
        // The rating axes, when this question carries any. `_record_response`
        // REFUSES an image_label answer that has dimensions and no selected
        // option - it returns 422 `incomplete_answer` - so without a control
        // for them the candidate could type every label correctly and still
        // never submit the question.
        dimensions: widget.q.dims.isEmpty
            ? null
            : _Options(
                store: widget.store,
                ev: widget.ev,
                q: widget.q,
                r: widget.store.responseFor(widget.ev, widget.q),
                readOnly: widget.readOnly,
                multi: false,
              ),
        child: _boxes.isEmpty
            ? _FreeText(
                store: widget.store,
                ev: widget.ev,
                q: widget.q,
                r: widget.store.responseFor(widget.ev, widget.q),
                readOnly: widget.readOnly,
                eyebrow: 'Your labels',
                rows: 8,
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Eyebrow('Label each numbered box'),
                      const Spacer(),
                      Text(
                        '$_filled / ${_boxes.length} labelled',
                        style: context.type.monoSmall.copyWith(
                          fontSize: 11.5,
                          color: t.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  for (final int n in shown)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: _LabelRow(
                        number: n,
                        controller: _ctl(n),
                        readOnly: widget.readOnly,
                        onChanged: (String v) => _write(n, v),
                      ),
                    ),
                  if (_pageCount > 1) ...<Widget>[
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        _PagerBtn(
                          label: 'Prev',
                          onPressed: _page > 1
                              ? () => setState(() => _page--)
                              : null,
                        ),
                        const SizedBox(width: 9),
                        Text(
                          'Boxes ${from + 1}-$to of ${_boxes.length}',
                          style: context.type.small,
                        ),
                        const SizedBox(width: 9),
                        _PagerBtn(
                          label: 'Next',
                          onPressed: _page < _pageCount
                              ? () => setState(() => _page++)
                              : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // A paginated form invites the fear that only the visible
                    // page is kept.
                    Text(
                      'Every page is submitted, not just this one.',
                      style: context.type.tiny,
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

/// The labelling answer area, with the question's rating axes above it.
///
/// A tiny wrapper rather than an inline `if`, because the box list is one
/// expression built two ways and threading a conditional prefix through both
/// branches duplicates it.
class _LabelAnswer extends StatelessWidget {
  final Widget? dimensions;
  final Widget child;

  const _LabelAnswer({required this.dimensions, required this.child});

  @override
  Widget build(BuildContext context) {
    if (dimensions == null) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[dimensions!, const SizedBox(height: 16), child],
    );
  }
}

/// `.lrow` - one labelling row. The container border tints when its inner
/// input takes focus.
class _LabelRow extends StatefulWidget {
  final int number;
  final TextEditingController controller;
  final bool readOnly;
  final ValueChanged<String> onChanged;

  const _LabelRow({
    required this.number,
    required this.controller,
    required this.readOnly,
    required this.onChanged,
  });

  @override
  State<_LabelRow> createState() => _LabelRowState();
}

class _LabelRowState extends State<_LabelRow> {
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() => _focused = _focus.hasFocus));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: t.bgApp,
        borderRadius: const BorderRadius.all(Radius.circular(9)),
        border: Border.all(color: _focused ? t.primary.o(.6) : t.border),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 44,
            child: Text(
              'BOX ${widget.number}',
              style: context.type.monoSmall.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: .66,
                color: t.textMuted,
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: SizedBox(
              height: 30,
              child: TextField(
                controller: widget.controller,
                focusNode: _focus,
                readOnly: widget.readOnly,
                onChanged: widget.onChanged,
                style: context.type.body,
                cursorColor: t.primary,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: t.bgApp,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 6,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: Radii.buttonSm,
                    borderSide: BorderSide(color: t.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: Radii.buttonSm,
                    borderSide: BorderSide(color: t.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: Radii.buttonSm,
                    borderSide: BorderSide(color: t.primary.o(.55)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PagerBtn extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const _PagerBtn({required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool on = onPressed != null;
    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
      child: GestureDetector(
        onTap: onPressed,
        child: Opacity(
          opacity: on ? 1 : .42,
          child: Container(
            height: 27,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.bgApp,
              borderRadius: Radii.buttonSm,
              border: Border.all(color: t.border),
            ),
            child: Text(
              label,
              style: context.type.button.copyWith(fontSize: 11.5),
            ),
          ),
        ),
      ),
    );
  }
}
