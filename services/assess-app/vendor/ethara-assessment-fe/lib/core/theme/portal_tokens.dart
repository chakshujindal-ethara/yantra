import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

/// ETHARA PORTAL — DESIGN TOKENS
///
/// Yantra: values remapped to Ethara's Social AI studio palette (the
/// violet-white board #F5F2FA, charcoal #05040A, accent #A800A8 / #F07EF0,
/// teal/amber/rose status), the set Yantra's own app paints (keep the two in
/// step: yantra-labs app/lib/core/theme/portal_tokens.dart), so the exam and
/// admin read as one product with it. [brand] is the primary-action gradient.
///
/// Upstream: a 1:1 transcription of the React portal tokens
/// (`analytics/app/src/index.css`). In Yantra's copy the colour values are the
/// studio palette below instead.
///
/// Two `static const` instances selected by ambient brightness. Deliberately
/// NOT a `ThemeExtension`: no lookup cost, no `InheritedWidget`, and tokens stay
/// readable from `const` constructors.
///
///     final t = PortalTokens.of(context);
///     Container(color: t.bgApp, child: Text('hi', style: TextStyle(color: t.textPrimary)));
///
/// THE ONE BRANDING RULE
/// Magenta is an accent, not a theme. It appears ONLY on primary CTAs, the
/// active nav item, focus/selected states and the brand mark. Surfaces, borders,
/// icons and meta text stay neutral. Status uses the semantic families
/// (success / info / warn / destructive) and NEVER magenta.
///
/// See `docs/DESIGN_SYSTEM.md` for the full specification and per-team briefs.
@immutable
class PortalTokens {
  const PortalTokens({
    required this.isDark,
    required this.primary,
    required this.primaryHover,
    required this.primarySubtle,
    required this.selected,
    required this.bgApp,
    required this.bgMuted,
    required this.bgSubtle,
    required this.bgBase,
    required this.bgHover,
    required this.border,
    required this.borderSubtle,
    required this.borderHover,
    required this.zebra,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.successText,
    required this.successBg,
    required this.successDot,
    required this.infoText,
    required this.infoBg,
    required this.infoDot,
    required this.warnText,
    required this.warnBg,
    required this.warnDot,
    required this.destText,
    required this.destBg,
    required this.destDot,
    required this.canvas,
    required this.canvasGrid,
    required this.tableBg,
    required this.tableBorder,
    required this.seatEmpty,
    required this.seatEmptyText,
    required this.ring,
    required this.skeleton,
    required this.scrollbar,
    required this.scrim,
    required this.shadowS1,
    required this.shadowS2,
    required this.shadowS3,
    required this.shadowS4,
    required this.shadowS5,
  });

  final bool isDark;

  // ── Brand / accent ────────────────────────────────────────────────────────
  /// Magenta accent. Primary CTA, active nav, brand mark, focus ring.
  final Color primary;

  /// Hover for [primary]. Darker in light mode, LIGHTER in dark mode.
  final Color primaryHover;

  /// Low-emphasis magenta wash — icon chips, active nav background.
  final Color primarySubtle;

  /// Selected row / item background.
  final Color selected;

  // ── Surfaces ──────────────────────────────────────────────────────────────
  /// Primary app and card surface. Cards, top bar, sidebar body.
  final Color bgApp;

  /// Inset panels, chips, table headers, form field wells.
  final Color bgMuted;

  /// Page backdrop behind raised cards.
  ///
  /// NOTE this token INVERTS: it is *lighter* than [bgApp] in light mode
  /// (#F8F9FA vs #FFFFFF) and *darker* in dark mode (#0A0A0D vs #18181C).
  final Color bgSubtle;

  /// Darkest page base, behind everything. Only the app scaffold uses this.
  final Color bgBase;

  /// Translucent hover overlay — composite it, never treat it as a solid.
  /// rgba(3,2,19,.04) light · rgba(255,255,255,.06) dark.
  final Color bgHover;

  // ── Lines ─────────────────────────────────────────────────────────────────
  final Color border;
  final Color borderSubtle;

  /// The only magenta-tinted line. Hover border for cards and inputs.
  final Color borderHover;

  /// Table stripe.
  final Color zebra;

  // ── Text ──────────────────────────────────────────────────────────────────
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  // ── Semantic status ───────────────────────────────────────────────────────
  // Four families. Red is reserved for FAILURE ONLY — never for "not started".
  // Status is always dot-or-icon + text, never colour alone.
  final Color successText;
  final Color successBg;
  final Color successDot;
  final Color infoText;
  final Color infoBg;

  /// Info dot. The React app reuses `infoText` here; we ship a real token so
  /// the four status families are symmetrical.
  final Color infoDot;
  final Color warnText;
  final Color warnBg;
  final Color warnDot;
  final Color destText;
  final Color destBg;
  final Color destDot;

  // ── Floor-plan canvas (Seat Allocation) ───────────────────────────────────
  final Color canvas;
  final Color canvasGrid;
  final Color tableBg;
  final Color tableBorder;
  final Color seatEmpty;
  final Color seatEmptyText;

  // ── Chrome ────────────────────────────────────────────────────────────────
  /// Focus ring colour. Every interactive element MUST show a visible ring.
  final Color ring;
  final Color skeleton;
  final Color scrollbar;

  /// Modal / drawer backdrop. Dimmer in dark mode, where the app surface is
  /// already dark and a light scrim would not separate the layers.
  final Color scrim;

  // ── Elevation ─────────────────────────────────────────────────────────────
  // Light shadows use near-black ink at low alpha. That ink is invisible on a
  // dark surface and flattens every card, so the dark scale is BOOSTED (higher
  // alpha, larger blur) rather than reused — same as `html.dark .shadow-s*`.
  final List<BoxShadow> shadowS1;
  final List<BoxShadow> shadowS2;
  final List<BoxShadow> shadowS3;
  final List<BoxShadow> shadowS4;
  final List<BoxShadow> shadowS5;

  /// The studio's primary-action fill (#B814D0 → #CC14CC: white text passes
  /// WCAG AA on every point of it).
  static const LinearGradient brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFB814D0), Color(0xFFCC14CC)],
  );

  /// Resolves the token set matching the ambient theme brightness.
  static PortalTokens of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// The token set for the app's CURRENT mode, without a [BuildContext].
  ///
  /// Only for the top-level colour helpers (`scoreColor`, `flagColor`) called
  /// from chart painters and table cell builders. [overrideBrightness] is set
  /// once at startup by the theme controller so this follows the user's
  /// explicit choice; null falls back to the OS. Prefer [of] whenever you have
  /// a context - it honours nested `Theme(...)` overrides.
  static Brightness? overrideBrightness;

  static PortalTokens get current {
    final b =
        overrideBrightness ?? PlatformDispatcher.instance.platformBrightness;
    return b == Brightness.dark ? dark : light;
  }

  static const PortalTokens light = PortalTokens(
    isDark: false,
    primary: Color(0xFFA800A8),
    primaryHover: Color(0xFF8C008C),
    primarySubtle: Color(0xFFF3DDF7),
    selected: Color(0xFFF0D6F5),
    bgApp: Color(0xFFFFFFFF),
    bgMuted: Color(0xFFEEEAF4),
    bgSubtle: Color(0xFFF5F2FA),
    bgBase: Color(0xFFFFFFFF),
    bgHover: Color(0x0A1A1426), // rgba(26,20,38,.04)
    border: Color(0xFFDDD8E4),
    borderSubtle: Color(0xFFE7E3ED),
    borderHover: Color(0xFFEBA9EC),
    zebra: Color(0xFFFBFAFD),
    textPrimary: Color(0xFF1A1426),
    textSecondary: Color(0xFF544E68),
    textMuted: Color(0xFF5F5974),
    successText: Color(0xFF06756A),
    successBg: Color(0xFFE1F3F0),
    successDot: Color(0xFF0A9C8A),
    infoText: Color(0xFF1F5BC4),
    infoBg: Color(0xFFE6EEFB),
    infoDot: Color(0xFF2F6FDB),
    warnText: Color(0xFF8A5A00),
    warnBg: Color(0xFFFAF0DC),
    warnDot: Color(0xFFD98E04),
    destText: Color(0xFFB3203A),
    destBg: Color(0xFFFCE6EA),
    destDot: Color(0xFFE0364F),
    canvas: Color(0xFFFAFAFB),
    canvasGrid: Color(0xFFE2E2E8),
    tableBg: Color(0xFFECECF0),
    tableBorder: Color(0xFFCBCBD4),
    seatEmpty: Color(0xFFE1E1E8),
    seatEmptyText: Color(0xFF787886),
    ring: Color(0xFFA800A8),
    skeleton: Color(0xFFECE8F2),
    scrollbar: Color(0xFFD5D0DD),
    scrim: Color(0x661A1426),
    shadowS1: [
      BoxShadow(color: Color(0x0F030213), offset: Offset(0, 1), blurRadius: 2),
    ],
    shadowS2: [
      BoxShadow(color: Color(0x14030213), offset: Offset(0, 2), blurRadius: 4),
    ],
    shadowS3: [
      BoxShadow(color: Color(0x1A030213), offset: Offset(0, 4), blurRadius: 8),
    ],
    shadowS4: [
      BoxShadow(color: Color(0x1F030213), offset: Offset(0, 8), blurRadius: 16),
    ],
    shadowS5: [
      BoxShadow(
        color: Color(0x29030213),
        offset: Offset(0, 16),
        blurRadius: 32,
      ),
    ],
  );

  static const PortalTokens dark = PortalTokens(
    isDark: true,
    primary: Color(0xFFF07EF0),
    primaryHover: Color(0xFFFF9CFF),
    primarySubtle: Color(0xFF26082A),
    selected: Color(0xFF2C0C31),
    bgApp: Color(0xFF13111B),
    bgMuted: Color(0xFF1A1822),
    bgSubtle: Color(0xFF05040A),
    bgBase: Color(0xFF0D0B14),
    bgHover: Color(0x0FFFFFFF), // rgba(255,255,255,.06)
    border: Color(0xFF29272F),
    borderSubtle: Color(0xFF1C1A22),
    borderHover: Color(0xFF6E2A70),
    zebra: Color(0xFF100E17),
    textPrimary: Color(0xFFEFEAF7),
    textSecondary: Color(0xFFA9A3B8),
    textMuted: Color(0xFF8D879C),
    successText: Color(0xFF2ED8C3),
    successBg: Color(0xFF0A1C1C),
    successDot: Color(0xFF2ED8C3),
    infoText: Color(0xFF6FA3FF),
    infoBg: Color(0xFF0D1428),
    infoDot: Color(0xFF6FA3FF),
    warnText: Color(0xFFFFC24D),
    warnBg: Color(0xFF1E170A),
    warnDot: Color(0xFFFFC24D),
    destText: Color(0xFFFF8396),
    destBg: Color(0xFF220C12),
    destDot: Color(0xFFFF6B81),
    canvas: Color(0xFF0C0C0E),
    canvasGrid: Color(0xFF202026),
    tableBg: Color(0xFF323232),
    tableBorder: Color(0xFF505050),
    seatEmpty: Color(0xFF26272E),
    seatEmptyText: Color(0xFF9696A2),
    ring: Color(0xFFF07EF0),
    skeleton: Color(0xFF1A1822),
    scrollbar: Color(0xFF34313D),
    scrim: Color(0xA6000000),
    shadowS1: [
      BoxShadow(color: Color(0x66000000), offset: Offset(0, 1), blurRadius: 2),
    ],
    shadowS2: [
      BoxShadow(color: Color(0x73000000), offset: Offset(0, 2), blurRadius: 6),
    ],
    shadowS3: [
      BoxShadow(color: Color(0x80000000), offset: Offset(0, 4), blurRadius: 10),
    ],
    shadowS4: [
      BoxShadow(color: Color(0x8C000000), offset: Offset(0, 8), blurRadius: 20),
    ],
    shadowS5: [
      BoxShadow(
        color: Color(0x99000000),
        offset: Offset(0, 16),
        blurRadius: 34,
      ),
    ],
  );
}

/// Spacing scale. 12 · 8 · 16 carry ~75% of all real spacing - that is the
/// rhythm, whatever the scale allows. [Space.x10] is here even though the React
/// scale skips it: 10px is the horizontal padding of every input in the system.
abstract final class Space {
  static const double x1 = 1;
  static const double x2 = 2;
  static const double x4 = 4;
  static const double x6 = 6;
  static const double x8 = 8;
  static const double x10 = 10;
  static const double x12 = 12;
  static const double x16 = 16;
  static const double x20 = 20;
  static const double x24 = 24;
  static const double x32 = 32;
  static const double x40 = 40;
  static const double x48 = 48;
  static const double x64 = 64;
}

/// Corner radii. `md` (8) is the default for controls; `lg` (12) for cards.
abstract final class Radii {
  static const double sm = 6;
  static const double md = 8;
  static const double lg = 12;
  static const double xl = 16;
  static const double full = 9999;

  static const BorderRadius rSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius rMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius rLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius rXl = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius rFull = BorderRadius.all(Radius.circular(full));
}

/// Control heights and icon sizes.
abstract final class Sizes {
  /// Small control — dense tables, filter bars, secondary actions.
  static const double controlSm = 32;

  /// Default control height. Buttons, inputs, selects, dropdowns.
  static const double controlMd = 36;
  static const double controlLg = 40;

  static const double navRow = 36;

  /// Top bar and brand header.
  static const double topBar = 56;

  /// Sidebar footer (account block).
  static const double sidebarFooter = 64;

  static const double sidebarExpanded = 240;
  static const double sidebarCollapsed = 64;

  /// Height floor for a dashboard card, so two cards side by side match.
  ///
  /// Sized to the tallest fixed element in that band - a 148px donut plus the
  /// panel's header and body padding - so the card beside it stops collapsing
  /// to the height of one sentence.
  static const double panelMin = 232;

  /// Row height for the two dashboard tables, so ten rows of one are exactly
  /// as tall as ten rows of the other.
  ///
  /// Content-driven heights drift: a Performance row carries a progress bar
  /// over a caption and measured 42.5, a Leaderboard row is a single line and
  /// measured 40. Over a ten-row page that is 25px, which is what made the two
  /// cards read as misaligned. 44 clears the taller of the two.
  static const double tableRow = 44;

  /// EXACT height of the two dashboard tables. Not a floor - see Panel.height.
  ///
  /// A floor cannot make two cards equal: it only stops one collapsing, and
  /// ten rows beside seven is still ten rows beside seven. Only a fixed height
  /// holds regardless of row count.
  ///
  /// Chrome (panel header, toolbar, grid header, pagination footer, borders)
  /// plus ten rows at [tableRow], with room for the toolbar to wrap to two
  /// lines on a narrow card - which it does, and which a tighter value
  /// overflowed by exactly 7px. Measured, not guessed: two widget tests police
  /// it. `dashboard_panels_match_test` fails if the two cards stop matching,
  /// and the scroll tests fail if the body no longer fits its rows.
  static const double panelTable = 656;

  /// The same idea for a card wrapping a table, sized to hold TEN rows.
  ///
  /// Ten because that is the point of a paged table: two cards side by side
  /// showing 7 rows and 11 rows were visibly different boxes, and a card that
  /// shrink-wraps a short list also jumps every time a search narrows it.
  /// Sized from the parts rather than guessed - panel header 45 (12+12
  /// padding, ~20 of text, 1 border) + toolbar 59 (11+11 padding, a 36
  /// control, 1 border) + grid header 35 (9+9 padding, ~16 of text, 1 border)
  /// + 10 rows at 41 with the last one losing its divider (409) + pagination
  /// footer 48 (10+10 padding, a 27 control, 1 border) + 2 of card border.
  static const double panelMinTable = 600;

  static const double iconXs = 12;
  static const double iconSm = 16;
  static const double iconMd = 20;
  static const double iconLg = 24;
  static const double iconXl = 32;
}

/// Layout constants. Page content is centred and capped; below [twoColumn] a
/// two-column body collapses to one.
abstract final class Layout {
  /// Default max content width for a console page.
  ///
  /// These mirror the React portal's `<Page max={…}>` values exactly — it is the
  /// one layout number screens legitimately override, because a dense dashboard
  /// needs more room than a single-subject page.
  static const double pageMax = 1440;

  /// Widest cap — analytics and full-width data tables.
  static const double pageMaxWide = 1520;

  /// Narrower cap for single-subject pages (member Projects, detail views).
  static const double pageMaxNarrow = 960;

  /// Page padding — 20 at small widths, 24 from `sm` up.
  /// React: `p-5 sm:p-6` on the page wrapper.
  static const double pagePadSm = 20;
  static const double pagePad = 24;

  /// Gap between page sections.
  static const double sectionGap = 20;

  /// Grid / bento gutter.
  static const double gridGap = 16;

  // Breakpoints. Use LayoutBuilder, not MediaQuery, for content-level response.
  /// Tailwind `sm`. Below this, page padding drops to [pagePadSm] and a stat
  /// row collapses to a column. Same number, two uses — kept as one constant so
  /// the two never drift apart.
  static const double sm = 640;
  static const double statGrid = sm;
  static const double headerStack = 720;
  static const double twoColumn = 1024;
  static const double tableScroll = 1040;
}

/// Motion. Every transition is short and eased — the portal is a data tool, not
/// a showcase. Honour [reducedMotion] before animating anything decorative.
abstract final class Motion {
  static const Duration fast = Duration(milliseconds: 100);
  static const Duration normal = Duration(milliseconds: 150);
  static const Duration slow = Duration(milliseconds: 250);

  /// Standard easing for hover, fills and colour swaps.
  static const Curve standard = Curves.easeOut;

  /// Entrances — menus, dialogs, expanding panels.
  static const Curve entrance = Curves.easeOutCubic;

  /// True when the user has asked the OS to reduce motion. Gate every
  /// non-essential animation on this.
  static bool reducedMotion(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}
