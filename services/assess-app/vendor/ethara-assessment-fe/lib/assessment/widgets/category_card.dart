// The one card that draws SOP-category strengths and weaknesses.
//
// FOUR SURFACES SHOW THIS, and they must agree to the decimal:
//   admin  - a candidate's attempt (per assessment, beside the grader's own
//            reasoning)
//   admin  - a candidate's performance page, reached from a leaderboard row
//   candidate - their own performance page
//   candidate - "See my answers" for one sitting, beside the grader feedback
//
// One widget, because the alternative is four that drift. A candidate and the
// operator judging them reading different numbers for the same category is the
// failure this file exists to prevent.
//
// The categories are the SOP's OWN TAGS - the facets extracted from the source
// document the questions were written from (`skill:`, `task:`, `domain:`,
// `modality:`, `output-format:`). That is deliberate: it lets an operator judge
// a candidate against the proficiencies the SOP actually asked for, rather than
// against a vocabulary this app invented.
import 'package:flutter/material.dart';

import '../domain/category_scores.dart';
import '../domain/enums.dart';
import '../theme.dart';
import '../widgets/charts.dart';
import '../widgets/controls.dart';
import '../widgets/feedback.dart';
import '../widgets/marks.dart';

/// Strengths and weaknesses as bars, with the two ends named.
///
/// [threshold] is the assessment's own pass mark, so a bar's colour answers "is
/// this good enough HERE?" rather than "is this a big number?" - a 55% category
/// is a pass on a 50% paper and a fail on a 70% one.
class CategoryCard extends StatelessWidget {
  const CategoryCard({
    super.key,
    required this.scores,
    required this.threshold,
    this.improved,
    this.audience = CategoryAudience.operator,
    this.showEnds = true,
  });

  final List<CategoryScore> scores;
  final double threshold;

  /// The biggest gain against a previous sitting of the SAME assessment, when
  /// there is one. Null on a first sitting - see `mostImproved` for why that is
  /// silence rather than a zero.
  final ({String tag, double delta})? improved;

  /// Who is reading. Changes the WORDING only, never the arithmetic.
  final CategoryAudience audience;

  /// Whether to name the strongest and weakest above the chart. Off where the
  /// card sits beside a full answer list that already makes the ends obvious.
  final bool showEnds;

  bool get _isCandidate => audience == CategoryAudience.candidate;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    if (scores.isEmpty) return const SizedBox.shrink();
    final CategoryScore best = scores.first;
    final String facet = facetOf(best.tag);

    // SPLIT ON THE PASS MARK, NOT ON RANK.
    //
    // This used to name `scores.first` the strongest and `scores.last` the
    // weakest and stop there - which meant a cohort that cleared every
    // category still had one paraded as "Needs coaching", and one that cleared
    // none had its least-bad reported as a strength. Rank says which is
    // highest; only the threshold says whether it is good enough, and the bars
    // below have always been coloured that way. Using the same test here is
    // what stops the summary disagreeing with the chart under it.
    final List<CategoryScore> strong = <CategoryScore>[
      for (final CategoryScore c in scores)
        if (c.percent >= threshold) c,
    ];
    final List<CategoryScore> weak = <CategoryScore>[
      for (final CategoryScore c in scores)
        if (c.percent < threshold) c,
    ];

    // THE TIE GUARD IS GONE, AND IS NOT NEEDED ANY MORE.
    //
    // The rank version had to suppress both tiles when every category carried
    // the same percentage, because first and last were then the SAME category
    // and it appeared under both headings at once - "Strongest: Pre shift
    // inspection 100.0%" beside "Weakest: Pre shift inspection 100.0%", on a
    // sitting where somebody scored 8/8. Splitting on the threshold cannot
    // produce that: a category is on exactly one side of the bar, so an
    // all-level set lands wholly in one box and the other says so.

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // MOST IMPROVED FIRST: the only line here about change rather than
        // state, and the one worth reading twice.
        if (improved case final ({String tag, double delta}) up)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Notice(
              tone: Tone.ok,
              strong: 'Most improved: ${readableTag(up.tag)}',
              text: _isCandidate
                  ? 'Up ${up.delta.toStringAsFixed(1)} points on this category '
                        'since your last attempt at this assessment.'
                  : 'Up ${up.delta.toStringAsFixed(1)} points on this category '
                        'since their last attempt at this assessment.',
            ),
          ),
        if (showEnds) ...<Widget>[
          // ONE HEIGHT FOR BOTH BOXES. An empty side used to render two lines
          // shorter than a filled one and sit lower in the row, so the pair
          // read as two different kinds of card. Stretch needs the
          // IntrinsicHeight because this row lives in a scroll view.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: _SideBox(
                    title: 'Strengths',
                    blurb: _isCandidate
                        ? 'At or above the pass mark'
                        : 'What the cohort is getting right',
                    categories: strong,
                    tone: t.successText,
                    threshold: threshold,
                    emptyLine: 'Nothing at the pass mark yet',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SideBox(
                    // A candidate is not "coached" by their own results page.
                    title: _isCandidate ? 'Weakest areas' : 'Needs coaching',
                    blurb: _isCandidate
                        ? 'Below the pass mark'
                        : 'Where the cohort went wrong',
                    categories: weak,
                    // Amber, not red: work to do, not a failure - and nothing
                    // here moves a mark.
                    tone: t.warnText,
                    threshold: threshold,
                    emptyLine: 'Nothing below the pass mark',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        BarChart(
          // FIXED 0-100. Scaling to the tallest bar draws the best of a weak
          // set at full width, which reads as mastery.
          maxValue: 100,
          valueSuffix: '%',
          bars: <Slice>[
            for (final CategoryScore c in scores)
              Slice(
                showEnds ? '${c.label}  (${c.answers})' : c.label,
                c.percent,
                c.percent >= threshold
                    ? t.successText
                    : c.percent >= threshold * 0.6
                    ? t.warnText
                    : t.destText,
              ),
          ],
        ),
        const SizedBox(height: 10),
        // FOUR SENTENCES DOWN TO TWO. The cut half explained the weighting
        // ("a category with more questions counts for more"), which the sheet
        // behind each box now shows directly as marks and answer counts - and
        // showing it beats asserting it.
        Text(
          'Marks earned over marks available, by SOP category ($facet), '
          'against the ${threshold.round()}% pass mark. '
          '${_isCandidate ? 'It does not change them.' : 'Never changes a mark or a result.'}',
          style: context.type.tiny.copyWith(height: 1.45, color: t.textMuted),
        ),
      ],
    );
  }
}

/// Who the card is speaking to. Wording only.
enum CategoryAudience { operator, candidate }

/// One half of the summary: every category on one side of the pass mark.
///
/// A BOX, NOT A TILE. The tile it replaces named a single category and threw
/// the rest away, so a cohort weak in four areas was reported as weak in one.
/// This says how many there are and what they average, names the first two,
/// and opens the full list on tap - which is the thing somebody planning
/// coaching actually needs and previously had to reconstruct from the bar
/// chart underneath.
class _SideBox extends StatefulWidget {
  const _SideBox({
    required this.title,
    required this.blurb,
    required this.categories,
    required this.tone,
    required this.threshold,
    required this.emptyLine,
  });

  final String title;
  final String blurb;
  final List<CategoryScore> categories;
  final Color tone;
  final double threshold;

  /// What to say when this side is empty. AN EMPTY SIDE IS A RESULT, not a
  /// missing value: "nothing below the pass mark" is the best thing a cohort
  /// can be told, and borrowing a category from the other side to fill the box
  /// would report a strength as a weakness.
  final String emptyLine;

  @override
  State<_SideBox> createState() => _SideBoxState();
}

class _SideBoxState extends State<_SideBox> {
  bool _hover = false;

  List<CategoryScore> get categories => widget.categories;
  String get title => widget.title;
  String get blurb => widget.blurb;
  Color get tone => widget.tone;
  double get threshold => widget.threshold;
  String get emptyLine => widget.emptyLine;

  double get _average {
    if (categories.isEmpty) return 0;
    // Averaged over MARKS, not over the per-category percentages, for the same
    // reason `categoryScores` is: a category carrying twenty answers and one
    // carrying two are not equal evidence.
    double earned = 0;
    double possible = 0;
    for (final CategoryScore c in categories) {
      earned += c.earned;
      possible += c.possible;
    }
    return possible <= 0 ? 0 : 100.0 * earned / possible;
  }

  String get _names {
    final List<String> shown = categories
        .take(2)
        .map((CategoryScore c) => c.label)
        .toList();
    final int rest = categories.length - shown.length;
    return rest > 0 ? '${shown.join(', ')}, +$rest more' : shown.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool empty = categories.isEmpty;
    // The same card shape and hover treatment `Kpi` uses, because this sits
    // where two Kpi tiles used to and the row must not look like two different
    // kinds of control.
    final Widget card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: t.bgApp,
        borderRadius: Radii.card,
        border: Border.all(
          color: (_hover && !empty) ? t.borderHover : t.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // The label, and at the row's end the one sign that this box opens
          // something: an expand icon that lights up with the border on
          // hover. It replaces the "tap for the full list" sentence, which
          // read as a caption and not as a control. An empty side opens
          // nothing, so it carries no icon.
          Row(
            children: <Widget>[
              Expanded(
                child: Text(title.toUpperCase(), style: context.type.eyebrow),
              ),
              if (!empty)
                Tooltip(
                  message: 'Show all ${categories.length}',
                  child: Icon(
                    Icons.open_in_full_rounded,
                    size: 14,
                    color: _hover ? t.textPrimary : t.textMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (empty)
            Text(emptyLine, style: context.type.bodyMuted)
          else ...<Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Text(
                  '${categories.length}',
                  style: context.type.kpiValue.copyWith(color: tone),
                ),
                const SizedBox(width: 6),
                Text(
                  categories.length == 1 ? 'category' : 'categories',
                  style: context.type.bodySecondary,
                ),
                const Spacer(),
                Mono('${_average.toStringAsFixed(0)}%', color: tone),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _names,
              style: context.type.small,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );

    if (empty) return card;
    return Semantics(
      button: true,
      label: '$title: show all ${categories.length} categories',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _open(context),
          child: card,
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) => showSheet<void>(
    context,
    title: title,
    sub: '$blurb, measured against the ${threshold.round()}% pass mark.',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final CategoryScore c in categories)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(c.label, style: context.type.body),
                      Text(
                        // The evidence behind the percentage. An average over
                        // two answers and one over forty are not the same
                        // claim, and the sheet is where there is room to say so.
                        '${c.earned.toStringAsFixed(c.earned == c.earned.roundToDouble() ? 0 : 1)}'
                        ' of ${c.possible.toStringAsFixed(0)} marks'
                        '  ·  ${c.answers} answer${c.answers == 1 ? '' : 's'}',
                        style: context.type.tiny,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Mono('${c.percent.toStringAsFixed(1)}%', color: tone),
              ],
            ),
          ),
      ],
    ),
  );
}
