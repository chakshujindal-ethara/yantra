import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/core/theme/portal_tokens.dart';
import 'package:yantra_app/core/widgets/cards.dart';

void main() {
  test('the light theme is built from the light tokens', () {
    final theme = AppTheme.light;
    const t = PortalTokens.light;
    expect(theme.brightness, Brightness.light);
    expect(theme.colorScheme.primary, t.primary);
    expect(theme.colorScheme.primary, const Color(0xFFA800A8), reason: "the studio's accent text on the board");
    expect(theme.colorScheme.surface, t.bgApp);
    expect(theme.colorScheme.surfaceContainer, t.bgMuted);
    expect(theme.colorScheme.outline, t.border);
    expect(theme.colorScheme.onSurface, t.textPrimary);
    expect(theme.colorScheme.onSurfaceVariant, t.textSecondary);
    expect(theme.colorScheme.error, t.destText);
    expect(theme.scaffoldBackgroundColor, t.bgSubtle, reason: 'pages sit on the studio board');
    expect(theme.appBarTheme.backgroundColor, t.bgApp);
    expect(theme.cardTheme.color, t.card);
    expect(PortalTokens.light.card.a, 1, reason: 'light cards are solid: a translucent fill shows its own shadow through');
    expect(PortalTokens.dark.card.a, lessThan(0.1), reason: 'dark cards are a faint glass on the board');
  });

  test('the dark theme is built from the dark tokens', () {
    final theme = AppTheme.dark;
    const t = PortalTokens.dark;
    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, t.primary);
    expect(theme.colorScheme.primary, const Color(0xFFF07EF0));
    expect(theme.colorScheme.surface, t.bgApp);
    expect(theme.colorScheme.outline, t.border);
    expect(theme.colorScheme.error, t.destText);
  });

  test('text runs in Plus Jakarta Sans with the weight on the wght axis', () {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      final body = theme.textTheme.bodyMedium;
      expect(body?.fontFamily, 'Plus Jakarta Sans');
      expect(theme.textTheme.titleMedium?.fontFamily, 'Plus Jakarta Sans');
      expect(theme.textTheme.titleMedium?.fontVariations, [const FontVariation('wght', 600)]);
    }
    expect(AppTheme.weight(FontWeight.w600).fontVariations, [const FontVariation('wght', 600)]);
  });

  testWidgets('ids and JSON use DM Mono; status chips use the semantic families', (tester) async {
    late TextStyle mono;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (context) {
            mono = AppTheme.mono(context);
            return Column(
              children: [
                StatusChip.status('accepted', key: const Key('accepted')),
                StatusChip.status('needs_edits', key: const Key('needs_edits')),
                StatusChip.status('rejected', key: const Key('rejected')),
                StatusChip.status('held', key: const Key('held')),
                StatusChip.status('paid', key: const Key('paid')),
                StatusChip.status('something_new', key: const Key('new')),
              ],
            );
          },
        ),
      ),
    );
    expect(mono.fontFamily, 'DM Mono');
    expect(find.text('needs edits'), findsOneWidget);
    StatusKind kindOf(String key) => tester.widget<StatusChip>(find.byKey(Key(key))).kind;
    expect(kindOf('accepted'), StatusKind.success);
    expect(kindOf('needs_edits'), StatusKind.warn);
    expect(kindOf('rejected'), StatusKind.dest);
    expect(kindOf('held'), StatusKind.warn);
    expect(kindOf('paid'), StatusKind.success);
    expect(kindOf('new'), StatusKind.info);
  });

  test('every Material surface the screens use is themed from the tokens, in both modes', () {
    for (final (theme, t) in [(AppTheme.light, PortalTokens.light), (AppTheme.dark, PortalTokens.dark)]) {
      expect(theme.radioTheme.fillColor?.resolve({WidgetState.selected}), t.primary);
      expect(theme.sliderTheme.activeTrackColor, t.primary);
      expect(theme.sliderTheme.inactiveTrackColor, t.bgMuted);
      expect(theme.chipTheme.backgroundColor, t.bgApp);
      expect(theme.chipTheme.selectedColor, t.primarySubtle);
      expect(theme.bottomSheetTheme.backgroundColor, t.bgApp);
      expect(theme.drawerTheme.backgroundColor, t.bgApp);
      expect(theme.scrollbarTheme.thumbColor?.resolve({}), t.scrollbar);
      expect(theme.datePickerTheme.backgroundColor, t.bgApp);
      expect(theme.datePickerTheme.todayBorder?.color, t.primary);
      expect(theme.badgeTheme.backgroundColor, t.accentFill, reason: 'white numbers need the solid fill');
      expect(theme.expansionTileTheme.iconColor, t.textSecondary);
      expect(theme.popupMenuTheme.color, t.bgApp);
      expect(theme.menuTheme.style?.backgroundColor?.resolve({}), t.bgApp);
    }
  });

  test('a focused button shows a 2px ring in the ring colour; an idle one does not', () {
    for (final (theme, t) in [(AppTheme.light, PortalTokens.light), (AppTheme.dark, PortalTokens.dark)]) {
      for (final style in [
        theme.filledButtonTheme.style!,
        theme.outlinedButtonTheme.style!,
        theme.textButtonTheme.style!,
        theme.iconButtonTheme.style!,
      ]) {
        final focused = style.side?.resolve({WidgetState.focused});
        expect(focused?.color, t.ring);
        expect(focused?.width, 2);
      }
      expect(theme.filledButtonTheme.style!.side?.resolve({}), isNull);
      expect(theme.outlinedButtonTheme.style!.side?.resolve({})?.color, t.border);
    }
  });

  test('white text passes WCAG AA on every point of the brand gradient', () {
    double contrast(Color a, Color b) {
      final (la, lb) = (a.computeLuminance(), b.computeLuminance());
      return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
    }

    for (final stop in PortalTokens.brand.colors) {
      expect(contrast(Colors.white, stop), greaterThanOrEqualTo(4.5), reason: '$stop');
    }
    for (final t in [PortalTokens.light, PortalTokens.dark]) {
      expect(contrast(t.primary, t.bgSubtle), greaterThanOrEqualTo(4.5), reason: 'accent text on the board');
      expect(contrast(t.textMuted, t.bgSubtle), greaterThanOrEqualTo(4.5), reason: 'quiet text on the board');
    }
  });

  testWidgets('a primary button is the gradient pill; a disabled one is a quiet well', (tester) async {
    Finder pill(String key) => find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byWidgetPredicate(
        (w) => w is DecoratedBox && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).borderRadius == Radii.rFull,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Column(
            children: [
              FilledButton(key: const Key('on'), onPressed: () {}, child: const Text('Go')),
              const FilledButton(key: Key('off'), onPressed: null, child: Text('Wait')),
            ],
          ),
        ),
      ),
    );
    final on = tester.widget<DecoratedBox>(pill('on')).decoration as BoxDecoration;
    expect(on.gradient, PortalTokens.brand);
    final off = tester.widget<DecoratedBox>(pill('off')).decoration as BoxDecoration;
    expect(off.gradient, isNull);
    expect(off.color, PortalTokens.light.bgMuted);
    expect(tester.widget<FilledButton>(find.byKey(const Key('on'))).style, isNull, reason: 'the look comes from the theme');
    expect(AppTheme.light.filledButtonTheme.style?.shape?.resolve({}), isA<StadiumBorder>());
  });

  test('in dark mode every fill that carries white content passes AA, and onPrimary reads on primary', () {
    double contrast(Color a, Color b) {
      final (la, lb) = (a.computeLuminance(), b.computeLuminance());
      return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
    }

    for (final (theme, t) in [(AppTheme.light, PortalTokens.light), (AppTheme.dark, PortalTokens.dark)]) {
      final s = theme.colorScheme;
      expect(contrast(s.onPrimary, s.primary), greaterThanOrEqualTo(4.5), reason: 'onPrimary on primary, dark=${t.isDark}');
      expect(contrast(Colors.white, theme.badgeTheme.backgroundColor!), greaterThanOrEqualTo(4.5), reason: 'badge');
      expect(
        contrast(Colors.white, theme.checkboxTheme.fillColor!.resolve({WidgetState.selected})!),
        greaterThanOrEqualTo(3),
        reason: 'tick',
      );
      expect(contrast(Colors.white, theme.datePickerTheme.dayBackgroundColor!.resolve({WidgetState.selected})!), greaterThanOrEqualTo(4.5));
      expect(contrast(Colors.white, t.accentFill), greaterThanOrEqualTo(4.5));
    }
  });

  testWidgets('a focused primary button shows the ring outside the pill; a pressed one darkens', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Center(
            child: FilledButton(key: const Key('on'), focusNode: focus, onPressed: () {}, child: const Text('Go')),
          ),
        ),
      ),
    );
    BoxDecoration pill() =>
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: find.byKey(const Key('on')),
                    matching: find.byWidgetPredicate(
                      (w) =>
                          w is DecoratedBox && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).borderRadius == Radii.rFull,
                    ),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(pill().boxShadow, isNull);
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(pill().boxShadow?.map((s) => s.color), contains(PortalTokens.light.ring));
  });

  testWidgets('a destructive confirm is a red pill, never the brand gradient', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (c) {
            ctx = c;
            return const Scaffold();
          },
        ),
      ),
    );
    final answer = confirm(
      ctx,
      title: 'Withdraw consent?',
      body: 'You cannot claim until you give it again.',
      confirmLabel: 'Withdraw',
      destructive: true,
    );
    await tester.pumpAndSettle();
    final button = find.ancestor(of: find.text('Withdraw'), matching: find.byType(FilledButton));
    final pill =
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: button,
                    matching: find.byWidgetPredicate(
                      (w) =>
                          w is DecoratedBox && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).borderRadius == Radii.rFull,
                    ),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(pill.gradient, isNull);
    expect(pill.color, PortalTokens.destFill);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(await answer, isTrue);
  });

  testWidgets('figures are the UI face with tabular digits; ids stay DM Mono', (tester) async {
    late TextStyle figure;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (context) {
            figure = AppTheme.figure(context, fontSize: 14);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(figure.fontFamily, 'Plus Jakarta Sans');
    expect(figure.fontFeatures, contains(const FontFeature.tabularFigures()));
    expect(figure.fontVariations, [const FontVariation('wght', 500)]);
  });

  testWidgets('a KPI tile wears its status colour as the bar and the dot; a plain count wears the brand', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(
          body: Column(
            children: [
              KpiTile(key: Key('dest'), label: 'Failed', value: '2', kind: StatusKind.dest),
              KpiTile(key: Key('plain'), label: 'Open', value: '8'),
            ],
          ),
        ),
      ),
    );
    Color barOf(String key) {
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byKey(Key(key)),
              matching: find.byWidgetPredicate(
                (w) => w is DecoratedBox && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).border != null,
              ),
            )
            .first,
      );
      return ((box.decoration as BoxDecoration).border! as Border).left.color;
    }

    expect(barOf('dest'), PortalTokens.light.destDot);
    expect(barOf('plain'), PortalTokens.brandSolid);
  });

  testWidgets('a focused destructive button shows the ring too; a disabled one is a quiet well', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    const t = PortalTokens.light;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Column(
            children: [
              FilledButton(
                key: const Key('red'),
                focusNode: focus,
                style: AppTheme.destructive(t),
                onPressed: () {},
                child: const Text('Delete'),
              ),
              FilledButton(key: const Key('red-off'), style: AppTheme.destructive(t), onPressed: null, child: const Text('Delete')),
            ],
          ),
        ),
      ),
    );
    BoxDecoration pill(String key) =>
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: find.byKey(Key(key)),
                    matching: find.byWidgetPredicate(
                      (w) =>
                          w is DecoratedBox && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).borderRadius == Radii.rFull,
                    ),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(pill('red-off').color, t.bgMuted);
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(pill('red').color, PortalTokens.destFill);
    expect(pill('red').boxShadow?.map((s) => s.color), contains(t.ring));
  });
}
