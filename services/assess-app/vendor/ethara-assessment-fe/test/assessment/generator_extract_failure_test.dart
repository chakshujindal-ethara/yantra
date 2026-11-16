// A failed extraction has to SAY it failed.
//
// THE BUG THIS EXISTS FOR. `assessments_be_v2` runs tag extraction in a cron,
// records why it failed in `tag_extract_error`, and the serializer sends it on
// every generator row. The client parsed it into `Generator.lastError` and then
// rendered that in exactly one place - the Generation tab - behind the early
// return at `if (!g.hasTags)`. A failed run has no tags, so the only screen
// that could explain the failure was the one screen the failure made
// unreachable.
//
// What the operator saw against the stage backend: press "Extract skills", the
// banner goes to "Extracting...", and a minute later the page is byte for byte
// the one from before the click - "this generator has not read its document
// yet", "Nothing extracted yet". Indistinguishable from a button that does
// nothing, while the server held a perfectly good sentence about a Vertex
// credential.
//
// So: the reason is asserted on all three surfaces a tagless generator can be
// looking at, and the healthy paths are asserted too - a screen that shouts
// "failed" at a generator nobody has run yet is the same bug with the sign
// flipped.
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/generator_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The sentence the module actually records. Long, specific, and the whole
/// point of the change: a generic "something went wrong" would have been no
/// more useful than the silence it replaced.
const String kReason =
    'Vertex refused the call: no credential is configured '
    '(assessments_be_v2.vertex_service_account_json is unset).';

/// A generator row in the shape the server sends it - snake_case, because that
/// is what came off the wire and reading only the camelCase spelling is how
/// this field got dropped once already.
Map<String, dynamic> genRow({
  required String state,
  String error = '',
  int resourceCount = 1,
}) => <String, dynamic>{
  'id': 77,
  'name': 'New T2I Gen',
  'resource_count': resourceCount,
  'tag_extract_state': state,
  'tag_extract_error': error,
  'tags': const <dynamic>[],
};

void main() {
  group('the reason survives the wire', () {
    test('tag_extract_error, snake_case, lands in tagFailure', () {
      final Generator g = Generator.fromJson(
        genRow(state: 'failed', error: kReason),
      );

      expect(g.tagExtractState, TagExtractState.failed);
      expect(g.tagFailure, kReason);
      expect(
        g.isExtractingTags,
        isFalse,
        reason: 'a failed run is finished; the button must not still spin',
      );
    });

    test('failed with no message still reports a failure', () {
      // The cron can die between writing the state and writing the reason.
      // Reporting nothing there would put the screen straight back to
      // "not started yet", which is the bug this file exists for.
      final Generator g = Generator.fromJson(genRow(state: 'failed'));

      expect(g.tagFailure, isNotNull);
      expect(g.tagFailure, contains('did not record a reason'));
    });

    test('tagFailure is narrower than lastError', () {
      // `lastError` answers for BOTH halves and prefers the generation error.
      // The three surfaces below are only reached when there are no tags,
      // where a leftover generation error would name the wrong run.
      final Generator g = Generator.fromJson(<String, dynamic>{
        ...genRow(state: 'failed', error: kReason),
        'sop_gen_error': 'Generation ran out of budget.',
      });

      expect(g.lastError, 'Generation ran out of budget.');
      expect(g.tagFailure, kReason);
    });

    test('no cry wolf: a generator nobody has run has no failure', () {
      expect(Generator.fromJson(genRow(state: 'idle')).tagFailure, isNull);
      expect(Generator.fromJson(genRow(state: 'done')).tagFailure, isNull);
    });

    test('a run in flight is busy, not failed', () {
      for (final String s in <String>['queued', 'generating']) {
        final Generator g = Generator.fromJson(genRow(state: s));
        expect(g.isExtractingTags, isTrue, reason: '$s is busy');
        expect(
          g.tagFailure,
          isNull,
          reason: 're-queueing clears tag_extract_error server-side ($s)',
        );
      }
    });
  });

  group('the screen states it', () {
    late AppStore store;

    setUp(() {
      // Every route answers with the failed row. `_loadAdmin` fans out over
      // nine of them and swallows its own errors, so what matters here is only
      // that the detail route hydrates the record the screen reads.
      store = AppStore(
        api: ApiClient(
          client: MockClient((http.Request req) async {
            final bool list = req.url.path.endsWith('/generators');
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': true,
                'data': list
                    ? <dynamic>[genRow(state: 'failed', error: kReason)]
                    : genRow(state: 'failed', error: kReason),
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
          baseUrl: 'http://x',
        ),
      );
      store.generators = <Generator>[
        Generator.fromJson(genRow(state: 'failed', error: kReason)),
      ];
    });

    Widget app(String tab) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: GeneratorDetailScreen(store: store, genId: '77', tab: tab),
        ),
      ),
    );

    testWidgets('Skills & Templates shows the reason, not an empty line', (
      WidgetTester t,
    ) async {
      await t.pumpWidget(app('skills'));
      await t.pump();

      expect(find.textContaining(kReason, findRichText: true), findsWidgets);
      expect(
        find.textContaining('Nothing extracted yet', findRichText: true),
        findsNothing,
        reason: 'this line is what made a refused run look like an idle one',
      );
    });

    testWidgets('the step banner names the failure', (WidgetTester t) async {
      await t.pumpWidget(app('skills'));
      await t.pump();

      expect(
        find.textContaining(
          'Step 2 of 3 - reading the document failed.',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'has not read its document yet',
          findRichText: true,
        ),
        findsNothing,
      );
    });

    testWidgets('the Generation gate stops saying "extract them first"', (
      WidgetTester t,
    ) async {
      await t.pumpWidget(app('generation'));
      await t.pump();

      expect(find.textContaining(kReason, findRichText: true), findsWidgets);
      expect(
        find.textContaining('Extract the skills first', findRichText: true),
        findsNothing,
        reason: 'that told the operator to redo the thing that just failed',
      );
    });
  });
}
