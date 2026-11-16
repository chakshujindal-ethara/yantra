import 'package:flutter/material.dart';

import '../errors.dart';
import 'portal_tokens.dart';

/// Typefaces. Family names must match `pubspec.yaml` exactly.
///
/// Plus Jakarta Sans ships as ONE variable file with a `wght` axis, so a
/// [FontWeight] alone does nothing: the weight must also go through
/// [FontVariation]. [AppTheme.weight] sets both; use it instead of a bare
/// `TextStyle(fontWeight: ...)`. DM Mono ships at w400 and w500 only.
abstract final class PortalType {
  static const String familyUi = 'Plus Jakarta Sans';
  static const String familyMono = 'DM Mono';
}

/// Light and dark `ThemeData` built from [PortalTokens]. Nothing in the screens
/// should name a colour; it reads the scheme, the tokens, or these helpers.
abstract final class AppTheme {
  static ThemeData get light => from(PortalTokens.light);
  static ThemeData get dark => from(PortalTokens.dark);

  /// Ids, codes, JSON and timestamps — DM Mono.
  static TextStyle mono(BuildContext context, {double fontSize = 13, Color? color}) => TextStyle(
    fontFamily: PortalType.familyMono,
    fontSize: fontSize,
    fontWeight: FontWeight.w400,
    color: color ?? PortalTokens.of(context).textPrimary,
  );

  /// Money, counts, percentages and countdowns: the UI face with tabular figures, the way the studio sets every
  /// number. DM Mono ([mono]) stays for ids, codes, digests and raw text.
  static TextStyle figure(BuildContext context, {double fontSize = 13, Color? color, FontWeight weight = FontWeight.w500}) => TextStyle(
    fontFamily: PortalType.familyUi,
    fontSize: fontSize,
    fontWeight: weight,
    fontVariations: [FontVariation('wght', weight.value.toDouble())],
    fontFeatures: const [FontFeature.tabularFigures()],
    color: color ?? PortalTokens.of(context).textPrimary,
  );

  /// A weight override that the variable UI font actually renders.
  static TextStyle weight(FontWeight w) => TextStyle(fontWeight: w, fontVariations: [FontVariation('wght', w.value.toDouble())]);

  static ThemeData from(PortalTokens t) {
    final brightness = t.isDark ? Brightness.dark : Brightness.light;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: t.primary,
      // dark primary is the light accent #F07EF0: content on it is ink, not white
      onPrimary: t.isDark ? const Color(0xFF1A1426) : Colors.white,
      primaryContainer: t.primarySubtle,
      onPrimaryContainer: t.textPrimary,
      secondary: t.textSecondary,
      onSecondary: t.bgApp,
      secondaryContainer: t.bgMuted,
      onSecondaryContainer: t.textPrimary,
      tertiary: t.infoText,
      onTertiary: t.bgApp,
      error: t.destText,
      onError: Colors.white,
      errorContainer: t.destBg,
      onErrorContainer: t.destText,
      surface: t.bgApp,
      onSurface: t.textPrimary,
      surfaceContainerLowest: t.bgBase,
      surfaceContainerLow: t.bgSubtle,
      surfaceContainer: t.bgMuted,
      surfaceContainerHigh: t.bgMuted,
      surfaceContainerHighest: t.bgMuted,
      onSurfaceVariant: t.textSecondary,
      outline: t.border,
      outlineVariant: t.borderSubtle,
      shadow: Colors.black,
      scrim: t.scrim,
      inverseSurface: t.textPrimary,
      onInverseSurface: t.bgApp,
      inversePrimary: t.primaryHover,
    );

    final base = ThemeData(useMaterial3: true, brightness: brightness, colorScheme: scheme);
    final textTheme = _textTheme(base.textTheme, t);

    OutlineInputBorder border(Color color, {double width = 1}) => OutlineInputBorder(
      borderRadius: Radii.rMd,
      borderSide: BorderSide(color: color, width: width),
    );

    // Keyboard focus is a 2px ring in the ring colour on every button, never only a fill change.
    final ring = BorderSide(color: t.ring, width: 2);
    WidgetStateProperty<BorderSide?> focusSide([BorderSide? idle]) =>
        WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) ? ring : idle);

    return base.copyWith(
      // the studio board behind every page; cards sit on it translucent
      scaffoldBackgroundColor: t.bgSubtle,
      canvasColor: t.bgApp,
      dividerColor: t.border,
      textTheme: textTheme,
      iconTheme: IconThemeData(color: t.textSecondary, size: Sizes.iconMd),
      appBarTheme: AppBarTheme(
        backgroundColor: t.bgApp,
        foregroundColor: t.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: Sizes.topBar,
        shape: Border(bottom: BorderSide(color: t.border)),
        titleTextStyle: textTheme.titleMedium,
        iconTheme: IconThemeData(color: t.textSecondary, size: Sizes.iconMd),
      ),
      cardTheme: CardThemeData(
        color: t.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: const EdgeInsets.only(bottom: Space.x12),
        shape: RoundedRectangleBorder(
          borderRadius: Radii.rXl,
          side: BorderSide(color: t.cardLine),
        ),
      ),
      dividerTheme: DividerThemeData(color: t.border, thickness: 1, space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style:
            FilledButton.styleFrom(
              // the gradient pill is painted by [_gradientPill]; the Material underneath stays clear
              backgroundColor: Colors.transparent,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.transparent,
              disabledForegroundColor: t.textMuted,
              minimumSize: const Size(0, Sizes.controlMd),
              padding: const EdgeInsets.symmetric(horizontal: Space.x20),
              shape: const StadiumBorder(),
              textStyle: textTheme.labelLarge?.merge(weight(FontWeight.w600)),
            ).copyWith(
              overlayColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.pressed)
                    ? Colors.white.withValues(alpha: 0.12)
                    : (s.contains(WidgetState.hovered) ? Colors.white.withValues(alpha: 0.06) : null),
              ),
              side: focusSide(),
              backgroundBuilder: (context, states, child) => _gradientPill(t, states, child),
            ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style:
            OutlinedButton.styleFrom(
              foregroundColor: t.textPrimary,
              backgroundColor: t.bgApp,
              side: BorderSide(color: t.border),
              minimumSize: const Size(0, Sizes.controlMd),
              padding: const EdgeInsets.symmetric(horizontal: Space.x16),
              shape: const StadiumBorder(),
              textStyle: textTheme.labelLarge,
            ).copyWith(
              side: WidgetStateProperty.resolveWith(
                (s) =>
                    s.contains(WidgetState.focused) ? ring : BorderSide(color: s.contains(WidgetState.hovered) ? t.borderHover : t.border),
              ),
            ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: t.primary,
          minimumSize: const Size(0, Sizes.controlMd),
          shape: const RoundedRectangleBorder(borderRadius: Radii.rMd),
          textStyle: textTheme.labelLarge,
        ).copyWith(side: focusSide()),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: t.textSecondary).copyWith(side: focusSide()),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        // the studio's pill switch: one rounded group on a solid face, the chosen part washed in magenta
        style: SegmentedButton.styleFrom(
          foregroundColor: t.textSecondary,
          backgroundColor: t.bgApp,
          selectedForegroundColor: t.primary,
          selectedBackgroundColor: t.primarySubtle,
          side: BorderSide(color: t.border),
          shape: const StadiumBorder(),
          textStyle: textTheme.labelLarge,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.bgApp,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.x10, vertical: Space.x10),
        border: border(t.border),
        enabledBorder: border(t.border),
        disabledBorder: border(t.borderSubtle),
        focusedBorder: border(t.ring, width: 2),
        errorBorder: border(t.destDot),
        focusedErrorBorder: border(t.destDot, width: 2),
        hoverColor: t.bgHover,
        labelStyle: textTheme.bodyMedium?.copyWith(color: t.textSecondary),
        floatingLabelStyle: textTheme.bodySmall?.copyWith(color: t.primary),
        hintStyle: textTheme.bodyMedium?.copyWith(color: t.textMuted),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: t.bgApp,
        surfaceTintColor: Colors.transparent,
        indicatorColor: t.primarySubtle,
        elevation: 0,
        height: 64,
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? t.primary : t.textSecondary, size: Sizes.iconLg),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => textTheme.labelMedium?.copyWith(color: s.contains(WidgetState.selected) ? t.primary : t.textSecondary),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: t.textSecondary,
        textColor: t.textPrimary,
        subtitleTextStyle: textTheme.bodySmall?.copyWith(color: t.textSecondary),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : t.textSecondary),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.accentFill : t.bgMuted),
        trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.primary : t.border),
      ),
      checkboxTheme: CheckboxThemeData(
        side: BorderSide(color: t.border, width: 1.5),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.accentFill : null),
        checkColor: const WidgetStatePropertyAll(Colors.white),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: t.primary, circularTrackColor: t.bgMuted, linearTrackColor: t.bgMuted),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.primary : t.textSecondary),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: t.primary,
        inactiveTrackColor: t.bgMuted,
        thumbColor: t.primary,
        overlayColor: t.primarySubtle,
        valueIndicatorColor: t.textPrimary,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: t.bgApp,
        selectedColor: t.primarySubtle,
        disabledColor: t.bgMuted,
        side: BorderSide(color: t.border),
        labelStyle: textTheme.labelMedium?.copyWith(color: t.textPrimary),
        secondaryLabelStyle: textTheme.labelMedium?.copyWith(color: t.primary),
        checkmarkColor: t.primary,
        shape: const RoundedRectangleBorder(borderRadius: Radii.rFull),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.bgApp,
        modalBackgroundColor: t.bgApp,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: t.border,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl))),
      ),
      drawerTheme: DrawerThemeData(backgroundColor: t.bgApp, surfaceTintColor: Colors.transparent, scrimColor: t.scrim),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(t.scrollbar),
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(4),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: t.bgApp,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: t.bgSubtle,
        headerForegroundColor: t.textPrimary,
        todayBorder: BorderSide(color: t.primary),
        todayForegroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : t.primary),
        dayForegroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : t.textPrimary),
        dayBackgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.accentFill : null),
        shape: RoundedRectangleBorder(
          borderRadius: Radii.rLg,
          side: BorderSide(color: t.border),
        ),
      ),
      badgeTheme: BadgeThemeData(backgroundColor: t.accentFill, textColor: Colors.white),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: t.textSecondary,
        collapsedIconColor: t.textSecondary,
        textColor: t.textPrimary,
        collapsedTextColor: t.textPrimary,
        shape: const Border(),
        collapsedShape: const Border(),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: t.bgApp,
        surfaceTintColor: Colors.transparent,
        textStyle: textTheme.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.rMd,
          side: BorderSide(color: t.border),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(t.bgApp),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          side: WidgetStatePropertyAll(BorderSide(color: t.border)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.bgApp,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.rXl,
          side: BorderSide(color: t.border),
        ),
        titleTextStyle: textTheme.titleMedium,
        contentTextStyle: textTheme.bodyMedium,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(textStyle: textTheme.bodyMedium),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.textPrimary,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: t.bgApp),
        shape: const RoundedRectangleBorder(borderRadius: Radii.rMd),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: t.textPrimary, borderRadius: Radii.rSm),
        textStyle: textTheme.bodySmall?.copyWith(color: t.bgApp),
      ),
      splashFactory: NoSplash.splashFactory,
      hoverColor: t.bgHover,
      focusColor: t.selected,
      highlightColor: t.selected,
    );
  }

  /// The primary button's fill: the brand gradient as a pill, a magenta glow under it on hover or focus,
  /// a quiet well when disabled.
  static Widget _gradientPill(PortalTokens t, Set<WidgetState> states, Widget? child) {
    final off = states.contains(WidgetState.disabled);
    final pressed = !off && states.contains(WidgetState.pressed);
    final hot = !off && states.contains(WidgetState.hovered);
    // the pill covers the Material, so the focus ring is drawn here, outside it with a gap, as the studio draws it
    final focused = !off && states.contains(WidgetState.focused);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: off || pressed ? null : PortalTokens.brand,
        color: off ? t.bgMuted : (pressed ? PortalTokens.brandPressed : null),
        borderRadius: Radii.rFull,
        boxShadow: focused
            ? [BoxShadow(color: t.bgSubtle, spreadRadius: 2), BoxShadow(color: t.ring, spreadRadius: 4)]
            : (hot ? PortalTokens.buttonGlow : null),
      ),
      child: child,
    );
  }

  /// A destructive [FilledButton]: the red pill (the theme's gradient builder would otherwise paint over any colour).
  static ButtonStyle destructive(PortalTokens t) => FilledButton.styleFrom(foregroundColor: Colors.white).copyWith(
    backgroundBuilder: (context, states, child) => DecoratedBox(
      decoration: BoxDecoration(
        color: states.contains(WidgetState.disabled) ? t.bgMuted : PortalTokens.destFill,
        borderRadius: Radii.rFull,
        boxShadow: states.contains(WidgetState.focused)
            ? [BoxShadow(color: t.bgSubtle, spreadRadius: 2), BoxShadow(color: t.ring, spreadRadius: 4)]
            : null,
      ),
      child: child,
    ),
  );

  /// Plus Jakarta Sans on every slot, weights pushed through the `wght` axis,
  /// sizes literal (no Material scaling), neutral colours from the tokens.
  static TextTheme _textTheme(TextTheme base, PortalTokens t) {
    TextStyle style(TextStyle? s, double size, FontWeight w, {Color? color, double height = 1.4}) => (s ?? const TextStyle()).copyWith(
      fontFamily: PortalType.familyUi,
      fontSize: size,
      fontWeight: w,
      fontVariations: [FontVariation('wght', w.value.toDouble())],
      fontFeatures: const [FontFeature.tabularFigures()],
      color: color ?? t.textPrimary,
      height: height,
      // headings sit a touch tighter (-0.015em), the way the studio sets them
      letterSpacing: size >= 18 ? -0.015 * size : 0,
    );
    return TextTheme(
      displayLarge: style(base.displayLarge, 40, FontWeight.w700, height: 1.1),
      displayMedium: style(base.displayMedium, 32, FontWeight.w700, height: 1.15),
      displaySmall: style(base.displaySmall, 28, FontWeight.w600, height: 1.2),
      headlineLarge: style(base.headlineLarge, 24, FontWeight.w600, height: 1.25),
      headlineMedium: style(base.headlineMedium, 24, FontWeight.w600, height: 1.2),
      headlineSmall: style(base.headlineSmall, 18, FontWeight.w600, height: 1.3),
      titleLarge: style(base.titleLarge, 16, FontWeight.w600),
      titleMedium: style(base.titleMedium, 15, FontWeight.w600),
      titleSmall: style(base.titleSmall, 13, FontWeight.w600),
      bodyLarge: style(base.bodyLarge, 15, FontWeight.w400, height: 1.5),
      bodyMedium: style(base.bodyMedium, 14, FontWeight.w400, height: 1.5),
      bodySmall: style(base.bodySmall, 12, FontWeight.w400, color: t.textSecondary),
      labelLarge: style(base.labelLarge, 14, FontWeight.w500),
      labelMedium: style(base.labelMedium, 12, FontWeight.w500, color: t.textSecondary),
      labelSmall: style(base.labelSmall, 11, FontWeight.w500, color: t.textSecondary),
    );
  }
}

/// The four semantic families. Red is for failure only; never magenta.
enum StatusKind { success, info, warn, dest }

/// Maps the backend's verdict / earning / task status strings onto a family.
/// Unknown strings read as [StatusKind.info] so a new status never paints red.
StatusKind statusKindFor(String status) => switch (status.toLowerCase()) {
  'accept' || 'accepted' || 'paid' || 'judged' || 'approved' || 'done' => StatusKind.success,
  'needs_edits' || 'held' || 'hold' || 'on_hold' || 'pending' || 'expired' => StatusKind.warn,
  'reject' || 'rejected' || 'failed' || 'error' => StatusKind.dest,
  _ => StatusKind.info,
};

/// A small dot-plus-text status chip. Colour is never the only signal: the
/// label carries the meaning, the dot only reinforces it.
class StatusChip extends StatelessWidget {
  const StatusChip(this.label, {super.key, required this.kind});

  /// Chip for a raw status string, mapped through [statusKindFor].
  StatusChip.status(String status, {Key? key, String? label})
    : this(label ?? status.replaceAll('_', ' '), key: key, kind: statusKindFor(status));

  final String label;
  final StatusKind kind;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final (text, bg, dot) = switch (kind) {
      StatusKind.success => (t.successText, t.successBg, t.successDot),
      StatusKind.info => (t.infoText, t.infoBg, t.infoDot),
      StatusKind.warn => (t.warnText, t.warnBg, t.warnDot),
      StatusKind.dest => (t.destText, t.destBg, t.destDot),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.x8, vertical: Space.x2),
      decoration: BoxDecoration(color: bg, borderRadius: Radii.rFull),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: Space.x6),
          Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: text)),
        ],
      ),
    );
  }
}

/// A full-width notice panel in one status family (used for inline results
/// such as "verdict recorded" or an error above a form).
class StatusBanner extends StatelessWidget {
  const StatusBanner(this.message, {super.key, required this.kind, this.icon});
  final String message;
  final StatusKind kind;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final (text, bg, dot) = switch (kind) {
      StatusKind.success => (t.successText, t.successBg, t.successDot),
      StatusKind.info => (t.infoText, t.infoBg, t.infoDot),
      StatusKind.warn => (t.warnText, t.warnBg, t.warnDot),
      StatusKind.dest => (t.destText, t.destBg, t.destDot),
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: Space.x12),
      padding: const EdgeInsets.all(Space.x12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: Radii.rMd,
        border: Border.all(color: dot.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[Icon(icon, size: Sizes.iconSm, color: dot), const SizedBox(width: Space.x8)],
          Expanded(child: _MessageLines(message, color: text)),
        ],
      ),
    );
  }
}

/// A message and, for staff, its smaller "Details" line (see `describeError`).
class _MessageLines extends StatelessWidget {
  const _MessageLines(this.message, {required this.color});
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (line, details) = splitDetails(message);
    final main = Text(line, style: theme.textTheme.bodyMedium?.copyWith(color: color));
    if (details == null) return main;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        main,
        const SizedBox(height: Space.x4),
        Text(
          'Details: $details',
          key: const Key('error-details'),
          style: theme.textTheme.bodySmall?.copyWith(color: color),
        ),
      ],
    );
  }
}
