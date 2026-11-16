// The Import Candidates sheet asks the server what the file WOULD do before
// anything is written, and imports only the people who can sit.
//
// THE INCIDENT (stage, 19 Oct 2026). An 874-row CSV was sent straight to the
// assign route; about eight minutes later the server refused the whole file
// over 8 accounts that cannot sign in. Nothing on screen said a request was
// running, the admin reloaded, and the refusal was never seen. The sheet now
// runs a dry run (about a second, writes nothing) as soon as the file parses,
// names who will be skipped and why, and sends only the rest.
@TestOn('vm')
library;

import 'dart:async';
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
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:ethara_assessment/services/file_pick_stub.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

http.Response _ok(Object data) => _json(<String, dynamic>{
  'ok': true,
  'data': data,
  if (data is List) 'meta': <String, dynamic>{'total': data.length},
});

Map<String, dynamic> _skip(String name, String email, String reason) =>
    <String, dynamic>{'name': name, 'email': email, 'reason': reason};

/// A dry run's answer. [added] is how many PEOPLE the server would add.
http.Response _check({
  required int added,
  List<Map<String, dynamic>> skipped = const <Map<String, dynamic>>[],
  int already = 0,
}) => _ok(<String, dynamic>{
  'dry_run': true,
  'assigned_count': added,
  'already_assigned': already,
  'skipped': skipped,
});

/// A roster CSV of [people], as `name,email` rows under a header.
PickedFile _csv(String file, List<(String, String)> people) => PickedFile(
  file,
  utf8.encode(
    'name,email\n${people.map(((String, String) p) => '${p.$1},${p.$2}').join('\n')}\n',
  ),
);

class _Rig {
  /// [knowsShowAnswers] false is a backend from before the import check: its
  /// assessment detail carries no `results_show_answers`, and it ignores
  /// `dry_run` (an answer to one would be a real import).
  _Rig({this.knowsShowAnswers = true});

  final bool knowsShowAnswers;

  /// The dry runs, in the order they were asked; each waits for the test.
  final List<Completer<http.Response>> checks = <Completer<http.Response>>[];

  /// The emails each REAL import sent.
  final List<List<String>> imported = <List<String>>[];

  late final AppStore store = AppStore(
    api: ApiClient(
      baseUrl: 'http://x',
      client: MockClient((http.Request req) async {
        final String path = req.url.path;
        final Map<String, dynamic> body =
            jsonDecode(req.body) as Map<String, dynamic>;
        if (path.endsWith('/assign')) {
          if (body['dry_run'] == true) {
            final Completer<http.Response> c = Completer<http.Response>();
            checks.add(c);
            return c.future;
          }
          imported.add(<String>[
            for (final Object? c in body['candidates'] as List<dynamic>)
              (c! as Map<String, dynamic>)['email'] as String,
          ]);
          return _ok(<String, dynamic>{'assigned_count': 1});
        }
        if (path.endsWith('/assessments')) return _ok(<dynamic>[_asm]);
        if (RegExp(r'/assessments/[^/]+$').hasMatch(path)) {
          return _ok(<String, dynamic>{
            ..._asm,
            if (knowsShowAnswers) 'results_show_answers': true,
          });
        }
        if (path.endsWith('/attempts') ||
            path.endsWith('/candidates') ||
            path.endsWith('/users')) {
          return _ok(<dynamic>[]);
        }
        return _ok(<String, dynamic>{});
      }),
    ),
  );

  static const Map<String, dynamic> _asm = <String, dynamic>{
    'id': '58',
    'name': 'Warehouse Safety',
    'state': 'draft',
    'active': true,
  };

  Widget app() => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: AssessmentNavScope(
        nav: AssessmentNav(),
        child: SingleChildScrollView(
          child: AssessmentDetailScreen(
            store: store,
            portal: Portal.admin,
            asmId: '58',
            tab: 'assign',
          ),
        ),
      ),
    ),
  );
}

/// The sheet's Import button ("Import" or "Import N candidate(s)", not the
/// screen's "Import from CSV"). Its `onPressed` is the assertion, since a
/// disabled button swallows a tap silently.
Btn _import(WidgetTester t) => t.widget<Btn>(
  find.byWidgetPredicate(
    (Widget w) =>
        w is Btn && RegExp(r'^Import( \d+ candidate\(s\))?$').hasMatch(w.label),
  ),
);

/// The skip notice. The screen behind the sheet carries Notices of its own.
final Finder _skipNotice = find.byWidgetPredicate(
  (Widget w) => w is Notice && (w.strong ?? '').contains('will be skipped'),
);

void main() {
  /// Opens the Import Candidates sheet; [files] answer the picker in turn.
  Future<_Rig> open(
    WidgetTester t,
    List<PickedFile> files, {
    bool knowsShowAnswers = true,
  }) async {
    t.view.physicalSize = const Size(1600, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    AssessmentDetailScreen.pick = ({String accept = ''}) async =>
        files.removeAt(0);
    addTearDown(() => AssessmentDetailScreen.pick = pickFile);
    final _Rig r = _Rig(knowsShowAnswers: knowsShowAnswers);
    r.store.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
    await t.pumpWidget(r.app());
    await t.pumpAndSettle();
    await t.tap(find.text('Import from CSV'));
    await t.pumpAndSettle();
    return r;
  }

  Future<void> choose(WidgetTester t) async {
    await t.tap(find.text('Choose a CSV File'));
    await t.pumpAndSettle();
  }

  /// Lets every toast's dwell timer run out, so none is pending at the end.
  Future<void> drain(WidgetTester t) => t.pump(const Duration(seconds: 30));

  testWidgets('it says it is checking, and holds Import until it knows', (
    WidgetTester t,
  ) async {
    final _Rig r = await open(t, <PickedFile>[
      _csv('roster.csv', <(String, String)>[
        ('Anita Rao', 'anita@x.io'),
        ('Bo Chen', 'bo@x.io'),
        ('Cy Dee', 'cy@x.io'),
      ]),
    ]);

    await choose(t);

    expect(r.checks, hasLength(1));
    expect(find.text('Checking 3 candidates...'), findsOneWidget);
    expect(_import(t).onPressed, isNull);

    r.checks.single.complete(_check(added: 3));
    await t.pumpAndSettle();

    expect(find.text('Checking 3 candidates...'), findsNothing);
    expect(find.text('3 to import'), findsOneWidget);
    expect(_skipNotice, findsNothing);
    expect(_import(t).label, 'Import 3 candidate(s)');
    expect(_import(t).onPressed, isNotNull);
  });

  testWidgets('who will be skipped is named, the count is the server\'s, and '
      'only the rest are sent, once each', (WidgetTester t) async {
    final _Rig r = await open(t, <PickedFile>[
      _csv('roster.csv', <(String, String)>[
        ('Anita Rao', 'anita@x.io'),
        ('Bo Chen', 'Bo@X.io'),
        ('Cy Dee', 'cy@x.io'),
        ('Di Eve', 'di@x.io'),
        ('Anita Again', 'ANITA@x.io'),
      ]),
    ]);
    await choose(t);

    // Five rows, four people, two skipped, one of the other two already on
    // the roster: ONE new candidate.
    r.checks.single.complete(
      _check(
        added: 1,
        already: 1,
        skipped: <Map<String, dynamic>>[
          // The server's own spelling; matched lower-cased.
          _skip('Bo Chen', 'BO@x.io', 'account is archived'),
          _skip('Cy Dee', 'cy@x.io', 'login is disabled'),
        ],
      ),
    );
    await t.pumpAndSettle();

    final Notice n = t.widget<Notice>(_skipNotice);
    expect(n.tone, Tone.warn);
    expect(n.strong, '2 will be skipped - they cannot sign in to sit.');
    expect(
      n.text,
      'Bo Chen <BO@x.io>: account is archived; '
      'Cy Dee <cy@x.io>: login is disabled',
    );
    expect(find.text('1 to import, 1 already assigned'), findsOneWidget);
    expect(_import(t).label, 'Import 1 candidate(s)');

    await t.tap(find.text('Import 1 candidate(s)'));
    await t.pumpAndSettle();

    // Already-assigned people go too: the server leaves them as they are.
    expect(r.imported, <List<String>>[
      <String>['anita@x.io', 'di@x.io'],
    ]);
    await drain(t);
  });

  testWidgets('a long skip list stops at eight, and nobody left disables '
      'Import', (WidgetTester t) async {
    final List<(String, String)> people = <(String, String)>[
      for (int i = 1; i <= 10; i++) ('P$i', 'p$i@x.io'),
    ];
    final _Rig r = await open(t, <PickedFile>[_csv('all.csv', people)]);
    await choose(t);

    r.checks.single.complete(
      _check(
        added: 0,
        skipped: <Map<String, dynamic>>[
          for (final (String, String) p in people) _skip(p.$1, p.$2, 'gone'),
        ],
      ),
    );
    await t.pumpAndSettle();

    final Notice n = t.widget<Notice>(_skipNotice);
    expect(n.strong, '10 will be skipped - they cannot sign in to sit.');
    expect(n.text, contains('P8 <p8@x.io>: gone; and 2 more'));
    expect(n.text, isNot(contains('P9')));
    expect(_import(t).label, 'Import 0 candidate(s)');
    expect(_import(t).onPressed, isNull);
  });

  testWidgets('a failed check says so and still lets the file go', (
    WidgetTester t,
  ) async {
    final _Rig r = await open(t, <PickedFile>[
      _csv('roster.csv', <(String, String)>[
        ('Anita Rao', 'anita@x.io'),
        ('Bo Chen', 'bo@x.io'),
      ]),
    ]);
    await choose(t);

    r.checks.single.complete(
      _json(<String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{'message': 'Server is restarting.'},
      }, 503),
    );
    await t.pumpAndSettle();

    expect(
      find.text(
        'Could not check the file first: Server is restarting. The import '
        'still skips anyone who cannot sit.',
      ),
      findsOneWidget,
    );
    expect(_import(t).label, 'Import 2 candidate(s)');

    await t.tap(find.text('Import 2 candidate(s)'));
    await t.pumpAndSettle();

    expect(r.imported, <List<String>>[
      <String>['anita@x.io', 'bo@x.io'],
    ]);
    await drain(t);
  });

  testWidgets('a file the server refuses holds Import and says why', (
    WidgetTester t,
  ) async {
    // MAIN SENDS THE REAL IMPORT IN BATCHES, so a row only the server refuses
    // (a name over 200 characters) would land every batch before its own and
    // then stop: half a roster. The dry run sees the whole file first.
    final _Rig r = await open(t, <PickedFile>[
      _csv('roster.csv', <(String, String)>[
        ('Anita Rao', 'anita@x.io'),
        ('Bo Chen', 'bo@x.io'),
      ]),
    ]);
    await choose(t);

    r.checks.single.complete(
      _json(<String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{
          'code': 'invalid',
          'message':
              'Nothing was assigned. Fix these candidates: row 2: the name '
              'is longer than 200 characters.',
        },
      }, 422),
    );
    await t.pumpAndSettle();

    final Notice n = t.widget<Notice>(
      find.byWidgetPredicate(
        (Widget w) =>
            w is Notice && (w.strong ?? '').startsWith('Nothing imported'),
      ),
    );
    expect(n.tone, Tone.bad);
    expect(n.text, contains('row 2: the name is longer than 200'));
    expect(find.textContaining('Could not check'), findsNothing);
    expect(_import(t).onPressed, isNull);
    expect(r.imported, isEmpty);
  });

  testWidgets('a check that never answers gives up and lets the file go', (
    WidgetTester t,
  ) async {
    final _Rig r = await open(t, <PickedFile>[
      _csv('roster.csv', <(String, String)>[
        ('Anita Rao', 'anita@x.io'),
        ('Bo Chen', 'bo@x.io'),
      ]),
    ]);
    await choose(t);
    expect(r.checks, hasLength(1));
    expect(_import(t).onPressed, isNull);

    await t.pump(const Duration(seconds: 31));
    await t.pump();

    expect(find.textContaining('Checking'), findsNothing);
    expect(
      find.text(
        'Could not check the file first: the check took too long. The '
        'import still skips anyone who cannot sit.',
      ),
      findsOneWidget,
    );
    expect(_import(t).label, 'Import 2 candidate(s)');
    expect(_import(t).onPressed, isNotNull);
  });

  testWidgets("a late answer for the old file does not land on the new one", (
    WidgetTester t,
  ) async {
    final _Rig r = await open(t, <PickedFile>[
      _csv('old.csv', <(String, String)>[('Old One', 'old@x.io')]),
      _csv('new.csv', <(String, String)>[
        ('New One', 'new1@x.io'),
        ('New Two', 'new2@x.io'),
      ]),
    ]);
    await choose(t);
    await choose(t);
    expect(r.checks, hasLength(2));

    r.checks[1].complete(_check(added: 2));
    await t.pumpAndSettle();
    // The OLD file's answer arrives last, and would skip somebody.
    r.checks[0].complete(
      _check(
        added: 0,
        skipped: <Map<String, dynamic>>[_skip('New One', 'new1@x.io', 'old')],
      ),
    );
    await t.pumpAndSettle();

    expect(find.text('new.csv'), findsWidgets);
    expect(_skipNotice, findsNothing);
    expect(_import(t).label, 'Import 2 candidate(s)');
    expect(_import(t).onPressed, isNotNull);
  });

  testWidgets('everyone already on the roster leaves nothing to import', (
    WidgetTester t,
  ) async {
    final _Rig r = await open(t, <PickedFile>[
      _csv('again.csv', <(String, String)>[
        ('Anita Rao', 'anita@x.io'),
        ('Bo Chen', 'bo@x.io'),
      ]),
    ]);
    await choose(t);

    r.checks.single.complete(_check(added: 0, already: 2));
    await t.pumpAndSettle();

    expect(find.text('0 to import, 2 already assigned'), findsOneWidget);
    expect(_import(t).label, 'Import 0 candidate(s)');
    expect(_import(t).onPressed, isNull);
  });

  // A BACKEND FROM BEFORE THE CHECK ignores `dry_run`, so a "check" sent to
  // it on pick would import the whole file for real, unbatched. It never
  // sends `results_show_answers`, so the sheet asks it nothing and imports
  // only when told, in batches, as before the check existed.
  testWidgets('an older server is never asked to check: picking sends '
      'nothing, Import sends the file', (WidgetTester t) async {
    final _Rig r = await open(t, <PickedFile>[
      _csv('roster.csv', <(String, String)>[
        ('Anita Rao', 'anita@x.io'),
        ('Bo Chen', 'bo@x.io'),
      ]),
    ], knowsShowAnswers: false);
    await choose(t);

    expect(r.checks, isEmpty);
    expect(r.imported, isEmpty, reason: 'nothing may be written on pick');
    expect(find.textContaining('Checking'), findsNothing);
    expect(find.text('2 to import'), findsOneWidget);

    await t.tap(find.text('Import 2 candidate(s)'));
    await t.pumpAndSettle();

    expect(r.checks, isEmpty);
    expect(r.imported, <List<String>>[
      <String>['anita@x.io', 'bo@x.io'],
    ]);
    await drain(t);
  });

  testWidgets('a repeated address is one candidate, even with no check', (
    WidgetTester t,
  ) async {
    final _Rig r = await open(t, <PickedFile>[
      _csv('dupes.csv', <(String, String)>[
        ('New Person', 'new.person2@example.com'),
        ('Bo Chen', 'bo@x.io'),
        ('New Person', 'NEW.PERSON2@example.com'),
      ]),
    ]);
    await choose(t);

    // With no answer to go on, the count falls back to the file - one row
    // per address.
    r.checks.single.complete(
      _json(<String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{'message': 'Server is restarting'},
      }, 503),
    );
    await t.pumpAndSettle();

    expect(find.text('2 to import'), findsOneWidget);
    expect(_import(t).label, 'Import 2 candidate(s)');

    await t.tap(find.text('Import 2 candidate(s)'));
    await t.pumpAndSettle();

    expect(r.imported, <List<String>>[
      <String>['new.person2@example.com', 'bo@x.io'],
    ]);
    await drain(t);
  });

  testWidgets('offline there is no server count, so the file counts', (
    WidgetTester t,
  ) async {
    final _Rig r = await open(t, <PickedFile>[
      _csv('roster.csv', <(String, String)>[
        ('Anita Rao', 'anita@x.io'),
        ('Bo Chen', 'bo@x.io'),
      ]),
    ]);
    // Offline from here: the check answers `added: 0` without asking anyone.
    // (A seed store cannot open this tab in a test - the picker load notifies
    // during build - so the live rig is switched over instead.)
    r.store.source = DataSource.seed;
    await choose(t);

    expect(r.checks, isEmpty);
    // Read as a server count, that 0 would disable Import on every file.
    expect(_import(t).label, 'Import 2 candidate(s)');
    expect(_import(t).onPressed, isNotNull);
  });

  testWidgets('a file with a bad row is refused without asking the server', (
    WidgetTester t,
  ) async {
    final _Rig r = await open(t, <PickedFile>[
      _csv('bad.csv', <(String, String)>[
        ('Anita Rao', 'anita@x.io'),
        ('Typo', 'not-an-email'),
      ]),
    ]);
    await choose(t);

    expect(r.checks, isEmpty);
    expect(find.textContaining('Checking'), findsNothing);
    expect(_import(t).onPressed, isNull);
  });
}
