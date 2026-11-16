import 'package:flutter/material.dart';

/// ETHARA PORTAL — TYPOGRAPHY
///
/// Two typefaces, no exceptions:
///   • **Plus Jakarta Sans** — all interface text. Labels, headings, body,
///     buttons, nav.
///   • **DM Mono** — every NUMERAL a human reads as data: scores, counts,
///     hours, IDs, codes, dates, timestamps, percentages.
///
/// The mono rule is not decoration. Tabular figures keep columns aligned and
/// stop a table of numbers from shimmering as values change.
///
/// ── BUNDLED FONTS, NOT THE CDN ────────────────────────────────────────────
/// Both families ship as assets in `assets/fonts/` and are declared in
/// `pubspec.yaml`. We reference them by family NAME rather than through
/// `google_fonts`, because `GoogleFonts.*` fetches from Google's CDN at runtime:
/// a network dependency on first paint and an EU privacy consideration.
///
/// DM Mono is bundled at w400 and w500 only. Asking for w600+ makes Flutter
/// synthesise a faux-bold, so the data scale below never exceeds w500 except
/// [dataXl], which is deliberate and only used for one hero number per screen.
///
/// ── NO FONT SCALING ───────────────────────────────────────────────────────
/// Sizes here are literal: `fontSize: 14` paints at 14px, matching the React
/// portal, which is the canonical visual reference. An older Ethara Flutter
/// design system applied a global `_scale = 0.9`, so code moved from it grows
/// ~11% here - re-check any fixed-height row.
abstract final class PortalType {
  /// Family names — must match `pubspec.yaml` exactly.
  static const String familyUi = 'Plus Jakarta Sans';
  static const String familyMono = 'DM Mono';

  /// Hindi answers and Hindi correct answers (the Transcription question) are
  /// Devanagari, which neither face has. Bundled so it never depends on the
  /// engine fetching a fallback font from Google at run time.
  static const List<String> fallback = ['Noto Sans Devanagari'];

  // ── Primitives ────────────────────────────────────────────────────────────

  /// Interface text — Plus Jakarta Sans.
  ///
  /// The bundled file is a VARIABLE font with a `wght` axis (200–800). A
  /// variable font ignores [FontWeight] on its own, so the weight is also
  /// pushed through [FontVariation] — set only one of them and every label
  /// renders at the default 400.
  static TextStyle ui({
    required double fontSize,
    FontWeight fontWeight = FontWeight.w400,
    Color? color,
    double? height,
    double? letterSpacing,
    FontStyle? fontStyle,
  }) => TextStyle(
    fontFamily: familyUi,
    fontFamilyFallback: fallback,
    fontSize: fontSize,
    fontWeight: fontWeight,
    fontVariations: [FontVariation('wght', fontWeight.value.toDouble())],
    color: color,
    height: height,
    letterSpacing: letterSpacing,
    fontStyle: fontStyle,
  );

  /// Numerals and identifiers — DM Mono. Bundled at w400/w500 only.
  static TextStyle mono({
    required double fontSize,
    FontWeight fontWeight = FontWeight.w400,
    Color? color,
    double? height,
    double? letterSpacing,
  }) => TextStyle(
    fontFamily: familyMono,
    fontFamilyFallback: fallback,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    height: height,
    letterSpacing: letterSpacing,
  );

  /// Small uppercase section label. Always `textMuted` unless told otherwise.
  static TextStyle eyebrow({required Color color}) => ui(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: color,
    letterSpacing: 0.66, // 11 * 0.06
  );

  // ── Named UI scale ────────────────────────────────────────────────────────

  /// Page title. One per screen.
  ///
  /// React: `text-2xl font-semibold` on `PageHeader` — 24px at w600. Not w800:
  /// the portal's page titles are semibold, and the extra weight read as a
  /// different product.
  static TextStyle headingXl(Color c) => ui(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    color: c,
    height: 1.2,
    letterSpacing: -0.3,
  );

  /// Detail-view title.
  static TextStyle headingLg(Color c) => ui(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: c,
    height: 1.25,
    letterSpacing: -0.2,
  );

  /// Section heading inside a page.
  static TextStyle headingMd(Color c) =>
      ui(fontSize: 17, fontWeight: FontWeight.w700, color: c, height: 1.3);

  /// Card title.
  static TextStyle titleLg(Color c) =>
      ui(fontSize: 15, fontWeight: FontWeight.w600, color: c, height: 1.4);

  /// Sub-title, table header, nav row.
  static TextStyle titleMd(Color c) =>
      ui(fontSize: 14, fontWeight: FontWeight.w600, color: c, height: 1.4);

  /// Small title.
  static TextStyle titleSm(Color c) =>
      ui(fontSize: 13, fontWeight: FontWeight.w600, color: c, height: 1.4);

  /// Default body text.
  static TextStyle bodyMd(Color c) =>
      ui(fontSize: 14, fontWeight: FontWeight.w400, color: c, height: 1.45);

  /// Small body — captions, descriptions, table cells.
  static TextStyle bodySm(Color c) =>
      ui(fontSize: 13, fontWeight: FontWeight.w400, color: c, height: 1.45);

  /// Fine print, meta lines, helper text.
  static TextStyle bodyXs(Color c) =>
      ui(fontSize: 12, fontWeight: FontWeight.w400, color: c, height: 1.4);

  /// Form label.
  static TextStyle label(Color c) =>
      ui(fontSize: 13, fontWeight: FontWeight.w500, color: c, height: 1.3);

  /// Dense label, chip text, pill label.
  static TextStyle labelSm(Color c) =>
      ui(fontSize: 11, fontWeight: FontWeight.w600, color: c, height: 1.3);

  /// Button label — always w600.
  static TextStyle button(Color c, {bool small = false}) => ui(
    fontSize: small ? 13 : 14,
    fontWeight: FontWeight.w600,
    color: c,
    height: 1.2,
  );

  // ── Named data (mono) scale ───────────────────────────────────────────────

  /// Hero metric — the one big number on a scorecard.
  /// w500 because DM Mono is bundled at w400/w500 only; at 32px the medium
  /// weight already reads as the heaviest thing on the page.
  static TextStyle dataXl(Color c) =>
      mono(fontSize: 32, fontWeight: FontWeight.w500, color: c, height: 1.1);

  /// KPI card value — 30px mono medium.
  ///
  /// React `KpiCard`: `font-mono text-[30px] font-medium leading-[1.1]`. It was
  /// 24 here, which is why our cards read noticeably smaller than the clone
  /// side by side.
  static TextStyle dataLg(Color c) =>
      mono(fontSize: 30, fontWeight: FontWeight.w500, color: c, height: 1.1);

  /// Inline value, legend count, stat tile.
  static TextStyle dataMd(Color c) =>
      mono(fontSize: 18, fontWeight: FontWeight.w500, color: c, height: 1.25);

  /// Table cell number, code, ID.
  static TextStyle dataSm(Color c) =>
      mono(fontSize: 13, fontWeight: FontWeight.w500, color: c, height: 1.4);

  /// Timestamp, duration, axis label, meta numeral.
  static TextStyle dataXs(Color c) =>
      mono(fontSize: 11, fontWeight: FontWeight.w400, color: c, height: 1.4);
}
