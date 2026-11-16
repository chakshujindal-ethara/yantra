// Domain entities - HANDOVER §5.1.
//
// Every entity is immutable with `copyWith`: the store mutates by replacing a
// record, which is what lets a screen rebuild from one source of truth.
// Scoring lives on the entities (`Attempt.result`, `Attempt.earnedMarks`)
// rather than in a service, so one place decides whether an attempt passed.
import 'enums.dart';
// `FormItemKind` only - for `Question.designerKind`, which names the Form Studio
// control a question was drawn as. `form_models.dart` imports `LabelRegion` back
// out of this file; Dart resolves that cycle fine because neither side needs the
// other during top-level initialisation, and a `show` clause keeps the coupling
// to the one symbol rather than the whole designer model.
// `FormItemKindX` carries `label`; a `show` clause naming only the enum hides
// the extension, and `k.label` then fails to resolve.
import 'form_models.dart' show FormItemKind, FormItemKindX;
import 'transcription.dart';

/// Reads a JSON field by camelCase name, falling back to its snake_case form.
///
/// The Odoo API speaks snake_case (`question_limit`, `duration_minutes`)
/// because that is how the ORM names its columns; this app speaks camelCase.
/// Before this existed every `fromJson` read only the camelCase key, so a
/// payload straight off the wire parsed "successfully" with EVERY field at its
/// default - an assessment list that rendered as rows of zeros rather than
/// failing loudly. Accepting both spellings is what makes the seed fixtures and
/// the live API interchangeable.
Object? jget(Map<String, dynamic> j, String camel) {
  if (j.containsKey(camel)) return j[camel];
  final String snake = camel.replaceAllMapped(
    RegExp(r'[A-Z]'),
    (Match m) => '_${m[0]!.toLowerCase()}',
  );
  return j[snake];
}

/// A byte count a person can read.
///
/// Bytes below 1 KB stay bytes: rounding a real 446-byte file to "0 KB" reads
/// as though nothing was stored.
String humanBytes(int bytes) {
  if (bytes <= 0) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

const List<String> _kMonths = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Sep 8th, 2026" - the format the flag tooltip is specified in.
///
/// SEPARATE FROM [humanDate] rather than a parameter on it, because the two
/// are read in different places for different reasons: `humanDate` labels a
/// column and wants to be short, this one sits inside a sentence a person
/// reads once ("Raised by Akshay Kumar on Sep 8th, 2026") and wants to be
/// unambiguous.
///
/// The ordinal rules are English's real ones, including the 11th/12th/13th
/// exception that a naive `% 10` gets wrong three times a month.
String ordinalDate(DateTime at) {
  final int d = at.day;
  final String suffix = (d >= 11 && d <= 13)
      ? 'th'
      : switch (d % 10) {
          1 => 'st',
          2 => 'nd',
          3 => 'rd',
          _ => 'th',
        };
  return '${_kMonths[at.month - 1]} $d$suffix, ${at.year}';
}

const Duration _kIst = Duration(hours: 5, minutes: 30);

/// [at] as India's wall clock reads it. Read only its date and clock fields:
/// the value is the instant SHIFTED, so comparing it with a real instant is
/// off by 5h30.
///
/// A BARE DATE NEEDS THIS TOO, not just a clock time. `.day` on a wire stamp is
/// the UTC day (the API sends `Z`) and on `toLocal()` it is the browser's, and
/// either one names the previous day for anything that happened between
/// midnight and 05:30 in India.
DateTime inIst(DateTime at) => at.toUtc().add(_kIst);

/// "21/9/2026": the short date the candidate's own screens print, as the India
/// date.
String istShortDate(DateTime at) {
  final DateTime t = inIst(at);
  return '${t.day}/${t.month}/${t.year}';
}

/// The clock time both formats below end on, ZONE INCLUDED - "10:04 PM IST",
/// or "10:04pm IST" inside a sentence.
///
/// The label lives here and nowhere else so no screen can print an IST time
/// without saying it is IST: candidates outside India read a bare "10:04 PM"
/// as their own clock (decided: every timestamp, candidates and staff alike).
/// [t] is already shifted to IST.
String _istClock(DateTime t, {bool inSentence = false}) {
  final int h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final String minute = t.minute.toString().padLeft(2, '0');
  final String half = t.hour < 12 ? 'AM' : 'PM';
  return inSentence
      ? '$h12:$minute${half.toLowerCase()} IST'
      : '$h12:$minute $half IST';
}

/// "30 Sep 2026, 12:50 PM IST": a fixed moment, year always present, as the
/// Conducted time on an assessment is read.
String istDateTime(DateTime at) {
  final DateTime t = inIst(at);
  return '${t.day} ${_kMonths[t.month - 1]} ${t.year}, ${_istClock(t)}';
}

/// "Sep 21, 2026 at 10:04pm IST": a moment named inside a sentence, as in
/// "Scored 630/630 candidates on Sep 21, 2026 at 10:04pm IST".
String istDateAtTime(DateTime at) {
  final DateTime t = inIst(at);
  return '${_kMonths[t.month - 1]} ${t.day}, ${t.year} at '
      '${_istClock(t, inSentence: true)}';
}

/// "10:03 AM IST" today, "18 Sep, 10:03 AM IST" earlier this year, "18 Sep
/// 2025, 10:03 AM IST" before that - always India Standard Time.
///
/// IST, not the browser's zone, so "10:03" names the same moment on every
/// screen the team compares. IST is a fixed UTC+05:30 with no daylight saving,
/// so an offset is exact and no timezone database is needed.
String istTimestamp(DateTime at, {DateTime? now}) {
  final DateTime t = inIst(at);
  final DateTime today = inIst(now ?? DateTime.now());
  final String time = _istClock(t);
  if (t.year == today.year && t.month == today.month && t.day == today.day) {
    return time;
  }
  final String day = '${t.day} ${_kMonths[t.month - 1]}';
  return t.year == today.year ? '$day, $time' : '$day ${t.year}, $time';
}

/// A date a person can read, from whatever the wire actually sent: the IST
/// clock time from [istTimestamp].
///
/// THE BUG THIS EXISTS FOR. The API dates a generator with `create_date`, an
/// ISO-8601 string, and it was printed raw: the generator header read
/// "updated 2026-08-12T08:57:14Z". The seed fixtures carry pre-humanised
/// strings ('2 days ago', '5 hours ago'), so every test and every design pass
/// looked correct while the live app showed a machine timestamp - the fixture
/// was hiding the defect rather than reproducing it.
///
/// ANYTHING THAT DOES NOT PARSE AS A DATE IS RETURNED UNCHANGED. That is what
/// keeps those fixtures rendering as they always did, and it is what makes this
/// safe to apply at parse time rather than at each call site.
String humanWhen(String raw) {
  final String text = raw.trim();
  if (text.isEmpty) return '';
  final DateTime? parsed = DateTime.tryParse(text);
  if (parsed == null) return text; // already human, or not a date at all
  return istTimestamp(parsed);
}

/// A raw score, as every surface must print it: a decimal from 0 to 1.
///
/// THE CONVENTION, IN ONE PLACE. The grader returns a 0-100 integer - that is
/// its prompt contract and what the pass threshold is expressed in - and the
/// console used to print that number straight out under labels like
/// "Subjective raw". So one screen showed a raw of `0.93` beside another
/// showing `93` for the same answer, and neither said which scale it was on.
///
/// Takes the grader's 0-100 because that is what the audit payload carries;
/// anything already 0-1 wants [rawDecimal] instead.
String rawFromHundred(num? hundred) =>
    ((hundred ?? 0) / 100).toStringAsFixed(2);

/// A raw that is ALREADY 0-1, formatted the same way, so the two cannot drift.
String rawDecimal(num? value) => (value ?? 0).toStringAsFixed(2);

/// A LIST, whatever the wire actually sent.
///
/// Every `as List<dynamic>` on the question path was an unguarded cast over
/// FREE-FORM LLM OUTPUT: `options_json`, `dimensions_json`, `solution_json` and
/// `label_boxes_json` are text columns holding whatever the model authored, so
/// a value that arrives as an object or a bare string is a data shape, not an
/// impossibility. A cast throws, `_loadDraft` catches, the hydrated record is
/// discarded, and the thin list row is kept - the card then reports no image and
/// no answer key over a record the server sent in full. Returning an empty list
/// loses one field instead of the whole question.
List<dynamic> jlist(Object? v) => v is List<dynamic> ? v : const <dynamic>[];

/// One row per event (`{reason, at}`) or per reason (`{reason, count}`) as a
/// per-reason tally, in the order first seen. Anything else is skipped.
List<({String reason, int count})> jtally(Object? v) {
  final Map<String, int> n = <String, int>{};
  for (final dynamic r in jlist(v)) {
    if (r is! Map<String, dynamic> || r['reason'] == null) continue;
    final Object? c = r['count'];
    final int add = c is num ? c.toInt() : 1;
    n.update('${r['reason']}', (int x) => x + add, ifAbsent: () => add);
  }
  return <({String reason, int count})>[
    for (final MapEntry<String, int> e in n.entries)
      (reason: e.key, count: e.value),
  ];
}

/// A MAP, whatever the wire actually sent. See [jlist].
Map<String, dynamic> jmap(Object? v) =>
    v is Map<String, dynamic> ? v : const <String, dynamic>{};

/// A STRING, whatever the wire actually sent.
///
/// `as String?` throws on a number or a bool, and Odoo sends `false` for an
/// unset Char - so the one shape most likely to arrive is the one the cast
/// cannot survive.
String? jstr(Object? v) => v == null ? null : (v is String ? v : '$v');

/// [jget] with a default, for the common scalar cases.
///
/// The double check runs FIRST, deliberately. On the web there is one numeric
/// type: `0.0 is int` is TRUE in compiled JavaScript, so an int-first order
/// sent every double through `toInt()`. That truncated $0.15208 to $0 in the
/// browser while passing in the VM, which is why the LLM budget screen read
/// $13.00 against a real $17.44 and every unit test still went green.
T jval<T>(Map<String, dynamic> j, String camel, T fallback) {
  final Object? v = jget(j, camel);
  if (v == null) return fallback;
  if (fallback is double && v is num) return v.toDouble() as T;
  if (fallback is int && v is num) return v.toInt() as T;
  if (v is T) return v as T;
  return fallback;
}

/// The `id` field, as a String, whatever the source sent.
///
/// Odoo ids are integers; the seed fixtures use strings like `A-1`. Both have
/// to land in the same `String id` field or a record loaded from the API can
/// never be looked up by a screen that was written against the fixtures.
String jid(Object? v) => v == null ? '' : v.toString();

/// The ONE rule for a candidate email, so the two ways one reaches the server
/// cannot disagree.
///
/// THE BUG THIS EXISTS FOR. `Foo.Bar@Example.COM` typed into the invite box
/// and `foo.bar@example.com` imported from a CSV created two applicant records
/// for one person, because the local half of an address is case-sensitive on
/// the wire and Odoo matched them verbatim. Both entry points now trim and
/// lower-case through here, so a duplicate can only be a genuinely different
/// mailbox.
String normalizeEmail(String raw) => raw.trim().toLowerCase();

/// The proctoring-violation Notice, as a strong line and a body line, derived
/// once so the attempt screen does not spell the rules out inline.
///
/// THE STRONG LINE fixes the singular/plural the old '(s)' construction left
/// unfilled: "1 proctoring violation recorded." reads, "1 proctoring
/// violation(s) recorded." reads like a template nobody finished.
///
/// THE BODY LINE is the full per-reason tally when the server kept a log -
/// "Right-click attempted (x3), Tab switched/window hidden (x2), ..." in the
/// order it sent (count descending) - because the old text named only the LAST
/// reason and a reviewer could not tell one lapse from a pattern. When the log
/// is EMPTY (a legacy attempt recorded before the server kept one) it falls
/// back to that same "Last reason: X" line so the record still reads sensibly.
///
/// THE AUTO-SUBMIT CLAUSE is appended unchanged: it distinguishes a
/// violation-triggered auto-submit from a plain time expiry, and a cap of 0
/// ("end on the first") from a real cap - a distinction the tally does not
/// carry and a reviewer answering an appeal needs.
///
/// [ai]: the AI proctoring count, its own tally and its own cap; the
/// auto-submit clause then answers to `ai_violation`.
({String strong, String text}) proctoringViolationNotice({
  required int count,
  required List<({String reason, int count})> violations,
  required String violationReason,
  required String autoSubmitReason,
  required int maxViolations,
  bool ai = false,
}) {
  final String kind = ai ? 'AI proctoring' : 'proctoring';
  final String strong = count == 1
      ? '1 $kind violation recorded.'
      : '$count $kind violations recorded.';
  final String ended = ai ? 'ai_violation' : 'violation';

  final String autoSuffix = switch ((autoSubmitReason, maxViolations)) {
    (final String r, 0) when r == ended =>
      ' The attempt was auto-submitted on the first violation, which is what '
          'a cap of 0 means.',
    (final String r, final int cap) when r == ended =>
      ' The attempt was auto-submitted on reaching the limit of $cap.',
    ('expired', _) =>
      ' The attempt was auto-submitted when the time ran out, not by these '
          'violations.',
    _ => '',
  };

  if (violations.isEmpty) {
    return (strong: strong, text: 'Last reason: $violationReason.$autoSuffix');
  }
  final String tally = violations
      .map((({String reason, int count}) v) => '${v.reason} (x${v.count})')
      .join(', ');
  return (strong: strong, text: '$tally.$autoSuffix');
}

/// An AI proctoring reason (`web/proctor_ai.js` prefixes every one). These
/// count against the paper's AI pair, apart from the regular count; the
/// server splits on the same prefix.
bool isAiReason(String r) => r.startsWith('AI: ');

/// A NESTED object, or an empty map when the key is absent or not a map.
///
/// The API groups related fields (`candidate`, `generator`, `flags`,
/// `warnings`); the fixtures hold the same values flat. Returning `{}` rather
/// than null lets a parser read the group first and fall back to the flat
/// spelling with [jval], without a null check at every site.
Map<String, dynamic> jobj(Map<String, dynamic> j, String camel) {
  final Object? v = jget(j, camel);
  return v is Map<String, dynamic> ? v : const <String, dynamic>{};
}

/// Tag NAMES out of a payload's `tags` field.
///
/// The API sends tag objects (`{id, name, ...}`); the seed fixtures send bare
/// strings. Both have to arrive as a plain name list or the tag chips render
/// as "Instance of ...".
///
/// `display` FIRST. The module stores a machine key in `name`
/// (`domain:ui-annotation`) and the readable form in `display`
/// (`UI annotation`), and it sends both. Reading `name` put the facet prefix on
/// every chip - "domain:ui-annotation" under a heading that already says
/// Domain, which states the facet twice and is not what anyone wants to read.
///
/// Falls back to `label`, then `name` with its prefix stripped, so a tag from
/// an older payload still reads sensibly.
List<String> jtags(Map<String, dynamic> j) => jlist(jget(j, 'tags'))
    .map((dynamic t) {
      if (t is! Map<String, dynamic>) return '$t';
      for (final String k in const <String>['display', 'label']) {
        final String v = (t[k] ?? '').toString().trim();
        if (v.isNotEmpty) return v;
      }
      final String name = (t['name'] ?? '').toString();
      final int i = name.indexOf(':');
      return i < 0 ? name : name.substring(i + 1);
    })
    .where((String s) => s.isNotEmpty)
    .toList();

/// An option inside a dimension.
class QOption {
  final String id;
  final String label;
  final bool correct;

  const QOption({required this.id, required this.label, this.correct = false});

  QOption copyWith({String? id, String? label, bool? correct}) => QOption(
    id: id ?? this.id,
    label: label ?? this.label,
    correct: correct ?? this.correct,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'label': label,
    'correct': correct,
  };

  // The wire calls these `name` and `is_correct`; the fixtures call them
  // `label` and `correct`. Reading only the fixture spelling is why every
  // option rendered BLANK against a live server - an MCQ was N unlabelled
  // radio buttons - and why `QDimension.correctIds` came back empty, which
  // made `hasKey` false for every objective question and took `hasCompleteKey`,
  // `launchReady` and two launch gates down with it.
  factory QOption.fromJson(Map<String, dynamic> j) => QOption(
    id: jid(jget(j, 'id')),
    label: jval(j, 'label', jval(j, 'name', '')),
    correct: jval(j, 'correct', jval(j, 'isCorrect', false)),
  );
}

/// A dimension is `code · name · options`. A question may carry several; an
/// objective question is marked correct only when every one of its dimensions
/// matches.
class QDimension {
  final String code;
  final String name;
  final List<QOption> options;

  /// The server's record id, when this came from a live payload.
  ///
  /// `code` is a display label that defaults to 'D1', NOT an identifier - so
  /// nothing carried the real id and an edit could only ever replace the whole
  /// dimension. Replacing deletes its options, and the answers pointing at
  /// them go too (or, now, the write is refused). Editing in place needs this.
  final String id;

  /// The Form Studio control the examiner drew for this axis, when the question
  /// came from a template ('linearScale', 'rating', 'checkboxes', ...).
  ///
  /// Empty means a plain single-choice axis, which is what every axis was
  /// before templates could carry a scale or a grid - so a question authored
  /// the old way renders exactly as it always did.
  final String inputKind;

  const QDimension({
    required this.code,
    required this.name,
    this.options = const <QOption>[],
    this.id = '',
    this.inputKind = '',
  });

  Set<String> get correctIds =>
      options.where((QOption o) => o.correct).map((QOption o) => o.id).toSet();

  bool get hasKey => correctIds.isNotEmpty;

  QDimension copyWith({
    String? code,
    String? name,
    List<QOption>? options,
    String? id,
    String? inputKind,
  }) => QDimension(
    id: id ?? this.id,
    code: code ?? this.code,
    name: name ?? this.name,
    options: options ?? this.options,
    inputKind: inputKind ?? this.inputKind,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'code': code,
    'name': name,
    'input_kind': inputKind,
    'options': options.map((QOption o) => o.toJson()).toList(),
  };

  /// Options for one dimension, in either shape the API sends.
  ///
  /// Objects (`{id, label, correct}`) carry their own verdict. Bare strings do
  /// not, so the sibling `correct` list is consulted - it holds option NAMES,
  /// matched case-insensitively the way the module matches them when it
  /// materialises an answer key.
  static List<QOption> _dimensionOptions(Map<String, dynamic> j) {
    final Set<String> correct = <String>{
      for (final Object? c in jlist(jget(j, 'correct')))
        if (c != null) '$c'.trim().toLowerCase(),
    };
    final List<dynamic> raw = jlist(jget(j, 'options'));
    return <QOption>[
      for (final dynamic o in raw)
        if (o is Map<String, dynamic>)
          QOption.fromJson(o)
        else
          QOption(
            id: '$o',
            label: '$o',
            correct: correct.contains('$o'.trim().toLowerCase()),
          ),
    ];
  }

  factory QDimension.fromJson(Map<String, dynamic> j) => QDimension(
    id: jid(jget(j, 'id')),
    // `label` is the DRAFT spelling of `name`. A draft axis that fell back to
    // the empty default rendered a nameless block of radio buttons, with the
    // question it is asking - "Q1 Instruction Aligned" - shown nowhere.
    code: jval(j, 'code', 'D1'),
    name: jval(j, 'name', jval(j, 'label', '')),
    // The control the examiner drew, when this axis came from a template.
    // Absent on every question authored the old way, which is exactly the
    // plain single-choice axis the empty default already means.
    inputKind: jval(j, 'input_kind', jval(j, 'inputKind', '')),
    // An option is EITHER an object or a bare string, and this used to cast
    // every entry to a Map. A generated draft stores its axes as
    // `{"label": ..., "options": ["YES", "NO"], "correct": ["YES"]}`, so the
    // cast threw on the first option and took the WHOLE draft down: the
    // hydration catch turned it into "Could not load the full record", the
    // thin list row was kept instead, and the reviewer got a card with no
    // image, no answer key and no axes - under a badge reading "Rendered".
    //
    // The correct answers travel BESIDE the options in that shape, as a
    // sibling `correct` list, so they are matched back on here by value.
    // Nothing else in the payload records which one is right.
    options: _dimensionOptions(j),
  );
}

String? _firstNonEmpty(List<Object?> candidates) {
  for (final Object? c in candidates) {
    if (c is String && c.isNotEmpty) return c;
  }
  return null;
}

/// The spellings of an image_ab option that name a SIDE of the pair: the
/// `AB_VERDICT_SYNONYMS` keys that map to "Response A" or "Response B" in the
/// module's constants.py. "Both Good" and "Both Bad" are verdicts, not sides,
/// exactly as there.
const Set<String> _abSideWords = <String>{
  'response a',
  'image a',
  'a',
  'option a',
  'candidate a',
  'left',
  'first',
  'response b',
  'image b',
  'b',
  'option b',
  'candidate b',
  'right',
  'second',
};

/// The rest of `AB_VERDICT_SYNONYMS`: two-response verdicts naming no side.
const Set<String> _abBothWords = <String>{
  'both good',
  'tie',
  'equal',
  'either',
  'no preference',
  'both bad',
  'neither',
};

/// The module's `_ab_norm_phrase`: lower-cased, each run of non-alphanumerics
/// one space.
String _abNorm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// Whether an answer option names a side ("Response A", "Image B"): the
/// module's `ab_is_side_option`.
bool abNamesSide(String option) => _abSideWords.contains(_abNorm(option));

/// An image_ab whose axes name no side: Yes/No checks on a tagged frame and a
/// reference, say. Its two plates are a left and a right picture, not
/// Response A and Response B, and there is no Overall Choice.
///
/// The module's own test (`side_free` in services/vertex.py): there are axes,
/// and no option on any of them names a side. No options means no evidence,
/// which stays the ordinary A/B pair.
bool abIsSideFree(QType type, Iterable<String> options) =>
    type == QType.imageAb && options.isNotEmpty && !options.any(abNamesSide);

/// A stimulus asset. [svg] carries hand-authored inline vector graphics in the
/// mock data; [url] points at the Odoo image controller when the app is bound
/// to a live backend.
class Asset {
  final String id;
  final String label;
  final String? url;
  final String? svg;

  /// Which slot this plate fills, mirroring `question.image.slot` in the
  /// module: `a` / `b` for an A/B pair, `reference` for a clean plate,
  /// `single` for the marked or lone plate, `output` for a generated result.
  ///
  /// It is the slot, not the position in the list, that decides what a layout
  /// renders - an A/B pair needs the `a` and `b` plates in those roles
  /// specifically, and ordering is not a contract.
  final String slot;

  /// The same plate with the numbered boxes burned in, server-side.
  ///
  /// `question_media` sends it only when the question's ONE overlay is that
  /// baked picture (label_overlay mode baked); otherwise it is empty and the
  /// client draws [regions] on the plain `url`. Reading only `url` once left
  /// the candidate looking at an unmarked photograph with numbered inputs
  /// beside it and no way to tell the boxes apart.
  final String? annotatedUrl;

  /// Numbered detection regions, for `image_label` stimuli. Each is a rect in
  /// fractional coordinates so it scales with whatever box the image lands in.
  final List<LabelRegion> regions;

  /// The still frame a video shows before it is played.
  ///
  /// `question_media` has always sent `poster_url` and no client read it, so
  /// every clip opened as a black rectangle: nothing about the frame said what
  /// the video was of, or even that it had loaded rather than failed. The QWeb
  /// runner set it as `<video poster>`. Null and empty are the same thing here -
  /// the serializer sends `""` for a clip with no poster.
  final String? posterUrl;

  /// What the server says this clip is: `"audio"` or `"video"` (a candidate
  /// `videos[]` entry carries it). Null on a payload that predates the key, and
  /// then `mediaKindOfAsset` falls back to the url's extension. A candidate clip
  /// url is a token path with NO extension, so for audio this key is the only
  /// thing that says it is not a video.
  final String? kind;

  const Asset({
    required this.id,
    required this.label,
    this.url,
    this.svg,
    this.slot = 'single',
    this.annotatedUrl,
    this.regions = const <LabelRegion>[],
    this.posterUrl,
    this.kind,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'label': label,
    if (url != null) 'url': url,
    if (svg != null) 'svg': svg,
    'slot': slot,
    'regions': regions.map((LabelRegion r) => r.toJson()).toList(),
    if (posterUrl != null) 'poster_url': posterUrl,
    if (kind != null) 'kind': kind,
  };

  /// Same asset with different boxes. Used to attach `label_boxes`, which the
  /// API sends beside the image rather than inside it.
  Asset copyWith({List<LabelRegion>? regions, String? url}) => Asset(
    id: id,
    label: label,
    url: url ?? this.url,
    svg: svg,
    slot: slot,
    annotatedUrl: annotatedUrl,
    regions: regions ?? this.regions,
    // Carried, not defaulted. `copyWith` is used to attach `label_boxes` to an
    // asset the payload already built, so dropping the poster here would blank
    // it on exactly the image questions that go through that path.
    posterUrl: posterUrl,
    kind: kind,
  );

  factory Asset.fromJson(Map<String, dynamic> j) => Asset(
    id: jid(jget(j, 'id')),
    label: jval(j, 'label', ''),
    // `data` FIRST. The module renders question images itself and returns
    // them inline as a `data:image/png;base64,...` URL under `data`; only
    // externally hosted assets carry a `url`. Reading `url` alone left
    // `url == null` on every generated image, so the stimulus panel drew
    // its "has not rendered" empty state over a PNG the server had sent.
    //
    // `admin_url` is the BANK/DRAFT spelling, and it was read for the
    // annotated overlay two lines down but never for the asset itself. A bank
    // question serializes its media only that way - as a path to the
    // ACL-checked /etp_assessment/admin_qimage and admin_qvideo proxies, never
    // inline - so an admin previewing an approved question saw the empty state
    // over media that existed, and a video question read "No video yet" with
    // both clips sitting on the record.
    // Empty counts as ABSENT. `image_admin_url` computes to False when the
    // record carries no picture, and the serializer sends that as "" - taken
    // literally it becomes a URL that can never load, so the panel would draw
    // a blank frame instead of saying the image has not rendered yet.
    url: _firstNonEmpty(<Object?>[
      jget(j, 'data'),
      jget(j, 'url'),
      jget(j, 'admin_url'),
    ]),
    svg: jstr(jget(j, 'svg')),
    slot: jval(j, 'slot', 'single'),
    // `admin_url` is the bank/draft spelling of the same thing.
    annotatedUrl: jstr(
      jget(j, 'annotated_url') ?? jget(j, 'annotated_admin_url'),
    ),
    regions: jlist(
      jget(j, 'regions'),
    ).whereType<Map<String, dynamic>>().map(LabelRegion.fromJson).toList(),
    // EMPTY IS ABSENT, same rule as `url` above: the serializer sends "" for a
    // clip with no poster, and taken literally that becomes a src that can
    // never load - a broken-image frame instead of the video's first frame.
    posterUrl: _firstNonEmpty(<Object?>[jget(j, 'poster_url')]),
    // Same empty-is-absent rule: Odoo sends `false` for an unset Char.
    kind: _firstNonEmpty(<Object?>[jget(j, 'kind')]),
  );
}

/// One line of a released result's section breakdown - "Objective 7 of 9
/// correct", "Written 2 of 3 passed".
///
/// STRUCTURED, because the server's own version of this is HTML. The model
/// composes `result_summary_public` as a styled Bootstrap card with inline
/// colours, which belongs to the backend's theme and would have to be either
/// rendered as foreign markup or stripped. `candidate_result.breakdown` sends
/// the numbers instead and the client draws its own rows.
class ResultSection {
  /// Stable machine key (`objective`, `subjective`), for anything that needs to
  /// branch. The human label travels separately so wording can change without
  /// a client release.
  final String key;
  final String label;
  final int value;
  final int total;

  /// The verb that makes the pair read: "correct", "passed".
  final String unit;

  /// Answers in this section still awaiting a grade. Non-zero means [value] is
  /// an incomplete figure and must not be presented as the final one.
  final int pending;

  const ResultSection({
    required this.key,
    required this.label,
    required this.value,
    required this.total,
    required this.unit,
    this.pending = 0,
  });

  String get summary => '$value of $total $unit';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    'label': label,
    'value': value,
    'total': total,
    'unit': unit,
    'pending': pending,
  };

  factory ResultSection.fromJson(Map<String, dynamic> j) => ResultSection(
    key: jval(j, 'key', ''),
    label: jval(j, 'label', ''),
    value: jval(j, 'value', 0),
    total: jval(j, 'total', 0),
    unit: jval(j, 'unit', ''),
    pending: jval(j, 'pending', 0),
  );
}

/// One numbered box on a labelling stimulus. Coordinates are fractions of the
/// image, 0-1.
class LabelRegion {
  final int number;
  final double x;
  final double y;
  final double w;
  final double h;

  const LabelRegion({
    required this.number,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'n': number,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
  };

  /// Parses BOTH shapes the module emits.
  ///
  /// The API sends `{"number": 1, "box_2d": [y0, x0, y1, x1], ...}` with
  /// coordinates in Gemini's 0-1000 space, top-left origin. This used to read
  /// `n/x/y/w/h` fractions, which no route ever sends, so every numbered box
  /// on a labelling question parsed as 0x0 at the origin - the candidate saw
  /// the screenshot with no boxes drawn on it and nothing to label.
  ///
  /// `box_2d` is Y-FIRST. Reading it as x,y silently transposes every box,
  /// which looks plausible on a square image and wrong on every other one.
  factory LabelRegion.fromJson(Map<String, dynamic> j) {
    final Object? box = jget(j, 'box_2d');
    if (box is List<dynamic> && box.length >= 4) {
      double at(int i) {
        final Object? v = box[i];
        // double BEFORE int: `0.0 is int` is true on the JS runtime, so an
        // int-first check truncates every fractional coordinate to zero on
        // web - the same trap `jval` documents.
        if (v is double) return v / 1000.0;
        if (v is int) return v / 1000.0;
        return (double.tryParse('$v') ?? 0) / 1000.0;
      }

      final double y0 = at(0), x0 = at(1), y1 = at(2), x1 = at(3);
      return LabelRegion(
        number: jval(j, 'number', jval(j, 'n', 0)),
        x: x0,
        y: y0,
        w: (x1 - x0).abs(),
        h: (y1 - y0).abs(),
      );
    }
    return LabelRegion(
      number: jval(j, 'number', jval(j, 'n', 0)),
      x: jval(j, 'x', 0.0),
      y: jval(j, 'y', 0.0),
      w: jval(j, 'w', 0.0),
      h: jval(j, 'h', 0.0),
    );
  }
}

/// The correct answer as a list, whatever shape the wire used.
///
/// mcq sends a bare string, msq sends a list. Normalising once here means no
/// screen has to branch on the question type just to read its own answer key.
List<String> _correctAnswers(Object? raw) {
  if (raw == null) return const <String>[];
  if (raw is List) {
    return <String>[
      for (final Object? v in raw)
        if (v != null && v.toString().trim().isNotEmpty) v.toString(),
    ];
  }
  final String one = raw.toString().trim();
  return one.isEmpty ? const <String>[] : <String>[one];
}

/// The answer key as a dimension tree, synthesising one when the payload sent
/// only a DRAFT's flat shape.
///
/// WHY THIS IS HERE AND NOT IN EACH RENDERER. A question carries two spellings
/// of one answer key: a bank question has `dimensions` (axes of options, each
/// with a correct flag), while a generated draft has `options` (bare strings)
/// and `correct_answer` (the correct ones by TEXT). Eleven display sites read
/// the first spelling and none read the second, so a draft msq with five
/// options and three correct rendered as an empty option list, an empty answer
/// key and a red "No answer key" - over a record the server sent in full.
///
/// Normalising once, here, fixes all eleven at once. Teaching each renderer the
/// second shape is eleven edits, eleven chances to disagree, and a twelfth
/// renderer that starts broken - which is exactly how three surfaces ended up
/// disagreeing about whether an A/B question even has a key.
///
/// The flat fields are left populated: the editor round-trips through them, and
/// they are what `/drafts/<id>/update` accepts.
List<QDimension> _dimensions(
  Map<String, dynamic> j,
  QType type,
  List<String> options,
  List<String> correct,
) {
  final List<QDimension> sent = jlist(
    jget(j, 'dims') ?? jget(j, 'dimensions'),
  ).whereType<Map<String, dynamic>>().map(QDimension.fromJson).toList();
  // STRICT FALLBACK. Once the server sends a draft's real axis rows this stops
  // firing on its own, so nothing has to be unwound later.
  if (sent.isNotEmpty) return sent;
  // Gate on the key SHAPE, not on `isObjective`: a subjective draft carrying
  // stray options must not acquire a key it is not marked by.
  if (!type.hasOptionKey || options.isEmpty) return const <QDimension>[];
  return <QDimension>[
    // `id: ''` is deliberate and load-bearing. These options have no server
    // records, and the editor maps an empty id to "create" - so a synthesised
    // dimension that reached a write would create rows rather than address
    // someone else's by id.
    QDimension.fromJson(<String, dynamic>{
      'id': '',
      'name': 'Answer',
      // `_dimensionOptions` already matches bare strings against a sibling
      // `correct` list, case-insensitively and trimmed - the same way the
      // module matches them when it materialises a key.
      'options': options,
      'correct': correct,
    }),
  ];
}

/// The rubric as display lines, whatever shape the wire used.
///
/// The module sends an OBJECT (`{ideal_labels: "...", mandatory_elements:
/// [...]}`); the fixtures send a plain list of strings. Casting straight to a
/// list threw a TypeError mid-parse on every real draft, `loadDraft` swallowed
/// it in a bare `catch (_)`, and the discarded record left the card on its
/// image-less list row - which is why the panel read "No image yet for this
/// question" under a badge that correctly said "Rendered".
List<String> _rubricLines(Object? raw) {
  // Flatten one level: a Map value may itself be a list of criteria.
  final Iterable<Object?> parts = switch (raw) {
    null => const <Object?>[],
    final List<Object?> l => l,
    final Map<Object?, Object?> m => m.values.expand(
      (Object? v) => v is List ? v : <Object?>[v],
    ),
    _ => <Object?>[raw],
  };
  return parts
      .where((Object? v) => v != null)
      .map((Object? v) => '$v'.trim())
      .where((String s) => s.isNotEmpty)
      .toList();
}

/// The box NUMBERS out of `label_boxes`, whichever shape it arrived in.
///
/// Two routes send this field and they disagree:
///   * `/exam/<token>/state` sends plain integers - `[1, 2, 5]`
///   * the draft detail sends maps - `[{number: 1, box_2d: [...]}, ...]`
///
/// Only the map shape was ever parsed, so on the exam route every element was
/// filtered out and a candidate got a labelling question with no inputs and no
/// overlay. Accepting both is the fix; sorted because the counter and the pager
/// both assume ascending order.
List<int> _labelBoxNumbers(List<dynamic> raw) {
  final List<int> out = <int>[];
  for (final dynamic e in raw) {
    if (e is num) {
      out.add(e.toInt());
    } else if (e is Map<String, dynamic>) {
      final Object? n = jget(e, 'number') ?? jget(e, 'n');
      if (n is num) out.add(n.toInt());
    }
  }
  out.sort();
  return out;
}

/// Attach the numbered boxes to the image they belong to.
///
/// The API keeps them apart: `images` carries the PNG, `label_boxes` carries
/// `{number, box_2d, label, description}`. The UI needs them together, because
/// a box is drawn ON the stimulus.
///
/// Boxes go on the FIRST image only. Every labelling question the module emits
/// has exactly one stimulus, and spreading one set of coordinates across
/// several images would draw the same box on all of them.
List<Asset> _assetsWithBoxes(List<dynamic> images, List<dynamic> boxes) {
  final List<Asset> out = images
      .whereType<Map<String, dynamic>>()
      .map(Asset.fromJson)
      .toList();
  if (out.isEmpty || boxes.isEmpty) return out;
  final List<LabelRegion> regions = boxes
      .whereType<Map<String, dynamic>>()
      .map(LabelRegion.fromJson)
      // A number-only entry (no geometry) parses as a 0x0 rect at the origin;
      // drawing that would put a phantom marker in the corner. Geometry-less
      // payloads simply keep the baked annotated bitmap instead.
      .where((LabelRegion r) => r.w > 0 && r.h > 0)
      .toList();
  if (regions.isEmpty) return out;
  // The boxes belong to the MARKED plate - the `single` slot. Wire order is
  // not a contract, so a question carrying more than one asset can sort
  // another plate first, and pinning the regions to index 0 would draw the
  // markers on the wrong picture. Index 0 stays as the fallback only for a
  // payload that omits the slot entirely.
  int target = out.indexWhere((Asset a) => a.slot == 'single');
  if (target < 0) target = 0;
  out[target] = out[target].copyWith(regions: regions);
  return out;
}

/// The seven labelled parts of a marking guide.
///
/// Odoo's draft form shows these as named fields; the API sends them under
/// `answer_key` for a draft and `subjective_rubric` for a bank question, and
/// nothing read either. What DID render was [Question.rubric] - the same JSON
/// flattened into anonymous bullets - so a reviewer saw the prose with no way
/// to tell a pass condition from a penalty rule. This is that labelling.
///
/// The two wire shapes differ (a draft sends strings, the bank sends lists), so
/// every field goes through [_rubricLines], which already accepts either.
class AnswerKeyDetail {
  final List<String> idealAnswer;
  final List<String> mandatoryElements;
  final List<String> penaltyRules;
  final List<String> scoringGuide;
  final List<String> checklist;
  final List<String> constraints;
  final List<String> passCondition;

  const AnswerKeyDetail({
    this.idealAnswer = const <String>[],
    this.mandatoryElements = const <String>[],
    this.penaltyRules = const <String>[],
    this.scoringGuide = const <String>[],
    this.checklist = const <String>[],
    this.constraints = const <String>[],
    this.passCondition = const <String>[],
  });

  /// Label / lines pairs, in the order Odoo's form lists them.
  List<(String, List<String>)> get sections => <(String, List<String>)>[
    ('Ideal answer', idealAnswer),
    ('Mandatory elements', mandatoryElements),
    ('Checklist', checklist),
    ('Constraints', constraints),
    ('Scoring guide', scoringGuide),
    ('Penalty rules', penaltyRules),
    ('Pass condition', passCondition),
  ].where(((String, List<String>) s) => s.$2.isNotEmpty).toList();

  bool get isEmpty => sections.isEmpty;
  bool get isNotEmpty => !isEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ideal_answer': idealAnswer,
    'mandatory_elements': mandatoryElements,
    'penalty_rules': penaltyRules,
    'scoring_guide': scoringGuide,
    'checklist': checklist,
    'constraints': constraints,
    'pass_condition': passCondition,
  };

  factory AnswerKeyDetail.fromJson(Object? raw) {
    final Map<String, dynamic> j = jmap(raw);
    return AnswerKeyDetail(
      // The ideal answer is keyed by TYPE upstream - `ideal_prompt` for a
      // prompt-authoring question, `ideal_labels` for a labelling one - so all
      // three spellings land in one field rather than in three empty ones.
      idealAnswer: _rubricLines(
        jget(j, 'idealAnswer') ??
            jget(j, 'idealLabels') ??
            jget(j, 'idealPrompt'),
      ),
      mandatoryElements: _rubricLines(jget(j, 'mandatoryElements')),
      penaltyRules: _rubricLines(jget(j, 'penaltyRules')),
      scoringGuide: _rubricLines(jget(j, 'scoringGuide')),
      checklist: _rubricLines(jget(j, 'checklist')),
      constraints: _rubricLines(jget(j, 'constraints')),
      passCondition: _rubricLines(jget(j, 'passCondition')),
    );
  }
}

/// What deleting a bank question would touch.
///
/// `referenced` is the server saying "retire it, do not erase it" - the
/// question is on a paper somebody has already sat.
class QUsage {
  final int assessmentCount;
  final int answerCount;
  final bool referenced;
  final List<String> assessmentNames;

  const QUsage({
    this.assessmentCount = 0,
    this.answerCount = 0,
    this.referenced = false,
    this.assessmentNames = const <String>[],
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'assessment_count': assessmentCount,
    'answer_count': answerCount,
    'referenced': referenced,
    'assessments': assessmentNames,
  };

  factory QUsage.fromJson(Object? raw) {
    final Map<String, dynamic> j = jmap(raw);
    return QUsage(
      assessmentCount: jval(j, 'assessmentCount', 0),
      answerCount: jval(j, 'answerCount', 0),
      referenced: jval(j, 'referenced', false),
      assessmentNames: <String>[
        for (final Object? a in jlist(jget(j, 'assessments')))
          if (a is Map<String, dynamic>)
            '${a['name'] ?? ''}'
          else if (a != null)
            '$a',
      ].where((String s) => s.isNotEmpty).toList(),
    );
  }
}

/// One question - a draft awaiting a human decision, or an approved bank row.
///
/// A draft and a bank question are the same shape; what separates them is
/// [state] and the bank-only fields ([answerKeyValid], [usedIn], [approvedOn]).
/// Keeping them one type is what lets the preview sheet render a draft and a
/// bank row through the same path.
class Question {
  final String id;
  final String genId;

  /// The task template this question reproduces, when one authored it.
  ///
  /// Empty for a question the model wrote freely from the SOP. Shown in place
  /// of the engine type: a reviewer needs to know WHICH TASK they are
  /// approving, and "Image A/B" is the rendering engine, not the task.
  final String sourceTemplateName;

  /// The designer kind the server named on the ROW, when it sent one.
  ///
  /// A list row carries no axis tree - `bank_question_row` deliberately sends
  /// one scalar instead, because the bank list clamps at 200 rows and the kind
  /// is the same on every axis of a question anyway. So `designerKind` reads
  /// this first and falls back to the axes, which is what a DETAIL payload and
  /// a draft carry. Empty on a question authored before the field existed,
  /// which the fallback and then `type` already handle.
  final String designerKindHint;

  /// A transcription question's language: 'hi' (Devanagari, with Hindi
  /// typing) or 'en' (small English letters). 'hi' for every other type.
  final String transcriptionLanguage;

  /// The Form Studio section this question was authored under, or empty.
  ///
  /// Sections already decided the ORDER a candidate meets questions in - the
  /// publish path sets `preserve_question_order` from the author's shuffle
  /// choice. What was missing is that nobody ever TOLD the candidate a section
  /// existed, so a paper the examiner grouped into "Before you start" / "On the
  /// floor" / "Escalation" arrived as one flat run and the grouping was
  /// invisible to the only person it was for.
  ///
  /// Empty for a question that did not come from a form, which renders no
  /// heading rather than an invented one. The runner shows it on every question
  /// because it serves one question at a time - there is no preceding question
  /// on screen to have carried the heading.
  final String sectionTitle;

  /// The Form Studio control this question was DRAWN as, when it was drawn in
  /// the designer, else null.
  ///
  /// WHY THIS IS NEEDED FOR A LABEL. The publish path collapses many designer
  /// kinds onto few engine types on purpose: a dropdown, a linear scale, a
  /// rating and a multiple choice are all stored as `mcq`, because they are all
  /// "pick one keyed option" as far as scoring is concerned. That is right for
  /// storage and wrong for a badge - the Selected Questions table and the
  /// generator's Drafts tab printed "MCQ" over four visibly different controls,
  /// which is the reported "question type is not rightly mapped for Form Studio
  /// questions".
  ///
  /// `input_kind` is the signal, and it is already on the wire and already
  /// trusted: `generated_question_mapper._kindFor` reopens a question in the
  /// designer with exactly this lookup. Reading it here means one vocabulary
  /// across the designer, the badge and the exam runner.
  ///
  /// Read from the FIRST axis that names one. A grid names its kind on every
  /// row and they always agree; a question with one keyed axis has one.
  FormItemKind? get designerKind {
    // The row's own scalar wins, then the axes. A list payload has only the
    // former and a draft only the latter, so both have to be read or the same
    // question would name its control on one screen and not on another.
    final String hinted = designerKindHint.trim().isNotEmpty
        ? designerKindHint.trim()
        : dims
              .map((QDimension d) => d.inputKind.trim())
              .firstWhere((String s) => s.isNotEmpty, orElse: () => '');
    if (hinted.isEmpty) return null;
    return FormItemKind.values
        .where((FormItemKind k) => k.name == hinted)
        .firstOrNull;
  }

  /// What to CALL this question on screen: the examiner's task name when a
  /// template authored it, then the control it was drawn as, else the engine
  /// type.
  ///
  /// Lives here rather than at each call site because "Image A/B" was being
  /// printed on the drafts table, the review queue, the queue's side list and
  /// the detail dialog - four places, one idea. A non-A/B task reproduced by
  /// the A/B engine reads as plainly wrong under that label.
  ///
  /// THE TEMPLATE NAME STILL WINS. A reviewer approving "Verify a single photo
  /// edit" needs the task, not the control; the designer kind only answers the
  /// case where there is no task name and the engine type is too coarse to be
  /// useful.
  String get taskLabel => sourceTemplateName.isNotEmpty
      ? sourceTemplateName
      : (designerKind?.label ?? type.short);

  /// The same idea in the longer form the detail surfaces use.
  String get taskLabelLong => sourceTemplateName.isNotEmpty
      ? sourceTemplateName
      : (designerKind?.label ?? type.label);

  /// The generator's NAME, as the server sent it.
  ///
  /// Not resolved through the store: `genById(genId)?.name ?? genId` printed a
  /// raw database id whenever generators had not been loaded - every screen
  /// that lists questions without also listing generators - and printed one
  /// permanently once the generator was deleted, since `generator_id` is
  /// ondelete="set null".
  final String genName;

  /// The SOP this came from, in words, stamped at approval time.
  ///
  /// Outlives the generator: a question whose generator was deleted keeps no
  /// id and no name, and this is the only attribution it has left.
  final String sourceRef;

  /// Out of the bank, but still on every assessment that used it.
  ///
  /// NOT archived - the record is still active, or the papers using it would
  /// stop listing it. Only ever true on a row the caller asked for with
  /// `include_retired`.
  final bool retired;

  /// Deleted, with its history kept: always [retired] too, never restorable,
  /// listed only under the bank's "Show deleted". Assessments, answers and
  /// scores still point at it.
  final bool deleted;
  final QType type;
  final String name;
  final String prompt;
  final String desc;
  final List<QDimension> dims;

  /// A DRAFT's answer key, which is not a dimension tree.
  ///
  /// A generated draft stores its choices as a flat list of option strings and
  /// the TEXT of the correct one - `options_json` and `correct_answer_json`.
  /// The dimension records only come into being when the draft is approved
  /// into the bank. Nothing modelled these, so the review queue could show a
  /// draft's options but never edit them.
  final List<String> options;

  /// The option TEXT that is correct. One entry for mcq, several for msq.
  final List<String> correctAnswers;
  final List<String> rubric;
  final List<Asset> images;
  final List<Asset> videos;

  /// Labelling questions: expected label per numbered region.
  ///
  /// THIS IS THE ANSWER KEY. The exam route never sends it and must not - the
  /// labels are the marking scheme. It is populated only on the admin/review
  /// surfaces and by the seed fixtures. Anything a CANDIDATE renders must come
  /// from [labelBoxes] instead.
  final Map<int, String> boxKey;

  /// The numbered boxes a candidate is asked to label - the numbers only.
  ///
  /// The exam route sends these as a plain list of integers; the draft-detail
  /// route sends the same idea as a list of maps carrying geometry. Both are
  /// accepted. The numbers are NOT guaranteed contiguous: when they come from
  /// `detections_json` a box can be missing, so the inputs are driven by these
  /// values rather than by `1..n`.
  final List<int> labelBoxes;
  final Difficulty difficulty;
  final AssetState? imageState;
  final AssetState? videoState;
  final String? imageError;

  /// True means the question or its answer key CITES the source material -
  /// "according to the SOP", "Section 2.1".
  ///
  /// The smell is the citation, not its absence. A candidate never sees the
  /// document, so an item that points at it cannot be answered from what is on
  /// screen; the module's own field help says so ("Items must be
  /// self-contained") and `constants.text_has_source_reference` is a regex over
  /// SOP/manual/procedure wording, which only ever fires when such a phrase is
  /// PRESENT.
  ///
  /// This was modelled inverted, as `hasSourceReference` defaulting to true,
  /// and the wire flag was flipped on the way in to preserve it. That produced
  /// a warning reading "No source reference - the generator could not tie this
  /// question back to a passage in the document" on drafts the server had
  /// flagged for the opposite reason, so the reviewer was asked to acknowledge
  /// a problem described backwards.
  final bool citesSource;

  /// True means a distractor gives the answer away.
  final bool hasRevealingOption;

  /// A human has signed the rubric off.
  final bool rubricReviewed;

  /// Whether the record HAS a rubric / an answer rationale, as opposed to the
  /// text of either.
  ///
  /// A paged list row carries neither field - they are a checklist and a
  /// paragraph - so warnings computed from `rubric.isEmpty` or
  /// `officialReasoning.isEmpty` fired on every row in the bank, over records
  /// that held both. The server sends these two booleans instead; where they
  /// are absent (a DETAIL payload, which carries the real text) they fall back
  /// to reading it, so both shapes agree.
  final bool hasRubric;
  final bool hasOfficialReasoning;

  /// Whether this question is graded against a RUBRIC, as the module decides
  /// it - `subjective_rubric_json` is non-empty, or the type is
  /// `subjective_rubric`.
  ///
  /// NOT the same as `type.isSubjective`, and the difference is the whole
  /// point. `isSubjective` is every type that is not mcq/msq, which includes
  /// `image_ab` - a type the generator never authors a rubric for. The client
  /// asked for a rubric sign-off on those and painted "Rubric unreviewed" over
  /// them, while the module's launch gate - which reads THIS field - never
  /// wanted one. So the console demanded a sign-off the server did not
  /// require, on a marking guide that does not exist.
  final bool hasSubjective;
  final DraftState state;
  final String denyReason;

  // ── Bank-only ───────────────────────────────────────────────────────────
  final bool answerKeyValid;

  /// The RECORD's own `active` flag, exactly as the wire sent it.
  ///
  /// Almost nothing should read this - see [active], which is what "active"
  /// means to an operator. It is kept as its own field so a round-trip through
  /// [toJson] carries the server's value rather than the derived one, and so
  /// [copyWith] cannot quietly turn a restore into an archive.
  final bool recordActive;

  /// May this question still be served? Not archived AND not retired.
  ///
  /// RETIRING IS NOT ARCHIVING, on purpose (see [retired]): the row has to
  /// stay active or every assessment already built on it would stop listing
  /// it. So a retired question arrives with `active: true` on the wire, and
  /// every `q.active` test in the app was passing it. That is what made the
  /// bank's "Active" card and the Start-here "active questions" figure keep
  /// counting a question the picker had already stopped offering - the two
  /// numbers an operator uses to decide whether a paper can be built at all.
  /// The wire fact lives in [recordActive]; this is the product fact, and it
  /// is the one a count should use.
  bool get active => recordActive && !retired;

  /// The server's own "may this reach a candidate" verdict: active, valid key,
  /// and whatever media its type requires. Null when the payload did not carry
  /// it (a draft row, a seed fixture), which is why it is nullable rather than
  /// defaulted - "the wire did not say" and "the wire said no" are different
  /// answers, and only the first should fall back to the local derivation.
  final bool? servable;

  /// The server's `has_valid_key`, kept separate from [answerKeyValid] on
  /// purpose. [answerKeyValid] defaults to TRUE and drafts never carry it, so
  /// reusing it here would silently delete the blocking 'No answer key'
  /// warning from every draft in the review queue.
  final bool? serverKeyValid;

  /// How many assessments have drawn it.
  final int usedIn;
  final DateTime? approvedOn;
  final List<String> tags;

  // ── Parity with the Odoo question form ──────────────────────────────────
  //
  // Everything below was already on the wire and read by nothing, which is a
  // worse failure than a field the server never sends: the data exists, the
  // reviewer is deciding without it, and there is no symptom to notice. The
  // same block exists on `Generator` for the same reason.

  /// Text / Image / Video, as the module derives it from the type.
  final String medium;

  /// [medium], but "Audio" for a question published from an Audio block
  /// (the server names every audio and video block "Video").
  String get mediumLabel =>
      medium == 'Video' && videos.any((Asset a) => a.kind == 'audio')
      ? 'Audio'
      : medium;

  /// The time budget in minutes. 0 means unset, not "no time".
  final int timeMinutes;

  /// The generator's own justification for the answer key.
  ///
  /// Odoo labels it "Answer Rationale (hidden from candidate)". The grader
  /// marks a candidate's written justification against it.
  final String officialReasoning;

  /// Does this question ask the candidate to WRITE something beside their
  /// choice? Sent as `requires_justification`.
  ///
  /// True for the prose types by their nature, and for an image A/B only when
  /// the examiner asked for a justification - Form Studio's "Require
  /// justification" switch, which the server derives from whether an answer
  /// rationale was authored (`serializers.wants_justification`). So this is the
  /// one question-shape fact the runner cannot infer from [type] alone.
  ///
  /// The runner MUST honour it: with no rationale there is no standard to mark
  /// prose against, so a box shown anyway is unscored, and its placeholder
  /// would promise a mark that does not exist.
  final bool requiresJustification;

  /// The labelled marking guide. See [rubric] for the unlabelled flattening of
  /// the same JSON; render one or the other, never both.
  final AnswerKeyDetail answerKey;

  /// The golden answer, and how it is known.
  final List<String> solution;
  final String solutionRationale;

  /// Which required elements of the SOP this question exercises.
  final List<String> coversElements;

  /// The render briefs the images and clips were authored from.
  final List<String> imageBriefs;
  final List<String> videoBriefs;

  /// Asset generation progress, distinct from the review [state].
  final String generationStatus;
  final String genBatchLabel;

  /// The bank question this draft became, once approved.
  final String approvedQuestionId;

  /// The server's "a key exists at all", weaker than [serverKeyValid].
  final bool? hasAnswerKeyFlag;

  /// The server's own sentence about which media slot is missing.
  final String missingMediaWarning;

  /// Labelling: whether detection looks for objects or UI elements.
  final String detectionMode;

  /// What a delete would touch. Null when the payload did not say.
  final QUsage? usage;
  final int sequence;

  /// Everything the module stores that has no first-class home here.
  ///
  /// Kept as raw JSON rather than modelled: these are pipeline artefacts whose
  /// shape belongs to the generator, and inventing a class per artefact would
  /// couple this app to internals it only needs to DISPLAY. Rendered in the
  /// preview's collapsed "Advanced" disclosure, mirroring Odoo's own
  /// "Advanced (raw JSON)" tab.
  final Map<String, dynamic> advanced;

  const Question({
    required this.id,
    required this.genId,
    this.genName = '',
    this.sourceRef = '',
    this.sourceTemplateName = '',
    this.designerKindHint = '',
    this.transcriptionLanguage = 'hi',
    this.sectionTitle = '',
    this.retired = false,
    this.deleted = false,
    required this.type,
    required this.name,
    required this.prompt,
    this.desc = '',
    this.dims = const <QDimension>[],
    this.options = const <String>[],
    this.correctAnswers = const <String>[],
    this.rubric = const <String>[],
    this.images = const <Asset>[],
    this.videos = const <Asset>[],
    this.boxKey = const <int, String>{},
    this.labelBoxes = const <int>[],
    this.difficulty = Difficulty.medium,
    this.imageState,
    this.videoState,
    this.imageError,
    this.citesSource = false,
    this.hasRevealingOption = false,
    this.rubricReviewed = false,
    this.hasSubjective = false,
    this.hasRubric = false,
    this.hasOfficialReasoning = false,
    this.state = DraftState.draft,
    this.denyReason = '',
    this.answerKeyValid = true,
    bool active = true,
    this.servable,
    this.serverKeyValid,
    this.usedIn = 0,
    this.approvedOn,
    this.tags = const <String>[],
    this.medium = '',
    this.timeMinutes = 0,
    this.officialReasoning = '',
    this.requiresJustification = false,
    this.answerKey = const AnswerKeyDetail(),
    this.solution = const <String>[],
    this.solutionRationale = '',
    this.coversElements = const <String>[],
    this.imageBriefs = const <String>[],
    this.videoBriefs = const <String>[],
    this.generationStatus = '',
    this.genBatchLabel = '',
    this.approvedQuestionId = '',
    this.hasAnswerKeyFlag,
    this.missingMediaWarning = '',
    this.detectionMode = '',
    this.usage,
    this.sequence = 0,
    this.advanced = const <String, dynamic>{},
  }) : recordActive = active;

  /// The rows of a multi-row question (a grid, or several option axes) that
  /// [r] leaves blank, out of [rows]. The server calls a grid with one row
  /// ticked "answered", so the pre-submit review asks this. A question with
  /// fewer than two option rows reports no rows: answered is the server's.
  ({int missing, int rows}) blankRows(Response? r) {
    final List<QDimension> rows = dims
        .where((QDimension d) => d.options.isNotEmpty)
        .toList();
    if (rows.length < 2) return (missing: 0, rows: 0);
    final Set<String> picked = (r?.lines ?? const <String>[]).toSet();
    final int missing = rows
        .where(
          (QDimension d) =>
              !d.options.any((QOption o) => picked.contains(o.id)),
        )
        .length;
    return (missing: missing, rows: rows.length);
  }

  /// A side-free image_ab ([abIsSideFree]), read off its axes' options.
  bool get isSideFreeAb => abIsSideFree(type, <String>[
    for (final QDimension d in dims)
      for (final QOption o in d.options) o.label,
  ]);

  /// Gate 6: every selected objective question must have a correct answer
  /// marked, on every one of its dimensions.
  ///
  /// The list payloads (`/api/v1/bank`, and the `questions` inside an
  /// assessment detail) send `dimension_count` rather than the dimensions
  /// themselves, so `dims` is empty there through no fault of the question.
  /// Falling straight to `false` failed gate 6 for every objective question on
  /// every real assessment. When the server sent its own verdict, trust it.
  bool get hasCompleteKey {
    if (!type.isObjective) return true;
    if (dims.isNotEmpty) return dims.every((QDimension d) => d.hasKey);
    // A DRAFT's flat key. Reached only when the payload named correct answers
    // AND the options they name, i.e. a usable key demonstrably exists.
    //
    // This cannot loosen launch gate 6: no bank payload ever sends
    // `correct_answer`, so a bank row or an assessment question still falls
    // through to the server's own verdict exactly as before. Requiring
    // `options` too is stricter than the old path, not weaker - a key naming an
    // option that does not exist scores nobody and is refused here.
    if (options.isNotEmpty && correctAnswers.isNotEmpty) return true;
    // Null - a fixture, or a payload with no key at all - stays a failure,
    // which is what keeps the blocking 'No answer key' warning honest.
    return serverKeyValid ?? false;
  }

  /// HOW MANY MARKS THIS QUESTION IS WORTH: its COMPONENT count.
  ///
  /// The unit of scoring is the component, not the question. One mark per
  /// KEYED dimension - a sub-question, and that covers mcq, msq and every
  /// image_ab verdict axis - plus one for an LLM-graded free-text answer
  /// (subjective_rubric, image_prompt, video_prompt, image_ab), plus one for
  /// the labelling box set taken as a whole however many boxes it holds. So a
  /// three-sub-question mcq is worth 3 and a four-axis image_ab with a
  /// justification is worth 5. `type.isSubjective` is exactly "not mcq/msq",
  /// which is exactly the set that carries a graded component, so the two
  /// clauses below need no per-type list to fall out of step with.
  ///
  /// IT DEGRADES TO 1 RATHER THAN LYING. The list payloads - `/api/v1/bank`,
  /// and the `questions` inside an assessment detail - send `dimension_count`
  /// instead of the dimensions themselves (see [hasCompleteKey]), so `dims` is
  /// empty there through no fault of the question. Counting keys off it would
  /// report a real mcq as worth 0 marks and quietly shrink a paper's total.
  /// Where the axes cannot be counted this returns the OLD one-mark-per-
  /// question answer and is knowingly an UNDERCOUNT - an image_ab on a list
  /// row reads 1 where the server marks it out of 5. That is the honest limit
  /// of what a list row carries; nothing here can invent the missing axes.
  ///
  /// So anything summing these is a FALLBACK ONLY. Prefer the server's own
  /// total (`score_marks`, [Attempt.serverTotal]) wherever it was sent.
  int get componentCount {
    final int keyed = dims.where((QDimension d) => d.hasKey).length;
    final int graded = type.isSubjective ? 1 : 0;
    final int n = keyed + graded;
    return n > 0 ? n : 1;
  }

  /// Gate 4 / launch readiness: the stimulus a type needs has to have landed.
  bool get mediaComplete {
    if (type.needsImage) {
      if (images.isEmpty) return false;
      final AssetState? s = imageState;
      if (s == null) return true;
      return s == AssetState.rendered || s == AssetState.uploaded;
    }
    if (type.needsVideo) {
      if (videos.isEmpty) return false;
      final AssetState? s = videoState;
      if (s == null) return true;
      return s == AssetState.rendered || s == AssetState.uploaded;
    }
    return true;
  }

  /// A question may be served only when it is approved, active, media-complete
  /// and carries a usable key.
  ///
  /// `servable` is the SERVER's own form of exactly that rule (active + valid
  /// key + required media, `serializers.py:1000`), so when it is sent it wins.
  /// The local derivation could never pass on a live bank row: those rows carry
  /// no `state` (an approved question is the only kind that exists, so there is
  /// no state to send), and no `images`/`videos`/`dimensions` either - so
  /// `poolFor` returned 0 for every generator and no assessment could be
  /// created at all. Fixtures send no `servable`, so they keep the old path.
  ///
  /// [retired] is checked BEFORE `servable`, because the server's verdict is
  /// about the record's flags and a retired question is still active, still
  /// keyed and still media-complete - it answers `servable: true` for a row
  /// that can never be served again. Without this, gate 4 counted retired
  /// questions in "the generator has usable questions" and reported a pool
  /// bigger than the one `poolFor` would actually offer.
  bool get launchReady =>
      !retired &&
      (servable ??
          (state == DraftState.approved &&
              active &&
              mediaComplete &&
              hasCompleteKey));

  /// The quality warnings shown on the review-queue draft card.
  ///
  /// The blocking subset is what the acknowledgement checkbox gates: a draft
  /// carrying an unacknowledged blocking warning cannot be approved by any
  /// route, including the keyboard one.
  List<QualityWarning> get warnings {
    final List<QualityWarning> out = <QualityWarning>[];
    if (citesSource) {
      out.add(
        const QualityWarning(
          'Cites the source document',
          'The question or its answer key points at the source material - '
              '"according to the SOP", "Section 2.1". The candidate never sees '
              'that document, so the item cannot be answered from what is on '
              'screen. It has to stand on its own.',
          blocking: true,
        ),
      );
    }
    if (hasRevealingOption) {
      out.add(
        const QualityWarning(
          'A distractor reveals the answer',
          'One of the wrong options names the right one. The question can be '
              'answered without knowing the material.',
          blocking: true,
        ),
      );
    }
    if (type.isObjective && !hasCompleteKey) {
      out.add(
        const QualityWarning(
          'No answer key',
          'An objective question with no correct option marked can never be '
              'scored.',
          blocking: true,
        ),
      );
    }
    // `image_ab` IS subjective and NEVER has a rubric - by design, not by
    // omission. The generator is asked for dimensions and a flaw plan instead
    // (prompts/question.md), and the module drops a rubric if one is ever
    // emitted on an A/B item. So the generic test below fired on every single
    // A/B question ever authored, could not be cleared from any screen, and
    // told a reviewer the answer key was missing while a complete four-axis
    // key sat right above the warning.
    //
    // What actually decides an A/B mark is the verdict key plus
    // `officialReasoning` - the rationale the grader marks the candidate's
    // written justification against. THAT is the thing worth warning about
    // when it is missing, so the type gets its own test rather than an
    // exemption from this one.
    if (type == QType.imageAb) {
      if (!hasOfficialReasoning) {
        out.add(
          const QualityWarning(
            'No answer rationale',
            'The written justification is graded against the answer rationale. '
                'Without one the grader marks it against nothing, and a '
                'generic profile decides a score the question\'s whole mark '
                'can turn on.',
          ),
        );
      }
    } else if (type.isSubjective && !hasRubric) {
      out.add(
        const QualityWarning(
          'No rubric',
          'A subjective question with no rubric falls back to the generic '
              'grader profile.',
        ),
      );
    }
    // NO "marking guide not approved" WARNING.
    //
    // The sign-off it named is now the APPROVAL itself: `action_approve` sets
    // `rubric_reviewed` on the question it creates, because the reviewer who
    // approves a draft is reading that draft's rubric when they do it. A
    // second, separate confirmation recorded no judgement the first one had
    // not already recorded - it just left the bank full of questions flagged
    // unreviewed that a human had in fact just reviewed.
    //
    // The FIELD and the launch gate that reads it both remain, so an
    // assessment run with "Require Reviewed Rubric Before Launch" still
    // refuses to serve a guide nobody signed. What changed is which action
    // signs it.
    if (imageState == AssetState.failed) {
      out.add(
        const QualityWarning(
          'Stimulus failed to render',
          'The image never landed. The candidate would see an empty plate.',
          blocking: true,
        ),
      );
    }
    if (videoState == AssetState.partial) {
      out.add(
        const QualityWarning(
          'Some clips are missing',
          'Part of the video stimulus rendered and part did not.',
        ),
      );
    }
    return out;
  }

  List<QualityWarning> get blockingWarnings =>
      warnings.where((QualityWarning w) => w.blocking).toList();

  Question copyWith({
    String? id,
    String? genId,
    String? genName,
    String? sourceRef,
    bool? retired,
    bool? deleted,
    QType? type,
    String? name,
    String? prompt,
    String? desc,
    List<QDimension>? dims,
    List<String>? rubric,
    List<Asset>? images,
    List<Asset>? videos,
    Map<int, String>? boxKey,
    Difficulty? difficulty,
    AssetState? imageState,
    AssetState? videoState,
    String? imageError,
    bool? citesSource,
    bool? hasRevealingOption,
    bool? rubricReviewed,
    bool? hasSubjective,
    bool? hasRubric,
    bool? hasOfficialReasoning,
    DraftState? state,
    String? denyReason,
    bool? answerKeyValid,
    bool? servable,
    bool? serverKeyValid,
    bool? active,
    int? usedIn,
    DateTime? approvedOn,
    List<String>? tags,
    List<String>? options,
    List<String>? correctAnswers,
    List<int>? labelBoxes,
    String? medium,
    int? timeMinutes,
    String? officialReasoning,
    bool? requiresJustification,
    AnswerKeyDetail? answerKey,
    List<String>? solution,
    String? solutionRationale,
    List<String>? coversElements,
    List<String>? imageBriefs,
    List<String>? videoBriefs,
    String? generationStatus,
    String? genBatchLabel,
    String? approvedQuestionId,
    bool? hasAnswerKeyFlag,
    String? missingMediaWarning,
    String? detectionMode,
    QUsage? usage,
    int? sequence,
    Map<String, dynamic>? advanced,
    bool clearImageError = false,
  }) => Question(
    id: id ?? this.id,
    genId: genId ?? this.genId,
    genName: genName ?? this.genName,
    sourceRef: sourceRef ?? this.sourceRef,
    sourceTemplateName: sourceTemplateName,
    designerKindHint: designerKindHint,
    transcriptionLanguage: transcriptionLanguage,
    sectionTitle: sectionTitle,
    retired: retired ?? this.retired,
    deleted: deleted ?? this.deleted,
    type: type ?? this.type,
    name: name ?? this.name,
    prompt: prompt ?? this.prompt,
    desc: desc ?? this.desc,
    dims: dims ?? this.dims,
    options: options ?? this.options,
    correctAnswers: correctAnswers ?? this.correctAnswers,
    rubric: rubric ?? this.rubric,
    images: images ?? this.images,
    videos: videos ?? this.videos,
    boxKey: boxKey ?? this.boxKey,
    difficulty: difficulty ?? this.difficulty,
    imageState: imageState ?? this.imageState,
    videoState: videoState ?? this.videoState,
    imageError: clearImageError ? null : (imageError ?? this.imageError),
    citesSource: citesSource ?? this.citesSource,
    hasRevealingOption: hasRevealingOption ?? this.hasRevealingOption,
    rubricReviewed: rubricReviewed ?? this.rubricReviewed,
    hasSubjective: hasSubjective ?? this.hasSubjective,
    hasRubric: hasRubric ?? this.hasRubric,
    hasOfficialReasoning: hasOfficialReasoning ?? this.hasOfficialReasoning,
    state: state ?? this.state,
    denyReason: denyReason ?? this.denyReason,
    answerKeyValid: answerKeyValid ?? this.answerKeyValid,
    servable: servable ?? this.servable,
    serverKeyValid: serverKeyValid ?? this.serverKeyValid,
    // `recordActive`, never the derived `active`: copying a retired row would
    // otherwise write `false` into the record flag, and restoring it would
    // then hand back a question that is out of the bank for a second,
    // invisible reason nothing in the product can undo.
    active: active ?? recordActive,
    usedIn: usedIn ?? this.usedIn,
    approvedOn: approvedOn ?? this.approvedOn,
    tags: tags ?? this.tags,
    // labelBoxes was absent from BOTH the signature and this call, so every
    // copyWith silently zeroed it - including the one that promotes an approved
    // draft into the bank, which is where a labelling question loses the very
    // boxes it asks a candidate to label.
    labelBoxes: labelBoxes ?? this.labelBoxes,
    medium: medium ?? this.medium,
    timeMinutes: timeMinutes ?? this.timeMinutes,
    officialReasoning: officialReasoning ?? this.officialReasoning,
    requiresJustification: requiresJustification ?? this.requiresJustification,
    answerKey: answerKey ?? this.answerKey,
    solution: solution ?? this.solution,
    solutionRationale: solutionRationale ?? this.solutionRationale,
    coversElements: coversElements ?? this.coversElements,
    imageBriefs: imageBriefs ?? this.imageBriefs,
    videoBriefs: videoBriefs ?? this.videoBriefs,
    generationStatus: generationStatus ?? this.generationStatus,
    genBatchLabel: genBatchLabel ?? this.genBatchLabel,
    approvedQuestionId: approvedQuestionId ?? this.approvedQuestionId,
    hasAnswerKeyFlag: hasAnswerKeyFlag ?? this.hasAnswerKeyFlag,
    missingMediaWarning: missingMediaWarning ?? this.missingMediaWarning,
    detectionMode: detectionMode ?? this.detectionMode,
    usage: usage ?? this.usage,
    sequence: sequence ?? this.sequence,
    advanced: advanced ?? this.advanced,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'genId': genId,
    'genName': genName,
    'sourceRef': sourceRef,
    'retired': retired,
    'deleted': deleted,
    'type': type.wire,
    'name': name,
    'prompt': prompt,
    'desc': desc,
    'dims': dims.map((QDimension d) => d.toJson()).toList(),
    'rubric': rubric,
    'images': images.map((Asset a) => a.toJson()).toList(),
    'videos': videos.map((Asset a) => a.toJson()).toList(),
    'boxKey': boxKey.map(
      (int k, String v) => MapEntry<String, String>('$k', v),
    ),
    'difficulty': difficulty.wire,
    'imageState': imageState?.wire,
    'videoState': videoState?.wire,
    'imageError': imageError,
    'citesSource': citesSource,
    'hasRevealingOption': hasRevealingOption,
    'rubricReviewed': rubricReviewed,
    'state': state.wire,
    'denyReason': denyReason,
    'answerKeyValid': answerKeyValid,
    if (servable != null) 'servable': servable,
    if (serverKeyValid != null) 'has_valid_key': serverKeyValid,
    // The wire value, so a record written out and read back in is the same
    // record. `active` is derived from `retired`, which is serialised above.
    'active': recordActive,
    'usedIn': usedIn,
    'approvedOn': approvedOn?.toIso8601String(),
    'tags': tags,
    // The draft answer key, which round-trips through these two names.
    'options': options,
    'correctAnswer': correctAnswers,
    'labelBoxes': labelBoxes,
    'medium': medium,
    'timeMinutes': timeMinutes,
    'officialReasoning': officialReasoning,
    'requiresJustification': requiresJustification,
    'answerKey': answerKey.toJson(),
    'solution': solution,
    'solutionRationale': solutionRationale,
    'coversElements': coversElements,
    'imageBriefs': imageBriefs,
    'videoBriefs': videoBriefs,
    'generationStatus': generationStatus,
    'genBatchLabel': genBatchLabel,
    'approvedQuestionId': approvedQuestionId,
    if (hasAnswerKeyFlag != null) 'hasAnswerKey': hasAnswerKeyFlag,
    'missingMediaWarning': missingMediaWarning,
    'detectionMode': detectionMode,
    if (usage != null) 'usage': usage!.toJson(),
    'sequence': sequence,
    'advanced': advanced,
  };

  /// Parses either shape: the seed fixtures (camelCase) or a live
  /// `/api/v1/bank` row (snake_case, integer id, nested `generator`).
  ///
  /// Every read goes through [jget]/[jval]/[jid], because a raw
  /// `j['id'] as String` throws on the wire - Odoo sends integer ids - and
  /// that TypeError used to escape `refresh()` and hang the loader.
  factory Question.fromJson(Map<String, dynamic> j) {
    // The API nests these; the fixtures flatten them.
    final Map<String, dynamic> g = jobj(j, 'generator');
    final Map<String, dynamic> w = jobj(j, 'warnings');

    // The module calls it `question_type`; the fixtures call it `type`.
    final Object? rawType = jget(j, 'type') ?? jget(j, 'questionType');
    final QType type = QType.parse(jstr(rawType));

    // A draft's flat answer key. `correct_answer` is a bare String for mcq and
    // a List for msq, so both are normalised to a list here and the caller
    // never has to ask which shape it got.
    final List<String> options = <String>[
      for (final Object? o in jlist(jget(j, 'options')))
        if (o != null) o.toString(),
    ];
    final List<String> correct = _correctAnswers(jget(j, 'correctAnswer'));

    return Question(
      id: jid(jget(j, 'id')),
      genId: g.isNotEmpty ? jid(g['id']) : jid(jget(j, 'genId')),
      // The nested `generator.name` the API has always sent and nothing read.
      genName: g.isNotEmpty ? '${g['name'] ?? ''}' : jval(j, 'genName', ''),
      sourceRef: jval(j, 'sourceRef', ''),
      sourceTemplateName: '${jobj(j, 'source_template')['name'] ?? ''}',
      designerKindHint: jval(j, 'designer_kind', jval(j, 'designerKind', '')),
      transcriptionLanguage: jval(j, 'transcription_language', 'hi') == 'en'
          ? 'en'
          : 'hi',
      sectionTitle: jval(j, 'section_title', jval(j, 'sectionTitle', '')),
      retired: jval(j, 'retired', false),
      deleted: jval(j, 'deleted', false),
      type: type,
      name: jval(j, 'name', ''),
      prompt: jval(j, 'prompt', ''),
      // `description` on the wire, `desc` in the fixtures.
      desc: jval(j, 'desc', jval(j, 'description', '')),
      dims: _dimensions(j, type, options, correct),
      options: options,
      correctAnswers: correct,
      // `subjective_rubric` is the BANK spelling; a draft sends `rubric`.
      // Only the draft name was read, so an approved subjective question -
      // the one place the rubric actually decides a mark - displayed "No
      // rubric. The generic grader profile applies." over a stored rubric with
      // a full checklist, constraints and pass condition. The reviewer was
      // being told the answer key did not exist.
      rubric: _rubricLines(jget(j, 'rubric') ?? jget(j, 'subjective_rubric')),
      // The numbered boxes live BESIDE the image on the wire
      // (`label_boxes`), not inside it, so they are attached here rather than
      // parsed by `Asset.fromJson`. Without this a labelling question rendered
      // a bare screenshot with nothing to label.
      images: _assetsWithBoxes(
        jlist(jget(j, 'images')),
        jlist(jget(j, 'label_boxes') ?? jget(j, 'labelBoxes')),
      ),
      // `video_files` on the wire, `videos` in the fixtures.
      videos: jlist(
        jget(j, 'videos') ?? jget(j, 'video_files'),
      ).whereType<Map<String, dynamic>>().map(Asset.fromJson).toList(),
      boxKey: jmap(jget(j, 'boxKey')).map(
        (String k, dynamic v) =>
            MapEntry<int, String>(int.tryParse(k) ?? 0, '$v'),
      ),
      labelBoxes: _labelBoxNumbers(
        jlist(jget(j, 'label_boxes') ?? jget(j, 'labelBoxes')),
      ),
      difficulty: Difficulty.parse(jstr(jget(j, 'difficulty'))),
      imageState: AssetState.parse(jstr(jget(j, 'imageState'))),
      videoState: AssetState.parse(jstr(jget(j, 'videoState'))),
      imageError: jstr(jget(j, 'imageError')),
      // READ STRAIGHT. `warnings.source_reference: true` means the item cites
      // the source document, which is the smell itself - it used to be flipped
      // into a "hasSourceReference" that meant the opposite, and the reviewer
      // was shown a warning describing the reverse problem.
      citesSource:
          jval(w, 'sourceReference', false) || jval(j, 'citesSource', false),
      hasRevealingOption:
          jval(w, 'revealingOption', false) ||
          jval(j, 'hasRevealingOption', false),
      rubricReviewed: jval(j, 'rubricReviewed', false),
      // Mirrors the module's own compute when the key is absent - a DRAFT
      // payload does not carry it - so the two agree either way.
      hasSubjective: jval(
        j,
        'hasSubjective',
        type == QType.subjectiveRubric ||
            _rubricLines(
              jget(j, 'rubric') ?? jget(j, 'subjective_rubric'),
            ).isNotEmpty,
      ),
      // Fall back to reading the text, so a DETAIL payload - which carries it
      // and sends no flag - answers the same as a list row that sends only the
      // flag.
      hasRubric: jval(
        j,
        'hasRubric',
        _rubricLines(
          jget(j, 'rubric') ?? jget(j, 'subjective_rubric'),
        ).isNotEmpty,
      ),
      hasOfficialReasoning: jval(
        j,
        'has_official_reasoning',
        // The module sends snake_case; the fixtures use camelCase. Reading only
        // one of them made every A/B question in the review queue claim "No
        // answer rationale" while the rationale was rendered on the same page.
        jval(
          j,
          'hasOfficialReasoning',
          jval(
            j,
            'official_reasoning',
            jval(j, 'officialReasoning', ''),
          ).trim().isNotEmpty,
        ),
      ),
      state: DraftState.parse(jstr(jget(j, 'state'))),
      denyReason: jval(j, 'denyReason', ''),
      // `has_valid_key` is the module's name for the same idea.
      answerKeyValid: jval(j, 'answerKeyValid', jval(j, 'hasValidKey', true)),
      // Nullable on purpose - see the field docs. `as bool?` rather than
      // jval so an absent key stays null instead of collapsing to false.
      servable: jget(j, 'servable') as bool?,
      serverKeyValid: jget(j, 'hasValidKey') as bool?,
      active: jval(j, 'active', true),
      usedIn: jval(j, 'usedIn', 0),
      approvedOn: DateTime.tryParse(jval(j, 'approvedOn', '')),
      tags: jtags(j),
      // ── Parity block. See the field docs for why each one matters. ──
      medium: jval(j, 'medium', ''),
      timeMinutes: jval(j, 'timeMinutes', 0),
      officialReasoning: jval(j, 'officialReasoning', ''),
      // `jget` falls back from camelCase to the wire's snake_case, so this
      // one read covers `requires_justification` and the camelCase fixtures.
      requiresJustification: jval(j, 'requiresJustification', false),
      // `answer_key` is the draft spelling, `subjective_rubric` the bank's.
      answerKey: AnswerKeyDetail.fromJson(
        jget(j, 'answerKey') ?? jget(j, 'subjectiveRubric'),
      ),
      solution: _rubricLines(jget(j, 'solution')),
      solutionRationale: jval(j, 'solutionRationale', ''),
      coversElements: _rubricLines(jget(j, 'coversElements')),
      imageBriefs: _rubricLines(jget(j, 'imageBriefs')),
      videoBriefs: _rubricLines(jget(j, 'videoBriefs')),
      generationStatus: jval(j, 'generationStatus', ''),
      genBatchLabel: jval(j, 'genBatchLabel', ''),
      approvedQuestionId: jid(jget(j, 'approvedQuestionId')),
      hasAnswerKeyFlag: jget(j, 'hasAnswerKey') as bool?,
      missingMediaWarning: jval(j, 'missingMediaWarning', ''),
      detectionMode: jval(j, 'detectionMode', ''),
      usage: jget(j, 'usage') == null
          ? null
          : QUsage.fromJson(jget(j, 'usage')),
      sequence: jval(j, 'sequence', 0),
      advanced: jmap(jget(j, 'advanced')),
    );
  }
}

/// A quality finding on a draft. A blocking warning must be acknowledged
/// before the draft can be approved.
class QualityWarning {
  final String title;
  final String detail;
  final bool blocking;

  const QualityWarning(this.title, this.detail, {this.blocking = false});
}

/// One uploaded file in a generator's corpus.
class Resource {
  final String id;
  final ResourceKind kind;
  final String file;
  final String size;
  final int pages;
  final ResourceStatus status;
  final String? error;

  const Resource({
    required this.id,
    required this.kind,
    required this.file,
    this.size = '',
    this.pages = 0,
    this.status = ResourceStatus.ready,
    this.error,
  });

  Resource copyWith({
    ResourceKind? kind,
    String? file,
    String? size,
    int? pages,
    ResourceStatus? status,
    String? error,
    bool clearError = false,
  }) => Resource(
    id: id,
    kind: kind ?? this.kind,
    file: file ?? this.file,
    size: size ?? this.size,
    pages: pages ?? this.pages,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'kind': kind.wire,
    'file': file,
    'size': size,
    'pages': pages,
    'status': status.wire,
    'error': error,
  };

  factory Resource.fromJson(Map<String, dynamic> j) => Resource(
    id: jid(jget(j, 'id')),
    // The wire names differ from the fixture names, and reading only the
    // fixture names rendered every real uploaded document as a blank row:
    //   kind  <- category            file  <- name
    //   error <- extraction_error    size  <- char_count (chars, not bytes)
    kind: ResourceKind.parse(
      (jget(j, 'kind') ?? jget(j, 'category')) as String?,
    ),
    file: jval(j, 'file', '').isNotEmpty
        ? jval(j, 'file', '')
        : jval(j, 'name', ''),
    // Prefer the stored SIZE. A PDF is read natively and never extracted,
    // so char_count is 0 and a size column built from it stayed blank on a
    // 6.5 MB document - the one number that proves the upload landed.
    size: jval(j, 'size', '').isNotEmpty
        ? jval(j, 'size', '')
        : (jval(j, 'fileSize', 0) > 0
              ? humanBytes(jval(j, 'fileSize', 0))
              : (jval(j, 'charCount', 0) > 0
                    ? '${jval(j, 'charCount', 0)} characters'
                    : '')),
    pages: jval(j, 'pages', 0),
    status: ResourceStatus.parse(jget(j, 'status') as String?),
    error: (jget(j, 'error') ?? jget(j, 'extractionError')) as String?,
  );
}

/// A directed generator pair: this generator is similar to [id].
class Similarity {
  final String id;
  final String name;
  final SimBand band;

  /// Match PERCENT, 0-100 - the module's own scale, not a 0-1 fraction. Those
  /// are the units it stores, labels ("Match %") and sets band thresholds in.
  final double score;

  /// The two component scores behind [score] (blended 0.30 lexical / 0.70
  /// semantic). Shown because a high blend built on a failed semantic pass
  /// deserves less confidence than one built on both.
  final double lexical;
  final double semantic;

  /// How the score was arrived at - see [SimMode].
  final SimMode mode;

  /// A sentence naming the evidence. The model's prose when there is one,
  /// otherwise the computed facet evidence.
  final String why;

  const Similarity({
    required this.id,
    required this.name,
    required this.band,
    required this.score,
    required this.why,
    this.lexical = 0,
    this.semantic = 0,
    this.mode = SimMode.lexical,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'band': band.wire,
    'score': score,
    'lexical': lexical,
    'semantic': semantic,
    'mode': mode.wire,
    'why': why,
  };

  factory Similarity.fromJson(Map<String, dynamic> j) => Similarity(
    id: jid(jget(j, 'id')),
    name: jval(j, 'name', ''),
    band: SimBand.parse(jget(j, 'band') as String?),
    score: jval<double>(j, 'score', 0.0),
    lexical: jval<double>(j, 'lexical', 0.0),
    semantic: jval<double>(j, 'semantic', 0.0),
    mode: SimMode.parse(jget(j, 'mode') as String?),
    why: jval(j, 'why', ''),
  );
}

/// One axis a worker judges, with the SOP's OWN answer options for THAT axis.
///
/// Axes are deliberately independent: the SOP may offer four choices on one and
/// two on another, and copying one axis's options onto another is exactly the
/// bug that made every A/B question on every project look identical.
class TaskAxis {
  const TaskAxis({
    required this.label,
    required this.options,
    this.evidence = '',
  });

  /// The SOP's own wording for the axis.
  final String label;

  /// The SOP's own answer labels, in SOP order.
  final List<String> options;

  /// A short verbatim SOP quote proving this axis and these options.
  final String evidence;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'label': label,
    'options': options,
    'evidence': evidence,
  };

  factory TaskAxis.fromJson(Map<String, dynamic> j) => TaskAxis(
    label: jval(j, 'label', ''),
    options: ((jget(j, 'options') ?? const <dynamic>[]) as List<dynamic>)
        .map((dynamic o) => '$o')
        .where((String o) => o.trim().isNotEmpty)
        .toList(),
    evidence: jval(j, 'evidence', ''),
  );
}

/// One task the SOP defines, with the contract an answer to it must satisfy.
///
/// The platform can assess a task shape nobody wrote code for because this is
/// read from the SOP at extraction time: the axes, their options, how many
/// assets a candidate is shown, and whether a justification is required.
class SopTask {
  const SopTask({
    required this.key,
    required this.display,
    this.oneSentence = '',
    this.subjectInputs = '',
    this.workerOutput = '',
    this.response = '',
    this.axes = const <TaskAxis>[],
    this.assetsPerQuestion = 0,
    this.justification = '',
    this.solutionShape = '',
  });

  /// Faceted key, e.g. `task:compare-ai-images`.
  final String key;

  /// Verb-first plain English, e.g. "Compare Two AI Images (A/B)".
  final String display;
  final String oneSentence;

  /// What the worker looks at for THIS task.
  final String subjectInputs;

  /// What the worker produces for THIS task.
  final String workerOutput;

  /// The response primitive: single_choice, compare_two, annotate_image, ...
  final String response;
  final List<TaskAxis> axes;
  final int assetsPerQuestion;

  /// 'required' | 'optional' | 'none'.
  final String justification;
  final String solutionShape;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    'display': display,
    'one_sentence': oneSentence,
    'subject_inputs': subjectInputs,
    'worker_output': workerOutput,
    'answer_contract': <String, dynamic>{
      'response': response,
      'dimensions': axes.map((TaskAxis a) => a.toJson()).toList(),
      'assets_per_question': assetsPerQuestion,
      'justification': justification,
      'solution_shape': solutionShape,
    },
  };

  factory SopTask.fromJson(Map<String, dynamic> j) {
    // The contract is nested under `answer_contract` on the wire; flattening it
    // here keeps every reader from having to know that.
    final Map<String, dynamic> c =
        (jget(j, 'answer_contract') as Map<String, dynamic>?) ??
        const <String, dynamic>{};
    return SopTask(
      key: jval(j, 'key', ''),
      display: jval(j, 'display', ''),
      oneSentence: jval(j, 'one_sentence', ''),
      subjectInputs: jval(j, 'subject_inputs', ''),
      workerOutput: jval(j, 'worker_output', ''),
      response: jval(c, 'response', ''),
      axes: ((jget(c, 'dimensions') ?? const <dynamic>[]) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(TaskAxis.fromJson)
          .toList(),
      assetsPerQuestion: jval<int>(c, 'assets_per_question', 0),
      justification: jval(c, 'justification', ''),
      solutionShape: jval(c, 'solution_shape', ''),
    );
  }
}

/// A reusable task template: the shape of ONE task, saved once and generated
/// from many times.
///
/// The structure is the Form Studio designer's own `sections` document, which is
/// what lets the existing designer author a template with no translation layer.
class TaskTemplate {
  const TaskTemplate({
    required this.id,
    required this.name,
    this.instructions = '',
    this.response = 'single_choice',
    this.questionType = '',
    this.structure = const <dynamic>[],
    this.itemCount = 0,
    this.usableCount = 0,
    this.shapeSummary = '',
    this.authoredBy = 'manual',
    this.rubricCriteria = '',
    this.rubricPassCondition = '',
    this.rubricConstraints = '',
    this.annotationTargets = '',
    this.annotationExpectedCount = 0,
    this.mediaBrief = '',
    this.shapeWarnings = const <String>[],
    this.originId,
    this.originName = '',
    this.updatedAt = '',
  });

  final int id;
  final String name;

  /// What the generator is told this shape is for. Never shown to a candidate.
  final String instructions;

  /// The response primitive the candidate performs.
  final String response;

  /// The stored question type [response] maps to. Derived server-side.
  final String questionType;

  /// Form Studio `sections`, verbatim.
  final List<dynamic> structure;
  final int itemCount;

  /// How many of [itemCount] would ACTUALLY generate.
  ///
  /// Lower than [itemCount] when an item has no usable shape at all - no
  /// title, or a choice question with fewer than two options. A MISSING
  /// ANSWER KEY DOES NOT COUNT AGAINST IT: a reusable template deliberately
  /// has none, because the key belongs to each generated instance. An earlier
  /// version judged templates with Form Studio's publish validator and so
  /// reported healthy templates as broken.
  final int usableCount;

  /// One gradable criterion per line - the rubric CHECKLIST a written answer is
  /// marked against. Empty for primitives that are not graded by rubric.
  final String rubricCriteria;

  /// What a passing answer must do, in the examiner's words.
  final String rubricPassCondition;

  /// Limits the answer must respect (length, tone, what to avoid).
  final String rubricConstraints;

  /// One expected annotation per line - what the candidate must mark.
  final String annotationTargets;

  /// How many marks a complete answer has. 0 derives it from the target list.
  final int annotationExpectedCount;

  /// What the generated image or clip must show, in the examiner's words.
  final String mediaBrief;

  /// True when some questions would silently not generate.
  bool get isPartlyBroken => usableCount < itemCount;

  /// True when NOTHING would generate - picking this spends money for zero.
  bool get isUnusable => itemCount > 0 && usableCount == 0;

  /// What this template actually ASKS, in one line: the first question's own
  /// wording plus its option count. Distinct from [name] because an LLM
  /// draft's name is often the generic shape ("Compare AI-Generated Images")
  /// while every SOP's own axis wording differs - this is the line that lets
  /// an operator tell two identically-named templates apart in the picker.
  final String shapeSummary;

  /// 'manual' or 'llm_edited'. There is no plain 'llm': an unedited draft is
  /// never saved.
  final String authoredBy;

  /// What the module computes as WRONG with this template, one per entry.
  ///
  /// Persisted server-side and recomputed on every edit, so it outlives the
  /// drafting toast: a warning that lived only in a `toaster.info` was gone on
  /// dismiss, on reload, and to anyone who opened the template later - leaving
  /// a template that would generate the wrong thing looking identical to one
  /// that would not. Empty when nothing is wrong.
  final List<String> shapeWarnings;

  /// The generator whose SOP this was authored against. NULL is normal - a
  /// template outlives its origin.
  final int? originId;
  final String originName;
  final String updatedAt;

  /// The quota key that addresses this template, e.g. `template:7`.
  String get shapeKey => 'template:$id';

  bool get isModelDrafted => authoredBy == 'llm_edited';

  factory TaskTemplate.fromJson(Map<String, dynamic> j) {
    final Map<String, dynamic>? origin =
        jget(j, 'origin') as Map<String, dynamic>?;
    return TaskTemplate(
      id: jval<int>(j, 'id', 0),
      name: jval(j, 'name', ''),
      instructions: jval(j, 'instructions', ''),
      response: jval(j, 'response', 'single_choice'),
      questionType: jval(j, 'question_type', ''),
      structure: (jget(j, 'structure') ?? const <dynamic>[]) as List<dynamic>,
      itemCount: jval<int>(j, 'item_count', 0),
      // Defaults to item_count, not 0: an older server that does not
      // send this field must not make every template look unusable.
      usableCount: jval<int>(j, 'usable_count', jval<int>(j, 'item_count', 0)),
      shapeSummary: jval(j, 'shape_summary', ''),
      authoredBy: jval(j, 'authored_by', 'manual'),
      rubricCriteria: jval(j, 'rubric_criteria', ''),
      rubricPassCondition: jval(j, 'rubric_pass_condition', ''),
      rubricConstraints: jval(j, 'rubric_constraints', ''),
      annotationTargets: jval(j, 'annotation_targets', ''),
      annotationExpectedCount: jval<int>(j, 'annotation_expected_count', 0),
      mediaBrief: jval(j, 'media_brief', ''),
      shapeWarnings: <String>[
        for (final dynamic w in jlist(jget(j, 'shape_warnings')))
          if ('$w'.trim().isNotEmpty) '$w'.trim(),
      ],
      originId: origin == null ? null : jval<int>(origin, 'id', 0),
      originName: origin == null ? '' : jval(origin, 'name', ''),
      updatedAt: jval(j, 'updated_at', ''),
    );
  }

  Map<String, dynamic> toWire() => <String, dynamic>{
    if (id > 0) 'id': id,
    'name': name,
    'instructions': instructions,
    'response': response,
    'structure': structure,
    'authored_by': authoredBy,
    // The examiner's own answer-key data. Always sent so clearing a field
    // actually clears it server-side; a primitive that does not use one just
    // sends it empty.
    'rubric_criteria': rubricCriteria,
    'rubric_pass_condition': rubricPassCondition,
    'rubric_constraints': rubricConstraints,
    'annotation_targets': annotationTargets,
    'annotation_expected_count': annotationExpectedCount,
    'media_brief': mediaBrief,
    if (originId != null && originId! > 0) 'origin_id': originId,
  };
}

/// One generator - one per source document.
class Generator {
  final String id;
  final String name;
  final String owner;

  /// When the generator was MADE. The server has only ever dated a
  /// generator with `create_date` - there is no write stamp on the wire - so
  /// the header calling this "updated" was describing a field it did not
  /// have.
  final String created;
  final String sopFile;

  /// How many drafts have been produced so far.
  final int questionCount;

  /// How many the next run will produce.
  final int plannedCount;
  final TagExtractState tagExtractState;
  final GenState sopGenState;

  /// The generator's own lifecycle - draft until its tags are extracted.
  ///
  /// Distinct from the two RUN states beside it: `sopGenState` is what the
  /// last generation did, this is what the generator IS. The server has always
  /// sent it; nothing here read it, so a half-built generator looked exactly
  /// like a finished one in the list.
  final GeneratorState state;

  /// A kill has been asked for and the run has not reached its next checkpoint.
  ///
  /// A SEPARATE FACT FROM [sopGenState], and both are needed. Generation runs
  /// in a cron worker, so a kill cannot take effect at the moment it is
  /// pressed: it raises a flag the spending lanes read before their next model
  /// call. Without this, pressing Kill left the screen looking untouched for up
  /// to a full call and invited a second press.
  final bool cancelRequested;

  /// Stop pressed on Extract skills, not yet settled by the server. The same
  /// cooperative kill as [cancelRequested]: the reply of the call already on
  /// the wire is not applied when it lands.
  final bool tagExtractCancelRequested;

  /// Empty until skills are extracted.
  final List<QType> allowedTypes;

  /// The server's own codes for the allowed types this build does not know
  /// ([QType.unsupported] in [allowedTypes]). See [typeCodes].
  final List<String> unknownTypeCodes;

  /// [types] as the server spells them (L2). "unsupported" is not a code:
  /// posting it got the whole list refused and locked the picker, so an
  /// unknown type goes back exactly as the server sent it.
  List<String> typeCodes(List<QType> types) => <String>[
    for (final QType t in types)
      if (t != QType.unsupported) t.wire,
    ...unknownTypeCodes,
  ];

  /// How many items of each SHAPE the examiner asked for, e.g.
  /// `{'mcq': 2, 'subjective_rubric': 3, 'template:7': 2}`.
  ///
  /// A key is either a question type or a saved task template. Generation
  /// treats these as a FLOOR - the requested total rises to their sum rather
  /// than dropping one of the examiner's choices - so the screen DERIVES its
  /// total from these instead of storing a second number that could disagree.
  final Map<String, int> shapeQuotas;

  /// Every distinct task the SOP defines, primary first, each carrying its own
  /// answer contract (the SOP's own axis labels and per-axis options).
  ///
  /// One entry for a single-task SOP; more when the SOP teaches several jobs.
  /// This is what lets the platform assess a task shape it has never seen.
  final List<SopTask> tasks;

  final List<Resource> resources;

  /// Facet-prefixed, e.g. `domain:logistics`.
  final List<String> tags;

  /// The fourteen-field skill bundle.
  final Map<String, String> meta;
  final List<Similarity> similar;

  // ── Parity with the Odoo generator form ─────────────────────────────────
  //
  // The detail route has always sent these and the client dropped them, so the
  // console could not show what the back office shows. A field the server
  // sends and the client ignores is worse than a missing one - it looks like
  // the data is absent.

  /// Files attached, per the server's own count. Cheaper than `resources.length`
  /// on a LIST row, which carries no resource rows at all.
  final int resourceCount;

  /// Drafts promoted into the bank.
  final int approvedCount;

  /// Generators whose SOP looks like this one's.
  final int similarCount;

  /// Free-text appended to the source material the model reads.
  ///
  /// The server has always sent and accepted this (`source_text`) and no
  /// screen showed it, so the one way to steer a run in words was Odoo.
  final String sourceText;

  /// False once retired. An archived generator KEEPS the questions it
  /// authored, and those questions keep their link back to the document that
  /// justified them - which is why retiring exists instead of deleting.
  final bool active;

  /// Deleted while an assessment uses it: inactive too, never restorable,
  /// listed only under "Show deleted". Its papers and results are kept.
  final bool deleted;

  /// Extracted question structures, and how many are selected for generation.
  final int structureCount;
  final int selectedStructureCount;

  /// `auto` (the model decides) or `fixed` (use [sopQuestionCount]).
  final String questionCountMode;

  /// The pinned number, meaningful only when [questionCountMode] is `fixed`.
  final int sopQuestionCount;

  /// The ceiling on how many labels ONE image-labelling question may carry.
  ///
  /// Per GENERATOR, not per assessment. The same document produces the same
  /// shape of question on every run, so the limit belongs beside the count
  /// that decides how many questions a run authors - setting it on the
  /// assessment would mean re-stating it for every paper drawn from the same
  /// SOP, and the two could then disagree about a question already written.
  ///
  /// Defaults to 20, the module's own default, rather than to 0. A generator
  /// parsed from a LIST row carries no `image_label_count`, and a 0 in the
  /// stepper reads as "no labels allowed" over a server that would accept
  /// twenty - the same class of invented number `plannedCount` had to stop
  /// printing. The module refuses anything below 1, which is why the control
  /// floors at 1 instead of offering a 0 the save would bounce.
  final int imageLabelCount;

  /// Image labelling pictures are screenshots of live websites instead of
  /// AI-made. Off by default: only a project that asks for it (High Res
  /// Dense). Detail-only, like [imageLabelCount].
  final bool imageLabelLiveCapture;

  /// `all` or a narrower selection of extracted structures.
  final String structureMode;

  /// Why the last run failed, empty when it did not. Shown verbatim: a
  /// generation failure the operator cannot read is a support ticket.
  final String sopGenError;
  final String tagExtractError;

  /// What the last generation run YIELDED: drafts created, items rejected and
  /// why. Present whether or not the run errored.
  ///
  /// A run can finish clean and produce nothing - the model returns items and
  /// validation throws every one of them out - and that is neither an error nor
  /// a success. Without this the screen showed "Done" beside "Nothing generated
  /// yet" and the reason lived only in a server log, so the examiner who paid
  /// for the call had no way to learn what happened.
  final String sopGenReport;

  /// When skills were last pulled out of the SOP, and what came back.
  final String tagExtractLastRun;
  final String lastExtractSummary;

  /// When the last generation run started and ended. Null on runs from
  /// before the server stamped them (§4.9).
  final DateTime? sopGenStartedAt;
  final DateTime? sopGenFinishedAt;

  /// Drafts by review state. DETAIL-ONLY: the list row does not send it.
  final GenLane draftCounts;

  const Generator({
    required this.id,
    required this.name,
    this.owner = '',
    this.created = '',
    this.sopFile = '',
    this.questionCount = 0,
    this.plannedCount = 12,
    this.tagExtractState = TagExtractState.idle,
    this.sopGenState = GenState.idle,
    this.state = GeneratorState.draft,
    this.cancelRequested = false,
    this.tagExtractCancelRequested = false,
    this.allowedTypes = const <QType>[],
    this.unknownTypeCodes = const <String>[],
    this.shapeQuotas = const <String, int>{},
    this.tasks = const <SopTask>[],
    this.resources = const <Resource>[],
    this.tags = const <String>[],
    this.meta = const <String, String>{},
    this.similar = const <Similarity>[],
    this.resourceCount = 0,
    this.approvedCount = 0,
    this.similarCount = 0,
    this.active = true,
    this.deleted = false,
    this.sourceText = '',
    this.structureCount = 0,
    this.selectedStructureCount = 0,
    this.questionCountMode = 'auto',
    this.sopQuestionCount = 0,
    this.imageLabelCount = 20,
    this.imageLabelLiveCapture = false,
    this.structureMode = 'all',
    this.sopGenError = '',
    this.sopGenReport = '',
    this.tagExtractError = '',
    this.tagExtractLastRun = '',
    this.lastExtractSummary = '',
    this.sopGenStartedAt,
    this.sopGenFinishedAt,
    this.draftCounts = const GenLane(),
  });

  bool get countIsAuto => questionCountMode != 'fixed';

  /// The smallest number of questions a run will ask for: every explicit
  /// quota, plus ONE for each ticked type that carries no quota.
  ///
  /// A type with no count shows an "any" chip, and that has always been
  /// documented as a coverage floor of one - but the floor was built from the
  /// quotas alone, so "any" was worth nothing. Two things followed: ticking
  /// another type left the total on screen unchanged, and `MSQ x3` plus
  /// `Rubric x any` displayed 3 on a run that asked for 4.
  ///
  /// A type carrying its own quota is counted by that quota, never twice.
  int get quotaFloor {
    final int asked = shapeQuotas.values.fold(0, (int a, int b) => a + b);
    final int loose = allowedTypes
        .where((QType t) => !shapeQuotas.containsKey(t.wire))
        .length;
    return asked + loose;
  }

  /// What a run will actually target.
  ///
  /// MIRRORS `effective_generation_count` IN `constants.py`, and must: this is
  /// the number the count field, the help line and the Generate button all
  /// print, while the server is what the run is placed with. When the two
  /// disagreed, the screen said one thing and the model was asked for another.
  ///
  /// The floor RAISES a total that is too small and never caps one that is
  /// large enough, so "20 across these three types" stays expressible.
  int get effectiveQuestionCount {
    final int floor = quotaFloor;
    if (floor == 0) return sopQuestionCount;
    return sopQuestionCount > floor ? sopQuestionCount : floor;
  }

  /// Something went wrong on the last run, either half.
  String? get lastError {
    if (sopGenError.isNotEmpty) return sopGenError;
    if (tagExtractError.isNotEmpty) return tagExtractError;
    return null;
  }

  /// Why the EXTRACTION failed, or null if it did not.
  ///
  /// Narrower than [lastError] on purpose. The three surfaces that report a
  /// failed extraction are reached only when there are no tags, and there a
  /// leftover `sopGenError` from an older generation run would name the wrong
  /// half of the pipeline.
  ///
  /// THE BUG THIS EXISTS FOR. The module records the reason in
  /// `tag_extract_error` and the payload carries it, but the console rendered
  /// it in exactly one place - the Generation tab - behind an early return
  /// taken whenever there are no tags. So the only screen that could explain a
  /// failure was the one screen a failure made unreachable: the run went
  /// "Extracting...", then back to "has not read its document yet", with the
  /// reason parsed and dropped.
  ///
  /// `failed` with an empty message is a real state - the cron can die between
  /// writing the state and writing the reason - so the state alone is enough
  /// to report the failure, and the message is what it can add.
  String? get tagFailure {
    if (tagExtractError.isNotEmpty) return tagExtractError;
    if (tagExtractState == TagExtractState.failed) {
      return 'The server did not record a reason. Check the generator '
          'history and the LLM budget screen, then try again.';
    }
    return null;
  }

  /// Files attached, whichever the payload carried: a LIST row has the count
  /// only, a DETAIL row has the rows themselves.
  int get fileCount => resources.isEmpty ? resourceCount : resources.length;

  bool get hasTags => tags.isNotEmpty;

  /// Work is outstanding: queued, generating or finalizing.
  ///
  /// Asks [GenState.isBusy] rather than naming one state, so the button
  /// stays disabled for the whole run instead of re-enabling the moment
  /// the cron moves from `queued` to `generating`.
  bool get isGenerating => sopGenState.isBusy;

  /// Whether the Kill button should be offered at all.
  ///
  /// Not shown once a kill is already in flight: the run cannot be stopped
  /// twice, and a second press would only look like the first one had failed.
  bool get canCancelGeneration => sopGenState.isCancellable && !cancelRequested;

  /// A kill is in flight. The screen says "Stopping..." rather than pretending
  /// the run has already ended - it stops at its next model call, which can be
  /// one call away.
  bool get isStopping => cancelRequested && sopGenState.isBusy;

  /// Whether Extract skills can be stopped: it is running and not already
  /// being stopped.
  bool get canCancelTagExtract =>
      isExtractingTags && !tagExtractCancelRequested;

  /// Extract skills was stopped and the server has not settled it yet.
  bool get isStoppingTagExtract =>
      tagExtractCancelRequested && isExtractingTags;

  /// Tag extraction is outstanding, according to the SERVER.
  ///
  /// Read from `tag_extract_state`, never from a local in-flight flag. The
  /// work runs in a cron, so it outlives the tab that asked for it: an
  /// in-memory busy key vanished on reload and left a fully clickable
  /// "Extract skills" button over a run that was still going, which is an
  /// invitation to spend a second LLM call on the same document.
  bool get isExtractingTags =>
      tagExtractState == TagExtractState.queued ||
      tagExtractState == TagExtractState.generating;

  /// A generator the module has labelled a near-duplicate of something else is
  /// flagged in the list, because that is the one band whose advice is "look
  /// before you build".
  bool get possibleDuplicate =>
      similar.any((Similarity s) => s.band == SimBand.nearDuplicate);

  Generator copyWith({
    String? name,
    String? owner,
    String? created,
    String? sopFile,
    int? questionCount,
    int? plannedCount,
    TagExtractState? tagExtractState,
    GenState? sopGenState,
    GeneratorState? state,
    bool? cancelRequested,
    bool? tagExtractCancelRequested,
    List<QType>? allowedTypes,
    Map<String, int>? shapeQuotas,
    List<SopTask>? tasks,
    List<Resource>? resources,
    List<String>? tags,
    Map<String, String>? meta,
    List<Similarity>? similar,
    // Detail-only, and overridable so a merge can preserve them across a list
    // refresh - the list route does not send either.
    int? sopQuestionCount,
    int? imageLabelCount,
    bool? imageLabelLiveCapture,
    String? questionCountMode,
    String? sourceText,
    GenLane? draftCounts,
  }) => Generator(
    id: id,
    name: name ?? this.name,
    owner: owner ?? this.owner,
    created: created ?? this.created,
    sopFile: sopFile ?? this.sopFile,
    questionCount: questionCount ?? this.questionCount,
    plannedCount: plannedCount ?? this.plannedCount,
    tagExtractState: tagExtractState ?? this.tagExtractState,
    sopGenState: sopGenState ?? this.sopGenState,
    state: state ?? this.state,
    cancelRequested: cancelRequested ?? this.cancelRequested,
    tagExtractCancelRequested:
        tagExtractCancelRequested ?? this.tagExtractCancelRequested,
    allowedTypes: allowedTypes ?? this.allowedTypes,
    unknownTypeCodes: unknownTypeCodes,
    shapeQuotas: shapeQuotas ?? this.shapeQuotas,
    tasks: tasks ?? this.tasks,
    resources: resources ?? this.resources,
    tags: tags ?? this.tags,
    meta: meta ?? this.meta,
    similar: similar ?? this.similar,
    // Carried through, not defaulted. A copyWith that silently drops server
    // fields is how the roster's marks reset to "0 / 0" on every local edit -
    // same class of bug, so every field added above is listed here.
    resourceCount: resourceCount,
    approvedCount: approvedCount,
    similarCount: similarCount,
    active: active,
    deleted: deleted,
    sourceText: sourceText ?? this.sourceText,
    structureCount: structureCount,
    selectedStructureCount: selectedStructureCount,
    questionCountMode: questionCountMode ?? this.questionCountMode,
    sopQuestionCount: sopQuestionCount ?? this.sopQuestionCount,
    imageLabelCount: imageLabelCount ?? this.imageLabelCount,
    imageLabelLiveCapture: imageLabelLiveCapture ?? this.imageLabelLiveCapture,
    structureMode: structureMode,
    sopGenError: sopGenError,
    sopGenReport: sopGenReport,
    tagExtractError: tagExtractError,
    tagExtractLastRun: tagExtractLastRun,
    lastExtractSummary: lastExtractSummary,
    sopGenStartedAt: sopGenStartedAt,
    sopGenFinishedAt: sopGenFinishedAt,
    draftCounts: draftCounts ?? this.draftCounts,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'owner': owner,
    'created': created,
    'sopFile': sopFile,
    'questionCount': questionCount,
    'plannedCount': plannedCount,
    'tagExtractState': tagExtractState.wire,
    'sopGenState': sopGenState.wire,
    'sopGenReport': sopGenReport,
    'allowedTypes': typeCodes(allowedTypes),
    'shape_quotas': shapeQuotas,
    'tasks': tasks.map((SopTask t) => t.toJson()).toList(),
    'resources': resources.map((Resource r) => r.toJson()).toList(),
    'tags': tags,
    'meta': meta,
    'similar': similar.map((Similarity s) => s.toJson()).toList(),
    'active': active,
    'sourceText': sourceText,
    'imageLabelCount': imageLabelCount,
    'imageLabelLiveCapture': imageLabelLiveCapture,
  };

  /// The resource rows, from wherever this payload happens to carry them.
  ///
  /// The DETAIL route sends `tabs.resources` AND an empty root `resources`; the
  /// fixtures send only the root. A `??` chain reads the root first, and an
  /// empty list is not null, so it won and the corpus tab reported "No files
  /// attached" over a stored document. Whichever list has rows wins.
  static List<dynamic> _resourceRows(Map<String, dynamic> j) {
    final Object? root = jget(j, 'resources');
    if (root is List<dynamic> && root.isNotEmpty) return root;
    final Object? tabs = jget(j, 'tabs');
    if (tabs is Map<String, dynamic>) {
      final Object? nested = jget(tabs, 'resources');
      if (nested is List<dynamic>) return nested;
    }
    return root is List<dynamic> ? root : const <dynamic>[];
  }

  /// Parses either shape: the seed fixtures (camelCase) or a live
  /// `/api/v1/generators` row (snake_case, integer id).
  ///
  /// Every read goes through [jget]/[jval]/[jid]. Reading `j['id'] as String`
  /// threw on the wire, because Odoo sends `"id": 2` as an integer - and that
  /// TypeError escaped `refresh()`, which caught only ApiError, so the screen
  /// span a loader forever with every list empty behind it.
  factory Generator.fromJson(Map<String, dynamic> j) => Generator(
    id: jid(jget(j, 'id')),
    name: jval(j, 'name', ''),
    owner: jval(j, 'owner', ''),
    // `create_date` is the ONLY date the API puts on a generator, which is
    // why this is `created` and not `updated`: the header spent its life
    // labelling a creation stamp as a modification one. Humanised here rather
    // than at each call site - the raw value is ISO-8601 and was reaching the
    // header as "updated 2026-08-12T08:57:14Z". `humanWhen` passes a non-date
    // through untouched, so the fixtures' own '2 days ago' strings survive.
    created: humanWhen(jval(j, 'created', jval(j, 'createDate', ''))),
    // `sop_title` is the module's name for the attached document.
    sopFile: jval(j, 'sopFile', jval(j, 'sopTitle', '')),
    questionCount: jval(j, 'questionCount', 0),
    // 0, not 12. A hardcoded 12 was a number the server never sent: the
    // Generation tab printed "Generate 12 questions" on a generator set to
    // `auto`, which is a promise about a count nobody chose. `sopQuestionCount`
    // is the real pinned value and is 0 when the mode is auto.
    plannedCount: jval(j, 'plannedCount', jval(j, 'sopQuestionCount', 0)),
    tagExtractState: TagExtractState.parse(
      jget(j, 'tagExtractState') as String?,
    ),
    sopGenState: GenState.parse(jget(j, 'sopGenState') as String?),
    state: GeneratorState.parse(jget(j, 'state') as String?),
    cancelRequested: jget(j, 'sopGenCancelRequested') as bool? ?? false,
    tagExtractCancelRequested: jval(j, 'tagExtractCancelRequested', false),
    sopGenReport: jval(j, 'sopGenReport', ''),
    allowedTypes:
        ((jget(j, 'allowedTypes') ?? const <dynamic>[]) as List<dynamic>)
            .map((dynamic t) => QType.parse(t.toString()))
            .toList(),
    unknownTypeCodes: <String>[
      for (final dynamic t
          in (jget(j, 'allowedTypes') ?? const <dynamic>[]) as List<dynamic>)
        if (QType.parse(t.toString()) == QType.unsupported) t.toString(),
    ],
    // PER-SHAPE COUNTS. Coerced to int because JSON has no integer type and a
    // count arriving as 2.0 is still a request for two items.
    shapeQuotas: <String, int>{
      for (final MapEntry<String, dynamic> e
          in ((jget(j, 'shape_quotas') ?? const <String, dynamic>{})
                  as Map<String, dynamic>)
              .entries)
        if (e.value is num && (e.value as num) > 0)
          e.key: (e.value as num).toInt(),
    },
    // EVERY task the SOP defines, each with its own axes and options.
    tasks: ((jget(j, 'tasks') ?? const <dynamic>[]) as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map(SopTask.fromJson)
        .toList(),
    // Root vs the DETAIL payload's `tabs.resources` - see `_resourceRows` for
    // why `??` alone was not enough. Whichever list has rows wins.
    resources: _resourceRows(
      j,
    ).map((dynamic r) => Resource.fromJson(r as Map<String, dynamic>)).toList(),
    // The API sends tag OBJECTS, the fixtures send bare strings.
    tags: jtags(j),
    meta:
        ((jget(j, 'meta') ?? const <String, dynamic>{}) as Map<String, dynamic>)
            .map((String k, dynamic v) => MapEntry<String, String>(k, '$v')),
    similar: ((jget(j, 'similar') ?? const <dynamic>[]) as List<dynamic>)
        .map((dynamic s) => Similarity.fromJson(s as Map<String, dynamic>))
        .toList(),
    resourceCount: jval(j, 'resourceCount', 0),
    approvedCount: jval(j, 'approvedCount', 0),
    similarCount: jval(j, 'similarCount', 0),
    active: jval(j, 'active', true),
    deleted: jval(j, 'deleted', false),
    sourceText: jval(j, 'sourceText', ''),
    structureCount: jval(j, 'structureCount', 0),
    selectedStructureCount: jval(j, 'selectedStructureCount', 0),
    questionCountMode: jval(j, 'questionCountMode', 'auto'),
    sopQuestionCount: jval(j, 'sopQuestionCount', 0),
    // camelCase key only: `jget` derives `image_label_count` itself, which
    // is what keeps the seed fixtures and the live payload interchangeable.
    imageLabelCount: jval(j, 'imageLabelCount', 20),
    imageLabelLiveCapture: jval(j, 'imageLabelLiveCapture', false),
    structureMode: jval(j, 'structureMode', 'all'),
    sopGenError: jval(j, 'sopGenError', ''),
    tagExtractError: jval(j, 'tagExtractError', ''),
    tagExtractLastRun: jval(j, 'tagExtractLastRun', ''),
    lastExtractSummary: jval(j, 'lastExtractSummary', ''),
    sopGenStartedAt: DateTime.tryParse(jval(j, 'sopGenStartedAt', '')),
    sopGenFinishedAt: DateTime.tryParse(jval(j, 'sopGenFinishedAt', '')),
    draftCounts: GenLane.fromJson(jget(j, 'draftCounts')),
  );
}

/// The eight proctoring rules as a value object, so a rule set can be copied
/// and compared without eight separate booleans travelling together.
class RuleSet {
  final Map<ProctorRule, bool> _on;

  const RuleSet(this._on);

  factory RuleSet.defaults() => const RuleSet(<ProctorRule, bool>{
    ProctorRule.tabSwitch: true,
    ProctorRule.copyPaste: true,
    ProctorRule.rightClick: true,
    ProctorRule.devtools: true,
    ProctorRule.fullscreen: true,
    // ON BY DEFAULT. The operator asked for a webcam requirement out of the
    // box: a proctored sitting that does not watch the camera is the gap they
    // were closing, so a fresh rule set turns it on rather than leaving it to
    // be remembered per assessment.
    ProctorRule.webcam: true,
    ProctorRule.watermark: true,
    // [ProctorRule.seb] is left out, so OFF, and no admin surface offers it
    // any more (see [switches]).
  });

  bool operator [](ProctorRule r) => _on[r] ?? false;

  /// Every rule with its state, for sending to the server. Complete rather
  /// than sparse: an omitted rule would leave the module's default in place,
  /// which is not the same as the operator having switched it off.
  Map<ProctorRule, bool> get asMap => <ProctorRule, bool>{
    for (final ProctorRule r in ProctorRule.values) r: this[r],
  };

  RuleSet toggle(ProctorRule r) =>
      RuleSet(<ProctorRule, bool>{..._on, r: !(this[r])});

  /// Turning a rule OFF turns off every rule that needs it
  /// ([ProctorRule.parent]), so the save is one write the server accepts:
  /// webcam off takes AI proctoring with it.
  RuleSet set(ProctorRule r, bool v) {
    RuleSet next = RuleSet(<ProctorRule, bool>{..._on, r: v});
    if (!v) {
      for (final ProctorRule child in ProctorRule.values) {
        if (child.parent == r) next = next.set(child, false);
      }
    }
    return next;
  }

  /// "Turn on AI proctoring first." when turning [r] on needs a parent that
  /// is off, else null. The server refuses that write; this says why first.
  String? needsFirst(ProctorRule r) {
    final ProctorRule? p = r.parent;
    return p != null && !this[p] ? 'Turn on ${p.label} first.' : null;
  }

  /// The rules that are on, in declaration order - what the exam instructions
  /// page lists back to the candidate.
  List<ProctorRule> get enabled =>
      ProctorRule.values.where((ProctorRule r) => this[r]).toList();

  /// The subset the proctoring simulator can fire.
  List<ProctorRule> get firable =>
      enabled.where((ProctorRule r) => r.firesViolation).toList();

  /// The switches the two admin surfaces show, in declaration order. Safe
  /// Exam Browser is no longer offered (owner, 20 Oct): its switch shows only
  /// while it is on, so a paper that already has it can be switched off and
  /// nothing can switch it on.
  List<ProctorRule> get switches => ProctorRule.values
      .where((ProctorRule r) => r != ProctorRule.seb || this[r])
      .toList();

  Map<String, dynamic> toJson() => <String, dynamic>{
    for (final ProctorRule r in ProctorRule.values) r.wire: this[r],
  };

  factory RuleSet.fromJson(Map<String, dynamic> j) =>
      RuleSet(<ProctorRule, bool>{
        for (final ProctorRule r in ProctorRule.values)
          r: (j[r.wire] ?? false) as bool,
      });
}

class Assessment {
  final String id;
  final String name;
  final AsmState state;

  /// False once archived. Odoo's own soft-delete, and the model's help text
  /// calls it "the safe alternative to deleting" - a finished assessment can
  /// never be erased without destroying the candidate results attached to it.
  ///
  /// Visibility only, and orthogonal to [state]: an in-progress sitting can be
  /// archived without stopping it. Everything that must not COUNT an archived
  /// assessment goes through `AppStore.visibleAssessments`, which drops them.
  final bool active;

  final String generatorId;
  final String generatorName;

  /// Optional tag; controls manager visibility, not eligibility.
  final String? projectId;
  final DateTime? startDate;
  final DateTime? endDate;

  /// When the assessment was launched (`launched_at`, UTC), or null for a draft.
  /// The server falls back to `start_date` for rows launched before it kept
  /// the stamp, so a null here means "never launched", not "unknown".
  final DateTime? launchedAt;

  /// Minutes. At least 2 - every assessment is timed.
  ///
  /// 0 used to mean "no limit". It does not any more: an untimed sitting never
  /// gets a deadline, so the server's expiry sweep skipped it and the attempt
  /// could never be settled.
  final int durationMinutes;

  /// 0 means the whole selection.
  final int questionLimit;

  /// Frozen at creation.
  final List<Question> questions;

  /// Every question this assessment MAY draw from - the choice, not the pick.
  ///
  /// On a DRAFT this is the generator's servable set, so the Selected Questions
  /// tab has something to show: `questions` is empty until the server's
  /// `action_start` writes it, and reading the tab off `questions` alone printed
  /// "0 questions" on a draft whose generator held twenty.
  ///
  /// ONCE LAUNCHED it is still the generator's servable set: a question the
  /// operator excluded before launching stays listed with its tick off, because
  /// the tab's job is to record which questions this paper draws and which it
  /// does not. Every tick is inert in that state - frozen, not hidden.
  final List<Question> pool;

  /// Which of [pool] the operator has shortlisted onto this assessment.
  ///
  /// The tick is the ASSESSMENT'S property, not the question's - the same bank
  /// question is in use on one assessment and out on another - so it lives here
  /// rather than as a flag on [Question].
  ///
  /// An EMPTY server-side shortlist arrives as every id present, because the
  /// server reads "nothing shortlisted" as "the whole generator". So this set
  /// is never legitimately empty while [pool] is not, and [inUseCount] can be
  /// trusted as the size of the paper about to be drawn.
  final Set<String> inUseIds;

  // Roll-up counters as reported by the API's list endpoint.
  //
  // A list row carries no nested questions or attempts - the API sends those
  // only on the detail endpoints - so a screen cannot derive these by counting
  // what it has in hand. They are -1 when unknown (the seed fixtures, which
  // DO carry the full object graph), and every reader is expected to fall back
  // to counting in that case. -1 rather than 0 because 0 is a legitimate
  // count and would be indistinguishable from "not sent".
  final int questionsAvailable;
  final int assignedCount;
  final int submittedCount;
  final int releasableCount;
  final int releasedCount;
  final int awaitingScoringCount;
  final int responseCount;

  /// What the SERVER says its scoring cron is doing on this assessment.
  ///
  /// NULL MEANS THE PAYLOAD DID NOT CARRY IT - an older deployment - and that
  /// has to stay distinguishable from [ScoringPhase.idle], which is a positive
  /// "there is nothing to stop". It is the same distinction the counters above
  /// draw with -1, made with the type system instead: a phase has no spare
  /// value to spend as a sentinel, and inventing one would put "not sent" and
  /// "not running" in the same bucket. See the Kill button's gate in
  /// `assessment_detail_screen.dart`, which falls back to its own derivation
  /// on null and trusts the server otherwise.
  final ScoringPhase? scoringPhase;

  /// The server's one-line breakdown beside [scoringPhase], e.g.
  /// `238 queued  ·  1 scoring  ·  464 scored`. Empty when there is nothing
  /// to report.
  ///
  /// RENDERED VERBATIM. The module composes it next to the predicate it counts
  /// with, so a sentence re-derived here could only ever disagree with the
  /// phase printed beside it.
  final String scoringSummary;

  /// A finished run's report, for "Scored 630/630 candidates on Sep 21, 2026
  /// at 10:04pm": submitted candidates graded, all submitted, and when the
  /// last one finished. -1 / null when the server did not send them.
  final int scoringScored;
  final int scoringCandidates;
  final DateTime? scoringFinishedAt;

  /// Compared against the internal percentage.
  final double passThreshold;

  /// The bar a written answer must clear to earn its mark.
  final double subjectiveThreshold;

  /// True when a threshold change is queued rather than already applied.
  ///
  /// The server recomputes inline for a small assessment and defers to a cron
  /// for a large one (over 500 graded answers). Without showing this, an
  /// operator moves the threshold, sees the OLD pass/fail, and reasonably
  /// concludes the change did nothing.
  final bool thresholdRecomputePending;

  /// The invited people, BEFORE launch creates their attempts.
  ///
  /// `/candidates` lists attempt records, and those only exist once an
  /// assessment is launched. Somebody invited to a draft was stored correctly
  /// on the server and shown nowhere, so the Assign tab read "0" and the
  /// invitation looked like it had failed.
  final List<Person> roster;

  /// Whether each candidate gets the questions in a randomised order.
  ///
  /// THE INVERSE OF THE MODULE'S `preserve_question_order`. The server stores
  /// the negative - "keep the authored order" - and this app carries the
  /// positive an operator actually reasons about, so the switch reads
  /// "Shuffle questions" rather than a double negative. The two are flipped at
  /// the wire in [fromJson] and in the api client's create/update, so neither
  /// side ever holds the other's polarity.
  ///
  /// DEFAULTS TO TRUE. A fixed order lets two candidates sitting side by side
  /// read each other's screens position-for-position, which is the whole
  /// reason the shuffle exists; anyone who wants the authored order turns it
  /// off deliberately.
  final bool shuffleQuestions;

  /// Governance gate at launch.
  final bool requireReviewedRubric;

  /// Whether a candidate's submit auto-queues them for the background grader.
  ///
  /// **Defaults to FALSE in the module**, and nothing in this app used to send
  /// it - so every assessment created here had LLM grading silently off. The
  /// scoring cron then drained an empty queue forever: `llm_auto_score=False`
  /// means `evaluator.write()` never sets `scoring_requested`, so subjective
  /// answers sat `pending` with zero attempts and no error anywhere.
  final bool llmAutoScore;

  /// `manual` or an automatic policy. The gate that reveals a score to a
  /// candidate - INVARIANT 3 - so it is carried explicitly rather than assumed.
  final String resultsRelease;

  /// Blends verdict and justification on image A/B.
  final RuleSet rules;

  /// The identity the watermark tiles, as the SERVER composed it.
  ///
  /// The runner used to derive this from the roster (`personById`), which a
  /// candidate never loads - so on the one surface the watermark exists for it
  /// resolved to null, `Watermark` short-circuited to an empty box, and the
  /// rule painted nothing while the instructions page listed it as active.
  /// `proctoring_rules` already builds "name  email" for the candidate the
  /// token names; carrying it is the only way the runner can know it.
  ///
  /// Empty on admin surfaces, where the serializer has no candidate to name.
  final String watermarkLabel;

  /// The password invigilators type to close Safe Exam Browser early. Admin
  /// detail only (`seb_quit_password`); never in a candidate payload.
  final String sebQuitPassword;
  final ViolationAction violationAction;

  /// The violation number at which the exam ends.
  final int maxViolations;

  /// The count that breaches the violation limit, in both modes (A-074): the
  /// cap, or the first violation under Auto-submit with no cap. Null for Log
  /// only with no cap, which has no limit to breach.
  int? get violationLimit =>
      maxViolations > 0 ? maxViolations : (violationAction.isAuto ? 1 : null);

  /// The AI proctoring pair (`ai_violation_action`, `ai_max_violations`):
  /// "AI: " reasons count against these, apart from the regular pair. A
  /// payload without them (an older server) reads as the regular pair.
  final ViolationAction aiViolationAction;
  final int aiMaxViolations;

  /// [violationLimit], for the AI count.
  int? get aiViolationLimit => aiMaxViolations > 0
      ? aiMaxViolations
      : (aiViolationAction.isAuto ? 1 : null);

  /// The action and the configured cap (0 = the first one) that a violation
  /// of this kind counts against.
  ({ViolationAction action, int cap}) policy(bool ai) => ai
      ? (action: aiViolationAction, cap: aiMaxViolations)
      : (action: violationAction, cap: maxViolations);

  /// Released candidates see the correct answers, each verdict and the
  /// grader's feedback (`results_show_answers`). Off, only their own answers
  /// and marks. Read when they open the review, so a change applies at once.
  final bool resultsShowAnswers;

  /// A transcription clip's own pass bar (`transcription_threshold`); 0
  /// follows [subjectiveThreshold]. See [barFor].
  final double transcriptionThreshold;

  /// The bar a written answer of type [t] must clear to earn its mark.
  double barFor(QType t) =>
      t == QType.transcription && transcriptionThreshold > 0
      ? transcriptionThreshold
      : subjectiveThreshold;

  Assessment({
    required this.id,
    required this.name,
    this.state = AsmState.draft,
    this.active = true,
    this.generatorId = '',
    this.generatorName = '',
    this.projectId,
    this.startDate,
    this.endDate,
    this.launchedAt,
    this.durationMinutes = 60,
    this.questionLimit = 0,
    this.questions = const <Question>[],
    this.pool = const <Question>[],
    this.inUseIds = const <String>{},
    this.questionsAvailable = -1,
    this.assignedCount = -1,
    this.submittedCount = -1,
    this.releasableCount = -1,
    this.releasedCount = -1,
    this.awaitingScoringCount = -1,
    this.responseCount = -1,
    this.scoringPhase,
    this.scoringSummary = '',
    this.scoringScored = -1,
    this.scoringCandidates = -1,
    this.scoringFinishedAt,
    // 70, not 60: DEFAULT_SUBJECTIVE_THRESHOLD in the module's constants.py.
    this.passThreshold = 70,
    this.subjectiveThreshold = 70,
    this.thresholdRecomputePending = false,
    this.roster = const <Person>[],
    this.shuffleQuestions = true,
    this.requireReviewedRubric = false,
    this.llmAutoScore = false,
    this.resultsRelease = 'manual',
    // Mirrors the module's own default. Held at `false` while the server
    // defaulted to `true`, a locally-created assessment would render its
    // Scoring tab with the switch off over a record the server had already
    // created with it on.
    RuleSet? rules,
    this.watermarkLabel = '',
    this.sebQuitPassword = '',
    this.violationAction = ViolationAction.logOnly,
    this.maxViolations = 3,
    // Copies of the regular pair unless given, as the upgrade seeds them.
    ViolationAction? aiViolationAction,
    int? aiMaxViolations,
    this.resultsShowAnswers = true,
    this.transcriptionThreshold = 0,
  }) : aiViolationAction = aiViolationAction ?? violationAction,
       aiMaxViolations = aiMaxViolations ?? maxViolations,
       rules =
           rules ??
           const RuleSet(<ProctorRule, bool>{
             ProctorRule.tabSwitch: true,
             ProctorRule.copyPaste: true,
             ProctorRule.rightClick: true,
             ProctorRule.devtools: true,
             ProctorRule.fullscreen: true,
             // ON BY DEFAULT, matching [RuleSet.defaults]. This is the default
             // an Assessment built with no `rules` gets - the seed fixtures and
             // any locally-constructed record - so it has to agree with the map
             // the create form seeds, or a fixture would render its webcam
             // switch off over the same default the form turns on.
             ProctorRule.webcam: true,
             ProctorRule.watermark: true,
           });

  int get totalQuestions => questions.length;

  /// How many questions ONE candidate sits. [questions] is the whole pool the
  /// launch draws from; each candidate gets [questionLimit] of it when that is
  /// set and smaller (`action_start`: `limit = question_limit or len(...)`).
  /// The denominator for anything counted per candidate - [totalQuestions]
  /// read "3 / 40" on a 10-question draw.
  int get paperSize => questionLimit > 0 && questionLimit < questions.length
      ? questionLimit
      : questions.length;

  /// Configuration is editable only in draft.
  bool get isEditable => state == AsmState.draft;

  /// How many of [pool] are ticked - the size of the paper about to be drawn.
  ///
  /// Counted against [pool] rather than off [inUseIds] directly, so an id left
  /// behind by a question that has since gone (retired between two loads)
  /// cannot inflate the figure the operator sizes their question limit against.
  int get inUseCount =>
      pool.where((Question q) => inUseIds.contains(q.id)).length;

  /// The questions this assessment would actually serve, right now.
  ///
  /// THE ONE COUNT THAT MIRRORS THE SERVER, and the reason it has to exist:
  /// [totalQuestions] reads `questions`, which the launch route only fills once
  /// a paper has been DRAWN. On a draft nobody has ticked, the shortlist is
  /// empty - which the module reads as "the whole generator"
  /// (`assessment.py::action_start`: `if shortlist: narrowed = ...`, then
  /// `limit = question_limit or len(available_questions)`) - so the server would
  /// launch all six while the client counted zero, refused its own launch gate,
  /// and printed "0 questions" beside a pool of six.
  ///
  /// [inUseIds] already resolves the empty case: `Assessment.fromJson` fills it
  /// from the pool rows' `in_use` flags, and the serializer marks every row in
  /// use when the shortlist is empty. So this is `inUseCount` with a fallback
  /// for the one shape that carries no pool at all - a list row, or seed data.
  ///
  /// NOT a replacement for [totalQuestions]. That one is the denominator marks
  /// are scored out of and the paper a candidate sat; this one is "what would go
  /// out if I launched now". They agree after launch, which is when it matters.
  int get effectiveQuestionCount =>
      pool.isEmpty ? questions.length : inUseCount;

  /// The questions [effectiveQuestionCount] counts, for the gates that have to
  /// look at each one rather than count them.
  List<Question> get effectiveQuestions => pool.isEmpty
      ? questions
      : pool.where((Question q) => inUseIds.contains(q.id)).toList();

  Question? questionById(String qid) {
    for (final Question q in questions) {
      if (q.id == qid) return q;
    }
    return null;
  }

  Assessment copyWith({
    String? name,
    AsmState? state,
    bool? active,
    String? generatorId,
    String? generatorName,
    String? projectId,
    DateTime? startDate,
    DateTime? endDate,
    DateTime? launchedAt,
    int? durationMinutes,
    int? questionLimit,
    List<Question>? questions,
    List<Question>? pool,
    Set<String>? inUseIds,
    double? passThreshold,
    double? subjectiveThreshold,
    bool? thresholdRecomputePending,
    ScoringPhase? scoringPhase,
    String? scoringSummary,
    int? scoringScored,
    int? scoringCandidates,
    DateTime? scoringFinishedAt,
    List<Person>? roster,
    bool? shuffleQuestions,
    bool? requireReviewedRubric,
    bool? llmAutoScore,
    String? resultsRelease,
    RuleSet? rules,
    String? watermarkLabel,
    String? sebQuitPassword,
    ViolationAction? violationAction,
    int? maxViolations,
    ViolationAction? aiViolationAction,
    int? aiMaxViolations,
    bool? resultsShowAnswers,
    double? transcriptionThreshold,
  }) => Assessment(
    id: id,
    // THE SERVER COUNTERS ARE CARRIED, NOT DROPPED.
    //
    // These seven have no parameter on purpose - they are the server's to
    // report, never the client's to set - but they were also not FORWARDED,
    // and each defaults to -1 in the constructor. So every copyWith silently
    // blanked them. Every switch on the Configuration tab goes through
    // `store.updateAsm(asm.copyWith(...))`, which writes the result straight
    // into the store, so flipping any one of them emptied the question and
    // candidate counts across the screen until a background refresh happened
    // to repair them. That read as "the toggle broke the question details".
    questionsAvailable: questionsAvailable,
    assignedCount: assignedCount,
    submittedCount: submittedCount,
    releasableCount: releasableCount,
    releasedCount: releasedCount,
    awaitingScoringCount: awaitingScoringCount,
    responseCount: responseCount,
    // THESE TWO TAKE A PARAMETER where the seven above deliberately do not.
    // The counters only ever arrive through a full `fromJson`; the phase also
    // arrives every few seconds from the lighter `/scoring` route while a run
    // is in flight (`AppStore.loadScoring`), which needs a way to write it.
    // Still the server's answer either way - nothing in the client derives a
    // phase of its own - and defaulting to the held value is what keeps a
    // Configuration-tab toggle from blanking the status banner mid-run.
    scoringPhase: scoringPhase ?? this.scoringPhase,
    scoringSummary: scoringSummary ?? this.scoringSummary,
    scoringScored: scoringScored ?? this.scoringScored,
    scoringCandidates: scoringCandidates ?? this.scoringCandidates,
    scoringFinishedAt: scoringFinishedAt ?? this.scoringFinishedAt,
    name: name ?? this.name,
    state: state ?? this.state,
    active: active ?? this.active,
    generatorId: generatorId ?? this.generatorId,
    generatorName: generatorName ?? this.generatorName,
    projectId: projectId ?? this.projectId,
    startDate: startDate ?? this.startDate,
    endDate: endDate ?? this.endDate,
    launchedAt: launchedAt ?? this.launchedAt,
    durationMinutes: durationMinutes ?? this.durationMinutes,
    questionLimit: questionLimit ?? this.questionLimit,
    questions: questions ?? this.questions,
    pool: pool ?? this.pool,
    inUseIds: inUseIds ?? this.inUseIds,
    passThreshold: passThreshold ?? this.passThreshold,
    subjectiveThreshold: subjectiveThreshold ?? this.subjectiveThreshold,
    thresholdRecomputePending:
        thresholdRecomputePending ?? this.thresholdRecomputePending,
    roster: roster ?? this.roster,
    shuffleQuestions: shuffleQuestions ?? this.shuffleQuestions,
    requireReviewedRubric: requireReviewedRubric ?? this.requireReviewedRubric,
    llmAutoScore: llmAutoScore ?? this.llmAutoScore,
    resultsRelease: resultsRelease ?? this.resultsRelease,
    rules: rules ?? this.rules,
    watermarkLabel: watermarkLabel ?? this.watermarkLabel,
    sebQuitPassword: sebQuitPassword ?? this.sebQuitPassword,
    violationAction: violationAction ?? this.violationAction,
    maxViolations: maxViolations ?? this.maxViolations,
    aiViolationAction: aiViolationAction ?? this.aiViolationAction,
    aiMaxViolations: aiMaxViolations ?? this.aiMaxViolations,
    resultsShowAnswers: resultsShowAnswers ?? this.resultsShowAnswers,
    transcriptionThreshold:
        transcriptionThreshold ?? this.transcriptionThreshold,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'state': state.wire,
    'active': active,
    'generatorId': generatorId,
    'generatorName': generatorName,
    'projectId': projectId,
    'startDate': startDate?.toIso8601String(),
    'endDate': endDate?.toIso8601String(),
    'launchedAt': launchedAt?.toIso8601String(),
    'durationMinutes': durationMinutes,
    'questionLimit': questionLimit,
    'questions': questions.map((Question q) => q.toJson()).toList(),
    // The tick rides on the ROW, the same shape the server sends, so
    // `fromJson(toJson(a))` round-trips the shortlist instead of dropping it.
    'pool': pool
        .map(
          (Question q) => <String, dynamic>{
            ...q.toJson(),
            'in_use': inUseIds.contains(q.id),
          },
        )
        .toList(),
    'passThreshold': passThreshold,
    'subjectiveThreshold': subjectiveThreshold,
    'thresholdRecomputePending': thresholdRecomputePending,
    'roster': roster.map((Person p) => p.toJson()).toList(),
    'shuffleQuestions': shuffleQuestions,
    'requireReviewedRubric': requireReviewedRubric,
    'llmAutoScore': llmAutoScore,
    'resultsRelease': resultsRelease,
    // Nested with the rules it belongs to, so `fromJson(toJson(a)) == a`.
    'rules': <String, dynamic>{
      ...rules.toJson(),
      'watermark_label': watermarkLabel,
    },
    'sebQuitPassword': sebQuitPassword,
    'violationAction': violationAction.wire,
    'maxViolations': maxViolations,
    'aiViolationAction': aiViolationAction.wire,
    'aiMaxViolations': aiMaxViolations,
    'resultsShowAnswers': resultsShowAnswers,
    'transcriptionThreshold': transcriptionThreshold,
  };

  /// Parses either shape: the seed fixtures (camelCase, nested `questions`)
  /// or an `/api/v1/assessments` row (snake_case, flat counters).
  ///
  /// A list row carries no questions - the API sends them only on the detail
  /// endpoint - so `questions` is empty here and the counters below are what a
  /// list screen renders. Reading a count off `questions.length` would show 0
  /// for every row loaded from the list.
  factory Assessment.fromJson(Map<String, dynamic> j) {
    // The API nests the generator; the fixtures flatten it.
    final Map<String, dynamic> g = jobj(j, 'generator');
    final ViolationAction action = ViolationAction.parse(
      jget(j, 'violationAction') as String?,
    );
    final int cap = jval(j, 'maxViolations', 3);

    final List<Question> questions = jlist(
      jget(j, 'questions'),
    ).whereType<Map<String, dynamic>>().map(Question.fromJson).toList();

    // THE POOL AND ITS TICKS, from one pass over the same rows.
    //
    // `pool` is absent from a list row and from the seed fixtures, and falling
    // back to `questions` with everything ticked is what keeps those honest:
    // a fixture assessment has no separate choice to make, its questions ARE
    // its pool, and an empty fallback would have emptied the Selected Questions
    // tab everywhere the app runs on seed data.
    final List<Map<String, dynamic>> poolRows = jlist(
      jget(j, 'pool'),
    ).whereType<Map<String, dynamic>>().toList();
    final List<Question> pool = poolRows.isEmpty
        ? questions
        : poolRows.map(Question.fromJson).toList();
    final Set<String> inUseIds = poolRows.isEmpty
        ? questions.map((Question q) => q.id).toSet()
        : <String>{
            for (final Map<String, dynamic> r in poolRows)
              if (jval(r, 'inUse', true)) jid(jget(r, 'id')),
          };

    return Assessment(
      id: jid(jget(j, 'id')),
      name: jval(j, 'name', ''),
      state: AsmState.parse(jget(j, 'state') as String?),
      active: jval(j, 'active', true),
      generatorId: g.isNotEmpty ? jid(g['id']) : jid(jget(j, 'generatorId')),
      generatorName: g.isNotEmpty
          ? (g['name'] ?? '').toString()
          : jval(j, 'generatorName', ''),
      projectId: jget(j, 'projectId') as String?,
      startDate: DateTime.tryParse(jval(j, 'startDate', '')),
      endDate: DateTime.tryParse(jval(j, 'endDate', '')),
      launchedAt: DateTime.tryParse(jval(j, 'launchedAt', '')),
      durationMinutes: jval(j, 'durationMinutes', 0),
      questionLimit: jval(j, 'questionLimit', 0),
      questions: questions,
      pool: pool,
      inUseIds: inUseIds,
      questionsAvailable: jval(j, 'questionsAvailable', -1),
      assignedCount: jval(j, 'assignedCount', -1),
      submittedCount: jval(j, 'submittedCount', -1),
      releasableCount: jval(j, 'releasableCount', -1),
      releasedCount: jval(j, 'releasedCount', -1),
      awaitingScoringCount: jval(j, 'awaitingScoringCount', -1),
      responseCount: jval(j, 'responseCount', -1),
      // On the detail row AND on every list row: `assessment_row` reports both,
      // so a roster opened from the list already knows whether it is being
      // graded without a second request.
      scoringPhase: ScoringPhase.parse(jstr(jget(j, 'scoringPhase'))),
      scoringSummary: jval(j, 'scoringSummary', ''),
      scoringScored: jval(j, 'scoringScored', -1),
      scoringCandidates: jval(j, 'scoringCandidates', -1),
      scoringFinishedAt: DateTime.tryParse(jval(j, 'scoringFinishedAt', '')),
      // `pass_threshold` is the effective bar the server decides pass/fail
      // by. A server from before Q20 omits it; its bar was the subjective one.
      subjectiveThreshold: jval(j, 'subjectiveThreshold', 70.0),
      passThreshold: jval(
        j,
        'passThreshold',
        jval(j, 'subjectiveThreshold', 70.0),
      ),
      thresholdRecomputePending: jval(j, 'thresholdRecomputePending', false),
      roster: ((jget(j, 'roster') ?? const <dynamic>[]) as List<dynamic>)
          .map((dynamic r) => Person.fromJson(r as Map<String, dynamic>))
          .toList(),
      // The server sends `shuffle_questions` already flipped out of its own
      // `preserve_question_order`, so this side reads the positive straight.
      // DEFAULTS TO TRUE to match the create form and the constructor: a
      // payload that predates the field must not read as "authored order",
      // which is the one thing the shuffle exists to prevent.
      shuffleQuestions: jval(j, 'shuffleQuestions', true),
      requireReviewedRubric: jval(j, 'requireReviewedRubric', false),
      llmAutoScore: jval(j, 'llmAutoScore', false),
      resultsRelease: jval(j, 'resultsRelease', 'manual'),
      rules: RuleSet.fromJson(jobj(j, 'rules')),
      // Lives INSIDE the rules block, beside the switch that turns it on.
      watermarkLabel: jval(jobj(j, 'rules'), 'watermarkLabel', ''),
      sebQuitPassword: jval(j, 'sebQuitPassword', ''),
      violationAction: action,
      maxViolations: cap,
      aiViolationAction: jget(j, 'aiViolationAction') == null
          ? action
          : ViolationAction.parse(jstr(jget(j, 'aiViolationAction'))),
      aiMaxViolations: jval(j, 'aiMaxViolations', cap),
      resultsShowAnswers: jval(j, 'resultsShowAnswers', true),
      transcriptionThreshold: jval(j, 'transcriptionThreshold', 0.0),
    );
  }
}

/// A person who can be assigned an assessment.
class Person {
  final String id;
  final String name;
  final String email;
  final String pod;

  const Person({
    required this.id,
    required this.name,
    required this.email,
    this.pod = '',
  });

  /// Initials for the avatar disc.
  String get initials {
    final List<String> parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((String p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'email': email,
    'pod': pod,
  };

  factory Person.fromJson(Map<String, dynamic> j) => Person(
    id: jid(jget(j, 'id')),
    name: jval(j, 'name', ''),
    email: jval(j, 'email', ''),
    pod: jval(j, 'pod', ''),
  );
}

/// One deduction, credit line or golden claim on a judge payload.
class JudgeNote {
  final double points;
  final String reason;
  final String evidence;

  /// Golden claims only: `hit` · `partial` · `miss`.
  final String verdict;

  /// Golden claims only: what kind of claim it is.
  final String kind;

  const JudgeNote({
    this.points = 0,
    required this.reason,
    this.evidence = '',
    this.verdict = '',
    this.kind = '',
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'points': points,
    'reason': reason,
    'evidence': evidence,
    'verdict': verdict,
    'kind': kind,
  };

  factory JudgeNote.fromJson(Map<String, dynamic> j) => JudgeNote(
    points: jval<double>(j, 'points', 0.0),
    reason: jval(j, 'reason', jval(j, 'claim', '')),
    evidence: jval(j, 'evidence', ''),
    verdict: jval(j, 'verdict', ''),
    kind: jval(j, 'kind', ''),
  );
}

/// The judge payload on a scored subjective answer - everything the audit
/// sheet exposes so a score can be defended.
class Judge {
  final String profile;
  final String gate;
  final String verdict;

  /// The raw 0-100 the grader returned. Stored rather than the derived mark,
  /// so changing `subjectiveThreshold` re-decides pass and fail on an
  /// already-graded answer without re-grading it.
  final double raw100;

  /// Weight 0.60 in the audit meters.
  final double keyCloseness;

  /// Weight 0.25.
  final double sopCoverage;
  final String clarity;
  final String aiConfidence;
  final String verdictConsistency;
  final String rubricSource;
  final List<JudgeNote> deductions;
  final List<JudgeNote> credit;
  final List<JudgeNote> claims;
  final String referenceAnswer;
  final String reasoning;
  final String judgeModel;

  /// WHICH GRADING PROMPT decided this score - e.g. `bundled:3f9a1c2d` or
  /// `override:7b4e02aa` (SNo 124). Parsed, but no screen here shows it: an
  /// opaque hash an admin cannot act on. Odoo shows it in developer mode.
  ///
  /// The other half of [judgeModel]. The model alone does not identify the
  /// grading: the same model under a different system prompt is a different
  /// rubric, so two scores are only comparable when BOTH match.
  ///
  /// Empty means the score predates versioning. It does NOT mean the score is
  /// wrong, and nothing was re-graded to fill it in - re-grading to populate a
  /// field would change marks that were correctly awarded.
  final String promptVersion;

  final int attempts;
  final String scoredHash;

  const Judge({
    this.profile = '',
    this.gate = '',
    this.verdict = '',
    this.raw100 = 0,
    this.keyCloseness = 0,
    this.sopCoverage = 0,
    this.clarity = '',
    this.aiConfidence = '',
    this.verdictConsistency = '',
    this.rubricSource = '',
    this.deductions = const <JudgeNote>[],
    this.credit = const <JudgeNote>[],
    this.claims = const <JudgeNote>[],
    this.referenceAnswer = '',
    this.reasoning = '',
    this.judgeModel = '',
    this.promptVersion = '',
    this.attempts = 1,
    this.scoredHash = '',
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'profile': profile,
    'gate': gate,
    'verdict': verdict,
    'raw100': raw100,
    'keyCloseness': keyCloseness,
    'sopCoverage': sopCoverage,
    'clarity': clarity,
    'aiConfidence': aiConfidence,
    'verdictConsistency': verdictConsistency,
    'rubricSource': rubricSource,
    'deductions': deductions.map((JudgeNote n) => n.toJson()).toList(),
    'credit': credit.map((JudgeNote n) => n.toJson()).toList(),
    'claims': claims.map((JudgeNote n) => n.toJson()).toList(),
    'referenceAnswer': referenceAnswer,
    'reasoning': reasoning,
    'judgeModel': judgeModel,
    'promptVersion': promptVersion,
    'attempts': attempts,
    'scoredHash': scoredHash,
  };

  factory Judge.fromJson(Map<String, dynamic> j) => Judge(
    profile: jval(j, 'profile', ''),
    gate: jval(j, 'gate', ''),
    verdict: jval(j, 'verdict', ''),
    raw100: jval<double>(j, 'raw100', 0.0),
    keyCloseness: jval<double>(j, 'keyCloseness', 0.0),
    sopCoverage: jval<double>(j, 'sopCoverage', 0.0),
    clarity: jval(j, 'clarity', ''),
    aiConfidence: jval(j, 'aiConfidence', ''),
    verdictConsistency: jval(j, 'verdictConsistency', ''),
    rubricSource: jval(j, 'rubricSource', ''),
    deductions: ((jget(j, 'deductions') ?? const <dynamic>[]) as List<dynamic>)
        .map((dynamic n) => JudgeNote.fromJson(n as Map<String, dynamic>))
        .toList(),
    credit: ((jget(j, 'credit') ?? const <dynamic>[]) as List<dynamic>)
        .map((dynamic n) => JudgeNote.fromJson(n as Map<String, dynamic>))
        .toList(),
    // `golden_claims` is the wire spelling; `claims` is the fixtures'.
    claims: jlist(
      jget(j, 'claims') ?? jget(j, 'goldenClaims'),
    ).map((dynamic n) => JudgeNote.fromJson(jmap(n))).toList(),
    referenceAnswer: jval(j, 'referenceAnswer', ''),
    reasoning: jval(j, 'reasoning', ''),
    judgeModel: jval(j, 'judgeModel', ''),
    promptVersion: jval(j, 'promptVersion', ''),
    attempts: jval(j, 'attempts', 1),
    scoredHash: jval(j, 'scoredHash', ''),
  );
}

/// The grader's audit for one answer, from whichever key carried it.
///
/// THE SERVER CALLS IT `grading`. This read `judge` and nothing else, and no
/// admin route has ever sent that key - so `Response.judge` was null on every
/// live answer and every screen that hangs off it rendered as though the answer
/// had never been graded: no Audit button on the results grid, and the response
/// detail's whole "why did it score that" panel absent, on answers the judge
/// had scored with a full rationale stored against them.
///
/// SUBSTANCE IS REQUIRED, not just presence. `response_audit` always emits the
/// `grading` block, empty strings and all, including for an objective answer no
/// judge ever touched and a subjective one still pending. Returning a Judge for
/// those would put an audit panel of blanks over questions that have nothing to
/// audit - which reads as a grader that ran and produced nothing, the exact
/// misreading this is meant to end.
///
/// `raw100` is carried in from the response, because the module stores it on
/// the answer (`llm_raw_100`) rather than inside the block. Without it the
/// audit's headline "Subjective raw" meter reads 0 against a real score.
Judge? _judgeFrom(Map<String, dynamic> j) {
  final Object? own = jget(j, 'judge');
  if (own is Map<String, dynamic>) return Judge.fromJson(own);

  final Map<String, dynamic> g = jmap(jget(j, 'grading'));
  if (g.isEmpty) return null;

  bool said(String camel) => jval(g, camel, '').trim().isNotEmpty;
  final bool graded =
      said('gate') ||
      said('profile') ||
      said('verdict') ||
      said('reasoning') ||
      said('feedback') ||
      said('judgeModel') ||
      jlist(jget(g, 'deductions')).isNotEmpty ||
      jlist(jget(g, 'credit')).isNotEmpty ||
      jlist(jget(g, 'goldenClaims')).isNotEmpty;
  if (!graded) return null;

  return Judge.fromJson(<String, dynamic>{
    ...g,
    if (jget(g, 'raw100') == null)
      'raw100': ((jget(j, 'llmRaw100') ?? jget(j, 'llmRaw_100')) as num?)
          ?.toDouble(),
  });
}

/// The selected OPTION IDS, from whichever shape carried them.
///
/// Two shapes again, and only the flat one was read. The exam runner posts and
/// the fixtures store bare option ids; the admin routes send one OBJECT per
/// selected line - `{id, dimension_id, selected_option_id, ...}` - because an
/// admin reading a mark needs to know which dimension each pick sat on.
///
/// `'$l'` over those objects produced strings like `{id: 138, dimension_id: 88,
/// ...}`, which is what every screen then compared against an option id. The
/// comparison could never match, so an msq the candidate had answered in full
/// and been given the mark for rendered as "Nothing selected" - on a paper
/// scored 10 / 10.
///
/// `id` IS NOT the option: it is the response LINE's own row id. Reading it
/// would match some unrelated option whose id happened to collide, which is
/// worse than matching nothing.
List<String> _linesFrom(Object? v) {
  final List<String> out = <String>[];
  for (final dynamic l in jlist(v)) {
    if (l is Map<String, dynamic>) {
      final String id = jid(jget(l, 'selectedOptionId'));
      if (id.isNotEmpty && id != 'null') out.add(id);
    } else if (l != null) {
      out.add('$l');
    }
  }
  return out;
}

/// One dimension's answer, as Odoo's "Dimension Answers" list shows it.
///
/// The module's own response form puts these in a TABLE - dimension on the
/// left, the option the candidate picked on the right - because a multi-axis
/// question is answered per axis and a mark is defended per axis. Flattening
/// them to "Response A, Both Good, Both Good, Response A" loses the only thing
/// that makes the row readable: WHICH axis each verdict was cast on.
///
/// Every field here rides on the response's own `lines`, already resolved to
/// names by the server, so this needs no question record to render.
class ResponseLine {
  final String dimensionId;
  final String dimensionName;
  final String optionId;
  final String optionName;

  /// The module's own verdict on this pick. Not recomputed here: on an axis
  /// whose key was never set, "not correct" and "no key" are different things
  /// and only the server can tell them apart.
  final bool isCorrect;

  const ResponseLine({
    this.dimensionId = '',
    this.dimensionName = '',
    this.optionId = '',
    this.optionName = '',
    this.isCorrect = false,
  });

  factory ResponseLine.fromJson(Map<String, dynamic> j) => ResponseLine(
    dimensionId: jid(jget(j, 'dimensionId')),
    dimensionName: jval(j, 'dimensionName', ''),
    optionId: jid(jget(j, 'selectedOptionId')),
    optionName: jval(j, 'selectedOptionName', ''),
    isCorrect: jval(j, 'isCorrect', false),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'dimensionId': dimensionId,
    'dimensionName': dimensionName,
    'selectedOptionId': optionId,
    'selectedOptionName': optionName,
    'isCorrect': isCorrect,
  };
}

/// The per-dimension answers, where the payload carried them.
///
/// Empty for the flat shape the exam runner posts, which is bare option ids and
/// has no dimension to report. A named pick is required: a line with no option
/// resolved is a row that would render as an empty cell.
List<ResponseLine> _detailsFrom(Object? v) {
  final List<ResponseLine> out = <ResponseLine>[];
  for (final dynamic l in jlist(v)) {
    if (l is! Map<String, dynamic>) continue;
    final ResponseLine line = ResponseLine.fromJson(l);
    if (line.optionName.isEmpty && line.optionId.isEmpty) continue;
    out.add(line);
  }
  return out;
}

/// One answer.
class Response {
  /// Selected option ids.
  final List<String> lines;

  /// Free text.
  final String justification;

  /// Labelling questions only: box number to typed text.
  final Map<int, String>? labels;

  /// Transcription questions only: the candidate's category, characteristics
  /// and speakers for the clip. [justification] holds the transcription.
  final ClipAnswers? clip;

  /// Transcription questions only, admin routes only: both texts, the word
  /// differences and the client rule's counts (`response_audit.transcription`).
  final TranscriptionReview? transcriptionReview;

  /// The OBJECTIVE half of the mark, and only that half.
  ///
  /// `_compute_score` returns 0 / 0 for any question type that is not mcq or
  /// msq - a graded answer's mark is not in this field and never was. Read
  /// [mark] instead of either pair; these two stay public only because the
  /// audit panels name the objective pair specifically.
  final int score;
  final int maxScore;

  /// The GRADED half. `_compute_llm_progress` sums this over the answers that
  /// needed a grader; the evaluator's total is the two halves added together.
  final int llmScore;
  final int llmMaxScore;

  /// Whether the module scored this answer objectively (`qtype in mcq, msq`).
  ///
  /// The discriminator between the two pairs above, and the module's own: it
  /// is computed from the question type in `_compute_scoring_kind` and sent on
  /// every response row.
  final bool hasObjective;

  /// THE MARK THE MODULE AWARDED, composed from both halves. Null on a payload
  /// written before the server sent it.
  ///
  /// 0..[finalMax], NOT 0 or 1. The module scores COMPONENTS now - see
  /// [finalMax] - so a three-sub-question mcq with two right lands here as 2.0
  /// and an image_ab can reach 5.0. It stays a double because the wire sends
  /// one; every branch of the composition still awards whole components, which
  /// is what keeps `score_marks` two integers and [mark] an int.
  ///
  /// Neither pair above holds it for an image_ab answer, which is the one type
  /// made of both: `score` is the objective half and stays 0 there, `llmScore`
  /// is the graded-score verdict alone. Its components are its verdict axes
  /// plus its justification, marked separately - a candidate who called every
  /// axis right and could not defend it keeps the axes and loses one mark -
  /// where the old rule was an all-or-nothing AND of the two halves. Reading
  /// either pair alone was wrong then and is wrong now. See [mark].
  final double? finalMark;

  /// The objective half of [finalMark]: how many of the question's KEYED
  /// DIMENSIONS the candidate got exactly right. Sent alongside it so a screen
  /// can say WHICH half was lost.
  ///
  /// A COUNT NOW, NOT A FLAG. It used to be 1 only when every sub-verdict was
  /// right and 0 otherwise; under the component rule each keyed dimension is
  /// marked on its own, so 2 of 3 sub-questions right reads 2.0 here. Anything
  /// testing `mcqMark == 1` for "the objective half was clean" is asking the
  /// wrong question - compare it against [objectiveMarksMax].
  final double? mcqMark;

  /// The denominator for [finalMark], and the authoritative statement of what
  /// this question is WORTH.
  ///
  /// THE UNIT OF SCORING IS THE COMPONENT, NOT THE QUESTION. One mark per
  /// keyed dimension - a sub-question, which covers mcq, msq and every
  /// image_ab verdict axis - plus one for an LLM-graded free-text answer
  /// (subjective_rubric, image_prompt, video_prompt, image_ab), plus one for a
  /// labelling box set taken as a whole. So a three-sub-question mcq is worth
  /// 3, an image_ab with four axes and a justification is worth 5, and
  /// [finalMark] is no longer 0 or 1. Every screen that printed "/ 1" against
  /// those was reporting a denominator the server had stopped using.
  ///
  /// Null only on a payload written before the server sent it - a cached row,
  /// a seed fixture - which is why [markOutOf] keeps its old derivation behind
  /// it rather than asserting every answer is out of nothing.
  final int? finalMax;

  /// The denominator for [mcqMark]: how many keyed dimensions this question
  /// has. Sent as its pair for the same reason [finalMax] is - a bare count of
  /// sub-questions passed says nothing without the number there were.
  final int? objectiveMarksMax;

  /// The UNGATED twin of [finalMark], over the LLM-GRADED COMPONENTS ONLY.
  ///
  /// Each graded component contributes its quality as a 0-1 fraction instead
  /// of the mark a threshold allowed it, so an answer that earned real partial
  /// credit and cleared no bar reads 0 marks here and a non-zero raw. That gap
  /// is the whole point: it separates a blank answer from a near miss, which
  /// the mark alone cannot. Admin-only - see [Attempt.rawResult] for why an
  /// ungated number must never reach a candidate.
  ///
  /// EVERY COMPONENT CARRIES A RAW, so [rawMax] equals `finalMax` and the raw
  /// spans the whole answer: a keyed sub-question contributes its own mark, a
  /// graded answer its 0-100 as a fraction. [rawMax] therefore reads 0 only
  /// for a question with no components at all. Test [hasRaw] rather than
  /// `rawScore == 0` all the same - a real raw of zero is a candidate who
  /// answered badly, and no raw at all is a question with nothing to measure.
  final double? rawScore;
  final int? rawMax;

  /// `draft` · `submitted`.
  final String state;
  final LlmState llmState;

  /// The raw 0-100 the grader returned, before the threshold decides the mark.
  final double? llmRaw100;
  final String? llmError;
  final Judge? judge;

  /// The per-lane breakdown behind [llmRaw100], as the module computed it.
  ///
  /// The API has always sent this under `subscores`; three separate comments in
  /// this app said so and nothing parsed it, so an image_ab raw arrived as one
  /// opaque number. That is the one type whose RAW is a blend - 75% verdicts,
  /// 25% written justification - and with the lanes dropped there was no screen
  /// anywhere that could answer "did they lose it on the call or on the
  /// write-up", which is the only question worth asking about an A/B answer.
  ///
  /// The MARK is not that blend: the verdict axes are marked one component
  /// each and the justification is one more, against the threshold. Print
  /// these lanes as quality, never as an account of how the mark was reached.
  final Subscores? subscores;

  /// What the candidate picked, ALREADY RESOLVED TO LABELS by the module.
  ///
  /// The client can only name a pick by joining the option ids in [lines] back
  /// to the question's own dimensions - and most admin surfaces never hold
  /// those. `/api/v1/responses` sends `question_name` and `question_type` and
  /// no options at all, and an assessment's question list is the BANK ROW
  /// shape, which carries a count of dimensions rather than the dimensions. So
  /// the join had nothing on either side of it and every objective answer on
  /// every admin screen printed "Nothing selected".
  ///
  /// The module computes this string itself and has sent it on every response
  /// row all along. Preferring it means an answer reads correctly from a list
  /// row, with no second request and no question record at all.
  final String serverAnswerSummary;

  /// The written answer's first 200 characters, whitespace-collapsed - what a
  /// list row carries in place of the full text it does not send. `""` when
  /// there is no text (or the candidate's data was erased); NULL from a
  /// server that predates the key, which cannot say either way.
  final String? justificationPreview;

  /// The answer key, resolved to labels by the module. Same argument as
  /// [serverAnswerSummary]: without it the key can only be rebuilt from
  /// per-option `is_correct` flags that the list shapes do not carry, which is
  /// why "Correct answer" read "No key recorded" on a question that has one.
  final String serverCorrectSummary;

  /// The answer BROKEN DOWN BY DIMENSION, as the module's own form shows it.
  ///
  /// Present on the audit routes and empty on the flat ones. See [ResponseLine]
  /// for why the breakdown matters and the joined summary is not enough.
  final List<ResponseLine> details;

  /// The categories this answer exercised, copied off its question.
  ///
  /// Canonical tag names as the vocabulary stores them (`skill:x`,
  /// `domain:y`) - `facetOf` and `readableTag` split them for display. An
  /// answer has no tags of its own; these come from
  /// `response_row`'s `tags` key, which reads `question_id.tag_ids`.
  ///
  /// Empty is the NORMAL case, not an error: a question authored before the
  /// vocabulary existed, or one whose generator was never tagged, has none. Any
  /// screen grouping by these has to say so rather than drawing an empty chart.
  final List<String> tags;

  /// The module's `needs_llm`: whether the grader marks this answer at all.
  /// False for an MCQ/MSQ (scored in code) and for a blank or auto-submitted
  /// answer. Null on a payload that predates the key - read [needsGrader].
  final bool? needsLlm;

  /// An individual re-score is queued for this answer and the grader has not
  /// reached it yet. The current mark stays until the new grade succeeds.
  final bool rescoreRequested;

  const Response({
    this.lines = const <String>[],
    this.justification = '',
    this.labels,
    this.clip,
    this.transcriptionReview,
    this.score = 0,
    this.maxScore = 1,
    this.llmScore = 0,
    this.llmMaxScore = 0,
    this.hasObjective = true,
    this.finalMark,
    this.mcqMark,
    this.finalMax,
    this.objectiveMarksMax,
    this.rawScore,
    this.rawMax,
    this.state = 'draft',
    this.llmState = LlmState.notNeeded,
    this.llmRaw100,
    this.llmError,
    this.judge,
    this.subscores,
    this.serverAnswerSummary = '',
    this.justificationPreview,
    this.serverCorrectSummary = '',
    this.details = const <ResponseLine>[],
    this.tags = const <String>[],
    this.needsLlm,
    this.rescoreRequested = false,
  });

  /// Whether there is anything for a re-score to grade. The server's
  /// `needs_llm` wins; a fixture without it falls back to the grader state,
  /// which is `not_needed` for exactly the answers the grader never sees.
  bool get needsGrader => needsLlm ?? llmState != LlmState.notNeeded;

  // Keyed off labelBoxes, not boxKey: boxKey is the answer key and a candidate
  // never receives it, so this decided "is this a labelling question" from a
  // field that is always empty on the exam route.
  factory Response.seed(Question q) => Response(
    labels: q.labelBoxes.isNotEmpty ? const <int, String>{} : null,
    clip: q.type == QType.transcription ? ClipAnswers() : null,
    llmState: q.type.isObjective ? LlmState.notNeeded : LlmState.pending,
  );

  /// Whether the candidate put anything in at all. `gradeOne` discards a
  /// subjective response entirely when this is false, so an empty answer
  /// becomes an unanswered question rather than a zero-scored one.
  bool get hasInput =>
      lines.isNotEmpty ||
      justification.trim().isNotEmpty ||
      (labels?.values.any((String v) => v.trim().isNotEmpty) ?? false) ||
      // A clip marked "not transcribed" is answered with an empty box. Ticks
      // and speakers alone are not an answer: the server refuses them without
      // text.
      (clip != null && !clip!.transcribed);

  int get filledLabels =>
      labels?.values.where((String v) => v.trim().isNotEmpty).length ?? 0;

  /// Whether this answer satisfies the WRITTEN half of [q], the way the server
  /// decides it.
  ///
  /// ONE IMPLEMENTATION, because the client having its own approximation of this
  /// rule is the bug. `examAdvance` used to test
  /// `justification.trim().isEmpty` directly, which refused two kinds of fully
  /// answered question on every Next press:
  ///
  ///   * `image_label` - the answer lives in [labels] and never in
  ///     [justification]. The server does not disagree: `_record_response`
  ///     PACKS the label map INTO `justification` before applying this same
  ///     test, so a labelled question passed server-side while the client was
  ///     still looking at an empty string. The candidate saw "8 / 8 labelled"
  ///     beside "needs a justification before it counts".
  ///   * `subjective_rubric` answered on its axes - the server's
  ///     `carried_by_axes` accepts a blank prose box ("explain any FAILED
  ///     check") when the dimensions are answered. A rubric with NO dimensions
  ///     is still pure prose and still requires it.
  ///
  /// Mirrors `controllers/api/candidate.py::_record_response`. Change that and
  /// change this; `completeness_gate_mirrors_server_test.dart` asserts the two
  /// agree in both directions, because a client LOOSER than the server is the
  /// regression this could introduce - it would wave a candidate forward into a
  /// 422 nobody warned them about.
  bool satisfiesProse(Question q) =>
      justification.trim().isNotEmpty ||
      // A clip whose category is not None is not transcribed: the empty box
      // is the complete answer (`_record_response` says the same).
      (q.type == QType.transcription &&
          clip != null &&
          clip!.category != 'none') ||
      (q.type == QType.imageLabel && filledLabels > 0) ||
      (q.type == QType.subjectiveRubric &&
          q.dims.isNotEmpty &&
          lines.isNotEmpty);

  /// THE MARK THIS ANSWER ACTUALLY EARNED, whichever half of the module
  /// scored it. Every screen that prints a mark reads this.
  ///
  /// The module keeps the two halves in separate fields: `_compute_score`
  /// short-circuits to 0 / 0 for anything that is not mcq or msq, and a graded
  /// answer's mark lands in `llm_score` / `llm_max_score` instead. Reading
  /// `score` alone therefore printed a hard 0 against every image and rubric
  /// answer - on a ten-question attempt with five graded answers, Attempt
  /// detail's "Score details" showed five rows of "0" directly underneath its
  /// own ring reading 10 / 10, and All responses aggregated the same five
  /// zeros into every group total, every "scored zero" count and the export.
  ///
  /// NEITHER HALF IS THE ANSWER FOR AN image_ab, which is made of both. Its
  /// mark is the module's AND of them - every sub-verdict exactly right AND
  /// its graded score over the threshold - and `llmScore` alone is just the
  /// second of those, so a candidate who wrote well over a wrong call printed
  /// a 1 in a column headed "Mark" against a question the module scored 0.
  /// [finalMark] is that composition, computed once on the server. The old
  /// reading stays as the fallback for a payload that predates it.
  ///
  /// Do not reconstruct this client-side. The graded score the module tests is
  /// already a blend of the verdicts and the write-up, so the AND is not the
  /// two independent halves it looks like. See `_compute_final_marks` in the
  /// module and its docs/ETP_KNOWLEDGE_BASE.md.
  int get mark => finalMark?.round() ?? (hasObjective ? score : llmScore);

  /// The denominator for [mark]. THE SERVER'S [finalMax] WINS.
  ///
  /// A question is worth its COMPONENT count now - see [finalMax] - so the two
  /// halves below can only ever answer 1, and printing "2 / 1" against a
  /// three-part mcq is worse than printing nothing. `final_max` is the
  /// per-question denominator the module actually marked against, so where it
  /// was sent it is the answer.
  ///
  /// The old derivation stays as the fallback for a payload that predates the
  /// field, and it carries a rule worth keeping: a graded answer is worth 1
  /// once a grader has run and 0 before that, which keeps an ungraded answer
  /// out of the denominator rather than counting it as lost. A live row now
  /// states its full denominator from the moment it is submitted, so a
  /// mid-grading answer does count against itself on the category panels -
  /// that is the server's own arithmetic, and matching it beats disagreeing
  /// with the score the same screen prints.
  ///
  /// A 0 is treated as "not stated": a question worth no marks at all is not a
  /// thing the module emits, and falling through costs nothing.
  int get markOutOf {
    final int? fromServer = finalMax;
    if (fromServer != null && fromServer > 0) return fromServer;
    return hasObjective ? maxScore : llmMaxScore;
  }

  /// Whether this answer has an ungated twin at all. See [rawScore]: `raw_max:
  /// 0` means there was nothing to measure, which is not the same as measuring
  /// it and getting zero.
  bool get hasRaw => (rawMax ?? 0) > 0;

  Response copyWith({
    List<String>? lines,
    String? justification,
    Map<int, String>? labels,
    ClipAnswers? clip,
    TranscriptionReview? transcriptionReview,
    int? score,
    int? maxScore,
    int? llmScore,
    int? llmMaxScore,
    bool? hasObjective,
    double? finalMark,
    double? mcqMark,
    int? finalMax,
    int? objectiveMarksMax,
    double? rawScore,
    int? rawMax,
    String? state,
    LlmState? llmState,
    double? llmRaw100,
    String? llmError,
    Judge? judge,
    Subscores? subscores,
    String? serverAnswerSummary,
    String? justificationPreview,
    String? serverCorrectSummary,
    List<ResponseLine>? details,
    List<String>? tags,
    bool? needsLlm,
    bool? rescoreRequested,
    bool clearError = false,
  }) => Response(
    lines: lines ?? this.lines,
    justification: justification ?? this.justification,
    labels: labels ?? this.labels,
    clip: clip ?? this.clip,
    transcriptionReview: transcriptionReview ?? this.transcriptionReview,
    score: score ?? this.score,
    maxScore: maxScore ?? this.maxScore,
    llmScore: llmScore ?? this.llmScore,
    llmMaxScore: llmMaxScore ?? this.llmMaxScore,
    hasObjective: hasObjective ?? this.hasObjective,
    finalMark: finalMark ?? this.finalMark,
    mcqMark: mcqMark ?? this.mcqMark,
    finalMax: finalMax ?? this.finalMax,
    objectiveMarksMax: objectiveMarksMax ?? this.objectiveMarksMax,
    rawScore: rawScore ?? this.rawScore,
    rawMax: rawMax ?? this.rawMax,
    state: state ?? this.state,
    llmState: llmState ?? this.llmState,
    llmRaw100: llmRaw100 ?? this.llmRaw100,
    llmError: clearError ? null : (llmError ?? this.llmError),
    judge: judge ?? this.judge,
    subscores: subscores ?? this.subscores,
    serverAnswerSummary: serverAnswerSummary ?? this.serverAnswerSummary,
    justificationPreview: justificationPreview ?? this.justificationPreview,
    serverCorrectSummary: serverCorrectSummary ?? this.serverCorrectSummary,
    details: details ?? this.details,
    needsLlm: needsLlm ?? this.needsLlm,
    rescoreRequested: rescoreRequested ?? this.rescoreRequested,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'lines': lines,
    'justification': justification,
    'labels': labels?.map(
      (int k, String v) => MapEntry<String, String>('$k', v),
    ),
    if (clip != null) 'clipAnswers': clip!.toJson(),
    'score': score,
    'maxScore': maxScore,
    'llmScore': llmScore,
    'llmMaxScore': llmMaxScore,
    'hasObjective': hasObjective,
    'finalMark': finalMark,
    'mcqMark': mcqMark,
    'finalMax': finalMax,
    'objectiveMarksMax': objectiveMarksMax,
    'rawScore': rawScore,
    'rawMax': rawMax,
    'state': state,
    'llmState': llmState.wire,
    'llmRaw100': llmRaw100,
    'llmError': llmError,
    'judge': judge?.toJson(),
    'subscores': subscores?.toJson(),
    'answerSummary': serverAnswerSummary,
    'justificationPreview': justificationPreview,
    'correctSummary': serverCorrectSummary,
    'details': details.map((ResponseLine l) => l.toJson()).toList(),
    'tags': tags,
    'needsLlm': needsLlm,
    'rescoreRequested': rescoreRequested,
  };

  /// Parses either shape: the seed fixtures (camelCase) or a live answer row
  /// (snake_case). Reads through [jget]/[jval] so neither spelling throws.
  factory Response.fromJson(Map<String, dynamic> j) => Response(
    lines: _linesFrom(jget(j, 'lines')),
    details: _detailsFrom(jget(j, 'lines') ?? jget(j, 'details')),
    // `jtags` accepts both a list of names and a list of tag OBJECTS, and
    // strips the facet for display. Kept as whatever the wire sent so the
    // grouping code can read the facet back off it.
    tags: jtags(j),
    serverAnswerSummary: jval(j, 'answerSummary', ''),
    justificationPreview: jget(j, 'justificationPreview') as String?,
    serverCorrectSummary: jval(j, 'correctSummary', ''),
    justification: jval(j, 'justification', ''),
    // `label_answers` is what the module sends; `labels` is the fixtures'
    // spelling. Reading only the latter left every admin screen with an empty
    // map, printing "No boxes labelled" over an answer the candidate filled in.
    labels: labelMap(jget(j, 'labelAnswers') ?? jget(j, 'labels')),
    clip: jget(j, 'clipAnswers') is Map
        ? ClipAnswers.fromJson(jget(j, 'clipAnswers'))
        : null,
    transcriptionReview: TranscriptionReview.fromJson(jget(j, 'transcription')),
    score: jval(j, 'score', 0),
    maxScore: jval(j, 'maxScore', 1),
    llmScore: jval(j, 'llmScore', 0),
    llmMaxScore: jval(j, 'llmMaxScore', 0),
    // TRUE when the key is absent, which is what keeps the seed fixtures
    // working: they carry no `has_objective` and put the real mark in `score`
    // whatever the question type, so the default has to be the branch that
    // reads `score`. Every live row states it.
    hasObjective: jval(j, 'hasObjective', true),
    // NULL, not 0, when the key is absent. A payload written before the server
    // sent these - a cached row, a seed fixture - must fall through to the old
    // reading in [mark] rather than assert that every answer scored nothing.
    // `jget` lowers each capital to `_x`, so these reach `final_mark` and
    // `mcq_mark` exactly; neither needs the second spelling `llmRaw100` does.
    finalMark: (jget(j, 'finalMark') as num?)?.toDouble(),
    mcqMark: (jget(j, 'mcqMark') as num?)?.toDouble(),
    // The component rule's denominators, on the same NULL-not-0 terms. Only
    // the camelCase spelling is written here on purpose: `jget` lowers each
    // capital to `_x`, so these reach `final_max`, `objective_marks_max`,
    // `raw_score` and `raw_max` - the wire keys - without a snake_case literal
    // that could drift from the camelCase one beside it.
    finalMax: (jget(j, 'finalMax') as num?)?.toInt(),
    objectiveMarksMax: (jget(j, 'objectiveMarksMax') as num?)?.toInt(),
    rawScore: (jget(j, 'rawScore') as num?)?.toDouble(),
    rawMax: (jget(j, 'rawMax') as num?)?.toInt(),
    state: jval(j, 'state', 'draft'),
    llmState: LlmState.parse(jget(j, 'llmState') as String?),
    // The module reports the raw subjective score 0-1; the fixtures use
    // 0-100. Kept as sent - the display layer decides how to render it.
    //
    // Two spellings on purpose. `jget` lowers each capital to `_x`, so
    // 'llmRaw100' becomes `llm_raw100` - one underscore short of the
    // `llm_raw_100` the server actually sends, and both lookups missed. The
    // field was therefore always null and `gradeOne` fell through to a SEEDED
    // RANDOM for every subjective answer against a live backend.
    // 'llmRaw_100' lowers to exactly `llm_raw_100`, so the wire key is reached
    // through jget rather than a raw `j[...]` read, which parser_safety_test
    // forbids for good reason.
    llmRaw100: ((jget(j, 'llmRaw100') ?? jget(j, 'llmRaw_100')) as num?)
        ?.toDouble(),
    llmError: jget(j, 'llmError') as String?,
    judge: _judgeFrom(j),
    subscores: jget(j, 'subscores') is Map<String, dynamic>
        ? Subscores.fromJson(jget(j, 'subscores')! as Map<String, dynamic>)
        : null,
    needsLlm: jget(j, 'needsLlm') as bool?,
    rescoreRequested: jval(j, 'rescoreRequested', false),
  );
}

/// The per-lane breakdown of a graded response, 0-100 each.
///
/// Only the lanes that apply to a type are non-zero, so a reader must decide
/// what to show from the QUESTION type rather than from which numbers happen to
/// be set - a genuinely zero justification lane and an absent one are both 0.0
/// on the wire.
class Subscores {
  /// image_ab: % of dimensions whose verdict matched the key. Deterministic,
  /// no LLM involved.
  final double abVerdictPct;

  /// image_ab: the LLM's 0-100 for the written justification alone.
  final double abJustificationPct;

  /// image_ab: the graded raw for the justification alone.
  ///
  /// NOT a blend, and not where the question's mark comes from. The verdict
  /// axes are keyed sub-questions marked one mark each without ever passing
  /// through a raw; this number decides the justification's own mark and no
  /// other.
  final double abFinalPct;

  /// image_label, reporting only - neither figure decides a mark.
  ///
  /// [labelCoveragePct] is the share of boxes the candidate attempted.
  /// [labelCorrectnessPct] is the MEAN of the per-box raws, which is a
  /// different question from how many boxes cleared the bar - that share is
  /// `labelFraction`, and it is what the labelling mark is taken from.
  final double labelCoveragePct;
  final double labelCorrectnessPct;

  const Subscores({
    this.abVerdictPct = 0,
    this.abJustificationPct = 0,
    this.abFinalPct = 0,
    this.labelCoveragePct = 0,
    this.labelCorrectnessPct = 0,
  });

  /// True once the grader has actually produced a blend worth showing. A
  /// verdict-only answer leaves the justification lane at 0 and the final equal
  /// to the verdict, which is not a breakdown - it is one number twice.
  bool get hasAbBlend => abFinalPct > 0 && abFinalPct != abVerdictPct;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ab_verdict_pct': abVerdictPct,
    'ab_justification_pct': abJustificationPct,
    'ab_final_pct': abFinalPct,
    'label_coverage_pct': labelCoveragePct,
    'label_correctness_pct': labelCorrectnessPct,
  };

  factory Subscores.fromJson(Map<String, dynamic> j) => Subscores(
    // `ab_verdict_pct` is the audit's own lane; `ab_mcq_pct` is the same
    // measure recomputed on the record. They agree, but the audit one is what
    // the blend was actually taken from, so it wins where both are present.
    abVerdictPct: _pct(jget(j, 'abVerdictPct') ?? jget(j, 'abMcqPct')),
    abJustificationPct: _pct(jget(j, 'abJustificationPct')),
    abFinalPct: _pct(jget(j, 'abFinalPct')),
    labelCoveragePct: _pct(jget(j, 'labelCoveragePct')),
    labelCorrectnessPct: _pct(jget(j, 'labelCorrectnessPct')),
  );

  static double _pct(Object? v) => (v as num?)?.toDouble() ?? 0;
}

/// One side of a `"N / M"` marks string, or null when it is not there.
///
/// The server sends marks already formatted because it is the only place that
/// can compute them for a list row. Parsing beats re-deriving: a client that
/// recomputes needs every response, and a candidate's list carries none.
int? _marksPart(Map<String, dynamic> result, int index) {
  final Object? raw = result['score_marks'];
  if (raw is! String) return null;
  final List<String> parts = raw.split('/');
  if (parts.length != 2) return null;
  return int.tryParse(parts[index].trim());
}

/// The server's own verdict, out of either shape the API uses: a candidate's
/// card nests it as `result: {result: 'pass'}`, the admin roster sends a flat
/// `result: 'pass'`.
///
/// Null when NEITHER is present, which is the signal that nothing but a
/// recomputation can answer - the seed fixtures, and any payload that carries
/// responses instead of a verdict. A value that is present but unrecognised
/// parses to `pending`, so a malformed payload can never invent a pass or a
/// fail.
ResultState? _serverVerdict(Map<String, dynamic> j) {
  final Object? nested = jobj(j, 'result')['result'];
  if (nested is String && nested.isNotEmpty) return ResultState.parse(nested);
  final Object? flat = jget(j, 'result');
  if (flat is String && flat.isNotEmpty) return ResultState.parse(flat);
  return null;
}

/// Server clock minus this device's, from `server_now` (L7).
///
/// ponytail: under 2s reads as zero. `server_now` is whole seconds with no
/// latency correction, so a CORRECT device clock came out +0.5..2s ahead and
/// time-up fired after the server's deadline. A real skew is larger and is
/// kept; subtract half the request's round trip if 2s ever proves too coarse.
Duration _clockOffset(String serverNow) {
  final Duration d =
      DateTime.tryParse(serverNow)?.difference(DateTime.now()) ?? Duration.zero;
  return d.abs() < const Duration(seconds: 2) ? Duration.zero : d;
}

/// The bucket the server filed this attempt under, when it sent one.
///
/// The `state` key is spelled TWO ways by two routes. The candidate's own list
/// sends a BUCKET (`available`, `upcoming`, `closed`, ...) computed from the
/// assessment's state; the admin roster sends the evaluator's own model state
/// (`submitted`). Only the first is a bucket, so only the five bucket spellings
/// are accepted here - and `all` is not one of them, because it is the tab that
/// means "no filter", never a value the server files an attempt under.
///
/// Null for anything else, which is the signal to fall back to deriving the
/// bucket locally. Same arrangement as [_serverVerdict] above.
Bucket? _serverBucket(Map<String, dynamic> j) {
  final Object? raw = jget(j, 'state');
  if (raw is! String || raw.isEmpty) return null;
  for (final Bucket b in Bucket.values) {
    if (b != Bucket.all && b.wire == raw) return b;
  }
  return null;
}

/// The pass mark the server applied, from a candidate's nested `result` or from
/// a flat spelling, or null when the payload states no rule.
double? _passThresholdPart(Map<String, dynamic> j) {
  final Object? nested = jget(jobj(j, 'result'), 'passThreshold');
  if (nested is num) return nested.toDouble();
  final Object? flat = jget(j, 'passThreshold');
  return flat is num ? flat.toDouble() : null;
}

/// One person's attempt.
/// D1 - the operator's flag on ONE SITTING, and the internal remark with it.
///
/// PER-ATTEMPT, NOT PER-PERSON. A concern about how somebody sat one
/// assessment is not a statement about them in general, so flagging an attempt
/// on assessment A leaves the same person's attempt on assessment B alone.
///
/// FLAG AND REMARK ARE INDEPENDENT. The flag is a pure toggle with no reason
/// text - clicking it raises it, clicking again clears it. The remark is free
/// text that can exist with or without a flag, and a flag can exist with no
/// remark. Neither implies the other, which is why [flagged] and [remark] are
/// read separately everywhere rather than one gating the other.
///
/// ADMIN-ONLY BY CONSTRUCTION. The server builds this inside
/// `evaluator_admin_row` and puts it on NO candidate-facing serializer, so a
/// runner or member payload simply has no `candidate_flag` key and this parses
/// to [none]. The client is not the boundary and must not pretend to be -
/// `test_api_invariants.py` walks every candidate response recursively and
/// fails on any flag key at any depth.
class CandidateFlag {
  const CandidateFlag({
    this.flagged = false,
    this.remark = '',
    this.by = '',
    this.at = '',
  });

  /// Neither flagged nor remarked. The default, and what an admin payload
  /// carries for the overwhelming majority of a cohort.
  static const CandidateFlag none = CandidateFlag();

  final bool flagged;

  /// The operator's remark. Independent of [flagged]: it may be set on an
  /// unflagged attempt, and a flagged attempt may carry none. May be long,
  /// because it exists to justify a decision months later, and is never
  /// truncated in transit - the server REFUSES an over-long one rather than
  /// clipping it.
  final String remark;

  /// Who raised the flag, and when, as the server rendered them. Empty when
  /// the attempt is not flagged - they describe the FLAG, not the remark.
  final String by;
  final String at;

  bool get hasRemark => remark.trim().isNotEmpty;

  /// Nothing to show at all - neither a flag nor a remark.
  bool get isEmpty => !flagged && !hasRemark;

  /// "Raised by Akshay Kumar on Sep 8th, 2026", or an empty string when the
  /// attempt is not flagged.
  ///
  /// Built here rather than at each call site because it is shown in three
  /// places (the roster cell, the leaderboard cell and the attempt header) and
  /// a sentence that differs between them reads as three different facts.
  String get raisedSentence {
    if (!flagged || by.isEmpty) return '';
    final DateTime? when = DateTime.tryParse(at);
    return when == null
        ? 'Raised by $by'
        : 'Raised by $by on ${ordinalDate(inIst(when))}';
  }

  factory CandidateFlag.fromJson(Map<String, dynamic>? j) {
    if (j == null || j.isEmpty) return none;
    final bool flagged = jval(j, 'flagged', false);
    final String remark = jval(j, 'remark', '');
    // A REMARK WITH NO FLAG IS A REAL STATE, so this cannot short-circuit on
    // `flagged` the way it used to - doing so silently dropped every remark an
    // operator left without also flagging the attempt.
    if (!flagged && remark.trim().isEmpty) return none;
    return CandidateFlag(
      flagged: flagged,
      remark: remark,
      by: jval(j, 'by', ''),
      at: jval(j, 'at', ''),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'flagged': flagged,
    'remark': remark,
    'by': by,
    'at': at,
  };
}

class Attempt {
  final String id;
  final String assessmentId;
  final String employeeId;

  /// Per-attempt handle. The candidate link is `/exam/<token>`.
  final String token;
  final AttemptState state;

  /// Set with `submitted`; blocks all further writes.
  final bool isLocked;

  /// Fixed at launch, shuffled per person.
  final List<String> questionOrder;
  final DateTime? startedAt;
  final DateTime? submittedAt;
  final InviteState inviteState;

  /// Why the invitation failed, in the server's own words.
  ///
  /// The API sends this alongside `invite_state: "failed"` (a real one reads
  /// "Could not contact the mail server..."). Without it the UI says only
  /// "Failed", and an operator has no way to tell a wrong address from a mail
  /// server that is down - so they press Resend forever on something a resend
  /// cannot fix.
  final String inviteError;
  final int violationCount;

  /// The server's `violation_limit_breached`: this attempt reached its
  /// violation limit, in either mode (A-074). Auto-submit ended the exam
  /// there; Log only did not, so under Log only this is the only trace of the
  /// breach. False when absent (an older server).
  final bool violationLimitBreached;
  final String violationReason;
  final DateTime? violationAt;

  /// The full tally of proctoring violations, one line per distinct reason,
  /// ordered by count descending as the server sends it.
  ///
  /// WHAT [violationReason] COULD NOT SAY. That field holds only the LAST
  /// reason, so an attempt with three right-clicks, two tab switches and a
  /// copy read "Last reason: Clipboard action: copy" and named neither the
  /// count nor the other two kinds - a reviewer answering an appeal could not
  /// tell a single lapse from a pattern. The module now keeps a per-reason
  /// log and serialises it here.
  ///
  /// EMPTY ON LEGACY ATTEMPTS, and on any payload that predates the log or
  /// sends a malformed one. Callers fall back to [violationReason] when this
  /// is empty, so an old record still reads sensibly rather than blank.
  final List<({String reason, int count})> violations;

  /// The AI proctoring side, counted apart from the regular one ("AI: "
  /// reasons): `ai_violation_count`, `ai_violation_limit_breached` and the
  /// `ai_violations` tally. Zero / false / empty from an older server.
  final int aiViolationCount;
  final bool aiViolationLimitBreached;
  final List<({String reason, int count})> aiViolations;

  /// Whether the AI watch ran on the candidate's device (`ai_status`):
  /// `running`, `failed`, or empty when it never reported.
  final String aiStatus;

  /// The count a violation of this kind adds to.
  int countOf(bool ai) => ai ? aiViolationCount : violationCount;

  /// [limitBreached], for the AI count against the paper's AI cap.
  bool aiLimitBreached(Assessment? asm) {
    final int? limit = asm?.aiViolationLimit;
    return aiViolationLimitBreached ||
        (limit != null && aiViolationCount >= limit);
  }

  /// Ended by the violation cap or the deadline.
  final bool autoSubmitted;

  /// WHY it was ended, when it was not the candidate who ended it:
  /// `'violation'`, `'expired'`, or empty for a paper they submitted
  /// themselves. Both UIs print it - a candidate whose exam ends under them is
  /// owed the reason, and a reviewer looking at a short paper has to be able
  /// to tell "cut off" from "gave up".
  final String autoSubmitReason;

  /// Invariant 3: the only gate on candidate-visible marks. Set by a person;
  /// there is no automatic path and there is no un-release.
  final bool resultsReleased;

  /// Advisory only - invariant 6 says a flag never changes a score.
  final bool integrityAlert;
  final bool scoreOutlier;

  /// D1 - the operator's manual flag, and the remark behind it.
  ///
  /// SEPARATE FROM THE TWO ABOVE, permanently. Those are machine-derived and
  /// recomputed; this one is only ever set by a person, and the server keeps
  /// the distinction too - `flagged_only` still selects exactly the automatic
  /// signals and the manual flag has its own `manual_flagged_only` parameter.
  final CandidateFlag candidateFlag;

  /// Free text erased, scores kept.
  final bool piiAnonymized;

  /// Marks the SERVER computed, when it sent them.
  ///
  /// [earnedMarks] recomputes from per-question responses, which only the
  /// DETAIL endpoint carries. A candidate's own list arrives with the marks
  /// already worked out (`result.score_marks`, e.g. "0 / 3") and no responses
  /// at all, so a screen that only recomputed showed nothing on the one
  /// surface a candidate actually opens. These hold the server's answer so a
  /// list row can render marks without inventing an Assessment to divide by.
  final int? serverEarned;
  final int? serverTotal;

  /// How many answers the server says landed. The admin roster is a LIST
  /// route: it carries this count but no answers, so counting `resp` reports
  /// 0 for an attempt that is plainly submitted. Null when not sent.
  final int? serverAnswered;

  /// How many QUESTIONS the paper holds, as the server counted them.
  ///
  /// KEPT APART FROM [serverTotal] ON PURPOSE. The two used to be one number:
  /// a question was worth a mark, so `total_questions` served as both the
  /// marks denominator and the progress denominator. The module scores
  /// COMPONENTS now - a three-sub-question mcq is worth 3 - so a paper of
  /// eight questions can be a paper of fourteen marks, and a card sharing one
  /// figure between them printed "14 questions" and capped its progress bar at
  /// 8 of 14 on an attempt the candidate had fully answered.
  ///
  /// This one counts questions and nothing else: what the card says the paper
  /// holds, and what an answered-count is a fraction of. Null when the route
  /// did not send it, which is every route that reports marks instead.
  final int? serverQuestions;

  /// The objective / subjective split, as the admin roster reports it.
  ///
  /// The two halves are graded by different machinery - options are marked
  /// instantly, prose waits on the LLM - so a reviewer reading one total
  /// cannot tell a genuinely low score from one still waiting on the judge.
  /// Null when the route did not send them (a candidate's own card never
  /// does; the split is an operator's view).
  final int? objectiveScore;
  final int? objectiveMax;
  final int? subjectiveScore;
  final int? subjectiveMax;

  /// Subjective answers still awaiting a verdict.
  final int subjectivePending;

  /// The released result split by section, as `candidate_result.breakdown`.
  ///
  /// "6 / 10" tells a candidate they failed and nothing about what to work on.
  /// The QWeb runner showed this split on its completion page (objective correct
  /// of total, written passed of total); the API sent no equivalent, so the app
  /// could only print one figure. Empty on every operator route and until
  /// results are released - it rides inside `result`, which is itself withheld
  /// until a person publishes.
  ///
  /// Counts and marks only, never a percentage: same invariant as `scoreMarks`.
  final List<ResultSection> resultSections;

  /// The UNGATED total, as the module computed it: every question contributes
  /// its quality as a 0-1 fraction instead of its thresholded mark.
  ///
  /// ADMIN-ONLY, AND NOT A SECOND OPINION ABOUT THE RESULT. `score_marks` is
  /// what the candidate is graded on and is the only number that decides
  /// pass/fail; this is the number that explains it. An attempt on this rig
  /// scores `0 / 5` marks with a raw of `2.25` - the candidate earned real
  /// partial credit on every question and cleared the bar on none of them, and
  /// with only the marks on screen a reviewer cannot tell that from a paper
  /// that was left blank.
  ///
  /// `etp_assessment_pro` has shown this to its admins all along as
  /// `raw_result`, with the mismatch spelled out in the field help. The backend
  /// here computes and serialises it identically; this side simply dropped it
  /// on the floor. Null when the route did not send it (candidate surfaces
  /// never do - see [internalPercent] for why an ungated number must not reach
  /// them).
  final double? rawResult;

  /// What [rawResult] is out of, AS THE SERVER STATES IT.
  ///
  /// This used to be derived here, by summing `raw_max` across the answers -
  /// which only the detail route sends, so every list route printed a bare raw
  /// with nothing to read it against. The attempt payload now carries the
  /// denominator with the numerator; [rawOutOf] remains as the fallback for a
  /// server that predates it.
  final int? serverRawMax;

  /// The attempt-level subjective scoring state, as the roster reports it
  /// (`pending`, `scoring`, `scored`, `failed`, `error`).
  final LlmState subjectiveState;

  /// Has the server been ASKED to grade this attempt - `evaluator.
  /// scoring_requested`, the flag its scoring cron selects on.
  ///
  /// Distinct from [subjectiveState] being `pending`, which only says an answer
  /// is ungraded. With automatic grading off nothing sets this, so a paper can
  /// sit ungraded indefinitely with no work in flight; that difference is what
  /// decides whether there is a scoring run to kill.
  final bool scoringRequested;

  /// When this sitting expires, as the module computed it.
  ///
  /// Sent on every admin row as `deadline` and read by nothing, so the one
  /// session fact that says whether an in-progress attempt is about to be swept
  /// by the expiry cron was on no screen. Started and Submitted were both
  /// there; the date that decides the outcome was not.
  final DateTime? deadline;

  /// Server clock minus this device's clock, from the `server_now` sent beside
  /// [deadline]. The runner counts down on device now + this, so a device
  /// clock that is off does not move the candidate's deadline. Zero when the
  /// server sent no `server_now` (an older backend), which is the old behaviour,
  /// and under 2s - see [_clockOffset].
  final Duration clockOffset;

  /// The server's OWN terminal-error flag (`subjective.has_terminal_error`).
  ///
  /// Null when the payload did not carry one, which is the shape the seed
  /// fixtures use. See [hasScoringError] for why reading it matters.
  final bool? subjectiveHasError;

  /// Why the grader last stopped on this candidate (`subjective.error`, from
  /// `evaluator.llm_error`). Empty when it has nothing to say.
  ///
  /// TWO CASES, BOTH THE ADMIN'S BUSINESS, and the server writes them in its
  /// own words: a queued re-score of an already-scored answer that failed
  /// ("Re-score of Q205 failed, its previous mark was kept: ..."), and a call
  /// deferred before it was made for a spend cap or a 429 ("Waiting to be
  /// graded, no attempt used: ..."). Neither moves a mark and neither is
  /// terminal - [subjectiveHasError] is the flag for that - so this is the
  /// only trace either one leaves. Without it both read as a silent
  /// "Pending": a queue waiting on money looks like a broken one, and a failed
  /// re-grade looks like one that confirmed the mark it kept.
  final String subjectiveError;

  /// Whether the server sent an objective / subjective breakdown worth
  /// showing. A candidate's own card never carries one.
  bool get hasSplit => objectiveMax != null || subjectiveMax != null;

  /// The server's own verdict, when it sent one. THE authority on pass and
  /// fail: it holds the pass threshold, and its denominator is the sum of marks
  /// actually obtainable rather than the question count.
  ///
  /// A TRI-STATE, not a bool. `pending` is a real value here - invariant 4
  /// holds an attempt with an unresolved subjective answer at pending whatever
  /// the score - and the bool this replaced collapsed it to "not passed", which
  /// reported a grader still working as the candidate's failure.
  final ResultState? serverResult;

  /// The BUCKET the server filed this attempt under, verbatim.
  ///
  /// The candidate's own list is the only caller that sends one, and it is
  /// authoritative: `attempt_bucket` on the server reads the ASSESSMENT's
  /// state, which a candidate never loads (the assessment list is a manager
  /// route). Re-deriving the bucket client-side therefore had nothing to read
  /// and defaulted every attempt to "Available" - so an assessment the admin
  /// had marked done, and one still sitting in draft, both offered the
  /// candidate a Start button that could only fail.
  ///
  /// Null on the ADMIN roster, which sends the evaluator's own `state`
  /// (`submitted`) rather than a bucket. Nullable so that surface keeps
  /// deriving locally, exactly as [serverResult] does.
  final Bucket? serverBucket;

  /// The pass mark the server applied, as a percentage of the marks available.
  ///
  /// Sent alongside a released result and on the exam gate. A candidate never
  /// loads an Assessment, so without this the threshold marker and the stated
  /// pass mark fell back to a hardcoded 70% on the only screens a candidate
  /// opens - drawing the bar against a bar that was not the one being applied.
  final double? serverPassThreshold;

  /// The assessment's name as the list row carried it, so a candidate screen
  /// can title a row without joining to a record it cannot load.
  final String assessmentName;

  /// The sitting's time limit, carried on the same card for the same reason.
  final int durationMinutes;

  /// The median sitting time of this attempt's assessment, over ALL its
  /// sittings, as the DETAIL route's `test_median_seconds` reports it.
  ///
  /// Null when the server did not send it (an older build, and every list
  /// row), sent null, or sent nothing positive. A list refresh keeps the held
  /// value - see `_mergeAttempts`.
  final Duration? testMedian;
  final Map<String, Response> resp;

  const Attempt({
    required this.id,
    required this.assessmentId,
    required this.employeeId,
    required this.token,
    this.state = AttemptState.pending,
    this.isLocked = false,
    this.questionOrder = const <String>[],
    this.startedAt,
    this.submittedAt,
    this.inviteState = InviteState.none,
    this.inviteError = '',
    this.violationCount = 0,
    this.violationLimitBreached = false,
    this.violationReason = '',
    this.violationAt,
    this.violations = const <({String reason, int count})>[],
    this.aiViolationCount = 0,
    this.aiViolationLimitBreached = false,
    this.aiViolations = const <({String reason, int count})>[],
    this.aiStatus = '',
    this.autoSubmitted = false,
    this.autoSubmitReason = '',
    this.resultsReleased = false,
    this.integrityAlert = false,
    this.scoreOutlier = false,
    this.candidateFlag = CandidateFlag.none,
    this.piiAnonymized = false,
    this.serverEarned,
    this.serverTotal,
    this.serverAnswered,
    this.serverQuestions,
    this.objectiveScore,
    this.objectiveMax,
    this.subjectiveScore,
    this.subjectiveMax,
    this.subjectivePending = 0,
    this.resultSections = const <ResultSection>[],
    this.rawResult,
    this.serverRawMax,
    this.subjectiveState = LlmState.pending,
    this.scoringRequested = false,
    this.deadline,
    this.clockOffset = Duration.zero,
    this.subjectiveHasError,
    this.subjectiveError = '',
    this.serverResult,
    this.serverBucket,
    this.serverPassThreshold,
    this.assessmentName = '',
    this.durationMinutes = 0,
    this.testMedian,
    this.resp = const <String, Response>{},
  });

  bool get isDone => state == AttemptState.submitted || isLocked;

  /// Answers landed. Prefers the server's count: on a LIST route `resp` is
  /// empty by design, so counting it reports 0 for a submitted attempt.
  ///
  /// WHICHEVER IS HIGHER, not `serverAnswered ?? resp.length`. That spelling
  /// read as "fall back to the local count", but a sitting in progress sends
  /// `answered_count: 0` - a real zero, not a missing key - so the fallback
  /// could never fire and the count froze at whatever the last load reported.
  /// The exam header sat on "0 answered" for the whole paper while the server
  /// had the answers, because nothing refreshes the attempt between questions.
  /// Taking the maximum keeps the list route honest (`resp` empty, server
  /// count wins) and the runner honest too (server count stale, local wins),
  /// and it cannot go backwards in either direction.
  int get answeredCount {
    final int local = _localAnswered;
    if (serverAnswered == null) return local;
    return local > serverAnswered! ? local : serverAnswered!;
  }

  /// What "Answered" is out of: THIS candidate's paper when the row says
  /// (L3), which on an independent draw is not the assessment's.
  int paperSize(Assessment asm) => serverQuestions ?? asm.paperSize;

  /// The violation limit reached, in either mode (A-074) - the one rule the
  /// candidate notices and every admin badge read (L4). Auto-submit also ends
  /// the paper there; Log only does not.
  ///
  /// The server's `violation_limit_breached`, or the same test on the counts
  /// held here: a `/me/assessments` row, which replaces the attempt after a
  /// submit, does not carry the flag. Without the paper there is no cap to
  /// test, so the flag alone.
  bool limitBreached(Assessment? asm) {
    final int? limit = asm?.violationLimit;
    return violationLimitBreached || (limit != null && violationCount >= limit);
  }

  /// Local responses that actually CARRY something.
  ///
  /// Not `resp.length`: a response row is created on the first keystroke, so
  /// a box somebody typed into and then cleared leaves an empty one behind.
  /// Counting those would report a question as answered that the server will
  /// refuse as incomplete - the progress bar and the header would disagree
  /// with the paper.
  ///
  /// [Response.hasInput] is the same predicate the grader uses to decide an
  /// answer is absent rather than wrong, so the count a candidate reads and
  /// the rule that scores them cannot drift apart.
  int get _localAnswered =>
      resp.values.where((Response r) => r.hasInput).length;

  /// Question ids this attempt has a real answer for, locally.
  Set<String> get answeredLocally => <String>{
    for (final MapEntry<String, Response> e in resp.entries)
      if (e.value.hasInput) e.key,
  };

  /// ── Scoring (HANDOVER §5.3) ─────────────────────────────────────────────
  ///
  /// Every COMPONENT is worth exactly one mark, and a question is worth as
  /// many marks as it has components - see [Question.componentCount]. There is
  /// still no weighting and still no partial credit: a component is won whole
  /// or lost whole, and what changed is only how many of them a question
  /// carries.
  ///
  /// Prefers the server's figure. Recomputing needs BOTH the answers and the
  /// assessment's questions; a list row has neither, and the silent result was
  /// a graded attempt rendering "0 / 0".
  int earnedMarks(Assessment asm) {
    final int? fromServer = serverEarned;
    if (fromServer != null) return fromServer;
    int n = 0;
    for (final Question q in asm.questions) {
      final Response? r = resp[q.id];
      if (r == null) continue;
      // `mark`, not `score`: the local walk summed the objective half only, so
      // it disagreed with the server's own total by exactly the graded answers.
      n += r.mark;
    }
    return n;
  }

  /// The marks denominator: the server's total when it sent one, else the
  /// paper's COMPONENT count.
  ///
  /// [serverTotal] is `score_marks`' right-hand side and is still exactly
  /// right - it simply got bigger, because the module now counts components
  /// rather than questions.
  ///
  /// THE FALLBACK IS WHAT CHANGED. It used to be `asm.totalQuestions`, which
  /// was only ever correct while a question was worth one mark. It is not: a
  /// paper of five questions can be a paper of fourteen marks, so the ring
  /// read "9 / 5" on any surface the server's total had not reached. Summing
  /// each question's own components is the closest the client can get from
  /// what it holds - and [Question.componentCount] undercounts where a list
  /// row withheld the dimensions, which is why the server's figure is tried
  /// first rather than merely preferred.
  ///
  /// Only THIS attempt's draw when [questionOrder] names it: `questions` is the
  /// pool, and a 10-of-40 paper summed all 40. An empty order (seed data)
  /// keeps the pool sum.
  int maxMarks(Assessment asm) =>
      serverTotal ??
      asm.questions
          .where(
            (Question q) =>
                questionOrder.isEmpty || questionOrder.contains(q.id),
          )
          .fold<int>(0, (int a, Question q) => a + q.componentCount);

  /// The denominator [rawResult] is on: the paper's component count.
  ///
  /// THE SAME DENOMINATOR AS THE MARKS. Every component carries a raw now - a
  /// keyed sub-question contributes its own mark, a graded answer its 0-100 as
  /// a fraction - so the raw and the mark describe one paper out of one total.
  /// They used not to, and the two figures appeared side by side out of
  /// different totals ("1.40 / 2" beside "3 / 5" for the same attempt), which
  /// read as a defect rather than a distinction.
  ///
  /// [serverRawMax] first, because it is stated rather than inferred and it is
  /// present on every route. Summing the answers is the fallback for a server
  /// that predates the key, and only the detail route carries answers at all -
  /// so null still means "this surface cannot say", and the caller must print
  /// the raw bare rather than over a denominator it guessed.
  int? get rawOutOf {
    if (serverRawMax != null) return serverRawMax;
    int n = 0;
    bool any = false;
    for (final Response r in resp.values) {
      final int? m = r.rawMax;
      if (m == null) continue;
      any = true;
      n += m;
    }
    return any ? n : null;
  }

  /// The marks earned on the components the raw covers - which is now all of
  /// them - so [rawResult] and this are directly comparable.
  ///
  /// This used to subtract `mcq_mark` from `final_mark`, isolating the graded
  /// remainder, because the raw covered only that. It covers the whole answer
  /// now, so subtracting the objective half would compare the raw against a
  /// number that excludes most of what it measures and report every
  /// multiple-choice paper as wildly "understated".
  ///
  /// Null when no answer states its mark, which is every list route.
  double? get gradedMarks {
    double n = 0;
    bool any = false;
    for (final Response r in resp.values) {
      final double? f = r.finalMark;
      if (f == null || !r.hasRaw) continue;
      any = true;
      n += f;
    }
    return any ? n : null;
  }

  /// `earned / total marks`, displayed as marks. The denominator counts
  /// COMPONENTS, not questions - see [maxMarks].
  String marksDisplay(Assessment asm) =>
      '${earnedMarks(asm)} / ${maxMarks(asm)}';

  /// THE PERCENTAGE IS INTERNAL. It exists only to compare against
  /// `passThreshold` and is never shown as a candidate's score.
  double internalPercent(Assessment asm) {
    final int max = maxMarks(asm);
    if (max == 0) return 0;
    return 100.0 * earnedMarks(asm) / max;
  }

  /// Every subjective answer that is still unresolved. Invariant 4 forces the
  /// result to pending while this is non-empty, whatever the score - which is
  /// what stops an infrastructure failure being recorded as a candidate's
  /// failure.
  List<String> unresolvedQuestionIds(Assessment asm) {
    final List<String> out = <String>[];
    for (final Question q in asm.questions) {
      final Response? r = resp[q.id];
      if (r == null) continue;
      if (r.llmState.isUnresolved) out.add(q.id);
    }
    return out;
  }

  /// Submitted work the grader has not finished, so there is no final mark to
  /// release. The server's count is read first, as in [result]: a roster row
  /// carries no `resp`, so the walk alone found nothing on every list and an
  /// ungraded attempt was offered for release.
  bool awaitingGrader(Assessment asm) =>
      subjectivePending > 0 || unresolvedQuestionIds(asm).isNotEmpty;

  /// A re-score has been asked for on this attempt and has not landed yet.
  ///
  /// NOT the same set as [unresolvedQuestionIds]: the commonest re-score is of
  /// an already-SCORED answer, whose `llm_state` stays `scored` while it waits.
  /// So the marking table cannot read the queue off the state column, and a
  /// screen that wants to know whether anything is in flight has to ask here.
  bool get hasQueuedRescore =>
      resp.values.any((Response r) => r.rescoreRequested);

  /// A terminal grader error is holding this attempt.
  ///
  /// THE SERVER'S FLAG WINS. The local walk needs both the assessment's
  /// question list and this attempt's answers, and a ROSTER row has neither -
  /// `resp` is empty by design on every list route. So it returned false for
  /// every attempt on every list, and the badge that routes a person to the one
  /// state nothing clears by itself (invariant 5: a terminal error is never
  /// retried automatically) never appeared. The module already reports it as
  /// `subjective.has_terminal_error`, on the same row the badge is drawn from.
  ///
  /// The walk stays as the fallback, for the seed fixtures and for a payload
  /// that predates the flag.
  bool hasScoringError(Assessment asm) {
    final bool? fromServer = subjectiveHasError;
    if (fromServer != null) return fromServer;
    return asm.questions.any(
      (Question q) => resp[q.id]?.llmState == LlmState.error,
    );
  }

  /// The URL a candidate opens to sit this attempt.
  ///
  /// Derived from [token] rather than stored, so it cannot drift from the
  /// route the exam screen is actually registered at. Empty when there is no
  /// token, which is what the copy button checks before offering itself.
  String get candidateLink => token.isEmpty ? '' : '/exam/$token';

  /// Pass, fail or pending for this attempt, from ONE source of truth.
  ///
  /// THE SERVER'S VERDICT WINS whenever it sent one, whether or not an
  /// Assessment is loaded. That is the fix for a verdict that flipped on
  /// navigation: the candidate screens chose their source by asking whether
  /// `asm` happened to be in the store, and `loadExamByToken` puts one there
  /// the moment a candidate opens the exam route. A released 6 / 10 that the
  /// server had judged a PASS against a 60% bar therefore read PASS on a fresh
  /// load and FAIL after any trip through the runner, because the cached
  /// assessment carried no threshold and [result] re-derived it against the
  /// 70% default. Neither number changed - only which of the two answers the
  /// screen looked at.
  ///
  /// [result] stays the fallback, for the surfaces that genuinely recompute:
  /// an admin re-deriving against a threshold they have just changed, and the
  /// seed fixtures, which carry no verdict at all.
  ResultState verdict(Assessment? asm) {
    final ResultState? fromServer = serverResult;
    if (fromServer != null) return fromServer;
    return asm == null ? ResultState.pending : result(asm);
  }

  /// What is still being graded, in the candidate's own words - empty when
  /// nothing is.
  ///
  /// ONE SENTENCE, TWO SURFACES. A bare grey "Pending" pill over a released
  /// mark whose written answers are still queued reads as a fail. The count is
  /// the server's (`result.subjective_pending`); what it MEANS - that the total
  /// can only rise - is said here so the completion screen and the attempt
  /// card cannot word it differently.
  ///
  /// "Not marked yet", not "still being marked": the count includes answers
  /// parked on a grader error, which wait for an admin (R8-07).
  String get pendingMarkingNote => subjectivePending <= 0
      ? ''
      : subjectivePending == 1
      ? '1 written answer has not been marked yet - your total may rise when '
            'it is.'
      : '$subjectivePending written answers have not been marked yet - your '
            'total may rise when they are.';

  /// The deadline, not the candidate or proctoring, ended this sitting.
  bool get endedOnClock => autoSubmitReason == 'expired';

  /// The pass mark to draw a threshold marker against: the one the server
  /// applied, else the loaded assessment's, else the module's own
  /// DEFAULT_SUBJECTIVE_THRESHOLD as a last resort.
  double passMarkPercent(Assessment? asm) =>
      serverPassThreshold ?? asm?.passThreshold ?? 70;

  /// `pending -> pass | fail`, with pending forced by any unresolved answer.
  ///
  /// INVARIANT 4 IS CHECKED FROM THE SERVER'S COUNTERS FIRST. The local walk
  /// ([unresolvedQuestionIds]) needs this attempt's answers, and a ROSTER row
  /// has none - `resp` is empty by design on every list route - so the walk
  /// returned [] for every attempt on every list and the pending guard did
  /// nothing at all. An attempt held on a terminal grader error therefore fell
  /// through to the percentage and rendered a hard FAIL: measured on production,
  /// 3 / 34 against a 70% bar on a candidate the module itself was reporting as
  /// `pending`, because ten of their answers were parked on a Vertex outage.
  /// That is precisely the failure invariant 4 exists to prevent - an
  /// infrastructure fault recorded as the candidate's failure.
  ///
  /// So the two signals that ARE on a roster row are consulted before the walk.
  /// `subjectivePending` is the module's own count of answers still awaiting a
  /// verdict (pending/queued/failed/error) and [hasScoringError] prefers the
  /// server's `has_terminal_error` flag. Both were already parsed; this method
  /// simply never asked them. Same fix, same reasoning, as [hasScoringError]
  /// itself.
  ///
  /// Prefer [verdict], which takes the server's whole answer rather than
  /// re-deriving one. This stays for the surfaces that genuinely recompute: an
  /// admin re-deriving against a threshold they just changed, and the seed
  /// fixtures, which carry no verdict at all.
  ResultState result(Assessment asm) {
    if (!isDone) return ResultState.pending;
    if (subjectivePending > 0) return ResultState.pending;
    if (hasScoringError(asm)) return ResultState.pending;
    if (unresolvedQuestionIds(asm).isNotEmpty) return ResultState.pending;
    return internalPercent(asm) >= asm.passThreshold
        ? ResultState.pass
        : ResultState.fail;
  }

  Attempt copyWith({
    String? token,
    AttemptState? state,
    bool? isLocked,
    List<String>? questionOrder,
    DateTime? startedAt,
    DateTime? submittedAt,
    InviteState? inviteState,
    String? inviteError,
    int? violationCount,
    bool? violationLimitBreached,
    String? violationReason,
    DateTime? violationAt,
    int? aiViolationCount,
    bool? aiViolationLimitBreached,
    bool? autoSubmitted,
    String? autoSubmitReason,
    bool? resultsReleased,
    bool? integrityAlert,
    bool? scoreOutlier,
    CandidateFlag? candidateFlag,
    bool? piiAnonymized,
    Duration? testMedian,
    Map<String, Response>? resp,
  }) => Attempt(
    id: id,
    assessmentId: assessmentId,
    employeeId: employeeId,
    // Overridable, because a list row carries no token: `evaluator_admin_row`
    // sends the exam link only when a Manager asked a DETAIL route for it, so
    // a cache merge has to be able to keep the one it already holds.
    token: token ?? this.token,
    state: state ?? this.state,
    isLocked: isLocked ?? this.isLocked,
    questionOrder: questionOrder ?? this.questionOrder,
    startedAt: startedAt ?? this.startedAt,
    submittedAt: submittedAt ?? this.submittedAt,
    inviteState: inviteState ?? this.inviteState,
    inviteError: inviteError ?? this.inviteError,
    violationCount: violationCount ?? this.violationCount,
    violationLimitBreached:
        violationLimitBreached ?? this.violationLimitBreached,
    violationReason: violationReason ?? this.violationReason,
    violationAt: violationAt ?? this.violationAt,
    autoSubmitted: autoSubmitted ?? this.autoSubmitted,
    autoSubmitReason: autoSubmitReason ?? this.autoSubmitReason,
    resultsReleased: resultsReleased ?? this.resultsReleased,
    integrityAlert: integrityAlert ?? this.integrityAlert,
    scoreOutlier: scoreOutlier ?? this.scoreOutlier,
    candidateFlag: candidateFlag ?? this.candidateFlag,
    piiAnonymized: piiAnonymized ?? this.piiAnonymized,
    // Carried through like the server counters below - the tally is the
    // server's to report and this copyWith has no parameter for it, so
    // rebuilding an Attempt after a local change must not drop it back to
    // empty and hide a recorded violation log.
    violations: violations,
    aiViolationCount: aiViolationCount ?? this.aiViolationCount,
    aiViolationLimitBreached:
        aiViolationLimitBreached ?? this.aiViolationLimitBreached,
    // Carried, like [violations]: the server's to report.
    aiViolations: aiViolations,
    aiStatus: aiStatus,
    // Carried through, not dropped. These hold the server's own marks and
    // answer count; rebuilding an Attempt without them (e.g. after a
    // local state change) silently reverted a correct "0 / 3" to "0 / 0".
    serverEarned: serverEarned,
    serverTotal: serverTotal,
    serverAnswered: serverAnswered,
    serverQuestions: serverQuestions,
    objectiveScore: objectiveScore,
    objectiveMax: objectiveMax,
    subjectiveScore: subjectiveScore,
    subjectiveMax: subjectiveMax,
    subjectivePending: subjectivePending,
    // Carried like the server counters above: it is the server's to report and
    // this copyWith has no parameter for it, so forwarding is what stops a
    // toggle elsewhere on the screen blanking the released breakdown.
    resultSections: resultSections,
    rawResult: rawResult,
    serverRawMax: serverRawMax,
    subjectiveState: subjectiveState,
    scoringRequested: scoringRequested,
    deadline: deadline,
    clockOffset: clockOffset,
    subjectiveHasError: subjectiveHasError,
    // Carried, like the server counters above: the grader's reason is the
    // server's to report and this copyWith has no parameter for it, so a local
    // change elsewhere on the screen must not blank the one notice saying why
    // the queue is waiting.
    subjectiveError: subjectiveError,
    serverResult: serverResult,
    serverBucket: serverBucket,
    serverPassThreshold: serverPassThreshold,
    assessmentName: assessmentName,
    durationMinutes: durationMinutes,
    testMedian: testMedian ?? this.testMedian,
    resp: resp ?? this.resp,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'assessmentId': assessmentId,
    'employeeId': employeeId,
    'token': token,
    'state': state.wire,
    'isLocked': isLocked,
    'questionOrder': questionOrder,
    'startedAt': startedAt?.toIso8601String(),
    'submittedAt': submittedAt?.toIso8601String(),
    'inviteState': inviteState.wire,
    'inviteError': inviteError,
    'violationCount': violationCount,
    'violationLimitBreached': violationLimitBreached,
    'violationReason': violationReason,
    'violationAt': violationAt?.toIso8601String(),
    // The tally survives a round-trip as a list of {reason, count} objects,
    // the same shape [fromJson] reads off the wire.
    'violations': <Map<String, dynamic>>[
      for (final ({String reason, int count}) v in violations)
        <String, dynamic>{'reason': v.reason, 'count': v.count},
    ],
    'aiViolationCount': aiViolationCount,
    'aiViolationLimitBreached': aiViolationLimitBreached,
    'aiViolations': <Map<String, dynamic>>[
      for (final ({String reason, int count}) v in aiViolations)
        <String, dynamic>{'reason': v.reason, 'count': v.count},
    ],
    'aiStatus': aiStatus,
    'autoSubmitted': autoSubmitted,
    'autoSubmitReason': autoSubmitReason,
    'resultsReleased': resultsReleased,
    'integrityAlert': integrityAlert,
    'scoreOutlier': scoreOutlier,
    'candidateFlag': candidateFlag.toJson(),
    'piiAnonymized': piiAnonymized,
    'resp': resp.map(
      (String k, Response v) => MapEntry<String, dynamic>(k, v.toJson()),
    ),
  };

  /// Parses either shape: the seed fixtures (camelCase, flat) or a live
  /// `/api/v1/assessments/<id>/candidates` row (snake_case, integer ids,
  /// nested `candidate` / `flags` / `subjective` objects).
  ///
  /// Every read goes through [jget]/[jval]/[jid]. A raw `as String` on an id
  /// throws against the wire, and that TypeError used to escape `refresh()`
  /// and leave the loader spinning with an empty roster behind it.
  factory Attempt.fromJson(Map<String, dynamic> j) {
    // The API groups the proctoring signals under `flags`; the fixtures hold
    // them flat. Read the group first, then fall back to the flat spelling.
    final Map<String, dynamic> flags = jobj(j, 'flags');
    // ...and the CANDIDATE's own attempt row groups them under `proctoring`
    // instead (serializers.attempt). Neither of the two spellings above
    // matched it, so the one surface a candidate actually loads reported a
    // violation count of zero no matter how many the server had recorded.
    final Map<String, dynamic> proctoring = jobj(j, 'proctoring');
    final Map<String, dynamic> candidate = jobj(j, 'candidate');

    // Hoisted because the BOOLEAN below is derived from it. Every payload that
    // carries the reason sends it flat; the `proctoring` read is a defensive
    // second spelling, not a shape the module currently produces.
    final String autoReason = jval(
      j,
      'autoSubmitReason',
      jval(proctoring, 'autoSubmitReason', ''),
    );

    // 'closed' collapses into submitted (see AttemptState.parse) so released
    // results stay reachable - but ONLY a real submission earns that. An
    // attempt that was never even started on a since-closed assessment must
    // stay pending, or the candidate is told their answers were recorded.
    final String rawState = (jget(j, 'state') as String?) ?? '';
    final bool neverSubmitted =
        jval(j, 'submittedAt', '').isEmpty && jval(j, 'startedAt', '').isEmpty;
    final AttemptState state = rawState == 'closed' && neverSubmitted
        ? AttemptState.pending
        : AttemptState.parse(rawState);

    return Attempt(
      id: jid(jget(j, 'id')),
      assessmentId: jid(jget(j, 'assessmentId')),
      // `candidate` is an object on the wire, `employeeId` a bare id in the
      // fixtures. Without this the roster shows a blank name for every row.
      employeeId: candidate.isNotEmpty
          ? jid(candidate['id'])
          : jid(jget(j, 'employeeId')),
      token: jval(j, 'token', jval(j, 'accessToken', '')),
      state: state,
      isLocked: jval(j, 'isLocked', false),
      questionOrder:
          ((jget(j, 'questionOrder') ?? const <dynamic>[]) as List<dynamic>)
              .map((dynamic q) => '$q')
              .toList(),
      startedAt: DateTime.tryParse(jval(j, 'startedAt', '')),
      submittedAt: DateTime.tryParse(jval(j, 'submittedAt', '')),
      inviteState: InviteState.parse(jget(j, 'inviteState') as String?),
      inviteError: jval(j, 'inviteError', ''),
      violationCount: jval(
        flags,
        'violationCount',
        jval(proctoring, 'violationCount', jval(j, 'violationCount', 0)),
      ),
      // Read wherever the count is, for the same reason.
      violationLimitBreached: jval(
        flags,
        'violationLimitBreached',
        jval(
          proctoring,
          'violationLimitBreached',
          jval(j, 'violationLimitBreached', false),
        ),
      ),
      violationReason: jval(
        flags,
        'violationReason',
        jval(proctoring, 'violationReason', jval(j, 'violationReason', '')),
      ),
      violationAt: DateTime.tryParse(jval(j, 'violationAt', '')),
      // TOLERANT BY DESIGN. A legacy attempt sends no `violations` key, an
      // in-flight one may send an empty list, and free-form rows have been
      // known to arrive with a missing count or a non-numeric one - none of
      // those may throw and lose the whole attempt on parse. Anything that is
      // not a `{reason, count}` object is skipped; the order the server sent
      // (count descending) is kept as-is rather than re-sorted here.
      //
      // NESTED UNDER `flags`, WHICH IS WHERE THE MODULE PUTS IT.
      // `evaluator_admin_row` sends the tally inside the `flags` object, beside
      // `integrityAlert` and `scoreOutlier`, and this read looked only at the
      // top level. So it found nothing on every real payload, `violations`
      // parsed empty, and `proctoringViolationNotice` took its legacy fallback -
      // printing "Last reason: Clipboard action: paste." on an attempt with nine
      // violations across several kinds. The tally was built, serialized and
      // then dropped one key short of the screen.
      violations: <({String reason, int count})>[
        for (final dynamic v in jlist(
          jget(flags, 'violations') ??
              jget(proctoring, 'violations') ??
              jget(j, 'violations'),
        ))
          if (v is Map<String, dynamic> && v['reason'] != null)
            (
              reason: '${v['reason']}',
              count: (v['count'] is num) ? (v['count'] as num).toInt() : 0,
            ),
      ],
      // Wherever the regular count is, for the same reason.
      aiViolationCount: jval(
        flags,
        'aiViolationCount',
        jval(proctoring, 'aiViolationCount', jval(j, 'aiViolationCount', 0)),
      ),
      aiViolationLimitBreached: jval(
        flags,
        'aiViolationLimitBreached',
        jval(
          proctoring,
          'aiViolationLimitBreached',
          jval(j, 'aiViolationLimitBreached', false),
        ),
      ),
      aiViolations: jtally(
        jget(flags, 'aiViolations') ??
            jget(proctoring, 'aiViolations') ??
            jget(j, 'aiViolations'),
      ),
      aiStatus: jval(
        flags,
        'aiStatus',
        jval(proctoring, 'aiStatus', jval(j, 'aiStatus', '')),
      ),
      // THE REASON IS THE FALLBACK, because for a long time nothing on the wire
      // set this at all. There is no `auto_submitted` column on an evaluator -
      // only a response has one - so this parsed to false on every server
      // payload, and the flag was true only in the seconds between a local
      // auto-submit and the next refresh, which overwrote it. The module now
      // derives and sends the boolean; the fallback keeps a cached or
      // fixture payload that predates it rendering the right branch.
      autoSubmitted: jval(j, 'autoSubmitted', autoReason.isNotEmpty),
      autoSubmitReason: autoReason,
      // The admin roster sends a flat `results_released`; a candidate's own
      // card nests it as `result.released`. Reading only the flat spelling
      // left every released result showing as "awaiting release" on the one
      // screen the candidate opens to see it.
      resultsReleased: jval(
        jobj(j, 'result'),
        'released',
        jval(j, 'resultsReleased', false),
      ),
      integrityAlert: jval(
        flags,
        'integrityAlert',
        jval(j, 'integrityAlert', false),
      ),
      scoreOutlier: jval(flags, 'scoreOutlier', jval(j, 'scoreOutlier', false)),
      // The BLOCK, not the boolean in `flags`. `flags.manual_flagged` says
      // only that a flag exists; the block carries the remark and who raised
      // it, which is the half an operator actually needs to read. Absent on
      // every candidate-facing payload, which parses to `CandidateFlag.none`.
      candidateFlag: CandidateFlag.fromJson(jobj(j, 'candidateFlag')),
      // Nested under `flags` like its three neighbours above - this one was
      // missed, so the erased-data badge never appeared and "Erase candidate
      // data" stayed on offer for an attempt already anonymised.
      piiAnonymized: jval(
        flags,
        'piiAnonymized',
        jval(j, 'piiAnonymized', false),
      ),
      serverEarned: _marksPart(jobj(j, 'result'), 0) ?? _marksPart(j, 0),
      // `progress` LAST, so the admin roster's flat spelling still wins where
      // it exists. The candidate's own route is the only one that nests the
      // count, and none of the three sources above can reach it: `jget` only
      // converts camelCase to snake_case at the TOP level, and `_marksPart`
      // needs a `score_marks` string that INVARIANT 3 withholds until a person
      // releases the result. So every card on "My assessments" read
      // "0 questions" against an attempt the server had already reported as
      // six - and the in-progress bar divided by that same zero.
      //
      // A LAST-RESORT MARKS DENOMINATOR, AND A KNOWN UNDERCOUNT. The module
      // scores COMPONENTS now - a three-sub-question mcq is worth 3 - so
      // `total_questions` is no longer the mark count it used to be. It stays
      // in the chain because the two spellings of `score_marks` above are what
      // actually carry the marks, and both are withheld by invariant 3 until a
      // person releases the result: without this the progress bar divided by
      // zero and the card read "0 questions" against an attempt the server had
      // already reported as six. A released attempt never reaches it.
      serverTotal:
          _marksPart(jobj(j, 'result'), 1) ??
          _marksPart(j, 1) ??
          (jget(j, 'totalQuestions') as num?)?.toInt() ??
          (jobj(j, 'progress')['total'] as num?)?.toInt(),
      // The admin roster reports how many answers landed. Counting `resp`
      // instead reads 0 on every list row, because answers arrive only on the
      // DETAIL endpoint - which is why a submitted attempt with 3 answers
      // displayed "0".
      serverAnswered:
          (jget(j, 'answeredCount') as num?)?.toInt() ??
          (jobj(j, 'progress')['answered'] as num?)?.toInt(),
      // The QUESTION count, read straight off the two keys that carry it -
      // never through `score_marks`, which is a MARK count now.
      serverQuestions:
          (jget(j, 'totalQuestions') as num?)?.toInt() ??
          (jobj(j, 'progress')['total'] as num?)?.toInt(),
      // `objective` / `subjective` are nested objects on the admin roster.
      objectiveScore: (jobj(j, 'objective')['score'] as num?)?.toInt(),
      objectiveMax: (jobj(j, 'objective')['max'] as num?)?.toInt(),
      subjectiveScore: (jobj(j, 'subjective')['score'] as num?)?.toInt(),
      subjectiveMax: (jobj(j, 'subjective')['max'] as num?)?.toInt(),
      // TWO SHAPES. The roster nests the count under `subjective`; a CANDIDATE
      // payload has no such object at all and carries it as
      // `result.subjective_pending`.
      subjectivePending:
          (jobj(j, 'subjective')['pending'] as num?)?.toInt() ??
          (jget(jobj(j, 'result'), 'subjectivePending') as num?)?.toInt() ??
          0,
      // NESTED INSIDE `result`, which is the released block - so an unreleased
      // attempt parses to an empty list without any check here. That is the
      // point: `candidate_result` omits every score key until a person
      // publishes, so there is nothing to guard against rendering early.
      resultSections: jlist(
        jget(jobj(j, 'result'), 'breakdown'),
      ).whereType<Map<String, dynamic>>().map(ResultSection.fromJson).toList(),
      // FLAT on the wire (`raw_result`), not inside the `subjective` object:
      // it spans both halves of the paper. Left null rather than defaulted to
      // 0 when absent, so "the route did not send it" stays distinguishable
      // from "the candidate genuinely earned nothing" - a 0 would be shown as
      // a real raw score on a candidate list that never carries one.
      rawResult: (jget(j, 'rawResult') as num?)?.toDouble(),
      // Same flat placement and the same null-not-zero rule as `rawResult`:
      // a 0 here would be read as "out of nothing" and suppress the whole
      // line, which is exactly what a list route sending neither key wants,
      // but NOT what a real attempt worth 0 components would mean.
      serverRawMax: (jget(j, 'rawMax') as num?)?.toInt(),
      subjectiveState: LlmState.parse(
        jobj(j, 'subjective')['state'] as String?,
      ),
      // THE FLAG THE SERVER'S DRAINER SELECTS ON, and the only honest answer to
      // "is this candidate's grading actually running?". `subjective.state` of
      // `pending` does NOT mean that: with automatic grading off, an answer
      // sits `pending` forever because nobody ever queued it. Reading the
      // assessment's `awaiting_scoring_count` instead - which counts answers
      // that NEED grading, not answers being graded - is what kept the Kill
      // Scoring button on screen permanently for an assessment where nothing
      // was being graded at all.
      scoringRequested:
          jobj(j, 'subjective')['scoring_requested'] as bool? ?? false,
      deadline: DateTime.tryParse(jval(j, 'deadline', '')),
      clockOffset: _clockOffset(jval(j, 'serverNow', '')),
      subjectiveHasError: jobj(j, 'subjective')['has_terminal_error'] as bool?,
      subjectiveError: jobj(j, 'subjective')['error'] as String? ?? '',
      serverResult: _serverVerdict(j),
      serverBucket: _serverBucket(j),
      serverPassThreshold: _passThresholdPart(j),
      assessmentName: jval(j, 'name', jval(j, 'assessmentName', '')),
      durationMinutes: jval(j, 'durationMinutes', 0),
      testMedian: _testMedianFrom(j),
      // Answers arrive only on the DETAIL endpoint; a list row carries none.
      //
      // TWO WIRE SHAPES, and only one of them was read. The fixtures hold a
      // MAP keyed by question id; `/api/v1/attempts/<id>` sends a LIST under
      // `answers`, one `response_audit` per answer. Reading `resp` alone meant
      // the live detail route parsed to an EMPTY map, so Attempt detail's
      // "Score details" said "This candidate has not answered anything yet."
      // directly under a header reading 10 / 10 answered - the server had sent
      // every answer, the parser looked under the other key.
      resp: _respFrom(j),
    );
  }

  /// `test_median_seconds` as a Duration, or null when it says nothing true.
  ///
  /// Read as `num` then `toInt()`: a double like 30.0 is an int in compiled JS
  /// but not on the VM, so neither spelling may throw. Absent, null, not a
  /// number, or <= 0 all mean "no median".
  static Duration? _testMedianFrom(Map<String, dynamic> j) {
    final Object? v = jget(j, 'testMedianSeconds');
    final int secs = v is num ? v.toInt() : 0;
    return secs > 0 ? Duration(seconds: secs) : null;
  }

  /// The response map, from whichever shape the payload used.
  ///
  /// Keyed by QUESTION id in both, because that is what every screen joins on:
  /// the grid walks `asm.questions` and asks the attempt for each one. The
  /// audit rows carry `question_id`, so the key is theirs to give - an answer
  /// with no question id is dropped rather than filed under '', which would
  /// collapse every such row onto one key and silently hide all but the last.
  static Map<String, Response> _respFrom(Map<String, dynamic> j) {
    final Object? asMap = jget(j, 'resp');
    if (asMap is Map<String, dynamic>) {
      return asMap.map(
        (String k, dynamic v) =>
            MapEntry<String, Response>(k, Response.fromJson(jmap(v))),
      );
    }
    final Map<String, Response> out = <String, Response>{};
    for (final dynamic row in jlist(jget(j, 'answers'))) {
      final Map<String, dynamic> m = jmap(row);
      final String qid = jid(jget(m, 'questionId'));
      if (qid.isEmpty) continue;
      out[qid] = Response.fromJson(m);
    }
    return out;
  }
}

/// ── The candidate's own answer sheet ──────────────────────────────────────
///
/// `/api/v1/exam/<token>/answers` is the one route that shows a candidate what
/// they answered, and it is scoped to a TOKEN rather than to an assessment
/// record. It carries the assessment's name, the result and one row per
/// question, every option already resolved to a label - option ids never leave
/// the server on this route.
///
/// This type exists because the review screen used to require an [Assessment],
/// which a candidate can never load (`/api/v1/assessments` is a manager
/// route), so a perfectly valid link resolved to "This link does not work".
class AnswerSheet {
  /// The assessment's name, so the screen can title itself without joining to
  /// a record it cannot load.
  final String assessmentName;

  /// Invariant 3's gate, as the SERVER reports it for this token.
  final bool released;

  /// Marks, parsed from `score_marks` ("0 / 3"). Null on an unreleased sheet.
  final int? earned;
  final int? total;

  final ResultState result;
  final List<AnswerSheetRow> rows;

  /// The pass mark this attempt was actually judged against, as a percentage.
  ///
  /// The sheet used to omit it, so the candidate's own category panel coloured
  /// its bars against a hardcoded 70 and PRINTED that number - telling somebody
  /// sitting a 60% paper that the bar was 70%. The server sends the figure
  /// `_compute_result` really applied, so it cannot disagree with the verdict
  /// shown beside it. Null only on an unreleased sheet, where there is no
  /// verdict to explain.
  final double? passThreshold;

  /// Where the marks came from, section by section. See [ResultSection].
  ///
  /// Parsed out of the same `result` block as everything else here, so it is
  /// gated by the same `released` check by construction - an unreleased sheet
  /// yields an empty list without this needing its own guard.
  final List<ResultSection> resultSections;

  const AnswerSheet({
    this.assessmentName = '',
    this.released = false,
    this.earned,
    this.total,
    this.result = ResultState.pending,
    this.rows = const <AnswerSheetRow>[],
    this.passThreshold,
    this.resultSections = const <ResultSection>[],
  });

  /// Whether there is a score to render. Marks are a PAIR, so one half without
  /// the other is not a figure anybody should see.
  bool get hasMarks => released && earned != null && total != null;

  factory AnswerSheet.fromJson(Map<String, dynamic> j) {
    final Map<String, dynamic> res = jobj(j, 'result');

    // THE GATE, applied while PARSING rather than while rendering.
    //
    // Every scoring field below is dropped when the result is unreleased, so a
    // screen cannot disclose a mark, a verdict or per-question correctness by
    // forgetting to check - the value simply is not in the object.
    final bool released = jval(res, 'released', false);

    return AnswerSheet(
      assessmentName: jval(jobj(j, 'assessment'), 'name', ''),
      released: released,
      // Preferred off the assessment block; `result` carries the same figure,
      // so either shape answers. Null rather than a default: a made-up bar is
      // worse than no bar.
      passThreshold: released
          ? (jget(jobj(j, 'assessment'), 'passThreshold') as num?)
                    ?.toDouble() ??
                (jget(res, 'passThreshold') as num?)?.toDouble()
          : null,
      earned: released ? _marksPart(res, 0) : null,
      total: released ? _marksPart(res, 1) : null,
      result: released
          ? ResultState.parse(jval(res, 'result', ''))
          : ResultState.pending,
      rows: ((jget(j, 'rows') ?? const <dynamic>[]) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(
            (Map<String, dynamic> r) =>
                AnswerSheetRow.fromJson(r, released: released),
          )
          .toList(),
      // Gated with the rest: `res` is empty of score keys until a person
      // publishes, so an unreleased sheet cannot leak the split either.
      resultSections: released
          ? jlist(jget(res, 'breakdown'))
                .whereType<Map<String, dynamic>>()
                .map(ResultSection.fromJson)
                .toList()
          : const <ResultSection>[],
    );
  }
}

/// One question on an answer sheet.
class AnswerSheetRow {
  /// The question's position in the candidate's own shuffled order.
  final int number;
  final String name;
  final String prompt;
  final QType type;

  /// What the candidate chose, already resolved to labels.
  final List<String> chosen;

  /// The key, as labels. Empty before release, and empty for a subjective
  /// question - a rubric's reference answer stays inside the audit surface.
  final List<String> correct;

  /// Free text. Not gated: the candidate's own words are theirs to read back
  /// whether or not a mark has been released.
  final String justification;

  /// A labelling answer, keyed by box number. Stored server-side in the same
  /// column as [justification], so until it was decoded the candidate's own
  /// results sheet showed them the raw JSON of what they had typed.
  final Map<int, String> labelAnswers;

  /// A transcription's own category / characteristics / speakers; null on
  /// every other type. Never the key.
  final ClipAnswers? clip;

  /// The server's own wording for this row's outcome ("Incorrect", "No
  /// Grade"). Empty before release.
  final String verdict;

  /// The tone the SERVER licensed for [verdict], off its `kind` field, so the
  /// client never decides that an outcome is red.
  final Tone tone;

  /// The grader's one-line judgement of this answer (`score_verdict`), shown
  /// first under "The judge's verdict". Released rows only, and empty when the
  /// server's verdict gate withholds one written under older instructions.
  final String scoreVerdict;
  final String feedback;
  final List<String> credit;
  final List<String> deductions;

  /// The SOP categories this question exercised, as canonical tag names.
  ///
  /// NOT GATED on release, for the same reason the images are not: a tag names
  /// a SKILL the question was testing, never the answer or the mark. A candidate
  /// mid-grading may legitimately read "this question was about artifact
  /// detection" - what release withholds is how they DID on it, which lives in
  /// [scoreRaw] and [verdict].
  final List<String> tags;

  /// The grader's own score for this answer as a 0-1 FRACTION, when there is
  /// one.
  ///
  /// GATED, because it IS the mark in all but name. Null on an objective
  /// question (no grader ran) and null before release.
  ///
  /// A FRACTION, NOT A PERCENTAGE, and the two live side by side in this API:
  /// `response_row` sends `llm_raw_100` (0-100) while this route sends
  /// `score_raw` (`llm_raw_score`, documented in the module as "llm_raw_100
  /// expressed as a 0-1 fraction"). Reading one on the other's scale is a
  /// silent 100x error - a 0.75 answer would render as "1%" - so any consumer
  /// must state which it holds. This holds the fraction.
  ///
  /// This is what makes a per-assessment category breakdown possible on the
  /// candidate's own answer sheet: the categories live on [tags], the
  /// performance lives here, and this route is the only one a candidate has
  /// that carries both.
  final double? scoreRaw;

  /// What this answer actually scored, out of [marksAvailable].
  ///
  /// A COUNT OF MARKS, NOT A FRACTION - the trap living next door in
  /// [scoreRaw]. An image_ab answer with four verdict axes and a justification
  /// is worth 5, and this arrives as e.g. 1.0 of 5, where `scoreRaw` on the
  /// same row is the grader's 0-1 number for the written part alone.
  ///
  /// GATED with [scoreRaw], because it IS the mark for this answer.
  ///
  /// NULL IS NOT ZERO. Null means there is no pair on this row to read - the
  /// sheet is unreleased, or the server predates per-answer marks and sent no
  /// `marks_earned` at all. Defaulting to 0.0 would score every answer from an
  /// older backend as a lost mark and show a candidate a paper of weaknesses
  /// they did not earn, so the absence is kept and `answersOfSheet` falls back
  /// to the old pass/fail-per-row reading for exactly those rows.
  final double? marksEarned;

  /// What the question behind this row was worth.
  ///
  /// ONE MARK PER COMPONENT, not one per question: a mark for each keyed
  /// sub-question, one for the graded written answer, one for the labelling box
  /// set. So a three-part mcq is worth 3 and an image_ab with four verdict axes
  /// plus a justification is worth 5, and a category mixing the two can only be
  /// averaged honestly if each row carries its own denominator.
  ///
  /// UNGATED, for the same reason [tags] is: what a question is worth describes
  /// the paper, never how the candidate did on it.
  ///
  /// FALLS BACK TO 1, NEVER TO 0. It is a DENOMINATOR - the category panel
  /// divides by the sum of these - so a 0 from an older server that sends no
  /// `marks_available` would be a division by zero rather than a missing field.
  /// 1 is also what those servers meant: before the change every question was
  /// worth exactly one mark.
  final int marksAvailable;

  /// The pictures and clips the question was ASKING ABOUT.
  ///
  /// Parsed exactly as [Question.fromJson] parses them, off the same keys and
  /// the same token-scoped routes, because a review row and a live question
  /// are the same question seen twice. Without these the sheet printed
  /// "Response A, Both Good" over an image pair the candidate could no longer
  /// see, and a labelling answer as a numbered list with no screenshot above
  /// it - an answer sheet that omits what was asked.
  final List<Asset> images;
  final List<Asset> videos;

  const AnswerSheetRow({
    this.number = 0,
    this.name = '',
    this.prompt = '',
    this.type = QType.mcq,
    this.chosen = const <String>[],
    this.correct = const <String>[],
    this.justification = '',
    this.labelAnswers = const <int, String>{},
    this.clip,
    this.verdict = '',
    this.tone = Tone.inert,
    this.scoreVerdict = '',
    this.feedback = '',
    this.credit = const <String>[],
    this.deductions = const <String>[],
    this.tags = const <String>[],
    this.scoreRaw,
    this.marksEarned,
    this.marksAvailable = 1,
    this.images = const <Asset>[],
    this.videos = const <Asset>[],
  });

  /// Anything to show above the answer.
  bool get hasMedia => images.isNotEmpty || videos.isNotEmpty;

  /// A side-free image_ab ([abIsSideFree]), read off what was [chosen].
  ///
  /// This row carries no axis options, only the picks, so it is partial
  /// evidence: an unanswered row keeps the A/B captions, and a "Both Good" pick
  /// counts as A/B, since on an A/B paper it may be all that was chosen.
  bool get isSideFreeAb =>
      abIsSideFree(type, chosen) &&
      !chosen.any((String c) => _abBothWords.contains(_abNorm(c)));

  /// Whether the candidate put anything in, mirroring [Response.hasInput].
  bool get hasInput =>
      chosen.isNotEmpty ||
      justification.trim().isNotEmpty ||
      labelAnswers.values.any((String v) => v.trim().isNotEmpty) ||
      (clip != null && !clip!.transcribed);

  /// The labelled boxes in box order, blanks dropped, ready to print as
  /// "1. spotify icon".
  List<MapEntry<int, String>> get labelLines =>
      labelAnswers.entries
          .where((MapEntry<int, String> e) => e.value.trim().isNotEmpty)
          .map(
            (MapEntry<int, String> e) =>
                MapEntry<int, String>(e.key, e.value.trim()),
          )
          .toList()
        ..sort(
          (MapEntry<int, String> a, MapEntry<int, String> b) =>
              a.key.compareTo(b.key),
        );

  factory AnswerSheetRow.fromJson(
    Map<String, dynamic> j, {
    required bool released,
  }) => AnswerSheetRow(
    number: jval(j, 'index', 0),
    name: jval(j, 'name', ''),
    prompt: jval(j, 'prompt', ''),
    type: QType.parse(jval(j, 'questionType', '')),
    chosen: _labels(jget(j, 'chosen')),
    // Every field from here down states or implies whether the answer was
    // right, so all of them are withheld until release.
    correct: released ? _labels(jget(j, 'correct')) : const <String>[],
    justification: _ownWords(jval(j, 'justification', '')),
    labelAnswers: labelMap(jget(j, 'labelAnswers')) ?? const <int, String>{},
    clip: jget(j, 'clipAnswers') is Map
        ? ClipAnswers.fromJson(jget(j, 'clipAnswers'))
        : null,
    verdict: released ? jval(j, 'verdict', '') : '',
    tone: released ? _kindTone(jval(j, 'kind', '')) : Tone.inert,
    scoreVerdict: released ? jval(j, 'scoreVerdict', '') : '',
    feedback: released ? jval(j, 'feedback', '') : '',
    credit: released ? _labels(jget(j, 'credit')) : const <String>[],
    deductions: released ? _labels(jget(j, 'deductions')) : const <String>[],
    // Ungated: a tag names the SKILL under test, not the outcome.
    tags: jtags(j),
    // Gated: `score_raw` is the grader's number for this answer.
    scoreRaw: released ? (jget(j, 'scoreRaw') as num?)?.toDouble() : null,
    // Gated with it: `marks_earned` is that answer's mark in plain marks.
    marksEarned: released ? (jget(j, 'marksEarned') as num?)?.toDouble() : null,
    // Ungated, and defaulted to 1 rather than 0 so a row from a server that
    // predates the field is still a usable denominator.
    marksAvailable: jval(j, 'marksAvailable', 1),
    // NOT gated on `released`. The question is not the answer key: the
    // candidate was shown these while sitting the exam, and withholding them
    // afterwards would hide the thing every other field on this row refers to.
    images: _assetsWithBoxes(
      jlist(jget(j, 'images')),
      jlist(jget(j, 'label_boxes') ?? jget(j, 'labelBoxes')),
    ),
    videos: jlist(
      jget(j, 'videos') ?? jget(j, 'video_files'),
    ).whereType<Map<String, dynamic>>().map(Asset.fromJson).toList(),
  );
}

/// The candidate's OWN words, or nothing.
///
/// When an attempt settles, `_auto_submit_expired` writes a Response for every
/// question the candidate never reached, with `justification` set to
/// "[Auto-submitted: time expired]" (or "[Submitted with unanswered
/// questions]", or the proctoring variant). That is the module's bookkeeping,
/// not an answer, and non-empty it would make [AnswerSheetRow.hasInput] true
/// and print the system string under "Your answer".
///
/// Dropped here, at the parse boundary, so both surfaces fall to "You did not
/// answer this question." and the inert "Not answered" pill. The server blanks
/// it too, on `auto_submitted`; this copy matches the placeholder text, so a
/// backend without that rule still reads honestly.
String _ownWords(String s) {
  final String t = s.trim();
  return t.startsWith('[Auto-submitted') ||
          t == '[Submitted with unanswered questions]'
      ? ''
      : s;
}

/// An int-keyed box->text map out of the API's string-keyed JSON object.
/// Null in means null out, which is how a non-labelling answer stays distinct
/// from a labelling one where every box was left blank.
Map<int, String>? labelMap(Object? v) {
  if (v is! Map<String, dynamic>) return null;
  return v.map(
    (String k, dynamic e) => MapEntry<int, String>(int.tryParse(k) ?? 0, '$e'),
  );
}

/// A list of display strings out of a field the API may send either as bare
/// strings (`chosen`, `correct`) or as note objects (`credit`, `deductions`).
List<String> _labels(Object? v) {
  if (v is! List<dynamic>) return const <String>[];
  return v
      .map(
        (Object? e) => e is Map<String, dynamic>
            ? (e['reason'] ?? e['label'] ?? e['text'] ?? '').toString()
            : '$e',
      )
      .where((String s) => s.isNotEmpty)
      .toList();
}

/// The module's `kind` field for a row, mapped onto the tone it is licensed to
/// use. An unrecognised kind stays inert rather than guessing at red.
Tone _kindTone(String kind) => switch (kind) {
  'ok' || 'pass' || 'correct' => Tone.ok,
  'fail' || 'bad' || 'incorrect' => Tone.bad,
  'warn' || 'partial' => Tone.warn,
  'info' => Tone.info,
  _ => Tone.inert,
};

/// One `/api/v1/exam/<token>/state` answer: the whole runner state, as the
/// SERVER decided it.
///
/// The runner used to read `Assessment.questions[n - 1]` and do its own index
/// arithmetic. The exam payload has never carried a question list - the
/// assessment object in it is five keys, and `questions` is not one of them -
/// so `asm.questions` was always empty and every candidate was told "This
/// assessment has no questions". The server sends ONE question at a time,
/// with its own `index` and `total`, and returns the next one from
/// `/answer`. This type is that envelope.
///
/// [outcome] is the single navigation authority. It is one of eight values and
/// the server has already applied every rule behind them - locked beats
/// closed, an expired attempt is auto-submitted before it is reported
/// complete. The client renders what it is told rather than re-deriving it.
class ExamView {
  /// invalid | login_required | wrong_candidate | closed | seb_required |
  /// instructions | question | complete
  ///
  /// Empty when the payload named none. A gate still reads that as invalid
  /// (`GateKind.parse`), but only an EXPLICIT `invalid` overrides a sitting
  /// the store already holds - see the exam screen.
  final String outcome;

  /// The current question - only on `outcome == 'question'`.
  final Question? question;

  /// 1-based position and cohort size, both from the server.
  final int index;
  final int total;

  final Set<String> answeredIds;
  final int progressPercent;

  /// A manager holding the token may READ the runner and never write to it.
  /// Every mutating route refuses with `wrong_candidate`, so the UI has to
  /// know before it offers a control that cannot work.
  final bool preview;

  /// `instructions` extras: duration_minutes, total_questions, question_limit.
  final Map<String, dynamic> instructions;

  /// `closed` carries a reason; `wrong_candidate` carries who was expected.
  final String reason;
  final String expectedCandidate;

  /// `complete` extras.
  final bool canReviewAnswers;
  final bool expired;

  /// Safe Exam Browser links: on `seb_required`, and on every envelope while
  /// the rule is on. Empty otherwise.
  final SebLinks seb;

  /// Where AI proctoring snapshots go, on `/begin`, `/state` and `/answer`'s
  /// `next` while `rules.ai_proctor` is on. Null otherwise, and when storage is not
  /// configured on the server.
  final EvidenceUploadPolicy? evidenceUpload;

  const ExamView({
    required this.outcome,
    this.question,
    this.index = 1,
    this.total = 0,
    this.answeredIds = const <String>{},
    this.progressPercent = 0,
    this.preview = false,
    this.instructions = const <String, dynamic>{},
    this.reason = '',
    this.expectedCandidate = '',
    this.canReviewAnswers = false,
    this.expired = false,
    this.seb = const SebLinks(),
    this.evidenceUpload,
  });

  bool get isQuestion => outcome == 'question';
  bool get isComplete => outcome == 'complete';
  bool get isInstructions => outcome == 'instructions';

  /// True when this is the last question, so the footer offers "Save & review"
  /// instead of "Save & next". Derived from the server's own index/total.
  bool get isLast => total > 0 && index >= total;

  factory ExamView.fromJson(Map<String, dynamic> j) {
    final Object? q = jget(j, 'question');
    final Object? ids = jget(j, 'answeredQuestionIds');
    return ExamView(
      outcome: jval(j, 'outcome', ''),
      question: q is Map<String, dynamic> ? Question.fromJson(q) : null,
      index: jval(jobj(j, 'question'), 'index', 1),
      total: jval(jobj(j, 'question'), 'total', 0),
      answeredIds: ids is List<dynamic>
          ? ids.map(jid).toSet()
          : const <String>{},
      progressPercent: jval(j, 'progressPercent', 0),
      preview: jval(j, 'preview', false),
      instructions: jobj(j, 'instructions'),
      reason: jval(j, 'reason', ''),
      expectedCandidate: jval(jobj(j, 'expectedCandidate'), 'name', ''),
      canReviewAnswers: jval(j, 'canReviewAnswers', false),
      expired: jval(j, 'expired', false),
      seb: SebLinks.fromJson(jobj(j, 'seb')),
      evidenceUpload: EvidenceUploadPolicy.fromJson(jobj(j, 'evidenceUpload')),
    );
  }

  ExamView copyWith({
    String? outcome,
    Question? question,
    int? index,
    int? total,
    Set<String>? answeredIds,
    int? progressPercent,
    EvidenceUploadPolicy? evidenceUpload,
  }) => ExamView(
    outcome: outcome ?? this.outcome,
    question: question ?? this.question,
    index: index ?? this.index,
    total: total ?? this.total,
    answeredIds: answeredIds ?? this.answeredIds,
    progressPercent: progressPercent ?? this.progressPercent,
    preview: preview,
    instructions: instructions,
    reason: reason,
    expectedCandidate: expectedCandidate,
    canReviewAnswers: canReviewAnswers,
    expired: expired,
    seb: seb,
    evidenceUpload: evidenceUpload ?? this.evidenceUpload,
  );
}

/// `/state`'s `seb` block: into Safe Exam Browser, where to get it, and out.
class SebLinks {
  /// `sebs://.../seb-config`: SEB downloads its settings and opens the exam.
  final String launchUrl;
  final String downloadUrl;

  /// Loading this inside SEB closes it (the Complete screen's exit button).
  final String quitUrl;

  const SebLinks({
    this.launchUrl = '',
    this.downloadUrl = '',
    this.quitUrl = '',
  });

  factory SebLinks.fromJson(Map<String, dynamic> j) => SebLinks(
    launchUrl: jval(j, 'launchUrl', ''),
    downloadUrl: jval(j, 'downloadUrl', ''),
    quitUrl: jval(j, 'quitUrl', ''),
  );
}

/// `evidence_upload`: an S3 presigned POST policy for AI proctoring snapshots.
///
/// The browser POSTs a multipart form straight to [url] - every entry of
/// [fields], then `key` (under [prefix]), then the JPEG - with no auth header.
/// `web/proctor_ai.js` does the POST; this side only carries the policy there.
class EvidenceUploadPolicy {
  final String url;
  final Map<String, String> fields;

  /// Every object key must start with this; it names the attempt.
  final String prefix;
  final String expiresAt;
  final int maxBytes;
  final String contentType;

  const EvidenceUploadPolicy({
    required this.url,
    required this.fields,
    required this.prefix,
    this.expiresAt = '',
    this.maxBytes = 400000,
    this.contentType = 'image/jpeg',
  });

  /// Null when the block is absent or carries no destination.
  static EvidenceUploadPolicy? fromJson(Map<String, dynamic> j) {
    final String url = jval(j, 'url', '');
    final String prefix = jval(j, 'prefix', '');
    if (url.isEmpty || prefix.isEmpty) return null;
    return EvidenceUploadPolicy(
      url: url,
      fields: <String, String>{
        for (final MapEntry<String, dynamic> e in jobj(j, 'fields').entries)
          e.key: '${e.value}',
      },
      prefix: prefix,
      expiresAt: jval(j, 'expiresAt', ''),
      maxBytes: jval(j, 'maxBytes', 400000),
      contentType: jval(j, 'contentType', 'image/jpeg'),
    );
  }

  /// The wire shape, for the JS bridge.
  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'fields': fields,
    'prefix': prefix,
    'expires_at': expiresAt,
    'max_bytes': maxBytes,
    'content_type': contentType,
  };
}

/// One row of the pre-submit checklist, from `/exam/<token>/review`.
///
/// Deliberately carries NO correctness: the server's `_review_payload` has no
/// field for it, which is what stops the answer key reaching a candidate who
/// has not submitted. See `released_answer_review_row` for the post-release
/// shape that does.
class ExamReviewRow {
  final int index;
  final String questionId;
  final String name;
  final bool answered;

  /// The server's count of blank rows on a multi-row question (a grid), which
  /// it still calls [answered]. -1 when not sent (an older server): the review
  /// then counts them itself, for the questions this session has seen.
  final int rowsUnanswered;

  const ExamReviewRow({
    required this.index,
    required this.questionId,
    required this.name,
    required this.answered,
    this.rowsUnanswered = -1,
  });

  factory ExamReviewRow.fromJson(Map<String, dynamic> j) => ExamReviewRow(
    index: jval(j, 'index', 0),
    questionId: jid(jget(j, 'questionId')),
    name: jval(j, 'name', ''),
    answered: jval(j, 'answered', false),
    rowsUnanswered: jval(j, 'rowsUnanswered', -1),
  );
}

/// One camera snapshot AI proctoring saved (a tripped rule, a rule still
/// holding, the start of the exam or a routine one), from
/// `GET /attempts/<id>/evidence`.
///
/// [url] is a PRESIGNED GET that expires after 900 s, so a row is only as good
/// as the read that produced it - the panel re-reads before opening a stale one.
/// [rule] and [at] come from the object's file name (`<epoch_ms>_<rule>.jpg`),
/// so either can be empty/null for a file somebody else put under the prefix.
class ProctoringEvidence {
  final String key;
  final String url;

  /// When the snapshot was taken. Null when the file name did not carry one.
  final DateTime? at;

  /// Why it was taken, as the file name spells it (`no_face`, `phone`,
  /// `start`, `periodic`).
  final String rule;
  final int size;

  const ProctoringEvidence({
    this.key = '',
    this.url = '',
    this.at,
    this.rule = '',
    this.size = 0,
  });

  /// The rule as a reviewer reads it. An unknown one is shown spelled out
  /// rather than hidden, so a rule added server-side still labels its rows.
  String get ruleLabel => switch (rule) {
    'no_face' => 'No face in view',
    'multiple_faces' => 'More than one face',
    'phone' => 'Phone detected',
    'left_frame' => 'Left the frame',
    // Not a check: why `proctor_ai.js` took it.
    'start' => 'Start of exam',
    'periodic' => 'Routine snapshot',
    // Eye movement, removed 19 Oct; its old snapshots may still be listed.
    'gaze_away' => 'Looking away',
    '' => 'Snapshot',
    _ => rule.replaceAll('_', ' '),
  };

  factory ProctoringEvidence.fromJson(Map<String, dynamic> j) {
    // A stamp with no zone is UTC here (the server derives it from epoch_ms),
    // but `tryParse` would call it local and `istDateTime` would then be off
    // by the browser's offset.
    final DateTime? at = DateTime.tryParse(jval(j, 'at', ''));
    return ProctoringEvidence(
      key: jval(j, 'key', ''),
      url: jval(j, 'url', ''),
      at: at == null || at.isUtc
          ? at
          : DateTime.utc(
              at.year,
              at.month,
              at.day,
              at.hour,
              at.minute,
              at.second,
              at.millisecond,
            ),
      rule: jval(j, 'rule', ''),
      size: jval<double>(j, 'size', 0.0).round(),
    );
  }

  /// The whole reply: the rows and the SERVER's count, which the header reads
  /// (the row list is capped, the count is not guessed from it).
  static ({List<ProctoringEvidence> items, int count}) parsePage(
    Map<String, dynamic> j,
  ) {
    final List<ProctoringEvidence> items = <ProctoringEvidence>[
      for (final dynamic e in jlist(jget(j, 'items')))
        if (e is Map<String, dynamic>) ProctoringEvidence.fromJson(e),
    ];
    final Object? count = jget(j, 'count');
    return (
      items: items,
      count: count is num ? count.toDouble().round() : items.length,
    );
  }
}

/// One background pipeline run.
class Job {
  final String id;
  final String genId;
  final String name;
  final JobState state;

  /// 0-100.
  final int progress;

  /// A mono ratio such as `9 / 24`.
  final String meta;
  final String detail;
  final JobKind kind;

  /// The action id a retry control fires.
  final String? retry;

  /// How many drafts the run intends to produce.
  final int want;

  /// Guard so a finished generate job lands its drafts exactly once.
  final bool landed;

  const Job({
    required this.id,
    required this.genId,
    required this.name,
    this.state = JobState.queued,
    this.progress = 0,
    this.meta = '',
    this.detail = '',
    this.kind = JobKind.generate,
    this.retry,
    this.want = 0,
    this.landed = false,
  });

  Job copyWith({
    JobState? state,
    int? progress,
    String? meta,
    String? detail,
    String? retry,
    int? want,
    bool? landed,
  }) => Job(
    id: id,
    genId: genId,
    name: name,
    state: state ?? this.state,
    progress: progress ?? this.progress,
    meta: meta ?? this.meta,
    detail: detail ?? this.detail,
    kind: kind,
    retry: retry ?? this.retry,
    want: want ?? this.want,
    landed: landed ?? this.landed,
  );
}

/// One model call - the source of every budget figure.
class LedgerRow {
  final String id;
  final LedgerOp op;
  final String model;

  /// Attribution: a generator id or an attempt id. Null means unattributed.
  final String? genId;

  /// The generator's name, as the server sent it alongside the id.
  ///
  /// Carried so a spend card can be titled from the ledger alone. The
  /// generator list is paged and archived generators are not in it, so a
  /// screen that could only look the id up in the store had no name to print
  /// for exactly the runs an operator is most likely to be auditing.
  final String genName;
  final String? evId;
  final int tokensIn;
  final int tokensOut;
  final int thoughts;
  final int images;
  final int videoSeconds;
  final double cost;
  final DateTime at;

  /// The server's own attribution label for the call - usually the generator
  /// or candidate it was spent on. Carried so the expanded row can say what a
  /// bare id cannot.
  final String note;

  const LedgerRow({
    required this.id,
    required this.op,
    required this.model,
    this.genId,
    this.genName = '',
    this.evId,
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.thoughts = 0,
    this.images = 0,
    this.videoSeconds = 0,
    this.cost = 0,
    required this.at,
    this.note = '',
  });

  int get totalTokens => tokensIn + tokensOut + thoughts;

  String get attributedTo => genId ?? evId ?? 'Unattributed';

  /// One row of `/api/v1/ledger`.
  ///
  /// This model existed only for seeded demo data, so against a live backend
  /// the LLM budget screen summed an empty list and reported "$0.00 / 0
  /// requests" while $17.44 of real spend sat in the ledger. A spend screen
  /// that under-reports is worse than one that is absent.
  factory LedgerRow.fromJson(Map<String, dynamic> j) => LedgerRow(
    id: jid(jget(j, 'id')),
    op: LedgerOp.parse(jval(j, 'operation', '')),
    model: jval(j, 'model', ''),
    genId: _genPart(j, 'id'),
    genName: _genPart(j, 'name') ?? '',
    evId: jget(j, 'evaluatorId') == null ? null : '${jget(j, 'evaluatorId')}',
    tokensIn: jval(j, 'tokensIn', 0),
    tokensOut: jval(j, 'tokensOut', 0),
    thoughts: jval(j, 'thoughtsTokens', 0),
    images: jval(j, 'imageCount', 0),
    videoSeconds: jval<double>(j, 'videoSeconds', 0.0).round(),
    // A double fallback, not `0`: jval keys off the fallback's runtime
    // type, so an int fallback truncates 0.15208 to 0 and the whole
    // spend screen reads $0.00.
    cost: jval<double>(j, 'costUsd', 0.0),
    at: DateTime.tryParse(jval(j, 'createDate', '')) ?? DateTime.now(),
    note: jval(j, 'note', ''),
  );

  /// One field of the NESTED generator, or null when the call was not
  /// attributed to one.
  ///
  /// `usage_row` sends `"generator": {"id": .., "name": ..}` - an OBJECT. This
  /// used to read `'${jget(j, 'generator')}'`, which stringifies the Dart Map,
  /// so every authoring row keyed on the literal text
  /// `{id: 323, name: Text to Image Gen test}`. That matched no generator in
  /// the store, so LLM budget printed the raw map as a project TITLE, and it
  /// split one generator across two cards: the evaluation rows reach the same
  /// generator the other way round (attempt -> assessment -> generatorId) and
  /// key on its real id, so authoring and evaluation never met.
  ///
  /// A flat spelling is still accepted for the seed fixtures.
  static String? _genPart(Map<String, dynamic> j, String field) {
    final Object? g = jget(j, 'generator');
    if (g == null) return null;
    if (g is Map<String, dynamic>) {
      final String v = jid(jget(g, field));
      return v.isEmpty ? null : v;
    }
    return field == 'id' ? jid(g) : null;
  }
}

/// One entry in the shared tag vocabulary.
class Tag {
  /// The server's record id.
  ///
  /// Carried because merging targets a RECORD, not a spelling: two tags can
  /// display the same text after normalisation, so merging by name would pick
  /// one of them arbitrarily. Empty in seed mode, which has no server.
  final String id;

  final String name;
  final int uses;

  /// Set when this tag is a near-duplicate of a canonical one.
  final String? mergeInto;

  const Tag({required this.name, this.id = '', this.uses = 0, this.mergeInto});

  /// The facet prefix, e.g. `domain` in `domain:logistics`.
  String get facet {
    final int i = name.indexOf(':');
    return i < 0 ? 'other' : name.substring(0, i);
  }

  bool get isCanonical => mergeInto == null;

  Tag copyWith({int? uses, String? mergeInto}) => Tag(
    id: id,
    name: name,
    uses: uses ?? this.uses,
    mergeInto: mergeInto ?? this.mergeInto,
  );

  factory Tag.fromJson(Map<String, dynamic> j) => Tag(
    // jid, not jval: Odoo sends an integer id, and `jval<String>` returns its
    // fallback for a non-String - so this was always '', and every tag merge
    // failed with "the tag has no server id". Every other model here uses jid.
    id: jid(jget(j, 'id')),
    name: jval(j, 'name', ''),
    // The API calls it `usage_count`; the fixtures call it `uses`.
    uses: jval(j, 'uses', jval(j, 'usageCount', 0)),
    mergeInto: jget(j, 'mergeInto') as String?,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (id.isNotEmpty) 'id': id,
    'name': name,
    'uses': uses,
    if (mergeInto != null) 'mergeInto': mergeInto,
  };
}

/// What a delete is about to do, as the SERVER computed it.
///
/// The confirmation an operator reads and the work that follows are the same
/// call with `preview` flipped, so this parses both. Deciding any of it in Dart
/// would mean the sentence somebody agreed to and the thing that happened were
/// worked out by two different pieces of code.
///
/// The distinction it carries is the whole point of the feature:
///
///   * `deleted` - nothing pointed at it, so the row is really gone.
///   * `retired` - an assessment uses it, or somebody has answered it. The row
///     survives, the paper keeps listing it and the answers stay attached; it
///     leaves the bank and can never be picked again. Erasing it instead would
///     delete those answers (`response.question_id` is ondelete="cascade") and
///     silently change scores that were already recorded.
///
/// A GENERATOR delete carries the same distinction one level up: a generator an
/// assessment points at is `archived` rather than `deleted` (the row survives,
/// out of every default list, and every question it authored is retired), and
/// one nothing points at is really erased. Those two facts are counted
/// SEPARATELY from the question counts - see [deletedGenerators] - because they
/// are different objects, and a sentence that mixes them tells the operator a
/// number about the wrong thing.
class DeletePreview {
  /// QUESTIONS that will be erased outright.
  ///
  /// On the generator routes this is `deleted_question_count`: the generator's
  /// own bank questions, never the generators. [deletedGenerators] is the
  /// count of generators.
  final int deletedCount;

  /// QUESTIONS that will be kept, out of the bank, because they carry history.
  final int retiredCount;

  /// Generators that will be erased outright, and generators that will be
  /// kept (moved to Deleted) because an assessment points at them.
  ///
  /// Counted from the per-generator `outcome` the routes send. The bulk
  /// envelope sums the same rows into `deleted_count` and `kept_count`,
  /// but the single-generator route answers with ONE summary and no envelope
  /// at all - tallying the rows is what lets both shapes be read by one piece
  /// of code, which is the same reason the factories below accept both.
  final int deletedGenerators;
  final int keptGenerators;

  /// Assessments that would be affected, named so the sentence can name them.
  final List<String> assessmentNames;

  /// How many candidate answers hang off the selection.
  final int answerCount;

  /// Generators only: what goes with them, counted over the ERASED generators
  /// alone. An archived generator keeps its drafts and its SOP files, so it
  /// contributes nothing here - see [fromGenerators].
  final int draftCount;
  final int fileCount;

  /// What the operator selected, which is not always what the server acts on.
  final int requested;

  const DeletePreview({
    this.deletedCount = 0,
    this.retiredCount = 0,
    this.deletedGenerators = 0,
    this.keptGenerators = 0,
    this.assessmentNames = const <String>[],
    this.answerCount = 0,
    this.draftCount = 0,
    this.fileCount = 0,
    this.requested = 0,
  });

  static List<String> _names(Object? raw) => <String>[
    for (final Object? a in (raw as List<dynamic>? ?? const <dynamic>[]))
      if (a is Map<String, dynamic>) '${a['name'] ?? ''}',
  ]..removeWhere((String s) => s.isEmpty);

  factory DeletePreview.fromQuestions(Map<String, dynamic> j, int requested) {
    // The single-question routes answer with ONE row rather than the bulk
    // envelope, so both shapes are read here - the sheet must not care which
    // call produced it.
    final Object? rows = jget(j, 'questions');
    if (rows is! List<dynamic>) {
      final bool retired = '${jget(j, 'outcome')}' == 'retired';
      return DeletePreview(
        deletedCount: retired ? 0 : 1,
        retiredCount: retired ? 1 : 0,
        assessmentNames: _names(jget(j, 'assessments')),
        answerCount: (jget(j, 'answerCount') as num?)?.toInt() ?? 0,
        requested: requested,
      );
    }
    int answers = 0;
    for (final Object? r in rows) {
      if (r is Map<String, dynamic>) {
        answers += (jget(r, 'answerCount') as num?)?.toInt() ?? 0;
      }
    }
    return DeletePreview(
      deletedCount: (jget(j, 'deletedCount') as num?)?.toInt() ?? 0,
      retiredCount: (jget(j, 'retiredCount') as num?)?.toInt() ?? 0,
      assessmentNames: _names(jget(j, 'assessments')),
      answerCount: answers,
      requested: requested,
    );
  }

  factory DeletePreview.fromGenerators(Map<String, dynamic> j, int requested) {
    // Bulk envelope and single-generator payload again, read as one.
    final Object? gens = jget(j, 'generators');
    final List<dynamic> list = gens is List<dynamic> ? gens : <dynamic>[j];
    int drafts = 0;
    int files = 0;
    int erased = 0;
    int archived = 0;
    final List<String> names = <String>[];
    for (final Object? g in list) {
      if (g is! Map<String, dynamic>) continue;
      names.addAll(_names(jget(g, 'assessments')));
      // Anything that is not the word "kept" counts as erased, including a
      // payload that carries no `outcome` at all: the routes only ever keep
      // the row when they say so, and defaulting the other way would announce
      // a survival nobody arranged. "archived" is the same answer from a
      // backend before 19.0.3.27.0.
      final String outcome = '${jget(g, 'outcome') ?? ''}';
      if (outcome == 'kept' || outcome == 'archived') {
        archived++;
        // NOTHING GOES WITH A KEPT GENERATOR. It is marked deleted but its row
        // survives whole - drafts and SOP files included - so its counts must
        // not be summed into the totals the sheet renders as "deleted with
        // it".
        continue;
      }
      erased++;
      drafts += (jget(g, 'draftCount') as num?)?.toInt() ?? 0;
      files += (jget(g, 'resourceCount') as num?)?.toInt() ?? 0;
    }
    return DeletePreview(
      deletedCount: (jget(j, 'deletedQuestionCount') as num?)?.toInt() ?? 0,
      retiredCount: (jget(j, 'retiredQuestionCount') as num?)?.toInt() ?? 0,
      deletedGenerators: erased,
      keptGenerators: archived,
      assessmentNames: names.toSet().toList(),
      draftCount: drafts,
      fileCount: files,
      requested: requested,
    );
  }

  /// True when something here has to be kept rather than erased.
  ///
  /// BOTH OBJECTS COUNT. An archived generator is history being kept exactly
  /// as a retired question is, and reading the question counts alone told an
  /// archive-only delete - one whose questions an earlier delete had already
  /// retired, so `retiredCount` is 0 - that it "cannot be undone", over a
  /// generator that is still there and can be unarchived.
  bool get keepsHistory => retiredCount > 0 || keptGenerators > 0;

  int get questionCount => deletedCount + retiredCount;

  int get generatorCount => deletedGenerators + keptGenerators;

  static String _n(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  /// The past-tense sentence for the toast, in the server's own numbers.
  ///
  /// QUESTIONS ONLY. The generator routes report the same two counts about
  /// their generators' questions, so reusing this there produced a sentence
  /// about the wrong objects - see [generatorOutcomeSentence].
  String get outcomeSentence {
    if (retiredCount == 0) return 'Deleted';
    if (deletedCount == 0) {
      return '$retiredCount moved to Deleted - their results are kept';
    }
    return '$deletedCount erased, $retiredCount moved to Deleted with their '
        'results kept';
  }

  /// The past-tense sentence for a GENERATOR delete: what happened to the
  /// generators, and then what happened to the questions they authored.
  ///
  /// TWO OBJECTS, NAMED SEPARATELY. This used to be [outcomeSentence], whose
  /// counts on this route are the generators' QUESTIONS - so deleting five
  /// generators announced whatever number of questions they happened to hold,
  /// and deleting generators that had approved nothing said the bare word
  /// "Deleted" no matter how many went. Both halves are stated here, and
  /// either half is dropped only when its count is genuinely zero.
  ///
  /// "Archived" is the half an operator cannot guess: they pressed Delete and
  /// the generator is still there, because an assessment points at it and the
  /// reference cannot be broken without taking that paper's history with it.
  String get generatorOutcomeSentence {
    final List<String> parts = <String>[];
    // "erased", not "deleted", and the same word the confirmation sheet puts
    // on its generator line: the operator pressed Delete on all of them, so
    // repeating that verb here names no outcome. Erased against archived is
    // the distinction they actually need afterwards.
    if (deletedGenerators > 0 && keptGenerators > 0) {
      parts.add(
        '${_n(deletedGenerators, 'generator')} erased, '
        '$keptGenerators moved to Deleted with their results kept',
      );
    } else if (keptGenerators > 0) {
      parts.add(
        '${_n(keptGenerators, 'generator')} moved to Deleted - '
        '${keptGenerators == 1 ? 'its' : 'their'} results are kept',
      );
    } else {
      // Zero generators is the empty-selection case the store already refuses,
      // so this reads as the plain erase it is rather than as a special case.
      parts.add('${_n(deletedGenerators, 'generator')} erased');
    }

    if (deletedCount > 0 && retiredCount > 0) {
      parts.add(
        '${_n(questionCount, 'question')}: $deletedCount erased, '
        '$retiredCount moved to Deleted',
      );
    } else if (retiredCount > 0) {
      parts.add('${_n(retiredCount, 'question')} moved to Deleted');
    } else if (deletedCount > 0) {
      parts.add('${_n(deletedCount, 'question')} erased');
    }

    return parts.join('. ');
  }
}

/// The server's own cohort aggregation, from `GET /api/v1/analytics`.
///
/// WHY THIS EXISTS. The dashboard used to derive every cohort figure from the
/// tables the store happened to hold, deciding each attempt's verdict with
/// `Attempt.result`. That divides by the assessment's frozen question count,
/// and an assessment loaded from the LIST endpoint carries no questions - so
/// its attempts were all "pending" and counted towards nothing. Opening one
/// assessment's detail page hydrated its questions and retroactively moved
/// every total on the dashboard. The same screen showed "nothing decided yet",
/// then 0/1 decided, then 3 of 6, decided entirely by where the operator had
/// browsed.
///
/// The server has no such gap: it reads the stored `result` on each evaluator.
/// These figures are therefore complete and do not move under navigation.
class CohortAnalytics {
  /// SITTINGS, not people. One row per attempt, so a candidate who sat two
  /// papers counts twice. This is the right denominator for `completionRate`
  /// and the score bands, and the WRONG one for a "Candidates" tile.
  final int assigned;

  /// DISTINCT HUMANS across the scoped assessments.
  ///
  /// The dashboard's "Candidates" tile summed each assessment's own
  /// `assignedCount` while taking passed/failed/decided from the server's
  /// per-sitting recordset - two denominators on one screen, which is how
  /// "Passed 1466" came to exceed "CANDIDATES 1330". Measured on etp_local:
  /// 198 sittings, 159 people, one person counted 14 times.
  ///
  /// Defaults to 0; `dashboard_screen` falls back to the local walk when the
  /// payload predates this field, exactly as `decided` and its neighbours do.
  final int people;
  final int submitted;
  final int decided;
  final int passed;
  final int failed;
  final int awaitingResult;
  final double avgScore;
  final double passRate;
  final double completionRate;

  /// Sittings opened but not submitted, and sittings never opened. NULL when
  /// the server predates them; the dashboard then splits its own cached rows.
  final int? inProgress;
  final int? notStarted;

  /// Attempts a person should look at. None of these changes a score.
  final int integrityAlert;
  final int scoreOutlier;
  final int violated;
  final int scoringError;

  /// DISTINCT attempts with any of the three flags above, not their sum. NULL
  /// from an older server, which leaves the dashboard to count its own rows.
  final int? needsReview;

  final List<AssessmentAnalytics> byAssessment;

  /// Where the cohort is strong and weak, by category, strongest first.
  ///
  /// COMPUTED SERVER-SIDE. The admin dashboard has no per-answer data: the
  /// attempt list route carries no answers and `resp` is only filled by the
  /// per-attempt detail call, so building this in the browser would mean one
  /// request per sitting.
  final List<CohortCategory> cohortCategories;

  const CohortAnalytics({
    this.assigned = 0,
    this.people = 0,
    this.submitted = 0,
    this.decided = 0,
    this.passed = 0,
    this.failed = 0,
    this.awaitingResult = 0,
    this.avgScore = 0,
    this.passRate = 0,
    this.completionRate = 0,
    this.inProgress,
    this.notStarted,
    this.integrityAlert = 0,
    this.scoreOutlier = 0,
    this.violated = 0,
    this.scoringError = 0,
    this.needsReview,
    this.byAssessment = const <AssessmentAnalytics>[],
    this.cohortCategories = const <CohortCategory>[],
  });

  factory CohortAnalytics.fromJson(Map<String, dynamic> j) {
    final Map<String, dynamic> t = jmap(jget(j, 'totals'));
    final Map<String, dynamic> f = jmap(jget(j, 'flags'));
    final Object? rows = jget(j, 'byAssessment');
    return CohortAnalytics(
      assigned: jval(t, 'assigned', 0),
      people: jval(t, 'people', 0),
      submitted: jval(t, 'submitted', 0),
      decided: jval(t, 'decided', 0),
      passed: jval(t, 'passed', 0),
      failed: jval(t, 'failed', 0),
      awaitingResult: jval(t, 'awaitingResult', 0),
      // Doubles, not ints. The server sends 41.7, and compiled to JavaScript
      // there is one numeric type, so an int fallback sends it down jval's
      // double branch and then casts: "41.7 is not a subtype of int" throws
      // during build and paints the dashboard grey.
      avgScore: jval(t, 'avgScore', 0.0),
      passRate: jval(t, 'passRate', 0.0),
      completionRate: jval(t, 'completionRate', 0.0),
      // Nullable: a missing key must read as "not sent", never as a real 0.
      inProgress: (jget(t, 'inProgress') as num?)?.toInt(),
      notStarted: (jget(t, 'notStarted') as num?)?.toInt(),
      integrityAlert: jval(f, 'integrityAlert', 0),
      scoreOutlier: jval(f, 'scoreOutlier', 0),
      violated: jval(f, 'violated', 0),
      scoringError: jval(f, 'scoringError', 0),
      needsReview: (jget(f, 'needsReview') as num?)?.toInt(),
      byAssessment: <AssessmentAnalytics>[
        if (rows is List)
          for (final Object? r in rows)
            if (r is Map<String, dynamic>) AssessmentAnalytics.fromJson(r),
      ],
      cohortCategories: <CohortCategory>[
        if (jget(j, 'cohortCategories') case final List cats)
          for (final Object? c in cats)
            if (c is Map<String, dynamic>) CohortCategory.fromJson(c),
      ],
    );
  }
}

/// One assessment's row of [CohortAnalytics].
class AssessmentAnalytics {
  final String id;
  final String name;
  final int candidates;
  final int submitted;
  final int decided;
  final int passed;
  final double avgScore;
  final int awaitingScoring;
  final int releasable;

  const AssessmentAnalytics({
    required this.id,
    this.name = '',
    this.candidates = 0,
    this.submitted = 0,
    this.decided = 0,
    this.passed = 0,
    this.avgScore = 0,
    this.awaitingScoring = 0,
    this.releasable = 0,
  });

  factory AssessmentAnalytics.fromJson(Map<String, dynamic> j) =>
      AssessmentAnalytics(
        id: jid(jget(j, 'id')),
        name: jval<String>(j, 'name', ''),
        candidates: jval(j, 'candidates', 0),
        submitted: jval(j, 'submitted', 0),
        decided: jval(j, 'decided', 0),
        passed: jval(j, 'passed', 0),
        avgScore: jval(j, 'avgScore', 0.0),
        awaitingScoring: jval(j, 'awaitingScoring', 0),
        releasable: jval(j, 'releasable', 0),
      );
}

/// One cohort-level category average, as the analytics route computed it.
///
/// [earned] and [possible] are carried alongside [percent] so the figure is
/// checkable by hand: "13 of 16" is auditable, "81.2%" on its own is not.
class CohortCategory {
  const CohortCategory({
    required this.tag,
    required this.label,
    required this.earned,
    required this.possible,
    required this.answers,
    required this.percent,
  });

  final String tag;
  final String label;
  final double earned;
  final double possible;

  /// How many answers stand behind the average. Shown because an average over
  /// two answers and one over forty are not the same claim.
  final int answers;
  final double percent;

  factory CohortCategory.fromJson(Map<String, dynamic> j) => CohortCategory(
    tag: jval(j, 'tag', ''),
    label: jval(j, 'label', ''),
    earned: jval(j, 'earned', 0.0),
    possible: jval(j, 'possible', 0.0),
    answers: jval(j, 'answers', 0),
    percent: jval(j, 'percent', 0.0),
  );
}

/// Live state of the subjective grading pipeline, from `GET /api/v1/scoring`.
///
/// WHY THIS EXISTS (SNo 112). The route has always reported lane counts and a
/// `drainer` block saying whether the grading crons are actually running, and
/// NOTHING in the client read it. So the two conditions an admin must act on -
/// a stalled drainer, and attempts in the error lane that will never retry
/// themselves - had no surface anywhere in the app. The only symptom was
/// candidates staying ungraded, which looks like slowness rather than a stop.
///
/// Deliberately small: only the fields a warning needs. The lane histogram and
/// the errored rows stay on the wire for a fuller screen later.
class ScoringPipeline {
  /// Attempts the grader still has work for.
  final int queued;

  /// In the error lane. These NEVER retry on their own - INVARIANT 5 - so this
  /// is the number that requires a person, not just patience.
  final int needsManualRequeue;

  /// The grading crons are not draining. `reason` says why when the server
  /// knows.
  final bool stalled;
  final int cronsTotal;
  final int cronsInactive;
  final int cronsOverdue;
  final String reason;

  /// The phase of THIS assessment's run, or null when the read was cohort-wide.
  ///
  /// The route answers a phase only for a request that carried an
  /// `assessment_id`: across every assessment at once "is grading running" is
  /// not a question with an actionable answer, so the server sends null rather
  /// than an aggregate somebody would act on.
  final ScoringPhase? phase;

  /// The server's one-line breakdown beside [phase]. Empty cohort-wide, and
  /// empty when there is nothing to report.
  final String summary;

  const ScoringPipeline({
    this.queued = 0,
    this.needsManualRequeue = 0,
    this.stalled = false,
    this.cronsTotal = 0,
    this.cronsInactive = 0,
    this.cronsOverdue = 0,
    this.reason = '',
    this.phase,
    this.summary = '',
  });

  /// True when an admin has something to do. The banner shows only for this.
  bool get needsAttention => stalled || needsManualRequeue > 0;

  factory ScoringPipeline.fromJson(Map<String, dynamic> j) {
    final Map<String, dynamic> d = jmap(jget(j, 'drainer'));
    return ScoringPipeline(
      queued: jval(j, 'queued', 0),
      needsManualRequeue: jval(j, 'needsManualRequeue', 0),
      stalled: jval(d, 'stalled', false),
      cronsTotal: jval(d, 'cronsTotal', 0),
      cronsInactive: jval(d, 'cronsInactive', 0),
      cronsOverdue: jval(d, 'cronsOverdue', 0),
      reason: jval(d, 'reason', ''),
      // TOP LEVEL, not inside `drainer`: the drainer block describes the crons,
      // these two describe the work in front of them.
      phase: ScoringPhase.parse(jstr(jget(j, 'phase'))),
      summary: jval(j, 'summary', ''),
    );
  }
}

/// One lane of a generation run: drafts by review state, images or videos by
/// render state. Each lane fills the counts it has and leaves the rest at 0.
class GenLane {
  final int total;
  final int pending;
  final int approved;
  final int denied;
  final int rendered;
  final int uploaded;
  final int ready;
  final int failed;

  const GenLane({
    this.total = 0,
    this.pending = 0,
    this.approved = 0,
    this.denied = 0,
    this.rendered = 0,
    this.uploaded = 0,
    this.ready = 0,
    this.failed = 0,
  });

  /// Images that exist, however they got there.
  int get done => rendered + uploaded;

  factory GenLane.fromJson(Object? v) {
    final Map<String, dynamic> j = jmap(v);
    return GenLane(
      total: jval(j, 'total', 0),
      pending: jval(j, 'pending', 0),
      approved: jval(j, 'approved', 0),
      denied: jval(j, 'denied', 0),
      rendered: jval(j, 'rendered', 0),
      uploaded: jval(j, 'uploaded', 0),
      ready: jval(j, 'ready', 0),
      failed: jval(j, 'failed', 0),
    );
  }
}

/// One generator's run, from `GET /api/v1/generators/<id>/progress`.
///
/// The generation twin of [ScoringPipeline] (ETP_PLANS_AND_STRATEGY.md §4.9):
/// the server names the phase and writes the one-line [summary], so the banner
/// and the screen's watch read one answer instead of folding counts out of
/// whatever drafts the store happens to hold. Every key is optional - a
/// missing one parses to its default, never a crash.
class GenerationProgress {
  /// idle, queued, authoring, finalizing, media, ready, failed or cancelled.
  final String phase;

  /// Work is still moving: queued, authoring, finalizing or media. The watch
  /// stops when this goes false.
  final bool active;
  final String summary;
  final bool stalled;
  final String stalledReason;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int elapsedS;
  final int llmCalls;
  final String lastStep;

  /// Null unless the server sent [showCost] - operators only, as `/ledger`.
  final double? costUsd;
  final bool showCost;
  final GenLane drafts;
  final GenLane images;
  final GenLane videos;
  final int? estMinutesLeft;
  final bool canRetryImages;

  const GenerationProgress({
    this.phase = 'idle',
    this.active = false,
    this.summary = '',
    this.stalled = false,
    this.stalledReason = '',
    this.startedAt,
    this.finishedAt,
    this.elapsedS = 0,
    this.llmCalls = 0,
    this.lastStep = '',
    this.costUsd,
    this.showCost = false,
    this.drafts = const GenLane(),
    this.images = const GenLane(),
    this.videos = const GenLane(),
    this.estMinutesLeft,
    this.canRetryImages = false,
  });

  /// There is a run to describe: one has started, or its drafts exist (a run
  /// from before the start stamp existed has drafts and no stamp).
  bool get hasRun => startedAt != null || drafts.total > 0;

  factory GenerationProgress.fromJson(Map<String, dynamic> j) {
    final Map<String, dynamic> run = jmap(jget(j, 'run'));
    final bool showCost = jval(j, 'showCost', false);
    final Object? cost = jget(run, 'costUsd');
    final Object? left = jget(jmap(jget(j, 'media')), 'estMinutesLeft');
    return GenerationProgress(
      phase: jval(j, 'phase', 'idle'),
      active: jval(j, 'active', false),
      summary: jval(j, 'summary', ''),
      stalled: jval(j, 'stalled', false),
      stalledReason: jval(j, 'stalledReason', ''),
      startedAt: DateTime.tryParse(jval(run, 'startedAt', '')),
      finishedAt: DateTime.tryParse(jval(run, 'finishedAt', '')),
      elapsedS: jval(run, 'elapsedS', 0),
      llmCalls: jval(run, 'llmCalls', 0),
      lastStep: jval(run, 'lastStep', ''),
      // Dropped unless the server said to show it, so a cost that leaks onto
      // a non-operator's payload still never reaches their screen.
      costUsd: showCost && cost is num ? cost.toDouble() : null,
      showCost: showCost,
      drafts: GenLane.fromJson(jget(j, 'drafts')),
      images: GenLane.fromJson(jget(j, 'images')),
      videos: GenLane.fromJson(jget(j, 'videos')),
      estMinutesLeft: left is num ? left.toInt() : null,
      canRetryImages: jval(j, 'canRetryImages', false),
    );
  }
}
