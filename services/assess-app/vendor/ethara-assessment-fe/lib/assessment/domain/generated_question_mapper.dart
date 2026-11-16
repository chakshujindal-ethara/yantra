// GENERATED QUESTION -> FORM STUDIO BLOCK.
//
// The model writes questions; Form Studio edits blocks. This file is the one
// place that translates between them, so "a generated question set opens in
// the Form Studio blocks" is a data mapping rather than a second, parallel
// editor built beside the first.
//
// WHY IT LIVES IN domain/ AND NOT A SCREEN. It is pure data in, pure data out
// - `Question` (what `/api/v1/drafts` and the bank serve) to `FormItem` (what
// `FormItemEditor` and `FormPreview` already know how to draw and edit). No
// widget, no BuildContext, no store. That is what lets any surface use it: the
// generator's draft review, a template preview, or a future "open this
// generated set in the designer" action, all from the same function.
//
// IT IS THE REVERSE OF `studio_form._item_spec` ON THE SERVER, and is written
// against that mapping deliberately rather than invented:
//
//     multipleChoice / dropdown  -> mcq            (one dim, one correct)
//     checkboxes                 -> msq
//     choiceGrid                 -> mcq            (one dim PER ROW)
//     checkboxGrid               -> msq            (one dim per row)
//     linearScale / rating       -> mcq            (options are the numbers)
//     shortAnswer / paragraph    -> subjective_rubric
//     date / time                -> subjective_rubric  (no picker in the exam)
//     imageBlock / videoBlock    -> mcq | msq      (+ its own media)
//     comparePair                -> image_ab
//     imageAnnotation            -> image_label
//     promptWriting              -> image_prompt | video_prompt  (by medium)
//
// EVERY BACKEND TYPE NOW HAS A BLOCK. `image_prompt` and `video_prompt` used
// to have none - no `FormItemKind` expressed "write the prompt that would
// produce this", so the forward mapping could never emit either and a
// generated one had to open as a lossy paragraph. `FormItemKind.promptWriting`
// closed that: one kind for both, with the medium read from the attached
// media exactly as `_item_spec` reads it. [MappedFormItem.notes] therefore
// reports only real defects now (a stimulus that has not rendered, a control
// this build no longer offers), not a gap in the designer's vocabulary.
import 'enums.dart';
import 'form_models.dart';
import 'models.dart' show Asset, Question, QDimension, QOption, TaskTemplate;

/// One generated question as a Form Studio block, plus anything the
/// translation could not carry across.
class MappedFormItem {
  const MappedFormItem(this.item, {this.notes = const <String>[]});

  final FormItem item;

  /// Lossy conversions, in the examiner's words. Empty means the block holds
  /// everything the generated question did.
  final List<String> notes;
}

/// The Form Studio block that can edit [q], chosen from what the model
/// actually produced.
///
/// THE CHOICE IS MADE IN TWO STEPS, most specific first:
///
///  1. `QDimension.inputKind` - when the question came from a task template,
///     each axis REMEMBERS which Form Studio control the examiner drew for it
///     ('linearScale', 'rating', 'checkboxes'...). That is an exact
///     round-trip and always wins.
///  2. `Question.type` - the engine type, for a question the model wrote
///     freely from the SOP. Several kinds collapse onto one engine type
///     (`mcq` is any of five), so this step can only pick the most faithful
///     of them; step 1 is why a templated question does not have to.
MappedFormItem formItemFromQuestion(Question q) {
  final List<String> notes = <String>[];
  final FormItemKind kind = _kindFor(q, notes);
  final FormItem item = FormItem(
    formNewId('item'),
    kind,
    // `name` is what the reviewer sees in every list; `prompt` is the text put
    // to the candidate. They are usually the same string, and when they are
    // not it is the PROMPT that belongs on the question.
    title: q.prompt.trim().isNotEmpty ? q.prompt.trim() : q.name.trim(),
    help: q.desc.trim(),
    // A generated question is always answered - nothing in a generated set is
    // decoration - so it arrives required, the way the server delivers it.
    required: true,
  );

  switch (kind) {
    case FormItemKind.multipleChoice:
    case FormItemKind.dropdown:
    case FormItemKind.checkboxes:
      _fillOptions(item, q);
    case FormItemKind.choiceGrid:
    case FormItemKind.checkboxGrid:
      _fillGrid(item, q);
    case FormItemKind.linearScale:
      _fillScale(item, q, notes);
    case FormItemKind.rating:
      _fillRating(item, q, notes);
    case FormItemKind.comparePair:
      _fillComparePair(item, q, notes);
    case FormItemKind.imageAnnotation:
      _fillAnnotation(item, q, notes);
    case FormItemKind.paragraph:
    case FormItemKind.shortAnswer:
      _fillSubjective(item, q);
    case FormItemKind.promptWriting:
      _fillPromptWriting(item, q, notes);
    case FormItemKind.imageBlock:
    case FormItemKind.videoBlock:
      _fillMediaQuestion(item, q);
    case FormItemKind.transcription:
      _fillTranscription(item, q, notes);
    // Kinds the mapper never chooses. Listed so a new FormItemKind cannot be
    // added to the enum without this switch failing to compile - the same
    // "one place to add a kind" guarantee the editor and preview registries
    // give, applied to the translation layer.
    case FormItemKind.textBlock:
      break;
  }

  return MappedFormItem(item, notes: notes);
}

/// A whole generated set as ONE form, ready for the designer's own blocks.
///
/// One section, because a generated set has no section structure of its own -
/// inventing one would put a page break where the model never asked for it.
({FormDef form, List<String> notes}) formFromGeneratedQuestions({
  required String title,
  required List<Question> questions,
}) {
  final List<String> notes = <String>[];
  final FormSection section = formNewSection();
  for (final Question q in questions) {
    final MappedFormItem mapped = formItemFromQuestion(q);
    section.items.add(mapped.item);
    // Prefixed with the question's own name: a bare "delivered as free text"
    // against a set of forty is not actionable.
    for (final String n in mapped.notes) {
      notes.add('${q.name.trim().isEmpty ? mapped.item.title : q.name}: $n');
    }
  }
  return (
    form: FormDef(
      formNewId('form'),
      title: title,
      sections: <FormSection>[section],
    ),
    notes: notes,
  );
}

// ── Seeding a TASK TEMPLATE from a question ────────────────────────────────

/// The response primitive a stored question type is served by.
///
/// The exact reverse of `constants.TASK_PRIMITIVE_TO_QUESTION_TYPE`. Two
/// primitives collapse onto `subjective_rubric` there (`free_text` and
/// `describe_media`), so coming back the other way has to pick one: plain
/// `free_text`, because it is the primitive that needs no media and therefore
/// cannot produce a template the generator refuses for want of a stimulus.
const Map<QType, String> kQTypeToTaskPrimitive = <QType, String>{
  QType.mcq: 'single_choice',
  QType.msq: 'multi_choice',
  QType.subjectiveRubric: 'free_text',
  QType.imageAb: 'compare_two',
  QType.imageLabel: 'annotate_image',
  QType.imagePrompt: 'author_prompt',
  QType.videoPrompt: 'author_video_prompt',
  // Never generated (a real recording and its correct answers come from the
  // examiner); listed so the map stays total. The nearest primitive.
  QType.transcription: 'free_text',
  // Matches the paragraph `_kindFor` opens it as, with its note.
  QType.unsupported: 'free_text',
};

/// An UNSAVED task template shaped like [q], for the template editor to open.
///
/// WHY THIS EXISTS. A generated question the examiner judges good is the best
/// possible description of the shape they want more of - which is exactly what
/// a task template is. Retyping it by hand to get there was the only route.
///
/// `id: 0` is the editor's own convention for "a draft the examiner has not
/// saved yet", so this opens as new work rather than silently overwriting a
/// stored template.
///
/// THE ANSWER KEY IS DELIBERATELY DROPPED. A template is a SHAPE, not an
/// instance: the key belongs to each generated question, because the model
/// decides per item which option is right for the stimulus it just invented
/// (`TaskTemplateEditor`'s own validation says so, and judging templates with
/// Form Studio's publish validator is a bug that has already been fixed once).
/// Carrying `correct` flags or a golden answer across would seed every
/// generated instance with the ONE question's answers.
TaskTemplate taskTemplateFromQuestion(Question q) {
  final FormItem item = formItemFromQuestion(q).item;
  final Map<String, dynamic> json = item.toJson()
    // A shape, not an instance - see above.
    ..remove('golden_answer')
    ..remove('golden_labels')
    ..remove('grid_key')
    ..remove('scale_golden')
    ..remove('rating_golden');
  if (json['options'] is List) {
    for (final Object? o in json['options'] as List<Object?>) {
      if (o is Map) o.remove('correct');
    }
  }
  return TaskTemplate(
    id: 0,
    // Named after the TASK, which is what a template is for - not after the
    // one question that suggested it.
    name: q.sourceTemplateName.trim().isNotEmpty
        ? q.sourceTemplateName.trim()
        : (q.name.trim().isEmpty
              ? 'Task from a generated question'
              : q.name.trim()),
    // The generator reads this, never a candidate: the question's own prompt
    // is the clearest statement of what to produce more of.
    instructions: q.prompt.trim(),
    response: kQTypeToTaskPrimitive[q.type] ?? 'single_choice',
    structure: <dynamic>[
      <String, dynamic>{
        'title': '',
        'items': <dynamic>[json],
      },
    ],
    itemCount: 1,
  );
}

// ── Choosing the kind ───────────────────────────────────────────────────────

FormItemKind _kindFor(Question q, List<String> notes) {
  // STEP 1: the template's own control, when there is one.
  final String hinted = q.dims
      .map((QDimension d) => d.inputKind.trim())
      .firstWhere((String s) => s.isNotEmpty, orElse: () => '');
  if (hinted.isNotEmpty) {
    final FormItemKind? exact = FormItemKind.values
        .where((FormItemKind k) => k.name == hinted)
        .firstOrNull;
    if (exact != null) return exact;
    // A control the designer no longer has. Worth saying out loud: the
    // question was authored as something this build cannot draw.
    notes.add(
      'the template drew this axis as "$hinted", which this version of the '
      'designer does not offer - it opens as its engine type instead.',
    );
  }

  // STEP 2: the engine type.
  switch (q.type) {
    case QType.mcq:
      return q.dims.length > 1
          ? FormItemKind.choiceGrid
          : FormItemKind.multipleChoice;
    case QType.msq:
      return q.dims.length > 1
          ? FormItemKind.checkboxGrid
          : FormItemKind.checkboxes;
    case QType.subjectiveRubric:
      return FormItemKind.paragraph;
    case QType.imageAb:
      return FormItemKind.comparePair;
    case QType.imageLabel:
      return FormItemKind.imageAnnotation;
    // Both prompt-writing types land on the ONE designer kind that expresses
    // them. Which of the two a form emits on the way back is read from the
    // attached media, so this direction needs no note and loses nothing - see
    // `FormItemKind.promptWriting`.
    case QType.imagePrompt:
    case QType.videoPrompt:
      return FormItemKind.promptWriting;
    case QType.transcription:
      return FormItemKind.transcription;
    // No designer kind can express a type this build does not know. Said out
    // loud, like the unknown control above, rather than silently re-typed.
    case QType.unsupported:
      notes.add(
        'its question type is not supported in this version of the app - it '
        'opens as a paragraph instead.',
      );
      return FormItemKind.paragraph;
  }
}

// ── Filling each shape ─────────────────────────────────────────────────────

/// The option list and its answer key.
///
/// TWO WIRE SHAPES, because a DRAFT and a BANK question do not store their
/// choices the same way: a draft has a flat `options_json` plus the TEXT of
/// the correct one, and the dimension records only exist once it is approved.
/// Both are accepted, dimensions first.
void _fillOptions(FormItem item, Question q) {
  final QDimension? dim = q.dims.isEmpty ? null : q.dims.first;
  if (dim != null && dim.options.isNotEmpty) {
    for (final QOption o in dim.options) {
      item.options.add(
        FormOption(formNewId('opt'), o.label, correct: o.correct),
      );
    }
    return;
  }
  // The draft shape: match the correct answers by TEXT, which is all a draft
  // carries. Compared trimmed and case-insensitively - the model's own
  // `correct_answer_json` is prose it wrote twice, not an id it looked up.
  final Set<String> correct = q.correctAnswers
      .map((String s) => s.trim().toLowerCase())
      .where((String s) => s.isNotEmpty)
      .toSet();
  for (final String label in q.options) {
    item.options.add(
      FormOption(
        formNewId('opt'),
        label,
        correct: correct.contains(label.trim().toLowerCase()),
      ),
    );
  }
}

/// A grid: one dimension per ROW, the shared columns from the first row's
/// options, and the key as row -> correct column label.
void _fillGrid(FormItem item, Question q) {
  item.columns.addAll(q.dims.first.options.map((QOption o) => o.label));
  for (int r = 0; r < q.dims.length; r++) {
    final QDimension d = q.dims[r];
    item.rows.add(d.name.trim().isEmpty ? 'Row ${r + 1}' : d.name);
    // EVERY correct column, not the first. `.firstOrNull` silently dropped the
    // rest, so round-tripping a checkbox-grid question back into the designer
    // (the task-template and annotation editors both do) discarded the extra
    // keys - and the next save wrote that loss back as the truth.
    final Set<String> keys = d.options
        .where((QOption o) => o.correct)
        .map((QOption o) => o.label)
        .toSet();
    if (keys.isNotEmpty) item.gridKey[r] = keys;
  }
}

/// A scale, reconstructed from the numeric options `_item_spec` wrote.
void _fillScale(FormItem item, Question q, List<String> notes) {
  final List<int> values = _numericOptions(q);
  if (values.isEmpty) {
    notes.add('the scale had no numeric options; it opens on 1-5.');
    return;
  }
  item.scaleMin = values.first;
  item.scaleMax = values.last;
  item.scaleGolden = _correctNumber(q);
}

void _fillRating(FormItem item, Question q, List<String> notes) {
  final List<int> values = _numericOptions(q);
  if (values.isEmpty) {
    notes.add('the rating had no numeric options; it opens on 5 stars.');
    return;
  }
  item.ratingMax = values.last;
  item.ratingGolden = _correctNumber(q);
}

void _fillComparePair(FormItem item, Question q, List<String> notes) {
  item.mediaUrl = _assetUrlForSlot(q.images, 'a') ?? '';
  item.mediaUrlB = _assetUrlForSlot(q.images, 'b') ?? '';
  if (item.mediaUrl.isEmpty || item.mediaUrlB.isEmpty) {
    notes.add(
      'an A/B comparison needs both sides; one of its images has not been '
      'rendered yet.',
    );
  }
  _fillOptions(item, q);
  // The A/B judge grades the candidate's justification against the official
  // rationale, which is exactly what the designer calls the golden answer.
  if (q.officialReasoning.trim().isNotEmpty) {
    item.goldenAnswer = q.officialReasoning.trim();
  }
}

void _fillAnnotation(FormItem item, Question q, List<String> notes) {
  final Asset? plate = _firstAssetWithUrl(q.images);
  item.mediaUrl = plate?.url ?? '';
  if (item.mediaUrl.isEmpty) {
    notes.add('the labelling image has not been rendered yet.');
  }
  // Drawn regions when the server has them (they make the markers tappable);
  // otherwise the box COUNT, which is the contract either way.
  if (plate != null && plate.regions.isNotEmpty) {
    item.regions.addAll(plate.regions);
  } else {
    item.annotationCount = q.labelBoxes.length;
  }
  item.goldenLabels.addAll(q.boxKey);
}

void _fillSubjective(FormItem item, Question q) {
  // The rubric IS the golden answer on a generated question - `_item_spec`
  // writes `rubric.ideal_answer` from it going the other way.
  final String golden = q.rubric
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .join('\n\n');
  if (golden.isNotEmpty) {
    item.goldenAnswer = golden;
  } else if (q.solutionRationale.trim().isNotEmpty) {
    item.goldenAnswer = q.solutionRationale.trim();
  }
}

/// PROMPT WRITING: the plate(s), the optional rating axes, and the model
/// prompt.
///
/// SLOTS, not list order. The transform form of these questions carries a
/// `reference` and an `output`; the from-scratch form carries one plate in
/// `single`. Reading positionally would silently swap the pair around, which
/// reverses what the question asks for.
void _fillPromptWriting(FormItem item, Question q, List<String> notes) {
  // Either medium can fill either slot, so both lists are considered - a
  // video_prompt question's plates live in `videos`, an image_prompt's in
  // `images`, and the transform form of either may mix them.
  final List<Asset> media = <Asset>[...q.images, ...q.videos];
  final String? reference =
      _assetUrlForSlot(media, 'reference') ?? _assetUrlForSlot(media, 'single');
  final String? output = _assetUrlForSlot(media, 'output');

  item.mediaUrl = reference ?? _firstAssetWithUrl(media)?.url ?? '';
  // Only a real pair fills the second slot. An `output` with no `reference`
  // is the from-scratch form with an oddly-named slot, not a transform.
  if (reference != null && output != null) item.mediaUrlB = output;

  if (item.mediaUrl.isEmpty) {
    notes.add('the prompt-writing stimulus has not been rendered yet.');
  }

  // The optional rating axes, when the question carries any.
  if (q.dims.isNotEmpty && q.dims.first.options.isNotEmpty) {
    _fillOptions(item, q);
  }
  // The model prompt: same field the designer calls the golden answer.
  _fillSubjective(item, q);
}

/// A media block that IS the question - options answered against its own
/// image or clip.
void _fillMediaQuestion(FormItem item, Question q) {
  final Asset? a = _firstAssetWithUrl(
    item.kind == FormItemKind.videoBlock ? q.videos : q.images,
  );
  item.mediaUrl = a?.url ?? '';
  item.multiSelect = q.type == QType.msq;
  _fillOptions(item, q);
}

/// TRANSCRIPTION: the clip and its language. The correct answers stay on the
/// server - a bank question's key is never sent to this screen - so the author
/// re-enters them, and is told so.
void _fillTranscription(FormItem item, Question q, List<String> notes) {
  item.mediaUrl = _firstAssetWithUrl(q.videos)?.url ?? '';
  item.mediaKind = 'audio';
  item.transcriptionLanguage = q.transcriptionLanguage;
  notes.add('re-enter the correct transcription and clip answers.');
}

// ── Small readers ──────────────────────────────────────────────────────────

/// The first dimension's options as ints, in order, when every one of them is
/// a number - which is how `_item_spec` stores a scale or a rating.
List<int> _numericOptions(Question q) {
  if (q.dims.isEmpty) return const <int>[];
  final List<int> out = <int>[];
  for (final QOption o in q.dims.first.options) {
    final int? n = int.tryParse(o.label.trim());
    if (n == null) return const <int>[];
    out.add(n);
  }
  out.sort();
  return out;
}

int? _correctNumber(Question q) {
  if (q.dims.isEmpty) return null;
  for (final QOption o in q.dims.first.options) {
    if (!o.correct) continue;
    final int? n = int.tryParse(o.label.trim());
    if (n != null) return n;
  }
  return null;
}

String? _assetUrlForSlot(List<Asset> assets, String slot) {
  for (final Asset a in assets) {
    if (a.slot == slot && (a.url ?? '').trim().isNotEmpty) return a.url;
  }
  return null;
}

Asset? _firstAssetWithUrl(List<Asset> assets) {
  for (final Asset a in assets) {
    if ((a.url ?? '').trim().isNotEmpty) return a;
  }
  return null;
}
