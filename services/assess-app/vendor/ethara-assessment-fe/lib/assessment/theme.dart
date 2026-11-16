// The assessment screens, wired to the PORTAL's design system.
//
// THE RULE: this app has ONE theme. `PortalTokens` and
// `PortalType` in `lib/core/theme/` are the single source of truth for colour
// and type. Nothing in this file invents a value - every token is an alias and
// every text style delegates to the portal's ramp.
//
// An adapter rather than a find-and-replace over 227 call sites: the screens
// were built against their own accessor names (`context.tokens`,
// `context.type.pageTitle`), and mapping once here lets a change to the portal
// palette or type scale reach them without anyone touching a screen. The two
// systems already agree on 29 of 32 colour names, so most of this is a rename.
import 'package:flutter/material.dart';

import '../core/theme/portal_tokens.dart';
import '../core/theme/portal_type.dart';

export '../../core/theme/portal_tokens.dart';
export '../../core/theme/portal_type.dart';

/// The portal's tokens under the name the assessment screens use.
typedef AppTokens = PortalTokens;

extension AssessmentTheme on BuildContext {
  /// The portal's active token set. The same `PortalTokens.of` the rest of the
  /// app reads, so two things on one screen can never disagree about what
  /// `bgApp` is.
  PortalTokens get tokens => PortalTokens.of(this);

  /// The assessment type ramp, expressed in the portal's styles.
  AssessmentTypeRamp get type => AssessmentTypeRamp(PortalTokens.of(this));
}

/// Maps the assessment screens' semantic style names onto [PortalType].
///
/// Each getter names a ROLE in the assessment UI ("the marks on a result
/// card", "a question prompt") and resolves to whichever portal style carries
/// that weight. Where the portal has an exact counterpart it is used verbatim;
/// nothing here defines a new size or weight.
@immutable
class AssessmentTypeRamp {
  const AssessmentTypeRamp(this._t);

  final PortalTokens _t;

  // ── Page furniture ──────────────────────────────────────────────────────
  TextStyle get pageTitle => PortalType.headingXl(_t.textPrimary);
  TextStyle get pageSub => PortalType.bodySm(_t.textSecondary);
  TextStyle get crumb => PortalType.bodyXs(_t.textMuted);
  TextStyle get eyebrow => PortalType.eyebrow(color: _t.textMuted);

  // ── Panels and sheets ───────────────────────────────────────────────────
  TextStyle get panelTitle => PortalType.titleLg(_t.textPrimary);
  TextStyle get panelNote => PortalType.bodyXs(_t.textMuted);
  TextStyle get sheetTitle => PortalType.headingLg(_t.textPrimary);
  TextStyle get sheetSub => PortalType.bodySm(_t.textSecondary);

  // ── Body ────────────────────────────────────────────────────────────────
  TextStyle get body => PortalType.bodyMd(_t.textPrimary);
  TextStyle get bodySecondary => PortalType.bodySm(_t.textSecondary);
  TextStyle get bodyMuted => PortalType.bodySm(_t.textMuted);
  TextStyle get small => PortalType.bodyXs(_t.textSecondary);
  TextStyle get tiny => PortalType.bodyXs(_t.textMuted);
  TextStyle get banner => PortalType.bodySm(_t.textPrimary);

  // ── Forms and controls ──────────────────────────────────────────────────
  TextStyle get fieldLabel => PortalType.label(_t.textSecondary);
  TextStyle get button => PortalType.button(_t.textPrimary);
  TextStyle get option => PortalType.bodyMd(_t.textPrimary);

  // ── Questions ───────────────────────────────────────────────────────────
  TextStyle get questionPrompt => PortalType.titleLg(_t.textPrimary);
  TextStyle get questionDesc => PortalType.bodySm(_t.textSecondary);

  // ── Numerals: always mono, so columns of figures stay aligned ───────────
  TextStyle get kpiValue => PortalType.dataLg(_t.textPrimary);

  /// A KPI whose value is a WORD, not a numeral - "Time out", "Violations".
  /// [kpiValue] is a 30px mono display size cut for two or three digits, so a
  /// word set in it ellipsises to "Time ..." once the card is anywhere near
  /// the grid's minimum width. Words drop to the UI face at a size that fits
  /// the longest value such a card can hold; the eyebrow label above is
  /// unchanged, so the card still reads as a stat.
  TextStyle get kpiValueWord => PortalType.headingMd(_t.textPrimary);

  TextStyle get kpiLabel => PortalType.eyebrow(color: _t.textMuted);
  TextStyle get kpiSub => PortalType.bodyXs(_t.textMuted);
  TextStyle get mono => PortalType.dataSm(_t.textPrimary);
  TextStyle get monoSmall => PortalType.dataXs(_t.textMuted);
  TextStyle get clock => PortalType.dataMd(_t.textPrimary);
  TextStyle get countChip => PortalType.dataXs(_t.textSecondary);

  /// The score itself on a result card. Mono and large: it is the number the
  /// candidate came for.
  TextStyle get marks => PortalType.dataXl(_t.textPrimary);

  /// The denominator in `X / N` - deliberately quieter than [marks], because
  /// the total is context and the score is the answer.
  TextStyle get marksDen => PortalType.dataMd(_t.textMuted);

  // ── Tables and tags ─────────────────────────────────────────────────────
  TextStyle get tableHead => PortalType.eyebrow(color: _t.textMuted);
  TextStyle get tableCell => PortalType.bodySm(_t.textPrimary);
  TextStyle get pill => PortalType.labelSm(_t.textPrimary);
  TextStyle get badge => PortalType.labelSm(_t.textPrimary);
  TextStyle get tag => PortalType.bodyXs(_t.textSecondary);
}

/// Corner radii for assessment surfaces.
///
/// Kept as `BorderRadius` constants rather than doubles because that is what
/// every call site passes straight into a `BoxDecoration`. The values match
/// the portal's cards and controls.
abstract final class Radii {
  // Yantra (studio look): panels and sheets 18, cards 14, fields 10; Btn is a
  // pill ([btnPill]), other button-shaped controls keep their corners.
  static const BorderRadius panel = BorderRadius.all(Radius.circular(18));
  static const BorderRadius card = BorderRadius.all(Radius.circular(14));
  static const BorderRadius sheet = BorderRadius.all(Radius.circular(18));
  static const BorderRadius button = BorderRadius.all(Radius.circular(8));
  static const BorderRadius buttonSm = BorderRadius.all(Radius.circular(7));
  static const BorderRadius buttonLg = BorderRadius.all(Radius.circular(9));
  static const BorderRadius btnPill = BorderRadius.all(Radius.circular(999));
  static const BorderRadius option = BorderRadius.all(Radius.circular(12));
  static const BorderRadius input = BorderRadius.all(Radius.circular(10));
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
  static const BorderRadius badge = BorderRadius.all(Radius.circular(5));
  static const BorderRadius bar = BorderRadius.all(Radius.circular(4));
}

/// `colour.o(0.5)` - the opacity helper the assessment widgets are written
/// against. `withValues` rather than the deprecated `withOpacity`.
extension TokenAlpha on Color {
  Color o(double alpha) => withValues(alpha: alpha);
}

/// Chart colours for the budget and usage graphs.
///
/// The portal's palette is semantic (success / info / warn / destructive) and
/// deliberately has no sequential ramp, because none of its screens plot a
/// series. These are the assessment charts' ordered steps, tinted from the
/// portal's own accent so a graph still reads as the same product.
///
/// The one branding rule still holds: this is a DATA ramp, not a new accent.
/// Nothing outside a chart may use it.
extension AssessmentCharts on PortalTokens {
  Color get seq1 => primarySubtle;
  Color get seq2 => primary;
  Color get seq3 => primaryHover;

  /// Categorical chart colours, drawn from the portal's semantic families so a
  /// legend never introduces a hue the design system does not have.
  Color get c1 => primary;
  Color get c2 => infoDot;
  Color get c3 => successDot;
  Color get c4 => warnDot;
  Color get c5 => destDot;

  /// The colour a drop shadow is tinted with.
  ///
  /// The portal ships shadows as ready-made `BoxShadow` LISTS (`shadowS1`..
  /// `shadowS5`); the assessment widgets build their own and only need a
  /// colour, so both end up the same shade of dark.
  Color get shadow =>
      isDark ? const Color(0xFF000000) : const Color(0xFF030213);

  /// Hover overlay opacity. Higher in dark mode, where a light film has to
  /// work against a dark surface to be seen at all.
  double get hoverA => isDark ? 0.06 : 0.04;
}
