// The attempt detail shows the camera snapshots AI proctoring saved.
//
// THE CONTRACT THIS PINS (Task 7's `GET /attempts/<id>/evidence`): rows
// `{key, url, at, rule, size}` newest first, `count`, and an empty list when
// storage is not configured. Each `url` is a presigned GET that lapses after
// 15 minutes.
//
// THE FOUR WAYS THE PANEL COULD LIE, each pinned below:
//   * a failed read drawn as "no snapshots" - a reviewer would clear a
//     candidate the server never got to look at, so a failure is its own state;
//   * an empty box on every older paper - hidden unless the paper is
//     AI-proctored or evidence exists;
//   * a thumbnail whose link expired while the page sat open - a tap on an old
//     one re-reads first;
//   * a time in the browser's zone - the caption is IST, zone named.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';

/// 10:04 UTC is 15:34 in India.
const String _kAt = '2026-10-06T10:04:00Z';
const String _kIst = '6 Oct 2026, 3:34 PM IST';

/// The route's reply, in its own shape.
Map<String, dynamic> evidence({
  List<Map<String, dynamic>>? items,
  int? count,
  String sig = '1',
}) {
  final List<Map<String, dynamic>> rows =
      items ??
      <Map<String, dynamic>>[
        <String, dynamic>{
          'key': 'proctoring/db/80/1759745040000_phone.jpg',
          'url': 'https://s3.example/phone.jpg?sig=$sig',
          'at': _kAt,
          'rule': 'phone',
          'size': 48211.0,
        },
        <String, dynamic>{
          'key': 'proctoring/db/80/1759744900000_no_face.jpg',
          'url': 'https://s3.example/no_face.jpg?sig=$sig',
          'at': '2026-10-06T10:01:40Z',
          'rule': 'no_face',
          'size': 39000,
        },
      ];
  return <String, dynamic>{
    'items': rows,
    'count': count ?? rows.length,
    'prefix': 'proctoring/db/80/',
  };
}

/// A fake server that records every path it is asked for.
class _Server {
  final List<String> paths = <String>[];

  /// Called per evidence request; `n` is 1 for the first.
  http.Response Function(int n) onEvidence = (int n) => ok(evidence());

  int get evidenceCalls =>
      paths.where((String p) => p.endsWith('/evidence')).length;

  /// The attempt detail row the screen tests serve (and are seeded with).
  Map<String, dynamic> attemptRow = <String, dynamic>{};

  ApiClient get api => ApiClient(
    baseUrl: 'http://x',
    client: MockClient((http.Request req) async {
      paths.add(req.url.path);
      if (req.url.path.endsWith('/evidence')) return onEvidence(evidenceCalls);
      if (RegExp(r'/attempts/[^/]+$').hasMatch(req.url.path)) {
        return ok(attemptRow);
      }
      return ok(<String, dynamic>{});
    }),
  );

  static http.Response ok(Map<String, dynamic> data) => http.Response(
    jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );

  static http.Response refused(
    int status,
    String message, {
    String code = 'refused',
  }) => http.Response(
    jsonEncode(<String, dynamic>{
      'ok': false,
      'error': <String, dynamic>{'code': code, 'message': message},
    }),
    status,
    headers: <String, String>{'content-type': 'application/json'},
  );
}

Future<void> mountPanel(
  WidgetTester t,
  ApiClient? api, {
  bool ai = true,
  DateTime Function()? clock,
}) async {
  t.view.physicalSize = const Size(1400, 1600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProctoringEvidencePanel(
            api: api,
            attemptId: '80',
            aiProctored: ai,
            clock: clock ?? DateTime.now,
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

/// The `Image` a thumbnail or the dialog is drawing, by URL (off the web the
/// image plate is `Image.network`).
Finder imageAt(String url) => find.byWidgetPredicate(
  (Widget w) =>
      w is Image &&
      w.image is NetworkImage &&
      (w.image as NetworkImage).url == url,
);

void main() {
  group('the evidence panel reads and draws the snapshots', () {
    testWidgets('each snapshot shows its rule and its IST time', (
      WidgetTester t,
    ) async {
      final _Server s = _Server();
      await mountPanel(t, s.api);

      expect(find.text('Proctoring evidence'), findsOneWidget);
      expect(find.text('2 snapshots'), findsOneWidget);
      expect(find.text('Phone detected'), findsOneWidget);
      expect(find.text('No face in view'), findsOneWidget);
      expect(
        find.text(_kIst),
        findsOneWidget,
        reason: 'the caption is IST with the zone named, not the browser clock',
      );
      expect(find.text('6 Oct 2026, 3:31 PM IST'), findsOneWidget);
      expect(imageAt('https://s3.example/phone.jpg?sig=1'), findsOneWidget);
    });

    testWidgets('the request goes to /attempts/<id>/evidence, once', (
      WidgetTester t,
    ) async {
      final _Server s = _Server();
      await mountPanel(t, s.api);

      expect(s.paths, <String>['/api/v1/attempts/80/evidence']);
    });

    testWidgets('a paper with none says so, with a count of 0', (
      WidgetTester t,
    ) async {
      final _Server s = _Server()
        ..onEvidence = (int n) =>
            _Server.ok(evidence(items: const <Map<String, dynamic>>[]));
      await mountPanel(t, s.api);

      expect(find.text('No snapshots for this attempt.'), findsOneWidget);
      expect(find.text('0 snapshots'), findsOneWidget);
    });

    testWidgets('one snapshot reads in the singular', (WidgetTester t) async {
      final _Server s = _Server()
        ..onEvidence = (int n) => _Server.ok(
          evidence(
            items: <Map<String, dynamic>>[
              <String, dynamic>{
                'key': 'k',
                'url': 'https://s3.example/a.jpg',
                'at': _kAt,
                'rule': 'left_frame',
                'size': 1,
              },
            ],
          ),
        );
      await mountPanel(t, s.api);

      expect(find.text('1 snapshot'), findsOneWidget);
      expect(find.text('Left the frame'), findsOneWidget);
    });

    testWidgets('a failed read says so and never draws "no snapshots"', (
      WidgetTester t,
    ) async {
      final _Server s = _Server()
        ..onEvidence = (int n) => _Server.refused(403, 'Admins only.');
      await mountPanel(t, s.api);

      expect(
        find.textContaining('Could not read the snapshots.'),
        findsOneWidget,
      );
      expect(find.textContaining('Admins only.'), findsOneWidget);
      expect(find.text('No snapshots for this attempt.'), findsNothing);
    });

    testWidgets('a paper with no AI rule never asks, so a storage fault '
        'cannot paint every attempt red', (WidgetTester t) async {
      // A paper without AI proctoring never took a snapshot. Reading S3 for it
      // could only fail, and a failure is drawn as an error on the page.
      final _Server s = _Server()
        ..onEvidence = (int n) => _Server.refused(500, 'Storage is down.');
      await mountPanel(t, s.api, ai: false);

      expect(s.evidenceCalls, 0);
      expect(find.text('Proctoring evidence'), findsNothing);
      expect(
        find.textContaining('Could not read the snapshots.'),
        findsNothing,
      );
    });

    testWidgets('a reply the page cannot read is an error too', (
      WidgetTester t,
    ) async {
      final _Server s = _Server()
        ..onEvidence = (int n) => http.Response('<html>proxy</html>', 502);
      await mountPanel(t, s.api);

      expect(
        find.textContaining('Could not read the snapshots.'),
        findsOneWidget,
      );
    });
  });

  group('an older backend without the route', () {
    // Odoo answers a path it does not know with an HTML 404, which the client
    // reports as a 404 that is NOT a domain refusal. That is "this server has
    // no such feature", not "the read failed".
    http.Response htmlNotFound(int n) =>
        http.Response('<html><h1>404 Not Found</h1></html>', 404);

    testWidgets('an HTML 404 hides the panel, even on an AI paper', (
      WidgetTester t,
    ) async {
      final _Server s = _Server()..onEvidence = htmlNotFound;
      await mountPanel(t, s.api);

      expect(s.evidenceCalls, 1, reason: 'it still had to ask');
      expect(find.text('Proctoring evidence'), findsNothing);
      expect(
        find.textContaining('Could not read the snapshots.'),
        findsNothing,
      );
      expect(find.text('No snapshots for this attempt.'), findsNothing);
    });

    testWidgets('an HTML 404 hides the panel on a non-AI paper too', (
      WidgetTester t,
    ) async {
      final _Server s = _Server()..onEvidence = htmlNotFound;
      await mountPanel(t, s.api, ai: false);

      expect(find.text('Proctoring evidence'), findsNothing);
      expect(
        find.textContaining('Could not read the snapshots.'),
        findsNothing,
      );
    });

    testWidgets('a JSON 404 the API wrote is still an error', (
      WidgetTester t,
    ) async {
      final _Server s = _Server()
        ..onEvidence = (int n) => _Server.refused(404, 'Attempt not found.');
      await mountPanel(t, s.api);

      expect(
        find.textContaining('Could not read the snapshots.'),
        findsOneWidget,
      );
      expect(find.textContaining('Attempt not found.'), findsOneWidget);
    });

    testWidgets('a 500 still says so', (WidgetTester t) async {
      final _Server s = _Server()
        ..onEvidence = (int n) => http.Response('<html>oops</html>', 500);
      await mountPanel(t, s.api);

      expect(
        find.textContaining('Could not read the snapshots.'),
        findsOneWidget,
      );
    });
  });

  group('the panel does not grow an empty box', () {
    testWidgets('hidden: a paper without AI proctoring and no snapshots', (
      WidgetTester t,
    ) async {
      final _Server s = _Server()
        ..onEvidence = (int n) =>
            _Server.ok(evidence(items: const <Map<String, dynamic>>[]));
      await mountPanel(t, s.api, ai: false);

      expect(s.evidenceCalls, 0, reason: 'nothing to look for');
      expect(find.text('Proctoring evidence'), findsNothing);
      expect(find.text('No snapshots for this attempt.'), findsNothing);
    });

    // BR-D12: "storage is not set up" is no reason to draw the panel on a paper
    // with no camera rule - there was never anything to keep.
    testWidgets('hidden: no storage on a paper without AI proctoring', (
      WidgetTester t,
    ) async {
      final _Server s = _Server()
        ..onEvidence = (int n) => _Server.ok(<String, dynamic>{
          'items': <Map<String, dynamic>>[],
          'count': 0,
          'storage': 'not_configured',
        });
      await mountPanel(t, s.api, ai: false);

      expect(find.text('Proctoring evidence'), findsNothing);
      expect(
        find.textContaining('Evidence storage is not set up'),
        findsNothing,
      );
    });

    testWidgets('seed mode has no server: nothing drawn, nothing loaded', (
      WidgetTester t,
    ) async {
      await mountPanel(t, null);

      expect(find.text('Proctoring evidence'), findsNothing);
    });
  });

  group('a snapshot opens, and a stale link is renewed first', () {
    testWidgets('a tap opens the image in a dialog with the same caption', (
      WidgetTester t,
    ) async {
      final _Server s = _Server();
      await mountPanel(t, s.api);

      await t.tap(find.text('Phone detected'));
      await t.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      // Thumbnail + dialog title, thumbnail + dialog sub.
      expect(find.text('Phone detected'), findsNWidgets(2));
      expect(find.text(_kIst), findsNWidgets(2));
      expect(s.evidenceCalls, 1, reason: 'a fresh link needs no re-read');
    });

    testWidgets('a link read 14 minutes ago or less is used as it is', (
      WidgetTester t,
    ) async {
      DateTime now = DateTime.utc(2026, 10, 6, 10, 0);
      final _Server s = _Server();
      await mountPanel(t, s.api, clock: () => now);

      now = now.add(const Duration(minutes: 14));
      await t.tap(find.text('Phone detected'));
      await t.pumpAndSettle();

      expect(s.evidenceCalls, 1);
      expect(find.byType(Dialog), findsOneWidget);
    });

    testWidgets(
      'a link older than 14 minutes is re-read, and the new one opens',
      (WidgetTester t) async {
        DateTime now = DateTime.utc(2026, 10, 6, 10, 0);
        final _Server s = _Server()
          ..onEvidence = (int n) => _Server.ok(evidence(sig: '$n'));
        await mountPanel(t, s.api, clock: () => now);
        expect(imageAt('https://s3.example/phone.jpg?sig=1'), findsOneWidget);

        now = now.add(const Duration(minutes: 15));
        await t.tap(find.text('Phone detected'));
        await t.pumpAndSettle();

        expect(s.evidenceCalls, 2);
        expect(find.byType(Dialog), findsOneWidget);
        // The thumbnail and the dialog both draw the RENEWED link; the expired
        // one is gone from the tree.
        expect(imageAt('https://s3.example/phone.jpg?sig=2'), findsNWidgets(2));
        expect(imageAt('https://s3.example/phone.jpg?sig=1'), findsNothing);
      },
    );

    testWidgets(
      'storage not set up is one calm sentence, not a red error or an empty box',
      (WidgetTester t) async {
        final _Server s = _Server()
          ..onEvidence = (int n) => _Server.ok(<String, dynamic>{
            'items': <Map<String, dynamic>>[],
            'count': 0,
            'storage': 'not_configured',
          });
        await mountPanel(t, s.api);

        expect(
          find.text(
            'Evidence storage is not set up on this server, so no snapshots '
            'are kept.',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('Could not read the snapshots.'),
          findsNothing,
        );
        expect(find.byType(Notice), findsNothing);
      },
    );

    testWidgets('a failed renewal says so instead of opening a dead link', (
      WidgetTester t,
    ) async {
      DateTime now = DateTime.utc(2026, 10, 6, 10, 0);
      final _Server s = _Server()
        ..onEvidence = (int n) => n == 1
            ? _Server.ok(evidence())
            : _Server.refused(500, 'Storage is down.');
      await mountPanel(t, s.api, clock: () => now);

      now = now.add(const Duration(minutes: 20));
      await t.tap(find.text('Phone detected'));
      await t.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(
        find.textContaining('Could not read the snapshots.'),
        findsOneWidget,
      );
      expect(find.textContaining('Storage is down.'), findsOneWidget);
    });

    testWidgets('Refresh re-reads and keeps the thumbnails on screen', (
      WidgetTester t,
    ) async {
      final _Server s = _Server()
        ..onEvidence = (int n) => _Server.ok(evidence(sig: '$n'));
      await mountPanel(t, s.api);

      await t.tap(find.text('Refresh'));
      await t.pumpAndSettle();

      expect(s.evidenceCalls, 2);
      expect(imageAt('https://s3.example/phone.jpg?sig=2'), findsOneWidget);
      expect(find.text('Phone detected'), findsOneWidget);
    });
  });

  group('the snapshots open as a zoomable gallery', () {
    /// The lightbox's zoom, which a page change resets.
    double scale(WidgetTester t) => t
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!
        .value
        .getMaxScaleOnAxis();

    testWidgets('a tap opens the picture to zoom, on the one tapped', (
      WidgetTester t,
    ) async {
      final _Server s = _Server();
      await mountPanel(t, s.api);

      await t.tap(find.text('No face in view'));
      await t.pumpAndSettle();

      expect(find.byType(InteractiveViewer), findsOneWidget);
      // Thumbnail + the gallery caption.
      expect(find.text('No face in view'), findsNWidgets(2));
      expect(imageAt('https://s3.example/no_face.jpg?sig=1'), findsNWidgets(2));
    });

    testWidgets('Next and Previous step through the page, unzoomed', (
      WidgetTester t,
    ) async {
      final _Server s = _Server();
      await mountPanel(t, s.api);

      await t.tap(find.text('Phone detected'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Zoom in'));
      await t.pumpAndSettle();
      expect(scale(t), greaterThan(1));

      await t.tap(find.byTooltip('Next'));
      await t.pumpAndSettle();
      expect(find.text('No face in view'), findsNWidgets(2));
      expect(find.text('6 Oct 2026, 3:31 PM IST'), findsNWidgets(2));
      expect(imageAt('https://s3.example/no_face.jpg?sig=1'), findsNWidgets(2));
      expect(scale(t), 1, reason: 'each page starts unzoomed');

      // The last page: Next does nothing.
      await t.tap(find.byTooltip('Next'));
      await t.pumpAndSettle();
      expect(find.text('No face in view'), findsNWidgets(2));

      await t.tap(find.byTooltip('Previous'));
      await t.pumpAndSettle();
      expect(find.text('Phone detected'), findsNWidgets(2));
      expect(find.text('No face in view'), findsOneWidget);
    });

    testWidgets('the arrow keys step too', (WidgetTester t) async {
      final _Server s = _Server();
      await mountPanel(t, s.api);

      await t.tap(find.text('Phone detected'));
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pumpAndSettle();
      expect(find.text('No face in view'), findsNWidgets(2));

      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.pumpAndSettle();
      expect(find.text('Phone detected'), findsNWidgets(2));
    });
  });

  group('the model reads what the wire sends', () {
    test('size parses double-before-int, so 48211.0 stays 48211', () {
      final ProctoringEvidence e = ProctoringEvidence.fromJson(
        <String, dynamic>{'size': 48211.0, 'rule': 'phone'},
      );
      expect(e.size, 48211);
      expect(ProctoringEvidence.fromJson(<String, dynamic>{'size': 7}).size, 7);
    });

    test('a row with nothing in it parses to blanks, never throws', () {
      final ProctoringEvidence e = ProctoringEvidence.fromJson(
        <String, dynamic>{'at': null, 'size': null},
      );
      expect(e.at, isNull);
      expect(e.key, '');
      expect(e.url, '');
      expect(e.size, 0);
      expect(e.ruleLabel, 'Snapshot');
    });

    test('a stamp with no zone is UTC, so its IST caption cannot drift', () {
      final ProctoringEvidence naive = ProctoringEvidence.fromJson(
        <String, dynamic>{'at': '2026-10-06T10:04:00'},
      );
      final ProctoringEvidence zoned = ProctoringEvidence.fromJson(
        <String, dynamic>{'at': '2026-10-06T10:04:00+00:00'},
      );
      expect(naive.at!.isUtc, isTrue);
      expect(istDateTime(naive.at!), _kIst);
      expect(istDateTime(zoned.at!), _kIst);
    });

    // `proctor_ai.js` names a snapshot that no check tripped after why it
    // was taken; an old `gaze_away` one (eye movement, gone 19 Oct) may
    // still sit in the bucket.
    test('the start, routine and old eye-movement snapshots read plainly', () {
      String label(String rule) => ProctoringEvidence.fromJson(
        <String, dynamic>{'rule': rule},
      ).ruleLabel;
      expect(label('start'), 'Start of exam');
      expect(label('periodic'), 'Routine snapshot');
      expect(label('gaze_away'), 'Looking away');
    });

    test('an unknown rule is spelled out rather than hidden', () {
      expect(
        ProctoringEvidence.fromJson(<String, dynamic>{
          'rule': 'hand_raised',
        }).ruleLabel,
        'hand raised',
      );
    });

    test('the page reads the server count, and falls back to the rows', () {
      expect(ProctoringEvidence.parsePage(evidence(count: 9)).count, 9);
      final page = ProctoringEvidence.parsePage(<String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{'key': 'a'},
          'junk',
        ],
      });
      expect(page.items.length, 1, reason: 'a non-row entry is dropped');
      expect(page.count, 1);
      expect(ProctoringEvidence.parsePage(<String, dynamic>{}).count, 0);
    });
  });

  group('the attempt detail mounts it with the attempt', () {
    Map<String, dynamic> assessment({required bool ai}) => <String, dynamic>{
      'id': 'a1',
      'name': 'ETP Assessment Pro',
      'state': 'done',
      'subjective_threshold': 60.0,
      'rules': <String, dynamic>{'ai_proctor': ai},
      'questions': <dynamic>[
        <String, dynamic>{
          'id': 'q1',
          'name': 'Question 1',
          'question_type': 'mcq',
        },
      ],
    };

    Future<_Server> open(
      WidgetTester t, {
      required bool ai,
      http.Response Function(int n)? onEvidence,
      String aiStatus = '',
    }) async {
      t.view.physicalSize = const Size(1800, 4000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final _Server s = _Server()
        ..attemptRow = <String, dynamic>{
          'id': '80',
          'assessment_id': 'a1',
          'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita Rao'},
          'state': 'submitted',
          'answered_count': 1,
          'total_questions': 1,
          if (aiStatus.isNotEmpty) 'ai_status': aiStatus,
        };
      if (onEvidence != null) s.onEvidence = onEvidence;
      final AppStore store = AppStore(api: s.api)
        ..accessRole = AccessRole.admin
        ..caps = Capability.values.toSet()
        ..people = <Person>[
          const Person(id: 'p1', name: 'Anita Rao', email: 'a@example.com'),
        ]
        ..assessments = <Assessment>[Assessment.fromJson(assessment(ai: ai))]
        ..attempts = <Attempt>[Attempt.fromJson(s.attemptRow)];
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: AssessmentNavScope(
              nav: AssessmentNav(),
              child: AttemptDetailScreen(
                store: store,
                portal: Portal.admin,
                attemptId: '80',
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      return s;
    }

    http.Response none(int n) =>
        _Server.ok(evidence(items: const <Map<String, dynamic>>[]));

    testWidgets('a non-AI paper with no snapshots shows no panel', (
      WidgetTester t,
    ) async {
      await open(t, ai: false, onEvidence: none);

      expect(find.byType(Kpi), findsWidgets, reason: 'the screen is up');
      expect(find.text('Proctoring evidence'), findsNothing);
    });

    testWidgets('the evidence is read once, after the attempt request', (
      WidgetTester t,
    ) async {
      final _Server s = await open(t, ai: true);

      final List<String> calls = s.paths
          .where((String p) => p.contains('/attempts/80'))
          .toList();
      expect(calls, <String>[
        '/api/v1/attempts/80',
        '/api/v1/attempts/80/evidence',
      ]);
      expect(
        find.text('Proctoring evidence'),
        findsOneWidget,
        reason: 'the default reply carries two snapshots',
      );
    });

    testWidgets('a non-AI paper makes no evidence request, so a storage '
        'fault shows nothing', (WidgetTester t) async {
      final _Server s = await open(
        t,
        ai: false,
        onEvidence: (int n) => _Server.refused(502, 'Storage is down.'),
      );

      expect(s.evidenceCalls, 0);
      expect(find.text('Proctoring evidence'), findsNothing);
      expect(
        find.textContaining('Could not read the snapshots.'),
        findsNothing,
      );
    });

    testWidgets('shown: the attempt ran AI although the rule is off now', (
      WidgetTester t,
    ) async {
      // The rule can be switched off after a sitting was captured; the
      // attempt's own AI status still says snapshots may exist.
      final _Server s = await open(t, ai: false, aiStatus: 'running');

      expect(s.evidenceCalls, 1);
      expect(find.text('Proctoring evidence'), findsOneWidget);
      expect(find.text('Phone detected'), findsOneWidget);
    });

    testWidgets('an AI paper with no snapshots yet says so', (
      WidgetTester t,
    ) async {
      await open(t, ai: true, onEvidence: none);

      expect(find.text('Proctoring evidence'), findsOneWidget);
      expect(find.text('No snapshots for this attempt.'), findsOneWidget);
    });
  });
}
