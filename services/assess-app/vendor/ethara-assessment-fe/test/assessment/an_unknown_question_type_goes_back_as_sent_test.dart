// L2: a generator's allowed type this build does not know parses as
// `QType.unsupported`. Any chip add or remove then posted "unsupported" back,
// the server refused the whole list (422), and the picker was stuck. The
// server's own code goes back instead, unchanged.
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

const String kNew = 'hologram_prompt';

Generator _gen() => Generator.fromJson(<String, dynamic>{
  'id': 7,
  'name': 'Forklift SOP',
  'allowed_types': <String>['mcq', kNew],
});

void main() {
  test('adding a type sends the unknown one back as its own code', () async {
    final List<Object?> sent = <Object?>[];
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        bearer: 't',
        client: MockClient((http.Request req) async {
          if (req.url.path.endsWith('/question_types')) {
            sent.add((jsonDecode(req.body) as Map<String, dynamic>)['codes']);
          }
          return http.Response(
            jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
    s.source = DataSource.live;
    final Generator g = _gen();
    expect(g.allowedTypes, <QType>[QType.mcq, QType.unsupported]);
    s.generators = <Generator>[g];

    // What the picker does on "Add a type": the list it holds, plus one.
    await s.setAllowedTypes('7', <QType>[...g.allowedTypes, QType.msq]);

    expect(sent, hasLength(1));
    expect(sent.single, <String>['mcq', 'msq', kNew]);
  });

  test('the server code survives the cache round trip', () {
    expect(Generator.fromJson(_gen().toJson()).unknownTypeCodes, <String>[
      kNew,
    ]);
  });

  testWidgets('the unknown type chip is shown but offers no edit', (
    WidgetTester t,
  ) async {
    // Its steppers would post "unsupported" as a quota key, and its remove
    // could not say which unknown code to drop.
    t.view.physicalSize = const Size(1500, 4200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final AppStore s = AppStore();
    final Generator g = s.generators.first;
    s.source = DataSource.live;
    s.updateGenerator(
      g.copyWith(
        allowedTypes: const <QType>[QType.mcq, QType.unsupported],
        shapeQuotas: const <String, int>{},
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: AssessmentNavScope(
            nav: AssessmentNav(),
            child: GeneratorDetailScreen(
              store: s,
              genId: g.id,
              tab: 'generation',
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(find.text(QType.unsupported.short), findsOneWidget);
    // MCQ's controls only.
    expect(find.byTooltip('Remove this type'), findsOneWidget);
    expect(find.byTooltip('One more'), findsOneWidget);
    await t.pump(const Duration(seconds: 4));
  });
}
