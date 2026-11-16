// Does a detail screen refetch when the route points at a DIFFERENT record?
//
// THE BUG THIS EXISTS FOR: every admin detail screen hydrated from its
// `initState` and none implemented `didUpdateWidget`. The router builds these
// screens with no key at a fixed slot, so walking from one record to another
// of the same kind reuses the same State - `initState` never runs again, and
// the second record is never fetched.
//
// Reported live on the generator Similarity tab: opening a match from one
// generator showed the other's Similarity as empty, in both directions, while
// the server held both directed pairs. A browser refresh "fixed" it, because
// that restarts the State. Only the DETAIL route carries `similar`; the list
// row does not, so there was nothing in the store to fall back on.
//
// The assertion is on the REQUEST, not on painted pixels: what broke was the
// fetch, and a screen that renders the right thing only because the store
// happened to be warm would pass a pixel test while still being broken.
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/generator_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/response_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Records which generator detail routes were asked for.
class _GeneratorRig {
  final List<String> fetched = <String>[];
  late final AppStore store;

  _GeneratorRig() {
    store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          // `/api/v1/generators/<id>` is the DETAIL route - the only one that
          // carries `similar`.
          final RegExp detail = RegExp(r'/api/v1/generators/([^/]+)$');
          final RegExpMatch? m = detail.firstMatch(path);
          if (m != null) fetched.add(m.group(1)!);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{
                'id': m?.group(1) ?? '0',
                'name': 'Generator ${m?.group(1) ?? '0'}',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        baseUrl: 'http://x',
      ),
    );
  }

  Widget app(String genId) => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: AssessmentNavScope(
        nav: AssessmentNav(),
        child: GeneratorDetailScreen(store: store, genId: genId),
      ),
    ),
  );
}

/// Records which attempt detail routes were asked for.
class _AttemptRig {
  final List<String> fetched = <String>[];
  late final AppStore store;

  _AttemptRig() {
    store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          // `/api/v1/attempts/<id>` is the DETAIL route - the only one that
          // carries the answers. The assessment fetched behind it lands on
          // `/api/v1/assessments/...` and is deliberately not counted here.
          final RegExp detail = RegExp(r'/api/v1/attempts/([^/]+)$');
          final RegExpMatch? m = detail.firstMatch(path);
          if (m != null) fetched.add(m.group(1)!);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{'id': path.split('/').last},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        baseUrl: 'http://x',
      ),
    );
  }

  Widget app(String attemptId) => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: AssessmentNavScope(
        nav: AssessmentNav(),
        child: AttemptDetailScreen(
          store: store,
          portal: Portal.admin,
          attemptId: attemptId,
        ),
      ),
    ),
  );
}

/// Records which response detail routes were asked for, `<attempt>/<question>`.
class _ResponseRig {
  final List<String> fetched = <String>[];
  late final AppStore store;

  _ResponseRig() {
    store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          // `/api/v1/responses/<attempt>/<question>` is the DETAIL route - the
          // only one that carries `lines`, `subscores` and the grading.
          final RegExp detail = RegExp(r'/api/v1/responses/([^/]+)/([^/]+)$');
          final RegExpMatch? m = detail.firstMatch(path);
          if (m != null) fetched.add('${m.group(1)}/${m.group(2)}');
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{'id': path.split('/').last},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        baseUrl: 'http://x',
      ),
    );
  }

  Widget app(String attemptId, String questionId) => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: AssessmentNavScope(
        nav: AssessmentNav(),
        child: ResponseDetailScreen(
          store: store,
          attemptId: attemptId,
          questionId: questionId,
        ),
      ),
    ),
  );
}

/// Records which assessment detail routes were asked for.
class _AssessmentRig {
  final List<String> fetched = <String>[];
  late final AppStore store;

  _AssessmentRig() {
    store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          // `/api/v1/assessments/<id>` is the DETAIL route - the only one that
          // carries the roster, the selected questions and the rules.
          final RegExp detail = RegExp(r'/api/v1/assessments/([^/]+)$');
          final RegExpMatch? m = detail.firstMatch(path);
          if (m != null) fetched.add(m.group(1)!);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{
                'id': path.split('/').last,
                'name': 'Assessment ${path.split('/').last}',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        baseUrl: 'http://x',
      ),
    );
  }

  Widget app(String asmId) => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: AssessmentNavScope(
        nav: AssessmentNav(),
        child: AssessmentDetailScreen(
          store: store,
          portal: Portal.admin,
          asmId: asmId,
        ),
      ),
    ),
  );
}

void main() {
  // A desktop-sized surface: this screen is an admin page and overflows the
  // 800x600 test default, which throws during layout and masks the assertion.
  void desktop(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('opening a different generator refetches its detail', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    final _GeneratorRig rig = _GeneratorRig();

    await tester.pumpWidget(rig.app('323'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(rig.fetched, contains('323'), reason: 'the first one is fetched');

    // The router rebuilds the SAME widget type at the SAME slot with a new id -
    // no key - so Flutter reuses the State and initState does not run again.
    await tester.pumpWidget(rig.app('1893'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      rig.fetched,
      contains('1893'),
      reason: 'walking to another generator must fetch it; without '
          'didUpdateWidget its Similarity tab renders empty over pairs the '
          'server is holding, until a browser refresh',
    );
  });

  testWidgets('rebuilding with the SAME id does not refetch', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    final _GeneratorRig rig = _GeneratorRig();

    await tester.pumpWidget(rig.app('323'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final int after = rig.fetched.length;

    // An ordinary rebuild - a store notify, a theme change - must not re-issue
    // the request, or every repaint would hit the server.
    await tester.pumpWidget(rig.app('323'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(rig.fetched.length, after, reason: 'no refetch for the same record');
  });

  testWidgets('opening a different attempt refetches its detail', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    final _AttemptRig rig = _AttemptRig();

    await tester.pumpWidget(rig.app('80'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(rig.fetched, contains('80'), reason: 'the first one is fetched');

    await tester.pumpWidget(rig.app('81'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      rig.fetched,
      contains('81'),
      reason:
          'walking from one candidate\'s attempt to the next must fetch it; '
          'without didUpdateWidget the second shows the first one\'s answers, '
          'or "Attempt not found", until a browser refresh',
    );
  });

  testWidgets('rebuilding with the SAME attempt id does not refetch', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    final _AttemptRig rig = _AttemptRig();

    await tester.pumpWidget(rig.app('80'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final int after = rig.fetched.length;

    await tester.pumpWidget(rig.app('80'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(rig.fetched.length, after, reason: 'no refetch for the same record');
  });

  testWidgets('opening a different answer refetches its detail', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    final _ResponseRig rig = _ResponseRig();

    await tester.pumpWidget(rig.app('80', '205'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(rig.fetched, contains('80/205'), reason: 'the first one is fetched');

    // The QUESTION half of the route changes on its own when the reader walks
    // between answers on one attempt, so it has to be part of the comparison.
    await tester.pumpWidget(rig.app('80', '206'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      rig.fetched,
      contains('80/206'),
      reason:
          'walking to the next answer must fetch it; without didUpdateWidget '
          'the per-dimension marking stays on the answer first opened',
    );
  });

  testWidgets('rebuilding with the SAME answer does not refetch', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    final _ResponseRig rig = _ResponseRig();

    await tester.pumpWidget(rig.app('80', '205'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final int after = rig.fetched.length;

    await tester.pumpWidget(rig.app('80', '205'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(rig.fetched.length, after, reason: 'no refetch for the same record');
  });

  testWidgets('opening a different assessment refetches its detail', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    final _AssessmentRig rig = _AssessmentRig();

    await tester.pumpWidget(rig.app('12'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(rig.fetched, contains('12'), reason: 'the first one is fetched');

    await tester.pumpWidget(rig.app('13'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      rig.fetched,
      contains('13'),
      reason:
          'walking to another assessment must fetch it; without '
          'didUpdateWidget the roster, the selected questions and the rules '
          'render as the empty state until a browser refresh',
    );
  });

  testWidgets('rebuilding with the SAME assessment id does not refetch', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    final _AssessmentRig rig = _AssessmentRig();

    await tester.pumpWidget(rig.app('12'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final int after = rig.fetched.length;

    await tester.pumpWidget(rig.app('12'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(rig.fetched.length, after, reason: 'no refetch for the same record');
  });
}
