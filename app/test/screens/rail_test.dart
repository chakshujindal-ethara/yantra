import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_backend.dart';

double sidebarWidth(WidgetTester tester) => tester.getSize(find.byKey(const Key('sidebar'))).width;

Finder navLabel(String text) => find.descendant(of: find.byKey(const Key('sidebar')), matching: find.text(text));

void main() {
  for (final width in [1100.0, 1440.0]) {
    testWidgets('at $width the side menu is the 64px rail; it opens to 252 over the page on hover', (tester) async {
      await pumpApp(tester, FakeBackend(), size: Size(width, 900), roles: ['ops', 'finance']);
      expect(sidebarWidth(tester), 64);
      expect(navLabel('Projects'), findsNothing, reason: 'icon chips only while folded');
      expect(find.bySemanticsLabel('Projects'), findsOneWidget, reason: 'assistive tech still hears the name');
      final pageLeft = tester.getTopLeft(find.byKey(const Key('page-title'))).dx;

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1000, 400));
      await tester.pump();
      await mouse.moveTo(const Offset(30, 400));
      await tester.pumpAndSettle();
      expect(sidebarWidth(tester), 252);
      expect(navLabel('Projects'), findsOneWidget);
      expect(navLabel('OPERATE'), findsOneWidget, reason: 'group labels show once it opens');
      expect(tester.getTopLeft(find.byKey(const Key('page-title'))).dx, pageLeft, reason: 'the open rail covers the page; nothing moves');

      await mouse.moveTo(const Offset(800, 400));
      await tester.pumpAndSettle();
      expect(sidebarWidth(tester), 64);
      await mouse.removePointer();
    });
  }

  testWidgets('choosing a link folds the rail at once, though the pointer is still on it', (tester) async {
    await pumpApp(tester, FakeBackend(), size: const Size(1440, 900), roles: ['ops', 'finance']);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1000, 400));
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(const Offset(30, 400));
    await tester.pumpAndSettle();
    expect(sidebarWidth(tester), 252);
    await tester.tap(find.byKey(const Key('nav-papers')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/ops/papers');
    expect(sidebarWidth(tester), 64, reason: 'folded after the pick');
    // it opens on hover again once the pointer has left
    await mouse.moveTo(const Offset(800, 400));
    await tester.pumpAndSettle();
    await mouse.moveTo(const Offset(30, 300));
    await tester.pumpAndSettle();
    expect(sidebarWidth(tester), 252);
  });

  testWidgets('a folded rail link is tappable where it is drawn', (tester) async {
    await pumpApp(tester, FakeBackend(), size: const Size(1440, 900), roles: ['ops', 'finance']);
    final link = find.byKey(const Key('nav-papers'));
    expect(tester.getCenter(link).dx, lessThan(64));
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/ops/papers');
  });

  testWidgets('keyboard focus inside the rail opens it; a nav row still navigates', (tester) async {
    await pumpApp(tester, FakeBackend(), size: const Size(1100, 900), roles: ['ops', 'finance']);
    for (var i = 0; i < 40 && sidebarWidth(tester) == 64; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }
    expect(sidebarWidth(tester), 252, reason: 'tabbing reaches the rail and opens it');
    // the next row (the first is the page you are on) is chosen with Enter: the page changes, the rail folds
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(currentLocation(tester), isNot('/ops/overview'), reason: 'Enter chose a page');
    expect(sidebarWidth(tester), 64, reason: 'a keyboard pick folds the rail too');
  });

  testWidgets('the rail renders in dark mode and passes the accessibility checks, folded and open', (tester) async {
    await pumpApp(tester, FakeBackend(), size: const Size(1100, 900), roles: ['client'], dark: true);
    expect(tester.takeException(), isNull);
    expect(sidebarWidth(tester), 64);
    await pumpApp(tester, FakeBackend(), size: const Size(1100, 900), roles: ['client']);
    await expectAccessible(tester);
    await openRail(tester);
    expect(tester.takeException(), isNull);
    await expectAccessible(tester);
  });

  testWidgets('the open rail passes the accessibility checks in dark mode', (tester) async {
    await pumpApp(tester, FakeBackend(), size: const Size(1100, 900), roles: ['client'], dark: true);
    await openRail(tester);
    expect(tester.takeException(), isNull);
    await expectAccessible(tester);
  });

  testWidgets('the names fade in as the rail opens and end fully opaque', (tester) async {
    await pumpApp(tester, FakeBackend(), size: const Size(1440, 900), roles: ['ops', 'finance']);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1000, 400));
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(const Offset(30, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    double opacityOf(String label) =>
        tester.widget<Opacity>(find.ancestor(of: navLabel(label), matching: find.byType(Opacity)).first).opacity;
    expect(opacityOf('Projects'), lessThan(1), reason: 'mid-fade');
    await tester.pumpAndSettle();
    expect(opacityOf('Projects'), 1);
  });
}
