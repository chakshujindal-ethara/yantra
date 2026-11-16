import 'package:flutter/material.dart';

import '../format.dart';
import '../theme/app_theme.dart';
import '../theme/portal_tokens.dart';
import 'tappable.dart';

/// A raised card on the page backdrop. Tappable cards get hover, focus ring and keyboard activation
/// from the InkWell; never paint a colour literal in a screen.
class PortalCard extends StatelessWidget {
  const PortalCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Space.x16),
    this.onTap,
    this.color,
    this.borderColor,
    this.margin = const EdgeInsets.only(bottom: Space.x12),
    this.emphasis = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final Color? borderColor;
  final EdgeInsetsGeometry margin;

  /// Magenta-washed: the one card that asks for attention (a live claim, a pending action).
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final bg = color ?? (emphasis ? t.primarySubtle : t.card);
    final line = borderColor ?? (emphasis ? t.borderHover : t.cardLine);
    final body = Padding(padding: padding, child: child);
    // the studio's glass card: translucent on the board, a hairline, 18px corners, a soft tinted lift
    return Padding(
      padding: margin,
      child: DecoratedBox(
        decoration: BoxDecoration(borderRadius: Radii.rXl, boxShadow: t.isDark ? null : t.shadowCard),
        child: Material(
          color: bg,
          shape: RoundedRectangleBorder(
            borderRadius: Radii.rXl,
            side: BorderSide(color: line),
          ),
          clipBehavior: Clip.antiAlias,
          child: onTap == null ? body : PortalTappable(onTap: onTap, borderRadius: Radii.rXl, child: body),
        ),
      ),
    );
  }
}

/// A section heading inside a page: title at the left, an optional action at the right.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing, this.subtitle});

  final String text;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Space.x8, bottom: Space.x12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: theme.textTheme.titleLarge),
                if (subtitle != null) Text(subtitle!, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// One figure a worker cares about. A dot and the label, the value large in the UI face, a one-line note. With [onTap]
/// the tile opens the page behind the figure: an arrow shows it, the tile lifts on hover, and assistive
/// tech hears a button.
class KpiTile extends StatefulWidget {
  const KpiTile({super.key, required this.label, required this.value, this.note, this.kind, this.icon, this.onTap});

  final String label;
  final String value;
  final String? note;

  /// Tints the note (and the icon) in a status family; the value itself stays neutral.
  final StatusKind? kind;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  State<KpiTile> createState() => _KpiTileState();
}

class _KpiTileState extends State<KpiTile> {
  bool _hover = false;

  String get label => widget.label;
  String get value => widget.value;
  String? get note => widget.note;
  StatusKind? get kind => widget.kind;
  IconData? get icon => widget.icon;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final tint = switch (kind) {
      StatusKind.success => t.successText,
      StatusKind.info => t.infoText,
      StatusKind.warn => t.warnText,
      StatusKind.dest => t.destText,
      null => t.textSecondary,
    };
    // the bar and the dot: the status family's dot colour, the brand magenta for a plain count
    final accent = switch (kind) {
      StatusKind.success => t.successDot,
      StatusKind.info => t.infoDot,
      StatusKind.warn => t.warnDot,
      StatusKind.dest => t.destDot,
      null => PortalTokens.brandSolid,
    };
    final open = widget.onTap;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      container: true,
      button: open != null,
      label: note == null ? '$label, $value' : '$label, $value. $note',
      onTap: open, // the child's tap is excluded with its text, so the node carries it
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: open == null ? null : (_) => setState(() => _hover = true),
        onExit: open == null ? null : (_) => setState(() => _hover = false),
        child: AnimatedSlide(
          duration: reduce ? Duration.zero : const Duration(milliseconds: 120),
          offset: _hover ? const Offset(0, -0.02) : Offset.zero,
          child: PortalCard(
            margin: EdgeInsets.zero,
            onTap: open,
            padding: EdgeInsets.zero,
            borderColor: _hover ? t.borderHover : null,
            // the studio's KPI card: a coloured bar down the left edge, a wash of the same colour fading
            // right, a dot before the label, the figure large in the UI face
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    accent.withValues(alpha: t.isDark ? 0.10 : 0.07),
                    accent.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.7],
                ),
                border: Border(left: BorderSide(color: accent, width: 3)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Space.x16, Space.x16, Space.x16, Space.x16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: Space.x8),
                        Expanded(
                          child: Text(label, style: theme.textTheme.labelLarge?.copyWith(color: t.textPrimary)),
                        ),
                        if (icon != null) Icon(icon, size: Sizes.iconSm, color: tint),
                        if (open != null) ...[
                          const SizedBox(width: Space.x4),
                          Icon(Icons.arrow_forward, size: Sizes.iconSm, color: _hover ? t.primary : t.textSecondary),
                        ],
                      ],
                    ),
                    const SizedBox(height: Space.x8),
                    Text(
                      value,
                      style: theme.textTheme.displaySmall
                          ?.copyWith(fontSize: 28, height: 1.1, color: t.textPrimary)
                          .merge(AppTheme.weight(FontWeight.w500)),
                    ),
                    if (note != null) ...[
                      const SizedBox(height: Space.x6),
                      Text(
                        note!,
                        style: theme.textTheme.bodySmall?.copyWith(color: kind == null ? t.textSecondary : tint),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// KPI tiles in a row that becomes a 2-column grid under [narrowBelow] and a single column under 360.
class KpiRow extends StatelessWidget {
  const KpiRow({super.key, required this.children, this.narrowBelow = 720});

  final List<Widget> children;
  final double narrowBelow;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final columns = c.maxWidth < 360 ? 1 : (c.maxWidth < narrowBelow ? 2 : children.length.clamp(1, 4));
        final width = (c.maxWidth - Space.x12 * (columns - 1)) / columns;
        return Padding(
          padding: const EdgeInsets.only(bottom: Space.x16),
          child: Wrap(
            spacing: Space.x12,
            runSpacing: Space.x12,
            children: [for (final child in children) SizedBox(width: width, child: child)],
          ),
        );
      },
    );
  }
}

/// `label` over `value`; ids and codes in mono.
class LabelValue extends StatelessWidget {
  const LabelValue({super.key, required this.label, required this.value, this.mono = false, this.selectable = false});

  final String label;
  final String value;
  final bool mono;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = mono ? AppTheme.mono(context, fontSize: 13) : theme.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.x6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: Space.x2),
          selectable ? SelectableText(value, style: style) : Text(value, style: style),
        ],
      ),
    );
  }
}

/// A small circle with the person's initials; magenta wash so it reads as the brand's "you".
class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.size = 32});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.primarySubtle,
        shape: BoxShape.circle,
        border: Border.all(color: t.primary.withValues(alpha: 0.55), width: 1.5),
      ),
      child: Text(
        initials(name),
        style: TextStyle(
          fontFamily: PortalType.familyUi,
          color: t.primary,
          fontSize: size * 0.38,
          fontWeight: FontWeight.w600,
          fontVariations: const [FontVariation('wght', 600)],
        ),
      ),
    );
  }
}

/// A checklist line: a done or pending mark, a title, a one-line hint and an optional action.
class ChecklistRow extends StatelessWidget {
  const ChecklistRow({super.key, required this.done, required this.title, this.hint, this.action, this.pending = false});

  final bool done;

  /// Neither done nor blocked: waiting on someone else (shown in the info family).
  final bool pending;
  final String title;
  final String? hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final (icon, color) = done
        ? (Icons.check_circle, t.successDot)
        : pending
        ? (Icons.schedule, t.infoDot)
        : (Icons.radio_button_unchecked, t.textMuted);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.x8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: Sizes.iconMd, color: color),
          ),
          const SizedBox(width: Space.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium?.copyWith(color: done ? t.textSecondary : t.textPrimary)),
                if (hint != null) Text(hint!, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: Space.x12), action!],
        ],
      ),
    );
  }
}

/// A labelled proportion bar. Measured with a LayoutBuilder, never flexed, so it always paints.
class ProgressRow extends StatelessWidget {
  const ProgressRow({
    super.key,
    required this.label,
    required this.value,
    required this.total,
    this.kind = StatusKind.success,
    this.trailing,
  });

  final String label;
  final double value;
  final double total;
  final StatusKind kind;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final fill = switch (kind) {
      StatusKind.success => t.successDot,
      StatusKind.info => t.infoDot,
      StatusKind.warn => t.warnDot,
      StatusKind.dest => t.destDot,
    };
    final fraction = total <= 0 ? 0.0 : (value / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.x6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
              Text(trailing ?? '${(fraction * 100).round()}%', style: AppTheme.figure(context, fontSize: 12, color: t.textSecondary)),
            ],
          ),
          const SizedBox(height: Space.x6),
          LayoutBuilder(
            builder: (context, c) => Stack(
              children: [
                Container(
                  height: 6,
                  width: c.maxWidth,
                  decoration: BoxDecoration(color: t.bgMuted, borderRadius: Radii.rFull),
                ),
                Container(
                  height: 6,
                  width: c.maxWidth * fraction,
                  decoration: BoxDecoration(color: fill, borderRadius: Radii.rFull),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Grey placeholder blocks while a page loads. Static (no shimmer), so reduced-motion users get the same.
class Skeleton extends StatelessWidget {
  const Skeleton({super.key, this.lines = 3, this.height = 14});

  final int lines;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < lines; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.x10),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: i == lines - 1 ? 0.6 : 1,
              child: Container(
                height: height,
                decoration: BoxDecoration(color: t.skeleton, borderRadius: Radii.rSm),
              ),
            ),
          ),
      ],
    );
  }
}

/// A short confirmation dialog. Returns true when confirmed.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String body,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final t = PortalTokens.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? AppTheme.destructive(t) : null,
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// An icon and one short fact ("15 minutes", "3 attempts left"). [mono] for figures and ids; [expand] lets
/// the text wrap inside a column instead of sizing to its content.
class Fact extends StatelessWidget {
  const Fact({super.key, required this.icon, required this.text, this.mono = false, this.expand = false});
  final IconData icon;
  final String text;
  final bool mono;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final label = Text(
      text,
      style: mono ? AppTheme.mono(context, fontSize: 12, color: t.textSecondary) : Theme.of(context).textTheme.bodySmall,
    );
    return Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      children: [
        Icon(icon, size: Sizes.iconSm, color: t.textMuted),
        const SizedBox(width: Space.x6),
        expand ? Expanded(child: label) : label,
      ],
    );
  }
}
