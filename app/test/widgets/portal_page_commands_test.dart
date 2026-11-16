import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:yantra_app/core/page_commands.dart';
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/core/widgets/portal_page.dart';

void main() {
  testWidgets('a page registers its commands under its location while mounted, and drops them after', (tester) async {
    final registry = PageCommands();
    final commands = [PageCommand('New batch', Icons.add, () {})];
    final router = GoRouter(
      initialLocation: '/a',
      routes: [
        GoRoute(
          path: '/a',
          builder: (_, _) => PortalPage(title: 'A', footer: const Text('sticky'), commands: commands, children: const []),
        ),
        GoRoute(
          path: '/b',
          builder: (_, _) => const PortalPage(title: 'B', children: []),
        ),
      ],
    );
    await tester.pumpWidget(
      PageCommandsScope(
        commands: registry,
        child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(registry.at('/a'), same(commands));
    expect(find.text('sticky'), findsOneWidget);
    router.go('/b');
    await tester.pumpAndSettle();
    expect(registry.at('/a'), isEmpty);
  });

  testWidgets('outside a route a page with commands still renders and registers nothing', (tester) async {
    final registry = PageCommands();
    await tester.pumpWidget(
      PageCommandsScope(
        commands: registry,
        child: MaterialApp(
          theme: AppTheme.light,
          home: PortalPage(title: 'Alone', commands: [PageCommand('Refresh', Icons.refresh, () {})], children: const []),
        ),
      ),
    );
    expect(find.text('Alone'), findsOneWidget);
    expect(registry.at('/'), isEmpty);
  });
}
