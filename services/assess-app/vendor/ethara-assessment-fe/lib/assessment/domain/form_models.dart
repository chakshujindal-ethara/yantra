// Form Studio's domain: a form, its sections, and the items on them.
//
// Kept apart from `models.dart` deliberately: the assessment models mirror
// what `/api/v1/...` serves today, while these describe a feature whose
// backend ships in a later phase. The JSON shapes here are the contract that
// backend will implement, so the store swap is a data-source change and not a
// remodel.
//
// Everything is MUTABLE. The designer edits one working object in place and
// repaints; copy-on-write buys nothing here because exactly one screen owns
// the object while it is being edited.

// LabelRegion only: the numbered fractional rect the exam stimuli already
// use. Sharing the type is what lets Form Studio reuse the interactive
// overlay widget instead of forking a second region model.
import 'models.dart' show LabelRegion;
import 'transcription.dart';

/// What one item on a form is.
///
/// The answer-collecting kinds come first; `textBlock`, `imageBlock` and
/// `videoBlock` only present content - which is why [isQuestion] exists and the
/// preview never validates a block as "required".
///
/// WHAT IS DELIBERATELY ABSENT. `date`, `time` and `fileUpload` were offered by
/// the designer and are gone. None of the three is a gradeable question on this
/// platform: `_item_spec` has no question-type mapping for an upload at all,
/// and a date or a time is a single literal with no answer key, no rubric and
/// nothing for the grader to mark - so an examiner could author one, publish it,
/// and the candidate's answer would count for nothing with no warning anywhere.
/// Two live items used them (form 12's refund-date and VIP-response-time
/// questions); [parse] degrades them to [shortAnswer], which is what the
/// candidate was effectively answering already - free text - except now it is
/// visibly free text that a rubric can mark.
enum FormItemKind {
  shortAnswer,
  paragraph,
  multipleChoice,
  checkboxes,
  dropdown,
  linearScale,
  rating,
  choiceGrid,
  checkboxGrid,
  textBlock,
  imageBlock,
  videoBlock,

  /// TRANSCRIPTION: the candidate hears a clip and types what is said, then
  /// answers the clip's category, sound characteristics and speakers - the
  /// Strix transcription task. The item OWNS its clip ([FormItem.mediaUrl],
  /// always audio), unlike an Audio block that rides along with the next
  /// question. [FormItem.goldenAnswer] is the correct transcription and
  /// [FormItem.goldenClip] the correct clip answers; the LLM judge marks
  /// against both with the client's critical/minor rule.
  transcription,
  comparePair,
  imageAnnotation,

  /// PROMPT WRITING: the candidate is shown an image or clip - or a
  /// reference -> output PAIR - and writes the text-to-image / text-to-video
  /// prompt that would produce it.
  ///
  /// ONE kind for both media, not two, because `image_prompt` and
  /// `video_prompt` differ only in the medium the prompt has to produce -
  /// `constants.TASK_PRIMITIVE_TO_QUESTION_TYPE` says as much on the server.
  /// Which of the two a form emits is decided from the attached media, the
  /// same way `_item_spec` already tells an image block from a video one.
  ///
  /// Carries no fields of its own: [FormItem.mediaUrl] is the single or
  /// REFERENCE plate, [FormItem.mediaUrlB] the optional OUTPUT plate,
  /// [FormItem.options] the optional rating axes the exam layout renders above
  /// the prompt box, and [FormItem.goldenAnswer] the model prompt the judge
  /// grades against.
  promptWriting,
}

extension FormItemKindX on FormItemKind {
  bool get isQuestion => switch (this) {
    FormItemKind.textBlock ||
    FormItemKind.imageBlock ||
    FormItemKind.videoBlock => false,
    _ => true,
  };

  /// Whether this kind carries an editable option list.
  ///
  /// `imageBlock`/`videoBlock` are here for the same reason `comparePair` is:
  /// the option list is what TURNS the block into a question (see
  /// [FormItem.isAnswerable]) - an empty one just means it stays decorative.
  bool get hasOptions => switch (this) {
    FormItemKind.multipleChoice ||
    FormItemKind.checkboxes ||
    FormItemKind.dropdown ||
    FormItemKind.comparePair ||
    FormItemKind.imageBlock ||
    FormItemKind.videoBlock ||
    // Prompt writing's options are the OPTIONAL rating axes the exam layout
    // draws above the prompt box. Unlike the kinds above, an empty list does
    // not make it decorative - the written prompt is the answer either way,
    // which is why it stays out of `FormItem.isAnswerable`'s options-gated
    // list.
    FormItemKind.promptWriting => true,
    _ => false,
  };

  bool get isGrid => switch (this) {
    FormItemKind.choiceGrid || FormItemKind.checkboxGrid => true,
    _ => false,
  };

  String get label => switch (this) {
    FormItemKind.shortAnswer => 'Short answer',
    FormItemKind.paragraph => 'Paragraph',
    FormItemKind.multipleChoice => 'Multiple choice',
    FormItemKind.checkboxes => 'Checkboxes',
    FormItemKind.dropdown => 'Dropdown',
    FormItemKind.linearScale => 'Linear scale',
    FormItemKind.rating => 'Rating',
    FormItemKind.choiceGrid => 'Multiple choice grid',
    FormItemKind.checkboxGrid => 'Checkbox grid',
    FormItemKind.textBlock => 'Title and description',
    FormItemKind.imageBlock => 'Image',
    // The kind string stays `videoBlock` on the wire. An audio block is a
    // `videoBlock` with `media_kind: 'audio'`; the designer labels it by the
    // item, not the kind (`formItemLabel` in `form_item_editor.dart`).
    FormItemKind.videoBlock => 'Video',
    FormItemKind.transcription => 'Transcription',
    FormItemKind.comparePair => 'Side-by-side comparison',
    FormItemKind.imageAnnotation => 'Image annotation',
    FormItemKind.promptWriting => 'Prompt writing',
  };

  /// RETIRED KINDS, and what a stored one becomes.
  ///
  /// `date`, `time` and `fileUpload` were removable precisely because the
  /// fallback is honest rather than lossy: all three collected a single
  /// unmarkable value, so reading one back as [shortAnswer] keeps the
  /// examiner's question text, its help, its required flag and its position -
  /// everything except a control that could never be scored. Named here rather
  /// than left to `orElse` so this is a decision on the record and not a typo
  /// silently landing on short answer.
  static const Map<String, FormItemKind> _retired = <String, FormItemKind>{
    'date': FormItemKind.shortAnswer,
    'time': FormItemKind.shortAnswer,
    'fileUpload': FormItemKind.shortAnswer,
  };

  static FormItemKind parse(String s) =>
      _retired[s] ??
      FormItemKind.values.firstWhere(
        (FormItemKind k) => k.name == s,
        orElse: () => FormItemKind.shortAnswer,
      );
}

/// One choice on a choice-carrying question.
///
/// A FORM IS LINEAR: NO BRANCHING, at the option level or the section level.
///
/// An option used to carry a `goTo` - drawn as a "Go to Section N" picker on
/// each option row - and a section carried one of its own. Both are gone, for
/// the same reason: NOTHING DOWNSTREAM READS THEM. The module has no `go_to`
/// anywhere, and the candidate's exam runner (`exam_screen.dart`) paginates one
/// QUESTION at a time and decides the last page by counting - there is no
/// concept of a section to jump to, let alone a conditional jump. So branching
/// steered the examiner's own preview and nothing else, which is worse than
/// absent: an examiner could design a routed form, watch the preview honour it,
/// and ship something the candidate sits straight through.
///
/// The fields are removed rather than hidden, and a stored `go_to` is IGNORED on
/// read. Leaving it in the model would keep a value nothing can display or
/// repair, and leaving it honoured would keep truncating forms.
class FormOption {
  FormOption(this.id, this.label, {this.correct = false});

  final String id;
  String label;

  /// ANSWER KEY: this option is a correct answer. Authored in the designer,
  /// used by scoring - never shown to a respondent.
  bool correct;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'label': label,
    if (correct) 'correct': true,
  };

  /// A stored `go_to` is dropped on read - see the class docstring.
  /// Minted when absent - see [FormItem.fromJson].
  static FormOption fromJson(Map<String, dynamic> j) => FormOption(
    _idOr(j['id'], 'opt'),
    (j['label'] ?? '').toString(),
    correct: j['correct'] == true,
  );
}

/// One item on a section: a question, or a content block.
class FormItem {
  FormItem(
    this.id,
    this.kind, {
    this.title = '',
    this.help = '',
    this.required = false,
    List<FormOption>? options,
    this.scaleMin = 1,
    this.scaleMax = 5,
    this.scaleMinLabel = '',
    this.scaleMaxLabel = '',
    this.ratingMax = 5,
    this.ratingGolden,
    this.scaleGolden,
    List<String>? rows,
    List<String>? columns,
    this.mediaUrl = '',
    this.mediaUrlB = '',
    this.mediaKind = '',
    this.fileAccept = '',
    this.fileMax = 1,
    List<LabelRegion>? regions,
    this.annotationCount = 0,
    this.goldenAnswer = '',
    Map<int, String>? goldenLabels,
    Map<int, Set<String>>? gridKey,
    this.multiSelect = false,
    this.requireJustification = false,
    this.transcriptionLanguage = 'hi',
    ClipAnswers? goldenClip,
  }) : goldenClip = goldenClip ?? ClipAnswers(),
       options = options ?? <FormOption>[],
       rows = rows ?? <String>[],
       columns = columns ?? <String>[],
       regions = regions ?? <LabelRegion>[],
       goldenLabels = goldenLabels ?? <int, String>{},
       gridKey = gridKey ?? <int, Set<String>>{};

  final String id;
  FormItemKind kind;
  String title;
  String help;
  bool required;

  // Choice kinds.
  //
  // NO PER-QUESTION OPTION SHUFFLE. `shuffle` reordered one question's choices
  // per respondent. It is gone in favour of the FORM-WIDE
  // [FormDef.shuffleQuestions], which reorders the QUESTIONS: two shuffle
  // toggles a few rows apart, one on the item and one behind the form's settings
  // gear, read as the same setting duplicated. A stored `shuffle` is ignored on
  // read, so a form authored with it serves its options in the authored order.
  final List<FormOption> options;
  // NO `allowOther`. A free-text "Other" choice is not one of the authored
  // options, so it can never match the answer key: every candidate who picks it
  // is marked wrong whatever they type. The publish path had always dropped it
  // with a warning ("not deliverable in an exam"), so the field only let an
  // examiner author something the server discarded. A stored `allow_other` is
  // ignored on read.

  // Linear scale.
  int scaleMin;
  int scaleMax;
  String scaleMinLabel;
  String scaleMaxLabel;

  /// Linear scale's answer key: the value in [scaleMin, scaleMax] a perfect
  /// response picks. Null means no key - respondents can still answer, but
  /// the item cannot be auto-scored, same as an empty [goldenAnswer].
  int? scaleGolden;

  // Rating.
  int ratingMax;

  /// Rating's answer key: the star count (1..[ratingMax]) a perfect response
  /// picks. Null means no key, same reasoning as [scaleGolden].
  int? ratingGolden;

  // Grids: the row prompts and the shared column choices.
  final List<String> rows;
  final List<String> columns;

  // Image / video blocks. A comparison block uses both: A left, B right.
  String mediaUrl;
  String mediaUrlB;

  /// What [mediaUrl] actually serves - `'image'`, `'video'`, or `''` for "not
  /// established".
  ///
  /// WHY THIS IS STORED RATHER THAN DERIVED. Every other reader works out the
  /// medium from the url, and for a Google Drive link that is impossible: a
  /// `/file/d/<id>/view` link has no extension and Drive serves an image and a
  /// video through the same url shape. Publish guessed "image", fetched the
  /// bytes into the question's image field, and the candidate got a dead 0:00
  /// player for a clip the examiner had every reason to think was attached.
  ///
  /// So the designer PROBES it - one `HEAD` when the link is pasted, reading the
  /// content type (`ApiClient.probeMediaKind`) - and records the answer here.
  /// `studio_form._item_media_is_video` reads it first and falls back to the
  /// url test for items authored before this field existed.
  ///
  /// Empty is the honest default and means "decide from the url". The probe
  /// fails closed: a CORS-blocked, timed-out or non-media response leaves this
  /// empty rather than writing a guess.
  ///
  /// Carried as `media_kind`, and it must appear in BOTH `toJson` and
  /// `fromJson` - duplicating an item copies it by JSON round trip, so a key
  /// missing from either side is silently lost.
  String mediaKind;

  // File upload.
  String fileAccept;
  int fileMax;

  // Image annotation: the numbered boxes the creator drew on [mediaUrl].
  // Numbers are stable for the item's life (deleting box 2 never renumbers
  // box 3) so a saved response can never point at a renamed marker.
  final List<LabelRegion> regions;

  // Image annotation, the common case: the picture arrives ALREADY MARKED
  // (a Q7r-style plate with its numbers baked in), so the creator only says
  // how many annotations it carries and respondents get that many numbered
  // answer fields. Drawing [regions] is the optional upgrade that makes the
  // markers tappable; when any are drawn they define the count instead.
  int annotationCount;

  /// The marker numbers this annotation item collects answers for: the drawn
  /// boxes when there are any, else 1..[annotationCount].
  List<int> get annotationNumbers => regions.isNotEmpty
      ? (regions.map((LabelRegion r) => r.number).toList()..sort())
      : List<int>.generate(annotationCount, (int i) => i + 1);

  // ── The answer key, authored in the designer ─────────────────────────────
  //
  // Mirrors the harness's solutions.json: objective kinds mark their correct
  // option(s) (FormOption.correct / gridKey), subjective kinds carry a GOLDEN
  // answer the LLM judge will grade worker text against. Stored on the form
  // document; the respondent runner must never serve any of it.

  /// Subjective golden answer (paragraph / short answer): the canonical
  /// answer, in the SOP's own words.
  String goldenAnswer;

  /// Annotation golden answers: marker number -> canonical description of
  /// what is wrong there (solutions.json's `answers` map, verbatim shape).
  final Map<int, String> goldenLabels;

  /// Grid answer key: row index -> the correct column label(s).
  ///
  /// A SET, not a single label, because a checkbox grid row is an MSQ: the
  /// respondent gets checkboxes and can tick several columns on one row, so a
  /// row where two columns are both right has to be able to say so. It could
  /// not before - the key held one label, and a respondent ticking both scored
  /// zero, because the mark is an exact-set match per row on the server
  /// (`response._dimension_marks`).
  ///
  /// [FormItemKind.choiceGrid] shares this field and is still single-valued:
  /// it draws radio buttons, so a set of two could never be matched. Publish
  /// refuses more than one there (`studio_form._item_spec`) rather than the type
  /// pretending it is impossible.
  final Map<int, Set<String>> gridKey;

  /// Whether THIS item collects an answer. Kind-level for everything except
  /// the comparison and the single media blocks, which are a question when
  /// they have options (a verdict to pick) and a display block when they
  /// have none (the video-prompt forms show a clip purely as context).
  bool get isAnswerable => switch (kind) {
    FormItemKind.comparePair ||
    FormItemKind.imageBlock ||
    FormItemKind.videoBlock => options.isNotEmpty,
    _ => kind.isQuestion,
  };

  /// imageBlock/videoBlock only: whether more than one option can be
  /// selected (checkboxes) instead of one (radio). Those two kinds have no
  /// separate "checkboxes" sibling the way multipleChoice/checkboxes do, so
  /// this flag carries the distinction instead.
  bool multiSelect;

  /// comparePair: does the candidate write a justification beside the verdict?
  ///
  /// A comparison is scorable on its VERDICT alone - the keyed side is marked in
  /// code - so the written half is the examiner's choice rather than part of the
  /// type. ON shows the box, requires an answer rationale to mark it against,
  /// and makes it worth a mark of its own; OFF hides it entirely and the
  /// question is worth its verdict axes.
  ///
  /// Carried to the server as `require_justification`, where publish enforces
  /// the pairing with [goldenAnswer] - see `studio_form._item_spec`. It must
  /// appear in BOTH `toJson` and `fromJson`: duplicating an item copies it by
  /// JSON round trip, so a key missing from either side is silently lost.
  bool requireJustification;

  /// Transcription: the language the clip is transcribed in ('hi' types
  /// Devanagari with Hindi typing; 'en' small English letters). Both this and
  /// [goldenClip] appear in `toJson` and `fromJson`, for the round-trip reason
  /// above.
  String transcriptionLanguage;

  /// Transcription: the correct category, characteristics and speakers, beside
  /// the correct transcription in [goldenAnswer].
  final ClipAnswers goldenClip;

  /// What the SERVER reads as this item's golden answer.
  ///
  /// `studio_form._item_spec` reads EVERY kind's key from `golden_answer`, and
  /// for a scale or a rating it requires a digit string inside the item's own
  /// range:
  ///
  ///     if not golden.isdigit() or not mn <= int(golden) <= mx:
  ///         problems.append("set the correct value (%s-%s) ...")
  ///
  /// The editor keeps those two keys as typed ints ([scaleGolden] /
  /// [ratingGolden]) because a picker over a numeric range is the right
  /// control - but a key that lived ONLY there was invisible to the server, so
  /// publishing a form with a rating question was refused with "set the
  /// correct value as the golden answer" however carefully the examiner had
  /// set it. This is what puts it on the wire where the server looks.
  String get _wireGoldenAnswer => switch (kind) {
    FormItemKind.linearScale => scaleGolden?.toString() ?? '',
    FormItemKind.rating => ratingGolden?.toString() ?? '',
    _ => goldenAnswer,
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'kind': kind.name,
    'title': title,
    'help': help,
    'required': required,
    if (kind.hasOptions)
      'options': options.map((FormOption o) => o.toJson()).toList(),
    if (kind == FormItemKind.imageBlock || kind == FormItemKind.videoBlock)
      'multi_select': multiSelect,
    if (kind == FormItemKind.comparePair)
      'require_justification': requireJustification,
    if (kind == FormItemKind.linearScale) ...<String, dynamic>{
      'scale_min': scaleMin,
      'scale_max': scaleMax,
      'scale_min_label': scaleMinLabel,
      'scale_max_label': scaleMaxLabel,
      if (scaleGolden != null) 'scale_golden': scaleGolden,
    },
    if (kind == FormItemKind.rating) ...<String, dynamic>{
      'rating_max': ratingMax,
      if (ratingGolden != null) 'rating_golden': ratingGolden,
    },
    if (kind.isGrid) ...<String, dynamic>{'rows': rows, 'columns': columns},
    if (mediaUrl.isNotEmpty) 'media_url': mediaUrl,
    if (mediaUrlB.isNotEmpty) 'media_url_b': mediaUrlB,
    if (mediaKind.isNotEmpty) 'media_kind': mediaKind,
    if (kind == FormItemKind.imageAnnotation) ...<String, dynamic>{
      'regions': regions.map((LabelRegion r) => r.toJson()).toList(),
      'annotation_count': annotationCount,
    },
    if (_wireGoldenAnswer.trim().isNotEmpty) 'golden_answer': _wireGoldenAnswer,
    if (goldenLabels.isNotEmpty)
      'golden_labels': goldenLabels.map(
        (int k, String v) => MapEntry<String, String>('$k', v),
      ),
    // Always a LIST on the wire, one column label per correct answer, even for
    // the single-valued choiceGrid. `studio_form._grid_row_key` accepts either
    // shape (a bare string is what every form authored before checkbox grids
    // went multi-select carries), so a one-element list needs no special case
    // and the two kinds keep one wire format.
    if (gridKey.isNotEmpty)
      'grid_key': gridKey.map(
        (int k, Set<String> v) =>
            MapEntry<String, List<String>>('$k', v.toList()),
      ),
    if (kind == FormItemKind.transcription) ...<String, dynamic>{
      'transcription_language': transcriptionLanguage,
      'golden_clip': goldenClip.toJson(),
    },
  };

  /// MINTED WHEN THE FILE DOES NOT CARRY ONE, and that is not cosmetic.
  ///
  /// An exported form written by hand, or by any tool that does not bother with
  /// ids, arrives with none - both of the real exports this was reported
  /// against had `id` absent on every single item. The designer keys each
  /// editor `ValueKey('item-\${it.id}')`, so every row got the SAME key.
  ///
  /// `debugChildrenHaveDuplicateKeys` is a DEBUG-ONLY assert. In a release
  /// build - which production is - duplicate keys do not throw: Flutter simply
  /// mis-matches elements, and one `State` ends up serving several items. Every
  /// per-item map inside that State then collides, which is how a Drive import
  /// scheduled for one question cancelled the one scheduled for the question
  /// before it, leaving all but the last stuck reading "Copying that Drive file
  /// into this app...".
  ///
  /// Ids only have to be unique within a session; the backend replaces them on
  /// first save, exactly as it does for an item created in the designer.
  static FormItem fromJson(Map<String, dynamic> j) {
    List<String> strs(Object? v) =>
        v is List ? v.map((Object? e) => e.toString()).toList() : <String>[];
    return FormItem(
      _idOr(j['id'], 'item'),
      FormItemKindX.parse((j['kind'] ?? '').toString()),
      title: (j['title'] ?? '').toString(),
      help: (j['help'] ?? '').toString(),
      required: j['required'] == true,
      options: j['options'] is List
          ? (j['options'] as List)
                .whereType<Map<String, dynamic>>()
                .map(FormOption.fromJson)
                .toList()
          : null,
      // A stored `shuffle` is dropped on read - see the field's own note above.
      scaleMin: j['scale_min'] is num ? (j['scale_min'] as num).toInt() : 1,
      scaleMax: j['scale_max'] is num ? (j['scale_max'] as num).toInt() : 5,
      scaleMinLabel: (j['scale_min_label'] ?? '').toString(),
      scaleMaxLabel: (j['scale_max_label'] ?? '').toString(),
      scaleGolden: j['scale_golden'] is num
          ? (j['scale_golden'] as num).toInt()
          // A form written before the typed key existed - or by the server,
          // which only ever speaks `golden_answer` - carries the scale's key
          // there as a digit string. Read it back so a round trip through
          // either side keeps the key.
          : int.tryParse((j['golden_answer'] ?? '').toString().trim()),
      ratingMax: j['rating_max'] is num ? (j['rating_max'] as num).toInt() : 5,
      ratingGolden: j['rating_golden'] is num
          ? (j['rating_golden'] as num).toInt()
          : int.tryParse((j['golden_answer'] ?? '').toString().trim()),
      rows: strs(j['rows']),
      columns: strs(j['columns']),
      mediaUrl: (j['media_url'] ?? '').toString(),
      mediaKind: (j['media_kind'] ?? '').toString(),
      mediaUrlB: (j['media_url_b'] ?? '').toString(),
      fileAccept: (j['file_accept'] ?? '').toString(),
      fileMax: j['file_max'] is num ? (j['file_max'] as num).toInt() : 1,
      regions: j['regions'] is List
          ? (j['regions'] as List)
                .whereType<Map<String, dynamic>>()
                .map(LabelRegion.fromJson)
                .where((LabelRegion r) => r.number > 0 && r.w > 0 && r.h > 0)
                .toList()
          : null,
      annotationCount: j['annotation_count'] is num
          ? (j['annotation_count'] as num).toInt().clamp(0, 99)
          : 0,
      goldenAnswer: (j['golden_answer'] ?? '').toString(),
      goldenLabels: _intKeyed(j['golden_labels']),
      gridKey: _intKeyedSets(j['grid_key']),
      multiSelect: j['multi_select'] == true,
      requireJustification: j['require_justification'] == true,
      transcriptionLanguage: j['transcription_language'] == 'en' ? 'en' : 'hi',
      goldenClip: j['golden_clip'] is Map
          ? ClipAnswers.fromJson(j['golden_clip'])
          : null,
    );
  }

  /// A `{"1": ["a", "b"]}` wire map as `{1: {"a", "b"}}`.
  ///
  /// Reads the LEGACY scalar shape too (`{"1": "a"}`), because that is what
  /// every form saved before checkbox grids went multi-select carries, and a
  /// form is loaded far more often than it is re-saved. Non-numeric keys and
  /// blank labels are dropped, matching [_intKeyed].
  static Map<int, Set<String>> _intKeyedSets(Object? raw) {
    if (raw is! Map) return <int, Set<String>>{};
    final Map<int, Set<String>> out = <int, Set<String>>{};
    raw.forEach((Object? k, Object? v) {
      final int? n = int.tryParse('$k');
      if (n == null) return;
      final Iterable<Object?> values = v is Iterable ? v : <Object?>[v];
      final Set<String> labels = values
          .map((Object? e) => (e ?? '').toString().trim())
          .where((String s) => s.isNotEmpty)
          .toSet();
      if (labels.isNotEmpty) out[n] = labels;
    });
    return out;
  }

  /// A `{"1": "text"}` wire map as `{1: "text"}`. Non-numeric keys dropped.
  static Map<int, String> _intKeyed(Object? raw) {
    if (raw is! Map) return <int, String>{};
    final Map<int, String> out = <int, String>{};
    raw.forEach((Object? k, Object? v) {
      final int? n = int.tryParse('$k');
      final String text = (v ?? '').toString();
      if (n != null && text.trim().isNotEmpty) out[n] = text;
    });
    return out;
  }
}

/// One page of the form. Respondents see one section at a time, in order;
/// an answered option may redirect (see [FormOption.goTo]).
///
/// A SECTION HAS NO DESTINATION OF ITS OWN. It used to carry a `goTo`, drawn
/// as an "After section N" picker offering "Continue to next section" /
/// "Submit form". That control was misleading in both directions: nothing
/// downstream read it (the module has no `go_to` anywhere, and the real exam
/// runner paginates per QUESTION and decides the last page by counting), so
/// the setting steered only the admin preview - and "Submit form" on a
/// non-final section made the preview end early, which read as the form being
/// broken. The candidate's flow is: Next through every question, Submit at the
/// end. Sections are grouping, not routing.
///
/// `go_to` on an incoming section is therefore IGNORED, not migrated: a
/// stored "@submit" from that picker would otherwise silently cut a form
/// short with no control left anywhere to see or repair it.
class FormSection {
  FormSection(
    this.id, {
    this.title = '',
    this.description = '',
    List<FormItem>? items,
  }) : items = items ?? <FormItem>[];

  final String id;
  String title;
  String description;
  final List<FormItem> items;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'description': description,
    'items': items.map((FormItem i) => i.toJson()).toList(),
  };

  /// Minted when absent, for the same reason as [FormItem.fromJson]: sections
  /// are keyed `ValueKey('sec-\${id}')` and would otherwise all share one.
  static FormSection fromJson(Map<String, dynamic> j) => FormSection(
    _idOr(j['id'], 'sec'),
    title: (j['title'] ?? '').toString(),
    description: (j['description'] ?? '').toString(),
    items: j['items'] is List
        ? (j['items'] as List)
              .whereType<Map<String, dynamic>>()
              .map(FormItem.fromJson)
              .toList()
        : null,
  );
}

/// A form: what Form Studio designs, and what a respondent will one day fill.
class FormDef {
  FormDef(
    this.id, {
    this.title = 'Untitled form',
    this.internalName = '',
    this.description = '',
    List<FormSection>? sections,
    this.published = false,
    this.shuffleQuestions = false,
    DateTime? updatedAt,
  }) : sections = sections ?? <FormSection>[],
       updatedAt = updatedAt ?? DateTime.now();

  final String id;

  /// The heading a RESPONDENT reads above the first question. Candidate-facing
  /// copy, and the only name the preview and the exam runner ever show.
  String title;

  /// What an OPERATOR calls this form in a list, when that has to differ from
  /// the heading candidates read.
  ///
  /// The designer seeds it from [title] because the two are usually the same
  /// string; this exists for the times they must not be - "Quality Assessment"
  /// to the candidate, "Q7r cohort 3 - retake" to the person who has to find
  /// it again next week. Editing it must never move the respondent heading,
  /// which is why it is a second field and not a rename.
  ///
  /// EMPTY IS THE WHOLE "not overridden" STATE - no companion flag, because a
  /// flag can disagree with the value it describes and then every reader has
  /// to pick which to believe. [displayTitle] is that decision, made once.
  String internalName;

  String description;
  final List<FormSection> sections;

  /// Publishing ships with the backend phase; every form is a draft until
  /// then. The field exists now so the list screen, the JSON contract and the
  /// eventual server agree on where the flag lives.
  bool published;

  /// FORM-WIDE question shuffle. When on, each candidate is served the
  /// questions in a random order (fixed for that candidate for the life of
  /// their sitting, the same way option shuffle is per-respondent). The
  /// DISPLAYED question number always counts 1..N in the order that candidate
  /// actually sees, so "Question 3" is their third question, not the third
  /// authored one. Distinct from [FormItem.shuffle], which reorders the
  /// choices WITHIN one question.
  bool shuffleQuestions;

  DateTime updatedAt;

  /// The name every ADMIN surface shows: the list, the search, the designer
  /// crumb and head, the delete confirmation, the export filename. Mirrors
  /// `etp.studio.form.display_title`, and exists for the same reason - one
  /// fallback expression instead of ten, so adding [internalName] could not
  /// leave a call site quietly reading the old field.
  ///
  /// The RESPONDENT view does not use this. `form_preview._formHeader` reads
  /// [title] directly, because an internal name must never reach a candidate.
  String get displayTitle => internalName.isNotEmpty
      ? internalName
      : (title.isEmpty ? 'Untitled form' : title);

  int get questionCount => sections
      .expand((FormSection s) => s.items)
      .where((FormItem i) => i.isAnswerable)
      .length;

  void touch() => updatedAt = DateTime.now();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    // ALWAYS EMITTED, like `title` and unlike `shuffle_questions`: this key is
    // how the server tells "no override" (empty) from "override cleared by the
    // operator" (also empty, but sent). Omitting it when empty would make a
    // cleared name indistinguishable from an absent one at the upsert, so the
    // old name would survive a clear.
    'internal_name': internalName,
    'description': description,
    'sections': sections.map((FormSection s) => s.toJson()).toList(),
    'published': published,
    if (shuffleQuestions) 'shuffle_questions': true,
    // UTC, with its `Z`: a local stamp has no zone and `fromJson` reads a
    // zone-less one as UTC, so an exported form would re-import 5h30 off.
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  static FormDef fromJson(Map<String, dynamic> j) => FormDef(
    (j['id'] ?? '').toString(),
    title: (j['title'] ?? '').toString(),
    internalName: (j['internal_name'] ?? '').toString(),
    description: (j['description'] ?? '').toString(),
    sections: j['sections'] is List
        ? (j['sections'] as List)
              .whereType<Map<String, dynamic>>()
              .map(FormSection.fromJson)
              .toList()
        : null,
    published: j['published'] == true,
    shuffleQuestions: j['shuffle_questions'] == true,
    updatedAt: _utcStamp(j['updated_at']),
  );
}

/// A wire stamp that names no zone, read as the UTC it is.
///
/// The forms route sends `write_date.isoformat()` - "2026-09-20T19:00:00",
/// UTC with no `Z` - and `DateTime.parse` takes a zone-less stamp as the
/// BROWSER's local time, which puts "Updated" 5h30 early in India. A stamp
/// that names its zone keeps it.
DateTime? _utcStamp(Object? raw) {
  final String s = (raw ?? '').toString().trim();
  if (s.isEmpty) return null;
  final bool zoned = RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(s);
  return DateTime.tryParse(zoned ? s : '${s}Z');
}

// ── Construction helpers ───────────────────────────────────────────────────
//
// Ids are minted client-side while the feature is local-only. They only have
// to be unique within one session; the backend will replace them with its own
// on first save, the same way every other record here got its id.

int _seq = 0;

/// [raw] as a non-empty id, minting one under [prefix] when the file omitted it.
///
/// Whitespace counts as absent: `"id": " "` is not an identifier, and letting
/// it through would reintroduce the duplicate-key collision it exists to stop.
String _idOr(Object? raw, String prefix) {
  final String id = (raw ?? '').toString().trim();
  return id.isEmpty ? formNewId(prefix) : id;
}

String formNewId(String prefix) =>
    '$prefix-${DateTime.now().millisecondsSinceEpoch}-${_seq++}';

/// A fresh option row, labelled by position the way a respondent will read it.
FormOption formNewOption(int position) =>
    FormOption(formNewId('opt'), 'Option ${position + 1}');

/// A fresh item of [kind], with the defaults the designer opens on.
FormItem formNewItem(FormItemKind kind) {
  final FormItem it = FormItem(formNewId('item'), kind);
  // A transcription's clip is always audio: the plate and the publish path
  // read the declared medium, so a link with no extension is still a clip.
  if (kind == FormItemKind.transcription) it.mediaKind = 'audio';
  // A comparison, or a single image/video block, starts with NO options: it
  // is a display until the creator adds one, and seeding one would silently
  // make it required-able (and, for the media blocks, a question at all).
  // Prompt writing is here for the adjacent reason: its options are the
  // OPTIONAL rating axes, and seeding one would put an unasked-for axis above
  // every prompt box.
  if (kind.hasOptions &&
      kind != FormItemKind.comparePair &&
      kind != FormItemKind.imageBlock &&
      kind != FormItemKind.videoBlock &&
      kind != FormItemKind.promptWriting) {
    // TWO, not one. `studio_form._options_of` refuses a choice question with
    // fewer than two options - "one option is not a choice" - so seeding a
    // single one handed the author a question that could never publish, and
    // said nothing about it until they pressed Send and got a refusal naming
    // a rule they had not broken on purpose. Two is the smallest shape that
    // IS a choice, so the designer now opens on something valid.
    //
    // The grid below already seeded two rows and two columns for the same
    // reason; the option list was the one that did not.
    it.options
      ..add(formNewOption(0))
      ..add(formNewOption(1));
  }
  if (kind.isGrid) {
    it.rows.addAll(<String>['Row 1', 'Row 2']);
    it.columns.addAll(<String>['Column 1', 'Column 2']);
  }
  return it;
}

FormSection formNewSection({String title = ''}) =>
    FormSection(formNewId('sec'), title: title);

// ── Duplicating and importing ──────────────────────────────────────────────

/// A deep copy of [src] with EVERY id newly minted - the form, its sections,
/// their items and every option.
///
/// WHY EVERY ID AND NOT JUST THE FORM'S. Item ids are not decoration: the
/// designer keys its text fields by item id, so two items sharing one make
/// Flutter share their edit state and typing in one appears in the other. They
/// also travel to the server - `publish_to_assessment` stamps
/// `source_ref = "form:<uid>#<item_id>"` - so duplicate ids across forms make
/// a published question untraceable to the item that produced it. Importing the
/// same document twice is the case that guarantees a collision.
FormDef formReminted(FormDef src, {String? title, String? internalName}) {
  final Map<String, dynamic> j = src.toJson();
  j['id'] = formNewId('form');
  if (title != null) j['title'] = title;
  // THE INTERNAL NAME IS HANDLED EXPLICITLY, not left to ride the round trip,
  // because a RENAME is what a duplicate is. `duplicateForm` copies a form as
  // "<name> (copy)" by passing `title`; carrying the source's internal name
  // over unchanged would give two rows that read IDENTICALLY in every admin
  // list - the operator-facing collision this function already prevents for
  // ids - and the copy is the row they are looking for. So a rename with no
  // internal name of its own clears the override and falls through to the new
  // title, while a re-mint that is not a rename (an import) keeps it.
  final bool renamed = title != null && title != src.title;
  j['internal_name'] = internalName ?? (renamed ? '' : src.internalName);
  for (final Object? s in (j['sections'] as List<dynamic>? ?? <dynamic>[])) {
    if (s is! Map) continue;
    s['id'] = formNewId('sec');
    for (final Object? it in (s['items'] as List<dynamic>? ?? <dynamic>[])) {
      if (it is! Map) continue;
      it['id'] = formNewId('item');
      for (final Object? o
          in (it['options'] as List<dynamic>? ?? <dynamic>[])) {
        if (o is Map) o['id'] = formNewId('opt');
      }
    }
  }
  return FormDef.fromJson(j);
}

/// What went wrong with an imported document, in words an examiner can act on.
class FormImportException implements Exception {
  const FormImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The largest document the SERVER will store, mirrored here so a too-big file
/// is refused with a clear reason instead of a 413 from `/forms/save`.
/// `studio_form.MAX_STRUCTURE_BYTES`.
const int kMaxFormStructureBytes = 512 * 1024;

/// Build a form from a decoded JSON document, ready to save.
///
/// TOLERANT ABOUT THE WRAPPER, STRICT ABOUT THE SHAPE. Accepts either a whole
/// form (what `FormDef.toJson` writes, so an export re-imports) or a bare
/// `sections` array, because that is the half people actually paste. Anything
/// else is refused by naming what was expected - an import that silently
/// produced an empty form would look like the feature not working.
///
/// Every id is re-minted, so importing the same file twice gives two
/// independent forms rather than one that overwrites the other.
FormDef formFromImportedJson(Object? decoded, {String fallbackTitle = ''}) {
  final Map<String, dynamic> doc;
  if (decoded is List) {
    // A bare sections array.
    doc = <String, dynamic>{'sections': decoded};
  } else if (decoded is Map<String, dynamic>) {
    doc = decoded;
  } else if (decoded is Map) {
    doc = decoded.cast<String, dynamic>();
  } else {
    throw const FormImportException(
      'That file is not a form: expected a JSON object with a "sections" '
      'list, or a bare list of sections.',
    );
  }

  final Object? sections = doc['sections'];
  if (sections is! List) {
    throw const FormImportException(
      'That file has no "sections" list, so there is no form in it.',
    );
  }
  if (sections.isEmpty) {
    throw const FormImportException(
      'That form has no sections, so there would be nothing to edit.',
    );
  }
  if (!sections.any((Object? s) => s is Map)) {
    throw const FormImportException(
      'The "sections" list does not contain any sections.',
    );
  }

  final String title = (doc['title'] ?? '').toString().trim();
  // The operator's name for the form travels with the file, and unlike
  // `published` it is safe to honour: it names a row in an admin list, it
  // reaches no candidate, and dropping it would silently rename an imported
  // form to its candidate-facing heading. Trimmed, so a file carrying "  "
  // imports as NOT overridden rather than as a blank-looking override.
  final String internalName = (doc['internal_name'] ?? '').toString().trim();
  final FormDef parsed = FormDef.fromJson(<String, dynamic>{
    ...doc,
    'internal_name': internalName,
    // Never trust an imported id: it could name a form that already exists,
    // and saving would then overwrite that one instead of adding this.
    'id': formNewId('form'),
    'title': title.isNotEmpty
        ? title
        : (fallbackTitle.trim().isNotEmpty
              ? fallbackTitle.trim()
              : 'Imported form'),
    // An import is always a draft: publishing is a decision, not a file
    // attribute, and honouring `published: true` here would put a form into
    // the exam pipeline because of what somebody wrote in a text file.
    'published': false,
  });
  // Both names passed explicitly: this re-mint is not a rename, so the
  // internal name has to survive it, and saying so here is cheaper than
  // relying on `formReminted`'s rename test to happen to read `title` as
  // unchanged.
  return formReminted(
    parsed,
    title: parsed.title,
    internalName: parsed.internalName,
  );
}

/// A new form as the designer first opens it: one section, one question.
FormDef formNewForm() => FormDef(
  formNewId('form'),
  sections: <FormSection>[
    FormSection(
      formNewId('sec'),
      items: <FormItem>[formNewItem(FormItemKind.multipleChoice)],
    ),
  ],
);

/// The bundled example: shows several kinds and a second section, so the first
/// visit to Form Studio demonstrates instead of explaining.
///
/// It used to demonstrate BRANCHING too - "All good" jumped to submit, the other
/// option opened a detail section. Both are gone with the feature (see
/// [FormOption]), and the answer key is marked on the verdict instead, which is
/// the construct that actually matters here: an example form that cannot be
/// scored teaches the wrong lesson.
FormDef formSample() {
  final FormSection basics = FormSection(
    'sec-sample-1',
    title: 'About Your Visit',
    description: 'Two quick questions before the detail.',
  );
  final FormSection detail = FormSection(
    'sec-sample-2',
    title: 'Tell us more',
    description: 'The detail behind the answers above.',
  );
  final FormItem verdict = FormItem(
    'item-sample-1',
    FormItemKind.multipleChoice,
    title: 'How did the visit go?',
    required: true,
    options: <FormOption>[
      FormOption('opt-sample-1', 'All good', correct: true),
      FormOption('opt-sample-2', 'Something went wrong'),
    ],
  );
  final FormItem team = FormItem(
    'item-sample-2',
    FormItemKind.dropdown,
    title: 'Which team did you meet?',
    options: <FormOption>[
      FormOption('opt-sample-3', 'Operations'),
      FormOption('opt-sample-4', 'Engineering'),
      FormOption('opt-sample-5', 'People'),
    ],
  );
  final FormItem story = FormItem(
    'item-sample-3',
    FormItemKind.paragraph,
    title: 'What happened?',
    help: 'As specific as you can - names, times, screens.',
    required: true,
  );
  final FormItem rate = FormItem(
    'item-sample-4',
    FormItemKind.linearScale,
    title: 'How severe was it?',
    scaleMin: 1,
    scaleMax: 5,
    scaleMinLabel: 'Cosmetic',
    scaleMaxLabel: 'Blocking',
  );
  basics.items.addAll(<FormItem>[verdict, team]);
  detail.items.addAll(<FormItem>[story, rate]);
  return FormDef(
    'form-sample',
    title: 'Visit Feedback (example)',
    description:
        'A bundled example form. Open it in the designer to see sections, '
        'branching and question kinds in use - or delete it and start clean.',
    sections: <FormSection>[basics, detail],
  );
}
