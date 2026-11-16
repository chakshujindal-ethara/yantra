import 'package:flutter/material.dart';

/// ETHARA STUDIO — DESIGN TOKENS
///
/// Transcribed from Ethara's Social AI studio (`apps/web/styles/tokens.css`, `login.css` `--st-*`,
/// `dashboard.css`): the violet-white "board" in light mode, near-black charcoal in dark, translucent
/// cards on a backdrop with a magenta bloom at the top left and a teal one at the bottom right, and the
/// brand gradient (#B814D0 → #CC14CC) on primary actions and the active nav chip. Solid surfaces
/// ([bgApp]) stay solid for dialogs, menus and fields; only cards use the translucent [card].
///
/// THE ONE BRANDING RULE
/// Magenta is an accent, not a theme. It appears ONLY on primary CTAs, the
/// active nav item, focus/selected states and the brand mark. Surfaces, borders,
/// icons and meta text stay neutral. Status uses the semantic families
/// (success / info / warn / destructive) and NEVER magenta.
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
    required this.ring,
    required this.skeleton,
    required this.scrollbar,
    required this.scrim,
    required this.shadowS1,
    required this.shadowS2,
    required this.shadowS3,
    required this.card,
    required this.cardLine,
    required this.bloomA,
    required this.bloomB,
    required this.shadowCard,
    required this.accentFill,
  });

  final bool isDark;

  // ── Brand / accent ────────────────────────────────────────────────────────
  /// Magenta accent. Primary CTA, active nav, brand mark, focus ring.
  final Color primary;

  /// Hover for [primary]. Darker in light mode, LIGHTER in dark mode.
  final Color primaryHover;

  /// Low-emphasis magenta wash: emphasis cards, selected chips and segments.
  final Color primarySubtle;

  /// Selected row / item background.
  final Color selected;

  // ── Surfaces ──────────────────────────────────────────────────────────────
  /// The solid surface: dialogs, menus, fields, sheets, buttons' faces. Cards use the translucent [card].
  final Color bgApp;

  /// Inset panels, chips, table headers, form field wells.
  final Color bgMuted;

  /// Page backdrop behind raised cards. Lighter than [bgApp] in light mode,
  /// darker in dark mode.
  final Color bgSubtle;

  /// Darkest page base, behind everything.
  final Color bgBase;

  /// Translucent hover overlay — composite it, never treat it as a solid.
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
  final Color infoDot;
  final Color warnText;
  final Color warnBg;
  final Color warnDot;
  final Color destText;
  final Color destBg;
  final Color destDot;

  // ── Chrome ────────────────────────────────────────────────────────────────
  /// Focus ring colour. Every interactive element MUST show a visible ring.
  final Color ring;
  final Color skeleton;
  final Color scrollbar;

  /// Modal / drawer backdrop.
  final Color scrim;

  // ── Elevation ─────────────────────────────────────────────────────────────
  // Light shadows use near-black ink at low alpha; the dark scale is boosted.
  final List<BoxShadow> shadowS1;
  final List<BoxShadow> shadowS2;
  final List<BoxShadow> shadowS3;

  // ── Studio surfaces ───────────────────────────────────────────────────────
  /// Card fill: translucent, so the page backdrop's blooms show through it.
  final Color card;

  /// Card hairline.
  final Color cardLine;

  /// The backdrop's magenta bloom (top left) and teal bloom (bottom right).
  final Color bloomA;
  final Color bloomB;

  /// The soft tinted lift under cards.
  final List<BoxShadow> shadowCard;

  /// A solid magenta that carries white content (a badge, a checkbox tick, a selected day, a switch track): the
  /// studio's `--accent-fill`. [primary] is the accent as text, which in dark mode is too light under white.
  final Color accentFill;

  /// Primary buttons, the active nav chip and the brand mark: the same fill everywhere.
  static const LinearGradient brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    // the studio's #B814D0 → #E11FE0, its bright end deepened to #CC14CC so white text on any point of it
    // passes WCAG AA (4.6:1; #E11FE0 is 3.8:1)
    colors: [Color(0xFFB814D0), Color(0xFFCC14CC)],
  );

  /// The brand gradient's first stop as one colour: the accent bar of a plain KPI tile.
  static const Color brandSolid = Color(0xFFB814D0);

  /// A primary button while pressed: the gradient's start, deepened.
  static const Color brandPressed = Color(0xFFA20FB8);

  /// A destructive action's fill. Red, never the brand gradient; white on it is 5.7:1 in both themes.
  static const Color destFill = Color(0xFFC0233D);

  /// The faint magenta wash down the top of the rail.
  static const LinearGradient railWash = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x0DE11FE0), Color(0x00E11FE0)],
    stops: [0, 0.3],
  );

  /// The row of the page you are on, washed magenta fading right.
  static const LinearGradient navWash = LinearGradient(colors: [Color(0x21E11FE0), Color(0x0AE11FE0)]);

  /// A nav icon chip under the pointer.
  static const Color navHoverChip = Color(0x1FE11FE0);

  /// The magenta glow under a primary button on hover.
  static const List<BoxShadow> buttonGlow = [BoxShadow(color: Color(0x73E11FE0), offset: Offset(0, 8), blurRadius: 24, spreadRadius: -8)];

  /// The glow under a gradient chip (the active nav icon, the brand mark).
  static const List<BoxShadow> chipGlow = [BoxShadow(color: Color(0x99B814D0), offset: Offset(0, 6), blurRadius: 14, spreadRadius: -6)];

  /// The lift under a nav row the pointer is on (light mode).
  static const List<BoxShadow> rowLift = [BoxShadow(color: Color(0x73B814D0), offset: Offset(0, 8), blurRadius: 18, spreadRadius: -12)];

  /// Resolves the token set matching the ambient theme brightness.
  static PortalTokens of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? dark : light;

  static const PortalTokens light = PortalTokens(
    isDark: false,
    // accent text on the board (--st-accent-text); fills use [brand]
    primary: Color(0xFFA800A8),
    primaryHover: Color(0xFF8C008C),
    primarySubtle: Color(0xFFF3DDF7),
    selected: Color(0xFFF0D6F5),
    bgApp: Color(0xFFFFFFFF),
    bgMuted: Color(0xFFEEEAF4),
    bgSubtle: Color(0xFFF5F2FA), // --st-board
    bgBase: Color(0xFFFFFFFF),
    bgHover: Color(0x0A1A1426),
    border: Color(0xFFDDD8E4),
    borderSubtle: Color(0xFFE7E3ED),
    borderHover: Color(0xFFEBA9EC),
    zebra: Color(0x051A1426),
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
    ring: Color(0xFFA800A8),
    skeleton: Color(0xFFECE8F2),
    scrollbar: Color(0xFFD5D0DD),
    scrim: Color(0x661A1426),
    shadowS1: [BoxShadow(color: Color(0x0F1A1426), offset: Offset(0, 1), blurRadius: 2)],
    shadowS2: [BoxShadow(color: Color(0x1A502878), offset: Offset(0, 8), blurRadius: 24, spreadRadius: -12)],
    shadowS3: [BoxShadow(color: Color(0x2E502878), offset: Offset(0, 18), blurRadius: 48, spreadRadius: -12)],
    // the studio's cards are rgba(255,255,255,.78), but CSS never paints a box-shadow under its box and Flutter does:
    // any translucency lets the lift shadow show through as an inner rectangle, so light cards are solid white
    card: Color(0xFFFFFFFF),
    cardLine: Color(0x141A1426), // rgba(26,20,38,.08)
    bloomA: Color(0x24E11FE0),
    bloomB: Color(0x1A2DE2C8),
    shadowCard: [
      BoxShadow(color: Color(0x0A0B0E14), offset: Offset(0, 1), blurRadius: 2),
      BoxShadow(color: Color(0x1F0B0E14), offset: Offset(0, 8), blurRadius: 24, spreadRadius: -12),
    ],
    accentFill: Color(0xFFB800B8),
  );

  static const PortalTokens dark = PortalTokens(
    isDark: true,
    primary: Color(0xFFF07EF0), // --st-accent-text
    primaryHover: Color(0xFFFF9CFF),
    primarySubtle: Color(0xFF26082A),
    selected: Color(0xFF2C0C31),
    bgApp: Color(0xFF13111B),
    bgMuted: Color(0xFF1A1822),
    bgSubtle: Color(0xFF05040A), // --st-board
    bgBase: Color(0xFF0D0B14),
    bgHover: Color(0x0FFFFFFF),
    border: Color(0xFF29272F),
    borderSubtle: Color(0xFF1C1A22),
    borderHover: Color(0xFF6E2A70),
    zebra: Color(0x05FFFFFF),
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
    ring: Color(0xFFF07EF0),
    skeleton: Color(0xFF1A1822),
    scrollbar: Color(0xFF34313D),
    scrim: Color(0xA6000000),
    shadowS1: [BoxShadow(color: Color(0x66000000), offset: Offset(0, 1), blurRadius: 2)],
    shadowS2: [BoxShadow(color: Color(0x99000000), offset: Offset(0, 12), blurRadius: 32, spreadRadius: -16)],
    shadowS3: [BoxShadow(color: Color(0x8C000000), offset: Offset(0, 18), blurRadius: 48, spreadRadius: -12)],
    card: Color(0x09FFFFFF), // rgba(255,255,255,.035)
    cardLine: Color(0x1AFFFFFF), // rgba(255,255,255,.1)
    bloomA: Color(0x2EE11FE0),
    bloomB: Color(0x182DE2C8),
    shadowCard: [BoxShadow(color: Color(0x99000000), offset: Offset(0, 12), blurRadius: 32, spreadRadius: -16)],
    accentFill: Color(0xFFC800C8),
  );
}

/// Spacing scale. 12 · 8 · 16 carry ~75% of all real spacing.
abstract final class Space {
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
}

/// Corner radii: controls 10, panels 14, cards 18 (the studio's `.dash-card`), pills full.
abstract final class Radii {
  static const double sm = 6;
  static const double md = 10;
  static const double lg = 14;
  static const double xl = 18;
  static const double full = 9999;

  static const BorderRadius rSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius rMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius rLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius rXl = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius rFull = BorderRadius.all(Radius.circular(full));
}

/// Control heights and icon sizes.
abstract final class Sizes {
  static const double controlSm = 32;
  static const double controlMd = 36;
  static const double controlLg = 40;
  static const double topBar = 56;
  static const double iconSm = 16;
  static const double iconMd = 20;
  static const double iconLg = 24;
}
