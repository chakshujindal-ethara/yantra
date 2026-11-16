// Status marks - HANDOVER §2.5. A status is never bare text: if a value can be
// pending, failed or done, it wears one of these, so the tone rule is enforced
// in one place.
//
// THE TONE RULE: red means failure or absence only. Pending, queued and
// scoring are inert or informational - never red. The mapping lives in
// `Tone` on the enum, so a state cannot be rendered in a tone it was not
// licensed to use.
// `material.dart` rather than `widgets.dart`, for `Tooltip` alone -
// `FlagToggle` needs it for `Tooltip` and `InkResponse`, and `data_grid.dart`
// already imports material for exactly that widget.
import 'package:flutter/material.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import '../theme.dart';

class ToneColors {
  final Color bg;
  final Color fg;
  final Color dot;
  final Color border;

  const ToneColors(this.bg, this.fg, this.dot, this.border);

  factory ToneColors.of(AppTokens t, Tone tone) => switch (tone) {
    Tone.ok => ToneColors(
      t.successBg,
      t.successText,
      t.successDot,
      t.successText.o(.4),
    ),
    Tone.warn => ToneColors(t.warnBg, t.warnText, t.warnDot, t.warnText.o(.4)),
    Tone.bad => ToneColors(t.destBg, t.destText, t.destDot, t.destText.o(.4)),
    Tone.info => ToneColors(t.infoBg, t.infoText, t.infoDot, t.infoText.o(.4)),
    Tone.inert => ToneColors(t.bgMuted, t.textSecondary, t.textMuted, t.border),
    Tone.accent => ToneColors(
      t.primarySubtle,
      t.primary,
      t.primary,
      t.primary.o(.4),
    ),
  };
}

/// `.pill` - a 22px rounded chip with a 5px indicator dot. The dot is the
/// secondary encoding that keeps the tone legible without colour.
class Pill extends StatelessWidget {
  final String label;
  final Tone tone;

  final bool showDot;

  const Pill(this.label, this.tone, {super.key, this.showDot = true});

  /// Build from any state enum, so a screen never picks a tone itself.
  factory Pill.state(dynamic state, {Key? key}) {
    final (String label, Tone tone) = switch (state) {
      AsmState s => (s.label, s.tone),
      AttemptState s => (s.label, s.tone),
      InviteState s => (s.label, s.tone),
      LlmState s => (s.label, s.tone),
      ResultState s => (s.label, s.tone),
      ScoringPhase s => (s.label, s.tone),
      DraftState s => (s.label, s.tone),
      AssetState s => (s.label, s.tone),
      GenState s => (s.label, s.tone),
      TagExtractState s => (s.label, s.tone),
      JobState s => (s.label, s.tone),
      ResourceStatus s => (s.label, s.tone),
      SimBand s => (s.label, s.tone),
      _ => ('$state', Tone.inert),
    };
    return Pill(label, tone, key: key);
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final ToneColors c = ToneColors.of(t, tone);
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: c.bg, borderRadius: Radii.pill),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (showDot) ...<Widget>[
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: c.dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
          ],
          // Flexible, because a pill lands in table cells whose width the pill
          // does not control. A long status ("Merge into domain:warehousing")
          // in a narrow column must ellipsize rather than paint outside the
          // cell - the status still reads, and nothing overlaps its neighbour.
          Flexible(
            child: Text(
              label,
              style: context.type.pill.copyWith(color: c.fg),
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
          ),
        ],
      ),
    );
  }
}

/// `.badge` - a 20px square-cornered mark with a border. Where a pill states a
/// state, a badge states a designation or a warning about the record itself.
/// D1 - the operator's flag on ONE sitting, as a clickable toggle.
///
/// ONE WIDGET FOR EVERY SURFACE (the Candidates roster, the Leaderboard and
/// the attempt header) because the thing that matters about this control is
/// what it DISCLOSES and what it DOES, and a rule about either kept in three
/// places is a rule that will differ in three places.
///
/// AN OUTLINE FLAG WHEN CLEAR, A FILLED RED ONE WHEN RAISED. The outline is
/// drawn for every row, not only flagged ones: a column that is blank until
/// something is wrong gives the operator nothing to click, and "flag this
/// person" is the whole point of the column. Clicking toggles - there is no
/// separate clear action to find.
///
/// The tooltip carries the sentence, never the label. "Raised by Akshay Kumar
/// on Sep 8th, 2026" is built once in [CandidateFlag.raisedSentence] so the
/// three surfaces cannot word it differently, and it is given to the
/// accessibility tree too, so it is not hover-only information for a keyboard
/// or screen-reader user.
class FlagToggle extends StatelessWidget {
  const FlagToggle({
    super.key,
    required this.flag,
    this.onToggle,
    this.size = 17,
  });

  final CandidateFlag flag;

  /// Null for a rung that may READ a flag but not set one. The icon still
  /// renders - a read-only Manager is often the person being asked why a
  /// candidate is held up - it simply does not respond to a click, and says so
  /// rather than looking broken.
  final VoidCallback? onToggle;

  final double size;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool on = flag.flagged;
    final String tip = on
        ? (flag.raisedSentence.isEmpty ? 'Flagged' : flag.raisedSentence)
        : (onToggle == null ? 'Not flagged' : 'Flag this candidate');

    final Widget icon = Icon(
      on ? Icons.flag : Icons.outlined_flag,
      size: size,
      // Muted rather than invisible when clear: the affordance has to be
      // findable before it is used.
      color: on ? t.destText : t.textMuted,
    );

    return Tooltip(
      message: tip,
      excludeFromSemantics: true,
      child: Semantics(
        label: tip,
        button: onToggle != null,
        child: onToggle == null
            ? Padding(padding: const EdgeInsets.all(4), child: icon)
            : InkResponse(
                onTap: onToggle,
                radius: size,
                // A 32px target around a 17px glyph - a flag in a grid row is
                // small, and a control that is hard to hit gets clicked twice,
                // which on a TOGGLE means it ends up back where it started.
                child: Padding(padding: const EdgeInsets.all(4), child: icon),
              ),
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  final String label;
  final Tone tone;
  final Widget? leading;

  const StatusBadge(this.label, this.tone, {super.key, this.leading});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final ToneColors c = ToneColors.of(t, tone);
    return Container(
      constraints: const BoxConstraints(minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: Radii.badge,
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (leading != null) ...<Widget>[leading!, const SizedBox(width: 5)],
          // The label wraps rather than overflowing: a badge can carry a whole
          // reason, and a sentence clipped mid-word tells nobody anything.
          Flexible(
            child: Text(label, style: context.type.badge.copyWith(color: c.fg)),
          ),
        ],
      ),
    );
  }
}

/// An attempt that reached its violation limit, in either mode (A-074). Under
/// Log only nothing ended the paper, so this red label is where the breach
/// shows; under Auto-submit it says why the paper ended. [cap] only where the
/// paper's own cap is loaded: a list row does not carry it. [ai]: the AI
/// proctoring count against the AI cap, which is breached apart.
class ViolationBreachBadge extends StatelessWidget {
  final Attempt attempt;
  final int? cap;
  final bool ai;

  const ViolationBreachBadge(
    this.attempt, {
    super.key,
    this.cap,
    this.ai = false,
  });

  @override
  Widget build(BuildContext context) {
    final String label = ai
        ? 'AI Violation Limit Breached'
        : 'Violation Limit Breached';
    return StatusBadge(
      (cap ?? 0) > 0 ? '$label - ${attempt.countOf(ai)} / $cap' : label,
      Tone.bad,
    );
  }
}

/// `.tag` - the quietest mark. Metadata, not state: a facet or a count label.
class TagChip extends StatelessWidget {
  final String label;

  /// `.tag.accent` - the one variant, used for a coverage designation.
  final bool accent;

  const TagChip(this.label, {super.key, this.accent = false});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent ? t.primarySubtle : t.bgMuted,
        borderRadius: Radii.pill,
        border: Border.all(color: accent ? t.primary.o(.4) : t.border),
      ),
      child: Text(
        label.toUpperCase(),
        style: context.type.tag.copyWith(
          color: accent ? t.primary : t.textSecondary,
        ),
      ),
    );
  }
}

/// `.mono` - a numeral the reader may want to compare or scan down a column.
/// Always tabular, so digits stay in vertical register.
class Mono extends StatelessWidget {
  final String text;
  final double? size;
  final Color? color;
  final FontWeight? weight;

  const Mono(this.text, {super.key, this.size, this.color, this.weight});

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: context.type.mono.copyWith(
      fontSize: size,
      color: color,
      fontWeight: weight,
    ),
  );
}

/// `.marks` - a score, always as marks out of a total.
///
/// Invariant 2: a candidate-facing score is `X / N`. The internal percentage
/// never surfaces as a score, so this widget has no percentage mode at all -
/// there is no way to render one by accident.
class Marks extends StatelessWidget {
  final int earned;
  final int total;
  final double? size;
  final Color? color;

  const Marks(this.earned, this.total, {super.key, this.size, this.color});

  @override
  Widget build(BuildContext context) {
    final ty = context.type;
    return Text.rich(
      TextSpan(
        children: <TextSpan>[
          TextSpan(
            text: '$earned',
            style: ty.marks.copyWith(fontSize: size, color: color),
          ),
          TextSpan(
            text: ' / $total',
            style: ty.marksDen.copyWith(fontSize: size),
          ),
        ],
      ),
    );
  }
}
