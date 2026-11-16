// D1 - the flag is a COLUMN, and clicking it is how you set it.
//
// The user asked for three specific things that a model test cannot see, so
// they are pinned here against the real screens:
//
//   1. Candidates gets a Remarks column and then a Flag column, in that order,
//      at the right-hand END of the table. Not a badge tucked inside the Flags
//      cell - that is what this replaced.
//   2. Every row draws a flag, clear or raised, because a column that is blank
//      until something is wrong gives the operator nothing to click.
//   3. Clicking toggles, and clicking a RAISED flag clears it. There is no
//      separate clear action anywhere.
//
// Plus the one that is easy to regress silently: a read-only Manager must still
// SEE the flag and must NOT be able to set it.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/marks.dart';

/// Icons scoped to the TOGGLES, never to the whole tree.
///
/// The Candidates toolbar has a "Flagged" filter chip whose `Btn` also draws
/// `Icons.outlined_flag`, so a bare `find.byIcon` matches the chip as well as
/// the column and every count is off by one. Scoping to `FlagToggle` is what
/// makes these assertions about the COLUMN.
Finder _toggleIcon(IconData icon) => find.descendant(
      of: find.byType(FlagToggle),
      matching: find.byIcon(icon),
    );

Map<String, dynamic> _row(String id, String name, Map<String, dynamic>? flag) =>
    <String, dynamic>{
      'id': id,
      'assessment_id': '58',
      'candidate': <String, dynamic>{'id': 'p$id', 'name': name},
      'state': 'submitted',
      'answered_count': 13,
      'total_questions': 19,
      'results_released': true,
      'flags': <String, dynamic>{'manual_flagged': flag?['flagged'] ?? false},
      'candidate_flag': ?flag,
    };

class _Rig {
  final List<({String path, Map<String, dynamic> body})> calls =
      <({String path, Map<String, dynamic> body})>[];
  late final AppStore store;

  final Map<String, Map<String, dynamic>> flags = <String, Map<String, dynamic>>{
    '2': <String, dynamic>{
      'flagged': true,
      'remark': 'Left the room twice without telling the proctor.',
      'by': 'Akshay Kumar',
      'at': '2026-09-08T09:15:00',
    },
  };

  List<Map<String, dynamic>> get rows => <Map<String, dynamic>>[
    _row('1', 'Aahan Trikha', flags['1']),
    _row('2', 'Jaahanvi', flags['2']),
  ];

  void init({bool admin = true}) {
    store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          final Map<String, dynamic> body = req.body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(req.body) as Map<String, dynamic>;
          calls.add((path: path, body: body));

          final RegExpMatch? f =
              RegExp(r'/attempts/([^/]+)/flag$').firstMatch(path);
          if (f != null) {
            final String id = f.group(1)!;
            final Map<String, dynamic> now = Map<String, dynamic>.from(
                flags[id] ?? <String, dynamic>{'flagged': false, 'remark': ''});
            if (body.containsKey('flagged')) {
              now['flagged'] = body['flagged'] == true;
            }
            if (body.containsKey('remark')) now['remark'] = body['remark'];
            flags[id] = now;
            return _json(<String, dynamic>{
              'attempt_id': id,
              'candidate_flag': now,
            });
          }
          if (path.endsWith('/candidates')) {
            return _json(rows, total: rows.length);
          }
          if (path.endsWith('/assessments')) {
            return _json(<dynamic>[
              <String, dynamic>{
                'id': '58',
                'name': 'Q7r + Grade & Fix',
                'state': 'done',
                'active': true,
              },
            ]);
          }
          if (path.endsWith('/attempts')) return _json(rows, total: rows.length);
          if (RegExp(r'/assessments/[^/]+$').hasMatch(path)) {
            return _json(<String, dynamic>{
              'id': '58',
              'name': 'Q7r + Grade & Fix',
              'state': 'done',
              'active': true,
            });
          }
          return _json(<String, dynamic>{});
        }),
        baseUrl: 'http://x',
      ),
    );
    store.accessRole = admin ? AccessRole.admin : AccessRole.manager;
    store.caps = admin ? Capability.values.toSet() : <Capability>{};
  }

  static http.Response _json(Object data, {int? total}) => http.Response(
    jsonEncode(<String, dynamic>{
      'ok': true,
      'data': data,
      if (data is List)
        'meta': <String, dynamic>{
          'total': total ?? data.length,
          'limit': 200,
          'offset': 0,
          'has_more': false,
        },
    }),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );

  Widget app(String tab) => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: AssessmentNavScope(
        nav: AssessmentNav(),
        child: SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: 1800,
              child: AssessmentDetailScreen(
                store: store,
                portal: Portal.admin,
                asmId: '58',
                tab: tab,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Pump [app] on a surface wide enough for the new columns.
///
/// The default test viewport is 800x600 and the Candidates grid is now 1500
/// wide, so the Flag column's centre falls outside it and `tap()` silently
/// MISSES - the tap "succeeds", no request is made, and the assertion reads as
/// a broken control rather than a too-small window.
///
/// `setSurfaceSize` asserts `inTest`, so it cannot live in `setUp`; the reset
/// is registered with `addTearDown` from inside the test instead.
Future<void> pumpWide(WidgetTester t, Widget app) async {
  await t.binding.setSurfaceSize(const Size(1900, 1400));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(app);
  await t.pumpAndSettle();
}

/// Let the toast's own dismissal timer expire.
///
/// `AppStore._act` raises a toast on success, and its timer outlives the
/// widget tree unless it is pumped out - the test then fails with "A Timer is
/// still pending", which is about the toast rather than about the control that
/// was clicked. Draining it keeps the failure message honest.
Future<void> drainToasts(WidgetTester t) async {
  await t.pump(const Duration(seconds: 10));
  await t.pumpAndSettle();
}

void main() {
  group('the Candidates table', () {
    testWidgets('ends with Remarks then Flag, in that order',
        (WidgetTester t) async {
      final _Rig r = _Rig()..init();
      await pumpWide(t, r.app('candidates'));

      // UPPERCASED BY THE GRID (`data_grid.dart:458` calls `toUpperCase()`),
      // so the header text on screen is not the label in the `Col`.
      expect(find.text('REMARKS'), findsOneWidget);
      expect(find.text('FLAG'), findsOneWidget);
      // ORDER, not just presence: the user asked for Remarks BEFORE Flag, and
      // "both columns exist" would pass with them the wrong way round.
      expect(
        t.getTopLeft(find.text('REMARKS')).dx,
        lessThan(t.getTopLeft(find.text('FLAG')).dx),
        reason: 'Remarks sits immediately before Flag, at the right-hand end',
      );
      // And they are the LAST two - nothing sits right of Flag.
      expect(
        t.getTopLeft(find.text('FLAG')).dx,
        greaterThan(t.getTopLeft(find.text('RELEASED')).dx),
      );
    });

    testWidgets('every row draws a flag, clear or raised',
        (WidgetTester t) async {
      final _Rig r = _Rig()..init();
      await pumpWide(t, r.app('candidates'));

      final Iterable<FlagToggle> toggles =
          t.widgetList<FlagToggle>(find.byType(FlagToggle));
      expect(toggles.length, 2, reason: 'one per row, not one per FLAGGED row');
      expect(toggles.where((FlagToggle f) => f.flag.flagged).length, 1);
      // The raised one is the filled glyph, the clear one the outline.
      expect(_toggleIcon(Icons.flag), findsOneWidget);
      expect(_toggleIcon(Icons.outlined_flag), findsOneWidget);
    });

    testWidgets('the remark is shown in its cell', (WidgetTester t) async {
      final _Rig r = _Rig()..init();
      await pumpWide(t, r.app('candidates'));
      expect(find.textContaining('Left the room twice'), findsOneWidget);
    });

    testWidgets('clicking a clear flag raises it', (WidgetTester t) async {
      final _Rig r = _Rig()..init();
      await pumpWide(t, r.app('candidates'));

      await t.tap(_toggleIcon(Icons.outlined_flag), warnIfMissed: false);
      await t.pumpAndSettle();

      final ({String path, Map<String, dynamic> body}) call = r.calls.lastWhere(
          (({String path, Map<String, dynamic> body}) c) =>
              c.path.contains('/flag'));
      expect(call.path, contains('/attempts/1/flag'));
      expect(call.body['flagged'], isTrue);
      expect(call.body.containsKey('remark'), isFalse,
          reason: 'toggling must not touch the remark');
      await drainToasts(t);
    });

    testWidgets('clicking a RAISED flag clears it - the only clear action',
        (WidgetTester t) async {
      final _Rig r = _Rig()..init();
      await pumpWide(t, r.app('candidates'));

      await t.tap(_toggleIcon(Icons.flag), warnIfMissed: false);
      await t.pumpAndSettle();

      final ({String path, Map<String, dynamic> body}) call = r.calls.lastWhere(
          (({String path, Map<String, dynamic> body}) c) =>
              c.path.contains('/flag'));
      expect(call.path, contains('/attempts/2/flag'));
      expect(call.body['flagged'], isFalse);
      await drainToasts(t);
    });
  });

  group('the Leaderboard table', () {
    testWidgets('carries a flag per row and no "Flagged" word',
        (WidgetTester t) async {
      final _Rig r = _Rig()..init();
      await pumpWide(t, r.app('leaderboard'));

      expect(t.widgetList<FlagToggle>(find.byType(FlagToggle)).length, 2);
      // The word-badge the user asked to remove.
      expect(find.text('Flagged'), findsNothing);
    });

    testWidgets('the icon fills RED immediately, without leaving the tab',
        (WidgetTester t) async {
      // THE REPORTED BUG. The request was made and the state was right on the
      // next visit, but the glyph did not change under the operator's finger -
      // so the click read as having done nothing and they clicked again, which
      // on a TOGGLE puts it back where it started.
      final _Rig r = _Rig()..init();
      await pumpWide(t, r.app('leaderboard'));

      expect(_toggleIcon(Icons.flag), findsOneWidget, reason: 'one starts raised');
      expect(_toggleIcon(Icons.outlined_flag), findsOneWidget);

      await t.tap(_toggleIcon(Icons.outlined_flag), warnIfMissed: false);
      await t.pumpAndSettle();

      expect(_toggleIcon(Icons.flag), findsNWidgets(2),
          reason: 'the clicked row must be filled red on the SAME frame path, '
              'not only after the tab is left and re-entered');
      expect(_toggleIcon(Icons.outlined_flag), findsNothing);
      await drainToasts(t);
    });

    testWidgets('clicking one flags that sitting', (WidgetTester t) async {
      final _Rig r = _Rig()..init();
      await pumpWide(t, r.app('leaderboard'));

      await t.tap(_toggleIcon(Icons.outlined_flag).first, warnIfMissed: false);
      await t.pumpAndSettle();

      expect(
        r.calls.lastWhere((({String path, Map<String, dynamic> body}) c) =>
            c.path.contains('/flag')).path,
        contains('/flag'),
      );
      await drainToasts(t);
    });
  });

  group('a read-only Manager', () {
    testWidgets('sees the flag but cannot set it', (WidgetTester t) async {
      final _Rig r = _Rig()..init(admin: false);
      await pumpWide(t, r.app('candidates'));

      final Iterable<FlagToggle> toggles =
          t.widgetList<FlagToggle>(find.byType(FlagToggle));
      expect(toggles.length, 2, reason: 'the state is readable at every rung');
      expect(toggles.every((FlagToggle f) => f.onToggle == null), isTrue,
          reason: 'a control the server answers 403 to must not be offered');

      await t.tap(_toggleIcon(Icons.flag), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(
        r.calls.where((({String path, Map<String, dynamic> body}) c) =>
            c.path.contains('/flag')),
        isEmpty,
        reason: 'and tapping it must send nothing',
      );
    });
  });
}
