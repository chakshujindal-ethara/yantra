// The signed-in person's card at the foot of the rail, which is now the ONLY
// way to the password form - by way of the account MENU it opens.
//
// WHY THE REAL SHELL AND NOT A STUB. `password_change_test.dart` drives the
// section with a stand-in sidebar, which proves the key routes and the screen
// renders - but the stand-in is written by the test, so it cannot prove that
// `_Sidebar` is the thing calling it. Account used to have a rail row as a
// second way in; it does not any more. If the card stops calling
// `onOpen('account')`, a candidate provisioned on the shared default password
// has no way left to change it, and every other test in the suite would still
// pass. That is exactly the gap this closes.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/app_shell.dart';
import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/screens/account/account_screen.dart';
import 'package:ethara_assessment/assessment/theme.dart';
import 'package:ethara_assessment/config.dart';
import 'package:ethara_assessment/session.dart';

/// A client that answers everything with an empty success envelope.
///
/// Enough for the shell to mount and the store to finish its first load
/// without a backend. Nothing here is asserted on - the subject is the rail.
ApiClient _quietApi() => ApiClient(
  baseUrl: 'http://stub',
  client: MockClient(
    (http.Request _) async => http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    ),
  ),
);

Future<void> _pumpShell(WidgetTester tester) async {
  // The data grids declare a minWidth of 860, so the default 800x600 window
  // would overflow every screen and read as a layout bug rather than a
  // viewport narrower than the app targets.
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final Session session = Session(api: _quietApi());
  addTearDown(session.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: AppShell(
        session: session,
        isDark: false,
        onToggleTheme: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('The name card is the way to Account', () {
    testWidgets('no rail row named Account is drawn', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester);

      // The label, anywhere in the real rail. Two ways into one page is the
      // thing the move was meant to remove, not something it should leave
      // behind.
      expect(find.text('Account'), findsNothing);
    });

    testWidgets('the card opens a menu, and Profile opens the form', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester);
      expect(find.byType(AccountScreen), findsNothing);

      // `Signed in` is what the card shows when the session has no name yet,
      // which is the state a stubbed `/auth/me` leaves it in.
      await tester.tap(find.text('Signed in').first);
      await tester.pumpAndSettle();

      // The menu, not the page. Everything about the PERSON is in one place
      // now rather than the card doing one of the three things.
      expect(find.text('Profile'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      expect(
        find.byType(AccountScreen),
        findsNothing,
        reason: 'the card opens the menu; the menu opens the page',
      );

      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();

      expect(
        find.byType(AccountScreen),
        findsOneWidget,
        reason:
            'this is the only route to the password form - a candidate on '
            'the provisioned default password has no other way to change it',
      );
    });

    testWidgets('sign-out is a named row, never a stray click', (
      WidgetTester tester,
    ) async {
      // The rule REPLACES an older one. Sign-out used to be a bare icon
      // beside the card, kept outside its tap target so a slightly-off click
      // could not fire it. In a menu that hazard is gone by construction - it
      // is a labelled row you choose from a list - and keeping it outside
      // meant the one destructive control was the only thing about the
      // account NOT in the account menu.
      await _pumpShell(tester);

      // Nothing signs you out until the menu is open.
      expect(find.text('Sign out'), findsNothing);

      await tester.tap(find.text('Signed in').first);
      await tester.pumpAndSettle();

      expect(find.text('Sign out'), findsOneWidget);
      // And it is not adjacent to Profile: a divider separates the
      // destructive row from the navigational ones.
      expect(find.byType(PopupMenuDivider), findsWidgets);
    });

    testWidgets('the theme toggle is in the menu too', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester);
      await tester.tap(find.text('Signed in').first);
      await tester.pumpAndSettle();

      // A preference about the person, sitting with the rest of them.
      expect(
        find.textContaining('Switch to'),
        findsOneWidget,
        reason: 'the theme is a preference, not a product setting',
      );
    });
  });

  group('The rail carries the company wordmark', () {
    testWidgets('Ethara.AI sits above the product row, tinted for the theme', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester);
      expect(tester.takeException(), isNull);

      final Finder logo = find.bySemanticsLabel('Ethara.AI');
      expect(logo, findsOneWidget);
      // The PNG is white on transparent: untinted it vanishes on the light
      // theme this shell is mounted in.
      final Finder image = find.byWidgetPredicate(
        (Widget w) => w is Image && w.semanticLabel == 'Ethara.AI',
      );
      final Image img = tester.widget<Image>(image);
      final Color textPrimary = tester.element(image).tokens.textPrimary;
      // Not vacuous: a hard-coded white must fail this, so the light token
      // has to differ from white.
      expect(textPrimary, isNot(Colors.white));
      expect(img.color, textPrimary);
      expect(img.colorBlendMode, BlendMode.srcIn);
      // Above the product name row, which stays.
      expect(find.text(kAppName), findsOneWidget);
      expect(
        tester.getTopLeft(logo).dy,
        lessThan(tester.getTopLeft(find.text(kAppName)).dy),
      );
    });
  });
}
