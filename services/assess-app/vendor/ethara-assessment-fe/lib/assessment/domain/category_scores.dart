/// Category-level performance: which skills a cohort (or one person) is strong
/// and weak at.
///
/// SHARED BY BOTH AUDIENCES ON PURPOSE. The admin reads it per assessment for a
/// cohort, the candidate reads it for their own sitting, and the spec asks for
/// "the same four categories" on both. One implementation means the two can
/// never disagree about what a category is or how its average was reached -
/// which is the failure mode that makes a candidate distrust their own report.
///
/// WHAT A "CATEGORY" IS. The vocabulary is faceted: `skill:ai-artifact-detection`,
/// `domain:ai-image-evaluation`, `modality:image`, `output-format:ab-choice`. Only
/// SKILL is a category worth coaching against - the others describe the shape of
/// the paper, not an ability, so "you are weak at modality:image" is not
/// actionable advice. `skill` is therefore preferred and the rest are a
/// fallback for banks that have not been tagged with skills yet.
library;

import 'enums.dart';
import 'models.dart';

/// How long a sitting took, or null when it cannot be known.
///
/// Both ends are required. An unsubmitted paper has no duration - the candidate
/// may still be writing it, or may have walked away - and treating "now minus
/// started" as a duration would report a growing time for an abandoned attempt
/// and pull the cohort median with it.
///
/// A NEGATIVE OR ZERO span is discarded rather than clamped. It means the clocks
/// disagreed (server time vs a backfilled timestamp), and a 0-minute sitting in
/// the median is a silent lie about the cohort; absent is honest.
///
/// THE SPAN ENDS AT THE EARLIER OF `submittedAt` AND `deadline`. The server
/// stamps `submitted_at` when a sitting is SETTLED, not when it ended: an
/// expired paper swept later by the cron, or on the candidate's next visit, is
/// stamped after its deadline (hours after, in the worst local case). Counting
/// to the stamp reported "3h" and a Slow tag for a paper the clock ended on
/// time. The server's median applies the same rule, so the tag and the number
/// it is judged by agree. No deadline: the stamp stands. Kept in this one place
/// so the dashboard, the attempt page and [timeUsed] cannot disagree.
Duration? attemptDuration(Attempt e) {
  final DateTime? a = e.startedAt;
  final DateTime? s = e.submittedAt;
  if (a == null || s == null) return null;
  final DateTime? dl = e.deadline;
  final DateTime b = dl != null && dl.isBefore(s) ? dl : s;
  final Duration d = b.difference(a);
  return d.inSeconds > 0 ? d : null;
}

/// "38 of 45 min": the time a sitting took against its limit, or null when
/// the span is unknown.
///
/// Capped at the limit: an expired sitting settled later by the cron, or on
/// the candidate's next visit, is stamped after the deadline it ended on.
String? timeUsed(Attempt e, Assessment? asm) {
  final Duration? d = attemptDuration(e);
  if (d == null) return null;
  final int limit = e.durationMinutes > 0
      ? e.durationMinutes
      : (asm?.durationMinutes ?? 0);
  final int mins = limit > 0 && d.inMinutes > limit ? limit : d.inMinutes;
  final String used = mins < 1 ? '<1' : '$mins';
  return limit > 0 ? '$used of $limit min' : '$used min';
}

/// A duration a person reads, from a value a machine measured.
String humanDuration(Duration d) {
  final int mins = d.inMinutes;
  if (mins < 1) return '<1 min';
  if (mins < 60) return '$mins min';
  final int h = mins ~/ 60;
  final int m = mins % 60;
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

/// Descriptive speed relative to the cohort. NEVER a score.
///
/// The doc is explicit that Pace is admin-side and descriptive only, so this
/// deliberately has no ordering against pass/fail and no colour that reads as
/// good or bad: a fast wrong paper and a fast right paper both say Fast.
enum Pace {
  fast('Fast'),
  average('Normal'),
  slow('Slow');

  const Pace(this.label);
  final String label;
}

/// The median of a set of durations, or null when there is nothing to take one
/// of.
///
/// MEDIAN, NOT MEAN, and the doc asks for a median for a good reason: one
/// candidate who left the tab open over lunch drags a mean far enough to label
/// most of the cohort "Fast".
Duration? medianDuration(Iterable<Duration> xs) {
  final List<int> secs = xs.map((Duration d) => d.inSeconds).toList()..sort();
  if (secs.isEmpty) return null;
  final int mid = secs.length ~/ 2;
  // Even counts average the two middles, so a two-person cohort does not
  // arbitrarily inherit the slower one's time as "typical".
  final int v = secs.length.isOdd
      ? secs[mid]
      : ((secs[mid - 1] + secs[mid]) / 2).round();
  return Duration(seconds: v);
}

/// Where one sitting sits against the cohort's median time.
///
/// The ±25% band is what keeps this readable. Without a band, half the cohort
/// is Fast and half is Slow by construction - every sitting either side of the
/// median gets a label, which tells the reader nothing they could act on. With
/// it, "Normal" means genuinely typical and the two tails are the ones worth a
/// look.
///
/// DECIDED FROM THE NUMBER THE OPERATOR READS, not from the raw quotient. The
/// tooltip prints the ratio to two decimals, so an unrounded branch let a
/// sitting at 1.2499 be tagged Normal and print "1.25x" directly above a legend
/// saying 1.25x is Slow. Rounding first costs nothing and is what makes the tag
/// and the legend agree for every value that can reach the screen.
Pace? paceOf(Duration? one, Duration? median) {
  final double? ratio = paceRatio(one, median);
  if (ratio == null) return null;
  final double shown = _shownRatio(ratio);
  if (shown <= kPaceFastAtOrBelow) return Pace.fast;
  if (shown >= kPaceSlowAtOrAbove) return Pace.slow;
  return Pace.average;
}

/// The ratio at the resolution it is printed at, so the branch above and the
/// string below can never be looking at different numbers. Parsed back from the
/// formatted text rather than scaled by hand: that is the only way to be sure
/// it matches what [paceExplanation] renders.
double _shownRatio(double ratio) => double.parse(ratio.toStringAsFixed(2));

/// The two edges of the band, NAMED so the sentence that explains Pace to an
/// operator is rendered from the same numbers that decide it. Two copies of
/// "1.25" - one in the branch and one in the help text - is how a tag comes to
/// contradict its own tooltip.
const double kPaceFastAtOrBelow = 0.75;
const double kPaceSlowAtOrAbove = 1.25;

/// How many times the test's median this sitting took. Null when there is
/// nothing to compare against.
double? paceRatio(Duration? one, Duration? median) {
  if (one == null || median == null || median.inSeconds <= 0) return null;
  return one.inSeconds / median.inSeconds;
}

/// Why a sitting earned its Pace tag, in the operator's own units.
///
/// THE ARITHMETIC, NOT THE ADJECTIVE, and with EXACT durations rather than the
/// ones in the columns. The grid rounds to whole minutes and floors at
/// "<1 min", so a row reading `1h 8m / <1 min / Slow` gives the reader no way
/// to check the tag, and `<1 min / <1 min / Average` tells them nothing at all.
/// This is the only place the real numbers appear.
String paceExplanation(Duration? one, Duration? median) {
  final double? ratio = paceRatio(one, median);
  if (ratio == null) {
    return 'No pace: this test has no median to compare against yet.';
  }
  return '${preciseDuration(one!)} against test\'s median '
      '${preciseDuration(median!)}: ${_shownRatio(ratio).toStringAsFixed(2)}x\n'
      '$paceLegend';
}

/// The step between two ratios an operator can tell apart. The tooltip prints
/// two decimals, so this is the narrowest gap that can ever show on screen -
/// and the middle band is stated one step inside each edge for that reason.
const double kPaceRatioStep = 0.01;

/// The three bands, spelled out. RENDERED FROM THE CONSTANTS, so the legend a
/// reader checks the tag against cannot drift from the branch that set it.
///
/// THE MIDDLE CLAUSE STOPS ONE STEP SHORT OF BOTH EDGES. Written as
/// "Normal 0.75x-1.25x" it claimed the two numbers `paceOf` gives away to Fast
/// and Slow, so the legend contradicted itself on its own text - and a row
/// printing 1.25x beside a Slow pill looked like a bug in the tag rather than
/// the legend being wrong.
String get paceLegend =>
    'Fast \u2264 ${kPaceFastAtOrBelow}x  \u2022  '
    'Normal ${(kPaceFastAtOrBelow + kPaceRatioStep).toStringAsFixed(2)}x'
    '\u2013${(kPaceSlowAtOrAbove - kPaceRatioStep).toStringAsFixed(2)}x  \u2022  '
    'Slow \u2265 ${kPaceSlowAtOrAbove}x';

/// A duration with its seconds kept, for the one place the rounding matters.
///
/// THE HOUR BRANCH KEEPS THEM TOO. It used to drop them, which made this
/// identical to [humanDuration] for every sitting of an hour or more - so on
/// exactly the long rows this panel sorts to the top, the tooltip repeated the
/// two figures already in the columns and printed a ratio that could not be
/// derived from either.
String preciseDuration(Duration d) {
  final int s = d.inSeconds;
  if (s < 60) return '${s}s';
  final int m = s ~/ 60;
  final int rem = s % 60;
  if (m < 60) return rem == 0 ? '${m}m' : '${m}m ${rem}s';
  final int h = m ~/ 60;
  final int mm = m % 60;
  final String hm = mm == 0 ? '${h}h' : '${h}h ${mm}m';
  return rem == 0 ? hm : '$hm ${rem}s';
}

/// The facet a tag belongs to, or `'other'` when it carries no prefix.
///
/// Mirrors `Tag.facet` rather than reusing it because these arrive as bare
/// strings on an answer, not as `Tag` records.
String facetOf(String tag) {
  final int i = tag.indexOf(':');
  return i < 0 ? 'other' : tag.substring(0, i);
}

/// Words that keep their own casing, whole.
///
/// Title-casing letter by letter turns `ai` into `Ai` and `ab` into `Ab`, which
/// is how the panel came to read "Ai artifact detection" - the one word on the
/// row a reader actually recognises, spelled wrong. These are checked before
/// any capitalisation happens.
const Map<String, String> _kAcronyms = <String, String>{
  'ai': 'AI',
  'ui': 'UI',
  'ux': 'UX',
  'qc': 'QC',
  'qa': 'QA',
  'sop': 'SOP',
  'llm': 'LLM',
  'ocr': 'OCR',
  'api': 'API',
  'url': 'URL',
  'pdf': 'PDF',
  'csv': 'CSV',
  'json': 'JSON',
  'html': 'HTML',
  'css': 'CSS',
  'id': 'ID',
  'ab': 'A/B',
  'mcq': 'MCQ',
  'msq': 'MSQ',
  'hr': 'HR',
  'kpi': 'KPI',
};

/// Words that stay lower-case unless they lead. Title Case that capitalises
/// "Of" and "The" reads like a headline generator, not a label.
const Set<String> _kMinorWords = <String>{
  'a',
  'an',
  'and',
  'as',
  'at',
  'but',
  'by',
  'for',
  'in',
  'of',
  'on',
  'or',
  'per',
  'the',
  'to',
  'v',
  'via',
  'vs',
  'with',
};

/// A tag without its facet, in words a person reads.
///
/// `skill:ai-artifact-detection` -> `AI Artifact Detection`.
///
/// THIS IS THE FALLBACK, not the first choice. The server sends the tag's own
/// `display` - a readable name minted once per key and pinned forever - and a
/// caller holding one should print that. This is for the surfaces that only
/// have the machine key: it is a guess, and a guess is why the acronym table
/// above exists.
///
/// It used to capitalise the first letter and stop, which gave
/// `Ai artifact detection` - sentence case over a hyphenated key, with the
/// acronym mangled.
String readableTag(String tag) {
  final int i = tag.indexOf(':');
  final String body = i < 0 ? tag : tag.substring(i + 1);
  final String spaced = body.replaceAll('-', ' ').replaceAll('_', ' ').trim();
  if (spaced.isEmpty) return tag;
  return titleCase(spaced);
}

/// Title Case for a phrase already split into words.
///
/// Shared with the label pass over the console's own headings, so a tag and a
/// panel title cannot end up capitalised by two different rules.
String titleCase(String phrase) {
  final List<String> words = phrase
      .split(RegExp(r'\s+'))
      .where((String w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return phrase;
  return <String>[
    for (int i = 0; i < words.length; i++) _titleWord(words[i], first: i == 0),
  ].join(' ');
}

String _titleWord(String word, {required bool first}) {
  final String lower = word.toLowerCase();
  final String? acronym = _kAcronyms[lower];
  if (acronym != null) return acronym;
  // A minor word keeps its place, but never at the front of a label.
  if (!first && _kMinorWords.contains(lower)) return lower;
  // A word already carrying inner capitals is somebody's deliberate spelling
  // ("iPhone", "McQueen"); only the first letter is touched.
  if (word.substring(1) != word.substring(1).toLowerCase()) {
    return word[0].toUpperCase() + word.substring(1);
  }
  return lower[0].toUpperCase() + lower.substring(1);
}

/// One category's performance.
class CategoryScore {
  /// The canonical tag, kept so a caller can group or link by it.
  final String tag;

  /// Marks earned and available across every answer in this category.
  final double earned;
  final double possible;

  /// How many answers contributed. Shown because an average over two answers
  /// and an average over forty are not the same claim, and a category with one
  /// answer behind it should not be presented as a finding.
  final int answers;

  /// The tag's own readable name, when the caller has one.
  ///
  /// The server sends it (`cohort_categories[].label`) and it beats anything
  /// derived here: it is pinned once per key by the extraction model, so every
  /// screen shows the same words for the same category. Null on the surfaces
  /// that only hold the machine key, where [label] falls back to
  /// [readableTag].
  final String? serverLabel;

  const CategoryScore({
    required this.tag,
    required this.earned,
    required this.possible,
    required this.answers,
    this.serverLabel,
  });

  /// 0-100. Zero when nothing was available, rather than NaN.
  double get percent => possible <= 0 ? 0 : 100.0 * earned / possible;

  String get label {
    final String pinned = (serverLabel ?? '').trim();
    return pinned.isEmpty ? readableTag(tag) : pinned;
  }
}

/// The categories present in [answers], strongest first.
///
/// [answers] pairs each answer with the marks available for its question,
/// because the denominator lives on the question and not on the answer.
///
/// AVERAGED OVER MARKS, NOT OVER PERCENTAGES. Averaging per-answer percentages
/// would weight a 1-mark question the same as a 10-mark one, so a cohort could
/// read "60% on Artifact detection" when it earned 6 of 60 marks. Summing both
/// sides and dividing once is the only figure that matches the marks a person
/// can check by hand.
///
/// UNTAGGED ANSWERS ARE SKIPPED, NOT BUCKETED. An "Other" bucket would present
/// the absence of a vocabulary as a category people are weak at.
List<CategoryScore> categoryScores(
  Iterable<({List<String> tags, double earned, double possible})> answers, {

  /// Categories with fewer than this many answers are dropped. One answer is an
  /// anecdote; the panel says "not enough data" rather than ranking it.
  int minAnswers = 1,
}) {
  // ONE FACET AT A TIME. Mixing `skill:` and `modality:` into one ranking
  // compares an ability against the format of the paper, and every answer would
  // appear in several rows - so the "weakest category" could be a fact about
  // the question type rather than about the candidate.
  final Set<String> facets = <String>{
    for (final ({List<String> tags, double earned, double possible}) a
        in answers)
      for (final String t in a.tags) facetOf(t),
  };
  final String chosen = facets.contains('skill')
      ? 'skill'
      : facets.contains('task')
      ? 'task'
      : facets.contains('domain')
      ? 'domain'
      : facets.isEmpty
      ? ''
      : (facets.toList()..sort()).first;
  if (chosen.isEmpty) return const <CategoryScore>[];

  final Map<String, ({double earned, double possible, int n})> acc =
      <String, ({double earned, double possible, int n})>{};
  for (final ({List<String> tags, double earned, double possible}) a
      in answers) {
    for (final String tag in a.tags.where((String t) => facetOf(t) == chosen)) {
      final ({double earned, double possible, int n}) prev =
          acc[tag] ?? (earned: 0, possible: 0, n: 0);
      acc[tag] = (
        earned: prev.earned + a.earned,
        possible: prev.possible + a.possible,
        n: prev.n + 1,
      );
    }
  }

  final List<CategoryScore> out = <CategoryScore>[
    for (final MapEntry<String, ({double earned, double possible, int n})> e
        in acc.entries)
      if (e.value.n >= minAnswers && e.value.possible > 0)
        CategoryScore(
          tag: e.key,
          earned: e.value.earned,
          possible: e.value.possible,
          answers: e.value.n,
        ),
  ];
  // Strongest first, then by name so equal scores have a stable order rather
  // than shuffling between rebuilds.
  out.sort((CategoryScore a, CategoryScore b) {
    final int byPct = b.percent.compareTo(a.percent);
    return byPct != 0 ? byPct : a.tag.compareTo(b.tag);
  });
  return out;
}

/// The answers of one attempt, shaped for [categoryScores].
///
/// Uses [Response.mark] and [Response.markOutOf] - the composed mark and its
/// matching denominator - so this cannot drift from what the score panels show.
///
/// `markOutOf` MATTERS MORE THAN IT LOOKS. A graded answer is worth 1 once a
/// grader has run and 0 before that, so an answer still awaiting the LLM
/// contributes nothing to EITHER side and is simply not counted yet. Hardcoding
/// a denominator of 1 would score every unscored answer as a loss, and a
/// candidate mid-grading would be shown weaknesses that are really just a queue.
List<({List<String> tags, double earned, double possible})> answersOf(
  Attempt attempt,
  Assessment assessment,
) => <({List<String> tags, double earned, double possible})>[
  for (final Question q in assessment.questions)
    if (attempt.resp[q.id] case final Response r)
      if (r.tags.isNotEmpty && r.markOutOf > 0)
        (
          tags: r.tags,
          earned: r.mark.toDouble(),
          possible: r.markOutOf.toDouble(),
        ),
];

/// The rows of one answer sheet, shaped for [categoryScores].
///
/// FOR THE CANDIDATE'S OWN "See my answers" SURFACE. The performance screen has
/// `Attempt`/`Response` to work from; this route has neither - it returns a flat
/// sheet - so the same maths is fed from the sheet instead. Both end in
/// [categoryScores], which is what keeps the two screens' numbers identical.
///
/// WEIGHTED BY EACH ROW'S OWN MARK PAIR. The sheet sends
/// [AnswerSheetRow.marksEarned] and [AnswerSheetRow.marksAvailable] per row -
/// a question is worth one mark per COMPONENT now, so a three-part mcq is worth
/// 3 and an image_ab with four verdict axes plus a justification is worth 5 -
/// and both halves go straight into [categoryScores].
///
/// THIS USED TO WEIGH EVERY ROW AS 1 and read an objective row as
/// all-or-nothing, because the route sent no per-row marks. That made a 3-mark
/// question pull a category exactly as hard as a 1-mark one, and scored a
/// candidate who got 2 of 3 as a flat loss - so any category mixing question
/// sizes reported a percentage nobody could reproduce from the marks in front
/// of them. [answersOf] has always summed real marks off [Response.markOutOf];
/// the candidate's path and the operator's now agree by construction rather
/// than by luck.
///
/// A ROW STILL HAS TO HAVE BEEN MARKED to count - see [_isMarked] - and a row
/// from a server that predates the pair falls back to the old reading, see
/// [_legacyEarned]. Rows the sheet reports as unmarked are skipped, not counted
/// as zero: "Not answered" and "Awaiting grading" both mean there is nothing to
/// average yet, and counting them as lost marks would show a candidate
/// weaknesses that are really a queue.
List<({List<String> tags, double earned, double possible})> answersOfSheet(
  AnswerSheet sheet,
) => <({List<String> tags, double earned, double possible})>[
  for (final AnswerSheetRow r in sheet.rows)
    if (r.tags.isNotEmpty && r.marksAvailable > 0 && _isMarked(r))
      (
        tags: r.tags,
        earned: r.marksEarned ?? _legacyEarned(r),
        possible: r.marksAvailable.toDouble(),
      ),
];

/// Whether a sheet row has been MARKED at all, as opposed to unanswered or
/// still in the grading queue.
///
/// THE MARK PAIR CANNOT ANSWER THIS ON ITS OWN: an ungraded row still arrives
/// with `marks_earned: 0.0` against its real `marks_available`, which is
/// indistinguishable from a genuine zero. So the outcome the SERVER stated -
/// its `kind`, parsed into [AnswerSheetRow.tone] - is what decides whether a
/// row counts, and the pair only decides by how much.
bool _isMarked(AnswerSheetRow r) {
  // A grader ran. Objective rows never carry this, which is the bug that once
  // produced an EMPTY breakdown for an all-MCQ paper where every question had
  // in fact been marked - caught by seeding a 12-question MCQ demo.
  if (r.scoreRaw != null) return true;
  // WITH A PAIR, ANY OUTCOME THE SERVER STATED COUNTS - `partial` included,
  // which the pass/fail reading below has to discard because it has no way to
  // say how much of the question was right. `inert` is what "Not answered" and
  // "Awaiting grading" arrive as, and neither is a mark of zero.
  if (r.marksEarned != null) return r.tone != Tone.inert;
  return r.tone == Tone.ok || r.tone == Tone.bad;
}

/// What a row earned when the server sent no pair for it, on the terms that
/// server scored by: one mark per question, a subjective row carrying the
/// grader's 0-1 fraction in [AnswerSheetRow.scoreRaw] and an objective row
/// carrying nothing but a pass/fail [AnswerSheetRow.tone].
///
/// A FRACTION, NOT A PERCENTAGE. `score_raw` is 0-1 while `llm_raw_100` next
/// door is 0-100; reading one on the other's scale renders a 0.75 answer as
/// "1%".
double _legacyEarned(AnswerSheetRow r) =>
    r.scoreRaw ?? (r.tone == Tone.ok ? 1.0 : 0.0);

/// The single biggest improvement between two sittings of the same test, or
/// null when nothing can be compared.
///
/// [now] and [before] are the same test's category scores from the current and
/// the previous attempt. A category only qualifies if it appears in BOTH -
/// a category that did not exist last time has no improvement to report, and
/// presenting it as one would be inventing a trend from a single data point.
({String tag, double delta})? mostImproved(
  List<CategoryScore> now,
  List<CategoryScore> before,
) {
  final Map<String, double> prev = <String, double>{
    for (final CategoryScore c in before) c.tag: c.percent,
  };
  ({String tag, double delta})? best;
  for (final CategoryScore c in now) {
    final double? was = prev[c.tag];
    if (was == null) continue;
    final double delta = c.percent - was;
    // STRICTLY POSITIVE. "Most improved: 0%" is not an improvement, and a
    // negative best would be a decline dressed up as progress.
    if (delta <= 0) continue;
    if (best == null || delta > best.delta) {
      best = (tag: c.tag, delta: delta);
    }
  }
  return best;
}
