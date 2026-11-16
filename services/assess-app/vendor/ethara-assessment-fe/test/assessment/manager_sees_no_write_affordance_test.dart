// A read-only Manager must not be OFFERED an action the server will refuse.
//
// `manager_nav_test` pins which rail rows a Manager sees. This pins what is
// inside them, which is the half that was missing: the rail was narrowed to six
// read-only surfaces and every one of those surfaces still drew its write
// buttons, because they were gated on `Portal` - and `Portal` is binary and
// reports `admin` for a Manager, since a Manager belongs in the console.
//
// FOUND BY SIGNING IN AS ONE. The Assessments screen offered "New Assessment"
// and an Archive control on every row; the account card at the foot of the rail
// said "Admin". Every one of those calls a route the server answers 403 to. A
// dead button is worse than a missing one: the reader cannot tell a permission
// from a bug, and the label they would quote in the report was wrong too.
//
// THE GATE IS `Capability`, NOT `AccessRole`. The server sends the capability
// set on the session payload, so what the console hides and what the API
// refuses come from one fact instead of two lists that drift. A Manager holds
// none of them - "read-only" is exactly "holds no capability" - which is why
// this file drives the store with an empty set rather than naming the role.
//
// NOT A SECURITY BOUNDARY. Every route re-checks its own group; this only
// decides what is worth drawing.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_list_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/bank_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_studio_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/tags_screen.dart';
import 'package:ethara_assessment/assessment/screens/account/account_screen.dart';
import 'package:ethara_assessment/assessment/nav.dart';

/// Answers every call with an empty success envelope.
///
/// The subject is what the screen DRAWS for a given capability set, so no
/// fixture data is needed - an empty list still renders the page head, the
/// toolbar and the empty state, which is where the offending buttons were.
ApiClient _quietApi() => ApiClient(
  baseUrl: 'http://stub',
  client: MockClient(
    (http.Request _) async => http.Response(
      jsonEncode(<String, dynamic>{
        'ok': true,
        'data': <dynamic>[],
        'meta': <String, dynamic>{'total': 0, 'has_more': false},
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    ),
  ),
);

/// A store on the operator console at [role], holding [caps] and nothing else.
///
/// `capabilities` is passed EXPLICITLY even for the admin case: the store
/// defaults a null set to every capability (a client talking to a backend that
/// predates the field must keep working), so leaving it out would make the
/// Manager cases pass for the wrong reason.
AppStore _store(AccessRole role, Set<Capability> caps) {
  final AppStore s = AppStore(api: _quietApi());
  addTearDown(s.dispose);
  s.adoptSession(
    orgRole: 'admin',
    name: 'Aarav Mehta',
    uid: '2',
    accessRoleWire: role.wire,
    capabilities: caps,
  );
  return s;
}

AppStore _manager() => _store(AccessRole.manager, const <Capability>{});

AppStore _admin() => _store(AccessRole.admin, Capability.values.toSet());

Future<void> _pump(WidgetTester tester, Widget child) async {
  // The grids declare minWidths up to 968, so the default 800x600 viewport
  // would overflow and read as a layout bug rather than a narrow window.
  tester.view.physicalSize = const Size(1600, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      // The screens navigate through `context.nav`, so the scope has to be
      // present or every row tap throws instead of asserting.
      home: AssessmentNavScope(
        nav: AssessmentNav(),
        child: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the Assessments list', () {
    testWidgets('an Admin is offered New Assessment', (
      WidgetTester tester,
    ) async {
      await _pump(tester, AssessmentListScreen(store: _admin(), portal: Portal.admin));
      expect(find.text('New Assessment'), findsWidgets);
    });

    testWidgets('a Manager is offered no way to create one', (
      WidgetTester tester,
    ) async {
      await _pump(tester, AssessmentListScreen(store: _manager(), portal: Portal.admin));

      expect(
        find.text('New Assessment'),
        findsNothing,
        reason:
            '/api/v1/assessments/create is Admin-only, so this button is a '
            '403 with a plus sign on it',
      );
    });

    testWidgets('a Manager is offered no Archive or Restore', (
      WidgetTester tester,
    ) async {
      await _pump(tester, AssessmentListScreen(store: _manager(), portal: Portal.admin));

      expect(find.byTooltip('Archive'), findsNothing);
      expect(find.text('Restore'), findsNothing);
    });
  });

  group('the Question Bank', () {
    testWidgets('an Admin is offered Import', (WidgetTester tester) async {
      await _pump(tester, BankScreen(store: _admin()));
      expect(find.text('Import'), findsOneWidget);
    });

    testWidgets('a Manager is offered neither Import nor Archive', (
      WidgetTester tester,
    ) async {
      await _pump(tester, BankScreen(store: _manager()));

      expect(find.text('Import'), findsNothing);
      expect(find.byTooltip('Archive'), findsNothing);
    });

    testWidgets('a Manager is not sent to the Review Queue', (
      WidgetTester tester,
    ) async {
      // The empty state pointed at a screen that is not on their rail, so the
      // button led nowhere they could go.
      await _pump(tester, BankScreen(store: _manager()));
      expect(find.text('Go to Review Queue'), findsNothing);
    });
  });

  group('Tags', () {
    testWidgets('an Admin is offered the vocabulary actions', (
      WidgetTester tester,
    ) async {
      await _pump(tester, TagsScreen(store: _admin()));
      expect(find.text('Import'), findsOneWidget);
      expect(find.text('Normalize Vocabulary'), findsOneWidget);
    });

    testWidgets('a Manager is offered none of them', (
      WidgetTester tester,
    ) async {
      await _pump(tester, TagsScreen(store: _manager()));

      expect(find.text('Import'), findsNothing);
      expect(find.text('Normalize Vocabulary'), findsNothing);
      expect(find.text('Merge All'), findsNothing);
    });
  });

  group('Form Studio', () {
    testWidgets('an Admin gets both tabs and the authoring actions', (
      WidgetTester tester,
    ) async {
      await _pump(tester, FormStudioScreen(store: _admin()));

      expect(find.text('Question Types'), findsOneWidget);
      expect(find.text('New Form'), findsWidgets);
      expect(find.text('Import'), findsOneWidget);
    });

    testWidgets('a Manager gets one tab and no authoring actions', (
      WidgetTester tester,
    ) async {
      await _pump(tester, FormStudioScreen(store: _manager()));

      expect(
        find.text('Question Types'),
        findsNothing,
        reason:
            '/api/v1/task_templates is Admin-only, so the tab could only ever '
            'report "we could not load these" - a permission dressed as an '
            'outage',
      );
      expect(find.text('Forms'), findsOneWidget);
      expect(find.text('New Form'), findsNothing);
      expect(find.text('Import'), findsNothing);
    });
  });

  group('the account card names the rung it is on', () {
    test('each role has its own label', () {
      // `Portal` is binary and reported `admin` for a Manager, which is how the
      // card came to tell a read-only operator they were an Admin.
      expect(AccessRole.admin.label, 'Admin');
      expect(AccessRole.manager.label, 'Manager');
      expect(AccessRole.candidate.label, 'Candidate');
      expect(AccessRole.none.label, 'No access');
    });

    test('no two rungs share a label', () {
      final Set<String> labels = AccessRole.values
          .map((AccessRole r) => r.label)
          .toSet();
      expect(labels.length, AccessRole.values.length);
    });

    test('a Manager is not promised anything they cannot do', () {
      // The Account screen printed "Author, launch, score and release" for a
      // Manager, because that sentence was a two-way switch on `portal`. Four
      // verbs, all four refused by the server.
      final String manager = AccessRole.manager.canDo.toLowerCase();
      for (final String verb in <String>[
        'author',
        'launch',
        'score',
        'release',
      ]) {
        expect(
          manager.contains(verb),
          isFalse,
          reason: 'a read-only Manager cannot $verb - the Account screen must '
              'not say they can',
        );
      }
      expect(manager, contains('read only'));
    });

    test('every rung says something, and none says the same thing', () {
      final Set<String> said = <String>{};
      for (final AccessRole r in AccessRole.values) {
        expect(r.canDo.trim(), isNotEmpty, reason: '${r.wire} says nothing');
        said.add(r.canDo);
      }
      expect(said.length, AccessRole.values.length);
    });
  });

  group('the Account screen', () {
    testWidgets('a Manager is named Manager, not Admin', (
      WidgetTester tester,
    ) async {
      // THREE SITES ON ONE SCREEN read `portal.label`: the pill beside the
      // name, the "Role" row, and the "What this role can do" sentence. All
      // three said Admin.
      await _pump(tester, AccountScreen(store: _manager()));

      expect(find.text('Manager'), findsWidgets);
      expect(
        find.text('Admin'),
        findsNothing,
        reason: 'this is the screen somebody opens to find out what they are',
      );
      expect(find.text('Author, launch, score and release'), findsNothing);
    });

    testWidgets('an Admin is still named Admin', (WidgetTester tester) async {
      await _pump(tester, AccountScreen(store: _admin()));

      expect(find.text('Admin'), findsWidgets);
      expect(find.text('Author, launch, score and release'), findsOneWidget);
    });
  });

  // `testWidgets`, not `test`, even though nothing here is a widget:
  // `adoptSession` starts the first load, and a plain `test` returns before that
  // future notifies - which then fires against a store the tear-down has already
  // disposed. `pumpAndSettle` drains it.
  group('the capability set is what does the gating', () {
    testWidgets('a Manager holds none', (WidgetTester tester) async {
      final AppStore s = _manager();
      await tester.pumpAndSettle();

      for (final Capability c in Capability.values) {
        expect(
          s.can(c),
          isFalse,
          reason: 'read-only means holding no capability to CHANGE anything',
        );
      }
    });

    testWidgets('an Admin holds all', (WidgetTester tester) async {
      final AppStore s = _admin();
      await tester.pumpAndSettle();

      for (final Capability c in Capability.values) {
        expect(s.can(c), isTrue);
      }
    });

    testWidgets('an absent set still means full access', (
      WidgetTester tester,
    ) async {
      // A client talking to a backend that predates `capabilities` must keep
      // working rather than lose every button.
      final AppStore s = AppStore(api: _quietApi());
      addTearDown(s.dispose);
      s.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
      await tester.pumpAndSettle();

      for (final Capability c in Capability.values) {
        expect(s.can(c), isTrue);
      }
    });
  });

  // Hiding a button stops the CLICK; it does not stop a LOAD. Three admin-only
  // lists are fetched on every console load and a Manager is refused all three,
  // so without a gate every sign-in files 403s in the network log. Two were
  // already behind `_ifAdmin` (generators, settings); `drafts` was not, because
  // it runs outside the `Future.wait` and its failure is swallowed - which made
  // it harmless and invisible at the same time, and a silent 403 is the first
  // thing anybody debugging this app will chase.
  group('the requests a Manager does not even make', () {
    testWidgets('no admin-only path is requested on a Manager load', (
      WidgetTester tester,
    ) async {
      final List<String> paths = <String>[];
      final AppStore s = AppStore(api: _recordingApi(paths));
      addTearDown(s.dispose);
      s.adoptSession(
        orgRole: 'admin',
        name: 'Aarav Mehta',
        uid: '2',
        accessRoleWire: AccessRole.manager.wire,
        capabilities: const <Capability>{},
      );
      await tester.pumpAndSettle();

      for (final String forbidden in <String>[
        '/api/v1/drafts',
        '/api/v1/generators',
        '/api/v1/settings',
      ]) {
        expect(
          paths,
          isNot(contains(forbidden)),
          reason: '$forbidden is Admin-only; a Manager asking for it earns a '
              '403 on every console load',
        );
      }
      expect(
        paths,
        contains('/api/v1/assessments'),
        reason: 'guard the guard - the recorder has to be seeing real traffic',
      );
    });

    testWidgets('an Admin still asks for all three', (
      WidgetTester tester,
    ) async {
      final List<String> paths = <String>[];
      final AppStore s = AppStore(api: _recordingApi(paths));
      addTearDown(s.dispose);
      s.adoptSession(
        orgRole: 'admin',
        name: 'Aarav Mehta',
        uid: '2',
        accessRoleWire: AccessRole.admin.wire,
        capabilities: Capability.values.toSet(),
      );
      await tester.pumpAndSettle();

      expect(paths, contains('/api/v1/drafts'));
      expect(paths, contains('/api/v1/generators'));
      expect(paths, contains('/api/v1/settings'));
    });
  });
}

/// Like [_quietApi], but records the path of every request it answers.
ApiClient _recordingApi(List<String> into) => ApiClient(
  baseUrl: 'http://stub',
  client: MockClient((http.Request req) async {
    into.add(req.url.path);
    return http.Response(
      jsonEncode(<String, dynamic>{
        'ok': true,
        'data': <dynamic>[],
        'meta': <String, dynamic>{'total': 0, 'has_more': false},
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }),
);
