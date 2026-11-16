// The generator page follows its own run (ETP_PLANS_AND_STRATEGY.md §4.9).
//
// THE ASK. The owner watched 16 drafts sit on "Pending" / "No image yet" for up
// to 12 minutes on prod with nothing on the page saying why: the image cron
// renders 2 drafts every 5 minutes, one draft failed with no retry in the app,
// and the store's 2 s `pollGeneration` had long since given up.
//
// Now the page reads `GET /generators/<id>/progress` on the scoring watch's
// schedule and shows one banner in the scoring style, run stats on the
// Generation tab, and "Retry failed images (n)" to the roles that may use it.
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
import 'package:ethara_assessment/assessment/screens/admin/generator_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

/// The contract's own example payload.
Map<String, dynamic> full() => <String, dynamic>{
  'generator_id': 77,
  'phase': 'media',
  'active': true,
  'summary':
      'Rendering media · images 3/6 (1 failed) · videos 2/3 · '
      'next image batch ~12:05 IST',
  'stalled': false,
  'stalled_reason': null,
  'next_generation_run_at': '2026-09-29T06:20:00Z',
  'run': <String, dynamic>{
    'started_at': '2026-09-29T06:15:09Z',
    'finished_at': '2026-09-29T06:18:27Z',
    'elapsed_s': 198,
    'llm_calls': 7,
    'last_step': 'critique',
    'last_step_at': '2026-09-29T06:18:26Z',
    'cost_usd': 1.23,
  },
  'drafts': <String, dynamic>{
    'total': 16,
    'pending': 16,
    'approved': 0,
    'denied': 0,
  },
  'images': <String, dynamic>{
    'total': 6,
    'pending': 2,
    'rendered': 3,
    'uploaded': 0,
    'failed': 1,
    'cancelled': 0,
  },
  'videos': <String, dynamic>{
    'total': 3,
    'pending': 1,
    'ready': 2,
    'failed': 0,
  },
  'media': <String, dynamic>{
    'next_image_run_at': '2026-09-29T06:20:40Z',
    'images_per_run': 2,
    'image_run_every_min': 5,
    'est_minutes_left': 5,
    'next_video_run_at': '2026-09-29T06:19:00Z',
  },
  'failed_images': <dynamic>[
    <String, dynamic>{'id': 85, 'name': 'Mark physical defects'},
  ],
  'can_retry_images': true,
  'show_cost': true,
};

/// A generator the Generation tab will open on: a document, skills read.
///
/// `done`, not busy, on purpose: the banner reads the progress route, and a
/// store that still called it running would hand it back to `pollGeneration`
/// when the test tears the page down.
Map<String, dynamic> genRow() => <String, dynamic>{
  'id': 77,
  'name': 'Egocentric frames',
  'resource_count': 1,
  'sop_gen_state': 'done',
  'tag_extract_state': 'done',
  'tags': <dynamic>[
    <String, dynamic>{'id': 1, 'name': 'domain:frames', 'display': 'Frames'},
  ],
  'allowed_types': <dynamic>['mcq'],
};

/// Answers `/progress` from a script, the last entry repeating, and tallies
/// every path.
class _Spy {
  final List<String> paths = <String>[];
  final List<Map<String, dynamic>> progress;

  _Spy(List<Map<String, dynamic>> progress)
    : progress = <Map<String, dynamic>>[...progress];

  int hits(String suffix) =>
      paths.where((String p) => p.endsWith(suffix)).length;

  http.Client get client => MockClient((http.Request req) async {
    final String path = req.url.path;
    paths.add(path);
    Object data = <dynamic>[];
    if (path.endsWith('/progress')) {
      data = progress.length > 1 ? progress.removeAt(0) : progress.first;
    } else if (path.endsWith('/generators')) {
      data = <dynamic>[genRow()];
    } else if (path.endsWith('/generators/77')) {
      data = genRow();
    } else if (path.endsWith('/retry_failed_images')) {
      data = <String, dynamic>{'retried': 1};
    }
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
}

Future<(_Spy, AppStore)> _open(
  WidgetTester t,
  List<Map<String, dynamic>> script, {
  String tab = 'generation',
}) async {
  final _Spy spy = _Spy(script);
  final AppStore s =
      AppStore(api: ApiClient(baseUrl: 'http://stub', client: spy.client))
        ..generators = <Generator>[Generator.fromJson(genRow())];
  t.view.physicalSize = const Size(1600, 3200);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: GeneratorDetailScreen(store: s, genId: '77', tab: tab),
        ),
      ),
    ),
  );
  await _wait(t, 0.1);
  addTearDown(() async => t.pumpWidget(const SizedBox.shrink()));
  return (spy, s);
}

/// Advance [seconds] and let the tick's request land.
Future<void> _wait(WidgetTester t, double seconds) async {
  await t.pump(Duration(milliseconds: (seconds * 1000).round()));
  await t.pump();
}

Finder _text(String s) => find.textContaining(s, findRichText: true);

Map<String, dynamic> _phase(
  String phase,
  String summary, {
  bool active = true,
  bool stalled = false,
  String reason = '',
  bool showCost = false,
  bool canRetry = false,
  int failed = 0,
}) => <String, dynamic>{
  'phase': phase,
  'active': active,
  'summary': summary,
  'stalled': stalled,
  'stalled_reason': reason,
  'run': <String, dynamic>{
    'started_at': '2026-09-29T06:15:09Z',
    'finished_at': active ? null : '2026-09-29T06:18:27Z',
    'elapsed_s': 198,
    'llm_calls': 7,
    'cost_usd': showCost ? 1.23 : null,
  },
  'drafts': <String, dynamic>{'total': 16, 'pending': 16},
  'images': <String, dynamic>{'total': 6, 'rendered': 5, 'failed': failed},
  'can_retry_images': canRetry,
  'show_cost': showCost,
};

void main() {
  group('the payload parses whatever arrives', () {
    test('the full contract', () {
      final GenerationProgress p = GenerationProgress.fromJson(full());
      expect(p.phase, 'media');
      expect(p.active, isTrue);
      expect(p.summary, startsWith('Rendering media'));
      expect(p.stalled, isFalse);
      expect(p.stalledReason, '', reason: 'null reads as empty, not "null"');
      expect(p.startedAt, DateTime.utc(2026, 9, 29, 6, 15, 9));
      expect(p.finishedAt, DateTime.utc(2026, 9, 29, 6, 18, 27));
      expect(p.elapsedS, 198);
      expect(p.llmCalls, 7);
      expect(p.lastStep, 'critique');
      expect(p.costUsd, 1.23);
      expect(p.showCost, isTrue);
      expect(p.drafts.total, 16);
      expect(p.drafts.pending, 16);
      expect(p.images.done, 3);
      expect(p.images.failed, 1);
      expect(p.images.pending, 2);
      expect(p.videos.ready, 2);
      expect(p.videos.total, 3);
      expect(p.estMinutesLeft, 5);
      expect(p.canRetryImages, isTrue);
      expect(p.hasRun, isTrue);
    });

    test('a partial payload keeps its defaults', () {
      final GenerationProgress p = GenerationProgress.fromJson(
        <String, dynamic>{
          'phase': 'queued',
          'active': true,
          'run': <String, dynamic>{'started_at': false, 'llm_calls': 2.0},
          'images': 'not a map',
        },
      );
      expect(p.phase, 'queued');
      expect(p.active, isTrue);
      expect(p.summary, '');
      expect(p.startedAt, isNull, reason: "Odoo's false is not a date");
      expect(p.llmCalls, 2, reason: 'a count arriving as 2.0 is still two');
      expect(p.images.total, 0);
      expect(p.costUsd, isNull);
      expect(p.estMinutesLeft, isNull);
      expect(p.hasRun, isFalse);
    });

    test('no keys at all is an idle run, not a crash', () {
      final GenerationProgress p = GenerationProgress.fromJson(
        const <String, dynamic>{},
      );
      expect(p.phase, 'idle');
      expect(p.active, isFalse);
      expect(p.stalled, isFalse);
      expect(p.canRetryImages, isFalse);
      expect(p.drafts.total, 0);
    });

    test('a cost is dropped unless the server says to show it', () {
      final GenerationProgress p = GenerationProgress.fromJson(
        <String, dynamic>{...full(), 'show_cost': false},
      );
      expect(p.costUsd, isNull, reason: 'operators only, as /ledger');
    });

    test('the generator row carries its run stamps and draft counts', () {
      final Generator g = Generator.fromJson(<String, dynamic>{
        ...genRow(),
        'sop_gen_started_at': '2026-09-29T06:15:09Z',
        'sop_gen_finished_at': false,
        'draft_counts': <String, dynamic>{
          'pending': 3,
          'approved': 2,
          'denied': 1,
          'total': 6,
        },
      });
      expect(g.sopGenStartedAt, DateTime.utc(2026, 9, 29, 6, 15, 9));
      expect(g.sopGenFinishedAt, isNull);
      expect(g.draftCounts.total, 6);
      expect(g.draftCounts.approved, 2);
      expect(g.copyWith(name: 'x').draftCounts.denied, 1);
      expect(Generator.fromJson(genRow()).draftCounts.total, 0);
    });
  });

  group('one banner, in the scoring style', () {
    testWidgets('queued: the server line, with a spinner', (
      WidgetTester t,
    ) async {
      await _open(t, <Map<String, dynamic>>[
        _phase('queued', 'Queued · starts at the next generation run'),
      ]);
      expect(_text('Queued · starts at the next generation run'),
          findsOneWidget);
      expect(find.byType(Spinner), findsOneWidget);
      expect(_text('Generation is not running.'), findsNothing);
    });

    testWidgets('authoring: the step and the call count', (
      WidgetTester t,
    ) async {
      await _open(t, <Map<String, dynamic>>[
        _phase(
          'authoring',
          'Writing questions · step critique · 7 model calls',
        ),
      ]);
      expect(_text('Writing questions · step critique'), findsOneWidget);
      expect(find.byType(Spinner), findsOneWidget);
    });

    testWidgets('media: images and videos, and when the next batch is', (
      WidgetTester t,
    ) async {
      await _open(t, <Map<String, dynamic>>[full()]);
      expect(_text('Rendering media · images 3/6 (1 failed)'),
          findsOneWidget);
      expect(find.byType(Spinner), findsOneWidget);
    });

    testWidgets('stalled: red, with the reason, and no spinner', (
      WidgetTester t,
    ) async {
      await _open(t, <Map<String, dynamic>>[
        _phase(
          'media',
          'Rendering media · images 3/6',
          stalled: true,
          reason: 'The image cron is disabled.',
        ),
      ]);
      expect(_text('Generation is not running.'), findsOneWidget);
      expect(_text('The image cron is disabled.'), findsOneWidget);
      expect(find.byType(Spinner), findsNothing,
          reason: 'a stalled run is not moving; a spinner would say it is');
      final Notice n = t.widget<Notice>(
        find.ancestor(
          of: _text('The image cron is disabled.'),
          matching: find.byType(Notice),
        ),
      );
      expect(n.tone, Tone.bad);
    });

    testWidgets('ready, for an operator: the run cost, here and on the tab', (
      WidgetTester t,
    ) async {
      await _open(t, <Map<String, dynamic>>[
        _phase(
          'ready',
          '16 drafts ready for review · 16 pending · took 3 min '
              '· run cost \$1.23',
          active: false,
          showCost: true,
        ),
      ]);
      expect(_text('16 drafts ready for review'), findsOneWidget);
      expect(find.byType(Spinner), findsNothing);
      expect(_text('cost \$1.23'), findsNWidgets(2),
          reason: 'the banner line and the Model calls stat');
      expect(_text('DRAFTS THIS RUN'), findsOneWidget);
      expect(_text('took 3 min'), findsNWidgets(2));
    });

    testWidgets('ready, for everyone else: no dollar anywhere', (
      WidgetTester t,
    ) async {
      await _open(t, <Map<String, dynamic>>[
        _phase(
          'ready',
          '16 drafts ready for review · 16 pending · took 3 min',
          active: false,
        ),
      ]);
      expect(_text('16 drafts ready for review'), findsOneWidget);
      expect(_text('\$'), findsNothing);
      expect(_text('MODEL CALLS'), findsOneWidget);
    });

    testWidgets('idle: nothing to say, so no banner', (WidgetTester t) async {
      await _open(t, <Map<String, dynamic>>[
        <String, dynamic>{'phase': 'idle', 'active': false, 'summary': ''},
      ]);
      expect(find.byType(Spinner), findsNothing);
      expect(_text('DRAFTS THIS RUN'), findsNothing);
    });
  });

  group('Retry failed images (n)', () {
    testWidgets('offered when the server allows it and something failed', (
      WidgetTester t,
    ) async {
      final (_Spy spy, _) = await _open(t, <Map<String, dynamic>>[
        _phase('ready', 'ready', active: false, canRetry: true, failed: 1),
      ]);
      expect(_text('Retry failed images (1)'), findsOneWidget);

      final int reads = spy.hits('/progress');
      await t.tap(_text('Retry failed images (1)'));
      await _wait(t, 0.1);
      expect(spy.hits('/generators/77/retry_failed_images'), 1);
      expect(spy.hits('/progress'), reads + 1,
          reason: 'a retry is media work again, so the watch restarts');
      // Past the confirmation toast's own 3.2 s timer.
      await _wait(t, 4);
    });

    testWidgets('hidden from a role the server refuses', (
      WidgetTester t,
    ) async {
      await _open(t, <Map<String, dynamic>>[
        _phase('ready', 'ready', active: false, failed: 1),
      ]);
      expect(_text('Retry failed images'), findsNothing);
    });

    testWidgets('hidden when nothing failed', (WidgetTester t) async {
      await _open(t, <Map<String, dynamic>>[
        _phase('ready', 'ready', active: false, canRetry: true),
      ]);
      expect(_text('Retry failed images'), findsNothing);
    });
  });

  group('the watch', () {
    testWidgets('stops when the run is no longer active, after one reload', (
      WidgetTester t,
    ) async {
      final Map<String, dynamic> busy = _phase('authoring', 'Writing');
      final (_Spy spy, AppStore s) = await _open(t, <Map<String, dynamic>>[
        busy,
        busy,
        _phase('ready', '16 drafts ready for review', active: false),
      ]);
      expect(spy.hits('/progress'), 1, reason: 'read on open');
      expect(s.screenWatchedGenerators, contains('77'),
          reason: 'the store poll leaves this generator to the page');
      final int details = spy.hits('/generators/77');

      await _wait(t, 5);
      expect(spy.hits('/progress'), 2, reason: 'the first answer is news: 5 s');
      await _wait(t, 15);
      expect(spy.hits('/progress'), 3, reason: 'one unchanged answer: 15 s');

      expect(_text('16 drafts ready for review'), findsOneWidget);
      expect(spy.hits('/generators/77'), details + 1,
          reason: 'the run ending earns one quiet reload of the generator');
      expect(spy.paths.where((String p) => p.endsWith('/drafts')), isNotEmpty,
          reason: '... and of its drafts');
      expect(s.screenWatchedGenerators, isEmpty);

      await _wait(t, 600);
      expect(spy.hits('/progress'), 3,
          reason: 'a finished run is not watched; ten minutes ask nothing');
    });

    testWidgets('a failed tick keeps the banner on screen', (
      WidgetTester t,
    ) async {
      int reads = 0;
      final AppStore s = AppStore(
        api: ApiClient(
          baseUrl: 'http://stub',
          client: MockClient((http.Request req) async {
            final bool progress = req.url.path.endsWith('/progress');
            if (progress && reads++ > 0) {
              return http.Response('upstream down', 502);
            }
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': true,
                'data': progress
                    ? _phase('authoring', 'Writing questions')
                    : (req.url.path.endsWith('/generators/77')
                          ? genRow()
                          : <dynamic>[]),
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
        ),
      )..generators = <Generator>[Generator.fromJson(genRow())];
      t.view.physicalSize = const Size(1600, 3200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: AssessmentNavScope(
              nav: AssessmentNav(),
              child: GeneratorDetailScreen(store: s, genId: '77', tab: 'corpus'),
            ),
          ),
        ),
      );
      await _wait(t, 0.1);
      addTearDown(() async => t.pumpWidget(const SizedBox.shrink()));
      expect(_text('Writing questions'), findsOneWidget);

      await _wait(t, 5);
      expect(reads, 2);
      expect(_text('Writing questions'), findsOneWidget,
          reason: 'a background blip must not wipe what the operator reads');
    });
  });

  group('pollGeneration', () {
    Map<String, dynamic> busyRow() => <String, dynamic>{
      ...genRow(),
      'sop_gen_state': 'generating',
    };

    AppStore store(List<String> paths) => AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        client: MockClient((http.Request req) async {
          paths.add(req.url.path);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': req.url.path.endsWith('/generators')
                  ? <dynamic>[busyRow()]
                  : <dynamic>[],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    )..generators = <Generator>[Generator.fromJson(busyRow())];

    test('leaves a generator its page is watching alone', () async {
      final List<String> paths = <String>[];
      final AppStore s = store(paths)..screenWatchedGenerators.add('77');
      await s.pollGeneration(every: const Duration(milliseconds: 1));
      expect(paths, isEmpty,
          reason: 'no 2 s re-read of every page for a run the page follows');
    });

    test('still follows it for everyone else', () async {
      final List<String> paths = <String>[];
      final AppStore s = store(paths);
      await s.pollGeneration(
        every: const Duration(milliseconds: 1),
        maxTicks: 3,
      );
      expect(paths.where((String p) => p.endsWith('/generators')), hasLength(3));
    });
  });
}
