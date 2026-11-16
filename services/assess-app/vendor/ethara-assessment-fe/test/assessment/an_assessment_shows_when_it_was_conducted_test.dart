// An assessment says WHEN IT WAS CONDUCTED, in India time.
//
// The list had an Awaiting column and no date: with a dozen runs of the same
// paper there was no way to tell them apart without opening each. The server
// now sends `launched_at` (ISO UTC, falling back to `start_date` for rows
// launched before it kept the stamp, null for a draft), the list prints it in
// the slot Awaiting held, and the detail header names it after the question
// count.
//
// THE THINGS THAT CAN GO WRONG:
//   - the clock is the browser's or UTC instead of IST (a launch at 19:00 UTC
//     is already tomorrow in India);
//   - a draft prints a date it never had instead of "-";
//   - the field is parsed but a background list refresh wipes it, which is
//     the `_mergeAssessments` hazard `sebQuitPassword` taught.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_list_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/data_grid.dart';

/// 12:50 PM in India: 07:20 UTC.
const String kLaunchedUtc = '2026-09-30T07:20:00Z';

Assessment _row(String id, {String? launchedAt, String state = 'done'}) =>
    Assessment.fromJson(<String, dynamic>{
      'id': id,
      'name': 'Paper $id',
      'state': state,
      'active': true,
      'launched_at': ?launchedAt,
    });

Future<void> _openList(WidgetTester t, List<Assessment> rows) async {
  await t.binding.setSurfaceSize(const Size(1600, 1400));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final AppStore s = AppStore()..assessments = rows;
  s.accessRole = AccessRole.admin;
  s.caps = Capability.values.toSet();
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: AssessmentNavScope(
        nav: AssessmentNav(),
        child: Scaffold(
          body: SingleChildScrollView(
            child: AssessmentListScreen(store: s, portal: Portal.admin),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> _openDetail(WidgetTester t, Assessment a) async {
  t.view.physicalSize = const Size(1600, 2600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final AppStore s = AppStore()..assessments = <Assessment>[a];
  s.accessRole = AccessRole.admin;
  s.caps = Capability.values.toSet();
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: AssessmentDetailScreen(
            store: s,
            portal: Portal.admin,
            asmId: a.id,
            tab: 'config',
          ),
        ),
      ),
    ),
  );
  await t.pump();
  addTearDown(() async => t.pumpWidget(const SizedBox.shrink()));
}

Finder _inGrid(Finder f) =>
    find.descendant(of: find.byType(DataGrid), matching: f);

// A store answering list and detail routes from two payloads, so a case can
// say what the list row carries and what the detail row carries SEPARATELY.
// The merge only matters when they differ.
Map<String, dynamic> _listRow = <String, dynamic>{};
Map<String, dynamic> _detailRow = <String, dynamic>{};

AppStore _serverStore() {
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      client: MockClient((http.Request req) async {
        final String path = req.url.path;
        Object data = <dynamic>[];
        Map<String, dynamic>? meta = <String, dynamic>{
          'total': 0,
          'has_more': false,
        };
        if (path.endsWith('/assessments')) {
          data = <dynamic>[_listRow];
          meta = <String, dynamic>{'total': 1, 'has_more': false};
        } else if (path.contains('/assessments/')) {
          data = _detailRow;
          meta = null;
        }
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'data': data,
            'meta': ?meta,
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    ),
  );
  addTearDown(s.dispose);
  s.adoptSession(
    orgRole: 'admin',
    name: 'Aarav Mehta',
    uid: '2',
    accessRoleWire: AccessRole.admin.wire,
    capabilities: Capability.values.toSet(),
  );
  return s;
}

Assessment _held(AppStore s) =>
    s.assessments.firstWhere((Assessment a) => a.id == '7');

void main() {
  group('the clock', () {
    test('is India time, and always says IST', () {
      final DateTime at = DateTime.parse(kLaunchedUtc);
      expect(istDateTime(at), '30 Sep 2026, 12:50 PM IST');
    });

    test('rolls the DAY over with the offset, and reads noon and midnight', () {
      // 19:00 UTC is 00:30 the next morning in India.
      expect(
        istDateTime(DateTime.utc(2026, 9, 30, 19)),
        '1 Oct 2026, 12:30 AM IST',
      );
      expect(
        istDateTime(DateTime.utc(2026, 9, 30, 6, 30)),
        '30 Sep 2026, 12:00 PM IST',
      );
    });
  });

  group('the list', () {
    testWidgets('prints the launch in IST under CONDUCTED, not AWAITING', (
      WidgetTester t,
    ) async {
      await _openList(t, <Assessment>[_row('1', launchedAt: kLaunchedUtc)]);

      expect(_inGrid(find.text('CONDUCTED')), findsOneWidget);
      expect(_inGrid(find.text('AWAITING')), findsNothing);
      expect(
        _inGrid(find.text('30 Sep 2026, 12:50 PM IST')),
        findsOneWidget,
        reason: '07:20 UTC is 12:50 PM in India, and the cell says so',
      );
    });

    testWidgets('names the IST day, not the UTC one, late in the evening', (
      WidgetTester t,
    ) async {
      await _openList(t, <Assessment>[
        _row('1', launchedAt: '2026-09-30T19:00:00Z'),
      ]);

      expect(_inGrid(find.text('1 Oct 2026, 12:30 AM IST')), findsOneWidget);
      expect(_inGrid(find.textContaining('30 Sep')), findsNothing);
    });

    testWidgets('a draft shows "-", never a date', (WidgetTester t) async {
      await _openList(t, <Assessment>[_row('1', state: 'draft')]);

      // Other cells print "-" too, so find the one UNDER the CONDUCTED header:
      // header and cell share the column's left padding.
      final double column = t
          .getTopLeft(_inGrid(find.text('CONDUCTED')))
          .dx;
      final Finder dashes = _inGrid(find.text('-'));
      final bool underHeader = <bool>[
        for (int i = 0; i < dashes.evaluate().length; i++)
          (t.getTopLeft(dashes.at(i)).dx - column).abs() < 1,
      ].contains(true);
      expect(underHeader, isTrue, reason: 'the Conducted cell must read "-"');
      expect(_inGrid(find.textContaining('2026')), findsNothing);
    });
  });

  group('the detail header', () {
    testWidgets('appends Conducted, in IST, after the question count', (
      WidgetTester t,
    ) async {
      await _openDetail(t, _row('A-1', launchedAt: kLaunchedUtc));

      expect(
        find.textContaining('questions  ·  Conducted 30 Sep 2026, '
            '12:50 PM IST'),
        findsOneWidget,
      );
    });

    testWidgets('a draft says nothing about being conducted', (
      WidgetTester t,
    ) async {
      await _openDetail(t, _row('A-1', state: 'draft'));

      expect(find.textContaining('questions'), findsWidgets);
      expect(find.textContaining('Conducted'), findsNothing);
    });
  });

  group('the cache', () {
    setUp(() {
      _listRow = <String, dynamic>{
        'id': '7',
        'name': 'Paper 7',
        'state': 'done',
        'active': true,
      };
      _detailRow = <String, dynamic>{
        ..._listRow,
        'launched_at': kLaunchedUtc,
      };
    });

    testWidgets('keeps the stamp when a list row does not carry the key', (
      WidgetTester t,
    ) async {
      final AppStore s = _serverStore();
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpAndSettle();
      expect(_held(s).launchedAt, isNull, reason: 'the list row has no stamp');

      await s.loadAssessment('7');
      expect(_held(s).launchedAt, DateTime.parse(kLaunchedUtc));

      await s.refresh(background: true);

      expect(
        _held(s).launchedAt,
        DateTime.parse(kLaunchedUtc),
        reason: 'a list row without the key must not blank what the detail '
            'read brought - the sebQuitPassword hazard',
      );
    });

    testWidgets('takes a newer stamp from the list row', (
      WidgetTester t,
    ) async {
      final AppStore s = _serverStore();
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpAndSettle();
      await s.loadAssessment('7');

      _listRow = <String, dynamic>{
        ..._listRow,
        'launched_at': '2026-10-02T04:00:00Z',
      };
      await s.refresh(background: true);

      expect(_held(s).launchedAt, DateTime.parse('2026-10-02T04:00:00Z'));
    });

    testWidgets('a list row that says null clears it', (WidgetTester t) async {
      final AppStore s = _serverStore();
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpAndSettle();
      await s.loadAssessment('7');

      _listRow = <String, dynamic>{..._listRow, 'launched_at': null};
      await s.refresh(background: true);

      expect(
        _held(s).launchedAt,
        isNull,
        reason: 'the key present as null is the server saying "not launched"',
      );
    });
  });
}
